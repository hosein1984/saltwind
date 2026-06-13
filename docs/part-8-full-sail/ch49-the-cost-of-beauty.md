# Chapter 49 — The Cost of Beauty

*Part 8 — Full Sail · Estimated time: 4–5h · learnopengl: [Debugging](https://learnopengl.com/In-Practice/Debugging)*

**What you'll see when done:** a panel section listing every render pass with its GPU milliseconds, live — and a measurably faster frame after you act on what it says.

## Where we are

Saltwind now renders shadows, reflections, an HDR scene, bloom, thousands of instances, particles, and UI — and you have no idea what any of it costs. Maybe it's fine! But "maybe" dies at the first complex scene on a weaker GPU. This chapter builds honest measurement first — CPU timers, then GPU timer queries with their async trap — and only then optimizes, because the first law of performance work is: **optimize only what the timer indicts.** Guessing has a near-perfect record of being wrong.

## Concepts

### The frame budget

60 fps = **16.6 ms** per frame, everything included: simulation, draw submission, GPU work, present. (144 Hz = 6.9 ms; a comfy 30-fps-cinematic = 33 ms.) A budget turns vague guilt into engineering: if the frame takes 12 ms, you have 4.6 ms to spend on something *pretty* — spend it! If it takes 19 ms, the biggest line item is the only conversation worth having. Also know the difference between **throughput and spikes**: an average of 14 ms with a 40 ms hitch every 2 s (hello, blocking IBL rebuild from ch43) feels worse than a flat 16. Track *max* per second alongside the average.

### CPU timers: what the processor saw

`core:time` gives monotonic tick timers (names verified at [pkg.odin-lang.org/core/time](https://pkg.odin-lang.org/core/time/)):

```odin
import "core:time"

start := time.tick_now()
terrain_render_all(...)
ms := time.duration_milliseconds(time.tick_since(start))
```

But understand what you measured: GL calls mostly *record commands*; the driver flushes them to the GPU whenever it pleases. A CPU timer around `terrain_render_all` measures *submission* cost (real! this is the draw-call overhead from ch45) — **not** rendering cost. A CPU timer around the whole frame *including* `glfw.SwapBuffers` measures true frame time, because swap blocks on vsync/GPU. The classic rookie reading — "SwapBuffers takes 9 ms, GLFW is slow!" — is the GPU bill arriving at the only cash register.

### GPU timer queries: what the GPU saw

GL 3.3 has timer queries: bracket a span of commands and the GPU records elapsed nanoseconds for *its* execution of them:

```odin
gl.GenQueries(1, &q)
gl.BeginQuery(gl.TIME_ELAPSED, q)
// ... draw calls ...
gl.EndQuery(gl.TIME_ELAPSED)
```

**The async gotcha:** the result doesn't exist until the GPU actually executes those commands — typically 1–3 frames later. Calling `gl.GetQueryObjectui64v(q, gl.QUERY_RESULT, &ns)` immediately *stalls the pipeline* until it does, destroying the very performance you're measuring (and serializing CPU/GPU so all your numbers lie). The fix is a small ring buffer: write into query set `frame % N`, read query set `(frame + 1) % N` — results that are N-1 frames stale, and nobody cares. Check readiness with `gl.GetQueryObjectiv(q, gl.QUERY_RESULT_AVAILABLE, &ready)` if you're cautious. One more limit: `TIME_ELAPSED` queries can't nest — one open span at a time, so structure them as a flat sequence of passes (which your renderer already is).

### Then, and only then: the classic wins, ranked

Once the panel shows real numbers, these are the usual suspects in a scene like Saltwind's, in rough order of payoff-per-effort:

1. **Halve the reflection FBO.** The ch30 planar reflection re-renders terrain+sky at full resolution, to be smeared by waves anyway. Half res = quarter cost of your second-most-expensive pass, visually free. (Refraction too.)
2. **State-change batching.** Sort draws by shader, then texture: every `gl.UseProgram` and texture bind is driver work. You don't need a material-sort framework — just *order your render proc sensibly*: all terrain chunks together (one shader bind, one splat-texture bind, N draws), all PBR props together, etc. You're probably 80% there by accident; make it deliberate and delete redundant binds (a tiny `current_program` cache in `shader_use` kills hundreds of redundant calls).
3. **Terrain chunk LOD.** Far chunks don't need full vertex density. The index-stride trick: build 2–3 extra index buffers per chunk resolution (every vertex / every 2nd / every 4th — same VBO!), pick by distance. Cracks appear at LOD seams; your ch23 skirts already hide them — that's *why* terrain skirts are standard. Vertex cost drops ~4× per LOD step.
4. **Particle & instance caps.** Storm rain at 4× density is invisible past 2× — cap pools, cap grass draw distance (ch45 exercise 4). Cheap insurance, not glory.
5. **Shadow pass diet.** Grass tufts in the shadow map cost vertices and change nothing visible. Casters list ⊂ drawables list.

> **Sidebar — `glDebugMessageCallback` (GL 4.3+).** Modern GL's best debugging tool: the driver *tells you* about errors and performance issues in a callback (no more `gl.GetError` scattering). It needs a 4.3 context — see ch50 for how to request one safely — and then ~10 lines: request a debug context via `glfw.WindowHint(glfw.OPENGL_DEBUG_CONTEXT, 1)`, `gl.Enable(gl.DEBUG_OUTPUT)`, set the callback, filter severities. If your hardware has 4.3 (it almost certainly does), turn this on in debug builds *today*; learnopengl's [Debugging](https://learnopengl.com/In-Practice/Debugging) article covers it well.

## Odin notes

A profiler wants zero-friction scoping, and Odin's `defer` makes a lovely one-liner pattern: `profile_scope` returns a started timer and you defer its stop — or simpler, a pair of explicit calls per pass since your passes are already a flat list. Resist the urge to build a macro empire; five passes need five begin/end pairs.

## Build

1. **A `Profiler`.** Per named pass: CPU ms, GPU ms, with double-buffered queries (use 3 for safety):

   ```odin
   MAX_PASSES :: 12
   FRAMES_IN_FLIGHT :: 3

   Pass_Timing :: struct {
       name:      string,
       queries:   [FRAMES_IN_FLIGHT]u32, // TIME_ELAPSED query objects
       cpu_start: time.Tick,
       cpu_ms:    f32,
       gpu_ms:    f32,                   // smoothed
   }

   Profiler :: struct {
       passes: [dynamic]Pass_Timing,
       frame:  int,
   }

   profiler_begin_pass :: proc(p: ^Profiler, pass: ^Pass_Timing) {
       pass.cpu_start = time.tick_now()
       gl.BeginQuery(gl.TIME_ELAPSED, pass.queries[p.frame % FRAMES_IN_FLIGHT])
   }

   profiler_end_pass :: proc(p: ^Profiler, pass: ^Pass_Timing) {
       gl.EndQuery(gl.TIME_ELAPSED)
       pass.cpu_ms = f32(time.duration_milliseconds(time.tick_since(pass.cpu_start)))
   }
   ```

   At frame start, harvest the *oldest* query set:

   ```odin
   profiler_collect :: proc(p: ^Profiler) {
       read := (p.frame + 1) % FRAMES_IN_FLIGHT // written FRAMES_IN_FLIGHT-1 frames ago
       for &pass in p.passes {
           ns: u64
           gl.GetQueryObjectui64v(pass.queries[read], gl.QUERY_RESULT, &ns)
           pass.gpu_ms = math.lerp(pass.gpu_ms, f32(ns) / 1_000_000.0, f32(0.05))
       }
       p.frame += 1
   }
   ```

   (Skip collection for the first `FRAMES_IN_FLIGHT` frames — the queries haven't been used yet; querying a never-used query object is an error.) The `lerp` smoothing makes numbers readable instead of jittering.

2. **Instrument the passes.** Wrap each: *shadow, reflection, refraction, scene, bloom, tonemap, ui*. Your ch44 pass-order comment block becomes code structure. Also count draw calls: a global incremented in `mesh_draw`/`instanced_mesh_draw`, reset per frame.

3. **Panel section.** In the microui window:

   ```odin
   if .ACTIVE in mu.header(ctx, "Frame") {
       mu.layout_row(ctx, {110, 70, 70})
       mu.label(ctx, "pass"); mu.label(ctx, "cpu ms"); mu.label(ctx, "gpu ms")
       for &pass in profiler.passes {
           mu.label(ctx, pass.name)
           mu.label(ctx, fmt.tprintf("%.2f", pass.cpu_ms))
           mu.label(ctx, fmt.tprintf("%.2f", pass.gpu_ms))
       }
       mu.label(ctx, fmt.tprintf("draws: %d  frame: %.1f / 16.6 ms", draw_calls, frame_ms))
   }
   ```

4. **Read it. Write down the verdict.** Sail to your densest island in a storm, panel open. Which pass is fattest? On most rigs it's *scene* (lots of PBR fragments) with *reflection* second. Yours may differ — that's the point. Commit the numbers in a `PERF.md` or commit message: before/after honesty.

5. **Execute the top two indicted wins.** Almost certainly: (a) half-res reflection+refraction targets — change the FBO sizes, done, measure (expect the reflection line to drop ~4×); (b) the shader/texture bind cache + grouping — add `current_program: u32` guard in `shader_use`, reorder your render proc by material, measure CPU submission drop.

6. **Terrain LOD if indicted.** If *scene* GPU time is dominated by terrain (test: skip terrain draws for one frame with a debug toggle and compare), add the index-stride LOD: at chunk build, also build index buffers at stride 2 and 4; at draw, pick by camera distance (e.g. >150 m → stride 2, >350 m → stride 4). Verify skirts swallow the seams.

7. **Caps.** Storm rain pool cap, grass distance cap, and clamp particle spawn when over budget (`if frame_ms > 15 { rate *= 0.5 }` is crude and effective — *adaptive* quality in one line).

## Checkpoint

The Frame panel shows ~7 passes with believable numbers: shadow ~0.4, reflection now ~0.7 (was ~2.5), scene ~4–8, bloom ~0.3, tonemap ~0.1, ui ~0.1 — and the totals roughly add up to the frame time when GPU-bound.

- Toggle a pass off (skip its draws) and its line drops to ~0 while others hold — queries are bracketing what you think they bracket.
- Numbers are stable to the eye (smoothing), and no stall: frame time with the panel open ≈ closed (async harvest working; if opening the profiler costs 3 ms, you're reading same-frame results).
- Draw-call count matches expectation (chunks + props + instanced batches + UI ≈ dozens, not thousands).
- Your two executed wins show in the numbers, recorded before/after.

## Pitfalls

- **GPU times all zero.** You read query set `frame % N` (just written, not executed) instead of the oldest; or you never called `profiler_collect`; or the pass had zero draws between begin/end.
- **Frame time *doubles* with profiler on.** You're calling `GetQueryObjectui64v` on the current frame's query — the stall. Ring buffer, oldest set, always.
- **`GL_INVALID_OPERATION` from queries.** Nested `TIME_ELAPSED` spans (one at a time!), or `EndQuery` without a matching begin, or harvesting a query that was never begun (the first-frames guard).
- **GPU numbers don't sum to frame time.** Normal when CPU-bound (GPU idles between passes) or when vsync pads the frame. Compare against frame time with vsync off (`glfw.SwapInterval(0)`) when measuring; ship with it on.
- **Reflection still slow after halving.** You halved the texture but not the `gl.Viewport` in that pass — you're rendering full-res into a quarter of memory... or rather, clipping. Both, together.
- **"It's faster on my machine but I can't tell why."** You changed three things before measuring. One change, one measurement, one note. Performance work is lab work.

## Exercises

1. Add a 120-frame scrolling frame-time graph to the panel (microui rects of varying height — you have a quad batcher; spikes become *visible* instead of felt).
2. Find a hitch: with the graph up, trigger the ch43 IBL rebuild. If it spikes, finish the amortization exercise — one face/mip per frame — and watch the spike flatten.
3. Implement `gl.GetError` sweep-mode: a debug flag that calls it after every pass and logs nonzero results with the pass name. (Then read the `glDebugMessageCallback` sidebar and feel the upgrade coming.)
4. **Stretch:** GPU-timestamp *within* the scene pass by splitting it: terrain / ocean / props / vegetation as separate bracketed sub-passes. Which actually dominates? Was your guess right? (It wasn't. It never is.)

## Commit

`git commit -m "ch49: CPU+GPU pass profiler, half-res reflections, bind batching, terrain LOD"`

[← Ch. 48: Words on Glass](ch48-words-on-glass.md) · [Ch. 50: Deeper Waters →](ch50-deeper-waters.md)
