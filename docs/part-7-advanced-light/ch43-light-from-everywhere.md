# Chapter 43 — Light from Everywhere

*Part 7 — Advanced Light · Estimated time: 6–8h · learnopengl: [IBL: Diffuse Irradiance](https://learnopengl.com/PBR/IBL/Diffuse-irradiance), [IBL: Specular IBL](https://learnopengl.com/PBR/IBL/Specular-IBL)*

**What you'll see when done:** the shaded side of your boat is blue at noon, orange at sunset, and moonlit-gray at night — because the *sky itself* is now a light source, and your sky changes.

## Where we are

Chapter 42 left one ugly survivor: `ambient = vec3(0.03) * albedo`. A constant. But ambient light isn't constant — it's the sum of light arriving from the entire sky and environment, and you have spent half this course building a *procedural sky that changes by the minute*. This chapter is the payoff of Chapter 27: we capture your own sky into a cubemap and precompute the rendering-equation integral against it, so every material is lit by the actual heavens above it. When the sun sets, the whole world relights. This is the most "engine programmer" chapter in the course; the math is ch42's, applied at scale.

## Concepts

### The problem: the integral we dodged

Direct lighting collapsed the rendering equation to a sum over a few light directions. Image-based lighting (IBL) refuses the collapse: light arrives from *every* direction of the environment map. Computing a hemisphere integral per fragment per frame is absurd — so we **precompute** it into lookup textures, exploiting one observation: the integral's *inputs* are few (surface normal; plus roughness and view angle for specular). Precompute the answer for every input, store in cubemaps, sample at runtime.

### Step 0: your sky becomes a cubemap

learnopengl loads an HDR photograph of an environment. You have something better: a *function* — your ch27 sky shader. Render it six times, once per cube face, with 90° FOV cameras looking ±X, ±Y, ±Z from the origin, into the faces of an RGBA16F cubemap (128² per face is plenty for a smooth sky). Re-capture when the time of day moves enough to matter.

```
            +----+
            | +Y |
       +----+----+----+----+
       | -X | +Z | +X | -Z |     6 renders of sky_color(dir),
       +----+----+----+----+     90° fov, one per face
            | -Y |
            +----+
```

### Diffuse: the irradiance map

For diffuse (Lambertian) lighting, the integral depends on **only the normal**: irradiance arriving at a surface facing direction N is a cosine-weighted average of the whole hemisphere around N. So: build a tiny cubemap (32² faces!) where each texel at direction N stores that average — a massively blurred version of the sky. Runtime cost: one texture fetch.

```glsl
// irradiance_convolve.frag — per output direction N, integrate the hemisphere
vec3 irradiance = vec3(0.0);
float samples = 0.0;
for (float phi = 0.0; phi < TWO_PI; phi += 0.05)
for (float theta = 0.0; theta < HALF_PI; theta += 0.05) {
    vec3 t = vec3(sin(theta) * cos(phi), sin(theta) * sin(phi), cos(theta));
    vec3 dir = t.x * right + t.y * up + t.z * N;       // tangent -> world
    irradiance += texture(u_sky_cube, dir).rgb * cos(theta) * sin(theta);
    samples += 1.0;
}
irradiance = PI * irradiance / samples;
```

The `sin(theta)` corrects for spherical-coordinate sample bunching at the pole; the final π is the Lambert normalization meeting the cosine-weighted sum.

### Specular: split-sum, prefiltered mips, and the BRDF LUT

Specular is harder: the integral depends on normal, **view angle**, *and* **roughness**. Epic's **split-sum approximation** (Karis 2013 — the paper that defined a console generation) breaks it into two precomputable halves:

1. **Prefiltered environment map.** The sky cubemap convolved with the GGX lobe at increasing roughness — stored in the **mip chain** of one cubemap: mip 0 = mirror (roughness 0), mip 4 = very rough. At runtime: `textureLod(u_prefiltered, R, roughness * MAX_MIP)`. The convolution importance-samples GGX directions around the reflection vector (the `importance_sample_ggx` function is built from a low-discrepancy Hammersley sequence — learnopengl's [Specular IBL](https://learnopengl.com/PBR/IBL/Specular-IBL) derives it step by step; implement it from there, it's ~20 lines).
2. **BRDF LUT.** What remains is a 2D function of `(N·V, roughness)` only — environment-independent, material-independent. Bake it once into a 512² RG16F texture: red = scale on F0, green = bias. It's the same texture in every engine on earth; generate it with one fullscreen pass at startup (or embed the bytes — but you have a GPU, generating takes 2 ms).

Runtime assembly, replacing the constant ambient:

```glsl
vec3 F = f_schlick_roughness(max(dot(N, V), 0.0), F0, roughness);
vec3 kD = (1.0 - F) * (1.0 - metallic);

vec3 irradiance = texture(u_irradiance, N).rgb;
vec3 diffuse    = irradiance * albedo;

vec3 R = reflect(-V, N);
vec3 prefiltered = textureLod(u_prefiltered, R, roughness * 4.0).rgb;
vec2 brdf = texture(u_brdf_lut, vec2(max(dot(N, V), 0.0), roughness)).rg;
vec3 specular = prefiltered * (F * brdf.x + brdf.y);

vec3 ambient = (kD * diffuse + specular) * ao;
```

(`f_schlick_roughness` is Schlick with `max(vec3(1.0 - roughness), F0)` replacing the 1.0 — damps grazing reflections on rough surfaces; one line, in the learnopengl article.)

### When to rebuild

Your sun moves. Rebuilding every frame is wasteful (and the prefilter isn't free); rebuilding never is wrong. Sweet spot: re-capture + reconvolve when the sun direction has rotated more than ~2° since the last build, and *amortize* — one cube face or one mip per frame — so there's no hitch. At default day-cycle speed that's a rebuild every few seconds, imperceptible since the sky changes smoothly anyway.

## Odin notes

Rendering to cubemap faces is plain GL — `gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_CUBE_MAP_POSITIVE_X + u32(face), cube_tex, mip)` — and the six view matrices are a fixed table worth writing as a global constant: `CUBE_VIEWS := [6]glsl.mat4{...}` using `glsl.mat4LookAt` with the standard (eye, center, up) triples from the learnopengl article (mind the upside-down ups; cubemaps inherit RenderMan's coordinate quirks). The capture projection is `glsl.mat4Perspective(glsl.radians_f32(90), 1.0, 0.1, 10.0)`.

## Build

1. **An `Environment` struct** owned by `Renderer`:

   ```odin
   Environment :: struct {
       sky_cube:    u32, // 128^2 RGBA16F cubemap, mipmapped
       irradiance:  u32, // 32^2  RGBA16F cubemap
       prefiltered: u32, // 128^2 RGBA16F cubemap, 5 mips
       brdf_lut:    u32, // 512^2 RG16F 2D texture
       capture_fbo: u32,
       built_sun_dir: glsl.vec3, // rebuild trigger
   }
   ```

   Allocate all textures up front (`gl.TexImage2D` per face per mip; for the prefiltered map use `gl.TexParameteri(..., gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR)` and allocate mips 0–4).

2. **Sky capture pass.** Reuse your ch27 sky fragment shader with a capture vertex shader (unit cube, view without translation — you have this pattern from the skybox). For each face: attach, set viewport to face size, set the face's view matrix, draw. Then `gl.GenerateMipmap(gl.TEXTURE_CUBE_MAP)` on the sky cube — the prefilter samples its mips to fight fireflies.

3. **Irradiance convolution pass.** New shader `irradiance.frag` with the double loop above; render to each face of the 32² irradiance cube, sampling the sky cube. Six draws, done in a millisecond.

4. **Prefilter pass.** New shader `prefilter.frag` with GGX importance sampling (Hammersley + `importance_sample_ggx` from the learnopengl article; ~1024 samples). For mip 0..4: `roughness = f32(mip) / 4.0`, set viewport to the mip's size, render all 6 faces at that mip.

5. **BRDF LUT.** One fullscreen-triangle pass (ch40 trick pays again) into the RG16F texture at startup, with the integration shader from the article. Or, if you'd rather not: precomputed LUT images are embeddable — but generating is genuinely less code than loading.

6. **Wire into `pbr.frag`.** Three new samplers (units 5–7, say), and replace the placeholder ambient with the assembly snippet from Concepts. Delete `vec3(0.03)` with ceremony.

7. **Rebuild logic.** In the frame update:

   ```odin
   if glsl.dot(env.built_sun_dir, sky.sun_dir) < math.cos(glsl.radians_f32(2)) {
       environment_rebuild(&renderer.env, &game.sky) // or enqueue amortized steps
       renderer.env.built_sun_dir = sky.sun_dir
   }
   ```

   Start with the blocking rebuild; amortize per-face if you see a hitch.

8. **Recalibrate.** Bring back the ch42 sphere rows. Metals now *work* — they mirror your sky. Walk the time of day across noon → sunset → night and watch every sphere follow.

## Checkpoint

Noon: shaded hull surfaces are cool blue (skylight), the brass fittings mirror a blue-white sky. Sunset: shadows warm to orange, metals catch the sun's smear along the horizon. Night: the world is dim blue-gray, lit by your moon-and-stars sky — *and you never touched a material*.

- The roughness-0 metal sphere shows a recognizable (blurry-at-128²) reflection of your actual sky, sun disk included.
- Sweep roughness 0→1 on a metal sphere: reflection blurs smoothly through the mip chain with no visible mip-pop.
- Toggle IBL off (bind black cubemaps via a debug key): the scene drops back to ch42's dead-ambient look. Keep this toggle; it's the best before/after in the course.
- Speed up the day cycle: ambient color tracks the sky with no hitching (amortized rebuild) and no stale-sky lag beyond a couple of degrees of sun travel.

## Pitfalls

- **Black ambient everywhere.** Capture FBO incomplete (mip-size viewport mismatch is the usual cause), or you're sampling cubemaps without binding them — check with a debug shader that outputs `texture(u_irradiance, N).rgb` directly.
- **Fireflies / sparkly noise in rough reflections.** Prefilter sampling mip 0 of an HDR sky with a tiny brilliant sun = variance city. Sample the sky cube's *mips* in the prefilter (`textureLod` with a roughness-scaled lod), and make sure you generated them in step 2.
- **Seams along cube edges.** Enable `gl.Enable(gl.TEXTURE_CUBE_MAP_SEAMLESS)` once at init — exists precisely for this, core since 3.2.
- **Irradiance map looks like the sky, not a blur of it.** Your tangent basis in the convolution shader is degenerate when N ≈ up; pick the basis-building `up` vector as `abs(N.y) < 0.99 ? vec3(0,1,0) : vec3(1,0,0)`.
- **Everything is lit double.** You're adding IBL ambient *and* still adding the sun via the irradiance map *and* via direct lighting. That's actually correct — the sun disk is in the captured sky — but its tiny solid angle contributes almost nothing to irradiance; the real bug is usually adding the old constant ambient on top. Delete it.
- **Hitch every few seconds.** That's the blocking rebuild; amortize (face per frame), or shrink prefilter sample counts for higher mips (rough mips need far fewer than 1024).

## Exercises

1. Lantern glass at night: emissive stays, but now watch the *deck* under the lantern — point light direct + warm IBL is the moment Saltwind's nights stop being gray soup.
2. Drop irradiance to 8² and prefiltered to 32²: find the size where you can actually tell the difference. (Spoiler: diffuse irradiance is shockingly compressible.)
3. Use the sky cube to replace the ch29 ocean's analytic sky reflection sampling — one source of truth for "what does the sky look like in direction R," and the ocean inherits sunset for free. Compare against the planar reflection FBO; decide which the ocean should keep (many games: cubemap far, planar near).
4. **Stretch:** capture the environment from the *boat's position* including terrain (render the full scene, not just sky, into the cubemap at low res, sun-shadowed). Islands now occlude and tint reflections. This is one step from local reflection probes — read about parallax-corrected cubemaps if it hooks you.

## Commit

`git commit -m "ch43: image-based lighting from the procedural sky — irradiance, prefiltered specular, BRDF LUT"`

[← Ch. 42: Physically Based](ch42-physically-based.md) · [Ch. 44: Milestone — Golden Hour →](ch44-milestone-golden-hour.md)
