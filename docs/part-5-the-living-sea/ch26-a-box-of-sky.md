# Chapter 26 — A Box of Sky

*Part 5 — The Living Sea & Sky · Estimated time: 2h · learnopengl: [Cubemaps](https://learnopengl.com/Advanced-OpenGL/Cubemaps)*

**What you'll see when done:** the gray void above your archipelago replaced by a full photographic sky that wraps the horizon in every direction and never gets closer no matter how far you fly.

## Where we are

The Archipelago milestone left you with islands, splatted terrain, and a depth-tinted sea — all floating in your clear color. Every screenshot so far has a flat slab of `gl.ClearColor` where a sky should be. This chapter fills the void with a **cubemap skybox**: the classic technique, and a stepping stone — Chapter 27 replaces the photos with a procedural sky, but the cubemap machinery you build today returns in Chapter 29 (environment sampling) and Chapter 43 (IBL).

## Concepts

### A texture you sample with a direction

A 2D texture is a function of `(u, v)`. A **cubemap** is a function of a *direction*: six square faces glued into a box, and the sampler answers "what color lies along this 3D vector?" The vector doesn't need to be normalized — GL finds which face the ray exits through and where it lands on that face.

```
            +----+
            | +Y |                 sample dir (0.3, 0.9, 0.1)
       +----+----+----+----+              \
       | -X | +Z | +X | -Z |               \  --> hits +Y face,
       +----+----+----+----+                   reads that texel
            | -Y |
            +----+
```

In GLSL that's a new sampler type:

```glsl
uniform samplerCube u_sky;
vec3 color = texture(u_sky, direction).rgb;
```

One historical wart: cubemap face orientation follows a left-handed convention inherited from RenderMan, so faces often look flipped or rotated when you first load them. The fix is mechanical (don't vertically flip on load, follow the face order below), not mathematical — don't burn an evening rederiving coordinate systems.

### The skybox illusion

A skybox is a unit cube drawn *around the camera's head*. Two tricks make a 2-meter cube read as an infinite sky:

1. **It never translates.** The sky must not get closer as you fly toward it. Strip the translation from the view matrix by round-tripping through a 3×3: `mat4(mat3(view))` keeps rotation, discards position. The cube is therefore always centered on your eye.
2. **It's always the farthest thing.** Instead of drawing it first (wasting fill rate on pixels terrain will cover), draw it *last* and force its depth to the far plane: in the vertex shader, output `gl_Position = pos.xyww`. After the perspective divide, depth = w/w = 1.0 — exactly the far plane. Set `gl.DepthFunc(gl.LEQUAL)` while drawing so that 1.0 passes against the cleared depth of 1.0.

The fragment direction is free: the cube's own object-space vertex position *is* the sample direction, interpolated across each face.

### Seams

With linear filtering, texels at a face edge have no neighbor to blend with — you get visible hairline seams along the box edges. GL 3.2+ fixes this globally with one switch: `gl.Enable(gl.TEXTURE_CUBE_MAP_SEAMLESS)`. Also set wrap mode to `CLAMP_TO_EDGE` on **all three** axes (`WRAP_S`, `WRAP_T`, and the cubemap-only `WRAP_R`).

### Getting a sky

You need six images named by face. Two good free routes:

- The classic set from the [Cubemaps article](https://learnopengl.com/Advanced-OpenGL/Cubemaps) (skybox.zip — ocean and sky, very on-brand).
- Any sunset HDRI from [Poly Haven](https://polyhaven.com/hdris) (CC0), converted to six faces with the free in-browser [HDRI-to-CubeMap](https://matheowis.github.io/HDRI-to-CubeMap/) tool. Export as six PNG/JPG faces at 1024².

Put them in `assets/textures/sky/` as `right/left/top/bottom/front/back`.

## Odin notes

Odin matrices convert between dimensions by copying the overlapping block, so stripping translation is a cast round-trip, no helper needed:

```odin
view_rot := glsl.mat4(glsl.mat3(view))   // upper-left 3x3 kept, translation zeroed
```

Note the resulting `mat4` gets `1` on the diagonal of the new row/column, which is exactly what you want. Also: `stbi.load` wants a `cstring`; string *literals* convert implicitly, so a `[6]cstring` table of paths costs nothing.

## Build

1. **Write the cubemap loader** in a new `src/skybox.odin` (or your texture file). Face order is fixed by the GL enum sequence: +X, −X, +Y, −Y, +Z, −Z = right, left, top, bottom, front, back.

   ```odin
   cubemap_load :: proc(faces: [6]cstring) -> u32 {
       id: u32
       gl.GenTextures(1, &id)
       gl.BindTexture(gl.TEXTURE_CUBE_MAP, id)
       stbi.set_flip_vertically_on_load(0)        // cubemaps: do NOT flip!
       for path, i in faces {
           w, h, ch: i32
           data := stbi.load(path, &w, &h, &ch, 3)
           assert(data != nil, "missing cubemap face")
           defer stbi.image_free(data)
           gl.TexImage2D(gl.TEXTURE_CUBE_MAP_POSITIVE_X + u32(i),
               0, gl.SRGB8, w, h, 0, gl.RGB, gl.UNSIGNED_BYTE, data)
       }
       gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
       gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
       gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
       gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
       gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_WRAP_R, gl.CLAMP_TO_EDGE)
       return id
   }
   ```

   `gl.SRGB8` because your pipeline has been gamma-correct since Chapter 16 — sky photos are sRGB like any other albedo. If you set `set_flip_vertically_on_load(1)` back in Chapter 6, restore it after loading the faces.

2. **Define the `Skybox` struct and creator.** Reuse `mesh_cube` from Chapter 11 — you only read `a_pos`, the normals and UVs in the stride are ignored.

   ```odin
   Skybox :: struct {
       cubemap: u32,
       cube:    Mesh,
       shader:  Shader,
   }
   ```

   In `skybox_create`, load the shader pair below and call `cubemap_load` with your six paths.

3. **Write `assets/shaders/skybox.vert`** — the two tricks live here:

   ```glsl
   #version 330 core
   layout (location = 0) in vec3 a_pos;
   out vec3 v_dir;
   uniform mat4 view;        // rotation-only, see step 5
   uniform mat4 projection;

   void main() {
       v_dir = a_pos;                                  // object-space pos IS the direction
       vec4 pos = projection * view * vec4(a_pos, 1.0);
       gl_Position = pos.xyww;                         // depth -> 1.0 after divide
   }
   ```

4. **Write `assets/shaders/skybox.frag`** — three lines: sample `samplerCube u_sky` with `normalize(v_dir)` (normalizing is optional but tidy), output it.

5. **Draw it last.** After terrain, props, and sea, before swap:

   ```odin
   skybox_draw :: proc(sb: Skybox, view, projection: glsl.mat4) {
       gl.DepthFunc(gl.LEQUAL)
       defer gl.DepthFunc(gl.LESS)
       gl.UseProgram(sb.shader.id)
       shader_set_mat4(sb.shader, "view", glsl.mat4(glsl.mat3(view)))
       shader_set_mat4(sb.shader, "projection", projection)
       gl.BindTexture(gl.TEXTURE_CUBE_MAP, sb.cubemap)
       mesh_draw(sb.cube)
   }
   ```

   You're viewing the cube from *inside*, so if you ever enabled back-face culling, disable it for this draw (or wind a dedicated inward-facing cube).

6. **Enable seamless filtering once at startup**, next to your other global GL state: `gl.Enable(gl.TEXTURE_CUBE_MAP_SEAMLESS)`.

7. **Retire the clear color.** Keep `gl.Clear` (you still need depth cleared, and color for safety) but the sky now owns every background pixel.

## Checkpoint

Islands silhouetted against a real sky; the horizon line of the photo roughly matching your sea horizon; clouds that rotate with your view but never approach.

- Fly hard toward the horizon for ten seconds — the sky doesn't move. (Translation stripped correctly.)
- Look straight up and roll the camera — no seams along cube edges.
- Terrain and buoys still draw *in front of* the sky everywhere. (Depth trick working.)
- Check the GPU cost intuition: the skybox draws last, so in a frame full of terrain it only shades the leftover background pixels.

## Pitfalls

- **Sky is solid black.** The cubemap is incomplete: you uploaded fewer than 6 faces, or min filter is mipmap-based (`LINEAR_MIPMAP_LINEAR`) with no mipmaps generated. Use plain `LINEAR` or call `gl.GenerateMipmap(gl.TEXTURE_CUBE_MAP)`.
- **Sky draws over everything / flickers.** You forgot `gl.DepthFunc(gl.LEQUAL)` (1.0 fails against cleared 1.0 with `LESS`), or you left depth writes off from a previous pass, or you didn't output `pos.xyww`.
- **The whole sky slides as you fly.** You uploaded the full view matrix. Strip translation with `glsl.mat4(glsl.mat3(view))`.
- **Faces scrambled or upside down.** You're flipping vertically on load (don't, for cubemaps), or your file order doesn't match +X, −X, +Y, −Y, +Z, −Z.
- **Hairline grid lines in the sky.** Missing `TEXTURE_CUBE_MAP_SEAMLESS` and/or `WRAP_R` not clamped.
- **Sky looks washed out or too dark.** Double-gamma: you loaded as `SRGB8` *and* still have a manual `pow(color, 1/2.2)` mismatch somewhere, or you loaded as `RGB8` into a gamma-correct pipeline. Pick one path (Chapter 16 rules apply).

## Exercises

1. Bind a key that swaps between two cubemap sets at runtime (day and dusk) — proof your loader is reusable, and a preview of Chapter 27's time-of-day.
2. In the skybox fragment shader, multiply the sample by a uniform `u_tint` and try `vec3(1.0, 0.6, 0.4)` — instant cheap sunset, and a hint at how much mileage color grading buys.
3. Sample the cubemap in your *sea* shader with the view reflection vector and blend 20% of it over the water color. Ugly but tantalizing — Chapter 29 does this properly.
4. **Stretch:** Write `cubemap_from_cross` that loads a single 4×3 cross-layout image and slices the six faces from it on the CPU before upload (stb gives you the pixels; you do the offset math).

## Commit

`git commit -m "ch26: cubemap skybox with depth trick"`

← [Chapter 25 — Milestone: The Archipelago](../part-4-raising-islands/ch25-milestone-the-archipelago.md) · [Chapter 27 — The Procedural Heavens](ch27-the-procedural-heavens.md) →
