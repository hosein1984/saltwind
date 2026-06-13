# Chapter 77 — The Shape of the Game

*Part 12 — Shipping a Game · Estimated time: 3h · learnopengl: no direct equivalent — this is game craft*

**What you'll see when done:** nothing new on screen — and one page of paper plus three Odin structs that decide what the next seven chapters build, which is more than most engines ever get.

## Where we are

Eleven parts. An FFT ocean, volumetric clouds, cloth sails, biomes, gulls with skeletons. Saltwind is, by any honest measure, a *better engine* than most shipped indie games run on. It is also — be equally honest — not a game. There is nowhere to go, nothing to want, no reason to trim the sail except that trimming the sail feels good.

This is the exact spot where hobby projects go to die. Not at the hard rendering chapter — you survived those — but here, at the silent transition from "build the world" to "decide what the world is *for*." The infinite-engine trap has a precise mechanism: engine work has a visible payoff every session (you've felt it 76 times), while design work has a payoff only when the whole loop closes. So the engineer keeps choosing the dopamine they know. Ten years later: a beautiful repository, zero players.

The countermeasure is the same one this course has used all along: make the invisible work produce an artifact *today*. Today's artifact is a one-page design document and the data tables that implement it. No renderer changes in this entire part — the renderer is done. What follows is systems programming, UX, and craft.

## Concepts

### The core loop, for engineers

Strip any game that holds people for dozens of hours and you find the same four-stroke engine:

```
 motivation ──> action ──> reward ──> reinvestment ──┐
     ^                                               │
     └───────────────────────────────────────────────┘
```

- **Motivation:** a want the player can state out loud ("I need 300 coins for the sailcloth").
- **Action:** the verb they perform to chase it — and this is the part that must be *intrinsically* fun, because they'll do it hundreds of times.
- **Reward:** the payout, legible and immediate.
- **Reinvestment:** spending the reward in a way that changes the next action — making the loop a spiral, not a circle.

Here is Saltwind's enormous, mostly-unearned advantage: **the action is already built, and it's already fun.** Sailing — reading the wind, planning around a storm front, choosing the beam reach over the beat — has been genuinely enjoyable since chapter 33 and got better in every part since. Most designers spend years trying to make their core verb feel good. Yours took eleven parts, but it's done. The design job left is small and specific: *give the sailing stakes.*

So, Saltwind's loop, concretely:

1. **Take a cargo contract** at a port (motivation: coins, a destination, a deadline).
2. **Plan the route** — and notice how much existing simulation suddenly becomes *gameplay*: wind direction decides whether the northern passage is a reach or a beat; the weather system (ch47, ch74) decides whether you dare the open crossing; biomes (ch75) mean the mangrove shallows are slow but sheltered. None of this needs new code. It needs a *reason to care*, which the contract provides.
3. **Sail it.** The fun you already built, now with a clock and a cargo manifest aboard.
4. **Earn** — coins on delivery, integer coins, because money that can be `0.30000000000000004` is not money (more in ch78).
5. **Upgrade** — better sailcloth (faster), bigger hold (more cargo), better charts (see more) — each one changing how the next route gets planned. Reinvestment closes the spiral.

### The smallest shippable version

The discipline that separates shipping from finishing: design the *minimum* loop that closes, on paper, before writing systems. For Saltwind:

- **5 ports** on existing named islands (ch37 gave you two; you'll name three more).
- **6 goods** with per-port prices that drift.
- **Contracts**: pickup, deliver, deadline, payout.
- **Gold** (coins, `int`).
- **3 upgrades**, three tiers each.

That's the whole game. Not a placeholder for the game — *the game*. Players will sail it for hours, because the action was always the point and the loop just keeps handing them reasons.

### Scope discipline: the cut list

Write down what you are **not** building, with reasons, so future-you can't renegotiate at midnight:

| Cut | Why |
|---|---|
| Combat | A second core verb = a second game's worth of tuning, AI, balance. The sea is the antagonist; storms already are combat. |
| NPCs walking around ports | Skeletal animation (ch71) makes it *possible*, which is exactly the trap. Walking NPCs demand ports as 3D walkable spaces, collision, idle behaviors — a month for ambience a trade screen delivers in a day. |
| Dialogue / story | Writing is a craft you'd be starting from zero; the economy IS the narrative ("storm damaged the docks" tells a story in one line). |
| AI trader ships | Boids (ch72) tempt you. Resist: they'd need docking, pathing, economy participation. Post-release, maybe. |
| Crafting, fishing, multiplayer | Each is a loop of its own. One loop, shipped, beats four loops abandoned. |

The rule behind every row: **a feature is cut if it doesn't make the core loop tighter.** Pin the list to the design doc. When an idea survives three re-reads of the cut list *and* the game is shipped, it can come back.

### Two books worth your time

This chapter compresses a literature. If it whets the appetite: Raph Koster's *A Theory of Fun for Game Design* (why mastering patterns — like reading wind — is what fun *is*), and Jesse Schell's *The Art of Game Design: A Book of Lenses* (a hundred questions to interrogate a design with; Lens #31, "the Lens of Action," is this chapter in one card). Neither is required. The course stays guided.

## Build

1. **Write the one-page design doc.** Create `design/saltwind-game.md` in the repo — it's an artifact, it gets committed. Fill this template *completely*; a blank field is a decision you're deferring to your weakest future moment:

   ```markdown
   # Saltwind — the game (one page, no scrolling)
   FANTASY    One sailor, one boat, an honest living between islands.
   CORE LOOP  Contract -> plan route (wind/weather/draft) -> sail -> coins -> upgrade.
   SESSION    10–20 min: dock to dock is one sitting.
   CONTENT    5 ports · 6 goods · contracts · 3 upgrades x 3 tiers.
   WIN STATE  None. The horizon is the point. (Upgrades cap; the sea doesn't.)
   THE CUTS   No combat. No walking NPCs. No dialogue. No AI ships. No crafting.
   DONE WHEN  A stranger plays 20 minutes unaided and takes a second contract.
   ```

   That last line is the real definition of done for this entire part. Write your own versions of each line — the act of choosing the words is the design work.

2. **Define the goods table** in `src/economy.odin`. Data first; the systems that read it are next chapter. A fixed enum and an enumerated array, exactly like ch10's `ACTION_KEYS` — Odin's idiom for "small closed set of things":

   ```odin
   Good_Id :: enum u8 { Fish, Timber, Rope, Rum, Pearls, Ironware }

   Good :: struct {
       name:       string,
       base_price: int,  // coins. Integer coins. If you feel an urge to
                         // type f32 here, lie down until it passes.
       weight:     f32,  // tonnes per unit — will load the hull in ch78
       volatility: f32,  // 0..1, how wildly the price wanders
   }

   GOODS := [Good_Id]Good{
       .Fish     = {"Salt Cod",  12, 0.4, 0.35},
       .Timber   = {"Timber",    18, 1.0, 0.20},
       .Rope     = {"Hemp Rope", 25, 0.3, 0.15},
       .Rum      = {"Rum",       40, 0.5, 0.45},
       .Pearls   = {"Pearls",   150, 0.1, 0.60},
       .Ironware = {"Ironware",  60, 1.2, 0.25},
   }
   ```

   Six goods spanning three axes: cheap/heavy bulk (Timber), expensive/light treasure (Pearls), volatile speculation (Rum). The spread *is* the gameplay — a full hold of timber sails differently than a pouch of pearls, and ch78 makes the boat feel it.

3. **Define ports** — promoting ch37's `Island` idea into economy data:

   ```odin
   Port :: struct {
       name:         string,
       island:       int,              // index into Game.islands
       dock_pos:     glsl.vec3,        // quay position, on the lee shore
       dock_heading: f32,              // approach bearing, for ch78's trigger
       produces:     bit_set[Good_Id], // local supply -> price drifts LOW here
       consumes:     bit_set[Good_Id], // local demand -> price drifts HIGH here
   }

   PORTS := [5]Port{
       {"Gullhaven",       0, {}, 0, {.Fish, .Rope},   {.Timber, .Rum}},
       {"Hartlepool Rock", 1, {}, 0, {.Ironware},      {.Fish, .Pearls}},
       {"Palmstrand",      2, {}, 0, {.Rum},           {.Ironware, .Rope}},
       {"Kelpmouth",       3, {}, 0, {.Timber},        {.Fish, .Ironware}},
       {"Pearl Shallows",  4, {}, 0, {.Pearls, .Fish}, {.Rum, .Timber}},
   }
   ```

   Pick the five islands from your seed (the ch75 biomes help: the atoll gets Pearl Shallows, the mangrove gets Kelpmouth). Leave `dock_pos` zeroed for now — you'll place quays by sailing up and pressing a debug key in ch78. Check the produce/consume graph on paper: **every good should have at least one cheap port and one expensive port, and no two ports should want to trade only with each other** — triangles, not ping-pong, make routes interesting.

4. **Define contracts and upgrades** — the remaining nouns, empty of behavior:

   ```odin
   Contract_State :: enum u8 { Offered, Accepted, Delivered, Expired }

   Contract :: struct {
       good:     Good_Id,
       quantity: int,
       from, to: int,            // port indices
       reward:   int,            // coins; never floats; still serious about this
       deadline: f64,            // sim-time (ch10's clock) when it lapses
       state:    Contract_State,
   }

   Upgrade_Id :: enum u8 { Sailcloth, Hold, Charts }
   Upgrade :: struct {
       name:   string,
       desc:   string,
       costs:  [3]int,  // tier 1..3, coins
       effect: [3]f32,  // interpreted per-upgrade (speed mult, capacity, chart radius)
   }
   UPGRADES := [Upgrade_Id]Upgrade{
       .Sailcloth = {"Sailcloth", "Faster on every point of sail", {300,  900, 2400}, {1.10, 1.22, 1.35}},
       .Hold      = {"Cargo Hold", "Carry more, sit deeper",       {250,  700, 2000}, {8, 14, 24}},
       .Charts    = {"Charts", "See farther on the chart",         {200,  500, 1500}, {1.5, 2.25, 3.5}},
   }
   ```

   Note what tuning looks like now: editing a table. That's the whole argument for data-driven design, made in nine lines.

5. **Compile it.** The tables do nothing yet — but `odin build` enforcing that every `Good_Id` has a `GOODS` entry (enumerated arrays are total) is your first design-as-code win. Add a temporary debug print of the port/goods matrix on startup and eyeball your trade triangles once more.

6. **Write the playtest questions** at the bottom of the design doc, *now*, while you have no code to defend. You'll ask them of real humans in ch83–84: Did they find the dock without help? Did they take a second contract unprompted? Can they say what they're saving up for? Did they ever check the wind before accepting a contract? Where did they look when they were lost? Each "no" maps to a specific chapter's fix — that's why you write them first.

## Checkpoint

The repo gains a `design/` directory and the game gains its nouns.

- `design/saltwind-game.md` fits on one screen and contains an explicit cut list and a "done when" sentence.
- `src/economy.odin` compiles; `GOODS`, `PORTS`, `UPGRADES` are enumerated/fixed arrays — adding a `Good_Id` without a table entry is a compile error.
- On paper: every good has a producing port and a consuming port, and you can trace at least two profitable *triangle* routes.
- You can state the core loop in one breath. Out loud. (Really — it's the elevator pitch you'll need for the itch page in ch84.)

## Pitfalls

- **"I'll just quickly add weather damage to cargo / crew morale / a fishing rod."** Scope creep wears the costume of small ideas. The test is mechanical: does it tighten contract → sail → coins → upgrade? Cargo damage in storms arguably does (risk pricing!) — fine, *write it in the doc as a stretch*, don't code it. Morale doesn't. Cut.
- **Engine work disguised as game work.** "Before I do contracts I should refactor the UI batcher / add a settings system / port to ash fully." You will recognize the warmth of the old dopamine. The next seven chapters schedule all of that — *after* the loop exists.
- **Designing economy depth nobody will see.** Production chains, regional inflation, futures markets — simulation-brain loves this. Players see a number next to a good in a port. Ch78's drifting prices plus events read as a living economy from the deck; build that, ship, then deepen if players ask.
- **Five identical ports.** If every port trades everything, routes don't matter and the chart (ch79) has nothing to say. The `produces`/`consumes` asymmetry is load-bearing; keep each port's lists short (2–3 goods).
- **Skipping the paper step because "the structs are the design."** The structs encode *what*; the page encodes *why* and — critically — *what was cut*. Code can't say no for you.

## Exercises

1. Price-check your world: for each pair of ports, compute best-case profit per tonne-kilometer (base prices, straight-line distance) in a scratch proc. If one route dominates everything, adjust `base_price` or port lists until at least three routes compete.
2. Add a `flavor: string` to `Port` — one sentence each ("Kelpmouth smells of tar and low tide"). It costs nothing and ch78's dock screen will make it the cheapest worldbuilding in the game.
3. Run your design doc through three of Schell's lenses (the Lens of Fun, of Motivation, of the Toy — summaries are findable online) and write one sentence of findings per lens into the doc.
4. **Stretch:** derive port names from the world seed instead of hardcoding — syllable tables (`"Gull"+"haven"`, `"Kelp"+"mouth"`) keyed off `core:math/rand` seeded per island. Different seed, different world, different ports: the trading game inherits ch21's infinity.

## Commit

`git commit -m "ch77: game design doc, cut list, economy data tables"`

← [Chapter 76 — Milestone: A Living World](../part-11-a-living-world/ch76-milestone-a-living-world.md) · [Chapter 78 — Ports of Call](ch78-ports-of-call.md) →
