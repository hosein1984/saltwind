# Chapter 67 — The Boat Writes on Water

*Part 10 — The True Ocean · Estimated time: 5h · learnopengl: no direct equivalent — background: Matthias Müller-Fischer's height-field water talks; ch50 Taster C was the trailer*

**What you'll see when done:** the hull pushes real rings into the sea — bow waves radiating ahead, a churned patch astern, rain-on-water in storms if you take the exercise — all riding *on top of* the FFT swell, and a cannonball splash toy you will play with for longer than you'll admit.

## Where we are

The FFT ocean is magnificent and completely indifferent to you. Sail through it and it does not care — the surface is a global simulation with no inputs. The Chapter 34 wake (scrolling foam textures) paints *evidence* of the boat, but the water never actually *responds*. Today it does: a local wave-equation simulation in compute, fed by hull impulses from the buoyancy system, composited into the ocean shader. Chapter 50's Taster C sketched this; now we build it for keeps — windowed, reprojected, stable, and budgeted.

## Concepts

### The 2D wave equation, discretized

Small ripples on water obey the wave equation — acceleration of height proportional to curvature:

```
∂²h/∂t² = c²·∇²h
```

On a grid, the Laplacian `∇²h` is the classic five-point stencil, and integrating with finite differences in time gives the **two-buffer scheme** (heights now and heights one step ago encode both position and velocity):

```
            h[x, z−1]
               │                ∇²h ≈ (N + S + E + W − 4·h) / Δx²
h[x−1,z] ── h[x,z] ── h[x+1,z]
               │                h_next = 2h − h_prev + (c·Δt/Δx)²·(N+S+E+W − 4h)
            h[x, z+1]           h_next *= damping        (≈ 0.996)
```

No velocity buffer needed: `2h − h_prev` *is* the velocity term. Three height textures (prev/curr/next) rotate each step. Look back at Chapter 50's `(sum * 0.5 − prev)` — that was this equation with `(c·Δt/Δx)² = 0.5` hardcoded; now you know what the constant meant.

**Stability (CFL condition):** information must not cross more than one cell per step: `c·Δt/Δx ≤ 1/√2` for the 2D stencil. Violate it and the sim doesn't drift wrong — it *detonates* exponentially within a second. With a 512² grid over a 60 m window, `Δx ≈ 0.117 m`; at `Δt = 1/60 s` that caps `c` at ~5 m/s. We'll use `c ≈ 2.5` — ripple-speed, comfortably stable. (Fixed timestep matters here: this is why your sim runs on the Chapter 10 clock, not render dt.)

### A window that follows the boat

A grid covering the whole sea is absurd; ripples only matter near the player. So the 512² grid maps to a 60 m square **window centered on the boat**, and the window moves. But here's the subtlety: the grid must move in *whole cells*, and when it does, the data must **reproject** — shift the textures by the same integer offset so existing ripples stay fixed in the *world* while the window slides under them:

```
   window at t            window at t+1 (boat moved →)
  ┌───────────┐             ┌───────────┐
  │   ○ ring  │      →      │ ○ ring    │   same ring, same WORLD position,
  │      ⛵   │             │      ⛵   │   new texel address (shifted left)
  └───────────┘             └───────────┘   fresh texels at right edge = 0
```

Snap-to-cell is Chapter 28's sea-tile lesson reborn; the shift pass is a five-line compute copy with an integer offset. Skip reprojection and your ripples smear sideways with the boat like decals on glass.

Open boundaries need care too: the wave equation happily reflects off the texture edge (a hard wall). A **damping ramp** near the borders (damping drops from 0.996 toward 0.9) absorbs outgoing waves so they fade instead of bouncing back into view.

### Impulses: the boat's signature

Where does energy enter? You already compute hull contact: Chapter 32's buoyancy samples four hull points and knows each one's submersion and relative vertical velocity. Each sim step, **splat** a small Gaussian bump into the height field at each submerged point, scaled by how hard that point is working — relative velocity times immersion. Result: a fast boat writes a strong V; a drifting boat writes almost nothing; a slamming bow in storm chop pounds out rings. The cannonball toy is the same splat with a big one-shot impulse — and it earns its place as your *unit test*: a single splat must produce a clean expanding circle, the sim's hello-world.

### Compositing: two simulations, one surface

The ocean vertex shader currently adds FFT displacement; now it also adds ripple height (masked to the window, faded at its edge), and the fragment shader perturbs the normal with the ripple gradient. The two simulations don't interact physically — FFT swell doesn't refract your rings — and it does not matter visually: the eye reads "small waves riding big waves" as one ocean. This layering (global spectral + local interactive) is exactly how shipping games do it.

### What about the old wake?

Keep Chapter 34's texture wake — these solve different problems. The ripple sim produces *waves*: geometry, normals, light response, interaction, but only within 60 m and only for ~10 seconds of damping. The texture wake produces *foam*: a persistent, cheap, hundreds-of-meters trail of churned water that a height sim cannot represent at all (foam isn't a wave). Production answer: both — rings from the sim, the white trail from ch34, each doing what it's best at. Retune the ch34 alpha down a touch; it no longer carries the whole illusion.

## Build

1. **`Ripple_Sim` in `src/ripple.odin`:**

   ```odin
   Ripple_Sim :: struct {
       size:       i32,        // 512
       extent:     f32,        // 60.0 meters
       tex:        [3]u32,     // r32f height: prev, curr, next (rotating)
       origin:     glsl.vec2,  // world xz of texel (0,0), snapped to cells
       step_shader, splat_shader, shift_shader: Shader,
   }
   ```

   Textures: `r32f`, `LINEAR`, `CLAMP_TO_BORDER` with a zero border (outside the window is calm by definition). `ripple_create`, `ripple_destroy` per house rules.

2. **The step pass** `assets/shaders/ripple_step.comp` — the stencil plus boundary damping:

   ```glsl
   layout(r32f, binding = 0) uniform readonly  image2D u_prev;
   layout(r32f, binding = 1) uniform readonly  image2D u_curr;
   layout(r32f, binding = 2) uniform writeonly image2D u_next;
   uniform float u_c2dt2_dx2;     // (c·Δt/Δx)² — CPU-computed, asserted ≤ 0.5

   void main() {
       ivec2 p = ivec2(gl_GlobalInvocationID.xy);
       int n = imageSize(u_curr).x;
       float h  = imageLoad(u_curr, p).r;
       float sum = imageLoad(u_curr, p + ivec2( 1,0)).r + imageLoad(u_curr, p + ivec2(-1,0)).r
                 + imageLoad(u_curr, p + ivec2(0, 1)).r + imageLoad(u_curr, p + ivec2(0,-1)).r;
       float next = 2.0*h - imageLoad(u_prev, p).r + u_c2dt2_dx2 * (sum - 4.0*h);
       float edge = min(min(p.x, p.y), min(n-1-p.x, n-1-p.y)) / 32.0; // texels to border
       next *= mix(0.90, 0.996, clamp(edge, 0.0, 1.0));               // absorbing rim
       imageStore(u_next, p, vec4(next, 0, 0, 0));
   }
   ```

   On the CPU: `assert(c*dt/dx <= 0.707)` at creation — make CFL a crash, not a mystery. Step on the *fixed timestep*; rotate `tex[0..2]` after each step; `SHADER_IMAGE_ACCESS_BARRIER_BIT` between sim dispatches, `TEXTURE_FETCH` before the ocean draw.

3. **The splat pass** — a single 16×16 workgroup dispatched *per impulse*, centered on the contact point:

   ```glsl
   uniform vec2  u_center;     // texel coords (can be fractional)
   uniform float u_strength;   // signed: pushes down (bow) or up (stern suction)
   uniform float u_radius;     // texels
   void main() {
       ivec2 p = ivec2(gl_GlobalInvocationID.xy) + ivec2(u_center) - 8;
       float r = length(vec2(p) - u_center) / u_radius;
       if (r > 1.0) return;
       float bump = u_strength * exp(-r * r * 4.0);
       imageStore(u_curr, p, vec4(imageLoad(u_curr, p).r + bump, 0,0,0));
   }
   ```

   (`u_curr` read-write, same-texel only — safe.) From Odin, after the buoyancy update: for each of the four hull points with submersion > 0, `ripple_splat(sim, world_to_texel(p), strength = clamp(rel_vel * imm * 0.15, -0.4, 0.4), radius = 4)`. Then the toy: a debug key splats `strength = 1.5, radius = 8` at a point ahead of the bow. Enjoy. (You will.)

4. **The moving window.** Each tick, compute the desired origin (boat position minus half extent), snap to whole cells, and if it moved by `(di, dj)` cells, run the shift pass on both `prev` and `curr` — each texel reads `imageLoad(src, p + ivec2(di, dj))` with out-of-range → 0 — then update `sim.origin`. Bound the shift (if the boat teleports > half a window, just clear). Ten minutes of code; the difference between a simulation *in the world* and a decal.

5. **Composite into the ocean.** Vertex shader, after FFT displacement:

   ```glsl
   vec2 ruv  = (world.xz - u_ripple_origin) / u_ripple_extent;
   float rim = smoothstep(0.0, 0.08, min(min(ruv.x, ruv.y), 1.0 - max(ruv.x, ruv.y)));
   world.y  += texture(u_ripple, ruv).r * rim;
   ```

   Fragment: perturb the normal by the ripple gradient — two `textureOffset` taps per axis, scaled by the same `rim`, added to the FFT normal before lighting. The rim mask plus the absorbing border means the window edge is invisible twice over.

6. **Budget check.** Pass panel: step + splats + occasional shift on a 512² r32f grid ≈ 0.10–0.15 ms — effectively free, and *fixed*: the cost never grows with boat speed, weather, or splash count. That's the design property worth noticing: a capped-size local sim is one of the cheapest "the world responds to me" effects in all of real-time graphics.

## Checkpoint

Sail a tight circle at speed: bow rings radiate outward and *outlive your turn*, staying fixed in the world as you come back around through them. Stop dead: the rings damp away over ~10 s. Storm weather: the slamming hull writes chaotic overlapping rings into the chop.

- Cannonball splat: one clean circle, expanding at constant speed, no square artifacts (stencil correct), no rebound from the window edge (absorbing rim working).
- Drive to the window edge: ripples fade smoothly; no pop as the window shifts (reprojection working — toggle the shift pass off to see what it saves you from).
- Wireframe + freeze: ripple displacement visible in geometry, riding on FFT swell.
- The ch34 wake foam still trails behind, now *over* real ripple geometry. Best of both.

## Pitfalls

- **Sim explodes to ±∞ within a second.** CFL violated — `u_c2dt2_dx2 > 0.5`, or you stepped with a variable render dt (one long frame = one giant Δt = detonation). Fixed timestep, asserted constant.
- **Rings turn square as they expand.** The five-point stencil's axis bias shows when `(cΔt/Δx)²` is far below its limit *and* radius is small; bump it closer to 0.5, or accept it — at ripple scale under FFT motion nobody sees it. (Diagonal 9-point stencil is the exercise-grade fix.)
- **Ripples smear with the boat.** No reprojection on window shift (step 4), or you snapped origin but splatted with unsnapped coordinates — both must use the same snapped origin.
- **Wave fronts reflect off invisible walls.** Border damping ramp missing or too narrow; widen to 32+ texels. (Also check `CLAMP_TO_BORDER` — `REPEAT` here makes ripples *teleport* across the window.)
- **Splash visible but no lighting response.** You composited height but not normals — the gradient perturbation in step 5 carries 80% of the visual effect; height alone is nearly invisible at ripple amplitudes.
- **Stale ripples flicker.** Texture rotation order vs. binding order mismatch after the rotate — name the indices (`prev_i`, `curr_i`, `next_i`) instead of juggling raw 0/1/2.

## Exercises

1. Rain: in storm weather, splat 30 tiny random impulses per second across the window. Rain-stippled water for one `for` loop.
2. Shore interaction: zero the propagation where terrain rises above sea level (sample your terrain heightfield texture in `ripple_step.comp`, multiply `next` by a land mask). Ripples now lap and stop at the beach — Chapter 50's Stretch, finally trivial.
3. Wire the splash to gameplay: when any *crate* (ch65) slams down with high relative velocity, splat it. The debris field now writes on the water too.
4. **Stretch:** a second, coarser ring (128² over 400 m) fed by the fine grid's edge outflow — long bow waves that persist beyond the near window. You're inventing cascade thinking independently; notice it's the third time this part (shadow cascades, ocean cascades, now this).

## Commit

`git commit -m "ch67: interactive ripple sim — wave equation in compute, hull impulses"`

← [Chapter 66 — Beneath the Surface](ch66-beneath-the-surface.md) · [Chapter 68 — Milestone: The True Ocean](ch68-milestone-the-true-ocean.md) →
