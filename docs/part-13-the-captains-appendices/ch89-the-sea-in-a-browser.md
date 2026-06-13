# Chapter 89 — The Sea in a Browser

*Part 13 — The Captain's Appendices · Standalone: requires Part 12 (specifically ch83's fallback ladder) · Estimated time: 10–14h · learnopengl: no direct equivalent — canonical references: the [Odin packages docs](https://pkg.odin-lang.org) for `vendor:wasm/WebGL` and `core:sys/wasm/js`, and MDN's [WebGL2 documentation](https://developer.mozilla.org/en-US/docs/Web/API/WebGL2RenderingContext)*

**What you'll see when done:** a URL. You paste it in chat, someone on another continent clicks it, and thirty seconds later they're sailing your sea in a browser tab — no download, no installer, no trust required.

## Where we are

This appendix needs Part 12 — not for the menus or the save system, but because **ch83's quality ladder is the entire porting spec**. The day you kept the Gerstner ocean, the 2D cloud layer, and the planar-reflection rung alive behind clean seams, you accidentally wrote a WebGL2 renderer; today you compile it. Honest scope up front: this is a *renderer and gameplay port*, not all of Saltwind. WebGL2 is roughly GL ES 3.0, which is roughly your GL 3.3 path minus a few conveniences and **minus compute entirely** — no FFT ocean, no volumetric clouds, no Part 10/limb-of-Part 11 showpieces. What ships is the ch83 Low preset: Gerstner sea, procedural sky, the islands, the boat, the trading loop. That is a complete, beautiful game — ch83 made you defend it, and now strangers will play it.

A warning before the fun: this chapter touches the fastest-moving corner of Odin. Package paths here were verified against current docs (`core:sys/wasm/js` for browser interop — older material calls it `vendor:wasm/js`, its pre-move home — and `vendor:wasm/WebGL` for GL); if something doesn't resolve, **check the current Odin docs and the package sources before fighting your code.**

## Concepts

### The target: `js_wasm32`

`odin build src -target:js_wasm32 -out:web/saltwind.wasm` produces a WebAssembly module instead of an executable. Three consequences define the whole port:

1. **There is no OS.** No `core:os` file IO, no window, no GL context creation by you. The browser owns all of it, and you reach it through JavaScript.
2. **There is no main loop.** A wasm module that loops forever freezes the tab. The browser calls *you*, once per display refresh.
3. **There are no threads** (by default — wasm threads need SharedArrayBuffer, special headers, and Odin-side support; treat them as out of scope and check current docs if you're curious). Your single-threaded core course code is fine; anything from Part 15 stays home.

### The glue: odin.js and the inverted loop

Odin ships the JavaScript runtime for this target at `core/sys/wasm/js/odin.js` (~2,300 lines — worth skimming; it's the other half of your program). It instantiates the module, wires up memory, provides every foreign import that `core:sys/wasm/js` and `vendor:wasm/WebGL` declare — including a complete WebGL 1+2 interface — and then drives a `requestAnimationFrame` loop that calls your exported step procedure each frame. Your `main` still runs, once, at load: it becomes pure initialization. The loop body moves into:

```odin
@(export)
step :: proc(dt: f32) -> (keep_going: bool) {
    game_frame(&g_game, dt)        // your ch10 accumulator lives happily inside
    return true
}
```

(The exact `step` signature has changed across Odin versions — the authoritative source is the rAF callback near the bottom of the odin.js you copied. Read it; it's ten lines.) Note what this means architecturally: globals. The desktop build keeps everything on `main`'s stack; the wasm build needs `g_game: Game` at file scope because `main` returns before the first frame. The cleanest shape — and a genuinely good refactor even for desktop — is `game_init / game_frame / game_shutdown` procs, with each platform's entry point calling them its own way.

### GL through `vendor:wasm/WebGL`

The package mirrors your GL calls with WebGL names: `gl.CreateBuffer()` instead of `GenBuffers`, `gl.BufferDataSlice(...)`, `gl.UniformMatrix4fv(loc, m)` — note that last one: **no count, no transpose flag**; the JS side hardcodes `transpose = false`, so your column-major `glsl.mat4` flows through unchanged. Context creation is two verified calls: `webgl.SetCurrentContextById("saltwind-canvas")` (tries WebGL2, falls back to 1) or `CreateCurrentContextById` with explicit attributes, then `webgl.IsWebGL2Supported()` / `webgl.GetESVersion(&major, &minor)` to fill your ch83 caps struct. `CreateProgramFromStrings` compiles a shader program in one call — convenient, since your shaders are about to become strings.

### Shaders: `#version 300 es`

GLSL ES 3.00 is close enough to desktop GLSL 330 that the port is mechanical: change the version line, and add **precision qualifiers** — mandatory in every fragment shader (`precision highp float;` after the version line; add `precision highp sampler2DShadow;` etc. as the compiler demands). Things that don't exist: compute (already excluded), `layout(binding = ...)` on samplers (set texture units with `Uniform1i` like your 3.3 path always did), and a handful of desktop-isms the compiler will name for you one at a time. One capability *check* you must add: rendering to floating-point textures — your entire HDR pipeline — is gated behind the `EXT_color_buffer_float` extension. It's near-universally supported, but query it (`IsExtensionSupported`, then `GetExtension` to enable), and let ch83's ladder fall back to an LDR pipeline if it's somehow absent.

### Assets without files

No `core:os` means `shader_load("assets/shaders/pbr.frag")` cannot open anything. Two honest options:

- **`#load` (use this):** Odin's compile-time embed — `PBR_FRAG :: #load("../assets/shaders/pbr.frag", string)` bakes the bytes into the wasm module. Build a small manifest (`WEB_ASSETS := map[string][]u8{...}` or a switch proc) and route your existing `asset_read` seam through it `when ODIN_OS == .JS`. Textures and models embed the same way as `[]u8`, decoded in memory — `core:image/png` is pure Odin and works on wasm without ceremony (check current docs before relying on `vendor:stb/image` here; vendored C on wasm has worked for some libraries via precompiled objects, but pure Odin can't break).
- **JS `fetch`:** stream assets on demand with custom glue. Real web games do this (a 200 MB wasm file is rude); it needs async plumbing that this chapter doesn't. Exercise 3 points the way.

### Input: the browser knocks

No GLFW. `core:sys/wasm/js` delivers DOM events to Odin callbacks — verified names: `js.add_window_event_listener(.Key_Down, nil, on_key_down)`, with an `Event_Kind` enum covering `.Key_Up`, `.Mouse_Move`, `.Mouse_Down`, `.Wheel`, `.Resize`, `.Pointer_Lock_Change`, even `.Gamepad_Connected` (and `js.get_gamepad_state` for ch81's gamepad support — the browser does the driver work). The event struct carries `e.key.code` (a string: `"KeyW"`), `e.mouse.movement`, `e.mouse.client`, modifier bools. Your job is a thin adapter writing into the same ch10 input state the GLFW callbacks write — the architecture chapter pays for itself one last time. Mouse-look needs the **Pointer Lock API**; there's no wrapper proc for *requesting* it in the package as of this writing, so use `js.evaluate("document.getElementById('saltwind-canvas').requestPointerLock()")` on click, and listen for `.Pointer_Lock_Change` (check current docs — small wrappers like this get added).

> **Sidebar — audio.** `vendor:miniaudio` binds a C library built for native backends; it does not target wasm. Browser audio is the WebAudio API, which means JS glue: either a custom foreign-import shim (the `js.evaluate` hammer works for crude one-shots: `js.evaluate("snd_gull.play()")` against `<audio>` tags in your HTML) or a silent build. Ship silent first — it's honest, and the sea is still beautiful muted. A real WebAudio bridge is exercise 4's stretch territory.

## Odin notes

Platform seams via `when`, not build tags — `ODIN_OS` is `.JS` on this target:

```odin
when ODIN_OS == .JS {
    // canvas sizing: CSS pixels × devicePixelRatio = real pixels
    rect := js.get_bounding_client_rect("saltwind-canvas")
    dpr  := js.device_pixel_ratio()
    w, h := i32(rect.width * dpr), i32(rect.height * dpr)
} else {
    w, h := glfw.GetFramebufferSize(window)
}
```

Two memory notes: the default heap on this target is backed by the package's page allocator growing wasm memory (`js.page_allocator()` exists if you need it directly), and `fmt.println` lands in the browser console — your ch83 logging works, redirected by the glue for free. Time: `time.now()` is not your friend on a target without an OS clock convention; your loop already gets `dt` handed to it, and that's the only clock the game needs.

## Build

1. **Extract the platform seam.** Refactor `main.odin` into `game_init/game_frame/game_shutdown` plus per-platform entries (`main_desktop.odin`, `main_web.odin` with `when ODIN_OS == .JS` guards). Desktop must still build and run identically after this step — verify before touching the web half.

2. **The web shell.** A `web/` folder: `index.html` with `<canvas id="saltwind-canvas">`, a copy of `odin.js` from your Odin install (`<odin-root>/core/sys/wasm/js/odin.js`), and a loader script:

   ```html
   <script src="odin.js"></script>
   <script>
     odin.runWasm("saltwind.wasm");
   </script>
   ```

   (Verify the entry call against the odin.js you copied — the API surface is the bottom of the file.)

3. **Context + caps.** In `main_web.odin`: `SetCurrentContextById`, assert `IsWebGL2Supported()`, query `EXT_color_buffer_float`, then fill the ch83 caps struct: `has_compute = false`, `gl_version = 3.3-ish`, preset forced to the Gerstner rung. The ladder does the rest — *that's the chapter's thesis executing*.

4. **Compile and triage.** `odin build src -target:js_wasm32 -out:web/saltwind.wasm`. The error list is your to-do list: every `core:os` call, every GLFW call, every `vendor:OpenGL` symbol outside the seam. Route each through the platform layer. This step is most of the hours; it's also where you discover every place you cheated on the seams, which is the port's real gift to the codebase.

5. **Shaders to ES.** Add a tiny preamble-injection to your shader loader: on web, replace `#version 330 core`/`430 core` with `#version 300 es` + precision block. Convert the Low-preset shader set only (the ladder already excludes the rest). Compile errors arrive one shader at a time via `GetShaderInfoLog` in the console — mechanical, oddly soothing.

6. **Embed assets.** The `#load` manifest from Concepts. Mind texture orientation: your stb path flipped images on load; `core:image` won't — flip rows at decode (or flip the UVs once, but you won't).

7. **Input adapter.** Event listeners → ch10 input state; pointer lock on canvas click; `.Resize` → recreate render targets (your ch40/85 resize machinery, fed by `get_bounding_client_rect` × `device_pixel_ratio`).

8. **Serve and sail.** Browsers won't fetch wasm from `file://` — run any static server (`python -m http.server` in `web/`) and open `http://localhost:8000`. First goal: clear color. Then the sky. Then the sea. Work up your own course's history — it's a strangely moving way to debug.

9. **Ship the URL.** Zip `web/` and upload to itch.io as an HTML5 project (set viewport dimensions, "click to run"), or push to GitHub Pages. No cross-origin-isolation headers needed — you have no threads. Send the link to the friend from ch83's playtest. Watch the message that comes back.

## Checkpoint

Someone who is not you sails Saltwind in a browser you've never touched.

- Desktop build still runs identically from the same tree (one codebase, two platforms — the seam held).
- The browser tab holds ~60 fps on the Gerstner rung; the console shows your ch83 log lines, and zero GL errors.
- Refresh mid-game: it boots clean every time (no leaked state — there's nowhere for it to leak *to*).
- WASD + pointer-locked mouse + a gamepad all steer the boat.
- The wasm file is under ~25 MB with embedded Low-preset assets — a courteous click.

## Pitfalls

- **Black canvas, no errors.** The context grabbed by id failed silently (typo'd canvas id, or odin.js loaded after your loader script ran). `SetCurrentContextById` returns a bool — you checked it, right?
- **`step` never runs / runs once.** Your `main` never returned (you ported the `for !should_close` loop — delete it; the browser is the loop), or `step` isn't exported, or the signature doesn't match what odin.js looks up. Read the bottom of odin.js.
- **Every framebuffer incomplete.** RGBA16F attachments without `EXT_color_buffer_float` enabled — query *and call GetExtension* (querying alone doesn't enable it in WebGL).
- **Shaders compile on your machine, fail on a phone.** Missing precision qualifiers default differently across drivers — desktop Chrome forgives, mobile doesn't. `precision highp float;` in every fragment shader, no exceptions.
- **Textures upside down.** The stb flip convention didn't make the trip (step 6). One flag, three hours, every porter pays it once.
- **Works locally, dead on itch.** Paths: the wasm/odin.js URLs are relative to the embed page, not your zip root. Keep everything flat in one folder and use relative `src`s.
- **It's all slower than you expected.** You're benchmarking through a debug build — `-o:speed` on the wasm build too. And remember the browser composites your canvas; close the 40-tab session before judging frame times.

## Exercises

1. **Seed in the URL:** read `?seed=1234` at boot (`js.evaluate` writing into a known DOM element, or a tiny custom import — check current docs for a location wrapper) so every shared link is a *specific* archipelago. Shared seeds turn your friends into cartographers.
2. **Touch the sea:** map `.Touch_Start`/`.Touch_Move` events to rudder and sail trim — two vertical strips of the screen as virtual sliders. Phone-playable is another whole audience for zero new rendering work.
3. **Streamed assets:** move textures out of `#load` into `fetch` via custom JS glue — show the ch37 compass as a loading screen while they arrive. Compare cold-load times; feel the 200 ms wasm parse you'd been hiding.
4. **Stretch — a WebAudio shim:** four foreign procs (`audio_play`, `audio_loop`, `audio_gain`, `audio_stop`) implemented in 30 lines of JS against decoded buffers, wired to ch36's call sites. The gulls return.

## Commit

`git commit -m "ch89: wasm/webgl2 port - js_wasm32 target, inverted main loop, #load assets, the ladder pays off"`

[← Ch. 88: Charts of the Modern World](ch88-charts-of-the-modern-world.md) · [Ch. 90: Light Remembered →](ch90-light-remembered.md)
