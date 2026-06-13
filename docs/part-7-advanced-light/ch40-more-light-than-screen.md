# Chapter 40 — More Light than Screen

*Part 7 — Advanced Light · Estimated time: 4h · learnopengl: [HDR](https://learnopengl.com/Advanced-Lighting/HDR)*

**What you'll see when done:** the setting sun is a searing bright disk with believable falloff instead of a clipped white circle, and an exposure key lets you "open the aperture" at dusk.

## Where we are

Shadow mapping gave you a second render pass; this chapter gives you a second *target*. Until now every shader has written colors straight into an 8-bit-per-channel window backbuffer, where anything above 1.0 is silently clamped. The sun is *thousands* of times brighter than the sea — your sunset has been lying to you. Today we let the scene be as bright as it wants, and only at the very end squeeze it onto the screen. This is also the chapter where the renderer grows up structurally: a `Renderer` that owns render targets and passes.

## Concepts

### Why LDR clamps kill sunsets

In the real scene, sun ≈ 50, sun glitter on waves ≈ 5, sky near sun ≈ 3, lit sail ≈ 1.2, shaded water ≈ 0.05. Clamped to [0,1], the top four all become "1.0, white-ish". Every relationship between bright things is destroyed *before* you ever see it; bloom (next chapter) has nothing to find; specular highlights are flat white pancakes. The fix is **high dynamic range** rendering: compute and store lighting in floating point, then map it down deliberately.

### The HDR pipeline

```
 lighting shaders          tonemap shader
 (unclamped values)        (HDR -> LDR + gamma)
        |                        |
        v                        v
 +---------------+        +-----------------+
 | RGBA16F FBO   | -----> | default         |
 | + depth tex   | sample | framebuffer     |
 +---------------+        +-----------------+
   "scene target"          fullscreen pass
```

Two new pieces: a framebuffer whose color attachment is `RGBA16F` (half-floats: range ±65504, plenty), and a **fullscreen tonemap pass** that samples it, applies tone mapping + gamma, and writes to the screen.

We attach the depth buffer as a *texture* too, not a renderbuffer — Chapter 46's soft particles will thank us.

### The fullscreen-triangle trick

You could draw a quad. The idiomatic move is one oversized triangle that covers the screen — fewer edges, no diagonal seam, and it needs *no vertex buffer at all*. Generate positions from `gl_VertexID`:

```glsl
// fullscreen.vert — no attributes!
out vec2 v_uv;
void main() {
    // ids 0,1,2 -> (0,0) (2,0) (0,2) in uv -> covers the whole screen
    v_uv = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2);
    gl_Position = vec4(v_uv * 2.0 - 1.0, 0.0, 1.0);
}
```

Core profile still requires *a* VAO to be bound, so create one empty VAO and `gl.DrawArrays(gl.TRIANGLES, 0, 3)`.

### Exposure and tone mapping operators

Tone mapping is a curve from unbounded radiance to [0,1]. Exposure is a multiplier applied first — your camera's aperture. The three operators worth knowing:

- **Reinhard** — `c / (c + 1)`. Never clips, but washes out brights into gray; whites never reach white.
- **Exposure** — `1 - exp(-c * exposure)`. Filmic-ish toe, simple, decent.
- **ACES (fitted)** — a polynomial fit (by Krzysztof Narkowicz) of the film industry's ACES curve. Adds pleasing saturation and shoulder rolloff; this is the "looks like a screenshot from a real game" knob:

```glsl
vec3 aces(vec3 x) {
    const float a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
    return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0);
}
```

### Where gamma lives now

In Chapter 16 you added `pow(color, vec3(1.0/2.2))` to the end of each lighting shader. That was correct *then*; now it's wrong twice over: intermediate HDR values must stay **linear** (light only adds correctly in linear space), and gamma must be applied exactly once. New law of the codebase: **all lighting shaders output linear radiance; the tonemap pass owns gamma.** You will delete every per-shader `pow` today. (sRGB *texture decode* from ch16 stays — inputs still need linearizing.)

### The render-graph moment

You now have: shadow pass → scene pass (into HDR target) → tonemap pass (to screen). Plus reflection/refraction FBOs from ch30. That's a *graph* of passes and targets, and it deserves a home: a `Renderer` struct that owns targets and exposes `renderer_begin_hdr` / `renderer_end_hdr`. Every later chapter (bloom, soft particles, grading) slots into this skeleton.

## Odin notes

A resize callback must recreate the HDR target. Odin makes the cleanup pattern painless: give `Render_Target` a `_create`/`_destroy` pair and call destroy-then-create in the GLFW framebuffer-size callback. Remember GLFW callbacks are `proc "c"` — you'll need `context = runtime.default_context()` (or your stored context) inside, as you set up back in ch2.

## Build

1. **`Render_Target` and `Renderer`.** New file `src/renderer.odin`:

   ```odin
   Render_Target :: struct {
       fbo:        u32,
       color_tex:  u32,
       depth_tex:  u32,
       width, height: i32,
   }

   Renderer :: struct {
       hdr:            Render_Target,
       tonemap_shader: Shader,
       fullscreen_vao: u32,
       exposure:       f32,
       tonemap_mode:   i32, // 0 reinhard, 1 exposure, 2 aces
   }
   ```

   `render_target_create(w, h)` builds the FBO: color = `gl.RGBA16F` (note: `gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA16F, w, h, 0, gl.RGBA, gl.FLOAT, nil)`), filtering `LINEAR`, clamp to edge; depth = `gl.DEPTH_COMPONENT24` texture attached to `gl.DEPTH_ATTACHMENT`. Check completeness.

2. **Begin/end.** The two procs the main loop calls:

   ```odin
   renderer_begin_hdr :: proc(r: ^Renderer) {
       gl.BindFramebuffer(gl.FRAMEBUFFER, r.hdr.fbo)
       gl.Viewport(0, 0, r.hdr.width, r.hdr.height)
       gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT | gl.STENCIL_BUFFER_BIT)
   }

   renderer_end_hdr :: proc(r: ^Renderer) {
       gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
       gl.Disable(gl.DEPTH_TEST)
       shader_use(r.tonemap_shader)
       shader_set_i32(r.tonemap_shader, "u_mode", r.tonemap_mode)
       shader_set_f32(r.tonemap_shader, "u_exposure", r.exposure)
       gl.ActiveTexture(gl.TEXTURE0)
       gl.BindTexture(gl.TEXTURE_2D, r.hdr.color_tex)
       gl.BindVertexArray(r.fullscreen_vao)
       gl.DrawArrays(gl.TRIANGLES, 0, 3)
       gl.Enable(gl.DEPTH_TEST)
   }
   ```

   Reroute the main loop: shadow pass → `renderer_begin_hdr` → everything you used to draw → `renderer_end_hdr`. The ch30 reflection/refraction FBO renders stay where they are (before the HDR pass); consider upgrading their formats to RGBA16F too so reflected suns stay hot.

3. **`tonemap.frag`.** Sample, expose, map, gamma:

   ```glsl
   uniform sampler2D u_hdr;
   uniform float u_exposure;
   uniform int u_mode;
   in vec2 v_uv;
   out vec4 frag;

   void main() {
       vec3 c = texture(u_hdr, v_uv).rgb * u_exposure;
       if      (u_mode == 0) c = c / (c + 1.0);
       else if (u_mode == 1) c = 1.0 - exp(-c);
       else                  c = aces(c);
       frag = vec4(pow(c, vec3(1.0 / 2.2)), 1.0);
   }
   ```

4. **Kill the old gamma.** Grep `assets/shaders/` for `1.0 / 2.2` and `1.0/2.2`; delete every occurrence outside `tonemap.frag`. The scene will look identical-ish afterward — if it suddenly looks *double-dark* or *double-bright*, you missed one or deleted the tonemap's.

5. **Turn the lights up.** Freed from the clamp, give the sun a real intensity: multiply your sun color by 3–6 in the uniform you upload; make the sun disk in the sky shader output 20+; make lantern point lights 10–50 with their attenuation. Tune by eye with the exposure key.

6. **Controls.** Bind `[`/`]` to halve/double exposure (multiplicative feels right — light is logarithmic), and a key to cycle `tonemap_mode`. Print the values.

7. **Resize.** In the framebuffer-size callback: `render_target_destroy(&r.hdr); r.hdr = render_target_create(w, h)`.

## Checkpoint

Sail toward the sunset and cycle the three operators: Reinhard turns the sun's surroundings milky-gray; exposure mode is warmer; ACES gives the sky a saturated orange shoulder and the sun a tight hot core with smooth falloff. Tap `[` a few times — the world dims like sunglasses but the sun disk *stays bright*, exactly like a real camera stopping down.

- With exposure at 1.0 and ACES, the scene's overall brightness roughly matches chapter 39 (gamma still applied exactly once).
- Sun glitter on waves shows a *gradient* of brightness instead of uniform white speckles.
- Resizing the window doesn't stretch or garbage the image.
- A debug render of the HDR texture's raw values (before tonemap) shows blown-out white near the sun — that's the headroom working.

## Pitfalls

- **Everything washed out / pale gray.** Gamma applied twice — a lighting shader still has its `pow`. Grep again.
- **Everything dark and oversaturated.** Gamma applied zero times — you deleted the tonemap's `pow` along with the others.
- **Black screen after the change.** The fullscreen pass needs *some* VAO bound in core profile, even with no attributes. Bind your empty `fullscreen_vao`.
- **Scene renders but stays clamped, sun still a flat disk.** Internal format is `RGBA8` because the `TexImage2D` *internalformat* arg says `gl.RGBA` instead of `gl.RGBA16F`. The third argument is the one that matters.
- **Stencil outline (ch38) stopped working.** Your HDR FBO has no stencil. Either add a `DEPTH24_STENCIL8` combined attachment (`gl.TexImage2D(..., gl.DEPTH24_STENCIL8, ..., gl.DEPTH_STENCIL, gl.UNSIGNED_INT_24_8, nil)` on `gl.DEPTH_STENCIL_ATTACHMENT`) or accept outlines drawing in the tonemapped pass.
- **Reflection FBO sun looks dull while the real sun glows.** The ch30 FBOs are still RGBA8 and clamping. Upgrade them to 16F.

## Exercises

1. Add a fourth mode: *uncharted-style* `c/(c+1)` per-channel vs luminance-based Reinhard (`l = dot(c, vec3(0.2126, 0.7152, 0.0722))`, scale by `l'/l`). Compare hue preservation near the sun.
2. Hold a key to sample the HDR texture's center pixel via `gl.ReadPixels` (float) and print its radiance — measure your sun.
3. Auto-exposure, crude edition: each frame, read back a tiny 4×4 mipmap of the HDR target (or `gl.GenerateMipmap` + read the top level), compute average luminance, and lerp exposure toward `0.5 / avg` over a second or two. Walk from a bright beach into a cliff's shadow and watch your eyes "adjust."
4. **Stretch:** make `Renderer` own the *shadow* pass too (`renderer_begin_shadow/end_shadow`), so `main` reads as a clean list of passes. This is the seed of a real render graph.

## Commit

`git commit -m "ch40: HDR pipeline — RGBA16F target, fullscreen tonemap, exposure, ACES"`

[← Ch. 39: Shadows on the Water](ch39-shadows-on-the-water.md) · [Ch. 41: The Sun Bleeds →](ch41-the-sun-bleeds.md)

> ⚓ **Optional side quest:** [Interlude 40a — The Eye Adjusts](ch40a-the-eye-adjusts.md) — auto-exposure with eye-adaptation lag, metered entirely on the GPU with a mipmap trick.
