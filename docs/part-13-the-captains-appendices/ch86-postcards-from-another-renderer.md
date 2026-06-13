# Chapter 86 — Postcards from Another Renderer

*Part 13 — The Captain's Appendices · Standalone: requires Part 10 (compute shaders) · Estimated time: 6h · learnopengl: no direct equivalent — canonical references: Shirley's free [Ray Tracing in One Weekend](https://raytracing.github.io) and [Physically Based Rendering](https://pbr-book.org)*

**What you'll see when done:** you frame a shot in photo mode, press P, and watch a noisy ghost of your scene resolve over thirty seconds into a postcard with soft sun shadows and grass-green light bleeding onto the hull — rendered by physics, not by your bag of tricks.

## Where we are

You need Part 10's compute machinery (`shader_load_compute`, dispatch math, barriers, image load/store) and you'll reuse Chapter 51's photo mode and F11 capture, Chapter 40's tonemap, and — the soul of the chapter — Chapter 29's `sky_common.glsl`. Parts 7 and 9 inform everything conceptually but nothing here depends on their passes, because tonight you're *not using your renderer at all*.

Why this question always comes up: after a learner builds shadow maps, SSR, and IBL, a suspicion forms — these are all workarounds for *something*, three differently-shaped patches over the same hole. The suspicion is correct. There is one equation all of real-time rendering is approximating, and there is another family of renderers — the offline ones behind every Pixar frame and every "path traced" toggle — that just... evaluates it. This appendix is the course's window into that other world. You will build a small, honest, progressive path tracer in a compute shader, point it at the scene you already have, and see soft shadows and color bleeding appear *for free* — effects you couldn't buy at any price in the rasterizer.

## Concepts

### The rendering equation, in human terms

Every renderer ever written is an answer to one question: *how much light leaves this point toward my eye?* Kajiya wrote the question down in 1986:

```
L_o(x, ω_o) = L_e(x, ω_o) + ∫ f(x, ω_i, ω_o) · L_i(x, ω_i) · cosθ_i dω_i
              └── emitted ──┘  └──── over the whole hemisphere above x ────┘
```

Read it as a sentence: the light leaving point `x` toward you is whatever `x` emits, **plus** light arriving from *every direction* `ω_i` in the hemisphere above it, each direction weighted by the BRDF `f` (how this material redirects light from `ω_i` toward you — you implemented `f`, it's your ch42 Cook-Torrance) and by `cosθ` (glancing light spreads over more area, so it counts less — your `NdotL`).

The trap is `L_i`, the incoming light. Where does light arriving at `x` come from? From *other surfaces* — whose outgoing light is defined by the same equation. It's an integral whose integrand contains the integral. Light bounces forever, and the equation says so.

### Rasterization is a pile of clever approximations of this integral

Here is the re-read of Parts 7–9 that this chapter exists for. Each technique you built is a hand-made approximation of one piece of the equation:

| You built | It approximates |
|---|---|
| Shadow mapping (ch39/57) | the *visibility* of `L_i` from one direction (the sun) — a single ray's worth of the integral, precomputed for all pixels at once |
| SSR (ch58) | `L_i` along one mirror direction, scavenged from pixels you already shaded |
| IBL (ch43) | the entire `∫ f · L_i · cosθ` for distant light, pre-integrated offline into cubemaps and a LUT |
| Ambient / SSAO (ch56) | multi-bounce light, replaced by a constant and then dimmed by a heuristic |

Every one trades correctness for the right to answer in 16 milliseconds. None of them can see around corners, none can bounce green off the grass onto the hull, and all of them disagree with each other in small ways you've spent chapters hiding. Tonight you meet the thing they're all imitating.

### Monte Carlo: average random samples and you converge

You can't integrate over infinite directions analytically — so estimate. The Monte Carlo insight: pick a *random* direction `ω` with probability density `pdf(ω)`, evaluate the integrand there, divide by the pdf, and that single number is an **unbiased estimate** of the whole integral. Average `N` of them and the error shrinks as `1/√N`.

That square root is the economics of the entire field, so say it precisely: **4× the samples halves the noise.** 16 samples is twice as clean as 4; getting from "noisy" to "clean" costs hundreds. This is why path tracing is progressive (the image *resolves* over time), why denoisers exist, and why your postcard takes thirty seconds instead of sixteen milliseconds.

A **path tracer** applies the estimator recursively: from the eye, shoot a ray; at the hit, estimate the integral with *one* random bounce direction; at that hit, one more; until the ray escapes to the sky or is terminated. One pixel sample = one random walk through the scene, carrying a running `throughput` of how much each bounce dimmed it. Sum light found along the way, average many walks per pixel.

### Importance sampling: aim your randomness

Uniform random directions waste samples where the integrand is tiny. Since you divide by the pdf, you're free to choose *any* distribution — so choose one shaped like the integrand:

- **Cosine-weighted hemisphere** for diffuse: pdf `= cosθ/π`, which exactly cancels the `cosθ` and the Lambertian `1/π` in the integrand. The math collapses to `throughput *= albedo`. Beautiful and standard.
- **GGX-distribution sampling** for specular: pick microfacet normals proportional to your ch42 NDF, so rough-mirror lobes get sampled where they're bright. We'll cheat tonight (perfect mirror below a roughness threshold) and leave true GGX sampling as an exercise — PBRT chapter 14 is the canon when you want it.

### Next-event estimation: don't wait to get lucky

The sun is the brightest thing in your sky and covers ~0.005% of the hemisphere. Random bounces essentially never hit it, so naive path tracing of a sunlit scene is noise soup. The fix, **next-event estimation (NEE)**: at *every* hit, additionally shoot one deliberate ray at the sun (jittered within its disk — that jitter is where soft shadow edges come from), test visibility, and add `throughput · f · sun_radiance · cosθ` if unblocked. One rule keeps it honest: the sun must be counted *only once* — since NEE samples it explicitly, bounce rays that happen to reach the sky must read the sky *without* the sun disk, or you'd double-count. (The general technique balancing both estimators is multiple importance sampling — PBRT again.)

### Russian roulette: quitting without bias

Paths must end, but truncating at a fixed depth loses energy. Russian roulette: after a couple of bounces, kill the path with probability `1 - p` — and if it survives, divide its throughput by `p`. Survivors are boosted exactly enough to pay for the dead, on average. Unbiased laziness; set `p` to the throughput's max channel, clamped.

### Accumulation

Per frame, add a few fresh samples per pixel into an `RGBA32F` accumulation texture (alpha can store nothing; an Odin-side counter tracks `N`). Display `accum.rgb / N` through your existing tonemap — the path tracer outputs linear HDR radiance, exactly the currency your ch40 pipeline trades in. Move the camera and the estimate is invalid: reset `N` to zero and start over. That's the whole progressive scheme.

## Odin notes

The accumulation texture must be `RGBA32F`, not 16F — thousands of accumulated samples overflow half-float precision and quantize to banding. Don't bother clearing it with GL calls: have the kernel treat `u_sample_index == 0` as "overwrite, don't add," and resetting becomes setting one integer to zero. For camera-move detection, store the view matrix used for the last dispatch and compare; any change resets. `core:math/rand` isn't needed — all randomness lives in the shader.

## Build

1. **The struct and mode.** New `src/pathtrace.odin`:

   ```odin
   Path_Tracer :: struct {
       accum:        u32,  // RGBA32F, native or scaled resolution
       width, height: i32,
       trace_shader: Shader,            // pathtrace.comp
       resolve_shader: Shader,          // fullscreen: accum/N -> HDR target
       sample_index: i32,               // samples accumulated so far
       samples_per_frame: i32,          // 1-4
       active:       bool,
       last_view:    glsl.mat4,
   }
   ```

   Hook the key: in photo mode (P, ch51), pressing P *again* toggles `active` and resets `sample_index`. While active, `game_render` skips the entire raster scene: dispatch the tracer, resolve into the HDR target, tonemap as always, draw the sample counter via the HUD. F11 (ch51) already saves whatever the backbuffer holds — postcards ship with zero new code.

2. **Scene representation — small and honest.** A path tracer needs ray-vs-world intersection, and your triangle soup would need a BVH (a real project; see ch88). Postcards don't: the *reader's-eye* version of Saltwind is an analytic ocean plane, a terrain heightfield, and a boat made of boxes.

   - **Ocean:** a flat plane at `y = 0` — postcards are becalmed; flat water also gives mirror reflections that flatter every shot. (Optionally perturb the *shading normal* with one Gerstner wave for life; keep the geometric plane flat.)
   - **Terrain:** you already have the height function as a texture (if you did ch67's shore exercise you have it baked; if not, bake your ch21 `terrain_height(x, z)` into an `r32f` texture over the island's extent at startup — twenty lines).
   - **Boat:** two or three OBBs — hull, cabin, mast — positioned from the boat's model matrix, each with `albedo, roughness, metallic` matching its ch42 material constants. Upload as uniforms (three boxes don't deserve an SSBO).

3. **Rays and randomness, top of `assets/shaders/pathtrace.comp`:**

   ```glsl
   #version 430
   layout(local_size_x = 8, local_size_y = 8) in;
   layout(rgba32f, binding = 0) uniform image2D u_accum;
   uniform mat4 u_inv_view_proj; uniform vec3 u_cam_pos;
   uniform int  u_sample_index, u_samples_per_frame;

   uint  rng_state;
   uint  pcg(inout uint s) { s = s*747796405u + 2891336453u;
         uint w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u; return (w >> 22u) ^ w; }
   float rnd(inout uint s) { return float(pcg(s)) / 4294967296.0; }

   vec3 ray_dir(vec2 pixel, vec2 jitter, vec2 res) {
       vec2 ndc = ((pixel + jitter) / res) * 2.0 - 1.0;
       vec4 p = u_inv_view_proj * vec4(ndc, 1.0, 1.0);
       return normalize(p.xyz / p.w - u_cam_pos);
   }
   ```

   Seed `rng_state` from pixel coordinates and `u_sample_index` (hash them together) so every sample of every pixel walks a different path. The sub-pixel `jitter` is free anti-aliasing — postcards have no jaggies, another quiet superiority of this renderer.

4. **Intersectors.** Plane is one line; the OBB slab test transforms the ray into box space:

   ```glsl
   // returns hit distance or -1; box space = unit axes, half-extents he
   float hit_obb(vec3 ro, vec3 rd, mat4 inv_xform, vec3 he, out vec3 n) {
       vec3 o = (inv_xform * vec4(ro, 1.0)).xyz;
       vec3 d = (inv_xform * vec4(rd, 0.0)).xyz;
       vec3 inv = 1.0 / d;
       vec3 t0 = (-he - o) * inv, t1 = (he - o) * inv;
       vec3 tmin3 = min(t0, t1), tmax3 = max(t0, t1);
       float tn = max(max(tmin3.x, tmin3.y), tmin3.z);
       float tf = min(min(tmax3.x, tmax3.y), tmax3.z);
       if (tn > tf || tf < 0.0) return -1.0;
       // normal = axis of the entering slab, world space, sign from box-space origin
       n = vec3(tn == tmin3.x, tn == tmin3.y, tn == tmin3.z) * sign(-d);
       n = normalize((transpose(inv_xform) * vec4(n, 0.0)).xyz);
       return tn;
   }
   ```

   The terrain is a **heightfield raymarch**: step along the ray (start coarse, ~2 m), and when a sample dips below the height texture's value, binary-search the last interval for the crossing; normal from central differences of the same texture — the exact math of ch22, evaluated in a new way. Not sphere tracing in the strict SDF sense (a heightfield isn't a distance field), but the same shape of algorithm, and at postcard budgets, robust and simple beats clever.

5. **The heart — one path:**

   ```glsl
   vec3 trace(vec3 ro, vec3 rd, inout uint rng) {
       vec3 radiance = vec3(0.0), throughput = vec3(1.0);
       for (int bounce = 0; bounce < 6; bounce++) {
           Hit h = intersect_scene(ro, rd);             // ocean | terrain | boat OBBs
           if (h.t < 0.0) {                             // escaped:
               bool primary = (bounce == 0);
               radiance += throughput * sky_color_pt(rd, u_sun_dir, primary);
               break;                                   // sun disk ONLY on primary rays
           }
           // next-event estimation: one jittered ray toward the sun's disk
           vec3 sdir = sample_sun_cone(u_sun_dir, rng); // ~0.5 deg half-angle
           if (dot(sdir, h.n) > 0.0 && !occluded(h.p + h.n*1e-3, sdir))
               radiance += throughput * h.albedo/PI * u_sun_radiance * dot(sdir, h.n);
           // bounce: mirror if smooth metal-ish, else cosine-weighted diffuse
           if (h.metallic > 0.5 && h.roughness < 0.3) {
               rd = reflect(rd, h.n);                   // throughput *= F ~ albedo
               throughput *= h.albedo;
           } else {
               rd = cosine_hemisphere(h.n, rng);        // pdf cancels cos & 1/PI
               throughput *= h.albedo;
           }
           ro = h.p + h.n * 1e-3;                       // bias: ray-space shadow acne!
           if (bounce >= 2) {                           // russian roulette
               float p = clamp(max(throughput.r, max(throughput.g, throughput.b)), 0.05, 0.95);
               if (rnd(rng) > p) break;
               throughput /= p;
           }
       }
       return radiance;
   }
   ```

   The ocean material: pick reflect vs. "water body" by a fresnel coin-flip (`rnd(rng) < fresnel`) — reflection continues the path; the body returns your deep-water color as throughput-tinted radiance. Crude, watertight, postcard-pretty.

6. **The sky lights both worlds.** `#include "sky_common.glsl"` (your ch29 loader splice) and write `sky_color_pt` as a thin wrapper that calls your `sky_color(dir, sun_dir)` with the sun-disk term suppressed for non-primary rays (pass a flag, like ch47's fog variant did). Stop and notice what just happened: **the same function that your skybox rasterizes, your water reflects, your IBL integrates, and your fog breathes is now the environment light of a path tracer.** Two renderers with not one line of shared pipeline agree on the color of the world, because the world's light *is a function* and both of them call it. This is the single most beautiful consequence of the procedural-sky decision made back in Chapter 27 — enjoy it.

7. **Dispatch and resolve.** Each frame while active:

   ```odin
   gl.UseProgram(pt.trace_shader.id)
   // ... uniforms: inv view-proj, cam pos, sun dir/radiance, boat OBBs, sample_index ...
   gl.BindImageTexture(0, pt.accum, 0, false, 0, gl.READ_WRITE, gl.RGBA32F)
   gl.DispatchCompute(dispatch_size(pt.width, 8), dispatch_size(pt.height, 8), 1)
   gl.MemoryBarrier(gl.TEXTURE_FETCH_BARRIER_BIT)
   pt.sample_index += pt.samples_per_frame
   ```

   In the kernel: run `u_samples_per_frame` paths, average them, then `imageStore(accum, id, u_sample_index == 0 ? new : old + new)`. The resolve pass is a fullscreen triangle into the HDR target writing `accum / float(N)` — then your tonemap, bloom-free (skip bloom here; the converged image needs no help), ACES, gamma. Draw `"postcard: 312 spp"` on the HUD.

8. **Frame, press, wait, save.** Anchor at golden hour, boat broadside to the sun, island behind. P (photo mode), P (postcard). Watch the first frames — static-noise chaos — resolve into an image over seconds-to-minutes. This is *offline-style rendering*; the slowness is not a bug to fix but the price of evaluating the true integral, and watching the noise melt is the whole show. F11 when it's clean.

## Checkpoint

Render the same composition twice — once raster (a normal F11), once postcard — and put them side by side. Look for what the path tracer gives you *for free* that Parts 7 and 9 made you sweat for, plus two things you never got at all:

- **Soft shadows:** the mast's shadow is sharp at its base and visibly penumbral at its tip — that's the sun-disk jitter in NEE, no PCF, no cascades, no bias tuning.
- **Color bleeding:** grass-green glow on the hull's shaded side, sand-warm light under the boom. No technique in your raster renderer can do this; here it's just bounce two.
- **Perfect reflections:** the boat's reflection in calm water has no SSR edge-fade, no missing backsides — rays don't run out of screen.
- Noise halves when the spp counter quadruples (eyeball 64 vs 256) — Monte Carlo's contract, visible.
- Sky, sun color, and water hue *match the raster image* — shared `sky_color`, shared tonemap.

## Pitfalls

- **Image gets darker/blotchier as it converges, never cleaner.** NaN poisoning: one `0/0` (often a degenerate normal or pdf) infects its pixel forever via accumulation. Guard with `if (any(isnan(s))) s = vec3(0);` before the store, then find the source.
- **Blinding white pixels that never average out — "fireflies."** A rare path found a huge radiance through a tiny pdf. Clamp per-sample radiance (e.g. `min(s, vec3(20.0))`) — technically biased, universally done.
- **Sun shadows AND a doubled sun glare.** Double counting: bounce rays see the sun disk in the sky *and* NEE samples it. Suppress the disk for non-primary rays (step 6's flag).
- **Black speckles on every surface.** Self-intersection — the bounced ray hits its own origin surface. Shadow acne, ray-tracing edition (the ch39 disease in a new body); the `1e-3` normal offset is the bias, and like ch39, too much detaches contact shadows.
- **Postcard is gamma-wrong vs. the raster view.** You tonemapped or gamma'd inside the kernel. Accumulate *linear radiance only*; the ch40 law — tonemap owns gamma, applied once — governs this renderer too.
- **Everything works but converges absurdly slowly in shade.** NEE missing or broken — without it you're waiting for random rays to find a half-degree sun. Check the occlusion test's ray origin bias and the sun cone angle.

## Exercises

1. **Depth of field, five lines:** jitter the ray *origin* across a small lens disk and aim at a focal-distance point. Your postcards gain real bokeh; photo mode grows an aperture slider.
2. **True GGX importance sampling** for the boat's metals (PBRT's chapter on sampling reflection functions, or Karis's "Real Shading in Unreal Engine 4" course notes): sample the half-vector from the NDF, reflect, weight. Rough brass at sunset is the payoff.
3. **Turntable postcards:** while converged, orbit the camera 1° per second, resetting accumulation each step but warm-starting from 16 spp — a slow, dreamlike fly-around. Capture frames, make a GIF.
4. **Stretch — a real mesh:** load the boat's actual triangles, build a flat 2-level BVH on the CPU (split on the longest axis, ~20 lines), upload nodes+triangles as SSBOs, and traverse it in the kernel. This is precisely the data structure the RT cores in modern GPUs build and walk in hardware — Vulkan exposes them as *ray queries*, and Chapter 88 picks up that thread. You'll have written the software version of the future.

## Commit

`git commit -m "ch86: progressive compute path tracer - postcard mode"`

[← Ch. 85: The Resolution Illusion](ch85-the-resolution-illusion.md) · [Ch. 87: Cargo Overboard →](ch87-cargo-overboard.md)
