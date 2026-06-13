# Interlude 54a — Ghosts & How to Bust Them

*⚓ Optional interlude · slots after [Chapter 54](ch54-smooth-sailing-edges.md) · Estimated time: 6–8h · learnopengl: no direct equivalent — canonical references: [Karis, "High Quality Temporal Supersampling" (SIGGRAPH 2014)](https://advances.realtimerendering.com/s2014/) and [Pedersen, "Temporal Reprojection Anti-Aliasing in INSIDE" (GDC 2016)](https://www.gdcvault.com/play/1022970/Temporal-Reprojection-Anti-Aliasing-in)*

**Prerequisites:** Chapter 54 (the AA toggles and LDR plumbing) and ch49's GPU timers. · **Required downstream:** none — skip freely. One note: [Interlude 59a](ch59a-the-physical-lens.md)'s per-object motion blur consumes the velocity buffer you build here; it ships a camera-only fallback if you skip.

**What you'll see when done:** the rigging holds rock-steady at sub-pixel thickness and the wave glitter stops seething — TAA running for real, with a debug key that shows you the ghosts you defeated.

## Why this is a side quest

Chapter 54 surveyed TAA and moved on, because the main line needed the *concept*, not the three days of plumbing. The plumbing is real: a velocity buffer means previous-frame matrices threaded through every moving thing, and the failure modes (ghosting, flicker, smear) are a genuinely adversarial debugging experience. But TAA is also the AA that modern games actually ship, the only one that fixes *shading* alias as well as edges, and the velocity buffer you build is reusable infrastructure (59a's motion blur eats it whole). If you've ever wanted to understand why every modern game has a "ghosting" complaint thread, this is the chapter where you earn the opinion.

## Concepts

### The idea, restated precisely

Supersampling works by taking many samples per pixel. TAA takes them — but **one per frame**, in different sub-pixel spots, and accumulates the results over time. Three mechanisms make that possible:

1. **Jitter.** Offset the projection by a different sub-pixel amount each frame, so the rasterizer samples a different position inside every pixel. Over 8 frames you've sampled 8 spots — supersampling on layaway.
2. **Reprojection.** The camera moved since last frame, so last frame's accumulated image is in the wrong place. A **velocity buffer** stores, per pixel, where this surface was on screen last frame; subtracting it from the current uv finds the pixel's history.
3. **Rectification.** Sometimes the history is *wrong* — the surface was hidden last frame (disocclusion), or lighting changed. Blindly blending wrong history is **ghosting**: trailing afterimages behind the boat. The fix is **neighborhood clamping**: history is only allowed to be a color that's plausible *this* frame.

The accumulation itself is an exponential moving average — `result = mix(history, current, 0.1)` — so each pixel is effectively the last ~10–20 frames of samples, which is why TAA output looks so eerily calm.

### Velocity: where was this pixel last frame?

For a static world point, its screen position is a pure function of the camera: `clip = P·V·world`. Store last frame's `P·V`, compute both, subtract:

```
velocity.uv = (curr_ndc.xy − prev_ndc.xy) * 0.5      // ndc → uv scale
```

For a **dynamic object** (boat, gulls, swinging lanterns) the model matrix moved too — so every dynamic object must keep `prev_model` and the velocity math becomes `P·V·M` vs `P_prev·V_prev·M_prev`. Two non-negotiable rules: velocity is computed with **unjittered** matrices (jitter is a sampling trick, not motion), and `prev_*` matrices are snapshotted **once per frame**, after rendering — not per draw.

**The ocean compromise.** Gerstner displacement moves every vertex every frame, so honest ocean velocity needs the wave function evaluated at both `t` and `t−dt`. We won't, for now: the displacement is mostly vertical (small screen-space velocity at typical viewing angles), and the surface is self-similar enough that clamping catches the rest. So: treat the ocean as static (camera reprojection only) and let the resolve use a **larger blend factor** (more current frame, less history) on ocean pixels, flagged via the velocity buffer's spare channel. Less accumulation means less AA benefit on water — that's the honest price, and the glitter calming *at all* still beats ch54's options. Exercise 3 buys back the truth.

### Neighborhood clamping — the ghostbuster

Sample the 3×3 neighborhood of the *current* frame around each pixel; take the min and max per channel; clamp the history color into that AABB. If the boat moved and the history pixel still holds boat-brown but the neighborhood is now all sea-blue, the clamp drags it to blue — ghost busted in one frame instead of twenty. This single heuristic is most of what separates shippable TAA from a smear generator. Disocclusions need no special detection: their history is wrong, the clamp catches it, and the cost is one frame of slightly-wrong color.

> **Sidebar — why YCoCg.** Clamping an RGB box is loose: many wrong colors fit inside it. Production TAA converts to **YCoCg** (luma + two chroma axes, a cheap reversible transform: `Y = (r+2g+b)/4, Co = (r−b)/2, Cg = (g − (r+b)/2)/2`) where natural neighborhoods are tighter boxes, so bad history gets clamped harder with less desaturation. Build RGB first — upgrade after it works; the difference shows on the orange-sail-against-blue-sky edge.

### The trade triangle

Every TAA knob trades between three corners — you cannot win all three:

```
        ghosting (history trusted too much)
            ▲
           ╱ ╲        blend ↓, clamp tight  → flicker returns
          ╱   ╲       blend ↑, clamp loose  → ghosts return
         ╱     ╲      everything in between → blur
        ▼───────▼
   flicker        blur
 (history       (history resampled
  rejected)      too softly)
```

Blur deserves its own note: sampling history at a reprojected (fractional) uv with bilinear filtering loses a little sharpness *every frame*, compounding. The standard fixes are a **Catmull-Rom (bicubic) history fetch** (~5 bilinear taps, exercise 2) and a mild **sharpen after the resolve** — we do the cheap sharpen today and note the bicubic. After this chapter, when a game's options menu offers "TAA sharpening," you'll know exactly which corner of the triangle it's patching.

## Odin notes

The Halton low-discrepancy sequence is ten lines, and `frame_index` lives on the `Renderer`:

```odin
halton :: proc(index, base: int) -> f32 {
    f, r, i := f32(1), f32(0), index
    for i > 0 {
        f /= f32(base)
        r += f * f32(i % base)
        i /= base
    }
    return r
}

taa_jitter :: proc(frame: int) -> glsl.vec2 {   // in [-0.5, 0.5] pixels
    i := frame % 8 + 1                          // skip index 0 (returns 0,0)
    return {halton(i, 2) - 0.5, halton(i, 3) - 0.5}
}
```

Injecting it: a clip-space translation by `t` adds `t·w` to clip x/y, which after the perspective divide is exactly `+t` in NDC — so the jittered projection is one multiply, no element surgery:

```odin
j := taa_jitter(r.frame_index)
ndc_offset := glsl.vec2{2 * j.x / f32(w), 2 * j.y / f32(h)}
proj_jittered := glsl.mat4Translate({ndc_offset.x, ndc_offset.y, 0}) * proj
```

Keep both `proj` and `proj_jittered` on the renderer: rasterization uses jittered, velocity and reprojection use clean.

## Build

1. **Previous-frame state.** On `Renderer`: `prev_view_proj: glsl.mat4`, `frame_index: int`. On every dynamic entity's render data: `prev_model: glsl.mat4`. At end-of-frame (one proc, called once): copy `view_proj → prev_view_proj`, each `model → prev_model`, `frame_index += 1`. First frame: initialize prev = current, or frame one smears spectacularly.

2. **The velocity target.** An `RG16F` texture (`r.velocity`), full res, plus a small `velocity_camera.frag` fullscreen pass that handles *everything static* by reprojecting depth — no scene shaders touched:

   ```glsl
   float d = texture(u_depth, v_uv).r;
   vec4 world = world_from_depth(v_uv, d);          // ch55's reconstruction (or inverse VP at ch54 stage)
   vec4 prev_clip = u_prev_view_proj * world;
   vec2 prev_ndc = prev_clip.xy / prev_clip.w;
   velocity = vec2((v_uv * 2.0 - 1.0) - prev_ndc) * 0.5;
   ```

   Then re-draw **dynamic objects only** into the same target with a thin velocity shader (vertex: current and previous clip positions through `u_vp`/`u_prev_vp` and `u_model`/`u_prev_model`; fragment: the subtraction), depth test `LEQUAL` against the scene depth, depth writes off. A handful of draws. Tag ocean pixels by writing, say, `velocity` with a flag in a spare way you choose (or test `material` later) — simplest: run the camera pass *after* the ocean using its depth, and mark ocean via a third small pass or just accept the global compromise; we use a half-blend on everything whose neighborhood variance is high (see step 5's note).

3. **Jitter on.** Use `proj_jittered` for every scene draw (G-buffer-era note: when you reach ch55, the geometry pass takes the jittered matrix and nothing else changes). With TAA *off*, pass zero jitter. Toggle jitter alone in the panel first: the whole screen should vibrate sub-pixel — ugly alone, raw material for the resolve. MSAA and TAA are mutually exclusive in our pipeline; the panel enforces one of `Off / MSAA / FXAA / TAA`.

4. **History ping-pong.** Two RGBA16F targets (`taa_history[2]`). The resolve pass reads `current HDR + velocity + history[read]`, writes `history[write]`, and the rest of the post stack (bloom onward) consumes `history[write]`. Swap indices each frame. TAA lives in **linear HDR, before bloom** — bloom from an unstabilized source flickers, which defeats the point.

5. **The resolve shader.** The heart, ~40 lines:

   ```glsl
   vec2 vel = texture(u_velocity, v_uv).rg;
   vec2 prev_uv = v_uv - vel;
   vec3 curr = texelFetch(u_current, ivec2(gl_FragCoord.xy), 0).rgb;

   vec3 mn = vec3(1e9), mx = vec3(-1e9);
   for (int y = -1; y <= 1; y++)
   for (int x = -1; x <= 1; x++) {
       vec3 c = texelFetch(u_current, ivec2(gl_FragCoord.xy) + ivec2(x, y), 0).rgb;
       mn = min(mn, c); mx = max(mx, c);
   }
   vec3 hist = texture(u_history, prev_uv).rgb;      // bilinear; bicubic is exercise 2
   hist = clamp(hist, mn, mx);                       // the ghostbuster

   float blend = u_blend;                            // 0.1 to start
   if (any(lessThan(prev_uv, vec2(0))) || any(greaterThan(prev_uv, vec2(1))))
       blend = 1.0;                                  // off-screen history: trust nothing
   frag = vec4(mix(hist, curr, blend), 1.0);
   ```

   For the ocean compromise, raise `blend` toward ~0.25 where the neighborhood luma range is large (animated water) — one `smoothstep` on `(luma(mx)-luma(mn))`, doubling as flicker control for fireflies.

6. **Sharpen after.** In `tonemap.frag` (or a tiny pass before it), a gentle unsharp: `c = c + (c - blur4(c)) * u_taa_sharpness` with strength ~0.25, enabled only when TAA is. This pays back the bilinear-history softness.

7. **Stand at the mast again.** The ch54 step-7 comparison, now with a fourth contender. Rigging: steady and *complete* (sub-pixel ropes accumulate into existence — something MSAA never managed). Glitter: calm. Now sail hard and stare behind the boat: with the clamp commented out, brown ghosts trail the hull; with it on, they die in a frame. Bind a debug key to that toggle — watching the clamp work is the lesson of the chapter.

## Checkpoint

The panel shows `taa: 0.4ms` (resolve + velocity), and the mast scene is the stillest it has ever been.

- Freeze the camera: the image visibly *converges* over ~10 frames (jagged → smooth). That's accumulation working.
- Hard turn: no smearing of the islands (camera reprojection working); the boat doesn't ghost against the sky (clamp working); HUD text is untouched (UI still drawn after — same law as FXAA).
- Toggle jitter with TAA off: vibration. Toggle TAA on: stillness *plus* the extra edge quality jitter bought.
- RenderDoc: velocity buffer is near-zero when still, paints the boat during a turn, and the resolve ping-pongs between two history textures.

## Pitfalls

- **Everything smears like a dream sequence.** Velocity sign error (`prev_uv = v_uv + vel`), or `prev_view_proj` never updated, or updated *before* the frame instead of after. Visualize `vel * 50 + 0.5` as color; still camera must be flat gray.
- **The image vibrates with TAA on.** You jittered, but the resolve isn't running (history not wired), or velocity was computed with the *jittered* matrices so reprojection chases the jitter. Clean matrices for velocity, always.
- **Boat ghosts, world doesn't.** `prev_model` missing or never snapshotted — the dynamic-object velocity draw silently used identity. Each moving thing needs its own previous transform.
- **Thin ropes flicker worse than before.** Blend factor too high or clamp box too tight (a sub-pixel rope's neighborhood may not contain rope at all). Lower `u_blend` toward 0.05 for the test; accept the trade triangle's terms — and the YCoCg sidebar buys slack.
- **Sky pixels drag streaks at the horizon.** Depth = 1.0 reprojects to garbage through the inverse. Special-case sky: zero velocity (it's at infinity; camera *rotation* still moves it — reconstruct with the rotation-only matrix if you see it).
- **First frame after a teleport / quality change explodes.** History is stale; reset it (`blend = 1` for one frame via a `history_valid` flag). Same flag belongs on resolution changes.

## Exercises

1. **Flicker fight:** weight current/history by inverse luminance (Karis): `w = 1/(1+luma)` on each before the mix, renormalize after. Watch the sun-glint fireflies stop strobing — this plus the clamp is most of "production TAA."
2. **Catmull-Rom history sampling:** replace the bilinear history fetch with the 5-tap bicubic (the INSIDE talk has the exact weights). A/B after 5 seconds of sailing — the texture detail you stopped losing is obvious on the deck planks.
3. **Honest ocean velocity:** in the velocity pass, evaluate the Gerstner displacement at `u_time` and `u_time - u_dt` for the reconstructed surface point and add the difference's screen-space projection. Restore the ocean's blend factor to normal and compare glitter stability.
4. **Stretch — TAAU:** render the scene at 0.75 scale (jittered), resolve into a *full-resolution* history with the same machinery (the jitter now also fills in spatial information). You've built temporal upscaling — Chapter 85 tells you where that road leads.

## Commit

`git commit -m "ch54a: TAA - halton jitter, velocity buffer, history reprojection, neighborhood clamp, sharpen"`

[← back to Ch. 54: Smooth Sailing Edges](ch54-smooth-sailing-edges.md) · [onward to Ch. 55: The Deferred Fleet →](ch55-the-deferred-fleet.md)
