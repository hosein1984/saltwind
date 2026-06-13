# Chapter 74 — The Tempest

*Part 11 — A Living World · Estimated time: 5–6h · learnopengl: no direct equivalent — this is engine/game material*

**What you'll see when done:** a real storm — a bolt tears the sky open, the world flashes white, thunder arrives *late* across the water, rain hammers everything but the deck under your sail, and spray rips off the whitecaps.

## Where we are

Almost every system a storm needs already exists: Weather transitions (ch47), particles (ch46), the FFT sea with wind-driven spectra (ch62–64), the ripple sim (ch67), clouds (ch69), cloth (ch70), audio (ch36), bloom (ch41). This is the conductor's chapter: little new machinery, lots of *orchestration* — making twelve systems hit the same downbeat. The one genuinely new toy is lightning, and it's a delight: forty lines of Odin geometry plus your existing bloom equals the most dramatic frame Saltwind can produce.

## Concepts

### Lightning bolts: midpoint displacement

A bolt is a jagged polyline from cloud base to (near) the sea. The classic generator is **recursive midpoint displacement** — the same fractal idea as terrain noise, in one dimension:

```
start:   A ─────────────────── B
split:   A ────── M ────────── B      M = midpoint + random offset ⊥ to AB
recurse: A ── m ─ M ── m' ──── B      offset halves each level
                                       + occasionally fork a branch from M
```

6–7 levels gives ~64–128 segments. Render as a triangle strip of camera-facing quads (the ch46 billboard math, applied per segment) with an **emissive HDR color far above 1.0** (`vec3(8, 9, 12)` and up) — and stop. You don't need glow geometry: the ch41 bloom pass *is* the glow, the ch58 SSR and ocean reflections pick it up over the water, and the whole composite happens for free because you built a real HDR pipeline three parts ago.

### The flash: lighting as an event

A bolt you see is one frame of geometry; a *flash* is the world's lighting changing. For 1–3 frames (or ~80 ms with exponential decay):

- **Override the directional light**: blend `sun_dir` toward the bolt's azimuth (elevated ~60°), and multiply `sun_color * sun_intensity` up to something brutal (×30–50) with a cold blue-white tint. Everything downstream — terrain, ocean specular, CSM shadows from the *bolt's* direction for a frame — reacts because they all read the same struct (ch27's single source of truth, cashing its largest check).
- **Brighten sky and clouds**: a `u_flash` uniform (0..1, decaying) added into the sky function and ch69's cloud ambient term — clouds light up *from within* when the bolt is behind them, which sells distant lightning even when the bolt itself is off-screen.

Don't re-capture IBL for the flash — ambient lags lighting by milliseconds in reality too, and the amortized capture (ch43) would smear it. The direct-light override carries the moment.

### Thunder: the speed of sound is content

Light is instant; sound crawls at ~343 m/s. Schedule the thunder sample at `delay = distance(bolt, camera) / 343.0` seconds after the flash, with volume falling off by distance and a low-pass-feeling choice of sample for far strikes (rumble) vs near (crack — pick from 2–3 samples by distance band). A strike 2 km off the beam flashes, and *six seconds later* the rumble arrives. Players who notice this detail never stop telling people about it. (`vendor:miniaudio` from ch36: play with a delay either by scheduling against your sim clock — an entry in a small pending-sounds array — or miniaudio's start-time facilities; the sim-clock array is simpler and survives pause correctly.)

### Rain v2: occlusion and impact

Ch46 rain falls through sails and cabin roofs. The fix reuses shadow thinking: render a tiny **top-down depth map** (256², orthographic, looking straight down, covering ~40 m around the boat — the shadow-map machinery from ch39 with a different camera) of just the boat's meshes. A raindrop spawning (or sampled per particle, it's one fetch) at world XZ compares its height against the mask: below the recorded depth → it's under cover → kill or don't spawn. No rain under the sail; a dry shadow on deck shaped exactly like your rig. Cheap, robust, startlingly convincing.

Where rain *lands*, it should answer:

- **Deck splashes:** on kill-by-collision against deck height, spawn a 3-frame splash-ring billboard from a tiny atlas (ch46 machinery, new texture).
- **Water impacts:** feed a few dozen random impulses per step into the ch67 ripple sim around the boat — the rain-pocked water surface that results is one of those effects nobody can name but everyone misses when it's gone.

### The churning sea and torn spray

Storm waves already work — ch62's spectrum takes wind speed, ch68 routed Weather into it. Two additions complete the picture. First, **spray torn from whitecaps**: ch64's Jacobian foam threshold tells you *where* crests are breaking; where foam value near the camera (sample the CPU mirror or a small readback you already maintain for buoyancy) exceeds a storm threshold, spawn wind-driven spray particles that fly far and low — `velocity = wind_vec * 1.2 + up * small`. Second, **Storm_Intensity as a continuum**: replace the binary storm with a 0..1 scalar in `Weather_Params`, so the lightning scheduler, spray rate, and rain rate all scale smoothly through a transition instead of switching on.

### The lightning scheduler

A storm conductor in twenty lines: while `storm_intensity > 0.5`, roll the next strike `rand.float32_range(3, 15) / storm_intensity` seconds out; pick a position in an annulus 200–2500 m from the boat (biased downwind — storms pass over); fire: generate bolt geometry, set flash = 1, schedule thunder. Keep the most recent bolt's mesh around for its 2-frame life, then free it. A debug key to force a strike *now* is mandatory tuning equipment.

## Build

1. **`src/lightning.odin` — the generator.**

   ```odin
   lightning_generate :: proc(from, to: glsl.vec3, levels: int) -> [dynamic]glsl.vec3 {
       pts: [dynamic]glsl.vec3
       append(&pts, from, to)
       offset := glsl.length(to - from) * 0.18
       for _ in 0 ..< levels {
           i := 0
           for i < len(pts) - 1 {
               mid := (pts[i] + pts[i + 1]) * 0.5
               mid.x += rand.float32_range(-offset, offset)
               mid.z += rand.float32_range(-offset, offset)
               inject_at(&pts, i + 1, mid)              // ordered insert
               i += 2
           }
           offset *= 0.5
       }
       return pts
   }
   ```

   Branches (optional, recommended): at each level, ~15% chance to recurse a short sub-bolt from a midpoint toward down-and-outward. Build the quad-strip mesh from the polyline (width ~0.5 m core), upload to a reusable `DYNAMIC_DRAW` mesh, draw unlit with the emissive HDR color into the HDR buffer before post.

2. **Flash plumbing.** `Storm_State :: struct { flash: f32, bolt_pos: glsl.vec3, next_strike: f32, thunder_queue: [4]Pending_Sound }`. On strike: `flash = 1`; each frame `flash *= exp(-dt * 14.0)`. While `flash > 0.01`: override the sun uniforms as in Concepts (compute the blended values where you already set sky uniforms — *don't* mutate `Sky` itself, or a pause mid-flash freezes the world white). Add `u_flash` to sky + cloud shaders.

3. **Thunder.** Pending-sounds array checked each sim step: `if sim_time >= entry.at { play(entry.sample, entry.volume) }`. Distance bands pick the sample; volume `clamp(1.0 - dist/4000.0, 0.15, 1.0)`. If you skipped ch36, this is the moment to un-skip it — a silent storm is half a storm.

4. **Rain occlusion mask.** New small pass in the ch60 list (only when `rain_rate > 0`): ortho depth render of the boat hierarchy, top-down, into a 256² depth texture; remember its view-proj. In the rain spawn/update, project particle XZ, compare heights, kill under cover. Reuse the ch39 depth-pass shader — zero new GLSL.

5. **Impacts.** Deck splash atlas + emitter on collision with deck AABB top; ripple impulses: per sim step, `n = int(rain_rate * dt * 0.2)` random points in a 25 m disc → ch67's impulse entry point (whatever you named it — the same hook the hull uses).

6. **Spray from whitecaps + scheduler.** Foam-threshold emitters (Concepts) with spawn rate × `storm_intensity`; the scheduler from Concepts in `weather_update`'s orbit. Extend `Weather_Params` with `storm_intensity` (Clear 0, Overcast 0.15, Storm 1.0) — the ch47 lerp gives you *gathering* storms for free: spray begins before the first bolt, exactly like a real front.

7. **The performance.** Key 3, wait through the transition, sit in it: bolts, delayed rumbles, dry deck under the sail, sea pocked with rain, spume streaming off crests downwind, the ch70 sail flogging if you round up. Then key 1 and let the world wring itself out. Take the screenshot when the bolt lands behind the volcanic island. You'll know the one.

## Checkpoint

A storm that behaves like weather, not a filter: discrete strikes with correct thunder latency, lighting that genuinely changes for the flash, rain that respects cover and marks the water, and a sea shedding spray at the crests.

- Force a strike 2 km away (debug key + position override): flash now, rumble ~6 s later, quieter than a near crack.
- During the flash, shadows visibly re-point for a frame or two (the directional override reaches CSM) — watch the mast's shadow jump.
- Stand under the sail in rain: deck dry in the sail's footprint, splash rings everywhere else; furl the sail (ch70 exercise 3) and the dry patch vanishes.
- GPU cost of storm extras (mask pass + bolt + particles) under ~0.5 ms — confirm on the ch60 pass timers.

## Pitfalls

- **The bolt is a thin dim line.** Emissive color isn't actually >1 (a clamp or an sRGB texture sneaked into the path), or you drew it after tonemap — it must enter the HDR buffer so bloom can feast.
- **Flash makes the screen pure white with no detail.** You scaled intensity *and* exposure has no headroom — let ACES (ch40) do its job; flash intensity ×30 through tonemap reads as "blinding but visible." If you're clipping, your override multiplied the already-multiplied value each frame (apply to a cached base, not in-place).
- **Thunder ignores pause / plays during it.** You scheduled on wall-clock time, not `sim_time`. Pending sounds live on the sim clock like everything else (ch10 discipline).
- **Rain stops at the mask boundary in a hard 40 m square.** Particles outside the mask's coverage must default to *visible*, not occluded — clamp your projected UV check and treat out-of-bounds as uncovered.
- **Ripple sim explodes under rain.** Too many/too strong impulses per step. Impulse magnitude scales *down* with count; total injected energy per second is the budget, not per-drop strength.
- **Storm feels like a toggle, not weather.** Things gate on `state == .Storm` instead of scaling with `storm_intensity` — ch47's parameters-not-states rule, third reminder, still undefeated.

## Exercises

1. Sheet lightning: strikes far beyond the horizon render *no bolt* — only the cloud/sky flash and a long-delayed rumble. Cheaper than a bolt and arguably more atmospheric; weight the scheduler 50/50.
2. The wind-shift front: tie a one-time 30–60° wind direction veer to storm onset (lerped, ch47 exercise 4). Your sail, cloth, gulls, gust fronts, and wave direction all swing together — the most systems one parameter has ever moved in this codebase.
3. St. Elmo's fire: faint additive glow particles at the masthead when `storm_intensity > 0.8`. Historically accurate, two lines, deeply spooky.
4. **Stretch:** bolt light *source* — for the flash frames, add a temporary point light at the strike position into the ch55 deferred light list with huge radius. Near strikes then light the rain and the wave faces from the side, not just from above. Compare against the directional-only version and decide if it earns its draw.

## Commit

`git commit -m "ch74: storms v2 — lightning, flash override, thunder delay, rain occlusion, whitecap spray"`

[← Ch. 73: The Green and the Gale](ch73-the-green-and-the-gale.md) · [Ch. 75: Many Shores →](ch75-many-shores.md)
