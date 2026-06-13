# Chapter 9 — Free as a Gull

*Part 2 — Standing on Deck · Estimated time: 3h · learnopengl: [Camera](https://learnopengl.com/Getting-started/Camera)*

**What you'll see when done:** the scene unlocked — mouse to look anywhere, WASD to fly, scroll to zoom, the crate and sea plane sliding past as you bank around them like a gull.

## Where we are

Chapter 8 nailed the camera to `{0, 2.5, 7}`. Time to pull the nail. A free-fly camera transforms Saltwind from a diorama into a *place* — and the `Camera` struct you build here survives unchanged in spirit all the way to the boat-following camera of Chapter 33.

## Concepts

### The view matrix is an inverse

A camera transform answers "where is the camera in the world?" — position and orientation, like any object's model matrix. But the GPU needs the opposite: "where is the world, relative to the camera?" So **view = inverse(camera's model matrix)**. You could literally call an inverse function each frame; `mat4LookAt` is the cheaper, numerically nicer shortcut that builds the inverse directly from *eye*, *target*, *up*. Our camera stores orientation as angles and feeds `LookAt` a target one unit ahead of the eye:

```
view = mat4LookAt(position, position + forward, {0, 1, 0})
```

### Yaw and pitch → a forward vector

Mouse-look is two angles:

```
        yaw (around world Y)               pitch (around camera's right)
            ─ look left/right                  ─ look up/down

      forward.x = cos(pitch) * cos(yaw)
      forward.y = sin(pitch)
      forward.z = cos(pitch) * sin(yaw)
```

Spherical coordinates, nothing more: pitch lifts the vector out of the horizontal plane (`sin(pitch)` of it goes to y), and what remains (`cos(pitch)`) is distributed around the horizon by yaw. With this formula yaw = 0 faces +X; we start at yaw = −90° to face −Z, the "into the screen" direction the fixed camera looked.

Why no roll? A fly camera that can roll induces nausea and disorientation for free. The constant world-up `{0,1,0}` in `LookAt` quietly enforces zero roll every frame.

**The pitch clamp:** at pitch = ±90°, forward becomes parallel to world-up and `LookAt`'s internal cross product degenerates (the camera "flips"). Clamp to ±89° and the singularity never happens. Every first-person game you've played does this; now you know why you can't look at your own feet-through-the-back-of-your-head.

### Mouse deltas, and the first-mouse jump

We want *relative* motion: how far did the mouse move this frame? GLFW gives *absolute* cursor positions via callback, so we keep the previous position and subtract. Two wrinkles:

1. **Cursor-disabled mode.** `glfw.SetInputMode(window, glfw.CURSOR, glfw.CURSOR_DISABLED)` hides the cursor and gives unbounded virtual motion — no screen edges to hit. This is the FPS-style capture mode.
2. **The first-mouse jump.** The very first callback reports the cursor's arbitrary position; subtracting your made-up initial "previous" produces a single huge delta and snaps the view violently. The fix: on the first event only, set previous = current and report zero delta.

Screen y grows *downward*, so a mouse-up motion is a *negative* y delta — invert it when applying to pitch, or the world look is inverted (some sailors like inverted; make it a constant).

### Frame-rate-independent movement

Position changes use the Chapter 2 rule: `position += direction * speed * dt`, with speed in units/second. Mouse *deltas* are different — they're already "per event", inherently frame-rate independent; multiply by a sensitivity constant only, *not* by dt.

### Zoom = field of view

Scroll-to-zoom is just narrowing `fovy` in the projection: 60° is natural, 20° is a spyglass. Clamp (20°–90°) or you'll scroll into fisheye madness or a zero-degree black void. The `fov` lives in the `Camera` — it's a property of how you're *looking*.

## Odin notes

GLFW mouse callbacks are `proc "c"` (no context, no captures — Chapter 2's lecture applies). The clean pattern: callbacks do the **minimum** — accumulate deltas into package globals — and the main loop consumes them on its own schedule:

```odin
g_mouse_dx, g_mouse_dy: f32   // accumulated since last consumed
g_scroll_dy: f32
g_last_x, g_last_y: f64
g_first_mouse := true
```

Accumulate (`+=`), don't overwrite — multiple mouse events can fire between frames, and you want their sum. Chapter 10 folds these globals into a proper `Input` struct; for now, globals are honest and visible.

## Build

1. **Create `src/camera.odin`** with the course-convention struct and procs:

   ```odin
   package saltwind

   import "core:math"
   import "core:math/linalg/glsl"

   Camera :: struct {
   	position: glsl.vec3,
   	yaw:      f32, // radians; −π/2 faces −Z
   	pitch:    f32, // radians; clamped to ±89°
   	fov:      f32, // radians, vertical
   }

   camera_forward :: proc(camera: Camera) -> glsl.vec3 {
   	return glsl.normalize(glsl.vec3{
   		math.cos(camera.pitch) * math.cos(camera.yaw),
   		math.sin(camera.pitch),
   		math.cos(camera.pitch) * math.sin(camera.yaw),
   	})
   }

   camera_view_matrix :: proc(camera: Camera) -> glsl.mat4 {
   	return glsl.mat4LookAt(camera.position, camera.position + camera_forward(camera), {0, 1, 0})
   }

   camera_projection :: proc(camera: Camera, aspect: f32) -> glsl.mat4 {
   	return glsl.mat4Perspective(camera.fov, aspect, 0.1, 2000)
   }
   ```

2. **Callbacks + globals** (in `main.odin` or a new `src/input.odin` — Chapter 10 reorganizes anyway):

   ```odin
   cursor_pos_callback :: proc "c" (window: glfw.WindowHandle, x, y: f64) {
   	if g_first_mouse {
   		g_last_x, g_last_y = x, y
   		g_first_mouse = false
   	}
   	g_mouse_dx += f32(x - g_last_x)
   	g_mouse_dy += f32(g_last_y - y) // inverted: screen y is down, pitch + is up
   	g_last_x, g_last_y = x, y
   }

   scroll_callback :: proc "c" (window: glfw.WindowHandle, dx, dy: f64) {
   	g_scroll_dy += f32(dy)
   }
   ```

   Register both after window creation, and capture the cursor:

   ```odin
   	glfw.SetCursorPosCallback(window, cursor_pos_callback)
   	glfw.SetScrollCallback(window, scroll_callback)
   	glfw.SetInputMode(window, glfw.CURSOR, glfw.CURSOR_DISABLED)
   ```

3. **Instantiate** before the loop, replacing the hardcoded matrices:

   ```odin
   	camera := Camera{
   		position = {0, 2.5, 7},
   		yaw      = -math.PI / 2, // face −Z, like ch8's fixed view
   		pitch    = 0,
   		fov      = math.to_radians_f32(60),
   	}
   ```

4. **Consume input each frame** — after `PollEvents`, before drawing:

   ```odin
   		SENSITIVITY :: 0.002 // radians per pixel
   		camera.yaw   += g_mouse_dx * SENSITIVITY
   		camera.pitch += g_mouse_dy * SENSITIVITY
   		camera.pitch  = clamp(camera.pitch, math.to_radians_f32(-89), math.to_radians_f32(89))
   		g_mouse_dx, g_mouse_dy = 0, 0

   		camera.fov = clamp(camera.fov - g_scroll_dy * math.to_radians_f32(2.5),
   		                   math.to_radians_f32(20), math.to_radians_f32(90))
   		g_scroll_dy = 0
   ```

   Note yaw `+=` with our forward formula: positive dx (mouse right) increases yaw, which swings forward from −Z toward +X — i.e. the view turns right. Correct.

5. **WASD,** scaled by dt, flying along *camera* axes (forward, and a right vector manufactured by cross product — Chapter 7's geometry, cashing in):

   ```odin
   		forward := camera_forward(camera)
   		right := glsl.normalize(glsl.cross(forward, glsl.vec3{0, 1, 0}))
   		speed := f32(8.0) * dt
   		if glfw.GetKey(window, glfw.KEY_W) == glfw.PRESS do camera.position += forward * speed
   		if glfw.GetKey(window, glfw.KEY_S) == glfw.PRESS do camera.position -= forward * speed
   		if glfw.GetKey(window, glfw.KEY_D) == glfw.PRESS do camera.position += right * speed
   		if glfw.GetKey(window, glfw.KEY_A) == glfw.PRESS do camera.position -= right * speed
   		if glfw.GetKey(window, glfw.KEY_SPACE) == glfw.PRESS      do camera.position.y += speed
   		if glfw.GetKey(window, glfw.KEY_LEFT_SHIFT) == glfw.PRESS do camera.position.y -= speed
   ```

6. **Wire the matrices:**

   ```odin
   		view := camera_view_matrix(camera)
   		projection := camera_projection(camera, aspect)
   ```

   Everything downstream (both shaders' uniforms) is unchanged. Run, and *fly*.

## Checkpoint

Full free flight: mouse looks, WASD translates relative to where you're facing, SPACE/SHIFT go up/down, scroll zooms like a spyglass.

- On launch the view does **not** jump when you first touch the mouse (first-mouse fix working).
- Try to look past straight up: the view stops at 89° instead of somersaulting.
- Fly a wide circle around the crate while looking at it — strafing + yaw — the "orbit by hand" test; it should feel continuous, no hitches at any yaw angle.
- Zoom fully in on the crate from across the plane: a flat-looking spyglass view. Fully out: wide-angle. The crate never *distorts on resize* regardless (aspect still per-frame).

## Pitfalls

- **View snaps violently on first mouse move?** First-mouse fix missing or your `g_first_mouse` is set in the wrong place (must be inside the callback, guarding the very first delta).
- **Look is inverted vertically?** You skipped the `g_last_y - y` flip (or double-flipped by also negating at the apply site). Pick one place for the sign.
- **Camera "flips" or view matrix degenerates looking straight up/down?** Pitch clamp missing, or clamped to ±90 exactly — must be strictly less (89 is the convention).
- **Movement speed depends on frame rate?** A missing `* dt`. Test by toggling `SwapInterval(0)` — flight speed should not change.
- **Diagonal movement (W+D) is faster than straight?** True in this build (the two unit vectors sum to length √2). Acceptable for a debug flycam; normalize the summed *wish direction* if it bothers you — the exercise below does it properly.
- **Mouse delta feels jittery at high frame rates?** You're overwriting (`=`) instead of accumulating (`+=`) in the callback — events between frames get dropped.

## Exercises

1. **Proper wish-direction movement:** sum the WASD contributions into one `wish: glsl.vec3`, and only if `glsl.length(wish) > 0` do `camera.position += glsl.normalize(wish) * speed`. Diagonals fixed.
2. A sprint key: holding CTRL multiplies speed ×4. Trivial — and you'll use it constantly once the world is 1000 units wide in Chapter 12.
3. Level flight mode: flatten `forward.y = 0` (then normalize) for W/S only, so forward motion skims at constant altitude like a gull riding ground effect — keep vertical motion on SPACE/SHIFT alone. Compare feels; pick one as Saltwind's flycam.
4. **Stretch:** Press M to release the cursor (`glfw.CURSOR_NORMAL`) and pause mouse-look; press again to recapture (set `g_first_mouse = true` on recapture — *why?* — see the first pitfall). This toggle becomes genuinely necessary the day you want to use the window's close button without ESC.

## Commit

```
git commit -m "ch09: free-fly camera — mouse look, WASD, fov zoom"
```

Prev: [Chapter 8 — Into the Third Dimension](../part-1-first-light/ch08-into-the-third-dimension.md) · Next: [Chapter 10 — The Pulse of the World](ch10-the-pulse-of-the-world.md)
