# Chapter 64 — Whitecaps

*Part 10 — The True Ocean · Estimated time: 3h · learnopengl: no direct equivalent — canonical reference: Tessendorf, ["Simulating Ocean Water"](https://people.computing.clemson.edu/~jtessen/reports/papers_files/coursenotes2004.pdf), §4.4 (choppy waves and the Jacobian)*

**What you'll see when done:** breaking crests that *catch foam* — white streaks born exactly where waves pinch and fold, lingering and fading as the wave moves on — and a Weather dial that turns the same ocean from glassy calm to whitecapped storm by changing the physics, not the paint.

## Where we are

Your FFT sea pinches its crests with choppy displacement, and sometimes — crank `u_choppy` and watch — the surface actually folds through itself at the steepest peaks. In reality that's where a wave *breaks*: the surface can't fold, so it shatters into foam. Conveniently, the same math that produces the fold can detect it. Today: detect, accumulate, render. Then we hand the whole sea state to the Weather machine, and Calm→Storm stops being a fog-and-parameters trick and becomes oceanography.

## Concepts

### The Jacobian: measuring the pinch

The choppy displacement moves surface point `(x, z)` horizontally by `λ·(Dx, Dz)`. Think of it as a *mapping* of the flat plane onto itself. The *Jacobian determinant* of that mapping measures local area change:

```
        ⎡ Jxx  Jxz ⎤        Jxx = 1 + λ·∂Dx/∂x      Jzz = 1 + λ·∂Dz/∂z
J = det ⎢          ⎥
        ⎣ Jzx  Jzz ⎦        Jxz = λ·∂Dx/∂z          Jzx = λ·∂Dz/∂x

J = Jxx·Jzz − Jxz·Jzx
```

- `J = 1`: no distortion (flat calm).
- `J < 1`: the surface is being *compressed* — texels crowd together. This is exactly the bunching-toward-crests you saw in Chapter 28's wireframe.
- `J ≤ 0`: the mapping folds over itself — geometric self-intersection, physical wave breaking.

So the foam rule is one comparison: **inject foam where `J < J_threshold`**, with the threshold somewhere around 0.5–0.9. Higher threshold → foam appears on merely-steep crests (stormy look); lower → only on true breakers. Tessendorf derives this in §4.4 of the notes; the derivatives we need are central differences of the `Dx`, `Dz` maps we already compute — four extra `imageLoad`s in the assembly pass.

A wonderful detail: `J` going negative is precisely when the *geometry* would self-intersect — so foam doesn't just decorate the artifact, it *hides* it. The whitecap covers the fold. This is why FFT oceans can run choppiness values that would be geometric disasters on a bare Gerstner.

### Foam has memory

A breaking crest passes in a second, but its foam patch lingers for many. So foam can't be a per-frame function of `J` — it needs **state**: an accumulation texture that gets injected where the sea breaks now and decays everywhere always:

```
foam(t+dt) = max( injection(J),  foam(t) · e^{−dt/τ} )
```

`τ` ≈ 3–6 s is the foam lifetime. Exponential decay reads as natural dissipation, and `max` (rather than `+=`) keeps repeated breaking from blowing past 1.0. This is a second tiny compute pass — and your second *stateful* texture after Chapter 50's ripples: the texture IS the simulation, frame feeding frame.

### Foam is a material, not a color

In the water shader, foam is where the surface stops behaving like water: real foam is air bubbles — diffuse, white, rough. So the foam mask doesn't tint; it *replaces* the shading regime:

- albedo → toward white (foam scatters sunlight diffusely),
- roughness → toward 1 (kills the specular glint),
- reflections (your ch58 SSR ⊕ planar ⊕ IBL chain) → faded out,
- Fresnel → irrelevant (it's not a dielectric surface anymore).

Half-measures here (just whitening color) produce "milk spills" — shiny white patches that still mirror the sky. Kill the reflection and it reads as foam instantly.

### Sea state belongs to Weather

Chapter 47's `Weather` lerps parameter blocks. The spectrum, though, was generated once on the CPU at startup — wind changes can't reach it. The fix is the standard production trick: split randomness from physics. The Gaussian noise (the dice rolls) is fixed per world seed and lives in a texture; the *Phillips shaping* moves to a small compute pass that rebuilds `h̃₀(k)` from the noise whenever wind changes — even every frame during a weather transition, at 256² it's nearly free. Same dice + new wind = the same sea, statistically reshaped, with no popping.

## Build

1. **Compute `J` in the assembly pass.** You already load neighbor texels for normals; add the choppy derivatives (remember each neighbor's own perm sign, same as `height_at`):

   ```glsl
   float dxx = (Dx(id + ivec2(1,0)) - Dx(id - ivec2(1,0))) / (2.0 * dx);
   float dzz = (Dz(id + ivec2(0,1)) - Dz(id - ivec2(0,1))) / (2.0 * dx);
   float dxz = (Dx(id + ivec2(0,1)) - Dx(id - ivec2(0,1))) / (2.0 * dx);
   float dzx = (Dz(id + ivec2(1,0)) - Dz(id - ivec2(1,0))) / (2.0 * dx);
   float J = (1.0 + u_choppy*dxx) * (1.0 + u_choppy*dzz)
           - (u_choppy*dxz) * (u_choppy*dzx);
   imageStore(u_displacement, id, vec4(disp, J));   // the .w slot ch61 reserved
   ```

   Debug-view `1.0 - J` on your overlay quad first: glowing filaments tracing every crest line. Verify before building on it.

2. **Add the foam accumulation texture** — single `r16f`, 256², `REPEAT`/`LINEAR`, plus `assets/shaders/ocean_foam.comp`. One texel per invocation reads and writes only itself, so one texture suffices (no ping-pong, no race):

   ```glsl
   layout(r16f,    binding = 0) uniform image2D u_foam;
   layout(rgba16f, binding = 1) uniform readonly image2D u_displacement;
   uniform float u_dt, u_foam_threshold, u_foam_decay;   // decay = e^{−dt/τ}, CPU-computed

   void main() {
       ivec2 id = ivec2(gl_GlobalInvocationID.xy);
       float J    = imageLoad(u_displacement, id).w;
       float inj  = clamp((u_foam_threshold - J) / u_foam_threshold, 0.0, 1.0);
       float foam = max(inj, imageLoad(u_foam, id).r * u_foam_decay);
       imageStore(u_foam, id, vec4(foam, 0, 0, 0));
   }
   ```

   Dispatch after assembly (it reads the displacement image: `SHADER_IMAGE_ACCESS_BARRIER_BIT` between them), then the usual `TEXTURE_FETCH` barrier before drawing. Note `u_foam` has no `readonly`/`writeonly` — it's both.

3. **Shade it.** In the water fragment shader, sample foam at the ocean UV and break up its texture with your Chapter 34 wake-foam texture (it tiles, it's white, it's free):

   ```glsl
   float foam = texture(u_foam, uv).r;
   foam *= texture(u_foam_pattern, world.xz * 0.15).r * 1.4;   // texture the mask
   albedo     = mix(albedo, vec3(0.9), foam);
   roughness  = mix(roughness, 1.0, foam);
   reflection_strength *= (1.0 - foam);                        // foam kills mirrors
   fresnel    = mix(fresnel, 0.02, foam);
   ```

   (Adapt names to your shader; the *structure* — albedo up, roughness up, reflection down — is the point.)

4. **Move `h̃₀` generation to the GPU.** Refactor Chapter 62: `spectrum_create` now generates and keeps only the **noise** (two Gaussians per texel, `rg32f` texture + the Odin array — Chapter 65 needs the array). New `assets/shaders/ocean_spectrum.comp` ports your `phillips` proc to GLSL and writes the `h̃₀(k)/conj h̃₀(−k)` texture, reading the noise texture at `id` and at the mirrored texel. Run it once at startup and whenever wind parameters change. Your Chapter 62 debug quad should look *identical* — same dice, same formula, new venue.

5. **Wire Weather.** Extend `Weather_Params` (the presets are an enumerated array — the compiler now walks you through every preset, ch47's design paying off):

   ```odin
   Weather_Params :: struct {
       // ... ch47 fields ...
       wind_speed:     f32, // m/s — drives the Phillips spectrum
       wave_amplitude: f32, // Phillips A scale
       choppiness:     f32, // λ
       foam_threshold: f32, // J cutoff
   }
   // Clear: {wind_speed = 4,  wave_amplitude = 0.4, choppiness = 0.7, foam_threshold = 0.2}
   // Storm: {wind_speed = 22, wave_amplitude = 1.0, choppiness = 1.6, foam_threshold = 0.85}
   ```

   Each frame, if the lerped params moved, re-dispatch `ocean_spectrum.comp` with the new wind. Amplitude and choppiness feed evolve/assemble directly. (Foam threshold rising with wind is doing real work: storm seas whitecap at lower steepness because real wind tears crests early.)

6. **Test the dial.** Your Chapter 47 weather keys now morph the *sea itself*: Calm — long, low, glassy, no foam; Storm — short steep seas, whitecaps everywhere, spume streaks. Watch the transition: because only the spectrum *shape* changes while the dice stay fixed, waves grow and sharpen in place rather than popping.

## Checkpoint

In a Storm preset: crests sharpen, fold — and flash white exactly at the fold, the foam trailing behind each breaking crest and dissolving over a few seconds.

- Debug-view `1 - J`: filaments live on crest lines, never in troughs.
- Freeze time: foam keeps decaying (it's stateful) while no new injection appears.
- Calm preset shows essentially zero foam; Storm whitecaps continuously. The *same* keypress from Chapter 47 now changes physics, not just fog color.
- Foam patches don't mirror the sky (reflection kill working) — check over a low sun where reflections are strongest.

## Pitfalls

- **Foam everywhere / nowhere.** `J` threshold fighting your choppiness: `λ` too low and `J` never dips below 0.9. Tune with the debug view, not the final render — and remember both are now Weather-driven; check the preset you're actually in.
- **Foam strobes or flickers.** You wrote `injection + decay*old` with injection recomputed per frame from a moving `J` — use `max`, which is temporally stable; or your dt is render-dt while sim runs fixed-step (use the sim dt you pass everywhere else).
- **Checkerboard foam.** The Jacobian derivatives skipped the neighbors' perm signs. Same bug as Chapter 63's normals, same fix.
- **Sea pops when weather changes.** You regenerated the *noise* with the spectrum (new dice = new ocean). Noise is generated once per world seed, ever; only the Phillips shaping re-runs.
- **Foam looks like flat white paint.** You skipped the pattern texture in step 3, or forgot to kill reflections — see "foam is a material."

## Exercises

1. Advect the foam: in `ocean_foam.comp`, read `foam` not at `id` but offset by a fraction of the local choppy displacement. Foam now slides along the moving surface instead of being painted on the world. Subtle; sells it.
2. Add foam to *geometry*: in the vertex shader, damp displacement slightly where foam is strong (`disp *= 1.0 - 0.2*foam`). Breaking crests visually collapse as they whiten.
3. Drive your Chapter 46 spray particles from the same signal: spawn spray where `J < 0` (true folding) with the wind as initial velocity. Storm crests now *throw* spume.
4. **Stretch:** sea-state hysteresis. Real foam coverage lags the wind by minutes. Give `Weather` a slow-follow value (`coverage += (target - coverage) * dt/60`) that scales foam threshold, so a dying storm leaves a foam-streaked sea that calms over two minutes. Free atmosphere.

## Commit

`git commit -m "ch64: jacobian whitecaps, foam accumulation, weather-driven sea state"`

← [Chapter 63 — The Fast Fourier Sea](ch63-the-fast-fourier-sea.md) · [Chapter 65 — Floating on Data](ch65-floating-on-data.md) →
