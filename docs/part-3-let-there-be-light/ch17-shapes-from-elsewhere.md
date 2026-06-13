# Chapter 17 — Shapes from Elsewhere

*Part 3 — Let There Be Light · Estimated time: 3.5h · learnopengl: [Assimp](https://learnopengl.com/Model-Loading/Assimp), [Mesh](https://learnopengl.com/Model-Loading/Mesh), [Model](https://learnopengl.com/Model-Loading/Model) (we replace Assimp with our own loader — see why below)*

**What you'll see when done:** a real buoy and a boat hull — made by an actual artist — floating on your sea, lit by your sun.

## Where we are

Everything in Saltwind so far was born from loops: cubes, spheres, grids. That ceiling is now real — you cannot `for`-loop your way to a boat. Time to load geometry from files. learnopengl reaches for Assimp here, a heavyweight C++ library that imports forty formats. We're going to write our own OBJ parser instead, in about a hundred lines of Odin.

Why that's the right call here: Assimp means a C++ build dependency, a wrapper layer, and a model-import abstraction big enough to obscure what's actually happening. Odin's standard library makes text parsing genuinely pleasant, OBJ is a format you can read in a text editor, and the *thing learnopengl is really teaching* in its Model Loading trilogy — turning indexed file data into your own `Mesh` — is exactly what you'll implement by hand. When OBJ runs out of road (animations, PBR materials, binary efficiency), Odin ships `vendor:cgltf` for glTF — sidebar at the end.

## Concepts

### Anatomy of an OBJ file

OBJ is line-oriented ASCII. Open one in your editor; you'll see four line types that matter:

```
v  -0.5 0.0  0.5      # position (x y z)
vt  0.0 1.0           # texture coordinate (u v)
vn  0.0 1.0  0.0      # normal
f  1/1/1 2/2/1 3/3/1  # face: vertex refs as pos/uv/normal
```

Three gotchas define the whole parsing problem:

1. **Indices are 1-based.** `f 1/1/1` refers to the *first* `v`, `vt`, `vn`. Subtract one. (Negative indices mean "count from the end" — rare; reject or handle, but know they exist.)
2. **Faces can be polygons.** Artists export quads constantly. A face with n vertices must become n−2 triangles by **fan triangulation**: vertices `(0, i−1, i)` for `i in 2..<n`. Valid for convex polygons, which is what real exports contain.
3. **OBJ indexes positions, uvs, and normals *separately*; OpenGL has one index per vertex.** This is the heart of the exercise. A corner of a cube might be `12/3/1` on one face and `12/7/2` on another — same position, different uv/normal. Each *distinct triple* must become one GL vertex.

### Deduplication with a map

The naive fix — emit a fresh vertex per face corner — works but triples your vertex count and throws away the post-transform vertex cache. The right structure is a hash map from index-triple to the GL index you already assigned:

```
for each corner "p/t/n" in each face:
    key = (p, t, n)
    if key in seen:      use seen[key]
    else:                append Vertex{positions[p], uvs[t], normals[n]}
                         seen[key] = new index; use it
```

This is a wonderfully Odin-shaped problem: a struct key, a `map`, two `[dynamic]` arrays, and you're done. On Kenney's models expect dedup to cut vertices by 50–70%.

## Odin notes

Everything you need is in `core:os`, `core:strings`, `core:strconv`:

- `os.read_entire_file(path) -> ([]byte, bool)` — slurp the file; `defer delete(data)`.
- `strings.split(s, "\n")` then `strings.trim_space(line)` per line — **trim_space also eats Windows `\r`**, which will otherwise silently break your last-token parses. `strings.fields(line)` splits on any whitespace run, which is exactly OBJ's token rule (and tolerates double spaces, tabs).
- `strconv.parse_f32(tok)` and `strconv.parse_int(tok)` return `(value, ok)` — propagate failures; a loader that silently mis-parses is a multi-hour debugging session deferred.
- A plain struct works directly as a map key — Odin hashes it by value:

  ```odin
  Vertex_Key :: struct { p, t, n: int }
  seen: map[Vertex_Key]u32
  ```

- Remember `defer delete(seen)`, `delete(positions)` etc., or take an allocator parameter and pass `context.temp_allocator` since everything is scratch except the final `Mesh`.

## Build

1. **Create `src/model_obj.odin`** with the signature `model_load_obj :: proc(path: string) -> (mesh: Mesh, ok: bool)`. Scaffolding: read the file, split lines, dispatch on the first field:

   ```odin
   data, read_ok := os.read_entire_file(path)
   if !read_ok do return {}, false
   defer delete(data)

   positions: [dynamic]glsl.vec3;  defer delete(positions)
   uvs:       [dynamic]glsl.vec2;  defer delete(uvs)
   normals:   [dynamic]glsl.vec3;  defer delete(normals)
   vertices:  [dynamic]Vertex;     defer delete(vertices)
   indices:   [dynamic]u32;        defer delete(indices)
   seen:      map[Vertex_Key]u32;  defer delete(seen)

   lines := strings.split(string(data), "\n"); defer delete(lines)
   for raw_line in lines {
       line   := strings.trim_space(raw_line)
       fields := strings.fields(line); defer delete(fields)
       if len(fields) == 0 || strings.has_prefix(line, "#") do continue
       switch fields[0] {
       case "v":  /* parse 3 floats -> append(&positions, ...) */
       case "vt": /* parse 2 floats -> append(&uvs, ...)       */
       case "vn": /* parse 3 floats -> append(&normals, ...)   */
       case "f":  /* below */
       }
   }
   ```

   The float parsing is three calls to `strconv.parse_f32` — write a tiny `parse_vec3(fields []string)` helper; you'll thank yourself.

2. **Parse face corners.** Each face token is `p`, `p/t`, `p//n`, or `p/t/n`. Split on `/` and treat empty/missing parts as "no index" (use 0 and map it to a default uv/normal slot):

   ```odin
   corner_to_index :: proc(tok: string, /* &arrays, &seen, &vertices */) -> u32 {
       parts := strings.split(tok, "/"); defer delete(parts)
       key: Vertex_Key
       key.p, _ = strconv.parse_int(parts[0]);                 key.p -= 1
       if len(parts) > 1 && parts[1] != "" { key.t, _ = strconv.parse_int(parts[1]); key.t -= 1 } else { key.t = -1 }
       if len(parts) > 2 && parts[2] != "" { key.n, _ = strconv.parse_int(parts[2]); key.n -= 1 } else { key.n = -1 }

       if idx, hit := seen[key]; hit do return idx
       v := Vertex{ position = positions[key.p] }
       if key.t >= 0 do v.uv     = uvs[key.t]
       if key.n >= 0 do v.normal = normals[key.n]
       append(&vertices, v)
       idx := u32(len(vertices) - 1)
       seen[key] = idx
       return idx
   }
   ```

3. **Triangulate the fan.** For a face line with corner tokens `fields[1:]`:

   ```odin
   first := corner_to_index(fields[1], ...)
   prev  := corner_to_index(fields[2], ...)
   for tok in fields[3:] {
       curr := corner_to_index(tok, ...)
       append(&indices, first, prev, curr)
       prev = curr
   }
   ```

   Triangles fall out automatically; quads become two tris; a hexagonal lantern lens becomes four.

4. **Upload.** You already have this from Chapter 11 — finish with `return mesh_create(vertices[:], indices[:]), true`. Print a one-line summary: `fmt.printf("%s: %d corners -> %d unique verts, %d tris\n", ...)`.

5. **Get models.** Free, CC0/CC-licensed low-poly fits Saltwind's look:

   - [Kenney's Pirate Kit](https://kenney.nl/assets/pirate-kit) — buoys, hulls, masts, crates; OBJ included. The course assumes these.
   - [Quaternius](https://quaternius.com) — ships and props, CC0.
   - [Sketchfab](https://sketchfab.com) filtered to CC0 — more variety; re-export as OBJ from Blender (check "Triangulate" and "Write Normals" on export and steps 2–3 get easier).

   Drop `buoy.obj` and `boat_hull.obj` (pick any hull piece) into `assets/models/`.

6. **Place them.** Load once at startup; draw with `lit` shader and a sensible material. Kenney models are about 1 unit per tile — scale to taste with `glsl.mat4Scale`. Put the buoy where a crate used to be and move the Chapter 15 lantern light to sit on top of it. The hull floats near the origin, waiting for Chapter 18.

## Checkpoint

A recognizably nautical scene: a striped buoy bobs-in-spirit (still static) on the water with the lantern on top, and a boat hull sits on the surface nearby — both shaded by your sun with correct normals.

- Loader summary prints plausible numbers (e.g., a few hundred unique verts, dedup well below corner count).
- Normal-visualization debug key (Chapter 14 exercise) shows smooth color over curved hull surfaces, hard changes at sharp edges.
- No GL errors; no stray triangles spiking to the origin (the classic off-by-one symptom).

## Pitfalls

- **Spikes radiating to one corner / scrambled mesh.** You forgot the `−1` on indices, or applied it twice. Index 0 in OBJ-land doesn't exist.
- **Half the faces missing, hull see-through from outside.** Winding/culling: if you enabled `gl.CULL_FACE`, an exporter writing clockwise faces will vanish. Check the export settings, or temporarily disable culling to confirm the diagnosis.
- **`parse_f32` fails only on some lines.** Windows line endings — the last token on each line carries a `\r`. `strings.trim_space` the line *before* `strings.fields`.
- **Model is black.** The file has no `vn` lines and your default normal is zero. Either re-export with normals or compute flat normals per triangle as a fallback (cross of two edges).
- **Quads render as two overlapping garbage triangles.** Fan order bug: the fan must pivot on the *first* corner, triangles `(0, i−1, i)` — not `(i−2, i−1, i)` chained wrong.
- **Texture looks vertically flipped.** OBJ's v coordinate convention vs stb_image's row order; you handled this for plain textures in Chapter 6 — apply the same flip policy here (`1 - v` at parse, or flip-on-load).

## Sidebar: `vendor:cgltf`

OBJ has no animation, no scene hierarchy, no PBR materials, and floats-as-text parsing won't scale to big meshes. The modern interchange format is **glTF**, and Odin vendors a binding to the excellent single-header `cgltf`. The shape of the work is identical to today's — walk buffers, build `Vertex` arrays, call `mesh_create` — just reading binary accessors instead of text lines. When Chapter 42's PBR materials make you want roughness/metallic data per model, glTF is the upgrade path; nothing you wrote today is wasted, because your `Mesh` is the common destination.

## Exercises

1. Add timing around `model_load_obj` (`core:time`) and report load milliseconds alongside vertex stats.
2. Parse `usemtl` + a companion `.mtl` file just enough to pull `Kd` (diffuse color) per object, and tint your `Material` from it.
3. Write `mesh_compute_flat_normals(vertices, indices)` as the missing-`vn` fallback from Pitfalls.
4. **Stretch:** Load the same model via `vendor:cgltf` (export glTF from Blender) into the same `Mesh` struct, and assert the triangle counts match your OBJ path.

## Commit

`git commit -m "ch17: hand-rolled obj loader, buoy and hull models"`

← [Chapter 16 — Honest Colors](ch16-honest-colors.md) · [Chapter 18 — The Family Tree](ch18-the-family-tree.md) →
