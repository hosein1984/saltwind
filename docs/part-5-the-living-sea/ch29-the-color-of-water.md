# Chapter 29 — The Color of Water

*Part 5 — The Living Sea & Sky · Estimated time: 3h · learnopengl: [Cubemaps — environment mapping](https://learnopengl.com/Advanced-OpenGL/Cubemaps)*

**What you'll see when done:** the gray rubber of Chapter 28 becomes *water* — deep blue beneath you, a mirror of the sky toward the horizon, and a glittering path of sun sparkles stretching across the swells.

## Where we are

The geometry rolls correctly, but the shading is still Chapter 24's flat-plane logic: up-facing normals, a constant blue. Water gets its identity from three things this chapter adds — true normals derived from the wave math, Fresnel reflectance, and a reflected sky. The sky part is why Chapter 27 mattered: a procedural sky is a *function* `sky_color(direction)`, so the water can evaluate it for any reflection ray without rendering anything extra.

## Concepts

### Analytic normals: differentiate, don't approximate

You could estimate normals by sampling the wave height at three nearby points and crossing the differences — three times the cost and blurry. Better: the Gerstner sum is a closed-form function, so differentiate it. GPU Gems chapter 1 gives the result for the normal at a *displaced* point (using `k = 2π/λ`, `q` per wave as in Chapter 28, `θ` as before):

```
N.x = − Σᵢ Dᵢ.x · kᵢAᵢ · cos(θᵢ)
N.z = − Σᵢ Dᵢ.y · kᵢAᵢ · cos(θᵢ)
N.y =  1 − Σᵢ qᵢ · kᵢAᵢ · sin(θᵢ)
```

Intuition check: with no waves, `N = (0,1,0)`. The x/z terms are just the negated slope of the height function; the y term shrinks below 1 near crests because the horizontal pinching tilts the surface harder than height alone suggests. Note the same steepness budget appears again: if `Σ qᵢkᵢAᵢ` exceeded 1, `N.y` would go negative at crests — folded geometry, folded normals.

Compute this in the **vertex shader** (same loop, same uniforms, three extra accumulators) and pass it down interpolated. Per-fragment evaluation is a nice-to-have for very large waves; the detail normal map below hides the difference.

### Fresnel: water is a mirror, edge-on

Look straight down into a harbor: you see bottom, or dark water. Look across it toward the horizon: you see sky, almost perfectly mirrored. Reflectivity rising toward grazing angles is the **Fresnel effect**, and the cheap, industry-standard approximation is Schlick's:

```glsl
F = F0 + (1.0 - F0) * pow(1.0 - cos_theta, 5.0);    // cos_theta = dot(N, V)
```

`F0` is reflectance looking straight on. For water it's tiny: **≈ 0.02** (2%). That single constant is doing real physics — it comes from water's index of refraction (1.33) via `F0 = ((n−1)/(n+1))²`. The fifth power makes the curve hug 0.02 for most angles, then rocket to 1.0 in the last 20 degrees. Water's whole look — dark here, silver there — is this curve.

### Reflecting a function instead of a texture

learnopengl's [environment mapping](https://learnopengl.com/Advanced-OpenGL/Cubemaps) samples a cubemap with `reflect()`. We do the same thing, but our "environment" is the `sky_color()` function from Chapter 27 — cheaper, always in sync with the time of day, and no seams. The reflection vector is:

```glsl
vec3 R = reflect(-V, N);   // V = normalize(view_pos - world_pos)
```

One practical guard: a wave-tilted normal can produce an `R` pointing slightly *below* the horizon, where the sky function has nothing meaningful. Folding it up (`R.y = abs(R.y)` or `max(R.y, 0.02)`) is the standard cheat until Chapter 30 gives you real reflections of islands.

### Sun glitter

The dancing sparkle path under a low sun is just Blinn-Phong specular with absurd shininess (hundreds), made *broken-up* by high-frequency normal detail that the Gerstner waves are too smooth to provide. The detail comes from a small tiling **normal map** scrolled in two directions at once — a 30-line addition that buys more realism per line than anything else in this part.

## Odin notes

The sky function must exist in two shaders (sky.frag, water.frag) without copy-paste drift. GLSL 330 has no `#include`, so add one — a 15-line preprocessor in your shader loader. Read the file with `core:os`, splice with `core:strings`, and compile with `gl.load_shaders_source` (the string-based sibling of `load_shaders_file`):

```odin
load_shader_source :: proc(path: string) -> (src: string, ok: bool) {
    data := os.read_entire_file(path) or_return
    text := string(data)
    INCLUDE :: "//#include \"sky_common.glsl\""
    if !strings.contains(text, INCLUDE) do return text, true
    common := os.read_entire_file("assets/shaders/sky_common.glsl") or_return
    defer delete(common)
    text, _ = strings.replace(text, INCLUDE, string(common), 1)
    return text, true
}
```

The directive doubles as a comment, so shader files stay valid for any external GLSL tooling. Generalizing to arbitrary filenames is a fine exercise; one hardcoded include is honestly all Saltwind ever needs.

## Build

1. **Extract `assets/shaders/sky_common.glsl`.** Move the entire `sky_color(vec3 dir, vec3 sun_dir)` function out of `sky.frag` into the new file; replace it in `sky.frag` with the include directive. Route both sky and water shaders through the new `load_shader_source` path. Verify the sky still renders before touching water.

2. **Add normals to `water.vert`.** Extend the Gerstner loop — same `k`, `theta`, `q` per wave:

   ```glsl
   vec3 n = vec3(0.0, 1.0, 0.0);
   for (int i = 0; i < 4; i++) {
       // ... k, theta, q exactly as in gerstner_offset ...
       float ka = k * u_waves[i].amplitude;
       n.x -= u_waves[i].direction.x * ka * cos(theta);
       n.z -= u_waves[i].direction.y * ka * cos(theta);
       n.y -= q * ka * sin(theta);          // starts at 1.0, shrinks at crests
   }
   v_normal = n;   // normalize in the fragment shader, after interpolation
   ```

   Evaluate it at the same `world.xz` you displaced from. (Merging this into one loop with `gerstner_offset` is tidier; keep the `// MIRRORS` comment honest.)

3. **Get a detail normal map.** Any small tiling water-ripple normal map works — [OpenGameArt](https://opengameart.org/) has several CC0 ones (search "water normal map"). Load it like any Chapter 6 texture (linear, *not* SRGB — normal maps are data, not color), wrap `REPEAT`, into `assets/textures/water_normal.png`.

4. **Rewrite `water.frag`.** The full pipeline, condensed to its spine:

   ```glsl
   //#include "sky_common.glsl"

   vec3 sample_detail(vec2 uv) {
       vec3 n = texture(u_detail, uv).rgb * 2.0 - 1.0;
       return vec3(n.x, n.z, n.y);              // tangent z-up -> world y-up
   }

   void main() {
       vec2 duv = v_world_pos.xz * 0.08;
       vec3 detail = sample_detail(duv + u_time * vec2(0.020, 0.013))
                   + sample_detail(duv * 1.7 - u_time * vec2(0.017, 0.026));
       vec3 N = normalize(normalize(v_normal) + detail * 0.18);
       vec3 V = normalize(u_view_pos - v_world_pos);
       vec3 L = u_sun_dir;                      // toward the sun (ch27 convention)

       float fresnel = 0.02 + 0.98 * pow(1.0 - max(dot(N, V), 0.0), 5.0);

       vec3 R = reflect(-V, N);
       R.y = abs(R.y);
       vec3 sky = sky_color(R, u_sun_dir);

       float depth_fade = clamp((u_view_pos.y + length(u_view_pos - v_world_pos)) / 120.0, 0.0, 1.0);
       vec3 body = mix(u_shallow_color, u_deep_color, depth_fade);

       vec3 col = mix(body, sky, fresnel);

       vec3 H = normalize(L + V);
       col += u_sun_color * u_sun_intensity
            * pow(max(dot(N, H), 0.0), 350.0) * 2.5;   // glitter
       frag_color = vec4(col, 1.0);
   }
   ```

   Starting colors: deep `{0.02, 0.08, 0.15}`, shallow `{0.05, 0.25, 0.30}` (set as uniforms from `Ocean`). The `depth_fade` here is a *view-distance* stand-in: water reads darker and more mirror-like far away, lighter near the camera. True terrain-depth shallows (sand visible through water) need the refraction pass — that's Chapter 30; if your Chapter 24 shoreline tint still runs, keep whichever looks better this week.

5. **Wire the uniforms.** `u_sun_dir`, `u_sun_color`, `u_sun_intensity` come from `game.sky` (same values Phong gets — one sun). `u_view_pos` from the camera. Two texture units if your terrain splatting taught you multi-binding; here water needs just the detail map.

6. **Tune for ten minutes.** Detail strength `0.18`, glitter power `350`, glitter gain `2.5`, scroll speeds — all taste. Scrub time to ~17:30 and adjust until the glitter path looks like crushed glass, not a white stripe and not noise.

## Checkpoint

Look down: dark translucent blue. Look toward the horizon: the sky, mirrored, swells gently breaking the reflection. Look toward the low sun: a sparkling road of light pointing at you across the water.

- The Fresnel transition is visible *in one screenshot*: dark near the bottom of the frame, sky-bright near the horizon.
- The glitter path always points from the sun toward you, and it dances as waves pass (detail normals working).
- Scrub to noon: glitter becomes a tight hot spot below the sun; to night: water goes near-black with a faint sky sheen. No uniform changes needed — it all flows from `Sky`.
- Wave *shape* shading is visible: crest faces toward the sun are brighter than slopes facing away (analytic normals working).

## Pitfalls

- **Water looks like flat metal.** Normals are still `(0,1,0)` — you computed `v_normal` but forgot to write it, or normalized the unnormalized sum in the vertex shader and interpolation broke it anyway. Debug with `frag_color = vec4(N * 0.5 + 0.5, 1.0)` (your Chapter 14 trick): you should see wave-shaped rainbow ripples, not flat green.
- **Mirror everywhere, no dark water.** Fresnel inverted — you used `dot(N, V)` where you needed `1 − dot(N, V)` inside the `pow`, or F0 ended up near 1. Straight down should give almost exactly `body` color.
- **Glitter is a solid white bar.** Detail normal strength too low or the map didn't load (sampler reads black, `*2−1` gives a constant tilt). Also check the map isn't loaded as sRGB — that bends the vectors.
- **Sky reflection has a hard seam at wave tops.** Your `R.y` guard is `max(R.y, 0.0)` and the sky function misbehaves at exactly 0 — use `abs()` or clamp to a small positive value.
- **Two skies disagree** (reflection color ≠ sky above). The include splice failed silently and an old copy of `sky_color` lives in one shader. Make the loader `assert` the include succeeded.

## Exercises

1. Add a uniform `u_fresnel_power` and try 3.0 and 8.0 against 5.0. Schlick says 5; your eyes get a vote.
2. Tint the *reflected* sky slightly green-blue (`sky * vec3(0.9, 1.0, 0.95)`) — real water absorbs red even in the first bounce. Subtle but rich.
3. Drive detail-normal scroll speed and strength from a `u_wind_strength` uniform (hardcode 0.5 for now). Chapter 33's `Wind` struct will plug straight in.
4. **Stretch:** per-fragment Gerstner normals. Move the normal loop into the fragment shader, evaluated at `v_world_pos.xz`. Compare close-up crest shading against the interpolated version — then decide if it's worth four sin/cos per wave per fragment.

## Commit

`git commit -m "ch29: water shading - analytic normals, fresnel, sky reflection, glitter"`

← [Chapter 28 — Waves that Roll](ch28-waves-that-roll.md) · [Chapter 30 — Through the Looking Glass](ch30-through-the-looking-glass.md) →
