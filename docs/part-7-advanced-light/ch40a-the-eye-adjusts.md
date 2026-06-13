# Interlude 40a — The Eye Adjusts

*⚓ Optional interlude · slots after [Chapter 40](ch40-more-light-than-screen.md) · Estimated time: 3h · learnopengl: no direct equivalent*

**Prerequisites:** Chapter 40 (HDR target, tonemap pass, the fullscreen triangle). · **Required downstream:** none — skip freely.

**What you'll see when done:** swing the camera from sun-blasted glitter into the black shadow of a cliff and the image blooms from murk into detail over a couple of seconds — your renderer has grown an iris, and it reacts like yours.

## Why this is a side quest

Chapter 40 gave you an exposure knob, and a knob is honestly enough for the main line: you tune for the scene you're in, and the course mostly keeps you in golden hour. But a fixed exposure that flatters sunset is wrong at noon and useless at night — every camera and every shipped game solves this with auto-exposure. Chapter 40's Exercise 3 sketched the crude version (read pixels back, stall the pipe); this interlude builds the real one: metered entirely on the GPU, no readback, with the adaptation *lag* that makes it feel like an eye instead of a thermostat.

## Concepts

### Metering: what is "how bright is the scene"?

Your HDR target holds scene-referred linear radiance; per pixel, luminance is the ch40 dot product `dot(c, vec3(0.2126, 0.7152, 0.0722))`. The naive meter — arithmetic mean of all luminances — is hostage to outliers: your sun disk outputs 20+, and a few thousand sun pixels can drag the average up until the whole sea exposes for the sun. The photographic answer (Reinhard et al., the same lineage as your tonemap) is the **log-average**:

```
L̄ = exp( mean( log(δ + L) ) )        δ ≈ 1e-4 so log never sees zero
```

That's a geometric mean: a pixel 1000× brighter than its neighbors nudges a log-average by a constant amount instead of yanking it by 1000×. It's the difference between "the sun is on screen" and "the image is the sun."

### Averaging two million pixels without reading them back

The GPU already owns a machine that averages textures: **the mipmap**. So the GL 3.3 pipeline is three tiny steps:

```
HDR scene ──lum pass──> 256×256 R16F (log L) ──glGenerateMipmap──> level 8 = 1×1
                                                  mean of all the logs, on-GPU
tonemap/adapt shaders: textureLod(u_log_lum, vec2(0.5), 8.0) → exp() → L̄
```

A fullscreen pass writes log-luminance into a small dedicated render target, one `gl.GenerateMipmap` folds it down, and the top mip *is* the mean — sampled with `textureLod` at max level, never touching the CPU. (256² is plenty: metering doesn't need every pixel, it needs a fair sample.)

### From luminance to exposure: the key value

Reinhard's **key-value formula** maps the metered average to an exposure: `exposure = key / L̄`, with `key ≈ 0.18` — photographic middle gray. Read it as an instruction to the tonemapper: *whatever the scene's average is, place it at 18% before the curve's shoulder.* Bright scene → small exposure; dark scene → large. Two clamps on L̄ keep it honest: a floor so a moonless night isn't cranked to noon (plus the shimmering disco of amplified noise that comes with it), and a ceiling so staring into the sun doesn't crush the deck to black.

### The lag is the feature

Applying that formula instantly per frame is the thermostat: every wave glint crossing the frame twitches the exposure, and the image *pumps*. Real eyes adapt over time — and asymmetrically: fast when it gets brighter, slow when it gets darker (walking out of a dark cabin onto a bright deck stings for half a second; going below decks takes long seconds to resolve). Exponential smoothing gives you exactly that with one line of state:

```
L_adapted += (L̄ − L_adapted) · (1 − exp(−dt / τ))      τ ≈ 0.5 s up, 3 s down
```

One value carried across frames means one piece of GPU state: a 1×1 ping-pong texture pair — read last frame's, write this frame's.

### Art direction stays in charge

Auto-exposure replaces the *level*, not the *taste*. Keep a manual override, and re-cast the ch40 `[`/`]` keys as **exposure compensation** in EV stops — a final `exp2(comp)` multiplier, exactly the ±EV dial on a camera. Dusk wants to *feel* dim; that's a −1 EV decision a meter can't make for you.

> **Sidebar — the compute histogram (for post-Part-10 readers).** The mip average weighs every pixel equally, and a frame that's half sky meters for the sky. Production engines build a 256-bin log-luminance **histogram** in a compute shader (GL 4.3 — Chapter 61 teaches you compute properly), then meter on a percentile band: discard the darkest ~10% and brightest ~5%, average what remains. Immune to the sun, immune to a black hull filling a third of the frame. Everything downstream — key value, clamps, adaptation — stays identical; only the metering swaps. Come back after Part 10 and do the Stretch exercise.

## Build

1. **Targets.** All fixed-size, so the resize callback never touches them. In `Renderer`:

   ```odin
   LUM_SIZE    :: 256
   LUM_TOP_MIP :: 8 // log2(LUM_SIZE)

   Renderer :: struct {
       // ...ch40 fields...
       lum_fbo, lum_tex: u32,        // 256², R16F, mipped
       adapt_fbo:        [2]u32,     // 1×1 ping-pong pair
       adapt_tex:        [2]u32,
       adapt_cur:        int,
       auto_exposure:    bool,
       exposure_comp:    f32,        // EV stops
   }
   ```

   `lum_tex` is `gl.R16F` (it stores *logs* — negative values are the common case), min filter `LINEAR_MIPMAP_LINEAR`; call `gl.GenerateMipmap(gl.TEXTURE_2D)` once at creation to allocate the chain. The adapt pair are 1×1 `R16F`, `NEAREST`; clear each to `0.18` once at startup so frame one isn't a flashbang.

2. **The luminance pass.** `lum.frag`, driven by the ch40 fullscreen triangle:

   ```glsl
   #version 330 core
   uniform sampler2D u_hdr;
   in vec2 v_uv;
   out vec4 frag;

   void main() {
       vec3  c = texture(u_hdr, v_uv).rgb;
       float l = dot(c, vec3(0.2126, 0.7152, 0.0722));
       frag = vec4(log(max(l, 1e-4)), 0.0, 0.0, 1.0);
   }
   ```

   Slot it inside `renderer_end_hdr`, before the tonemap: bind `lum_fbo`, viewport 256², draw the triangle sampling `hdr.color_tex`, then bind `lum_tex` and `gl.GenerateMipmap(gl.TEXTURE_2D)` — *every frame*, that's the fold.

3. **The adaptation pass.** `adapt.frag`, rendered into a 1×1 viewport:

   ```glsl
   #version 330 core
   uniform sampler2D u_log_lum;  // mipped 256²
   uniform sampler2D u_prev;     // last frame's adapted L, 1×1
   uniform float u_dt;
   out vec4 frag;

   void main() {
       float avg  = exp(textureLod(u_log_lum, vec2(0.5), 8.0).r);
       float prev = texture(u_prev, vec2(0.5)).r;
       float tau  = avg > prev ? 0.5 : 3.0;   // brighten fast, darken slow
       float a    = 1.0 - exp(-u_dt / tau);
       frag = vec4(max(prev + (avg - prev) * a, 1e-4), 0.0, 0.0, 1.0);
   }
   ```

   Odin side — pass `dt` into `renderer_end_hdr` and ping-pong:

   ```odin
   dst := 1 - r.adapt_cur
   gl.BindFramebuffer(gl.FRAMEBUFFER, r.adapt_fbo[dst])
   gl.Viewport(0, 0, 1, 1)
   shader_use(r.adapt_shader)
   shader_set_f32(r.adapt_shader, "u_dt", dt)
   // unit 0: lum_tex · unit 1: adapt_tex[r.adapt_cur]
   gl.DrawArrays(gl.TRIANGLES, 0, 3)
   r.adapt_cur = dst
   ```

4. **Exposure in the tonemap.** `tonemap.frag` grows three uniforms and one branch:

   ```glsl
   uniform sampler2D u_adapted;   // 1×1
   uniform int   u_auto;
   uniform float u_comp;          // EV stops

   float exposure = u_exposure;   // ch40 manual path, untouched
   if (u_auto == 1) {
       float l = clamp(texture(u_adapted, vec2(0.5)).r, 0.03, 2.0);
       exposure = 0.18 / l * exp2(u_comp);
   }
   vec3 c = texture(u_hdr, v_uv).rgb * exposure;
   ```

   `0.03` and `2.0` are the L̄ clamps — the no-disco rails. Tune them against your sun intensity from ch40 step 5.

5. **Controls.** A key toggles `auto_exposure`; in auto mode `[`/`]` step `exposure_comp` by ±0.5 EV. Print L̄, adapted L, and final exposure in the title bar. Keep manual mode alive — it's your debugging reference ("what does the scene *actually* look like at exposure 1?").

6. **The moment.** Drop the sun low (ch27 keys), sail into the shadow side of an island until cliff fills the view, hold a beat, then swing the bow back through the sun glitter.

## Checkpoint

Into the cliff shadow: the first instant is too dark — then detail blooms out of the murk over ~3 seconds. Swing back to the sun path: a blinding overshoot that collapses in about half a second. Fast into light, slow into dark — backwards from a thermostat, exactly like an eye.

- Hold the camera still on a mixed scene: exposure settles and *stays* settled. Waves glinting must not pump the image — the log-average plus the lag absorb them (if it pumps, see Pitfalls).
- The sun disk remains the brightest thing through every adjustment — exposure scales, ACES still owns the rolloff.
- Toggling auto off snaps to the manual value instantly; toggling on re-adapts from wherever it left off.
- Resize the window: nothing changes. The whole metering chain is fixed-size by design.

## Pitfalls

- **Exposure slowly fades to black (or white) over seconds.** The ping-pong reads the texture it's writing — a feedback loop, undefined, usually stale-or-garbage. Two textures, alternate every frame, never bind the destination as `u_prev`.
- **One black frame, then NaN forever.** `log(0)` from any fully black pixel becomes −inf, the mip average becomes NaN, and NaN propagates through `exp`, the lerp, and eternity. The `max(l, 1e-4)` is load-bearing.
- **Exposure frozen at its startup value.** `gl.GenerateMipmap` runs at creation but not per frame — level 8 still holds the average of the allocation-time contents.
- **`textureLod` returns a single unaveraged texel.** `lum_tex`'s min filter isn't a mipmap mode (set `LINEAR_MIPMAP_LINEAR`), or `LUM_TOP_MIP` doesn't match `log2(LUM_SIZE)` after you "tuned" the size.
- **Night looks like noon, with shimmer.** No floor clamp on L̄: `0.18 / 0.0001` is exposure 1800, amplifying f16 quantization into visible noise. Clamp.
- **Image pumps despite the lag.** τ set in frames instead of seconds (you passed raw frame count, or `dt` in ms), or you're smoothing *exposure* after clamping instead of luminance before — clamp-then-smooth reintroduces steps at the rail.

## Exercises

1. Center-weighted metering: multiply `lum.frag`'s output by a soft vignette (bright center, dim corners — weight the *log* values via a lerp toward the mean, or simply render the lum pass from the center 70% of the HDR texture's UVs). Composition now drives exposure, like a real camera's meter.
2. Plot the chase: log L̄, adapted L, and exposure to the title bar and sail through a full ch27 day. Find the τ values where dawn feels gradual but stepping out of shadow still has that half-second sting.
3. **Stretch (after Part 10):** the histogram version — a compute shader builds 256 log-luminance bins with shared-memory atomics, a second dispatch meters on the 10th–95th percentile band. A/B against the mip chain at sunset with the sun on-screen versus just off-screen; the histogram shouldn't care, the mip average will.

## Commit

`git commit -m "ch40a: auto-exposure — log-luminance mip metering, temporal adaptation, EV compensation"`

← Back to [Chapter 40 — More Light than Screen](ch40-more-light-than-screen.md) · onward to [Chapter 41 — The Sun Bleeds](ch41-the-sun-bleeds.md) →
