# Chapter 57 — Shadows Far and Near

*Part 9 — The Deep Engine · Estimated time: 6–8h · learnopengl: [Cascaded Shadow Mapping (guest)](https://learnopengl.com/Guest-Articles/2021/CSM)*

**What you'll see when done:** crisp shadows under the boat's rigging *and* real shadows on islands two kilometers off the bow — at the same time, with no shimmer when you turn the helm.

## Where we are

Chapter 39's shadow map follows the camera inside one orthographic box — and that box has been quietly lying to you ever since. Make it small enough for sharp deck shadows and distant islands fall outside it (no shadows past 100 m); make it big enough for the archipelago and your 2048² texels stretch to half a meter each (deck shadows become staircase mush). One resolution cannot serve two scales. **Cascaded shadow maps** end the compromise: several shadow maps, each covering a *slice* of the view frustum — small and sharp near the camera, large and coarse in the distance, exactly matching how perspective spends your pixels.

## Concepts

### The texel-density argument

A screen pixel 5 m away covers ~1 cm of world; a pixel on a far island covers meters. Shadow quality is about matching *shadow-map texel size* to *screen pixel footprint*. One ortho box gives constant texel size everywhere — wrong at both ends. Cascades approximate the ideal logarithmic falloff with a staircase:

```
 camera ►  [ cascade 0 ][  cascade 1  ][    cascade 2    ][      cascade 3      ]
 view dist 0.1m       15m            60m               220m                 800m
 texel ≈   7mm          3cm            10cm               40cm     (2048² each)
```

### Splitting the frustum

Uniform splits waste texels far away; pure logarithmic splits starve the mid-range. The standard practical scheme (from the original PSSM paper) blends them with λ:

```
d_i = λ · n·(f/n)^(i/N)  +  (1−λ) · (n + (i/N)·(f−n))      λ ≈ 0.5–0.9
```

With `n=0.1, f=800, N=4, λ=0.75` you get splits near 15 / 60 / 220 / 800 — tune to taste. Cap shadow distance well below the camera far plane (nobody needs shadows at 5 km; fog owns that range anyway).

### Fitting each cascade — and not shimmering

Per cascade: take its view-frustum slice, find the 8 corners in world space, and build a light-space ortho box around them — conceptually ch39, per slice. But the naive tight fit *changes size and position every time the camera moves*, so shadow texels constantly re-grid and edges crawl. Two-part stabilization:

1. **Constant size:** bound the slice with its **enclosing sphere** (radius depends only on the projection, not camera pose) and make the ortho box a fixed cube around that sphere. Rotating the camera no longer changes the box's size.
2. **Texel snapping:** the box still *translates* with the camera — so quantize: transform the sphere center to light space, snap x/y to whole multiples of `world_units_per_texel = diameter / resolution`, transform back. The shadow grid now moves in texel-sized jumps that are invisible by construction.

Extend the box's near plane generously backward (`z` range × ~3 or a fixed pull-back) so a tall island *behind* the slice still casts into it.

### One texture to rule them: the array

Four separate shadow FBOs would work; a **2D array texture** is cleaner — one `gl.TEXTURE_2D_ARRAY` of `DEPTH_COMPONENT32F` with 4 layers, one FBO, re-attaching each layer with `gl.FramebufferTextureLayer` per cascade pass, one sampler in the shader.

> **Sidebar — `sampler2DArrayShadow` and hardware PCF.** Declare the sampler as a *shadow* sampler and set `gl.TEXTURE_COMPARE_MODE = gl.COMPARE_REF_TO_TEXTURE` (+ `COMPARE_FUNC = gl.LEQUAL`): `texture(u_cascades, vec4(uv, layer, ref_depth))` then returns a pre-filtered comparison *result* in [0,1] — with `LINEAR` filtering, the hardware compares 4 neighboring texels and bilinearly blends the outcomes. Your ch39 3×3 PCF loop on top of that effectively becomes ~6×6-quality for the same 9 taps. Free money; take it.

### Choosing and blending cascades

In the fragment shader, pick the cascade by comparing **view-space depth** against the split distances, then transform the world position by that cascade's light matrix. At a split boundary the texel density jumps 3–4× — a visible line across the terrain — so blend: within a band (~10%) of a split, sample both cascades and `mix` by position in the band.

```glsl
int layer = 3;
for (int i = 0; i < 4; i++)
    if (view_depth < u_splits[i]) { layer = i; break; }
float s = shadow_sample(layer, world_pos);
float band = 0.1 * u_splits[layer];
if (layer < 3 && u_splits[layer] - view_depth < band)
    s = mix(shadow_sample(layer + 1, world_pos), s,
            (u_splits[layer] - view_depth) / band);
```

Bias scales with the cascade — far cascades have huge texels and need proportionally larger slope-scaled bias (`bias_i ∝ world_units_per_texel_i`), or distant islands acne while the deck peter-pans.

## Odin notes

The fitting code is pure `linalg/glsl`: `glsl.mat4LookAt(center - sun_dir * back_dist, center, up)` for the light view and `glsl.mat4Ortho3d(-r, r, -r, r, near, far)` for the cube around the sphere (same proc as ch39). Upload the four matrices as one call: they're contiguous in a `[4]glsl.mat4`, so `gl.UniformMatrix4fv(loc, 4, false, &mats[0][0, 0])` with `uniform mat4 u_light_mats[4]` on the GLSL side; the splits ride in a single `vec4`. Allocate the array texture immutably now that you have 4.3: `gl.TexStorage3D(gl.TEXTURE_2D_ARRAY, 1, gl.DEPTH_COMPONENT32F, size, size, 4)`.

## Build

1. **`Shadow_Cascades`.** Replacing the ch39 single-map struct:

   ```odin
   CASCADE_COUNT :: 4

   Shadow_Cascades :: struct {
       fbo:        u32,
       tex:        u32,                          // TEXTURE_2D_ARRAY, depth
       size:       i32,                          // 2048
       mats:       [CASCADE_COUNT]glsl.mat4,     // light proj*view per cascade
       splits:     [CASCADE_COUNT]f32,           // far edge of each, view space
       distance:   f32,                          // total shadow range, ~800
       lambda:     f32,                          // 0.75
   }
   ```

   Create the array texture (`TexStorage3D` as above), `COMPARE_REF_TO_TEXTURE`, `LINEAR` filtering, `CLAMP_TO_BORDER` with border color 1.0 (`gl.TexParameterfv(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_BORDER_COLOR, &border[0])`) so outside-the-box means "lit," and one FBO with no color buffer (`gl.DrawBuffer(gl.NONE)` — as in ch39).

2. **Split computation.** `cascades_update(sc, camera, sun_dir)` each frame. The λ-blend:

   ```odin
   n, f := f32(0.1), sc.distance
   for i in 1 ..= CASCADE_COUNT {
       p   := f32(i) / CASCADE_COUNT
       log := n * math.pow(f / n, p)
       lin := n + p * (f - n)
       sc.splits[i - 1] = math.lerp(lin, log, sc.lambda)
   }
   ```

   Then per cascade build the slice's enclosing sphere. Cheapest correct route: compute the 8 slice corners in world space (inverse of `proj_slice * view` applied to the NDC cube, with `proj_slice` using that slice's near/far), center = average, radius = max distance to a corner — then *round the radius up* (e.g. to 0.5 m) to stabilize against float wobble.

3. **Fit + snap.**

   ```odin
   texel := 2 * radius / f32(sc.size)
   light_view := glsl.mat4LookAt(center - sun_dir * (radius * 3), center, UP)
   c := (light_view * glsl.vec4{center.x, center.y, center.z, 1}).xyz
   c.x = math.floor(c.x / texel) * texel     // snap in light space
   c.y = math.floor(c.y / texel) * texel
   // rebuild light_view aimed at the snapped center (inverse-transform c back)
   proj := glsl.mat4Ortho3d(-radius, radius, -radius, radius, 0.1, radius * 6)
   sc.mats[i] = proj * light_view
   ```

   (Equivalently — and easier — snap by adjusting the ortho box's left/right/bottom/top by the sub-texel remainder. Either way: the *grid* must move in whole texels.)

4. **Render pass.** For each cascade: `gl.FramebufferTextureLayer(gl.FRAMEBUFFER, gl.DEPTH_ATTACHMENT, sc.tex, 0, i32(cascade))`, clear depth, draw casters with that cascade's matrix. Keep ch49's discipline: casters list ⊂ drawables (no grass in cascade 3), and cull per cascade against its box — cascade 0 draws a fraction of the scene. Wrap each in a `gl.PushDebugGroup` ("cascade 0"…) for RenderDoc.

5. **Receiver side.** In the deferred lighting shader (and the shared `#include` so forward surfaces agree): `sampler2DArrayShadow`, the selection + blend logic from Concepts, your ch39 3×3 PCF loop now calling the hardware-compare `texture(...)` per tap, per-cascade bias scale. View-space depth for selection: you already reconstruct view position for SSAO — reuse `-view_pos.z`.

6. **Debug tint.** A panel toggle multiplying the lit scene by a cascade color key (red/green/blue/yellow). Sail: rings of color should travel with you, boundaries roughly where your splits say. Keep this toggle forever; it's the first thing you'll reach for when shadows misbehave at sea.

7. **Tune.** `lambda` and `distance` sliders in the panel. Verify the two promises: deck shadow sharp (compare ch39 screenshots), island 1.5 km away has actual shadows on its western cliffs at sunset.

## Checkpoint

Sunset, looking down the archipelago: rigging shadows crisp on the deck, palm shadows visible on an island far ahead, and slowly turning the camera produces **zero** edge crawl.

- Debug tint shows 4 stable distance bands that move with the camera and don't pulse when you only *rotate* (sphere fit working).
- Spin the camera in place watching one deck shadow edge: no shimmer (snapping working). Comment out the snap lines and confirm it returns — then restore.
- No visible brightness line at split boundaries on open terrain (blending working); toggle the blend band to 0 to see what you fixed.
- Shadow pass GPU ms ≈ 2–4× ch39's, not 4× the *whole frame* (per-cascade culling working).

## Pitfalls

- **Shadows vanish past the first split.** Selection compares against the wrong quantity (world distance vs view-space `-z`), or `u_splits` uploaded in a different unit/order than the CPU computed. Print both; tint view tells you instantly which cascade a pixel chose.
- **Edges still shimmer.** Snapping happens in the wrong space (must be light/texture space, not world), or radius wobbles (round it up), or you snapped *before* building the final ortho. Re-check step 3 ordering.
- **Acne on far islands only.** Bias constant across cascades. Scale it by each cascade's texel size; also confirm your ch39 slope-scale term survived the refactor.
- **A hard diagonal line of wrong shadow across the sea.** A caster outside a cascade's box clipped by its near plane — extend the light-space z pull-back (the `radius * 3`), and keep `CLAMP_TO_BORDER` = 1.0 so out-of-map lookups read "lit."
- **`texture()` returns 0/1 with no softening.** Filtering is `NEAREST`, or `TEXTURE_COMPARE_MODE` unset (then a shadow sampler's behavior is undefined — the ch53 callback usually flags the sampler/texture mismatch).
- **Everything in cascade 3's tint.** The loop's `break` missing or splits ascending in the wrong order — classic copy-paste casualty.

## Exercises

1. Make `CASCADE_COUNT` honestly configurable (2/3/4 at startup) and find Saltwind's sweet spot — many sea-heavy scenes are happy with 3.
2. Resolution ratio experiment: 4×1024 vs 4×2048 vs 2×4096 — same memory for two of these. Screenshot the deck and the far island for each; write down which you'd ship.
3. Visualize a cascade's depth map in the corner of the screen (you wrote this for ch39 — port it to array layers with a `u_layer` uniform). Watch the snap quantize its motion as you sail.
4. **Stretch:** shadow caster *caching* — cascade 3 changes slowly (it's huge); re-render it only every 4th frame or when the sun/camera moves past a threshold, reusing the stored map otherwise. Measure the win, and note the artifact you've accepted (objects "lag" into far shadows).

## Commit

`git commit -m "ch57: cascaded shadow maps — 4 stabilized cascades in an array texture, hardware PCF, seam blending"`

[← Ch. 56: Shadows in Corners](ch56-shadows-in-corners.md) · [Ch. 58: Mirrors of the Sea →](ch58-mirrors-of-the-sea.md)
