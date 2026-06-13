# Chapter 16 — Honest Colors

*Part 3 — Let There Be Light · Estimated time: 1.5h · learnopengl: [Gamma Correction](https://learnopengl.com/Advanced-Lighting/Gamma-Correction)*

**What you'll see when done:** the same scene, but *right* — richer midtones, sunlight that falls off the way real light does, and shading that survives a squashed sphere.

## Where we are

You now have a competent Phong renderer with materials and multiple lights. It also has two quiet bugs that almost every first renderer ships with: all your lighting math has been happening in a warped color space, and your normal transformation breaks the moment you scale anything non-uniformly. Both fixes are small; understanding them is the point of this chapter.

## Concepts

### Your monitor is lying to your shader

Monitors don't display pixel values linearly. A framebuffer value of 0.5 doesn't emit half the photons of 1.0 — it emits roughly `0.5^2.2 ≈ 0.22` of them. This power curve (≈ gamma 2.2, standardized as **sRGB**) exists for a good reason: human vision is far more sensitive to differences in darks than in brights, so encoding colors with a curve spends the 8 bits per channel where your eye can actually see them. It's perceptual compression, and it's fine — *as long as everyone knows it's happening.*

Your shader didn't know. Lighting math — multiplying by `cos`, adding light contributions, attenuating by distance — is only correct in **linear** space, where 0.5 means half the photons. You computed correct linear values, wrote them to the framebuffer, and the monitor then applied its decode curve to numbers that were never encoded. Result: everything displayed too dark, so you (like everyone) compensated by cranking light values, which crushes the response into a washed-out, plasticky look. The most visible symptom: a light's falloff appears to die abruptly instead of fading long and gently. The [Gamma Correction](https://learnopengl.com/Advanced-Lighting/Gamma-Correction) article's side-by-side images are worth a long look.

```
 shader (linear) ──► framebuffer ──► monitor decodes (^2.2) ──► photons
                          ▲
        we must ENCODE (^1/2.2) here so decode cancels out
```

Two ways to apply the encode:

1. **`gl.Enable(gl.FRAMEBUFFER_SRGB)`** — the GPU encodes automatically on every write to the default framebuffer. Free, exact, one line. Our choice for now.
2. **`pow(color, vec3(1.0/2.2))`** as the last line of the fragment shader — manual, works everywhere, but every shader that writes to the screen must remember it.

When we build post-processing in Chapters 30/40, we'll revisit this: intermediate framebuffers must stay *linear*, and the encode happens once at the very final blit. `FRAMEBUFFER_SRGB` handles that gracefully because it only applies to sRGB-format targets.

### The textures were lying too

Here's the trap that catches people *after* they enable gamma encoding: your sand and crate textures were authored on monitors, in sRGB. Their texel values are already encoded. If you sample them and treat the result as linear, your albedo is wrong (too dark in the math, then brightened at output — the net look is washed out and pale: **double-correction**).

The fix is to tell OpenGL the truth about the data: upload color textures with internal format `gl.SRGB8_ALPHA8` instead of `gl.RGBA8`. The sampler hardware then decodes sRGB→linear *for free* at sample time, before filtering — which also makes mipmap and bilinear blends correct.

The crucial discipline: **only color (albedo) textures are sRGB.** A heightmap, a normal map, a roughness mask — these are *data* stored in image files for convenience. They were never "displayed", never encoded. Decode them and you corrupt them: Chapter 20's heightmap terrain would come out with wrongly-curved slopes, and a future normal map would bend every normal. Make sRGB an explicit flag in your texture loader, defaulting in neither direction — force yourself to decide per texture.

### The normal matrix

Second lie: `mat3(model) * a_normal`. Rotations preserve perpendicularity and uniform scales just stretch length (fixed by `normalize`), but a **non-uniform scale** changes the *direction* a normal should point:

```
   circle, normal ok        squashed in y — transforming the normal
        n                   like a position tilts it the WRONG way:
        |                        n (correct: tilts more upright)
      .---.                     /                       
     (  ·  )                 .--·--.    model*n would flatten it
      '---'                 (___·___)   toward the surface instead
   ```

Positions on the surface flatten; normals must do the opposite to stay perpendicular. The transform that does this is the **inverse transpose** of the model matrix's upper 3×3. (One-line argument: the normal must keep zero dot product with every surface tangent `t`; tangents transform by `M`, so we need `N` with `(N n)·(M t) = 0`, satisfied by `N = (M⁻¹)ᵀ`.) For pure rotation+translation, inverse transpose equals the original 3×3 — which is why the bug hides until you scale something.

Computing an inverse per draw on the CPU is cheap at our scale; do *not* compute it in the shader per vertex.

## Odin notes

`core:math/linalg/glsl` has an `inverse_transpose` procedure group that accepts `glsl.mat4` directly. Odin can convert between matrix sizes — `glsl.mat3(m4)` takes the upper-left 3×3:

```odin
normal_mat := glsl.mat3(glsl.inverse_transpose(model))
```

Uploading a `mat3` follows the same pattern as your `mat4` helper — add `shader_set_mat3`:

```odin
shader_set_mat3 :: proc(s: Shader, name: cstring, m: ^glsl.mat3) {
    gl.UniformMatrix3fv(gl.GetUniformLocation(s.id, name), 1, false, &m[0, 0])
}
```

## Build

1. **Turn on output encoding** once during GL init:

   ```odin
   gl.Enable(gl.FRAMEBUFFER_SRGB)
   ```

   Run it. The scene gets brighter and the lantern falloff suddenly has a long, soft tail. Also: your textures now look pale — expected, fix incoming.

2. **Make the texture loader honest.** Add a flag to `texture_create`:

   ```odin
   texture_create :: proc(path: cstring, srgb: bool) -> Texture {
       // ... stbi.load as before, desired_channels = 4 ...
       internal := i32(gl.SRGB8_ALPHA8) if srgb else i32(gl.RGBA8)
       gl.TexImage2D(gl.TEXTURE_2D, 0, internal, w, h, 0,
                     gl.RGBA, gl.UNSIGNED_BYTE, pixels)
       // ... mipmaps, params as before ...
   }
   ```

   Pass `true` for the crate and sand textures. (The *data* format argument stays `gl.RGBA` — only the internal format changes; the GPU does the decode.)

3. **Retune the lights.** Your Chapter 15 values were tuned against the broken pipeline. Drop ambient to ~0.05–0.1, pull `sun_color` back toward 1.0, and consider swapping the lantern to true inverse-square (`constant=1, linear=0, quadratic=1`, then scale the light color up) — linear-space rendering tolerates physical falloff much better.

4. **Fix the normal path.** In whatever proc issues a mesh draw with a model matrix (your `mesh_draw` or the scene loop), compute and upload the normal matrix alongside `model`:

   ```odin
   normal_mat := glsl.mat3(glsl.inverse_transpose(model))
   shader_set_mat4(shader, "model", &model)
   shader_set_mat3(shader, "normal_mat", &normal_mat)
   ```

   In `lit.vert`: `uniform mat3 normal_mat;` and `v_normal = normal_mat * a_normal;`.

5. **Prove it.** Draw a test sphere with `glsl.mat4Scale({3, 0.6, 3})` — a squashed dome. With the old `mat3(model)` the rim lighting is visibly wrong (toggle to compare); with the normal matrix the dome shades like a real lens shape.

## Checkpoint

Same composition as Chapter 15, but the image reads as *photographed* rather than *painted*: dark sides of crates hold detail, the lantern pool fades over many meters, and the squashed sphere has a correct bright cap.

- Disable `FRAMEBUFFER_SRGB` at runtime with a debug key: the whole scene visibly darkens and falloffs shorten. Re-enable: back to good.
- Albedo textures are not washed out (if they are, they're being decoded twice — see Pitfalls).
- The squashed sphere's highlight sits where a real squashed ball's would, not stretched down the side.

## Pitfalls

- **Washed-out, pale, low-contrast everything.** Double correction. You have *two* of: sRGB internal formats, `pow(1/2.2)` in the shader, `FRAMEBUFFER_SRGB`. Pick the pipeline: sRGB textures in, linear math, `FRAMEBUFFER_SRGB` out — and nothing else.
- **Too dark overall.** Zero corrections: you enabled `FRAMEBUFFER_SRGB` before creating the window's GL context, or your GLFW framebuffer isn't sRGB-capable. Request it via the window hints if needed, and verify the enable actually happened after context creation.
- **Specular highlights suddenly enormous.** Not a bug — linear space reveals how strong your specular constants were. Retune `material.specular` down and `shininess` up.
- **Terrain (Chapter 20) comes out with bizarre plateau-heavy slopes.** Heightmap loaded with `srgb = true`. Data textures stay linear, always.
- **Normal matrix per vertex in GLSL (`transpose(inverse(model))`).** Works, but you're inverting a matrix per vertex per frame. Do it once on the CPU.
- **Lighting unchanged on the squashed sphere even with the fix.** Your model matrix for that draw is built without the scale (e.g., scale baked into mesh vertices) — then there's nothing to fix; bake-time scaling needs no normal correction.

## Exercises

1. Wire a debug key that toggles `FRAMEBUFFER_SRGB` each press and flash the state in the window title. Train your eye on the difference for thirty seconds.
2. Add a `u_gamma` uniform and the manual `pow(color, vec3(1.0/u_gamma))` path; compare 2.2 against the hardware sRGB curve (they differ slightly — sRGB has a linear toe).
3. Photograph (screenshot) a gradient quad from 0 to 1 before and after this chapter; inspect the midpoint pixel value in an image editor.
4. **Stretch:** Make `texture_create` reject obviously-wrong usage: panic (in debug) if a file under `assets/textures/data/` is loaded with `srgb=true`. Filesystem conventions as type safety.

## Commit

`git commit -m "ch16: gamma-correct pipeline, srgb textures, normal matrix"`

← [Chapter 15 — Materials of the Sea-World](ch15-materials-of-the-sea-world.md) · [Chapter 17 — Shapes from Elsewhere](ch17-shapes-from-elsewhere.md) →
