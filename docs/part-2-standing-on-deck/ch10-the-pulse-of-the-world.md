# Chapter 10 — The Pulse of the World

*Part 2 — Standing on Deck · Estimated time: 2.5h · learnopengl: no direct equivalent — this is engine/game material*

**What you'll see when done:** frame timings live in the title bar, a crate bobbing on a rock-solid simulation clock, P to freeze the world mid-bob, and T for dreamy slow motion.

## Where we are

learnopengl doesn't cover this chapter — it teaches rendering, and rendering demos can get away with `GetKey` calls sprinkled through the loop and physics stepped by whatever `dt` the GPU coughs up. A *game* that will eventually have sailing physics, buoyancy, and weather cannot. This is a plumbing chapter, kept deliberately lean, with the payoff bent into view per course rules: a live frame-time readout, pause, and slow-mo by the end. Two pieces of architecture, both small, both load-bearing for the next 42 chapters.

## Concepts

### Input as data, not as scattered calls

`glfw.GetKey` answers "is W down *right now*?" — fine for held movement, but useless for "did P get *pressed this frame*?" (pause must toggle once per press, not 60 times a second while held). The standard cure: poll everything once per frame into a struct, and derive **edges** by comparing to last frame:

```
            frame N−1   frame N    derived
 down:         0           1       pressed  (went down this frame)
 down:         1           1       held
 down:         1           0       released (went up this frame)
```

Everything downstream reads the `Input` struct — no GLFW calls beyond the poll. The win isn't elegance, it's *capability*: pressed/released edges, rebindable keys (bindings live in one table), and input that can later be recorded, replayed, or faked in tests. The mouse globals from Chapter 9 move in here too, completing the pattern: callbacks accumulate, `input_poll` harvests.

### Fixed timestep: Fix Your Timestep

The classic problem (and the classic essay: Glenn Fiedler's *[Fix Your Timestep](https://gafferongames.com/post/fix_your_timestep/)*): if simulation steps by render `dt`, then physics behaves *differently at different frame rates*. Integration error scales with step size — a buoyancy spring stable at `dt=0.016` can literally explode at `dt=0.1` (one window-drag hitch is enough). Sailing physics in Chapter 33 will be exactly such a spring system.

The cure: **simulate in fixed quanta; render whenever.** Accumulate real frame time; consume it in fixed `FIXED_DT` bites:

```
 real time arrives in irregular lumps:   |--17ms--|---33ms---|--12ms--|
 accumulator consumes it in fixed bites:  [16.6][16.6][16.6][16.6]...
                                          sim   sim   sim   sim
 leftover (< one bite) stays in the accumulator for next frame
```

```text
accumulator += frame_dt
for accumulator >= FIXED_DT {
    simulate(FIXED_DT)        // ALWAYS the same step. Deterministic. Stable.
    accumulator -= FIXED_DT
}
render()                      // as fast as vsync allows
```

Consequences worth internalizing: a fast machine renders several frames between sim steps; a slow one runs several sim steps per render. Either way the *world* advances identically. (The essay's final refinement — interpolating render state between the last two sim states to kill micro-judder — is real but overkill at our object counts; we note it and move on. Camera movement stays on render `dt` deliberately: input-to-eye latency should be as short as possible, and the camera has no physics to destabilize.)

One guard: clamp `frame_dt` (we use 0.25s max) so a debugger pause or window drag doesn't enqueue 400 sim steps — each slow enough to make the *next* frame slower: the "spiral of death."

### Pause and time scale, nearly free

Once simulation time is its own currency, manipulating it is trivial: **pause** = stop feeding the accumulator; **slow-mo** = feed it `frame_dt * 0.2`. The renderer never notices — you can still fly the camera around a frozen, mid-bob world, which besides being delightful is a legitimately great debugging tool (and the seed of Chapter 51's screenshot mode).

## Odin notes

- An enum + enumerated array is the idiomatic Odin key table: `[Action]bool` arrays index directly by enum value, and `for action in Action` iterates the whole enum. Compact, typo-proof, zero hashing.
- `fmt.ctprintf` formats into a temporary `cstring` — exactly what `glfw.SetWindowTitle` wants. It allocates from the temp allocator; add `free_all(context.temp_allocator)` once at the end of the frame loop (a good habit before any per-frame allocation sneaks in).

## Build

1. **Create `src/input.odin`:**

   ```odin
   package saltwind

   import "vendor:glfw"

   Action :: enum {
   	Move_Forward, Move_Back, Move_Left, Move_Right,
   	Move_Up, Move_Down, Sprint,
   	Pause, Slow_Mo, Wireframe, Quit,
   }

   ACTION_KEYS := [Action]i32{
   	.Move_Forward = glfw.KEY_W,    .Move_Back = glfw.KEY_S,
   	.Move_Left    = glfw.KEY_A,    .Move_Right = glfw.KEY_D,
   	.Move_Up      = glfw.KEY_SPACE, .Move_Down = glfw.KEY_LEFT_SHIFT,
   	.Sprint       = glfw.KEY_LEFT_CONTROL,
   	.Pause        = glfw.KEY_P,    .Slow_Mo = glfw.KEY_T,
   	.Wireframe    = glfw.KEY_TAB,  .Quit = glfw.KEY_ESCAPE,
   }

   Input :: struct {
   	down:     [Action]bool,
   	pressed:  [Action]bool, // edge: went down this frame
   	mouse_dx, mouse_dy: f32,
   	scroll_dy: f32,
   }

   input_poll :: proc(input: ^Input, window: glfw.WindowHandle) {
   	for action in Action {
   		was_down := input.down[action]
   		is_down := glfw.GetKey(window, ACTION_KEYS[action]) == glfw.PRESS
   		input.down[action]    = is_down
   		input.pressed[action] = is_down && !was_down
   	}
   	input.mouse_dx,  g_mouse_dx  = g_mouse_dx, 0 // harvest & reset ch9's globals
   	input.mouse_dy,  g_mouse_dy  = g_mouse_dy, 0
   	input.scroll_dy, g_scroll_dy = g_scroll_dy, 0
   }
   ```

   (Move the Chapter 9 globals and callbacks into this file — input now has a home.)

2. **Convert the loop.** Declare `input: Input` before the loop; call `input_poll(&input, window)` right after `glfw.PollEvents()`. Then sweep `main` for raw `GetKey` calls and replace: `input.down[.Move_Forward]`, `input.pressed[.Quit]`, etc. Wireframe finally becomes a real toggle:

   ```odin
   		if input.pressed[.Wireframe] do wireframe = !wireframe
   		gl.PolygonMode(gl.FRONT_AND_BACK, gl.LINE if wireframe else gl.FILL)
   ```

3. **Split clocks.** Introduce simulation state and the accumulator:

   ```odin
   	FIXED_DT :: 1.0 / 60.0
   	accumulator: f64
   	sim_time:    f64 // the world's own clock — drives bobbing, waves, sun…
   	paused := false
   	time_scale := 1.0
   ```

   In the loop:

   ```odin
   		frame_dt := min(now - last_time, 0.25) // anti-spiral clamp
   		last_time = now

   		if input.pressed[.Pause] do paused = !paused
   		time_scale = 0.2 if input.down[.Slow_Mo] else 1.0

   		if !paused do accumulator += frame_dt * time_scale
   		for accumulator >= FIXED_DT {
   			sim_time += FIXED_DT
   			// world updates go here — for now, nothing else; the bob reads sim_time
   			accumulator -= FIXED_DT
   		}
   ```

4. **Move the world onto sim_time.** The crate's bob/tumble from Chapter 8 currently reads `glfw.GetTime()` — wall time, unpausable. Switch it (and the shader's `u_time` for world effects) to `f32(sim_time)`. The *camera* keeps using `f32(frame_dt)` — re-read the Concepts paragraph on why, it's a checkpoint question in Chapter 13.

5. **Frame-time title.** Quarter-second cadence so it's readable:

   ```odin
   		title_timer += frame_dt
   		if title_timer >= 0.25 {
   			title_timer = 0
   			glfw.SetWindowTitle(window, fmt.ctprintf(
   				"Saltwind — %.2f ms (%.0f fps)%s",
   				frame_dt * 1000, 1.0 / frame_dt,
   				" [PAUSED]" if paused else ""))
   		}
   		free_all(context.temp_allocator)
   ```

6. Run. Watch ~16.7 ms in the title. Press P mid-bob: the crate freezes at an angle while you fly around it. Hold T: syrup-time.

## Checkpoint

Title bar reads steady frame times; the world obeys P and T; the camera obeys neither.

- Press and *hold* P: exactly one toggle (edge detection works). Tap it twice fast: pause, unpause.
- While paused, fly a full circle around the frozen crate — renderer alive, world stopped.
- Hold T: the crate bobs in slow motion while your camera moves at full speed.
- Drag the window around for two seconds, release: the crate does **not** fast-forward to catch up wildly (the 0.25s clamp), and the bob resumes at normal speed.

## Pitfalls

- **Pause toggles rapidly while held?** You used `input.down` where you meant `input.pressed` — the entire reason `pressed` exists.
- **Everything froze on pause, including the camera?** You gated the whole loop body on `!paused` instead of just the accumulator feed. Pause stops *simulation*, never rendering or input.
- **Crate stutters or double-steps occasionally?** You're advancing `sim_time` (or the bob) *outside* the fixed loop too, or rendering reads a mix of `sim_time` and `glfw.GetTime()`. One world clock. Audit every time read.
- **Machine hitches snowball into permanent slow-motion?** Missing `min(…, 0.25)` clamp — the spiral of death, live.
- **`ctprintf` memory climbing over hours?** `free_all(context.temp_allocator)` missing from the loop.

## Exercises

1. Add `.Time_Faster` / `.Time_Slower` actions (`]` and `[`) stepping `time_scale` ×2 / ÷2, clamped to [0.125, 8]; show it in the title when ≠ 1. A time-lapse dial — wait until there's a sun to drag across the sky in Chapter 27.
2. Prove determinism: run with vsync on, then with `SwapInterval(0)` at hundreds of fps — the bob's phase at sim_time = 10.0 is identical both ways. That's the fixed timestep's entire promise, demonstrated.
3. Log a warning when more than 3 sim steps run in one frame — your first performance canary, and free with the accumulator loop's structure.
4. **Stretch:** Single-step mode: while paused, `.` (period) runs exactly one `FIXED_DT` step. Trivial with this architecture (`if input.pressed[.Step] do accumulator += FIXED_DT`, gate inside `paused`) — and indispensable when buoyancy goes wrong frame-by-frame in Chapter 32.

## Commit

```
git commit -m "ch10: Input struct, fixed timestep, pause & time scale"
```

Prev: [Chapter 9 — Free as a Gull](ch09-free-as-a-gull.md) · Next: [Chapter 11 — Meshes that Matter](ch11-meshes-that-matter.md)
