# Interlude 39a — Lanterns in the Dark

*⚓ Optional interlude · slots after [Chapter 39](ch39-shadows-on-the-water.md) · Estimated time: 4h · learnopengl: [Point Shadows](https://learnopengl.com/Advanced-Lighting/Point-Shadows)*

**Prerequisites:** Chapter 39 (shadow mapping + PCF), Chapter 15 (lantern point lights). · **Required downstream:** none — skip freely.

**What you'll see when done:** at night, the lantern on the stern throws the mast's shadow swinging across the deck and out over the black water — radiating *away* from the flame in every direction, as lantern shadows do.

## Why this is a side quest

Chapter 39 shadowed the sun, and one directional light is 95% of the visual win in a daylight sailing game. Point-light shadows cost six scene renders *per light* for a payoff you only see at night standing near a lantern — gorgeous, but a luxury. The main line spends that frame budget elsewhere; tonight, you get to splurge.

## Concepts

### Six frustums, one cube

A directional light sees the world through one orthographic box. A lantern shines *everywhere*: no single 2D map can hold "distance to nearest blocker" for all directions. The natural texture for a function of direction is one you already own — a **cubemap** (Chapter 26). Render depth six times, once per face, each with a 90° perspective frustum; together the faces tile the full sphere with no gaps and no overlap:

```
            +Y
             |          each face: fov = 90°, aspect = 1
        -X --+-- +X     six lookAt matrices from the light position
       /     |          stored: distance to nearest caster, per direction
     +Z     -Y
   (camera-free render: the "camera" is the lantern)
```

In the lighting pass there is no light-space matrix at all: the vector **from light to fragment** is itself the cubemap lookup direction, and its length is the value to compare. That symmetry is the whole trick.

### Store linear distance, not clip-space depth

Chapter 39 stored hardware depth and compared in light clip space. Here that gets awkward — six different projections, and the sampling side has no `lsp.xyz / lsp.w` to replay. So the depth pass writes its own value: **`length(fragment − light) / far`**, a linear, projection-free distance normalized into the depth attachment's [0,1]. The fragment shader is no longer empty — it computes that and writes `gl_FragDepth`. The comparison becomes plain geometry: `length(frag − light)` vs `sampled · far`.

### PCF on a sphere

The 3×3-texel loop from Chapter 39 doesn't translate — there is no 2D texel grid to step, only directions. Instead, perturb the lookup *direction* with a small set of well-spread 3D offsets and average the comparisons. Twenty offsets is the classic set; scaling the offset radius with the viewer's distance to the fragment makes near shadows crisp and far shadows soft for free.

### The honest bill

Each shadowed point light re-renders every caster in its radius **six times**. Saltwind's answer: exactly **one** shadowed lantern — whichever is nearest the camera — re-picked every frame so the shadows follow you from buoy to buoy as you sail. All other lanterns keep casting *light* without shadows; at night, with several flames in view, nobody can tell which one is the honest one. This budget discipline (N shadowed lights, nearest-first) is exactly what shipping games do.

> **Sidebar — the geometry-shader single pass.** GL 3.3 can attach the *whole* cubemap with `gl.FramebufferTexture` and use a geometry shader that emits each triangle six times, routing copies to faces via `gl_Layer` — one draw call instead of six. learnopengl teaches this version, and it's elegant. It is also, on most real drivers, *not faster*: geometry shaders defeat several fast paths, and the 6-pass version lets you frustum-cull per face while the GS version transforms every triangle six times regardless. Build the six passes; treat the GS as the Stretch exercise and let your own GPU timer pick the winner.

## Build

1. **The depth cubemap + FBO.** Six square depth faces, then the familiar color-less framebuffer:

   ```odin
   POINT_SHADOW_SIZE :: 1024

   gl.GenTextures(1, &point_shadow_tex)
   gl.BindTexture(gl.TEXTURE_CUBE_MAP, point_shadow_tex)
   for i in 0 ..< u32(6) {
       gl.TexImage2D(gl.TEXTURE_CUBE_MAP_POSITIVE_X + i, 0, gl.DEPTH_COMPONENT24,
                     POINT_SHADOW_SIZE, POINT_SHADOW_SIZE, 0,
                     gl.DEPTH_COMPONENT, gl.FLOAT, nil)
   }
   gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_MIN_FILTER, gl.NEAREST)
   gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_MAG_FILTER, gl.NEAREST)
   gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
   gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
   gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_WRAP_R, gl.CLAMP_TO_EDGE)
   ```

   The FBO gets `gl.DrawBuffer(gl.NONE)` / `gl.ReadBuffer(gl.NONE)` as in ch39; faces attach per pass in step 4.

2. **Six face matrices.** The up vectors look wrong and aren't — they follow the cubemap spec's per-face orientation. Copy exactly:

   ```odin
   point_shadow_faces :: proc(pos: glsl.vec3, far: f32) -> [6]glsl.mat4 {
       proj := glsl.mat4Perspective(math.PI * 0.5, 1.0, 0.05, far) // 90°, square
       return {
           proj * glsl.mat4LookAt(pos, pos + {+1, 0, 0}, {0, -1, 0}),
           proj * glsl.mat4LookAt(pos, pos + {-1, 0, 0}, {0, -1, 0}),
           proj * glsl.mat4LookAt(pos, pos + {0, +1, 0}, {0, 0, +1}),
           proj * glsl.mat4LookAt(pos, pos + {0, -1, 0}, {0, 0, -1}),
           proj * glsl.mat4LookAt(pos, pos + {0, 0, +1}, {0, -1, 0}),
           proj * glsl.mat4LookAt(pos, pos + {0, 0, -1}, {0, -1, 0}),
       }
   }
   ```

   `far` is the lantern's reach — ~50 from the ch15 attenuation constants. Light beyond `far` exists; shadow doesn't — keep them matched.

3. **The distance-writing depth shader.** `point_depth.vert` outputs world position alongside `gl_Position = u_face_vp * world`; the fragment shader finally earns a body:

   ```glsl
   #version 330 core
   in vec3 v_world;
   uniform vec3  u_light_pos;
   uniform float u_far;

   void main() {
       gl_FragDepth = length(v_world - u_light_pos) / u_far;
   }
   ```

4. **The six passes.** After the ch39 sun pass, before the main render:

   ```odin
   gl.Viewport(0, 0, POINT_SHADOW_SIZE, POINT_SHADOW_SIZE)
   gl.BindFramebuffer(gl.FRAMEBUFFER, point_shadow_fbo)
   shader_use(point_depth_shader)
   shader_set_vec3(point_depth_shader, "u_light_pos", light.position)
   shader_set_f32(point_depth_shader, "u_far", light.far)
   for face, i in point_shadow_faces(light.position, light.far) {
       gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.DEPTH_ATTACHMENT,
                               gl.TEXTURE_CUBE_MAP_POSITIVE_X + u32(i),
                               point_shadow_tex, 0)
       gl.Clear(gl.DEPTH_BUFFER_BIT)
       shader_set_mat4(point_depth_shader, "u_face_vp", face)
       draw_casters_near(light.position, light.far)
   }
   ```

   `draw_casters_near` is your ch39 caster list filtered by a sphere test — boat, buoys, and terrain chunks whose AABB intersects the light sphere (`closest point on AABB to center` vs `far`). Most faces will draw a handful of meshes. **Exclude the lantern's own glass and cage** — the light source sits inside them and they'd blacken the world (see Pitfalls).

5. **Pick the shadowed lantern.** Each frame, find the `Point_Light` nearest the camera; pass its index as `u_shadowed_light` (−1 for none), plus `u_point_shadow` (a new texture unit) and `u_point_far`.

6. **Sample in the lighting shader.** Add to `lit.frag` (and the water shader if you want lantern shadows on the sea at night — you do):

   ```glsl
   uniform samplerCube u_point_shadow;
   uniform float u_point_far;
   uniform int   u_shadowed_light;

   const vec3 pcf_dirs[20] = vec3[](
       vec3( 1, 1, 1), vec3( 1,-1, 1), vec3(-1,-1, 1), vec3(-1, 1, 1),
       vec3( 1, 1,-1), vec3( 1,-1,-1), vec3(-1,-1,-1), vec3(-1, 1,-1),
       vec3( 1, 1, 0), vec3( 1,-1, 0), vec3(-1,-1, 0), vec3(-1, 1, 0),
       vec3( 1, 0, 1), vec3(-1, 0, 1), vec3( 1, 0,-1), vec3(-1, 0,-1),
       vec3( 0, 1, 1), vec3( 0,-1, 1), vec3( 0,-1,-1), vec3( 0, 1,-1));

   float point_shadow_factor(vec3 frag_pos, vec3 light_pos) {
       vec3  to_frag = frag_pos - light_pos;
       float current = length(to_frag);
       float radius  = (1.0 + length(u_camera_pos - frag_pos) / u_point_far) / 25.0;
       float lit = 0.0;
       for (int i = 0; i < 20; ++i) {
           float d = texture(u_point_shadow, to_frag + pcf_dirs[i] * radius).r * u_point_far;
           lit += (current - 0.1) > d ? 0.0 : 1.0;
       }
       return lit / 20.0;
   }
   ```

   In the point-light loop, multiply that light's diffuse + specular (never ambient) by the factor when `i == u_shadowed_light`. The bias is **0.1 meters** — distance units now, not clip-space fractions.

7. **Set the scene.** Drop the sun below the horizon (your ch27 day/night key), sail up to a lantern buoy, and look at the water on the buoy's far side.

## Checkpoint

Night, calm-ish sea, boat alongside the lantern buoy: the buoy's own crate blocks a wedge of light, the boat hull lays a long boat-shaped darkness across the water *away* from the flame, and as both bob, every shadow swings — radially, like spokes.

- Sail from one lantern's pool toward another: the shadow honor migrates to the nearer lantern with no crash and (at night, among multiple flames) no obvious pop.
- Shadow edges are soft (the 20-tap PCF) and stay stable as the camera orbits.
- Frame time: note the cost of the six passes with your title-bar ms. It should be small — your caster cull keeps each face to a few meshes — but *measured*, not assumed.
- Daytime: visually nothing changes (the sun swamps lantern light), and that's correct — this is a night feature.

## Pitfalls

- **Everything the light touches is black.** The lantern's own glass/cage mesh is in the caster list — the light is *inside* a caster, so every direction finds a blocker at distance ≈ 0. Exclude the fixture (or shrink it out with the 0.05 near plane).
- **Shadows rotated 90° or mirrored on some faces.** An up vector in the face table got "corrected" to `{0, 1, 0}`. They really are `-Y` for four faces; copy the table verbatim.
- **One face of the world unshadowed.** The `gl.Clear` sits outside the loop, so only the first attached face was cleared — or `u_face_vp` is set once. Both must run per face.
- **Acne stripes on the deck.** Bias too small *for distance units*. You're comparing meters now; 0.005 (a ch39 reflex) is half a centimeter. Start at 0.1 and tune; front-face culling during the depth passes helps here too.
- **Shadow ends abruptly while light keeps going.** `u_point_far` smaller than the lantern's attenuation reach — the cubemap stores `1.0` past `far`, which reads as "lit," then your comparison misbehaves at the seam. Match `far` to the ~50 m reach.
- **Main scene renders tiny in a corner.** The viewport, again, as in ch39. Reset it after the sixth pass.

## Exercises

1. Amortize: re-render the cubemap only when the light or a nearby caster has moved more than a few centimeters since the last render (the bobbing means "almost every frame" — so also try every *other* frame and judge whether anyone can tell).
2. Two shadowed lanterns: a second cubemap + FBO, the two nearest lights, and a title-bar ms comparison. Decide for yourself where Saltwind's budget says stop.
3. **Stretch:** the learnopengl geometry-shader version — `gl.FramebufferTexture` to attach the whole cubemap, one pass, `gl_Layer` routing in a GS. Wrap both paths in GPU timer queries (Chapter 49 formalizes these) and keep whichever your driver actually runs faster. Write the number you measured in a comment for future-you.

## Commit

`git commit -m "ch39a: omnidirectional point shadows — depth cubemap, 6 passes, nearest lantern"`

← Back to [Chapter 39 — Shadows on the Water](ch39-shadows-on-the-water.md) · onward to [Chapter 40 — More Light than Screen](ch40-more-light-than-screen.md) →
