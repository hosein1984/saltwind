# Interlude 70a — Ropes and Rigging

*⚓ Optional interlude · slots after [Chapter 70](ch70-canvas-and-wind.md) · Estimated time: 3–4h · learnopengl: no direct equivalent — canonical reference: the same [Jakobsen "Advanced Character Physics"](https://www.cs.cmu.edu/afs/cs/academic/class/15462-s13/www/lec_slides/Jakobsen.pdf) you just used*

**Prerequisites:** Chapter 70 (the Verlet integrator and constraint relaxer are the whole engine here). · **Required downstream:** none — skip freely.

**What you'll see when done:** a halyard sagging in its honest catenary on a calm morning, an anchor line that snaps taut and *holds the boat*, and a lantern swinging from the boom that makes every night sail 40% more atmospheric.

## Why this is a side quest

Chapter 70 built a 2D constraint network and called it cloth. Delete one dimension and you have rope — same integrator, same two-line constraint, no shear family, no triangles. The main line moves on because the gull is waiting, but a sailboat without visible rigging is a sailboat in pajamas, and this is the cheapest visual upgrade in the part: maybe ninety minutes of code you already understand, and suddenly the boat has *lines*. It's the victory lap for the cloth chapter — take it.

## Concepts

A rope is a chain of particles with one distance constraint between each neighbor:

```
 taut (slack 0):   pin ●──●──●──●──●──● pin     a straight, humming line

 slack 6%:         pin ●╮              ╭● pin   relaxation finds the catenary —
                        ╰●╮          ╭●╯        nobody computes it, it emerges
                          ╰●──●──●──●╯
 hanging:          pin ●                        boom end
                        ╰●╮
                          ●                     heavy last particle
                          ◉  ← the lantern        (inv_mass 0.25)
```

Everything you know transfers, plus three rope-specific facts:

- **The sag is free.** Pin both ends of a chain with a little slack and relaxation converges to (a fine approximation of) the catenary — the exact curve real ropes hang in. Nobody computes it; it *emerges*, just like luffing did.
- **Chains converge slower than grids.** A correction at one end propagates one constraint per relaxation pass, so a 20-particle rope wants more iterations than the sail did (~12–16), or it goes stretchy. Still microseconds.
- **Unequal mass is one array.** A lantern is just a heavy last particle. Give each particle `inv_mass` (pinned = 0) and split the constraint correction proportionally — the two-liner from ch70 becomes `p1 += delta * err * w1` / `p2 -= delta * err * w2` with `w1 = inv1/(inv1+inv2)`. Heavy things now *swing* the rope instead of riding it.

Wind and boat motion come along for free: wind is a small per-particle force (ropes are thin — no per-triangle orientation needed), and boat motion arrives through the pinned ends exactly as the boom drove the sail foot. Deck collision is one projection: transform the particle into boat space, and if it's below the deck plane, push it up.

## Odin notes

Don't shoehorn this into `Cloth` with `h = 1` — a tiny dedicated struct reads better and the constraint list is implicit (particle `i` to `i+1`):

```odin
Rope :: struct {
    pos, prev:  []glsl.vec3,
    inv_mass:   []f32,           // 0 = pinned
    rest:       f32,             // segment length
    iterations: int,             // 12
    strain:     []f32,           // per-segment, written by the solver (debug + gameplay)
}
```

Allocate in `rope_create(a, b, n, slack)` with `rest = distance(a, b) * (1 + slack) / f32(n - 1)`; never allocate at runtime. `rope_step` is `cloth_step` minus the constraint slice — loop `i ..< n-1` directly — and while satisfying each constraint, store `strain[i] = length / rest`. The solver computes the debug view as a side effect.

## Build

1. **`src/rope.odin`.** `rope_create`, then `rope_step(r, wind_vec, dt)` from the fixed timestep — the whole solver fits on a page:

   ```odin
   rope_step :: proc(r: ^Rope, wind: glsl.vec3, dt: f32) {
       for i in 0 ..< len(r.pos) {                       // integrate
           if r.inv_mass[i] == 0 do continue
           vel := (r.pos[i] - r.prev[i]) * 0.995
           r.prev[i] = r.pos[i]
           r.pos[i] += vel + (glsl.vec3{0, -9.8, 0} + wind * 0.3) * dt * dt
       }
       for _ in 0 ..< r.iterations {                     // relax
           for i in 0 ..< len(r.pos) - 1 {
               delta := r.pos[i + 1] - r.pos[i]
               l := glsl.length(delta)
               r.strain[i] = l / r.rest
               w_sum := r.inv_mass[i] + r.inv_mass[i + 1]
               if w_sum == 0 do continue                 // both pinned
               corr := delta * ((l - r.rest) / (l * w_sum))
               r.pos[i]     += corr * r.inv_mass[i]
               r.pos[i + 1] -= corr * r.inv_mass[i + 1]
           }
       }
   }
   ```

   Order per fixed step: write pins from the scene graph (and set their `prev = pos` — same teleport law as ch70) → `rope_step` → collision.

2. **Three ropes, three behaviors.**
   - **Halyard:** masthead node → a cleat at the mast foot, `slack = 0.06`, both ends pinned to the boat's scene nodes (ch18). It sags. That's the feature.
   - **Anchor line:** bow fairlead → the anchor's drop point on the seabed (cast it when the player anchors; despawn otherwise). `slack = 0.02`, ~30 particles.
   - **Lantern:** boom end → 6 particles, last one with `inv_mass = 0.25` and the ch15 lantern (light and all) parented to it, oriented along the final segment.

3. **The payoff coupling.** Each fixed step while anchored, read the anchor line's end-segment strain; above 1.0, apply a restoring force to the boat along the rope toward the anchor, proportional to `(strain - 1)`. The boat now drifts downwind, fetches up on its rode with a visible jerk, and *swings at anchor* — boat physics and rope physics agreeing through one f32. This is the moment the interlude stops being decoration.

4. **Deck collision.** After relaxation: transform each particle to boat space; if inside the deck's top-plane footprint and below it, clamp `y` to the deck and pull `prev` toward `pos` (kills sliding jitter — it's friction, squint). The swinging lantern now lands on the deck in a storm instead of passing through it.

5. **Ribbon rendering.** A camera-facing strip, same idea as the ch34 wake — for each particle:

   ```odin
   for i in 0 ..< n {
       prev_i, next_i := max(i - 1, 0), min(i + 1, n - 1)
       tangent := glsl.normalize(r.pos[next_i] - r.pos[prev_i])
       to_cam  := glsl.normalize(cam_pos - r.pos[i])
       side    := glsl.normalize(glsl.cross(tangent, to_cam)) * radius
       verts[i * 2 + 0] = {r.pos[i] - side, {0, f32(i) / f32(n - 1)}}
       verts[i * 2 + 1] = {r.pos[i] + side, {1, f32(i) / f32(n - 1)}}
   }
   ```

   `BufferSubData` per frame like the sail; static indices. A 3cm-wide strip with a rope texture reads perfectly at gameplay distance. (True cylinder segments: exercise 2.)

6. **Tension debug view.** Panel toggle: draw each segment with the ch53 debug lines colored `lerp(green, red, clamp(strain - 1, 0, 1) * 10)`. Watch the halyard flash red in gusts and the anchor rode breathe with the swell — the simulation telling you the truth again, in color.

## Checkpoint

At anchor in a building breeze: the boat falls back, the rode straightens segment by segment, goes red at the bow, and the boat swings nose-to-wind. The lantern swings through a tack and settles with a damped wobble. The halyard hangs quiet and curved.

- Tension view: calm = all green with sagging curves; storm = taut red anchor rode, flickering halyard.
- Ram the throttle in circles: nothing explodes, nothing stretches past ~1.2× visibly (iterations doing their job).
- All ropes together cost < 0.05 ms on the ch49 CPU timer.
- Cut the engine at night and watch the lantern. If you don't sit there an extra minute, file a bug against your own soul.

## Pitfalls

- **Rope stretches like taffy.** Too few iterations for the chain length, or you forgot the mass-weighted split and pinned ends are absorbing correction. 12–16 passes; pins take zero.
- **Explodes when the boat tacks or teleports.** Pinned `prev` not updated with `pos` — the constraint sees infinite velocity. Same bug as ch70's, same fix, you'll still write it twice.
- **Lantern orbits like a centrifuge.** Its damping is the rope's 0.995 — too lively for a heavy pendulum. Damp the last particle harder (0.97) or it never settles.
- **Rope vibrates on the deck.** You projected `pos` but left `prev` below the plane, so every step re-adds the velocity. Pull `prev` up too.
- **Anchor force launches the boat.** You applied the restoring force per *render* frame or forgot to clamp strain. Fixed timestep, clamp, and scale by mass — it's a spring, treat it gently.

## Exercises

1. **Mooring lines:** when docked (ch78), two ropes from bow and stern cleats to dock bollards. The boat now visibly *rides* against its lines with the swell — dockside screenshots improve immediately.
2. **Real cylinders:** replace the ribbon with 6-sided tube segments using parallel-transport frames along the rope (carry the previous segment's normal, rotate by the tangent change). Compare close-up; decide if it was worth it (at lantern distance: yes).
3. **Stretch — the parted line:** give the anchor rode a strain limit (say 1.5 sustained for 2s in a storm). When it parts, unpin the seabed end, let the rope whip, and set the boat adrift. Pair with ch74 and ch70's blown-out sail for the full disaster reel.

## Commit

`git commit -m "ch70a: verlet ropes - halyard, anchor rode with boat coupling, swinging lantern, tension debug"`

[← back to Ch. 70: Canvas and Wind](ch70-canvas-and-wind.md) · [onward to Ch. 71: Bones of the Gull →](ch71-bones-of-the-gull.md)
