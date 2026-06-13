# Chapter 93 — Other Captains

*Part 14 — A Crowded Sea · Estimated time: 4.5h · learnopengl: no direct equivalent — this is game-systems material*

**What you'll see when done:** sails on the horizon that aren't yours. Follow one in: she rounds the headland, drops speed off Gullhaven's quay, sits loading for a sim-hour, and casts off for Kelpmouth — because timber is dear there this week, and she checked the same prices you do.

## Where we are

Chapters 91–92 built a ship that can sail anywhere on its own. This chapter builds the *someone* who decides where: a `Captain` with a ship, a route, a goal, a name, and opinions. The design principle carries over from ch92 and is worth stating once, hard: **NPCs play the same game as the player.** They read the same `port_price` numbers, sail the same polar, dock at the same quays, wait out the same loading. No teleporting, no invented gold. The payoff lands in ch94 — their trades will move the same economy you trade in — but it already pays here: a ship you can follow from decision to dock without catching it cheating is a ship the player invents stories about.

## Concepts

### The Captain

A captain is a small pile of state with a state machine on top:

```
        ┌──────────┐  arrived & slow  ┌──────────┐  dwell done  ┌──────────┐
        │ Sailing  │ ───────────────> │ Docking  │ ───────────> │ Loading  │
        └──────────┘                  └──────────┘              └──────────┘
             ^                                                       │ buy/sell, pick next route
             └───────────────────────────────────────────────────────┘
                                  (or Idle, if no route pays)
```

`Sailing` runs ch92's AI down a ch91 route. `Docking` is `arrive` with the sail eased — close on the quay, kill way, snap nothing. `Loading` is a **dwell timer**, and don't skimp on it: a ship that sits at the quay for a sim-hour is *visible commerce* — you sail past, see her moored where yesterday there was empty stone, and the world reads as inhabited. `Idle` is the honest state for "no route currently profits"; idle ships swing at anchor in the roads, which is also scenery.

### Picking routes from the real economy

Route selection is three nested loops over data you already ship: for each good, for each destination port, score `(price_there − price_here) · affordable_qty` against the time to sail it (straight-line over estimated polar speed is a fine estimate; the route refines it). The crucial property is *what's absent*: no scripted routes, no spawn tables. When Palmstrand's rum glut deepens, more captains pick Palmstrand — emergent scheduling from four lines of arithmetic. Personality enters as weights, not branches: a `greed` parameter trades profit against distance, `patience` scales dwell, `caution` widens ch92's avoidance margins and corridor. Three floats per captain and no two ships behave alike — cheap character, the best kind.

### Simulation LOD — the load-bearing pattern

Ten ships running full ch32/ch33 physics with four `ocean_height_at` samples each is real CPU spend on actors the player mostly can't see. The pattern that fixes it appears in every open-world game ever shipped, and this is the right place to learn it explicitly:

- **Full** (near the player): the complete stack — steering, sailing physics, buoyancy, wake, the works. The ship must withstand being *watched*.
- **Coarse** (far away): no physics at all. Advance a `progress` scalar along the route at the speed the polar *says* this leg makes good, place the ship at the path point, done. A few multiplies per ship. The ship must merely *exist correctly* — be in a plausible place, at a plausible time, with plausible cargo.

The two rules that make it invisible: **hysteresis** (promote at 350 m, demote at 450 m — a single threshold flickers ships across the boundary) and **conservation of truth** (the coarse model must agree with the full model *on average* — same polar, same wind — or ships visibly lurch at promotion, and worse, far ships arrive systematically earlier than near ones, which ch94's economy would faithfully turn into a price bug).

### Spawning, despawning, and names

Population policy: hold `TARGET_CAPTAINS` (8–12) alive. Spawn replacements in `Loading` at a port beyond the player's sight radius — ships materialize *moored*, never mid-ocean in open view. Despawn only ships that are Coarse, far, and route-complete; a captain mid-contract owes the economy a delivery (ch94 will hold the debt).

And names. Hash the world seed with the captain's spawn ordinal through ch25's FNV-1a — the same six lines that named your world — and index syllable tables: *Saltrunner*, *Pearl Heron*, *Stormdancer*. Same seed, same fleet. The name goes in the dock UI and the spyglass HUD; players will develop grudges against specific ships, which is exactly the point of naming things.

### Sails first

The romance requirement: you should spot a ship as a fleck of white long before you can name her hull. You don't need planetary curvature for it — two existing systems already conspire. Distance fog (ch47) and atmospheric perspective eat low-albedo, low-silhouette geometry (a dark hull at the waterline) several hundred meters before they eat a tall, sun-lit sail. Lean in: keep the sail mesh in the far LOD after the hull drops to a box (or nothing), and let the fleck resolve as she closes — sail, then mast, then hull, then name. Spotting traffic from the masthead becomes a small pleasure, which is what most of "alive" is made of.

## Odin notes

Captains live in a `[dynamic]Captain` owned by `Game` — and per ch35's law, **handles, not pointers**: despawn swaps-and-pops, so any stored `^Captain` (the COLREGS pair cache from ch92 is the sneaky one) must be an index or generation handle instead. If you took ch35's optional ash path, captains are a textbook archetype — `{Ship, Route, Captain_Brain}` — and the spawn/despawn queue replaces your swap-and-pop; either storage serves the chapter equally. Strings from the name generator are allocated once at spawn; free them at despawn (`delete(c.name)`) or spawn-leak forever.

## Build

1. **The struct,** in `src/captain.odin`:

   ```odin
   Captain_State :: enum u8 { Sailing, Docking, Loading, Idle }
   Sim_Lod      :: enum u8 { Full, Coarse }

   Captain :: struct {
       name:      string,
       ship:      Boat,            // the ch32/33 type, unmodified
       ai:        Ship_Ai,         // ch92: helm, path, tack state
       state:     Captain_State,
       lod:       Sim_Lod,
       at_port:   int,             // valid in Docking/Loading/Idle
       dest_port: int,
       good:      Good_Id,
       qty:       int,
       coins:     int,             // they keep books; ch94 audits them
       dwell:     f32,             // sim-seconds left at the quay
       progress:  f32,             // distance along route (Coarse uses it; Full syncs it)
       greed, caution, patience: f32,   // 0..1, rolled at spawn from the seeded rng
   }
   ```

2. **Route selection** — the same data the trade screen reads:

   ```odin
   captain_pick_route :: proc(c: ^Captain, e: ^Economy) -> bool {
       best_score: f32 = 0
       for good in Good_Id {
           here := port_price(e, c.at_port, good)
           afford := min(c.coins / max(here, 1), hold_capacity(c, good))
           if afford <= 0 do continue
           for p in 0 ..< len(PORTS) {
               if p == c.at_port do continue
               profit := (port_price(e, p, good) - here) * afford
               if profit <= 0 do continue
               hours := route_time_estimate(c.at_port, p)            // dist / polar avg
               score := f32(profit) / math.pow(hours, 1.0 + c.greed) // greedy = distance-blind
               if score > best_score {
                   best_score = score
                   c.good, c.qty, c.dest_port = good, afford, p
               }
           }
       }
       return best_score > MIN_WORTH_SAILING   // below it: Idle, honestly
   }
   ```

   For now the buy/sell at each end only moves the captain's own `coins` ledger — port prices don't feel it yet. That asymmetry is deliberate and temporary; ch94 exists to close it.

3. **The state machine,** ticked in the fixed step:

   ```odin
   captain_update :: proc(c: ^Captain, g: ^Game, dt: f32) {
       switch c.state {
       case .Loading, .Idle:
           c.dwell -= dt
           if c.dwell <= 0 {
               if captain_pick_route(c, &g.economy) {
                   captain_buy(c, &g.economy)
                   c.ai.path = request_route(g, c.at_port, c.dest_port)  // ch91 (queued in ch96)
                   c.state = .Sailing
               } else {
                   c.state = .Idle; c.dwell = 60 * c.patience           // check back later
               }
           }
       case .Sailing:
           captain_sail(c, g, dt)                                       // step 4: LOD switch
           if route_remaining(c) < DOCK_APPROACH do c.state = .Docking
       case .Docking:
           captain_dock_approach(c, g, dt)        // arrive behavior, sail eased
           if captain_moored(c) {
               captain_sell(c, &g.economy)
               c.at_port = c.dest_port
               c.state = .Loading
               c.dwell = (1800 + 1800 * c.patience) // half to one sim-hour, visible at the quay
           }
       }
   }
   ```

4. **The LOD switch** — the pattern, explicit:

   ```odin
   captain_sail :: proc(c: ^Captain, g: ^Game, dt: f32) {
       d := glsl.distance(c.ship.position.xz, g.boat.position.xz)
       if c.lod == .Coarse && d < 350 do captain_promote(c, g)    // hysteresis: two thresholds
       if c.lod == .Full   && d > 450 do c.lod = .Coarse

       switch c.lod {
       case .Full:
           ship_ai_update(&c.ai, &c.ship, g, dt)                  // ch92, all of it
           boat_update_sailing(&c.ship, g.wind, dt)               // ch33, unmodified
           boat_update_buoyancy(&c.ship, g.ocean, dt)             // ch32, unmodified
           c.progress = path_progress_of(c.ai.path[:], c.ship.position.xz)
       case .Coarse:
           heading := path_heading_at(c.ai.path[:], c.progress)
           rel := angle_wrap(g.wind.direction - heading - math.PI)
           c.progress += g.wind.strength * 0.6 * sail_power(rel) * dt   // ch33's speed formula, no dynamics
           p := path_point_at(c.ai.path[:], c.progress)
           c.ship.position = {p.x, 0, p.y}
           c.ship.yaw = heading
       }
   }
   ```

   `captain_promote` seeds the full model from the coarse one — position from the path, `speed` from the coarse formula, `y` from `ocean_height_at` — so the handoff is seamless. Note the Coarse branch deliberately reuses `sail_power`: conservation of truth, enforced by sharing the formula.

5. **Population,** once per sim-minute: count live captains; below target, spawn one `Loading` at a port > 600 m from the player (seeded rng picks port and personality; FNV-1a of `(world_seed, spawn_ordinal)` names her). Above target — only after route-complete, Coarse, and far — swap-remove. Spawn ordinal increments forever; it's what keeps names stable per seed.

6. **Render the fleet.** Full-LOD ships use your existing boat draw (hull, sail with trim angle, ch34 wake — wakes for the nearest 3 only; ch96 revisits the budget). Coarse ships: hull-box plus the *real sail mesh* held to far distance, per Concepts. Bob `y` with a cheap single `ocean_height_at` sample only when within ~800 m; beyond that nobody can see the waterline anyway.

7. **Watch one full loop.** Debug-pin a captain (microui: name, state, dest, cargo, coins, LOD) and follow her: load at the quay, beat out of the bay, coarse-out when you fall behind, dock at the far port. The pin panel is your truth instrument for the next three chapters — build it well.

## Checkpoint

- 8–12 named ships stay alive indefinitely; the fleet census (debug panel) shows a believable mix of Sailing/Loading/Idle at any moment.
- Follow one ship dock to dock: every state transition visible, no teleports, dwell long enough to *see* her moored.
- Sit at 400 m and drift across the LOD boundary: no pop, no lurch, no speed change you can point to (log promotions while tuning).
- Restart with the same seed: same captains, same names, same opening routes. Same sea, same souls.
- Sails resolve before hulls on approach; the spyglass moment works at dawn with fog up.

## Pitfalls

- **Far ships arrive faster (or slower) than near ones.** The coarse speed formula drifted from the full model — different multiplier, or it ignores wind. Same `sail_power`, same `0.6`, same wind, or ch94 inherits a systematic freight-rate error you'll hunt for a week.
- **Ships flicker between LODs at the boundary.** One threshold instead of two. Hysteresis isn't optional; 100 m of gap is the price of calm.
- **A despawn crashes the COLREGS pass.** Stored `^Captain`/`^Boat` across the swap-and-pop. Indices or handles (ch35), and run despawns at a defined point in the tick, never mid-iteration.
- **Every captain picks the same best route.** They're deciding from identical state with identical weights — the fleet convoys. Personality spread plus *decision-time jitter* (re-pick on personal timers, not all on the same minute) fixes it; ch94's price impact will finish the job by making crowded routes self-defeating.
- **Captains go broke and idle forever.** `MIN_WORTH_SAILING` too high, or they buy at prices that leave no margin after your rounding. Give spawn coins a healthy float and log any captain whose balance trends down across three routes — that log *is* ch94's balancing tool, arriving early.
- **Ships spawn in front of the player.** Your "beyond sight" radius ignores the spyglass/chart. Spawn moored at ports outside the *fog* distance, and never promote a freshly spawned ship for its first minute.

## Exercises

1. A **harbor log** at each port (dock UI tab): the last five arrivals/departures with name, cargo, and destination — three lines of bookkeeping in `captain_dock_approach`/cast-off, and suddenly ports have gossip. ("*Stormdancer*, out of Kelpmouth, bound for Pearl Shallows with rum.")
2. Add a **hail**: sail within 30 m of a Full-LOD ship and press E — a HUD line reports her name, destination, and cargo. One distance check plus data you already have; it makes ch94's "read the world" play style tactile.
3. Personality audit: spawn 50 captains headless (no render) for a fast-forwarded sim-day and histogram routes-by-greed. Verify greedy captains measurably favor short hops — if the parameter doesn't show up in data, it isn't real.
4. **Stretch:** weather courage. Feed ch47/ch74's storm state into route selection — `caution` scales a storm penalty on exposed legs, so timid captains harbor-wait while bold ones sail. After ch94, watch a storm create a *delivery gap* the brave exploit. (That sentence is the whole economy chapter, foreshadowed.)

## Commit

`git commit -m "ch93: captains — states, economy-driven routes, sim LOD, spawn policy, named fleet"`

← [Chapter 92 — Rules of the Road](ch92-rules-of-the-road.md) · [Chapter 94 — The Invisible Hand, Visible](ch94-the-invisible-hand-visible.md) →
