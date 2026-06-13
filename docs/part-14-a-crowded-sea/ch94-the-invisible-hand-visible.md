# Chapter 94 — The Invisible Hand, Visible

*Part 14 — A Crowded Sea · Estimated time: 4h · learnopengl: no direct equivalent — this is game-economy material*

**What you'll see when done:** you race a ship named *Saltrunner* to Hartlepool Rock with holds full of fish — and lose. The trade screen shows fish at 9 coins where yesterday it paid 19, because she got there first and sold first. Three days later you watch three sails converge on Kelpmouth and *know*, before opening the chart, that timber is expensive up north.

## Where we are

Chapter 78's economy was a puppet: prices random-walked on biased noise, and the `produces`/`consumes` sets were stage directions. It was the right economy to ship — legible, tunable, alive-*looking*. But now actual ships carry actual cargo between actual ports, and the puppet has to become the real thing: prices should move because **goods moved**, and the noise should shrink to a garnish. This is the chapter where Part 14's systems start feeding each other — captains read prices (ch93), prices move because captains sailed (today), and the player stops trading against a slot machine and starts trading against *traffic*.

## Concepts

### From multiplier to inventory

The honest model replaces "a price multiplier that wanders" with "a warehouse with a level." Each port holds **stock** per good, plus a **target** stock (what comfortable looks like for this port, derived from `produces`/`consumes`). Price falls out of scarcity:

```
price = base_price · (target / stock)^elasticity · event_mult · small_noise
```

Stock above target → cheap; stock scarce → dear; `elasticity` (~0.6) controls how violently price reacts. Now everything becomes a flow into or out of that one number. Producers add stock each sim-hour (the **faucet**). Consumers burn it (the **sink**). And every trade — player or NPC, *same proc, no exceptions* — moves it: buying 10 timber at Kelpmouth removes 10 timber from Kelpmouth, and the next visitor finds timber dearer. That last sentence is the entire chapter. Supply and demand stop being a metaphor painted on noise and become arithmetic on a warehouse, and the invisible hand becomes visible because it has to row.

### The player now competes

The consequence lands immediately: arrive at a port after an NPC sold the same good and the spread you sailed for is *eaten*. This will feel like a bug for about an hour and then become the best mechanic in the game — because it's counterable by everything Part 14 already built. The harbor log (ch93 ex.1) says who sailed where with what. A hail tells you a ship's cargo. Three sails heading north *means something now*. The expert player stops reading prices and starts reading **traffic** — which is precisely the "read the world" fantasy the part promised, emerging from systems rather than scripts.

### Events as propagation, not decoration

ch78's events overrode a price and printed a headline. Rewire them to act on *flows* and the downstream behavior writes itself: a storm closing Kelpmouth (no docking) doesn't just spike a number — Kelpmouth's production piles up unsold behind the breakwater while every port that *consumes* Kelpmouth timber burns stock with no resupply, because the captains who would have carried it diverted (ch93's route scoring already handles "can't dock" as "no route"). Shortages appear two hops from the storm, days later, with no code knowing the words "shortage" or "downstream." When you see it happen the first time, you will go check whether you accidentally scripted it. You didn't.

### Faucets, sinks, and the seawall

Balancing vocabulary, since you now run a real economy: **faucets** create value (port production, contract rewards), **sinks** destroy it (port consumption, upgrades, the spread captains pocket). If faucets outrun sinks, stocks fatten, prices sag, and trade dies of abundance; reversed, prices pin at clamps and everyone's broke. Runaway happens specifically when a loop closes without a sink — e.g., captains buying low and selling high *create* coins ex nihilo unless production/consumption keeps repricing their next run. Three disciplines keep you safe: keep the **clamps** from ch78 (stock floors/ceilings, `max(1, …)` price) as the seawall while you tune, watch **aggregates** not anecdotes (total coins in the world, total stock per good — two debug numbers, plotted), and tune *flow rates* before touching formulas. Almost every economy bug is a rate, not a law.

### Determinism, on the record

Everything stochastic here — noise garnish, event rolls, captain personalities, dwell jitter — draws from the single `rand.Rand` seeded from the world seed (ch78 established it; keep the habit absolute). The yield: a *replayable* economy. Same seed, hands off the keyboard, fast-forward a sim-day → identical prices to the coin, every run. That's your regression test for this chapter, your repro for every balancing bug, and — quietly — the property ch95 stands on, because a deterministic economy is one a host can own and a client can trust.

## Odin notes

Stocks are integers. The faucet/sink rates are *fractional per tick*, so accumulate: a per-port-per-good `f32` remainder bucket that ticks units into the `int` stock only when it crosses 1.0 — same accumulator pattern as ch10's timestep, four lines, and money math stays exact. The sparkline ring buffers (`[120]i32` of prices, one sample per sim-minute) live per port-good *only for the goods the panel currently shows* — 5 ports × 6 goods × 120 samples is small enough to just keep all of it; do that instead, simpler. And keep `economy_step` allocation-free; it now runs under ch96's fast-forward at 60× and will be *measured*.

## Build

1. **Re-found the market,** in `src/economy.odin`:

   ```odin
   Port_Market :: struct {
       stock:     [Good_Id]int,
       target:    [Good_Id]int,
       acc:       [Good_Id]f32,      // fractional flow accumulator
       event:     Market_Event,      // ch78's, now acting on flows
       spark:     [Good_Id]Spark,    // step 5
   }

   port_price :: proc(e: ^Economy, port: int, good: Good_Id) -> int {
       m := &e.ports[port]
       scarcity := f32(m.target[good]) / f32(max(m.stock[good], 1))
       p := f32(GOODS[good].base_price) * math.pow(scarcity, 0.6) * m.event_mult(good) * m.noise[good]
       return max(1, int(p + 0.5))
   }
   ```

   Initialize `target` from the bit_sets — producers ~40 units, consumers ~15, neutral ~25 — and `stock = target` so the world starts becalmed. Every existing `port_price` caller (trade screen, contract generation, captain routing) gets the new behavior without changing a line: the function signature was the load-bearing wall, and it held.

2. **One trade proc to rule them all:**

   ```odin
   market_trade :: proc(e: ^Economy, port: int, good: Good_Id, qty: int) -> (cost: int, ok: bool) {
       m := &e.ports[port]
       if qty > 0 && m.stock[good] < qty do return 0, false      // can't buy what isn't there
       unit := port_price(e, port, good)                          // price BEFORE the trade moves it
       m.stock[good] -= qty                                       // buy drains, sell (qty<0) fills
       return unit * qty, true
   }
   ```

   Route the player's ch78 `trade` through it; replace ch93's ledger-only `captain_buy`/`captain_sell` with it. From this commit forward there is no second way to move goods — grep for direct `stock` writes the way ch35 grepped for `gl.` calls.

3. **Rewrite `economy_step`** as flows plus garnish:

   ```odin
   economy_step :: proc(e: ^Economy, dt_minutes: f32) {
       for &m, pi in e.ports {
           for good in Good_Id {
               rate: f32 = 0
               if good in PORTS[pi].produces do rate += PRODUCE_PER_MIN        // faucet
               if good in PORTS[pi].consumes do rate -= CONSUME_PER_MIN        // sink
               if m.event_blocks_flow(good)  do rate  = flow_under_event(rate) // storms throttle
               m.acc[good] += rate * dt_minutes
               for m.acc[good] >= 1  { m.stock[good] += 1; m.acc[good] -= 1 }
               for m.acc[good] <= -1 { m.stock[good] -= 1; m.acc[good] += 1 }
               m.stock[good] = clamp(m.stock[good], 0, 3 * m.target[good])     // the seawall
               m.noise[good] = 1.0 + (rand.float32(&e.rng)*2-1) * GOODS[good].volatility * 0.06
           }
           spark_tick(&m, e, pi)        // step 5: sample prices once per sim-minute
       }
       economy_step_events(e, dt_minutes)
   }
   ```

   Note the noise coefficient: ch78 ran 0.015 *per minute compounding on the multiplier*; this is a flat ±6%-ish shimmer on top of structural price. The structure now comes from ships.

4. **Events act on the world, not the number.** Extend `Market_Event` with `closes_port: bool` and flow throttles. While a port is closed: `dock_check` returns false for it (one guard), and captain route scoring skips it as a destination (ch93 already skips unreachable ports — verify, don't assume). Wire ch74's storm to roll port closures as ch78 wired price events. Then run the experiment from Concepts and watch a shortage arrive somewhere the storm never touched. Keep the headline machinery — *"Kelpmouth harbor closed by storm"* — because legibility is still the law.

5. **The sparkline panel** — economy debugging made pleasant, on ch48's batcher:

   ```odin
   Spark :: struct { samples: [120]i32, head: int }

   ui_sparkline :: proc(b: ^UI_Batch, r: Rect2D, s: ^Spark, color: glsl.vec4) {
       lo, hi := spark_minmax(s); span := max(hi - lo, 1)
       for i in 0 ..< len(s.samples) - 1 {
           a := spark_at(s, i); c := spark_at(s, i + 1)         // oldest → newest
           x0 := r.x + r.w * f32(i)     / f32(len(s.samples) - 1)
           x1 := r.x + r.w * f32(i + 1) / f32(len(s.samples) - 1)
           y0 := r.y + r.h * (1 - f32(a - lo) / f32(span))
           y1 := r.y + r.h * (1 - f32(c - lo) / f32(span))
           ui_push_line(b, {x0, y0}, {x1, y1}, 1.5, color)      // a rotated quad, ch48's HUD trick
       }
   }
   ```

   The panel (microui tab or a new game-UI screen — your call) shows a grid: ports × goods, each cell a two-hour sparkline with current price. Tint cells where an NPC traded in the last 10 sim-minutes. Ten minutes of watching this grid teaches you your own economy better than any amount of formula-staring — you'll *see* the sawtooth of a port being farmed by captains and the slow ramp of a brewing shortage.

6. **The aggregate watchdog.** Two more debug numbers, updated in `economy_step`: total coins (player + all captains) and total stock per good, world-wide. Sparkline both. Coins should wobble around a level (faucets ≈ sinks); any steady slope is a leak with a sign on it. This is a ten-line early-warning system for every balancing mistake you're about to make.

7. **Balance pass.** Fast-forward a sim-day (the time-acceleration key arrives formally in ch96; a crude `for` loop over `economy_step` + `captain_update` serves today). Acceptance: no good pinned at a clamp for hours, captains' aggregate coins roughly flat, player contract rewards still in ch78's intended range (re-run ch78 step 9's loop timing — first upgrade still lands in a first session). Expect to tune `PRODUCE_PER_MIN`, `CONSUME_PER_MIN`, and elasticity; expect not to touch the formulas.

## Checkpoint

- Buy 10 timber, watch the price you paid: the *next* unit is dearer, and the sparkline shows your own dent. You are a market participant now, with the scars to prove it.
- Shadow a captain into port (ch93's pin panel): her sale visibly moves the destination's sparkline within a sim-minute.
- Close Kelpmouth by debug-forced storm for six sim-hours: timber stock piles up there, and at least one timber-consuming port's price climbs — then watch the relief fleet converge when it reopens.
- Same seed, hands-off, one fast-forwarded sim-day, twice: identical sparklines, to the coin.
- The aggregate watchdog shows flat-ish coins and stocks over a sim-day — or you can name the leak.

## Pitfalls

- **Prices oscillate violently port-to-port** as captains overcorrect: everyone chases the same spread, dumps at once, price craters, repeat. That's a real economics phenomenon (the cobweb cycle) — damp it with what ch93 built: decision-time jitter, personality spread, and price impact itself (the first seller eats the spread the second sailed for). If it persists, your `elasticity` is too high — each unit moves price too far.
- **A good flatlines at zero stock everywhere.** Sinks outrun faucets — consumption exists but no port produces enough, and captains can't carry what nobody stocks. Check the produce/consume graph from ch77 step 3 still balances *under the new flow rates*; the paper check becomes a numbers check.
- **The player can't compete at all.** NPC dwell too short or fleet too large — captains arbitrage every spread below the player's sailing time. Tune dwell *up* (it's also better scenery) and remember the player has edges captains don't: contracts pay above spot, and captains never take contracts.
- **Determinism broke.** Someone called `rand.float32()` bare — context rng, not `e.rng`. Audit every `rand.` call in economy and captain code; one stray ruins the replay test *and* ch95's handshake.
- **`market_trade` rejects a legitimate NPC sale.** Sign confusion: selling is `qty < 0` and needs no stock check (the *port* always has room up to the clamp). Write the two assertions now; this proc is about to be called by a network RPC (ch95) and must be unfoolable.
- **The sparkline grid tanks the frame.** 30 cells × 119 segments is ~3,600 quads — fine for the batcher, but only if you build it once per sim-minute tick, not per render frame. Cache the vertices; redraw on new sample.

## Exercises

1. **Price memory as a mechanic:** fold ch78 ex.1's stale ledger into the new model — the chart (ch79) shows last-*seen* prices with age stamps, and the Charts upgrade tier 3 adds "harbor rumors": current direction (▲▼) without magnitude for adjacent ports. Imperfect information is what makes reading traffic valuable.
2. Add **freight contracts for NPCs**: when a shortage exceeds a threshold, the suffering port posts a bounty contract *both* the player and captains can take (captains score it like any route, with the bounty as spread). Watch relief convoys self-organize; feel free to feel like a central banker.
3. Plot the **cobweb**: log (price, quantity-shipped) pairs for one good for a sim-day and scatter-plot them in the debug panel. If it spirals inward, your damping works; outward, revisit pitfall one with evidence instead of vibes.
4. **Stretch:** regional weather pricing. Multiply each *route's* risk (storm exposure along the ch91 path, from ch47/74 state) into captain scoring — storms now reroute trade around weather, creating windward/leeward price gradients during bad seasons. One multiply in one proc; continental consequences.

## Commit

`git commit -m "ch94: inventory-backed prices, unified trades, propagating events, sparkline panel, watchdog"`

← [Chapter 93 — Other Captains](ch93-other-captains.md) · [Chapter 95 — Two Sails, One Sea](ch95-two-sails-one-sea.md) →
