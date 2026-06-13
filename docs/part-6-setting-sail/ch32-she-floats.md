# Chapter 32 — She Floats

*Part 6 — Setting Sail · Estimated time: 2.5h · learnopengl: no direct equivalent — this is engine/game material*

**What you'll see when done:** the boat hull from Chapter 17 riding your Gerstner swells — bow lifting over crests, deck rolling as a beam sea passes under her — without a single line of shader code.

## Where we are

The boat has been a static prop since the Chapter 18 transform hierarchy put her mast on her hull. Meanwhile, Chapter 28 quietly built this chapter's entire foundation: `ocean_height_at(pos, time)` — the CPU mirror of the wave shader. Today that discipline pays out. Buoyancy here is pure CPU simulation feeding the existing hierarchy root; the GPU never hears about it.

## Concepts

### Graphics buoyancy: sample, don't simulate

Honest framing up front: real buoyancy is Archimedes — integrate displaced volume over the submerged hull, apply force at the center of buoyancy, fight gravity, damp with drag. Games that need boats to *capsize* do this. We don't; our boat should look right and feel stable. The graphics-buoyancy trick: **sample the water height at a few hull points and pose the boat to match the implied plane.** No forces, no integration, no tuning hell. (When you want the real thing later: Jacques Kerner's ["Water interaction model for boats in video games"](https://www.gamedeveloper.com/programming/water-interaction-model-for-boats-in-video-games) is the standard write-up — excellent further reading, not tonight's job.)

### Four points define a pose

Sample the ocean under four points in *boat-local* space — bow, stern, port, starboard — rotated by the boat's current yaw into world space:

```
            bow ●                 pitch = atan2(h_bow − h_stern, L)
                |                 roll  = atan2(h_port − h_starboard, W)
   port ● ──────┼────── ● starboard      y  = average of all four
                |
          stern ●            L = bow-stern distance, W = beam width
```

- **Height:** average the four samples → the root's `y`.
- **Pitch** (nose up/down): the bow-minus-stern height difference over their separation is the slope under the hull; `atan2(dh, length)` converts to an angle.
- **Roll** (lean left/right): same with port/starboard over the beam width.

That's the entire model. Note what it gets right automatically: a wave shorter than the hull barely tips her (the four samples straddle it and average out), while a long swell tips her fully — exactly how hull length works in reality.

### Critically damped smoothing: the anti-jitter

Snapping the boat to the sampled pose every tick *works* but looks nervous — small chop makes the hull twitch. Real boats have inertia. You want each value (y, pitch, roll) to *chase* its target: fast when far, settling without overshoot. "Without overshoot" is the definition of **critical damping** — a spring-damper tuned to the boundary between bouncy and sluggish. The classic implementation is the `SmoothDamp` routine from *Game Programming Gems 4* (the one Unity ships):

```odin
// Critically damped spring toward target. smooth_time ≈ seconds to mostly arrive.
smooth_damp :: proc(value, velocity: ^f32, target, smooth_time, dt: f32) {
    omega := 2.0 / max(smooth_time, 0.0001)
    x := omega * dt
    e := 1.0 / (1.0 + x + 0.48*x*x + 0.235*x*x*x)   // fast approx of exp(-x)
    change := value^ - target
    temp := (velocity^ + omega*change) * dt
    velocity^ = (velocity^ - omega*temp) * e
    value^ = target + (change + temp) * e
}
```

Each smoothed quantity carries its own velocity state. Frame-rate independent, never overshoots, two tunables total (one `smooth_time` for height, one shared by the angles). This little proc will follow you through the camera (Chapter 33) and beyond — put it somewhere central.

### Simulate in the fixed step

Buoyancy is *simulation*: it runs in the Chapter 10 fixed-timestep update with the sim clock — the same clock `u_time` gets. If you sample with render time but display with sim time, the boat leads or trails the visible wave by a frame and looks like it's surfing soap. One clock. (Chapter 35 formalizes this layering.)

## Odin notes

`smooth_damp` mutates through pointers — Odin has no `ref` parameters, so `^f32` in, explicit `&` at the call site: `smooth_damp(&boat.y, &boat.y_vel, target_y, 0.35, dt)`. The caller-visible `&` is the idiom working as intended: you can see exactly which arguments a call can change.

## Build

1. **Extend `Boat`** (or create `src/boat.odin` if she's still bare fields in `Game`):

   ```odin
   Boat :: struct {
       position:   glsl.vec3,   // x,z driven by ch33; y by buoyancy
       yaw:        f32,         // ch33 will own this
       pitch, roll: f32,
       // smoothing state
       y_vel, pitch_vel, roll_vel: f32,
       // hull sample geometry (local space, meters)
       half_length, half_beam: f32,   // e.g. 2.4 and 0.9 for the ch17 hull
       node: ^Transform,              // the ch18 hierarchy root
   }
   ```

   Eyeball `half_length`/`half_beam` from your OBJ's bounds — sample points should sit at ~80% of the hull extents, roughly at the waterline.

2. **Write the sampler.** Rotate local offsets by yaw, query the ocean:

   ```odin
   boat_sample_heights :: proc(b: Boat, o: Ocean, t: f32) -> (bow, stern, port, starboard: f32) {
       s, c := math.sin(b.yaw), math.cos(b.yaw)
       local_to_world :: proc(b: Boat, s, c: f32, local: glsl.vec2) -> glsl.vec2 {
           return {b.position.x + local.x*c - local.y*s,
                   b.position.z + local.x*s + local.y*c}
       }
       bow       = ocean_height_at(o, local_to_world(b, s, c, {0,  b.half_length}), t)
       stern     = ocean_height_at(o, local_to_world(b, s, c, {0, -b.half_length}), t)
       port      = ocean_height_at(o, local_to_world(b, s, c, {-b.half_beam, 0}), t)
       starboard = ocean_height_at(o, local_to_world(b, s, c, { b.half_beam, 0}), t)
       return
   }
   ```

   (Mind your yaw convention from the camera chapter — if the boat ends up pitching when she should roll, your local axes are swapped; see Pitfalls.)

3. **Write `boat_update_buoyancy`** in the fixed-step update:

   ```odin
   boat_update_buoyancy :: proc(b: ^Boat, o: Ocean, t, dt: f32) {
       bow, stern, port, starboard := boat_sample_heights(b^, o, t)

       target_y     := (bow + stern + port + starboard) * 0.25
       target_pitch := math.atan2(bow - stern,      b.half_length * 2.0)
       target_roll  := math.atan2(port - starboard, b.half_beam   * 2.0)

       smooth_damp(&b.position.y, &b.y_vel,     target_y,     0.35, dt)
       smooth_damp(&b.pitch,      &b.pitch_vel, target_pitch, 0.50, dt)
       smooth_damp(&b.roll,       &b.roll_vel,  target_roll,  0.50, dt)
   }
   ```

   Those smooth times (0.35 s height, 0.5 s angles) are a small boat. A heavy ketch wants 0.6/0.9; a dinghy 0.2/0.3.

4. **Drive the hierarchy root.** Compose the root transform in the order translate → yaw → roll → pitch, so pitch and roll are *boat-relative*:

   ```odin
   b.node.local = glsl.mat4Translate(b.position) *
                  glsl.mat4Rotate({0, 1, 0}, b.yaw) *
                  glsl.mat4Rotate({0, 0, 1}, b.roll) *
                  glsl.mat4Rotate({1, 0, 0}, b.pitch)
   ```

   The mast, boom, and anything else parented in Chapter 18 comes along free — that's why the hierarchy exists.

5. **Park her somewhere visible and watch.** Set `position` to open water near your start island, run, and study her through a few wave trains. Then crank `steepness` to 0.85 and confirm she takes the steeper sea gracefully (the smoothing eats the sharp crest accelerations).

6. **Promote the Chapter 19 buoys** if you took Chapter 31's integration advice — same `ocean_height_at` call, plus optional tiny pitch/roll with two samples. Everything that floats in Saltwind floats through this one function now. That's the CPU/GPU discipline made visible.

## Checkpoint

The hull rises and falls with each swell, bow pitching up the face and down the back, with a slow secondary roll when waves pass abeam. Nothing jitters, even in chop.

- Crest passes amidships: boat is level at the top, pitched on both faces. Wave shorter than the hull: she barely reacts.
- Set both smooth times to 0.01 — instant nervous twitching. Restore. (You've just *seen* what the damping buys.)
- The waterline stays visually glued: no daylight under the keel in troughs, deck never awash on crests. If either happens, your sample points are wider than the real hull — pull them in.
- Pause the sim (Chapter 10 pause): boat freezes *with* the waves, no drift. (Same clock everywhere.)

## Pitfalls

- **Boat floats above or below the visible water.** CPU/GPU desync — the Chapter 28 lockstep broke. Re-run the debug-cube test from that chapter; usually a shader-only tweak or a second time variable.
- **She rolls when she should pitch.** Local axes swapped relative to your model: many OBJ hulls face −Z or +X. Fix in `boat_sample_heights`'s offsets, not by re-exporting the model.
- **Jitter that smoothing won't kill.** You're calling `boat_update_buoyancy` from the render loop with render `dt` while the clock advances in fixed steps — sample and smooth in the *fixed* update only.
- **Slow vertical oscillation that never settles.** You implemented an underdamped spring by hand instead of `smooth_damp` (or broke the `e` approximation). Critical damping must not overshoot, ever.
- **Boat works until you raise `steepness`, then sinks at crests.** Remember `ocean_height_at` inverts horizontal displacement iteratively; if you "optimized" the iteration away, steep crests are exactly where it matters.

## Exercises

1. Add keyboard nudges (temporary) to drag the boat's x/z and watch her cross wave trains at angles — your first taste of Chapter 33.
2. Expose `half_length` as a debug-tweakable and double it: a longer "virtual hull" rides chop more smoothly. Real naval architecture, one variable.
3. Sample a 5th point at the boat's center and compare it to the 4-point average; print the difference. When the wave is shorter than the hull, the disagreement is your averaging *working*.
4. **Stretch:** read the Kerner article and implement a toy version on a cube: 8 corner samples, per-corner submerged-depth force, gravity, linear drag. Compare its behavior to the boat's. Now you know exactly what you're *not* shipping, and why.

## Commit

`git commit -m "ch32: graphics buoyancy - boat rides the gerstner sea"`

← [Chapter 31 — Milestone: Ocean at Sunset](../part-5-the-living-sea/ch31-milestone-ocean-at-sunset.md) · [Chapter 33 — The Wind in Your Sail](ch33-the-wind-in-your-sail.md) →
