# Chapter 90 — Light Remembered

*Part 13 — The Captain's Appendices · Standalone: requires Part 9 (the deferred renderer; builds directly on ch43's IBL bakery and ch55's ambient pass) · Estimated time: 7–9h · learnopengl: no direct equivalent — canonical references: [Tatarchuk, "Irradiance Volumes for Games" (GDC Europe 2005)](https://developer.amd.com/wordpress/media/2012/10/Tatarchuk_Irradiance_Volumes.pdf) and [Majercik et al., "Dynamic Diffuse Global Illumination with Ray-Traced Irradiance Fields" (JCGT 2019)](https://jcgt.org/published/0008/02/01/)*

**What you'll see when done:** the ch78 night port, relit: crates under the dock lantern glowing lantern-warm on their *shadow* sides, the hull picking up bounce off the quay, and the under-dock dark actually dark — ambient light that knows where you're standing.

## Where we are

You need ch43's `Environment` (the sky capture + irradiance convolution + prefilter pipeline) and ch55's deferred lighting pass, where the IBL ambient term lives. Ch56's SSAO still multiplies in unchanged; ch39a's lantern shadows and ch78's night port make the showcase sing but aren't load-bearing.

Why this question always comes up: every learner who builds IBL eventually stands somewhere the sky *isn't* — under a roof, beside a lantern, in the lee of a cliff — and notices the lie. Direct light is local (ch55 made sure of it: a hundred lanterns, each reaching only its radius). Ambient light is **global**: one irradiance cubemap, captured from one point, containing only sky. Stand on the lantern-lit dock at midnight and the warm pools of direct light are right — but every shadowed surface is filled with the same moon-blue, as if the dock, the lanterns, and the cliff behind you didn't exist. Two lies in one: no local *occlusion* (SSAO patches the close-range half) and no local *sources or bounce*. Global illumination is the family of fixes; **irradiance probes** are its most shippable member, and — this is the appendix's secret — you already built every hard part in ch43. Today you build it *in many places*.

## Concepts

### A probe is a memory of light

An irradiance probe is a point in space that remembers the answer to "how much light arrives here, from every direction?" — exactly what ch43's irradiance cubemap is, except captured from *inside the scene*, with the scene visible. Lay probes in a grid over the port, bake each one, and at runtime every surface asks the eight probes around it, blended trilinearly — ambient light becomes a *field* instead of a constant.

### Baking is ch43 with the camera moved

Per probe: render the lit scene into a small cubemap from the probe's position — your ch43 capture pass verbatim, except the "scene" is no longer just the sky shader but a cut-down lit scene pass (sun + shadow + lanterns + emissive + sky; no post, no particles). Then run ch43's `irradiance.frag` convolution on it, completely unchanged. The light that lands in the probe includes sunlit surfaces and lantern-lit planks — which means a surface lit by *the probe* receives light that bounced off *those surfaces*. That's not a metaphor: this is real (one-bounce, baked) global illumination, and the entire new machinery is a `for` loop around code from Part 7. The build-it-once philosophy's largest single payout.

### Encoding: you can't keep 64 cubemaps warm

A 32² cubemap per probe is fine to *bake* through but absurd to *sample* — a 12×4×12 grid is 576 probes. The bake must be compressed into a few numbers per probe. Two classic encodings:

- **Ambient cube** (Half-Life 2): six colors, one per axis direction; sample with squared-normal weights. Trivial to understand, slightly faceted results.
- **L1 spherical harmonics** — the one we'll use, and gentler than its reputation. SH is the Fourier series of the sphere: a set of orthogonal basis functions of direction, where keeping only the low-order terms keeps only the smooth part of the signal. Irradiance *is* smooth (the cosine convolution kills high frequencies), so it lives almost entirely in the first two bands. **L0** is one number: the average light from everywhere. **L1** is three numbers: how strongly the light tilts along x, y, z — a "brightness direction." Four RGB coefficients total, and reconstruction is four multiply-adds:

```
E(n) ≈ c0·L00 + c1·( L11·n.x + L1m1·n.y + L10·n.z )      c0 ≈ 0.886, c1 ≈ 1.023
```

Projecting a cubemap *into* those coefficients is a weighted sum over its texels — each texel's color times its basis function value times its solid angle. Twenty lines of CPU loop at bake time (the cubemaps are 32², readback is nothing).

### Storage and the free trilinear blend

Pack the grid into **four small 3D textures** (one per SH coefficient, RGBA16F, sized nx×ny×nz). At runtime, one normalized grid coordinate samples all four with `LINEAR` filtering — and the hardware's trilinear interpolation *is* the eight-probe blend. The deferred ambient pass swaps `texture(u_irradiance, N)` for `sh_irradiance(world_pos, N)`, four taps and a dot product. Specular stays on ch43's global prefiltered map (+ SSR where it applies) — specular GI is a different mountain; say so in the panel tooltip and move on.

### Leaks, and probes inside rocks

Two failure modes own this technique's reputation. **A probe baked inside geometry** records blackness (or garbage) and bleeds it outward through the blend. Detect at bake time — if most of the capture's depth is within a half meter, flag the probe invalid and substitute its nearest valid neighbor's coefficients. **Light leaking through walls**: a surface just inside the dark warehouse blends with probes *outside* in the moonlight, because trilinear weights don't know about the wall. Mitigations, cheap to dear: place grid bounds so walls fall *between* probe planes; sample the field at `P + N * half_spacing` (normal offset — biases toward probes that can actually see the surface); and the real fix — per-probe depth + visibility-weighted blending — is DDGI, your further reading, and you'll recognize every ingredient when you get there.

### Time of day: rebake on a budget

The sun moves, so the field must follow. Rebaking 576 probes in one frame is a hitch; rebaking **a few probes per frame, round-robin** is invisible — at 4 probes/frame a full sweep takes ~2.4 s, and ch43's same ">2° sun rotation" trigger starts each sweep. Light *remembered* is allowed to lag a few seconds behind light *happening*; the sky changes smoothly and nobody can tell.

## Odin notes

```odin
Probe_Grid :: struct {
    origin, spacing: glsl.vec3,
    nx, ny, nz:      int,
    sh:              [4]u32,        // four 3D textures, RGBA16F, LINEAR/CLAMP
    coeffs:          [][4]glsl.vec3, // CPU mirror, nx*ny*nz, for bake + upload
    valid:           []bool,
    rebake_cursor:   int,
}
probe_index :: proc(g: ^Probe_Grid, x, y, z: int) -> int { return (z*g.ny + y)*g.nx + x }
```

`gl.TexImage3D` with `gl.RGBA16F`/`gl.RGBA`/`gl.FLOAT` allocates each field texture; updating one probe after a rebake is a 1×1×1 `gl.TexSubImage3D` per coefficient — four tiny uploads, no full re-upload. The bake reuses ch43's per-face view matrices helper and `capture_fbo`; resist the urge to write new capture code, the whole point is that you don't have to.

## Build

1. **The grid.** `probe_grid_create` over the port's AABB — start 12×4×12 at ~4 m spacing, first y-layer ~1.5 m above the quay. Debug-draw a small sphere per probe (ch53 lines or an instanced ch11 sphere). Stare at the layout; move bounds so dock walls sit between probe columns (the cheapest leak fix happens here, before any code).

2. **The bake scene pass.** A `scene_draw_lit_basic(view, proj)` that renders opaques + ocean + sky with sun, CSM, and the nearest handful of lanterns — your forward shaders from the pre-deferred era are still in the repo (ch83 proved it). No post, no tonemap — **the bake stays HDR linear**.

3. **The bake loop.** For each probe: six faces into the ch43 scratch cubemap → `irradiance.frag` convolution into the 32² irradiance cube → read back the six faces (`gl.GetTexImage` per face) → project to L1 SH on the CPU:

   ```odin
   for face in 0 ..< 6 {
       for texel, i in face_pixels[face] {
           dir, sa := cubemap_texel_dir_solid_angle(face, i, SIZE)
           c := texel.rgb * sa
           coeffs[0] += c * 0.282095                  // Y00
           coeffs[1] += c * 0.488603 * dir.y          // Y1-1
           coeffs[2] += c * 0.488603 * dir.z          // Y10
           coeffs[3] += c * 0.488603 * dir.x          // Y11
       }
   }
   ```

   Validity check while you're there: depth faces mostly nearer than 0.5 m → `valid = false`, copy nearest valid neighbor. Full first bake of 576 probes takes a few seconds — it's a bake; print progress and enjoy it.

4. **Upload + the shader swap.** Fill the four 3D textures, then in `deferred_lighting.frag`:

   ```glsl
   uniform sampler3D u_sh0, u_sh1, u_sh2, u_sh3;
   uniform vec3 u_probe_origin, u_probe_inv_extent;   // 1 / (spacing * count)

   vec3 sh_irradiance(vec3 p, vec3 n) {
       vec3 uvw = (p + n * u_probe_normal_offset - u_probe_origin) * u_probe_inv_extent;
       uvw = clamp(uvw, u_half_texel, 1.0 - u_half_texel);
       vec3 L00  = texture(u_sh0, uvw).rgb;            // hardware trilinear =
       vec3 L1m1 = texture(u_sh1, uvw).rgb;            //   the 8-probe blend
       vec3 L10  = texture(u_sh2, uvw).rgb;
       vec3 L11  = texture(u_sh3, uvw).rgb;
       return max(0.886 * L00 + 1.023 * (L11 * n.x + L1m1 * n.y + L10 * n.z), 0.0);
   }
   ```

   Replace the diffuse irradiance term *only*; prefiltered specular and the BRDF LUT stay global; SSAO multiplies the result exactly as in ch56. Wire a panel toggle: **Global IBL / Probe grid** — this toggle is the appendix.

5. **Rebake amortization.** `probe_grid_tick`: when the ch43 sun-rotation trigger fires, mark a sweep; each frame, rebake `rebake_budget` probes (4) from `rebake_cursor`, `TexSubImage3D` them in, advance. Watch a full day cycle on the dock: the field follows the sun a breath behind, and the frame never hitches (prove it with the ch49 timer).

6. **The showcase.** Night, ch78 dock, lanterns lit. Toggle. With global IBL: shadowed crate faces are uniform moon-gray, the under-dock is implausibly bright. With probes: warmth pools *around* the lanterns even in shadow, bounce ties the boat to the quay, the dark is dark. Take the screenshot — this is the course's last new image of the port, and it should be its best.

## Checkpoint

The step-6 toggle should read as "someone turned the GI on" to a viewer who knows nothing about rendering.

- Debug spheres, shaded by their own coefficients: each visibly tinted by its neighborhood — warm near lanterns, blue up high, dim under the dock. Any black sphere inside a rock got caught by validity (temporarily disable the fix to *see* one, then re-enable).
- Walk the boat's lantern along the quay and rebake: the field follows the light source. Light is being remembered, on request.
- Time-of-day sweep: no hitch > the frame budget; sweep completes in a few seconds (panel shows cursor progress).
- SSAO off/on still behaves per ch56's law: probes feed *ambient*; the sun's term never touches them.

## Pitfalls

- **Everything black after the swap.** Grid uv outside [0,1] (origin/spacing math, or the missing half-texel inset) — visualize `grid_uv` as color; or the 3D textures were left at `NEAREST` *unfiltered mip settings* with incomplete sampler state (no mips: set `MIN_FILTER` to `LINEAR`, not `LINEAR_MIPMAP_LINEAR`).
- **Visible cell-sized blocks of ambient.** One of the four textures is `NEAREST`, or you packed coefficients into one texture along x and trilinear is blending *across coefficients*. Four separate textures — that's why.
- **Light leaks through the warehouse wall.** Spacing wider than the wall plus no normal offset. Offset first, re-place grid bounds second; if it still leaks, you've found the motivation to read the DDGI paper.
- **Double-counted sky.** You added the probe term while the old global irradiance term still runs. Replace, don't add — the probes *contain* the sky (they captured it).
- **The bake looks tonemapped/washed out.** The bake scene pass went through `renderer_end_hdr` or wrote to an RGBA8 scratch. HDR linear end to end; the only tonemap in this game runs on the final frame.
- **Probes flicker mid-sweep.** You convolve into the same irradiance cube you're reading or update coefficients mid-frame. Bake into scratch, upload finished coefficients only — one probe being 2 s stale is invisible; one probe being half-written is a strobe.

## Exercises

1. **Ambient cube A/B:** encode six axis colors instead of SH (project with `max(0, dot(dir, axis))²` weights), sample with squared-normal blending, and compare on the dock — where does SH's smoothness visibly win, and where can you honestly not tell?
2. **Probe-lit fog:** feed `sh_irradiance` (evaluated with the view direction) into ch59's volumetric march as its ambient in-scatter term. Lantern-warmed mist under the dock at midnight — the two best atmospheric systems in the course, finally talking.
3. **Author-placed probes:** let the ch48 panel add hand-placed probes inside tricky interiors (the warehouse), blended in by distance after the grid lookup. Ten minutes of tooling, and you've reinvented how shipped games actually handle interiors.
4. **Stretch — read the DDGI paper** (Majercik et al., the header link) and write half a page mapping each of its components to what you built: octahedral-encoded probes ↔ your SH, visibility/depth probes ↔ your leak fixes, per-frame ray budget ↔ your rebake cursor. You'll find you built the static two-thirds of a 2019 research result — the remaining third is why Part 13 keeps saying "further reading."

## Commit

`git commit -m "ch90: irradiance probe GI - scene-lit bakes via ch43 pipeline, L1 SH grid, trilinear ambient in deferred, amortized rebake"`

[← Ch. 89: The Sea in a Browser](ch89-the-sea-in-a-browser.md) · [Course overview](../00-COURSE-OVERVIEW.md)
