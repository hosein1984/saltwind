package main

import "core:math/linalg/glsl"

transform_trs :: proc(t, r, s: glsl.mat4) -> glsl.mat4 {
	return t * r * s
}
