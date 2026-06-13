# Chapter 66 — Beneath the Surface

*Part 10 — The True Ocean · Estimated time: 6h · learnopengl: no direct equivalent — background reading: any Beer–Lambert primer; Tessendorf §5 touches underwater light*

**What you'll see when done:** the camera dips below a swell and the world *changes state* — blue-green haze swallowing the distance, caustic light dancing on the sand, god rays slanting down from a bright wobbling ceiling that ends in a circle of sky.

## Where we are

Your ocean has only ever been observed from above. But the camera is free (and Chapter 32's boat occasionally buries her bow), and right now crossing the surface shows you the embarrassing truth: an infinitely thin sheet with nothing underneath. The terrain already continues below sea level (it has since Chapter 20 — the shallows prove it). Today we light it, fog it, and dress it, and we give the surface a *backside*. Almost everything here reuses machinery you own: Beer–Lambert from the Chapter 47 fog work, a post pass like Chapter 54's FXAA, god rays from Chapter 59, instancing from Chapter 45, particles from Chapter 46. Underwater is where your whole engine shows up to work.

## Concepts

### Knowing when you're under

One comparison: `camera.position.y < ocean_height_at(ocean, camera.position.xz, t)` — and notice that *just works* on the FFT sea, because Chapter 65 gave that function a real backend. (The payoff chapter keeps paying.) Add a small hysteresis band (±10 cm) so spray-level bobbing doesn't strobe the underwater state at 60 Hz.

### Beer–Lambert: why the deep is blue-green

Light traveling distance `d` through water is absorbed exponentially, *per wavelength*:

```
T(d) = e^{−σ·d}        σ ≈ (0.35, 0.07, 0.05) per meter   (clear ocean water)
```

Red's coefficient is ~7× green's: at 5 m, red is down to 17%; at 15 m, 0.5% — gone. That asymmetry is the *entire* color story underwater: nothing is "tinted blue," red simply doesn't survive the trip. Two distances matter and both get absorbed: sun → object (depth below surface) and object → camera (view distance). For a post pass we fold the first into a depth-darkening and apply the second per pixel:

```glsl
vec3 absorb   = exp(-u_sigma * view_dist);            // σ as a vec3 — per channel!
vec3 in_scatter = u_water_color * (1.0 - absorb);     // light scattered INTO the ray
color = color * absorb + in_scatter;
```

That second term — in-scattering — is what makes distant water *glow* faintly instead of fading to black; it's the same fog equation as Chapter 47, with a physically-motivated σ. (`u_water_color` is your deep-water color, darkened with camera depth.)

### The surface from below: Snell's window

Light bends entering water (refractive index n ≈ 1.33). Reversed, a ray from underwater can only *exit* if it hits the surface steeper than the **critical angle**:

```
sin θc = 1/1.33  →  θc ≈ 48.6°

            sky    sky    sky
         ──────────────────────── surface
            ╲     │     ╱
             ╲ 48.6°  ╱        inside the cone: the WHOLE sky,
              ╲   │   ╱         refraction-compressed into a circle
        mirror ╲  │  ╱ mirror
               (camera)         outside: total internal reflection —
                                the surface mirrors the dark deep
```

Looking up, you see the entire hemisphere of sky squeezed into a ~97°-wide bright circle — **Snell's window** — surrounded by a darker mirror of the water below. We approximate rather than simulate: render the ocean mesh's backside, and in the shader blend "bright refracted sky" vs. "dark TIR mirror" on the view angle against the critical cosine (≈ 0.66). With FFT waves wobbling the boundary, the approximation is uncannily convincing — the window's writhing edge is what your brain checks for.

### Caustics, the honest cheap way

Real caustics are wave crests acting as lenses, focusing sunlight into bright filaments on the seabed. Real solutions raytrace or render caustic maps; *convincing* solutions observe that the focusing pattern looks like the wave normals' flatness, animated. We sample the ocean normal map (we have it! in world-mapped UVs!) at the seabed's xz at two scales, multiply, sharpen with a power — bright moving filaments that genuinely derive from the same wave field the player sees overhead, for two texture taps. Attenuate by depth (Beer–Lambert again — caustics are *sunlight*, it traveled `depth` meters) and by sun elevation.

### The rest is set dressing — and you own all the tools

God rays: Chapter 59's machinery with underwater parameters (higher density, σ-tinted color, shafts keyed to the Snell window region). Kelp: Chapter 45 instancing + a vertex sway like the Chapter 73 preview you've already half-built for palms. Sand motes: a Chapter 46 emitter with near-zero gravity, camera-following volume. None of these get a Concepts section; you've earned the right to just build them.

## Build

1. **The state switch.** `game.underwater: bool` from the hysteresis test, evaluated once per frame. It gates: the post pass (step 2), ocean backface culling (step 4), god-ray parameter set (step 6), the miniaudio low-pass if you did Chapter 36 (one `if`, enormous effect).

2. **The underwater post pass.** New entry in your Chapter 60 pass list, between scene resolve and tonemap (it must run pre-ACES — absorption is linear-light physics, not grading). It's a fullscreen triangle reading scene color + depth:

   ```glsl
   float d     = linearize(texture(u_depth, uv).r);          // ch56 gave you this
   vec3  view_dist = min(d, 80.0);                           // beyond ~80 m: all fog anyway
   vec3  absorb    = exp(-u_sigma * view_dist);
   vec3  deep      = u_deep_color * exp(-u_sigma * u_cam_depth); // darker the deeper YOU are
   color = color * absorb + deep * (1.0 - absorb);
   ```

   Plus the lens: distort `uv` by two scrolling sines (`uv += 0.004 * sin(uv.yx * 30.0 + u_time * vec2(1.3, 1.7))`) *before* the scene sample, and a slight blue-green vignette. Keep distortion subtle — 0.004 is "water in your mask," 0.02 is "migraine."

3. **Wave the σ flag through Weather.** Storm water carries sediment: raise σ and shift `u_deep_color` gray-green in the Storm preset. One struct field, big mood swing.

4. **The surface from below.** When underwater, draw the ocean with `gl.Disable(gl.CULL_FACE)` and handle the backside in the fragment shader:

   ```glsl
   vec3 n = v_normal;
   if (!gl_FrontFacing) {
       n = -n;
       float up = dot(-view_dir, vec3(0,1,0));               // toward the surface
       float window = smoothstep(0.60, 0.72, up);            // cos 48.6° ≈ 0.66
       vec3 through = sky_color(refract(view_dir, n, 1.33)) * 1.3;  // bright circle
       vec3 tir     = u_deep_color * 0.4;                    // dark mirror
       color = mix(tir, through, window);
       // fade by camera depth: the ceiling dims as you sink
   }
   ```

   Mention in passing what `refract` returns outside the window: a zero vector — total internal reflection is *in the API*. The `smoothstep` band hides the seam, and the FFT normals animate the window edge for free.

5. **Caustics on the seabed.** In the terrain fragment shader, gated on `world.y < u_sea_level` (the shader runs for shallows seen from above too — caustics through shallows are half the effect):

   ```glsl
   vec2 cuv = world.xz / u_tile_size;
   float c1 = texture(u_ocean_normal, cuv * 1.0 + u_time*0.013).y;
   float c2 = texture(u_ocean_normal, cuv * 2.7 - u_time*0.021).y;
   float caustic = pow(clamp(c1 * c2, 0.0, 1.0), 6.0) * 4.0;
   float depth_below = u_sea_level - world.y;
   vec3 caustic_light = u_sun_color * caustic * exp(-u_sigma * depth_below)
                      * max(u_sun_dir.y, 0.0);
   diffuse += caustic_light;
   ```

   The `.y` of a wave normal is "flatness" — flat patches are where crest-lenses focus. Two scales multiplied kill the obvious tiling; the power sharpens blobs into filaments.

6. **God rays, underwater edition.** Reuse the Chapter 59 raymarch pass with an underwater parameter block: density ×4, scattering color = `u_sun_color * exp(-u_sigma * depth)`, and — the detail that sells it — modulate ray strength by the caustic function sampled at the ray's surface entry point, so shafts flicker with the waves. If you built only the radial-blur version in ch59, that works too: the bright Snell window is exactly the kind of source radial blur loves.

7. **Dress the seabed.** It exists; make it a place:
   - **Kelp/coral:** 4–6 crossed-quad kelp blades and a couple of coral lumps (your procedural mesh tools from Chapter 11 are fine — lumpy spheres with a palette). Instance a few thousand across shallow seabed (slope + depth mask, same logic as Chapter 45's palm placement). Sway: `pos.xz += sin(u_time * 1.2 + i_phase) * 0.3 * pow(v_height01, 2.0)` — bend grows with height up the blade.
   - **Sand motes:** Chapter 46 emitter, ~500 particles in a 20 m camera-following box, drift velocity = a slow curl of the wind field, soft-particle fade near geometry. Active only when `game.underwater`.

## Checkpoint

Dive (fly down, or bury the bow) on a sunny day: the moment of crossing reads as a *state change* — fog closes in per-channel (watch a red crate go gray-green ahead of everything else!), the surface overhead is a moving mirror pierced by a bright circle of sky, shafts of light angle down through it, caustics crawl over sand and kelp.

- Surface crossing is clean both ways — no flicker frame, no gap where the thin sheet shows (hysteresis + backface draw working).
- A red object loses its red within ~6 m of view distance; white sand at 2 m depth shows caustics; at 20 m it barely glows. Per-channel σ is visibly doing the work.
- Look straight up from 5 m down: bright circle, dark surround, wobbling boundary. Tilt toward horizontal: all mirror.
- Pass panel: underwater pass ≈ post-pass cheap (~0.2 ms), rays at their ch59 cost, kelp in your instancing budget. Nothing here is expensive; it's all leverage.

## Pitfalls

- **Everything just looks "blue-tinted," not underwater.** You applied a constant tint instead of distance-dependent per-channel absorption — the *exponential with distance* is the effect; a multiply is sunglasses.
- **Underwater fog applied to the sky/surface seen through the window.** Your depth buffer has far-plane values there; `min(d, 80.0)` handles it, but only if the ocean backside *writes depth* — draw it in the depth-tested scene, not as an afterthought.
- **State strobes at the surface.** No hysteresis, or you tested against the *flat* sea level instead of `ocean_height_at` — in a 2 m swell those disagree by 2 m.
- **Caustics tile obviously / slide unnaturally.** One sample instead of two multiplied scales, or your scroll speeds are aliased multiples; make them irrational-ish (0.013, 0.021).
- **Snell window visible from *above* the water.** The backside branch ran on front faces — gate on `gl_FrontFacing`, not on `game.underwater` alone (you can be above water looking at a wave's back).
- **God rays wash out the whole screen.** Underwater density × the ch59 default exposure: retune as a *pair*. Rays should be readable only against the darker mirror region, like the reference photos you should absolutely have open right now.

## Exercises

1. Drop the σ values into the microui panel and find: Caribbean (low σ, cyan), Baltic (high green σ, murk), Storm runoff (high everything, brown-green). Save them as presets — Chapter 75's biomes will want them.
2. Refract the *scene* at the crossing: when the camera is half-submerged, render a split view (above-fog top, underwater bottom) using the surface height at the camera to place the line. Classic, fiddly, glorious.
3. Make the caustics respect Weather: storm seas (steep, foam-broken) actually have *weaker* defined caustics — scale `caustic` by `1 − foam` sampled from Chapter 64's texture. Coupling for free.
4. **Stretch:** depth-keyed audio if you did Chapter 36 — low-pass cutoff and a heartbeat-quiet ambience that deepens with `u_cam_depth`, crossfaded over the surface transition. Underwater is 50% sound; you'll never dive without it again.

## Commit

`git commit -m "ch66: underwater — absorption, snell window, caustics, dressed seabed"`

← [Chapter 65 — Floating on Data](ch65-floating-on-data.md) · [Chapter 67 — The Boat Writes on Water](ch67-the-boat-writes-on-water.md) →
