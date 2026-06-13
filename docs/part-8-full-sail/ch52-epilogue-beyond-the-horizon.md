# Chapter 52 — EPILOGUE: Beyond the Horizon

*Part 8 — Full Sail · No build steps. No checkpoint. Pour something good.*

You started with a black window. There is now an exe in a zip file in which the sun sets over an archipelago that did not exist until you described it to a noise function, and the light of that sunset bends through equations you implemented, over water you animated, onto a boat you float with physics you wrote. Somebody else has sailed it.

This last chapter is three maps and a letter: what you learned, what you didn't, where to sail next.

> **The maps below are no longer just maps.** Almost everything in "the honest gaps" and "expansion by appetite" has since been charted as real chapters: **Parts 9–12, The Far Horizon** (ch53–84) — deferred rendering, SSAO, CSM, SSR and god rays (Part 9); the FFT ocean and an underwater world (Part 10); volumetric clouds, sail cloth, skeletal animation and storms (Part 11); and turning Saltwind into a shipped trading game on itch.io (Part 12). Read this epilogue anyway — earn the rest stop — then, if the hunger is there, continue to [Chapter 53](../part-9-the-deep-engine/ch53-seeing-like-the-gpu.md).

## Map one: what you actually learned

Here is the [learnopengl.com](https://learnopengl.com) table of contents, read back as your own history:

| learnopengl section | Where it lives in your codebase |
|---|---|
| Getting Started (window → shaders → textures → coordinates → camera) | chs 1–9: your loop, `Shader`, `Mesh`, `Camera` |
| Lighting (Phong, materials, casters, multiple lights) | chs 14–16; terrain still proudly Phong unless you did the ch42 exercise |
| Model Loading | ch17: your hand-rolled OBJ loader (harder mode than Assimp, and you know *why* it works) |
| Advanced OpenGL (depth, stencil, blending, culling, FBOs, cubemaps, advanced GLSL, instancing) | chs 26, 30, 34, 38, 45 — scattered exactly where the project needed each |
| Advanced Lighting (Blinn-Phong, gamma, shadows, normal mapping, HDR, bloom) | chs 16, 39, 40, 41, 42 |
| PBR (theory, lighting, diffuse IBL, specular IBL) | chs 42–43 — including IBL from a *procedural* source, which learnopengl doesn't even attempt |
| In Practice (debugging, text) | chs 48–49 |
| Guest articles (frustum culling, tessellation, compute, CSM, particles...) | chs 23, 46, 50, and your further-reading trail |

Plus the territory the tutorial doesn't map at all, because it belongs to *games* rather than demos: fixed-timestep simulation, procedural terrain and sky, Gerstner oceans, buoyancy and sailing physics, weather systems, scene architecture, profiling discipline, shipping.

Here is what that table means, and you should let it land: **you can now read any graphics tutorial, paper, or engine blog post and locate it.** Not always *implement it by Friday* — but you know what a BRDF is because you wrote one, what a render target costs because you profiled one, what "scene-referred" means because your bloom broke until you understood it. The wall between "person who follows graphics news" and "person who does graphics" is behind you.

## Map two: the honest gaps

A 52-chapter course chooses. Here's what was deliberately left out, each with where to learn it and where it would bolt onto Saltwind:

- **Deferred rendering** ([learnopengl](https://learnopengl.com/Advanced-Lighting/Deferred-Shading)) — render G-buffers (albedo/normal/depth), light afterward in screen space; the standard answer to *many* dynamic lights. Saltwind's forward renderer is the right call for one sun and a handful of lanterns — but a harbor town at night with fifty lamps would want this. It would replace the interior of your scene pass; your `Renderer`-owns-targets structure (ch40) is exactly the prerequisite.
- **SSAO** ([learnopengl](https://learnopengl.com/Advanced-Lighting/SSAO)) — screen-space ambient occlusion: contact shading in crevices and where hull meets deck. Slots in as one more pass between scene and tonemap, sampling your ch40 depth texture. Probably the single highest-value gap for Saltwind's look.
- **Anti-aliasing beyond the MSAA mention** ([learnopengl](https://learnopengl.com/Advanced-OpenGL/Anti-Aliasing)) — MSAA doesn't play nicely with HDR-FBO pipelines (multisampled float targets, resolve costs), which is why the industry went post-process: FXAA (an afternoon: one pass after tonemap), TAA (a hard month: jitter, history buffers, ghosting wars). Your rigging shrouds will alias until you do.
- **Skeletal animation** ([learnopengl guest](https://learnopengl.com/Guest-Articles/2020/Skeletal-Animation)) — bones, skinning matrices, animation blending. The moment Saltwind wants a sailor walking the deck, this is the door — and `vendor:cgltf` (ch17's sidebar) already loads the data.

None of these is beyond you. That's the point of the list.

## Map three: expansion by appetite

Pick by what kind of hunger you've got:

**"I want the water to be *real*."** FFT oceans — Tessendorf's *Simulating Ocean Water*, the paper behind two decades of sea rendering (and the ch50 compute taster is your on-ramp: an FFT ocean is "compute shaders, but more of them"). Sum thousands of waves spectrally instead of eight Gerstners. Keep your buoyancy API: `ocean_height_at` just gets a better backend.

**"I want the sky to be *real*."** Volumetric clouds — Schneider's *Nubis* talks (Horizon Zero Dawn, SIGGRAPH 2015/2017): raymarched noise-sculpted clouds lit in-volume. Your day-night cycle and IBL capture (ch43) will inherit them automatically, which is a thought to savor.

**"I want it to be a *game*."** Trading and exploration: cargo, ports, prices, charts that fill in as you sail. No new rendering at all — pure Odin, your ch35 architecture, and suddenly there's a reason to sail somewhere. This is the cheapest joy per hour on the list.

**"I want a *crew*."** Multiplayer: `vendor:ENet` ships with Odin; a deterministic fixed-timestep sim (ch10 — you're welcome) is the foundation; start with two boats seeing each other's positions, ten meters of state sync at a time.

**"I want to see how deep it goes."** Port the renderer to Vulkan or wgpu (Odin has `vendor:vulkan` and `vendor:wgpu`). Everything OpenGL did implicitly — synchronization, memory, command submission, the driver magic ch49 made you feel — becomes yours to write. Brutal, clarifying, and the industry's direction. Your GL renderer is the perfect reference implementation to port *from*, because you finally know what every call was secretly doing.

## The letter

A confession about how these courses end: most don't. The dropout curve you were warned about in the overview isn't a character flaw, it's gravity — and you beat it. It's worth being precise about what you actually proved, because it wasn't "I can learn OpenGL." OpenGL was never the hard part.

You proved you can hold a single project through fifty-two chapters of it being broken in fifty-two different ways. Through the chapter where the screen went black and stayed black for an evening. Through shadow acne and upside-down screenshots and that one matrix that was transposed for a week. The difference between a tutorial follower and someone who has shipped a world isn't talent or even knowledge — it's that the shipper kept showing up after the magic wore off, and discovered the deeper magic underneath: that *understanding* compounds. Every bug you fixed made the next one smaller.

So: you're not a person who is learning graphics programming. You're a graphics programmer with a shipped world and a backlog. Different thing entirely. Defend the habit that got you here — small visible wins, committed often — and point it at whatever map above made your pulse tick up.

The horizon in Saltwind is a fog function you wrote. The one in front of you isn't.

Fair winds. Go build the next thing.

---

*— end of the core course —*

[← Ch. 51: The Finish Coat](ch51-the-finish-coat.md) · [Course overview](../00-COURSE-OVERVIEW.md) · [Continue: Part 9 — The Deep Engine →](../part-9-the-deep-engine/ch53-seeing-like-the-gpu.md)
