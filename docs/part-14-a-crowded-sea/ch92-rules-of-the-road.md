# Chapter 92 — Rules of the Road

*Part 14 — A Crowded Sea · Estimated time: 5h · learnopengl: no direct equivalent — game AI material; the source is Craig Reynolds' "Steering Behaviors for Autonomous Characters" (GDC 1999)*

**What you'll see when done:** a ship with nobody aboard sails the route from chapter 91 — trimming, tacking through the no-go zone in honest zigzags, swerving off a sandbar — and when two of them meet crossing off the port mouth, the give-way vessel bears away astern of the other, exactly like she's read the rulebook.

## Where we are

Chapter 91 answers *which way*; this chapter answers *how to sail it*. The temptation — and the way most tutorials do it — is to give NPC ships their own cheap movement: lerp along the path, slide around obstacles, done. Resist it. The entire character of this part comes from one decision: **NPC ships sail under the same physics as the player.** Same `Wind`, same `sail_power` polar, same rudder authority that fades at low speed, same no-go cone. An AI that must *earn* its way upwind is an AI whose ships heel on a reach and stall in irons where yours would — and when you overtake one beating into a channel, tack for tack, the world stops being scenery. The price of that honesty is this chapter: autonomy expressed not as positions, but as *helm orders*.

## Concepts

### Steering behaviors, and what we keep

Reynolds' 1999 framework is the lingua franca of game movement: simple procs (**seek**, **arrive**, **path-follow**, **avoid**…) each compute a desired velocity from local information, and a blend of them drives the agent. We keep the *decomposition* — small behaviors, each owning one concern, combined by priority — but change the output type. Reynolds' agents apply steering forces directly; our boats can't, because a sailboat doesn't get to choose its acceleration. The wind does. So every behavior here distills to a single number: a **desired heading**. The physics decides what that heading is worth.

### The helm controller — this chapter's heart

Between "I want heading θ" and the ch33 model sits the part that makes everything else work: a small controller that turns heading error into rudder, the way a helmsman does. Pure proportional control (`rudder = k·error`) overshoots and S-curves forever, because the boat has yaw momentum the proportional term can't see. The fix is the **D term** — damp by the *rate of change* of the error, which is the controller noticing "I'm already swinging toward the mark, ease off":

```
rudder = clamp(Kp · error + Kd · d(error)/dt, -1, +1)
```

That's a PD controller, the workhorse of every physical control problem from quadcopters to inverted pendulums, and ten lines of Odin. (The missing "I" of PID handles steady-state bias — weather helm, in our terms — which our boats don't have; add it the day they do.) Two tuning truths worth pre-loading: `Kp` sets eagerness, `Kd` sets composure, and you tune by watching wakes — a snake-shaped wake means raise `Kd` or lower `Kp`; a wide lazy arrival means the opposite. Trim, mercifully, is already solved: NPCs run ch33's `auto_trim` and are, canonically, the bosun it was named for.

### Path following, arrival, and the no-go problem

**Path-follow** chases a point that slides along the ch91 waypoint chain just ahead of the ship — chase a *moving carrot*, not the next waypoint itself, or the ship scallops between points. **Arrive** caps desired speed as the goal nears (we can't command speed directly, so the controller's proxy is to ease the sail out — drop `auto_trim` and over-ease near the dock; ch93's docking leans on this).

Then the real problem: the carrot is dead upwind. The polar says heading there produces zero power — desire all you like, the boat stalls. A sailor **tacks**: sails close-hauled ~45° off the wind on one side, then the other, making good a zigzag whose average is the forbidden heading. That's a small state machine, not a behavior blend — discrete mode, hysteresis, an explicit switch event — and it's the difference between an AI that sails and an AI that drifts to a stop pointing at its goal:

```
            ▲ wind
   ════════════════════ no-go cone (±~45°)
      ↗ Port_Tack
     /        target dead upwind, corridor around the rhumb line
     \  ← switch when cross-track > corridor half-width
      ↘ Starboard_Tack
     /
    boat
```

### Avoidance: feelers, and ships with manners

Terrain avoidance is Reynolds' classic **feelers**: probe ahead of the bow (and ±30°) a distance that grows with speed, sampling `terrain_height_at` — the *terrain function*, not the ch91 grid, because the grid was eroded for planning margins and the question here is "will I *actually* ground". A hit biases the desired heading away, weighted by urgency (closest hit wins).

Ship-vs-ship is different in kind: the obstacle maneuvers too, and if both ships dodge symmetrically they dance into each other — the corridor-shuffle problem. Real mariners solved it in 1862 with the COLREGS, and we take the flavor of Rule 15: **in a crossing, the vessel that has the other on her starboard side gives way** (preferably by turning to pass astern); the other is the *stand-on* vessel and holds course. Asymmetry is the whole trick — exactly one ship maneuvers, so the negotiation is silent and deterministic. To know a crossing is *converging* you compute the **closest point of approach** (CPA): with relative position `p` and relative velocity `v`, the time of closest approach is `t* = -dot(p, v)/dot(v, v)`; if `t*` is positive-and-soon and the separation at `t*` is under a couple of boat lengths, act.

### Blending: priorities, not soup

With four behaviors emitting headings, how do they combine? Weighted averaging — Reynolds' simplest scheme — fails at the worst moment: averaging "hard to port, rocks!" with "to starboard, on route" yields "straight on, confidently". Use **priority override with a bias channel** instead: terrain avoidance, when triggered, *replaces* the desired heading outright; COLREGS adds a bounded heading bias; path-follow supplies the default. One `switch`, readable at 2 a.m., and the failure mode is "too cautious" instead of "split the difference into the reef".

## Build

1. **The helm,** in `src/steering.odin`:

   ```odin
   Helm :: struct {
       desired_heading: f32,
       prev_err:        f32,
       kp, kd:          f32,    // start: 1.8, 0.9
   }

   helm_update :: proc(b: ^Boat, h: ^Helm, dt: f32) {
       err  := angle_wrap(h.desired_heading - b.yaw)
       derr := angle_wrap(err - h.prev_err) / dt
       h.prev_err = err
       b.rudder = clamp(h.kp * err + h.kd * derr, -1.0, 1.0)
   }
   ```

   Call it in the fixed step *before* `boat_update_sailing` — the controller writes the same `rudder` field the player's keys write, which is the whole architecture in one sentence. Smoke-test: hard-set `desired_heading`, watch the ship come about and settle without snaking. Tune `kp`/`kd` here, now, on this test — every later behavior inherits the tuning.

2. **Path-follow with a sliding carrot.** Keep a `progress` scalar (distance along the smoothed ch91 waypoint chain); each tick, advance it so the carrot sits `LOOK_AHEAD` (~35 m) past the ship's closest point on the path, then aim at it:

   ```odin
   steer_path :: proc(s: ^Ship_Ai, b: ^Boat) -> f32 {
       carrot := path_point_at(s.path[:], s.progress + LOOK_AHEAD)
       to := carrot - b.position.xz
       return math.atan2(to.x, to.y)        // +Z = 0, ch33's convention
   }
   ```

   Never let `progress` move backward — a ship blown past a waypoint should press on, not loop back to formally collect it.

3. **The tack state machine.** Wrap the path heading before it reaches the helm:

   ```odin
   Tack_State :: enum u8 { Direct, Port_Tack, Starboard_Tack }
   NO_GO :: f32(0.8)   // ~46°: a hair outside the polar's dead zone, so close-hauled still pulls

   tack_resolve :: proc(s: ^Ship_Ai, b: ^Boat, w: Wind, want: f32) -> f32 {
       into_wind := angle_wrap(w.direction + math.PI)
       off := angle_wrap(want - into_wind)
       if abs(off) > NO_GO { s.tack = .Direct; return want }       // sailable as-is

       if s.tack == .Direct {                                      // entering the cone: pick a board
           s.tack = off >= 0 ? .Starboard_Tack : .Port_Tack
       }
       cross := cross_track_error(s.path[:], s.progress, b.position.xz)
       if abs(cross) > TACK_CORRIDOR {                             // ~60 m: time to come about
           s.tack = cross > 0 ? .Port_Tack : .Starboard_Tack
       }
       return s.tack == .Starboard_Tack ? angle_wrap(into_wind + NO_GO)
                                        : angle_wrap(into_wind - NO_GO)
   }
   ```

   The hysteresis lives in `TACK_CORRIDOR`: the ship holds each board until it has genuinely strayed, then comes about *once*. Watch one beat upwind end to end — the helm swings, the boat carries way through the eye exactly like your own good tacks do, the bosun jibes the boom (ch33 ex.2 pays off unprompted on every AI ship).

4. **Terrain feelers,** highest priority:

   ```odin
   steer_avoid_terrain :: proc(b: ^Boat, want: f32) -> (heading: f32, urgent: bool) {
       reach := 25.0 + b.speed * 6.0
       for offs in ([3]f32{0, 0.5, -0.5}) {
           dir := angle_wrap(b.yaw + offs)
           step: f32 = 8
           for d := step; d <= reach; d += step {
               p := b.position.xz + glsl.vec2{math.sin(dir), math.cos(dir)} * d
               if terrain_height_at(p) > SEA_LEVEL - DRAFT {
                   away := offs >= 0 ? f32(-1.1) : f32(1.1)     // turn away from the hit feeler
                   return angle_wrap(b.yaw + away * (1.0 - d/reach + 0.4)), true
               }
           }
       }
       return want, false
   }
   ```

5. **CPA + COLREGS** as a bounded bias among ships within ~120 m:

   ```odin
   colregs_bias :: proc(me, other: ^Boat) -> f32 {
       p := other.position.xz - me.position.xz
       v := boat_velocity_xz(other) - boat_velocity_xz(me)
       t := -glsl.dot(p, v) / max(glsl.dot(v, v), 0.001)
       if t < 0 || t > 25 do return 0                            // diverging or far future
       if glsl.length(p + v * t) > 18 do return 0                // passes clear
       rel := angle_wrap(math.atan2(p.x, p.y) - me.yaw)
       if rel > 0 && rel < math.PI/2 do return 0.55              // she's to starboard: give way,
       return 0                                                  //   bear off to pass astern
   }
   ```

   The give-way ship adds the bias (sign per your yaw convention — verify against ch33's: positive rudder must turn the bow toward positive `rel`); the stand-on ship returns 0 and *holds course*, which is her job. Add a pinch of personality jitter to the 0.55 in ch93 so no two captains shave it equally close.

6. **Compose** in priority order — one proc, one spine:

   ```odin
   ship_ai_update :: proc(s: ^Ship_Ai, b: ^Boat, g: ^Game, dt: f32) {
       want := steer_path(s, b)
       want  = tack_resolve(s, b, g.wind, want)
       want += colregs_bias_sum(b, g)                       // bounded nudge
       if h, urgent := steer_avoid_terrain(b, want); urgent do want = h   // override
       s.helm.desired_heading = angle_wrap(want)
       helm_update(b, &s.helm, dt)
   }
   ```

   Then the existing, unmodified `boat_update_sailing(&b, g.wind, dt)` does the sailing. Note what this proc *doesn't* contain: speed, position, physics. Helm orders only.

7. **Stage the crossing.** Two AI ships on perpendicular routes timed to collide off the port mouth (debug-spawn key). Watch: the ship with the other to starboard eases away, crosses astern, and resumes her route; the stand-on ship never wavers. Save this setup — it's a checkpoint here and a set piece in ch96.

## Checkpoint

- A lone AI ship sails a full ch91 route — reaches, runs, and an honest upwind beat with clean, countable tacks — and arrives without grounding.
- The wake tells the controller story: long fair curves, no snaking; rudder saturation only during tacks and emergencies.
- The staged crossing resolves asymmetrically: give-way bears off astern, stand-on holds course, no mutual-dodge waltz, no spiral of politeness.
- Drop the wind to near-calm: the AI ship slows and her turns go sluggish *exactly* like yours do, because it is the same code feeling the same calm.

## Pitfalls

- **The ship S-curves down every leg.** PD gains tuned at one speed, wrong at another — rudder authority scales with speed (ch33), so effective gain does too. Either schedule `kp` by `1/authority` or just tune at cruise speed and accept lazy low-speed turns (real boats have them).
- **`derr` spikes and the rudder chatters.** You forgot to `angle_wrap` the error *difference* — when `err` crosses the ±π seam, the raw difference jumps by 2π and the D term kicks the helm hard over. Wrap every angle subtraction, every time, forever.
- **The ship parks bow-to-wind, forever in irons.** Desired heading inside the no-go cone with no tack machine, or `NO_GO` set *inside* the polar's dead zone so the close-hauled heading itself has no power. The tack headings must sit where `sail_power` already pulls.
- **Tacks every two seconds.** Corridor too narrow, or you re-pick the board from scratch each tick instead of holding state. The enum is not decoration — hysteresis *is* the machine.
- **Two ships orbit each other.** Both decided to give way — your relative-bearing test is symmetric (sign error) so each sees the other "to starboard". Log both verdicts; in a legal crossing exactly one may be true.
- **Avoidance fights path-follow into a wall.** You averaged instead of overriding. Priority means the lower layer is *silent* when the higher one speaks.

## Exercises

1. **Helm telemetry:** plot `desired_heading`, `yaw`, and `rudder` as three strips in the debug panel (the ch48 batcher; ch94 builds sparklines you can back-port). Watching a tack as three traces teaches more control theory than this chapter has room for.
2. Give the player a **autopilot**: press P with a chart waypoint set (ch79) and your own boat runs `ship_ai_update` to it. You've built cruise control from spare parts — and it's the single best way to *feel* your gain tuning.
3. Implement Rule 14 (head-on: **both** alter to starboard) and Rule 13 (overtaking vessel keeps clear regardless of side). Each is one extra relative-bearing band in `colregs_bias`.
4. **Stretch:** replace the three fixed feelers with a **shadow steer**: simulate the ch33 model forward 8 s at coarse dt for three candidate headings (current, ±35°) and score each by clearance and progress — pick the best. This is model-predictive control in miniature, and it's only affordable because your physics is ten lines.

## Commit

`git commit -m "ch92: PD helm, path-follow, tack state machine, feelers, COLREGS crossing"`

← [Chapter 91 — Lanes of the Sea](ch91-lanes-of-the-sea.md) · [Chapter 93 — Other Captains](ch93-other-captains.md) →
