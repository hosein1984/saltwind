# Chapter 62 — The Spectrum of the Sea

*Part 10 — The True Ocean · Estimated time: 4h · learnopengl: no direct equivalent — canonical reference: Jerry Tessendorf, ["Simulating Ocean Water"](https://people.computing.clemson.edu/~jtessen/reports/papers_files/coursenotes2004.pdf), SIGGRAPH course notes, 1999–2004*

**What you'll see when done:** a debug quad showing the *frequency-domain fingerprint of a wind sea* — a glowing field of random complex amplitudes, bright at low frequencies, stretched along the wind, dark across it — the seed from which Chapter 63 will grow the real ocean.

## Where we are

This is the theory chapter of the part — mostly concepts, with a small but crucial build at the end. Read it slowly; everything in Chapters 63–65 is a mechanical consequence of what's on this page. By the end you'll know exactly *what* the FFT will transform and *why* the result will look like the North Atlantic instead of a bathtub.

## Concepts

### Why eight Gerstners can never be the open sea

Look at real open water and you see motion at every scale simultaneously: 100 m swells, 10 m wind waves, 1 m chop, 10 cm ripples — all at once, none repeating. Now look at your four (or eight, or sixteen) Gerstner waves: a few discrete spikes of energy. The eye is brutal at detecting the difference. With few components, the surface visibly *beats* — patterns recur every few seconds as the sinusoids drift in and out of phase — and the spatial texture is corduroy: too organized, too clean.

Oceanographers describe a real wind sea not as a list of waves but as a **spectrum**: a continuous function saying how much energy lives at each spatial frequency and direction. The sea surface is then modeled as a *random process* — a sum of thousands of sinusoids whose amplitudes are drawn from the spectrum and whose phases are random:

```
energy                       Gerstner: 4 spikes        real sea: continuous
  │   ▄                            │ |                       │▄▄
  │  ▄█▄                           │ |   |                   │██▄
  │ ▄███▄▄                         │ |   |  | |              │████▄▄
  │▄███████▄▄▄▄                    │ |   |  | |              │████████▄▄▄▄▄
  └────────────── frequency       └─────────────            └──────────────
```

The good news: you already own a machine that renders a sum of sinusoids — you've had one since Chapter 28. The problem is purely *scale*: evaluating 256×256 = 65,536 waves per point, per frame, by looping, is hopeless. The FFT (next chapter) evaluates *all of them at all points* in O(N² log N). This chapter builds the spectrum the FFT will consume.

### The Phillips spectrum, term by term

Tessendorf's notes popularized the **Phillips spectrum** for graphics — an analytic model of a fully-developed wind sea. For a wave vector **k** (direction = travel direction of the wave, magnitude `k = 2π/λ`):

```
                exp( −1 / (kL)² )
P_h(k) = A · ───────────────────── · |k̂ · ŵ|²        with  L = V² / g
                       k⁴
```

- **`A`** — a global amplitude knob. It has a physical definition; in practice everyone (Tessendorf included) tunes it by eye. Weather will drive it in Chapter 64.
- **`L = V²/g`** — the largest wave a wind of speed `V` can sustain (`g = 9.81 m/s²`). At `V = 10 m/s`, `L ≈ 10 m`... of *wavenumber scale*: waves with `kL ≫ 1` (shorter than ~L) are unconstrained; waves with `kL ≪ 1` are exponentially suppressed by the `exp(−1/(kL)²)` factor. Wind needs time and distance to build big waves; a gentle breeze simply cannot raise a 200 m swell. This one factor is why a Calm spectrum and a Storm spectrum *shape* differently rather than just scaling.
- **`1/k⁴`** — energy falls off steeply with frequency. Big waves carry most of the energy; chop is texture, not displacement. (Two of the four powers come from converting an energy spectrum to a height-amplitude spectrum; don't sweat the bookkeeping.)
- **`|k̂ · ŵ|²`** — **directional spreading**: `k̂` is the wave's direction, `ŵ` the wind's. Waves aligned with the wind (dot ≈ ±1) get full energy; waves running *across* the wind get none. The square gives a soft cos² falloff. Two refinements you'll implement: raise the exponent (|k̂·ŵ|⁶ gives a tighter, more storm-like sea), and multiply waves moving *against* the wind (dot < 0) by a small factor like 0.1 — Tessendorf notes real seas strongly suppress upwind travel, and killing it also reduces standing-wave shimmer.
- One practical extra: multiply by **`exp(−k²ℓ²)`** with a tiny cutoff length `ℓ` (centimeters). It suppresses wavelengths near and below your texel size, which otherwise alias into crawling noise.

### JONSWAP, for when someone asks

The Phillips model assumes an infinite, fully-developed sea. The **JONSWAP spectrum** (Joint North Sea Wave Project, 1973 — they measured the actual North Sea) refines it with **fetch**: the distance over which wind has blown. As a frequency spectrum:

```
            α g²         ⎛  5 ⎛ω_p⎞⁴⎞
S(ω) =  ─────────── exp ⎜− ─ ⎜───⎟ ⎟ · γ^r       r = exp(−(ω−ω_p)²/(2σ²ω_p²))
             ω⁵          ⎝  4 ⎝ ω ⎠ ⎠
```

- **`ω_p`** — the peak frequency, which *decreases* with wind speed `U` and fetch `F`: `ω_p = 22·(g²/(U·F))^(1/3)`. Longer fetch → energy migrates to longer waves. This is why lake chop is short and steep while ocean swell is long: the Pacific has more fetch than Lake Garda.
- **`α = 0.076·(U²/(F·g))^0.22`** — overall energy, also fetch-dependent.
- **`γ^r`** — the famous **peak enhancement**: `γ ≈ 3.3` sharpens the spectral peak by ~3× relative to the older Pierson-Moskowitz shape (`σ` ≈ 0.07 below the peak, 0.09 above). Real growing seas pile energy near the peak; this term is what makes JONSWAP seas look *organized* — a dominant swell with riders — rather than mushy.

We implement Phillips (simpler, and it's a *k*-space formula, which is what the FFT wants); JONSWAP is an exercise and a one-evening upgrade later — the rest of the pipeline doesn't care which spectrum filled the texture. That's the beauty of the architecture.

### A complex-number refresher (you'll live in ℂ for two chapters)

Everything ahead manipulates complex numbers, for one reason: **a complex number is an amplitude and a phase in one value**, and *multiplying* complex numbers adds phases. Euler's identity is the whole toolkit:

```
e^{iθ} = cos θ + i sin θ            the unit circle, parameterized
                                              Im
multiply by e^{iθ}  = rotate by θ              │    z = a+bi
conjugate z* = a − bi = mirror in Re-axis      │   ╱
|z|² = z·z* = a² + b²                          │  ╱ θ
z + z* = 2a   (purely real!)            ───────┼─────── Re
```

A wave with amplitude and phase is one complex number `h̃`; advancing it in time is multiplying by `e^{iωt}` — *no trig per wave, just complex multiplies*. Heights, though, must be real. The fix is the identity above: a value plus its own conjugate is real. So the time-evolved amplitude is built **conjugate-symmetric**:

```
h̃(k, t) = h̃₀(k)·e^{iω(k)t}  +  h̃₀*(−k)·e^{−iω(k)t}
```

Check it: conjugate the whole expression and replace `k` with `−k` — you get the same thing back, i.e. `h̃(−k) = h̃*(k)`. A spectrum with that symmetry (called *Hermitian*) sums to a purely real surface: the wave at `−k` is the mirror partner whose imaginary part cancels yours. This is why the texture we build today stores **both** `h̃₀(k)` and `h̃₀*(−k)` — the FFT needs the pair.

And the frequencies aren't free parameters: deep-water physics fixes the **dispersion relation**

```
ω(k) = √(g·k)
```

— long waves travel faster than short ones (you met this as `S = √(g/k)` in a Chapter 28 exercise; it's the same statement). Dispersion is *the* reason FFT oceans move so convincingly: every one of the 65,536 waves moves at its own physically-correct speed, so the surface never repeats and big swells visibly outrun their chop.

### The initial spectrum: rolling 131,072 dice

Tessendorf's recipe for the time-zero amplitudes:

```
h̃₀(k) = (ξ_r + i·ξ_i) · √( P_h(k) / 2 )
```

where `ξ_r, ξ_i` are independent **Gaussian** random numbers (mean 0, variance 1). Gaussian, not uniform — sums of many random waves are Gaussian by the central limit theorem, and ocean statistics confirm it; uniform randoms give a subtly flat, dead-looking sea. Each texel of an N×N texture holds one `h̃₀(k)`: random in phase, spectrum-shaped in expected magnitude. The sea is random, but its *statistics* are exactly Phillips.

Which `k` does texel `(m, n)` represent? The frequency grid from Chapter 61's quantization lesson, now centered:

```
k = 2π·(m − N/2, n − N/2) / L        m, n ∈ [0, N)
```

with `L` the tile size in meters. The texel at the center is `k = 0` — the "wave" with infinite wavelength, i.e. the mean sea level. `P_h` divides by `k⁴`, so `k = 0` must be special-cased to zero **or your entire ocean becomes NaN** (the #1 crash of this part; one NaN texel spreads through the FFT to every output texel).

## Odin notes

`core:math/rand` today: `rand.float32()` returns uniform [0,1) using `context.random_generator`; seed deterministically with `rand.reset(seed)` (the old `rand.create` API is gone). Gaussians via **Box-Muller** — two uniforms in, two independent Gaussians out:

```odin
gaussian_pair :: proc() -> (f32, f32) {
    u1 := max(rand.float32(), 1e-7)        // ln(0) guard
    u2 := rand.float32()
    r  := math.sqrt(-2.0 * math.ln(u1))
    a  := 2.0 * math.PI * u2
    return r * math.cos(a), r * math.sin(a)
}
```

For the texture data, stay in `[4]f32` rather than any complex type — the array uploads byte-for-byte as `RGBA32F` and mirrors what the GLSL will read. (Chapter 63's CPU FFT will use Odin's builtin `complex64` where clarity wins; here, layout wins.)

## Build

1. **Create `src/ocean_spectrum.odin`** with the state and the spectrum function:

   ```odin
   Ocean_Spectrum :: struct {
       n:          i32,        // 256
       tile_size:  f32,        // 256.0 — same L as ch61
       wind_speed: f32,        // m/s
       wind_dir:   glsl.vec2,  // normalized
       amplitude:  f32,        // Phillips A — start ~3e-7, tune by eye
       h0:         [][4]f32,   // per texel: h̃0(k).xy, conj(h̃0(−k)).zw — KEEP (ch65 needs it)
       tex_h0:     u32,        // rgba32f
   }

   phillips :: proc(s: ^Ocean_Spectrum, k: glsl.vec2) -> f32 {
       klen := glsl.length(k)
       if klen < 1e-6 do return 0.0                    // the k=0 / NaN guard
       l    := s.wind_speed * s.wind_speed / 9.81
       dotw := glsl.dot(k / klen, s.wind_dir)
       p    := s.amplitude * math.exp(-1.0 / (klen*klen*l*l)) / (klen*klen*klen*klen)
       p *= dotw * dotw
       if dotw < 0 do p *= 0.1                         // suppress upwind waves
       p *= math.exp(-klen*klen * 0.01)                // tiny-wave cutoff, ℓ=0.1 m
       return p
   }
   ```

2. **Generate `h̃₀`** — note each texel needs its own pair *and* its mirror's, conjugated:

   ```odin
   spectrum_create :: proc(n: i32, tile: f32, wind: glsl.vec2, speed, amp: f32) -> (s: Ocean_Spectrum) {
       s = {n = n, tile_size = tile, wind_dir = glsl.normalize(wind),
            wind_speed = speed, amplitude = amp}
       s.h0 = make([][4]f32, int(n * n))
       rand.reset(game_world_seed())                   // same seed = same ocean
       gauss := make([][2]f32, int(n * n)); defer delete(gauss)
       for i in 0 ..< len(gauss) { gauss[i][0], gauss[i][1] = gaussian_pair() }

       for m in 0 ..< int(n) do for j in 0 ..< int(n) {
           k  := k_for_texel(j, m, int(n), tile)       // 2π(idx − N/2)/L, see Concepts
           mj := (int(n) - j) % int(n)                 // texel of −k (wraps!)
           mm := (int(n) - m) % int(n)
           g  := gauss[m*int(n)+j]; gm := gauss[mm*int(n)+mj]
           hp := math.sqrt(phillips(&s, k)  / 2.0)
           hm := math.sqrt(phillips(&s, -k) / 2.0)
           s.h0[m*int(n)+j] = {g[0]*hp, g[1]*hp, gm[0]*hm, -gm[1]*hm} // .zw = conjugate
       }
       return
   }
   ```

   The mirror index `(N − j) % N` (not `N − 1 − j`!) is the frequency-grid wraparound — index 0 is its own mirror. Get this wrong and Chapter 63's sea will have a faint imaginary ghost: not dramatic, just *wrong*, and maddening to trace later. Also note `−k` reuses the *mirror texel's* Gaussians — that's what makes `h0[texel of −k].xy` and `h0[texel of k].zw` true conjugates of each other.

3. **Upload as `RGBA32F`** (32F, not 16F — spectra span many orders of magnitude and 16-bit underflows the high frequencies to zero):

   ```odin
   gl.GenTextures(1, &s.tex_h0)
   gl.BindTexture(gl.TEXTURE_2D, s.tex_h0)
   gl.TexStorage2D(gl.TEXTURE_2D, 1, gl.RGBA32F, s.n, s.n)
   gl.TexSubImage2D(gl.TEXTURE_2D, 0, 0, 0, s.n, s.n, gl.RGBA, gl.FLOAT, raw_data(s.h0))
   ```

   Filtering `NEAREST` — frequency space is not for interpolating.

4. **Visualize it.** Reuse your Chapter 30 debug-quad overlay: draw `tex_h0` with a tiny fragment shader showing `length(texel.xy) * u_scale` (start `u_scale ≈ 50`). Bind it to a debug key next to the reflection/refraction views.

5. **Play.** Wire `wind_speed` and `amplitude` to your microui panel with a "regenerate" button that calls `spectrum_create` again. Watch the spectrum reshape — this is the dial you'll hand to Weather in Chapter 64.

## Checkpoint

A noisy starburst on your debug quad: brightest near the center (low frequencies — remember the texture's frequency origin is at texel N/2, so "center" of the quad), elongated **along** the wind direction, dark in the perpendicular band (the `|k̂·ŵ|²` lobes), fading by `1/k⁴` toward the edges.

- Crank `wind_speed` 5 → 25 m/s: the bright region grows toward the center (longer waves admitted — that's `L = V²/g` working).
- Rotate `wind_dir`: the dark cross-wind band rotates with it.
- Same world seed → identical texture every run, bit for bit. Determinism is a feature you'll lean on in Chapter 65.
- Center texel is exactly zero (read it back with `gl.GetTexImage` in a debug assert if you're thorough).

## Pitfalls

- **A NaN sea (next chapter) or a white debug quad now.** `k = 0` wasn't guarded, or `ln(0)` in Box-Muller. One bad texel is enough; the FFT democratizes it to all of them.
- **Spectrum looks like uniform static, no shape.** You're visualizing the raw value (signed, mostly near zero) rather than `length(xy)` scaled up; or amplitude `A` is so high everything clips — drop `u_scale`.
- **Bright cross instead of lobes along the wind.** Wind direction not normalized, or you applied `|k̂·ŵ|²` with `k` instead of `k̂` (unnormalized dot).
- **Different ocean every launch.** You seeded from time somewhere, or another system consumed randoms from the same generator before `spectrum_create` ran. `rand.reset` immediately before generation makes the spectrum self-contained.
- **`.zw` channels identical to `.xy`.** You conjugated the texel's own value instead of the *mirrored texel's* — reread step 2; Hermitian symmetry pairs `k` with `−k`, not with itself.

## Exercises

1. Add the spreading exponent as a parameter: `pow(abs(dotw), u_spread)` with `u_spread` from 2 to 8 on a slider. Watch the lobes tighten — storm seas are directional, calm seas are washy.
2. Plot a 1D slice: log-print `phillips` along the wind axis for k = 0.01..10 and eyeball the `1/k⁴` line and the low-k cliff. Ten minutes, and the formula stops being a spell.
3. Make `amplitude` and `wind_speed` part of `Weather_Params` now (plumbing only — Chapter 64 connects the wires).
4. **Stretch:** implement JONSWAP. Convert from `S(ω)` to `P(k)` using the dispersion relation (`ω = √(gk)`, so `dω/dk = ½√(g/k)` — multiply by that Jacobian), keep the Phillips directional factor, expose `fetch` in km. Compare the two seas at the same wind speed: JONSWAP's defined peak reads as "one swell family plus texture" — many people never go back.

## Commit

`git commit -m "ch62: phillips spectrum h0(k) generation and debug view"`

← [Chapter 61 — The Parallel Sea](ch61-the-parallel-sea.md) · [Chapter 63 — The Fast Fourier Sea](ch63-the-fast-fourier-sea.md) →
