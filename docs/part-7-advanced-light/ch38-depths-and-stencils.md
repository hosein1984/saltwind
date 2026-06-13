# Chapter 38 — Depths & Stencils

*Part 7 — Advanced Light · Estimated time: 3h · learnopengl: [Depth Testing](https://learnopengl.com/Advanced-OpenGL/Depth-testing), [Stencil Testing](https://learnopengl.com/Advanced-OpenGL/Stencil-testing), [Face Culling](https://learnopengl.com/Advanced-OpenGL/Face-culling)*

**What you'll see when done:** your boat glows with a clean colored outline when the mouse hovers over it, and your frame got slightly faster because every mesh now culls its back faces correctly.

## Where we are

You sailed out of Part 6 with a complete *game*: buoyant boat, wind, wake, compass course. Part 7 is about light — shadows, HDR, bloom, PBR, IBL — and all of it leans hard on three pieces of pipeline machinery you've been using on autopilot since Chapter 8: the depth buffer, its neighbor the stencil buffer, and face culling. Before we build a shadow mapper on top of them, we spend one chapter actually understanding them. Think of it as inspecting the rigging before the storm.

## Concepts

### Depth testing, properly this time

After the fragment shader runs, each fragment carries a depth value in [0, 1]. The depth test compares it against what's already in the depth buffer at that pixel, using the function you set with `gl.DepthFunc`:

| Func | Passes when... | You'd use it for |
|---|---|---|
| `LESS` (default) | new < stored | normal opaque rendering |
| `LEQUAL` | new <= stored | skybox drawn last at depth 1.0 (you did this in ch26) |
| `EQUAL` | new == stored | multi-pass over already-laid-down geometry |
| `ALWAYS` | always | overlays, fullscreen passes |
| `GREATER` | new > stored | reversed-Z (sidebar below) |

Two separate switches control it, and confusing them causes classic bugs:

- `gl.Enable(gl.DEPTH_TEST)` — turns the *comparison* on or off.
- `gl.DepthMask(false)` — turns *writing* off while still testing. Transparent things (your wake from ch34) want exactly this: test against the world, but don't occlude what's behind them.

### Precision: why the far plane is innocent and the near plane is guilty

The perspective divide makes stored depth proportional to `1/z`. Plot it and you see the problem:

```
depth value
1.0 |                    ________________----------
    |          _____-----
    |      __--
0.5 |    /
    |   /
    |  |
0.0 |__|____________________________________________ view-space z
   near                                            far
```

Half of your depth precision is spent on the first few meters in front of the camera. The lever that matters is the **near plane**: moving `near` from 0.1 to 1.0 gains you roughly as much far-field precision as pulling the far plane in by 10x. Saltwind's world is big — islands a kilometer away — so set `near = 0.5` or so and only shrink it if close-up geometry visibly clips.

> **Sidebar: reversed-Z.** Modern engines store depth as `1 - depth` in a floating-point depth buffer with `gl.DepthFunc(gl.GREATER)`. Float precision is densest near 0, `1/z` precision is densest near 1 — flip one and they *cancel*, giving near-uniform precision. It needs `glClipControl` (GL 4.5) to do properly, so it's out of scope for our 3.3 baseline, but when you see "reversed-Z" in an engine post, this is all it is.

### Z-fighting and its three fixes

When two surfaces are coplanar (your terrain skirt edges, a decal on a hull), they quantize to the same depth and flicker as the camera moves. Fixes, in order of preference: (1) don't create coplanar geometry — offset it; (2) widen the near plane as above; (3) `gl.Enable(gl.POLYGON_OFFSET_FILL)` with `gl.PolygonOffset` to nudge one of them — which, foreshadowing, is also a tool for shadow bias next chapter.

### The stencil buffer

Alongside each pixel's depth value lives an 8-bit stencil value. Per draw you configure a test (`gl.StencilFunc`) and what to do with the value when fragments pass or fail (`gl.StencilOp`). It's a per-pixel scratchpad: "mark every pixel the boat touched," then later, "only draw where the mark is / isn't."

The outline trick (the one we build) is two passes:

```
Pass 1: draw boat normally, stencil op REPLACE with ref=1
        -> stencil buffer now holds a boat-shaped mask of 1s
Pass 2: draw boat scaled up ~3%, flat color shader,
        stencil func NOTEQUAL ref=1, depth test off
        -> only the rim that pokes outside the mask survives
```

You also need stencil bits in your default framebuffer: GLFW gives you 8 by default (`GLFW_STENCIL_BITS` defaults to 8), so no window changes needed — but you must clear it: add `gl.STENCIL_BUFFER_BIT` to your clear.

### Face culling: the free 30%

Every triangle has a winding order as seen from the camera. With `gl.Enable(gl.CULL_FACE)`, counter-clockwise-wound front faces are kept and back faces discarded *before* the fragment shader — roughly halving fragment work on closed meshes. You've had this on since early chapters for the crate, but Saltwind has accumulated meshes since then, and this chapter's Build does a formal audit. The rules:

- Closed, opaque meshes (hull, buoys, rocks): cull `BACK`. This is the default; assert your winding is CCW.
- Terrain: it's a heightfield seen from above — cullable. But your chunk *skirts* (ch23) hang downward; if you generated their triangles by copy-paste, half are probably wound backwards and will vanish. Fix the winding, don't disable culling.
- The ocean: cullable from above, but you *can* go underwater. Either disable culling for the ocean draw or accept a missing surface from below until ch47 handles submersion.
- Sails and wake quads: genuinely two-sided, zero thickness. Disable culling for those draws — this is the documented exception, not a bug. In the sail's fragment shader, flip the normal for back faces: `if (!gl_FrontFacing) n = -n;`.

## Build

1. **Centralize depth state.** You almost certainly have `gl.Enable(gl.DEPTH_TEST)` once at init. Make render-state explicit per pass instead: in your main render proc, set depth func/mask before each logical group (opaque, sky, transparent). A tiny helper struct keeps you honest:

   ```odin
   Render_Pass_State :: struct {
       depth_test:  bool,
       depth_write: bool,
       depth_func:  u32, // gl.LESS, gl.LEQUAL, ...
       cull:        bool,
   }

   apply_pass_state :: proc(s: Render_Pass_State) {
       if s.depth_test { gl.Enable(gl.DEPTH_TEST) } else { gl.Disable(gl.DEPTH_TEST) }
       gl.DepthMask(s.depth_write)
       gl.DepthFunc(s.depth_func)
       if s.cull { gl.Enable(gl.CULL_FACE) } else { gl.Disable(gl.CULL_FACE) }
   }
   ```

   Opaque = `{true, true, gl.LESS, true}`; sky = `{true, false, gl.LEQUAL, false}`; wake/sail = `{true, false, gl.LESS, false}`.

2. **Audit the near plane.** Find your `glsl.mat4Perspective` call. If near is 0.01 or 0.1 from the early chapters, raise it to 0.5 and fly close to a buoy to confirm nothing clips. While there, fly to the far side of the archipelago and check distant islands no longer shimmer against the sea.

3. **Audit culling mesh by mesh.** Enable `gl.Enable(gl.CULL_FACE)` globally, then walk through every draw: terrain chunks, skirts, ocean, hull, mast, sails, buoys, wake. Anything that disappears has reversed winding — fix it at generation time by swapping two indices per triangle, e.g. emit `(a, c, b)` instead of `(a, b, c)` in the skirt generator. Add explicit exceptions only for sails and wake:

   ```odin
   gl.Disable(gl.CULL_FACE)        // sails: two-sided by design
   mesh_draw(&boat.sail_mesh)
   gl.Enable(gl.CULL_FACE)
   ```

4. **Hover detection.** Before the outline can react to the mouse, you need to know the cursor is on the boat. Build a ray from the camera through the cursor (unproject the NDC mouse position with the inverse of `proj * view`), then test it against the boat's AABB — you already have AABB code from frustum culling (ch23):

   ```odin
   ray_hits_aabb :: proc(origin, dir: glsl.vec3, box: AABB) -> bool {
       t_min, t_max := f32(0), f32(1e9)
       for axis in 0 ..< 3 {
           inv := 1.0 / dir[axis]
           t0 := (box.min[axis] - origin[axis]) * inv
           t1 := (box.max[axis] - origin[axis]) * inv
           if inv < 0 { t0, t1 = t1, t0 }
           t_min = max(t_min, t0)
           t_max = min(t_max, t1)
       }
       return t_min <= t_max
   }
   ```

5. **Stencil pass 1 — write the mask.** Clear stencil with your other buffers, then when drawing the boat normally:

   ```odin
   gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT | gl.STENCIL_BUFFER_BIT)
   // ...
   gl.Enable(gl.STENCIL_TEST)
   gl.StencilOp(gl.KEEP, gl.KEEP, gl.REPLACE) // sfail, dpfail, dppass
   gl.StencilFunc(gl.ALWAYS, 1, 0xFF)
   gl.StencilMask(0xFF)                       // allow stencil writes
   boat_draw(&game.boat, ...)
   ```

6. **Stencil pass 2 — the rim.** Write a trivial `outline.vert`/`outline.frag` pair (assets/shaders/) — vertex shader applies MVP with the model matrix's scale bumped, fragment outputs a constant color. Then:

   ```odin
   if game.boat_hovered {
       gl.StencilFunc(gl.NOTEQUAL, 1, 0xFF)
       gl.StencilMask(0x00)              // don't write stencil now
       gl.Disable(gl.DEPTH_TEST)
       shader_use(outline_shader)
       outline_model := boat_model * glsl.mat4Scale(glsl.vec3{1.03, 1.03, 1.03})
       shader_set_mat4(outline_shader, "u_model", &outline_model)
       boat_draw_geometry(&game.boat)    // same meshes, outline shader
       gl.Enable(gl.DEPTH_TEST)
       gl.StencilMask(0xFF)
   }
   gl.Disable(gl.STENCIL_TEST)
   ```

   The scale method outlines each mesh from its own origin; on a multi-part boat the masts get slightly thicker outlines than the hull. For a hover highlight that's fine — note the alternative (extrude along normals in the vertex shader) in a comment for later.

## Checkpoint

A sunny sailing scene, visually identical to chapter 37 — until you mouse over the boat, which picks up a crisp warm-yellow (or your choice) outline that hugs its silhouette, visible even where the boat overlaps islands behind it.

- Move the mouse on and off the hull: the outline toggles with no flicker.
- Fly the camera below the terrain edge: chunk skirts are still visible (winding fixed, not culling disabled).
- Look at the sails from both sides: lit correctly, not invisible from behind.
- Distant islands no longer z-shimmer against the ocean after the near-plane change.

## Pitfalls

- **Outline never appears.** You forgot `gl.StencilMask(0xFF)` before clearing — `gl.Clear` respects the stencil write mask, so a mask of 0 makes the clear a no-op and pass 1 writes nothing either.
- **Outline appears but the whole scaled boat is colored.** Your `gl.StencilFunc(gl.NOTEQUAL, 1, 0xFF)` is being applied in pass 1 too, or you cleared stencil between the passes.
- **Everything disappeared when you enabled culling.** Your meshes are wound clockwise. Either fix the generators or — one line, no shame — `gl.FrontFace(gl.CW)` and standardize on CW everywhere.
- **Terrain skirts vanished but terrain is fine.** Classic copy-paste winding bug in the skirt generator; swap two indices per skirt triangle.
- **Z-fighting got *worse* after "fixing" the near plane.** You moved the *far* plane out instead. Far barely matters; near is the lever.
- **Outline z-fights with the boat at the rim.** You left depth testing on in pass 2. The whole point of `gl.Disable(gl.DEPTH_TEST)` there is that the stencil alone decides.

## Exercises

1. Bind a debug key that cycles `gl.DepthFunc` between `LESS`, `ALWAYS`, and `GREATER` and prints the current one. One frame of `ALWAYS` is a memorable lesson in why painter's-order rendering died.
2. Visualize the depth buffer: a debug fragment shader outputting `gl_FragCoord.z` (linearize it — the raw value is nearly all white; the linearization formula is in the learnopengl Depth Testing article) toggled by a key.
3. Outline the *buoys* on hover too, reusing the same stencil shader — notice how little extra code pass-based design costs you.
4. **Stretch:** implement the normal-extrusion outline (`position + normal * width` in the vertex shader, width in world units) and compare it against the scale method on the mast. Bonus: scale width by distance so the outline stays constant in screen pixels.

## Commit

`git commit -m "ch38: depth audit, face-culling discipline, stencil boat outline"`

[← Ch. 37: Maiden Voyage](../part-6-setting-sail/ch37-milestone-maiden-voyage.md) · [Ch. 39: Shadows on the Water →](ch39-shadows-on-the-water.md)
