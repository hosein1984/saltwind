#version 330 core

layout (location = 0) in vec3 a_position;

uniform float u_time;

void main() {
    float offset = 0.75 * sin(u_time + a_position.y);
    gl_Position = vec4(a_position + offset, 1.0);
}