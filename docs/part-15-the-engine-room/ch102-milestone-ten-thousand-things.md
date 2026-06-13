# Chapter 102 — MILESTONE: Ten Thousand Things

*Part 15 — The Engine Room · Estimated time: 6–8h · learnopengl: no direct equivalent — this is engine material. Primary sources: "Approaching Zero Driver Overhead" (Everitt, McDonald, Hector, Foley — GDC 2014) and "GPU-Driven Rendering Pipelines" (Haar & Aaltonen — SIGGRAPH 2015). You are about to build what those talks describe.*

**What you'll see when done:** the archipelago at ten times Chapter 45's density — a hundred thousand palms, grasses, rocks, and chunks — drawn by a handful of `MultiDrawElementsIndirect` calls whose contents the CPU never wrote, at a frame time the panel proves is *better* than Chapter 96's.

## Where we are

Count what the last five chapters built: workers that compute without touching GL (97–98), uploads that flow on a budget (99), a world that exists only near you (100), and visibility that lives in an SSBO no CPU ever reads (101). Every piece points at the same destination. Today the CPU stops issuing draw calls one by one and instead says, once: *"GPU — here is everything that exists; you decide what to draw, then draw it."* This is GPU-driven rendering, the architecture under every big open-world engine of the last decade, and the final chapter of this course. It is a milestone chapter — expect both build steps and the closing rituals.

## Concepts

### One draw call to rule N draws

`gl.MultiDrawElementsIndirect(mode, type, indirect, drawcount, stride)` executes `drawcount` distinct indexed draws from an array of command structs living in a **GL buffer** bound to `gl.DRAW_INDIRECT_BUFFER` — not in your address space:

```
 CPU: one call ──> [ cmd0 | cmd1 | cmd2 | ... | cmdN ]  (DRAW_INDIRECT_BUFFER)
                      │       │
                      ▼       ▼
 GPU: draw palms(cmd0), draw rocks(cmd1), ...   — no driver round trip per draw
```

Each command is the GL-specified five-`u32` struct — and since *the GPU reads it from a buffer*, a compute shader can **write** it. That's the trick: chapter 101's cull shader stops writing visibility *flags* and starts writing draw *commands*. Cull and command generation fuse into one dispatch; the CPU's render loop shrinks to "dispatch cull, barrier, multi-draw."

For this to be one draw, all participating meshes must live in one VAO: concatenate the vertex/index buffers of palms, rocks, grass, chunk meshes into a **mega-buffer** at load, record each mesh's `first_index`/`base_vertex`, share one vertex format. (You standardized vertex layouts in Chapter 11. That decision is currently saving you a week.)

### Who tells the GPU *how many* commands?

Three honest options, in increasing GL version:

1. **Fixed slots, zeroed when culled** (GL 4.3): one command slot per batch, cull shader writes `instance_count = 0` for invisible ones. `drawcount` is a CPU constant. Zero readback, zero atomics; the GPU skips empty draws cheaply. **Our default.**
2. **Compacted with an atomic counter** (GL 4.3): cull shader `atomicAdd`s a counter in a small SSBO and writes survivors densely. The count lives GPU-side; the CPU either reads 4 stale bytes through a ring (acceptable) or—
3. **`gl.MultiDrawElementsIndirectCount`** (GL 4.6 / ARB_indirect_parameters): the GPU reads `drawcount` itself from a `gl.PARAMETER_BUFFER`. Fully readback-free compaction. Use it where 4.6 exists; the ch83 capability ladder decides at init.

We build 1, then upgrade to 2+3 as the marked steps — the difference is twenty lines, and you'll have both shapes in your hands.

### Which draw am I? `gl_DrawID`, stated honestly

With per-draw uniforms gone, shaders index per-draw data (material id, texture index, object transform offset) from an SSBO — by **`gl_DrawID`**, the index of the current command. The honest requirement: `gl_DrawID` needs **GLSL 4.60** (`#version 460`) or the `ARB_shader_draw_parameters` extension (where it's spelled `gl_DrawIDARB`). GL 4.6 shipped in 2017; most desktop hardware that survived Part 9's 4.3 bump has it, but *check*, don't assume — extension string at init, ch83 style.

The classic fallback for 4.3-only drivers: the `base_instance` field. `gl_InstanceID` does **not** include the base instance (a spec landmine worth memorizing) — but *instanced vertex attributes do*: an attribute with `divisor = 1` reading a buffer of draw indices `[0,1,2,…]` delivers, to every vertex of draw k whose command says `base_instance = k`, exactly the value `k`. Per-draw ID, GL 3.3-era machinery, slightly bent.

### Bindless textures — the optional capstone

One multi-draw can't rebind textures between commands, so materials need all textures reachable at once. Texture *arrays* (all palm/rock/grass albedos as layers, indexed in-shader) solve it within one size/format — fine for vegetation, and that's our main path. **`ARB_bindless_texture`** solves it generally: ask for a 64-bit handle (`glGetTextureHandleARB`), make it resident (`glMakeTextureHandleResidentARB`), put handles in an SSBO, and construct `sampler2D` from a `uvec2` in the shader. It never became core GL — the hardware floor (notably older Intel iGPUs) could never promise it, so it stayed an extension with sharp edges (residency is manual; a non-resident handle is a device hang on some drivers). It *is* the default idiom in Vulkan/DX12 (descriptor indexing). Note also: extension entry points aren't in `vendor:OpenGL`'s core loader — you fetch the proc pointers yourself via `glfw.GetProcAddress`. Capstone status: build it if the extension string says yes and the itch says go.

## Odin notes

- The command struct, laid out exactly as the GL spec orders its fields, with the insurance the course has paid since ch61:

  ```odin
  Draw_Command :: struct {
  	count:          u32, // index count
  	instance_count: u32, // 0 = culled (option 1's whole trick)
  	first_index:    u32, // into the mega index buffer
  	base_vertex:    u32, // careful: i32 in pure GL terms; u32 fine while meshes pack forward
  	base_instance:  u32,
  }
  #assert(size_of(Draw_Command) == 20)
  ```

  `vendor:OpenGL` ships its own `gl.DrawElementsIndirectCommand` (plus `DrawArraysIndirectCommand` and `DispatchIndirectCommand`) — ours exists to satisfy the conventions and the `#assert` habit; assert against theirs in a test if you like.
- A buffer is a buffer: create the command buffer once, bind it as `gl.SHADER_STORAGE_BUFFER` (binding N) for the cull dispatch and as `gl.DRAW_INDIRECT_BUFFER` for the draw. Same `u32` handle, two hats.
- The barrier between compute-write and indirect-read has its own bit: `gl.MemoryBarrier(gl.COMMAND_BARRIER_BIT)` (add `gl.SHADER_STORAGE_BARRIER_BIT` for the per-draw data SSBO). Wrong-bit symptoms are the ch61 special: fine on your driver, garbage on another.
- `gl.MultiDrawElementsIndirect(gl.TRIANGLES, gl.UNSIGNED_INT, nil, draw_count, 0)` — `nil` means "offset 0 into the bound indirect buffer", `stride 0` means tightly packed. The matrices you still upload (view/proj) go the way they always have: `gl.UniformMatrix4fv(loc, 1, false, &m[0, 0])`.

## Build

1. **The mega-buffer.** `Mesh_Registry`: concatenate vegetation/rock/chunk-LOD meshes into one VBO/EBO/VAO; per mesh record `{count, first_index, base_vertex}`. Draw the *old* way through the registry first (a loop of `gl.DrawElementsBaseVertex` — core since 3.2) and confirm pixel-identical rendering. Commit this before anything indirect exists; it isolates the mesh plumbing from the GPU-driven plumbing.

2. **Batches and slots.** A **batch** = (mesh, chunk) pair for chunk geometry, or (species, chunk) for instanced vegetation — a few thousand slots at showcase density. Fill a CPU-side `[]Draw_Command` (instances of a species in a chunk = `instance_count`; per-batch `base_instance` points into the ch45-style instance-data SSBO, which replaces instanced vertex attributes — fetch `instance_models[base + gl_InstanceID]` in the vertex shader... using the fallback note from Concepts if you're below 4.6). Upload commands, bind as indirect, `MultiDrawElementsIndirect`, *no culling yet*. Same image, draw-call line in the panel collapses to single digits.

3. **The cull writes the commands.** Extend ch101's `hiz_cull.comp` (`#version 430`, bump to `460` if step 5 lands): per batch — frustum test, Hi-Z test, then:

   ```glsl
   layout(std430, binding = 2) buffer Commands { DrawCommand cmds[]; };

   cmds[id].instance_count = visible ? batch_instance_count[id] : 0u;
   // count/first_index/base_vertex/base_instance were written once at batch build
   ```

   CPU render loop becomes: update camera UBO → dispatch cull → `gl.MemoryBarrier(gl.COMMAND_BARRIER_BIT | gl.SHADER_STORAGE_BARRIER_BIT)` → one multi-draw per shader (terrain-textured vs vegetation-alpha-tested — two or three multi-draws total). Delete the ch101 CPU readback scaffolding with prejudice.

4. **Compaction upgrade.** Add the atomic path: a 4-byte SSBO counter zeroed per frame (`gl.ClearBufferSubData` or a tiny dispatch); survivors do `uint slot = atomicAdd(draw_count, 1u);` and write their full command to `cmds[slot]`. If `GL_ARB_indirect_parameters`/4.6: bind the counter buffer as `gl.PARAMETER_BUFFER` and call `gl.MultiDrawElementsIndirectCount`. Else: keep option 1 as the shipping path and leave this behind the ch83 capability flag. Measure both — at our scale expect them within noise of each other (empty draws are cheap); knowing that *from your own timers* is the lesson.

5. **Per-draw data via `gl_DrawID`.** `#version 460` (state it in the shader, check at init): material index, splat parameters, chunk origin — one `Per_Draw` SSBO indexed `per_draw[gl_DrawID]`. On 4.3-only hardware: the divisor-1 draw-index attribute fallback from Concepts. Either way, the last per-draw uniform upload in the hot path dies here.

6. **Bindless capstone (optional).** If `GL_ARB_bindless_texture` is in the extension list: fetch `glGetTextureHandleARB`/`glMakeTextureHandleResidentARB` pointers via `glfw.GetProcAddress`, take handles for the vegetation/material textures at load, make them resident, store `uvec2` handles in the material SSBO, and in GLSL: `#extension GL_ARB_bindless_texture : require` … `sampler2D(material.albedo_handle)`. Otherwise the texture-array path from step 2 stands, and stands proudly — it ships in real engines too.

7. **THE SHOWCASE.** Multiply ch45's scatter densities ×10 (palms ~20k, grass ~200k instances across the resident ring; let ch100 stream them per-chunk). Sail the densest coast at golden hour with the panel open. Fill in the table — these cells are the part's report card:

   | | ch96 baseline | ch102, culling off | ch102, full |
   |---|---|---|---|
   | draw calls | ~hundreds | ~3 | ~3 |
   | instances submitted | 1× | 10× | 10× |
   | cull + pyramid GPU ms | — | — | |
   | scene GPU ms | | | |
   | total frame ms | | | |

   The honest expectation: ch102-full beats ch96 *while drawing ten times more* — and "culling off" at 10× is unplayable, which is the proof the culling earns its lane.

8. **Screenshot #12.** The dense-coast shot, panel visible, draw-call counter in frame. This is the last numbered screenshot of the course — the one where the *numbers* are the beauty. Post it (r/odinlang, the Odin Discord's #showcase, wherever your ch84 players are) with the one-line caption it deserves: *"~3 draw calls."*

## Checkpoint — the milestone list

- Step 1 registry renders pixel-identical to the loop it replaced; step 3 renders identical to step 2 with culling forced visible.
- Behind the volcano: the cull dispatch zeroes most commands; frame ms drops in lockstep with ch101's counters. Fast spin: no vanishing geometry (the one-frame-pop policy rode along into the command writer).
- Kill the CPU readback: grep proves no `GetBufferSubData` in the render path; frame graph shows no sync sawtooth.
- The table above, filled in, committed in `PERF.md`. ch102-full ≤ ch96 baseline at 10× density.
- The 4.3 fallback path (no `gl_DrawID`, no Count variant) still renders correctly — ch83's ladder extends to the end.
- One hour of sailing the showcase build: flat memory (ch100), flat frame time, zero hitches. The engine room hums.

## Pitfalls

- **Missing `COMMAND_BARRIER_BIT`.** The multi-draw consumes commands the cull hasn't finished writing — flickering subsets of the world, *only on some drivers*. The indirect buffer is a shader-storage write being read by the command processor; it needs its own bit.
- **`base_instance` assumed inside `gl_InstanceID`.** It isn't. Instance data indexed `instance_models[gl_InstanceID]` ignores your carefully packed offsets and every batch draws batch 0's trees. SSBO-fetch with `base_instance + gl_InstanceID` (via the attribute trick pre-4.6, or `gl_BaseInstance` itself in 4.6).
- **`gl_DrawID` in a `#version 430` shader.** Compile error if you're lucky; on lax drivers, silent zero — all draws read material 0. State `460`, check the context version at init, keep the fallback honest.
- **Forgetting the indirect buffer is also an SSBO binding.** Leaving it bound as SSBO binding 2 while another dispatch writes binding 2 elsewhere scribbles over your commands. Track buffer bindings like the resources they are (RenderDoc's buffer inspector earns its keep tonight).
- **Alpha-tested grass in the same multi-draw as opaque terrain.** Different shader = different multi-draw, full stop; and grass still must not write the ch101 pyramid. The number of multi-draws is "number of shaders," not 1 — three calls is victory, don't chase one.
- **Bindless handle made resident, texture then streamed out by ch99.** Resident handles pin memory; the streamer must `MakeTextureHandleNonResidentARB` before eviction or VRAM quietly fills. If you build the capstone, wire it into the residency state machine the day it's born.

## Quiz

1. **Why can a compute shader "issue draw calls" when GL has no such shader capability?**
   <details>It can't — it writes draw *commands* into a buffer, and the CPU issues one `MultiDrawElementsIndirect` that tells the GPU's command processor to read them. The CPU still calls; it just no longer decides the contents.</details>
2. **What does `instance_count = 0` accomplish, and what problem does it dodge?**
   <details>The draw slot executes as a no-op, so visibility is decided entirely GPU-side with a fixed `drawcount` — dodging any CPU readback of "how many survived" and the GL-4.6 requirement of the Count variant.</details>
3. **A teammate reads the visibility/draw count back every frame with `GetBufferSubData` "just for the panel." What happens?**
   <details>A full pipeline sync each frame — the CPU stalls until the GPU reaches the cull dispatch, serializing exactly like ch49's same-frame query reads. Stale ring-buffer copies (or on-screen GPU-rendered counters) give the number without the stall.</details>
4. **Why must the Hi-Z pyramid be max-depth rather than min-depth, in one sentence?**
   <details>Max answers "how far does the *farthest* occluder reach here" — a box is hidden only if its nearest point is behind that; min would cull everything behind the nearest fragment, which is almost everything.</details>
5. **Why did all `gl.*` calls stay on the main thread all part, even though we added threads precisely for performance?**
   <details>A GL context is bound to one thread; calls from others are undefined. So workers produce data (vertices, pixels, decisions) and main does all driver talk — which is also why upload budgeting (ch99) exists at all.</details>
6. **Your world generates differently with 4 workers than with 8. Which rule of ch98/ch100 was broken?**
   <details>Chunk generation stopped being a pure function of (seed, coords) — some job read shared mutable state or a shared random stream, so scheduler order leaked into content. Per-chunk seeds and own-slot writes restore order-independence.</details>
7. **Why is `gl_DrawID` gated behind GLSL 4.60, and what's the portable substitute?**
   <details>Draw-parameter visibility in shaders arrived via ARB_shader_draw_parameters, core only in GL 4.6/GLSL 4.60. Substitute: a divisor-1 instanced attribute over a buffer of draw indices — instanced attributes (unlike `gl_InstanceID`) honor `base_instance`, delivering the slot's index to every vertex.</details>
8. **Bindless textures: why "never core," and what's the modern-API descendant?**
   <details>Not all GL-4-class hardware could implement it (residency + 64-bit handles), so Khronos couldn't mandate it; it stayed ARB with manual residency. Vulkan/DX12 descriptor indexing ("bindless" descriptors) is the same idea made a first-class citizen.</details>

## The engine room is yours

Look at what this part actually was: you took a *shipped game* and rebuilt its bones while it kept sailing — threads under the simulation, streams under the assets, an endless world under the map, and finally a renderer where the GPU feeds itself. Reread Chapter 88's tour of Vulkan and DX12 now and notice what's changed: command buffers the CPU fills and the GPU consumes, explicit synchronization you place yourself, descriptor arrays indexed by shader — *you have now built all of these*, in OpenGL, with your own hands. The modern APIs are no longer a foreign country; they're a pen pal you've been writing to for six chapters without knowing their name. When you open vkguide.dev someday — and you should — you will mostly be learning new spellings.

**If you're returning after a break**, the recap that restores the thread: workers produce, main uploads (97–98); residency states + budgeted upload queue (99); the world is a pure function and resident chunks are its cache, rebased small by ⚓25a's floating origin (100); a max-depth pyramid answers occlusion in one dispatch (101); and the cull dispatch writes the draw commands the GPU then executes, ~3 calls a frame (102). Sail the showcase build for ten minutes before touching code. That's what it's for — that has *always* been what it's for.

This is the course's true last chapter, and you should hear that plainly: there is no Chapter 103. The first ending, [Chapter 52 — Beyond the Horizon](../part-8-full-sail/ch52-epilogue-beyond-the-horizon.md), told you where the sea continues — FFT oceans you have since built, Vulkan you are now ready for — and the [course overview](../00-COURSE-OVERVIEW.md) shows the whole voyage in one map, from a black window to this. Somewhere back there you wrote `gl.ClearColor` for the first time and a blue rectangle felt like magic. It was. It still is — you just run the magic show now.

```
git commit -m "ch102: MILESTONE — MultiDrawElementsIndirect, compute-written draw lists, ten thousand things"
git tag engine-room
```

← [Chapter 101 — What the Eye Can't See](ch101-what-the-eye-cant-see.md) · [Chapter 52 — EPILOGUE: Beyond the Horizon](../part-8-full-sail/ch52-epilogue-beyond-the-horizon.md) · [Course Overview](../00-COURSE-OVERVIEW.md)
