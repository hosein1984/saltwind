# Chapter 22 — The Lay of the Land

*Part 4 — Raising Islands · Estimated time: 2.5h · learnopengl: no direct equivalent — terrain shading is engine material (the [Multiple lights](https://learnopengl.com/Lighting/Multiple-lights) shader structure carries over)*

**What you'll see when done:** the relief map becomes land — sunlit slopes and shadowed valleys, beaches blending into grass, cliffs breaking through where the ground gets steep.

## Where we are

Your archipelago has shape but no shading: every fragment uses a fake up-normal, so the islands look like paper cutouts colored by altitude. This chapter computes real terrain normals (the right way), derives **slope** from them, and uses height *and* slope together to blend three ground textures — the technique known as **texture splatting**.

## Concepts

### Normals from a heightfield: central differences

You could compute each triangle's face normal and average them per vertex — the generic mesh approach. For a heightfield, don't. You have something better: the terrain *is* a function `h(x, z)`, and a function has derivatives. Sample the height one cell left/right and front/back, and the slope in each direction is a finite difference:

```
            h(x, z-1)
                │            dh/dx ≈ (h(x+1,z) - h(x-1,z)) / (2·cell)
 h(x-1, z) ── (x,z) ── h(x+1, z)
                │            dh/dz ≈ (h(x,z+1) - h(x,z-1)) / (2·cell)
            h(x, z+1)
```

Two tangent vectors follow: `(2·cell, hR−hL, 0)` along x and `(0, hF−hB, 2·cell)` along z. Their cross product — with signs worked through — gives the unnormalized normal:

```
n = normalize( vec3( hL − hR,  2·cell,  hB − hF ) )
```

(`hL` = height one cell in −x, `hR` = +x, `hB` = −z, `hF` = +z.) Why this beats face-averaging here:

- **Smoother**: central differences sample a 2-cell neighborhood symmetrically; face averaging inherits the diagonal split direction of your quads, producing a subtle herringbone shimmer in specular light.
- **Cheaper**: four array reads and a normalize per vertex; no triangle pass, no accumulation buffer.
- **Mesh-independent**: it's the derivative of the *heightfield*, not of one tessellation of it. Chapter 23 splits the terrain into chunks, and chunk meshes computed from the global heightfield get seamless normals for free — face-averaging per chunk would crease every border.

It's "analytic" in spirit: you're differentiating the underlying function, just numerically.

### Slope

How steep is the ground? The normal already knows. For unit `n` and up vector `(0,1,0)`:

```
slope = 1 − dot(n, up) = 1 − n.y      // 0 = flat, →1 = cliff
```

Flat beach: `n.y ≈ 1`, slope ≈ 0. A 45° hillside: `n.y ≈ 0.707`, slope ≈ 0.29. Near-vertical cliff: slope → 1. Cheap, already per-vertex, and exactly the input nature uses: soil and grass cling to flat ground; steep ground sheds them and shows rock.

### Texture splatting

Splatting = sampling several tiling textures and blending by per-fragment **weights**. Ours come from two rules, each a `smoothstep` band (hard `if` thresholds produce contour-line seams):

```
by height:  sand below ~1.5 m  → grass above ~5 m     (shore band)
by slope:   rock wherever slope > ~0.25, overriding both
```

Weights must (approximately) sum to 1 — compute them sequentially with `mix` so that's automatic:

```glsl
vec3 ground = mix(sand_col, grass_col, smoothstep(1.5, 5.0, height));
vec3 albedo = mix(ground, rock_col,  smoothstep(0.22, 0.38, slope));
```

Tiling practicalities: these textures repeat every few meters (uv = `world_pos.xz * tiles_per_meter`, wrap mode `gl.REPEAT`), so pick textures authored as seamless, and expect visible repetition at distance — every open-world game fights this; low-frequency noise modulation (exercise) is the standard first aid.

> **Sidebar — texture arrays.** Three samplers is fine; ten is uniform-juggling misery. GL 3.3 has `sampler2DArray`: one texture object with N layers, indexed by a float in the shader (`texture(arr, vec3(uv, layer))`). All layers must share size/format. When your splat palette grows past four or five, that's the upgrade — and it's a prerequisite mindset for instanced foliage in Chapter 45.

One more name to file away: **triplanar mapping** — projecting the texture along all three axes and blending by the normal — fixes the stretched-taffy look of steep cliffs that we're accepting today. It triples sample cost; it's the Stretch exercise.

## Build

1. **Compute normals after generation.** Add `terrain_compute_normals(t: ^Terrain)`, called at the end of `terrain_generate` before the mesh build; it fills the `normal` field of your vertex array (or a parallel `[]glsl.vec3` the mesh builder reads):

   ```odin
   terrain_compute_normals :: proc(t: ^Terrain, normals: []glsl.vec3) {
       h :: proc(t: ^Terrain, x, z: int) -> f32 {     // clamped fetch
           return t.heights[clamp(z, 0, t.depth-1) * t.width +
                            clamp(x, 0, t.width-1)]
       }
       for z in 0 ..< t.depth {
           for x in 0 ..< t.width {
               hl := h(t, x-1, z); hr := h(t, x+1, z)
               hb := h(t, x, z-1); hf := h(t, x, z+1)
               n  := glsl.normalize(glsl.vec3{hl - hr, 2 * t.cell_size, hb - hf})
               normals[z * t.width + x] = n
           }
       }
   }
   ```

   The clamped fetch handles edges by repeating the border height — adequate until Chapter 23 makes borders interior.

2. **Light the terrain properly.** Bring `terrain.frag` up to Part 3 standard: pass world normal from the vertex shader, do the sun's diffuse + ambient there (terrain rarely wants specular except wet sand — skip it for now). Identity model matrix means no normal-matrix gymnastics; `v_normal = a_normal` is honest here.

3. **Get three tiling textures.** Sand, grass, rock — e.g. from [Polyhaven](https://polyhaven.com/textures) (CC0) or [Kenney](https://kenney.nl); diffuse/albedo maps only. Load them `srgb = true` (they're colors!) with `gl.REPEAT` wrapping and mipmaps, into `assets/textures/terrain/`.

4. **Bind three texture units.** At terrain draw time:

   ```odin
   gl.ActiveTexture(gl.TEXTURE0); gl.BindTexture(gl.TEXTURE_2D, sand.id)
   gl.ActiveTexture(gl.TEXTURE1); gl.BindTexture(gl.TEXTURE_2D, grass.id)
   gl.ActiveTexture(gl.TEXTURE2); gl.BindTexture(gl.TEXTURE_2D, rock.id)
   shader_set_i32(terrain_shader, "u_sand", 0)
   shader_set_i32(terrain_shader, "u_grass", 1)
   shader_set_i32(terrain_shader, "u_rock", 2)
   ```

5. **The splat shader.** Replace Chapter 20's solid-color bands:

   ```glsl
   uniform sampler2D u_sand, u_grass, u_rock;

   void main() {
       vec2 tuv = v_world_pos.xz * 0.18;          // ~5.5 m repeat
       vec3 sand_c  = texture(u_sand,  tuv).rgb;
       vec3 grass_c = texture(u_grass, tuv).rgb;
       vec3 rock_c  = texture(u_rock,  tuv * 0.7).rgb;  // different tiling hides alignment

       vec3  N     = normalize(v_normal);
       float slope = 1.0 - N.y;
       float h     = v_world_pos.y;

       vec3 albedo = mix(sand_c, grass_c, smoothstep(1.5, 5.0, h));
       albedo      = mix(albedo, rock_c,  smoothstep(0.22, 0.38, slope));

       vec3 L = normalize(-sun_dir);
       vec3 lit = (0.18 + 0.82 * max(dot(N, L), 0.0)) * sun_color * albedo;
       frag_color = vec4(lit, 1.0);
   }
   ```

6. **Tune in motion.** Fly low along a coastline at a raking sun angle. Adjust the two smoothstep bands and the tiling factor until beaches feel beach-width and cliffs grab the steep faces. Hot-reload makes this the most pleasant tuning session so far.

## Checkpoint

Islands with readable terrain: bright and dark hillsides under the sun, sandy shorelines wrapping every coast at consistent width, grass above, and rock exactly where the ground steepens — including inland gullies you didn't know your noise had carved.

- Normal-visualization key: smooth rainbow over hills, no gridded shimmer, no seams at terrain edges.
- Drag the sun (Chapter 19 keys) across the sky: hillside shading swings convincingly; valleys fall into shadow at low angles.
- Rock appears on steep coastal bluffs even at *low* altitude — proof slope, not just height, is voting.

## Pitfalls

- **Lighting inverted on one axis (sun from the north lights southern slopes).** Sign error in the central difference — the normal formula is `{hl − hr, 2·cell, hb − hf}`; flipping either subtraction mirrors the lighting.
- **Terrain too flat-lit / too dramatic.** Missing `2 * cell_size` in the Y term (or using `1.0`). The Y term anchors *how steep a height difference is* relative to horizontal distance; wrong Y = wrong world.
- **Herringbone shimmer at glancing light.** You averaged face normals instead of central differences, or computed differences from *mesh vertices* of a strided/LOD mesh rather than the full `heights` array.
- **Hard contour lines between materials.** `step` (or an `if`) instead of `smoothstep`, or both smoothstep edges set equal.
- **Washed-out ground textures.** Loaded with `srgb = false`. Albedo textures are colors — Chapter 16 discipline applies.
- **Obvious tiling checkerboard from altitude.** Inherent; mitigate by differing tiling factors per layer (the `* 0.7` above), and do Exercise 2.

## Exercises

1. Put the four smoothstep edges (`h0, h1, s0, s1`) and the tiling factor in uniforms; tune live, then bake the winners into the shader.
2. Break up tiling: modulate the height threshold by low-frequency noise — `smoothstep(1.5, 5.0, h + 1.5 * noise_tex_sample)` — using a small noise texture (or vertex-color noise from `fbm_2d` baked into uv2). Coastline grass edges turn ragged and natural.
3. Add a fourth band: snow above ~30 m on flat-enough ground (`slope < 0.2`). One more `mix`.
4. **Stretch:** Triplanar-map just the rock layer: sample `u_rock` three times with `world.yz`, `world.xz`, `world.xy` uvs, blend by `abs(N)` raised to a sharpening power and normalized. Compare a cliff face before/after — the taffy-stretch vanishes.

## Commit

`git commit -m "ch22: central-difference normals, slope, texture splatting"`

← [Chapter 21 — The Noise of Creation](ch21-the-noise-of-creation.md) · [Chapter 23 — A World in Pieces](ch23-a-world-in-pieces.md) →
