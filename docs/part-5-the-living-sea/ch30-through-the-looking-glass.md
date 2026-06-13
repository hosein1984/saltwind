# Chapter 30 — Through the Looking Glass

*Part 5 — The Living Sea & Sky · Estimated time: 4h · learnopengl: [Framebuffers](https://learnopengl.com/Advanced-OpenGL/Framebuffers)*

**What you'll see when done:** islands, buoys, and the boat hull reflected in the water — wobbling with the waves — and real sandy shallows visible *through* the surface near every beach.

## Where we are

Chapter 29's water reflects the sky function, but islands cast no reflection and the sea is opaque paint. Both fixes need the same tool: rendering the scene to a **texture** instead of the screen, then sampling that texture from the water shader. This is the framebuffer chapter — the single most reusable technique left in the course (shadows, HDR, and bloom in Part 7 are all "framebuffers plus an idea").

## Concepts

### Framebuffers: the screen is not special

Everything you've rendered so far went to the **default framebuffer** — the window, created by GLFW. A *framebuffer object* (FBO) is a user-made render destination, assembled from attachments:

```
            Framebuffer Object
            +---------------------------+
  draw -->  | COLOR_ATTACHMENT0 ------> texture (sample it later)
            | DEPTH_STENCIL    -------> renderbuffer (opaque, fast)
            +---------------------------+
```

- A **texture attachment** is a normal texture you can sample afterward — use it for anything you need to *read*.
- A **renderbuffer** is a write-only attachment — faster, for buffers you only need *during* the pass (almost always depth).

An FBO must be **complete** before use: at least one attachment, all attachments the same size, formats renderable. `gl.CheckFramebufferStatus(gl.FRAMEBUFFER) == gl.FRAMEBUFFER_COMPLETE` or you get nothing and GL won't say why loudly. Two eternal companions of FBO work: set `gl.Viewport` to the FBO's size when you bind it (and back!), and remember `gl.Clear` clears the *currently bound* framebuffer.

### Planar reflection: render the world from underwater

For a mirror lying in the plane y = 0, the reflection seen from camera C is exactly what a second camera C′ — C mirrored through the plane — sees. Our `Camera` makes the mirror trivial:

```
        C  (y=5, pitch=-10°)              real camera looks down at water
   ~~~~~~~~~~~~~~~~~ y=0 ~~~~~~~
        C' (y=-5, pitch=+10°)             mirrored camera looks up from below
```

Negate `position.y` and negate `pitch`; yaw stays. Render the scene from C′ into the reflection FBO. Because C′ is a proper camera (a rotation, not a true mirror transform), its image is the reflection *flipped vertically* — so when sampling, flip: `uv = vec2(ndc.x, 1.0 - ndc.y)`. (The alternative — composing the view matrix with a mirror matrix — avoids the flip but reverses triangle winding; the negate-pitch version is the one that won't fight your face culling.)

One problem: the mirrored camera sees geometry *below* the water (the underwater half of islands), which would reflect terrain that should be hidden. Fix with a **clip plane**: enable `gl.CLIP_DISTANCE0` and have each vertex shader write `gl_ClipDistance[0]`. Positive keeps the vertex, negative clips it. For a plane stored as `vec4(a,b,c,d)` (normal + offset), the distance is one dot product: `dot(vec4(world_pos, 1.0), u_clip_plane)`.

### Refraction: the underwater pass

Same idea, no mirrored camera: render the scene from the *real* camera but keep only what's **below** the water (clip plane flipped), into a second FBO. Sampling this under the water surface gives you true see-through shallows — sand tinted blue-green by depth, replacing every approximation since Chapter 24.

### Projective texturing: where do I sample?

The reflection texture is a rendered *screenful*. Which texel corresponds to the water fragment you're shading? The fragment's own screen position. Pass clip-space position from the vertex shader, perspective-divide in the fragment shader, remap from NDC [−1,1] to UV [0,1]:

```glsl
vec2 ndc = (v_clip_pos.xy / v_clip_pos.w) * 0.5 + 0.5;
```

This is **screen-space projective texturing**, and it's also how shadow mapping will find its texels in Chapter 39.

### Distortion, and the price of half measures

Sampling the textures directly gives glassy, suspiciously perfect reflections. Offset the UVs by the water's detail normals (or a dedicated **DuDv map** — a texture storing 2D offsets, same idea) and the reflection wobbles with the waves. Finally: reflections don't need full resolution — half-res reflection FBOs are an industry-standard 4× savings that the wobble completely hides.

## Build

1. **Build the `Render_Target` abstraction** in `src/render_target.odin`:

   ```odin
   Render_Target :: struct {
       fbo, color, depth_rbo: u32,
       width, height:         i32,
   }

   render_target_create :: proc(w, h: i32) -> (rt: Render_Target, ok: bool) {
       rt.width, rt.height = w, h
       gl.GenFramebuffers(1, &rt.fbo)
       gl.BindFramebuffer(gl.FRAMEBUFFER, rt.fbo)
       defer gl.BindFramebuffer(gl.FRAMEBUFFER, 0)

       gl.GenTextures(1, &rt.color)
       gl.BindTexture(gl.TEXTURE_2D, rt.color)
       gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGB8, w, h, 0, gl.RGB, gl.UNSIGNED_BYTE, nil)
       gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
       gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
       gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
       gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
       gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, rt.color, 0)

       gl.GenRenderbuffers(1, &rt.depth_rbo)
       gl.BindRenderbuffer(gl.RENDERBUFFER, rt.depth_rbo)
       gl.RenderbufferStorage(gl.RENDERBUFFER, gl.DEPTH24_STENCIL8, w, h)
       gl.FramebufferRenderbuffer(gl.FRAMEBUFFER, gl.DEPTH_STENCIL_ATTACHMENT, gl.RENDERBUFFER, rt.depth_rbo)

       ok = gl.CheckFramebufferStatus(gl.FRAMEBUFFER) == gl.FRAMEBUFFER_COMPLETE
       return
   }
   ```

   Write `render_target_destroy` (delete texture, renderbuffer, framebuffer) and a `render_target_bind` that binds and sets `gl.Viewport(0, 0, rt.width, rt.height)`. Note `nil` for pixel data — allocate, don't upload.

2. **Add two targets to `Game`:** `reflection` at **half** window resolution, `refraction` at full (it carries the shallows detail). Recreate both in your window-resize callback — stretched stale FBOs are an instantly recognizable bug.

3. **Teach scene shaders to clip.** In every vertex shader that draws *into* these passes (terrain, lit objects — the sky always passes), add:

   ```glsl
   uniform vec4 u_clip_plane;   // set to (0,0,0,1) = "keep everything" normally
   // in main(), after computing world position:
   gl_ClipDistance[0] = dot(vec4(world.xyz, 1.0), u_clip_plane);
   ```

   On the CPU, `gl.Enable(gl.CLIP_DISTANCE0)` before the FBO passes and `gl.Disable` after — when disabled, the written distance is simply ignored, so the uniform default never hurts.

4. **Restructure the frame** into a `render_scene(game, camera, clip_plane)` proc (everything *except* the water), then:

   ```odin
   // 1: reflection pass — mirrored camera, keep what's above water
   refl_cam := game.camera
   refl_cam.position.y = -refl_cam.position.y
   refl_cam.pitch      = -refl_cam.pitch
   gl.Enable(gl.CLIP_DISTANCE0)
   render_target_bind(game.reflection)
   gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
   render_scene(game, refl_cam, {0, 1, 0, 0.1})     // y > -0.1 survives

   // 2: refraction pass — real camera, keep what's below
   render_target_bind(game.refraction)
   gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
   render_scene(game, game.camera, {0, -1, 0, 0.1}) // y < 0.1 survives
   gl.Disable(gl.CLIP_DISTANCE0)

   // 3: main pass — back to the window
   gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
   gl.Viewport(0, 0, window_w, window_h)
   gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
   render_scene(game, game.camera, {0, 0, 0, 1})
   ocean_draw(game)                                  // water reads both textures
   ```

   The `0.1` bias overlaps the two passes slightly so wave-displaced water never reveals an unrendered gap at the shoreline.

5. **Sample in the water shader.** Vertex: `v_clip_pos = gl_Position;` (declare an `out vec4`). Fragment:

   ```glsl
   vec2 ndc      = (v_clip_pos.xy / v_clip_pos.w) * 0.5 + 0.5;
   vec2 distort  = detail.xz * 0.02;                  // reuse ch29's detail normal
   vec2 refl_uv  = clamp(vec2(ndc.x, 1.0 - ndc.y) + distort, 0.001, 0.999);
   vec2 refr_uv  = clamp(ndc + distort, 0.001, 0.999);

   vec3 reflection = texture(u_reflection, refl_uv).rgb;
   vec3 refraction = texture(u_refraction, refr_uv).rgb;
   ```

   Then upgrade Chapter 29's final mix: the *body* color becomes the refraction tinted by your deep/shallow colors, and the *reflected* side blends the rendered reflection over the analytic sky (the texture wins where it has content; keep `sky_color(R, ...)` as the always-correct base):

   ```glsl
   vec3 body = mix(refraction * u_shallow_color * 2.0, u_deep_color, depth_fade);
   vec3 refl = mix(sky, reflection, 0.8);
   vec3 col  = mix(body, refl, fresnel);
   ```

   Bind the two textures to units 0 and 1 (`gl.ActiveTexture(gl.TEXTURE0 + n)`), detail map to 2 — and set the sampler uniforms once at init (`shader_set_i32`).

6. **Tune.** Distortion `0.02` is a starting point; too high and islands' reflections tear apart. If the reflection looks pixelated, that's the half-res FBO — the distortion should disguise it; raise to full-res only if it bothers you in stills.

## Checkpoint

Sail (fly, for one more part) close to an island at golden hour: the island reflects in the swell, the reflection wobbling as waves pass. Near the beach, the sandy bottom shows through blue-green water that deepens convincingly.

- Reflections of islands sit *under* the islands and move correctly as you move (flip and projection right).
- No upside-down terrain poking through wave crests near shore (clip bias working).
- The shallows tint comes from actual rendered terrain now — stand over deep water and the bottom fades to `deep_color`.
- Frame cost: roughly 2.3× scene draws (full + half-res + clipped refraction). Note your new frame time; Chapter 49 will ask.

## Pitfalls

- **Both FBO textures pure black.** Incompleteness — run the `CheckFramebufferStatus` assert; the classic causes are a 0×0 size (resize callback ran before creation) or forgetting the color attachment entirely.
- **Main view renders tiny in a corner of the window.** You set the FBO viewport and never restored the window's. Every `render_target_bind` needs a matching viewport restore in step 4's main pass.
- **Reflection upside down or sliding oppositely.** Missing the `1.0 - ndc.y` flip, or you mirrored position but forgot pitch (or vice versa).
- **Reflected islands visible through other islands / haloes at the waterline.** Clip distance isn't actually active: `gl.Enable(gl.CLIP_DISTANCE0)` missing, or one shader in the pass never writes `gl_ClipDistance[0]` (then the value is undefined — some drivers keep everything, some clip everything).
- **Weird smearing at screen edges when waves distort.** Distorted UVs escaping [0,1] with the wrong wrap mode — the `clamp` in step 5 plus `CLAMP_TO_EDGE` on the FBO textures handles it.
- **Everything doubles in cost and the reflection shows the water itself.** You included `ocean_draw` inside `render_scene` — the water must not render into its own source textures.

## Exercises

1. Draw both FBO textures as small overlay quads in a corner (a fixed quad, no view matrix — you've had a 2D-capable shader since Chapter 5). Keep it behind a debug key forever; "look at the actual texture" solves half of all FBO bugs.
2. Try reflection at quarter-res and refraction at half. Find your taste threshold; note that distortion strength and resolution trade off against each other.
3. Add a `u_reflectivity` slider (0..1) scaling the reflection blend, and find where "Caribbean postcard" becomes "chrome".
4. **Stretch:** the Fresnel mix can pop where the refraction texture has no data (deep water beyond the far plane of useful content). Fade `refraction`'s contribution by the *refraction pass depth*: attach a depth **texture** instead of a renderbuffer to the refraction target, sample it, linearize, and compute true water depth per pixel — this is also exactly the soft-edge technique Chapter 46 uses for particles, so you're scouting ahead.

## Commit

`git commit -m "ch30: planar reflection and refraction via framebuffers"`

← [Chapter 29 — The Color of Water](ch29-the-color-of-water.md) · [Chapter 31 — Milestone: Ocean at Sunset](ch31-milestone-ocean-at-sunset.md) →
