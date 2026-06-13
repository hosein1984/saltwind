# Chapter 99 — Cargo Below Decks

*Part 15 — The Engine Room · Estimated time: 5h · learnopengl: no direct equivalent — this is engine material. PBO mechanics reference: the OpenGL wiki's "Pixel Buffer Object" and "Buffer Object Streaming" pages are the honest sources.*

**What you'll see when done:** sail toward an island and watch its high-res textures fade in from the ch83 magenta-checker fallback a few seconds out — while the ch49 frame-time graph stays ruler-flat where it used to spike off the chart.

## Where we are

Saltwind loads everything at startup — fine for a fixed asset set, fatal for ch100's endless world. The naive alternative, "load it when you need it," means file IO and PNG decode *inside a frame*. This chapter builds the real thing: workers read and decode, the main thread uploads on a budget, and every asset knows whether it's resident. The ch98 split — *produce on workers, upload on main* — becomes a permanent piece of infrastructure.

## Concepts

### First, the crime scene

Before fixing the hitch, cause one. Bind a debug key that loads a fat texture (a 4096² PNG — make one) synchronously, mid-frame, the way Chapter 6 taught you: `stbi.load`, `gl.TexImage2D`, mipmaps. On the ch49 frame graph that's a single bar 5–10× taller than its neighbors: ~50–150 ms of file read + inflate + decode, plus a few ms of upload. One such frame is a visible stumble; one per island approach is a seasick game. *Measure it; write the number down.* The whole chapter exists to delete that bar.

The anatomy of the hitch tells us where everything goes:

| Stage | Cost (4k PNG, typical) | Needs GL? | → Runs on |
|---|---|---|---|
| File read | 5–30 ms | no | worker |
| PNG decode (stbi) | 40–120 ms | no | worker |
| Texture create + upload | 2–8 ms | **yes** | main, *budgeted* |
| Mipmap generation | 1–3 ms | **yes** | main, same budget |

### Residency: every asset is a tiny state machine

```
 Unloaded ──request──> Loading ──decoded──> Pending_Upload ──budget──> Ready
    ^                                                                   │
    └───────────────────────── evict (ch100) ───────────────────────────┘
```

While not `Ready`, the renderer uses the ch83 fallback (magenta checker for textures) — which means **streaming is a quality problem, not a correctness problem**. The game never waits, never crashes, never renders garbage; it just looks worse for a moment. That property is what makes the rest of this part safe to build.

### The upload budget

Uploads happen on main (GL's rule), so they must be *rationed*: a per-frame time budget, ~2 ms, spent from a priority-ordered queue of decoded results. A 16 MB RGBA texture might not fit one frame's budget — so big textures upload in **slices** (a few hundred rows of `gl.TexSubImage2D` per frame into a pre-created texture). Smoothness beats latency: a texture arriving over 6 frames is invisible; a 12 ms frame is not.

### Priority is geography

What loads first? Whatever you're sailing toward. Each frame (or each half second), score requests by distance from the camera to the asset's user — island distance for terrain detail, model distance for prop textures — and pop the queue best-first. A binary heap is overkill at our counts; sort the pending list when you enqueue. Re-prioritization on direction change falls out free.

### PBO streaming vs. plain TexSubImage2D — measured, not believed

`gl.TexSubImage2D` from client memory makes the driver copy your bytes into its own staging memory, then DMA to the GPU. A **Pixel Buffer Object** lets you write into driver-visible memory yourself: bind a buffer to `gl.PIXEL_UNPACK_BUFFER`, map a region with `gl.MapBufferRange(… gl.MAP_WRITE_BIT | gl.MAP_UNSYNCHRONIZED_BIT)`, memcpy on any thread you like*, unmap, then `TexSubImage2D` with an *offset* instead of a pointer — the copy to GPU happens async. `MAP_UNSYNCHRONIZED` means "driver, don't stall checking whether the GPU still reads this region — I promise it doesn't," and you keep that promise with **fences**: after the upload, `f := gl.FenceSync(gl.SYNC_GPU_COMMANDS_COMPLETE, 0)`; before reusing that PBO region, `gl.ClientWaitSync(f, 0, 0)` must report signaled (`gl.ALREADY_SIGNALED`/`gl.CONDITION_SATISFIED`), else use the next region in the ring. Lie to `MAP_UNSYNCHRONIZED` and you upload pixels into texels the GPU is mid-read — the classic shimmering-garbage bug.

(*The map/unmap **calls** are GL and stay on main; the *pointer* you get can be memcpy'd into from a worker between them if you're careful. We keep even the memcpy on main today — decoded bytes are already in RAM and the copy is cheap.)

The honest recommendation, which you will verify in step 6: **on modern desktop drivers, plain `TexSubImage2D` with sliced uploads is usually within noise of the PBO ring** — drivers internally do what the PBO does manually. PBOs win when you stream constantly (video, ch100's worst case) or on stingier drivers. Build plain first, keep the PBO path behind a flag, and let the ch49 timers choose. Engines carry both for exactly this reason.

## Odin notes

- `stbi.load` (`vendor:stb/image`) is safe to call concurrently from several workers — its state is per-call. The exception is the global vertical-flip flag: `stbi.set_flip_vertically_on_load(1)` has been set **once at startup** since Chapter 6 — leave it alone forever after; toggling it per-load from workers is a race on a global.
- `stbi.load` allocates with malloc; the pointer travels to the main thread in the result struct and main calls `stbi.image_free` after upload. Cross-thread malloc/free is fine; *who* frees must be written down. Put `// freed by upload_queue after upload` at the field.
- A fire-and-forget job's args can't live on the temp allocator (ch98 note): the load-request struct is heap-allocated by `stream_request` and freed by the upload pass after completion.
- `gl.MapBufferRange(target, offset, length, access) -> rawptr` returns a raw pointer; build a slice over it the Odin way: `pixels := ([^]u8)(ptr)[:length]`. And check it for `nil` — maps can fail.

## Build

1. **Cause the hitch** (Concepts, "crime scene"). Record the spike's ms with the ch49 graph. This number is the chapter's villain.

2. **Asset states.** In `src/assets.odin`, extend your texture record:

   ```odin
   Residency :: enum { Unloaded, Loading, Pending_Upload, Ready }

   Streamed_Texture :: struct {
   	path:     string,
   	id:       u32,       // valid only when Ready; else use assets.fallback_texture
   	state:    Residency, // written via sync.atomic_store, read via atomic_load
   	priority: f32,       // distance² to camera; smaller = sooner
   	// decoded result, owned by the loader until upload:
   	pixels:   [^]u8,
   	w, h:     i32,
   }
   ```

   `texture_bind_or_fallback(t)` returns `t.id` when `Ready`, else the ch83 magenta checker. Sweep your draw paths through it.

3. **The load job.** `stream_request(s, tex)` flips state to `Loading` and submits a ch98 fire-and-forget job (heap-allocated request):

   ```odin
   stream_load_job :: proc(raw: rawptr) {
   	t := (^Streamed_Texture)(raw)
   	w, h, ch: i32
   	t.pixels = stbi.load(strings.clone_to_cstring(t.path, context.temp_allocator),
   	                     &w, &h, &ch, 4)
   	t.w, t.h = w, h
   	if t.pixels == nil { sync.atomic_store(&t.state, Residency.Unloaded); return } // ch83: log once
   	sync.atomic_store(&t.state, Residency.Pending_Upload)

   	sync.mutex_lock(&g_streamer.mutex)
   	append(&g_streamer.pending_uploads, t)
   	sync.mutex_unlock(&g_streamer.mutex)
   }
   ```

   The atomic store of `state` is the publication point; main never touches `pixels` until it observes `Pending_Upload`.

4. **The budgeted upload pass.** `stream_update(s)` runs once per frame on main, after sim, before render:

   ```odin
   UPLOAD_BUDGET_MS :: 2.0
   start := time.tick_now()
   for {
   	if time.duration_milliseconds(time.tick_since(start)) > UPLOAD_BUDGET_MS do break
   	sync.mutex_lock(&s.mutex)
   	slice.sort_by(s.pending_uploads[:], proc(a, b: ^Streamed_Texture) -> bool {
   		return a.priority < b.priority
   	})
   	t, got := pop_safe(&s.pending_uploads)
   	sync.mutex_unlock(&s.mutex)
   	if !got do break
   	stream_upload_some(s, t) // creates texture on first call, then slices
   }
   ```

   `stream_upload_some` does `gl.TexStorage2D` once (immutable, levels for full mip chain), then `gl.TexSubImage2D` for up to N rows per call (size N so one slice ≈ 0.5 ms; measure); when the last slice lands: `gl.GenerateMipmap`, `stbi.image_free(t.pixels)`, `sync.atomic_store(&t.state, Residency.Ready)`. A partially-uploaded texture stays `Pending_Upload` and goes back in the queue.

5. **Priority = distance.** Each half second, for every `Unloaded` streamable in the world: `t.priority = dist2(camera, owner_position)`; request the closest K that aren't loading. Mark island detail textures (ch24 splats at high res) and prop/model textures (ch17/ch45) as streamable; ship-critical UI/fallbacks stay startup-loaded.

6. **The PBO ring, behind a flag.** Allocate 4 PBOs of slice size with `gl.GenBuffers`/`gl.BufferData(gl.PIXEL_UNPACK_BUFFER, …, nil, gl.STREAM_DRAW)`. Per slice: pick the next ring entry whose fence is signaled (`gl.ClientWaitSync(f, 0, 0)`; if `gl.TIMEOUT_EXPIRED`, skip uploading this frame — never block), map with `gl.MapBufferRange(gl.PIXEL_UNPACK_BUFFER, 0, len, gl.MAP_WRITE_BIT | gl.MAP_UNSYNCHRONIZED_BIT | gl.MAP_INVALIDATE_RANGE_BIT)`, memcpy, `gl.UnmapBuffer`, `TexSubImage2D` with `rawptr(uintptr(0))` as the data argument (offset into the bound PBO), then `gl.DeleteSync(old)` and `f = gl.FenceSync(gl.SYNC_GPU_COMMANDS_COMPLETE, 0)`. Unbind the PBO (`BindBuffer(gl.PIXEL_UNPACK_BUFFER, 0)`) afterward or every later `TexSubImage2D` in the codebase silently reads offsets instead of pointers — a legendary footgun.

7. **Measure both paths and judge.** Approach an island cold (textures evicted via debug key) with the frame graph up: plain path vs PBO path, total time-to-Ready and max frame ms. Write the verdict as a comment above the flag. On most 2020s desktop drivers: a tie on frame spikes, plain wins on simplicity — keep plain as default, PBO compiled in for ch100's heavier traffic.

## Checkpoint

The villain number from step 1 is dead.

- Debug-load the same 4k texture through the streamer: the frame graph stays flat (no bar above ~1.2× median) while the texture fades in over several frames, magenta → real.
- Sail at an island from far out: detail textures resolve in distance order, closest first; turn the boat and the order re-sorts.
- Yank a texture file from disk and request it: magenta checker persists, one log line, no crash — ch83's contract holds under threading.
- Panel shows: pending loads, pending uploads, upload ms this frame (≤ ~2), textures resident.
- Both upload paths produce identical final pixels (RenderDoc the texture each way).

## Pitfalls

- **`stbi.load` or `gl.*` on the wrong thread.** Decode on workers, upload on main — and the *map call itself* is GL: workers never call `MapBufferRange` either.
- **Reading `state` non-atomically.** Main polling `t.state == .Pending_Upload` while a worker stores it is the ch97 race; both sides go through `sync.atomic_load`/`atomic_store`. (An enum is integer-backed; atomics on it are fine.)
- **`MAP_UNSYNCHRONIZED` without fences.** Works on your machine, shimmers on the player's. The fence ring is not optional equipment; it is the seat belt the flag removes.
- **Forgetting to unbind `PIXEL_UNPACK_BUFFER`.** Every subsequent texture upload in the entire app misinterprets its data pointer as a PBO offset. If unrelated textures corrupt after enabling the PBO path, it's this.
- **Uploading the whole 4k texture in one budget tick.** The budget must bound *actual elapsed time*, checked between slices — not "one texture per frame," which re-imports the hitch for big assets.
- **Eviction while Loading.** If ch100 later evicts an asset whose job is in flight, the job writes into freed memory. The state machine must forbid `Loading → Unloaded` directly: mark `evict_when_done` and let the upload pass discard the result. Build the flag now, while it's cheap.

## Exercises

1. Add a streaming debug overlay: each streamed texture as a small colored square (state-colored: gray/yellow/orange/green) with distance — a one-glance picture of the streamer's mind.
2. Time-to-Ready histogram: record request→Ready ms per texture for a full island approach; print min/median/max at quit. Then halve the budget to 1 ms and compare — feel the latency/smoothness dial.
3. Extend the streamer to *meshes*: ch17 OBJ parse on a worker (pure string→vertices), `mesh_upload` through the same budgeted queue. The ch98 terrain path almost wrote this for you.
4. **Stretch:** persistent mapping (GL 4.4): `gl.BufferStorage` with `gl.MAP_PERSISTENT_BIT | gl.MAP_COHERENT_BIT`, map *once*, keep the pointer forever, fences only. This is the modern streaming idiom (and the one closest to Vulkan's). Measure against both existing paths.

## Commit

```
git commit -m "ch99: async texture streaming — worker decode, budgeted main-thread uploads, PBO ring vs TexSubImage measured"
```

← [Chapter 98 — The Bosun's Crew](ch98-the-bosuns-crew.md) · [Chapter 100 — A Sea Without Edges](ch100-a-sea-without-edges.md) →
