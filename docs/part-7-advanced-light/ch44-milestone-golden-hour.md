# Chapter 44 — MILESTONE: Golden Hour

*Part 7 — Advanced Light · Estimated time: 2–3h · learnopengl: no direct equivalent — this is your victory lap*

**What you'll see when done:** the screenshot you'll show people.

## Where we are

Count what Part 7 added: real shadows, an HDR pipeline, bloom, a physically based material system, and a sky that lights the whole world. Each chapter you tuned its own feature in isolation. A milestone chapter is for the opposite: making everything sing *together*. There is almost no new theory below — this is an art pass, a self-test, and a deliberate pause. Do not skip the before/after ritual; it is the single best motivation deposit available to you right now.

## The before/after ritual

You've been staring at incremental changes for weeks; your eyes have normalized everything. Fix that:

1. `git stash` anything uncommitted, then `git checkout` your ch37 commit (this is why we commit every chapter).
2. Build, run, sail for two minutes at sunset. *Really look.*
3. `git checkout` back to ch43. Same place, same time of day.
4. Marvel. You are allowed five full minutes of smugness. That delta — clamped flat sunset to bleeding golden light on physically shaded water — is **yours**, line by line.

## The art pass

Graphics programmers ship features; *games* ship moments. Spend an hour as a lighting artist. Set the day-cycle to manual control (you have a time-of-day scrubber key from ch27 — if not, add one now, you'll use it forever) and work these knobs against each other:

**The golden-hour recipe (starting values, then trust your eyes):**

- **Sun elevation:** 4–8° above the horizon. Below 4° you lose terrain shadow definition; above 12° the gold fades. The magic is long shadows + warm Fresnel on the water.
- **Sun radiance:** warm it — `(50, 30, 14)`-ish ratios rather than white. Your sky shader's scattering already reddens the *disk*; the direct-light uniform should agree with it.
- **Wave steepness:** back it off ~20% from your ch28 setting. Glitter reads best on broad swells with small ripples, not chop — steep waves shatter the sun's reflected streak.
- **Exposure:** set it so the *sea* midtones sit right and let the sun blow out. Sunset images live or die by silhouette contrast; don't rescue the shadows.
- **Bloom threshold ~1.0, strength 0.06–0.12.** The sun streak on the water should *just* halo. If island silhouettes glow, you've gone too far.
- **Tone mapper: ACES.** This scene is why you implemented it.
- **Composition** (yes, really): boat one-third from frame edge, sun streak leading to it, island silhouette breaking the horizon. Three minutes of camera placement beats thirty of parameter tweaks.

Save the result as a named preset in code — `golden_hour_preset :: proc(game: ^Game)` — so you can return to it after every future chapter. Then make one more preset of your own invention: blue hour, storm light before ch47 exists, high noon. Presets are how you learn what each knob *means*.

## Integration sweep

Small debts from chs 38–43 to settle before Part 8 piles on:

1. The stencil outline (ch38) draws into the HDR target now — confirm its color is sane post-ACES (outline colors near 1.0 desaturate; use ~3.0 for a confident line).
2. Confirm shadows land on PBR materials *and* Phong terrain consistently — same `shadow_factor`, same bias constants, one shared GLSL include if you've grown one (`#include` isn't in GLSL 330; a string-concat at `shader_load` time is a fine homegrown substitute).
3. Run the resize callback hard (drag the window corner wildly): HDR target, bloom targets, and reflection FBOs must all rebuild without leaks (`render_target_destroy` then create — check with a counter if paranoid).
4. Verify the IBL rebuild doesn't fight the planar reflection pass order: capture sky → shadow pass → reflection FBOs → HDR scene → bloom → tonemap. Write this list as comments in your main render proc; it is your render graph documentation.

## Self-test quiz

Eight questions; answers below the fold. If you miss more than two, reread the relevant Concepts section — Part 8 builds on all of this.

1. Why must bloom be composited *before* tone mapping rather than after?
2. Your shadow edges shimmer and crawl whenever the camera moves, though they're stable when it's still. What did you forget?
3. What's wrong with applying `pow(c, 1.0/2.2)` in the PBR fragment shader, and where does gamma now live?
4. In the metallic workflow, why does a pure metal have no diffuse term at all?
5. What three inputs does the split-sum approximation reduce the specular IBL integral to, and which textures store the precomputed halves?
6. Slope-scaled bias: why do surfaces facing *away* from perpendicular-to-sun need more bias?
7. Why did we raise the near plane to 0.5 instead of pulling the far plane in to fix z-fighting?
8. Your friend's bloom looks like fog over the entire screen. Name the two most likely causes.

<details>
<summary>Answers</summary>

1. Bloom is light energy; it must pass through the same camera response (tonemap + gamma) as the rest of the scene. Composited after, it adds linear-space values to display-space pixels, producing washed-out gray halos that ignore exposure.
2. Texel snapping of the shadow box: the ortho box must move in whole shadow-map-texel increments in light space, otherwise the rasterization of every caster re-quantizes differently each frame.
3. It applies gamma twice (the tonemap pass already does it) and corrupts any later linear-space math (bloom, grading). Gamma lives in exactly one place: the end of the tonemap pass.
4. In metals, refracted light is absorbed by free electrons instead of being scattered back out, so all reflected energy is specular — and F0 is tinted by the metal's albedo.
5. Normal/reflection direction, roughness, and N·V. The prefiltered environment cubemap mip chain stores the radiance half (indexed by R and roughness); the BRDF LUT stores the BRDF half (indexed by N·V and roughness) as an F0 scale and bias.
6. At grazing sun angles a depth-map texel spans a long sliver of surface, so the depth error between the texel's stored depth and a fragment within it grows with slope — bias must grow proportionally (`1 - dot(N, L)`).
7. Depth precision is distributed as 1/z: it's dense near the near plane and sparse far away. Raising near reclaims far-field precision dramatically; shrinking far barely helps because almost no precision lives out there anyway.
8. Threshold below average scene luminance (everything passes the bright pass), or compositing after tonemap. (Honorable mention: blur weights that don't sum to 1, gaining energy per pass.)

</details>

## Screenshot #6 checklist

- [ ] Golden-hour preset loaded; sun 4–8° up
- [ ] Boat composed off-center, sun streak on the water leading the eye to it
- [ ] An island silhouette with visible self-shadowing
- [ ] Bloom visible on the sun and streak only
- [ ] HUD/debug overlays hidden (if you have any keys bound, this is why ch51 adds photo mode)
- [ ] Screenshot at your monitor's full resolution (OS capture is fine; F11 capture comes in ch51)

Put it side by side with screenshot #1 — the empty blue sea from ch13 — and post the pair. The Odin Discord's #showcase and [r/odinlang](https://reddit.com/r/odinlang) genuinely love this stuff, and "I built this following a course, here's chapter 13 vs 44" is the most encouraging genre of post that exists. Someone reading it will start their own. learnopengl's screenshot thread will also recognize exactly what they're looking at.

## Returning after a break

This is the course's natural long-rest point — Part 8 is a different *kind* of work (scale, simulation, polish). If you put Saltwind down for weeks, here's the re-entry paragraph:

> *You have a sailing game with a fully modern forward renderer: depth/stencil discipline (38), camera-following directional shadows with PCF (39), an RGBA16F HDR pipeline ending in an ACES tonemap that owns gamma (40), half-res additive bloom (41), Cook-Torrance PBR with metallic/roughness materials and normal mapping on boat and buoys (42), and IBL — irradiance + prefiltered specular + BRDF LUT — captured live from your procedural sky (43). The `Renderer` struct owns every render target; the pass order is documented in your main render proc. Part 8 adds instancing, particles, weather, UI, and profiling — it starts by making the world* full, *not prettier.*

Run the game once before reading Chapter 45. Sail to your favorite island. That's what it's for.

## Commit

`git commit -m "ch44: golden hour — art pass, presets, milestone screenshot #6"`

[← Ch. 43: Light from Everywhere](ch43-light-from-everywhere.md) · [Ch. 45: A Thousand Things →](../part-8-full-sail/ch45-a-thousand-things.md)
