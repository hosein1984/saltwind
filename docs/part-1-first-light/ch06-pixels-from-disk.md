# Chapter 6 — Pixels from Disk

*Part 1 — First Light · Estimated time: 3h · learnopengl: [Textures](https://learnopengl.com/Getting-started/Textures)*

**What you'll see when done:** a wooden crate face filling the quad — real pixels from a real file, filtered and mipmapped, the first imported artwork in Saltwind.

## Where we are

Everything on screen so far is computed color. Worlds need *surfaces*: wood grain, sand, sailcloth. This chapter brings image files onto geometry — decoding with `stb_image`, uploading to GPU texture memory, and configuring the sampling machinery (wrap, filter, mipmaps) that decides what a texture looks like when it's stretched, shrunk, or viewed from a thousand units away. The crate texture you load today gets boxed up into the floating cargo of Chapters 8–13.

## Concepts

### Texels: image cells, not screen pixels

An image file decodes into a rectangular grid of color values. Each cell in that grid is a **texel**: short for *texture element*.

A **pixel** is a cell in the final image on your monitor. A **texel** is a cell in a texture stored in memory. They often line up in simple examples, but they are not the same thing:

```
texture on disk / GPU memory          final framebuffer
┌────┬────┬────┬────┐                 ┌────┬────┬────┬────┬────┐
│ T0 │ T1 │ T2 │ T3 │                 │ P0 │ P1 │ P2 │ P3 │ P4 │
├────┼────┼────┼────┤                 ├────┼────┼────┼────┼────┤
│ ... image data ... │       drawn →   │ ... screen output ... │
└────┴────┴────┴────┘                 └────┴────┴────┴────┴────┘
```

A 1024×1024 crate texture always has 1,048,576 texels. Draw that crate as a tiny distant square and many texels contribute to one screen pixel. Draw it huge and many screen pixels may be colored from the same few texels. Texture sampling is the machinery that answers, "Given this spot on the surface, which texture color should this screen pixel receive?"

That idea is renderer-wide, not OpenGL-specific. Metal, Direct3D, Vulkan, and WebGPU all have the same split: image data made of texels, screen output made of pixels, and a sampler in between.

### UV coordinates: positions on the image

A texture is addressed in **UV space**. OpenGL and GLSL often call the same axes **S** and **T**, so you will see both names:

| Teaching name | OpenGL name | Direction on a normal 2D image |
|---|---|---|
| `u` | `s` | left → right |
| `v` | `t` | bottom → top |

UVs are normalized: `(0,0)` is the bottom-left of the image and `(1,1)` is the top-right, independent of resolution. A 256×256 texture and a 4096×4096 texture use the same UV range.

Each vertex carries a UV coordinate; the rasterizer interpolates those UVs across the triangle; then the fragment shader samples the texture at the interpolated spot:

```
 (0,1)        (1,1)        v3──────v2     vertex → uv
   ┌────────────┐           │      │      v0 → (0,0)   v1 → (1,0)
   │   image    │           │ quad │      v2 → (1,1)   v3 → (0,1)
   └────────────┘           │      │
 (0,0)        (1,0)        v0──────v1
```

The important phrase is **interpolated spot**. The shader usually asks for a position between texel centers, such as `u = 0.372`. Real texture coordinates are continuous. The stored texel grid is discrete. The sampler has to turn that in-between request into a color.

### Sampling: asking a texture for a color

In the fragment shader, this line is the sample:

```glsl
frag_color = texture(u_texture, v_uv);
```

Read it as: "Sampler, use `u_texture`'s current rules to answer what color lives at `v_uv`."

The sampler does several small jobs in order:

1. Take the interpolated UV from the fragment.
2. Apply the wrap mode if `u` or `v` is outside the normal 0–1 range.
3. Decide whether the texture is being magnified, minified, and which mip level fits.
4. Fetch one or more texels.
5. Filter those texels into one returned color.

The texture is not pasted onto the quad once. Sampling happens per fragment, every frame. The vertex UVs just give the rasterizer enough information to produce a UV for each fragment.

### Wrap modes: what happens outside 0–1

What does sampling at `u = 1.7` mean? Your choice, per axis.

OpenGL names the axes `S` and `T`, so these two calls configure the horizontal and vertical texture directions separately:

```odin
gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.REPEAT) // u/s axis
gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.REPEAT) // v/t axis
```

For our crate, both axes use the same rule, but they do not have to. Later, a texture might repeat horizontally while clamping vertically.

- `gl.REPEAT`: tile the texture; `1.7` behaves like `0.7`.
- `gl.MIRRORED_REPEAT`: tile, but every other tile flips direction.
- `gl.CLAMP_TO_EDGE`: clamp to the nearest edge texel; right for images that should not tile, like UI icons.
- `gl.CLAMP_TO_BORDER`: return a chosen border color outside the image.

This is the first "axis" to keep straight: **wrap axes are UV axes**. `WRAP_S` is the `u` direction. `WRAP_T` is the `v` direction.

### Filtering: how several texels become one color

Filtering means **reconstructing a color from discrete texels**. The shader asks for a continuous position; the texture only stores a grid. The filter is the rule that bridges those two worlds.

The two basic filters are:

- `gl.NEAREST`: choose the nearest texel center. This gives hard square edges when magnified.
- `gl.LINEAR`: blend neighboring texels. On a 2D texture, this blends in both `u/s` and `v/t`, usually using the 4 nearest texels. This is often called **bilinear filtering**.

So filtering also has UV axes, but they are not configured with separate `FILTER_S` and `FILTER_T` settings in basic OpenGL. `gl.LINEAR` on a 2D texture means "blend across the local 2D texel grid."

Now the second "axis" to keep straight: **minification vs. magnification is not horizontal vs. vertical**. It is about scale.

- **Magnification**: the texture is being enlarged on screen. One texel may cover many screen pixels. `gl.TEXTURE_MAG_FILTER` chooses how that enlargement looks. It can only be `gl.NEAREST` or `gl.LINEAR`; mipmaps do not help because there is no higher-detail image to use.
- **Minification**: the texture is being shrunk on screen. One screen pixel may cover many texels. `gl.TEXTURE_MIN_FILTER` chooses how that shrinkage looks, and it may use mipmaps.

For Saltwind's crate:

```odin
gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR)
gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
```

Read those as: "When a screen pixel covers many texels, use smooth filtering with mipmaps. When many screen pixels cover one texel, use smooth filtering without mipmaps."

### Mipmaps, explained properly

Minification has a nastier problem than blur. Picture the crate 300 units away, covering 4 pixels on screen. Each pixel's sample lands on *one* arbitrary texel out of the thousands the crate spans — and which texel changes every frame as anything moves. The result is shimmering, crawling noise (and a memory-bandwidth disaster: the GPU pulls scattered texels from all over a big image).

**Mipmaps** pre-solve this: a chain of pre-averaged copies at ½, ¼, ⅛… resolution down to 1×1 (+33% memory, total). At sample time the GPU measures how fast uv changes between adjacent screen pixels (the *derivative* — this is why GPUs shade in 2×2 quads) and picks the mip level whose texels are roughly pixel-sized. Each sample then averages over the correct footprint, because the averaging already happened offline.

The filter modes with `MIPMAP` in the name choose how levels combine. `gl.LINEAR_MIPMAP_LINEAR` — linear within one mip level, then linear again between two adjacent mip levels — is the default-quality choice and what we use. That extra blend across the mip chain is called **trilinear filtering**: two texture axes (`u` and `v`) plus the mip-level axis. `gl.GenerateMipmap(gl.TEXTURE_2D)` builds the whole chain in one call after upload.

Magnification never uses mipmaps (there's nothing *more* detailed to use), so `MAG_FILTER` must be plain `NEAREST` or `LINEAR`.

### Texture units and samplers

A shader samples through a `uniform sampler2D`. Which texture? Indirection: the GL context has ~16+ numbered **texture units**. A texture unit is a numbered shelf the shader can look at during a draw.

This is the part of the API that looks odd at first:

```odin
gl.ActiveTexture(gl.TEXTURE0)
gl.BindTexture(gl.TEXTURE_2D, crate_tex.id)
shader_set_i32(shader, "u_texture", 0)
```

Read it as three separate pieces of state:

1. `gl.ActiveTexture(gl.TEXTURE0)` says, "future texture binds affect texture unit 0."
2. `gl.BindTexture(gl.TEXTURE_2D, crate_tex.id)` says, "put `crate_tex` into the active unit's 2D texture slot."
3. `shader_set_i32(shader, "u_texture", 0)` says, "the shader sampler named `u_texture` should read from texture unit 0."

The sampler uniform is not set to the texture object's OpenGL handle. It is set to the **texture unit index**. The chain looks like this:

```text
uniform sampler2D u_texture
        |
        v
texture unit 0
        |
        v
unit 0's TEXTURE_2D binding
        |
        v
crate_tex object
```

Or, as concrete context state:

```text
OpenGL context
  active texture unit: TEXTURE0

  texture unit 0
    TEXTURE_2D       -> crate_tex
    TEXTURE_CUBE_MAP -> none

  texture unit 1
    TEXTURE_2D       -> none
```

So `gl.BindTexture` does not mean "bind this texture globally." It means "bind this texture to this target slot on whichever texture unit is active right now."

That is why multiple textures work:

```odin
gl.ActiveTexture(gl.TEXTURE0)
gl.BindTexture(gl.TEXTURE_2D, crate_tex.id)
shader_set_i32(shader, "u_crate", 0)

gl.ActiveTexture(gl.TEXTURE1)
gl.BindTexture(gl.TEXTURE_2D, sand_tex.id)
shader_set_i32(shader, "u_sand", 1)
```

Now one draw can sample both `u_crate` and `u_sand`. Chapter 22's terrain splatting uses the same idea with four textures at once.

This is the same binding machinery you use while loading a texture, just with a different purpose. During load, binding a texture makes it the object that receives `TexParameteri`, `TexImage2D`, and `GenerateMipmap`. During draw, binding a texture makes it reachable through the texture unit that a shader sampler points at. Same state slots, two moments in the texture's life.

### Where to get textures

Two excellent CC0 (no strings attached) libraries: [ambientCG](https://ambientcg.com) and [Poly Haven](https://polyhaven.com/textures). Grab a wooden-crate or planks texture (1K resolution is plenty for the whole course; the JPG/PNG "diffuse"/"color" map is the one you want — the normal/roughness siblings become relevant in Part 7). Save as `assets/textures/crate.png` (stb_image also reads jpg/tga/bmp fine).

## Odin notes

- `vendor:stb/image` is Odin bindings over the canonical C decoder; import as `stbi`. Paths are `cstring` — take `path: cstring` in `texture_load` and literals just work.
- `stbi.load` returns a multipointer (`[^]u8`) that **you** must free with `stbi.image_free` — a perfect `defer` (the GL upload copies the data; the CPU copy is dead weight after).
- **Flip on load:** image files store rows top-down; GL expects bottom-up. `stbi.set_flip_vertically_on_load(1)` once, globally, before any load — or every texture in the course renders upside down.

## Build

1. **Create `src/texture.odin`:**

   ```odin
   package saltwind

   import "core:fmt"
   import gl "vendor:OpenGL"
   import stbi "vendor:stb/image"

   Texture :: struct {
   	id:            u32,
   	width, height: i32,
   }

   texture_load :: proc(path: cstring) -> (tex: Texture, ok: bool) {
   	stbi.set_flip_vertically_on_load(1)
   	channels: i32
   	data := stbi.load(path, &tex.width, &tex.height, &channels, 0)
   	if data == nil {
   		fmt.eprintln("[texture] failed to load:", path)
   		return {}, false
   	}
   	defer stbi.image_free(data)

   	format: u32 = gl.RGBA if channels == 4 else gl.RGB

   	gl.GenTextures(1, &tex.id)
   	gl.BindTexture(gl.TEXTURE_2D, tex.id)
   	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.REPEAT)
   	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.REPEAT)
   	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR)
   	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)

       gl.PixelStorei(gl.UNPACK_ALIGNMENT, 1)
   	gl.TexImage2D(gl.TEXTURE_2D, 0, i32(format), tex.width, tex.height, 0, format, gl.UNSIGNED_BYTE, data)
   	gl.GenerateMipmap(gl.TEXTURE_2D)
   	return tex, true
   }

   texture_destroy :: proc(tex: ^Texture) {
   	gl.DeleteTextures(1, &tex.id)
   	tex^ = {}
   }
   ```

   Read `TexImage2D`'s parameters once, carefully: target; mip level 0 (base); *internal* format (how the GPU stores it); dimensions; legacy `border=0`; then the *source* format + type describing the bytes you're handing over. The internal/source split matters from Chapter 16 (sRGB) onward.

2. **Give the quad uvs.** Swap the `color` field for `uv` (`glsl.vec2`), and reshape the quad to a centered square so the crate isn't stretched — the horizon look returns in Chapter 8 as real 3D:

   ```odin
   Sea_Vertex :: struct {
   	position: glsl.vec3,
   	uv:       glsl.vec2,
   }

   	vertices := [?]Sea_Vertex{
   		{{-0.5, -0.5, 0.0}, {0.0, 0.0}},
   		{{ 0.5, -0.5, 0.0}, {1.0, 0.0}},
   		{{ 0.5,  0.5, 0.0}, {1.0, 1.0}},
   		{{-0.5,  0.5, 0.0}, {0.0, 1.0}},
   	}
   ```

   Update attribute 1 to match: **2** components, `offset_of(Sea_Vertex, uv)`.

3. **Update the shaders.** `basic.vert`: `a_color`/`v_color` become `a_uv`/`v_uv` (`vec2`). `basic.frag` samples:

   ```glsl
   #version 330 core
   in vec2 v_uv;
   out vec4 frag_color;

   uniform sampler2D u_texture;

   void main() {
   	frag_color = texture(u_texture, v_uv);
   }
   ```

4. **Load and bind.** After shader setup:

   ```odin
   	crate_tex, tex_ok := texture_load("assets/textures/crate.png")
   	if !tex_ok do return
   ```

   In the loop, before the draw:

   ```odin
   		gl.ActiveTexture(gl.TEXTURE0)
   		gl.BindTexture(gl.TEXTURE_2D, crate_tex.id)
   		shader_set_i32(shader, "u_texture", 0)
   ```

5. Run. Wood.

## Checkpoint

A square wooden crate face, centered, upright, correctly oriented (any text/labels in the texture read normally).

- Set both uv maxima from 1.0 to 4.0: the texture tiles 4×4 (that's `REPEAT` working). Back to 1.0.
- Set all four uvs temporarily to `{0.5, 0.5}`: the whole quad becomes one sampled point from the crate, because every fragment asks the sampler the same question. Restore the corner uvs.
- Swap `MAG_FILTER` to `gl.NEAREST` and maximize the window: individual texels as crisp squares. Back to `LINEAR`.
- Shrink the window very small: no shimmer or sparkle on the crate — mipmaps earning their 33%.
- Hold TAB: still two triangles under all that wood.

## Pitfalls

- **Solid black quad?** The classic: mipmapped `MIN_FILTER` (the default is mipmap-based!) but no `GenerateMipmap` call — the sampler reads missing levels as black. Also check: texture bound before draw; sampler uniform set to the right unit.
- **`stbi.load` returns nil?** Wrong working directory (run from `saltwind/` root), wrong filename, or a format quirk — `stbi.failure_reason()` returns a hint string.
- **Image upside down?** `set_flip_vertically_on_load` missing or called after the load.
- **Skewed, sheared rainbow garbage?** Channel mismatch — you told `TexImage2D` `gl.RGB` for a 4-channel PNG (or vice versa). Our `channels`-based `format` handles it; this appears if you hardcode.
- **Subtly diagonal-shifted garbage on RGB images with odd widths?** Row-alignment: GL defaults to 4-byte row alignment, 3-byte texels can violate it. Fix with `gl.PixelStorei(gl.UNPACK_ALIGNMENT, 1)` before upload, or use power-of-two-sized textures (do both eventually; add the `PixelStorei` to `texture_load` now).

## Exercises

1. Load a second texture (sand, from ambientCG — it becomes the island beach in Part 4) onto unit 1 and blend in the shader: `mix(texture(u_texture, v_uv), texture(u_texture2, v_uv), 0.5)`. Two samplers, two units, one draw.
2. Animate uv in the vertex shader: `v_uv = a_uv + vec2(u_time * 0.05, 0.0)` with wrap `REPEAT`. The texture conveyor-belts sideways. **Remember this one** — uv-scrolling is exactly how Chapter 12 fakes moving water.
3. Set `WRAP_S/T` to `gl.CLAMP_TO_EDGE` and sample with uvs up to 2.0 — see the border-smear. Decide for yourself why this (not REPEAT) is right for, say, a HUD icon.
4. **Stretch:** Write a `texture_load_params` variant taking wrap and filter modes as arguments with Odin default parameter values (`wrap: i32 = gl.REPEAT`, …). `texture_load` becomes a one-line call into it. The sea, terrain, and UI chapters all want different sampling.

## Commit

```
git commit -m "ch06: textures — stb_image, mipmaps, crate on quad"
```

Prev: [Chapter 5 — Quads & Indices](ch05-quads-and-indices.md) · Next: [Chapter 7 — The Mathematics of Motion](ch07-the-mathematics-of-motion.md)
