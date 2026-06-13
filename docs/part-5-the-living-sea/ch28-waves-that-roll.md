# Chapter 28 — Waves that Roll

*Part 5 — The Living Sea & Sky · Estimated time: 3h · learnopengl: no direct equivalent — the canonical source is [GPU Gems ch. 1, "Effective Water Simulation from Physical Models"](https://developer.nvidia.com/gpugems/gpugems/part-i-natural-effects/chapter-1-effective-water-simulation-physical-models)*

**What you'll see when done:** the flat blue plane finally *moves* — long swells with sharp crests and wide troughs rolling diagonally across the archipelago, exactly the motion your eye knows from the real sea.

## Where we are

Your sea has been a static plane since Chapter 12 (the buoys bob on a cheap sine, but the surface itself is frozen). Today the sea grid's vertices start moving in the vertex shader. And because Chapter 32 will float the boat on these same waves *on the CPU*, this chapter establishes a discipline you'll keep for the rest of the course: **the wave math lives in exactly one Odin table, and the CPU and GPU evaluate it identically.**

## Concepts

### Sum of sines, and why it looks like rubber

The obvious wave is a traveling sine: `y = A * sin(k·(D·p) − ωt)` for amplitude `A`, direction `D`, and a few constants we'll define properly below. Add four of these with different directions and sizes and you get a heaving surface — but a strangely *wrong* one. Real wind waves are not sinusoidal: they have **wide, flat troughs and narrow, peaked crests**. A sum of sines is vertically symmetric — equal time above and below the waterline — so it reads as a rubber sheet with something rolling underneath, not water.

The reason is physical: water in a passing wave doesn't bob straight up and down. Each parcel of water moves in a roughly **circular orbit** — forward at the crest, backward in the trough. The surface shape this traces is a trochoid, not a sine.

```
 sum of sines:   ~~~∩~~~∩~~~        gerstner:    __/\____/\__
 (symmetric,     rounded crests     (crests pinched sharp,
  rubbery)                           troughs stretched flat)

 water parcels:  o → at crest
                 ↑       ↓     each parcel orbits a circle;
                 o ← in trough  the surface is what the circles trace
```

### Gerstner waves: displace horizontally too

The Gerstner (trochoidal) wave, dated 1802 and popularized for GPUs by GPU Gems, adds the missing ingredient: **horizontal displacement toward the crests**. A grid point at rest position `(x, z)` ends up at:

```
P.x = x + Σᵢ Qᵢ Aᵢ Dᵢ.x cos(θᵢ)
P.y =     Σᵢ    Aᵢ      sin(θᵢ)          θᵢ = kᵢ (Dᵢ · (x,z)) − kᵢ Sᵢ t + offset
P.z = z + Σᵢ Qᵢ Aᵢ Dᵢ.y cos(θᵢ)
```

Term by term, per wave `i`:

- **Wavelength λ → frequency k.** `k = 2π / λ` is the spatial frequency (radians per meter). Long swells: λ = 40–80 m. Chop: λ = 3–10 m.
- **Amplitude A.** Crest-to-midline height in meters. Keep `A ≤ λ/20` or so; real waves break beyond steepness limits.
- **Speed S → phase.** A wave moving at `S` m/s shifts its phase by `k·S` per second, hence the `− k S t` term. (Deep-water physics says `S = √(g/k)` — longer waves travel faster. Use it as a default, then cheat freely for art.)
- **Direction D.** Unit `vec2` on the sea plane. Spread your waves within ±30–60° of the wind direction — perfectly aligned waves look like corduroy.
- **Steepness Q.** The star of the show. `Q = 0` is a pure sine; larger `Q` pulls points horizontally toward the nearest crest, pinching crests sharp and flattening troughs.

### The steepness budget: why Σ QᵢAᵢkᵢ ≤ 1

Horizontal pinching has a failure mode. The horizontal displacement of wave `i` has slope `Qᵢ Aᵢ kᵢ` at the crest; if the *total* `Σ Qᵢ Aᵢ kᵢ` exceeds 1, neighboring grid points cross past each other and the surface folds through itself — visible as weird inverted loops at every crest. GPU Gems' tidy solution: let the artist set one global steepness `Q_global ∈ [0,1]` and derive each wave's `Qᵢ = Q_global / (kᵢ Aᵢ N)` for `N` waves. The sum then can't exceed `Q_global ≤ 1`, ever. We'll do exactly that.

### One table, two evaluators

The vertex shader runs this math per vertex per frame. Chapter 32 needs `ocean_height_at(pos, time)` on the CPU to float the boat — *the same math*. If the two ever disagree (you tweak a constant in the shader and forget the Odin side), the boat floats above or below the visible water and the illusion dies instantly. The discipline:

- Wave parameters are defined **once**, in an Odin array in `src/ocean.odin`.
- The shader receives them as uniforms — never hardcode a wave constant in GLSL.
- The CPU evaluator is written to mirror the GLSL loop line-for-line, and both carry a comment pointing at the other: `// MIRRORS assets/shaders/water.vert — change both!`

## Build

1. **Define the data** in a new `src/ocean.odin`:

   ```odin
   Wave :: struct {
       direction:  glsl.vec2, // normalized, on the xz plane
       amplitude:  f32,       // meters
       wavelength: f32,       // meters
       speed:      f32,       // m/s
   }

   Ocean :: struct {
       waves:     [4]Wave,
       steepness: f32,    // global Q, 0..1
       shader:    Shader,
       mesh:      Mesh,   // your camera-following sea grid
   }

   ocean_default_waves :: proc() -> [4]Wave {
       return {
           {glsl.normalize(glsl.vec2{ 1.0,  0.3}), 0.60, 55.0, 9.0},
           {glsl.normalize(glsl.vec2{ 0.8, -0.4}), 0.30, 27.0, 6.5},
           {glsl.normalize(glsl.vec2{ 0.2,  0.9}), 0.15, 11.0, 4.0},
           {glsl.normalize(glsl.vec2{-0.4,  0.8}), 0.08,  5.0, 2.5},
       }
   }
   ```

   One big swell, two mid waves, one ripple — a classic spectrum. Start with `steepness = 0.6`.

2. **Upload once at startup** (the table is static for now). GLSL struct-array uniforms are addressed by name per field:

   ```odin
   ocean_upload_waves :: proc(o: ^Ocean) {
       gl.UseProgram(o.shader.id)
       for w, i in o.waves {
           base := fmt.tprintf("u_waves[%d].", i)
           shader_set_vec2(o.shader, fmt.tprintf("%sdirection",  base), w.direction)
           shader_set_f32(o.shader,  fmt.tprintf("%samplitude",  base), w.amplitude)
           shader_set_f32(o.shader,  fmt.tprintf("%swavelength", base), w.wavelength)
           shader_set_f32(o.shader,  fmt.tprintf("%sspeed",      base), w.speed)
       }
       shader_set_f32(o.shader, "u_steepness", o.steepness)
   }
   ```

3. **Rewrite `assets/shaders/water.vert`** (your sea shader from Chapter 24, whatever you named it). The displacement loop:

   ```glsl
   #version 330 core
   layout (location = 0) in vec3 a_pos;
   // ... your existing outs ...

   struct Wave { vec2 direction; float amplitude; float wavelength; float speed; };
   uniform Wave  u_waves[4];
   uniform float u_steepness;
   uniform float u_time;
   uniform mat4  model, view, projection;

   vec3 gerstner_offset(vec2 p, float t) {
       vec3 off = vec3(0.0);
       for (int i = 0; i < 4; i++) {
           float k     = 6.28318530 / u_waves[i].wavelength;
           float theta = k * dot(u_waves[i].direction, p) - k * u_waves[i].speed * t;
           float q     = u_steepness / (k * u_waves[i].amplitude * 4.0); // 4 = wave count
           off.x += q * u_waves[i].amplitude * u_waves[i].direction.x * cos(theta);
           off.y +=     u_waves[i].amplitude *                          sin(theta);
           off.z += q * u_waves[i].amplitude * u_waves[i].direction.y * cos(theta);
       }
       return off;
   }

   void main() {
       vec3 world = (model * vec4(a_pos, 1.0)).xyz;
       world += gerstner_offset(world.xz, u_time);   // MIRRORS src/ocean.odin — change both!
       // ... pass world pos to frag, gl_Position = projection * view * vec4(world, 1.0);
   }
   ```

   Displace using the **world-space** xz (not object-space) so the wave field is fixed in the world while the grid slides under the camera.

4. **Write the CPU mirror** in `src/ocean.odin`. First the literal twin of the GLSL:

   ```odin
   // MIRRORS assets/shaders/water.vert gerstner_offset — change both!
   ocean_displace :: proc(o: Ocean, p: glsl.vec2, t: f32) -> glsl.vec3 {
       off: glsl.vec3
       for w in o.waves {
           k     := 2.0 * math.PI / w.wavelength
           theta := k * glsl.dot(w.direction, p) - k * w.speed * t
           q     := o.steepness / (k * w.amplitude * f32(len(o.waves)))
           off.x += q * w.amplitude * w.direction.x * math.cos(theta)
           off.y += w.amplitude * math.sin(theta)
           off.z += q * w.amplitude * w.direction.y * math.cos(theta)
       }
       return off
   }
   ```

   Then the height query. Subtlety: Gerstner displaces *horizontally*, so the water above point `p` originated at some other rest point `s` where `s + offset(s).xz = p`. Invert with two or three fixed-point iterations — plenty at sane steepness:

   ```odin
   ocean_height_at :: proc(o: Ocean, p: glsl.vec2, t: f32) -> f32 {
       s := p
       for _ in 0 ..< 3 {
           d := ocean_displace(o, s, t)
           s = p - glsl.vec2{d.x, d.z}
       }
       return ocean_displace(o, s, t).y
   }
   ```

5. **Feed time.** Use your fixed-timestep simulation clock (accumulated `f32` seconds since Chapter 10), uploaded each frame as `u_time`, and pass the *same* value to any CPU query. Two clocks = two oceans.

6. **Densify the grid.** A 55 m swell across a grid with 4 m spacing is fine; the 5 m chop wave needs ~1 m spacing to not shimmer. Bump your camera-following sea tile to roughly 256×256 vertices over ~300 m, and make the follow logic **snap to whole grid cells** (`math.floor(cam.x / spacing) * spacing`) — if the grid slides continuously, vertices sample the wave field at ever-shifting points and the sea "swims".

7. **Verify the mirror.** Temporary debug: each frame, place a small test cube at `{x, ocean_height_at(ocean, {x, z}, t), z}` for a few positions. The cubes must ride the visible surface exactly — perfect lockstep is the whole point. Keep this debug behind a key; Chapter 32 thanks you.

## Checkpoint

Rolling swells crossing the sea diagonally, crests noticeably sharper than troughs, small chop riding on top of the big wave. Your debug cubes surf the surface without ever sinking or hovering.

- Set `steepness = 0.0` and back to `0.8` — watch crests go from round sine-hills to pinched ridges.
- Toggle wireframe (`gl.PolygonMode(gl.FRONT_AND_BACK, gl.LINE)`) and look along the surface: grid points visibly bunch *toward* crests. That's the horizontal displacement.
- Waves pass *through* islands for now (they ignore terrain) — noted, accepted, ignored until the Chapter 31 tuning notes.
- The debug cubes stay glued to the surface even at high steepness.

## Pitfalls

- **Loops / inverted geometry at every crest.** Steepness budget blown: with the `q = Q/(kAN)` formula this can't happen for `Q ≤ 1` — so you've hardcoded a `q` somewhere or your wave count divisor doesn't match the actual number of waves.
- **Boat-debug cubes float offset from the surface.** CPU/GPU drift: different time value, a tweaked constant in only one place, or you forgot the fixed-point inversion and queried `offset(p).y` directly (visible error at high steepness).
- **Sea vertices shimmer or crawl when the camera moves.** The follow-tile isn't snapping to grid spacing (step 6).
- **Everything looks fine for ten minutes, then turns to jelly.** `f32` time precision: after hours, `k*S*t` is a huge number and `sin` precision collapses. Wrap your sim clock (e.g., modulo a large common multiple like 3600) before upload.
- **The lighting is garbage — black facets, weird shading.** Expected! Your fragment shader still uses the flat plane's up-normal (or none). Chapter 29 derives real normals; resist fixing it tonight.

## Exercises

1. Add `+`/`-` keys that scale global `steepness` at runtime (re-upload the uniform). Find the value where crests *just* start to look pinched — that's usually your keeper.
2. Replace each wave's hand-picked `speed` with the deep-water relation `S = √(9.8/k)` and compare. Notice the big swell speeds up and the chop slows down — physics has opinions.
3. Make wave 4's direction slowly rotate over minutes (re-upload per frame). Subtle, but the sea stops feeling like a looping GIF.
4. **Stretch:** read GPU Gems' treatment of directional vs. circular waves, then add a fifth wave whose direction points *radially away from* the nearest island center — surf lines that wrap the shore.

## Commit

`git commit -m "ch28: gerstner waves with CPU/GPU mirrored evaluation"`

← [Chapter 27 — The Procedural Heavens](ch27-the-procedural-heavens.md) · [Chapter 29 — The Color of Water](ch29-the-color-of-water.md) →
