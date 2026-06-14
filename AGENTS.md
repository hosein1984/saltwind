# Saltwind Agent Notes

## Project

Saltwind is a self-paced Odin + OpenGL learning project that grows from a blank window into a playable sailing game. The docs are written as a course, but the user's goal is deeper understanding, not just copying code.

## Collaboration Style

- Be a companion and technical guide, not only a code editor.
- When a chapter introduces a new graphics concept, explain the mental model before changing code.
- Prefer small, chapter-sized steps with visible outcomes.
- Preserve the course's tone: practical, warm, nautical when natural, but technically precise.
- Do not skip over "obvious" graphics setup details; the user wants to understand what the machine is doing.
- Prefer chapter explanations in this order: goal, plain-language problem, conceptual model/data flow, minimal code shape, then API quirks and OpenGL-specific gotchas.
- In graphics docs, explain the general graphics idea first in language that would also apply to Metal, Direct3D, Vulkan, or WebGPU; then map that idea to the specific OpenGL names used in Saltwind.
- When OpenGL naming is misleading, separate the official API contract from the teaching analogy so the user can tell what is specification and what is mental model.

## Technical Conventions

- Language: Odin.
- Graphics baseline: OpenGL 3.3 core profile.
- Windowing/input: `vendor:glfw`.
- OpenGL loader/bindings: `vendor:OpenGL`.
- Code lives in `src/`, currently as a single package.
- Course docs live in `docs/`.
- Use `odin run src`, `odin build src`, or Makefile targets depending on the chapter context.

## Current Course State

- The user has finished Chapters 2 and 3.
- Chapter 2 establishes the render loop, GL loading, viewport setup, vsync, clearing, and input polling.
- Chapter 3 draws the first triangle with manual shader compilation/linking, a VBO, a VAO, and one vertex attribute.
- The user wants deeper explanations and visualizations for concepts that are easy to hand-wave:
  - OpenGL as concrete current-context state slots,
  - VBOs as raw GPU byte storage,
  - VAOs as vertex-input recipes,
  - what `gl.VertexAttribPointer` records,
  - why `gl.EnableVertexAttribArray` matters,
  - when VAOs should be bound/unbound,
  - how shader attribute locations connect to VAO attributes.

## Editing Rules

- Keep documentation changes scoped to the chapter being discussed unless the user asks for a broader rewrite.
- Do not overwrite user changes in `src/main.odin`; the working tree may contain chapter progress.
- Use focused verification after edits: at minimum inspect diffs and ensure links/paths still make sense.
