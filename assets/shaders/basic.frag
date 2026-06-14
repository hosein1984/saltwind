#version 330 core

in vec3 v_color;

uniform float u_time;

out vec4 frag_color;

void main() {
	float shimmer = 0.04 * sin(u_time * 2.0);
	frag_color = vec4(v_color + shimmer, 1.0);
}