# Chapter 27 — The Procedural Heavens

*Part 5 — The Living Sea & Sky · Estimated time: 3h · learnopengl: no direct equivalent — this is engine/game material*

**What you'll see when done:** a sky computed from nothing — blue zenith fading to a pale horizon, a glowing sun disk you can drag across the heavens with two keys, and the whole world's lighting following it from cold dawn to orange dusk.

## Where we are

The photo skybox from Chapter 26 looks great and is utterly dead: its sun is painted at a fixed spot that has nothing to do with your Phong `sun_dir`, and it can never be 7 a.m. This chapter throws away the six JPEGs (keep the loader — Chapter 43 wants it) and computes the sky in the fragment shader instead. The payoff is a single source of truth: one `Sky` struct owns the sun, and the sky shader, the Phong lighting, and (from Chapter 29) the water reflections all read from it.

## Concepts

### Same box, new paint

Nothing changes about the *geometry*: you still draw the Chapter 26 cube with the rotation-only view matrix and the `xyww` depth trick. Only the fragment shader changes. The interpolated direction `v_dir` is all a sky model needs — a sky is, by definition, a function `color(direction)`.

### A two-stop gradient that lies well

Real skies get their color from Rayleigh scattering: short (blue) wavelengths scatter out of the sun's path and reach you from every direction; near the horizon, light traverses more air, scatters more, and washes toward white; at sunset the long path strips the blues entirely and leaves orange. Full physical models exist — [Preetham](https://courses.cs.duke.edu/cps124/spring08/assign/07_papers/p91-preetham.pdf) and the newer [Hosek-Wilkie](https://cgg.mff.cuni.cz/projects/SkylightModelling/) are the classics, worth a read later — but you can fake 90% of the look with an artist-friendly recipe:

- **Vertical gradient:** mix a horizon color into a zenith color by `dir.y`. Bias it (`pow` or `smoothstep`) so the horizon band stays wide, like real atmosphere.
- **Sun-driven palettes:** pick *two* palettes (day and dusk) and blend between them using the sun's elevation `sun_dir.y`. Below the horizon, fade everything toward a dark night blue.
- **Warm glow around the sun:** add an orange tint scaled by `pow(max(dot(dir, sun_dir), 0), k)` — strongest at low sun. This sells "sunset" more than anything else.

```
 zenith (deep blue)          sun elevation drives WHICH
   |                          palette you're blending:
   |  gradient by dir.y
   |                            day:   zenith #3469BF  horizon #A6C6E3
   ~~~~ horizon (pale) ~~~~     dusk:  zenith #2A3558  horizon #E8804A
   |                            night: zenith #060A14  horizon #0C1426
   v  below horizon: darken
```

### The sun disk

The sun subtends about 0.53° — `cos(0.265°) ≈ 0.99999`. Comparing `dot(dir, sun_dir)` against cosines that close to 1 is finicky, so use a `smoothstep` between two thresholds for an antialiased disk, plus a wider soft `pow` halo:

```glsl
float d    = dot(dir, sun_dir);
float disk = smoothstep(0.9995, 0.9999, d);
float halo = pow(max(d, 0.0), 600.0) * 0.5;
```

### One clock to rule them all

The `Sky` struct owns `time_of_day` in hours (0–24). From it, derive the sun direction: at 6:00 the sun rises, peaks at 12:00, sets at 18:00. Sweep an angle through that arc and tilt it off vertical so noon shadows aren't dead overhead:

```
elevation = sin(a),  a = (time - 6) / 12 * π     6h → 0, 12h → π/2, 18h → π
```

Crucially, **the sun's color and intensity feed the existing Phong sun** from Chapter 14. Decide the sign convention once and write it down: `sky.sun_dir` points *toward* the sun (what the sky shader wants); the Phong uniform `sun_dir` is the direction light *travels*, so it gets `-sky.sun_dir`.

## Build

1. **Create `src/sky.odin`** with the struct and the clock:

   ```odin
   Sky :: struct {
       time_of_day:   f32,        // hours, 0..24
       sun_dir:       glsl.vec3,  // toward the sun, normalized
       sun_color:     glsl.vec3,
       sun_intensity: f32,        // 0 at night, 1 at noon
       shader:        Shader,
       cube:          Mesh,       // same unit cube as ch26
   }

   sky_sun_direction :: proc(time_of_day: f32) -> glsl.vec3 {
       a := (time_of_day - 6.0) / 12.0 * math.PI
       return glsl.normalize(glsl.vec3{math.cos(a), math.sin(a), 0.35})
   }
   ```

   The constant `0.35` z-component tilts the arc; tune to taste.

2. **Write `sky_update`** (call it each frame, before rendering). Advance the clock, derive direction, then derive color and intensity from elevation with simple ramps:

   ```odin
   sky_update :: proc(sky: ^Sky, dt: f32) {
       sky.time_of_day = math.mod(sky.time_of_day + dt*TIME_SCALE, 24.0)
       sky.sun_dir = sky_sun_direction(sky.time_of_day)

       elev := sky.sun_dir.y                       // -1 .. 1
       sky.sun_intensity = clamp((elev + 0.05) / 0.25, 0.0, 1.0)
       noon   := glsl.vec3{1.00, 0.98, 0.92}
       sunset := glsl.vec3{1.00, 0.45, 0.20}
       warm   := clamp(1.0 - elev*3.0, 0.0, 1.0)   // 1 near horizon
       sky.sun_color = glsl.lerp(noon, sunset, glsl.vec3{warm, warm, warm})
   }
   ```

   One Odin gotcha worth knowing here: unlike GLSL's `mix(vec3, vec3, float)`, the vector overloads of `glsl.lerp`/`glsl.mix` take a *vector* `t` — hence the spelled-out `vec3{warm, warm, warm}`. Scalar `clamp`/`min`/`max`/`abs` are Odin built-ins, no import needed.

   `TIME_SCALE` of about `0.2` gives a 2-minute day; also bind two keys (say `[` and `]`) that add/subtract `4.0 * dt` hours so you can scrub.

3. **Feed Phong.** Where Chapter 14 set hardcoded sun uniforms, now write:

   ```odin
   shader_set_vec3(lit_shader, "sun_dir",   -game.sky.sun_dir)
   shader_set_vec3(lit_shader, "sun_color", game.sky.sun_color * game.sky.sun_intensity)
   ```

   Consider also scaling your ambient term by `0.3 + 0.7*sun_intensity` so nights actually get dark.

4. **Write `assets/shaders/sky.frag`.** Structure the color logic as a *function* — Chapter 29 will lift it verbatim into the water shader:

   ```glsl
   #version 330 core
   in vec3 v_dir;
   out vec4 frag_color;
   uniform vec3 u_sun_dir;

   vec3 sky_color(vec3 dir, vec3 sun_dir) {
       float elev = sun_dir.y;
       float day  = smoothstep(-0.10, 0.25, elev);
       float dusk = smoothstep(0.35, 0.05, abs(elev));   // peaks at horizon

       vec3 zenith  = mix(vec3(0.024, 0.039, 0.078), vec3(0.20, 0.41, 0.75), day);
       vec3 horizon = mix(vec3(0.047, 0.078, 0.149), vec3(0.65, 0.78, 0.89), day);
       horizon = mix(horizon, vec3(0.91, 0.50, 0.29), dusk);   // sunset band

       float t = pow(1.0 - clamp(dir.y, 0.0, 1.0), 2.5);       // wide horizon band
       vec3 col = mix(zenith, horizon, t);

       float d = dot(dir, sun_dir);
       col += vec3(1.0, 0.55, 0.25) * dusk * pow(max(d, 0.0), 4.0) * 0.35; // warm side
       col += vec3(1.0, 0.95, 0.85) * smoothstep(0.9995, 0.9999, d) * day; // disk
       col += vec3(1.0, 0.80, 0.55) * pow(max(d, 0.0), 600.0) * 0.5;       // halo
       return col;
   }

   void main() {
       frag_color = vec4(sky_color(normalize(v_dir), u_sun_dir), 1.0);
   }
   ```

   The vertex shader is Chapter 26's unchanged. Below the horizon (`dir.y < 0`) the `clamp` holds the horizon color — the sea covers it anyway.

5. **Swap the render path.** `sky_draw` is `skybox_draw` minus the cubemap bind, plus `shader_set_vec3(sky.shader, "u_sun_dir", sky.sun_dir)`. Delete the `Skybox` value from `Game` (keep `cubemap_load` in the codebase).

6. **Sanity-tune.** Scrub time with your keys and watch dawn → noon → dusk → night. Adjust the palette constants until your 18:30 looks like a postcard. These numbers are *content*, not code — there are no wrong answers.

## Checkpoint

A living sky: blue gradient at noon, a blinding little disk with a halo, an orange wall in the west at 18:00, near-black at midnight — and your islands' lighting tracking all of it, because Phong now drinks from the same struct.

- Scrub from 12:00 to 18:30: the sky band turns orange *and* the terrain's lit side warms simultaneously.
- The sun disk sits exactly where the terrain shadows say it should (specular glints point at it).
- At 00:00 the world is dim but not pure black (your scaled ambient).
- Frame time unchanged — this shader runs only on background pixels.

## Pitfalls

- **Sun disk is a huge blob or invisible.** The `smoothstep` thresholds are extremely sensitive near 1.0; print `dot(dir, sun_dir)` as a color to debug, and make sure *both* vectors are normalized — an unnormalized `v_dir` ruins the dot product.
- **Lighting and sky disagree about where the sun is.** Sign bug: you fed `sky.sun_dir` (toward sun) into a uniform expecting light-travel direction, or vice versa. Grep every use; the convention from this chapter's Concepts is law from now on.
- **The sky "pops" at dawn/dusk.** Your ramps have hard edges — every transition should be a `smoothstep`/`clamp` over a range of elevations, never an `if`.
- **Banding in the gradient.** 8-bit framebuffer banding is real, especially at dusk. Live with it until Chapter 40 (HDR) — or add a tiny dither: `col += (fract(sin(dot(gl_FragCoord.xy, vec2(12.9898, 78.233))) * 43758.5453) - 0.5) / 255.0`.
- **Night is orange.** Your dusk factor uses `elev` instead of `abs(elev)` — it must peak at the horizon and fade *both* above and below.

## Exercises

1. Add a `u_time_of_day` uniform and tint the halo color from yellow (noon) to deep red (horizon) for extra drama.
2. Make `TIME_SCALE` adjustable at runtime (comma/period keys) and add a pause-time key. You'll use this constantly while tuning the ocean.
3. Move your point-light lanterns (Chapter 15) to only switch on when `sun_intensity < 0.2`. Sailing past a lit buoy at midnight is your first "wow" moment of Part 5.
4. **Stretch:** stars. In `sky_color`, when `day < 0.5`, hash the direction into a pseudo-random sparkle: quantize `dir` into cells (`floor(dir * 60.0)`), hash the cell to a brightness, and keep only the top ~2% as white points scaled by `(1.0 - day)`. Bonus: rotate the direction by time so the stars wheel overnight.

## Commit

`git commit -m "ch27: procedural sky with sun disk and day/night clock"`

← [Chapter 26 — A Box of Sky](ch26-a-box-of-sky.md) · [Chapter 28 — Waves that Roll](ch28-waves-that-roll.md) →
