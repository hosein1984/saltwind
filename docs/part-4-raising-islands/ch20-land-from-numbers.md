# Chapter 20 — Land from Numbers

*Part 4 — Raising Islands · Estimated time: 2.5h · learnopengl: [Guest Article: Tessellation — Height map](https://learnopengl.com/Guest-Articles/2021/Tessellation/Height-map) (further reading; we build the mesh on the CPU)*

**What you'll see when done:** the first land in Saltwind — a gray-green island rising out of your flat blue sea, built from nothing but a grayscale image and a double loop.

## Where we are

Part 3 ended with a sunlit anchorage and nowhere to sail to. Terrain in real-time graphics almost always starts the same way: a **heightmap** — a 2D array of elevations — turned into a grid mesh where each vertex's `y` comes from the array. This chapter builds that machinery with the heights read from a grayscale image; Chapter 21 swaps the image for procedural noise, and the machinery survives untouched.

## Concepts

### The heightfield contract

A heightfield says: *for every (x, z) on a regular grid, here is one height y.* That single restriction (no caves, no overhangs) buys you enormous simplification — terrain becomes a function `height(x, z)`, storable as a flat `[]f32`, sampleable by anything (mesh builder, boat physics, sea shader in Chapter 24).

An 8-bit grayscale image is a fine first source: texel value 0 = lowest, 255 = highest. Two numbers map it into the world:

- `cell_size` — meters between adjacent grid vertices (horizontal scale)
- `height_scale` — meters of elevation at texel value 255 (vertical scale)

Keep heights in **meters in world space** in the `[]f32` from the start — convert from texel units exactly once, at load. Every later system (normals, buoyancy, shoreline) gets to assume meters.

### Grid topology and winding

A `width × depth` array of vertices yields `(width−1) × (depth−1)` quads, each split into two triangles. Vertex `(x, z)` lives at flat index `z * width + x` — write that little formula on a sticky note; nearly every terrain bug for the next three chapters is this formula scrambled.

```
   x →                       quad (a,b,c,d):     a───b
 z a───b ...                 tri 1: a, c, b      │ \ │   CCW seen
 ↓ │ \ │                     tri 2: b, c, d      │  \│   from ABOVE (+y)
   c───d ...                                     c───d
```

Winding matters because face culling is on (or will be). With +x east and +z south, the order `a, c, b` / `b, c, d` is counter-clockwise viewed from above — the surface's front faces the sky. Get it backwards and your island is invisible from the air but visible from underground, a uniquely disorienting bug.

### How big is this mesh?

A 256×256 heightmap is 65,536 vertices and 130,050 triangles — trivially fine as a single draw. But notice the smell: one mesh means the GPU processes every triangle even when you're looking at one corner of the island. Hold that thought for Chapter 23 (chunks + culling). For today, one `Mesh` is correct and simple.

### Color before normals

Proper terrain lighting needs per-vertex normals — that's Chapter 22's job (done right, via central differences). To make today's island readable without them, the fragment shader colors by **height bands** — sand low, grass mid, rock high — with a fixed up-facing normal for a touch of sun. It will look like a relief map, not a landscape. That's the correct amount of done for today.

## Build

1. **Define `Terrain`** in `src/terrain.odin`, per course conventions:

   ```odin
   Terrain :: struct {
       width, depth:  int,        // vertex counts
       cell_size:     f32,        // meters between vertices
       height_scale:  f32,        // meters at full white
       heights:       []f32,      // len = width * depth, world meters
       origin:        glsl.vec3,  // world position of vertex (0, 0)
       mesh:          Mesh,
   }
   ```

   And the sampling helper everything else will use — bilinear, clamped:

   ```odin
   terrain_height_at :: proc(t: ^Terrain, world_x, world_z: f32) -> f32 {
       fx := (world_x - t.origin.x) / t.cell_size
       fz := (world_z - t.origin.z) / t.cell_size
       x0 := clamp(int(fx), 0, t.width  - 2)
       z0 := clamp(int(fz), 0, t.depth  - 2)
       tx := clamp(fx - f32(x0), 0, 1)
       tz := clamp(fz - f32(z0), 0, 1)
       h00 := t.heights[ z0      * t.width + x0    ]
       h10 := t.heights[ z0      * t.width + x0 + 1]
       h01 := t.heights[(z0 + 1) * t.width + x0    ]
       h11 := t.heights[(z0 + 1) * t.width + x0 + 1]
       top := h00 + (h10 - h00) * tx
       bot := h01 + (h11 - h01) * tx
       return top + (bot - top) * tz
   }
   ```

2. **Load the heightmap** with stb_image, requesting a single channel:

   ```odin
   terrain_load_heightmap :: proc(t: ^Terrain, path: cstring) -> bool {
       w, h, n: i32
       pixels := stbi.load(path, &w, &h, &n, 1)   // force grayscale
       if pixels == nil do return false
       defer stbi.image_free(pixels)

       t.width, t.depth = int(w), int(h)
       t.heights = make([]f32, t.width * t.depth)
       for i in 0 ..< len(t.heights) {
           t.heights[i] = f32(pixels[i]) / 255.0 * t.height_scale
       }
       return true
   }
   ```

   Note what's *not* here: no sRGB. A heightmap is data (Chapter 16's distinction, now load-bearing) — and since we read raw bytes ourselves rather than uploading to a GL texture, there's no place to make that mistake. Yet.

3. **Build the mesh** — `terrain_build_mesh(t: ^Terrain)`. Vertices first (uv spans 0..1 across the whole terrain; normals straight up for now), then the index loop, which is the part worth showing:

   ```odin
   for z in 0 ..< t.depth - 1 {
       for x in 0 ..< t.width - 1 {
           a := u32( z      * t.width + x)
           b := u32( z      * t.width + x + 1)
           c := u32((z + 1) * t.width + x)
           d := u32((z + 1) * t.width + x + 1)
           append(&indices, a, c, b)
           append(&indices, b, c, d)
       }
   }
   ```

   Vertex positions: `{origin.x + f32(x) * cell_size, heights[z * width + x], origin.z + f32(z) * cell_size}`. Finish with `t.mesh = mesh_create(vertices[:], indices[:])`.

4. **Get a heightmap.** Any 8-bit grayscale PNG works: paint a soft white blob on black in GIMP/Krita (Gaussian-blurred scribbles make surprisingly good islands), or grab any free heightmap PNG online. 256×256 is plenty. Save to `assets/textures/heightmap.png`. Reasonable first numbers: `cell_size = 2.0`, `height_scale = 40.0`, origin centered: `{-256, 0, -256}`.

5. **Write `terrain.vert` / `terrain.frag`.** The vertex shader is your standard MVP with world position passed through. The fragment shader banding, with `smoothstep` so bands blend instead of striping:

   ```glsl
   in vec3 v_world_pos;
   uniform vec3 sun_dir;

   void main() {
       vec3 sand  = vec3(0.76, 0.70, 0.50);
       vec3 grass = vec3(0.25, 0.45, 0.20);
       vec3 rock  = vec3(0.45, 0.42, 0.40);
       float h = v_world_pos.y;
       vec3 albedo = mix(sand, grass, smoothstep(1.0,  6.0, h));
       albedo      = mix(albedo, rock, smoothstep(14.0, 22.0, h));
       float light = 0.25 + 0.75 * max(dot(vec3(0,1,0), -sun_dir), 0.0);
       frag_color = vec4(albedo * light, 1.0);
   }
   ```

6. **Draw it** before the sea in your render loop (model matrix = identity — the terrain bakes its placement into its vertices via `origin`). Fly over and around it.

7. **One sanity assert** that will save you in Chapter 21: after building, check `terrain_height_at` at a few vertex positions against the raw array. Bilinear at exact vertices must return the vertex height.

## Checkpoint

An island — sand ringing its base, grass on the flanks, gray rock at the summit — sitting in your sea, with the sea plane visibly lapping its lower slopes.

- Flying *through* the island is possible (no collision — fine) and from underneath you see through it (culling — correct winding confirmed).
- `height_scale` doubled at runtime + mesh rebuilt = mountains; halved = dunes.
- Band edges are soft gradients, not hard contour lines.
- The crates/buoys from Part 3 still render correctly afterward (state leaks show up here).

## Pitfalls

- **Diagonal shredded-paper mess.** Index formula scrambled — usually `x * width + z` in one place and `z * width + x` in another. One helper proc, `terrain_index(t, x, z)`, used everywhere.
- **Island invisible from above, visible from below.** Winding is clockwise-from-above; swap the second and third index of each triangle.
- **Terraced, stair-stepped slopes.** Inherent to 8-bit heightmaps (256 levels stretched over 40 m = 16 cm steps). Mostly hidden by lighting later; truly fixed by 16-bit sources or Chapter 21's float-native noise.
- **Island floats above the sea / is drowned.** `origin.y` vs sea level mismatch. Decide now: sea level is `y = 0`, terrain heights may map below it (we'll *want* underwater terrain in Chapter 24 — consider `heights = (texel/255 - 0.3) * height_scale` so the blob's black border is seafloor).
- **`stbi.load` returns nil.** Working directory. You solved this for textures in Chapter 6 — same fix, run from the project root or make asset paths absolute relative to the executable.
- **Everything renders but lighting bands crawl when the camera moves.** You passed view-space position into the height bands. Band on `v_world_pos.y`, which must come from `model * a_pos`, untouched by `view`.

## Exercises

1. Add a `stride` parameter to `terrain_build_mesh` that skips vertices (every 2nd, 4th) — instant LOD preview, and a feel for vertex count vs silhouette quality.
2. Move the height-band thresholds into uniforms and tune them live with hot-reload.
3. Use `terrain_height_at` to clamp the camera: `camera.position.y = max(camera.position.y, terrain_height_at(...) + 1.5)`. Walk the island.
4. **Stretch:** Load a 16-bit grayscale PNG via `core:image/png` (stb's 8-bit path quantizes) and compare the slopes up close — then read the [tessellation height map article](https://learnopengl.com/Guest-Articles/2021/Tessellation/Height-map) to see where GPU-side terrain goes in GL 4.x.

## Commit

`git commit -m "ch20: heightmap terrain mesh"`

← [Chapter 19 — Milestone: Sunlit Waters](../part-3-let-there-be-light/ch19-milestone-sunlit-waters.md) · [Chapter 21 — The Noise of Creation](ch21-the-noise-of-creation.md) →
