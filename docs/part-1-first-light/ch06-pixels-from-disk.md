# Chapter 6 — Pixels from Disk

*Part 1 — First Light · Estimated time: 3h · learnopengl: [Textures](https://learnopengl.com/Getting-started/Textures)*

**What you'll see when done:** a wooden crate face filling the quad — real pixels from a real file, filtered and mipmapped, the first imported artwork in Saltwind.

## Where we are

Everything on screen so far is computed color. Worlds need *surfaces*: wood grain, sand, sailcloth. This chapter brings image files onto geometry — decoding with `stb_image`, uploading to GPU texture memory, and configuring the sampling machinery (wrap, filter, mipmaps) that decides what a texture looks like when it's stretched, shrunk, or viewed from a thousand units away. The crate texture you load today gets boxed up into the floating cargo of Chapters 8–13.

## Concepts

### UV coordinates

A texture is addressed in **UV space** (GLSL says `st`, everyone else says `uv`): (0,0) at the bottom-left of the image to (1,1) at the top-right, independent of resolution. Each vertex carries a uv; the rasterizer interpolates it across the triangle; the fragment shader *samples* the texture at the interpolated spot:

```
 (0,1)        (1,1)        v3──────v2     vertex → uv
   ┌────────────┐           │      │      v0 → (0,0)   v1 → (1,0)
   │   image    │           │ quad │      v2 → (1,1)   v3 → (0,1)
   └────────────┘           │      │
 (0,0)        (1,0)        v0──────v1
```

### Wrap modes

What does sampling at uv = 1.7 mean? Your choice, per axis: `gl.REPEAT` (tile — fractional part only; what the sea will use to tile wave detail forever), `gl.MIRRORED_REPEAT`, `gl.CLAMP_TO_EDGE` (smear the border pixel — right for things that shouldn't tile), `gl.CLAMP_TO_BORDER`.

### Filtering

UVs are continuous; texels are discrete — sampling almost never lands dead-center on one. `gl.NEAREST` grabs the closest texel (crunchy, deliberate-retro). `gl.LINEAR` blends the 4 surrounding texels (smooth). Set separately for magnification (texture too close — blown up) and minification (too far — shrunk).

### Mipmaps, explained properly

Minification has a nastier problem than blur. Picture the crate 300 units away, covering 4 pixels on screen. Each pixel's sample lands on *one* arbitrary texel out of the thousands the crate spans — and which texel changes every frame as anything moves. The result is shimmering, crawling noise (and a memory-bandwidth disaster: the GPU pulls scattered texels from all over a big image).

**Mipmaps** pre-solve this: a chain of pre-averaged copies at ½, ¼, ⅛… resolution down to 1×1 (+33% memory, total). At sample time the GPU measures how fast uv changes between adjacent screen pixels (the *derivative* — this is why GPUs shade in 2×2 quads) and picks the mip level whose texels are roughly pixel-sized. Each sample then averages over the correct footprint, because the averaging already happened offline.

The filter modes with `MIPMAP` in the name choose how levels combine: `gl.LINEAR_MIPMAP_LINEAR` — linear within a level *and* blending between two adjacent levels ("trilinear") — is the default-quality choice and what we use. `gl.GenerateMipmap(gl.TEXTURE_2D)` builds the whole chain in one call after upload. Magnification never uses mipmaps (there's nothing *more* detailed to use) — so `MAG_FILTER` must be plain `NEAREST`/`LINEAR`.

### Texture units and samplers

A shader samples through a `uniform sampler2D`. Which texture? Indirection: the GL context has ~16+ numbered **texture units**; `gl.ActiveTexture(gl.TEXTURE0 + n)` selects a unit, `gl.BindTexture` attaches a texture to it, and the sampler uniform is set to the integer `n`. One texture: unit 0, set the sampler to 0, done. The machinery exists so a single draw can read several textures at once — Chapter 22's terrain splatting uses four.

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
