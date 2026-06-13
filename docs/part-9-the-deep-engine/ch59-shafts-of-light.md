# Chapter 59 — Shafts of Light

*Part 9 — The Deep Engine · Estimated time: 6–8h · learnopengl: no direct equivalent — canonical references: [Mitchell, "Volumetric Light Scattering as a Post-Process"](https://developer.nvidia.com/gpugems/gpugems3/part-ii-light-and-shadows/chapter-13-volumetric-light-scattering-post-process) (GPU Gems 3, ch. 13) and [Wronski, "Volumetric Fog" (SIGGRAPH 2014)](https://bartwronski.com/publications/)*

**What you'll see when done:** the sun breaking past the island's headland throws visible shafts of light through the haze, and the mast cuts a moving shadow through the air itself.

## Where we are

Your ch47 fog says light scatters in the air; your renderer has never shown the *consequence*: where something blocks the sun, the air behind it should be visibly darker — god rays, crepuscular rays, the cathedral-light of every sailing painting ever. You'll build this twice. First the **screen-space radial blur** — twenty lines, almost free, breathtaking at sunset, and honest about being a trick. Then the real thing: **raymarching the fog volume against your new cascaded shadow maps**, which works from any angle because it's actual (single-scattering) physics. Ch57 wasn't just about shadows on *surfaces* — it was the prerequisite for shadows in *air*.

## Concepts

### Build A — radial blur: light as an image effect

Mitchell's GPU Gems 3 technique: in image space, light streaming from the sun is *radial smearing of bright pixels away from the sun's screen position*. So: extract the bright sun-sky region, then per pixel take N samples stepping from the pixel *toward* the sun's screen position, summing with decaying weights — occluders (mast, island) leave dark wedges in the sum, which is exactly what rays look like:

```
 bright-pass (sun visible,  ──►  radial accumulation  ──►  additive
  scene drawn as occluder)        toward sun's uv            composite
        ☀                            ☀
       ▁█▁                        ░\░|░/░
      ▕mast▏    samples march    ░░\░|░/░░    mast leaves a
       ▕██▏      toward sun       ░░░╲|╱░░░    dark wedge = ray gap
```

Strengths: ~0.3 ms, gorgeous. Honest limits: it needs the sun *on screen* (fade it out with `dot(view_forward, sun_dir)` as the sun leaves frame), and the "shafts" exist only in image space — turn the camera and they're gone. Sunset bonus material, not atmosphere.

### Build B — raymarching: light as participating medium

Real shafts are **single scattering**: sunlight enters the fog, scatters off particles along your view ray, and some scatters *toward your eye* — except where the sun is shadowed, contributing per visible step:

```
 in_scatter(view ray) = Σ over steps:  T(t) · shadow(x_t) · ρ(x_t) · phase(θ) · Δt · sun_color
 with transmittance     T(t) = exp(−Σ ρ·Δt so far)        (Beer-Lambert, same law as ch47)
```

- `shadow(x_t)` — your ch57 CSM, sampled at a *point in the air*. This is the term that carves shafts.
- `ρ(x_t)` — fog density; **reuse the ch47 height-falloff exponential** so the volumetrics and the fog are one atmosphere, not two systems disagreeing.
- `phase(θ)` — scattering isn't uniform: atmospheric particles scatter strongly *forward*. The **Henyey-Greenstein** function with anisotropy `g ≈ 0.5–0.7` makes shafts bloom around the sun direction and stay subtle elsewhere:

```glsl
float phase_hg(float cos_t, float g) {
    float g2 = g * g;
    return (1.0 - g2) / (4.0 * 3.14159265 * pow(1.0 + g2 - 2.0 * g * cos_t, 1.5));
}
```

### Making 16 samples look like 200

A correct march wants hundreds of steps; a frame budget allows ~16 at half resolution. Three tricks close the gap:

- **Dither the start offset.** Offset each pixel's first step by a per-pixel noise value: neighboring pixels sample interleaved depths, and banding melts into fine noise. *Blue* noise is ideal (its error is spectrally easy on the eye); a one-line stand-in is **interleaved gradient noise**: `fract(52.9829189 * fract(dot(gl_FragCoord.xy, vec2(0.06711056, 0.00583715))))` (Jimenez 2014). Swap in a real blue-noise texture later (Christoph Peters' free pack) — the upgrade is visible.
- **Half (or quarter) resolution** — fog is low-frequency; the shafts don't need pixels.
- **Bilateral upsample** — when compositing to full res, weight the 4 nearest half-res taps by depth similarity so fog doesn't leak across the mast's silhouette (same idea as ch56's blur, now in upsampling clothes).

## Odin notes

Projecting the sun for Build A: the sun is a direction, so project the *point at infinity* — a w = 0 homogeneous vector, which drops the view translation for free:

```odin
clip := proj * view * glsl.vec4{sun_dir.x, sun_dir.y, sun_dir.z, 0.0}
sun_visible := clip.w > 0.0          // w <= 0: behind the camera, skip the pass
sun_uv := (clip.xy / clip.w) * 0.5 + 0.5
fade := clamp(glsl.dot(camera_forward(cam), sky.sun_direction) * 2.0, 0.0, 1.0)
```

This is also the moment your `Sky`-owned `sun_direction` convention pays off — one source of truth feeds sky, IBL, CSM, and now two god-ray passes.

## Build

1. **Build A — bright extraction.** Small half-res pass from the HDR buffer: `bright = color * step(0.9999, depth) * smoothstep(u_t0, u_t1, luminance)` — sky-only (depth test kills foreground into black, which *is* the occluder information) and only the hot region near the sun.

2. **Build A — radial accumulation.** Second half-res pass, ~64 taps:

   ```glsl
   vec2 duv = (u_sun_uv - v_uv) * (u_ray_length / 64.0);
   vec2 uv = v_uv; float w = 1.0; vec3 acc = vec3(0.0);
   for (int i = 0; i < 64; i++) {
       uv += duv;
       acc += texture(u_bright, uv).rgb * w;
       w *= u_decay;                       // ~0.95
   }
   frag = vec4(acc * u_exposure_rays * u_onscreen_fade, 1.0);
   ```

   Composite additively into the HDR target before bloom (it's light — let bloom and tonemap treat it as such). `u_onscreen_fade` from the Odin note. Ship it behind a toggle; admire a sunset; note how the mast wedges appear. Then note what happens when you look 90° away. On to physics.

3. **Build B — the march.** Half-res RGBA16F target. For each pixel: reconstruct the view ray and the opaque endpoint from depth (cap at, say, 300 m — fog owns the rest), then:

   ```glsl
   float t_max = min(dist_to_surface, u_march_dist);
   float dt = t_max / 16.0;
   float t = dt * ign(gl_FragCoord.xy);          // dithered start
   vec3 acc = vec3(0.0); float trans = 1.0;
   for (int i = 0; i < 16; i++) {
       vec3 p = cam_pos + ray_dir * t;
       float rho = fog_density(p);               // ch47's, via #include
       float sh  = csm_shadow_air(p);            // ch57 sample, no slope bias
       acc   += trans * sh * rho * dt * phase_hg(dot(ray_dir, u_sun_dir), u_g) * u_sun_color;
       trans *= exp(-rho * dt * u_extinction);
       t += dt;
   }
   frag = vec4(acc, trans);
   ```

   `csm_shadow_air` is your cascade sampler minus the surface-specific bias tricks (a point in air needs only a small constant bias) — factor the `#include` so both callers share cascade selection.

4. **Bilateral upsample + composite.** Full-res pass: 4 half-res taps weighted by depth closeness —

   ```glsl
   float d_full = texture(u_depth, v_uv).r;
   vec4 acc = vec4(0.0); float wsum = 0.0;
   for (int i = 0; i < 4; i++) {                 // the 4 nearest half-res texels
       vec2 uv_h = half_res_tap_uv(v_uv, i);
       float w = exp(-abs(d_full - texture(u_half_depth, uv_h).r) * 400.0) + 1e-4;
       acc += texture(u_volumetric, uv_h) * w; wsum += w;
   }
   acc /= wsum;
   ```

   — then `color = color * acc.a + acc.rgb` folded into (or just before) the fog composite. Order with ch47's fog so each meter of air is fogged once: simplest is volumetrics first (it's the near, shadow-aware term), analytic fog after for the kilometers beyond `u_march_dist`.

5. **One atmosphere.** Drive `u_extinction`, density, and `g` from the ch47 Weather parameter block: hazy morning = high density, strong shafts; clear noon = nearly none; storm = dense but *g* low (diffuse gloom, no crisp shafts since the sun's hidden anyway). The shafts must come and go with weather, not with a debug slider someone forgot.

6. **The money test.** Anchor east of a tall island at low sun. Shafts pour over the ridgeline. Now do what Build A cannot: turn the camera so the sun is *behind* you and watch the island's shadow volume still hang in the air, correctly. Keep both builds; A is nearly free and stacks fine at sunset.

7. **Panel.** Toggles + GPU ms for both passes; sliders for g, density scale, march distance, sample count (8/16/32).

## Checkpoint

Sun behind the headland: distinct bright shafts in the gaps, soft gloom in the island's air-shadow, and the rigging's shadow faintly readable in the haze near the boat.

- Camera 360°: Build B's shafts are stable and view-independent; toggling Build A alone reproduces the on-screen-only behavior (and its fade as the sun exits frame).
- No banding rings with dither on (toggle the dither term to see the bands you killed); no halo of fog leaking over the mast silhouette (bilateral upsample working).
- Weather sweep: clear → hazy → storm changes shaft intensity/sharpness plausibly with *zero* shader edits (parameter block working).
- Cost: Build A ~0.3 ms; Build B at half-res/16 ≈ 0.8–1.5 ms. Quarter-res/8 still reads as shafts in a storm — know your fallback.

## Pitfalls

- **Build A: rays wheel around like searchlights at frame edges.** Sun uv computed with w ≤ 0 (sun behind camera) or unclamped far off-screen — gate on `clip.w > 0` and fade; never clamp uv onto the border (that's the searchlight).
- **Build B: concentric banding.** Dither missing, applied per-*sample* instead of per-pixel-start, or your "noise" is `sin(x*12.9898...)`-style and correlates across the screen. IGN or a real blue-noise texture, offsetting the *initial* t.
- **Shafts at noon look like volumetric soup.** Phase too isotropic (g too low) or density flat with height — verify the ch47 height falloff actually feeds `fog_density`, and let g ≈ 0.6 keep the effect sun-directional.
- **Air-shadow acne: stripes in midair.** You inherited the surface slope-scaled bias (meaningless in air — there's no slope) or too-small constant bias near cascade boundaries. Small constant bias; the blend band from ch57 helps here too.
- **Double fog: horizon twice as thick when volumetrics on.** Both Build B and the ch47 analytic fog integrated the same near-field air. Respect the hand-off distance from step 4 — analytic fog starts where the march stops.
- **Shafts flicker as the camera moves.** Half-res depth mismatch in the upsample (use NEAREST when fetching half-res depth) or march distance keyed to surface depth without the cap, so dt jumps per pixel. Cap and clamp.

## Exercises

1. Add the moon: at night, run Build B with moon direction/color (your ch27 sky knows them). Moonlit fog shafts over black water is the best cheap screenshot in the part.
2. Lantern halos: a crude local volumetric — analytic in-scatter integral along the view ray for each of the brightest ~4 point lights (closed-form for constant density, no shadowing; search "analytic single scattering point light"). Misty harbor lamps at anchor.
3. Replace IGN with a tiled 64² blue-noise texture and A/B at 8 samples — count how much sample budget the noise quality bought you.
4. **Stretch:** read Wronski's volumetric fog paper and sketch (on paper, no code) how Saltwind's version would map to a 160×90×64 froxel volume in compute — density+lighting injected per cell, then a froxel-space accumulation, sampled by *every* shader including transparents. Part 10 gives you compute; this is a natural first victim after the ocean.

## Commit

`git commit -m "ch59: god rays — radial-blur pass + CSM-shadowed volumetric raymarch with HG phase, dither, bilateral upsample"`

[← Ch. 58: Mirrors of the Sea](ch58-mirrors-of-the-sea.md) · [Ch. 60: Milestone — The Deep Engine →](ch60-milestone-the-deep-engine.md)

> ⚓ **Optional side quest:** [Interlude 59a — The Physical Lens](ch59a-the-physical-lens.md) — give photo mode a real lens: thin-lens depth of field with click-to-focus, motion blur, and a tastefully restrained lens flare.
