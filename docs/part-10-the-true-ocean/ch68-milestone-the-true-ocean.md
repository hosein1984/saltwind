# Chapter 68 — MILESTONE: The True Ocean

*Part 10 — The True Ocean · Estimated time: 4h · learnopengl: review — this milestone integrates Tessendorf's full pipeline; skim his notes once more and marvel at how much of them you've implemented*

**What you'll see when done:** a sixty-second performance — glassy dawn calm building to a whitecapped, spray-blown storm and easing back — triggered from one debug button, every system you've built this part playing its section.

## Where we are

Count what changed since Chapter 60: wave evaluation moved to compute (61), a statistical spectrum replaced hand-tuned waves (62), a GPU FFT synthesizes 65,536 of them (63), the sea breaks and foams by its own physics (64), the boat floats on a CPU mirror of the same math (65), the underwater world exists (66), and the water answers the hull (67). You built the ocean tech that AAA studios staff teams for, alone, in Odin, validated against your own reference implementations. This milestone does what milestones do: integrate, audit, showcase — and then send you off for a well-earned rest.

## Concepts

### A showcase is a test plan wearing a costume

The scripted Calm→Storm→Calm sequence isn't (only) for showing off. It sweeps the entire parameter space of the part *continuously* — and continuous sweeps find the bugs that preset-hopping hides: the foam that never decays because decay only resets on state change, the reflection FBO clipping that fails only above 1.5 m amplitude, the buoyancy spring that resonates at one specific sea state on the way *down* from storm. Drive every dial through its range, slowly, while watching. That's also exactly what a milestone integration sweep is.

### Scripting on top of Weather, not beside it

Chapter 47's `Weather` already knows how to lerp parameter blocks; Chapter 64 taught those blocks to drive physics. The showcase is therefore tiny: a timeline that feeds *targets* to the existing machine:

```
t:      0s ─────── 20s ─────── 35s ─────── 45s ──────── 60s
state:  Clear  →   Overcast  → Storm  →    Overcast  →  Clear
        glassy     building    whitecaps,  foam decays  glassy again,
        dawn       swell       spray,      slowly       sea remembers
                               god rays                 (ch64 hysteresis)
```

Everything lerps because everything *already* lerps — spectrum amplitude and wind (64), fog and σ (47/66), god-ray density (59/66), foam threshold (64). Cloud cover gets a placeholder scalar this part (sky-shader gray-out); Chapter 69 — literally the next chapter — replaces it with real volumetric clouds. The seam is intentional.

## Build

1. **The showcase script.** In `src/showcase.odin`:

   ```odin
   Showcase_Key :: struct { t: f32, state: Weather_State }

   SHOWCASE_STORM := []Showcase_Key{
       {0, .Clear}, {20, .Overcast}, {35, .Storm}, {45, .Overcast}, {60, .Clear},
   }

   Showcase :: struct { keys: []Showcase_Key, t: f32, active: bool, next: int }

   showcase_update :: proc(sc: ^Showcase, w: ^Weather, dt: f32) {
       if !sc.active do return
       sc.t += dt
       if sc.next < len(sc.keys) && sc.t >= sc.keys[sc.next].t {
           weather_set_target(w, sc.keys[sc.next].state)   // the ch47 entry point
           sc.next += 1
       }
       if sc.t >= sc.keys[len(sc.keys)-1].t + 5 do sc.active = false
   }
   ```

   A microui button — "▶ Calm→Storm→Calm (60s)" — sets `active`, resets `t`. Add a camera suggestion to the panel, not the code: chase-cam, low, slightly abaft the beam. (Resist auto-driving the camera; you'll want to *look around* during the storm, and so will anyone you hand the build to.)

2. **Integration sweep.** Run the showcase repeatedly; station yourself at each subsystem. The known trouble spots, with fixes:

   - **Reflection FBOs at storm seas (ch30).** The clip-plane bias was tuned for ±0.6 m Gerstners; 2 m FFT swell pokes through, leaving holes in reflections at wave troughs. Make the bias track the sea: `bias = max_amplitude_estimate(weather)` — a `0.1 + 1.5 * wave_amplitude` lerp is plenty. Same check for the refraction plane.
   - **Buoyancy stability in chop (ch65).** Watch crates during the storm *peak* and the *decay* phase. Resonant bouncing → damp velocity, clamp spring force; tunneling at crest collisions → substep when relative velocity is high.
   - **Underwater in storm (ch66).** Dive at t=35. Surface-crossing hysteresis must hold in 2 m chop (widen the band proportional to amplitude); σ shift to murky should be visibly arriving with the storm.
   - **Ripples vs. swell (ch67).** Hull-slam splats in storm chop can compound; verify the clamp on splat strength, and that the rim mask hides the window even when 2 m of FFT displacement carries it around.
   - **The foam tail.** After t=60, the sea should still wear decaying foam streaks for a minute (ch64 exercise 4 if you did it; if not, watch foam vanish abruptly and decide if you care — then do the exercise).

3. **Performance audit.** Pull up the Chapter 60 pass panel and write the Part 10 column next to your Part 9 numbers (1080p, mid-range desktop GPU, storm state — your numbers will differ; the *shape* shouldn't):

   | Pass | ch60 (ms) | ch68 (ms) |
   |---|---|---|
   | ocean sim (evolve+FFT+assemble+foam) | — | ~0.35 |
   | ripple sim | — | ~0.12 |
   | shadow cascades | ~1.2 | ~1.2 |
   | G-buffer + lighting | ~2.0 | ~2.1 |
   | reflection+refraction FBOs | ~1.4 | ~1.5 |
   | SSAO / SSR / god rays | ~1.8 | ~2.0 |
   | post (HDR, bloom, FXAA, underwater) | ~0.9 | ~1.0 |

   The headline: the entire FFT ocean — spectrum, 16 butterfly passes, assembly, foam, ripples — costs **under half a millisecond**. Less than your bloom. Say it out loud; in Chapter 28 the ocean was four waves in a vertex shader. If your numbers are wildly off, RenderDoc the outlier — the usual suspect is a stray full-pipeline barrier (`gl.MemoryBarrier(gl.ALL_BARRIER_BITS)` left from debugging) serializing the dispatches.

4. **Screenshot #8.** It's a pair this time, from the same anchorage:
   - **Storm bow-shot:** mid-showcase, camera low near the bow quarter, sun behind broken "clouds" (your placeholder gray at ~0.7), whitecaps to the horizon, foam streaking the swell, spray particles off the crests, the hull throwing rings.
   - **Glassy dawn:** showcase ended, calm restored, sun just up, long low swell, reflections nearly unbroken, maybe one crate drifting. The *same ocean*. That pair — physics apart, one parameter block apart — is the part's thesis stated in two images.

   Use the Chapter 51 screenshot mode (UI off, supersampled). Put them side by side in your repo's README.

5. **Self-test checklist.** All must pass before you call the part done:
   - [ ] `fft self-test ... PASS` prints at startup (and fails loudly if you break a twiddle).
   - [ ] Debug cubes surf the surface in every weather state.
   - [ ] Freeze time: surface, foam injection, and ripples all hold still (foam *decay* may continue — it's stateful; know why).
   - [ ] Kill the compute path (force the ch61 fallback): the game still runs on Gersters for the 3.3 crowd. (Chapter 83 will thank you.)
   - [ ] One full showcase loop with the pass panel open: no pass spikes, no GL debug-callback messages.

## Quiz

Answers in the fold — write yours first.

1. A colleague's FFT ocean is a perfect checkerboard of up/down texels. What's the bug, where does it come from, and where is the one right place to fix it?
2. You see `gl.MemoryBarrier(gl.SHADER_IMAGE_ACCESS_BARRIER_BIT)` between the last ocean dispatch and the ocean *draw call*. The ocean renders correctly on your machine. Ship it?
3. Why must `h̃₀(−k)` be the conjugate of `h̃₀(k)` — what literally goes wrong on screen if the symmetry is broken?
4. Why does the Phillips spectrum need the `exp(−1/(kL)²)` factor — what would a storm sea look like without it, given a calm wind?
5. The Jacobian at a texel is −0.2. What is the surface doing there geometrically, and what do we do about it visually?
6. Why did we choose the CPU mirror over PBO readback for buoyancy, when readback gives the *exact* rendered surface? Two reasons minimum.
7. Your ripple sim runs fine at 60 fps but explodes the first time a frame takes 50 ms. Why — and why doesn't the FFT ocean have the same failure mode?
8. Underwater, a red buoy 10 m away looks gray-green but white sand 10 m away looks blue-white. Same water, same distance — explain with one equation.

<details>
<summary>Answers</summary>

1. The missing `(−1)^(x+z)` permutation sign: the spectrum was built on *centered* frequencies (`k = 2π(m−N/2)/L`) but the FFT sums uncentered indices; the shift theorem turns the N/2 offset into an alternating sign in the spatial result. Fix it once, in the assembly pass, applied to every transformed value — including the neighbor taps used for normals and the Jacobian (and in the CPU mirror!).
2. No. The barrier bit must match how the data is *consumed next*: the draw call **samples** the maps with `texture()`, so it needs `TEXTURE_FETCH_BARRIER_BIT`. `SHADER_IMAGE_ACCESS` orders against `imageLoad/Store` only. "Works on my driver" is exactly the symptom of an incorrect barrier — it's undefined, not wrong-everywhere.
3. A sum of complex exponentials is real only if the spectrum is Hermitian: `h̃(−k) = h̃*(k)` makes each wave's imaginary part cancel its mirror partner's. Broken symmetry leaves a nonzero imaginary field — and since you render the real part, you see a wrong, lower-energy, subtly asymmetric sea, plus the imaginary residue makes validation against the CPU reference fail (which is how you'd catch it).
4. `L = V²/g` is the largest wave the wind can sustain; the exponential suppresses wavelengths beyond it. Without it, a 4 m/s breeze would carry energy at 300 m wavelengths — giant rolling swell under a calm wind, the "wrong planet" look. (And conversely, the factor is why raising wind speed *reshapes* the sea instead of just scaling it.)
5. Negative Jacobian = the choppy mapping folds the surface through itself — area locally inverts; geometrically the mesh self-intersects, physically the wave is breaking. We inject foam there (threshold well above 0, ~0.5–0.9), which both depicts the breaking and hides the geometric fold.
6. Determinism (same seed + same clock = same surface, so fixed-timestep physics replays identically and never waits), zero latency (readback is 2+ frames stale — visible hull float at speed), independence from the render loop (physics runs with the window minimized), and no risk of an accidental pipeline stall. Readback's exactness buys nothing buoyancy needs — hulls don't respond to the chop the mirror filters out.
7. The ripple sim integrates the wave equation with an explicit stencil bound by CFL: `c·Δt/Δx ≤ 1/√2`. A 50 ms frame stepped with render-dt (or a fixed-timestep loop that does one giant catch-up step) violates it and the scheme diverges exponentially. The FFT ocean isn't an integration at all — it *evaluates* a closed-form function of `t` each frame; any `t` is as stable as any other.
8. Beer–Lambert per channel: `T = e^{−σd}` with `σ_red ≈ 7×σ_blue`. The buoy's *red* reflectance has nothing left to reflect — its signal is absorbed en route (sun→buoy plus buoy→eye), leaving gray-green. The sand is white: it reflects the blue-green light that *does* survive, so it reads blue-white. Same water, same distance, different source spectra.

</details>

## Share it

Post the storm/dawn pair — r/odinlang, the Odin Discord's #showcase, the learnopengl screenshots thread, or wherever you posted Screenshot #4 back when the ocean was four sine waves (find that old post first; the before/after will do your motivation more good than anything in this chapter). "Tessendorf FFT ocean in Odin, CPU-validated, half a millisecond" is a sentence very few hobby programmers get to write. You wrote the whole stack under it.

## Where to rest, and the recap for when you return

This is a real stopping point — the best since Chapter 52. Sail your storm. Take weeks if you like.

**The one-paragraph recap to reread when you return:** Saltwind's ocean is now a Tessendorf FFT sea: `ocean_spectrum.comp` shapes per-world-seed Gaussian noise by the Phillips spectrum into `h̃₀(k)` whenever Weather's wind changes; each frame `ocean_evolve.comp` advances it to time `t` via `ω=√(gk)`, sixteen `ocean_butterfly.comp` ping-pong dispatches inverse-transform height and choppy displacement, and `ocean_assemble.comp` applies the `(−1)^(x+z)` permutation, builds normals and the fold-detecting Jacobian, feeding the foam accumulator. The boat floats via `ocean_height_at` — same signature since Chapter 28 — now backed by a 64² CPU FFT mirror of the same spectrum. Underwater is a post pass (per-channel Beer–Lambert) plus caustics and the Snell window; a 512² wave-equation ripple sim follows the hull and composites on top. All of it is driven by `Weather_Params`, all of it is on the pass panel, and `fft self-test PASS` at startup means the math is still the math.

Next part, you look *up*: volumetric clouds, cloth sails, living creatures. The sky is about to deserve the sea.

## Commit

`git commit -m "ch68: MILESTONE — the true ocean: showcase, integration sweep, audit"`

← [Chapter 67 — The Boat Writes on Water](ch67-the-boat-writes-on-water.md) · [Chapter 69 — Castles of Vapor](../part-11-a-living-world/ch69-castles-of-vapor.md) →
