# Chapter 48 — Words on Glass

*Part 8 — Full Sail · Estimated time: 5h · learnopengl: [Text Rendering](https://learnopengl.com/In-Practice/Text-Rendering) (we choose a bitmap atlas over FreeType — see why below)*

**What you'll see when done:** a compass strip across the top of the screen, a wind arrow with your speed in knots, and a live debug panel of sliders that finally retires your zoo of tweak-keys.

## Where we are

You've been steering by vibes since chapter 37's "compass course" (a printed heading, if we're honest). Meanwhile every chapter since has added debug keys — exposure, bloom, weather, bias — that only you can remember. Today: text on screen, a sailing HUD, and a real debug panel via `vendor:microui`. None of it touches the 3D pipeline; UI is just textured quads drawn last, in an orthographic projection, blended over the scene.

## Concepts

### The overlay pass

After tonemapping, switch to "2D mode": no depth test, alpha blending on, and a pixel-space projection — `glsl.mat4Ortho3d(0, w, h, 0, -1, 1)` maps (0,0)-top-left to (w,h)-bottom-right, matching how everyone thinks about UI. Everything in this chapter renders inside this pass, *after* `renderer_end_hdr` — UI shouldn't be tonemapped; it's drawn *on the glass*, not in the world.

### Text: why an atlas, and why not FreeType

learnopengl's text chapter rasterizes glyphs at runtime with FreeType. It's the right tool for big multilingual UI — and the wrong default here: FreeType is an external C dependency (everything else in Saltwind ships with Odin), runtime rasterization is machinery you don't need for a HUD whose strings are ASCII at one size, and learnopengl's per-glyph-texture approach is a draw call *per character* anyway. The pragmatic 2025 answer is a **bitmap font atlas**: one pre-baked texture of glyphs + a table of UV rectangles and advances, batched into one draw call per string (or per frame).

```
atlas texture            metrics per glyph
+--------------------+   'A': uv rect, size,
| ABCDEFGHIJKLMNOP.. |        bearing, advance
| QRSTUVWXYZabcdef.. |   text -> quads:
| ghij...0123456789..|   pen.x += advance, kern, next
+--------------------+
```

Get one from the [BMFont](https://www.angelcode.com/products/bmfont/) format ecosystem (free generators: BMFont itself, [fontbm](https://github.com/vladimirgamalyan/fontbm), Hiero) — a PNG + a text `.fnt` file you can parse in ~40 lines of Odin (`core:strings` + `strconv`). Glyph rendering is then: for each char, append 4 vertices (pos from pen + bearing, uv from table) to a `[dynamic]Vertex`, advance the pen, upload, draw once.

> **Sidebar — `vendor:stb/easy_font`.** Odin ships stb's tiny vector-ish debug font: feed it a string, it emits quad vertices, zero textures. Perfect for "I need text *right now* and don't care how it looks." Fine for prototyping this chapter's step 1; the atlas replaces it because easy_font is unantialiased, single-style, and ugly at size.

### microui: an immediate-mode renderer-agnostic UI

`vendor:microui` ([API](https://pkg.odin-lang.org/vendor/microui/)) is an immediate-mode UI: every frame you *declare* the UI (`mu.button`, `mu.slider`...), and it emits a flat list of draw **commands** (rect, text, icon, clip) that *you* render — it never touches GL. Three integration duties, all yours:

1. **Init & font callbacks.** It needs to measure text; it ships a built-in 128×128 atlas (`mu.default_atlas_alpha`) with measuring procs.
2. **Input plumbing.** Forward GLFW mouse/keys to `mu.input_mouse_move/_down/_up`, `mu.input_scroll`, `mu.input_text`.
3. **Command rendering.** Iterate commands with `mu.next_command_iterator`, draw rects and glyph quads with the same batched-quad machinery your HUD text already uses. One renderer feeds both.

The payoff is enormous for a tool UI: a slider is *one line per frame*, no retained widget objects, no callbacks.

### The HUD pieces

- **Compass strip:** the classic sailing-game ribbon. Your boat's heading in degrees maps to a horizontal offset into a strip showing N · 30 · 60 · E ·... Render tick marks + cardinal letters as text/quads, scrolling horizontally by `heading_deg * pixels_per_degree`, centered marker fixed. Also drop a marker at the bearing of your destination island — navigation, suddenly.
- **Wind arrow:** a rotated quad (or triangle mesh) at screen corner pointing to *apparent* wind relative to boat heading — what a masthead vane shows; you compute true→apparent already in ch33.
- **Speed in knots:** `glsl.length(boat.velocity.xz) * 1.9438`, formatted with `fmt.tprintf("%.1f kn", speed)` (temp allocator — perfect for per-frame strings).

## Odin notes

The microui ↔ GLFW types need small adapters: GLFW gives cursor position as f64 (cast to i32), and microui's scroll convention is pixels (multiply GLFW's wheel offset by ~-30). microui's `Command_Variant` is a union of pointers — iterate with a `switch v in variant` over `^mu.Command_Text`, `^mu.Command_Rect`, `^mu.Command_Icon`, `^mu.Command_Clip`. And note `mu.Context` is large; put it in your `Game` (or a `UI` struct), not on a frame stack.

## Build

1. **Quad batcher.** The workhorse everything else uses:

   ```odin
   UI_Vertex :: struct { pos: glsl.vec2, uv: glsl.vec2, color: glsl.vec4 }

   UI_Batch :: struct {
       verts:   [dynamic]UI_Vertex,
       vao, vbo: u32,          // DYNAMIC_DRAW, grown as needed
       white_uv: glsl.vec2,    // a solid-white texel for untextured rects
   }

   ui_push_quad :: proc(b: ^UI_Batch, rect: Rect2D, uv: Rect2D, color: glsl.vec4) {
       // two triangles, six UI_Vertex appends
   }
   ```

   `ui_flush` uploads with `gl.BufferSubData` (re-`BufferData` if grown), draws with the ortho matrix and one texture, clears the array. Shader: trivial vert (ortho * pos), frag = `texture(u_atlas, uv) * color`.

2. **Font atlas.** Generate a BMFont PNG+.fnt at ~16 px from a clean sans (or grab a ready-made one), parse into `Glyph :: struct{uv: Rect2D, size, bearing: glsl.vec2, advance: f32}` keyed by rune, write `ui_text(b, pos, str, color)` that pushes per-glyph quads. Test with frame time in a corner.

3. **microui init.** One-time:

   ```odin
   import mu "vendor:microui"

   ui.mu_ctx = new(mu.Context)
   mu.init(ui.mu_ctx)
   ui.mu_ctx.text_width  = mu.default_atlas_text_width
   ui.mu_ctx.text_height = mu.default_atlas_text_height
   ```

   Upload its atlas as a texture once — it's alpha-only, so expand: make an RGBA buffer where `rgb = 255, a = mu.default_atlas_alpha[i]`, sized `mu.DEFAULT_ATLAS_WIDTH × mu.DEFAULT_ATLAS_HEIGHT`.

4. **Input plumbing.** In your existing GLFW callbacks (or polling layer), forward:

   ```odin
   mu.input_mouse_move(ctx, i32(xpos), i32(ypos))
   mu.input_mouse_down(ctx, i32(xpos), i32(ypos), .LEFT)   // on press
   mu.input_mouse_up(ctx, i32(xpos), i32(ypos), .LEFT)     // on release
   mu.input_scroll(ctx, 0, i32(yoff * -30))
   ```

   Crucial gameplay guard: when the panel is open and the mouse is over it, *don't* also steer the boat — gate your game input on a `ui_wants_mouse` flag (e.g. `ctx.hover_root != nil`).

5. **Declare the panel.** Each frame between `mu.begin(ctx)` and `mu.end(ctx)`:

   ```odin
   if mu.begin_window(ctx, "Saltwind", mu.Rect{10, 40, 300, 440}) {
       defer mu.end_window(ctx)
       if .ACTIVE in mu.header(ctx, "Render") {
           mu.layout_row(ctx, {120, -1})
           mu.label(ctx, "exposure")
           mu.slider(ctx, &renderer.exposure, 0.05, 4.0)
           mu.label(ctx, "bloom")
           mu.slider(ctx, &renderer.bloom_strength, 0.0, 0.4)
       }
       if .ACTIVE in mu.header(ctx, "Weather") {
           if .SUBMIT in mu.button(ctx, "Storm") { weather_set(&game.weather, .Storm) }
           mu.slider(ctx, &game.weather.current.fog_density, 0.0, 0.05)
       }
   }
   ```

   Migrate every debug key you regret into here. (Sliders take `^f32` — microui's `Real` — which is why `Renderer` fields being f32 pays off.)

6. **Render microui's commands** into the overlay pass via your batcher:

   ```odin
   cmd: ^mu.Command
   for variant in mu.next_command_iterator(ctx, &cmd) {
       switch v in variant {
       case ^mu.Command_Rect: ui_push_rect(b, v.rect, v.color)
       case ^mu.Command_Text: ui_push_mu_text(b, v.pos, v.str, v.color) // default_atlas glyphs
       case ^mu.Command_Icon: ui_push_mu_icon(b, v.id, v.rect, v.color)
       case ^mu.Command_Clip: ui_flush(b); gl.Scissor(...)              // y-flip! GL is bottom-up
       case ^mu.Command_Jump: // handled by the iterator
       }
   }
   ```

   Glyph/icon UVs come from `mu.default_atlas[mu.DEFAULT_ATLAS_FONT + int(ch)]` and `mu.default_atlas[icon_id]`. Enable `gl.SCISSOR_TEST` for the pass; remember scissor rects are bottom-left origin: `gl.Scissor(r.x, screen_h - (r.y + r.h), r.w, r.h)`.

7. **The HUD.** Compass strip (scrolling ticks + letters via `ui_text`, destination marker from `atan2` of the to-island vector), wind arrow (push a rotated quad — rotate the four corners around the center on the CPU), speed text. Bind Tab to toggle the debug panel; the HUD always shows.

## Checkpoint

Top of screen: a compass ribbon that slides as you turn, with a marker drifting toward center as you come onto course for your destination. Corner: wind arrow swinging as you tack, "6.3 kn" beneath it. Tab: a panel where dragging *exposure* visibly re-exposes the world in real time, and the Storm button does what it says.

- Turn a slow full circle: compass passes N→E→S→W in order and the destination marker crosses center exactly when the bow points at the island.
- Drag a slider while the boat sails: boat doesn't steer (input gating works).
- Panel scroll/clip works: shrink the window and interior contents clip cleanly at its edge (scissor y-flip correct).
- Text is crisp at 1:1 (no filtering blur — `NEAREST` or exact pixel alignment for the UI atlas).

## Pitfalls

- **All UI invisible.** Depth test still on (the 3D pass left depth ~0 everywhere at the near plane after... no — simply disable it), or your ortho is `(0, w, 0, h, ...)` so everything is vertically flipped off where you expect; we chose top-left origin: `mat4Ortho3d(0, w, h, 0, -1, 1)`.
- **Text renders as solid blocks.** The mu atlas was uploaded as RGB without the alpha expansion, or blending is off, or your shader ignores `.a`.
- **microui widgets don't react.** Input goes to the context *after* `mu.begin` consumed the frame's state — plumb inputs *before* `mu.begin(ctx)` each frame; with polling-style input, do it at top of frame.
- **Clipped widgets bleed outside windows.** You batched across a `Command_Clip` boundary — you must flush the batch *before* changing scissor state. (This is the classic immediate-UI renderer bug.)
- **Scissor clips the wrong region.** Forgot the y-flip, or used window coords while rendering at framebuffer scale (mind HiDPI: GLFW window size ≠ framebuffer size).
- **Per-frame string garbage grows memory.** Use `fmt.tprintf` (temp allocator, freed by your per-frame `free_all(context.temp_allocator)` from ch10), not `fmt.aprintf`.

## Exercises

1. Add a "wave" header to the panel: amplitude/steepness sliders straight into `weather.current`. Congratulations — you've rebuilt ch28's tuning session as a tool that takes seconds instead of recompiles.
2. Heel indicator: a small arc + needle showing boat roll (you have it from ch32's wave alignment). Sailors feel heel; players must see it.
3. Latency check: display `len(particles)`, draw-call count (increment a global in `mesh_draw`), and the ch10 frame time — the seed of ch49's profiler.
4. **Stretch:** SDF text — bake a signed-distance-field atlas (many BMFont tools export one) and render with `smoothstep(0.5 - w, 0.5 + w, d)` in the shader. Your HUD survives 4K and scaling without re-baking; read Valve's 2007 SDF paper for why this trick conquered the industry.

## Commit

`git commit -m "ch48: HUD (compass, wind, knots) and microui debug panel"`

[← Ch. 47: The Breath of Distance](ch47-the-breath-of-distance.md) · [Ch. 49: The Cost of Beauty →](ch49-the-cost-of-beauty.md)
