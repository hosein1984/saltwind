# Chapter 8 — Into the Third Dimension

*Part 1 — First Light · Estimated time: 3.5h · learnopengl: [Coordinate Systems](https://learnopengl.com/Getting-started/Coordinate-Systems)*

**What you'll see when done:** a wooden crate floating in space above a vast blue plane stretching to the horizon — Saltwind's first honest 3D frame.

## Where we are

Chapter 7 gave us one transform from model coordinates straight to NDC. Real 3D splits that journey into named stages with a matrix per leg — the **MVP** chain — and adds the **depth buffer** so near things correctly hide far things. By the end of this chapter, the flat era of Saltwind is over for good.

## Concepts

### The coordinate-space pipeline

Every vertex travels:

```
 LOCAL SPACE          crate corner at (±0.5, ±0.5, ±0.5), forever
     │   × Model      (place this object in the world: T·R·S from ch7)
 WORLD SPACE          crate sits at (0, 1.5, 0), 2 units above the sea
     │   × View       (express everything relative to the camera)
 VIEW SPACE           crate is 8 units in front of the camera, slightly left
     │   × Projection (apply perspective; squeeze the view frustum)
 CLIP SPACE           4D, w carries "distance for perspective"
     │   ÷ w          (perspective division — GPU does this, free)
 NDC                  the familiar −1…+1 cube
     │   viewport     (gl.Viewport mapping)
 SCREEN SPACE         actual pixels
```

In the shader it's one line — note the order, right-to-left as always:

```glsl
gl_Position = u_projection * u_view * u_model * vec4(a_position, 1.0);
```

Why three matrices instead of pre-multiplying one MVP on the CPU? Because they change at different rates: projection rarely (resize/zoom), view once per frame, model once per object. Keeping them separate is also how lighting later gets world-space positions (Chapter 14 needs `u_model * position` *without* the rest).

**World space conventions for Saltwind, fixed now and forever:** +Y is up, the sea lives at y=0, one unit ≈ one meter, and we use GL's right-handed system (+X right, +Y up, +Z *toward* the default camera — so "north into the screen" is −Z).

### View: the camera is a lie

The GPU has no camera. To "move the camera right" you transform *the entire world left*. The view matrix is exactly the inverse of where-the-camera-is — and rather than build inverses by hand, `glsl.mat4LookAt(eye, centre, up)` constructs it directly: camera at `eye`, looking at `centre`, with `up` breaking the roll ambiguity. This chapter hardcodes one; Chapter 9 makes it fly.

### Projection: perspective, honestly

`glsl.mat4Perspective(fovy, aspect, near, far)` defines a **frustum** — a truncated pyramid of visible space — and maps it to the NDC cube:

- `fovy`: vertical field of view, radians. ~45–60° reads natural; bigger fish-eyes.
- `aspect`: width/height **of the framebuffer**. This is what finally fixes the squashed-square problem from Chapter 7 — the matrix pre-compensates for the screen's shape. Recompute it on resize and the image stops distorting, period.
- `near`/`far`: clip distances. Things nearer than `near` or beyond `far` vanish.

The trick under the hood: the perspective matrix stores the view-space depth into clip-space **w**, and the GPU divides x,y,z by w after the vertex shader. Far things (big w) shrink toward the center. That's perspective — one division.

### The depth buffer

With 3D comes a new problem: the plane is drawn after the crate (or before — either way), so who wins each pixel? Painter's-order is hopeless for interpenetrating geometry. The **depth buffer** (z-buffer) solves it per fragment: alongside each pixel's color the GPU stores its depth; an incoming fragment is compared (`gl.LESS` by default) and discarded if something nearer already owns the pixel. Enable it, and *clear it every frame* along with color — yesterday's depths are as stale as yesterday's colors.

**Z-fighting**, briefly: depth precision is finite and — thanks to that perspective division — concentrated near the `near` plane. Two surfaces nearly coplanar (a decal on a hull) or a huge `far/near` ratio (near=0.001!) produce flickering stripes as depths tie unpredictably. Rules of thumb: keep `near` as large as you can tolerate (0.1, not 0.001), don't model coplanar surfaces, and we'll meet the proper tools (polygon offset, reversed-z lore) when shadows force the issue in Chapter 39.

## Odin notes

- `glfw.GetFramebufferSize(window)` returns `(width, height)` as a tidy multi-value — query it every frame for the aspect ratio (cheap, and simpler than caching via callback). Guard against a minimized window: height 0 → division by zero → NaN matrix → black screen with no error.
- A 36-vertex array literal is a wall of numbers; Odin's `[?]` sizing at least counts it for you. This is the last hand-typed mesh — Chapter 11 generates them procedurally.

## Build

1. **The cube.** Replace the quad's 4 vertices with a 36-vertex cube (6 faces × 2 triangles × 3 — we deliberately skip the EBO here: with per-face uvs, corner vertices *aren't* shared — a cube corner needs 3 different uvs. Chapter 11 discusses when indexing pays and when it can't). Keep the `Sea_Vertex` struct (position + uv). The pattern, front face shown:

   ```odin
   	cube_vertices := [?]Sea_Vertex{
   		// front face (+z), CCW from outside
   		{{-0.5, -0.5,  0.5}, {0, 0}}, {{ 0.5, -0.5,  0.5}, {1, 0}}, {{ 0.5,  0.5,  0.5}, {1, 1}},
   		{{ 0.5,  0.5,  0.5}, {1, 1}}, {{-0.5,  0.5,  0.5}, {0, 1}}, {{-0.5, -0.5,  0.5}, {0, 0}},
   		// back face (−z) … then left, right, bottom, top: 30 more rows
   	}
   ```

   Type the other five faces (mirror the pattern; learnopengl's [Coordinate Systems](https://learnopengl.com/Getting-started/Coordinate-Systems) has the full canonical list if you want to cross-check numbers). Upload with `DrawArrays`-style setup — no EBO for this VAO — and draw with `gl.DrawArrays(gl.TRIANGLES, 0, 36)`.

2. **The sea plane.** A second VAO/VBO/EBO trio: 4 vertices at y=0 spanning ±400 units, uvs 0–1, indexed like Chapter 5's quad — but lying flat (x and **z**, not x and y):

   ```odin
   	plane_vertices := [?]Sea_Vertex{
   		{{-400, 0, -400}, {0, 0}},
   		{{ 400, 0, -400}, {1, 0}},
   		{{ 400, 0,  400}, {1, 1}},
   		{{-400, 0,  400}, {0, 1}},
   	}
   ```

3. **Shaders go MVP.** `basic.vert`:

   ```glsl
   uniform mat4 u_model;
   uniform mat4 u_view;
   uniform mat4 u_projection;

   void main() {
   	v_uv = a_uv;
   	gl_Position = u_projection * u_view * u_model * vec4(a_position, 1.0);
   }
   ```

   Make a second fragment shader, `assets/shaders/flat.frag` — same `basic.vert` partner, solid color for the sea:

   ```glsl
   #version 330 core
   in vec2 v_uv;
   out vec4 frag_color;
   uniform vec3 u_color;
   void main() { frag_color = vec4(u_color, 1.0); }
   ```

   Load it as a second `Shader` (`flat_shader, _ := shader_load("assets/shaders/basic.vert", "assets/shaders/flat.frag")`) — your first taste of multiple programs per frame.

4. **Depth on, clear both.** At init: `gl.Enable(gl.DEPTH_TEST)`. In the loop, the clear becomes:

   ```odin
   		gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
   	```

   And change the clear color to a sky tone — the upper half *is* sky now: `gl.ClearColor(0.45, 0.62, 0.74, 1.0)`.

5. **Matrices each frame.** Camera fixed on a gentle vantage; aspect resize-proof:

   ```odin
   		fb_w, fb_h := glfw.GetFramebufferSize(window)
   		if fb_h == 0 do continue // minimized
   		aspect := f32(fb_w) / f32(fb_h)

   		projection := glsl.mat4Perspective(math.to_radians_f32(55), aspect, 0.1, 1000)
   		view := glsl.mat4LookAt({0, 2.5, 7}, {0, 1, 0}, {0, 1, 0})

   		// crate: floating 1.5 above the sea, slowly tumbling
   		model := glsl.mat4Translate({0, 1.5, 0}) * glsl.mat4Rotate({0.4, 1, 0}, t * 0.6)
   ```

   Draw the crate with `shader` (texture bound, all three matrices set), then the plane with `flat_shader` (`u_model` = `glsl.mat4(1)` — the identity — and `shader_set_vec3(flat_shader, "u_color", {0.04, 0.10, 0.18})`). Each program needs its *own* view/projection uniforms set — uniforms belong to programs, not to the frame.

6. Run. Crate in space, sea to the horizon, sky above.

## Checkpoint

A tumbling wooden crate floating above a deep-blue plane that meets the sky at a clean, distant horizon line.

- Resize the window aggressively, tall-and-narrow to ultrawide: the crate **never distorts**. (That's `aspect` recomputed per frame.)
- The crate occludes the plane correctly as it tumbles below its own midline — depth test at work. Comment out `gl.Enable(gl.DEPTH_TEST)` once to see the alternative: far faces drawn over near ones, an inside-out crate. Re-enable.
- Hold TAB (wireframe): the crate is 12 triangles, the plane 2, and perspective visibly converges the plane's edges.
- Look at where plane meets sky: that hard edge is the horizon we'll soften with distance fade in Chapter 12.

## Pitfalls

- **Black screen?** The unholy trinity: ① forgot `DEPTH_BUFFER_BIT` in the clear (frame 2 onward fails the depth test against frame 1's depths — screen freezes or blanks); ② camera inside/behind the geometry — eye `{0,2.5,7}` looks toward origin, make sure you didn't put the crate at z=20; ③ NaN aspect from a 0-height framebuffer.
- **Crate renders but plane doesn't (or vice versa)?** You set matrices on one program and drew with the other. `UseProgram` first, then that program's uniforms, then draw — per object.
- **Crate looks inside-out / sees its own back faces weirdly?** Depth test off, or a face wound the wrong way in your hand-typed data (with culling off it still *renders*, just oddly at silhouettes). Check against the learnopengl vertex list.
- **Plane flickers/stripes at the horizon?** Mild z-fighting with the far plane at extreme distance — pull the plane to ±400 (not ±10000) or `far` up from 1000. Remember the ratio rule.
- **Everything tiny / everything fisheye?** `fovy` in degrees passed where radians expected. `math.to_radians_f32`, always.

## Exercises

1. A second crate at `{2.5, 0.8, -2}` with its own spin — one more `shader_set_mat4(u_model)` + draw. Then five of them from a `[5]glsl.vec3` of positions in a loop. You've invented the scene; Chapter 11 formalizes it.
2. Sink the camera eye to `{0, 0.4, 7}` — nearly sea level. The plane compresses into a dramatic flat band: that low-on-the-water look is exactly the deck view of Part 6. Restore (or keep — your world now).
3. Try `near = 0.001` and watch for shimmer/z-fighting on the crate at distance; try `far = 50` and watch the plane's corners get clipped away mid-screen. Settle back on 0.1/1000 knowing *why*.
4. **Stretch:** Make the crate **bob**: `y = 1.5 + 0.2 * math.sin(t * 1.2)` and a slow roll `mat4Rotate({0,0,1}, 0.1 * math.sin(t * 0.9))` composed in. Floating cargo on an invisible swell — Chapter 13's milestone scene is already forming.

## Commit

```
git commit -m "ch08: MVP, depth buffer, crate above the sea plane"
```

Prev: [Chapter 7 — The Mathematics of Motion](ch07-the-mathematics-of-motion.md) · Next: [Chapter 9 — Free as a Gull](../part-2-standing-on-deck/ch09-free-as-a-gull.md)
