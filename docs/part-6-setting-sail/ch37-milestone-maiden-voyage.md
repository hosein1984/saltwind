# Chapter 37 — MILESTONE: Maiden Voyage

*Part 6 — Setting Sail · Estimated time: 2h · learnopengl: review — no new graphics this chapter*

**What you'll see when done:** a voyage with a *name on it*: casting off from Hartlepool Rock, holding a compass course across open water, and arriving — officially, with a message — at Gullhaven. Saltwind is now a game you can finish a session of.

## Where we are

Part 6 gave you a boat that floats, sails, wakes, and sounds. What's missing is *purpose* — the difference between a tech demo and a game is somewhere to go. This milestone adds the smallest possible goal loop: two named islands, a compass readout, an arrival check. Real HUD rendering is Chapter 48; today the window title is your instrument panel — ugly, honest, and zero new GL.

## Integration pass

1. **Name your islands.** Your Chapter 21 world seed produces island centers. Pick the two most distant (or your two favorites) and promote them to data:

   ```odin
   Island :: struct {
       name:     string,
       position: glsl.vec2,   // world xz of the island center
       radius:   f32,         // approximate shore radius
   }
   // in Game:
   islands: [2]Island,
   voyage_target: int,        // index into islands
   arrived: bool,
   ```

   Hardcode names with flavor (`"Hartlepool Rock"`, `"Gullhaven"`) or derive them from the seed (exercise). Radius: eyeball from your falloff mask parameters — the distance where terrain crosses y = 0.

2. **Compass heading.** Convert the boat's yaw into a 0–360° compass bearing, plus the classic 16-point name. North is −Z (or +Z — *decide and write it in a comment*; the only wrong choice is an unconscious one):

   ```odin
   heading_degrees :: proc(yaw: f32) -> f32 {
       deg := -yaw * 180.0 / math.PI       // sign per your yaw convention
       return math.mod(deg + 360.0, 360.0)
   }

   COMPASS_POINTS := [16]string{"N","NNE","NE","ENE","E","ESE","SE","SSE",
                                "S","SSW","SW","WSW","W","WNW","NW","NNW"}
   compass_point :: proc(deg: f32) -> string {
       return COMPASS_POINTS[int(math.round(deg / 22.5)) % 16]
   }
   ```

3. **Bearing and distance to target** — the same math pointed at the goal:

   ```odin
   to_target := target.position - glsl.vec2{g.boat.position.x, g.boat.position.z}
   dist      := glsl.length(to_target)
   bearing   := math.mod(-math.atan2(to_target.x, -to_target.y) * 180.0/math.PI + 360.0, 360.0)
   ```

   (Reuse `angle_wrap` from Chapter 33 if your signs fight you — and they will, once. Test by sailing due "north" and checking the readout says N.)

4. **The instrument panel.** Once per render frame (it's cheap, but title updates can be throttled to ~10 Hz if your window manager flickers):

   ```odin
   title := fmt.ctprintf("Saltwind — HDG %03.0f° %s · %s brg %03.0f° · %.0f m · %.1f kn",
       hdg, compass_point(hdg), target.name, bearing, dist, g.boat.speed * 1.94)
   glfw.SetWindowTitle(window, title)
   ```

   `fmt.ctprintf` allocates from the temp allocator — fine if you call `free_all(context.temp_allocator)` per frame (you should be by now). The `* 1.94` converts m/s to knots, because this is a *sailing* game.

5. **The arrival trigger**, in `game_simulate`:

   ```odin
   if !g.arrived && dist < target.radius + 25.0 {
       g.arrived = true
       fmt.printfln("You arrived at %s. Voyage complete.", target.name)
       // and/or: glfw.SetWindowTitle -> "⚓ Welcome to Gullhaven"
   }
   ```

   Want a loop instead of an ending? On arrival, flip `voyage_target` to the other island and reset `arrived` — infinite ferry duty, and a surprisingly good soak test.

6. **Spawn at the dock.** Start the boat just off island 0, pointed roughly at the target, wind set so the first leg is a beam reach (the fun point of sail). First impressions matter, even to yourself.

## Tuning the feel (the real work)

Sail the full crossing at least three times and interrogate it:

- **Too slow to be fun?** Raise wind strength or the `0.6` scale in `boat_update_sailing` — crossing should take 2–4 minutes, long enough to trim and settle, short enough to want another run.
- **Turning feels like a truck / a shopping cart?** Rudder authority curve (Chapter 33 step 3). Trucks: raise the speed-independent `0.25` floor. Carts: lower it and raise the speed-scaled part.
- **The sea fights the voyage?** If waves toss the bow enough to obscure the horizon line you're steering by, drop big-swell amplitude 20%. Playability outranks drama on a working passage.
- **Does the wind direction make both legs interesting?** A wind perpendicular to the island axis gives beam reaches both ways (easy mode); diagonal wind makes one leg a beat upwind — better game. Choose deliberately.
- **In irons recovery:** botch a tack on purpose mid-crossing. If escaping the no-go zone takes more than ~5 seconds of fiddling, widen the `0.25` rudder floor — frustration, not realism, is the failure mode.

## The screenshot (#5 of 8)

Mid-passage, follow cam: bow pointed at the destination island on the horizon, wake curving behind from your last course correction, heel visible, window title showing heading and distance. Checklist:

- [ ] Destination island visible ahead (small — distance should read in the title)
- [ ] Wake shows a recent turn (proves it's a voyage, not a screensaver)
- [ ] Boat heeled on a reach, boom trimmed accordingly if you did Chapter 33 ex. 2
- [ ] Window title in frame with HDG/bearing/distance/knots
- [ ] Bonus: time of day ~17:00 so Part 5 flexes in the background

## Quiz

Write your answers before unfolding.

1. Why must `ocean_height_at` and the water vertex shader use the same time value, and which clock is it?
2. The boat's pitch comes from `atan2(h_bow − h_stern, hull_length)`. Why does a wave much shorter than the hull barely pitch the boat?
3. What two properties make critically damped smoothing better than `value = target` and better than a plain spring for boat pose?
4. Name the points of sail in order from 0° to 180° off the wind, and where our polar curve peaks.
5. Why does rudder authority scale with boat speed, and what player-visible bug does that scaling prevent?
6. In the wake renderer, why are depth *writes* disabled but depth *testing* left on?
7. Why must `world_flush` (ash) or any structural change wait until after query iteration completes?
8. Your frame does reflection, refraction, and main passes. List what must be re-set when switching render targets, and the two classic bugs from forgetting.

<details>
<summary>Answers</summary>

1. The CPU buoyancy samples must match the GPU-displaced surface exactly or the boat floats above/below the visible water. Both use the fixed-timestep simulation clock — never render time.
2. The bow and stern samples land on different phases of the short wave (one up, one down, or both mid-slope); the difference — and thus the pitch — averages toward zero. Hull length acts as a low-pass filter over wavelengths, as in reality.
3. It's frame-rate independent and it never overshoots: snapping transmits every jolt of chop (jitter), while an underdamped spring oscillates after each wave. Critical damping is the fastest approach *without* overshoot.
4. In irons (dead zone) → close-hauled (~45°) → beam reach (90°) → broad reach (~135°, our peak) → running (180°, slight sag).
5. A real rudder generates turning force from water flowing over it — no flow, no force. Scaling prevents the parked boat from rotating in place like a shopping cart.
6. Testing keeps the wake correctly hidden behind islands and the hull; writing would stamp the transparent quad's depth into the buffer and incorrectly occlude things drawn after it through its see-through parts.
7. Iteration walks archetype storage directly; spawning/despawning/moving components reshuffles that storage, invalidating iterators and component pointers mid-walk. The command queue defers the mutation to a safe point.
8. Re-bind the framebuffer, reset `gl.Viewport` to the target's size, and clear the new target. Classic bugs: rendering the main view at FBO resolution in a corner of the window (viewport), and ghost frames in the reflection (missing clear).

</details>

## Share it

Post the passage — ideally as a 20-second clip (OBS, or ShareX on Windows) rather than a still: the wake, heel, and compass title only read in motion. The Odin Discord #showcase and [r/odinlang](https://www.reddit.com/r/odinlang/) have seen your sunset; show them it *sails*. Caption suggestion: chapter count and line count — people underestimate how reachable this is.

## If you're returning after a break

Part 6 recap: the boat is posed by *graphics buoyancy* — `ocean_height_at` sampled at bow/stern/port/starboard, averaged for height, `atan2` deltas for pitch/roll, all eased by `smooth_damp` (critically damped, in `src/boat.odin`). Sailing is a polar curve `sail_power(angle_off_wind)` × trim score × wind strength, chased with a ~2.5 s time constant; rudder yaw scales with speed; heel is a roll bias from the beam wind. The wake is a ring buffer of stern points rebuilt each frame into a blended triangle strip (draw order: scene → sky → water → wake; depth write off). The frame is four phases — input → simulate (fixed) → animate → render — and only `game_render` speaks GL. Optionally, floating cargo lives in an `ash` ECS world and audio loops track game state. Next: Part 7 — shadows, HDR, bloom — the beauty arc. The boat will look *very* good under a low sun with shadows on the water.

## Commit

`git commit -m "ch37: milestone - maiden voyage between named islands"`

← [Chapter 36 — The Sound of the Sea](ch36-the-sound-of-the-sea.md) · [Chapter 38 — Depths & Stencils](../part-7-advanced-light/ch38-depths-and-stencils.md) →
