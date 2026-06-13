# Chapter 100 — A Sea Without Edges

*Part 15 — The Engine Room · Estimated time: 5–6h · learnopengl: no direct equivalent — this is engine material. The spiritual references are every open-world GDC postmortem ever given; the math is yours from Chapter 21.*

**What you'll see when done:** you point the bow at empty horizon and sail — for ten minutes, for an hour — and islands keep being born ahead and dying astern, the minimap shows the loaded ring drifting with you, and the resident-memory line in the panel stays flat as the sea on a windless day.

## Where we are

Your archipelago has had an edge since Chapter 25: worldgen ran once, over a fixed span. Everything since — the job system that generates chunks in parallel (98), the budgeted upload queue (99) — was secretly scaffolding for this chapter. Today the world becomes a *window*: a few hundred chunks resident around the boat, generated on approach, retired behind you, over an archipelago that is mathematically infinite. This is the chapter where Chapter 21's "the world is a pure function of seed and coordinates" stops being a discipline and becomes the entire load-bearing structure.

## Concepts

### Floating origin, the two-paragraph recap

An `f32` has a 24-bit mantissa, so the spacing between representable values grows with magnitude: ~2 mm at 16 km from the origin, ~8 mm at 65 km. Positions survive that; *arithmetic* doesn't — every view-matrix multiply and animation add rounds differently frame to frame, and a few millimeters of wander on something a meter from the camera is whole pixels of vertex jitter, stuttering animation, and crawling speculars. Practical pain begins around 10 km out. An endless world sails past that in twenty minutes.

The fix (interlude [⚓ 25a — The World Unmoored](../part-4-raising-islands/ch25a-the-world-unmoored.md), **required before this chapter if you skipped it** — go build it, it's three focused hours): keep *render space* small by rebasing. When the camera drifts past a threshold, subtract a snapped shift from every world-space position in the game — camera, boat, buoys, terrain origin, NPC ships — and accumulate the running total in an `f64` `world_offset`. Render space stays within ±4 km of zero forever; **logical space** (`render + world_offset`, in `f64` with micrometre precision out to planetary distances) is what seeds, saves, and — today — the chunk streamer consume. Everything below speaks logical coordinates unless it's about to touch the GPU.

### The desired set: rings around the boat

Each frame (or each half second — nothing here is latency-critical), compute which chunks *should* exist from the camera's logical position:

```
            ┌─────────────────────────────┐
            │     unloaded (retired)      │   chunk coord = floor(logical_xz / CHUNK_METERS)
            │   ┌─────────────────────┐   │
            │   │  low-res ring       │   │   r ≤ R_FULL     → full-res mesh + textures
            │   │   ┌────────────┐    │   │   r ≤ R_LOW      → low-res mesh (stride-4 LOD,
            │   │   │  full-res  │    │   │                     ch49's index trick)
            │   │   │     ⛵      │    │   │   r >  R_UNLOAD  → retire
            │   │   └────────────┘    │   │
            │   └─────────────────────┘   │   R_FULL < R_LOW < R_UNLOAD  (hysteresis!)
            └─────────────────────────────┘
```

The **desired set** is a pure function of one point. The streamer's whole job is reconciling reality with it: chunks in desired-but-missing start generating (ch98 jobs); chunks in resident-but-undesired retire. Reconciliation, not events — if a frame is dropped or a job is slow, the next pass simply re-derives the truth. This idempotent shape is why streaming systems survive contact with reality.

### Hysteresis, or: don't thrash the boundary

If load and unload share a radius, a boat tacking along a chunk boundary loads and retires the same chunk every few seconds — wasted cores, wasted uploads, visible popping. The cure is two radii: load when closer than `R_LOW`, retire only when farther than `R_UNLOAD = R_LOW + 2 chunks`. The gap is a no-man's-land where chunks simply *stay* in whatever state they hold. Same trick as a thermostat, same reason.

### The world is the function, the chunks are its cache

`chunk_generate(world_seed, cx, cz)` must depend on nothing else — not neighbor chunks, not generation order, not time. Your ch21 fBm already works this way (noise sampled at world coordinates), and ch45's scatter derives per-chunk seeds. Two consequences worth savoring: revisiting a chunk regenerates it *bit-identically*, so retiring a chunk loses nothing — resident chunks are merely a **cache** of the function; and the desired set can be generated in any order on any number of workers (ch98's determinism rule, now structural). Anything that *isn't* a pure function of seed+coords — discovered-by-the-player state, picked-up cargo, ch79's chart fog — is **player data**, lives in save files keyed by chunk coordinate, and is applied *after* generation. Worldgen makes the stage; saves decorate it.

### Meshes go chunk-local

One change to ch23's chunk build: bake vertices in **chunk-local** space (origin at the chunk's corner) instead of world space, and position each chunk at draw time with `u_model = mat4Translate(chunk_render_origin)`. The 25a interlude already moved terrain to an origin-relative draw; this finishes the thought — a rebase now costs *nothing* per chunk (only the origins shift), and a chunk's mesh is valid wherever the floating origin happens to be when it's born.

## Odin notes

- The chunk key is `Chunk_Coord :: [2]i32` — and it's map-key-ready: `resident: map[Chunk_Coord]^Streamed_Chunk` just works (Odin hashes comparable types natively). `floor` the f64 division, don't truncate: `(-0.5 → -1)`, or the four chunks around the origin alias.
- Per-chunk seed: `chunk_seed :: proc(world: u64, c: Chunk_Coord) -> u64 { h := world; h ~= u64(i64(c.x)) * 0x9E3779B97F4A7C15; h = (h ~ (h >> 30)) * 0xBF58476D1CE4E5B9; h ~= u64(i64(c.y)) * 0x94D049BB133111EB; return h ~ (h >> 31) }` — a splitmix-style hash, not arithmetic like `x + z * 1000` (which makes diagonal twins). Cast through `i64` so negative coords don't sign-extend surprises into you.
- The resident map is touched **only by the main thread**. Workers receive a pointer to their own chunk record and fill it; main inserts/removes map entries and flips states with `sync.atomic_store`. One owner, no map locks, no iteration-during-mutation bugs.

## Build

1. **The streamer.** In `src/chunk_streamer.odin`:

   ```odin
   Chunk_State :: enum { Missing, Generating, Built, Resident, Retiring }

   Streamed_Chunk :: struct {
   	coord:      Chunk_Coord,
   	state:      Chunk_State, // atomic access between main & worker
   	lod:        int,         // 0 = full, 1 = stride-4
   	verts:      []Terrain_Vertex, // filled by job, freed after upload
   	mesh:       Mesh,             // GL handles — main thread only
   	evict_when_done: bool,        // the ch99 in-flight-eviction flag
   }

   Chunk_Streamer :: struct {
   	world_seed: u64,
   	resident:   map[Chunk_Coord]^Streamed_Chunk,
   	// radii in chunks:
   	r_full: int, r_low: int, r_unload: int, // e.g. 4, 8, 10
   }
   ```

2. **The desired-set pass**, `stream_update_chunks(s, camera_logical: glsl.dvec3)`, on main, every half second: compute the camera's chunk coord; walk the square `[-r_low … +r_low]²` around it; for each coord inside the circle not in `resident`, allocate a record, insert, set `Generating`, and submit a ch98 job that calls `chunk_generate(world_seed → chunk_seed(coord))` into `verts`, then atomically stores `Built`. Then walk `resident` and mark anything farther than `r_unload` as `Retiring` (or `evict_when_done` if still `Generating`).

3. **Upload and retire through the ch99 budget.** Extend `stream_update`'s budgeted loop: each tick can also (a) `mesh_upload` one `Built` chunk → `Resident` (then `delete(chunk.verts)`), or (b) destroy one `Retiring` chunk's mesh (`mesh_destroy` — GL, main thread) and delete the map entry. Textures for chunk splats ride the existing ch99 texture queue with priority = chunk distance. One budget governs everything that touches the driver — that's the design.

4. **LOD rings.** A chunk entering `r_full` from the low ring re-submits at `lod = 0` (generate full vertices; swap meshes at upload — never delete the low mesh before the full one is resident, or the sea gets a hole). Leaving `r_full` swaps back to the cached low mesh if you kept it (keep it — it's small) or regenerates. Skirts from ch49 hide the ring seam; verify by sailing the boundary in wireframe.

5. **Wire the world systems.** `terrain_height_at(p)` now finds the chunk under `p` (logical) and samples it — buoyancy (ch32), scatter queries, and NPC sailing (ch92–93, if built) all route through it; return sea level + a `false` for not-yet-resident and make buoyancy tolerate it (it already tolerates open ocean). The ch25a rebase registry gains one line: chunk render origins shift with everything else.

6. **Saves and the chart.** ch80's save file gains a sparse `map[Chunk_Coord]Chunk_Player_Data` (discovered flag for ch79's chart fog, looted/placed items). On chunk upload, apply player data if present. The chart (ch79) reads the discovered set directly — it's already chunk-shaped if you built it on the world grid; if not, this is the nudge.

7. **The minimap overlay.** A debug panel widget: one colored rect per tracked chunk — gray `Missing`-adjacent, yellow `Generating`, orange `Built`, green `Resident` (bright = full LOD), red `Retiring` — camera at center. This is not optional decoration; it is how every streaming bug for the rest of your life gets diagnosed in five seconds instead of an evening.

8. **The voyage.** Panel additions: resident chunk count, resident MB (count × bytes per LOD), generation jobs in flight. Now sail one compass heading for as long as you can stand — make tea, come back. Memory flat. Chunks born ahead, retired astern. The world does not end. **Chart it:** log resident MB once a second to a CSV for an hour and plot it; that flat line is the whole part in one picture.

## Checkpoint

The map has no edge and the process has no growth.

- One-hour straight-line sail: resident count oscillates in a fixed band (±the hysteresis gap); process memory flat after the first minutes (the CSV proves it).
- Sail out 30 km, turn 180°, sail home: the islands you left are *exactly* where and how they were — same coves, same palms (pure function + per-chunk seeds), plus your discovered-mask intact (saves applied on reload).
- Tack along a chunk boundary for two minutes: the minimap shows **zero** load/retire flicker in the hysteresis band.
- Teleport (ch25a's J key) 50 km: one frame of ocean, then the ring fills in over a few seconds by priority, closest first — no hitch bar on the frame graph at any point.
- Kill the streamer with a debug toggle mid-sail: the world stops being born ahead (you sail off the edge of the loaded set into open sea) but nothing crashes — reconciliation resumes cleanly when re-enabled.

## Pitfalls

- **One radius for load and unload.** Boundary thrash: the same chunk churning through generate/upload/retire while you sail parallel to its edge. Hysteresis gap of ≥2 chunks; verify with the tack test above.
- **Worldgen that secretly orders.** Any neighbor read or shared accumulator in `chunk_generate` makes the world depend on completion order — different every run, different per core count. The function takes seed + coord, full stop. (If a future feature *needs* neighbor data — rivers, roads — generate in two passes with the first pass still pure.)
- **Map mutation from workers.** Insert/delete on `resident` from a job = corrupted map, eventual crash far from the cause. Workers fill their own record; only main touches the map.
- **Evicting a chunk mid-generation.** The job writes into a freed record. The `evict_when_done` flag (built in ch99, used here) is the law: `Generating` never transitions directly to gone.
- **World-space baked meshes.** A rebase slides the floating origin out from under them and distant chunks jitter exactly as 25a warned. Chunk-local vertices + per-chunk origin translate; the 25a teleport test is the regression test.
- **`int` chunk coords derived from f32 positions.** At 100 km the f32 position is ±8 mm — fine — but compute coords from the **f64 logical** position, and `floor`, not cast. Aliasing here makes the streamer disagree with the renderer about where the boat is, and the symptom (wrong ring center) looks haunted.

## Exercises

1. Prefetch along the velocity vector: bias the desired-set center half a ring ahead of the boat's heading. Measure time-to-Resident for chunks crossing the bow before and after.
2. Add a `--seed-tour` debug mode: teleport through 10 random points 100 km apart, screenshot each, re-run with the same world seed, diff the screenshots. Automated proof of the pure function.
3. Budget tuning: log the ch99 queue's worst frame ms during the teleport storm, then halve/double `UPLOAD_BUDGET_MS` and chunk job granularity. Find your machine's knee and write it in `PERF.md`.
4. **Stretch:** ocean-only chunks are 90% of an archipelago — detect "fully below sea level" at generation (the fBm island mask tells you cheaply) and represent them as a flag instead of a mesh, drawing the ch12 sea tile over them. Resident MB should drop dramatically; re-run the hour chart and frame both lines.

## Commit

```
git commit -m "ch100: chunk streaming — desired-set rings, hysteresis, ch98 generation + ch99 budgeted uploads, flat memory forever"
```

← [Chapter 99 — Cargo Below Decks](ch99-cargo-below-decks.md) · [Chapter 101 — What the Eye Can't See](ch101-what-the-eye-cant-see.md) →
