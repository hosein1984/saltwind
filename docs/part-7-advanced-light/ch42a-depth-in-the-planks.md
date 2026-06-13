# Interlude 42a — Depth in the Planks

*⚓ Optional interlude · slots after [Chapter 42](ch42-physically-based.md) · Estimated time: 3h · learnopengl: [Parallax Mapping](https://learnopengl.com/Advanced-Lighting/Parallax-Mapping)*

**Prerequisites:** Chapter 42 (TBN basis, normal mapping, the `Material` texture set). · **Required downstream:** none — skip freely.

**What you'll see when done:** crouch the camera to the deck and the gaps between planks open and close as you move — near edges occluding far walls of grooves that, geometrically, do not exist.

## Why this is a side quest

Normal mapping fakes the *lighting* of small-scale detail; from straight on it's magnificent, but slide toward a grazing view and the flatness confesses — bumps that catch light yet never shift, never occlude. Parallax mapping fakes the *position* too. It's a per-material luxury you spend exactly where the camera gets close (deck planks under your feet, rock faces you sail past), the main line ships beautifully without it, and it costs zero new GL objects — this whole interlude is fragment-shader craft.

## Concepts

### A height map and a lie

The ch42 texture set grows one channel: a **height map** (Poly Haven and ambientCG ship it as "displacement" in every set — linear, single channel, *not* sRGB). Following learnopengl we work in the **depth** convention: 0 = the surface plane, 1 = the deepest carving. If your map is white-is-high, invert at sample time: `depth = 1.0 - h`.

The lie itself: your fragment shader runs at point `P` on flat geometry, but the *carved* surface the eye would actually hit lies a little further along the view ray. So don't shade what's at `P` — figure out which texel the ray would really strike, and sample **all** the other maps there instead. The geometry never moves; only the UVs do.

### The view ray in tangent space

Every offset happens in UV space, so the view vector must live where UVs do: **tangent space**, where x and y are the U and V axes and z points out of the surface. You built the machinery in ch42 — and for an orthonormal TBN, the inverse is free:

```glsl
vec3 V_t = normalize(transpose(v_tbn) * (u_camera_pos - v_world_pos));
```

Now `V_t.xy / V_t.z` is "UV distance traveled per unit of depth descended" — the whole technique is walking that ratio.

### Basic → steep → POM

**Basic parallax** makes one guess: sample depth at `P`, offset by `(V_t.xy / V_t.z) · depth · scale`, done. One sample can't know about occlusion, so it shears and swims at steep depths and low angles — but it's ten minutes of work and calibrates your scale.

**Steep parallax** stops guessing and marches: slice the depth range into `n` layers, step the UV along the ray one layer at a time, and stop at the first step where the ray's depth is below the height field. Right shape, but quantized — depth comes back in `1/n` steps and surfaces band like contour lines.

**Parallax occlusion mapping** fixes the bands with one more sample's worth of math: at the crossing, you know how far the ray was *above* the surface on the previous step and *below* it on this one — linearly interpolate the two UVs by those signed distances. The intersection lands between layers, and the banding melts.

```
eye ──→ V_t          depth 0.00 ─●────────────────────  layer 0
                           0.33 ───●────____            layer 1
                           0.66 ─────●__/    ← crossed between layers 1 and 2:
                           1.00         \__    interpolate, don't snap
                                  height-field profile
```

### Where it shines, where it lies

Shines: tiling surfaces seen from arm's length at moderate angles — deck planks, rock, brick, rope coils. Breaks: **silhouettes** stay ruler-straight (the mesh edge doesn't know about the grooves), and at **extreme grazing angles** the march smears texels into streaks while the layer count explodes. The honest mitigations, both built below: fade the effect out by view angle so the worst sliver never renders, and fade by distance — beyond ~15 m the parallax shift is sub-pixel, so paying for a march there is pure waste. Distance also buys the **layer-count LOD**: fewer layers far away, where banding can't be seen. (One more lie to know about: shadow maps still see the flat surface, so a groove can be lit while "inside" a shadowed bump — at Saltwind's scales, nobody has ever noticed.)

> **Sidebar — self-shadowing.** Bumps that poke up should shade their own valleys, and the machinery is already in your hands: from the POM hit point, march *toward the light* (transform `L` into tangent space, same `transpose(v_tbn)`) with the same layered loop; if any step finds the height field above the ray, the texel is in its own shadow — multiply that light's diffuse by ~0.3. Eight lines, one extra march, and at sunset the plank grooves go striped with light and dark. Exercise 2 builds it.

## Odin notes

`Material` grows `height_tex: u32` and `height_scale: f32`; make the default a 1×1 *black* texture (depth 0 everywhere = perfectly flat), so every material you don't touch keeps rendering identically through the same shader. Load displacement maps like metallic/roughness — internal format `R8`/`RGBA8`, never `SRGB8_ALPHA8`.

## Build

1. **Extend `Material`.** Field, default black texture, `shader_set_f32(s, "u_height_scale", mat.height_scale)`, and a new sampler binding. Load the displacement maps for your deck wood and rock materials; start `height_scale` at 0.05.

2. **Tangent-space view vector.** In `pbr.frag`, compute `V_t` as above, call the function below once at the top of `main`, and use the offset UV for **every** texture sample — albedo, normal, metallic, roughness, AO. One UV, one truth.

3. **Basic parallax first.** Calibration before sophistication:

   ```glsl
   vec2 parallax_uv(vec2 uv, vec3 V_t) {
       float depth = texture(u_height, uv).r;
       return uv - (V_t.xy / max(V_t.z, 0.1)) * depth * u_height_scale;
   }
   ```

   Run it. Head-on it's already convincing; sweep the camera low along the deck and watch the planks shear sideways. That shear is what the march fixes — leave this version in until you've *seen* it.

4. **Steep parallax + POM interpolation.** Replace the body:

   ```glsl
   vec2 parallax_uv(vec2 uv, vec3 V_t) {
       float d    = length(u_camera_pos - v_world_pos);
       float lod  = 1.0 - smoothstep(8.0, 20.0, d);         // 1 near → 0 far
       float scale = u_height_scale * smoothstep(0.02, 0.15, V_t.z) * lod;
       if (scale < 1e-4) return uv;                         // distant/grazing: free

       float n       = mix(32.0, 8.0, clamp(V_t.z, 0.0, 1.0)) * max(lod, 0.25);
       float layer_d = 1.0 / n;
       vec2  delta   = (V_t.xy / V_t.z) * scale / n;

       vec2  cur   = uv;
       float depth = 0.0;
       float h     = textureLod(u_height, cur, 0.0).r;
       while (depth < h) {
           cur   -= delta;
           depth += layer_d;
           h      = textureLod(u_height, cur, 0.0).r;
       }
       vec2  prev   = cur + delta;
       float after  = h - depth;                                          // below
       float before = textureLod(u_height, prev, 0.0).r - depth + layer_d; // above
       return mix(cur, prev, after / (after - before));
   }
   ```

   Two deliberate choices to notice. `textureLod`, not `texture`: inside a loop whose trip count differs between neighboring pixels, implicit mip derivatives are undefined — some drivers shrug, others sparkle along plank seams. And the layer count runs `mix(32, 8, V_t.z)` — *more* layers at grazing angles, where each layer covers more UV distance.

5. **The honesty fades, verified.** They're already in step 4's first four lines: `smoothstep(0.02, 0.15, V_t.z)` kills only the worst grazing sliver (where even 32 layers smear), and the distance term fades both scale and layer count. Orbit the boat from 30 m: the deck must look exactly like ch42 — and cost exactly like ch42.

6. **Dress the set.** Deck planks: groove depth reads best at `height_scale` 0.04–0.06. Rock faces on any rock-textured props or your ch45 instanced rocks: 0.06–0.08. Resist big numbers — past ~0.1 every artifact in the Pitfalls list arrives at once.

## Checkpoint

Crouch to the deck at golden hour and slide the camera along a plank: the near edge of each groove occludes its far wall, seams open and close, and caulk lines duck behind wood that has no thickness. Stand up: the deck quietly returns to ch42. Sail past a rock face: bulges shift against each other with real parallax.

- Head-on view is pixel-identical to ch42 (offset → 0 as `V_t.xy` → 0).
- No contour-line banding in the grooves at low angles — the POM interpolation working.
- A debug key forcing `height_scale = 0` gives a clean A/B; the difference should be *startling* up close and invisible at 25 m.
- Title-bar ms unchanged when the deck is distant or off-screen (the early-out earning its keep).

## Pitfalls

- **The surface swims like heat haze.** Height/depth inverted — a white-is-high map read as depth marches the wrong way through the surface. Invert at sample time.
- **Bumps sink instead of rise (or slide *with* the camera).** Sign error: the convention here is camera-*to*-fragment flipped (`u_camera_pos - v_world_pos`) and `uv -= delta` while descending. Flip either one alone and the illusion inverts.
- **Contour-line banding.** Steep parallax without the interpolation tail, or the layer `mix` arguments reversed (giving *fewer* layers at grazing).
- **Sparkles or seams between planks.** `texture()` inside the divergent loop — use `textureLod`. If sparkles persist at texture tile borders, your height map isn't tileable and the march walked across the seam into an unrelated plank.
- **Lighting stopped matching the relief.** The height map got the offset UV but the normal map (or albedo) still samples `v_uv`. Every map, one offset UV.
- **Random texels smeared at the horizon-most angles.** `V_t.z` near zero makes `delta` enormous and the march leaps across the texture. The angle fade in step 4 is the guard — check you didn't "simplify" it away.

## Exercises

1. A/B the budget: keys to force `n` to 8, 32, and 64 layers with the LOD disabled, title-bar ms for each while the deck fills the screen. Find Saltwind's number, then re-enable the LOD and confirm it picks roughly that near and less far.
2. Build the self-shadow sidebar: tangent-space light march from the POM hit, multiply the sun's diffuse term. Watch the grooves go striped at sunset — then check the cost.
3. **Stretch:** relief mapping — replace the single interpolation with 5 binary-search refinement steps between `prev` and `cur`. Compare against POM at 8 layers, close up: binary search buys back most of what the low layer count lost, which is exactly how you'd ship POM on a tighter GPU budget.

## Commit

`git commit -m "ch42a: parallax occlusion mapping — tangent-space march, angle/distance fades, layer LOD"`

← Back to [Chapter 42 — Physically Based](ch42-physically-based.md) · onward to [Chapter 43 — Light from Everywhere](ch43-light-from-everywhere.md) →
