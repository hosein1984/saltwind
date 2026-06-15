package main

import "core:fmt"
import gl "vendor:OpenGL"
import stbi "vendor:stb/image"

Texture :: struct {
	id:            u32,
	width, height: i32,
}

texture_load :: proc(path: cstring) -> (tex: Texture, ok: bool) {
	stbi.set_flip_vertically_on_load(1)

	channels: i32
	data := stbi.load(path, &tex.width, &tex.height, &channels, 0)
	if data == nil {
		fmt.eprintln("[texture] failed to load: ", path)
		return {}, false
	}
	defer stbi.image_free(data)

	source_format: u32 = gl.RGBA if channels == 4 else gl.RGB
	internal_format: i32 = gl.RGBA8 if channels == 4 else gl.RGB8

	gl.GenTextures(1, &tex.id)
	gl.BindTexture(gl.TEXTURE_2D, tex.id)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)

	gl.PixelStorei(gl.UNPACK_ALIGNMENT, 1)
	gl.TexImage2D(gl.TEXTURE_2D, 0, internal_format, tex.width, tex.height, 0, source_format, gl.UNSIGNED_BYTE, data)
	gl.GenerateMipmap(gl.TEXTURE_2D)

	gl.BindTexture(gl.TEXTURE_2D, 0)

	return tex, true
}

texture_destroy :: proc(tex: ^Texture) {
	gl.DeleteTextures(1, &tex.id)
	tex^ = {}
}
