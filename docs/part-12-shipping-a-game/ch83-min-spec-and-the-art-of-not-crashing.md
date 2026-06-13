# Chapter 83 — Min-Spec & the Art of Not Crashing

*Part 12 — Shipping a Game · Estimated time: 5h · learnopengl: no direct equivalent — this is the unglamorous craft that ships*

**What you'll see when done:** Saltwind booting on a 2014 laptop with Intel graphics — Gerstner waves instead of FFT, a flat cloud layer instead of volumetrics, 40 fps, *playable* — and a `saltwind.log` that would tell you exactly why, if anyone asked.

## Where we are

Everything so far ran on one machine: yours. The moment ch84 puts a zip on the internet, your game runs on machines you've never imagined — integrated GPUs, ancient drivers, laptops that report OpenGL 4.1, Windows installs with no audio device. The difference between a project and a product is what happens *there*. Today is defense in depth: detect, degrade, log, and never, ever crash on someone else's hardware without leaving a note.

## Concepts

### Capability detection: ask, don't assume

Part 9 raised the context to 4.3 *with a fallback plan* — today the plan comes due. The strategy has two layers:

1. **Context negotiation.** Request 4.3 core; if `glfw.CreateWindow` returns nil, lower the hint and try 3.3 (the core course's whole renderer ran on 3.3 — it never stopped working). The result is a single struct of truth, filled once, read everywhere.
2. **Capability queries** inside whatever context you got: `gl.GetIntegerv` for `MAJOR_VERSION`/`MINOR_VERSION`, `MAX_TEXTURE_SIZE`, `MAX_3D_TEXTURE_SIZE`; compute limits only when ≥4.3. Plus the two identity strings — `gl.GetString(gl.RENDERER)` and `gl.VENDOR)` — which you don't branch on (never sniff vendor strings for behavior) but *always log*, because every bug report you'll ever get starts with them.

### The graceful ladder

Here is the payoff of a course rule you may not have noticed being a rule: **we never deleted a working system.** Each rung of the ladder is code that still exists in your repo, behind the seams you already built:

| Missing | Fallback | Where the seam already is |
|---|---|---|
| GL 4.3 / compute | **Gerstner ocean (ch28)** — `ocean_height_at` was the API both backends honor (ch65 kept it) | the ocean's update/sample interface |
| Compute clouds (ch69) | 2D cloud layer + ch47 atmospheric fog | sky pass composition |
| Interactive ripples (ch67) | none — pure garnish, omit silently | additive blend into the ocean |
| SSR (ch58) | planar reflection (ch30) ⊕ IBL — the ch58 fallback chain, now load-bearing | reflection resolve |
| High shadow budget | fewer cascades (ch57 → ch39's single map at the floor) | shadow pass setup |

The deep lesson, worth saying plainly: *fallbacks aren't extra work if you never threw away the simpler thing.* Your git history is a quality ladder. The chapters were the rungs.

### Quality presets: capability ≠ preference

Two separate axes. Capability is what the machine *can* do (detected, hard limits); quality is what the player *wants* (chosen, soft budget). A preset is a row in a table — and after ch77 you know exactly what that means in Odin:

```odin
Quality :: enum { Low, Medium, High }
Quality_Preset :: struct {
    reflection_res:  i32,
    shadow_cascades: int,
    shadow_res:      i32,
    particle_cap:    int,
    cloud_steps:     int,    // 0 = 2D layer
    ssr:             bool,
    ocean_fft:       bool,   // capability may veto; preset may decline
}
PRESETS := [Quality]Quality_Preset{
    .Low    = { 256, 1, 1024,  500,  0, false, false},
    .Medium = { 512, 3, 2048, 2000, 48, true,  true},
    .High   = {1024, 4, 4096, 8000, 96, true,  true},
}
```

The effective config is `min(capability, preference)` — a preset can ask for FFT, but no compute means no FFT regardless. Default preset on first run: pick by a crude heuristic (compute support + `MAX_TEXTURE_SIZE` ≥ 16384 → Medium, else Low) and let the player promote themselves in ch81's options.

### Crash-proofing: every load returns `ok`, every failure has a face

The policy, stated once and enforced by grep: **no asset load may panic.** Every `*_load` returns `(thing, ok)`; every call site either handles `!ok` or passes through a fallback. And fallbacks should be *visible in dev, survivable in prod*: the *magenta texture* (a 4×4 `0xFF00FF` checker — screams in screenshots, renders fine), the *unit cube* (any mesh that fails loads as a cube — the game looks wrong and works), the *silent sound* (ch36/82 already fail mute). Ship the fallbacks in the exe (a few bytes of generated data, not files — the fallback for "file missing" cannot be a file). When a player reports "my boat is a pink cube," you'll know it's a paths problem from the description alone. That's the fallback doing its second job: diagnosis at a distance.

### Asserts, panics, and a shipped game

Odin's `assert` is for *programmer errors* — invariants that, if false, mean the code is wrong (`assert(cascade_count <= 4)`). Content and environment problems (missing file, no audio device, weird GPU) are *expected conditions* and get `ok` returns + logs, never asserts. Release builds compile with `-disable-assert` (ch51's script already does) — which means an assert must never guard against something that *can actually happen in the field*, because in the field it won't be there. Odin has no exceptions to catch and no `recover` to lean on; the discipline is the design: errors as values on every path a stranger's machine can reach. (Leave `panic` for corruption-grade impossibilities — a panic with a good message beats silent memory corruption, and your log file will carry the message home.)

### Driver folklore: the "works on NVIDIA, black on Intel" checklist

GPU drivers differ most exactly where the spec says "undefined." NVIDIA is famously permissive — code that *happens* to work there meets the spec for the first time on Intel/AMD. The classics, each one a real shipped bug somewhere:

- **Missing barriers.** Compute writes read without `gl.MemoryBarrier` (image/SSBO bits) — NVIDIA's scheduler often hides it; Intel shows you stale zeros. Audit every dispatch→consume edge (ch61 taught the bits; ch63's FFT ping-pong is the high-risk zone).
- **Uninitialized FBO reads.** Sampling a target before its first clear is undefined — black, garbage, or *last frame's data* depending on vendor. Clear every attachment once at creation.
- **Unclamped/driver-unrolled loops.** A raymarch whose count comes from a uniform with no compile-time bound can compile pathologically or wrong on stricter compilers — clamp loop counts with constants (`min(u_steps, 128)`).
- **`texelFetch`/array out-of-bounds** "working" (returning zero) on one vendor, garbage on another. Bounds are yours to enforce.
- **Behavior differences in what the spec leaves loose** — point sprite sizes, line widths > 1, `gl_FragDepth` performance cliffs. If a feature note says "implementation-defined," believe it.

You can't test all hardware; you *can* run RenderDoc (ch53) with a skeptic's eye, fix every `glDebugMessageCallback` warning (not just errors), and then —

### The friend-test protocol

Two people, not ten. The zip from your release script, no verbal instructions beyond "tell me what you see." You watch (screen-share or over-the-shoulder), you say *nothing*, you take notes with timestamps. What you are testing is not the renderer — it's the **first ten minutes**: Did it launch? Did they find the dock? Did the trade screen explain itself? Did they take a second contract (ch77's "done when")? Every place they flounder is a fix, ranked by how early it happens — a confusing minute one outranks a crash in hour two, because nobody who quits at minute one ever finds the crash. Fix the top three, send build two. *This* loop, run twice, improves a game more than any feature.

## Odin notes

Logging to a file is `core:log`: build a `log.Logger` with `log.create_file_logger(...)` over a file you've opened for writing, assign it to `context.logger` at the top of `main`, and every `log.infof`/`log.errorf` in the codebase (you've been accumulating them since ch80) routes there with timestamps and source locations. One verification note in the spirit of this course: the file-logger's parameter type has changed across Odin versions as `core:os` modernized (an `os.Handle` historically; a `^os.File` on current master) — open `<odin>/core/log/file_console_logger.odin` and match what *your* release declares; the three-line wrapper below is the only code that touches it. In debug builds, keep the console logger too; `log.create_multi_logger`-style fan-out exists, but two builds with one logger each is simpler and fine.

## Build

1. **Context negotiation,** replacing the fixed hints from ch53:

   ```odin
   GL_Caps :: struct {
       major, minor:     int,
       has_compute:      bool,    // >= 4.3
       max_texture_size: i32,
       renderer, vendor: string,  // logged verbatim, never branched on
   }

   window_create_best :: proc() -> (win: glfw.WindowHandle, caps: GL_Caps) {
       try := [?][2]i32{{4, 3}, {3, 3}}
       for v in try {
           glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, v[0])
           glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, v[1])
           glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
           if win = glfw.CreateWindow(1280, 720, "Saltwind", nil, nil); win != nil {
               caps.major, caps.minor = int(v[0]), int(v[1])
               caps.has_compute = v[0] > 4 || (v[0] == 4 && v[1] >= 3)
               return
           }
           log.warnf("GL %d.%d context refused, stepping down", v[0], v[1])
       }
       return nil, {}   // main shows a message box / stderr and exits politely
   }
   ```

   After `MakeContextCurrent` + loader: fill `max_texture_size` (`gl.GetIntegerv(gl.MAX_TEXTURE_SIZE, &caps.max_texture_size)`), clone the `gl.GetString` results, and **log the whole struct first thing** — the opening lines of every `saltwind.log` are the machine's confession.

2. **The log file,** before anything can fail:

   ```odin
   main :: proc() {
       logfile, ferr := os.open("saltwind.log", os.O_WRONLY | os.O_CREATE | os.O_TRUNC, 0o644)
       if ferr == nil {
           context.logger = log.create_file_logger(logfile)   // see Odin notes re: param type
       } else {
           context.logger = log.create_console_logger()       // can't write? still log
       }
       log.infof("Saltwind starting, version %s", GAME_VERSION)  // ch84 stamps this
       ...
   ```

   Truncate-on-start keeps it one-session-sized; exercise 2 rotates. From here on, the rule: every `return false`/`ok=false` path in the codebase logs *why* before returning. A silent failure on your machine is a mystery on someone else's. (And remember ch51: with `-subsystem:windows` there *is* no console — in release, this file is the only witness.)

3. **Thread the ladder.** Make backend choice explicit and logged:

   ```odin
   ocean_init :: proc(g: ^Game) {
       want_fft := PRESETS[g.settings.quality].ocean_fft && g.caps.has_compute
       if want_fft {
           if ocean_fft_init(&g.ocean) { log.info("ocean: FFT (compute)"); return }
           log.warn("ocean: FFT init failed, falling back")   // failure != lack of support
       }
       ocean_gerstner_init(&g.ocean)
       log.info("ocean: Gerstner (GL 3.3 path)")
   }
   ```

   Same shape for clouds (`cloud_steps == 0 || !has_compute` → the 2D layer: a scrolling noise-textured dome quad you can build in an hour from ch26/47 parts — it needs to *exist*, not compete) and SSR (→ ch30 planar ⊕ IBL, the ch58 chain's lower rungs). Buoyancy already works on both oceans because ch65 preserved the `ocean_height_at` contract — verify by sailing each path.

4. **Wire presets** into `Settings` (a `quality: Quality` field — version bump, migration case, you know the drill) and the ch81 options screen. Preset changes rebuild the affected targets through the ch40/81 resize machinery; cascade/particle/step counts are uniforms or caps read per frame. Then the test that matters: **force Low + 3.3 on your own machine** (a `-define` or env var that lies about caps) and *play a full contract loop*. Low isn't a punishment build; it's somebody's whole experience of your game. Make it one you'd defend.

5. **Fallback assets,** generated at startup, owned by the loader:

   ```odin
   assets_init_fallbacks :: proc(a: ^Assets) {
       px: [16]u32
       for i in 0 ..< 16 do px[i] = (i % 2 == (i / 4) % 2) ? 0xFFFF00FF : 0xFF000000
       a.fallback_texture = texture_from_memory(raw_data(px[:]), 4, 4)  // magenta check
       a.fallback_mesh    = mesh_unit_cube()                            // ch11 still earning
   }

   texture_load :: proc(a: ^Assets, path: string) -> Texture {
       tex, ok := texture_load_file(path)
       if !ok { log.errorf("texture missing: %s — using fallback", path); return a.fallback_texture }
       return tex
   }
   ```

   Sweep every loader behind this pattern (textures, meshes, shaders — a failed shader *compile* falls back to the last good binary if hot-reload kept one, else a flat-color "error shader"; sounds already fail silent). Then prove it: rename `assets/textures/` and launch. The correct result is a fully magenta, fully *playable* archipelago and a log that lists every missing file. That screenshot is your crash-proofing certificate — keep it.

6. **The driver audit, two hours, with RenderDoc open:** every `MemoryBarrier` edge in chs 61–67 checked against what's read after it; every FBO attachment cleared at creation; every shader loop bounded by a constant; the `glDebugMessageCallback` output (ch53) at zero *warnings*, not zero errors. Fix or file each finding. You're hunting bugs you cannot see on your own GPU — the checklist is the only flashlight you get.

7. **Run the friend test.** Two people, the protocol above, notes with timestamps. Then do the hard part: fix the top three stumbles *before* adding anything. (If both testers failed to find the dock — the single most common result for this genre — your fixes live in ch78's prompt radius, ch79's chart legibility, or a first-contract tutorial hint drawn with one `ui_text`. Cheap fixes, massive effect.)

## Checkpoint

Saltwind degrades like a professional and confesses like a friend.

- Force the 3.3 path: Gerstner sea, 2D clouds, planar reflections — and a complete, playable, *saved-compatible* game (saves carry no renderer state; ch80's audit pays off).
- `saltwind.log` from a clean run reads as a boot story: version, GPU strings, GL version, ocean/cloud/SSR backend choices, settings loaded, save loaded. A stranger's log should diagnose a stranger's machine.
- Rename the assets folder: magenta world, zero crashes, every missing file logged once.
- Two humans have played the zip while you stayed silent, and three of their stumbles are fixed in the log (git log, this time).

## Pitfalls

- **Testing fallbacks only by code review.** The Gerstner path "obviously still works" — until you actually run it and the ch64 foam uniforms it never heard of are NaN. Fallback paths rot unless *executed*; the force-low define from step 4 belongs in your pre-release ritual (ch84 checklists it).
- **Capability checks scattered at point of use.** `if caps.has_compute` in fourteen files means the fifteenth forgets. Decide each backend *once* at init (step 3), store the choice, branch on the choice.
- **The log file that grows forever** — truncate-on-start (or rotate, exercise 2); a 2 GB log is a bug report nobody can email you.
- **Magenta shipping to players.** The fallback's job is to survive *and be reported* — in release builds, count fallback activations and surface "some assets failed to load — see saltwind.log" once on the HUD. Silent magenta means players think it's art direction. Some will say they like it.
- **Treating the friend test as QA.** You're not collecting bugs; you're watching comprehension fail in real time. If you explain *anything* during the session, you've patched the player instead of the game — and the next player ships without the patch.
- **Vendor-sniffing your way around a driver bug.** `if vendor == "Intel"` is a curse on your future. Find the spec violation (it's almost always yours — see the checklist), fix the actual UB; if it's genuinely a driver bug, work around it for *everyone* (the workaround is spec-legal by construction).

## Exercises

1. A `--safe-mode` flag (or `-define`): forces Low + 3.3 + windowed + audio off. The first thing you'll ask a player with a black screen to try; build it before you need it.
2. Log rotation: keep `saltwind.log` and `saltwind.prev.log` (rename before truncate). The bug that only happens on second launch sends its regards.
3. An `F1` "system info" overlay: caps struct, active backends, preset, frame time, version — everything a bug reporter needs, screenshotable. Add "press F1 and screenshot it" to your known-issues template (ch84).
4. **Stretch:** a startup self-test mode (`--diag`) that creates every render target at every preset, compiles every shader, loads every asset manifest entry, and exits 0/1 with a full log — your release script (ch84) runs it against the dist folder so a broken zip can't leave the building.

## Commit

`git commit -m "ch83: capability ladder, quality presets, asset fallbacks, file logging, friend test"`

← [Chapter 82 — The Ship's Orchestra](ch82-the-ships-orchestra.md) · [Chapter 84 — Finale: Flotilla](ch84-finale-flotilla.md) →
