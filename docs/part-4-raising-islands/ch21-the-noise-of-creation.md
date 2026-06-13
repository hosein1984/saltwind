# Chapter 21 — The Noise of Creation

*Part 4 — Raising Islands · Estimated time: 3h · learnopengl: no direct equivalent — this is procedural-generation material*

**What you'll see when done:** type a different number, get a different world — an archipelago of islands you didn't draw, conjured from a seed and a sum of noise octaves.

## Where we are

Chapter 20's terrain machinery eats a `[]f32` of heights and doesn't care where they came from. The painted heightmap was scaffolding; today we replace it with **procedural noise**, which gives us infinite variety, perfect float precision (no 8-bit terracing), and — the magic word — a *seed*: the entire world compressed into one integer.

## Concepts

### Gradient noise, in one diagram

`rand()` per point gives white noise — useless static, no spatial structure. What terrain wants is *smooth* randomness: nearby points get similar values, distant points are uncorrelated. Perlin's insight (1985): put random **gradients** (directions) on an integer lattice, and between lattice points, blend the dot products of each corner's gradient with the offset to your sample point:

```
 lattice:   ↗        ↖       value at × = smooth blend of
            •--------•       dot(corner_gradient, offset_to_×)
            |   ×    |       over the 4 corners
            |        |
            •--------•       — zero AT corners, hills/valleys
            ↓        →         BETWEEN them, smooth everywhere
```

Because the value comes from gradients rather than random *values* at corners, the result has no flat spots at lattice points and a pleasing, dune-like character. **Simplex noise** (Perlin again, 2001) is the refinement everyone uses: a triangular lattice instead of a square one — fewer corners to blend, less directional grid artifact, cheaper in higher dimensions. Odin's `core:math/noise` implements **OpenSimplex2**, a patent-free, artifact-improved member of that family. One call gives you a value in roughly **[−1, 1]** that varies smoothly with the input coordinate.

One octave of simplex noise looks like rolling dunes — smooth, boring, single-scale. Real terrain has detail at *every* scale.

### fBm: stacking octaves

**Fractal Brownian motion** sums several noise samples ("octaves"), each at higher frequency and lower amplitude:

```
height = Σ  amplitude_i * noise(frequency_i * p)

frequency_i = base_freq * lacunarity^i      (lacunarity ≈ 2.0)
amplitude_i = persistence^i                 (persistence ≈ 0.5)
```

- **Lacunarity** — frequency multiplier per octave. 2.0 means each octave's features are half the size of the last.
- **Persistence** — amplitude multiplier. 0.5 means each octave contributes half as much. Raise it for craggy chaos, lower it for smooth hills with faint texture.

```
octave 0:  ~~~~∿~~~~∿~~~~        big swells
octave 1:  ∿∿∿∿∿∿∿∿∿∿∿∿∿∿        + hills          Σ = terrain
octave 2:  ʌʌʌʌʌʌʌʌʌʌʌʌʌʌʌʌ      + roughness
```

Divide by the total amplitude so the sum stays in [−1, 1] regardless of octave count. Five or six octaves is plenty for our scale.

(Worth a teaser now, payoff later: **domain warping** — feeding noise *coordinates* offset by other noise, `fbm(p + fbm(p))` — bends the straight "grain" of fBm into folded, tectonic-looking coasts. It's a two-line exercise below.)

### From noise field to islands: falloff masks

Raw fBm fills the whole plane with land. An island is fBm *multiplied by a mask* that is 1 in the middle and falls to 0 (and below) toward the edges. A radial **smooth bump** works beautifully:

```
d = distance(p, blob_center) / blob_radius        // 0 center, 1 edge
falloff = (1 - smoothstep(0, 1, d))               // 1 → 0, smooth
```

And the genuinely fun part — an **archipelago** is just several blobs, combined with `max` (union of islands), over one continuous fBm field. Because all blobs sample the *same* noise, neighboring islands share geological character, like a real island chain. Subtract a constant before scaling so the un-masked regions dip below sea level: seafloor, which Chapter 24 will read for shallows.

### Seeds

OpenSimplex2 takes an explicit `seed: i64`. Same seed + same params = same world, forever, on every machine — that's why a seed is a *save file* for geography. Use a different derived seed per octave (e.g. `seed + i`) so octaves don't share lattice alignment, and derive blob positions from the seed too (a tiny hand-rolled LCG or hash is fine) so the *layout* of the archipelago changes per seed, not just the bumps.

## Odin notes

Verified against [`core:math/noise`](https://pkg.odin-lang.org/core/math/noise/): the package provides `noise_2d`, `noise_3d_improve_xz`, etc. The 2D sampler is what we need:

```odin
import "core:math/noise"

v: f32 = noise.noise_2d(seed, noise.Vec2{x, z})   // noise.Vec2 :: [2]f64
```

Mind the types: **coordinates are `f64`** (`noise.Vec2 :: [2]f64`), the seed is `i64`, and the return is `f32`. There are no built-in octave/fBm helpers — we write our own, which is the point. (If you ever animate noise in time, `noise_3d_improve_xz(seed, {x, t, z})` is the recommended variant when y is your "different" axis.)

## Build

1. **Define the parameter struct** — this is the knob panel for your universe:

   ```odin
   World_Gen_Params :: struct {
       seed:         i64,
       frequency:    f64,     // base feature size; try 0.004 (units: 1/meter)
       octaves:      int,     // 5
       lacunarity:   f64,     // 2.0
       persistence:  f64,     // 0.5
       height_scale: f32,     // 45.0 — peak height in meters
       sea_floor:    f32,     // -12.0 — depth where masks hit zero
       blob_count:   int,     // 4
       world_radius: f32,     // blobs scatter within this radius
   }
   ```

2. **Write fBm:**

   ```odin
   fbm_2d :: proc(seed: i64, x, z: f64, octaves: int,
                  lacunarity, persistence: f64) -> f32 {
       sum, amp_total: f32
       amp:  f32 = 1.0
       freq: f64 = 1.0
       for i in 0 ..< octaves {
           sum += amp * noise.noise_2d(seed + i64(i), noise.Vec2{x * freq, z * freq})
           amp_total += amp
           freq *= lacunarity
           amp  *= f32(persistence)
       }
       return sum / amp_total   // back to ~[-1, 1]
   }
   ```

3. **Scatter falloff blobs from the seed.** A minimal LCG keeps it dependency-free and deterministic:

   ```odin
   Falloff_Blob :: struct { center: glsl.vec2, radius: f32 }

   next_rand :: proc(state: ^u64) -> f32 {       // xorshift-ish, 0..1
       state^ = state^ * 6364136223846793005 + 1442695040888963407
       return f32(state^ >> 40) / f32(1 << 24)
   }
   // in world_gen: rng := u64(params.seed) * 2 + 1
   // center = (next_rand-0.5) * 2 * world_radius per axis (keep first blob at 0,0)
   // radius = world_radius * (0.25 + 0.35 * next_rand(&rng))
   ```

4. **Write the height function** — the heart of the chapter:

   ```odin
   world_gen_height :: proc(p: World_Gen_Params, blobs: []Falloff_Blob,
                            wx, wz: f32) -> f32 {
       n := fbm_2d(p.seed, f64(wx) * p.frequency, f64(wz) * p.frequency,
                   p.octaves, p.lacunarity, p.persistence)      // -1..1
       n = n * 0.5 + 0.5                                        //  0..1

       mask: f32 = 0
       for b in blobs {
           d := glsl.length(glsl.vec2{wx, wz} - b.center) / b.radius
           t := clamp(d, 0, 1)
           bump := 1 - t * t * (3 - 2 * t)                      // smoothstep, inverted
           mask = max(mask, bump)
       }
       return p.sea_floor + (p.height_scale - p.sea_floor) * (n * mask)
   }
   ```

   Read the last line carefully: where the mask is 0 you get `sea_floor` (underwater plain); where mask and noise are both high you get peaks near `height_scale`. The coast — `height = 0` — emerges wherever `n * mask` crosses the right fraction. Nobody draws it; it just *happens*.

5. **Replace the image loader.** `terrain_generate(t: ^Terrain, params: World_Gen_Params)` fills `t.heights` by looping the grid and calling `world_gen_height` at each vertex's world xz, then calls your existing `terrain_build_mesh`. Keep `terrain_load_heightmap` around — it cost you nothing and it's a great debugging input. Grow the terrain to enjoy the archipelago: 512×512 vertices, `cell_size = 2`, origin centered.

6. **Run it. Then change the seed and run it again.** Spend a few minutes just generating worlds — and tune: `frequency` too high reads as crumpled foil, too low as featureless lens; `persistence` 0.45–0.55 is the sweet band.

## Checkpoint

Several distinct islands — varied size, shared character — rising from the sea, with underwater terrain faintly visible as dark sea-bottom where the water meets the beach (if your sea shader has any transparency yet; if not, that's Chapter 24).

- Same seed → byte-identical terrain across runs.
- `seed + 1` → completely different layout, same *style*.
- Octaves 1 vs 6 (live param + regenerate) → dunes vs detailed terrain.
- Generation time printed; a 512×512 grid with 5 octaves should be tens of milliseconds, not seconds.

## Pitfalls

- **Flat zero terrain.** You passed integer-ish coordinates: `noise.Vec2` is `[2]f64`, and if `frequency` is 1.0 with `cell_size` 2.0 you're sampling far-apart lattice points — looks like static or nothing. World-coordinate-times-small-frequency (≈0.001–0.01) is the right magnitude.
- **Every octave looks suspiciously aligned / value range drifts.** Same seed for all octaves, or you forgot to divide by `amp_total`. Both fixes are in the `fbm_2d` excerpt.
- **Islands always in the same places across seeds.** Blob positions not derived from the seed — only the noise changed. Feed the seed into the blob RNG.
- **A perfectly circular island outline.** Mask radius too small relative to noise feature size, so the mask dominates. Bigger blobs, or raise `frequency` so the noise has a vote at the coastline.
- **Hitch on regeneration.** You're regenerating per frame (param tweak hooked to update). Regenerate on keypress only; also remember `mesh_destroy` before rebuilding or you leak GL buffers every press.
- **`f32` passed where `f64` expected (compile error).** Odin doesn't implicitly convert. Cast at the fBm boundary, exactly once, like the excerpts do.

## Exercises

1. Live-tune: bind keys to nudge `persistence` and `octaves`, regenerate on press, print params. Ten minutes of this teaches more than any text.
2. **Ridged noise:** replace the octave sample with `1 - abs(noise_sample)` (before amplitude) for one of the high octaves — sharp mountain ridges appear.
3. Two-line **domain warp**: `wx2 := wx + 80 * fbm_2d(p.seed+99, f64(wx)*0.002, f64(wz)*0.002, 3, 2, 0.5)`, same for `wz2`, then sample the main fBm at the warped coordinates. Compare coastlines before/after.
4. **Stretch:** Add a `square_bump` falloff alternative (`1 - max(abs(dx), abs(dz))` squared and smoothed) and a per-blob `shape` enum — mixed-shape archipelagos read as more natural than all-circles.

## Commit

`git commit -m "ch21: fbm simplex terrain, falloff masks, seeded archipelago"`

← [Chapter 20 — Land from Numbers](ch20-land-from-numbers.md) · [Chapter 22 — The Lay of the Land](ch22-the-lay-of-the-land.md) →
