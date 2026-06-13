# Chapter 31 — MILESTONE: Ocean at Sunset

*Part 5 — The Living Sea & Sky · Estimated time: 2h · learnopengl: review of [Cubemaps](https://learnopengl.com/Advanced-OpenGL/Cubemaps) and [Framebuffers](https://learnopengl.com/Advanced-OpenGL/Framebuffers)*

**What you'll see when done:** the signature shot of the whole course — a rolling Gerstner sea at 18:40, islands black against an orange sky, the sun's glitter path crossing wobbling reflections. The image from the course intro. You're about to make it.

## Where we are

Five chapters ago you had a static blue plane under a clear color. Now: a procedural sky with a working sun, trochoidal waves with a CPU twin, Fresnel water sampling that sky, and rendered reflections and refractions. Nothing new today. Milestone chapters are for integration debt, tuning, and the screenshot — and this one is *the* screenshot.

## Integration pass

Work through these in order; each takes minutes but they compound.

1. **One sun, audited.** Grep your render code for every place `sun_dir`, `sun_color`, or `sun_intensity` is set. Every single one must read from `game.sky`. Any hardcoded leftover from Chapters 14–25 will desynchronize the moment you scrub time. (Classic stragglers: the terrain shader, a forgotten lantern pass.)

2. **One clock, audited.** `u_time` for water (vertex *and* fragment scrolling), the CPU `ocean_height_at` callers, and any bobbing buoys must all use the fixed-timestep sim clock. If buoys still bob on a render-time sine from Chapter 19, port them to `ocean_height_at` now — it's three lines, and they become wave-accurate for free (and you've just rehearsed Chapter 32).

3. **The shoreline truce.** Waves currently roll *through* island beaches. The full fix (depth-fading wave amplitude near shore) needs per-pixel water depth — Chapter 30's Stretch. The milestone-grade mitigation: keep big-swell amplitude modest (≤ 0.7 m) and let the refraction shallows visually anchor the waterline. Decide consciously; don't let it nag you mid-screenshot.

4. **Resize robustness.** Resize the window hard, several times. Reflections must not stretch or go stale (FBO recreation), the projection aspect must follow, and the sky must stay seamless.

5. **Five-minute soak.** Let it run; watch for the f32-time jelly (Chapter 28 pitfall), driver leaks from per-frame FBO creation (should be none), and frame-time creep.

## Tuning recipes

Settle your sea's personality. Two known-good starting points, expressed in Chapter 28's wave table — copy, then season:

**Calm evening (the postcard):**

```odin
steepness = 0.45
waves = {
    {glsl.normalize(glsl.vec2{1.0,  0.2}), 0.45, 65.0, 9.5},
    {glsl.normalize(glsl.vec2{0.9, -0.3}), 0.20, 31.0, 6.0},
    {glsl.normalize(glsl.vec2{0.3,  0.8}), 0.10, 13.0, 4.0},
    {glsl.normalize(glsl.vec2{-.3,  0.9}), 0.05,  6.0, 2.8},
}
```

**Choppy afternoon:**

```odin
steepness = 0.85
waves = {
    {glsl.normalize(glsl.vec2{1.0,  0.4}), 0.55, 38.0, 7.5},
    {glsl.normalize(glsl.vec2{0.7, -0.6}), 0.35, 19.0, 5.5},
    {glsl.normalize(glsl.vec2{0.1,  1.0}), 0.20,  9.0, 3.8},
    {glsl.normalize(glsl.vec2{-.5,  0.7}), 0.10,  4.5, 2.5},
}
```

Color guidance: calm seas want the Chapter 29 defaults; choppy seas read better with a slightly greener deep (`{0.03, 0.10, 0.13}`), stronger detail normals (0.25), and glitter gain dropped to ~1.8 (more facets catch the sun anyway). At sunset, if the water looks too dark against the bright sky band, raise the `mix(sky, reflection, …)` weight toward the analytic sky — the function is brighter than the half-res texture.

## The screenshot (#4 of 8)

Scrub to roughly 18:30–18:50, position the sun a third up from the horizon, camera ~3 m above the water looking *along* the glitter path toward an island on one side. Checklist before you press the key:

- [ ] Sun disk and halo visible, not clipped by the frame edge
- [ ] Glitter path runs from sun toward camera, broken into sparkles
- [ ] At least one island reflected, reflection wobbling
- [ ] Horizon line straight and seam-free across the whole frame
- [ ] Shallows visible somewhere (sand through water)
- [ ] No clear-color gray anywhere, no FBO debug quads left on

Save it next to your Chapter 13/19/25 screenshots and look at the four in sequence. That progression is the course working.

## Quiz

Answers in the fold — write yours down first.

1. Why does the skybox vertex shader output `pos.xyww` instead of `pos.xyzw`?
2. In `mat4(mat3(view))`, what information is destroyed, and what visual bug does it prevent?
3. A sum-of-sines ocean looks "rubbery". What physical behavior of water parcels do Gerstner waves add, and what does it do to crest shape?
4. What goes wrong if `Σ Qᵢ Aᵢ kᵢ > 1`, and how does the `q = Q/(kAN)` formula make that impossible?
5. Why does `ocean_height_at` need fixed-point iteration instead of just evaluating the wave sum at the query point?
6. F0 for water is about 0.02. What does that number mean physically, and why does the sea still mirror the sky near the horizon?
7. Why does the reflection pass need a clip plane — what artifact appears without one?
8. Your reflection FBO is half resolution and nobody notices. Why does the same trick *not* work for the refraction texture?

<details>
<summary>Answers</summary>

1. After the perspective divide, depth = w/w = 1.0 — the far plane exactly — so the sky passes the `LEQUAL` test only where nothing else drew, letting it render last and shade only background pixels.
2. The translation column. Without stripping it, the sky cube sits at a fixed world spot and the camera can fly toward/past it — the sky must rotate with the view but never translate.
3. Water parcels orbit in circles (forward at crest, back in trough). Gerstner adds the horizontal component of that orbit, bunching surface points toward crests: sharp narrow peaks, wide flat troughs — a trochoid.
4. Neighboring surface points displace past each other and the surface self-intersects, showing loops at crests. Setting `qᵢ = Q/(kᵢAᵢN)` makes each term contribute `Q/N` to the sum, totaling exactly `Q ≤ 1`.
5. Gerstner displaces points *horizontally*: the water above (x,z) originated at some other rest point. The iteration solves "which rest point lands here" so the height matches what's rendered.
6. Looking straight at water, only 2% of light reflects (a consequence of water's index of refraction, ~1.33). Schlick's `pow(1−cosθ, 5)` term rockets toward 1 at grazing angles, so near the horizon reflectivity approaches a perfect mirror.
7. The mirrored camera sits underwater looking up, so it sees the *underside* of islands (terrain below y=0). Clipping everything below the plane keeps only what a true reflection would show; without it, dark underwater geometry smears into the reflection.
8. The reflection is distorted by waves and read at grazing angles — blur hides everywhere. The refraction shows the seabed nearly head-on through calm shallows; half-res there is visible as blur on the sand right where the player looks.

</details>

## Share it

This is the shot people post. The Odin Discord's #showcase and [r/odinlang](https://www.reddit.com/r/odinlang/) both enjoy a good procedural sunset, and learnopengl readers hang out in its screenshots thread — your water is now several chapters past the tutorials it grew from. Post the Chapter 13 screenshot next to today's for the before/after.

## If you're returning after a break

Recap of Part 5 in one paragraph: the sky is a fragment-shader function `sky_color(direction, sun_dir)` drawn on a depth-tricked cube, owned by `Sky` (which also owns the time-of-day clock and feeds the Phong sun). The sea is a camera-following grid displaced in the vertex shader by 4 Gerstner waves defined *once* in `src/ocean.odin` and mirrored exactly by `ocean_height_at` on the CPU — never edit one side without the other. Water shading = analytic Gerstner normals + detail normal map, Schlick Fresnel (F0 = 0.02) blending refraction-based body color against reflection + sky. Reflection/refraction are scene re-renders into `Render_Target` FBOs with `gl_ClipDistance` planes. Next: Part 6 puts you *in the boat*.

## Commit

`git commit -m "ch31: milestone - ocean at sunset"`

← [Chapter 30 — Through the Looking Glass](ch30-through-the-looking-glass.md) · [Chapter 32 — She Floats](../part-6-setting-sail/ch32-she-floats.md) →
