# Interlude 46a — Glass Without Sorting

*⚓ Optional interlude · slots after [Chapter 46](ch46-spray-and-storm.md) · Estimated time: 4h · learnopengl: [Weighted Blended OIT (guest)](https://learnopengl.com/Guest-Articles/2020/OIT/Weighted-Blended)*

**Prerequisites:** Chapter 46 (particle pools, the depth copy), Chapter 34 (the wake), Chapter 40 (HDR target, fullscreen passes). · **Required downstream:** none — skip freely.

**What you'll see when done:** sun through a translucent sail, through bow spray, over the wake — and as you orbit the boat, nothing pops, flickers, or swaps order, from any bearing.

## Why this is a side quest

Chapter 34 ducked sorting ("the wake's triangles barely overlap"), and Chapter 46 ducked it again ("white spray over white foam hides ordering sins"). Both dodges were correct engineering — which is exactly why the honest general fix lives in a side quest: weighted-blended OIT is a production technique with real trade-offs, and Saltwind only *needs* it once you start stacking transparents that differ. Today you stack them on purpose.

## Concepts

### The recipe for failure

Make the sail slightly translucent — canvas with the sun behind it wants this anyway (`alpha ≈ 0.85`, drawn in the transparent stage). Now line up the shot: camera abeam, sail in front of bow spray in front of the wake. Orbit. Whatever order you draw the pools in is wrong from *somewhere* — sail-then-spray looks right from port and inside-out from starboard, particles flicker against the wake as the camera's view axis swings past their depth order. The root is mathematical: alpha `over` is **not commutative** — A over B ≠ B over A — so correctness demands per-fragment back-to-front order. Across a mesh sail, a triangle-strip wake, and two instanced particle pools, that means merging everything into one depth-sorted draw stream, every frame. Nobody does that for fun.

### McGuire & Bavoil's bargain

Weighted-blended OIT (2013) replaces ordered compositing with two aggregates that *do* commute:

```
accum     = Σ wᵢ·aᵢ·Cᵢ   (and Σ wᵢ·aᵢ alongside)        — a weighted sum
revealage = ∏ (1 − aᵢ)                                   — total transmittance

final = (accum.rgb / Σ wᵢ·aᵢ) · (1 − revealage) + background · revealage
```

Sums and products don't care about order: draw the sail, wake, and spray in any sequence and every pixel lands identically. The price is honest too — the transparent color is a weighted *average* of the layers, not a true stack, so "red glass behind blue glass" and "blue glass behind red glass" produce the same purple. The weight function exists to push that average toward what ordering would have given.

### The weight function and its knobs

The canonical pick from the paper (equation 9, the one the learnopengl article uses):

```glsl
float w = clamp(pow(min(1.0, a * 10.0) + 0.01, 3.0) * 1e8 *
                pow(1.0 - gl_FragCoord.z * 0.9, 3.0), 1e-2, 3e3);
```

Three knobs worth knowing: the **depth term** gives nearer fragments a louder vote (the order-ish cue that rescues most scenes); the **alpha term** lets nearly-opaque fragments dominate wisps; the **clamps** keep the sums inside f16 range with hundreds of overlapping particles. It's a heuristic, tuned per game — Exercise 2 tunes it for Saltwind's draw distances.

### Two targets, two blend states — and a GL 3.3 wrinkle

The algorithm wants MRT with *different* blending per attachment: an `RGBA16F` **accum** target blending additively (`ONE, ONE`) and an `R16F` **revealage** target blending multiplicatively (`ZERO, ONE_MINUS_SRC_COLOR`). Per-target blend state is `gl.BlendFunci` — **GL 4.0**. Under our `gl.load_up_to(3, 3)` that function pointer is never loaded (calling it is a nil-pointer crash), so we use the same-blend-for-all-targets fallback, and it costs nothing: `gl.BlendFuncSeparate` (GL 2.0) already sets one rule for RGB and a *different* one for alpha, across all targets. Shuffle the channels so each aggregate lands where its blend rule already lives:

- **target 0** `RGBA16F`: `.rgb` = Σ w·a·C (additive RGB) · `.a` = ∏(1−a) (multiplicative alpha) — cleared to `(0,0,0,1)`
- **target 1** `R16F`: `.r` = Σ w·a (additive RGB) — cleared to 0

One call serves both: `gl.BlendFuncSeparate(gl.ONE, gl.ONE, gl.ZERO, gl.ONE_MINUS_SRC_ALPHA)`. Identical math to the paper, channels rearranged. (Why `R16F` revealage instead of the article's `R8`? A storm's worth of 0.25-alpha rain layers underflows 8 bits; f16 keeps the product honest.)

> **Sidebar — the honest comparison.** **Sorting** is exact for non-interpenetrating surfaces, costs CPU every frame, and still fails when geometry interleaves (two crossing wake strips have no correct order). **Depth peeling** is exact for any geometry but re-renders all transparents once per layer — N layers, N passes. **WBOIT** is one pass, approximate, and fails *gracefully*: errors show as slightly-wrong mixing, never popping. Saltwind's transparents are its sweet spot — many low-alpha, low-contrast, similar-color fragments. Its weak case is two high-contrast surfaces overlapping at similar depth and alpha; with white spray, white wake, and cream sail, you will struggle to construct a complaint.

### Who's in, who's out

In: spray, rain, the wake, the sail. Out: the **ocean**, deliberately, for three reasons. It's effectively the *background* every transparent composites over, so it belongs in the opaque-ish base pass; its "transparency" is the bespoke ch30 refraction pipeline (depth tint, DuDv distortion) that an averaged blend would simply destroy; and it fills half the screen — paying f16 MRT fill for a surface that's 95% opaque is the wrong bill. Big specialized surfaces keep their pipelines; OIT is for the *crowd* of small transparents. (Part 9's deferred renderer reaches the same verdict about the ocean, for cousin reasons.)

## Odin notes

`gl.DrawBuffers` wants a pointer into an array: `bufs := [2]u32{gl.COLOR_ATTACHMENT0, gl.COLOR_ATTACHMENT1}; gl.DrawBuffers(2, &bufs[0])`. Per-attachment clear values are `gl.ClearBufferfv` (core since 3.0): pass `&clear[0]` of a `[4]f32`. Both live happily at 3.3 — nothing in this interlude needs a context bump.

## Build

1. **Stage the failure.** Give the sail its translucency and draw it in the transparent stage after the wake. Kick up spray, orbit slowly, screenshot the popping. This is your "before" — and your motivation when the MRT plumbing gets fiddly.

2. **The OIT target.** Two color textures sized with the HDR target, *sharing its depth*:

   ```odin
   Oit_Target :: struct {
       fbo:        u32,
       accum_tex:  u32, // RGBA16F
       weight_tex: u32, // R16F — Σ w·a
   }
   ```

   `accum_tex` exactly like ch40's HDR color; `weight_tex` via `gl.TexImage2D(gl.TEXTURE_2D, 0, gl.R16F, w, h, 0, gl.RED, gl.FLOAT, nil)`. Attach as `COLOR_ATTACHMENT0/1`, attach **the HDR target's existing depth texture** as `DEPTH_ATTACHMENT` (shared: transparents depth-test against the opaque scene for free), set `DrawBuffers`, check completeness. Recreate alongside `hdr` in the resize callback.

3. **OIT fragment outputs.** Each transparent shader — particle, wake, sail — computes its color exactly as before (tint, atlas, soft-particle fade), then ends differently:

   ```glsl
   layout (location = 0) out vec4 o_accum;
   layout (location = 1) out vec4 o_weight;

   void write_oit(vec4 color) {   // straight alpha, linear HDR
       float w = clamp(pow(min(1.0, color.a * 10.0) + 0.01, 3.0) * 1e8 *
                       pow(1.0 - gl_FragCoord.z * 0.9, 3.0), 1e-2, 3e3);
       o_accum  = vec4(color.rgb * color.a * w, color.a);
       o_weight = vec4(color.a * w);
   }
   ```

   `o_accum.a` is the *raw* alpha — the separate-alpha blend turns it into the running ∏(1−a) for you.

4. **The pass.** After opaques, the ocean, and the ch46 depth blit — where the transparent stage used to be:

   ```odin
   gl.BindFramebuffer(gl.FRAMEBUFFER, oit.fbo)
   clear_accum  := [4]f32{0, 0, 0, 1}   // revealage starts at 1!
   clear_weight := [4]f32{0, 0, 0, 0}
   gl.ClearBufferfv(gl.COLOR, 0, &clear_accum[0])
   gl.ClearBufferfv(gl.COLOR, 1, &clear_weight[0])
   gl.DepthMask(false)
   gl.BlendFuncSeparate(gl.ONE, gl.ONE, gl.ZERO, gl.ONE_MINUS_SRC_ALPHA)
   // draw sail, wake, spray, rain — in ANY order; that's the point
   gl.DepthMask(true)
   ```

   Do **not** clear depth — it's the scene's, on loan.

5. **Composite.** A fullscreen triangle back onto the HDR target, classic alpha blend (`gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA`), depth test off:

   ```glsl
   uniform sampler2D u_accum;
   uniform sampler2D u_weight;
   in vec2 v_uv;
   out vec4 frag;

   void main() {
       vec4  accum  = texture(u_accum, v_uv);
       float reveal = accum.a;
       vec3  avg    = accum.rgb / max(texture(u_weight, v_uv).r, 1e-5);
       frag = vec4(avg, 1.0 - reveal);  // = avg·(1−reveal) + scene·reveal
   }
   ```

   Pixels no transparent touched composite to exactly nothing (`reveal` still 1). Then carry on to tonemap as ever — everything stayed linear HDR throughout.

6. **Re-run the recipe.** Same sail, same spray, same orbit as step 1.

## Checkpoint

Sun behind the translucent sail, bow throwing spray across the wake: orbit a full circle and the layered glass holds from every bearing — no popping, no order swaps, and spray *within* a burst self-blends smoothly (the case sorting could never afford per-particle).

- Keep a key toggling old path vs OIT: WBOIT loses a little punch where dense spray stacks (the averaging), and gains everywhere ordering used to lie. Decide if you like the trade — that's the real lesson.
- Soft particles still dissolve at the hull (the depth-copy fade rode along inside `color.a` *before* weighting).
- Heavy rain: revealage stays smooth, no banding — the `R16F` earning its bits.
- If you ever add additive pools (sparks, sun motes): leave them out of OIT and draw them after the composite — addition was never broken.

## Pitfalls

- **Scene only visible through transparents / screen washed dark.** Accum cleared to `(0,0,0,0)`: revealage starts at 0, meaning "fully covered everywhere." The alpha clear value must be 1 — it's why step 4 uses `ClearBufferfv` instead of one `gl.Clear`.
- **Instant crash on `gl.BlendFunci`.** It's GL 4.0; under `load_up_to(3, 3)` the pointer is nil. Use the `BlendFuncSeparate` shuffle — or take the Stretch exercise's capability-checked 4.0 path.
- **Transparents draw through islands.** The OIT FBO got its own fresh depth attachment (empty = everything passes). Share the HDR depth texture, and never clear depth in this pass.
- **Hard particle edges came back.** The soft fade was applied after `write_oit` computed weights — fade `color.a` first — or you sampled the live depth *attachment* instead of ch46's blit copy (the feedback loop, again).
- **Everything behind glass slightly dimmed or doubled.** Composite blend reversed, or you output `reveal` instead of `1.0 - reveal`.
- **The sail looks exactly like before.** Its fragment shader still declares a single `out` — with one output, GL writes attachment 0 and silently drops the weight target, and the composite divides garbage by zero-ish. Both outs, both attachments, every transparent shader.

## Exercises

1. Debug views: bind keys to fullscreen-blit `accum.rgb`, `Σ w·a`, and revealage raw. Watch one spray burst write all three — the weight function stops being a magic number when you can *see* its vote.
2. `gl_FragCoord.z` is hyperbolic — nearly all its precision sits in the first meters. Swap the depth term for one built on linearized view-space z (you wrote `linearize` in ch46) with a falloff scaled to Saltwind's ~200 m transparent range, and A/B sail-near-over-spray-far, which the canonical term handles worst.
3. **Stretch:** the GL 4.0 path behind a capability check: `gl.load_up_to(4, 0)`, per-target `gl.BlendFunci`, the article's canonical layout (revealage alone in its own target, cleared to 1). Verify pixel-identical output against the channel shuffle — proof the rearrangement was free — then keep whichever your min-spec allows (Chapter 83 will ask).

## Commit

`git commit -m "ch46a: weighted-blended OIT — accum/revealage MRT, one blend state, composite pass"`

← Back to [Chapter 46 — Spray & Storm](ch46-spray-and-storm.md) · onward to [Chapter 47 — The Breath of Distance](ch47-the-breath-of-distance.md) →
