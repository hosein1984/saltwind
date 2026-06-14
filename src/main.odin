package main

import "core:fmt"
import "core:math/linalg/glsl"
import "core:strings"
import gl "vendor:OpenGL"
import "vendor:glfw"

WINDOW_WIDTH :: 1280
WINDOW_HEIGHT :: 720
WINDOW_TITLE :: "Saltwind"

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
	
	// odinfmt:disable
	vertices := [?]f32{
		-0.6, -0.5, 0.0, // left
		 0.6, -0.5, 0.0, // right
		 0.0,  0.6, 0.0, // top
	}
	// odinfmt:enable

	vao, vbo: u32
	gl.GenVertexArrays(1, &vao)
	gl.GenBuffers(1, &vbo)

	gl.BindVertexArray(vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, vbo)
	gl.BufferData(gl.ARRAY_BUFFER, size_of(vertices), &vertices, gl.STATIC_DRAW)

	gl.VertexAttribPointer(0, 3, gl.FLOAT, false, 3 * size_of(f32), 0)
	gl.EnableVertexAttribArray(0)

	gl.BindVertexArray(0)


	last_time := glfw.GetTime()
	reload_timer: f32 = 0.0

	for !glfw.WindowShouldClose(window) {
		// Timing
		now := glfw.GetTime()
		dt := f32(now - last_time)
		last_time = now

		reload_timer += dt
		if reload_timer > 1.0 {
			reload_timer = 0.0
			shader_reload_if_changed(&shader)
		}

		width, height := glfw.GetFramebufferSize(window)

		// Update
		glfw.PollEvents()
		if glfw.GetKey(window, glfw.KEY_ESCAPE) == glfw.PRESS {
			glfw.SetWindowShouldClose(window, true)
		}

		// Draw
		gl.ClearColor(0.04, 0.10, 0.18, 1.0) // deep sea blue
		gl.Clear(gl.COLOR_BUFFER_BIT)

		gl.UseProgram(shader.id)
		shader_set_f32(shader, "u_time", f32(now))
		shader_set_vec2(shader, "u_resolution", glsl.vec2{f32(width), f32(height)})
		gl.BindVertexArray(vao)
		gl.DrawArrays(gl.TRIANGLES, 0, 3)

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
