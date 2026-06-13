# Chapter 23 — A World in Pieces

*Part 4 — Raising Islands · Estimated time: 3h · learnopengl: [Guest Article: Frustum Culling](https://learnopengl.com/Guest-Articles/2021/Scene/Frustum-Culling)*

**What you'll see when done:** the same archipelago — but the window title now reads something like `chunks 19/64`, and that fraction is the GPU work you're *not* doing anymore.

## Where we are

Your terrain is one mesh. Every frame, the GPU transforms all half-million vertices — including the islands behind your head. The fix has two halves: cut the terrain into **chunks** (so there's something to skip), and test each chunk's bounding box against the camera's **view frustum** (so we know what to skip). This is the first chapter whose payoff is a *number* rather than a pixel — and it's the load-bearing wall for every "more stuff" chapter ahead (instancing, foliage, LOD).

## Concepts

### Why chunks

A draw call is all-or-nothing: the GPU can't skip half a mesh. Visibility culling therefore needs geometry split into independently drawable pieces, each with a cheap proxy — an **AABB** (axis-aligned bounding box) — that conservatively contains it. Per frame, per chunk: test AABB against frustum; draw or skip.

Chunk size is a trade: small chunks cull tightly but multiply draw calls; huge chunks are one draw but cull coarsely. **64×64 cells (65×65 vertices) per chunk** is a fine default. The +1 matters: adjacent chunks must *share* their border row/column of vertices (both chunks emit them), or one-cell gaps open along every seam.

```
 512×512-cell terrain → 8×8 = 64 chunks
 ┌────┬────┬────┐ ┄        each chunk:
 │    │    │    │          65×65 verts = 4225
 ├────┼────┼────┤          8192 tris
 │    │ ◉  │    │          1 AABB: (min_x, min_y, min_z)
 ├────┼────┼────┤                   (max_x, max_y, max_z)
 │    │    │    │          y bounds from the chunk's
 └────┴────┴────┘ ┄        actual min/max heights
```

The AABB's y-extent comes from scanning the chunk's heights during the build — a mountain chunk gets a tall box, a seafloor chunk a flat one. Tight boxes cull better.

### The frustum, and where its planes come from

The camera sees a truncated pyramid — the frustum — bounded by six planes: near, far, left, right, top, bottom. The elegant fact (Gribb & Hartmann's classic observation): you can read all six planes straight off the combined view-projection matrix, no trigonometry, no FOV math.

Why it works, in three lines: after `clip = VP · world`, a point is visible iff `−w ≤ x ≤ w` (same for y, z). Take the left bound: `x ≥ −w` rewrites as `(row₄ + row₁) · world ≥ 0` — which is exactly "the point is on the positive side of the plane whose coefficients are *row 4 plus row 1* of VP." Each of the six inequalities yields one plane:

```
left   = row4 + row1        right  = row4 − row1
bottom = row4 + row2        top    = row4 − row2
near   = row4 + row3        far    = row4 − row3
```

Each plane is a `vec4` `(a, b, c, d)` meaning `a·x + b·y + c·z + d ≥ 0` for points inside. For in/out tests the planes don't even need normalizing (only distances in world units would).

Column-major alert: Odin's `glsl.mat4` (like GLSL) is column-major, indexed `m[col, row]`. "Row i" of the matrix is therefore gathered *across* columns: `{m[0, i], m[1, i], m[2, i], m[3, i]}`. This single indexing fact causes 90% of frustum-culling failures.

### AABB vs plane: the positive-vertex trick

A box is outside the frustum if it's entirely on the negative side of *any* plane. Testing all 8 corners works; the slick version tests one: the **p-vertex**, the corner farthest along the plane normal. Pick each coordinate of the corner by the sign of the plane's normal component — if even the *most-positive* corner is below the plane, the whole box is out.

```
        plane n →
   ┌────────●  ← p-vertex (max x chosen because n.x > 0, etc.)
   │  AABB  │     dot(n, p) + d < 0  ⇒  box fully outside
   └────────┘
```

Note the test is *conservative the right way*: boxes that straddle a plane (or sit in the frustum's corner regions outside the true pyramid) are kept. We never skip a visible chunk; we occasionally draw an invisible one. Correctness first, efficiency second.

## Build

1. **The chunk type**, alongside `Terrain`:

   ```odin
   Terrain_Chunk :: struct {
       mesh:     Mesh,
       aabb_min: glsl.vec3,
       aabb_max: glsl.vec3,
   }
   ```

   `Terrain` gains `chunks: []Terrain_Chunk` and `chunk_cells: int` (64). The global `heights` array stays — it remains the single source of truth for normals (Chapter 22's seam-free guarantee), `terrain_height_at`, and Chapter 24's heightfield texture.

2. **Split the build.** Rework `terrain_build_mesh` into `terrain_build_chunks(t)`: loop chunk coordinates `(cx, cz)`; for each, emit vertices for grid range `[cx*64 .. cx*64+64] × [cz*64 .. cz*64+64]` *inclusive* (the shared border), indices with the same `a,c,b / b,c,d` winding (local indexing now — vertex `(x,z)` within the chunk is `z * 65 + x`), and track min/max while you go:

   ```odin
   lo := glsl.vec3{max(f32), max(f32), max(f32)}
   hi := glsl.vec3{min(f32), min(f32), min(f32)}
   for /* each vertex position p in this chunk */ {
       lo = glsl.min(lo, p)
       hi = glsl.max(hi, p)
   }
   chunk.aabb_min, chunk.aabb_max = lo, hi
   ```

   (If `glsl.min/max` on vectors isn't in your version, componentwise `min()` on the three fields — Odin's builtin `min` — does it.) Normals still come from the global `heights` via Chapter 22's central differences — *not* per-chunk meshes.

3. **Extract the frustum** in `src/frustum.odin`:

   ```odin
   Frustum :: [6]glsl.vec4

   frustum_from_matrix :: proc(vp: glsl.mat4) -> (f: Frustum) {
       row :: proc(m: glsl.mat4, i: int) -> glsl.vec4 {
           return {m[0, i], m[1, i], m[2, i], m[3, i]}   // column-major gather!
       }
       r0, r1, r2, r3 := row(vp, 0), row(vp, 1), row(vp, 2), row(vp, 3)
       f[0] = r3 + r0   // left
       f[1] = r3 - r0   // right
       f[2] = r3 + r1   // bottom
       f[3] = r3 - r1   // top
       f[4] = r3 + r2   // near
       f[5] = r3 - r2   // far
       return
   }
   ```

   Build it once per frame from `camera_projection(...) * camera_view_matrix(...)` — the same product you upload, same order.

4. **The visibility test:**

   ```odin
   aabb_in_frustum :: proc(f: Frustum, lo, hi: glsl.vec3) -> bool {
       for plane in f {
           p := glsl.vec3{
               hi.x if plane.x >= 0 else lo.x,
               hi.y if plane.y >= 0 else lo.y,
               hi.z if plane.z >= 0 else lo.z,
           }
           if plane.x * p.x + plane.y * p.y + plane.z * p.z + plane.w < 0 {
               return false   // fully outside this plane
           }
       }
       return true
   }
   ```

5. **Cull in the draw loop**, and count:

   ```odin
   drawn := 0
   for &chunk in game.terrain.chunks {
       if !aabb_in_frustum(frustum, chunk.aabb_min, chunk.aabb_max) do continue
       mesh_draw(&chunk.mesh)
       drawn += 1
   }
   ```

6. **Show the stats.** Once per second (you have a timer from the fixed-timestep work), put it in the title:

   ```odin
   glfw.SetWindowTitle(game.window,
       fmt.ctprintf("Saltwind — chunks %d/%d", drawn, len(game.terrain.chunks)))
   ```

7. **Add the freeze-frustum debug key** (this is not optional — it's how you *verify* culling): a key that stops updating the stored frustum while the camera keeps moving. Fly backwards out of the frozen view and watch chunks disappear from the edges of where you *were* looking. There is no better way to catch over-culling.

## Checkpoint

The archipelago renders pixel-identically to Chapter 22 — that's the first test. The title fraction tells the new story.

- Looking at the horizon across the world: roughly a third to half of chunks drawn. Straight down at your feet: a handful. Sky: near zero (terrain behind you culled).
- Freeze the frustum, fly to the side: a clean hole in the world matching the frozen view's edges, chunk-shaped bites and all.
- No seams or normal creases along any chunk border (global-heights normals doing their job).
- With culling forcibly off (`drawn = all`), identical image — culling must only ever remove the invisible.

## Pitfalls

- **Everything culled / nothing ever culled.** The row gather is wrong — you grabbed columns (`m[i, 0..3]`) instead of rows (`m[0..3, i]`). Column-major. Check this first, always.
- **Chunks vanish while clearly on screen, worst at screen edges.** AABB y-range wrong (forgot to include heights, or min/max swapped), or you extracted from `P` only / `V * P` instead of `P * V` — use exactly the matrix product you render with.
- **One-cell-wide gaps between chunks.** Off-by-one: chunks must share border vertices — 65 vertices per 64 cells. Inclusive upper bound in the vertex loop.
- **Lighting seams at chunk borders.** Normals computed per-chunk (clamped differences at chunk-local edges). Compute from the global `heights` array with global clamping.
- **Culling pops only when *rolling* or at high FOV.** You normalized planes with a bug, or built the frustum from last frame's camera. Build after camera update, before draw; normalization is unnecessary — delete it.
- **Draw calls went from 1 to 64 and frame time *rose*.** Per-draw work (uniform re-uploads, texture rebinds) now ×64. Bind terrain shader/textures once outside the chunk loop; per chunk, only the draw.

## Exercises

1. Track and display culled-vertex count, not just chunks — `(total − drawn) * 4225` makes the savings visceral.
2. Sort visible chunks front-to-back by AABB-center distance before drawing. No visual change, but early-z gets friendlier; you'll want this habit by Part 7.
3. Give `aabb_in_frustum` a unit test in pure Odin (`core:testing`): hand-build a simple perspective VP, assert boxes ahead/behind/beside the camera classify correctly.
4. **Stretch:** Per-chunk LOD: build a second index buffer per chunk with stride-2 vertices (quarter the triangles) and select it when the AABB center is beyond some distance. Watch for cracks at LOD borders — and read how the [tessellation article](https://learnopengl.com/Guest-Articles/2021/Tessellation/Tessellation) solves this on the GPU in GL 4.x.

## Commit

`git commit -m "ch23: terrain chunks, frustum extraction, aabb culling"`

← [Chapter 22 — The Lay of the Land](ch22-the-lay-of-the-land.md) · [Chapter 24 — Where Land Meets Sea](ch24-where-land-meets-sea.md) →
