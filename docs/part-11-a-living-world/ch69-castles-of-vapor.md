# Chapter 69 — Castles of Vapor

*Part 11 — A Living World · Estimated time: 8–10h · learnopengl: no direct equivalent — canonical reference: Andrew Schneider's Nubis talks ([SIGGRAPH 2015](https://advances.realtimerendering.com/s2015/The%20Real-time%20Volumetric%20Cloudscapes%20of%20Horizon%20-%20Zero%20Dawn%20-%20ARTR.pdf) and the later Advances in Real-Time Rendering follow-ups)*

**What you'll see when done:** towering white cumulus drifting over the archipelago — sun-silvered on one flank, shadow-bellied beneath — that thicken into a gray ceiling when you summon a storm.

## Where we are

Your ch27 sky is a function of direction: gradient, sun disk, done. Your ch47 weather "grays it out" with a desaturation knob — a confession, not a cloud. Meanwhile Part 10 handed you exactly the tools real clouds need: compute shaders for noise generation, and a pass-list Renderer (ch60) that makes adding a quarter-res pass routine. Today we raymarch actual volumes of vapor, the pragmatic version of what Guerrilla shipped in Horizon Zero Dawn. It's the most shader-math-dense chapter in the course — and the single biggest visual upgrade since IBL.

## Concepts

### A cloud is a density function

Stop thinking geometry. A cloud layer is a function `density(world_pos) -> float`, nonzero inside a shell of atmosphere between two altitudes:

```
  4000 m  ───────────────────── shell top
            ☁☁      ☁☁☁☁
           ☁☁☁☁    ☁☁☁☁☁☁        density > 0 somewhere in here
            ☁☁       ☁☁
  1500 m  ───────────────────── shell base
   ~~~~~~~~ sea ~~~~~~~~~~~~~~  camera lives down here
```

Rendering = for each pixel, march a ray from the camera through the shell, accumulating how much light the vapor along it scatters toward you and how much it blocks. Three sub-problems: **shape** (what is the density?), **lighting** (what color is a lit sample?), and **cost** (how do we afford it?).

### Shape: weather map × noise × height profile

Schneider's decomposition, which everyone now uses:

1. **A 2D weather texture** (512², low-frequency fBm you generate yourself) says, per world XZ: *coverage* (R: is there cloud here at all?) and *type* (G: puffy low cumulus vs flatter stratus — it selects the height profile). It scrolls with the wind, so cloudscapes drift.
2. **A 3D base-shape texture** (128³, tiling) gives clouds their cauliflower body: **Perlin-Worley** noise. Worley (cellular) noise produces bubble-like cells — exactly cloud billows — and inverting it (`1 - worley`) gives puffs instead of voids. Channel R holds Perlin remapped by Worley; G/B/A hold Worley at rising frequencies for an fBm you assemble in the shader.
3. **A 3D detail texture** (32³ Worley) erodes the edges so silhouettes wisp instead of blobbing.
4. **A height gradient** shapes the cumulus profile: density fades in just above the shell base (flat bottoms — real cumulus have them, it's the condensation level), bulges in the middle, and tapers to nothing at the top. Two smoothsteps:

```glsl
float height_gradient(float h01, float cloud_type) {
    // h01 = 0 at shell base, 1 at top; cumulus profile
    float bottom = smoothstep(0.0, 0.07, h01);
    float top    = 1.0 - smoothstep(mix(0.3, 0.9, cloud_type), 1.0, h01);
    return bottom * top;
}
```

Density = base noise fBm, **remapped by coverage** (so coverage doesn't just scale density — it carves it: `density = remap(base, 1.0 - coverage, 1.0, 0.0, 1.0)`), times the height gradient, minus detail erosion at the edges. The remap trick is the heart of the look: low coverage leaves only the *cores* of the noise, which reads as scattered fair-weather puffs; high coverage releases the whole field.

### Lighting: Beer-Lambert, phase, and the powder line

A sample at `p` is lit by the sun attenuated by all the cloud between `p` and the sun — so at every density sample, run a **secondary march** toward the sun (4–6 coarse steps is plenty) accumulating optical depth `τ`, then:

- **Beer-Lambert:** `light = exp(-τ)` — the same law as your ch47 fog and ch66 underwater absorption. Third time it's paid rent.
- **Powder term:** pure Beer's law makes the sun-facing edges of dense clouds too bright and the crevices too flat. Schneider's "powder" approximation `1.0 - exp(-2.0 * τ)` darkens the just-inside-the-surface region, which reads as the dark creases between billows. Use `beer * powder` when looking *toward* the sun, fade the powder term out away from it.
- **Henyey-Greenstein phase:** clouds scatter strongly *forward* — that's why their sun-side rims blaze (silver lining, literally). `phase_hg(cos_angle, g)` with `g ≈ 0.3`, plus a second narrower lobe (`g ≈ 0.8`) mixed in for the bright halo when looking near the sun:

```glsl
float phase_hg(float c, float g) {
    float g2 = g * g;
    return (1.0 - g2) / (4.0 * 3.14159 * pow(1.0 + g2 - 2.0 * g * c, 1.5));
}
```

Sample color = `u_sun_color * beer * powder * phase + ambient`, where ambient is a cheap gradient (sky color above, dimmer toward cloud base). Along the primary ray you accumulate front-to-back: `color += transmittance * sample_light * density * step; transmittance *= exp(-density * absorption * step);` and bail when transmittance drops under ~0.01.

### Cost: adaptive steps, quarter res, bilateral upsample

Full-res 128-step marching is a GPU funeral. Three mitigations, in order of importance:

1. **March only the shell.** Ray-intersect the two altitude planes; start and end there. Pixels whose scene depth (your G-buffer/depth copy) is closer than the shell entry skip entirely — mountains occlude clouds for free.
2. **Adaptive stepping:** march at double step length while in empty air; on the first nonzero density, step back once and continue at fine resolution. When transmittance is nearly gone, stop. Add a per-pixel blue-noise offset to the start distance (your ch59 dither texture) so undersampling becomes noise instead of banding.
3. **Quarter resolution + bilateral upsample.** Render the march into a ¼-size RGBA16F target (RGB = scattered light, A = transmittance), then upsample with a **bilateral** filter: a 4-tap upsample that weights each low-res neighbor by how close its (downsampled) depth is to the full-res pixel's depth, so cloud color doesn't bleed across mountain silhouettes. This is the production-lite version: the full production upgrade is **temporal reprojection** (render 1/16 of the pixels per frame, reproject the rest — Schneider's talks cover it) — flag it, skip it. Without TAA infrastructure it's more bug than benefit.

### The payoff you don't have to build: IBL

Keep the density and lighting functions in `assets/shaders/clouds_common.glsl` (your `#include` concat from ch44). Then add a low-step-count call to them in the **sky shader variant used by the ch43 IBL capture**. Because the capture re-renders and re-convolves whenever the sky changes, the moment clouds roll in, your *ambient light* goes gray and soft — the deck, the sails, the water all dim under overcast **automatically**. No new system. This is what building on a function-of-direction sky buys you, three parts later.

## Odin notes

3D textures and compute meet for the first time. The compute shader writes a `layout(rgba8) image3D`; allocation and dispatch from Odin:

```odin
gl.GenTextures(1, &tex)
gl.BindTexture(gl.TEXTURE_3D, tex)
gl.TexImage3D(gl.TEXTURE_3D, 0, gl.RGBA8, 128, 128, 128, 0, gl.RGBA, gl.UNSIGNED_BYTE, nil)
gl.TexParameteri(gl.TEXTURE_3D, gl.TEXTURE_WRAP_S, gl.REPEAT) // and T, R — it tiles!
gl.TexParameteri(gl.TEXTURE_3D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
gl.TexParameteri(gl.TEXTURE_3D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)

gl.UseProgram(noise_gen) // from shader_load_compute (ch61)
gl.BindImageTexture(0, tex, 0, gl.TRUE, 0, gl.WRITE_ONLY, gl.RGBA8)
gl.DispatchCompute(128 / 4, 128 / 4, 128 / 4)
gl.MemoryBarrier(gl.TEXTURE_FETCH_BARRIER_BIT)
```

The `layered = gl.TRUE` argument in `BindImageTexture` is the one everyone forgets — without it you bind a single 2D slice of the 3D image and 127/128ths of your texture stays black. This runs **once at startup** (~milliseconds); no CPU noise loops, no disk cache.

## Build

1. **Noise generator compute shader** — `assets/shaders/worley_perlin.comp` (GLSL 430, `local_size_x = 4, local_size_y = 4, local_size_z = 4`). Tiling Worley: hash one feature point per lattice cell, take distance to the nearest over the 27 neighbors, **wrap the cell coordinates** by the lattice period so the texture tiles:

   ```glsl
   float worley(vec3 p, float freq) {     // p in [0,1)^3, returns 0 (center) .. 1 (far)
       p *= freq;
       vec3 id = floor(p), f = fract(p);
       float d = 1e9;
       for (int x = -1; x <= 1; x++)
       for (int y = -1; y <= 1; y++)
       for (int z = -1; z <= 1; z++) {
           vec3 cell = vec3(x, y, z);
           vec3 fp   = hash33(mod(id + cell, freq));  // mod => tiling
           d = min(d, length(cell + fp - f));
       }
       return clamp(d, 0.0, 1.0);
   }
   ```

   Main: `R = remap(perlin_fbm, 1.0 - worley_fbm, 1.0, 0.0, 1.0)` (Perlin-Worley), `G/B/A = 1.0 - worley` at freq 4/8/14. A tiling Perlin is the same trick with gradient hashing — or reuse your terrain's fBm shaped into a shader function. Don't chase perfection; you will never see this texture raw.

2. **`src/clouds.odin`** — the system struct and startup:

   ```odin
   Cloud_Layer :: struct {
       noise_base:   u32,  // 128^3 RGBA8
       noise_detail: u32,  // 32^3  RGBA8
       weather_tex:  u32,  // 512^2 RG8, coverage + type
       quarter_fbo:  u32,
       quarter_tex:  u32,  // (w/4, h/4) RGBA16F: rgb scatter, a transmittance
       march_shader: Shader,
       upsample_shader: Shader,
       base_alt, top_alt: f32,  // 1500, 4000
   }
   ```

   `clouds_create` allocates all three textures and dispatches the generators (the weather texture is a second tiny compute shader: 2 octaves of fBm in R, another in G). Recreate `quarter_tex` in your resize handler at `w/4, h/4`.

3. **The march shader** — a fullscreen pass sampling the depth copy. Ray setup: unproject the pixel to a world ray (you have this from SSR, ch58), intersect `y = base_alt` and `y = top_alt` planes, clamp the segment by scene depth, early-out if empty. Core loop:

   ```glsl
   vec3 scatter = vec3(0.0);
   float trans  = 1.0;
   float t      = t_start + blue_noise * step_len;
   for (int i = 0; i < MAX_STEPS && t < t_end; i++) {
       vec3  p = ray_origin + ray_dir * t;
       float d = cloud_density(p, /*cheap=*/false);
       if (d > 0.001) {
           float tau   = light_march(p);            // 5 steps toward sun
           vec3  light = u_sun_color * exp(-tau)
                       * (1.0 - exp(-2.0 * tau)) * phase
                       + ambient_at(p);
           scatter += trans * light * d * step_len;
           trans   *= exp(-d * u_absorption * step_len);
           if (trans < 0.01) break;
           t += step_len;                            // fine step in cloud
       } else {
           t += step_len * 2.0;                      // coarse step in air
       }
   }
   out_color = vec4(scatter, trans);
   ```

   `cloud_density` lives in `clouds_common.glsl`: sample weather (XZ / weather_scale, scrolled by `u_wind_offset`), remap base noise by coverage, multiply height gradient, erode with detail near the density threshold. Start with MAX_STEPS 64, step_len ~120 m, light march 5 × 300 m.

4. **Upsample + composite pass.** Bilateral 4-tap: sample the four nearest quarter-res texels, weight by `exp(-abs(depth_full - depth_quarter) * k)`, normalize. Composite into the HDR buffer **before tonemap**: `final = scene_rgb * cloud.a + cloud.rgb`. Register both as passes in the ch60 Renderer list (after opaque + ocean, before god rays — shafts in front of clouds look wrong) with their own GPU timers.

5. **Couple to Weather.** Add `cloud_coverage: f32` (and optionally `cloud_type`) to `Weather_Params` — Clear ≈ 0.3, Overcast ≈ 0.75, Storm ≈ 0.95 — and feed `weather.current.cloud_coverage` into the march shader as a coverage *bias* added before the remap. The ch47 lerp machinery transitions it for free: press 3 and watch the puffs swell, merge, and shut out the sun over thirty seconds.

6. **IBL hook.** In the capture-only sky shader (ch43 step 2), `#include clouds_common.glsl` and run an 8-step march with the detail texture skipped (`cheap = true`). The amortized recapture does the rest. Verify with the IBL debug toggle: overcast on → deck ambient goes gray within a few seconds.

7. **Tune.** Coverage bias, absorption (~0.8), the two HG g values, ambient strength. Park the boat, set time to 17:30, and adjust until the sun-side rims glow. These numbers are content; spend the time.

## Checkpoint

Cumulus stacked over the islands, flat-bottomed and cauliflower-topped, drifting downwind; crevices shade themselves; looking near the sun the edges burn silver. Press 3: the field thickens to a storm ceiling and the whole world's ambient dims with it.

- Clouds sit *behind* island peaks correctly, and the bilateral upsample shows no color bleed at those silhouettes.
- Scrub time to 18:00: cloud undersides catch the sunset color (they inherit `u_sun_color` — same struct as everything since ch27).
- GPU timer for the cloud pass: ~1–2.5 ms at 1080p quarter-res on a midrange card. Full-res debug toggle: ~10×. That ratio is the chapter's economics lesson.
- IBL toggle test from step 6 passes.

## Pitfalls

- **Concentric banding rings.** Step undersampling. The blue-noise start offset is mandatory, not optional; verify it actually varies per pixel (sample the ch59 dither texture with `gl_FragCoord.xy / 64.0`, not a constant).
- **Clouds are gray mush with no shape.** Coverage is *scaling* density instead of *remapping* it. The remap (`remap(base, 1 - coverage, 1, 0, 1)`) is what carves distinct puffs; double-check its clamp.
- **127 black slices.** `BindImageTexture` with `layered = false` on a 3D texture — see Odin notes.
- **Sun-facing clouds darker than sky-facing.** Phase function backwards: `cos_angle` must be `dot(ray_dir, u_sun_dir)` with both normalized and your ch27 sign convention (toward the sun) respected. Grep the convention comment.
- **Shimmering/swimming when the camera moves.** Your blue-noise offset is in *screen* space and the march is in world space — fine — but if you also jitter `t_end` or the weather scroll per frame, samples crawl. Jitter the start only.
- **Frame rate dies at the horizon.** Near-horizontal rays cross the shell for tens of kilometers. Clamp the march distance (`t_end = min(t_end, t_start + 30000.0)`) and fade the result into the ch47 haze — the fog hides the cut.

## Exercises

1. Cloud shadows: project the weather texture (coverage × a softness curve) onto the world in your terrain/ocean shaders as a sun-light multiplier. Drifting cloud shadows on the sea for one texture sample.
2. Wind shear: offset the noise sample position by `wind_dir * h01 * shear` so cloud tops lean downwind. Subtle, and suddenly they're *weather*, not décor.
3. A `cloud_type` gradient in the weather texture's G channel: stratus near 0 (low, flat profile), cumulus near 1. Let Storm push type toward stratus while raising coverage — the pre-storm sky flattens before it darkens, like the real thing.
4. **Stretch:** temporal reprojection — render 1/4 of the quarter-res pixels per frame in a 2×2 cadence, reproject the rest with last frame's view-projection, fall back to a fresh march on disocclusion. Read both Nubis decks first; budget a weekend.

## Commit

`git commit -m "ch69: raymarched volumetric clouds — worley-perlin, beer/powder/HG, quarter-res"`

[← Ch. 68: The True Ocean](../part-10-the-true-ocean/ch68-milestone-the-true-ocean.md) · [Ch. 70: Canvas and Wind →](ch70-canvas-and-wind.md)
