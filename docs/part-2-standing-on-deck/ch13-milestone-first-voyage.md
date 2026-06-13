# Chapter 13 — MILESTONE: First Voyage

*Part 2 — Standing on Deck · Estimated time: 2h · learnopengl: review — [Getting Started](https://learnopengl.com/Getting-started/Review) covers the same ground we just sailed past*

**What you'll see when done:** your screenshot moment #1 — gliding low over endless dusk-colored water among drifting crates, in a codebase tidy enough to carry the next 39 chapters.

## Where we are

Twelve chapters ago: a black window. Now: an endless animated sea under a flycam, floating cargo on a fixed-timestep world clock, hot-reloading shaders, and a real mesh system. This milestone chapter adds almost nothing new on purpose. Milestones are for three things: **integration** (make everything play together and look deliberate), **consolidation** (a refactor pass while the code is still small enough to refactor fearlessly), and **rest** (a self-test, a screenshot, and explicit permission to put this down for two weeks without losing the thread).

## Integration: the sunset pass

1. **One palette, one place.** Hunt down every color literal and gather them at the top of `sea.odin` / `main.odin` as named constants. Then set the scene to golden-hour:

   ```odin
   SKY_COLOR     :: glsl.vec3{0.86, 0.58, 0.38} // low-sun amber
   HORIZON_COLOR :: SKY_COLOR                    // the ch12 agreement, now enforced by the compiler
   ```

   In `sea.frag`, warm the water to match — sunset sea reflects sunset sky (cheaply, by hand, until Chapter 29 does it for real):

   ```glsl
   	vec3 deep  = vec3(0.05, 0.09, 0.14);
   	vec3 crest = vec3(0.25, 0.16, 0.14); // warm glint instead of cyan
   ```

   Tune live via hot-reload until the water reads as evening. There is no correct answer; there is *your* answer.

2. **Set dressing.** Spread the crate fleet out (8–10 crates over a ~60-unit area, varied phases and spins), park the red buoy among them, and set the camera's spawn low — `{0, 1.8, 12}`, pitch slightly down — so launching the program drops you straight into the screenshot.

3. **A quit that isn't a crash.** Verify every `*_destroy` runs on exit (`defer mesh_destroy(&…)`, `shader_destroy`, `texture_destroy`, window, GLFW). Thirty seconds of hygiene; the habit is the point.

## Refactor: the app/render split

If Chapters 9–12 left `main.odin` as a 300-line stew, fix it now — every later chapter assumes roughly this shape (same package, so this is *moving procs between files*, no import ceremony):

```text
src/
├── main.odin     ← main() only: init, the loop skeleton, shutdown
├── app.odin      ← Game struct + game_init/game_update/game_render/game_destroy
├── camera.odin   ← (ch9, already exists)
├── input.odin    ← (ch10, already exists)
├── shader.odin   ├ texture.odin  ├ mesh.odin  ├ sea.odin   ← (already exist)
```

The one new type, per conventions:

```odin
Game :: struct {
	camera:   Camera,
	input:    Input,
	sea:      Sea,
	crate:    Mesh,
	buoy:     Mesh,
	crate_tex: Texture,
	shader:    Shader,   // textured objects
	flat_shader: Shader, // solid color
	sim_time: f64,
	paused:   bool,
	time_scale: f64,
}
```

`main`'s loop body collapses to: poll → `game_update(&game, frame_dt)` (input consumption, camera, the fixed-step accumulator) → `game_render(&game, aspect)` (matrices, uniforms, draws). If a proc needs more than `&game` plus a couple of scalars, it's probably holding state that belongs *in* `Game`. Build, run, confirm identical behavior — refactors that change behavior are two bugs, not one.

## Self-test

Close the book; answer from memory; then check.

1. What does a VAO store, and what does a VBO store?
2. Why does `shader_set_mat4` pass `false` for the transpose parameter?
3. In `v' = T * R * S * v`, which transform applies to the vertex first?
4. Why does the simulation use a fixed timestep while the camera uses render `dt`?
5. What two things must happen to the depth buffer for depth testing to work correctly across frames?
6. Why does the sea tile snap to *whole-cell* increments instead of following the camera smoothly?
7. Why must `gl.load_up_to` run after `glfw.MakeContextCurrent`?
8. A texture renders solid black. Name the most likely cause.

<details>
<summary><b>Answers</b></summary>

1. The VAO stores the vertex *layout*: attribute formats, strides, offsets, which buffers they read from, and the EBO binding. The VBO stores the actual vertex *bytes*. The VAO is the description; the VBO is the data.
2. Odin's `glsl.mat4` is already column-major in memory, exactly as OpenGL expects — uploading with `transpose = true` would double-convert and scramble the transform.
3. **S** (scale) — with column vectors, the matrix nearest the vector applies first; the chain reads right-to-left.
4. Physics integration error depends on step size, so a variable step makes simulation behavior frame-rate-dependent and can make spring-like systems (buoyancy, sailing) unstable. The camera has no integration to destabilize, and using render `dt` minimizes input-to-view latency.
5. It must be enabled (`gl.Enable(gl.DEPTH_TEST)`) and *cleared every frame* (`gl.DEPTH_BUFFER_BIT` in `gl.Clear`) — otherwise the new frame tests against last frame's depths.
6. Snapping by whole cells means the vertex lattice always occupies identical world positions — vertices never slide through the (world-anchored) color/wave field, which would cause visible swimming, especially once vertices carry wave displacement in ch28.
7. GL functions are looked up *from the driver through the current context*; with no current context there's nothing to query and the loader can't resolve any pointers.
8. A mipmap-based `MIN_FILTER` (the GL default!) with no mipmaps generated — `gl.GenerateMipmap` missing after upload. (Runners-up: texture not bound at draw time; sampler uniform pointing at the wrong unit.)

</details>

Five or more cold? Sail on. Fewer? Skim the relevant chapters' Concepts sections — they were written to be re-read.

## Screenshot moment #1

The checklist before you press the key:

- [ ] Launch → you spawn low over the water, crates ahead, buoy visible
- [ ] Sunset palette: amber sky, warm-dark water, horizon seamless in all directions
- [ ] Fly 60 seconds in one direction: no world edge, no seam, no stutter
- [ ] P freezes the bobbing fleet mid-motion; T slows it to syrup; title bar shows steady ~16.7 ms
- [ ] TAB shows a clean dense wireframe sea; TAB again, back to glass
- [ ] Window resize at any aspect: zero distortion

Then frame it: low camera, crates leading the eye toward the horizon, slight downward pitch. Take the screenshot (OS screenshot tool is fine; Saltwind grows its own screenshot key in Chapter 51).

**Share it.** Post it to the [Odin Discord](https://discord.gg/odinlang)'s showcase channel or [r/odinlang](https://reddit.com/r/odinlang) with a line about the course — "endless procedural sea, 13 chapters into building a sailing world in Odin" gets exactly the reception you'd hope. This isn't vanity: the dropout curve for long projects bends *hard* around the first time strangers say "nice." Collect that. You'll want five more of these moments and you should get all of them.

## Coming back after a break

*This is a good place to rest.* When you return — next week or next month — here's the thread: **Saltwind is a fixed-timestep world** (`game_update`, accumulator, `sim_time`) **rendered by a free camera** (`Camera` in `camera.odin`, view/projection per frame) **drawing `Mesh`es** (`mesh.odin` generators, one vertex format: position/normal/uv) **with file-loaded `Shader`s that hot-reload** (`shader.odin`, edit `assets/shaders/*` while it runs). The sea is a 256² grid that follows the camera in whole-cell snaps, colored by two scrolling sine layers and faded into the sky at distance. Run it, fly for two minutes, hold TAB once — it all comes back. Then turn the page: Part 3 puts a **sun** in that sky, and the normals you've been dutifully generating since Chapter 11 finally go to work.

## Commit

```
git commit -m "ch13: milestone — first voyage; app/render split, sunset pass"
```

Also tag it — milestones deserve tags: `git tag part-2-first-voyage`

Prev: [Chapter 12 — A Flat Blue Forever](ch12-a-flat-blue-forever.md) · Next: [Chapter 14 — One Sun](../part-3-let-there-be-light/ch14-one-sun.md)
