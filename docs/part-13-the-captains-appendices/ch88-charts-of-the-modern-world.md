# Chapter 88 — Charts of the Modern World

*Part 13 — The Captain's Appendices · Standalone essay: requires Part 8 · No build steps, no checkpoint — this is a chart-reading session. Bring coffee.*

Chapter 52 was the emotional bookend of this course — the letter about what you proved by finishing. Read it when you need it. This chapter is the *technical* bookend: a navigator's chart of the graphics world as it stands in the mid-2020s, drawn for someone who now has an unusual qualification — you've built a complete modern renderer on an API the industry calls legacy, which means you know precisely what every newer API is *for*. This essay names the waters, marks where your knowledge transfers, and is honest about the one part that doesn't.

## What "explicit API" actually means

Vulkan, Direct3D 12, and Metal are routinely called "low-level," which makes them sound like assembly. The truer word is **explicit**. Here's the difference in terms of work you've already done.

When you call `gl.DrawElements`, the driver performs a small miracle on your behalf: it checks what state you've changed since the last draw, recompiles or fetches pipeline configurations, allocates and shuffles memory behind textures and buffers, inserts synchronization so your ch61 compute pass finishes before the vertex shader samples its output (well — *mostly*; you met `gl.MemoryBarrier` because even GL's guarantees have edges), and schedules everything across frames you believe are sequential but aren't. You've *felt* this miracle: it's the unexplained spikes in your ch49 timers, the first-frame shader hitch, the driver thread in your profiler.

Explicit APIs stop guessing and hand you the controls:

- **You manage synchronization.** Every dependency you got "for free" — render-to-texture then sample, compute then draw — becomes a barrier or semaphore you place. Misplace one and you get your ch61 black-ocean bug, everywhere, all the time. (You debugged that once. That's why you're allowed in these waters.)
- **You manage memory.** Textures and buffers don't own storage; you allocate heaps and sub-allocate from them — `Render_Target`'s create/destroy discipline, promoted from etiquette to law.
- **You record command buffers.** Instead of issuing calls that execute "now-ish," you record lists of work and submit them, possibly from many threads. The driver's hidden thread becomes your visible code.
- **Pipeline state is baked.** Your `Shader` plus blend/depth/cull state compiles into an immutable pipeline object up front — the first-frame hitch, dragged into the open where you can schedule it.

The reward is predictability and multi-core scaling; the cost is that the hundred-line triangle becomes a thousand-line triangle. The four charts on the table:

| API | Steward · where it runs | Character |
|---|---|---|
| **Vulkan** | Khronos · Windows, Linux, Android (macOS via MoltenVK) | maximum explicitness; the most portable of the fully explicit three |
| **Direct3D 12** | Microsoft · Windows, Xbox | Vulkan's sibling in spirit; the PC/console industry default |
| **Metal** | Apple · macOS, iOS | the most ergonomic explicit API; mandatory in Apple's waters |
| **WebGPU / wgpu** | W3C spec; wgpu and Dawn as native libraries · everywhere, including browsers | explicit-*ish*: you keep command buffers and bind groups, it keeps the sync and memory housekeeping |

WebGPU is the interesting newcomer — designed decades after the others learned their lessons, and roughly 70% of the control for 30% of the ceremony. Odin ships bindings for both ends of the spectrum: `vendor:vulkan` and `vendor:wgpu`.

## Where OpenGL honestly stands

OpenGL is complete. Version 4.6 (2017) was the last; no new features are coming. That sentence sounds like an obituary and isn't: drivers remain maintained on Windows and Linux (Apple froze GL at 4.1 and deprecated it — your fallback ladder from ch83 was partly about them), the API runs on two decades of hardware, the documentation and debugging ecosystem are the most mature in graphics, and nothing about a finished spec stops you from shipping. You *did* ship — an itch.io build with an FFT ocean, CSM, SSR, volumetric clouds, and a compute path tracer, at frame rates that embarrass the "OpenGL is slow" folklore. For learning, for solo and small-team games, for research prototypes, GL remains arguably the best tool available, precisely *because* the driver does the bookkeeping. Saltwind is the proof you carry.

What GL genuinely cannot give you is the modern hardware features below — they're exposed (if at all) only through vendor extensions. Those features are the actual reason to learn a new API, so let's chart them.

## Hardware ray tracing

Since 2018, GPUs have shipped fixed-function units that accelerate exactly two operations: building/refitting **BVHs** (bounding volume hierarchies) over triangle soups, and traversing them — millions of ray-triangle queries per frame. You know precisely what this hardware is for, because in ch86 you wrote the software version: your OBB tests and heightfield march were hand-rolled intersectors, and the ch86 Stretch exercise — a CPU-built BVH traversed in a compute shader — is *literally* the thing the silicon does, minus three orders of magnitude.

APIs expose it two ways. **Ray-tracing pipelines** are the full apparatus: shader tables, ray-generation/closest-hit/miss stages, recursion — built for full path tracers. **Ray queries** are the modest, more broadly useful form: any ordinary shader (fragment, compute) can say "cast this ray, tell me what it hit" inline. Vulkan has both; OpenGL has neither, and never will.

What shipping games actually do with it is **hybrid rendering**, and you are unusually equipped to understand why. A full path trace per frame is still too slow (ch86 taught you the economics: noise halves per 4× samples), so games keep the raster pipeline as the base and surgically replace the *approximations* with true rays: RT shadows replace shadow maps (no more ch39/57 bias tuning, no cascade seams — just visibility queries), RT reflections replace SSR (no more ch58 screen-edge fades — rays don't run out of screen), RT GI replaces ambient hacks with real bounce light, then a temporal denoiser cleans the low sample counts. You built every one of those approximations, and in ch86 you built the thing they approximate. You understand both endpoints of the bridge; hardware RT is just the bridge being cheap enough to cross per-frame, one effect at a time.

## The geometry pipeline, rethought

Three related developments dismantle assumptions your renderer was built on.

**Mesh shaders** replace the vertex-attribute machinery (your VAOs, the input assembler, optional tessellation/geometry stages) with something compute-shaped: a mesh shader is a workgroup that *emits* a small batch of triangles — typically one **meshlet**, a precomputed cluster of ~64–128 triangles — and an optional **amplification/task stage** decides which meshlets to launch at all. The payoff is culling at meshlet granularity *on the GPU*: the back half of every island, the boat's far side, gone before rasterization. (Nanite-style renderers push the idea to its limit: meshlet hierarchies with per-cluster LOD.) GL offers this only as an NVIDIA extension; in Vulkan/D3D12 it's a standard feature.

**Bindless resources** remove the texture-unit shuffle you've danced since ch6 (`ActiveTexture`, `BindTexture`, pray the units line up). Instead, all textures live in one big descriptor array and shaders index it freely — a material becomes just an integer. (GL actually has `ARB_bindless_texture`, but it's an extension outside core, with sharp edges; in modern APIs this is the *default* idiom.)

**GPU-driven rendering** is where both converge, and it's the logical end of the road ch45 started. Instancing taught you to stop issuing one draw per palm tree; GPU-driven rendering stops issuing one draw per *anything*: the scene lives in GPU buffers, a compute pass does frustum and occlusion culling (your ch23 AABB test, ported to compute — you could write that pass *today*), writes surviving draws into a buffer, and a single **indirect draw** call executes them all. The CPU's role shrinks to "press play." A taste of this is genuinely reachable in GL 4.6 — `glMultiDrawElementsIndirect` plus compute-side culling — and making that work is the best possible warm-up for the full modern version.

For upscalers — DLSS, FSR, XeSS, and why the learned ones need explicit APIs — Chapter 85 already drew that chart; it folds into this one.

## What transfers (almost everything)

Here is the part to internalize before any anxiety about "starting over" takes hold.

- **Every concept transfers untouched.** Walk the Concepts column of all 88 chapters: linear algebra and transforms, cameras, depth, lighting models, PBR and IBL, shadow mapping in all its bias-haunted glory, HDR/tonemapping/bloom, deferred vs. forward, SSAO, SSR, FFT oceans, volumetrics, particles, skeletal animation, fixed timesteps, frame profiling, the rendering equation itself. None of it was ever about OpenGL — GL was the syntax, not the subject.
- **Your shaders transfer with dialect changes.** Vulkan compiles the GLSL you already write down to SPIR-V; WebGPU's WGSL is a re-spelling of concepts you know (`var<uniform>`, `@group`, same math, same `sky_color`). The hard-won *content* of your shaders — the BRDF, the FFT butterflies, the cloud raymarcher — pastes across.
- **Your architecture transfers best of all.** A `Renderer` that owns targets and passes (ch40), explicit pass begin/end, per-pass timers, resources with create/destroy pairs: you've been writing renderer-shaped code for fifty chapters, and modern APIs reward exactly that shape. Vulkan's render passes and wgpu's pass encoders will feel like your own conventions, formalized.
- **Your debugging instincts transfer.** RenderDoc works on all of these APIs; "scrub the frame, inspect the resource, find the pass that lied" (ch53) is the universal method.

What doesn't transfer: the GL state-machine habits. Bind-to-edit, global state that leaks between passes, "just call it and the driver sorts it out," implicit sync as a birthright. Those reflexes you'll consciously retire — and honestly, ch53's debug-callback discipline and ch60's pass-list cleanup already retired half of them.

## If you port: a concrete sketch

Don't port Saltwind wholesale — port the **Part 1–8 skeleton** as a learning exercise, with your GL renderer open in the other window as the reference implementation that you know, line by line, actually works. That referent is worth more than any tutorial.

**wgpu first** is my honest recommendation for most readers: closest fit to the renderer you already have, runs on every OS and the web, `vendor:wgpu` ships with Odin, and its validation layer produces actual error messages. The mapping is pleasingly direct: your `Render_Target` becomes a texture + view + render-pass descriptor; your `Shader` becomes a WGSL module + pipeline object; your uniform helpers become bind groups (plan them as "per-frame / per-pass / per-material" sets — the structure your shader_set calls were secretly approximating); the fullscreen-triangle tonemap ports in an afternoon and that first ACES-graded clear color will feel like ch2 all over again, in the best way. Your game code — boat, wind, cargo, economy — doesn't change at all.

**Vulkan** is maximum truth, maximum ceremony: choose it if your goal is employment in engine work or you simply want no abstraction between you and the machine. Expect the famous thousand lines before the first triangle; expect also that every one of those lines names something you've already met implicitly. vkguide.dev (below) exists precisely to route you through it project-style — it's philosophically the same kind of resource this course was.

## The reading list

- **[vkguide.dev](https://vkguide.dev)** — the project-driven Vulkan tutorial; the closest thing to "Saltwind, but Vulkan."
- **[Learn wgpu](https://sotrh.github.io/learn-wgpu/)** — the standard wgpu walkthrough (Rust, but the API concepts map 1:1 to `vendor:wgpu`).
- **[Ray Tracing Gems I & II](https://www.realtimerendering.com/raytracinggems/)** — free PDFs; the bridge from your ch86 path tracer to production hybrid RT.
- **GPU Zen** (the book series) and the **"Open Problems in Real-Time Rendering"** SIGGRAPH courses — where the industry talks about what it hasn't solved yet; you can read these now, which is the point of the last 88 chapters.
- **The GDC Vault** ([gdcvault.com](https://www.gdcvault.com), much of it free) — search any system you built (CSM, FFT ocean, GPU-driven, frame graphs) and hear shipping teams describe the same problems with bigger budgets.
- And keep [Real-Time Rendering](https://www.realtimerendering.com)'s resource page bookmarked — the field's living index.

## The chart is drawn

A last bearing before you go. Every API in this essay — the explicit ones, the ray-traced ones, the GPU-driven ones — exists to answer the same question your first triangle asked in Chapter 3: *how do I get this data to draw itself?* The answers grow more powerful and more verbose, but the sea under them doesn't change: it's transforms and light and sampling and synchronization, and you have sailed all of it, in a small boat you built yourself, which is the only way anyone ever really learns the water. The chart is drawn now. Vulkan, wgpu, hardware rays, meshlets — these aren't walls at the edge of your map anymore; they're just weather, in waters you already know how to read. Pick a heading.

---

[← Ch. 87: Cargo Overboard](ch87-cargo-overboard.md) · [Course overview](../00-COURSE-OVERVIEW.md) · [The emotional bookend: Ch. 52 — Beyond the Horizon](../part-8-full-sail/ch52-epilogue-beyond-the-horizon.md)
