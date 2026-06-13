# Chapter 58 — Mirrors of the Sea

*Part 9 — The Deep Engine · Estimated time: 6–7h · learnopengl: no direct equivalent — canonical reference: [McGuire & Mara, "Efficient GPU Screen-Space Ray Tracing"](https://jcgt.org/published/0003/04/04/) (JCGT 2014; companion [casual-effects writeup](http://casual-effects.blogspot.com/2014/08/screen-space-ray-tracing.html))*

**What you'll see when done:** the wet deck after a storm mirrors the mast and the sunset sky, lantern light smears across rain-slicked rails — reflections of *actual scene geometry*, computed from nothing but the frame you already rendered.

## Where we are

You own three reflection technologies and none of them helps a wet deck. The planar FBO (ch30) only reflects across the *ocean's* plane; the IBL cubemap (ch43) only knows the distant sky; neither can show the mast in a puddle. But the rendered frame itself contains the mast, lit and finished — and the depth buffer says where everything is. **Screen-space reflections** ray-trace against that: march the reflected ray through view space, checking the depth buffer for a hit, and reuse the lit pixel you find. It fails often and predictably — half this chapter is the art of *fading out gracefully* and falling back through the chain you already built.

## Concepts

### Raymarching the depth buffer

Per shaded pixel: reconstruct view-space position `P` (ch55 math) and normal `N` (G-buffer), reflect the eye ray `R = reflect(normalize(P), N)`, then walk:

```
 camera ·________            step along R in view space;
         \       ¯¯¯¯·-------  at each step, project to uv,
          \   R ↗      ?       compare ray depth to depth buffer
           \  ↗      ▒▒▒▒▒
        ____\↗_______▒mast▒    ray behind recorded surface
        ▒deck▒       ▒▒▒▒▒     (and not by too much) => HIT:
                               sample the HDR color there
```

Coarse-then-fine beats brute force: take big steps (say 32–64 of them, growing geometrically) until the ray first dips behind the depth buffer, then **binary search** between the last two positions for 4–6 iterations to land precisely. The coarse march finds *that* there's a hit; the refinement finds *where*.

### Thickness — the question the depth buffer can't answer

The depth buffer records surface *fronts*, not volumes. When the ray passes behind a recorded depth, is it inside the mast (hit) or did it pass *behind* a thin rope (no hit)? You can't know — so you assume a **thickness**: count it a hit only if `ray_depth − scene_depth < u_thickness` (≈0.3–1.0 m). Too small: rays tunnel through hulls, banded reflections. Too large: everything thin smears long false streaks. There is no correct value, only a tuned one.

### Fading: the art of failing politely

SSR's information ends at the screen's edge and behind the front surface. Hard failure reads as glitch; *faded* failure reads as "soft reflection." Compute a confidence ∈ [0,1] and multiply:

- **Screen-edge fade** — hit uv near the border: `fade = smoothstep` on distance to each edge. Reflections slide off-screen as the camera turns instead of popping.
- **Facing fade** — rays bending back *toward* the camera (`R.z > 0` in view space, pointing at you) mostly hit backsides of things the buffer never recorded. Fade by `1 - smoothstep(...)` on that component.
- **Ray-length fade** — long rays accumulate error and likely left useful data anyway.
- **No-hit = confidence 0** — march exhausted without intersection.

> **Sidebar — roughness-aware SSR.** A mirror deck is rare; a *glossy* one is everywhere. Cheap and effective: you already have blurred copies of the scene in the bloom mip/ping-pong chain — sample your reflection color from a blurrier level as roughness rises, and fade SSR out entirely past roughness ~0.6 (let IBL's prefiltered mips own rough surfaces — that's literally what they encode). The expensive route (jittered rays + temporal accumulation) needs TAA machinery you've sensibly deferred.

### The fallback chain

Each technology covers the previous one's blind spot:

```
                      │ reflects what?            │ blind spot
 ─────────────────────┼───────────────────────────┼─────────────────────────
 SSR (this chapter)   │ anything on screen, any   │ offscreen & occluded
                      │ surface orientation       │ content; rough surfaces
 planar FBO (ch30)    │ full re-render, including │ only valid for ONE
                      │ offscreen content         │ plane (the sea's)
 IBL cubemap (ch43)   │ the distant sky, any      │ no local geometry,
                      │ roughness (prefiltered)   │ no parallax
```

Compose by confidence:

```glsl
vec3 ibl    = prefiltered_specular(R_world, roughness);   // always defined (ch43)
vec3 ssr    = ssr_color.rgb;                              // best when valid
vec3 spec   = mix(ibl, ssr, ssr_confidence);              // the chain
```

**The ocean keeps its planar FBO**, and this is worth saying carefully: for one flat, screen-dominating plane, planar reflection is *better* than SSR — it re-renders the scene from the mirrored camera, so it reflects things that are off-screen or occluded in the main view (the sky behind you, the far side of the boat), exactly SSR's blind spots, and the wave distortion hides its half-res softness. SSR wins on *arbitrary* surfaces — decks, hulls, rails — where a per-plane FBO is impossible. Use each where it's strong; that's the chain: **SSR where confident → planar on the sea plane → IBL everywhere else.** And when SSR shows nothing for a reflection of something off-screen — be at peace. Every shipped game you admire has the same hole; they just fade it well.

## Build

1. **Wet-deck material hook.** Give SSR something to reflect off: a `wetness` uniform (driven by the ch47 Weather block — rain raises it, sun dries it) that, in the geometry pass, lerps deck/prop roughness down toward ~0.1 and darkens albedo slightly. Rain-slick world, still IBL-only reflections — the "before."

2. **SSR pass + target.** Half-res RGBA16F target `ssr` (color rgb + confidence in alpha). It runs *after* the lighting pass and forward ocean/sky (so the reflected image is complete), reading: scene HDR color, G-buffer depth + normal + roughness. Skip pixels with `roughness > 0.6` or sky depth — write confidence 0.

3. **The march.** Core of `ssr.frag`:

   ```glsl
   vec3 P = view_pos_from_depth(v_uv, depth);
   vec3 N = normalize(mat3(u_view) * gbuffer_normal);
   vec3 R = normalize(reflect(normalize(P), N));

   float t = u_step0;                 // ~0.1
   vec3 prev = P;
   for (int i = 0; i < 48; i++) {
       vec3 s = P + R * t;
       vec3 uvz = project_to_uv_depth(s);          // proj, /w, *0.5+0.5
       if (any(lessThan(uvz.xy, vec2(0))) || any(greaterThan(uvz.xy, vec2(1)))) break;
       float scene_z = view_z_from_depth(texture(u_depth, uvz.xy).r);
       if (s.z < scene_z && scene_z - s.z < u_thickness) {
           // refine between prev and s with 5 binary-search halvings, then:
           frag = vec4(texture(u_scene, hit_uv).rgb, confidence(hit_uv, R, t));
           return;
       }
       prev = s; t *= u_step_growth;  // ~1.12: geometric — fine near, coarse far
   }
   frag = vec4(0);
   ```

   (View space looks down −z: "ray behind surface" is `s.z < scene_z`.) Start the ray at `P + N * 0.05` to dodge self-intersection. The two helpers:

   ```glsl
   vec3 project_to_uv_depth(vec3 view_p) {
       vec4 c = u_proj * vec4(view_p, 1.0);
       return c.xyz / c.w * 0.5 + 0.5;          // uv in xy, depth in z
   }

   float confidence(vec2 hit_uv, vec3 R, float ray_len) {
       vec2 e = min(hit_uv, 1.0 - hit_uv);                       // dist to edges
       float edge   = smoothstep(0.0, 0.1, min(e.x, e.y));
       float facing = 1.0 - smoothstep(0.0, 0.5, R.z);           // toward camera
       float dist   = 1.0 - smoothstep(0.5, 1.0, ray_len / u_max_dist);
       return edge * facing * dist;
   }
   ```

4. **Composite.** In a small fullscreen pass (or folded into the deferred lighting shader on a second iteration): bilinearly sample `ssr` and build the chain, weighted so reflections obey ch42's physics:

   ```glsl
   vec4  s     = texture(u_ssr, v_uv);                          // rgb + confidence
   float ssr_w = s.a * (1.0 - smoothstep(0.4, 0.6, roughness)); // confidence × gate
   vec3  env   = mix(prefiltered, s.rgb, ssr_w);                // swap radiance source
   vec3  specular = env * (F * brdf.x + brdf.y);                // ch43 envelope, unchanged
   ```

   — the *same* Fresnel/BRDF envelope multiplies either source; only where the radiance comes from changes, so rough surfaces degrade to exactly ch43's look. The ocean shader: untouched.

5. **Sea-plane exemption.** The ocean is forward and never in the G-buffer, so SSR naturally skips it — verify this (it's free correctness), and note the chain happening across one frame: deck = SSR, sea = planar, rough rock = IBL.

6. **Tune on three shots.** (a) Wet deck, mast against sunset: mast reflection lands, slides off-screen *gently* on camera turn. (b) Lantern row at night on wet planks: smears of light. (c) Look straight down a wet hull at the horizon: rays exit screen instantly — should degrade to IBL, not black. Panel sliders: thickness, step0, growth, max steps, plus SSR-only debug view (rgb = color, or visualize confidence as heat).

7. **Cost check.** Half-res, 48 steps, early-out: expect ~0.5–1.5 ms. Full-res comparison once, for your own eyes, then back to half.

## Checkpoint

After a rain squall at sunset, the deck mirrors mast, sail, and sky; turning the camera makes reflections fade — never pop — and the open sea looks exactly as good as it did in ch30.

- SSR debug view: confident (hot) on smooth wet surfaces facing reflectable content; zero on sky, ocean, rough rock, and rays leaving the screen.
- The mast's reflection in the deck *tracks correctly* as you walk the camera — parallax right, not a decal (reconstruction + projection healthy).
- Thickness sanity: rigging ropes don't smear 50 m streaks (too thick) and the hull's reflection isn't venetian-blinds (too thin).
- RenderDoc pixel history on a deck pixel: G-buffer write → lighting → SSR composite, with the SSR pass reading the *completed* HDR frame.

## Pitfalls

- **Reflections of the backs of things / streaks from silhouettes.** Thickness too large, or no binary refinement — the coarse hit lands past thin geometry. Refine, then tune thickness *last*, after step size.
- **Self-reflection acne — surface reflects itself as noise.** Ray starts exactly on the surface. Offset along the normal, and/or skip the first march step.
- **Everything reflects, even dry rough wood.** You forgot the roughness gate and Fresnel weighting in the composite — SSR color must be *weighted like specular*, not added like emissive.
- **Reflections double-image or shear.** Space mismatch: normal left in world space while P is view space (or `project_to_uv_depth` uses proj×view on a view-space point). One space per shader, asserted in a comment at the top.
- **Banding rings on flat surfaces.** Coarse steps visible: too few steps or growth too aggressive. More steps, gentler growth, or jitter the start `t` per pixel by a hash of `gl_FragCoord` (preview of ch59's dithering trick).
- **It works, but the panel says 4 ms.** Full-res march, or no early-outs (sky/rough pixels must exit before the loop). Half-res + gates first; only then argue with step counts.

## Exercises

1. Confidence-as-heatmap debug view, permanently in the panel rotation: red = SSR, blue = fallback. Sail at sunset and *watch the chain negotiate*, surface by surface.
2. Roughness-aware sampling (sidebar): bind the bloom chain's blur levels and select by roughness. Glossy-but-not-mirror lantern light on wet wood is the payoff shot.
3. Temporal cheapening: march only half the pixels each frame in a checkerboard and fill the rest from neighbors. Measure, and note where it falls apart (fast pans).
4. **Stretch:** implement McGuire & Mara's actual contribution — marching in *screen space* with a perspective-correct DDA so each step advances exactly one pixel (or N pixels), eliminating both over- and under-sampling of the view-space march. Compare quality at equal step counts. The paper's code is famously readable.

## Commit

`git commit -m "ch58: screen-space reflections — depth raymarch with refinement, confidence fades, SSR->planar->IBL chain"`

[← Ch. 57: Shadows Far and Near](ch57-shadows-far-and-near.md) · [Ch. 59: Shafts of Light →](ch59-shafts-of-light.md)
