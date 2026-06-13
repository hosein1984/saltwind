# Chapter 2 — Heartbeat

*Part 1 — First Light · Estimated time: 2h · learnopengl: [Hello Window](https://learnopengl.com/Getting-started/Hello-Window)*

**What you'll see when done:** the window breathes — sixty times a second it clears to a deep sea blue, resizes without complaint, and quits on ESC.

## Where we are

Chapter 1 gave us a window with a GL context attached, but we never made a single GL call — the contents were undefined memory. This chapter establishes the *render loop*: the heartbeat that every subsequent chapter adds organs to. By the end, the structure of `main` will be the structure it keeps for the rest of the course.

## Concepts

### Loading function pointers

Remember from Chapter 1: modern GL functions live inside the driver and must be fetched at runtime. GLFW knows how to ask the driver (`glfw.GetProcAddress`), and `vendor:OpenGL` knows which ~700 functions exist. One line marries them:

```odin
gl.load_up_to(3, 3, glfw.gl_set_proc_address)
```

This walks every GL function up to version 3.3 and fills in `vendor:OpenGL`'s function pointers. Two rules: it must run *after* `MakeContextCurrent` (no current context → no driver to ask), and before any other `gl.` call (unloaded pointer → instant crash). `glfw.gl_set_proc_address` is a tiny glue proc the vendor packages provide precisely for this marriage.

### Double buffering

If the GPU drew directly into the visible framebuffer you'd watch triangles appear one by one — flickering, tearing chaos. Instead there are (at least) two buffers: you draw into the hidden **back buffer**, and when the frame is complete, `glfw.SwapBuffers` flips it to the front in one atomic step. The viewer only ever sees finished frames.

`glfw.SwapInterval(1)` is **vsync**: the swap waits for the monitor's refresh, capping you at (typically) 60 fps and eliminating tearing. We turn it on and keep it on — Saltwind is a sailing world, not a benchmark.

### Clearing, and a promise about color

`gl.ClearColor(r, g, b, a)` sets state (there's that state machine); `gl.Clear(gl.COLOR_BUFFER_BIT)` actually paints the back buffer with it. We're choosing a deep sea blue:

```odin
gl.ClearColor(0.04, 0.10, 0.18, 1.0)
```

Why such dark numbers? Because right now our pipeline is *not gamma-corrected*: the values we write are sent raw to a display that interprets them non-linearly. In Chapter 16 we'll do this honestly (work in linear light, convert at the end), and a lot of colors will need re-tuning. Until then we pick values that *look* right on screen and keep them in one obvious place. Consider this the course's first foreshadowing: **color is a pipeline, not a number.** ([learnopengl: Gamma Correction](https://learnopengl.com/Advanced-Lighting/Gamma-Correction) if you can't wait.)

### The viewport and resizing

GL needs to know what rectangle of the window it maps NDC coordinates onto: `gl.Viewport(0, 0, width_px, height_px)`. Set it once at startup *and* every time the framebuffer changes size — via a GLFW callback. Note "framebuffer size", not "window size": on HiDPI displays they differ (a 1280×720 window can be a 2560×1440 framebuffer).

### Delta time

The loop runs as fast as vsync allows, which varies per machine. Anything that moves must move in *units per second*, scaled by the time the last frame took:

```text
dt = now - last_time      // seconds, ~0.0166 at 60Hz
position += velocity * dt
```

`glfw.GetTime()` returns seconds as `f64` since GLFW init — the only clock we'll need for a long while.

## Odin notes

**The `proc "c"` gotcha — read this twice.** GLFW is a C library; callbacks you hand it must use the C calling convention: `proc "c" (…)`. A `proc "c"` has **no Odin context** — no allocator, no logger. Inside one you cannot call anything that needs `context` (like `fmt.println`) unless you first restore one:

```odin
import "base:runtime"

some_callback :: proc "c" (...) {
	context = runtime.default_context() // now context-using calls are legal
	fmt.println("resized!")
}
```

Raw GL calls are themselves `proc "c"` (they're driver pointers), so calling `gl.Viewport` inside a callback is fine without that line. Because callbacks also can't capture locals, anything they need to share with `main` goes in package-level globals — or you skip callbacks entirely and poll. We'll use both, deliberately, over the next chapters.

## Build

1. **Load GL and set the viewport.** In `main`, right after `glfw.MakeContextCurrent(window)`:

   ```odin
   import gl "vendor:OpenGL"

   	gl.load_up_to(3, 3, glfw.gl_set_proc_address)

   	fb_width, fb_height := glfw.GetFramebufferSize(window)
   	gl.Viewport(0, 0, fb_width, fb_height)
   ```

2. **Handle resizes.** Above `main`, add the callback, and register it after window creation:

   ```odin
   framebuffer_size_callback :: proc "c" (window: glfw.WindowHandle, width, height: i32) {
   	gl.Viewport(0, 0, width, height)
   }
   ```

   ```odin
   	glfw.SetFramebufferSizeCallback(window, framebuffer_size_callback)
   ```

3. **Vsync.** One line, after `MakeContextCurrent`:

   ```odin
   	glfw.SwapInterval(1)
   ```

4. **The loop itself.** Replace the Chapter 1 skeleton with the full heartbeat:

   ```odin
   	gl.ClearColor(0.04, 0.10, 0.18, 1.0) // deep sea blue — re-tuned in ch16

   	last_time := glfw.GetTime()
   	for !glfw.WindowShouldClose(window) {
   		now := glfw.GetTime()
   		dt := f32(now - last_time)
   		last_time = now
   		_ = dt // unused this chapter; everything moves with it from ch4 on

   		glfw.PollEvents()
   		if glfw.GetKey(window, glfw.KEY_ESCAPE) == glfw.PRESS {
   			glfw.SetWindowShouldClose(window, true)
   		}

   		gl.Clear(gl.COLOR_BUFFER_BIT)
   		// ← every visible thing in Saltwind will be drawn here

   		glfw.SwapBuffers(window)
   	}
   ```

   Note the shape: *poll input → update → clear → draw → swap*. That ordering survives all 52 chapters.

5. Run it. Deep blue. Press ESC. Gone.

## Checkpoint

A calm, even, dark sea-blue window. Nothing moves, but the program is now a live loop redrawing ~60 times per second.

- Resize the window, including maximizing: blue fills the whole client area at all times, no stretching artifacts, no white borders.
- ESC closes the window; so does the ✕ button.
- Check CPU usage in your task manager: with vsync on it should be near zero — the swap blocks until the monitor is ready.
- Temporarily print `dt` once per second-ish: values around 0.016–0.017 on a 60 Hz display confirm vsync.

## Pitfalls

- **Instant crash (nil pointer) on the first `gl.` call?** `load_up_to` is missing, or runs before `MakeContextCurrent`. It must be: make current → load → everything else.
- **Black window instead of blue?** You called `gl.ClearColor` but not `gl.Clear`, or you cleared *after* `SwapBuffers`. ClearColor sets state; Clear does work.
- **Crash inside the resize callback?** You called a context-needing proc (e.g. `fmt.println`) in a `proc "c"` without `context = runtime.default_context()` first.
- **Window content lags or smears while resizing on Windows?** Normal — most drivers block the loop during the OS resize drag. The callback still fires; content is correct the moment you release.
- **`SetWindowShouldClose` type error?** It takes a `b32`; passing literal `true` is fine, passing an `int` is not.

## Exercises

1. Animate the clear color: `gl.ClearColor(0.04, 0.10, 0.18 + 0.1 * f32(math.sin(now)), 1.0)` (import `core:math`). The sea breathes. Revert after — but you've just done your first time-driven animation.
2. Set `glfw.SwapInterval(0)` and print frames-per-second once per second (count frames, reset on the second boundary). Watch the number explode and one CPU core max out. Restore `SwapInterval(1)`.
3. **Stretch:** Add a package-level global `g_resized: bool` that the framebuffer callback sets, and have the loop print the new size when it sees the flag (then clear it). This callback-sets-flag, loop-consumes-flag pattern is exactly how we'll integrate mouse input in Chapter 9.

## Commit

```
git commit -m "ch02: render loop, GL loader, sea-blue clear"
```

Prev: [Chapter 1 — The Shoreline Ahead](ch01-the-shoreline-ahead.md) · Next: [Chapter 3 — First Triangle](ch03-first-triangle.md)
