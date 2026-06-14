# Saltwind Agent Notes

## Project

Saltwind is a self-paced Odin + OpenGL learning project that grows from a blank window into a playable sailing game. The docs are written as a course, but the user's goal is deeper understanding, not just copying code.

## Collaboration Style

- Be a companion and technical guide, not only a code editor.
- When a chapter introduces a new graphics concept, explain the mental model before changing code.
- Prefer small, chapter-sized steps with visible outcomes.
- Preserve the course's tone: practical, warm, nautical when natural, but technically precise.
- Do not skip over "obvious" graphics setup details; the user wants to understand what the machine is doing.

## Technical Conventions

- Language: Odin.
- Graphics baseline: OpenGL 3.3 core profile.
- Windowing/input: `vendor:glfw`.
- OpenGL loader/bindings: `vendor:OpenGL`.
- Code lives in `src/`, currently as a single package.
- Course docs live in `docs/`.
- Use `odin run src`, `odin build src`, or Makefile targets depending on the chapter context.

## Current Course State

- The user has just read Chapter 1, `docs/part-1-first-light/ch01-the-shoreline-ahead.md`.
- Chapter 1 creates a 1280x720 GLFW window titled "Saltwind" and makes its OpenGL context current.
- The user specifically wanted clearer explanations of:
  - what a window is,
  - what an OpenGL context is,
  - what `glfw.Init()` does,
  - what `glfw.MakeContextCurrent(window)` means.

## Editing Rules

- Keep documentation changes scoped to the chapter being discussed unless the user asks for a broader rewrite.
- Do not overwrite user changes in `src/main.odin`; the working tree may contain chapter progress.
- Use focused verification after edits: at minimum inspect diffs and ensure links/paths still make sense.
