# Chapter 55 — The Deferred Fleet

*Part 9 — The Deep Engine · Estimated time: 8–10h · learnopengl: [Deferred Shading](https://learnopengl.com/Advanced-Lighting/Deferred-Shading)*

**What you'll see when done:** a hundred swaying lantern lights across a night harbor at a frame rate that would have made the forward renderer weep — and a debug view of your world decomposed into albedo, normals, and roughness.

## Where we are

Your renderer is *forward*: every opaque fragment shades against every light in one heroic shader. With one sun plus a handful of lanterns, that's correct and fast. This chapter breaks it on purpose — 100 lights, measured with your own ch49 timers — and then rebuilds the opaque world as a **deferred** renderer: a geometry pass that writes surface properties to a **G-buffer**, then lighting passes that read them back. The ocean, sky, and particles stay forward, and learning to run both halves in one frame is the real skill here. This is the biggest refactor of the course; the payoff carries Parts 9–12.

## Concepts

### First, the indictment (measure before believing)

Forward lighting cost ≈ `fragments × lights`. The terrain fills most of the screen; 100 lights means every one of those ~2M fragments evaluates 100 Cook-Torrance BRDFs — including lanterns 800 m away contributing 0.0000. Worse, fragments killed later by depth (overdraw — wave troughs behind islands, palm fronds) paid full price anyway. Deferred restructures the cost:

```
 forward:   fragments(with overdraw) × lights
 deferred:  fragments(with overdraw) × G-buffer write     (cheap, no lighting)
          + pixels actually covered by each light × BRDF  (the win)
```

Lighting becomes proportional to *screen area each light touches*. A far lantern touches 50 pixels; it costs 50 BRDFs total, not 2 million.

### The G-buffer: a frozen surface

The geometry pass runs your existing vertex work (and normal mapping) but instead of lighting, it *writes the BRDF's inputs* to multiple render targets (MRT — one FS, several `out` variables, one per attachment):

```
 RT0  RGBA8    | albedo.rgb              | metallic  |
 RT1  RGBA16F  | world normal.xyz        | roughness |
 RT2  RGBA16F  | emissive.rgb (HDR)      | (spare)   |
 D    D24S8    | depth — position is reconstructed from this
```

Notes on the choices: albedo is an LDR color, 8 bits is plenty; normals need sign and precision, so 16F (see the sidebar for the grown-up packing); emissive is HDR (lantern glass at intensity 30 must survive). The spare alpha will hold per-material AO when you want it. **No position attachment** — learnopengl starts with one for clarity, but storing 12 bytes/pixel of data you can recompute from depth is bandwidth you'll want back.

> **Sidebar — octahedral normals.** Production G-buffers pack the unit normal into two channels by mapping the sphere onto an unfolded octahedron: `n / (|x|+|y|+|z|)`, fold the lower hemisphere, store xy in RG16 — ~10 lines each way, near-uniform precision, RT1 shrinks to RG16F with roughness moved to a spare. See Cigolle et al., ["A Survey of Efficient Representations for Independent Unit Vectors"](https://jcgt.org/published/0003/02/01/) (JCGT 2014). Do it as the exercise; ship RGBA16F first — debuggability beats bytes while you're building.

### Position from depth — the reconstruction math

The depth buffer stores window-space depth `d ∈ [0,1]` at each pixel; together with the pixel's uv that's a full NDC coordinate, and NDC is just clip space divided by `w`. So run the projection backward:

```glsl
vec3 view_pos_from_depth(vec2 uv, float d) {
    vec4 ndc  = vec4(uv * 2.0 - 1.0, d * 2.0 - 1.0, 1.0);
    vec4 v    = u_inv_proj * ndc;   // back to view space, up to scale
    return v.xyz / v.w;             // the divide undoes perspective
}
// world: (u_inv_view * vec4(view_pos, 1.0)).xyz
```

Why the divide works: `proj * view_pos` gave clip = `(x,y,z,w)`; NDC was `clip/w`. Multiplying NDC (with w=1) by `inv_proj` yields `clip/w` mapped back — i.e. `view_pos / w` — and dividing by the resulting `.w` (which lands as `1/w`-scaled) restores it. Sanity-test it: output `view_pos_from_depth(...).z` as color; near should differ smoothly from far. Reconstruct in *view* space then transform to world — inverting `proj * view` in one matrix works too but compounds precision loss at archipelago distances.

### Two lighting passes

1. **Fullscreen pass — sun + IBL + emissive.** One fullscreen triangle (ch40's trick, third encore). For each pixel: read G-buffer, reconstruct position, run *exactly* your ch42/43 code — Cook-Torrance sun with the ch39 shadow, IBL ambient, add emissive. Pull the BRDF functions into a shared `#include` so forward and deferred can't drift apart.

2. **Light volumes — the point lights.** Each lantern only reaches `radius` meters (solve your attenuation for where it drops below ~1/256: with `1/(1 + kl·d + kq·d²)` that's `radius = (-kl + sqrt(kl² - 4·kq·(1 - 256/5)))/(2·kq)` — precompute on the CPU). Draw your ch11 procedural **sphere mesh**, scaled to that radius, with a fragment shader that reads the G-buffer and adds that one light's contribution, blended additively:

   ```odin
   gl.Enable(gl.BLEND); gl.BlendFunc(gl.ONE, gl.ONE)
   gl.DepthMask(false)
   gl.Disable(gl.DEPTH_TEST)      // simple & correct; see optimization below
   gl.CullFace(gl.FRONT)          // works even with the camera inside the volume
   for light in lights { /* set uniforms, draw sphere */ }
   gl.CullFace(gl.BACK); gl.DepthMask(true); gl.Enable(gl.DEPTH_TEST)
   ```

   Front-face culling means a light you're standing inside still rasterizes (its back shell is behind you... in front of the camera). With depth test off you shade some pixels where the volume covers sky or foreground — the in-shader radius check zeroes them, costing only bandwidth. The classic refinements — stencil-mark the volume's interior first (two passes, like ch38's outline trick), or just `gl.Scissor` to the light's screen rect — are profile-first optimizations; the panel will tell you if you need them at 100 lights (you likely won't).

### The hybrid frame — what stays forward and why

A G-buffer stores **one surface per pixel**. Transparency is *multiple* surfaces per pixel, blended — it cannot live there. Your most beautiful objects are transparent:

```
 shadow pass
 reflection / refraction FBOs (forward mini-frames, as ever)
 GEOMETRY pass ──► G-buffer            (terrain, boat, props, instances)
 (ch56 SSAO will slot here)
 LIGHTING ──► HDR target               (fullscreen sun+IBL, then volumes)
 FORWARD on top, same depth buffer:    sky (LEQUAL trick) → ocean → wake,
                                       particles, transparent bits
 bloom → tonemap → FXAA → UI
```

The crucial plumbing trick: **attach the G-buffer's depth texture as the HDR target's depth attachment too** (one texture, two FBOs — legal and standard). The forward pass then depth-tests against the opaque world for free: the ocean correctly hides behind islands, particles sort against the boat, no copies. MSAA, though, is gone — multisampled G-buffers explode bandwidth and per-sample lighting cost, which is exactly why ch54 gave you FXAA. The other honest costs: G-buffer bandwidth (~16 bytes/pixel written then read), and *material uniformity* — every deferred surface must describe itself in those four targets; exotic materials (toon, subsurface, cloth hacks) either pack a material-ID flag or stay forward.

## Odin notes

`gl.DrawBuffers` takes a count and pointer: build the list as a local array and pass `raw_data(bufs[:])` or `&bufs[0]` — `bufs := [3]u32{gl.COLOR_ATTACHMENT0, gl.COLOR_ATTACHMENT1, gl.COLOR_ATTACHMENT2}; gl.DrawBuffers(3, &bufs[0])`. And since GLSL 430 you can declare `layout(binding = 0) uniform sampler2D u_g_albedo;` etc. in the lighting shaders — bind-by-convention, no more `shader_set_i32("u_g_albedo", 0)` boilerplate. Adopt it for all new shaders this part.

## Build

1. **The indictment.** Before touching anything: extend the forward PBR shader's light loop to a `MAX_LIGHTS=100` uniform array, scatter 100 lanterns around the nearest island (reuse the ch45 instance scatter), set time to night, and read the scene pass GPU ms on the ch49 panel. Write the number down. This is the "before" photo.

2. **`G_Buffer`.** New file `src/gbuffer.odin`:

   ```odin
   G_Buffer :: struct {
       fbo:                       u32,
       albedo_metallic:           u32, // RGBA8
       normal_roughness:          u32, // RGBA16F
       emissive:                  u32, // RGBA16F
       depth_tex:                 u32, // DEPTH24_STENCIL8
       width, height:             i32,
   }
   ```

   `gbuffer_create(w, h)` allocates all four, attaches color 0–2 + depth-stencil, sets `gl.DrawBuffers`, checks completeness. NEAREST filtering (you'll fetch exact texels), clamp to edge. Label everything (`gl.ObjectLabel`) — you'll be staring at these in RenderDoc for three chapters. Wire into the resize path.

3. **Geometry shaders.** `gbuffer.vert` is your `pbr.vert` unchanged (TBN and all). `gbuffer.frag` is `pbr.frag` with the lighting amputated:

   ```glsl
   layout(location = 0) out vec4 g_albedo_metallic;
   layout(location = 1) out vec4 g_normal_roughness;
   layout(location = 2) out vec4 g_emissive;

   void main() {
       vec3 albedo = texture(u_albedo, v_uv).rgb * u_base_color;
       vec3 N      = normal_from_map();       // your existing TBN code
       g_albedo_metallic   = vec4(albedo, u_metallic);
       g_normal_roughness  = vec4(N, u_roughness);
       g_emissive          = vec4(u_emissive_color * u_emissive_strength, 0.0);
   }
   ```

   Make terrain write the G-buffer too: port the splat shader's albedo logic, roughness ~0.9, metallic 0. (Terrain finally joins the PBR world — its Phong days end here as a free bonus.) Instanced props: same treatment, keep the mat4 attributes.

4. **Reroute the frame.** `renderer_begin_geometry` binds the G-buffer (clear color+depth; clear emissive to 0, *not* sky color). Draw terrain, boat, props, instances into it. Then bind the HDR target — whose depth attachment you've switched to *the G-buffer's depth texture* — and do **not** clear depth there.

5. **Fullscreen lighting pass.** `deferred_lighting.frag`: read the three targets + depth, reconstruct world position (Concepts), then paste in your sun + shadow + IBL ambient + emissive code via the shared include. Depth `d == 1.0` (sky) → output 0 and let the forward sky pass own it. First light: you should see your *fully lit world* again, minus ocean and sky. Celebrate; the hard half is done.

6. **Forward layer.** Sky, ocean, wake, particles draw as before into the HDR target — they never stopped being forward; only confirm they test against the shared depth. The ocean shader still does its planar/IBL thing untouched.

7. **Light volumes.** `Point_Light :: struct { position: glsl.vec3, color: glsl.vec3, radius: f32 }`, a `[dynamic]Point_Light` on the renderer, CPU radius from the attenuation cutoff, and the volume pass from Concepts: per light set `u_light_pos/color/radius` + MVP for the scaled sphere, draw. In-shader: reconstruct position, `if (dist > u_radius) discard;`, attenuate smoothly to zero *at* the radius (`att *= pow(1 - dist/u_radius, 2)` style) or you'll see the sphere's edge as a hard line.

8. **100 lanterns, after.** Same scene as step 1, now: lantern meshes render instanced with emissive in the geometry pass; their lights are 100 entries in the volume pass. Read the panel. Typical outcome: forward-100 was tens of ms; geometry+lighting+volumes is a fraction. Put both numbers in the commit message — this chapter *is* that comparison.

9. **G-buffer debug view.** A panel toggle that draws the four targets in quadrants (tiny fullscreen shader, or four blits). You will use it weekly for the rest of the course.

## Checkpoint

Night, 100 lanterns swaying light across water and hulls, frame time sane. The debug quad view shows clean albedo / rainbow-ish normals / roughness / depth.

- Toggling the quadrant view shows sensible data everywhere opaque; sky pixels are depth 1.0 and zero normals.
- Sun, shadows, and IBL look *identical* to ch52 on the boat (shared include working) — A/B screenshots if unsure.
- Standing the camera inside a lantern's radius still lights the deck (front-face culling working).
- RenderDoc: geometry pass shows 3 color outputs in the FB tab; the lighting fullscreen draw reads all four; each volume draw covers only its little screen patch (Mesh Viewer → preview).

## Pitfalls

- **Everything black after step 5.** Depth reads as 1.0 everywhere — you cleared depth after switching FBOs, or the HDR target still has its *own* depth attachment instead of the G-buffer's texture. RenderDoc the depth texture at the lighting draw.
- **World lit but warped, lights slide when the camera moves.** Position reconstruction bug: forgot the `/ v.w`, used `uv` without the `*2-1` remap, or `u_inv_proj` is actually `inverse(proj*view)` mixed with another view multiply. The `.z`-as-color sanity test finds it in one minute.
- **Normals look right but lighting is subtly wrong (rim darkness, flipped speculars).** You stored world normals but the lighting shader treats them as view space (or vice versa, especially in ch56). Pick world space, write it on a sticky note.
- **Hard circle edges around lights.** Attenuation isn't zero at the volume's surface. Force it to zero at `radius` (step 7), not just "small."
- **Terrain looks different (better, but different).** It does — it's PBR now, and it also moved from forward to deferred. Re-tune its roughness/splat colors deliberately rather than chasing the old Phong look.
- **Lanterns glow but cast no light / light but no glow.** Glow is *emissive in the geometry pass* (feeds bloom); light is *an entry in the volume list*. Two systems; a lantern needs both lines of code.
- **Bandwidth surprise on a laptop GPU.** G-buffer at 4K is heavy. Your ch49 timers will show the geometry pass cost; this is the moment to remember the octahedral sidebar and the spare channels.

## Exercises

1. Octahedral-encode normals (sidebar): RT1 becomes RG16F + roughness in B... or pack roughness+metallic together and drop a whole target. Measure the geometry pass before/after.
2. Make the wind blow the lanterns: you already sway the meshes (ch45-style); sway `Point_Light.position` with the same phase so light and lantern move together. Eerily good.
3. Add a `material_id` to the spare emissive alpha and use it to give sand a different specular response than rock in the lighting pass — your first packed material flag.
4. **Stretch:** tiled light culling, CPU edition — divide the screen 16×16, project each light's bounds, build per-tile light lists, and draw *one* fullscreen pass that loops only each tile's lights (lists in a UBO). You've just sketched Forward+/clustered shading; compare against volumes at 100 and 500 lights.

## Commit

`git commit -m "ch55: deferred G-buffer renderer + light volumes; forward ocean/sky/particles hybrid (forward 100 lights: Xms -> deferred: Yms)"`

[← Ch. 54: Smooth Sailing Edges](ch54-smooth-sailing-edges.md) · [Ch. 56: Shadows in Corners →](ch56-shadows-in-corners.md)
