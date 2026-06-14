#version 330 core

out vec4 frag_color;

uniform float u_time;
uniform vec2 u_resolution;

void main() {
	vec3 deep = vec3(0.05, 0.25, 0.30);
	vec3 foam = vec3(0.65, 0.80, 0.78);
	float pulse = 0.5 + 0.5 * sin(u_time * 1.5);
	
	vec3 color = mix(deep, foam, pulse);
	vec3 tint  = vec3(gl_FragCoord.y / u_resolution, 1.0);

	frag_color = vec4(color * tint, 1.0);
}