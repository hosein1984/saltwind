# Chapter 101 — What the Eye Can't See

*Part 15 — The Engine Room · Estimated time: 5h · learnopengl: no direct equivalent — this is engine material. The Hi-Z technique traces to "Hierarchical-Z map based occlusion culling" (Haar & Aaltonen's SIGGRAPH 2015 "GPU-Driven Rendering Pipelines" made it canon); GL 4.3 required, as bumped in Chapter 53.*

**What you'll see when done:** anchor behind a volcanic island and watch the visible-chunk counter fall from 38 to 9 — the archipelago behind the mountain simply stops being drawn, and the scene-pass GPU milliseconds fall with it.

## Where we are

Chapter 23's frustum culling answers "is it inside the view cone?" — it cannot answer "is it *behind the island*?" Sail close to one big landmass and look across it: frustum culling happily passes 40 chunks, three NPC ships, and ten thousand instanced palms that contribute zero pixels, because a mountain stands in front of them. The depth test discards them *per fragment, after vertex shading* — you pay transform, raster, and early-z for everything the mountain hides. **Occlusion culling** discards them per *object*, before the draw. This chapter builds the modern GPU way — a Hi-Z depth pyramid tested in compute — and its results land in an SSBO that Chapter 102 will consume without the CPU ever seeing them. That last clause is the design: everything here is built to be *readback-free*.

## Concepts

### First, measure the crime

Park behind your biggest island. Read the panel: chunks drawn (ch23's counter), scene-pass GPU ms (ch49). Now toggle a debug key that skips drawing everything whose AABB center is beyond the island (a hack — hardcode a plane). The GPU ms difference between "honest" and "hack" is the prize occlusion culling competes for. Write both numbers down; if the difference is 0.3 ms, read this chapter and implement it anyway — at ch102's 10× density it becomes 3 ms.

### The old way: GPU occlusion queries, and their trap

GL has asked-the-GPU occlusion since the 2000s: render a cheap proxy (the AABB as 12 triangles) with color and depth writes off, wrapped in `gl.BeginQuery(gl.SAMPLES_PASSED, q)` / `gl.EndQuery`, and the query counts fragments that passed depth. Zero → the box is invisible → skip the real object next time. (`gl.ANY_SAMPLES_PASSED` is the cheaper boolean flavor.)

The trap is the same one ch49's timer queries taught you: **the result lives in the future.** Read it immediately and you stall the pipeline; read it next frame and your visibility is one frame stale — an object un-hides one frame late and *pops in*. Per-object queries also cost a draw call each, which at our object counts erases the win.

> **Sidebar — conditional render.** `gl.BeginConditionalRender(q, gl.QUERY_WAIT)` … `gl.EndConditionalRender` tells the *driver* to skip the enclosed draws if query `q` reported zero samples — no CPU readback at all, latency handled by the GPU. Elegant, worth knowing, still one query + one proxy draw per object, and it can't feed a ch102-style indirect pipeline. We visit it in exercise 2 and move on.

### The modern way: a depth pyramid, asked in bulk

Hi-Z inverts the question. Instead of "GPU, please test this box" (one round trip per box), build a **Hi-Z pyramid** — the depth buffer mipmapped with **max** instead of average — and test *all* boxes in one compute dispatch:

```
 mip 0: full-res depth        mip 3: each texel = max depth of an 8×8 block
 ┌──────────────┐                ┌────┐    A box projects to a screen rect.
 │  ▒▒▒▒        │   max-reduce   │ ▒░ │    Pick the mip where that rect is
 │  ▒▒▒▒▒▒      │  ───────────>  │ ░░ │    ~1–2 texels wide. Sample the 4
 │      ░░░     │                └────┘    covering texels: the MAX depth any
 └──────────────┘                          occluder reaches in that region.
```

The test, with standard depth (0 = near, 1 = far): project the AABB's 8 corners to NDC, take the screen-space rect and the box's **nearest** depth; if `nearest_box_depth > max_occluder_depth_in_rect`, every part of the box lies behind the farthest occluder covering it — occluded, conservatively and correctly. The max-reduction is what makes 4 samples stand in for thousands: a single far-away texel in the footprint (a gap between islands) raises the max and *keeps the box visible*. We never wrongly cull; we sometimes wrongly draw. Same conservative direction as ch23.

**Where does the depth come from?** The classic answer: *last frame's* opaque depth buffer. It's free, it's complete — and it's stale: after a camera cut, last frame's mountains hide this frame's open sea. Policy, stated once and honored forever: **one-frame-pop is acceptable; one-frame-vanish is not.** On teleports, cuts, or yaw faster than a threshold, skip occlusion culling for one frame (everything passes). A frame of extra drawing is invisible; a frame of missing island is a bug report.

### What may not occlude (write the list down)

Into the pyramid go *reliable, opaque, depth-written* things only: terrain chunks, large rocks, hull. **Not** the ocean (it moves — a wave crest that occluded last frame is a trough now; and your forward-rendered water blends), **not** alpha-tested sails or vegetation (their depth is full of holes the pyramid's max can't represent safely), **not** particles, **never** the skybox. In practice: build the pyramid from the depth buffer *after the opaque terrain/prop pass, before water and transparents* — your ch55/ch60 pass structure already has that seam.

## Odin notes

- The pyramid is an `R32F` texture with a full mip chain (`gl.TexStorage2D(gl.TEXTURE_2D, levels, gl.R32F, w, h)` — depth formats can't be written by image load/store, so we copy depth into a color format). Mip count: `levels = 1 + int(math.floor(math.log2(f32(max(w, h)))))`.
- Sampling *specific texels of specific mips* in compute is `texelFetch(tex, coord, mip)` — no sampler state involved — but binding a single mip for *writing* is `gl.BindImageTexture(unit, tex, mip_level, …)`. One texture, level-bound per dispatch.
- Visibility output is `visibility: []u32` worth of SSBO — one slot per registered cullee, indexed by a stable `cull_id` you assign when chunks/batches register. Odin side: `gl.BufferData(gl.SHADER_STORAGE_BUFFER, count * size_of(u32), nil, gl.DYNAMIC_DRAW)`; `#assert(size_of(u32) == 4)` is free.
- AABBs upload as a `[]Cull_Box` SSBO — `Cull_Box :: struct { min: glsl.vec3, _p0: f32, max: glsl.vec3, _p1: f32 }`, `#assert(size_of(Cull_Box) == 32)` — the ch61 std430 padding rule, still earning.

## Build

1. **Measure** (Concepts step). Two numbers in a comment: honest ms, hack ms.

2. **Meet the old way once.** Pick the 5 nearest non-visible-suspect chunks; give each a `SAMPLES_PASSED` query drawing its AABB (color mask off, depth mask off, depth *test* on) after the opaque pass; read results with a 1-frame-late ring (ch49's pattern); skip chunks whose last-frame count was 0. Watch it work — then fly a fast circle and watch the pop-in. Delete or flag-gate it; you now understand viscerally what the Hi-Z path must beat.

3. **The pyramid build.** After the opaque pass, copy depth to pyramid mip 0 (a fullscreen pass reading the depth texture and writing `gl_FragDepth`-free R32F — or a tiny compute with `texelFetch` on the depth attachment). Then reduce, one dispatch per mip in `assets/shaders/hiz_reduce.comp`:

   ```glsl
   #version 430
   layout(local_size_x = 8, local_size_y = 8) in;
   uniform sampler2D u_src;              // previous mip, via texelFetch
   layout(r32f, binding = 0) uniform writeonly image2D u_dst;

   void main() {
       ivec2 dst = ivec2(gl_GlobalInvocationID.xy);
       if (any(greaterThanEqual(dst, imageSize(u_dst)))) return;
       ivec2 src = dst * 2;
       float d = texelFetch(u_src, src, 0).r;
       d = max(d, texelFetch(u_src, src + ivec2(1, 0), 0).r);
       d = max(d, texelFetch(u_src, src + ivec2(0, 1), 0).r);
       d = max(d, texelFetch(u_src, src + ivec2(1, 1), 0).r);
       imageStore(u_dst, dst, vec4(d));
   }
   ```

   CPU loop: for each level `i in 1..<levels`, set `u_src` mip via `gl.TexParameteri(gl.TEXTURE_BASE_LEVEL/MAX_LEVEL, i-1)` (or a per-mip texture view), `gl.BindImageTexture(0, pyramid, i, …)`, dispatch `ceil(w_i/8) × ceil(h_i/8)`, then `gl.MemoryBarrier(gl.SHADER_IMAGE_ACCESS_BARRIER_BIT | gl.TEXTURE_FETCH_BARRIER_BIT)` — image-written, texture-read next level: both bits, the ch61 lesson. Odd sizes: the max of a 2×2 that hangs off the edge clamps to the last texel — fine, it's conservative.

4. **The cull dispatch**, `assets/shaders/hiz_cull.comp` — one invocation per cullee:

   ```glsl
   layout(std430, binding = 0) readonly  buffer Boxes      { CullBox boxes[]; };
   layout(std430, binding = 1) writeonly buffer Visibility { uint visible[]; };
   uniform mat4 u_view_proj;  uniform vec2 u_pyramid_size;  uniform int u_force_visible;

   // per box: frustum test (ch23's planes, now in GLSL) — then:
   //   project 8 corners, w-clamp behind-camera cases to "visible",
   //   ndc rect -> uv rect * pyramid_size = pixel footprint
   //   mip  = clamp(int(ceil(log2(max(foot.x, foot.y) * 0.5))), 0, u_levels - 1);
   //   max4 = max of texelFetch(u_pyramid, corner_texels, mip).r
   //   visible[id] = (nearest_ndc_z <= max4) ? 1u : 0u;
   ```

   Frustum + occlusion in one shader: frustum culling just *moved to the GPU*, joining its new colleague. Follow with `gl.MemoryBarrier(gl.SHADER_STORAGE_BARRIER_BIT)`. `u_force_visible` is the camera-cut switch (step 6).

5. **Consume — temporarily — on the CPU.** Until ch102, copy the visibility SSBO into a 3-deep ring of buffers (`gl.CopyBufferSubData`) and read the *oldest* with `gl.GetBufferSubData` — the ch49 latency dance, applied to visibility, stale by 2 frames but never stalling. Gate chunk and instanced-batch draws on it (registered `cull_id` per chunk and per ch45 batch). Yes, this readback is scaffolding; ch102 demolishes it — the SSBO will feed the GPU's own draw commands and the CPU stops being a middleman.

6. **Camera-cut robustness.** Set `u_force_visible = 1` for one frame when: ch25a teleport fires, a rebase fires, the map/menu closes, or yaw delta exceeds ~60°/frame. Also force-visible anything whose `cull_id` was registered this frame (fresh ch100 chunks have no history).

7. **Numbers on glass.** Panel: cullees tested, frustum-culled, occlusion-culled, drawn — and the pyramid build + cull dispatch on the ch49 GPU timers (expect ~0.05–0.15 ms each at 1080p; the technique must cost less than it saves, *prove it*).

## Checkpoint

The mountain finally pulls its weight.

- Behind the big island: chunks drawn falls toward your step-1 "hack" number; scene GPU ms falls accordingly; total frame ms strictly better than honest baseline (pyramid + cull cost included).
- Freeze culling (reuse the ch23 freeze-frustum key, now freezing the visibility buffer too) and fly up sideways: a chunk-shaped hole *behind where the island was* — the negative-space photograph of occlusion working.
- Fast 360° spin: no missing terrain, ever (force-visible policy) — record it and scrub frame by frame.
- Ocean off the occluder list: sail into a deep wave trough — distant islands do **not** flicker out.
- RenderDoc: pyramid mips are plausible max-reductions (inspect mip 4); the cull dispatch reads the right mip for a known box.

## Pitfalls

- **Min where max belongs.** A min-pyramid culls anything behind the *nearest* occluder fragment — entire screen vanishes when a sail crosses it. If everything disappears the moment anything is close: this.
- **Testing the box's far depth instead of near.** Conservative becomes aggressive; islands vanish while half-visible. The box's *nearest* point must be behind the *farthest* occluder.
- **Mip chosen by box size in world units.** It's the *screen footprint* (post-projection) that picks the mip; a huge far box is small on screen. Wrong mip = footprint spans many texels of which you sample 4 = false culls at screen edges.
- **Corners behind the near plane.** Projecting a corner with `w <= 0` produces NDC garbage. Any corner behind the camera → mark visible and move on; the frustum test already handled truly-outside cases.
- **Missing barrier between reduce dispatches.** Mip N reads stale mip N−1 on some drivers only — the ch61 "works here, breaks there" classic. One `MemoryBarrier` per level, correct bits.
- **Letting the ocean or sails occlude.** Wave troughs and alpha holes un-hide what the pyramid claims is hidden — distant geometry strobes with the swell. Opaque, static-ish, depth-honest occluders only; re-read the list, it was written down for a reason.

## Exercises

1. Visualize the pyramid: a debug fullscreen pass showing a chosen mip (slider in the panel). Watching the max-depth blobs of your islands breathe as you sail is both diagnostic and weirdly beautiful.
2. Implement the conditional-render variant (`gl.BeginConditionalRender(q, gl.QUERY_WAIT)`) for the 5 biggest chunks alongside Hi-Z, and compare: GPU ms, code complexity, and what happens at a camera cut. One paragraph verdict in `PERF.md`.
3. Extend culling to NPC ships (Part 14, if built): one `Cull_Box` per ship, fed from its logical position each frame. A harbor behind a headland should cost nothing until you round it.
4. **Stretch:** screen-size culling in the same shader — if the projected footprint is smaller than ~2 pixels, cull regardless of occlusion (a distant grass batch contributes nothing). Count how many cullees this removes at the ch102 showcase density; it's often more than occlusion itself.

## Commit

```
git commit -m "ch101: Hi-Z occlusion — max-depth pyramid in compute, AABB tests to a visibility SSBO, one-frame-pop policy"
```

← [Chapter 100 — A Sea Without Edges](ch100-a-sea-without-edges.md) · [Chapter 102 — MILESTONE: Ten Thousand Things](ch102-milestone-ten-thousand-things.md) →
