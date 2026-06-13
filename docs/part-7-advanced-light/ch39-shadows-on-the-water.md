# Chapter 39 — Shadows on the Water

*Part 7 — Advanced Light · Estimated time: 5h · learnopengl: [Shadow Mapping](https://learnopengl.com/Advanced-Lighting/Shadows/Shadow-Mapping)*

**What you'll see when done:** at low sun, your boat drags a long soft shadow across the swells, and island ridges throw shade into their own valleys.

## Where we are

Your lighting so far has a tell: nothing blocks the sun. The boat is lit as if the mast casts no shade on the deck; valleys are as bright as ridgetops. Shadow mapping fixes this, and it's the single biggest realism jump left in the course. It's also the first time you render the scene *twice* per frame — a habit the rest of Part 7 will build on.

## Concepts

### The idea in one paragraph

A point is in shadow if something stands between it and the sun. Testing that with rays is expensive; the rasterizer gives it to us almost free. Render the scene from the *sun's point of view* into a depth-only framebuffer — the **shadow map**. Each texel answers: "how far from the sun is the nearest surface along this direction?" Then in your normal lighting pass, transform each fragment into the sun's clip space, compare its depth against the stored one. Stored depth smaller → something is closer to the sun than you → you're in shadow.

```
            sun
             |  ortho frustum
        +----v----+
        |  depth  |   pass 1: scene -> shadow map (depth only)
        |   map   |
        +---------+
             |
   fragment P: project into light space,
   compare P.z  vs  shadowmap[P.xy]      pass 2: normal render
   P.z > stored + bias  =>  in shadow
```

### Light-space matrix: orthographic, because the sun is far

A directional light has no position, so perspective makes no sense — use `glsl.mat4Ortho3d` (that's the Odin name; verify-it-yourself link: [pkg.odin-lang.org/core/math/linalg/glsl](https://pkg.odin-lang.org/core/math/linalg/glsl/)) combined with a `glsl.mat4LookAt` pointed along the sun direction. The matrix `light_proj * light_view` maps a world position into the sun's clip space; we call it `light_space`.

### The shadow box must follow the camera

A naive ortho box covering the whole archipelago spreads your 2048² texels over kilometers — each texel becomes a meter-wide blob. The fix: make the ortho box only cover *where the player is looking*, and move it every frame. Practical recipe (a simplified version of what cascades do):

1. Pick a shadow distance, say 80 m — shadows beyond that fade out.
2. Center the box at `camera.position + camera_forward * (shadow_distance * 0.5)`.
3. Build `light_view = glsl.mat4LookAt(center - sun_dir * 200, center, {0,1,0})` and an ortho box of half-size ~`shadow_distance`, with generous near/far (`1` to `400`) so tall islands *behind* the box still cast into it.
4. **Snap the box to texel-sized increments** in light space. If you skip this, the shadow edges crawl and shimmer every time the camera moves — the most common "my shadows boil" complaint.

> **Further reading — cascades.** Production engines split the view frustum into 3–4 depth ranges with one shadow map each ("cascaded shadow maps"), which is exactly this trick applied at several scales. When you want crisp shadows at 5 m *and* 500 m, read learnopengl's [CSM guest article](https://learnopengl.com/Guest-Articles/2021/CSM). Today, one well-fitted box is plenty.

### Acne, bias, and peter-panning: the eternal triangle

The shadow map is discrete; a surface sampling its *own* depth texel will randomly self-shadow, producing stripey **shadow acne**. The cure is a **bias**: treat the fragment as slightly closer to the sun than it is. Too much bias and shadows detach from their objects' feet — **peter-panning** (objects appear to float, like Peter Pan's escaped shadow). The good middle ground is a **slope-scaled bias**: surfaces facing the sun need almost none; grazing surfaces need more:

```glsl
float bias = max(0.05 * (1.0 - dot(N, L)), 0.005);
```

Two more tools if tuning gets hard: cull *front* faces during the shadow pass (`gl.CullFace(gl.FRONT)`) so the stored depth is the object's back side — acne moves to surfaces that are in shadow anyway; and `gl.PolygonOffset` from ch38 applied during the depth pass.

### PCF: soft edges for cheap

A raw comparison gives hard, aliased, one-texel-staircase edges. **Percentage-closer filtering** samples a 3×3 neighborhood of the shadow map, does the comparison per sample, and averages the nine 0/1 results into a soft factor. It's nine fetches, the GPU doesn't blink, and it sells the whole effect.

### Shadows on water

The ocean is just another lit surface — pass `light_space` and the shadow map to the water shader and multiply the sun's diffuse + specular contribution by the shadow factor. At low sun this looks *terrific*: the boat's shadow rides over wave crests, and islands lay dark lanes across the sea. One subtlety: sample using the **displaced** Gerstner world position (the one you computed in the vertex shader), not the flat grid position, or shadows will swim against the waves.

## Build

1. **Shadow map FBO.** A depth-only framebuffer; we explicitly tell GL there's no color:

   ```odin
   SHADOW_SIZE :: 2048

   gl.GenTextures(1, &shadow_tex)
   gl.BindTexture(gl.TEXTURE_2D, shadow_tex)
   gl.TexImage2D(gl.TEXTURE_2D, 0, gl.DEPTH_COMPONENT24, SHADOW_SIZE, SHADOW_SIZE,
                 0, gl.DEPTH_COMPONENT, gl.FLOAT, nil)
   gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST)
   gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST)
   gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_BORDER)
   gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_BORDER)
   border := [4]f32{1, 1, 1, 1} // outside the box = max depth = lit
   gl.TexParameterfv(gl.TEXTURE_2D, gl.TEXTURE_BORDER_COLOR, &border[0])

   gl.GenFramebuffers(1, &shadow_fbo)
   gl.BindFramebuffer(gl.FRAMEBUFFER, shadow_fbo)
   gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.DEPTH_ATTACHMENT, gl.TEXTURE_2D, shadow_tex, 0)
   gl.DrawBuffer(gl.NONE)
   gl.ReadBuffer(gl.NONE)
   ```

   Check completeness with `gl.CheckFramebufferStatus` as you did in ch30.

2. **Light-space matrix each frame.** Compute it on the CPU, with texel snapping:

   ```odin
   shadow_light_space :: proc(cam: ^Camera, sun_dir: glsl.vec3) -> glsl.mat4 {
       center := cam.position + camera_forward(cam) * (SHADOW_DIST * 0.5)
       view   := glsl.mat4LookAt(center - sun_dir * 200.0, center, {0, 1, 0})

       // snap the box origin to whole shadow-map texels
       texel := (2.0 * SHADOW_DIST) / f32(SHADOW_SIZE)
       c := (view * glsl.vec4{center.x, center.y, center.z, 1}).xyz
       c.x = math.floor(c.x / texel) * texel
       c.y = math.floor(c.y / texel) * texel
       // rebuild view translated by the snap delta, or equivalently bake it
       // into the ortho offsets — either works; keep whichever reads cleaner.

       proj := glsl.mat4Ortho3d(-SHADOW_DIST, SHADOW_DIST, -SHADOW_DIST, SHADOW_DIST, 1.0, 400.0)
       return proj * view
   }
   ```

3. **Depth-only shader.** `shadow_depth.vert` is three lines — `gl_Position = u_light_space * u_model * vec4(a_position, 1.0);` — and the fragment shader is *empty* (depth writes happen regardless). One shader serves every mesh.

4. **The shadow pass.** At the top of your frame render, before the main pass:

   ```odin
   gl.Viewport(0, 0, SHADOW_SIZE, SHADOW_SIZE)
   gl.BindFramebuffer(gl.FRAMEBUFFER, shadow_fbo)
   gl.Clear(gl.DEPTH_BUFFER_BIT)
   gl.CullFace(gl.FRONT) // back-side depths: tames acne
   shader_use(shadow_shader)
   shader_set_mat4(shadow_shader, "u_light_space", &light_space)
   draw_all_casters() // terrain chunks + boat + buoys; NOT ocean, NOT sky
   gl.CullFace(gl.BACK)
   gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
   gl.Viewport(0, 0, window_w, window_h)
   ```

   The ocean doesn't cast (waves shadowing terrain is imperceptible and the displaced mesh complicates things); it only *receives*.

5. **Receive in the lighting shaders.** In each receiving vertex shader, add `out vec4 v_light_space_pos = u_light_space * vec4(world_pos, 1.0);`. In the fragment shaders (terrain, boat/buoy, water), add the lookup with slope-scaled bias and 3×3 PCF:

   ```glsl
   float shadow_factor(vec4 lsp, vec3 N, vec3 L) {
       vec3 p = lsp.xyz / lsp.w * 0.5 + 0.5;       // [0,1] shadow-map space
       if (p.z > 1.0) return 1.0;                   // beyond the box: lit
       float bias = max(0.05 * (1.0 - dot(N, L)), 0.005);
       vec2 texel = 1.0 / vec2(textureSize(u_shadow_map, 0));
       float lit = 0.0;
       for (int x = -1; x <= 1; ++x)
       for (int y = -1; y <= 1; ++y) {
           float d = texture(u_shadow_map, p.xy + vec2(x, y) * texel).r;
           lit += (p.z - bias) > d ? 0.0 : 1.0;
       }
       return lit / 9.0;
   }
   ```

   Multiply diffuse and specular by it — never ambient, or shadows go pitch black:
   `vec3 color = ambient + shadow * (diffuse + specular);`

6. **Water.** Same function in the ocean fragment shader; compute `v_light_space_pos` from the Gerstner-displaced position. Sail at sunset and watch the hull's shadow stretch.

7. **Fade at the box edge.** Shadows that end in a hard line at 80 m look broken. Fade the factor toward 1.0 over the last 10–20% of distance from the box center — a one-line `mix` keyed on `length(p.xy * 2.0 - 1.0)`.

## Checkpoint

Low morning sun: the mast lays a thin line of shade across the deck and onto the water; island ridges shade their west slopes; sailing close past a cliff puts your whole boat into cool shadow.

- Toggle a debug key that renders the shadow map grayscale in a corner quad — you should recognize the terrain and boat silhouettes from above-at-an-angle.
- Orbit the camera: shadow edges stay put (texel snapping working) rather than crawling.
- No stripes on sunlit terrain (acne handled); boat shadow connects to the hull at the waterline (no peter-panning).
- Shadows visibly soften over a few pixels at their edges (PCF).

## Pitfalls

- **Whole world in shadow.** Your light-space depth comparison is inverted, or you sampled with `p` not remapped from [-1,1] to [0,1].
- **Shadows only in one quadrant of the world.** You forgot to reset `gl.Viewport` after the shadow pass — the main scene rendered into a 2048×2048 corner. Everyone does this once.
- **Stripes everywhere (acne).** Bias too small, or you applied bias in the *shadow pass* instead of the comparison. Try front-face culling in the depth pass before cranking bias.
- **Shadows detached from objects (peter-panning).** Bias too big. Drop the constant term first; the slope term does most of the work.
- **Shadow pops in/out as the camera turns.** Your ortho near/far is too tight: a tall island behind the box stops being rendered into the map. Extend the light-view near plane backward (the `- sun_dir * 200` and far=400 above).
- **Shadows swim across the ocean.** You sampled light-space using the undisplaced grid position. Use the displaced world position from the Gerstner math.

## Exercises

1. Make `SHADOW_DIST` and the bias constants live-tweakable (keys or your shader hot-reload) and find your favorite trade-off between reach and crispness.
2. Render the shadow map debug quad with linearized values and watch what texel snapping does: disable snapping and observe the boiling edges.
3. At night the moon is your directional light (ch27) — feed the moon direction into the same pipeline and get moon shadows for free.
4. **Stretch:** two cascades — a 0–30 m box and a 30–120 m box, two FBOs, select per fragment by distance. Compare deck-detail sharpness against the single box.

## Commit

`git commit -m "ch39: directional shadow mapping with PCF and camera-following light box"`

[← Ch. 38: Depths & Stencils](ch38-depths-and-stencils.md) · [Ch. 40: More Light than Screen →](ch40-more-light-than-screen.md)

> ⚓ **Optional side quest:** [Interlude 39a — Lanterns in the Dark](ch39a-lanterns-in-the-dark.md) — a depth cubemap gives the nearest lantern true omnidirectional shadows that swing with the swell.
