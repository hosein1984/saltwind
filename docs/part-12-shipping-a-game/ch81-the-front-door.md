# Chapter 81 — The Front Door

*Part 12 — Shipping a Game · Estimated time: 6h · learnopengl: no direct equivalent — this is UX carpentry*

**What you'll see when done:** launch the exe and the camera drifts past a palm-lined headland at golden hour while "SALTWIND — Set Sail / Continue / Options / Quit" floats over your own ocean; rebind every key, plug in a gamepad mid-game, and quit through an "unsold cargo aboard — really?" prompt that fades to black like it means it.

## Where we are

Right now your game boots into the middle of itself — fine for the developer, disorienting for everyone else. Menus are where players form their first opinion *and* the last thing most hobby projects build, which is why so many demos feel like demos. None of today is hard; all of it is the difference between "program" and "game."

## Concepts

### The cheapest beautiful menu in games

AAA studios learned this decades ago: the best main-menu background is *the game itself*, camera on rails. You own a renderer that produces postcard frames on demand — pointing it at an island and slowly orbiting costs nothing and instantly outclasses any static image. It also pulls triple duty: it's a soak test (the menu runs your whole pipeline), a mood-setter, and free marketing footage (ch84's trailer opens with it). The implementation is a camera path plus your existing `Game_Mode` machinery: `.Menu` is just a mode where the camera ignores the boat and the UI draws big buttons.

### Settings that apply *live*

The options screen is a thin UI over ch80's `Settings` struct, with one rule: **every change applies immediately and persists immediately.** Apply-buttons and restart-required dialogs are admissions of architectural debt — and you genuinely don't have that debt: resolution is `glfw.SetWindowSize`/`SetWindowMonitor` plus your existing framebuffer-resize path (every render target in `Renderer` already rebuilds on resize since ch40 — that investment pays out *here*), vsync is `glfw.SwapInterval`, volumes are one setter each (ch82 formalizes the buses). Write `settings_apply(g, old, new)` that diffs and applies, then `settings_write` — both called from the options UI's edit points.

### Rebinding: the ch10 investment pays again

Because ch10 routed *all* input through `ACTION_KEYS: [Action]i32`, rebinding is data editing: the table stops being a constant, loads from `Settings.keybinds`, and the options screen edits it. The one new pattern is **capture mode**: click an action's row → the row reads "press a key…" → the next key pressed becomes the binding. Plus two pieces of hygiene: Escape cancels capture (so Escape itself stays bindable only deliberately), and conflicts are resolved by *swapping* — if you bind Anchor to M and M was Chart, Chart takes Anchor's old key. Swap beats both silent duplicates (two actions, one key, chaos) and hard rejection (player has to find the conflict themselves).

### Gamepad through the same funnel

GLFW's gamepad API (verified against the Odin binding): `glfw.JoystickPresent(glfw.JOYSTICK_1)` and `glfw.JoystickIsGamepad(jid)` to detect, then per frame `glfw.GetGamepadState(jid, &state)` filling a `glfw.GamepadState{ buttons: [15]u8, axes: [6]f32 }`, indexed by `glfw.GAMEPAD_BUTTON_A`, `glfw.GAMEPAD_AXIS_LEFT_X`, etc. — already mapped through GLFW's SDL-style database, so an Xbox pad and a DualShock land on the same logical layout. The architecture move: the pad feeds the *same* `Input` struct as the keyboard. `input_poll` ORs pad buttons into `down[action]` and writes the analog sticks into the `rudder`/`trim` intents that ch33's sailing already consumes — analog rudder, incidentally, makes the boat feel *wonderful*, arguably better than keys. No system downstream of `Input` knows a gamepad exists. That's the whole point of the abstraction, paying for the third time (debug UI gating was the second).

### The polish trio

Three details that register as production quality far beyond their cost: **fade transitions** (a fullscreen black quad with animated alpha over every mode change — 20 lines, total tonal transformation), **consequence-aware confirmation** ("Quit" is instant when docked-and-saved, but warns "Cargo aboard since last save" when quitting would lose progress — the *conditionality* is what reads as care), and **cursor memory** (reopening any menu restores the last-selected item — keyboard/gamepad navigation feels precognitive).

## Odin notes

Gamepad buttons in the Odin binding are `[15]u8` with values `glfw.PRESS`/`glfw.RELEASE` (1/0) — compare against `glfw.PRESS`, don't truth-test the byte, and remember `GetGamepadState` returns `b32` false when the pad vanished mid-frame (cable yanked): guard the read. Axes are `[6]f32` in −1..1 with real-world noise around 0 — apply a radial deadzone (`if abs(v) < 0.15 do v = 0`, then rescale the live range to 0..1, or diagonals feel notchy). And `glfw.SetJoystickCallback` fires with `glfw.CONNECTED`/`DISCONNECTED` events — connection is the *one* gamepad thing better done by callback than polling.

## Build

1. **The rails.** A handful of hand-placed waypoints orbiting your favorite island, Catmull-Rom-interpolated (you have spline math from the wake/cloth chapters; if not, lerp between points with smoothstep — at this speed nobody can tell), camera looking at the headland, 60-second loop. In `.Menu` mode, `game_animate` advances the rail and the boat sits moored somewhere photogenic in frame. Set time-of-day to your ch44 golden hour. Done: the most beautiful menu you've ever shipped, for ~40 lines.

2. **Menu screens as a tiny stack.** One enum + array — a full UI framework would be procrastination:

   ```odin
   Menu_Screen :: enum { None, Main, Pause, Options, Keybinds, Confirm_Quit }

   Menu :: struct {
       screen:   Menu_Screen,
       selected: [Menu_Screen]int,   // cursor memory per screen — the polish trio
       capture_action: Maybe(Action),
       fade:     f32,                // 0 = clear, 1 = black
       fade_to:  Game_Mode,
   }
   ```

   Draw with the ch78 widgets, sized up: `ui_button` already does hover/click; add keyboard/gamepad focus by drawing the `selected` row highlighted and moving it with Up/Down/dpad, activating with Enter/A. Mouse hover *sets* `selected` so the two input styles never fight. Escape in `.Sailing` opens `Pause` (it stops being raw Quit — update `ACTION_KEYS`); Escape in a menu goes back one screen.

3. **Fades.** `menu.fade` eases toward a target; mode changes route through `game_fade_to(g, mode)` which fades to 1, calls `game_set_mode`, fades back. Render as the *last* UI quad, full-screen black with `alpha = fade`. Boot sequence: start at `fade = 1` in `.Menu` and ease in — the game now *opens* rather than *appears*.

4. **Options screen** — rows over `Settings`, applying live:

   ```odin
   if ui_row_toggle(g, "VSync", &new.vsync) {
       glfw.SwapInterval(new.vsync ? 1 : 0)
   }
   if ui_row_options(g, "Resolution", RESOLUTIONS[:], &res_index) {
       new.width, new.height = RESOLUTIONS[res_index].w, RESOLUTIONS[res_index].h
       glfw.SetWindowSize(g.window, i32(new.width), i32(new.height))
       // framebuffer-size callback -> renderer_resize: ch40 handles the rest
   }
   ui_row_slider(g, "Master volume", &new.volume_master, 0, 1)  // ch82 consumes
   if new != g.settings { settings_apply(g, g.settings, new); g.settings = new; settings_write(g) }
   ```

   Fullscreen toggles via `glfw.SetWindowMonitor` with `glfw.GetPrimaryMonitor()` and the desktop video mode (`glfw.GetVideoMode`) — remember to stash the windowed position/size for the way back. Mute (evicted from M in ch79) lives here now.

5. **Keybinds screen.** Each row: action name, current key (`glfw.GetKeyName` for printables; a small lookup table for the rest), and capture-on-click:

   ```odin
   if cap, capturing := g.menu.capture_action.?; capturing {
       if key := input_last_key_pressed(g); key != 0 {
           if key != glfw.KEY_ESCAPE {
               for other in Action {                       // conflict -> swap
                   if g.keybinds[other] == key do g.keybinds[other] = g.keybinds[cap]
               }
               g.keybinds[cap] = key
               settings_write(g)
           }
           g.menu.capture_action = nil
       }
   }
   ```

   `input_last_key_pressed` needs the GLFW key callback to stash the most recent press — one global, harvested like ch9's mouse globals. While capturing, `input_poll` must *not* translate keys to actions (one early-out). Add a "Restore defaults" button; testers always find a way to need it.

6. **Gamepad in `input_poll`,** after the keyboard pass:

   ```odin
   if glfw.JoystickPresent(glfw.JOYSTICK_1) && glfw.JoystickIsGamepad(glfw.JOYSTICK_1) {
       state: glfw.GamepadState
       if glfw.GetGamepadState(glfw.JOYSTICK_1, &state) {
           dz :: proc(v: f32) -> f32 { return abs(v) < 0.15 ? 0 : (v - math.sign(v)*0.15) / 0.85 }
           input.rudder_analog = dz(state.axes[glfw.GAMEPAD_AXIS_LEFT_X])
           input.trim_analog   = dz(state.axes[glfw.GAMEPAD_AXIS_RIGHT_Y])
           pad_or :: proc(input: ^Input, a: Action, pressed: bool) {
           	was := input.down[a]
           	input.down[a] |= pressed
           	input.pressed[a] |= pressed && !was
           }
           pad_or(input, .Anchor, state.buttons[glfw.GAMEPAD_BUTTON_A] == glfw.PRESS)
           pad_or(input, .Chart,  state.buttons[glfw.GAMEPAD_BUTTON_Y] == glfw.PRESS)
           pad_or(input, .Pause,  state.buttons[glfw.GAMEPAD_BUTTON_START] == glfw.PRESS)
       }
   }
   ```

   In `boat_update_sailing`, analog rudder (when nonzero) overrides the digital intent. Menu navigation reads dpad through the same `pad_or` trick on `Move_*` actions. Don't build pad *rebinding* — the GLFW mapping layer already standardized the layout, and the cut list (ch77) applies to UX too.

7. **Confirm-quit with a conscience.** Track `g.dirty_since_save` (set by trades/contract changes, cleared by `save_write`). Quit and Exit-to-menu route through `Confirm_Quit` *only when dirty*, with the message naming the stakes: `"You have cargo and 2 active contracts unsaved. Dock to save. Quit anyway?"` Specific beats generic — it teaches the save model while it warns.

8. **Wire the boot path:** settings → window → `.Menu` mode with fade-in → "Continue" enabled only if `save_read` would succeed (`os.exists` on the slot — cheap check, honest button states). "Set Sail" = `game_new` + fade; "Continue" = `save_read` + fade. Test the whole flow with the exe double-clicked from Explorer, not from your shell — ch51's lesson, recurring.

## Checkpoint

Saltwind has a front door, and walking through it feels intentional.

- Cold boot: fade from black into the orbiting island; no boat controls leak into the menu; Continue is grayed out until a save exists.
- Change resolution and vsync mid-game with the sea visible: instant, no restart, no stretched framebuffers (watch bloom/SSR for one frame of wrong-size artifacts — if present, a target missed the ch40 resize path).
- Rebind Anchor to M: Chart swaps to E automatically, both rows update, `settings.json` shows the change, and it survives relaunch.
- Unplug the gamepad mid-sail: boat reverts to keyboard intent without a twitch; replug: analog rudder resumes (connection callback logged).
- Quit with unsold cargo: named warning. Dock, then quit: no warning. The difference *is* the feature.

## Pitfalls

- **The menu world runs the full sim and the boat drifts away over 10 minutes idle.** Either moor the boat (zero wind force in `.Menu`) or embrace it as ambiance — but decide; testers leave games on menus for hours and screenshot what they find. (ch83's soak test will thank you either way.)
- **Resolution change breaks every render target.** Some FBO was created at boot size and never registered with `renderer_resize`. The grep is `render_target_create` — every call site either re-runs on resize or has a comment explaining why it's resolution-independent (the ch79 chart bake is; the SSAO buffer is not).
- **Capture mode captures itself.** Click "rebind" with Enter focused and Enter immediately becomes the binding. Consume the activating press (skip capture for one frame) — every UI programmer learns this one the same way.
- **Deadzone applied per-axis makes diagonals sticky;** no rescale after deadzone makes the first 15% of stick dead weight. Radial-ish deadzone + rescale, as in step 6.
- **Settings written every frame.** `if new != g.settings` is doing real work in step 4 — without it you're hammering the disk at 144 Hz (and Odin's struct equality makes the guard one line; use it).
- **The fade hides a hitch instead of masking a transition.** If fading to `.Sailing` from a load stutters, the load is synchronous under the fade — acceptable! — but *hold* the black until the first real frame is ready, or the player sees one frame of last-mode garbage. Fade out, do work, render once, fade in.

## Exercises

1. Menu rail variety: three rails (different islands/times of day), one chosen per boot from the world seed + date. Returning players get a subtly different welcome.
2. An options "Reset to defaults" that fades the *settings* — animate sliders gliding back. Pure theater, ten lines, weirdly delightful.
3. Gamepad glyphs: when the last input device was a pad, button hints render "Ⓐ Anchor" instead of "E — Anchor" (track `last_device` in `Input`; the glyphs are four more BMFont private-use characters, per ch79 ex. 1).
4. **Stretch:** a photo-sensitive pause — `.Pause` keeps rendering the world *unpaused in the background* behind a blurred panel (one extra blur pass you own from ch41), while simulation actually pauses. Compare with a hard-frozen backdrop and pick a side; write the sentence defending it in `design/`.

## Commit

`git commit -m "ch81: main menu on rails, options + live settings, key rebinding, gamepad, fades"`

← [Chapter 80 — Letters in a Bottle](ch80-letters-in-a-bottle.md) · [Chapter 82 — The Ship's Orchestra](ch82-the-ships-orchestra.md) →
