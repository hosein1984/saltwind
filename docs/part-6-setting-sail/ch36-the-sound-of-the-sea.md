# Chapter 36 — The Sound of the Sea *(optional)*

*Part 6 — Setting Sail · Estimated time: 2h · learnopengl: no direct equivalent — this is engine/game material*

> **This chapter is optional.** Saltwind's remaining chapters never depend on audio. Skip to [Chapter 37](ch37-milestone-maiden-voyage.md) freely and return whenever you want your ocean to murmur. If you're skipping: the one idea worth stealing anyway is *parameter-driven ambience* — game state modulating loop volumes — which applies to any engine system.

**What you'll see when done:** nothing — but close your eyes: waves lapping louder as you descend toward the water, wind rising with the `Wind` struct, and a gull crying somewhere off your port bow, *actually off your port bow*.

## Where we are

Saltwind is mute. `vendor:miniaudio` ships with Odin — the excellent single-header C audio engine, pre-bound — so for about 150 lines you get an ambience that does more for immersion than most rendering features. We stay deliberately modest: three loops, occasional gulls, no mixer graphs.

## Concepts

### miniaudio's high-level engine

miniaudio has layers; we use only the top one: `engine` (owns the device, the mixer, a resource manager) and `sound` (one playing instance). The flow is C-flavored: zero the struct, init it through a pointer, check a `result` enum, uninit when done. Two ways to play:

- **Fire-and-forget:** `engine_play_sound(&engine, "path.wav", nil)` — loads, plays, cleans up. Perfect for one-shot gull cries; no handle to manage.
- **Managed `sound`:** init once, keep the struct, then `sound_start/stop`, `sound_set_volume`, `sound_set_pitch`, `sound_set_pan` at will. Required for loops you'll modulate every frame.

Sounds are configured with flags at init. The Odin binding turns the C flag mask into a proper bit_set — `{.STREAM, .LOOPING}` streams from disk (right for minute-long ambience loops; decoding fully into memory is `{.DECODE}`, right for short effects) and loops forever.

### Spatialization for one gull

miniaudio has a built-in 3D spatializer: give the engine's *listener* a position/direction each frame, give a sound a position, and it computes attenuation and stereo panning for you. We use it exactly once (the gull) — and disable it on the ambience loops with `.NO_SPATIALIZATION`, since "the ocean" has no position.

### Ambience is a function of game state

The design idea of the chapter: loop volumes should *derive from state you already have*, continuously, like a shader derives color. Wave loop: louder near the water and in strong wind. Wind loop: tracks `wind.strength`. That's two `sound_set_volume` calls per frame driven by two lerps — laughably cheap, surprisingly alive.

### Where to get sounds

[freesound.org](https://freesound.org) — filter by **CC0**. You want: a seamless ocean-waves loop (search "ocean loop", 30 s+), a wind loop, and 2–3 short seagull cries. Formats: miniaudio decodes **WAV, FLAC, and MP3** natively — convert anything else (notably OGG/Vorbis, which stock miniaudio does *not* decode) or just download WAVs. Drop them in `assets/audio/`.

## Odin notes

The binding lives at [`vendor:miniaudio`](https://pkg.odin-lang.org/vendor/miniaudio/) with the `ma_` prefix stripped: C's `ma_engine_init` is `ma.engine_init`. Types are C-style lowercase (`ma.engine`, `ma.sound`, `ma.result`). File paths are `cstring` — string literals convert implicitly; runtime-built paths need `strings.clone_to_cstring` (and a `delete`). On Windows, no extra linker flags — the vendor library handles it.

## Build

1. **Define `Audio`** in `src/audio.odin`:

   ```odin
   import ma "vendor:miniaudio"

   Audio :: struct {
       engine:     ma.engine,
       waves, wind: ma.sound,
       gull:       ma.sound,
       gull_timer: f32,
       ok:         bool,
   }
   ```

2. **Init the engine and loops.** Note the early-out: if audio fails (no device, missing files), Saltwind sails on silently — never let sound crash a graphics project:

   ```odin
   audio_init :: proc(a: ^Audio) {
       if ma.engine_init(nil, &a.engine) != .SUCCESS do return

       load_loop :: proc(e: ^ma.engine, s: ^ma.sound, path: cstring) -> bool {
           if ma.sound_init_from_file(e, path,
               {.STREAM, .LOOPING, .NO_SPATIALIZATION}, nil, nil, s) != .SUCCESS {
               return false
           }
           ma.sound_set_volume(s, 0.0)        // fade in from update
           ma.sound_start(s)
           return true
       }
       if !load_loop(&a.engine, &a.waves, "assets/audio/ocean_loop.wav") do return
       if !load_loop(&a.engine, &a.wind,  "assets/audio/wind_loop.wav")  do return

       // gull: managed (so we can position it), decoded (it's short), started manually
       if ma.sound_init_from_file(&a.engine, "assets/audio/gull1.wav",
           {.DECODE}, nil, nil, &a.gull) != .SUCCESS do return

       a.gull_timer = 8.0
       a.ok = true
   }
   ```

   `nil` config to `engine_init` means sane defaults (device, sample rate, autostart). Write the matching `audio_destroy`: `ma.sound_uninit` each sound, then `ma.engine_uninit` — order matters, sounds first.

3. **Drive the ambience** from `game_animate` (it's presentation, render-rate is fine):

   ```odin
   audio_update :: proc(a: ^Audio, g: ^Game, dt: f32) {
       if !a.ok do return
       wind01 := clamp(g.wind.strength / 14.0, 0.0, 1.0)

       // waves: loud at the waterline, fading with camera height; wind whips them up
       height01 := clamp(1.0 - (g.camera.position.y - 1.5) / 50.0, 0.0, 1.0)
       ma.sound_set_volume(&a.waves, (0.25 + 0.55*height01) * (0.5 + 0.5*wind01))

       ma.sound_set_volume(&a.wind, 0.15 + 0.65 * wind01)
       ma.sound_set_pitch(&a.wind, 0.9 + 0.25 * wind01)   // stronger wind sounds *faster*

       audio_update_listener(a, g)
       audio_update_gulls(a, g, dt)
   }
   ```

   The pitch nudge on the wind loop is the cheapest trick in audio: same sample, audibly "more wind".

4. **Listener follows the camera** — required for the gull's 3D panning to mean anything:

   ```odin
   audio_update_listener :: proc(a: ^Audio, g: ^Game) {
       p := g.camera.position
       f := camera_forward(g.camera)        // you've had this since ch9
       ma.engine_listener_set_position(&a.engine, 0, p.x, p.y, p.z)
       ma.engine_listener_set_direction(&a.engine, 0, f.x, f.y, f.z)
   }
   ```

   (Listener index 0 — engines support up to 4 for splitscreen; we have one set of ears.)

5. **Random gulls, positioned in the world:**

   ```odin
   audio_update_gulls :: proc(a: ^Audio, g: ^Game, dt: f32) {
       a.gull_timer -= dt
       if a.gull_timer > 0 do return
       a.gull_timer = rand.float32_range(7.0, 22.0)

       angle := rand.float32_range(0, math.TAU)
       d     := rand.float32_range(15.0, 60.0)
       p     := g.boat.position + glsl.vec3{math.cos(angle)*d, rand.float32_range(8, 25), math.sin(angle)*d}

       ma.sound_set_position(&a.gull, p.x, p.y, p.z)
       ma.sound_seek_to_pcm_frame(&a.gull, 0)     // rewind — stop doesn't rewind
       ma.sound_set_pitch(&a.gull, rand.float32_range(0.9, 1.15))  // cheap variety
       ma.sound_start(&a.gull)
   }
   ```

   Spatialized sounds default to sensible distance attenuation; if the gull is too quiet at 60 m, pull `ma.sound_set_max_distance`/`ma.sound_set_rolloff` levers later.

6. **Wire it in:** `audio_init` after window/GL setup, `audio_update` in `game_animate`, `audio_destroy` at shutdown. Add a mute toggle (M) that calls `ma.engine_set_volume(&a.engine, 0.0 or 1.0)` — you *will* want it while debugging shaders to the same 30 seconds of gull.

## Checkpoint

Stand on the (virtual) deck: waves and wind in proportion. Now verify with your ears.

- Fly straight up 60 m: waves fade to a distant wash; wind remains. Descend to the surface: waves swell back.
- Set `wind.strength` to 2, then 13 (debug keys): both loops and the wind's pitch respond immediately.
- Wait for a gull with headphones on: it's audibly on one side, and *which* side matches where the camera faces.
- Quit the program: clean exit, no audio-thread hang (destroy order right).

## Pitfalls

- **`engine_init` succeeds but silence.** Sounds were inited but never `sound_start`ed (sounds do *not* autostart), or volume is still the 0.0 you set before the first update ran.
- **A loop "pops" at the seam.** Your WAV isn't a seamless loop — fix the asset (crossfade its ends in Audacity), not the code.
- **The gull plays once, never again.** `sound_stop`/end-of-sound doesn't rewind; without `sound_seek_to_pcm_frame(&snd, 0)` a finished sound restarts from its end (i.e., instantly finishes).
- **OGG files fail to load.** Stock miniaudio decodes WAV/FLAC/MP3 only. Convert; don't fight it.
- **Crash on exit.** You uninit'd the engine before the sounds, or destroyed `Audio` while it lived on the stack of an exited scope — keep it in `Game`.
- **Panning sounds wrong/inverted.** Listener direction not updated (everything pans as if you face +Z forever) — step 4 must run every frame, after the camera settles.

## Exercises

1. Add a third loop: rigging creaks, volume tied to `abs(boat.roll)` plus `boat.speed`. Three state-driven loops layer into something that genuinely sounds like sailing.
2. Load three gull samples and pick randomly per cry — with the pitch jitter, ~9 effective variations from three files.
3. Duck the ambience (halve wave/wind volume over ~0.5 s, restore after) while a gull cries — a poor man's mixer side-chain, and you have `smooth_damp` lying around for exactly this.
4. **Stretch:** positional *wave* audio — once per second, find the nearest shoreline point (terrain height ≈ 0) within 80 m and park a looping surf sound there with `sound_set_position`. Approaching a beach now *sounds* like approaching a beach.

## Commit

`git commit -m "ch36: miniaudio ambience - waves, wind, positional gulls"`

← [Chapter 35 — A Place for Everything](ch35-a-place-for-everything.md) · [Chapter 37 — Milestone: Maiden Voyage](ch37-milestone-maiden-voyage.md) →
