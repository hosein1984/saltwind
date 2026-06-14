package main

import "core:fmt"
import "core:math/linalg/glsl"
import "core:os"
import "core:time"
import gl "vendor:OpenGL"

Shader :: struct {
	id:      u32,

	// fields for hot-reloading
	vs_path: string,
	fs_path: string,
	vs_time: time.Time,
	fs_time: time.Time,
}


shader_load :: proc(vs_path, fs_path: string) -> (Shader, bool) {
	id, load_ok := gl.load_shaders_file(vs_path, fs_path)
	if !load_ok {
		msg, stage := gl.get_last_error_message()
		fmt.eprintfln("[shader] %v error loading %s + %s:\n\t%s", stage, vs_path, fs_path, msg)
		return {}, false
	}

	vs_time, _ := os.last_write_time_by_name(vs_path)
	fs_time, _ := os.last_write_time_by_name(fs_path)

	shader := Shader {
		id      = id,
		vs_path = vs_path,
		fs_path = fs_path,
		vs_time = vs_time,
		fs_time = fs_time,
	}

	return shader, true
}

shader_destroy :: proc(shader: ^Shader) {
	gl.DeleteProgram(shader.id)
	shader.id = 0
}

shader_set_f32 :: proc(shader: Shader, name: cstring, value: f32) {
	gl.Uniform1f(gl.GetUniformLocation(shader.id, name), value)
}

shader_set_i32 :: proc(shader: Shader, name: cstring, value: i32) {
	gl.Uniform1i(gl.GetUniformLocation(shader.id, name), value)
}

shader_set_vec2 :: proc(shader: Shader, name: cstring, value: glsl.vec2) {
	value := value
	gl.Uniform2fv(gl.GetUniformLocation(shader.id, name), 1, &value[0])
}

shader_set_vec3 :: proc(shader: Shader, name: cstring, value: glsl.vec3) {
	value := value
	gl.Uniform3fv(gl.GetUniformLocation(shader.id, name), 1, &value[0])
}

shader_set_mat4 :: proc(shader: Shader, name: cstring, value: glsl.mat4) {
	value := value
	gl.UniformMatrix4fv(gl.GetUniformLocation(shader.id, name), 1, false, &value[0, 0])
}

shader_reload_if_changed :: proc(shader: ^Shader) {
	vs_time, _ := os.last_write_time_by_name(shader.vs_path)
	fs_time, _ := os.last_write_time_by_name(shader.fs_path)

	if vs_time == shader.vs_time && fs_time == shader.fs_time {
		return
	}

	new_shader, ok := shader_load(shader.vs_path, shader.fs_path)
	if !ok {
		return
	}

	shader_destroy(shader)
	shader^ = new_shader
	fmt.println("[shader] reloaded")
}
