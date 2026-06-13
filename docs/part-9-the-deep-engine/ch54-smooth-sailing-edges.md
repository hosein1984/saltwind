# Chapter 54 — Smooth Sailing Edges

*Part 9 — The Deep Engine · Estimated time: 4–5h · learnopengl: [Anti Aliasing](https://learnopengl.com/Advanced-OpenGL/Anti-Aliasing)*

**What you'll see when done:** the boat's rigging lines hold steady as silhouettes instead of shimmering staircases — via real MSAA you can toggle, and an FXAA pass you'll probably ship.

## Where we are

Sail toward the sun and watch the mast stays: they crawl, sparkle, and stair-step. Every screenshot so far has had jagged edges and you've politely ignored them. This chapter teaches why aliasing happens — properly, as a sampling problem — then builds both classic answers: hardware **MSAA** on your HDR target (with the multisampled-FBO plumbing learnopengl's [Anti Aliasing](https://learnopengl.com/Advanced-OpenGL/Anti-Aliasing) chapter covers for the backbuffer), and **FXAA** as a post pass. You'll keep both behind toggles and learn why next chapter's deferred renderer will force a choice.

## Concepts

### Aliasing is a sampling problem

A pixel is not a little square you fill in — it's a **point sample** of a continuous image function, taken at the pixel center. Sampling theory (Nyquist) says you can only reconstruct detail that varies slower than half your sampling rate. The world contains *infinitely* sharp detail — a triangle edge is an instantaneous transition — so the signal always contains frequencies your pixel grid can't represent, and those frequencies don't vanish: they **fold back** ("alias") into false low-frequency patterns. Stairsteps are the alias of an edge; crawling is that alias *moving*.

Three distinct species infest Saltwind:

- **Geometric aliasing** — silhouette edges and subpixel geometry. A rigging rope is thinner than a pixel; whether any given pixel center lands inside it flips frame to frame as the camera bobs. That's the shimmer.
- **Shading aliasing** — the *surface* is smooth but the *shading function* on it has high frequencies: tight GGX speculars on normal-mapped water, sun glitter, palm-frond texture detail past the mip chain's help. Pixel centers sample the bright sliver or miss it.
- **Temporal aliasing** — either of the above, animated. The eye is brutally good at noticing flicker.

The taxonomy matters because the fixes attack different species, and sales brochures won't tell you which.

### MSAA: more visibility samples, same shading

Supersampling (render 4× the pixels, downscale) fixes everything and costs everything. **MSAA** is the hardware's surgical discount: per pixel it stores **N samples** (color + depth + stencil each), and the rasterizer computes a **coverage mask** — which of the N sample points the triangle overlaps. But the fragment shader still runs **once per pixel** per covered triangle, and its single result is written to all covered samples (depth-tested per sample).

```
 pixel with 4 samples          edge pixel: triangle covers 2 of 4
 ┌───────────┐                 ┌───────────┐
 │ ×       × │   1 FS run      │ ×    /  ✓ │   FS runs once,
 │           │   fills all     │     / ✓   │   result stored in the
 │ ×       × │   covered ×     │ ×  /      │   2 covered samples;
 └───────────┘                 └───────────┘   resolve averages 4
```

The **resolve** (averaging samples down to one pixel) happens in an explicit blit when you render to an FBO. Consequences worth internalizing:

- Geometric edges get up to N intensity levels: silhouettes smooth out. ✔
- Interior shading is computed once per pixel — **shading aliasing is untouched**. Your wave glitter still sparkles at 8×. ✘
- Memory and bandwidth: a 4×-multisampled RGBA16F + depth target is ~4× the already-chunky HDR target. On the resolve, averaging **linear HDR** samples then tonemapping is also subtly wrong — a 10,000-nit sun sample averaged with a dark sail sample is still huge, tonemaps to white, and the edge stays hard. (Engines that care tonemap *per sample* before resolve; we'll note it and move on.)

### The multisampled render target

Three changes versus ch40's target: textures are `gl.TEXTURE_2D_MULTISAMPLE` allocated with `gl.TexImage2DMultisample`, every attachment must share the same sample count, and you cannot `texture()` them in a shader — only `texelFetch` via `sampler2DMS`, or blit-resolve to a normal texture. We resolve: render scene → MS target, `gl.BlitFramebuffer` into the ordinary HDR target, and the rest of the post stack (bloom, tonemap) is none the wiser.

### FXAA: find edges in the image, blur along them

**FXAA 3.11** (Timothy Lottes, 2011) ignores geometry entirely. It runs on the final LDR image, detects edges by **luma contrast** between neighbors, estimates the edge's direction and length by walking along it, and blends each edge pixel with its neighbor *across* the edge by a carefully tuned amount. One fullscreen pass, ~0.2 ms, catches geometric *and* shading alias (anything that looks like an edge), costs a little overall sharpness. It wants two things: input *after* tonemap+gamma (it's tuned for perceptual values) and **luma in the alpha channel** so it doesn't recompute it per tap.

### TAA, honestly (survey only)

The modern default is **temporal AA**: jitter the projection matrix by a subpixel offset each frame (a Halton sequence), so over time each pixel *accumulates* many sample positions; reproject last frame's accumulated image using per-pixel **motion vectors**; blend ~90% history + 10% current. Effectively supersampling spread across time — it's why modern games look smooth *and* why they ghost (history invalid behind moving objects) and smear (the fixes — neighborhood clamping, history rejection — trade flicker back in). It needs motion vectors from every moving thing, including your Gerstner verts. Worth doing someday; not this part. Further reading: the *Inside* TAA talk (Pedersen, GDC 2016) and Karis's "High Quality Temporal Supersampling" (SIGGRAPH 2014).

## Build

1. **A multisampled target.** Extend `Render_Target` (or add `Render_Target_MS`) with a sample count:

   ```odin
   render_target_create_ms :: proc(w, h: i32, samples: i32) -> Render_Target {
       t: Render_Target
       gl.GenTextures(1, &t.color_tex)
       gl.BindTexture(gl.TEXTURE_2D_MULTISAMPLE, t.color_tex)
       gl.TexImage2DMultisample(gl.TEXTURE_2D_MULTISAMPLE, samples,
                                gl.RGBA16F, w, h, true)
       gl.GenTextures(1, &t.depth_tex)
       gl.BindTexture(gl.TEXTURE_2D_MULTISAMPLE, t.depth_tex)
       gl.TexImage2DMultisample(gl.TEXTURE_2D_MULTISAMPLE, samples,
                                gl.DEPTH24_STENCIL8, w, h, true)
       // FBO attach (TEXTURE_2D_MULTISAMPLE target), completeness check as in ch40
       return t
   }
   ```

   No filter parameters — MS textures have none. Give `Renderer` an `msaa_samples: i32` (0 = off) and create this target alongside `hdr` when nonzero.

2. **Reroute and resolve.** When MSAA is on, `renderer_begin_hdr` binds the MS target instead. At `renderer_end_hdr`, resolve before tonemapping:

   ```odin
   gl.BindFramebuffer(gl.READ_FRAMEBUFFER, r.hdr_ms.fbo)
   gl.BindFramebuffer(gl.DRAW_FRAMEBUFFER, r.hdr.fbo)
   gl.BlitFramebuffer(0, 0, w, h, 0, 0, w, h,
                      gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT, gl.NEAREST)
   ```

   Rectangles must match exactly when multisampled, and depth blits require `gl.NEAREST`. One ripple: ch46's soft particles need a readable depth texture, but with MSAA the scene depth is now multisampled. Simplest fix — do a depth-only resolve blit right before the particle pass (opaques are done by then), and point the soft-particle sampler at the resolved depth while the particles themselves still draw into the MS target.

3. **Panel toggle.** microui combo/buttons for 0/2/4/8× that destroys and recreates the MS target (clamp to `gl.GetIntegerv(gl.MAX_SAMPLES, ...)`). Watch the ch49 GPU timer for the scene pass as you switch — that bandwidth bill is the lesson.

4. **Luma for FXAA.** In `tonemap.frag`, after gamma, write luma to alpha:

   ```glsl
   frag = vec4(c, dot(c, vec3(0.299, 0.587, 0.114)));
   ```

   Tonemap must now render into a new RGBA8 LDR target (`r.ldr`) instead of the backbuffer when FXAA is enabled.

5. **Integrate FXAA 3.11.** Download the canonical `Fxaa3_11.h` — Lottes's original from the NVIDIA Graphics SDK, GLSL-compatible and widely mirrored on GitHub (search `Fxaa3_11.h`; verify you got version 3.11 from the header comment). Save as `assets/shaders/fxaa3_11.glsl`, then write the wrapper pass:

   ```glsl
   #version 430 core
   #define FXAA_PC 1
   #define FXAA_GLSL_130 1
   #define FXAA_QUALITY__PRESET 29
   #include "fxaa3_11.glsl"      // your ch47 expander resolves this

   uniform sampler2D u_image;     // LDR, luma in alpha
   uniform vec2 u_rcp_frame;      // 1.0 / resolution
   in vec2 v_uv;
   out vec4 frag;

   void main() {
       frag = FxaaPixelShader(v_uv, vec4(0), u_image, u_image, u_image,
           u_rcp_frame, vec4(0), vec4(0), vec4(0),
           0.75,    // subpix: amount of sub-pixel aliasing removal
           0.166,   // edgeThreshold: min local contrast to bother
           0.0833,  // edgeThresholdMin: dark-area cutoff
           0.0, 0.0, 0.0, vec4(0));
   }
   ```

   The unused parameters are console-path leftovers — the price of canonical code. The three knobs that matter: `subpix` (higher = smoother but blurrier), `edgeThreshold` (lower = more edges processed), `edgeThresholdMin` (raises the floor so night scenes aren't all "edge").

6. **Order the tail of the frame.** … bloom → tonemap(+grading, +luma) → **FXAA** → text/UI. UI after FXAA, always — crisp glyphs are not aliasing to be fixed. Add the FXAA toggle + GPU ms to the panel.

7. **Stand at the mast and compare.** Sun behind the rigging, camera gently bobbing. Cycle: nothing / 4× MSAA / FXAA / both. MSAA: ropes still flicker where they're subpixel (no sample count saves a half-pixel rope, though 8× helps), silhouettes clean, glitter unchanged. FXAA: silhouettes and glitter both calmer, tiny texture detail slightly softened.

## Checkpoint

A panel section reads like: `msaa 4x: scene 6.8ms (was 4.1)` and `fxaa: 0.18ms`. Toggling either visibly changes the rigging.

- With MSAA 4×, zoom a screenshot of the mast edge: up to 4 intensity steps across the silhouette instead of on/off.
- With only FXAA, the wave-glitter sparkle is noticeably tamer — confirming it treats shading alias, which MSAA provably (toggle it) does not.
- MSAA off→8× changes scene-pass GPU ms substantially; FXAA cost is flat regardless of scene.
- RenderDoc: the resolve blit appears between scene and bloom; the MS texture shows per-sample inspection in the Texture Viewer (sample dropdown).

## Pitfalls

- **`GL_INVALID_OPERATION` on the blit.** Multisampled blits demand identical src/dst rectangles, and depth blits demand `gl.NEAREST`. Also both MS attachments must have the *same* sample count — color at 4× with depth at 8× fails completeness earlier (`FRAMEBUFFER_INCOMPLETE_MULTISAMPLE`).
- **Black screen with MSAA on.** Something still samples the MS color texture with `texture()` — e.g. your soft-particle or bloom pass grabbed `hdr_ms.color_tex` instead of the resolved `hdr.color_tex`. The ch53 debug callback names this loudly.
- **MSAA "on" but nothing changes.** You created the MS target but `renderer_begin_hdr` still binds the old FBO, or samples=0 path. Check Pipeline State FB tab in RenderDoc: does the scene draw target say MS?
- **FXAA does nothing.** Luma isn't in alpha (step 4), or you fed it the *HDR* buffer — FXAA's thresholds assume 0–1 perceptual values. It runs after tonemap, period.
- **Text and HUD look smeared.** UI is drawn before FXAA. Move it after; same fix for the photo-mode grain if you added it in ch51.
- **Window resize crashes or misrenders.** The MS target, LDR target, and `u_rcp_frame` all need the resize treatment from ch40 step 7.

## Exercises

1. Add a debug zoom magnifier (sample a 32×32 region, draw it 8× on the HUD) to compare AA modes without squinting.
2. Implement "show me the edges": a debug FXAA mode outputting red where edge contrast exceeds threshold. Watch what it considers an edge during a storm — and tune `edgeThresholdMin` for night sails.
3. Roughness-clamp the glitter: shading alias also yields to *shading* fixes. Increase ocean roughness with distance (a cheap stand-in for LEAN/Toksvig mapping — look them up) and watch far glitter calm down with AA off entirely.
4. **Stretch:** per-sample tonemapped resolve — write a `sampler2DMS` fullscreen pass that `texelFetch`es all N samples, tonemaps each, averages, and outputs LDR directly. Compare the sun-on-mast edge against blit-resolve-then-tonemap. (You're reimplementing what the blit did, but *correctly* for HDR.)

## Commit

`git commit -m "ch54: MSAA on the HDR target with resolve blit, FXAA 3.11 post pass, AA toggles"`

[← Ch. 53: Seeing Like the GPU](ch53-seeing-like-the-gpu.md) · [Ch. 55: The Deferred Fleet →](ch55-the-deferred-fleet.md)

> ⚓ **Optional side quest:** [Interlude 54a — Ghosts & How to Bust Them](ch54a-ghosts-and-how-to-bust-them.md) — build the full TAA this chapter only surveyed: Halton jitter, a velocity buffer, history reprojection, and the neighborhood clamp that busts the ghosts.
