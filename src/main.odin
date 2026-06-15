package main

import "core:fmt"
import "core:math"
import "core:math/linalg/glsl"
import "core:strings"
import gl "vendor:OpenGL"
import "vendor:glfw"

WINDOW_WIDTH :: 1280
WINDOW_HEIGHT :: 720
WINDOW_TITLE :: "Saltwind"

Sea_Vertex :: struct {
	position: glsl.vec3,
	uv:       glsl.vec2,
}



// odinfmt: disable
vertices := [?]Sea_Vertex{
	{position = {-0.5, -0.5, 0.0}, uv = {0.0, 0.0}},
	{position = { 0.5, -0.5, 0.0}, uv = {1.0, 0.0}},
	{position = { 0.5,  0.5, 0.0}, uv = {1.0, 1.0}},
	{position = {-0.5,  0.5, 0.0}, uv = {0.0, 1.0}},
}
indices := [?]u32{
	0, 1, 2,
	2, 3, 0,
}
// odinfmt: enable


main :: proc() {
	if !glfw.Init() {
		desc, code := glfw.GetError()
		fmt.eprintln("GLFW init failed: ", code, desc)
		return
	}
	defer glfw.Terminate()

	glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 3)
	glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 3)
	glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
	when ODIN_OS == .Darwin {
		glfw.WindowHint(glfw.OPENGL_FORWARD_COMPAT, glfw.TRUE) // macOS requires this for core
	}

	window := glfw.CreateWindow(WINDOW_WIDTH, WINDOW_HEIGHT, WINDOW_TITLE, nil, nil)
	if window == nil {
		fmt.eprintln("Window or GL context creation failed")
		return
	}
	defer glfw.DestroyWindow(window)

	glfw.MakeContextCurrent(window)
	gl.load_up_to(3, 3, glfw.gl_set_proc_address)

	fb_width, fb_height := glfw.GetFramebufferSize(window)
	gl.Viewport(0, 0, fb_width, fb_height)

	glfw.SetFramebufferSizeCallback(window, framebuffer_resize_callback)

	// Enable v-sync
	glfw.SwapInterval(1)

	// Setup shaders
	shader, shader_ok := shader_load("assets/shaders/basic.vert", "assets/shaders/basic.frag")
	if !shader_ok do return

	crate_tex, tex_ok := texture_load("assets/textures/crate.jpg")
	if !tex_ok do return

	vao, vbo, ebo: u32
	gl.GenVertexArrays(1, &vao)
	gl.GenBuffers(1, &vbo)
	gl.GenBuffers(1, &ebo)

	gl.BindVertexArray(vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, vbo)
	gl.BufferData(gl.ARRAY_BUFFER, size_of(vertices), &vertices, gl.STATIC_DRAW)
	gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, ebo)
	gl.BufferData(gl.ELEMENT_ARRAY_BUFFER, size_of(indices), &indices, gl.STATIC_DRAW)

	gl.VertexAttribPointer(0, 3, gl.FLOAT, false, size_of(Sea_Vertex), offset_of(Sea_Vertex, position))
	gl.EnableVertexAttribArray(0)
	gl.VertexAttribPointer(1, 2, gl.FLOAT, false, size_of(Sea_Vertex), offset_of(Sea_Vertex, uv))
	gl.EnableVertexAttribArray(1)

	gl.BindVertexArray(0)

	last_time := f32(glfw.GetTime())
	reload_timer: f32 = 0.0

	for !glfw.WindowShouldClose(window) {
		// Timing
		t := f32(glfw.GetTime())
		dt := t - last_time
		last_time = t

		reload_timer += dt
		if reload_timer > 1.0 {
			reload_timer = 0.0
			shader_reload_if_changed(&shader)
		}

		// Update
		glfw.PollEvents()
		if glfw.GetKey(window, glfw.KEY_ESCAPE) == glfw.PRESS {
			glfw.SetWindowShouldClose(window, true)
		}

		polygon_mode := u32(gl.FILL)
		if glfw.GetKey(window, glfw.KEY_TAB) == glfw.PRESS {
			polygon_mode = gl.LINE
		}
		gl.PolygonMode(gl.FRONT_AND_BACK, polygon_mode)

		// Draw
		gl.ClearColor(0.04, 0.10, 0.18, 1.0) // deep sea blue
		gl.Clear(gl.COLOR_BUFFER_BIT)

		gl.UseProgram(shader.id)

		gl.BindVertexArray(vao)

		gl.ActiveTexture(gl.TEXTURE0)
		gl.BindTexture(gl.TEXTURE_2D, crate_tex.id)
		shader_set_i32(shader, "u_texture", 0)

		shader_set_f32(shader, "u_time", f32(t))

		s := 0.6 + 0.1 * math.sin(2 * t)
		transform := glsl.mat4Translate({0.5, 0.4, 0}) * glsl.mat4Rotate({0, 0, 1}, t * 0.8) * glsl.mat4Scale({s, s, 1.0})
		shader_set_mat4(shader, "u_transform", transform)

		gl.DrawElements(gl.TRIANGLES, len(indices), gl.UNSIGNED_INT, nil)

		transform = glsl.mat4Translate({-0.5, -0.4, 0}) * glsl.mat4Rotate({0, 0, 1}, t * 0.8) * glsl.mat4Scale({s, s, 1.0})
		shader_set_mat4(shader, "u_transform", transform)

		gl.DrawElements(gl.TRIANGLES, len(indices), gl.UNSIGNED_INT, nil)

		glfw.SwapBuffers(window)

		free_all(context.temp_allocator)
	}
}

framebuffer_resize_callback :: proc "c" (window: glfw.WindowHandle, width, height: i32) {
	gl.Viewport(0, 0, width, height)
}

compile_shader :: proc(source: string, kind: u32) -> (id: u32, ok: bool) {
	source_cstring := strings.clone_to_cstring(source)
	id = gl.CreateShader(kind)
	gl.ShaderSource(id, 1, &source_cstring, nil)
	gl.CompileShader(id)

	success: i32
	gl.GetShaderiv(id, gl.COMPILE_STATUS, &success)
	if success == 0 {
		log: [512]u8
		gl.GetShaderInfoLog(id, 512, nil, raw_data(log[:]))
		fmt.eprintln("shader compile error:\n\t", string(log[:]))
		return 0, false
	}

	return id, true
}
