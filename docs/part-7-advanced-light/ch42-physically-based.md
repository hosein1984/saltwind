# Chapter 42 — Physically Based

*Part 7 — Advanced Light · Estimated time: 6–8h · learnopengl: [PBR Theory](https://learnopengl.com/PBR/Theory), [PBR Lighting](https://learnopengl.com/PBR/Lighting), [Normal Mapping](https://learnopengl.com/Advanced-Lighting/Normal-Mapping)*

**What you'll see when done:** the boat's brass lantern fittings look like metal, its painted hull looks like paint, wet wood looks wet — under the same sun, with no per-material hacks.

## Where we are

Phong has carried you 41 chapters, and its sins are now visible in HDR: specular highlights whose size and brightness are unrelated knobs, materials that gain energy at glancing angles, "shininess 32" meaning nothing physical. Physically based rendering replaces Phong's ad-hoc terms with a model where parameters mean real things — *how rough is this surface? is it a metal?* — and materials look right under any light. This is the longest theory section in the course. Pour something; take it slow; it's worth owning.

## Concepts

### Radiance and irradiance, in human terms

- **Radiance** (L): how much light arrives *along one ray* — from one direction, onto one point. "How bright does the sun look from here."
- **Irradiance** (E): all the radiance arriving at a point from *every* direction on the hemisphere above it, summed. "How much total light lands on this patch of deck."

The rendering equation says: outgoing radiance toward your eye = for every incoming direction, take incoming radiance, multiply by the **BRDF** (the function saying how much of light from direction A scatters toward direction B) and by the geometric `cos θ` term, and add it all up. For direct lighting we cheat beautifully: the sun is *one* direction and a point light is *one* direction per light, so the integral collapses into a sum over lights. (Chapter 43 tackles the actual integral, for light arriving from the whole sky.)

### Microfacets: roughness is geometry too small to see

Every real surface is a landscape of microscopic mirrors. On a smooth surface they're aligned, so reflections are tight and sharp; on a rough surface they point everywhere, so reflections smear out. One parameter — **roughness** ∈ [0,1] — statistically describes that landscape. This replaces Phong's shininess with something you can reason about: brushed brass ≈ 0.4, varnished hull ≈ 0.15, weathered rope ≈ 0.9.

```
 smooth (r=0.1)            rough (r=0.8)
 ---__---__---             /\_/‾\_/\/‾\
 highlights: tight,        highlights: broad,
 bright, mirror-like       dim, diffuse-ish
```

### Energy conservation and the metallic split

A surface cannot reflect more light than it receives. Whatever bounces off specularly (`kS`) is *not available* to be absorbed-and-rescattered diffusely (`kD`): `kD = 1 - kS`. Phong ignored this; PBR enforces it, which is why PBR materials hold up at every sun angle.

The second big idea is the **metallic workflow**. Physically, there are two kinds of surface:

- **Dielectrics** (wood, paint, rope, water): tint their *diffuse* light with albedo; their specular reflection is colorless, around 4% at normal incidence (`F0 ≈ vec3(0.04)`).
- **Metals**: no diffuse at all (free electrons absorb refracted light); their specular *is* tinted — `F0 = albedo`, and it's strong (50–100%).

One `metallic` parameter (0 or 1, with the in-betweens used for texel-blended transitions) selects between them:

```glsl
vec3 F0 = mix(vec3(0.04), albedo, metallic);
vec3 kD = (1.0 - F) * (1.0 - metallic);
```

### Cook-Torrance: D, G, F

The specular BRDF we implement is Cook-Torrance: `f_spec = D·G·F / (4·(N·V)·(N·L))`. Three factors, each answering one question about the microfacet landscape:

**D — GGX normal distribution.** *What fraction of microfacets point exactly the right way* (along the half vector `H = normalize(V + L)`) to bounce light from L into V? GGX's long tail is why its highlights have that realistic glow-then-fade instead of Phong's abrupt circle:

```glsl
float d_ggx(vec3 N, vec3 H, float roughness) {
    float a  = roughness * roughness;     // Disney remap: perceptual -> alpha
    float a2 = a * a;
    float ndh = max(dot(N, H), 0.0);
    float denom = ndh * ndh * (a2 - 1.0) + 1.0;
    return a2 / (PI * denom * denom);
}
```

**G — Smith geometry term.** *What fraction of those microfacets are actually visible* — not shadowed (light blocked on the way in) or masked (view blocked on the way out) by their neighbors? Rough surfaces at grazing angles lose a lot here:

```glsl
float g_schlick_ggx(float ndx, float roughness) {
    float r = roughness + 1.0;
    float k = (r * r) / 8.0;              // k for direct lighting
    return ndx / (ndx * (1.0 - k) + k);
}
float g_smith(vec3 N, vec3 V, vec3 L, float roughness) {
    return g_schlick_ggx(max(dot(N, V), 0.0), roughness)
         * g_schlick_ggx(max(dot(N, L), 0.0), roughness);
}
```

**F — Schlick Fresnel.** *How reflective is the surface at this viewing angle?* Everything becomes a mirror at grazing incidence — you proved this on the ocean in ch29; the same equation now serves every material:

```glsl
vec3 f_schlick(float cos_theta, vec3 F0) {
    return F0 + (1.0 - F0) * pow(clamp(1.0 - cos_theta, 0.0, 1.0), 5.0);
}
```

### The full direct-lighting loop

Per light (sun + your lanterns), in linear HDR space — this is the heart of the chapter:

```glsl
vec3 pbr_direct(vec3 N, vec3 V, vec3 L, vec3 radiance,
                vec3 albedo, float metallic, float roughness) {
    vec3 H = normalize(V + L);
    vec3 F0 = mix(vec3(0.04), albedo, metallic);

    float D = d_ggx(N, H, roughness);
    float G = g_smith(N, V, L, roughness);
    vec3  F = f_schlick(max(dot(H, V), 0.0), F0);

    vec3 specular = (D * G * F)
        / (4.0 * max(dot(N, V), 0.0) * max(dot(N, L), 0.0) + 1e-4);

    vec3 kD = (vec3(1.0) - F) * (1.0 - metallic);
    float ndl = max(dot(N, L), 0.0);
    return (kD * albedo / PI + specular) * radiance * ndl;
}
```

Note the `albedo / PI`: Lambertian diffuse normalized so it doesn't emit more than it receives. Note also there's no `pow(..., shininess)` anywhere, no separate specular color, no ambient — ambient becomes IBL next chapter (use a small constant `vec3(0.03) * albedo` as a placeholder until then).

### The texture set

PBR materials ship as texture sets sampled per fragment: **albedo** (sRGB — decode it!), **metallic** (linear, single channel), **roughness** (linear, single channel — often packed into one RGB texture with metallic and AO), **normal** (linear, tangent space), optional **AO** (linear; multiplies the ambient term only). Free CC0 sets at [polyhaven.com](https://polyhaven.com/textures) and [ambientcg.com](https://ambientcg.com) — grab a wood, a rope, and a metal for the boat.

### Normal mapping and TBN (required equipment)

PBR's tight highlights are wasted on per-vertex normals — you need normal maps, so you need **tangent space**. A normal map stores normals relative to the surface: +Z out of the surface, +X along increasing U, +Y along increasing V. To use one you build a per-vertex basis — **T**angent (the direction U grows in 3D), **B**itangent, **N**ormal — and transform sampled normals into world space with the `mat3(T, B, N)`.

Tangents come from the UV layout. For a triangle with edges `e1, e2` (positions) and UV deltas `(du1,dv1), (du2,dv2)`, solve the 2×2 system:

```odin
// per triangle, accumulated into each vertex then normalized
r := 1.0 / (du1 * dv2 - du2 * dv1)
tangent := glsl.vec3{
    r * (dv2 * e1.x - dv1 * e2.x),
    r * (dv2 * e1.y - dv1 * e2.y),
    r * (dv2 * e1.z - dv1 * e2.z),
}
```

In the vertex shader, orthonormalize with Gram-Schmidt and build the matrix:

```glsl
vec3 T = normalize(mat3(u_model) * a_tangent);
vec3 N = normalize(mat3(u_normal) * a_normal);
T = normalize(T - dot(T, N) * N);
vec3 B = cross(N, T);
v_tbn = mat3(T, B, N);
```

Fragment side: `vec3 n = texture(u_normal_map, v_uv).rgb * 2.0 - 1.0; N = normalize(v_tbn * n);`.

## Odin notes

Extending `Vertex` ripples through the codebase — this is why we standardized it. Add `tangent: glsl.vec3` to `Vertex`, bump the attribute setup in `mesh_upload` (`offset_of(Vertex, tangent)`, attribute index 3), and every existing mesh keeps working because untouched shaders simply ignore attribute 3. Compute tangents in the OBJ loader (ch17) after faces are assembled: accumulate per-triangle tangents into shared vertices, normalize at the end — same pattern as your smooth-normal accumulation. For procedural meshes that won't be normal-mapped (ocean grid), write any unit vector; it's never read.

## Build

1. **Extend `Vertex` and the loader.** Add the `tangent` field, the vertex-attrib pointer, and the accumulation loop in `obj_load`. Verify nothing regresses (everything still draws) before touching shaders.

2. **A `Material` type.**

   ```odin
   Material :: struct {
       albedo_tex, normal_tex, metallic_tex, roughness_tex, ao_tex: u32,
       // fallback factors when a map is absent (bind a 1x1 white/flat texture)
       albedo_factor:    glsl.vec3,
       metallic_factor:  f32,
       roughness_factor: f32,
   }
   ```

   Create 1×1 default textures once (white, flat-normal `(128,128,255)`, etc.) so one shader handles textured and untextured materials uniformly — factors multiply samples.

3. **`pbr.vert` / `pbr.frag`.** Vertex: standard MVP + world position + TBN out + light-space position (shadows still apply!). Fragment: sample the five maps, decode albedo from sRGB (or use `gl.SRGB8_ALPHA8` internal format and let GL do it, as in ch16), build N from TBN, then loop:

   ```glsl
   vec3 Lo = vec3(0.0);
   // sun (directional): radiance = sun color, shadowed
   Lo += shadow * pbr_direct(N, V, -u_sun_dir, u_sun_radiance,
                             albedo, metallic, roughness);
   // lanterns (points): attenuate by inverse-square — physically correct,
   // now sane because HDR can represent the hot core
   for (int i = 0; i < u_point_count; ++i) {
       vec3 to_l = u_point_pos[i] - v_world_pos;
       float dist2 = dot(to_l, to_l);
       vec3 radiance = u_point_color[i] / max(dist2, 0.01);
       Lo += pbr_direct(N, V, normalize(to_l), radiance,
                        albedo, metallic, roughness);
   }
   vec3 ambient = vec3(0.03) * albedo * ao;   // placeholder until ch43
   frag = vec4(ambient + Lo, 1.0);
   ```

   Output linear HDR — no gamma here, per ch40 law.

4. **Convert the boat and buoys.** Assign materials: hull = painted wood (albedo map, roughness ~0.3 where painted), deck = bare wood (roughness ~0.7), lantern fittings = brass (metallic 1.0, roughness 0.35), buoys = worn painted metal. If your OBJ has material groups from ch17, map group → `Material`; otherwise split the draw by mesh part. **Terrain stays Phong** — converting it is an exercise; mixed pipelines are normal mid-migration and the visual mismatch is smaller than you fear.

5. **Inverse-square attenuation.** Replace the ch15 constant/linear/quadratic attenuation for lanterns with pure `1/d²` (clamped) as above — with HDR + PBR this is both simpler and correct.

6. **Sanity scene.** Before judging the boat, render a debug row of 7 spheres (your ch11 sphere mesh), roughness 0→1 left to right, one row metallic 0 and one metallic 1, all white albedo. This is the standard PBR calibration ritual; learnopengl's [Lighting](https://learnopengl.com/PBR/Lighting) page shows what it should look like. If the spheres are right, the boat will be right.

## Checkpoint

The sphere rows show: dielectric row with a white highlight tightening as roughness drops, body color constant; metal row with *no* diffuse body, reflections tinted by albedo, going mirror-tight at low roughness. On the boat: the brass lantern cap catches a warm tinted gleam, the hull's paint shows a soft sheen at grazing angles, rope is matte but not dead.

- Roughness 0 sphere: tiny intense highlight; roughness 1: broad dim sheen — and total brightness *feels* conserved across the row.
- Look along the hull toward the sun: Fresnel brightens the paint at grazing angle, like the ocean does.
- Normal maps: wood grain catches light directionally; toggle the normal map (bind flat default) to confirm the difference.
- Shadows from ch39 still land on PBR surfaces.

## Pitfalls

- **Black specular everywhere.** Division by zero in the BRDF — you forgot the `+ 1e-4` in the denominator, or `roughness` is exactly 0 (clamp your roughness to ≥ 0.025).
- **Metals look black.** Correct-ish, actually — metals have no diffuse, and you have no environment yet. Until ch43's IBL, metals only show direct highlights. Don't "fix" this; finish ch43.
- **Everything too dark vs Phong.** The `albedo / PI` is new energy bookkeeping; compensate by raising sun radiance (it's HDR — let it be 5–10), not by deleting the π.
- **Highlights are square-ish or banded.** Albedo texture not decoded from sRGB (doing BRDF math on gamma values), or normal map *was* decoded as sRGB (it must be linear — internal format `RGBA8`, not `SRGB8_ALPHA8`).
- **Normal-mapped lighting looks inverted in one axis.** Your normal map's green channel convention (OpenGL vs DirectX) — flip `n.y` after decode and see which looks right.
- **Seams or shading discontinuities on the hull.** Mirrored UVs flip the tangent handedness. Quick fix: where it shows, re-export the model without mirrored UVs; proper fix: compute and store a handedness sign (w component of tangent) — fine to defer.

## Exercises

1. Add a debug uniform that overrides metallic/roughness with slider-controlled constants for the whole boat (your ch48 panel will make this nicer; keys for now). Material dialing teaches faster than reading.
2. Convert the **terrain** to PBR: albedo from your splat layers, roughness from a per-layer constant (sand 0.55, grass 0.8, rock 0.75), metallic 0. Notice how wet sand at the shoreline (lerp roughness toward 0.1 near sea level) suddenly reads as *wet*.
3. Give the lantern an emissive term: a sixth map (or factor) added to the fragment output *after* lighting. Bloom (ch41) picks it up automatically.
4. **Stretch:** implement the AO map properly through your pipeline (multiply ambient only — watch how multiplying *direct* light by AO deadens the image, then put it back where it belongs).

## Commit

`git commit -m "ch42: Cook-Torrance PBR with metallic/roughness materials and normal mapping"`

[← Ch. 41: The Sun Bleeds](ch41-the-sun-bleeds.md) · [Ch. 43: Light from Everywhere →](ch43-light-from-everywhere.md)

> ⚓ **Optional side quest:** [Interlude 42a — Depth in the Planks](ch42a-depth-in-the-planks.md) — parallax occlusion mapping carves grooves into the deck that the geometry doesn't have.
