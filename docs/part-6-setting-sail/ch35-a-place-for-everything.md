# Chapter 35 — A Place for Everything

*Part 6 — Setting Sail · Estimated time: 3h · learnopengl: no direct equivalent — this is engine/game material*

**What you'll see when done:** nothing new on screen — and that's the point. Same sunset, same boat, but a main loop you can read top to bottom, and (optionally) fifty wave-riding cargo crates spawned through a real ECS in a dozen lines.

## Where we are

Be honest about your `main.odin`. Since Chapter 10 it has accreted: camera logic interleaved with buoyancy, wake emission next to FBO binding, input checks sprinkled through update code. Every chapter made it 5% worse, and Part 7 (shadows, HDR, bloom — each adding *passes*) will not be kind to it. This chapter is the mid-course refactor: first imposing order with plain Odin, then an honest look at ECS — including a guided, optional integration of the `ash` library sitting in this repo's folder.

## Concepts

### The four-phase frame

Almost every real-time game settles into the same loop shape. Name the phases and make the code match:

```
 input ──> simulation ──> animation ──> render
 (poll,    (FIXED step:    (render-rate:  (passes:
  intent)   sailing,        camera lag,    reflection,
            buoyancy,       wake mesh,     refraction,
            wind, time)     boom swing)    main, sky,
                                           water, wake)
```

- **Input** translates raw GLFW state into *intent* (`rudder = -1`, `trim_delta`, toggles) — nothing moves here.
- **Simulation** runs zero or more *fixed* steps (Chapter 10's accumulator): boat physics, wind, the sim clock. Deterministic, frame-rate independent.
- **Animation** runs once per render frame: chase-camera smoothing, wake strip building, anything cosmetic that should be silk-smooth at 144 Hz even though the sim ticks at 60.
- **Render** touches the GPU, and *only* it touches the GPU.

The enforcement mechanism in plain Odin is embarrassingly simple: four procs — `game_input`, `game_simulate`, `game_animate`, `game_render` — each taking `^Game`, called in order by a `main` short enough to memorize. The discipline that matters: **data flows left to right.** Render reads simulation state; it never writes it. The moment a render proc mutates the boat, determinism dies quietly.

### Handles, not pointers

As soon as you hold "things" in a `[dynamic]` array (buoys, crates, islands), the temptation is to store `^Buoy` references. Don't: `append` may reallocate the array and every pointer into it becomes a landmine. The standard cure is a **handle** — index plus generation:

```odin
Handle :: struct { index: u32, gen: u32 }
```

Look-up checks the generation against a per-slot counter; a stale handle (the slot was freed and reused) fails loudly instead of corrupting memory. If that pattern sounds familiar, it should — it's exactly how OpenGL's `u32` object names work, and (not coincidentally) exactly how ash's `Entity` IDs work. You can build handle-based storage yourself in ~60 lines… which is the on-ramp to the real question.

### ECS: the honest section

An Entity Component System stores *components* (plain data structs) in tightly packed arrays grouped by *archetype* (the set of components an entity has), and runs *systems* (procs) over *queries* (give me everything with Position and Velocity). What it buys you:

- **Composition over taxonomy.** A "buoy with a lantern that's also a quest marker" is just three components — no inheritance diamond, no `entity_type` switch statements.
- **Cache-friendly iteration** over thousands of homogeneous things.
- **Lifecycle hygiene**: generational IDs, deferred spawn/despawn, observers.

What it costs: a layer of indirection in your debugging, ceremony for singletons, and a real learning curve. So the honest verdict for Saltwind: **you don't need it.** One boat, one ocean, one sky, one wind — those are singletons, and `Game` struct fields are the *correct* storage for singletons. ECS starts paying when you have *many heterogeneous interacting things*: 200 buoys, 30 gulls, floating cargo, drifting debris, AI boats. If your expansion plans (Chapter 52 talks about them) include a living world, learn it now on friendly ground. Otherwise, skip the optional half of this chapter without guilt — structs and slices are not a junior solution; they're the right tool at this scale.

## Odin notes

`ash` follows the Odin convention of *collections*. Copy `ash-main/` into `saltwind/libs/ash/`, then build with a collection mapping and import it:

```text
odin build src -collection:libs=libs -out:saltwind.exe
```

```odin
import ash "libs:ash"
```

(Alternative: place it under `src/ash/` and use a relative `import ash "ash"` — collections are tidier once more libraries arrive.) Also note ash is **not thread-safe** by design — fine, since all our phases run on one thread.

## Build

1. **Carve up `Game`.** Group what's grown wild — the goal is that each phase touches an obvious subset:

   ```odin
   Game :: struct {
       // simulation state (fixed step owns this)
       sim_time:  f32,
       ocean:     Ocean,
       sky:       Sky,
       wind:      Wind,
       boat:      Boat,
       // presentation state (render rate owns this)
       camera:        Camera,
       camera_mode:   Camera_Mode,
       wake:          Wake,
       // render resources
       reflection, refraction: Render_Target,
       shaders:   Shaders,        // gather the loose Shader fields into one struct
       // input intent, written by game_input, read by simulate
       input:     Input_State,
   }
   ```

2. **Write the four phase procs** and shrink `main`'s loop to the skeleton:

   ```odin
   for !glfw.WindowShouldClose(window) {
       glfw.PollEvents()
       game_input(&game, window)

       accumulator += frame_dt
       for accumulator >= SIM_DT {
           game_simulate(&game, SIM_DT)   // sailing, buoyancy, wind, sim_time
           accumulator -= SIM_DT
       }

       game_animate(&game, frame_dt)      // chase cam, wake strip, boom
       game_render(&game)                 // the only proc that calls gl.*
       glfw.SwapBuffers(window)
   }
   ```

   Most of this exists from Chapter 10 — the work is *moving* code into the right proc and discovering, via compile errors, every place a phase was reaching across the line. Budget an hour; it's the cheapest hour of technical-debt repayment you'll ever buy.

3. **`Input_State` as intent.** A struct of `rudder: f32`, `trim_delta: f32`, toggles as `bool`s, written *only* in `game_input`. Simulation reads intent; it never calls `glfw.GetKey`. (Payoff beyond cleanliness: replays and demo recording become "record `Input_State` per tick" — keep it in mind for Chapter 49's profiling captures.)

   Everything below this line is **optional** — the ash integration. The refactor above stands on its own.

4. **Vendor ash** as in Odin notes, add `world: ash.World` to `Game`, and define components for floating cargo — plain structs, registered or auto-registered on first use:

   ```odin
   Position  :: struct { value: glsl.vec3 }
   Floater   :: struct { bob_offset: f32 }            // rides ocean_height_at
   Render_As :: struct { mesh: ^Mesh, tint: glsl.vec3 }

   ecs_init :: proc(g: ^Game) {
       ash.world_init(&g.world)
       for _ in 0 ..< 50 {
           spot := random_open_water_spot(g)          // rejection-sample vs terrain
           ash.world_spawn(&g.world,
               Position{spot},
               Floater{rand.float32() * 0.2},
               Render_As{&g.crate_mesh, {0.7, 0.5, 0.3}},
           )
       }
   }
   ```

5. **Write two systems** — and notice they're *just procs called from the right phase*, exactly like everything else in step 2 (ash deliberately has no built-in scheduler; its `examples/04_systems` and `examples/05_scheduler` show this pattern and a fancier stage-based variant you can graduate to):

   ```odin
   // called from game_simulate
   float_system :: proc(g: ^Game, t: f32) {
       filter := ash.filter_contains(&g.world, {Position, Floater})
       it := ash.query_iter(ash.world_query(&g.world, filter))
       for entry in ash.query_next(&it) {
           pos := ash.entry_get(entry, Position)
           f   := ash.entry_get(entry, Floater)
           pos.value.y = ocean_height_at(g.ocean, pos.value.xz, t) + f.bob_offset
       }
   }

   // called from game_render
   render_floaters_system :: proc(g: ^Game) {
       filter := ash.filter_contains(&g.world, {Position, Render_As})
       it := ash.query_iter(ash.world_query(&g.world, filter))
       for entry in ash.query_next(&it) {
           pos := ash.entry_get(entry, Position)
           r   := ash.entry_get(entry, Render_As)
           model := glsl.mat4Translate(pos.value)
           shader_set_mat4(g.shaders.lit, "model", model)
           shader_set_vec3(g.shaders.lit, "tint", r.tint)
           mesh_draw(r.mesh^)
       }
   }
   ```

   `entry_get` returns a *pointer* into component storage — mutate through it freely, but don't store it across frames (handles, not pointers — `ash.Entity` is the handle).

6. **Despawn safely.** When the boat sails within 3 m of a crate, "collect" it. Structural changes during iteration are forbidden in any archetype ECS; ash gives you the command queue:

   ```odin
   it := ash.query_iter(ash.world_query(&g.world, filter))
   for entry in ash.query_next(&it) {
       pos := ash.entry_get(entry, Position)
       if glsl.distance(pos.value, g.boat.position) < 3.0 {
           ash.entry_queue_despawn(&entry)
       }
   }
   ash.world_flush(&g.world)   // applies queued despawns, AFTER iteration
   ```

7. **Clean up:** `ash.world_destroy(&g.world)` on shutdown, next to your other destroys.

## Checkpoint

Behaviorally identical game (refactor) — plus, if you took the optional path, 50 crates riding the swells that vanish as you sail through them.

- `game_render` is the only proc in the codebase containing `gl.` calls (grep proves it).
- Pause the sim: crates freeze with the waves (float_system runs in simulate, with sim time).
- Collect a few crates, then sail back through where they were — no ghosts, no crashes (queue + flush working).
- Frame time unchanged: 50 entities is nothing; ash's archetype iteration is nanoseconds here.

## Pitfalls

- **The refactor "won't converge"** — everything seems to need everything. Symptom of cosmetic state living in simulation (camera position in `Boat`?) or vice versa. Sort each field by *who writes it*; ownership becomes obvious.
- **Crates jitter while the boat is smooth.** You ran `float_system` from `game_animate` with render time. Same clock, same phase as the boat's buoyancy: simulate.
- **Crash or weird component values after collecting a crate.** You called `world_despawn` mid-iteration instead of queueing, or used a stored `entry`/component pointer after `world_flush`. Structural changes invalidate live pointers — that's *why* the queue exists.
- **`undeclared name: ash`.** The `-collection:libs=libs` flag is missing from your build command (editor build tasks too, not just your terminal).
- **ECS creep.** A week from now you'll itch to move `Boat` into the world as an entity. Resist until you have a *second* boat. Singletons in `Game` are not a smell; ash even acknowledges this with its resources API (`world_set_resource`) for exactly this kind of global.

## Exercises

1. Add a `Lantern` component (color, radius) to ~10 crates and make your Chapter 15 point-light pass query for `{Position, Lantern}` — entities now *compose* into the renderer with no new entity types.
2. Implement the 60-line handle-based storage from Concepts for your terrain chunks (no ash) — feel the difference between building the pattern and importing it.
3. Use `ash.world_on_despawn` (observers) to play a little visual pop — store the position and spawn three foam quads via your Chapter 34 machinery — when a crate is collected.
4. **Stretch:** port the *buoys* into the world and write `bob_system` using **bulk iteration** (`query_iter_archs` + `archetype_slice` — see ash's `examples/02_bulk`). Benchmark entry vs. bulk iteration at 10,000 buoys with `time.tick_now`; ash's own benches show ~20–40× — verify on your machine.

## Commit

`git commit -m "ch35: four-phase frame, handles, optional ash ECS for floaters"`

← [Chapter 34 — Cutting the Water](ch34-cutting-the-water.md) · [Chapter 36 — The Sound of the Sea](ch36-the-sound-of-the-sea.md) →
