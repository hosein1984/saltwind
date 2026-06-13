# Chapter 82 — The Ship's Orchestra

*Part 12 — Shipping a Game · Estimated time: 4h · learnopengl: no direct equivalent — this one's for your ears*

**What you'll see when done:** nothing, again — but cast off from port and the harbor theme hands over to the open-sea strings mid-phrase without a seam; thunder cracks and the music politely steps back for two seconds; selling cargo clinks like it's worth something.

## Where we are

Ch36 gave Saltwind an ambient *soundscape* — waves, wind, gulls, all derived from game state. What a shipped game adds is a *mix*: grouped volume control (because ch81's three sliders need something real to move), music that follows the game's emotional state, and the dozens of tiny one-shots that make a UI feel manufactured rather than improvised.

> **Skipped ch36?** Catch up in twenty minutes, you only need its skeleton: an `Audio` struct holding a `ma.engine` (init once, uninit at shutdown, every call checked against `.SUCCESS` and failing *silent*, never fatal), looping sounds via `ma.sound_init_from_file` with `{.STREAM, .LOOPING, .NO_SPATIALIZATION}` + `ma.sound_start`, per-frame `ma.sound_set_volume` driven by game state, and `audio_update` called from `game_animate`. Build that minimal version (ch36 steps 1–3), skip the gulls, return here. Everything below stacks on it.

## Concepts

### Buses are just groups (verified against the binding)

A mixing bus — one knob governing a family of sounds — is the organizing idea of game audio. miniaudio models it directly, and the Odin vendor binding carries the full API: `ma.sound_group` is a node in the engine's mix graph, created with `ma.sound_group_init(engine, flags, parent_group, &group)`. The fourth-from-last parameter of `ma.sound_init_from_file` (which ch36 passed as `nil`) is exactly this: the group the sound routes through. Groups nest — pass a parent group to `sound_group_init` — so the textbook topology costs four calls:

```
                    engine endpoint (device)
                          │
                       [master]          <- Settings.volume_master
                  ┌───────┼────────┐
              [music] [ambience] [sfx]   <- the other ch81 sliders
               stems   ch36 loops  one-shots
```

`ma.sound_group_set_volume(&bus, v)` moves a whole family at once. And should you ever meet a binding (or another library) without groups, the honest fallback is manual gain multiplication — `final = sound_gain * bus_gain * master_gain`, applied in your own update loop. It's what groups do internally; you'd just be doing the multiplication yourself, once per sound per frame. We have groups; we use groups — but knowing the fallback demystifies them.

### Music as horizontal layers

Vertical scoring = stack instrument layers of one piece; horizontal = swap between pieces by state. Saltwind wants horizontal: four stems — **port**, **calm sea**, **open sea**, **storm** — mapped from state you already simulate (`Game_Mode` + wind strength + ch47/74 weather). The craft is in the joins:

- **Beat-agnostic crossfades.** Synchronizing to musical bars requires authored stems and tempo metadata — scope creep wearing headphones. Instead: all stems loop simultaneously from boot, *one* audible at a time, transitions done by fading volumes over ~4 seconds. Long fades forgive everything; nobody hears that the storm theme entered on beat 3.
- **Equal-power, not linear.** Two linear ramps crossing at 0.5 dip audibly in the middle (your ear hears amplitude as power). Fade with `sqrt(t)` / `sqrt(1−t)` — constant perceived loudness through the join. This is the one DSP fact in the chapter; it's also the difference between "crossfade" and "something wrong with the speakers."

### Ducking

When something important sounds (thunder, the contract-complete sting), the music *ducks* — drops several dB fast, recovers slow. Real mixers do this with side-chain compression; a game can fake it perfectly with an envelope on the music bus: on trigger, snap a `duck` target to 0.3, ease it back to 1.0 over ~2 s, multiply into the bus volume. Players never notice ducking exists; they notice thunder *feels louder* — which was the point.

### Sourcing music, and the license ledger

You need four loopable stems (1–2 minutes each). The honest sources: **Kevin MacLeod (incompetech.com)** — enormous catalog, CC-BY 4.0, exactly credit-and-go; the **Free Music Archive** (filter by license); **freesound.org** for one-shots (prefer CC0). The hygiene that separates shippers from infringers, one paragraph, non-negotiable: *the moment* an external asset enters `assets/`, its attribution line enters `CREDITS.txt` — author, title, source URL, license, and any modification ("trimmed, looped"). CC-BY without attribution is infringement, not a vibe. The file ships in the zip (ch84 checks), and a `credits` button in ch81's menu reads it straight from disk — one `os.read_entire_file`, instant good citizenship. Do it per-asset as you download; reconstructing provenance the night before release is a punishment you can simply not assign yourself.

## Odin notes

`ma.sound_set_fade_in_milliseconds(&snd, vol_begin, vol_end, ms)` runs the fade on the audio thread — smoother than per-frame `set_volume` from a 60 Hz game loop, and it has one lovely convention: pass `-1` as `vol_begin` to mean "from wherever the volume currently is," which makes *interrupted* crossfades (storm hits mid-fade to calm) correct for free. Groups have the same proc (`ma.sound_group_set_fade_in_milliseconds`). Use the engine-time fades for music; keep per-frame `set_volume` for the state-derived ambience loops, where continuous control *is* the feature.

## Build

1. **The bus rack,** extending ch36's `Audio`:

   ```odin
   Audio_Bus :: enum { Master, Music, Ambience, Sfx }

   Audio :: struct {
       engine: ma.engine,
       buses:  [Audio_Bus]ma.sound_group,
       // ... ch36 fields (waves, wind, gull) ...
       stems:      [Music_Stem]ma.sound,
       active_stem: Music_Stem,
       duck:        f32,   // 1 = no duck; eases back up
       ok: bool,
   }

   audio_init_buses :: proc(a: ^Audio) -> bool {
       if ma.sound_group_init(&a.engine, {}, nil, &a.buses[.Master]) != .SUCCESS do return false
       for bus in Audio_Bus do if bus != .Master {
           if ma.sound_group_init(&a.engine, {}, &a.buses[.Master], &a.buses[bus]) != .SUCCESS do return false
       }
       return true
   }
   ```

   Re-route ch36's loops by replacing their `nil` group argument with `&a.buses[.Ambience]`. Shutdown order grows one layer: sounds, then child groups, then master, then engine (`ma.sound_group_uninit` for each — leaves before branches, as ever).

2. **Wire ch81's sliders.** In `settings_apply` (or each frame if you prefer brute simplicity):

   ```odin
   ma.sound_group_set_volume(&a.buses[.Master],   g.settings.volume_master)
   ma.sound_group_set_volume(&a.buses[.Music],    g.settings.volume_music * a.duck)
   ma.sound_group_set_volume(&a.buses[.Sfx],      g.settings.volume_sfx)
   ma.sound_group_set_volume(&a.buses[.Ambience], g.settings.volume_sfx)  // or its own slider
   ```

   The old M-key mute becomes `volume_master = 0` through the same path — one volume model, no special cases. (Music gets per-frame attention anyway because of `duck`; that line lives in `audio_update`.)

3. **Load the stems,** all looping, all started, all silent but one:

   ```odin
   Music_Stem :: enum { Port, Calm, Open, Storm }
   STEM_FILES := [Music_Stem]cstring{
       .Port  = "assets/audio/music_port.mp3",
       .Calm  = "assets/audio/music_calm.mp3",
       .Open  = "assets/audio/music_open.mp3",
       .Storm = "assets/audio/music_storm.mp3",
   }
   for stem in Music_Stem {
       if ma.sound_init_from_file(&a.engine, STEM_FILES[stem],
           {.STREAM, .LOOPING, .NO_SPATIALIZATION}, &a.buses[.Music], nil,
           &a.stems[stem]) != .SUCCESS do return
       ma.sound_set_volume(&a.stems[stem], stem == .Calm ? 1.0 : 0.0)
       ma.sound_start(&a.stems[stem])
   }
   ```

   Four simultaneous streaming decodes is trivial load (they're idle reads when silent), and "everything always playing" is what makes transitions a pure volume problem.

4. **The stem selector + equal-power crossfade,** in `audio_update`:

   ```odin
   target := music_stem_for_state(g)   // .Docked->Port; storm? ->Storm; wind>8 ->Open; else Calm
   if target != a.active_stem {
       FADE_MS :: 4000
       // -1 begin volume = "from current" -> interrupted fades stay smooth
       ma.sound_set_fade_in_milliseconds(&a.stems[a.active_stem], -1, 0, FADE_MS)
       ma.sound_set_fade_in_milliseconds(&a.stems[target],        -1, 1, FADE_MS)
       a.active_stem = target
   }
   ```

   Where's the `sqrt`? Inside miniaudio's fader the ramp is linear, so approximate equal-power by *overlapping generously*: the 4-second crossfade keeps combined energy close enough that ears forgive it. If you want the textbook curve, drive both volumes per-frame yourself with `sqrt(t)`/`sqrt(1-t)` over the transition — 12 lines, exercise 1 makes you compare. Add a 2-second hysteresis on `music_stem_for_state` (the wind flutters across thresholds; the music must not).

5. **Ducking.** Trigger points: ch74's thunder, contract completion, the first dock of a session:

   ```odin
   audio_duck :: proc(a: ^Audio, depth: f32 = 0.3) { a.duck = min(a.duck, depth) }

   // in audio_update, every frame:
   a.duck = min(1.0, a.duck + dt * 0.4)            // ~2 s recovery
   ma.sound_group_set_volume(&a.buses[.Music], g.settings.volume_music * a.duck)
   ```

   Thunder already knows its moment (ch74 computes the flash-to-rumble delay); one `audio_duck(a, 0.25)` beside the thunder one-shot and the storm suddenly has *authority*.

6. **The one-shot polish pass.** Fire-and-forget through the SFX bus — `ma.engine_play_sound(&a.engine, path, &a.buses[.Sfx])` — wrapped once so call sites stay tidy:

   | Moment | Sound | Where it hooks |
   |---|---|---|
   | UI hover / click | soft tick / tock | `ui_button` (one line, covers every menu) |
   | Buy / sell | coin clink | `trade` in ch78 |
   | Contract accepted | paper + stamp | contract panel |
   | Contract complete | short sting (2–3 s) + duck | the ch78 payout |
   | Anchor drop / raise | chain + splash | `game_set_mode` transitions |
   | Save written | quill scratch | `save_write` |

   Source these CC0 from freesound; pitch-jitter the frequent ones (`ma.sound_set_pitch` needs a managed sound — for clicks, the ch36 gull pattern: one managed sound, rewind, jitter, start). The whole table is an afternoon and it's the afternoon players will *feel* most.

7. **CREDITS.txt,** as a build step, not an intention: create it now with every asset already in the repo (the BMFont's font license too — check it), add the ch81 menu button that displays it, and add a line to your release script (ch51's `build_release.bat`) that **fails the build if `CREDITS.txt` is missing from `dist/`**. Enforcement beats memory.

## Checkpoint

Close your eyes through one full loop — port, cast off, open water, storm, return — and the music narrates it.

- Sit at the dock: port theme. Cast off: 4-second handover to calm-sea, no loudness dip you can hear (if there's a hole in the middle, your fade is linear and short — lengthen or curve it).
- Trigger a storm from the debug panel mid-crossfade: the interrupted fade redirects smoothly (the `-1` begin-volume at work), and thunder ducks the music — audible as the *storm* feeling big, not the music acting weird.
- Drag ch81's music slider to zero: stems silent, ambience and SFX untouched; master to zero: everything (bus hierarchy verified by ear).
- Sell ten cargo units fast: ten clinks, no stutter, no voice cap weirdness; quit: clean exit (uninit order still right — groups after sounds, engine last).

## Pitfalls

- **Stems drift out of phase... is not a thing here** — but *thinking* it is leads people to stop/start stems on transitions, which produces genuine pops and restart-from-zero weirdness. Everything plays always; volume is the only knob touched per transition. (Phase alignment matters for *vertical* layering of one piece — not our design.)
- **The crossfade dips in the middle.** Linear fades crossing at 0.5 — the one DSP fact, ignored. Longer overlap or sqrt curves.
- **Music flip-flops at a weather boundary.** No hysteresis on the state→stem mapping; the wind oscillates across 8.0 and your soundtrack develops a stutter. Two-second commitment minimum, longer is safer.
- **Clicks louder than cannon fire.** One-shots normalized at the DAW's mercy. Pick a reference (the wave loop at the waterline), audition every new asset against it, and bake per-asset gain into your one-shot wrapper table rather than editing files.
- **A CC-BY track with no attribution shipped.** Not a code bug; the only one in this list with legal mail attached. The build-script check in step 7 exists because everyone forgets once.
- **Audio init failure crashes the menu.** A machine with no output device (true of more streaming/VM setups than you'd think) must boot fine and play mute — ch36's `ok` early-out pattern now has to guard *every* new call site too. Grep for `a.engine` outside `audio_*` procs; there should be none.

## Exercises

1. Implement the per-frame `sqrt` equal-power crossfade alongside the engine-fade version, switchable in the debug panel; A/B them with eyes closed. Keep the winner and delete the loser (deleting is the skill).
2. Sea-state intensity layer: a percussion-only stem that fades in *vertically* over calm/open by wave height (one piece of vertical scoring after all — note it needs stems from the same track at the same tempo, which is why MacLeod's multi-version tracks help).
3. Interior muffling: when `.Docked` with the trade screen open, low-pass the ambience (miniaudio's node graph has filters — check what the binding exposes; honest fallback: fade ambience to 0.4, which reads as "indoors" anyway).
4. **Stretch:** a debug "mixer" panel — microui sliders for every bus and stem volume live, plus a VU-ish readout via `ma.sound_get_current_fade_volume`. You'll tune the whole mix in one session with it, which is the argument for tools in miniature.

## Commit

`git commit -m "ch82: audio buses, horizontal music stems, ducking, one-shot pass, CREDITS.txt"`

← [Chapter 81 — The Front Door](ch81-the-front-door.md) · [Chapter 83 — Min-Spec & the Art of Not Crashing](ch83-min-spec-and-the-art-of-not-crashing.md) →
