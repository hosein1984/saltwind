# Chapter 41 — The Sun Bleeds

*Part 7 — Advanced Light · Estimated time: 3h · learnopengl: [Bloom](https://learnopengl.com/Advanced-Lighting/Bloom)*

**What you'll see when done:** the low sun bleeds soft light into the sky around it, wave glitter sparkles with halos, and at night the boat's lantern glows like a real flame instead of a bright dot.

## Where we are

HDR gave you pixels brighter than 1.0 — and so far the tonemapper just politely squeezes them down. But your eye expects very bright things to *bleed*: lens scatter, corneal scatter, film halation. Bloom fakes that by blurring only the bright parts of the HDR image and adding the blur back. It's the chapter with the highest beauty-per-line-of-code ratio in this course, and also the easiest effect to ruin by overdoing. Both facts get respected below.

## Concepts

### The pipeline

```
HDR scene ──► bright pass ──► blur H ──► blur V ──► blur H ──► ... ──► composite
 (RGBA16F)    (threshold,      ping      pong       ping              add into HDR,
               half res)        +────── N iterations ─────+           THEN tonemap
```

Three stages: extract pixels above a threshold, blur them a lot, add the result back **before tone mapping**. That ordering matters — bloom is light, and light gets tonemapped with everything else. Composite after tonemap and your halos turn into gray fog.

### Bright pass with a soft knee

A hard cutoff (`if luminance > 1.0 keep else black`) makes bloom *flicker*: a wave facet oscillating around the threshold pops its halo on and off every frame. The fix is a **soft knee** — a quadratic ramp around the threshold so contribution fades in smoothly:

```glsl
vec3 c = texture(u_hdr, v_uv).rgb;
float l = dot(c, vec3(0.2126, 0.7152, 0.0722));
float knee = u_threshold * u_softness;                 // e.g. 1.0 * 0.5
float soft = clamp(l - u_threshold + knee, 0.0, 2.0 * knee);
soft = soft * soft / (4.0 * knee + 1e-5);
float contrib = max(soft, l - u_threshold) / max(l, 1e-5);
frag = vec4(c * contrib, 1.0);
```

With HDR in place, a threshold of ~1.0 means "only things brighter than a fully lit white surface bloom" — sun, glitter, lanterns. Exactly right.

### Separable Gaussian blur, ping-pong, and the resolution trick

A 2D Gaussian blur of radius *n* costs *n²* samples — but a Gaussian is **separable**: blur horizontally, then vertically, for 2*n* cost and an identical result. You alternate between two FBOs ("ping-pong"): A→B horizontal, B→A vertical, repeat for a wider blur.

The cheapest blur win, though, is **resolution**: do all of this at *half* (or quarter) resolution. Downsampling is itself a blur, the Gaussian gets effectively twice as wide per tap, and you pay a quarter of the fragment cost. Bloom is low-frequency by nature — nobody can tell.

Rather than hard-coding magic weights, compute them in Odin and upload — it's more instructive and lets you tweak sigma live:

```odin
// weights[0] is the center tap; kernel is symmetric
compute_gauss_weights :: proc(weights: []f32, sigma: f32) {
    total := f32(0)
    for i in 0 ..< len(weights) {
        w := math.exp_f32(-f32(i * i) / (2 * sigma * sigma))
        weights[i] = w
        total += i == 0 ? w : 2 * w
    }
    for &w in weights { w /= total } // normalize: blur must not gain energy
}
```

Five weights (center + 4) with sigma ≈ 2.5, run for 4–6 ping-pong iterations at half res, gives a wide creamy halo.

### Composite, and the seasoning rule

Final step: `hdr_color + bloom_color * u_bloom_strength` — additive, in linear HDR space, then tonemap as before. And the taste advice, which you should write on a sticky note: **bloom is a seasoning, not a sauce.** Strength around 0.04–0.15. If you can *see* "the bloom effect" when looking at an ordinary sunlit sail, it's too strong. Bloom should be something you only notice when it's gone — toggle it off and the image feels suddenly dead, like a dry stage light. The mid-2000s "everything smeared in vaseline" era happened because this knob goes to 11.

## Build

1. **Half-res ping-pong targets.** Two color-only `RGBA16F` render targets at `width/2 × height/2` (no depth needed), owned by `Renderer`. Reuse `render_target_create` with a flag or a slimmer `blur_target_create`. Set filtering to `LINEAR` — downsampling and the blur both rely on it — and wrap `CLAMP_TO_EDGE` so the sun at the screen edge doesn't smear in from the other side.

2. **Three small shaders**, all using the ch40 fullscreen triangle:
   - `bloom_bright.frag` — the soft-knee extraction above; reads the full-res HDR texture, writes into ping target (the viewport change does the downsample).
   - `blur.frag` — 1D 5-tap Gaussian; uniform `u_horizontal` flips the offset axis, `u_weights[5]` from the Odin proc:

   ```glsl
   uniform sampler2D u_src;
   uniform bool u_horizontal;
   uniform float u_weights[5];
   in vec2 v_uv; out vec4 frag;
   void main() {
       vec2 texel = 1.0 / vec2(textureSize(u_src, 0));
       vec2 dir = u_horizontal ? vec2(texel.x, 0.0) : vec2(0.0, texel.y);
       vec3 sum = texture(u_src, v_uv).rgb * u_weights[0];
       for (int i = 1; i < 5; ++i) {
           sum += texture(u_src, v_uv + dir * float(i)).rgb * u_weights[i];
           sum += texture(u_src, v_uv - dir * float(i)).rgb * u_weights[i];
       }
       frag = vec4(sum, 1.0);
   }
   ```

   - Extend `tonemap.frag` with `uniform sampler2D u_bloom; uniform float u_bloom_strength;` and change the first line to `vec3 c = (texture(u_hdr, v_uv).rgb + texture(u_bloom, v_uv).rgb * u_bloom_strength) * u_exposure;` — compositing and tonemapping in one pass, since both are fullscreen anyway.

3. **The bloom pass proc.** Between scene and tonemap:

   ```odin
   renderer_bloom_pass :: proc(r: ^Renderer) {
       gl.Disable(gl.DEPTH_TEST)
       gl.Viewport(0, 0, r.ping.width, r.ping.height)

       // bright extract: hdr -> ping
       gl.BindFramebuffer(gl.FRAMEBUFFER, r.ping.fbo)
       shader_use(r.bright_shader)
       bind_tex0(r.hdr.color_tex)
       fullscreen_draw(r)

       // ping-pong blur
       horizontal := true
       for _ in 0 ..< 2 * r.blur_iterations {
           dst := horizontal ? &r.pong : &r.ping
           src := horizontal ? &r.ping : &r.pong
           gl.BindFramebuffer(gl.FRAMEBUFFER, dst.fbo)
           shader_use(r.blur_shader)
           shader_set_bool(r.blur_shader, "u_horizontal", horizontal)
           bind_tex0(src.color_tex)
           fullscreen_draw(r)
           horizontal = !horizontal
       }
   }
   ```

   After an even number of passes the result sits in `ping`; bind it as `u_bloom` (texture unit 1) in `renderer_end_hdr`. Don't forget to restore the full-res viewport there.

4. **Uniform upload for weights.** `gl.Uniform1fv(loc, 5, &weights[0])` — or loop `shader_set_f32` with indexed names `u_weights[0]`… if your helper doesn't do arrays yet; now's a fine moment to add `shader_set_f32_array`.

5. **Tune.** Keys for `u_bloom_strength` (start 0.08), threshold (start 1.0), iterations (start 5). Then go look at: the sun half-set behind an island (rim bleed over the silhouette — the money shot), glitter on the swells, and a lantern at midnight (set its emissive bright, ~30, and watch it become a warm orb).

## Checkpoint

At golden hour the sun's disk feathers into the sky and bleeds over the island silhouette in front of it; specular glitter twinkles with tiny halos; with bloom toggled off the same scene looks abruptly clinical.

- Toggle bloom on/off with a debug key: difference obvious at the sun, *barely perceptible* on a lit sail. That's correct seasoning.
- Stare at wave glitter for ten seconds: no on/off popping of halos (soft knee working).
- The halo is round, not cross- or staircase-shaped (enough iterations, linear filtering on).
- Frame time barely moved (you're at half res; if you went up >1 ms, check you didn't blur at full res).

## Pitfalls

- **Bloom looks like gray fog over everything.** You composited *after* tonemapping, or your threshold is below typical scene luminance so the whole image blooms.
- **Flickering halos on waves.** Hard threshold — implement the soft knee; also consider slightly lowering glitter intensity variance.
- **Visible square/streak artifacts in the halo.** `NEAREST` filtering on the ping-pong textures, or too-few blur iterations with too-large sigma.
- **Bloom smears in from the opposite screen edge.** Wrap mode is `REPEAT` (the default!) on the blur targets. Set `CLAMP_TO_EDGE`.
- **Whole screen darkens when bloom enabled.** Your blur weights don't sum to 1 (forgot the ×2 for symmetric taps, or forgot to normalize) — energy is leaking each iteration.
- **Nothing blooms at night.** Lantern emissive color is ≤ 1.0. Bloom eats HDR; feed it real radiance (10+).

## Exercises

1. Add a debug view mode that shows the bright-pass output and each blur stage on screen (cycle with a key). Watching the energy spread is the best intuition builder.
2. Drop the blur chain to *quarter* res. Can you see the difference at 1080p? Measure the cost difference.
3. Give the lantern a subtle flicker (noise-driven intensity, ±15% at ~8 Hz) — bloom amplifies it into convincing firelight on the water.
4. **Stretch:** replace ping-pong Gaussian with a downsample/upsample mip chain (the "Call of Duty: Advanced Warfare" method, described in learnopengl's [Phys. Based Bloom guest article](https://learnopengl.com/Guest-Articles/2022/Phys.-Based-Bloom)): blur while descending 4–5 mips, additively upsample back. Wider, more stable bloom for less cost.

## Commit

`git commit -m "ch41: bloom — soft-knee bright pass, half-res separable blur, pre-tonemap composite"`

[← Ch. 40: More Light than Screen](ch40-more-light-than-screen.md) · [Ch. 42: Physically Based →](ch42-physically-based.md)
