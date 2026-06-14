# Chapter 1 — The Shoreline Ahead

*Part 1 — First Light · Estimated time: 2h · learnopengl: [Creating a window](https://learnopengl.com/Getting-started/Creating-a-window)*

**What you'll see when done:** a real OS window, 1280×720, titled "Saltwind", holding an OpenGL 3.3 core context — the empty harbor where everything else will be built.

## Where we are

Nowhere yet. That's the point. Fifty-two chapters from now this window will hold a procedural archipelago at golden hour — Gerstner waves, shadow-mapped islands, bloom on the sun, a boat answering its rudder. Today it holds nothing, and getting to "nothing, on purpose, under your control" is genuinely the first engineering problem of any graphics project.

If you haven't read the [course overview](../00-COURSE-OVERVIEW.md), do it now — it explains the rules (every chapter ends with something visible; you write all the code; milestones are sacred) and the conventions every chapter assumes.

## Concepts

### How OpenGL actually works in 2026

You did OpenGL years ago. Here's the refresher on what's actually happening, because everything in this course hangs off this mental model.

**The GPU is a separate computer.** Your Odin code runs on the CPU. The GPU is a massively parallel coprocessor with its own memory, optimized for doing the same small operation to millions of items at once. OpenGL is the protocol you use to talk to it: you upload data (vertices, textures), upload tiny programs (*shaders*), set some switches, and say "draw". The GPU then pushes your data through a mostly-fixed **pipeline**:

```
 your vertex data ──► VERTEX SHADER ──► primitive assembly ──► RASTERIZER ──► FRAGMENT SHADER ──► tests & blending ──► framebuffer
 (positions, uvs…)    (your program,     (group verts into      (turn each      (your program,       (depth test,        (the pixels you
                       runs per vertex)   triangles)             triangle into    runs per pixel-     blending)           actually see)
                                                                 fragments)       candidate)
```

The two boxes in caps that say "your program" are where almost all of the visual interest in this course lives. Everything else is configuration.

**OpenGL is a state machine.** There is a big implicit context full of switches and bindings: *the* currently bound buffer, *the* current shader program, *the* clear color. Calls like `gl.BindBuffer` don't draw anything; they change what subsequent calls refer to. Most classic OpenGL bugs are state bugs — you changed a switch three calls ago and forgot. We'll build habits (and eventually abstractions) that keep state changes local and obvious.

**Driver and loader.** Your GPU vendor ships a driver that implements OpenGL. Your program doesn't link against "OpenGL" at compile time the way you link a normal library — beyond version 1.1, every GL function is a *function pointer* you must look up from the driver at runtime. The thing that does the looking-up is called a **loader** (you may remember GLAD or GLEW). Odin's `vendor:OpenGL` package *is* the loader, written in Odin — one call in Chapter 2 and every `gl.*` function works.

**Why 3.3 core?** OpenGL 3.3 core profile (2010) is the line where "modern" GL begins: no fixed-function pipeline, shaders mandatory, VAOs mandatory. It runs on essentially everything, it's what learnopengl teaches, and the concepts transfer cleanly to 4.x, Vulkan, WebGPU, and Metal. Where 4.x offers a genuinely better way (DSA, compute), chapters will flag it in a sidebar — but the baseline stays 3.3.

**Why Odin makes this pleasant.** The classic C++ OpenGL setup chore — hunting down GLFW binaries, generating a GLAD loader, fighting CMake — does not exist here. Odin *ships* with maintained bindings: `vendor:glfw` (windowing/input, with the static library included), `vendor:OpenGL` (loader + helpers), `vendor:stb/image` (textures), and `core:math/linalg/glsl` (math types that mirror GLSL). Zero downloads, zero build scripts. `odin run src` is the whole build system.

### GLFW in one paragraph

OpenGL renders pixels but knows nothing about windows, keyboards, or mice — those are OS concerns. GLFW is the thin, boring, reliable cross-platform library that creates a window, attaches a GL context to it, and feeds you input events. You'll touch maybe fifteen of its functions in the whole course.

### What is a window?

A **window** is an operating-system thing, not an OpenGL thing. On Windows, macOS, and Linux, the desktop environment owns the idea of "a rectangle on screen with a title bar, close button, size, position, focus, and input events." That rectangle can receive mouse movement, keyboard input, resize messages, minimize events, and close requests. It can also expose an area called the **client area**: the part inside the borders where an application is allowed to draw.

OpenGL does not create that rectangle. It does not know about title bars, taskbars, DPI scaling, monitors, or the close button. This is why we need GLFW. When we call:

```odin
window := glfw.CreateWindow(WINDOW_WIDTH, WINDOW_HEIGHT, "Saltwind", nil, nil)
```

we are asking GLFW to ask the operating system for a real native window. GLFW then gives us back a handle: `glfw.WindowHandle`. Treat that handle as an opaque ticket. We do not inspect its internals; we hand it back to GLFW when we want to ask questions about that window or perform window-related actions.

### What is an OpenGL context?

An **OpenGL context** is the driver's record of an OpenGL universe.

That sounds grand, but it is precise: a context owns the OpenGL state machine. It remembers things like the currently bound buffer, the current shader program, the enabled depth test, the clear color, the viewport, and eventually the GL objects you create: buffers, textures, vertex arrays, shader programs, framebuffers. When you call `gl.BindBuffer`, `gl.UseProgram`, or `gl.ClearColor`, you are not changing global reality. You are changing state inside the current OpenGL context.

The context is created by the GPU driver, but it must be created *for* some drawable surface. In Chapter 1, GLFW creates a context associated with the window's drawable area. That association gives OpenGL a default framebuffer: the color buffer that will eventually become the pixels visible in the window.

The window and the context are therefore related, but they are not the same thing:

| Thing | Owned by | Job |
|---|---|---|
| Window | Operating system, reached through GLFW | A visible rectangle, input target, resize/close events |
| OpenGL context | GPU driver, reached through OpenGL calls | The GL state machine and the doorway to GPU rendering |
| Default framebuffer | Provided through the window/context pair | The image storage that appears in the window after buffer swaps |

This distinction matters because later we will create OpenGL objects that have no window-like shape at all: textures, offscreen framebuffers, shadow maps, reflection buffers. OpenGL is not "drawing to a window" in the abstract. It is executing commands inside a current context, targeting whichever framebuffer is currently bound.

### What does `glfw.Init` do?

`glfw.Init()` starts GLFW's internal connection to the platform. Before it succeeds, GLFW is not ready to create windows, query monitors, receive input, or create OpenGL contexts.

Under the hood, the exact work depends on the operating system: loading platform backends, preparing access to the display server, initializing joystick and timer support, setting up internal bookkeeping, and getting ready to translate OS-specific messages into GLFW's cross-platform API. You do not need to memorize the platform details. The important contract is simpler:

1. Call `glfw.Init()` before almost any other GLFW function.
2. If it returns false, ask `glfw.GetError()` and stop.
3. After it succeeds, pair it with `glfw.Terminate()` when the program is done.

That last point is why the chapter immediately does this:

```odin
if !glfw.Init() {
	desc, code := glfw.GetError()
	fmt.eprintln("GLFW init failed:", code, desc)
	return
}
defer glfw.Terminate()
```

`defer` makes the lifetime visible: from this line until the end of `main`, GLFW is alive.

### What does `MakeContextCurrent` mean?

OpenGL calls do not take a `window` or `context` parameter:

```odin
gl.ClearColor(0.04, 0.10, 0.18, 1.0)
gl.Clear(gl.COLOR_BUFFER_BIT)
```

So which context do they affect?

The answer is: the OpenGL context that is **current on the calling thread**.

That is what this line does:

```odin
glfw.MakeContextCurrent(window)
```

It tells GLFW: "Take the OpenGL context associated with this window and bind it to this thread." After that, OpenGL commands issued on this thread know which driver's state machine they belong to. Without a current context, modern GL calls either cannot be loaded yet or have no valid target to operate on.

This is also why Chapter 2 will load OpenGL function pointers *after* `MakeContextCurrent`. The loader has to ask the current context's driver for addresses like "where is `glCreateShader`?" No current context means there may be no driver entry point to ask.

For a one-window game, you can almost forget the rule after you call it once. But the rule becomes important in advanced tools and engines: multiple windows, shared contexts, background loading threads, editor viewports, and offscreen render workers all have to be explicit about which context is current where. For Saltwind right now, the story is beautifully small: one window, one context, one main thread.

## Odin notes

- `vendor:glfw` returns Odin-friendly types: `glfw.Init()` returns a `b32` you can use directly in `if !glfw.Init()`, `glfw.CreateWindow` returns a `glfw.WindowHandle` that is `nil` on failure.
- Window titles and paths cross into C land as `cstring`. String literals convert implicitly, so `"Saltwind"` just works.
- `defer` is your cleanup workhorse: `defer glfw.Terminate()` right after a successful `glfw.Init()` means you can early-return anywhere without leaking.

## Build

1. **Install Odin.** Grab the latest release from [odin-lang.org](https://odin-lang.org/docs/install/) (or build from source). Verify with `odin version`. Then install [OLS](https://github.com/DanielGavin/ols) (the Odin Language Server) for your editor — you want go-to-definition into the vendor packages; reading `vendor:glfw` and `vendor:OpenGL` source is a first-class way to answer API questions all course long.

2. **Create the project.**

   ```text
   saltwind/
   ├── src/            ← all Odin code, single package
   └── assets/
       ├── shaders/    ← .vert/.frag files (from ch. 4)
       ├── textures/   ← images (from ch. 6)
       └── models/     ← meshes (from ch. 17)
   ```

   Also `git init` in `saltwind/` now — one commit per chapter is the course's progress bar.

3. **Prove the toolchain.** Create `src/main.odin`:

   ```odin
   package saltwind

   import "core:fmt"

   main :: proc() {
   	fmt.println("fair winds")
   }
   ```

   From the `saltwind/` root run `odin run src`. You should see `fair winds`. Always run from the project root — asset paths later in the course are relative to it.

4. **Open the window.** Replace `main.odin` with the real thing. Initialize GLFW first; this wakes up GLFW's platform layer so it is allowed to talk to the OS. Then — *before* creating the window — request exactly the context we want with window hints:

   ```odin
   package saltwind

   import "core:fmt"
   import "vendor:glfw"

   WINDOW_WIDTH  :: 1280
   WINDOW_HEIGHT :: 720

   main :: proc() {
   	if !glfw.Init() {
   		desc, code := glfw.GetError()
   		fmt.eprintln("GLFW init failed:", code, desc)
   		return
   	}
   	defer glfw.Terminate()

   	glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 3)
   	glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 3)
   	glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
   	when ODIN_OS == .Darwin {
   		glfw.WindowHint(glfw.OPENGL_FORWARD_COMPAT, glfw.TRUE) // macOS requires this for core
   	}

   	window := glfw.CreateWindow(WINDOW_WIDTH, WINDOW_HEIGHT, "Saltwind", nil, nil)
   	if window == nil {
   		fmt.eprintln("window or GL context creation failed")
   		return
   	}
   	defer glfw.DestroyWindow(window)

   	glfw.MakeContextCurrent(window)
   	// the GL context now exists and is bound to this thread
   }
   ```

   The hints matter: without them you get a default ("any version, compatibility-ish") context, and on some drivers your core-profile shaders in Chapter 3 would mysteriously fail. `CreateWindow` gives us both halves of the first real graphics object in the program: an OS window and a driver-created OpenGL context attached to it. `MakeContextCurrent` then selects that context for this thread. This is the state-machine pattern already: GL calls have no window parameter; they apply to whichever context is *current* on the calling thread.

5. **Keep it alive.** A window with no event loop appears for a millisecond and dies (or freezes, unresponsive, on some platforms). Add at the bottom of `main`:

   ```odin
   	for !glfw.WindowShouldClose(window) {
   		glfw.PollEvents()
   	}
   ```

   `PollEvents` processes the OS message queue — moving, resizing, the close button. `WindowShouldClose` becomes true when the user clicks ✕. That's the skeleton of every real-time application ever written.

6. Run `odin run src`. Window appears, titled **Saltwind**, and stays until you close it.

## Checkpoint

A 1280×720 window titled "Saltwind". Its contents are *undefined* — black, white, garbage, or a stale screenshot of your desktop, depending on the OS. That's expected: we never told the GPU to draw, so the framebuffer holds whatever memory it held. Chapter 2 fixes that first thing.

- Close button works, window dies cleanly, program exits with no error output.
- Drag and resize the window: no freeze (events are being polled).
- Run `odin build src -o:speed` once too — confirms a release build also works.

## Pitfalls

- **`glfw.CreateWindow` returns nil?** Print `glfw.GetError()`. Most common cause: your driver can't provide a 3.3 *core* context — almost always a remote-desktop session, a VM without GPU passthrough, or ancient drivers. Update drivers first.
- **Linker errors mentioning `glfw3` on Linux?** The vendored static lib needs system packages on some distros (X11/Wayland dev libs); install your distro's `glfw` dev package or check the note in `vendor/glfw/bindings/bindings.odin` — it can link against the system GLFW.
- **Window opens and instantly closes?** You forgot the event loop (step 5), or your `defer glfw.Terminate()` is *before* the `Init` check and you're returning early.
- **`odin run src` says "no package found"?** You're not in the `saltwind/` root, or `main.odin` isn't inside `src/`, or its first line isn't `package saltwind`.

## Exercises

1. Make the window non-resizable with `glfw.WindowHint(glfw.RESIZABLE, glfw.FALSE)`, see that resizing is refused, then remove it — Saltwind stays resizable and Chapter 2 will handle resizes properly.
2. Print the actual context version you received: after `MakeContextCurrent`, `glfw.GetWindowAttrib(window, glfw.CONTEXT_VERSION_MAJOR)` (and `_MINOR`). On some drivers you'll get 3.3 exactly; others hand you 4.6 core, which is fine — core contexts are backward compatible within reason.
3. **Stretch:** Add a `glfw.SetErrorCallback` that prints every GLFW error as it happens. Note the callback must be `proc "c"` — we'll dig into exactly what that means in Chapter 2.

## Commit

```
git commit -m "ch01: GLFW window with 3.3 core context"
```

Next: [Chapter 2 — Heartbeat](ch02-heartbeat.md)
