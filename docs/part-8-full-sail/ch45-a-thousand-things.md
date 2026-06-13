# Chapter 45 — A Thousand Things

*Part 8 — Full Sail · Estimated time: 4–5h · learnopengl: [Instancing](https://learnopengl.com/Advanced-OpenGL/Instancing)*

**What you'll see when done:** islands crowded with palms swaying over rocks and grass tufts, a flock of gulls wheeling over your mast — thousands of objects, one draw call each *kind*.

## Where we are

Golden hour looked gorgeous and *empty*. Islands need vegetation; skies need birds. The naive approach — one draw call per palm — dies fast, and this chapter starts by making you watch it die, because the lesson ("draw calls have fixed CPU cost; geometry is nearly free") is the most important performance fact in real-time rendering. Then we fix it with instancing: one draw call, N copies, per-instance data streamed as vertex attributes.

## Concepts

### Why 500 draw calls hurt when 500,000 triangles don't

Every `gl.DrawElements` costs the *CPU*: driver validation, state snapshot, command-buffer encoding — on the order of tens of microseconds with a 3.3-era driver. 500 palms × ~40 µs ≈ 20 ms of pure overhead before the GPU draws a single triangle. Meanwhile the GPU eats vertices by the million per millisecond. The bottleneck is the *number of conversations*, not the amount said in each.

**Instancing** is one conversation about N things: `gl.DrawElementsInstanced(mode, count, type, indices, instance_count)` draws the same mesh `instance_count` times; the vertex shader distinguishes copies by `gl_InstanceID` — or better, by **instanced arrays**.

### Instanced arrays: per-instance vertex attributes

`gl.VertexAttribDivisor(index, 1)` changes an attribute's advance rate: instead of *per vertex*, it advances *per instance*. Pack each instance's model matrix into a VBO, and every instance's vertices see "their" matrix as a plain attribute. One wrinkle: an attribute slot holds at most a vec4, so a mat4 occupies **four consecutive attribute locations**:

```
attrib 3: column 0 (vec4) ┐
attrib 4: column 1 (vec4) ├── glsl: layout(location = 3) in mat4 a_model;
attrib 5: column 2 (vec4) │   (consumes locations 3,4,5,6 automatically)
attrib 6: column 3 (vec4) ┘   divisor = 1 on all four
```

### Scattering: procedural placement with rules

Where do palms go? The terrain already knows: you have `terrain_height_at(x, z)` and normals from ch22. Scattering = throw seeded-random points at an island's bounds, keep those passing per-species rules:

| Species | height above sea | slope (n.y) | density |
|---|---|---|---|
| Palm | 1.5 – 12 m | > 0.85 (flat-ish) | low, beach bias |
| Rock | anywhere above water | any | sparse |
| Grass tuft | 1 – 25 m | > 0.75 | high |

Seeded means *deterministic*: same world seed, same forests, every run — your archipelago stays *yours*. Randomize yaw and scale (0.8–1.3) per instance or the copies read as obvious clones.

### A flock of gulls

Same machinery, dynamic data: gull instance matrices change every frame, so their instance VBO is updated with `gl.BufferSubData` each frame (with `gl.DYNAMIC_DRAW` at allocation). For motion, full boids are optional; layered orbits are 90% of the effect for 5% of the code: each gull follows an inclined ellipse around a drifting flock center with its own phase and radius, banking into the turn. (If boids tempt you: separation/alignment/cohesion over a `[dynamic]` array of positions+velocities is ~40 lines — Exercise 3.)

## Odin notes

`core:math/rand` seeding: the modern API uses `rand.reset(seed)` to reseed the default generator (per [pkg.odin-lang.org/core/math/rand](https://pkg.odin-lang.org/core/math/rand/) — `rand.create` is gone; generators live in `context.random_generator`). For order-independent determinism, derive a per-island seed: `rand.reset(world_seed ~ island_seed(i))`, then `rand.float32()`, `rand.float32_range(lo, hi)` as needed. Matrices: `glsl.mat4` is column-major and tightly packed, so a `[]glsl.mat4` uploads directly: `gl.BufferData(gl.ARRAY_BUFFER, len(mats) * size_of(glsl.mat4), raw_data(mats), gl.STATIC_DRAW)`.

## Build

1. **Watch it die first.** Load (or generate — a cylinder + cone-fan canopy is fine until you OBJ a real palm) a palm mesh. Spawn 500 with a naive loop of `mesh_draw` calls, each with its own `shader_set_mat4("u_model", ...)`. Put your ch10 frame timer on screen (or print it). Note the ms. *Write the number in a comment.* This is your baseline for the victory lap.

2. **`Instanced_Mesh`.** A mesh plus an instance buffer:

   ```odin
   Instanced_Mesh :: struct {
       mesh:         Mesh,
       instance_vbo: u32,
       count:        i32,
   }

   instanced_mesh_create :: proc(mesh: Mesh, mats: []glsl.mat4, dynamic_: bool) -> (im: Instanced_Mesh) {
       im.mesh = mesh
       im.count = i32(len(mats))
       gl.GenBuffers(1, &im.instance_vbo)
       gl.BindVertexArray(mesh.vao)
       gl.BindBuffer(gl.ARRAY_BUFFER, im.instance_vbo)
       gl.BufferData(gl.ARRAY_BUFFER, len(mats) * size_of(glsl.mat4),
                     raw_data(mats), dynamic_ ? gl.DYNAMIC_DRAW : gl.STATIC_DRAW)
       for i in u32(0) ..< 4 { // four vec4 columns at locations 3..6
           loc := 3 + i
           gl.EnableVertexAttribArray(loc)
           gl.VertexAttribPointer(loc, 4, gl.FLOAT, false,
                                  size_of(glsl.mat4), uintptr(i * size_of(glsl.vec4)))
           gl.VertexAttribDivisor(loc, 1)
       }
       gl.BindVertexArray(0)
       return
   }

   instanced_mesh_draw :: proc(im: ^Instanced_Mesh) {
       gl.BindVertexArray(im.mesh.vao)
       gl.DrawElementsInstanced(gl.TRIANGLES, im.mesh.index_count,
                                gl.UNSIGNED_INT, nil, im.count)
   }
   ```

3. **Instanced shader variant.** Copy `pbr.vert` to `pbr_instanced.vert`: replace `uniform mat4 u_model` with `layout(location = 3) in mat4 a_model`, and the normal matrix with `mat3(a_model)` (legitimate while instance scaling stays uniform — note the caveat in a comment). The fragment shader is shared untouched — abstractions paying rent.

4. **The scatter pass.** At world-gen time, per island:

   ```odin
   scatter_species :: proc(t: ^Terrain, seed: u64, tries: int,
                           min_h, max_h, min_ny: f32) -> [dynamic]glsl.mat4 {
       rand.reset(seed)
       out: [dynamic]glsl.mat4
       for _ in 0 ..< tries {
           x := rand.float32_range(t.bounds.min.x, t.bounds.max.x)
           z := rand.float32_range(t.bounds.min.z, t.bounds.max.z)
           h := terrain_height_at(t, x, z)
           n := terrain_normal_at(t, x, z)
           if h < min_h || h > max_h || n.y < min_ny { continue }
           m := glsl.mat4Translate({x, h, z})
              * glsl.mat4Rotate({0, 1, 0}, rand.float32() * math.TAU)
              * glsl.mat4Scale(glsl.vec3(rand.float32_range(0.8, 1.3)))
           append(&out, m)
       }
       return out
   }
   ```

   Run it for palms, rocks, grass with the table's rules; build one `Instanced_Mesh` per species. Draw each with the instanced shader. (Grass tufts: a pair of crossed quads, two-sided per the ch38 exception, alpha-tested with `discard`.)

5. **Gulls.** A stretched-diamond body + two triangle wings is a fine gull at distance (flap by scaling wing verts in the vertex shader with `sin(u_time * 8.0 + float(gl_InstanceID))` — instanced *and* animated for free). Each frame, recompute ~30 matrices around a center that slowly orbits the boat, and:

   ```odin
   gl.BindBuffer(gl.ARRAY_BUFFER, gulls.instance_vbo)
   gl.BufferSubData(gl.ARRAY_BUFFER, 0, len(mats) * size_of(glsl.mat4), raw_data(mats))
   ```

6. **The victory lap.** Crank palms to 2000, grass to 20,000. Compare frame time against your step-1 comment. Smile.

## Checkpoint

Sailing past an island: palm clusters lean over the beach line, rocks pepper the slopes, grass shivers in the wind band above the sand — and a loose spiral of gulls turns above your wake. Frame time within ~1 ms of empty-island ch44.

- 500 naive palms measurably slow (your recorded number); 2000+ instanced palms don't.
- Regenerate the world with the same seed: identical placement, every time.
- No palms underwater, none on cliff faces (rules working).
- Gulls flap out of phase with each other and bank as they turn.

## Pitfalls

- **All instances render at the origin, stacked.** The instance attributes aren't enabled on this VAO (they're VAO state! create them with the mesh's VAO bound), or divisor wasn't set so every vertex reads matrix row 0.
- **Instances render but distorted/sheared.** Attribute stride/offset wrong — each column is one vec4 at offset `i * 16` bytes with stride `size_of(glsl.mat4)` = 64.
- **Only the first instance is correct.** You uploaded with `size_of(mats)` (slice header = 16 bytes!) instead of `len(mats) * size_of(glsl.mat4)`. The classic Odin GL slip since ch3.
- **Scatter differs between runs despite the seed.** Something else consumed randomness from the default generator between `rand.reset` and your scatter (or chunk generation order varies). Reset immediately before each species, with a derived per-species seed.
- **Palms pop in/out at island edges.** Your ch23 frustum culling tests per-chunk AABBs; the instanced palm batch needs its own AABB (union of instance positions + mesh radius), or skip culling vegetation batches entirely — one draw call is cheap to leave on.
- **Grass looks like black rectangles at distance.** Alpha-tested cutouts + mipmaps = fading coverage. Quick fix: clamp the texture's lower mips' alpha or raise the `discard` threshold; proper fix is alpha-to-coverage (worth a search if it bugs you).

## Exercises

1. Wind sway: pass `u_time` and wind direction (you have a wind model from ch33!) into the instanced vertex shader; bend palms by `sin(time + world_pos.x * 0.1)` scaled by height above ground, and shiver grass at higher frequency. The island comes *alive*.
2. Density maps: instead of uniform tries, multiply acceptance probability by a low-frequency noise sample so palms cluster in groves rather than spreading evenly.
3. Real boids for the gulls: separation/alignment/cohesion + a soft attractor toward the boat. Cap speeds, clamp turn rates, and they stop looking like particles and start looking like birds.
4. **Stretch:** distance-culled vegetation — partition grass instances by terrain chunk, and only include chunks within 150 m in the draw (rebuild or sub-range the instance buffer per frame). Measure: at what count does *updating* cost more than just always drawing?

## Commit

`git commit -m "ch45: instanced vegetation scatter and a gull flock"`

[← Ch. 44: Golden Hour](../part-7-advanced-light/ch44-milestone-golden-hour.md) · [Ch. 46: Spray & Storm →](ch46-spray-and-storm.md)
