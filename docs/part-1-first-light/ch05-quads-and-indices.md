# Chapter 5 — Quads & Indices

*Part 1 — First Light · Estimated time: 2.5h · learnopengl: [Hello Triangle (EBO section)](https://learnopengl.com/Getting-started/Hello-Triangle)*

**What you'll see when done:** the lower half of the window filled with a sea-colored quad, deep at your feet and pale at the horizon line — Saltwind's first hint of ocean.

## Where we are

One triangle is a proof of life; everything real is built from many, and triangles share vertices. A quad is two triangles sharing an edge — drawn naively that's 6 vertices, 2 of them duplicates. At quad scale, who cares; at the scale of Chapter 12's sea grid (a quarter-million triangles), duplication would double memory and wreck the GPU's vertex cache. The cure is **indexed drawing**, and while we're restructuring vertex data anyway, we'll formalize **interleaved attributes** with proper `size_of`/`offset_of` bookkeeping. The quad we build is not a demo: it's the sea's ancestor, and the chapter ends with it covering the horizon.

## Concepts

### The Element Buffer Object (EBO)

Store each unique vertex **once**, then describe triangles as lists of *indices* into that vertex array:

```
 3───────2        vertices: 0, 1, 2, 3   (four, not six)
 │     ⟋ │        indices:  0, 1, 2,     ← triangle A
 │   ⟋   │                  2, 3, 0      ← triangle B
 │ ⟋     │
 0───────1        shared verts 0 and 2 are stored once, referenced twice
```

The indices live in their own GPU buffer bound to `gl.ELEMENT_ARRAY_BUFFER`, and the draw call changes from `DrawArrays` to:

```odin
gl.DrawElements(gl.TRIANGLES, 6, gl.UNSIGNED_INT, nil)
```

— "assemble triangles by reading 6 indices". One subtle, important VAO fact: **the VAO records the EBO binding**. Bind the EBO while your VAO is bound and it's captured; binding the VAO later restores it. (This also means: never unbind `ELEMENT_ARRAY_BUFFER` while a VAO is bound — you'd record the *unbinding*.)

A vertex-cache bonus you get for free: when consecutive triangles reuse an index the GPU skips re-running the vertex shader for it. Index buffers aren't just smaller — they're faster.

### Interleaved attributes, with types doing the math

Chapter 3's exercise hand-counted stride bytes. From now on, a vertex is a struct, and the compiler counts:

```
memory, one vertex after another (interleaved):
┌────────────┬────────────┬────────────┬────────────┬───
│ pos₀ color₀│ pos₁ color₁│ pos₂ color₂│ pos₃ color₃│ …
└────────────┴────────────┴────────────┴────────────┴───
  stride = size_of(Sea_Vertex)
  color's offset within each cell = offset_of(Sea_Vertex, color)
```

Interleaved (all attributes of a vertex adjacent) beats separate arrays for our use because the vertex shader touches all attributes of a vertex together — one cache line, not three.

### Wireframe: your first debugging lens

`gl.PolygonMode(gl.FRONT_AND_BACK, gl.LINE)` tells the rasterizer to draw triangle *edges* instead of filling. It's global state (set it back with `gl.FILL`) and it answers a whole category of questions instantly: Is my geometry there at all? Are the triangles where I think? Is the diagonal going the way I expect? When the sea grid misbehaves in Chapter 12 — and it will — wireframe is the first thing you'll reach for.

## Odin notes

- `size_of(Sea_Vertex)` and `offset_of(Sea_Vertex, color)` are compile-time and exactly fit `VertexAttribPointer`'s stride/offset parameters (the binding takes the offset as `uintptr`, which `offset_of` returns). Reorder the struct fields and the GL layout updates itself — this is the whole trick.
- `glsl.vec3` is `[3]f32` underneath — tightly packed, no hidden padding, safe to upload raw. Import `core:math/linalg/glsl` now; Chapter 7 makes heavy use of it.
- Odin's ternary reads `value_if if cond else value_else` — used below for the wireframe toggle.

## Build

1. **Define the vertex struct and the quad.** In `main.odin` (it moves to `mesh.odin` in Chapter 11):

   ```odin
   import "core:math/linalg/glsl"

   Sea_Vertex :: struct {
   	position: glsl.vec3,
   	color:    glsl.vec3,
   }
   ```

   The quad fills the window's lower half — y from −1 up to 0 in NDC, the top edge becoming a horizon line across the middle of the screen. Deep color below, pale haze at the horizon:

   ```odin
   	vertices := [?]Sea_Vertex{
   		{{-1.0, -1.0, 0.0}, {0.02, 0.08, 0.15}}, // 0 near-left, deep
   		{{ 1.0, -1.0, 0.0}, {0.02, 0.08, 0.15}}, // 1 near-right, deep
   		{{ 1.0,  0.0, 0.0}, {0.45, 0.58, 0.62}}, // 2 horizon-right, haze
   		{{-1.0,  0.0, 0.0}, {0.45, 0.58, 0.62}}, // 3 horizon-left, haze
   	}
   	indices := [?]u32{
   		0, 1, 2,
   		2, 3, 0,
   	}
   ```

2. **Upload with an EBO.** Replace the Chapter 3 buffer setup:

   ```odin
   	vao, vbo, ebo: u32
   	gl.GenVertexArrays(1, &vao)
   	gl.GenBuffers(1, &vbo)
   	gl.GenBuffers(1, &ebo)

   	gl.BindVertexArray(vao)
   	gl.BindBuffer(gl.ARRAY_BUFFER, vbo)
   	gl.BufferData(gl.ARRAY_BUFFER, size_of(vertices), &vertices, gl.STATIC_DRAW)
   	gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, ebo) // recorded into the VAO
   	gl.BufferData(gl.ELEMENT_ARRAY_BUFFER, size_of(indices), &indices, gl.STATIC_DRAW)

   	gl.VertexAttribPointer(0, 3, gl.FLOAT, false, size_of(Sea_Vertex), offset_of(Sea_Vertex, position))
   	gl.EnableVertexAttribArray(0)
   	gl.VertexAttribPointer(1, 3, gl.FLOAT, false, size_of(Sea_Vertex), offset_of(Sea_Vertex, color))
   	gl.EnableVertexAttribArray(1)
   	gl.BindVertexArray(0)
   ```

3. **Teach the shaders about color.** `basic.vert` gains the attribute and passes it through:

   ```glsl
   layout (location = 0) in vec3 a_position;
   layout (location = 1) in vec3 a_color;

   out vec3 v_color;

   void main() {
   	v_color = a_color;
   	gl_Position = vec4(a_position, 1.0);
   }
   ```

   `basic.frag` blends the interpolated color with last chapter's pulse — dialed way down, a shimmer rather than a strobe:

   ```glsl
   in vec3 v_color;
   out vec4 frag_color;
   uniform float u_time;

   void main() {
   	float shimmer = 0.04 * sin(u_time * 2.0);
   	frag_color = vec4(v_color + shimmer, 1.0);
   }
   ```

   (If you built hot-reload, edit these with Saltwind *running* and watch the quad change live. This is the workflow now.)

4. **Switch the draw call.**

   ```odin
   		gl.UseProgram(shader.id)
   		shader_set_f32(shader, "u_time", f32(glfw.GetTime()))
   		gl.BindVertexArray(vao)
   		gl.DrawElements(gl.TRIANGLES, 6, gl.UNSIGNED_INT, nil)
   ```

5. **Wireframe on a held key.** In the loop, before drawing:

   ```odin
   		wireframe := glfw.GetKey(window, glfw.KEY_TAB) == glfw.PRESS
   		gl.PolygonMode(gl.FRONT_AND_BACK, gl.LINE if wireframe else gl.FILL)
   ```

   Hold TAB: two triangles and their shared diagonal, plainly visible. This stays in the codebase forever (Chapter 10 promotes it to a proper toggle).

## Checkpoint

Lower half of the window: a sea gradient from deep blue-black at the bottom edge to pale haze along the dead-center horizon line. Upper half: the Chapter 2 clear color, doing duty as sky. Squint and it's already a seascape.

- Hold TAB: exactly 2 wire triangles, diagonal running 0→2 (bottom-left to horizon-right).
- The horizon sits at the exact vertical center at any window size.
- Reorder the `Sea_Vertex` fields (color first), rerun: identical output — `offset_of` absorbed the change. Put it back.
- Change one index (e.g. the second triangle to `2, 3, 1`): geometry visibly breaks. Indices are real. Restore.

## Pitfalls

- **Nothing draws after the EBO switch?** `DrawElements` with no EBO bound in the VAO — you bound `ELEMENT_ARRAY_BUFFER` *before* `BindVertexArray`, so the binding wasn't recorded. Order: VAO first, then EBO.
- **Garbage triangles spraying from one corner?** Index type mismatch: indices declared as something other than `u32` while telling GL `gl.UNSIGNED_INT`, or `size_of(indices)` computed from the wrong array.
- **Everything draws as wireframe permanently?** `PolygonMode` is sticky state — you set `gl.LINE` and never set `gl.FILL` back on the no-key path.
- **Quad colors are flat, not a gradient?** Attribute 1 not enabled (`EnableVertexAttribArray(1)` missing — attribute reads constant), or `v_color`/`a_color` plumbing skipped in one of the shaders (the link error message names the mismatched varying — read it).
- **Stride looks right but rendering is skewed?** You passed `size_of(Sea_Vertex)` for stride but hand-typed an offset instead of `offset_of`. Never hand-type either again.

## Exercises

1. Add a third triangle above the horizon — a distant sail: three more vertices (pale gray), three more indices, count in `DrawElements` becomes 9. Cute, temporary, instructive.
2. Compute the savings: for an N×N grid of quads, how many vertices with and without indexing? (Answer shape: 6N² versus (N+1)². For N=255, that's ~390k vs ~65k.) This is Chapter 12's entire justification, done on a napkin.
3. Replace the index array with `u16` indices and `gl.UNSIGNED_SHORT` in the draw call. Works fine at 4 vertices — and know that it stops working past 65,535 vertices, which the sea grid will exceed. Revert to `u32`.
4. **Stretch:** Drive the horizon color from a uniform (`u_horizon: vec3` — your `shader_set_vec3` finally gets used) instead of baking it per-vertex: pass the vertex's y up as a varying and `mix` in the fragment shader based on it. You've just invented the distance-fade pattern Chapter 12 uses for real.

## Commit

```
git commit -m "ch05: indexed quad — EBO, interleaved attributes, horizon"
```

Prev: [Chapter 4 — The Shader Forge](ch04-the-shader-forge.md) · Next: [Chapter 6 — Pixels from Disk](ch06-pixels-from-disk.md)
