# Chapter 3 — First Triangle

*Part 1 — First Light · Estimated time: 4h · learnopengl: [Hello Triangle](https://learnopengl.com/Getting-started/Hello-Triangle)*

**What you'll see when done:** one sea-green triangle on the deep blue — the single most disproportionately satisfying image in computer graphics.

## Where we are

The heartbeat from Chapter 2 clears and swaps, but the GPU has never received geometry or a program from us. This chapter is the longest conceptual climb in Part 1, because drawing *one triangle* in modern GL requires touching the entire pipeline honestly: vertex data on the GPU, a vertex shader, a fragment shader, a compiled-and-linked program, and a vertex array object describing how the bytes map to shader inputs. Climb it once, properly, and everything after is variations.

## Concepts

### The pipeline, properly this time

Chapter 1 sketched it; now we walk it. You issue a draw call like "draw 3 vertices as a triangle". The GPU then:

```
1. VERTEX SPECIFICATION   your buffer of raw floats is sliced into per-vertex
                          attributes (we say: every 3 floats = one position)
        │
2. VERTEX SHADER          YOUR program runs once per vertex. Its one duty:
                          output the vertex position in clip space, via the
                          built-in gl_Position. (Later: also pass along uvs,
                          normals, colors for downstream stages.)
        │
3. PRIMITIVE ASSEMBLY     vertices are grouped into primitives — for
                          gl.TRIANGLES, every 3 verts become one triangle.
        │
4. RASTERIZATION          each triangle is tested against the screen grid:
                          which pixels does it cover? Each covered pixel
                          becomes a FRAGMENT — a pixel candidate carrying
                          interpolated values from the 3 vertices.
        │
5. FRAGMENT SHADER        YOUR program runs once per fragment and answers
                          one question: what color is this fragment?
        │
6. TESTS & BLENDING       depth test (ch8), stencil test (ch38), blending
                          (ch34) — fragments can be discarded or mixed here.
        │
7. FRAMEBUFFER            survivors are written into the back buffer,
                          which SwapBuffers will reveal.
```

Two stages are programmable and mandatory in core profile: **vertex** and **fragment**. The fixed stages between them do enormous work for free — most magically, rasterization *interpolates*: any value the vertex shader outputs is smoothly blended across the triangle's surface before the fragment shader reads it. That one feature is how a 3-vertex triangle can carry a gradient, a texture, or smooth lighting.

### NDC: the GPU's native coordinates

The vertex shader must place vertices in **clip space**, which (for now, with w=1) you can read as **Normalized Device Coordinates**: a cube from −1 to +1 on every axis. (−1,−1) is the bottom-left of the viewport, (+1,+1) top-right, regardless of window size. Anything outside is clipped away.

```
        (+1,+1)
   ┌───────┐
   │  NDC  │      x: left −1 … +1 right
   │   ·(0,0)     y: bottom −1 … +1 top   ← y is UP, unlike most UI systems
   │       │      z: −1 … +1 (depth; ignored until ch8)
   └───────┘
(−1,−1)
```

Matrices (chapters 7–8) exist to transform sensible world coordinates *into* this cube. Today we skip the middleman and type NDC directly.

### VBO: bytes on the GPU

A **Vertex Buffer Object** is a chunk of GPU memory. You create a handle (`gl.GenBuffers`), bind it to a target (`gl.ARRAY_BUFFER` — the state machine again: "the buffer subsequent vertex-data calls refer to"), and upload with `gl.BufferData`. The upload's last parameter is a *usage hint*: `gl.STATIC_DRAW` means "written once, drawn many times" — true for nearly everything in Saltwind.

After upload, the GPU sees only bytes. It does not know that every 12 bytes is a `vec3` position. That knowledge lives in…

### VAO: the layout recorder

A **Vertex Array Object** stores the *description* of vertex input: which buffer, which attributes, what type, what stride, what offset. While a VAO is bound, calls to `gl.VertexAttribPointer` and `gl.EnableVertexAttribArray` are recorded into it. At draw time you bind the VAO and the whole configuration snaps back in one call. Core profile *requires* a bound VAO to draw — forget it and you get nothing (the #1 black-screen cause in this chapter).

The mapping call is dense; label its parameters now and you'll never fear it again:

```
gl.VertexAttribPointer(0,        3,         gl.FLOAT, false,       12,      0)
                       │         │          │         │            │        │
                       location  components type      normalize?   stride   offset
                       in shader per vertex                        bytes    bytes
                       (layout   (vec3 = 3)           (ints→0..1   between  to 1st
                       qualifier)                     conversion)  vertices value
```

### GLSL and the compile-link dance

Shaders are written in **GLSL** (C-like, built-in vector types) and compiled *by the driver at runtime* from source you hand it. A vertex+fragment pair is linked into a **program**, the unit you actually bind for drawing. The dance: `CreateShader → ShaderSource → CompileShader` (×2), then `CreateProgram → AttachShader (×2) → LinkProgram`, checking for errors after every compile and the link. It's verbose — and this is the *only* chapter where you'll write it by hand. Chapter 4 wraps it forever. We do it manually once because when shaders fail at 11pm in Chapter 29, you need to know what the wrapper is actually doing.

Vertex shader for today:

```glsl
#version 330 core
layout (location = 0) in vec3 a_position;

void main() {
	gl_Position = vec4(a_position, 1.0);
}
```

`layout (location = 0)` pins this input to attribute slot 0 — the same `0` you pass to `VertexAttribPointer`. The position is already NDC, so we pass it through, padding to `vec4` with w=1 (w matters from Chapter 8).

Fragment shader:

```glsl
#version 330 core
out vec4 frag_color;

void main() {
	frag_color = vec4(0.13, 0.45, 0.40, 1.0); // sea green
}
```

The single `out vec4` is the fragment's color. Every fragment of our triangle gets the same constant — for now.

## Odin notes

- GLSL source goes to the driver as a NUL-terminated C string. Odin's raw string literals (backticks) handle multi-line sources cleanly, and you can declare them as `cstring` constants directly. `gl.ShaderSource` wants a *pointer to* a `cstring` (it accepts arrays of sources), so copy the constant into a local and pass its address.
- Handles in GL are plain `u32`s. Odin's `gl.GenBuffers(1, &vbo)` mirrors C exactly — the first argument is a count, so you can generate arrays of handles at once.
- The error-log buffer trick: stack-allocate `log: [512]u8`, pass `raw_data(log[:])`, print with `string(log[:])`. No allocation, no cleanup.

## Build

1. **Shader sources.** Near the top of `main.odin`, the two GLSL programs as `cstring` constants (Chapter 4 moves them to files — tolerate the string literals for one chapter):

   ```odin
   VERTEX_SOURCE: cstring = `#version 330 core
   layout (location = 0) in vec3 a_position;
   void main() {
   	gl_Position = vec4(a_position, 1.0);
   }`

   FRAGMENT_SOURCE: cstring = `#version 330 core
   out vec4 frag_color;
   void main() {
   	frag_color = vec4(0.13, 0.45, 0.40, 1.0);
   }`
   ```

2. **A compile helper with real error reporting.** Driver compile errors are silent unless you ask. Always ask:

   ```odin
   compile_shader :: proc(source: cstring, kind: u32) -> (id: u32, ok: bool) {
   	id = gl.CreateShader(kind)
   	source := source
   	gl.ShaderSource(id, 1, &source, nil) // nil length → NUL-terminated
   	gl.CompileShader(id)

   	success: i32
   	gl.GetShaderiv(id, gl.COMPILE_STATUS, &success)
   	if success == 0 {
   		log: [512]u8
   		gl.GetShaderInfoLog(id, 512, nil, raw_data(log[:]))
   		fmt.eprintln("shader compile error:\n", string(log[:]))
   		return 0, false
   	}
   	return id, true
   }
   ```

3. **Link into a program.** After `gl.load_up_to` in `main`:

   ```odin
   	vs, vs_ok := compile_shader(VERTEX_SOURCE, gl.VERTEX_SHADER)
   	fs, fs_ok := compile_shader(FRAGMENT_SOURCE, gl.FRAGMENT_SHADER)
   	if !vs_ok || !fs_ok do return

   	program := gl.CreateProgram()
   	gl.AttachShader(program, vs)
   	gl.AttachShader(program, fs)
   	gl.LinkProgram(program)

   	link_ok: i32
   	gl.GetProgramiv(program, gl.LINK_STATUS, &link_ok)
   	if link_ok == 0 {
   		log: [512]u8
   		gl.GetProgramInfoLog(program, 512, nil, raw_data(log[:]))
   		fmt.eprintln("program link error:\n", string(log[:]))
   		return
   	}
   	gl.DeleteShader(vs) // safe after linking — the program keeps its own copy
   	gl.DeleteShader(fs)
   ```

   Compiling and linking are separate failure points with separate logs. A shader can compile fine and the link still fail (e.g. vertex outputs not matching fragment inputs — you'll meet that in Chapter 14).

4. **Vertex data, VBO, VAO.** Three vertices in NDC, counter-clockwise (the convention that will matter when we enable face culling much later — build the habit now):

   ```odin
   	vertices := [?]f32{
   		-0.6, -0.5, 0.0, // left
   		 0.6, -0.5, 0.0, // right
   		 0.0,  0.6, 0.0, // top
   	}

   	vao, vbo: u32
   	gl.GenVertexArrays(1, &vao)
   	gl.GenBuffers(1, &vbo)

   	gl.BindVertexArray(vao)                                // start recording layout
   	gl.BindBuffer(gl.ARRAY_BUFFER, vbo)
   	gl.BufferData(gl.ARRAY_BUFFER, size_of(vertices), &vertices, gl.STATIC_DRAW)

   	gl.VertexAttribPointer(0, 3, gl.FLOAT, false, 3 * size_of(f32), 0)
   	gl.EnableVertexAttribArray(0)

   	gl.BindVertexArray(0)                                  // stop recording (hygiene)
   ```

   Order matters: the VAO must be bound *before* `VertexAttribPointer`, because that call records into the currently bound VAO (and captures which `ARRAY_BUFFER` was bound at that moment).

5. **Draw.** In the render loop, between `gl.Clear` and `SwapBuffers`:

   ```odin
   		gl.UseProgram(program)
   		gl.BindVertexArray(vao)
   		gl.DrawArrays(gl.TRIANGLES, 0, 3)
   ```

   `DrawArrays(mode, first, count)`: take 3 vertices starting at 0, assemble as triangles. This single call kicks off the entire pipeline diagram above.

6. Run. Sea-green triangle on deep blue.

## Checkpoint

One solid sea-green triangle, centered, on the Chapter 2 blue.

- Resize the window: the triangle stretches with it. NDC is relative to the viewport, so a wide window means a wide triangle — *this is correct for now* and is exactly the problem the projection matrix solves in Chapter 8.
- Change the fragment color constant, rerun: color changes. You've edited your first shader.
- Move a vertex's y to `0.9`, rerun: geometry changes. Put it back.
- No errors in the console — your compile/link checks are silent because they passed.

## Pitfalls

- **Black (well, blue) screen, no errors?** In order of likelihood: ① no `gl.BindVertexArray(vao)` before the draw; ② `VertexAttribPointer` called while the wrong/no VAO bound; ③ `gl.EnableVertexAttribArray(0)` missing — the attribute reads as constant zero, all three verts collapse to one point; ④ vertices typed with z outside ±1.
- **Compile error log mentions `version`?** The `#version 330 core` line must be the *first* line of the source — watch for a stray leading newline in your raw string literal.
- **It compiles in your head but the log says `'a_position' : undeclared identifier`?** You edited the vertex shader but the error is from the fragment shader (or vice versa). Tag your error prints with which stage failed — improving that is Exercise 0 in spirit and Chapter 4 in practice.
- **Triangle is white, not sea-green?** Your fragment shader failed to compile and some drivers fall back to white; your error checking would have told you — make sure you actually abort on `!fs_ok`.
- **Crash on `gl.BufferData`?** Passing `&vertices` is correct for a fixed array; if you switched to a slice or dynamic array, you need `raw_data(vertices)` and `len(vertices) * size_of(f32)` instead. (We'll standardize on slices in Chapter 11.)

## Exercises

1. Make the triangle enormous — vertices at (−1,−1), (1,−1), (0,1) — then beyond NDC, e.g. y = 3.0. Observe clipping doing its job: the triangle is sliced cleanly at the viewport edge.
2. Add a second triangle by extending the array to 6 vertices and drawing `gl.DrawArrays(gl.TRIANGLES, 0, 6)`. Notice you're already duplicating shared-edge vertices — feel the pain that Chapter 5's index buffer cures.
3. Per-vertex color via interpolation: add a second attribute (location 1, 3 floats, interleaved after position — stride becomes `6 * size_of(f32)`, color's offset `3 * size_of(f32)`), declare `layout (location = 1) in vec3 a_color;` plus `out vec3 v_color;` in the vertex shader, `in vec3 v_color;` in the fragment shader, and output it. A smooth gradient appears — rasterizer interpolation made visible. Keep this code mentally close; Chapter 5 builds on the same interleaving.
4. **Stretch:** Break things on purpose and read the logs: delete a semicolon in the fragment shader; change `out vec4` to `out vec3`; rename `v_color` in only one shader (a *link*-stage error). Knowing what each failure looks like is worth an hour of future debugging.

## Commit

```
git commit -m "ch03: first triangle — VBO, VAO, manual shader pipeline"
```

Prev: [Chapter 2 — Heartbeat](ch02-heartbeat.md) · Next: [Chapter 4 — The Shader Forge](ch04-the-shader-forge.md)
