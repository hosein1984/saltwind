# Chapter 53 — Seeing Like the GPU

*Part 9 — The Deep Engine · Estimated time: 4–5h · learnopengl: [Debugging](https://learnopengl.com/In-Practice/Debugging)*

**What you'll see when done:** your whole frame laid open in RenderDoc — every pass, every texture, every vertex — and a console that *tells you* when you misuse GL, because Saltwind now runs on a 4.3 core context.

## Where we are

Welcome back aboard. The core course ended with a finished world; Part 9 makes the *renderer under it* professional-grade — deferred shading, SSAO, cascaded shadows, screen-space reflections, volumetrics. Every one of those is a multi-pass technique where the failure mode is "black screen, no error." So before we build anything, we acquire the two tools that make the next seven chapters debuggable instead of miserable: **RenderDoc**, the frame debugger every graphics programmer lives in, and **`glDebugMessageCallback`**, which requires us to finally raise the mast from GL 3.3 to **4.3 core**. Nothing gets prettier today. Everything gets *seeable*.

## Concepts

### Why printf dies at the GPU boundary

Your CPU debugging instincts — print it, step through it — stop at `gl.DrawElements`. The actual work happens later, on another processor, in thousands of parallel invocations you can't attach to. The graphics equivalent of a debugger is a **frame capture**: record every GL call in one frame plus all the resources they touched, then *replay* the frame call-by-call on demand, inspecting GPU state between any two calls. That's RenderDoc. A capture answers the questions printf can't: *what was actually bound? what did the vertex shader actually output? what's actually in that texture right now?*

### The RenderDoc tour

```
 Event Browser            Pipeline State           Texture Viewer
 (the frame as a          (what was bound at        (any texture, any
  tree of calls)           this draw)                point in the frame)
 ┌──────────────┐         ┌───┬───┬───┬───┬───┐     ┌───────────────┐
 │ Shadow Pass  │  click  │VTX│VS │RS │FS │FB │     │ inputs  ────► │
 │ Scene Pass   │ ──────► │   │   │   │   │   │     │ outputs ────► │
 │  ├ draw #214 │         └───┴───┴───┴───┴───┘     │ + pixel hist. │
 │ Bloom ...    │              Mesh Viewer: VS in / VS out / preview │
 └──────────────┘
```

- **Event Browser** — the frame as an ordered list of actions. Select any draw; everything else in the UI shows the state *as of that draw*.
- **Pipeline State** — per-stage inspection: vertex attributes and their interpretation (VTX), the exact shader source + **uniform values** (VS/FS), rasterizer state (culling! depth func!), bound textures with thumbnails, and framebuffer attachments (FB).
- **Texture Viewer** — every texture and render target, at any event, with channel toggles, range remapping (essential for HDR and depth textures), and *pixel history*: click a pixel, see every draw that wrote it and why others failed (depth test, stencil, scissor).
- **Mesh Viewer** — the draw's vertices as a table and 3D preview, both *VS Input* (what you uploaded) and *VS Output* (post-transform, in clip space). This is where "my geometry vanished" stops being a mystery.
- **Resource Inspector** — every buffer, texture, shader, and FBO the capture knows about, with creation parameters. The fastest way to catch "this texture is RGBA8 but I meant RGBA16F."

### The debug callback: GL that talks back

`gl.GetError` is a one-flag breathalyzer you must remember to administer. GL 4.3 made **KHR_debug** core: the driver pushes human-readable messages — errors, performance warnings, deprecations — to a callback *you* register, with source/type/severity classification. Plus two gifts for RenderDoc: `gl.PushDebugGroup`/`gl.PopDebugGroup` turn your pass structure into named, collapsible nodes in the Event Browser, and `gl.ObjectLabel` names your FBOs and textures so the Texture Viewer says "gbuffer_normal" instead of "Texture 47".

### Why 4.3, and the escape hatch

The bump buys this expansion its foundations:

- **`glDebugMessageCallback`** and friends (this chapter) — driver messages, debug groups, object labels.
- **Compute shaders** — Part 10's FFT ocean and ripple sim. The real reason; 4.3 is exactly the version that added them.
- **`gl.TexStorage2D/3D`** immutable textures — allocate all mips/layers in one validated call; ch57's cascade array uses it.
- **Texture views** — alias one texture's storage with another format/mip range; handy for debug visualization of single mips.
- **SSBOs** and the GLSL 430 niceties — `layout(binding = N)` on samplers and UBOs, explicit uniform locations; less `shader_set_i32` boilerplate from here on.

Any GPU from roughly 2012 onward has 4.3; your players' machines almost certainly do. But "almost" is a word engines respect, so today you also plant a build flag — `GL33_FALLBACK` — that keeps the old context request compiling. Chapter 83 turns that flag into a real min-spec story; for now it's an escape hatch and a discipline: *every 4.3-only feature you add from here on gets a comment naming it.*

From this chapter onward, all shader excerpts use `#version 430 core`.

## Odin notes

The debug callback is called by the driver, possibly mid-GL-call, so it's a `proc "c"` — no Odin context. Same drill as your GLFW callbacks from ch2: first line `context = runtime.default_context()` before touching `fmt`. vendor:OpenGL declares the matching pointer type as `gl.debug_proc_t`, so your proc's signature must be exactly: `(source, type, id, severity: u32, length: i32, message: cstring, userParam: rawptr)`.

The build flag is Odin's `#config`: `GL33_FALLBACK :: #config(GL33_FALLBACK, false)` in `main.odin`, then `when GL33_FALLBACK { ... }` blocks — toggled per-build with `odin build src -define:GL33_FALLBACK=true`, zero runtime cost.

## Build

1. **Install RenderDoc** from [renderdoc.org](https://renderdoc.org) (stable build). In the *Launch Application* tab: executable = your `saltwind.exe`, working directory = your project root (so `assets/` resolves — the #1 "capture is black because the app crashed" cause). Launch; an overlay confirms injection. Press **F12** while sailing; quit; the capture opens.

2. **Orientation lap.** In the Event Browser, walk the frame top to bottom and match it to your mental model: shadow pass, reflection, refraction, HDR scene, bloom ping-pongs, tonemap. Click the tonemap draw and look at *FB* in Pipeline State — that's the backbuffer. Click an ocean draw, open the Texture Viewer, and inspect your HDR target mid-frame with range remapping (drag the white point up — there's your >1.0 sun). You built all of this; now you can *see* all of it.

3. **Kata 1 — "why is this draw black?"** Sabotage on purpose: in the boat's render proc, comment out the albedo texture bind. Run, capture the black boat. Diagnosis path: Event Browser → the boat draw → Pipeline State → FS stage → texture list. You'll see whatever stale texture (or "No Resource") sits on that unit. While you're there, check the uniform values panel — this is also where a forgotten `shader_set_*` shows up as a default-zero uniform. Restore the bind. *The lesson: black output = inspect FS inputs first.*

4. **Kata 2 — "where did my geometry go?"** Sabotage two: upload the boat's model matrix with `transpose = true` (flip the third argument of `gl.UniformMatrix4fv`). Capture the boatless sea. Diagnosis: select the draw (it's still *in* the Event Browser — submitted, just invisible) → Mesh Viewer. *VS Input* looks fine; *VS Output* shows clip-space positions that are garbage — the translation smeared into the w row. Compare against a healthy draw. This tab also instantly diagnoses zero scale (all vertices identical), wrong winding after a flip (preview shows backfaces), and missed buffer uploads (input all zeros).

5. **Kata 3 — "what does this frame cost?"** Open a storm-weather capture. Right-click the Event Browser columns and enable **Duration**; let RenderDoc replay with timings. Now read the frame like a bill: how much is the scene pass vs both planar FBOs vs bloom? Cross-check against your ch49 panel numbers (same shape, not identical — replay timing differs from live). Count draws per pass. Write down the three most expensive events; ch55 will come back for them.

6. **Raise the mast.** In your GLFW init, change the context request and the loader ceiling, behind the flag:

   ```odin
   GL33_FALLBACK :: #config(GL33_FALLBACK, false)
   GL_MAJOR :: 3 when GL33_FALLBACK else 4
   GL_MINOR :: 3

   glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, GL_MAJOR)
   glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, GL_MINOR)
   glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
   when ODIN_DEBUG && !GL33_FALLBACK {
       glfw.WindowHint(glfw.OPENGL_DEBUG_CONTEXT, 1)
   }
   // after MakeContextCurrent:
   gl.load_up_to(GL_MAJOR, GL_MINOR, glfw.gl_set_proc_address)
   ```

   Run. Everything should look identical — 4.3 core is a superset of 3.3 core.

7. **Bump the shaders.** Find-and-replace `#version 330 core` → `#version 430 core` across `assets/shaders/`. Better: since your ch47 `#include` expander already preprocesses every shader, have it *prepend* the version line instead and delete it from the files — one place owns the version forever:

   ```odin
   GLSL_VERSION :: "#version 330 core\n" when GL33_FALLBACK else "#version 430 core\n"
   // in the expander, before gl.load_shaders_source:
   src := strings.concatenate({GLSL_VERSION, expanded}, context.temp_allocator)
   ```

   Verify hot reload still works after the change.

8. **Wire the callback.** In a new `src/gl_debug.odin`:

   ```odin
   gl_debug :: proc "c" (source, type, id, severity: u32,
                         length: i32, message: cstring, user: rawptr) {
       context = runtime.default_context()
       if severity == gl.DEBUG_SEVERITY_NOTIFICATION do return
       sev := severity == gl.DEBUG_SEVERITY_HIGH ? "HIGH" :
              severity == gl.DEBUG_SEVERITY_MEDIUM ? "med" : "low"
       fmt.eprintf("[GL %s] (%d) %s\n", sev, id, message)
   }

   gl_debug_init :: proc() {
       gl.Enable(gl.DEBUG_OUTPUT)
       gl.Enable(gl.DEBUG_OUTPUT_SYNCHRONOUS) // message fires inside the offending call
       gl.DebugMessageCallback(gl_debug, nil)
       gl.DebugMessageControl(gl.DONT_CARE, gl.DONT_CARE,
                              gl.DEBUG_SEVERITY_NOTIFICATION, 0, nil, false)
   }
   ```

   Call it after `load_up_to`, guarded by the same `when`. Test it: bind a texture to a nonexistent target once — enjoy the driver explaining your crime in prose.

9. **Name your frame.** Bracket each pass in your renderer (`gl.PushDebugGroup(gl.DEBUG_SOURCE_APPLICATION, 0, -1, "shadow pass")` … `gl.PopDebugGroup()`; length `-1` means null-terminated) and label your key targets (`gl.ObjectLabel(gl.TEXTURE, r.hdr.color_tex, -1, "hdr_color")`). Recapture: the Event Browser is now a table of contents. With seven more passes coming this part, this is the best ten minutes you'll spend.

## Checkpoint

The game runs on a 4.3 core debug context and looks pixel-identical to ch52. A fresh RenderDoc capture shows named, collapsible pass groups and labeled textures.

- `gl.GetString(gl.VERSION)` (print at startup) reports 4.3+ and your console shows zero debug-callback output during a normal sail — or it shows real warnings you now get to fix.
- All three katas reproduced and diagnosed: you found the missing bind in Pipeline State, the bad matrix in Mesh Viewer's VS Output, and you have written-down per-pass costs from Duration.
- A `-define:GL33_FALLBACK=true` build compiles and runs (callback and groups silently skipped).
- Shader hot reload still works after the version-line change.

## Pitfalls

- **RenderDoc shows an empty/black capture.** The app crashed before the first present (usually working-directory → missing assets), or you captured during a loading frame. Set the working dir in the launch tab; capture after the world is visibly up.
- **Context creation fails at 4.3.** Ancient GPU or — far more often — you're on the integrated GPU of a dual-GPU laptop with stale drivers. Update drivers; force the discrete GPU for `saltwind.exe`; worst case, you have a genuine `GL33_FALLBACK` user: you.
- **Crash inside the debug callback.** You called `fmt` without setting the Odin context, or your proc signature deviates from `gl.debug_proc_t` (argument order matters; `message` is `cstring`, not `string`).
- **A flood of "Buffer object ... will use VIDEO memory" notifications.** That's NVIDIA's severity-NOTIFICATION chatter — exactly why step 8 filters it. If you still see it, your `DebugMessageControl` call runs *before* the callback is registered or the enables.
- **Frame rate dipped in debug builds.** `DEBUG_OUTPUT_SYNCHRONOUS` serializes the driver. Keep it: correctness tooling belongs in debug builds, and your release build (no `OPENGL_DEBUG_CONTEXT` hint) is untouched.
- **`load_up_to(4, 3, ...)` but 4.x functions are nil.** The *context* is still 3.3 because the window hints didn't take (hints must precede `CreateWindow`, and they reset — set them every run).
- **Shaders fail to compile only after the expander owns `#version`.** A stray `#version` line survives in some file (now line 2 — illegal), or the expander prepends *after* an early `#include`. Version first, includes second, everything else third.

## Exercises

1. Pixel-history a wake-foam pixel: find every draw that touched it (ocean, foam quad, tonemap) and one fragment that *lost* the depth test. Screenshot it — this feature will save you in ch58.
2. Make high-severity messages crash loudly in debug builds: `when ODIN_DEBUG` call `intrinsics.debug_trap()` (from `base:intrinsics`) in the callback when `severity == gl.DEBUG_SEVERITY_HIGH` — with `DEBUG_OUTPUT_SYNCHRONOUS` the debugger stops *on the offending GL call*.
3. Use `gl.DebugMessageInsert` to inject your own marker (e.g. "IBL rebuild, face 3") and find it in a capture — application messages ride the same stream.
4. **Stretch:** capture a frame during the amortized ch43 IBL rebuild and walk the cubemap face render in the Texture Viewer, mip by mip. Verify the prefilter mips actually blur the sun the way ch43 claimed. (You believed it then; now look.)

## Commit

`git commit -m "ch53: GL 4.3 core + debug callback, RenderDoc katas, debug groups and labels"`

[← Ch. 52: Epilogue — Beyond the Horizon](../part-8-full-sail/ch52-epilogue-beyond-the-horizon.md) · [Ch. 54: Smooth Sailing Edges →](ch54-smooth-sailing-edges.md)
