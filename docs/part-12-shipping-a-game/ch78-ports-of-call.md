# Chapter 78 — Ports of Call

*Part 12 — Shipping a Game · Estimated time: 6h · learnopengl: no direct equivalent — pure game systems*

**What you'll see when done:** you ghost up to the Gullhaven quay, drop anchor, and a trade screen opens — salt cod is cheap here, rum is dear in Palmstrand, and a contract pays 240 coins to prove it. The boat sits visibly deeper when you cast off loaded.

## Where we are

Chapter 77 gave the game its nouns. Today they get verbs: docking, trading, hauling, earning. This is the longest chapter of the part because it builds three muscles you'll reuse through ch81 — a game-state machine, a game UI layer, and the economy simulation. All of it sits on ch35's four-phase frame without bending it.

## Concepts

### The game-state machine

Until now Saltwind had one implicit state: sailing (with pause as a flag). Ports introduce a second mode of being — docked, mouse-driven, sim still ticking but the boat moored. Model it explicitly:

```odin
Game_Mode :: enum { Sailing, Docked, Chart, Menu }   // Chart in ch79, Menu in ch81
```

A small enum switch, not a stack of polymorphic state objects — at four states, the switch is the honest tool. The rule that keeps it clean: **mode gates input and UI; it never forks simulation.** `game_simulate` runs the ocean, weather, and economy identically in every mode (the world doesn't stop because you're shopping); what changes per mode is which *intent* gets written in `game_input` and which screens `game_render` overlays. Transitions live in one proc, `game_set_mode`, so cursor capture, HUD visibility, and (ch82) music stems change in exactly one place.

### Docking: a trigger with manners

The arrival trigger from ch37 ("within radius, you win") graduates: docking should require being *near the quay*, *slow*, and *roughly bow-on*. Distance + speed + heading — three cheap checks that make players actually perform a docking maneuver, which turns every contract's last 30 seconds into gameplay. When eligible, show a prompt ("E — drop anchor at Gullhaven"); on E, kill the boat's velocity, snap nothing (teleporting the boat reads as a bug), and enter `.Docked`.

### Your own game UI (and why microui keeps its job)

ch48 gave you two UI layers: the batched quad/text renderer, and microui on top of it. The trade screen uses the *batcher*, not microui. Reasoning worth internalizing: microui is a superb **tool** UI — gray rectangles, instant widgets, zero styling. A **game** UI is a product surface: it needs your font at your sizes, hover states, layout that breathes, eventually gamepad focus (ch81). Fighting microui's styling to look like a nautical ledger costs more than writing the four widgets you need on machinery you already own. So: microui stays for the debug panel (Tab, forever), and you grow `ui_*` procs — a button, a row, a panel — that draw with `ui_push_quad`/`ui_text` and do immediate-mode hit-testing against the mouse. The pattern is microui's, miniaturized; you already know how it works because you rendered its commands.

### Cargo with consequences

A hold is a count per good plus a capacity from the Hold upgrade. The design gold is making weight *physical*: total cargo tonnage feeds the ch33 sailing model as added mass (slower acceleration, wider turns) and the ch32 buoyancy as a draft offset (the boat rides lower — visible from the dock!). A loaded boat handles like a loaded boat, an empty one feels skittish, and suddenly "do I take the full timber contract or run light and fast?" is a decision made through the rudder, not a spreadsheet. This is the lovely feedback loop: economy → physics → feel → economy.

### A drifting economy

Per port, per good, keep a price multiplier that random-walks with character:

- **Mean reversion** toward a bias set by `produces` (bias low) / `consumes` (bias high) — structure.
- **Noise** scaled by the good's `volatility` — texture.
- **Events** — occasional, named, legible: *"Storm damaged Kelpmouth's docks: timber pays double for two days."* One sentence converts simulation into story; players will swear the economy is deeper than it is, and they'll be right in the way that matters.

Seed the walk from the world seed (ch21) so a given world has *its* economy — and save that seed (ch80 saves the rest). Contracts are then generated *from* the live state: find a good cheap at A and dear at B, offer above-spot reward for the trouble of a deadline.

## Odin notes

Money is `int`. Centimes of floating-point error compound into support emails; integer coins compound into nothing. All prices are coins-per-unit, all math is integer multiply and divide — and when you must scale by a float multiplier, do it as `int(f32(base) * mult + 0.5)` in *one* place (`port_price`) so rounding policy lives in one line. Also: `[Good_Id]int` enumerated arrays make a cargo hold a fixed-size value type — copyable, serializable (ch80), zero allocations.

## Build

1. **Mode machinery.** Add `mode: Game_Mode` to `Game` plus the single transition proc:

   ```odin
   game_set_mode :: proc(g: ^Game, m: Game_Mode) {
       if g.mode == m do return
       g.mode = m
       switch m {
       case .Sailing:
           glfw.SetInputMode(g.window, glfw.CURSOR, glfw.CURSOR_DISABLED)
       case .Docked, .Chart, .Menu:
           glfw.SetInputMode(g.window, glfw.CURSOR, glfw.CURSOR_NORMAL)
       }
   }
   ```

   In `game_input`, switch on mode first: sailing intent only in `.Sailing`, mouse-as-cursor in `.Docked`. The boat-steering guard you wrote for microui hover (ch48) generalizes into this.

2. **Place the quays.** Sail to each port's island, nose up to a nice lee shore, and press a debug key that prints `boat.position` and heading — paste into `PORTS`. Ten minutes of pleasant fieldwork. Then the dock check, in `game_simulate`:

   ```odin
   dock_check :: proc(g: ^Game) -> (port: int, ok: bool) {
       for p, i in PORTS {
           d := glsl.distance(g.boat.position.xz, p.dock_pos.xz)
           if d > 18.0 do continue
           if g.boat.speed > 1.5 do continue                       // ~3 kn
           if abs(angle_wrap(g.boat.yaw - p.dock_heading)) > 0.8 do continue
           return i, true
       }
       return 0, false
   }
   ```

   When `ok`, HUD shows the anchor prompt (your ch48 text); on `input.pressed[.Anchor]` (E), zero the velocity, `game_set_mode(g, .Docked)`, `g.docked_port = port`. Autosave hooks in here next chapter — leave a `// ch80: autosave` comment as a flag to future-you.

3. **Grow the game-UI widgets** in `src/ui_game.odin` — immediate-mode, batcher-backed:

   ```odin
   ui_button :: proc(g: ^Game, id: string, r: Rect2D, label: string) -> bool {
       hot := rect_contains(r, g.input.mouse_pos)
       bg := hot ? COLOR_PARCHMENT_HI : COLOR_PARCHMENT
       ui_push_quad(&g.ui, r, g.ui.white_uv_rect, bg)
       ui_text_centered(&g.ui, r, label, COLOR_INK)
       return hot && g.input.mouse_clicked          // edge, from ch10's pattern
   }
   ```

   That's the whole widget model: draw from state, return interaction. Add `ui_panel` (bordered quad + title) and `ui_row` (label left, value right, two buttons). No retained objects, no callbacks, no IDs-with-hashing — at this widget count, position *is* identity. Style it now, once: parchment fills, ink text, your BMFont at two sizes. This skin carries through ch81.

4. **The trade screen,** drawn from `game_render` when `.Docked`. Buy/sell per good, one row each:

   ```odin
   for good in Good_Id {
       price  := port_price(&g.economy, g.docked_port, good)
       have   := g.cargo.units[good]
       y      := row_y(int(good))
       ui_text(&g.ui, {x0, y}, GOODS[good].name, COLOR_INK)
       ui_text(&g.ui, {x1, y}, fmt.tprintf("%d c", price), price_color(g, good, price))
       ui_text(&g.ui, {x2, y}, fmt.tprintf("x%d", have), COLOR_INK)
       if ui_button(g, "buy",  {x3, y, 70, 24}, "Buy")  do trade(g, good, +1)
       if ui_button(g, "sell", {x4, y, 70, 24}, "Sell") do trade(g, good, -1)
   }
   ```

   `trade` validates coins, capacity, and stock, then mutates — it's simulation state, so route it as an intent if you're strict (a `pending_trade` field consumed in `game_simulate`) or accept the small sin of mutating gold from UI code with a comment; at this scale, the comment is honest. `price_color` tints below-average prices green-ish, above red-ish: one lookup, huge readability. Show gold, capacity (`used/max` tonnes), the port's flavor line, and a "Cast off" button → `.Sailing`.

5. **Make cargo heavy.** In `boat_update_sailing` and buoyancy:

   ```odin
   cargo_tonnes :: proc(c: Cargo) -> f32 {
       total: f32
       for good in Good_Id do total += f32(c.units[good]) * GOODS[good].weight
       return total
   }
   // sailing: heavier = slower to accelerate, statelier to turn
   load     := cargo_tonnes(g.cargo) / UPGRADES[.Hold].effect[g.upgrades[.Hold]]
   g.boat.accel_scale  = 1.0 / (1.0 + 0.6 * load)
   g.boat.rudder_scale = 1.0 / (1.0 + 0.3 * load)
   // buoyancy: ride lower — players SEE the load
   g.boat.draft_offset = 0.25 * load
   ```

   Sail empty, then sail full of timber. If you can't feel the difference blindfolded, double the coefficients and walk them back.

6. **The economy step,** ticked once per sim-minute (not per frame — hook it to your ch27 time-of-day clock):

   ```odin
   economy_step :: proc(e: ^Economy, dt_minutes: f32) {
       for &port, pi in e.ports {
           for good in Good_Id {
               bias: f32 = 1.0
               if good in PORTS[pi].produces do bias = 0.7
               if good in PORTS[pi].consumes do bias = 1.4
               m := &port.mult[good]
               m^ += (bias - m^) * 0.02 * dt_minutes                    // mean reversion
               m^ += (rand.float32(&e.rng)*2-1) * GOODS[good].volatility * 0.015 * dt_minutes
               m^ = clamp(m^, 0.4, 2.5)
           }
       }
       economy_step_events(e, dt_minutes)   // step 7
   }
   port_price :: proc(e: ^Economy, port: int, good: Good_Id) -> int {
       return max(1, int(f32(GOODS[good].base_price) * e.ports[port].mult[good] + 0.5))
   }
   ```

   `e.rng` is a `rand.Rand` created with `rand.create(g.world_seed ~ 0xEC0)` — the economy's walk is *part of the world*, reproducible from the seed you'll save in ch80.

7. **Events.** A small table-driven system: every few sim-hours, low chance per port to start an event — `{port, good, mult_override, expires, headline}`. While active, `port_price` applies the override, and the trade screen + dock prompt show the headline. Wire one to the weather for the signature move: when ch74's storm passes over a port's island, roll for *"Storm damaged the docks: timber pays double."* The simulation systems start feeding each other — this is the moment Saltwind becomes more than the sum of its parts.

8. **Contracts.** Generate three offers whenever you dock, *from* live prices:

   ```odin
   contract_generate :: proc(g: ^Game, from: int) -> Contract {
       // pick a good cheap here, a port where it's dear
       good, to := best_spread(&g.economy, from)
       qty      := 4 + rand.int_max(8, &g.economy.rng)
       spread   := port_price(&g.economy, to, good) - port_price(&g.economy, from, good)
       dist     := glsl.distance(PORTS[from].dock_pos.xz, PORTS[to].dock_pos.xz)
       return Contract{
           good = good, quantity = qty, from = from, to = to,
           reward   = qty * spread + int(dist * 0.15) + 50,    // spread + distance + flat
           deadline = g.sim_time + f64(dist / 4.0) * 2.5,      // ~2.5x sailing time at 4 m/s
           state    = .Offered,
       }
   }
   ```

   Accepting loads the cargo (if it fits) and escrows nothing — payment on delivery. In `game_simulate`, expire overdue contracts; on docking at `to` with the goods aboard, pay out with a satisfying HUD line (ch82 adds the coin-clink). A contracts panel on the trade screen lists offers and your active runs with time remaining in sim-hours.

9. **Tune one full loop.** Dock → accept → sail → deliver → buy sailcloth tier 1 should take 20–40 minutes of play. Adjust rewards and upgrade costs until the *first* upgrade lands inside a first session — the hook must set before the player puts it down.

## Checkpoint

A playable trading loop, start to finish, with nothing imaginary left in it.

- Approach a quay too fast or side-on: no prompt. Slow, bow-on: prompt; E docks without teleporting the boat.
- Buy 10 timber: gold drops by exactly `10 * price` (integers!), the capacity bar fills, and casting off, the boat visibly rides lower and turns wider.
- Watch one good's price at one port across a sim-day via the debug panel: it wanders, but producers stay cheap-ish and consumers dear-ish.
- Accept a contract, deliver it late on purpose: it expires, no payout, no crash; deliver one on time: gold up, contract cleared, and the same seed regenerates the same world economy on restart.

## Pitfalls

- **The trade screen steers the boat.** Mouse clicks leaking into sailing input — your mode gate in `game_input` isn't first, or some system still reads `glfw.GetKey` directly (grep for it; ch10 promised you'd never need to again).
- **Prices explode or flatline.** Random walk without mean reversion diverges; reversion without noise converges to static. You need both terms, and the `clamp` is the seawall. Plot one price in the debug panel before trusting it.
- **The economy is "alive" but invisible.** If prices only exist inside the trade screen, drift reads as arbitrary numbers. The fix is *legibility*: price-vs-base color tinting, event headlines, and (ch79) routes on the chart. Players need to see *why*, not just *what*.
- **Float coins.** `f32` gold "works" until 16,777,216 — and produces 239.99999 long before. You were warned, twice now.
- **Docking is a pixel-hunt.** Radius too small or the heading cone too tight, and players circle the quay in frustration (your ch83–84 friend-testers *will* hit this). Generous first, strict later: 18 m / ±45° is a starting point, not a virtue.
- **Contract rewards that ignore the journey.** Pure price-spread rewards make short hops strictly optimal and the far ports decorative. The distance term (and storm-season multipliers, exercise 3) is what makes the map matter.

## Exercises

1. A price *ledger*: record each port's prices when you dock and show them (with a "as of 2 days ago" stamp) in the trade screen — stale knowledge as a mechanic, and the Charts upgrade can later refresh it remotely.
2. Buy/sell quantity modifiers: shift-click for 5, ctrl-click for max-affordable/max-held. Twenty minutes of work; testers will bless you.
3. Seasonal pressure: multiply storm frequency into `economy_step`'s bias for weather-exposed ports (storms raise consumer prices — supply boats aren't getting through; you are).
4. **Stretch:** drifting salvage — when a contract expires *en route* (yours or, fictionally, "another trader's"), spawn crates of that good near the route using ch35's ash floaters; collecting them is found money. The despawn-on-collect machinery exists verbatim in ch35 step 6.

## Commit

`git commit -m "ch78: docking, game-state modes, trade UI, cargo physics, drifting economy, contracts"`

← [Chapter 77 — The Shape of the Game](ch77-the-shape-of-the-game.md) · [Chapter 79 — The Chart Room](ch79-the-chart-room.md) →
