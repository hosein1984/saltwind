# Interlude 59a — The Physical Lens

*⚓ Optional interlude · slots after [Chapter 59](ch59-shafts-of-light.md) · Estimated time: 8–10h · learnopengl: no direct equivalent — canonical references: [Jimenez, "Next Generation Post Processing in Call of Duty: Advanced Warfare" (SIGGRAPH 2014)](https://advances.realtimerendering.com/s2014/) and [Hullin et al., "Physically-Based Real-Time Lens Flare Rendering" (SIGGRAPH 2011)](https://resources.mpi-inf.mpg.de/lensflareRendering/)*

**Prerequisites:** Chapter 59 (you now own a half-res post toolkit), ch55's depth reconstruction, ch51's photo mode. [Interlude 54a](ch54a-ghosts-and-how-to-bust-them.md)'s velocity buffer unlocks the *per-object* motion blur; if you skipped it, the camera-only fallback here works fine. · **Required downstream:** none — skip freely.

**What you'll see when done:** photo mode grows a lens: click the gull on the masthead and the islands behind it melt into bokeh, spin the camera and the world streaks honestly, and a low sun scatters a restrained line of ghosts across the frame.

## Why this is a side quest

Everything in Part 9 so far simulates the *world*. This interlude simulates the *camera* — and Saltwind's default camera is an eyeball, which has no aperture ghosts and barely any motion blur. So these are photo-mode effects first, taste effects second, and gameplay effects only with restraint dialed in. The main line skips them because none of them make the world more true; they make *pictures* of the world more cinematic, and that's a legitimately different job. It's also the best shader-craft workout in the part: all three effects are "gather pixels under a model" problems, and the models — thin lens, shutter interval, internal reflection — are real optics you can reason about.

## Concepts

### The thin lens, in photographer's words

A pinhole camera (yours, until today) focuses *everything*. A real lens has a **focal length** `f` (millimeters — 24mm is wide, 50mm is "normal", 200mm is a telephoto), an **aperture** written as an f-number `N` (f/2.8 is a wide opening, f/16 a pinprick), and a **focus distance** `S` — the one distance rendered truly sharp. A point at any other distance `d` lands on the sensor not as a point but as a disc: the **circle of confusion**, and the thin-lens model gives its diameter in closed form:

```
CoC(d) = A · f · (d − S) / (d · (S − f))        with  A = f / N   (aperture diameter)
```

Keep it **signed**: negative means *near field* (in front of focus), positive means *far field* (behind). Every photographic intuition falls out of this one formula: longer lens or wider aperture → shallower depth of field; DoF extends further behind the focus plane than in front; stop down to f/16 and CoC stays sub-pixel almost everywhere — which is exactly why gameplay (an eyeball, pupil ≈ f/8 in daylight) should default to *off or nearly so*, and photo mode gets the f/1.8 dreaminess.

### Near and far are different problems

Far field is the easy half: a blurred island never bleeds over the sharp mast in front of it, so a gather that rejects samples sharper-and-nearer than the pixel works. The near field is the hard half: an out-of-focus rope *in front of* the focus plane spreads over the sharp background behind it — its blur must *grow outward past its own silhouette*. Production splits the two into separate weighted gathers; we do a serviceable single-pass version with near-field weighting and accept slightly conservative foreground bleed. The signed CoC is what makes the split possible at all.

### The gather, and why DoF lives in HDR

Half resolution, a spiral of ~24 taps scaled by the pixel's CoC, each tap weighted by *its own* CoC (a sharp sample must not be smeared by a blurry neighbor — compare tap CoC against pixel CoC and down-weight mismatches). Do it **before tonemapping**: an HDR sun glint is thousands of times brighter than its neighbors, and when it spreads across a disc it stays visibly brighter — that disc *is* bokeh. Run the same blur in LDR and glints dissolve into gray mush; this single ordering decision is most of the difference between "blur filter" and "lens".

### Motion blur: the shutter is an integral

Film exposes over an interval, so anything that moves paints a streak. You already know the machinery: **velocity**. Camera-only velocity needs no scene changes — reconstruct the world position from depth, reproject through last frame's view-projection, subtract (it's ch54a's fullscreen camera-velocity pass; if you skipped 54a, you'll write those twelve lines now, and they're in this chapter's Build). Per-object velocity — the boat blurring while the camera holds still — needs 54a's full velocity buffer; with it, motion blur consumes the same texture and gets dynamic objects for free. Either way the blur itself is ~8 taps along the velocity vector, center-weighted, length clamped, scaled by a **shutter** parameter (180° shutter = half the frame interval, the cinema default and the right starting value).

### Lens flare: ghosts of the aperture

Point a real lens near the sun and its internal elements reflect a little light back and forth; each bounce path projects a **ghost** — a tinted blob on the line *from the light through the image center*, at some signed fraction along it. Add a wide **halo** ring, and a **starburst** from aperture-blade diffraction, and you have the whole anatomy. The trick that sells it is **occlusion**: flare exists only when the sun is actually visible, so test the depth buffer at the sun's screen position (a small neighborhood, averaged, so it fades over a few frames as the mast crosses it) and scale everything by the result. You already project the sun to screen — ch59's Odin note — so this pass slots straight in.

**The restraint sermon, delivered once:** flare is the garlic of post effects. Real ghosts are *barely there* — modern coated lenses suppress them on purpose, and your eye has no aperture blades at all. If a screenshot's first impression is "nice lens flare," the flare failed. Intensity ~0.03 of what looks impressive in isolation, fade it with sun visibility *and* with view angle, and keep a debug key that toggles it while you stare at a sunset until you genuinely cannot decide whether it's on. That's the correct strength.

## Odin notes

Click-to-focus is a one-pixel depth readback under the cursor — a sync stall, which photo mode (frozen frame, who cares) is the one legitimate place for:

```odin
photo_focus_pick :: proc(r: ^Renderer, mx, my: f64) -> f32 {
    x := i32(mx)
    y := r.native_h - i32(my) - 1            // GL origin is bottom-left
    d: f32
    gl.BindFramebuffer(gl.READ_FRAMEBUFFER, r.gbuffer.fbo)
    gl.ReadPixels(x, y, 1, 1, gl.DEPTH_COMPONENT, gl.FLOAT, &d)
    gl.BindFramebuffer(gl.READ_FRAMEBUFFER, 0)
    return depth_to_view_dist(d, r.near, r.far)   // CPU twin of ch55's reconstruction
}
```

Don't snap `focus_dist` to the picked value — ease toward it (`focus_dist = math.lerp(focus_dist, picked, 1 - math.pow(0.001, dt))`) and you get a focus *pull*, which reads as a camera operator instead of a teleport.

## Build

1. **The lens struct.** On the camera (or photo-mode state): `focal_len: f32` (mm), `f_stop: f32`, `focus_dist: f32` (m), plus `shutter: f32` (0–1, default 0.5) and `flare_strength: f32`. Photo-mode panel sliders with photographic labels — "50mm f/2.8" teaches more than three raw floats. Gameplay defaults: f/16, shutter 0.5, flare 0.03.

2. **CoC pass.** Full-res `R16F` target from depth — the signed formula from Concepts, output in *half-res pixels*:

   ```glsl
   uniform float u_focal_len;   // meters! 50mm lens -> 0.05 (convert once, on the CPU)
   uniform float u_f_stop, u_focus_dist, u_coc_to_pixels;
   void main() {
       float d = view_dist_from_depth(texture(u_depth, v_uv).r);   // ch55's reconstruction
       float A = u_focal_len / u_f_stop;                            // aperture diameter
       float coc = A * u_focal_len * (d - u_focus_dist)
                 / (d * (u_focus_dist - u_focal_len));              // sensor-plane meters
       frag_coc = clamp(coc * u_coc_to_pixels, -MAX_COC, MAX_COC);  // signed half-res pixels
   }
   ```

   `u_coc_to_pixels` folds sensor size and resolution into one tuning constant (~2000 to start; calibrate by eye against the debug view). Bind that debug view now — green = far field, red = near, black = sharp — and sail until the focus plane is something you can *see*.

3. **Prefilter.** Downsample HDR color + CoC to half res in one pass. Premultiply color by saturated |CoC| here so in-focus pixels contribute no energy to blur taps that overreach.

4. **The gather.** Half-res pass, ~24 taps on a golden-angle spiral scaled by the pixel's CoC:

   ```glsl
   float coc = texture(u_coc, v_uv).r;
   vec4 acc = vec4(texture(u_half_color, v_uv).rgb, 1.0);
   for (int i = 0; i < 24; i++) {
       vec2 off = spiral_tap(i) * abs(coc) * u_texel;       // golden-angle disc
       float s_coc = texture(u_coc, v_uv + off).r;
       // far-field: don't let sharp/nearer samples smear; near-field: let foreground spread
       float w = (s_coc >= coc * 0.9) ? 1.0 : clamp(abs(s_coc) / max(abs(coc), 1e-4), 0.0, 1.0);
       acc += vec4(texture(u_half_color, v_uv + off).rgb * w, w);
   }
   frag = vec4(acc.rgb / acc.a, 1.0);
   ```

5. **Composite.** Full-res: blend sharp HDR with the half-res blur by `smoothstep(0.5, 2.0, abs(coc))`. Bilinear upsampling is fine here — defocus *is* low frequency; that's the whole point.

6. **Click-to-focus.** In photo mode, left-click calls `photo_focus_pick`, eases `focus_dist`. Add an `A`-key autofocus that picks the center pixel — and now your photo mode handles like a camera app.

7. **Motion blur, fallback first.** A half-res pass sampling velocity. No 54a? Write the camera-only velocity inline: reconstruct world position from depth, transform by `u_prev_view_proj` (snapshot it end-of-frame — one matrix, not 54a's whole apparatus), subtract NDCs. Have 54a? Bind its velocity texture instead — one uniform swap, dynamic objects come along free. Then blur: 8 taps along `vel * u_shutter`, clamped to ~16 pixels, zero velocity where depth = 1.0 (the 54a sky rule applies here too). Order: after DoF, before bloom.

8. **Lens flare.** One half-res pass plus a composite. Inputs: ch59's `sun_uv`, `sun_visible`, and an occlusion factor from depth around `sun_uv` (16 taps, fraction that are sky, smoothed over time). In the shader, for ~5 ghosts: `ghost_uv = mix(u_sun_uv, vec2(0.5), g_offset[i])` (offsets like −0.5, 0.3, 0.8, 1.4, 2.0 — some past center, mirrored), each a soft disc tinted by a per-ghost color with a small chromatic shift, faded by distance from frame center. Add a thin halo ring at fixed radius from center along the same axis, and a starburst texture (paint one: radial spikes) billboarded at `sun_uv`, rotated slightly with camera yaw so it lives on the *lens*, not the sky. Sum, multiply by occlusion × `u_flare_strength`, add into HDR before bloom — bloom will soften everything one more welcome notch.

9. **Order audit, recite it:** TAA resolve → **DoF → motion blur** → bloom (+ flare) → tonemap → FXAA/grain/UI. All three new passes on the ch49 GPU timer and behind panel toggles; motion blur also gets a *user* setting slider — some players get motion-sick, and shipping it forced is a genuine accessibility failure.

## Checkpoint

In photo mode at f/2: click the gull — the archipelago melts behind it and sun glitter becomes discs, not mush (that's the HDR ordering working). Click the horizon — focus pulls smoothly forward-to-back.

- Whip the camera: the world streaks along the motion, the HUD doesn't, the sky doesn't smear garbage at the horizon.
- With 54a: hold the camera still while the boat surges — the hull blurs, the island behind it doesn't. Without 54a: confirm it doesn't, and that you know why (camera-only velocity is zero when the camera is still — honest fallback, honestly understood).
- Sun slides behind the mast: every ghost fades over a few frames, no popping.
- All three at gameplay defaults: barely perceptible. All three at photo settings: a poster. Timer cost: DoF ~0.6ms, blur ~0.3ms, flare ~0.2ms at 1080p.

## Pitfalls

- **Bokeh looks like gray fog.** You blurred after tonemapping, or premultiplied without renormalizing (divide by accumulated weight). HDR in, weights out.
- **Sharp foreground halos around blurred background.** The gather is averaging sharp near samples into far-field pixels — that's the weight comparison in step 4 missing or backwards.
- **Click-to-focus always returns the far plane.** You read depth from the default framebuffer after the deferred switch (read the G-buffer's depth), or forgot the Y flip.
- **Everything subtly blurs with TAA on.** Your velocity (or reprojection matrix) includes the jitter — 54a's law, restated: velocity uses clean matrices, always.
- **Flare shines through the island.** Occlusion sampled at the wrong uv (recheck the `clip.w > 0` gate from ch59's note) or you skipped the off-screen fade, so a behind-camera sun projects to garbage.
- **Motion blur smears the boat onto the sky during a turn.** Velocity dilation problem — strictly correct fixes are tile-max (exercise 2); the cheap patch is sampling velocity at the *tap* position, not only the center.

## Exercises

1. **Hexagonal bokeh:** replace the disc spiral with three skewed line gathers (or just a hex-shaped tap pattern) — six aperture blades, the unmistakable "cinema lens" signature on glints.
2. **Tile-max velocity dilation** (McGuire's motion-blur papers): quarter-res max-velocity tiles let blur trails extend *past* object silhouettes, which is what your eye expects and step 7 can't do.
3. **Anamorphic streak:** a one-dimensional horizontal bloom pass on the brightest pixels, tinted blue, added at photo-mode-only strength. Yes, it's a cliché. Try it anyway; delete it if it survives the restraint test.
4. **Stretch — focus peaking:** in photo mode, overlay a thin colored edge (Sobel on luminance) only where |CoC| < 0.5 — exactly what mirrorless cameras do to show the focus plane. Sounds decorative; turns out to *teach* the thin-lens formula every time you drag the slider.

## Commit

`git commit -m "ch59a: physical lens - thin-lens DoF with click-to-focus, camera+object motion blur, occlusion-tested lens flare"`

[← back to Ch. 59: Shafts of Light](ch59-shafts-of-light.md) · [onward to Ch. 60: Milestone — The Deep Engine →](ch60-milestone-the-deep-engine.md)
