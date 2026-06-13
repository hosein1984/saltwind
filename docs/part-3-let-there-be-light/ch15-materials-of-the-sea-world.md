# Chapter 15 — Materials of the Sea-World

*Part 3 — Let There Be Light · Estimated time: 2.5h · learnopengl: [Materials](https://learnopengl.com/Lighting/Materials), [Light casters](https://learnopengl.com/Lighting/Light-casters), [Multiple lights](https://learnopengl.com/Lighting/Multiple-lights)*

**What you'll see when done:** dusk on the water — the distant sun still rakes the crates, while a warm lantern on a buoy pools orange light that fades with distance.

## Where we are

Chapter 14 hard-coded one light and one set of reflection constants into the fragment shader. Every object is equally shiny, and the only light in the universe is the sun. This chapter splits the hard-coded numbers into two clean ideas — *what the surface is* (a `Material`) and *what's illuminating it* (lights of different types) — and teaches the shader to sum several lights at once.

## Concepts

### Material: what a surface is made of

Pull the magic constants out of the shader and name them:

| Field | Meaning | Crate | Brass lantern |
|---|---|---|---|
| `ambient` | tint under ambient fill | dim wood brown | dim gold |
| `diffuse` | the main perceived color | wood brown | gold |
| `specular` | color/strength of the glint | gray, weak | bright yellowish |
| `shininess` | highlight tightness | 16 | 128 |

This ambient/diffuse/specular split is the classic Phong material, and you should know now: it's a *phenomenological* model — numbers tuned to look right, not physics. In Chapter 42 we'll replace it wholesale with PBR's metallic/roughness parameters, which are grounded in measurable properties. Phong is still worth learning properly: it's simpler, it runs anywhere, and PBR will make far more sense as a *correction* to Phong than as a starting point.

One practical note from [Materials](https://learnopengl.com/Lighting/Materials): keep `ambient` roughly equal to `diffuse` (or just derive it) — independent ambient colors are a knob almost nobody needs.

### Light types: the sun is not a lantern

A **directional light** (the sun) has a direction, constant everywhere, no falloff. A **point light** (the lantern) has a *position*, shines in all directions, and gets weaker with distance. Real light follows an inverse-square law, but pure `1/d²` looks harsh in non-HDR rendering, so the classic trick ([Light casters](https://learnopengl.com/Lighting/Light-casters)) is a tunable rational falloff:

```
attenuation = 1 / (Kc + Kl·d + Kq·d²)
```

`Kc` is almost always 1.0 (stops the value exceeding 1 near the source); `Kl` (linear) dominates at mid range; `Kq` (quadratic) kills the light at the far end. The learnopengl table is a good starting point — for a lantern that reaches ~50 m: `Kc=1.0, Kl=0.09, Kq=0.032`. Once we're HDR in Chapter 40, you can graduate to honest `1/d²`.

The per-light computation otherwise *is* Chapter 14's math, with one change: for a point light, `L` is no longer a constant uniform but `normalize(light_pos - frag_pos)`, recomputed per fragment.

### Many lights: just add them up

Light is linear — the contribution of each source simply adds. So the fragment shader becomes:

```
color = dir_light_contribution
for each point light: color += point_light_contribution(i)
color *= albedo
```

We use a fixed-size array plus a count uniform: GLSL 330 has no dynamic arrays, and re-linking shaders per light count is misery. `MAX_POINT_LIGHTS 8` costs nothing when count is 1 — the loop bound is a uniform, and unused array slots are never read.

### Struct uniforms in GLSL

GLSL lets you group uniforms in structs and arrays, but understand what's underneath: **there is no "set the struct" call.** Each leaf member is its own uniform with its own location, addressed by a dotted string:

```
"material.diffuse"
"point_lights[1].position"
```

You query and set them individually, exactly like any other uniform. A struct that is never used in computing the shader's output gets optimized away entirely, and its members report location −1 — make your `shader_set_*` helpers tolerate that quietly (a debug log at most, never a crash).

## Odin notes

Building those dotted, indexed uniform names every frame wants formatted *cstrings*, since `gl.GetUniformLocation` takes a `cstring`. `core:fmt` has exactly the tool: `fmt.ctprintf`, which formats into the temp allocator and returns a `cstring` — no manual `delete` needed if you free `context.temp_allocator` per frame (you set that up in Chapter 10):

```odin
name := fmt.ctprintf("point_lights[%d].position", i)
loc  := gl.GetUniformLocation(shader.id, name)
```

If your existing `shader_set_vec3` takes a `cstring` name, it composes perfectly with `ctprintf`.

## Build

1. **Define the types** in a new `src/lighting.odin`:

   ```odin
   Material :: struct {
       ambient:   glsl.vec3,
       diffuse:   glsl.vec3,
       specular:  glsl.vec3,
       shininess: f32,
   }

   Dir_Light :: struct {
       direction: glsl.vec3,
       color:     glsl.vec3,
   }

   Point_Light :: struct {
       position:    glsl.vec3,
       color:       glsl.vec3,
       constant:    f32,   // Kc
       linear:      f32,   // Kl
       quadratic:   f32,   // Kq
   }
   ```

   Add a couple of named constants: `MATERIAL_WOOD`, `MATERIAL_BRASS`, `MATERIAL_DEFAULT`.

2. **Mirror them in `lit.frag`** and write one function per light type. The point-light function is the new material:

   ```glsl
   #define MAX_POINT_LIGHTS 8

   struct Material { vec3 ambient; vec3 diffuse; vec3 specular; float shininess; };
   struct Point_Light {
       vec3 position; vec3 color;
       float constant; float linear; float quadratic;
   };

   uniform Material    material;
   uniform Point_Light point_lights[MAX_POINT_LIGHTS];
   uniform int         point_light_count;

   vec3 calc_point_light(Point_Light light, vec3 N, vec3 V, vec3 frag_pos) {
       vec3  L    = normalize(light.position - frag_pos);
       float diff = max(dot(N, L), 0.0);
       vec3  R    = reflect(-L, N);
       float spec = pow(max(dot(V, R), 0.0), material.shininess);

       float d   = length(light.position - frag_pos);
       float att = 1.0 / (light.constant + light.linear * d + light.quadratic * d * d);

       return att * light.color *
              (diff * material.diffuse + spec * material.specular);
   }
   ```

   Refactor Chapter 14's sun math into a matching `calc_dir_light`, then in `main`:

   ```glsl
   vec3 result = calc_dir_light(sun, N, V);
   for (int i = 0; i < point_light_count; i++) {
       result += calc_point_light(point_lights[i], N, V, v_world_pos);
   }
   frag_color = vec4(result * texture(u_texture, v_uv).rgb, 1.0);
   ```

3. **Write the upload procs**: `material_apply(shader, mat)` sets the four `material.*` uniforms; `point_lights_apply(shader, lights: []Point_Light)` loops with `fmt.ctprintf` for the five members each and sets `point_light_count` via `shader_set_i32`. Clamp to `MAX_POINT_LIGHTS` defensively.

4. **Build the lantern buoy.** Place a small sphere (the lantern glass) on top of one of your floating crates, drawn with an *emissive cheat*: a separate tiny shader (or a `u_unlit` flag uniform) that outputs plain bright color, so the lantern itself glows rather than being lit. Add a `Point_Light` at the same position: warm color `{1.0, 0.6, 0.25}`, the 50 m attenuation constants above.

5. **Drive it per frame.** Sun stays as before; lantern position follows the crate it sits on (it bobs in Chapter 19). Set materials per object before each draw — wood for crates, brass for the lantern's metal cage if you model one.

6. **Tune at dusk.** Drop `sun_color` to something low and red. The lantern only reads when the sun isn't washing it out — this is your first taste of light *balancing*, the actual daily work of rendering.

## Checkpoint

A dim red-orange sun grazes the scene; one crate carries a glowing lantern that throws warm light onto its own lid and the neighboring crate, visibly fading on the crate two positions away.

- Walk the camera toward the lantern: the lit pool on the sea-adjacent crates stays put (lighting is in world space); only the specular glints move.
- Set `point_light_count = 0` at runtime: lantern light vanishes, glowing sphere remains (emissive is separate from lighting).
- Double `quadratic`: the pool of light visibly tightens.

## Pitfalls

- **`GetUniformLocation` returns −1 for the whole struct name.** Expected — you can only address leaf members like `material.diffuse`, never `material`.
- **Everything works until you add the loop, then the point light is black.** Classic: you declared the array but set uniforms with the wrong index string (`point_light[0]` vs `point_lights[0]`). Print the locations once; −1 means name mismatch.
- **The lantern lights the whole ocean uniformly.** Attenuation constants still zero — `1/(0+0+0)` is undefined and many drivers give you 1.0 everywhere (or NaN black). `constant` must be ≥ 1.
- **Lantern looks right up close but the scene dims when it's far away.** You multiplied *ambient* by attenuation too and there's a global ambient inside the point-light function. Keep scene ambient in the directional light only.
- **Shader edits do nothing.** You're editing `lit.frag` but the lantern sphere uses the unlit shader — hot-reload both.

## Exercises

1. Flicker: modulate the lantern's color by `0.85 + 0.15 * math.sin(7.3 * t) * math.sin(13.1 * t)` — two incommensurate sines read as fire.
2. Add a second lantern with a cold blue-white color on a far crate; balance both attenuations so their pools just barely overlap.
3. Make `material_apply` cache the last-applied material per shader and skip redundant `gl.Uniform*` calls. Measure with a frame counter whether it matters yet (it won't — but the pattern will).
4. **Stretch:** Add a spotlight type (`cutoff`, `outer_cutoff`, the `smoothstep` cone edge from [Light casters](https://learnopengl.com/Lighting/Light-casters)) and mount it high as a lighthouse beam sweeping the horizon with `math.sin(t)`.

## Commit

`git commit -m "ch15: materials, point lights, multi-light shader"`

← [Chapter 14 — One Sun](ch14-one-sun.md) · [Chapter 16 — Honest Colors](ch16-honest-colors.md) →
