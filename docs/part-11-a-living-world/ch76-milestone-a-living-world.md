# Chapter 76 — MILESTONE: A Living World

*Part 11 — A Living World · Estimated time: 3–4h · learnopengl: review of Part 11*

**What you'll see when done:** nothing new — and that's the test. You'll drop anchor, put the controls down for two minutes, and watch a world that no longer needs you.

## Where we are

Eight chapters ago, Saltwind was a gorgeous diorama: a perfect ocean under a perfect sky, holding its breath. Now clouds build and drift, canvas luffs and fills, gulls wheel and perch, fish school under the hull, gusts comb the grass, storms roll through and pass, and four kinds of shore wait over the horizon. A milestone chapter, as always, means three things: prove it all works *together*, prove it all fits in the *frame budget*, and take the screenshot. Then — rest. You've earned a long one.

## Concepts

### The anchored watch test

The defining property of a living world is that it generates moments *without input*. So the acceptance test is literal inactivity: anchor in a bay, let go of the keyboard, and watch for two minutes. The world should produce, unprompted:

```
0:00  clouds drifting downwind; their shadows (ch69 ex.1) crossing the bay
0:10  the anchored sail luffing gently head-to-wind — cloth telling the truth
0:20  gulls arriving, circling, one settling on the spreader
0:35  a gust front: dark patch on the water, then grass, then palms (ch73's wave)
0:50  fish flickering under the hull, parting around the anchor line's shadow
1:10  weather autopilot (ch47 ex.3) tips toward Overcast: coverage climbs,
      ambient cools (IBL), the sea state stiffens
1:40  first rumble of a passing squall; rain pocks the water, deck dry under sail
2:00  it's already easing — the front moves on. The world didn't notice you watching.
```

If any beat fails — gulls flap in unison, the sail hangs rigid, the gust arrives everywhere at once — you know which chapter to revisit. This test is also your *demo*: it's what you show people, because it requires no explanation.

### The integration sweep

Part 11 added five always-on simulations. The classic milestone bugs are *seams between systems*, and you hunt them with the same checklist discipline as ch60:

- **One wind:** sail cloth, cloud scroll, gust texture, gull drift, spray velocity, smoke — change wind direction 180° via debug key and confirm *everything* swings. Any holdout has a private wind.
- **One clock:** pause (ch10) must freeze cloth mid-luff, boids mid-bank, clips mid-flap, lightning mid-flash — and the camera must still fly. Anything that keeps moving is reading wall-clock time.
- **One weather:** scrub the Clear→Storm transition slowly and watch for *steps* — any parameter that jumps instead of easing got wired to a state instead of `weather.current` (ch47's rule; final audit).
- **Determinism:** same seed → same islands, biomes, vegetation, *and* the same first ten seconds of boid motion if you seeded their spawn (worth it for debugging; drift after that is fine and expected).

### The Part 11 frame budget

Five new systems on the ch49 CPU timers and ch60 GPU pass timers. Targets for a midrange GPU at 1080p — yours will differ; what matters is that *you have numbers and know which knob moves each*:

| System | Where | Budget | The knob |
|---|---|---|---|
| Clouds (march + upsample) | GPU | 1.5–2.5 ms | steps, quarter→eighth res, march distance clamp |
| Cloth (sail ×1–2) | CPU | < 0.1 ms | iterations, grid size |
| Boids (~400 + grid) | CPU | < 0.8 ms | counts, cell size, rule radii |
| Skeletal (LOD0 sample + upload) | CPU+GPU | < 0.3 ms | LOD0 count, bone count |
| Vegetation wind | GPU | ~0 (vertex math) | flutter distance fade |
| Storm extras (mask, bolt, particles) | GPU | < 0.5 ms (storm only) | mask res, particle caps |
| Lightning gen (per strike) | CPU | one-off, < 0.1 ms | levels |
| **Part 11 total** | | **≤ ~4 ms** | |

Stack that on Part 9's pipeline and Part 10's ocean and you should still clear 60 fps with headroom. If not, the table tells you where to negotiate — and ch49's adaptive-quality trick (scale the knob when frame time spikes) now has five new knobs to scale.

## Build

1. **Run the watch test.** Two full minutes, hands off, three different anchorages (temperate bay, atoll lagoon, off the volcanic coast). Note every beat that breaks the spell — that's your punch list. Fix in priority order: unison motion first (it's the most artificial tell), parameter pops second, perf hitches third.

2. **Run the integration sweep.** The four audits from Concepts. Bind the debug keys you need (wind-flip, force-strike, weather-scrub) permanently — Part 12's polish work reuses all of them.

3. **Fill the budget table.** Your numbers, in a comment block or your project notes. Any row over budget: apply its knob until it fits, and write down what you traded (e.g., "clouds 48 steps, slight banding at horizon, acceptable in motion").

4. **Screenshot #9 — a pair.** Photo mode (ch51): one frame of **storm lightning over the volcanic island** — bolt behind the ridge, flash on the wave faces, sail straining (force-strike key earns its keep); one frame of **calm mangrove dawn** — 6:30 light, glassy water in a channel, gulls low, mist if you built the ch47 fog bank. The pair *is* the part: the same world, two temperaments.

5. **Share it.** r/odinlang, the Odin Discord, the learnopengl screenshots thread — and this time post the *pair* with one line: "all procedural, all simulated, Odin + OpenGL." Part 11 screenshots are the ones that get replies. Read the replies on a day motivation dips.

6. **Commit and tag:** `git tag part-11-complete`.

## Checkpoint

- [ ] The anchored watch test produces every beat in the script, in three biomes, without input.
- [ ] Wind-flip, pause, and weather-scrub audits all pass — one wind, one clock, one weather.
- [ ] Budget table filled in; total Part 11 cost ≤ ~4 ms on your hardware, every row attributed.
- [ ] Same seed → same world, byte for byte, biomes and forests included.
- [ ] Screenshot pair #9 taken and shared.
- [ ] Clouds appear in IBL (overcast dims the deck), thunder lags the flash, and the sail luffs in irons — the three best "systems talking" moments, all verified.

## Quiz

Answers in the fold — write yours first.

1. Why is Verlet integration so much more stable than Euler spring-mass for cloth, in one sentence?
2. In the cloud density function, why must coverage *remap* the base noise rather than just multiply it?
3. A vertex is skinned 100% to joint J. The animation poses J exactly at its bind-pose global transform. What does `global[J] * inverse_bind[J]` evaluate to, and why is that the most useful debugging fact in the chapter?
4. Why does `linalg.quaternion_slerp` negate one input when `dot(a, b) < 0`?
5. Your 400 boids run at O(n·k) instead of O(n²). What property of the *rules* makes the spatial hash correct (not just fast)?
6. The gust front visibly travels across the island. What two properties of the gust noise sampling make that happen?
7. Lightning thunder arrives 4.2 s after the flash. Roughly how far away was the strike, and which system owns that delay — audio, weather, or the sim clock?
8. Why does adding a fifth biome require zero changes to the scatter, splat, or grading *code*?

<details>
<summary>Answers</summary>

1. Verlet stores no explicit velocity — it's implicit in `x - x_prev` — so when constraints move a position, the velocity automatically becomes consistent instead of fighting the correction (the desync that makes spring-mass explode).
2. Multiplying scales all density uniformly (thin everywhere); remapping (`remap(base, 1-coverage, 1, 0, 1)`) raises the threshold the noise must clear, so low coverage *carves away* all but the noise cores — distinct puffs instead of global haze.
3. The identity matrix — the inverse bind matrix is the inverse of exactly that bind-pose global. So "render with bind pose and check nothing moves" isolates skinning-pipeline bugs from animation-data bugs.
4. `q` and `-q` represent the same rotation (double cover); if their dot is negative, naive interpolation takes the long arc (>180°). Negating one flips it to the equivalent short path.
5. All three rules depend only on neighbors within a *bounded radius* — so a grid with cell size ≥ the largest radius provably contains every relevant neighbor within the 27 adjacent cells.
6. The noise UVs scroll *along the wind direction* (so features physically translate downwind), and the slow large octave dominates the envelope (so a single front stays coherent over seconds instead of decorrelating).
7. ~1.4 km (4.2 s × ~343 m/s). The sim clock owns it: the strike schedules a pending sound at `sim_time + d/343`, which is why thunder correctly freezes with pause.
8. Because those systems were parameterized: scatter consumes `[]Scatter_Rule`, splat consumes uniforms, grading consumes a params struct. A biome is a row in `BIOME_TABLE` supplying those values — data, not branches.

</details>

## Pitfalls

- **The watch test feels dead despite every system working.** Check *rates*: weather autopilot too slow to act within two minutes, gull perch chance too low, gust octave too slow. Liveliness is mostly event frequency tuning, not features.
- **It all works until Storm + boids + clouds coincide, then hitches.** Worst-case frames are what budgets are for — profile *during* the storm, not at anchor in the sun. The spike is usually particle spawn bursts; cap them (ch49 ex.3).
- **Pause audit fails for exactly one system.** It's the one whose update you call from the render loop "because it's visual" — cloth and clip sampling are the usual suspects. Simulation goes in the fixed step, no exceptions, even pretty simulation.
- **Screenshots look worse than the live game.** Motion is doing heavy lifting (clouds, cloth, water all read better animated). For stills: lower the sun, force a bolt, raise wave amplitude one notch — stills need ~20% more drama than play does.

## A place to rest

This is the best stopping point in the entire course, and you should genuinely consider taking it. **The recap to reread when you return:** Saltwind is a complete living world — a 4.3-core multi-pass renderer (Part 9) drawing an FFT ocean (Part 10) under volumetric clouds, crewed by cloth sails and skeletal gulls, boids below and above, wind that combs the islands, storms that conduct every system at once, and biomes that make the chart worth sailing (Part 11). The git tag is `part-11-complete`. What remains isn't graphics at all: Part 12 turns this world into a *game* people can download — trading loop, ports, chart room, save files, menus, min-spec fallbacks, and an itch.io page with your name on it. When you're hungry again, Chapter 77 is waiting. Bring the screenshot pair; it's going on the store page.

## Commit

`git commit -m "ch76: milestone — a living world; watch test, integration sweep, budget audit"`

[← Ch. 75: Many Shores](ch75-many-shores.md) · [Ch. 77: The Shape of the Game →](../part-12-shipping-a-game/ch77-the-shape-of-the-game.md)
