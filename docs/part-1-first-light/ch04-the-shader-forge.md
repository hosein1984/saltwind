# Chapter 4 — The Shader Forge

*Part 1 — First Light · Estimated time: 3h · learnopengl: [Shaders](https://learnopengl.com/Getting-started/Shaders)*

**What you'll see when done:** the triangle pulsing between deep water and foam, driven by a clock you pass to the GPU — and shaders living in their own files where they belong.

## Where we are

Chapter 3's manual compile-link dance taught you what shader loading *is*. Now we put it behind an abstraction we'll use for the remaining 48 chapters: a `Shader` struct, file loading, honest error reporting, and uniform helpers. Then we use it to learn the concept this chapter is really about — **uniforms**, the channel through which your CPU code steers your GPU programs every frame. And the flagship exercise builds shader **hot-reload**, the single best quality-of-life feature in this entire course.

## Concepts

### Uniforms: per-draw knobs

Vertex attributes change *per vertex*. Uniforms are the opposite: values that are **constant across one draw call** but settable between draws — the current time, the camera matrix, the sun direction, a material color. Declared in GLSL at file scope:

```glsl
uniform float u_time;
```

and set from the CPU by name: query the location once (`gl.GetUniformLocation(program, "u_time")` → an `i32` slot), then `gl.Uniform1f(loc, value)` *while the program is bound* with `gl.UseProgram`. Uniforms keep their value per-program until you set them again — more state machine.

Two facts that save future debugging: a location of `-1` means "no such active uniform", and — the classic trap — the GLSL compiler **optimizes away uniforms you don't actually use**, so a freshly-declared-but-unused uniform also reports −1. Setting location −1 is silently ignored, which is somehow both merciful and maddening.

### Shaders as assets, not string literals

String-literal shaders mean recompiling the *program* (the Odin one) for every shader tweak. Shaders are content, like textures — they belong in `assets/shaders/`, loaded at runtime. The payoff compounds: runtime loading is what makes hot-reload possible, and from Chapter 28 onward you'll be iterating on wave shaders dozens of times an hour.

`vendor:OpenGL` ships a helper that does exactly the Chapter 3 dance, reading from disk:

```odin
program_id, ok := gl.load_shaders_file("assets/shaders/sea.vert", "assets/shaders/sea.frag")
```

When compilation fails, the helper records the driver's error log; you retrieve it with `gl.get_last_error_message()`, which returns the message *and* which stage failed. We wrap all of this once, properly, today.

### The abstraction, per course conventions

```odin
Shader :: struct {
	id: u32,
}
```

Yes, one field. The struct earns its keep through its procs (`shader_load`, `shader_set_*`, later `shader_destroy`) and because other writers — Chapters 12, 27, 29 — will assume exactly this type. Resist the urge to add fields until a chapter tells you to.

## Odin notes

- `gl.GetUniformLocation` takes a `cstring` name. Take `name: cstring` in the helpers and call sites stay literal: `shader_set_f32(sh, "u_time", t)` — no conversions anywhere.
- Uniform-upload functions that take pointers (`Uniform3fv`, `UniformMatrix4fv`) need an addressable value. Parameters in Odin are immutable, so shadow first: `v := v`, then `&v[0]`.
- `os.last_write_time_by_name` (in `core:os`) returns a file's modification stamp — the whole basis of hot-reload. On Windows, `vendor:OpenGL` even ships a ready-made `gl.update_shader_if_changed`; we write our own portable one in the exercise so it's yours.

## Build

1. **Create the shader files.** `assets/shaders/basic.vert`:

   ```glsl
   #version 330 core
   layout (location = 0) in vec3 a_position;

   void main() {
   	gl_Position = vec4(a_position, 1.0);
   }
   ```

   `assets/shaders/basic.frag` — now with a clock:

   ```glsl
   #version 330 core
   out vec4 frag_color;

   uniform float u_time;

   void main() {
   	vec3 deep = vec3(0.05, 0.25, 0.30);
   	vec3 foam = vec3(0.65, 0.80, 0.78);
   	float pulse = 0.5 + 0.5 * sin(u_time * 1.5);
   	frag_color = vec4(mix(deep, foam, pulse), 1.0);
   }
   ```

   (`mix` is GLSL's lerp — you will type it a thousand more times.)

2. **Create `src/shader.odin`** — same `package saltwind`, new file; Odin compiles every file in `src/` together, no imports needed between them:

   ```odin
   Shader :: struct {
   	id: u32,
   }

   shader_load :: proc(vs_path, fs_path: string) -> (shader: Shader, ok: bool) {
   	id, load_ok := gl.load_shaders_file(vs_path, fs_path)
   	if !load_ok {
   		msg, stage := gl.get_last_error_message()
   		fmt.eprintfln("[shader] %v error loading %s + %s:\n%s", stage, vs_path, fs_path, msg)
   		return {}, false
   	}
   	return Shader{id = id}, true
   }

   shader_destroy :: proc(shader: ^Shader) {
   	gl.DeleteProgram(shader.id)
   	shader.id = 0
   }
   ```

3. **Uniform helpers** in the same file. We need `f32` and `i32` today; `vec3` and `mat4` are stubs whose chapters are coming (7 and 14) — write all four now so the API is complete:

   ```odin
   shader_set_f32 :: proc(shader: Shader, name: cstring, value: f32) {
   	gl.Uniform1f(gl.GetUniformLocation(shader.id, name), value)
   }

   shader_set_i32 :: proc(shader: Shader, name: cstring, value: i32) {
   	gl.Uniform1i(gl.GetUniformLocation(shader.id, name), value)
   }

   shader_set_vec3 :: proc(shader: Shader, name: cstring, value: glsl.vec3) {
   	value := value
   	gl.Uniform3fv(gl.GetUniformLocation(shader.id, name), 1, &value[0])
   }

   shader_set_mat4 :: proc(shader: Shader, name: cstring, value: glsl.mat4) {
   	value := value
   	gl.UniformMatrix4fv(gl.GetUniformLocation(shader.id, name), 1, false, &value[0, 0])
   }
   ```

   (Add `import "core:math/linalg/glsl"` and `import gl "vendor:OpenGL"` plus `core:fmt` at the top of `shader.odin`.) Looking up locations by string every frame is mildly wasteful; it is also irrelevant at our scale. Chapter 49's profiling pass revisits this — `gl.get_uniforms_from_program` can cache the whole table — but premature now.

4. **Gut `main.odin`.** Delete `VERTEX_SOURCE`, `FRAGMENT_SOURCE`, `compile_shader`, and the inline link code. Replace with:

   ```odin
   	shader, shader_ok := shader_load("assets/shaders/basic.vert", "assets/shaders/basic.frag")
   	if !shader_ok do return
   ```

   And in the loop, drive the pulse:

   ```odin
   		gl.UseProgram(shader.id)
   		shader_set_f32(shader, "u_time", f32(glfw.GetTime()))
   		gl.BindVertexArray(vao)
   		gl.DrawArrays(gl.TRIANGLES, 0, 3)
   ```

   Remember: `UseProgram` first, *then* set uniforms — they target the currently bound program.

5. **Verify the error path on purpose.** Put a deliberate typo in `basic.frag` (`vec33`), run, and confirm you get a readable message naming the stage and the GLSL line number. Fix it. You will be very glad this works the day a shader fails for real.

6. Run from the project root (`odin run src` — file paths are relative to where you run). The triangle breathes between deep water and foam.

## Checkpoint

The triangle pulses smoothly, roughly one full cycle every four seconds.

- Edit `basic.frag` (change `foam` to something lurid), rerun: new colors with zero changes to Odin code.
- Break the shader, run: clear console error with stage + line, program exits cleanly rather than crashing.
- Resize: still fine — nothing this chapter touched geometry.

## Pitfalls

- **`load_shaders_file` fails but the files exist?** You're running from inside `src/` or your editor's working directory — paths are relative to the *current working directory*, so run from the `saltwind/` root. This bites everyone exactly once per project.
- **Pulse doesn't pulse?** ① Forgot `shader_set_f32` in the loop; ② cast missing — `glfw.GetTime()` is `f64`, the helper takes `f32`; ③ you set the uniform before `gl.UseProgram`.
- **`GetUniformLocation` returns −1 for a uniform you swear exists?** It's declared but unused in the GLSL, so the compiler removed it; or you typo'd the name (GLSL `u_Time` ≠ `"u_time"`).
- **Worked, then broke after you reorganized files?** `shader.odin` must start with `package saltwind` like every file in `src/` — different package names in one directory won't compile.

## Exercises

1. Add `u_resolution` (`vec2`-style — add a `shader_set_vec2` or pass two floats) and tint the fragment by `gl_FragCoord.xy / u_resolution` — a viewport-anchored gradient and your first taste of `gl_FragCoord`.
2. Move the *vertices* with time instead: pass `u_time` into the vertex shader and offset `a_position.x` by `0.25 * sin(u_time + a_position.y)`. The triangle sways like a mast. Note the uniform must be declared in whichever stage uses it.
3. **Stretch (flagship — do not skip):** **Shader hot-reload.** In `shader.odin`:

   ```odin
   Shader_Watch :: struct {
   	vs_path, fs_path: string,
   	vs_time, fs_time: os.File_Time,
   }

   shader_watch_reload :: proc(shader: ^Shader, watch: ^Shader_Watch) {
   	vt, _ := os.last_write_time_by_name(watch.vs_path)
   	ft, _ := os.last_write_time_by_name(watch.fs_path)
   	if vt == watch.vs_time && ft == watch.fs_time do return
   	watch.vs_time, watch.fs_time = vt, ft

   	if new_shader, ok := shader_load(watch.vs_path, watch.fs_path); ok {
   		shader_destroy(shader)
   		shader^ = new_shader
   		fmt.println("[shader] reloaded")
   	} // on failure: keep the old program running, error already printed
   }
   ```

   Call it from the loop on a one-second timer (accumulate `dt`; reset at 1.0). Initialize the watch's times right after the first load. Now: run Saltwind, open `basic.frag`, change a color, *save* — and watch the running triangle change without restarting. Failure-tolerance is the killer detail: a broken save keeps the last good shader on screen and prints the error. **Keep this in the loop permanently.** Every shader chapter from here to 51 assumes you iterate this way.

## Commit

```
git commit -m "ch04: Shader struct, file loading, uniforms, hot-reload"
```

Prev: [Chapter 3 — First Triangle](ch03-first-triangle.md) · Next: [Chapter 5 — Quads & Indices](ch05-quads-and-indices.md)
