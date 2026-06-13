# Chapter 85 — The Resolution Illusion

*Part 13 — The Captain's Appendices · Standalone: requires Part 7 (HDR pipeline) · Estimated time: 4h · learnopengl: no direct equivalent — canonical reference: [AMD FidelityFX-FSR on GitHub](https://github.com/GPUOpen-Effects/FidelityFX-FSR)*

**What you'll see when done:** Saltwind at 67% render scale looking 95% as sharp as native — with the scene pass timer cut nearly in half and the HUD text still pixel-perfect.

## Where we are

This appendix needs Chapter 40's `Renderer` (the HDR target and the fullscreen tonemap pass) and is happiest if you also have Chapter 49's per-pass GPU timers, because the whole chapter is an economics lesson and timers are how you count the money. If you've done Part 9, the deferred targets scale along for free; if you haven't, everything here works on the ch40 pipeline alone.

Why this question always comes up: every settings menu in every modern game has a "render scale" slider and a dropdown that says DLSS / FSR / XeSS / TAAU, and every graphics learner eventually asks *what are those actually doing, and can I have one?* The answer is in three parts — one you can build in an hour, one you can build in an evening, and one you should understand but probably not build — and this chapter is honest about which is which.

## Concepts

### The economics: shading cost is pixel count

Almost everything expensive in your frame — the ocean fragment shader, PBR, SSR, god rays, bloom — costs *per pixel shaded*. Vertex work and CPU work don't care about resolution; fragment work scales linearly with it. So the single biggest performance dial in real-time rendering is embarrassingly simple: **shade fewer pixels, then stretch the result.**

Render scale `s` scales *both* axes, so pixel count scales with `s²`:

| `render_scale` | pixels shaded | typical name |
|---|---|---|
| 1.00 | 100% | native |
| 0.77 | ~59% | "quality" |
| 0.67 | ~44% | "balanced" |
| 0.59 | ~35% | "performance" |
| 0.50 | 25% | "ultra performance" |

Those odd-looking ratios are the actual presets FSR and DLSS use. At 0.67 you shade well under half the pixels — if your frame is fragment-bound (sail at the ocean and check your ch49 panel; it is), the scene pass cost drops nearly proportionally.

### The illusion has one rule: never upscale the UI

The 3D scene survives upscaling because it's photographic content — soft gradients, no hard reference for the eye. Text and HUD lines do not survive: a 1px compass tick bilinearly stretched by 1.5× becomes a smeared gray nothing, and every player notices instantly. So the pipeline is always:

```
 scene passes              tonemap + upscale          UI pass
 (scale s, HDR)            (to NATIVE backbuffer)     (NATIVE)
 ┌──────────────┐          ┌──────────────────┐       ┌─────────┐
 │ 0.67w × 0.67h│ ───────> │   w × h          │ ────> │ w × h   │
 └──────────────┘  sample  └──────────────────┘  over └─────────┘
```

Render the world small, upscale it, **then** draw microui, the compass, and the HUD at full native resolution on top. The UI must never pass through the upscaler. This rule is worth stating twice because every first implementation gets it wrong: *the UI must never pass through the upscaler.* Your ch48 UI already draws after `renderer_end_hdr`, which means your architecture is accidentally perfect — you only have to *not break it*.

### Free bilinear: the tonemap pass is already an upscaler

Look at what `renderer_end_hdr` does: it binds the default framebuffer, sets the viewport, and samples `hdr.color_tex` with `LINEAR` filtering. If the HDR texture happens to be *smaller* than the window, that `texture()` call bilinearly interpolates — which is exactly a bilinear upscale. You don't add an upscaling pass today; you discover you already had one.

### Better than bilinear: what FSR1 actually does

Bilinear is a 2×2 average — it has no idea where edges are, so it blurs across them. AMD's **FidelityFX Super Resolution 1.0** is the best-known *spatial* (single-frame) upgrade, and it's two stages:

- **EASU** (Edge-Adaptive Spatial Upsampling): a 12-tap reconstruction that analyzes local luma gradients to find the direction and strength of the nearest edge, then stretches its sampling kernel *along* the edge instead of across it. Edges stay edges; the blur goes where the eye can't see it.
- **RCAS** (Robust Contrast-Adaptive Sharpening): a sharpening pass that measures how much local contrast headroom exists at each pixel and sharpens *up to* that limit, so it never produces the halos a naive unsharp mask does.

The full shaders are public and MIT-licensed in [AMD's FidelityFX-FSR repository](https://github.com/GPUOpen-Effects/FidelityFX-FSR) — portable single-header GLSL/HLSL, designed to be dropped into anybody's engine, including an OpenGL one. We will not retype 2000 lines of AMD's micro-optimized code here; we'll build a simplified edge-aware upscale and a faithful CAS-style sharpener so you understand every knob, and then you can swap in the production shaders if you want the last few percent. The integration knobs that matter more than the shader internals:

1. **Placement:** FSR1 wants *tonemapped, gamma-encoded, low-noise* input. Run it after tonemap, before film grain (ch51) and UI. Grain and UI go on top at native.
2. **Negative mip bias:** texture sampling at 0.67 scale picks mips for 0.67 screen density, so surfaces go slightly soft. Production integrations apply `gl.TexParameterf(gl.TEXTURE_2D, gl.TEXTURE_LOD_BIAS, log2(s))` (a negative number) to material textures to compensate.
3. **Sharpness** is a user setting. Ship the slider.

### The temporal story, honestly

Spatial upscalers reconstruct from one frame, so they cannot invent detail that was never sampled. **Temporal** upscalers can, because across frames the camera jitters sub-pixel and the same surface gets sampled at slightly different positions — over a few frames you've *actually rendered* the missing information; you just have to find it again. The machinery, in concept:

- **Jitter:** offset the projection matrix by a sub-pixel amount each frame (a Halton sequence), so low-res samples land in different spots within each native pixel.
- **Motion vectors:** every pixel renders its screen-space velocity (current clip position minus last frame's, needs the previous frame's MVP per object). This tells the upscaler where each pixel *was*, so history can be fetched from the right place while everything moves.
- **History accumulation:** keep last frame's upscaled output; reproject it through the motion vectors; blend a little of the new frame into it. Detail accumulates over ~8–16 frames.
- **Rejection heuristics:** the hard 90%. When history is wrong — disocclusion, lighting change, transparency, your animated ocean — blindly blending produces *ghosting*. So you clamp history to the neighborhood of current-frame colors, compare depths, detect disocclusions, and fall back to spatial upscaling where trust fails.

That ladder, in increasing sophistication: **TAAU** (TAA with upscaling — the rejection heuristics are yours to hand-tune, and you will spend a month at war with ghosting), **FSR 2/3** (AMD's hand-written heuristics, refined by a team for years, open source), and **DLSS / XeSS** (the rejection-and-reconstruction logic *learned* by a neural network from offline-rendered ground truth, executed on dedicated tensor/matrix hardware — NVIDIA's tensor cores, Intel's XMX units). The learned versions win because history rejection is exactly the kind of fuzzy, perceptual decision networks are good at.

### Why you can't have DLSS (and what you can have)

NVIDIA ships DLSS as a closed SDK with integration hooks for **Direct3D 11/12 and Vulkan only**. There is no OpenGL hook; as of this writing none has ever been announced, and the architecture makes a community shim impractical (the SDK needs to inject its own GPU work and resources into your API's command stream). The same platform story applies to FSR 2/3's *official* SDK backends, though FSR's shaders are open source, so determined people have ported them to GL — the integration cost (motion vectors everywhere, jitter, reactive masks) is the real price, not the API.

So the honest OpenGL menu, the one you can actually ship — and it's a respectable one:

- **Render scale + edge-aware spatial upscale + CAS sharpening** (this chapter) — FSR1-class results.
- **MSAA or FXAA at native** (ch54) when you have the budget for native.
- **Both:** render scale for the heavy scenes, AA on top.

> **Sidebar: frame generation.** DLSS 3 and FSR 3 added *frame interpolation*: render frames N and N+1, synthesize a fake frame between them from motion vectors and optical flow, and present it in the middle. It doubles displayed FPS but adds latency — the real frame N+1 must finish before the fake one shows, and your input only affects real frames. That's why competitive players argue about it and why both vendors pair it with latency-reduction tech (Reflex, Anti-Lag). It's a *smoothness* technology, not a *responsiveness* one. Know the distinction and you understand the entire argument.

## Odin notes

Recreating five render targets on a slider change is the same destroy-then-create dance as your window-resize callback — factor both through one `renderer_recreate_targets(r)` so scale changes and resizes can't diverge. Two small sharp edges: compute scaled sizes from the *native* size each time (never scale the already-scaled size, or repeated slider moves compound), and `max(..., 1)` the result — a minimized window times 0.5 is a zero-size texture and an incomplete FBO. The mip-bias helper is one call, `gl.TexParameterf(gl.TEXTURE_2D, gl.TEXTURE_LOD_BIAS, bias)`, applied per-texture while it's bound; stash the bias in your texture struct so hot-reloaded textures reapply it.

## Build

1. **Add the setting.** In `Renderer`:

   ```odin
   Renderer :: struct {
       // ... ch40 fields ...
       render_scale: f32, // 0.5 .. 1.0
       native_w, native_h: i32,
   }

   renderer_scaled_size :: proc(r: ^Renderer) -> (w, h: i32) {
       w = max(i32(f32(r.native_w) * r.render_scale), 1)
       h = max(i32(f32(r.native_h) * r.render_scale), 1)
       return
   }
   ```

   Everywhere you create or resize the scene-resolution targets (the HDR target; bloom chain, G-buffer, SSR/SSAO targets if you have Part 9), use `renderer_scaled_size` instead of the window size. Resize-on-change: a `renderer_set_scale` that destroys and recreates them, exactly like your window-resize callback.

2. **Audit the viewports.** Every scene pass must `gl.Viewport(0, 0, scaled_w, scaled_h)`; the tonemap pass and everything after it must `gl.Viewport(0, 0, native_w, native_h)`. Your ch40 `renderer_begin_hdr` already sets the viewport from the target — verify each pass does, then verify the tonemap resets to native. This audit *is* the implementation; the bilinear upscale happens by itself when the `LINEAR`-filtered HDR texture is sampled across the bigger viewport.

3. **Protect the UI.** Confirm microui, HUD, and ch51 grain draw after `renderer_end_hdr`, to the default framebuffer, at native viewport. Set `render_scale = 0.5` and look at the compass: if the text is crisp while the sea is soft, you've done it right. If the text is soft, something UI-shaped is rendering inside the HDR pass — evict it.

4. **Bind keys and measure.** `-`/`=` to step `render_scale` by 0.05 (clamp 0.5–1.0), value on the debug panel next to the ch49 timers. Sail somewhere fragment-heavy (open ocean, sun low, SSR on) and record the scene-pass GPU time at 1.0, 0.77, 0.67, 0.5. Plot it mentally against the s² column above — it should track within a few percent, and the gap between them is your *non-fragment* cost. This one measurement teaches more about your frame than anything since ch49.

5. **Insert an LDR intermediate for the better upscaler.** For Build 2 the tonemap can no longer write straight to the screen. Add a low-res `RGBA8` target (`ldr`, sized like the HDR target). When upscale mode is on: tonemap renders into `ldr` (scaled viewport), then the new upscale pass samples `ldr` and writes to the backbuffer (native viewport). UI still last, still native.

6. **Edge-aware upscale, `assets/shaders/upscale_easu_lite.frag`.** The simplified version of EASU's idea — detect the local diagonal and interpolate along it:

   ```glsl
   uniform sampler2D u_src;       // low-res LDR
   uniform vec2 u_src_size;       // in texels
   in vec2 v_uv; out vec4 frag;
   float luma(vec3 c) { return dot(c, vec3(0.299, 0.587, 0.114)); }

   void main() {
       vec2 p  = v_uv * u_src_size - 0.5;
       vec2 f  = fract(p);
       ivec2 i = ivec2(floor(p));
       vec3 tl = texelFetch(u_src, i,               0).rgb;
       vec3 tr = texelFetch(u_src, i + ivec2(1, 0), 0).rgb;
       vec3 bl = texelFetch(u_src, i + ivec2(0, 1), 0).rgb;
       vec3 br = texelFetch(u_src, i + ivec2(1, 1), 0).rgb;
       float d1 = abs(luma(tl) - luma(br));   // contrast across ↘ diagonal
       float d2 = abs(luma(tr) - luma(bl));   // contrast across ↙ diagonal
       // edge runs along the LOW-contrast diagonal: bias interpolation onto it
       float w = clamp((d2 - d1) * 4.0, -1.0, 1.0) * 0.25;
       vec3 a = mix(tl, tr, clamp(f.x + w * (f.y - 0.5) * 2.0, 0.0, 1.0));
       vec3 b = mix(bl, br, clamp(f.x - w * (f.y - 0.5) * 2.0, 0.0, 1.0));
       frag = vec4(mix(a, b, f.y), 1.0);
   }
   ```

   Real EASU uses 12 taps and a proper directional lanczos kernel; this 4-tap version captures the *decision* (which way does the edge run?) and visibly cleans 45° edges — rigging shrouds, island silhouettes. Toggle it against plain bilinear with a key.

7. **CAS-style sharpen, `assets/shaders/sharpen_cas.frag`** — a faithful miniature of AMD's contrast-adaptive idea, run at native after the upscale (ping-pong via one native RGBA8 target, or fold it into the upscale shader):

   ```glsl
   uniform sampler2D u_src; uniform float u_sharpness; // 0..1
   in vec2 v_uv; out vec4 frag;
   void main() {
       vec3 c = texture(u_src, v_uv).rgb;
       vec3 n = textureOffset(u_src, v_uv, ivec2( 0,-1)).rgb;
       vec3 s = textureOffset(u_src, v_uv, ivec2( 0, 1)).rgb;
       vec3 w = textureOffset(u_src, v_uv, ivec2(-1, 0)).rgb;
       vec3 e = textureOffset(u_src, v_uv, ivec2( 1, 0)).rgb;
       vec3 mn = min(c, min(min(n, s), min(w, e)));
       vec3 mx = max(c, max(max(n, s), max(w, e)));
       // contrast headroom: how far can we sharpen before clipping?
       vec3 amp = sqrt(clamp(min(mn, 1.0 - mx) / max(mx, 1e-4), 0.0, 1.0));
       vec3 wgt = amp * -mix(0.06, 0.18, u_sharpness);     // negative ring weight
       frag = vec4((c + (n + s + w + e) * wgt) / (1.0 + 4.0 * wgt), 1.0);
   }
   ```

   The `amp` term is the whole trick: flat areas (no headroom worth using) and already-clipping edges get little sharpening; mid-contrast detail gets the most. That's why it doesn't halo like a naive kernel. RCAS adds noise-aware damping and faster approximate math on top — same skeleton.

8. **Wire the mode switch.** `upscale_mode: enum { Bilinear, Edge_Aware, Edge_Aware_Sharp }` on `Renderer`, a debug-panel selector, and the sharpness slider. Final order, recite it: scene (scaled) → tonemap → upscale → sharpen → grain → UI (native).

## Checkpoint

At `render_scale = 0.67`, toggle through the three modes while anchored near an island with rigging against the sky: bilinear is soft, edge-aware firms the diagonals, sharpen brings back the "native feel" on terrain texture. Then:

- Scene-pass GPU time at 0.67 is roughly 45–55% of native (fragment-bound scenes track s²).
- HUD text identical at every scale — zoom a screenshot to prove it.
- At 0.5 + sharpening, screenshots are honestly "good enough to play"; at 0.77, most people can't tell without A/B flipping.
- Resizing the window keeps everything consistent (native sizes update, scaled targets recreate).

## Pitfalls

- **UI is blurry.** It's being drawn inside the scaled pass, or your upscale pass runs after the UI. The order is law: upscale first, UI last. (Second statement of the rule, as promised.)
- **Image looks vaseline-smeared beyond what scale explains.** Mip bias — your textures are mipping for low-res density. Apply the `log2(s)` LOD bias from Concepts, or accept softness at scales above ~0.7 where it's minor.
- **One pass renders at the wrong size** (classic symptoms: bloom misaligned, SSR a quarter-screen). A pass missed the viewport audit or still allocates from `native_w`. Grep every `gl.Viewport` and every target creation.
- **Sharpening crawls/shimmers on the ocean.** Too much sharpness on subpixel wave detail. Drop `u_sharpness`, or mask the sharpen by depth so the distant sea gets less.
- **`texelFetch` out-of-bounds black border at the right/bottom edge.** Clamp `i` to `u_src_size - 2` before fetching the 2×2 quad.
- **Performance didn't improve.** You're not fragment-bound (small window, simple scene) — or the scaled targets quietly weren't recreated and you've been A/B-testing identical images. Check the timer *and* the texture sizes in RenderDoc.

## Exercises

1. Ship it: add Quality/Balanced/Performance presets (0.77/0.67/0.59) plus the sharpness slider to your ch81 settings menu, persisted in the ch80 settings file.
2. Implement the negative mip bias properly: a `texture_set_lod_bias` helper applied to material textures (not UI, not LUTs), updated when `render_scale` changes. Compare distant terrain crispness at 0.67.
3. Replace the EASU-lite shader with AMD's real `ffx_fsr1.h` EASU+RCAS, ported to GLSL 430 (the header is designed for this — it's mostly `#define`s away). Compare against your version: where does the 12-tap kernel visibly win?
4. **Stretch — dynamic resolution.** Every 30 frames, read the scene-pass GPU timer: above 90% of frame budget → step `render_scale` down 0.05; below 60% → step up. Two refinements that make it production-grade: hysteresis (different up/down thresholds so it doesn't oscillate), and avoiding the realloc hitch by allocating targets at native size once and rendering into a scaled corner viewport, adjusting the tonemap UVs to match. Sail into a storm and watch the slider drive itself.

## Commit

`git commit -m "ch85: render scale + edge-aware upscale + CAS sharpen, UI at native"`

[← Course overview](../00-COURSE-OVERVIEW.md) · [Ch. 86: Postcards from Another Renderer →](ch86-postcards-from-another-renderer.md)
