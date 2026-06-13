# Chapter 56 — Shadows in Corners

*Part 9 — The Deep Engine · Estimated time: 4–6h · learnopengl: [SSAO](https://learnopengl.com/Advanced-Lighting/SSAO)*

**What you'll see when done:** the boat's deck fittings sit *in* the deck instead of floating on it — soft contact darkening in every crevice, corner, and rock crack, driven by your new G-buffer.

## Where we are

Chapter 43 made the sky light everything — including, dishonestly, the inside of corners. Real ambient light gets *occluded*: a crevice sees less sky than an open deck, so it should receive less IBL. The full answer is global illumination; the screen-space answer that shipped a thousand games is **SSAO** (Crysis, 2007): estimate, per pixel, how much nearby geometry blocks the ambient hemisphere — using only the depth and normals you already have. This is the first technique that exists *because* of ch55: the G-buffer hands us position and normal for free.

## Concepts

### Ambient occlusion, the idea

For each surface point, ask: of the hemisphere of directions around the normal, what fraction is blocked by nearby geometry? That fraction — **occlusion** — should attenuate *ambient* light (light arriving from everywhere). A point at the bottom of a crevice might see 30% of its hemisphere; an open deck plank sees ~100%. The result is the soft darkening photographers know from corners and contact points, and it's the strongest cheap cue for "these objects actually touch."

### The screen-space estimate

We can't trace rays against the scene, but the depth buffer *is* the scene, from one viewpoint. So:

```
                 view space, hemisphere around N
                        s2      s3
                    s1   ·     ·          for each sample s:
                  ·   \  |   /              project s -> uv
            ______\____\_|__/______         scene_depth = depth at uv
                   \    (P)------N          if scene is in FRONT of s
            ███████████████                    -> s is inside geometry
              (depth buffer)                   -> occluded
```

Take N sample points in a hemisphere oriented along the surface normal at P (all in **view space**); project each to screen; compare the sample's depth against the depth buffer there. Samples buried behind recorded geometry count as occluded; `occlusion = occluded / N`, then `ao = 1 - occlusion`, raised to a power for contrast. It's biased and view-dependent — offscreen and behind-the-front-surface geometry is invisible to it — and it still reads as *exactly right* to the eye.

### The three classic refinements (all load-bearing)

- **Cosine-ish kernel.** Random hemisphere points, but scaled so they bunch near P: `scale = lerp(0.1, 1.0, (i/N)²)`. Near occluders matter most; this puts your 32 samples where they count.
- **The 4×4 rotation noise.** 32 samples is too few — you'd see banding. Instead of more samples, give each pixel a *random rotation* of the kernel: a tiny 4×4 texture of random vectors, tiled across the screen (`uv * screen_size / 4`). Banding becomes high-frequency noise, and noise is exactly what a small **blur** erases — a 4×4 box blur matching the noise tile, ideally weighted to not bleed across depth edges (the "bilateral-ish" blur).
- **The range check.** A mast 30 m behind a sky-adjacent pixel would "occlude" it without one. Scale contribution by proximity: `range = smoothstep(0.0, 1.0, radius / abs(P.z - scene_z))`. No range check = dark halos around every silhouette.

### Where AO is applied — and where it must never be

AO attenuates **ambient/indirect** light only: in your deferred lighting pass, multiply the IBL term (`kD * diffuse + specular`) by it. **Do not multiply direct sun light** — the sun is not "light from everywhere"; its occlusion is called a *shadow* and ch39/ch57 already compute it properly. Multiplying direct light by AO is the most common SSAO integration mistake, and it reads as grime smeared over sunlit surfaces. (Leave emissive alone too — lantern glass doesn't self-shadow its own glow.)

```glsl
vec3 ambient = (kD * diffuse + specular) * texture(u_ssao, v_uv).r;
vec3 color   = direct_sun /* untouched! */ + ambient + emissive;
```

Further reading once this ships: **HBAO** (horizon-based, marches the depth field for the actual horizon angle) and **GTAO** (ground-truth AO, Activision 2016 — the modern standard, adds cosine weighting and a bent-normal output). Same inputs, better estimators.

## Odin notes

Kernel and noise generation want `core:math/rand`: `rand.float32()` gives [0,1). Build the kernel once at startup into a `[64]glsl.vec3` and upload via `gl.Uniform3fv(loc, 64, &kernel[0][0])` — or, now that you're on 4.3, a small UBO. The noise texture is a 4×4 RGBA16F upload of `vec3(rand*2-1, rand*2-1, 0)` vectors with `gl.REPEAT` wrapping — the z=0 keeps them tangent-plane rotations.

## Build

1. **Decide your space.** Your G-buffer stores *world* normals; SSAO math is cleanest in *view* space. In the SSAO shader, transform: `N = normalize(mat3(u_view) * world_normal)`, and reconstruct `P` with the ch55 `view_pos_from_depth` (stop before the inverse-view step). Radius stays in meters — view space is a rigid transform of world space, distances are identical.

2. **Kernel + noise at startup.**

   ```odin
   ssao_kernel: [64]glsl.vec3
   for i in 0 ..< 64 {
       s := glsl.vec3{rand.float32()*2-1, rand.float32()*2-1, rand.float32()}
       s = glsl.normalize(s) * rand.float32()
       scale := f32(i) / 64.0
       s *= math.lerp(f32(0.1), 1.0, scale * scale) // bunch near origin
       ssao_kernel[i] = s
   }
   ```

   Note `z = rand.float32()` (not `*2-1`): hemisphere, not sphere. The noise texture:

   ```odin
   noise: [16]glsl.vec3
   for &n in noise do n = {rand.float32()*2-1, rand.float32()*2-1, 0}
   gl.GenTextures(1, &ssao_noise_tex)
   gl.BindTexture(gl.TEXTURE_2D, ssao_noise_tex)
   gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA16F, 4, 4, 0, gl.RGB, gl.FLOAT, &noise[0])
   gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST)
   gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST)
   gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.REPEAT)
   gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.REPEAT)
   ```

3. **Two small targets.** `ssao_raw` and `ssao_blur`, single-channel `gl.R8`, screen size (half resolution is a classic save — exercise 3). They slot into the frame between geometry and lighting, exactly where the ch55 diagram reserved the spot.

4. **`ssao.frag`.** Fullscreen pass reading G-buffer depth + normal + noise:

   ```glsl
   vec3 P = view_pos_from_depth(v_uv, texture(u_depth, v_uv).r);
   vec3 N = normalize(mat3(u_view) * texture(u_g_normal, v_uv).xyz);
   vec3 rnd = texture(u_noise, v_uv * u_noise_scale).xyz;
   vec3 T = normalize(rnd - N * dot(rnd, N));   // Gram-Schmidt
   mat3 TBN = mat3(T, cross(N, T), N);

   float occlusion = 0.0;
   for (int i = 0; i < 64; i++) {
       vec3 s = P + (TBN * u_kernel[i]) * u_radius;
       vec4 o = u_proj * vec4(s, 1.0);
       o.xyz = o.xyz / o.w * 0.5 + 0.5;
       float scene_z = view_pos_from_depth(o.xy, texture(u_depth, o.xy).r).z;
       float range = smoothstep(0.0, 1.0, u_radius / abs(P.z - scene_z));
       occlusion += (scene_z >= s.z + u_bias ? 1.0 : 0.0) * range;
   }
   frag = pow(1.0 - occlusion / 64.0, u_power);
   ```

   (View space looks down −z, so "scene closer to camera than sample" is `scene_z >= s.z + bias`.) Start with `radius 0.5`, `bias 0.025`, `power 1.5`.

5. **Blur pass.** 4×4 box over `ssao_raw` into `ssao_blur`, then make it bilateral-ish — weight each tap by depth closeness so the deck's AO doesn't bleed onto the sea behind it:

   ```glsl
   float center_d = texture(u_depth, v_uv).r;
   float sum = 0.0, wsum = 0.0;
   for (int x = -2; x < 2; x++)
   for (int y = -2; y < 2; y++) {
       float ao = textureOffset(u_ssao_raw, v_uv, ivec2(x, y)).r;
       float d  = textureOffset(u_depth,    v_uv, ivec2(x, y)).r;
       float w  = exp(-abs(center_d - d) * 800.0);
       sum += ao * w; wsum += w;
   }
   frag = sum / wsum;
   ```

   Compare plain box vs bilateral on the boat's railing against the sky.

6. **Wire into lighting.** Bind `ssao_blur` in the deferred lighting pass and multiply *only* the ambient term (Concepts). Add a panel toggle + an "AO only" debug view (output `vec3(ao)`) — the AO-only view is where all tuning happens.

7. **Tune on the two reference scenes.** (a) Boat deck at noon: cleats, mast base, and gunwale corners should show soft contact darkening visible from 5–10 m; if the whole deck darkens, radius is too big or power too high. (b) Terrain crevices on a rocky island: cracks read deeper, cliff-base/beach contact grounds. Sliders for radius/bias/power in the panel; this is feel work, give it twenty minutes.

## Checkpoint

Toggle SSAO on a noon deck shot: with it off, hardware sits *on* the boat; with it on, it sits *in* the boat. Subtle is correct — if you can see "the SSAO effect" from across the harbor, it's overcooked.

- AO-only view: white open surfaces, soft gray in crevices, no banding (noise+blur working), no dark halo ringing the mast against the sky (range check working).
- Sunlit faces are equally bright with AO on/off *except* in their corners — proof you're only touching ambient.
- Camera orbit: AO stays glued to geometry; mild shimmer at screen edges is normal (screen-space life), crawling bands are not.
- GPU cost on the panel: ~0.5–1.5 ms full-res for SSAO+blur. If it's 5 ms, you're full-res 64-tap on a big monitor — see exercise 3.

## Pitfalls

- **Self-occlusion acne — surfaces uniformly dirty-gray.** Bias too small (or zero): a surface's own depth ties against its samples. Raise `u_bias`; if only steep slopes suffer, it's the classic depth-precision-at-grazing-angle problem — a slightly larger bias is fine.
- **Dark halos around silhouettes.** Missing/wrong range check, or radius huge. The mast should not shade the island 200 m behind it.
- **Visible 4×4 checkerboard.** Noise tiled with the wrong `u_noise_scale` (must be `screen_size / 4.0`), noise texture not `REPEAT`, or you skipped the blur.
- **AO swims when the camera turns.** Normals weren't transformed to view space (still world) or P and N are in different spaces — the TBN is then nonsense that changes with view.
- **Everything subtly darker, even open ocean.** You multiplied the whole lighting result (or the ocean's forward shader) by AO. Ambient only, deferred opaque only — the ocean never even renders into the G-buffer.
- **AO flickers between frames at half res.** Depth downsampling mismatch — sample depth with NEAREST and reconstruct at the same resolution you ray-test, or stay full-res until exercise 3.

## Exercises

1. Expose the sun: try multiplying direct light by AO deliberately, screenshot the deck, then undo it. Knowing exactly what the mistake looks like inoculates you forever.
2. Use the G-buffer's spare alpha: bake per-material AO (your OBJ boat's AO texture if it has one, or 1.0) in the geometry pass, and combine `min(ssao, material_ao)` in lighting. Crevice detail finer than SSAO's radius comes from the texture; large-scale contact from SSAO.
3. Half-resolution SSAO + bilateral *upsample* (weight by depth difference against the full-res depth) — the production configuration. Measure, then compare quality on the rigging.
4. **Stretch:** implement the HBAO core idea for comparison: per pixel, march 4 screen-space directions in the depth buffer, track the highest horizon angle per direction, and convert to occlusion. Same inputs, no kernel, often cleaner on terrain. Read the NVIDIA HBAO paper (Bavoil & Sainz 2008) first.

## Commit

`git commit -m "ch56: SSAO — view-space hemisphere kernel, noise rotation, bilateral blur, ambient-only wiring"`

[← Ch. 55: The Deferred Fleet](ch55-the-deferred-fleet.md) · [Ch. 57: Shadows Far and Near →](ch57-shadows-far-and-near.md)
