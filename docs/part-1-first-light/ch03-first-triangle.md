# Chapter 3 — First Triangle

*Part 1 — First Light · Estimated time: 4h · learnopengl: [Hello Triangle](https://learnopengl.com/Getting-started/Hello-Triangle)*

**What you'll see when done:** one sea-green triangle on the deep blue — the single most disproportionately satisfying image in computer graphics.

## Where we are

Chapter 2 gave us a living window: GL functions are loaded, the viewport is set, the loop clears the back buffer, and `SwapBuffers` reveals each frame. But the GPU still has no geometry from us and no program from us.

This chapter is the first time we feed the GPU both:

- **data**: three vertex positions,
- **code**: a vertex shader and a fragment shader,
- **a recipe**: how those raw vertex bytes become shader inputs,
- **a command**: draw three vertices as one triangle.

Every real-time graphics API has to solve this same problem. Metal, Direct3D, Vulkan, WebGPU, and OpenGL all need vertex data, shader code, a vertex layout, render state, and a draw command. The names differ. The underlying job is the same: teach the GPU how to turn three numbers-per-corner into colored pixels.

OpenGL's names are especially old and stateful, so we will keep translating them back into the general graphics idea.

## The goal

We want this CPU-side Odin array:

```odin
vertices := [?]f32{
    -0.6, -0.5, 0.0, // left
     0.6, -0.5, 0.0, // right
     0.0,  0.6, 0.0, // top
}
```

to become this GPU-side story:

```text
CPU memory                         GPU resources/state                  screen

3 positions  ──upload bytes──►     vertex buffer
                                   vertex layout:
                                     input 0 reads vec3 positions
                                   shader program / pipeline:
                                     vertex shader positions verts
                                     fragment shader colors pixels
                                          │
                                          ▼
                                   draw 3 vertices as 1 triangle
                                          │
                                          ▼
                                   sea-green triangle
```

In OpenGL terms, those general pieces map like this:

| General graphics idea | OpenGL name in this chapter |
|---|---|
| GPU vertex storage | VBO, a `gl.ARRAY_BUFFER` |
| Vertex layout / input description | VAO plus `gl.VertexAttribPointer` and `gl.EnableVertexAttribArray` |
| Shader program / pipeline program | linked `program` from a vertex shader and fragment shader |
| Bind the resources needed for a draw | `gl.UseProgram(program)` and `gl.BindVertexArray(vao)` |
| Draw command | `gl.DrawArrays(gl.TRIANGLES, 0, 3)` |

For one triangle, the idea is:

1. The GPU owns a copy of the vertex bytes.
2. The GPU has a compiled vertex shader and fragment shader linked into a program.
3. The vertex input layout says "shader input 0 reads three floats per vertex from those bytes."
4. Each frame makes the shader program and vertex layout active.
5. A draw command asks the GPU to process three vertices as one triangle.

Everything in the chapter serves one of those five truths.

## Concepts

### The pipeline in plain English

When you ask the GPU to render something, you usually issue a draw command. In this chapter, the OpenGL draw command is `gl.DrawArrays(gl.TRIANGLES, 0, 3)`: process three vertices as one triangle. Conceptually, the GPU then does this:

```text
1. VERTEX FETCH          Read per-vertex attributes from buffers.
                         For us: attr 0 = vec3 position.

2. VERTEX SHADER         Run our vertex shader once per vertex.
                         Its required output is gl_Position.

3. PRIMITIVE ASSEMBLY    Group vertices into primitives.
                         Here: every 3 vertices form 1 triangle.

4. RASTERIZATION         Work out which pixels the triangle covers.
                         Each covered pixel becomes a fragment.

5. FRAGMENT SHADER       Run our fragment shader once per fragment.
                         Its output is the fragment color.

6. TESTS AND BLENDING    Later chapters: depth, stencil, alpha blending.

7. FRAMEBUFFER           Write surviving fragments into the back buffer.
```

Two stages are programmable and mandatory for this basic rasterization pipeline: the **vertex shader** and the **fragment shader**. The stages between them are fixed-function, but not simple. Rasterization, especially, does a small miracle: values output by the vertex shader can be interpolated smoothly across the triangle before the fragment shader reads them. Exercise 3 makes that visible with per-vertex color.

### Coordinates for today: NDC

The vertex shader must output positions in **clip space**. For today, with `w = 1`, you can think of this as **Normalized Device Coordinates**: x, y, and z from `-1` to `+1`.

```text
        (+1,+1)
   ┌───────┐
   │  NDC  │      x: left -1 … +1 right
   │   ·(0,0)     y: bottom -1 … +1 top
   │       │      z: -1 … +1, ignored until Chapter 8
   └───────┘
(-1,-1)
```

That is why our vertex positions are small numbers like `-0.6` and `0.6`. We are placing the triangle directly in the GPU's final coordinate cube. Later, matrices will let us work in sensible world coordinates and transform them into this cube.

### Data and recipe: VBO vs VAO

A **Vertex Buffer Object** answers one question:

```text
Where are the vertex bytes?
```

After upload, the GPU sees our positions as raw storage:

```text
VBO #7

byte offset
0      4      8      12     16     20     24     28     32
│      │      │      │      │      │      │      │      │
[-0.6][-0.5][ 0.0][ 0.6][-0.5][ 0.0][ 0.0][ 0.6][ 0.0]
   vertex 0 position      vertex 1 position      vertex 2 position
```

But a VBO is only bytes. It does not know those bytes are positions. It does not know that every 12 bytes is one vertex. It does not know the shader wants a `vec3`.

A **Vertex Array Object** answers the next question:

```text
How should vertex shader inputs be fetched from those bytes?
```

After our setup, the VAO records a table like this:

```text
VAO #3
└─ attribute location 0
   ├─ enabled:    yes
   ├─ components: 3
   ├─ type:       FLOAT
   ├─ normalized: no
   ├─ stride:     12 bytes
   ├─ offset:     0 bytes
   └─ source:     VBO #7
```

The shader has a matching input:

```glsl
layout (location = 0) in vec3 a_position;
```

That location number is the handshake. The shader says, "I need a `vec3` at location 0." The VAO says, "Location 0 is enabled, and it reads 3 floats from VBO #7 every 12 bytes."

So the draw call can fetch vertex inputs like this:

```text
vertex 0: attr 0 = read 3 floats from byte 0  -> (-0.6, -0.5, 0.0)
vertex 1: attr 0 = read 3 floats from byte 12 -> ( 0.6, -0.5, 0.0)
vertex 2: attr 0 = read 3 floats from byte 24 -> ( 0.0,  0.6, 0.0)
```

The VBO is the data. The VAO is the recipe for reading the data.

### Shaders: tiny programs for the pipeline

Shaders are small programs written in GLSL and compiled by the driver at runtime. A vertex shader and fragment shader are linked together into a **shader program**, which is the thing we bind before drawing.

Today's vertex shader:

```glsl
#version 330 core
layout (location = 0) in vec3 a_position;

void main() {
    gl_Position = vec4(a_position, 1.0);
}
```

It receives one `a_position` per vertex. Because our positions are already in NDC, it passes them straight through as `gl_Position`.

Today's fragment shader:

```glsl
#version 330 core
out vec4 frag_color;

void main() {
    frag_color = vec4(0.13, 0.45, 0.40, 1.0);
}
```

It runs once per covered fragment and outputs the same sea-green color every time.

The shader program and the VAO do not own each other. They meet through matching attribute locations:

```text
shader program                             VAO
layout(location = 0) in vec3 a_position    attr 0 reads vec3 from VBO #7
```

If the shader expects location 0 but the VAO only configures location 1, both objects can be valid and the draw can still be wrong. OpenGL often lets pieces be individually valid while the current combination is nonsense. That is one reason state bugs feel slippery.

### State: why binding exists

OpenGL calls usually act on the current context state. Imagine a few relevant slots:

```text
Current OpenGL context
├─ current shader program:      0
├─ current vertex array object: 0
├─ current ARRAY_BUFFER:        0
├─ current clear color:         (0.04, 0.10, 0.18, 1.0)
└─ current viewport:            (0, 0, framebuffer_width, framebuffer_height)
```

`gl.BindBuffer(gl.ARRAY_BUFFER, vbo)` changes the `current ARRAY_BUFFER` slot. `gl.UseProgram(program)` changes the `current shader program` slot. `gl.BindVertexArray(vao)` changes the `current vertex array object` slot.

The draw call then uses the current state:

```text
gl.DrawArrays(...)
   ├─ uses the current shader program
   ├─ uses the current VAO's vertex-input recipe
   └─ writes into the current framebuffer
```

This is the core OpenGL rhythm: prepare state, then draw with the prepared state.

## Minimal code shape

Before the details, the chapter's code has this shape:

```odin
// setup once
program := compile_and_link(vertex_shader, fragment_shader)

vao, vbo := create_handles()

gl.BindVertexArray(vao)
gl.BindBuffer(gl.ARRAY_BUFFER, vbo)
gl.BufferData(gl.ARRAY_BUFFER, size, data, gl.STATIC_DRAW)
gl.VertexAttribPointer(0, 3, gl.FLOAT, false, stride, offset)
gl.EnableVertexAttribArray(0)
gl.BindVertexArray(0)

// every frame
gl.Clear(gl.COLOR_BUFFER_BIT)
gl.UseProgram(program)
gl.BindVertexArray(vao)
gl.DrawArrays(gl.TRIANGLES, 0, 3)
glfw.SwapBuffers(window)
```

Read that as:

```text
make program
upload vertex bytes
record how attr 0 reads those bytes
each frame: use program + recipe, then draw
```

## Build

1. **Shader sources.** Near the top of `main.odin`, add the two GLSL programs. Chapter 4 moves shaders into files; for this one chapter, string literals keep everything visible:

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

2. **Compile one shader with real error reporting.** Driver compile errors are silent unless you ask. Always ask:

   ```odin
   compile_shader :: proc(source: cstring, kind: u32) -> (id: u32, ok: bool) {
       id = gl.CreateShader(kind)
       source := source
       gl.ShaderSource(id, 1, &source, nil) // nil length means NUL-terminated
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

3. **Link the shaders into a program.** After `gl.load_up_to` in `main`:

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
       gl.DeleteShader(vs)
       gl.DeleteShader(fs)
   ```

   Compiling and linking are separate failure points. A shader can compile, then the program can fail to link because the stages do not agree with each other. You will see that kind of failure once we pass data from the vertex shader to the fragment shader.

4. **Upload vertex data and record the vertex-input recipe.**

   ```odin
       vertices := [?]f32{
           -0.6, -0.5, 0.0, // left
            0.6, -0.5, 0.0, // right
            0.0,  0.6, 0.0, // top
       }

       vao, vbo: u32
       gl.GenVertexArrays(1, &vao)
       gl.GenBuffers(1, &vbo)

       gl.BindVertexArray(vao)

       gl.BindBuffer(gl.ARRAY_BUFFER, vbo)
       gl.BufferData(gl.ARRAY_BUFFER, size_of(vertices), &vertices, gl.STATIC_DRAW)

       gl.VertexAttribPointer(0, 3, gl.FLOAT, false, 3 * size_of(f32), 0)
       gl.EnableVertexAttribArray(0)

       gl.BindVertexArray(0)
   ```

   In plain language:

   ```text
   Bind VAO       choose the recipe object we are editing
   Bind VBO       choose the vertex storage
   BufferData     upload the CPU array into that storage
   AttribPointer  record how location 0 reads from the currently bound VBO
   EnableAttrib   enable per-vertex array fetching for location 0
   Unbind VAO     done editing this recipe
   ```

5. **Draw.** In the render loop, between `gl.Clear` and `SwapBuffers`:

   ```odin
           gl.UseProgram(program)
           gl.BindVertexArray(vao)
           gl.DrawArrays(gl.TRIANGLES, 0, 3)
   ```

   `DrawArrays(mode, first, count)` means: starting at vertex 0, process 3 vertices as `gl.TRIANGLES`. This single call kicks off the pipeline.

6. Run. Sea-green triangle on deep blue.

## OpenGL contracts and quirks

This section is where the API weirdness lives. The concepts above are the part to keep in your head while building. The details below are the part to check when something goes blue-screen-silent.

### `gl.VertexAttribPointer`

Despite the name, this does more than set a pointer. It records an attribute recipe into the currently bound VAO.

```odin
gl.VertexAttribPointer(0,        3,         gl.FLOAT, false,       12,      0)
                       │         │          │         │            │        │
                       location  components type      normalize?   stride   offset
                       in shader per vertex                        bytes    bytes
```

The official contract: `gl.VertexAttribPointer` saves the attribute's component count, type, normalization flag, stride, offset, and the buffer currently bound to `gl.ARRAY_BUFFER` as vertex-array state. That last part is the sneaky one: the VBO source is captured at the moment you call `VertexAttribPointer`. ([Khronos reference](https://registry.khronos.org/OpenGL-Refpages/gl4/html/glVertexAttribPointer.xhtml))

### `gl.EnableVertexAttribArray`

This function does not upload data. It does not bind the shader variable. It does not bind the VBO.

It flips one bit in the currently bound VAO:

```text
attribute location 0 uses per-vertex array data: yes
```

The official contract: `gl.EnableVertexAttribArray(0)` enables the generic vertex attribute array at location 0. When draw calls run, enabled arrays are accessed and used for rendering. ([Khronos reference](https://registry.khronos.org/OpenGL-Refpages/gl4/html/glEnableVertexAttribArray.xhtml))

Another way to say it:

```text
location 0 disabled:
  every vertex receives the current generic attribute value

location 0 enabled:
  every vertex fetches its own value from the configured array
```

For us, location 0 is `a_position`. If it is disabled, OpenGL does not fetch the three positions from the VBO. The vertex shader receives the same value for every vertex, so the triangle collapses to a point and you see only the blue clear color. Your shader compiled. Your buffer exists. Your attribute recipe exists. The per-vertex array was simply not enabled.

### VAO binding and unbinding

Bind a VAO when you are editing its vertex-input recipe:

```odin
gl.BindVertexArray(vao)
gl.VertexAttribPointer(...)
gl.EnableVertexAttribArray(...)
```

Bind a VAO when you are drawing with its recipe:

```odin
gl.BindVertexArray(vao)
gl.DrawArrays(...)
```

You do not need to unbind after every draw. State remains active until changed. The setup-time `gl.BindVertexArray(0)` is just hygiene: it marks "done editing this VAO" and helps catch accidental later changes.

### Can I bind the VBO before the VAO?

Technically, yes, if the same VBO is still bound to `gl.ARRAY_BUFFER` when `gl.VertexAttribPointer` runs:

```odin
gl.BindBuffer(gl.ARRAY_BUFFER, vbo)
gl.BindVertexArray(vao)
gl.VertexAttribPointer(...)
```

But the important moment is `VertexAttribPointer`, because that is when OpenGL captures the current `gl.ARRAY_BUFFER` binding into the VAO's attribute state. This is clearer and harder to break:

```odin
gl.BindVertexArray(vao)
gl.BindBuffer(gl.ARRAY_BUFFER, vbo)
gl.VertexAttribPointer(...)
```

Put the state you are editing next to the call that records it. Future-you will appreciate the breadcrumb.

One Chapter 5 preview: `gl.ELEMENT_ARRAY_BUFFER` behaves differently. That binding is stored directly in the VAO. Index buffers get their own careful explanation when we need them.

## Odin notes

- GLSL source goes to the driver as a NUL-terminated C string. Odin's raw string literals handle multi-line sources cleanly, and you can declare them as `cstring` constants directly.
- `gl.ShaderSource` wants a pointer to a `cstring` because OpenGL accepts an array of source strings. That is why the helper copies `source` into a local and passes `&source`.
- Handles in GL are plain `u32`s. Odin's `gl.GenBuffers(1, &vbo)` mirrors C exactly: the first argument is a count, so you can generate arrays of handles at once.
- The error-log buffer trick is simple and useful: stack-allocate `log: [512]u8`, pass `raw_data(log[:])`, print with `string(log[:])`.

## Checkpoint

One solid sea-green triangle, centered, on the Chapter 2 blue.

- Resize the window: the triangle stretches with it. NDC is relative to the viewport, so a wide window means a wide triangle. This is correct for now; the projection matrix solves it in Chapter 8.
- Change the fragment color constant, rerun: color changes. You've edited your first shader.
- Move a vertex's y to `0.9`, rerun: geometry changes. Put it back.
- No errors in the console: your compile/link checks are silent because they passed.

## Pitfalls

- **Black or blue screen, no errors?** Check the state combination: program used, VAO bound before draw, `VertexAttribPointer` called while the intended VAO was bound, and `EnableVertexAttribArray(0)` called.
- **Only the clear color appears after removing `EnableVertexAttribArray(0)`?** Good. You have proven that the attribute recipe and the enabled bit are separate.
- **Compile error log mentions `version`?** The `#version 330 core` line must be the first line of the source. Watch for a stray leading newline in your raw string literal.
- **The log says `a_position` is undeclared?** Check which shader failed. A vertex shader error and fragment shader error can look similar if your print does not include the stage name.
- **Triangle is white, not sea-green?** Your fragment shader likely failed to compile and your code kept going. Make sure you return on `!fs_ok`.
- **Crash on `gl.BufferData`?** Passing `&vertices` is correct for a fixed array. If you switch to a slice or dynamic array, use `raw_data(vertices)` and `len(vertices) * size_of(f32)` instead.

## Exercises

1. Make the triangle enormous: vertices at `(-1, -1)`, `(1, -1)`, `(0, 1)`. Then push one coordinate beyond NDC, such as `y = 3.0`, and observe clipping at the viewport edge.
2. Add a second triangle by extending the array to 6 vertices and drawing `gl.DrawArrays(gl.TRIANGLES, 0, 6)`. Notice the duplicated shared-edge vertices. Chapter 5's index buffer exists to solve that pain.
3. Per-vertex color via interpolation: add a second attribute at location 1, interleaved after position. The stride becomes `6 * size_of(f32)` and color's offset is `3 * size_of(f32)`. Add `layout (location = 1) in vec3 a_color;` plus `out vec3 v_color;` in the vertex shader, then `in vec3 v_color;` in the fragment shader. A smooth gradient appears.
4. Break things on purpose and read the logs: delete a semicolon in the fragment shader, change `out vec4` to `out vec3`, or rename a varying in only one shader. Knowing the shape of failures is real graphics skill.
5. Comment out only `gl.EnableVertexAttribArray(0)`, rerun, then restore it. This makes the enabled-bit concept visible in the least glamorous but most convincing way.

## Commit

```
git commit -m "ch03: first triangle — VBO, VAO, manual shader pipeline"
```

Prev: [Chapter 2 — Heartbeat](ch02-heartbeat.md) · Next: [Chapter 4 — The Shader Forge](ch04-the-shader-forge.md)
