# Chapter 75 — Many Shores

*Part 11 — A Living World · Estimated time: 5h · learnopengl: no direct equivalent — this is procedural-generation material*

**What you'll see when done:** a black volcanic ridge smoking on the northern horizon, a white-sand atoll ring to the south, mangrove flats threaded with channels to the east — one seed, four kinds of shore, and sailing between them finally feels like *traveling*.

## Where we are

Ch21's worldgen makes beautiful islands — all of them cousins. Same noise recipe, same sand-grass-rock palette, same palms. After an hour of sailing, the player's eye has solved the archipelago. This chapter parameterizes everything that makes an island *itself* — noise recipe, splat palette, vegetation set, even the color grade — into per-biome data, then assigns biomes from the seed along a climate gradient. The deep lesson is architectural: **four biomes is zero new systems**. Every system from Parts 4, 8, and 11 already takes parameters; biomes are rows in tables.

## Concepts

### Biome = a row of parameters, not a branch of code

The wrong way: `if biome == .Volcanic` scattered through terrain, scatter, and shading code — N biomes × M systems edit points. The right way: one descriptor struct, one table, and every system reads its parameters through the island's biome:

```odin
Biome :: enum { Temperate, Volcanic, Atoll, Mangrove }

Biome_Desc :: struct {
    // worldgen
    noise:          Noise_Recipe,        // octaves, persistence, ridged, warp...
    falloff:        Falloff_Kind,        // .Bump, .Ring, .Flat_Pan
    height_scale:   f32,
    // surface
    splat:          Splat_Palette,       // the ch22 layer textures/tints + thresholds
    vegetation:     []Scatter_Rule,      // the ch45 table, per-biome rows
    // mood
    grade:          Grade_Params,        // ch51 lift/gamma/gain nudge
    sea_tint:       glsl.vec3,           // shallow-water color (ch24/ch66)
}

BIOME_TABLE := [Biome]Biome_Desc{ ... }  // exhaustive — add a biome, the compiler
                                         // demands its row (ch47's enumerated-array trick)
```

Adding a fifth biome later should be: one enum value, one table row, zero logic edits. Hold yourself to that test.

### Ridged fBm: mountains with spines

Standard fBm is rolling — good for dunes and hills, wrong for volcanic ridges. **Ridged fBm** transforms each octave before summing: `r = 1 - abs(n)` turns the noise's zero-crossings into sharp creases pointing *up*; squaring sharpens them; and weighting each octave by the previous octave's value makes detail cling to the ridgelines instead of carpeting everything:

```odin
ridged_fbm_2d :: proc(seed: i64, x, z: f64, octaves: int, lac, pers: f64) -> f32 {
    sum, amp_total: f32
    amp: f32 = 1.0; freq: f64 = 1.0; weight: f32 = 1.0
    for i in 0 ..< octaves {
        n := noise.noise_2d(seed + i64(i), noise.Vec2{x * freq, z * freq})
        r := 1.0 - abs(n)
        r  = r * r * weight
        weight = clamp(r * 2.0, 0.0, 1.0)        // detail follows ridges
        sum += r * amp; amp_total += amp
        freq *= lac; amp *= f32(pers)
    }
    return sum / amp_total                        // ~0..1 (note: not -1..1!)
}
```

Mind the range change — ridged output is already 0..1, so the `n*0.5+0.5` remap in `world_gen_height` must be recipe-conditional. A volcanic island is ridged fBm, high `height_scale`, low persistence (clean spines), with the regular bump falloff. Add a crater for free: subtract a small sharp bump at the island center from the height.

### Falloff masks are island *shapes*

Ch21's radial bump made all islands blobs. Two new masks:

- **Ring (atoll):** an annulus instead of a bump — land lives at radius `r0`, falls off inward *and* outward, leaving a lagoon:

  ```
  bump:   ▁▂▄█▄▂▁        ring:   ▁▂█▂▁ ▁▂█▂▁     (cross-section)
                                  └ lagoon ┘
  ring = 1 - smoothstep(0, w, abs(d - r0))        d = dist/radius, r0≈0.7, w≈0.25
  ```

  Pair with tiny `height_scale` (atolls are *flat*), white-sand splat, and a notch: multiply the ring by `smoothstep` of another low-freq noise to break it into motu (islets) with passes a boat can thread. Your lagoon inherits ch24's shallow tinting automatically — turquoise, no new code.

- **Flat pan (mangrove):** clamp the interior to barely-above-sea (`height = min(height, 1.5 + n * 1.0)`), then carve **channels**: where `abs(channel_noise) < 0.06` (the zero-crossing lines of a low-frequency noise — they form connected, branching curves, which is exactly what creeks look like), push height below sea level. Mangrove "trees" are palms swapped for a broccoli-ish canopy mesh scattered with `min_h = -0.5` — they stand *in* the water, which instantly reads as mangrove.

### Assignment: seed + climate gradient

Random biome per island works but produces volcanic islands beside atolls with no logic. One step better — a **climate gradient**: biome probability varies across the archipelago (volcanic likelihood rising to the north, atolls in the south, mangroves in between near sea level). Derive from the blob position plus the seed:

```odin
biome_for_island :: proc(world_seed: i64, blob: Falloff_Blob, idx: int) -> Biome {
    rand.reset(u64(world_seed) ~ u64(idx) * 0x9E3779B97F4A7C15)
    t := blob.center.y / world_radius * 0.5 + 0.5   // 0 south .. 1 north
    roll := rand.float32()
    switch {
    case roll < t * 0.6:              return .Volcanic   // likelier north
    case roll < t * 0.6 + (1-t)*0.5:  return .Atoll      // likelier south
    case roll < 0.85:                 return .Temperate
    case:                             return .Mangrove
    }
}
```

Same seed → same world, biomes included (the `rand.reset` per island keeps it order-independent, ch45's discipline). The gradient means the *map makes sense*: sailing north, the horizon genuinely changes character.

### Graded shores: mood by proximity

Ch51's color grade is global; ch51's exercise 2 lerped it with weather. Now blend it by *place*: weight each nearby island's `grade` by inverse distance (smoothstepped to zero beyond ~600 m), blend with the open-sea base grade, and feed the result through the existing weather-grade lerp. Approaching the volcanic island, shadows cool and contrast rises; gliding into the mangrove at dawn, everything warms and lifts. It's subliminal — which is the point. (Blend the *parameters*, one lerp per field — same trick as `weather_lerp`.)

## Build

1. **Restructure worldgen.** `World_Gen_Params` grows `biomes: []Biome` (parallel to blobs) filled by `biome_for_island` at generation time. `world_gen_height` dispatches per-blob: each blob contributes `recipe_height(biome_desc, ...) * mask(biome_desc.falloff, ...)`, combined with `max` as before. Where blobs of different biomes overlap, `max` resolves it — and the noise continuity across the field (ch21) keeps shared geology plausible.

2. **Implement the recipes.** `ridged_fbm_2d` (excerpt above), the ring mask, the flat-pan + channels treatment. Test each biome *alone* first: a debug param forcing all islands to one biome, regenerate, fly over (the ch9 freecam never retired). Tune until each silhouette is recognizable from a mile out — that's the actual acceptance test, because that's how the player meets them.

3. **Fill `BIOME_TABLE`.** Splat palettes: volcanic = black basalt / gray scree / sparse moss with a high grass-line; atoll = white coral sand everywhere, vegetation only on motu centers; mangrove = mud / wet sand / canopy green. Vegetation tables: per-biome `[]Scatter_Rule` rows (volcanic: rocks dense, palms rare and low; atoll: palms in motu clusters; mangrove: canopy trees with sub-sea-level `min_h`). The ch45 scatter loop takes rules — it doesn't know biomes exist. That's the proof the architecture held.

4. **Per-biome splat uniforms.** The ch22 terrain shader's layer textures/tints/thresholds become per-draw uniforms set from the chunk's island biome (carry `island_index` on `Terrain_Chunk` — chunks were per-island-ish already; if a chunk straddles, nearest blob wins, the seam hides in water). No shader edits if your thresholds were already uniforms; the audit *is* the work.

5. **Sea tint + grading blend.** Route `sea_tint` into the shallow-water color (ch24/ch66 path). Implement `grade_blend_at(pos)` (Concepts) on the CPU each frame, feed the post shader the blended lift/gamma/gain. Clamp total weight so two close islands don't double-grade.

6. **The voyage test.** Fresh seed, full sail, cross the archipelago south to north. Lagoon → open sea → green hills → black ridges. If any leg of that trip feels like the previous island again, find which table row is too timid and turn it up. Differentiation reads at the horizon or not at all.

## Checkpoint

Four shores, one seed: a craggy ridged silhouette, a turquoise-ringed sliver of white, a low green tangle threaded with creeks, and the familiar temperate cousin — each recognizable at distance, each shifting the image's mood as you close.

- Same seed regenerates identical biomes, layouts, and vegetation, every run.
- Force-all-volcanic debug toggle: ridgelines have connected spines, not fBm bumps with sharp tops (the octave weighting is working).
- Sail an atoll pass into the lagoon: shallows go turquoise (sea tint), depth-tint shifts, and the grade warms — three systems agreeing about place.
- Adding a stub fifth biome (copy a row, change two numbers) touches the enum and the table *only* — the architecture test passes.

## Pitfalls

- **Volcanic islands look like regular islands with cliffs.** You ridged the final sum, not each octave — the per-octave `1 - abs(n)` plus the `weight` feedback is what makes ridge*lines*. Re-read the excerpt.
- **Ridged terrain floats above sea / range is wrong.** The 0..1 vs −1..1 mismatch from Concepts — the recipe must declare its output range, and `world_gen_height` must remap accordingly per recipe.
- **The lagoon is dry / the atoll is a wall.** Ring falloff multiplied against `sea_floor` remap wrong — inside the ring, mask ≈ 0 must mean *sea floor*, not zero height. Check the final-line arithmetic from ch21 step 4 with mask = 0.
- **Mangrove channels are disconnected puddles.** You thresholded `noise < x` (blobs) instead of `abs(noise) < x` (zero-crossing *lines*). The abs is the channels.
- **Biomes reshuffle between runs of the same seed.** Something consumed default-generator randomness before assignment, or you seeded once for all islands. `rand.reset` per island with a derived seed (excerpt), immediately before use — ch45's exact pitfall, worldgen edition.
- **Grading pops crossing between islands.** Weights don't sum smoothly — normalize by total weight including the open-sea base, and make every falloff a smoothstep, never a cutoff.

## Exercises

1. Biome ambience (if you built ch36): per-biome sound beds — surf-on-coral hiss for the atoll, insect drone for the mangrove, wind-over-stone for volcanic — crossfaded by the same proximity weights as the grade. Ears confirm what eyes suspect.
2. Volcanic smoke: a lazy ch46 emitter at the highest peak of each volcanic island — huge, slow, dark particles, wind-bent (ch73's `wind_at` formula CPU-side). Visible from miles: a *landmark*, which is gameplay.
3. Per-biome weather bias: mangroves rainier, atolls clearer — a per-biome nudge on the ch47 Markov weights when the boat is within an island's radius. Microclimates in five lines.
4. **Stretch:** archipelago *names*. Seed-derive a name per island (syllable tables: "Kava-ruu", "Pellan Skerry" — volcanic names harsher, atoll names softer) and float them on the ch48 HUD when first sighted (distance < 1500 m, first time). Part 12's chart room (ch79) will inherit this — and naming a thing you generated is the cheapest emotional investment mechanic ever discovered.

## Commit

`git commit -m "ch75: biomes — ridged volcanic, atoll rings, mangrove channels, data-driven palettes"`

[← Ch. 74: The Tempest](ch74-the-tempest.md) · [Ch. 76: MILESTONE — A Living World →](ch76-milestone-a-living-world.md)
