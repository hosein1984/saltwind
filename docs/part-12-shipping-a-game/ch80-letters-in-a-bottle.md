# Chapter 80 — Letters in a Bottle

*Part 12 — Shipping a Game · Estimated time: 4h · learnopengl: no direct equivalent — this is shipping craft*

**What you'll see when done:** quit mid-voyage with a hold full of rum, relaunch, and resume at the same swell under the same evening sky, the same coins in your purse — and your chart still remembers every league you've ever sailed.

## Where we are

The loop works; the loop also evaporates on exit. A game that forgets is a demo. Today: save/load done with shipping discipline — versioned from day one, autosaving where players expect it, and honest about Odin's serialization options instead of pretending there's one true way.

## Concepts

### What *is* the game? (The save-state audit)

The most clarifying exercise in systems programming: walk `Game` field by field and sort into three buckets.

**Save** — state that is *the player's story or the world's identity*:
gold, cargo, upgrades, active and offered contracts, the economy (every port's price multipliers, active events, and the RNG state — or, cheaper and almost as good, the economy seed plus elapsed sim time), boat position/heading/velocity, `sim_time` and time-of-day, current weather state and its timer, the **world seed** (one `u64` that *is* the archipelago — chs 21/25's gift to this chapter), the discovered mask, waypoints, and which port you're docked at.

**Regenerate** — derived data rebuilt by code you already have: terrain meshes, the chart bake, IBL captures, port tables (they're constants), the entire render state.

**Deliberately forget** — transient simulation: FFT ocean spectra (regenerated in milliseconds and visually seedless anyway), ripples, particles, wake ring buffers, cloth sail node positions, boids. Saving these would couple your save format to your most churn-prone systems for zero player-visible benefit. *The skill here is the third bucket* — juniors save everything; shippers save the story.

### Serialization in Odin: the honest comparison

**`core:encoding/json` via reflection.** `json.marshal(value)` walks any Odin type at runtime and emits JSON; `json.unmarshal(data, &value)` reverses it. Pros: ~20 lines total, human-readable saves (debugging a player's broken save by *reading it* is a shipping superpower), trivially diffable, tolerant of field additions. Cons: slower (irrelevant at our size — a Saltwind save is a few KB), allocates through reflection, and silently zeroes fields missing from old files (which we'll turn into a *feature* via defaults + migration).

**Hand-rolled binary.** A versioned header, then fields written in explicit order with `io.write_*` or straight buffer packing. Pros: compact, fast, total control, no reflection surprises. Cons: every field addition is a version bump and a migration branch *you* write; debugging means a hex editor. The right call for 100 MB open-world saves; over-engineering for ours.

We ship JSON and build binary as the Stretch — the comparison is worth having in your hands, not just your head.

### Versioning: the discipline that costs nothing today

Every save format you will ever design changes. The only question is whether version 1 planned for it. The rules, all cheap, all from day one: a `version: int` field *first* in the struct; loaders that `switch` on it and migrate forward (v1→v2→v3, chained, never v1→v3 special cases); never reuse or repurpose a field name; and defaults chosen so that a missing field (JSON's behavior for old saves) is *safe*, not garbage. Breaking old saves after release converts your warmest players — the ones with 20 hours in — into your angriest. The version field is a promise to them.

### Where files go

Two defensible answers. The *proper* one: the OS config directory — `core:os/os2` provides `os2.user_config_dir(allocator)` (on Windows it returns `%AppData%`-family paths; it takes an allocator and an optional `roaming` flag and returns `(dir, err)`). The *pragmatic* one for an itch.io zip game: an exe-relative `./saves/` directory — the whole game stays one self-contained folder, players can find/back up/delete their saves, and uninstall leaves no litter. We default to exe-relative (you already resolve exe-relative paths for assets since ch51) **with a note**: if you ever distribute through a store that installs to a write-protected location (Program Files via an installer), switch to `user_config_dir` — writes next to the exe will fail there. Wrap the decision in one proc, `save_dir()`, so the policy lives in one place.

## Odin notes

The two signatures this chapter leans on, verbatim from `core:encoding/json`:

```odin
json.marshal   :: proc(v: any, opt: json.Marshal_Options = {}, allocator := context.allocator)
                  -> (data: []u8, err: json.Marshal_Error)
json.unmarshal :: proc(data: []byte, ptr: ^$T, spec := json.DEFAULT_SPECIFICATION,
                       allocator := context.allocator) -> json.Unmarshal_Error
```

`Marshal_Options{pretty = true}` gets you indented output — always, for saves; the bytes are free and `diff` becomes a debugging tool. Unmarshal *allocates* for strings/slices inside your struct using the passed allocator — keep `Save_Data` to value types (fixed arrays, enums, ints, floats) and there's nothing to free, which is exactly how we designed ch77's tables. One more habit: `json.unmarshal` returns an error union — check it; a corrupt save must fall back to "new game," never to a half-loaded crash.

## Build

1. **Define `Save_Data`** in `src/save.odin` — a plain mirror of the audit, *not* a pointer into live `Game`:

   ```odin
   SAVE_VERSION :: 1

   Save_Data :: struct {
       version:     int,
       world_seed:  u64,
       sim_time:    f64,
       time_of_day: f32,
       gold:        int,
       cargo:       [Good_Id]int,
       upgrades:    [Upgrade_Id]int,           // tier owned, 0..3
       contracts:   [8]Contract,               // fixed slots; .state tells empties
       econ_mult:   [5][Good_Id]f32,           // per-port price multipliers
       boat_pos:    glsl.vec3,
       boat_yaw:    f32,
       weather:     Weather_Kind,
       waypoint:    glsl.vec2,
       has_waypoint: bool,
       docked_port: int,                       // -1 if at sea
   }
   ```

   Write `save_capture(g: ^Game) -> Save_Data` and `save_apply(g: ^Game, s: Save_Data)` as explicit field-by-field procs. Tedious? Slightly. But this boundary is *the* migration point, the place where "what the game persists" is readable in one screen — worth every line.

2. **Write and read:**

   ```odin
   save_write :: proc(g: ^Game, slot: string) -> bool {
       s := save_capture(g)
       data, merr := json.marshal(s, {pretty = true}, context.temp_allocator)
       if merr != nil { log.errorf("save marshal: %v", merr); return false }
       path := fmt.tprintf("%s/%s.json", save_dir(), slot)
       if !os.write_entire_file(path, data) { log.errorf("save write: %s", path); return false }
       chart_mask_write(g, slot)               // step 4
       return true
   }

   save_read :: proc(g: ^Game, slot: string) -> bool {
       path := fmt.tprintf("%s/%s.json", save_dir(), slot)
       data, ok := os.read_entire_file(path, context.temp_allocator)
       if !ok do return false
       s: Save_Data
       if err := json.unmarshal(data, &s); err != nil {
           log.errorf("save parse: %v — starting fresh", err); return false
       }
       save_migrate(&s)                        // step 3
       save_apply(g, s)
       chart_mask_read(g, slot)
       return true
   }
   ```

   `save_apply` must *regenerate* after applying: if `world_seed` differs from the running world, rebuild terrain and re-bake the chart (your ch25 pipeline already does this from a seed). Boat pose applies *after* the world exists. Order matters; write it as a numbered comment block.

3. **Migration, scaffolded now while it's trivial:**

   ```odin
   save_migrate :: proc(s: ^Save_Data) {
       switch s.version {
       case SAVE_VERSION:        // current — nothing to do
       case 0:                   // pre-versioning saves (yours, from testing today)
           s.version = 1
           // fallthrough chains go here as versions accrue:
           // case 1: s.new_field = sensible_default; s.version = 2
       case:
           log.warnf("save from the future (v%d) — loading anyway, expect defaults", s.version)
       }
   }
   ```

   The discipline: when you add a field to `Save_Data`, you bump `SAVE_VERSION` and add a case *in the same commit*. Make it a habit before it's load-bearing.

4. **The discovered mask** is image data — JSON would balloon it 4× and make saves unreadable. It's already a 512² single-channel buffer; `vendor:stb/image`'s writer (same package as the loader, as ch51 established) makes it one call:

   ```odin
   chart_mask_write :: proc(g: ^Game, slot: string) {
       path := fmt.ctprintf("%s/%s_chart.png", save_dir(), slot)
       stbi.write_png(path, 512, 512, 1, raw_data(g.discovered), 512)
   }
   ```

   Read back with `stbi.load` (request 1 channel) — and enjoy the side effect: the save file is *literally a picture of everywhere the player has sailed*. Open one. It's a little moving.

5. **Autosave on dock.** Replace ch78's `// ch80: autosave` comment with `save_write(g, "auto")`, plus a quiet "Voyage logged" line in the HUD (never a modal — autosaves should be felt, not read). Manual save/load on F5/F9 to the same single `"auto"` slot for now; multiple slots are a menu feature (ch81 gives save/load a front door). Docking is the *correct* autosave moment for this game: it's the natural chapter break, all transactions are settled, and the boat is stationary — no mid-physics pose to quibble over.

6. **`settings.json` — separate file, separate concern.** Resolution, vsync, volumes, keybinds are *machine* preferences, not *story*; mixing them into saves means "load game" changes your resolution. Same JSON machinery, its own struct (`Settings`, `SETTINGS_VERSION`), written on change, read before window creation (it decides the window!). Ch81 builds the UI over it; today, define it and wire volume + vsync:

   ```odin
   Settings :: struct {
       version:    int,
       width, height: int,
       fullscreen: bool,
       vsync:      bool,
       volume_master, volume_music, volume_sfx: f32,   // ch82 consumes these
       keybinds:   map[string]i32,                     // action name -> GLFW key; ch81
   }
   ```

   (The `map` is the one allocation in our save story — `delete` it on shutdown, or use a fixed `[Action]i32` array and convert; the array is more Odin, the map survives `Action` enum reordering. Choose and comment why.)

7. **First-run flow.** On boot: read settings (or defaults), create window, then `if !save_read(g, "auto") do game_new(g)`. A failed or absent save must land in a *good* new game — seed chosen, boat at Gullhaven's quay, 100 coins. Corrupt-save fallback is the same path. Test it by truncating `auto.json` with a text editor: the game should log, shrug, and start fresh — never crash on its own files.

## Checkpoint

The game remembers. Specifically:

- Mid-voyage quit → relaunch: position, heading, gold, cargo, contracts (with correct remaining deadlines — `sim_time` round-trips), weather, and time-of-day all match. The *waves* don't match, by design — say why in one sentence (third bucket).
- Open `saves/auto.json` in an editor: you can read your gold, hand-edit it to 9999, and the game loads your dishonesty without complaint (readable saves cut both ways; ch84's "known issues" can wink at this).
- `auto_chart.png` opened in an image viewer is a recognizable ghost of your voyages.
- Delete the saves folder entirely: clean first-run, new game, no crash. Corrupt the JSON: logged warning, new game, no crash.

## Pitfalls

- **Saving live pointers/handles by accident.** A `^Mesh` or texture id sneaks into `Save_Data` via a copied struct — reflection happily serializes the *number*, and loading it is nonsense. The capture/apply boundary exists to make every persisted field a conscious copy of plain data.
- **Saves break when you add a field.** They shouldn't — JSON unmarshal leaves missing fields zeroed — but *zero* must be safe (`has_waypoint=false` good; `docked_port=0` meaning "docked at Gullhaven" bad — that's why it's `-1` sentinel'd). Audit defaults whenever the struct grows; that audit *is* the migration case.
- **Loading doesn't regenerate.** Gold and position restore but the world is yesterday's: you applied `world_seed` without rebuilding terrain/chart, or rebuilt them and then stomped the freshly-stamped mask by loading the PNG after... order. The numbered comment block in `save_apply` is not decoration.
- **Settings and saves entangled.** "Continue" changed the resolution, or a fresh save reset the keybinds. Two files, two structs, two versions. The test: deleting one must never affect the other.
- **Autosave hitches the frame.** Marshal + write of a few KB won't — but the chart re-bake on seed mismatch will, and it must never run on a *routine* load. Guard it: `if s.world_seed != g.world_seed`.
- **`fmt.ctprintf` path handed to a proc that keeps it.** Temp-allocator strings die at frame end; `stbi.write_png` uses it immediately (fine), but if you build a path and stash it in `Game`, clone it. You know this; saves are where it resurfaces.

## Exercises

1. Save-file forward-compatibility drill: add `total_coins_earned: int` to `Save_Data` (bump version, add the migration case, surface it on the dock screen as "lifetime earnings"). Time yourself — the whole point of the scaffold is that this takes five minutes.
2. Rolling autosaves: keep `auto_0/1/2`, rotating on each dock. The first time a save corrupts (power cut mid-write), the previous slot is worth the chapter. Bonus rigor: write to `auto_tmp.json` then rename — atomic enough for a sailing game.
3. A "captain's log": append one human-readable line per docking (`"Day 12, made Kelpmouth, sold 8 timber, 432c aboard"`) to `log.txt` in the save dir. Costs nothing, and players who find it will screenshot it.
4. **Stretch:** the binary format. Magic bytes `SALT`, `u32` version, then fields in explicit order via a `Writer` over a `[dynamic]u8`; a reader that validates magic and length at every step. Implement save/load parity with JSON (a round-trip test proc that captures → writes both → reads both → asserts equality), measure sizes, and write three sentences in `design/` on when you'd switch. Now you've *earned* the opinion.

## Commit

`git commit -m "ch80: versioned JSON saves, autosave on dock, chart mask PNG, settings.json"`

← [Chapter 79 — The Chart Room](ch79-the-chart-room.md) · [Chapter 81 — The Front Door](ch81-the-front-door.md) →
