package main

import "core:fmt"
import "core:math"
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


	last_time := glfw.GetTime()
	for !glfw.WindowShouldClose(window) {
		// Timing
		now := glfw.GetTime()
		dt := f32(now - last_time)
		last_time = now
		fmt.println("DT:", dt)

		// Update
		glfw.PollEvents()
		if glfw.GetKey(window, glfw.KEY_ESCAPE) == glfw.PRESS {
			glfw.SetWindowShouldClose(window, true)
		}

		// Draw
		gl.ClearColor(0.04, 0.10, 0.18, 1.0) // deep sea blue
		gl.Clear(gl.COLOR_BUFFER_BIT)


		glfw.SwapBuffers(window)
	}
}

framebuffer_resize_callback :: proc "c" (window: glfw.WindowHandle, width, height: i32) {
	gl.Viewport(0, 0, width, height)
}
