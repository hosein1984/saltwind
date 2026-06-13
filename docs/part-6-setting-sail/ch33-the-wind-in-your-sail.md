# Chapter 33 — The Wind in Your Sail

*Part 6 — Setting Sail · Estimated time: 3.5h · learnopengl: no direct equivalent — this is engine/game material*

**What you'll see when done:** you, at the helm — steering with the rudder, trimming the sail to the wind, heeling into a beam reach with a chase camera hanging off your stern. Saltwind becomes a game in this chapter.

## Where we are

The boat floats (Chapter 32) but goes nowhere, and you still watch her from a fly camera like a seagull with opinions. Today: a global `Wind`, a simplified-but-honest sailing model, rudder steering, and a follow camera. None of it is graphics — and it's the most fun code in the course.

## Concepts

### The points of sail (your new vocabulary)

A sailboat cannot sail straight into the wind, and — surprisingly — straight *downwind* isn't fastest either. Performance depends on the angle between the wind and your heading. Sailors name the angles, and the names are worth learning because they make the tuning conversation precise:

```
                    WIND
                     ↓
              ░░ in irons ░░          ~0–35° off wind: the no-go zone.
             ↗              ↖         Sail flaps, boat stalls.
       close-hauled    close-hauled   ~45°: beating upwind, heeled hard
           →   beam reach   ←         90°: wind abeam — fast, fun
             ↘              ↙         ~135°: broad reach — fastest
                 running              180°: dead downwind — quick but
                     ↑                      sluggish, less apparent wind
                  (heading)
```

A real boat's performance-by-angle chart is called a **polar diagram**. We'll implement a cartoon of one — a curve `sail_power(angle_off_wind)` that's zero in irons, climbs through close-hauled, peaks at a broad reach, and sags a little dead downwind. That single curve *is* the sailing model; everything else is bookkeeping.

### Trim: the player's second axis

Wind angle is half the story; the sail must be *trimmed* — sheeted at the right angle for the current point of sail. Roughly: sail nearly centered when close-hauled, eased ~45° on a beam reach, all the way out when running. We model trim as one number (the sail angle relative to the boat) and score it: power is multiplied by how close trim is to ideal. Offer **auto-trim** as a toggle — purists steer *and* trim; everyone else lets the bosun do it. Game design tip hiding here: auto-trim ON is the right default; manual trim is depth for those who seek it.

### Game feel: why instant response feels wrong

The naive implementation — `speed = wind * polar(angle)` — is *correct* and feels terrible. Real boats accelerate over seconds; mass and drag write the easing curves for you. When the response is instant, the player's brain rejects the object as weightless. The fix costs two lines: chase a **target** speed with a time constant. Same for the rudder: real rudders only bite when water flows past them, so yaw authority should scale with speed — which also automatically prevents the parked boat from spinning in place like a shopping cart. Acceleration curves are 80% of "feel"; numbers first, then feel-tune with your hands on the keys, never by staring at code.

### Heel: physics as theater

Beam wind pushes the rig sideways; the boat leans (heels) away from the wind. We *could* derive it from forces — but Chapter 32 taught the cheaper trick: compute a target heel from the beam component of the wind and feed it through `smooth_damp` into the buoyancy roll. Pure flourish, sells the wind harder than any particle effect could.

### The chase camera

A follow camera has two jobs: keep the boat readable, and *lag* — snapping kills the sense of motion. Place the camera behind and above the boat (in boat space), smooth its world position, and aim it at a **look-ahead** point in front of the bow, so the player sees where they're *going*. Keep the free camera behind a toggle; you'll debug from gull-view forever.

## Build

1. **Define `Wind`** in `src/wind.odin` — global, simple, shared (the water shader's detail scroll from Chapter 29's exercise 3 can finally plug in):

   ```odin
   Wind :: struct {
       direction: f32,  // radians, direction the wind blows TOWARD
       strength:  f32,  // m/s; 4 = light, 8 = fresh, 14 = strong
   }
   ```

2. **Write the polar curve.** A piecewise `smoothstep` chain reads better than it sounds:

   ```odin
   // 0..1 power multiplier from angle between wind and heading (radians, 0 = bow into wind)
   sail_power :: proc(angle_off_wind: f32) -> f32 {
       a := abs(angle_off_wind)             // symmetric port/starboard
       deg := a * 180.0 / math.PI
       switch {
       case deg < 30:  return 0.0                                    // in irons
       case deg < 50:  return glsl.smoothstep(f32(30), 50, deg) * 0.7  // close-hauled
       case deg < 90:  return 0.7 + glsl.smoothstep(f32(50), 90, deg) * 0.2
       case deg < 135: return 0.9 + glsl.smoothstep(f32(90), 135, deg) * 0.1 // broad reach peak
       case:           return 1.0 - glsl.smoothstep(f32(135), 180, deg) * 0.25 // running sag
       }
   }
   ```

   Plot it mentally against the diagram above; every named point of sail is a line of this switch.

3. **Extend `Boat` with sailing state** — `speed, target_speed, rudder, sail_trim: f32`, `auto_trim: bool` — and write the fixed-step `boat_update_sailing`:

   ```odin
   boat_update_sailing :: proc(b: ^Boat, w: Wind, dt: f32) {
       // wind angle relative to the bow, wrapped to [-π, π]
       rel := angle_wrap(w.direction - b.yaw - math.PI) // bow INTO wind = 0

       ideal_trim := clamp(abs(rel) * 0.5, 0.15, math.PI/2)  // half the wind angle, never amidships
       if b.auto_trim do b.sail_trim = ideal_trim
       trim_score := 1.0 - clamp(abs(b.sail_trim - ideal_trim) / 0.6, 0.0, 1.0)

       b.target_speed = w.strength * 0.6 * sail_power(rel) * trim_score
       b.speed += (b.target_speed - b.speed) * (1.0 - math.exp(-dt / 2.5)) // ~2.5s response

       // rudder: authority grows with speed
       authority := 0.25 + 0.75 * clamp(b.speed / 6.0, 0.0, 1.0)
       b.yaw += b.rudder * 0.8 * authority * dt

       // advance along heading (forward = local +Z, matching ch32's bow offset)
       b.position.x += math.sin(b.yaw) * b.speed * dt
       b.position.z += math.cos(b.yaw) * b.speed * dt
   }
   ```

   `angle_wrap` is the usual `math.mod(a + π, 2π) − π` with negative-mod care — write it once in a math utils file; the compass in Chapter 37 needs it too. The boring 70% not shown: input mapping that sets `rudder` to −1/0/+1 from A/D (ease it toward zero when released — rudders center themselves), Q/E adjusting `sail_trim` by `1.5*dt`, T toggling `auto_trim`.

4. **Add heel.** In `boat_update_buoyancy`, fold a wind-heel term into the roll target:

   ```odin
   rel  := angle_wrap(w.direction - b.yaw - math.PI)
   heel := -math.sin(rel) * (w.strength / 14.0) * 0.22  // radians; sign: away from wind
   target_roll += heel * clamp(b.speed / 2.0, 0.3, 1.0) // a parked boat heels less
   ```

   Beam reach (`rel = ±90°`) gives maximum heel; irons and running give none. `sin` does the work.

5. **Build the chase camera.** Add a `camera_mode: enum { Free, Follow }` to `Game` (toggle on C). In Follow, *don't* drive yaw/pitch — compute the view directly:

   ```odin
   camera_follow_update :: proc(g: ^Game, dt: f32) {
       b := g.boat
       behind := glsl.vec3{-math.sin(b.yaw), 0, -math.cos(b.yaw)}
       target_pos  := b.position + behind * 11.0 + glsl.vec3{0, 4.5, 0}
       look_ahead  := b.position - behind * 8.0 + glsl.vec3{0, 1.0, 0}

       k := 1.0 - math.exp(-dt * 3.0)              // position lag ~0.3s
       g.cam_pos_smooth  += (target_pos - g.cam_pos_smooth) * k
       g.cam_look_smooth += (look_ahead - g.cam_look_smooth) * k
       g.view = glsl.mat4LookAt(g.cam_pos_smooth, g.cam_look_smooth, {0, 1, 0})
   }
   ```

   Update once per *render* frame (cameras are presentation, not simulation). Wherever you previously built the view from `Camera`, branch on the mode. Note the lagged look-at point — when you turn, the camera swings wide then settles, which reads as momentum.

6. **Sail.** Set wind to `direction = π/4, strength = 7`. Steer with A/D. Try to sail into the wind: she stalls (in irons). Bear away to a beam reach: she accelerates and heels. Square off downwind: fast but flat. Tack through the wind (carry speed through the no-go cone) — if you can feel the difference between a good tack and a botched one, the model works.

## Checkpoint

You're sailing: rudder steers (only when moving), the boat accelerates over seconds, heels on a reach, stalls head-to-wind, and the camera swings behind you with a satisfying lag.

- Head dead upwind: speed bleeds to zero. Fall off 50°: she builds way again.
- Manual trim (auto-trim off): badly eased sail visibly costs speed; ideal trim recovers it.
- At full speed, hard rudder turns briskly; from a standstill, the bow barely creeps.
- Toggle C mid-sail: free cam for debugging, follow cam for sailing, no state corruption either way.

## Pitfalls

- **Boat spins instantly / turns while parked.** Rudder authority isn't speed-scaled, or you applied yaw in the input handler instead of the fixed step.
- **Speed flips sign or boat sails backward in irons.** Your polar returns negative values or your relative angle isn't wrapped — `angle_wrap` everything before comparing; test at the 180° seam (wind dead astern) where naive subtraction jumps by 2π.
- **The camera vibrates.** You're smoothing in the fixed step but rendering more often (or with unsmoothed interpolation). Camera smoothing belongs in the render-frame update with render dt.
- **Heel fights the waves.** You *replaced* the buoyancy roll target instead of adding to it. Wind heel is a bias on top of the wave-following roll.
- **Everything works but feels dead.** Response constants too fast. Double the speed time-constant (2.5 → 5.0) and the camera lag, feel again. Game feel is found by oscillating past the right value from both sides, never by reasoning alone.

## Exercises

1. Print (window title is fine for now) the point-of-sail name from the relative angle — "Close-hauled (stbd)", "Beam reach (port)", "Running". Instant sailing tutor, and Chapter 37 reuses the logic.
2. Rotate the boom: if your Chapter 18 hierarchy has the sail/boom as a child node, set its local yaw to `sail_trim` (mirrored by tack side). Auto-trim ON makes the boom swing across on every tack — a free jibe animation.
3. Make `Wind` wander: every 20–40 s (use `core:math/rand`), pick a new direction within ±25° and strength ±2, and `smooth_damp` toward it. Sailing a shifting wind is a different (better) game.
4. **Stretch:** apparent wind. What a sail actually feels is true wind *minus* boat velocity — compute the apparent vector, feed *its* angle and magnitude into the polar and heel. Notice you can now out-point your old boat upwind and the heel stiffens on a close reach: one vector subtraction, startling realism.

## Commit

`git commit -m "ch33: wind, sailing model, rudder, and chase camera"`

← [Chapter 32 — She Floats](ch32-she-floats.md) · [Chapter 34 — Cutting the Water](ch34-cutting-the-water.md) →
