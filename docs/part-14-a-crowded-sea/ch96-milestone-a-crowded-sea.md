# Chapter 96 — MILESTONE: A Crowded Sea

*Part 14 — A Crowded Sea · Estimated time: 3–4h · learnopengl: review of Part 14*

**What you'll see when done:** harbor traffic at dawn — and the unsettling, wonderful feeling of arriving somewhere that was already busy before you got there.

## Where we are

Five chapters ago the sea was alive but empty: weather, gulls, waves — no *neighbors*. Now routes thread the archipelago (ch91), ships sail them under real physics and real manners (ch92), captains with names and ledgers work them (ch93), their cargo moves the same prices you trade against (ch94), and — if you took the co-op chapter — a friend can sail it all beside you (ch95). A milestone, as always, means three things: prove the systems work *together*, prove they fit the *budget*, and take the screenshot. This is also the last milestone before the course turns inward — Part 15 is engine-room work, threads and streaming and GPU-driven drawing — so make this one count: it's the last time the headline feature is something you can *watch*.

## Concepts

### The harbor watch

ch76's acceptance test was an anchored boat and an empty horizon. This part's test is the same discipline pointed at a *crowd*: anchor in the roads off Gullhaven at 05:45 sim-time, hands off the keyboard, and watch the port mouth for two minutes. A crowded sea should produce, unprompted:

```
0:00  a ship moored at the quay, loading — visible commerce (ch93's dwell)
0:15  another rounds the headland inbound, sail first out of the dawn haze,
      hull resolving as she closes (ch93's sails-first LOD)
0:30  she meets an outbound ship off the mouth — crossing situation: the
      give-way vessel eases astern of the stand-on, no waltz (ch92)
0:50  the moored ship casts off, beats upwind out of the bay in honest,
      countable tacks (ch92's machine; ch33's physics)
1:10  the dock UI, glanced at, shows timber cheaper than ten minutes ago —
      somebody sold here while you watched (ch94)
1:30  a third sail on the horizon, bound elsewhere, ignoring you entirely
2:00  the harbor log has new entries; none of them are about you
```

If a friend is aboard (ch95), her boat rides the same swell through all of it, and the captains give way to her too. Every beat that fails names its chapter — that's your punch list.

### The integration sweep

Part 14's classic seams, hunted with ch60/ch76 checklist discipline:

- **Do NPC ships cast shadows and wakes?** They should — *by ring, not by default*. Decide the cost table deliberately: **Full-LOD ring** (≤4 ships): shadow casters in the ch57 cascades, wakes for the nearest 3 (the ch67 wake buffer is a real budget — fourth wake on, oldest off), spray at the bow. **Coarse ring**: no shadow (at 450 m+ a hull's shadow is sub-pixel in every cascade that contains it), no wake, single `ocean_height_at` bob inside 800 m, none beyond. Write the table down; "everything everywhere" is how frame budgets die at milestones.
- **Pathfinding amortization.** ch93 requested routes inline ("queued in ch96" — the bill is due). Build the queue: `route_request(g, from, to) -> Route_Handle` appends to a `[dynamic]Route_Request`; the game serves **at most one A\* per frame** and marks the handle ready. A captain whose route hasn't landed simply stays in `Loading` a frame or three longer — nobody will ever notice, and the worst-case frame no longer contains four searches. Verify with the ch49 timer: spike a debug key that re-routes the whole fleet at once and watch the cost smear across frames instead of stacking in one.
- **One economy, fast-forwarded.** Add the **time-acceleration debug key** ch94 promised: hold F6 to feed the accumulator `frame_dt * 60` (the fixed-step architecture from ch10 makes this a one-line cheat with zero new code paths — the payoff tour continues). Run a sim-day in a minute, watching the ch94 watchdog: aggregate coins flat-ish, no good pinned at a clamp, captains' balances not trending to zero. Then the determinism replay: same seed, two fast-forwarded runs, identical sparklines to the coin. (Host-only in co-op, and it must ride the ch95 pause/time events if a client is connected — or just gate it to offline sessions.)
- **Sim-LOD radii, tuned.** The 350/450 m defaults were guesses. Measure: sit in traffic, log the Full-ring population for a minute. If it ever exceeds ~4, shrink the promote radius; if ships visibly pop their wakes into existence inside your attention radius, grow it. The right numbers are *yours* — what matters is that you chose them while watching the ch49 timers rather than inheriting them from a chapter.

### The Part 14 frame budget

Part 14 is almost all CPU — a novelty after three parts of GPU accounting. Targets at the usual midrange-1080p reference, fleet of 12, traffic in view:

| System | Where | Budget | The knob |
|---|---|---|---|
| A* (amortized, ≤1/frame) | CPU | < 0.5 ms on its frame, 0 otherwise | cell size, queue depth |
| Full-ring AI + physics (≤4 ships) | CPU | < 0.4 ms | ring radius, feeler count |
| Coarse fleet (8–12) | CPU | < 0.05 ms | it's multiplies; leave it |
| Economy step + sparklines | CPU | < 0.1 ms | sample rate (per sim-minute, cached) |
| Net service + sends (ch95) | CPU | < 0.2 ms | send rate, snapshot size |
| NPC hulls/sails/wakes/shadows | GPU | < 1.0 ms | wake count, shadow ring, instancing |
| **Part 14 total** | | **≤ ~1.5 ms CPU, ~1 ms GPU** | |

Stack it on Parts 9–11's pipeline and you should still clear 60 with room. The fast-forward key is also a stress test: at 60× the *simulation* cost runs sixty times per frame — if F6 drops you below interactive, your sim tick has render-shaped work hiding in it, which is exactly the disease Part 15's profiler will go hunting for.

## Build

1. **Run the harbor watch.** Two minutes, hands off, at two ports (pick one the fleet favors — the ch94 sparklines tell you which). Punch-list every broken beat; fix in order: collisions and groundings first (they shatter the fiction), LOD pops second, economy oddities third.

2. **Run the integration sweep.** All four audits from Concepts. The shadow/wake cost table goes in a comment near the LOD switch; the route queue replaces ch93's inline call; F6 becomes a permanent resident of the debug keymap next to ch76's wind-flip.

3. **Stage the crossing, on purpose.** The ch92 step-7 spawn key earns its keep: two ships timed to cross off the port mouth at 06:00 light. Watch from the give-way ship's quarter. If you have ch95, have your friend hold station to leeward as the stand-on vessel holds course past her — three boats, three authors: one scripted by you, one by an algorithm, one by a human, indistinguishable at a glance. That's the part, summarized in one frame.

4. **Fill the budget table.** Your numbers, ch49 CPU timers and ch60 GPU timers, worst case (traffic in view, F6 held, friend connected). Any row over budget: apply its knob, write down the trade.

5. **Screenshot #11 — harbor traffic at dawn.** Photo mode (ch51), 06:00–06:30 light, low sun across the port mouth. The checklist:
   - [ ] one ship moored at the quay, loading
   - [ ] two underway off the mouth, mid-crossing — give-way visibly turning astern
   - [ ] a third as a sail-fleck on the horizon, hull still swallowed by haze
   - [ ] wakes catching the dawn (nearest ships only — your cost table at work)
   - [ ] the friend's boat alongside, if ch95 happened
   - [ ] bonus: the harbor log or a sparkline in frame — commerce, legible

6. **Share it.** r/odinlang, the Odin Discord's #showcase, the learnopengl screenshots thread. The line that does it justice: *"None of this traffic is scripted — they're trading because the prices are real."* Of all eleven screenshots, this is the one whose caption is a systems-design brag, and the replies will ask exactly the questions Part 14 answered. Answer them; teaching it back is the best retention tool you own.

7. **Commit and tag:** `git tag part-14-complete`.

## Checkpoint

- [ ] The harbor watch produces every beat in the script, at two different ports, without input.
- [ ] ≤1 A* per frame under a fleet-wide re-route; the queue serves captains within a few frames.
- [ ] A fast-forwarded sim-day: watchdog flat, no clamp-pinning, and the same-seed replay matches to the coin.
- [ ] Full ring holds ≤4 ships in the worst traffic you can find; no wake/shadow pop inside attention range.
- [ ] Budget table filled in; Part 14 total ≤ ~1.5 ms CPU on your hardware, every row attributed.
- [ ] Screenshot #11 taken, checklist satisfied, and shared.
- [ ] (ch95) Two machines ride one swell through the whole watch; a client trade dents both sparklines.

## Quiz

Answers in the fold — write yours first.

1. Your A* heuristic is octile distance, but edge costs are wind-time. What single property must the speed clamp preserve for the paths to stay optimal, and why?
2. Why does the helm controller need the D term — what does the boat have that pure proportional control can't see?
3. In a COLREGS crossing, why must exactly *one* ship maneuver? What failure returns if both do?
4. The coarse sim-LOD deliberately calls the same `sail_power` as the full model. Which *other* system breaks — and how would the bug present — if it didn't?
5. Why can ch95 ship a whole ocean in zero bytes, while the economy needs a snapshot and a single owner? Name the property that separates them.
6. The remote boat renders ~100 ms in the past. What exactly does that delay buy, and what does it cost?
7. A client in co-op buys timber. Walk the message path from keypress to both screens agreeing — and name the step that makes duplication impossible.
8. F6 fast-forward runs 60 sim steps per frame and your frame rate barely moves. What does that prove about your tick — and what would it mean if it didn't hold?

<details>
<summary>Answers</summary>

1. Admissibility: cost-per-meter must never drop below 1× (speed clamped ≤ 1), so octile distance never *overestimates* remaining cost. Overestimate, and A* can pop the goal while a cheaper route still hides in the open set — paths go suboptimal.
2. Yaw momentum. The error alone says nothing about how fast the bow is already swinging; the D term (rate of change of error) is the controller noticing the swing and easing off, which kills the overshoot-S-curve cycle.
3. Asymmetry makes the negotiation silent and deterministic: the give-way vessel turns astern, the stand-on holds course. If both maneuver, they dodge symmetrically into each other — the corridor-shuffle dance the rule exists to break.
4. The economy. Far (coarse) ships would arrive systematically earlier or later than near (full) ones, so freight rates differ by *observer distance* — presenting as a price bias you'd hunt for a week in ch94's flows before suspecting ch93's LOD.
5. The ocean is a **pure function of (seed, sim_time)** — ch63 evolves by `e^{iωt}` from absolute time, no accumulation — so any machine recomputes it identically. The economy *accumulates* rng draws and trade history step by step, so divergence compounds; accumulated state needs one authoritative owner.
6. It buys certainty: the two snapshots bracketing render-time have already arrived, so the boat interpolates between known truths and never extrapolates a wrong guess. It costs 100 ms of freshness — imperceptible for sailboats, fatal for hitscan shooters.
7. Client sends a `Trade_Msg` RPC on the reliable channel → host validates and runs the one true `market_trade` → host replies with the result and broadcasts the stock table → client applies *only* host messages. Duplication is impossible because the client never applies its own request — one authority, one application site.
8. That the fixed tick contains only simulation — no rendering, no allocation, no GPU sync hiding inside it (ch10's separation, audited at 60×). If the frame rate collapsed, render-shaped work is living in the sim step, which is precisely what Part 15's profiling chapters exist to find and evict.

</details>

## Pitfalls

- **The harbor watch shows ships but no *traffic*.** Everyone's mid-ocean and nobody's loading — your dwell times are too short relative to route lengths, so port time rounds to invisible. Tune dwell up (ch93 called it visible commerce for a reason) and verify the spawn policy seeds new captains *in* `Loading`, at quays.
- **Frame spikes exactly when a ship docks.** The next route is computed inline at cast-off — the queue from the sweep isn't actually being used on that path. Grep for direct `astar_find` calls the way ch94 grepped for stock writes; the request queue must be the only door.
- **Fast-forward desyncs the economy replay.** Something in the accelerated path reads *render* state — usually a per-frame rather than per-tick rng draw, or a sparkline sampling hook mutating state. The replay test bisects it fast: it passed in ch94, so the regression is whatever this chapter touched.
- **The screenshot reads as empty despite 12 captains.** Fleet's spread across the archipelago and your port's not the hub. Don't script it — *read* it: the ch94 sparklines tell you which port the fleet is farming this seed; shoot there at dawn, or bump `TARGET_CAPTAINS` for the session. Stills need ~20% more drama than play does (ch76's law, still true).
- **With a friend connected, captains stutter but player boats are smooth.** The fleet stream is on the state channel at 4 Hz but you interpolate it with the boat's 100 ms cushion — too thin for the wider packet spacing. Give fleet ghosts their own `INTERP_DELAY` of ~300 ms; nobody can tell with NPC ships, which is the whole reason their rate is low.

## A place to rest

A genuinely good one, second only to ch76's. **The recap to reread when you return:** Saltwind is now a *populated* place — a fleet of named captains plans wind-aware routes (A* over a sea graph), sails them under the player's own physics (PD helm, tack machine, COLREGS manners), trades them through an inventory-backed economy that the player competes in, and — over ENet — shares its deterministic ocean with a friend, syncing boats and markets in kilobytes because the sea itself needs no syncing. The tag is `part-14-complete`; screenshot #11 is the dawn harbor. What remains is the engineering arc: Part 15 takes this finished, crowded game and rebuilds its plumbing — worker threads, async streaming, one-draw-call oceans — the way real teams retrofit real engines. It's the most professional material in the course, and it lands better rested. When you're ready, Chapter 97 is waiting, and it begins by measuring everything you just built.

## Commit

`git commit -m "ch96: milestone — a crowded sea; harbor watch, route queue, fast-forward audit, screenshot #11"`

← [Chapter 95 — Two Sails, One Sea](ch95-two-sails-one-sea.md) · [Chapter 97 — Many Hands](../part-15-the-engine-room/ch97-many-hands.md) →
