# Chapter 19 — MILESTONE: Sunlit Waters

*Part 3 — Let There Be Light · Estimated time: 2h · learnopengl: review of the Lighting chapter set*

**What you'll see when done:** golden light raking across open water, lantern-topped buoys rising and dipping on a gentle swell, a boat riding at anchor — and a sun you can drag across the sky with two keys.

## Where we are

Part 3 is built. You have Phong lighting, materials, multiple light types, a gamma-honest pipeline, a model loader, and a transform hierarchy. This milestone chapter adds almost no theory — it stitches the pieces into one scene worth screenshotting, then checks your understanding before the part break.

## Build: integration

1. **Bob the buoys.** Give each buoy a root `Scene_Node` and drive it from accumulated time in your update step. A sine offset is an honest placeholder — Chapter 32 replaces it with real wave sampling, and because you're driving a *root transform*, that swap will touch only these lines:

   ```odin
   for &b in game.buoys {   // store node indices + a per-buoy phase
       node := &game.nodes[b.node]
       node.transform.position.y = 0.15 * math.sin(f32(game.time) * 1.2 + b.phase)
       node.transform.rotation.z = 0.06 * math.sin(f32(game.time) * 0.9 + b.phase)
       node.transform.rotation.x = 0.05 * math.sin(f32(game.time) * 1.1 + b.phase * 2.3)
   }
   ```

   Give each buoy a different `phase` (e.g. `f32(i) * 1.7`) — synchronized bobbing looks mechanical instantly. The lantern lights already follow, courtesy of Chapter 18's `world[3].xyz` lookup.

2. **Put the sun on an arc.** Replace the constant `sun_dir` with an angle you steer — foreshadowing the Chapter 27 day/night cycle:

   ```odin
   // input: comma/period (or [ and ]) nudge sun_angle in update()
   game.sun_angle = clamp(game.sun_angle, 0.05, math.PI - 0.05)
   sun_dir := glsl.vec3{
       -math.cos(game.sun_angle),
       -math.sin(game.sun_angle),   // angle 0 = on the horizon, PI/2 = noon
       -0.25,
   }
   ```

   Then make color follow elevation — the whole mood of the scene from one `mix`:

   ```odin
   elevation := math.sin(game.sun_angle)               // 0 horizon .. 1 noon
   warm := glsl.vec3{1.0, 0.45, 0.2}
   noon := glsl.vec3{1.0, 0.97, 0.9}
   t := clamp(elevation * 2.5, 0, 1)
   sun_color := warm + (noon - warm) * t                // odin array math: lerp by hand
   ```

3. **Anchor the boat.** The Chapter 18 boat floats statically at a nice spot near the buoys — remove the test spin, keep a barely-perceptible heel (`rotation.z = 0.02 * math.sin(t * 0.7)`) so it doesn't read as nailed down. Lantern lit at the masthead.

4. **Dress the set.** Three or four buoys at varied distances; crates from Part 2 scattered between them (they can share the bob code); camera start position framing boat, buoys, and the low sun together. Cap `point_light_count` at what's actually in the scene.

5. **Sweep for regressions.** Hot-reload still works on `lit.frag`? Normal-visualization key still works? `FRAMEBUFFER_SRGB` still enabled after any window/context changes? Two minutes now saves a confusing Part 4.

## Checkpoint

Run it, set the sun low, and just fly around for a while — you've earned it.

- Buoys bob out of phase; lantern light pools slide on the water-adjacent geometry as they move.
- Holding the sun keys drags the light from warm dawn through white noon and back; specular glints track it.
- The boat heels almost imperceptibly; mast and lantern move rigidly with it.
- Steady frame rate with all lights on (this scene is trivial for any GPU — if it isn't, something is wrong; check you're not reloading shaders or models per frame).

## Screenshot moment #2

Checklist for the keeper:

- Sun elevation low (angle ≈ 0.3) for long warm light and big specular streaks.
- Camera low, a few meters off the water, looking past a lantern buoy toward the boat.
- One lantern near the camera so its pool of warm light is visible against cool water.
- Save it as `screenshots/02-sunlit-waters.png` in the repo — the series is the course's progress bar.

Share it: the [Odin Discord](https://discord.com/invite/sVBPHEv) #showcase channel and [r/odinlang](https://www.reddit.com/r/odinlang/) both enjoy a good "learning graphics in Odin" series — and posting publicly is the single best anti-abandonment device known to hobby programming.

## Self-test quiz

Work these from memory, then check.

1. Why must normals be re-normalized in the fragment shader even though every vertex normal is unit length?
2. In the diffuse term `max(dot(N, L), 0)`, what physical fact does the cosine represent, and what would removing the `max` do?
3. Why does a directional light have no position and no attenuation?
4. Your scene looks pale and washed out after enabling sRGB texture formats. What's the likely cause?
5. When is `mat3(model)` *not* sufficient for transforming normals, and what replaces it?
6. An OBJ face corner reads `7/12/7` on one face and `7/12/9` on another. How many GL vertices does your loader emit for position 7, and why?
7. In `world = parent_world * T * R * S`, what goes visibly wrong if you accidentally compute `S * R * T` for the local part?
8. Why did we put an empty root node above the boat's hull?

<details>
<summary>Answers</summary>

1. Linear interpolation of two unit vectors across a triangle yields vectors *shorter* than unit length (the chord vs the arc); unnormalized N skews every dot product, dimming mid-triangle shading.
2. `cos θ` is the spread of a fixed-width light beam over a larger surface area at grazing angles — same energy, more area, less irradiance per point. Without the clamp, surfaces facing away would receive *negative* light and darken the ambient/specular sum incorrectly.
3. It models a source effectively at infinity: rays arrive parallel (one direction fits all fragments) and the distance is effectively constant, so falloff is meaningless.
4. Double gamma correction — the textures are being decoded sRGB→linear at sample time *and* you still have a manual `pow(1/2.2)` (or the textures were already linear and shouldn't be SRGB8). Exactly one decode in, one encode out.
5. Under non-uniform scale (and shears). The normal matrix — transpose of the inverse of the model's upper 3×3 — keeps normals perpendicular to the transformed surface.
6. Two. The triples differ (different normal index), so they're distinct keys in the dedup map; same position, different shading data.
7. Translation happens *first* (in matrix application order), so the object is rotated and scaled around the parent's origin rather than its own — children orbit instead of sitting in place.
8. So physics/buoyancy (ch32) can own one transform that moves the entire assembly, while the hull keeps an independent cosmetic local offset; it separates "where the boat is" from "how the boat's parts are arranged."

</details>

## If you're returning after a break

Welcome back; the wind held. Here's the state of Saltwind in one paragraph: the renderer lights everything with one **directional sun** plus up to eight **point lights**, summed per-fragment in `lit.frag` using **Phong** terms driven by a per-object `Material`. The pipeline is **gamma-correct**: albedo textures load as `SRGB8_ALPHA8`, math happens linear, `FRAMEBUFFER_SRGB` encodes output, and draws pass an **inverse-transpose normal matrix**. Models load through your own **OBJ parser** (`model_load_obj`, dedup via `map[Vertex_Key]u32`) into the same `Mesh` type as the procedural primitives. Objects live in a flat `Scene_Node` array with parent indices; `scene_update_world` does one forward pass of `parent_world * T·R·S`; the boat is a hull/mast/lantern hierarchy under an empty root. Buoys bob on placeholder sines; the sun rides a key-controlled arc with elevation-tinted color. Skim your git log for Part 3, run the program, drag the sun across the sky once — and sail on into Part 4, where we raise islands from noise.

## Commit

`git commit -m "ch19: milestone — sunlit waters"`

← [Chapter 18 — The Family Tree](ch18-the-family-tree.md) · [Chapter 20 — Land from Numbers](../part-4-raising-islands/ch20-land-from-numbers.md) →
