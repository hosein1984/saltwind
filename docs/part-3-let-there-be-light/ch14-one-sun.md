# Chapter 14 — One Sun

*Part 3 — Let There Be Light · Estimated time: 2.5h · learnopengl: [Colors](https://learnopengl.com/Lighting/Colors), [Basic Lighting](https://learnopengl.com/Lighting/Basic-Lighting)*

**What you'll see when done:** your crates and test sphere suddenly have *form* — bright sun-facing sides, shadowed backsides, and a hard white glint that slides across surfaces as you fly.

## Where we are

At the end of the First Voyage milestone you have an endless sea, floating crates, and a camera that goes anywhere. But everything is painted in flat, constant color — the world looks like cardboard cutouts because every pixel of a crate face is exactly the same color regardless of which way it faces. This chapter fixes that with the oldest trick in real-time graphics: Phong lighting under a single directional sun.

## Concepts

### Light is multiplication

A surface doesn't *have* a color; it *reflects* fractions of the light that hits it. A red crate under white light looks red because it reflects the red component and absorbs the rest. In shader terms that's a componentwise multiply:

```glsl
vec3 result = light_color * surface_color;
```

White light `(1,1,1)` times red surface `(1,0.2,0.2)` gives red. Dim blue moonlight times the same surface gives a murky dark purple. That one multiply is the whole conceptual foundation — everything else in this chapter just computes *how much* light arrives and bounces toward your eye. Read [Colors](https://learnopengl.com/Lighting/Colors) if you want the longer version.

### Normals: which way a surface faces

To know how much light a point receives, you need to know which way the surface is facing there. That's the **normal**: a unit vector perpendicular to the surface. Your `Vertex` struct has carried a `normal: glsl.vec3` field since Chapter 11 — it's been all zeros, dead weight in the VBO. Today it earns its keep.

```
        n            n           n
        |          \ |           |
   _____|____       \|      _____|_____
   flat face        edge     each face of a cube gets its
                  (sphere)   own normal -> verts duplicated
```

This is why your procedural cube has 24 vertices, not 8: a corner vertex belongs to three faces with three *different* normals, so it must be stored three times. A sphere is the opposite — the normal at any point is simply the direction from the center to that point, so shared vertices are fine.

### Diffuse: the dot product does the work

Matte surfaces scatter incoming light evenly in all directions, so their brightness depends only on the angle between the surface normal `N` and the direction *toward* the light `L`. Both unit length. Then:

```
brightness = max(dot(N, L), 0)
```

Why the dot product? `dot(N, L) = cos(angle)` for unit vectors. Light hitting head-on (angle 0) gives 1.0; light grazing along the surface (90°) gives 0; light from *behind* gives a negative number, which would suck light out of the scene — hence the `max` with 0.

```
   L  N            N            N
    \ |            |            |   L
     \|            |            |  /
  ----+----    ----+----    ----+----
  cos≈0.7       L below:     cos≈0.9
                clamped 0
```

The physical intuition: a beam of light one meter wide covers one meter of ground when hitting straight down, but smears across many meters when grazing — same energy, more area, less light per point. Cosine is exactly that ratio.

### Ambient: the honest hack

With only diffuse, anything facing away from the sun is pitch black. In reality, light bounces off the sea and sky and fills in shadows. Simulating that properly is global illumination (we'll fake it better in Chapter 43); for now we add a small constant:

```glsl
vec3 ambient = 0.15 * light_color;
```

### Specular: the glint

Shiny surfaces reflect light like an imperfect mirror. The reflected ray `R = reflect(-L, N)` bounces off the surface; the closer your *view direction* `V` is to `R`, the brighter the glint:

```glsl
float spec = pow(max(dot(V, R), 0.0), shininess);
```

The `pow` is the interesting part. `dot(V,R)` falls off gently; raising it to a power sharpens the falloff into a tight highlight. `shininess = 8` is broad satin; `256` is a pinpoint sparkle on polished metal. Because specular depends on the *viewer*, it's the term that moves when you fly — the visual cue that sells "wet" and "shiny", and the one your ocean will lean on hard in Chapter 29.

### A directional sun, and which space to light in

The sun is so far away that its rays are effectively parallel: a directional light has a **direction** but no position and no falloff. One `vec3` uniform.

You must compute lighting with all vectors in the same coordinate space. learnopengl uses view space; we use **world space** — it's easier to reason about ("the sun points down and west"), and the terrain, sea, and sky chapters all want world-space positions anyway. The price: the fragment shader needs the camera's world position as a uniform to build `V`, and normals must be transformed from model space to world space. For now `mat3(model)` is fine because we only translate and rotate; Chapter 16 fixes the general case.

## Build

1. **Give the cube real normals.** In `mesh_cube` you already emit 24 vertices (4 per face). Set each face's normal on all four of its vertices:

   ```odin
   // +X face — all four verts share this normal
   FACE_NORMALS := [6]glsl.vec3{
       {+1, 0, 0}, {-1, 0, 0},
       { 0,+1, 0}, { 0,-1, 0},
       { 0, 0,+1}, { 0, 0,-1},
   }
   // inside the per-face loop:
   for &v in face_verts {
       v.normal = FACE_NORMALS[face]
   }
   ```

2. **Sphere normals are free.** For a unit sphere centered at the origin, the normal *is* the position direction: `v.normal = glsl.normalize(v.position)`. One line in `mesh_sphere`. For `mesh_grid`, every normal is `{0, 1, 0}`.

3. **Confirm the attribute is wired.** Chapter 11's vertex layout already declared location 1 with `offset_of(Vertex, normal)`; if you commented out the `EnableVertexAttribArray(1)` back then, restore it. No layout changes needed — the field was always in the stride.

4. **Write `assets/shaders/lit.vert`.** Pass world-space position and normal through:

   ```glsl
   #version 330 core
   layout (location = 0) in vec3 a_pos;
   layout (location = 1) in vec3 a_normal;
   layout (location = 2) in vec2 a_uv;

   uniform mat4 model, view, projection;

   out vec3 v_world_pos;
   out vec3 v_normal;
   out vec2 v_uv;

   void main() {
       vec4 world = model * vec4(a_pos, 1.0);
       v_world_pos = world.xyz;
       v_normal    = mat3(model) * a_normal;   // ok until non-uniform scale (ch16)
       v_uv        = a_uv;
       gl_Position = projection * view * world;
   }
   ```

5. **Write `assets/shaders/lit.frag`** — the full Phong sum:

   ```glsl
   #version 330 core
   in vec3 v_world_pos;
   in vec3 v_normal;
   in vec2 v_uv;
   out vec4 frag_color;

   uniform vec3 sun_dir;        // direction the light TRAVELS, e.g. (0.4, -1, 0.3)
   uniform vec3 sun_color;
   uniform vec3 view_pos;
   uniform sampler2D u_texture;

   void main() {
       vec3 albedo = texture(u_texture, v_uv).rgb;
       vec3 N = normalize(v_normal);            // re-normalize after interpolation!
       vec3 L = normalize(-sun_dir);            // toward the light
       vec3 V = normalize(view_pos - v_world_pos);

       vec3 ambient  = 0.15 * sun_color;
       vec3 diffuse  = max(dot(N, L), 0.0) * sun_color;
       vec3 R        = reflect(-L, N);
       vec3 specular = 0.5 * pow(max(dot(V, R), 0.0), 32.0) * sun_color;

       frag_color = vec4((ambient + diffuse + specular) * albedo, 1.0);
   }
   ```

6. **Hook up the uniforms.** Load the new pair with `gl.load_shaders_file`, then per frame, before drawing the crates and sphere:

   ```odin
   shader_set_vec3(lit_shader, "sun_dir",   glsl.normalize(glsl.vec3{0.4, -0.8, 0.3}))
   shader_set_vec3(lit_shader, "sun_color", {1.0, 0.97, 0.9})
   shader_set_vec3(lit_shader, "view_pos",  game.camera.position)
   ```

   Leave the sea on its existing shader — it gets its own lighting treatment in Part 5.

7. **Add a test sphere** near the crates if you removed it after Chapter 11; smooth surfaces show off diffuse falloff and the moving specular dot far better than boxes.

## Checkpoint

A morning sea: each crate shows three visibly different brightnesses on its three visible faces; the sphere has a smooth bright-to-dark gradient with a white highlight; flying in an arc around the sphere makes the highlight track your movement.

- Faces pointing away from `(−sun_dir)` are dim but not black (ambient).
- The specular dot moves when the **camera** moves; the diffuse shading does not.
- Rotate a crate (temporary `glsl.mat4Rotate`) — shading rotates with it.
- Set `sun_color` to `{1, 0.3, 0.2}`: instant sunset, no other change.

## Pitfalls

- **Everything black.** Normals are still zero — verify you regenerate meshes after editing the primitive procs, and that attribute location 1 matches the shader's `layout (location = 1)`.
- **Faceted bands or weird soft patches on the sphere.** You forgot `normalize(v_normal)` in the fragment shader; interpolated normals shrink below unit length between vertices.
- **Lighting changes when an object merely moves.** You transformed the normal with the full `mat4` and a `w=1` — translation leaked in. Use `mat3(model) * a_normal`.
- **Highlight on the dark side of the sphere.** Sign error: `reflect` expects the *incident* vector (`-L`). Also clamp `dot(N,L)` before trusting specular, or gate specular with `dot(N,L) > 0`.
- **Sun seems to come from the opposite side.** Decide once whether `sun_dir` is the direction light travels (this course) or the direction toward the sun, and negate consistently.

## Exercises

1. Add a *normal visualization* mode behind a key: `frag_color = vec4(N * 0.5 + 0.5, 1.0)`. Keep it forever — it's your number-one lighting debugger.
2. Bind keys to rotate `sun_dir` around the X axis and watch the scene pass from noon to dusk.
3. Try `shininess` values 2, 8, 32, 128, 512 on the sphere and note where "plastic" becomes "lacquer".
4. **Stretch:** Replace Phong's `reflect` with the Blinn-Phong half-vector `H = normalize(L + V)` and `dot(N, H)` (see the [Advanced Lighting](https://learnopengl.com/Advanced-Lighting/Advanced-Lighting) article). Compare highlights at grazing angles on the sea-level grid — Phong's artifact is obvious there.

## Commit

`git commit -m "ch14: phong lighting under one directional sun"`

← [Chapter 13 — Milestone: First Voyage](../part-2-standing-on-deck/ch13-milestone-first-voyage.md) · [Chapter 15 — Materials of the Sea-World](ch15-materials-of-the-sea-world.md) →
