# Chapter 79 — The Chart Room

*Part 12 — Shipping a Game · Estimated time: 5h · learnopengl: no direct equivalent — though it's secretly a render-to-texture victory lap*

**What you'll see when done:** press M and the world becomes a sepia nautical chart — contour-banded islands on weathered paper, your boat a small dart trailing a heading line, undiscovered waters hidden under fog that burns away exactly where you've sailed.

## Where we are

The economy gave players reasons to go places; now they need to *plan*. Ch48's compass strip answers "which way is Gullhaven?" but not "which way *around the volcanic island* to Gullhaven, given that I've never seen the eastern strait?" That's a map's job. This is the one chapter in Part 12 with real shader work — and it's pure dessert: every input (the heightfield, ortho cameras, render-to-texture, the UI batcher) has existed for fifty chapters. You're just pointing them at paper.

## Concepts

### One render, at startup

The chart base is *static* — terrain doesn't move. So render it once: an orthographic camera straight down, the whole archipelago in frame, into an FBO you keep for the rest of the session (ch30 built you everything needed). Two honest options for what to draw:

1. **Re-render the terrain meshes** with a dedicated `chart.frag` — easy, reuses culling/buffers, but you pay vertex cost for a 2048² one-off (fine).
2. **A fullscreen quad sampling the heightfield** — if your ch20–21 pipeline kept a world heightmap texture (or you bake one now by sampling `terrain_height_at` into a texture on the CPU), the chart becomes a pure image-space shader.

Take option 1 if unsure; the shader below works for both since all it needs is world-space height.

### The paper shader

Real nautical charts encode depth and elevation as *bands*, not gradients. Quantize height into steps, darken band boundaries into contour-ish lines, and grade everything into a sepia palette:

- land: `floor(h / band_width)` → 4–5 parchment-to-umber steps, a darker line where the band index changes between neighboring pixels (`fwidth` of the band index does this in one expression);
- sea: two or three blue-gray washes by depth, so shallows read as sandbars — *navigation information*, not decoration;
- finish: paper-grain noise (your ch51 hash), a vignette, and a slight warm tint toward the edges, like a chart that's lived in a tube.

### Fog of war: the chart as an artifact of play

A coverage texture — one channel, world-mapped, ~512² — starts black and gets stamped with a soft brush wherever the boat sails. The chart composite shows paper where coverage is high and "uncharted" blankness (deeper sepia, no contours) where it's low. CPU stamping is completely sufficient: one soft-disc splat into a `[]u8` per sim-tick the boat moves, `gl.TexSubImage2D` of the dirty region when it changes. (A compute-shader brush is a fun ch61-skills flex — exercise 4 — but 512² bytes is nothing; spend your complexity budget where players can see it.) The payoff is disproportionate: the chart *fills in*, sessions leave visible sediment, and "I haven't been up there yet" becomes something a player can point at. Exploration was always in the game; now it has a face. The mask saves to disk in ch80 — it's the most personal state the game has.

### Waypoints close the navigation loop

Click the chart to plant a waypoint; the ch48 compass strip gets a waypoint marker and the HUD gets a small arrow when it's off-screen. Combined with the wind arrow you already render, route planning becomes: open chart → see contract line → notice the wind → place a waypoint on the windward side of the strait → sail the compass. Every piece existed; the chart is the table they all finally sit at.

## Odin notes

Chart math is two tiny spaces: world XZ ↔ chart UV. Write the pair once, test once, use everywhere — boat icon, port labels, fog stamps, click-to-world:

```odin
WORLD_EXTENT :: 4096.0   // your archipelago bounds from ch21/25

chart_uv_from_world :: proc(p: glsl.vec2) -> glsl.vec2 {
    return p / WORLD_EXTENT + 0.5
}
world_from_chart_uv :: proc(uv: glsl.vec2) -> glsl.vec2 {
    return (uv - 0.5) * WORLD_EXTENT
}
```

Every chart bug you'll meet is one of these two procs used backwards, or a screen↔UV pan/zoom slip. Keep pan/zoom as `chart_center: glsl.vec2` (in UV) and `chart_scale: f32`, derive screen rects from them, and never store screen coordinates.

## Build

1. **Bake the chart base** at startup, after world generation:

   ```odin
   chart_bake :: proc(g: ^Game) {
       rt := render_target_create(2048, 2048, .RGBA8)
       defer render_target_release_fbo(&rt)        // keep the texture, drop the FBO

       proj := glsl.mat4Ortho3d(-WORLD_EXTENT/2, WORLD_EXTENT/2,
                                -WORLD_EXTENT/2, WORLD_EXTENT/2, 1, 1000)
       view := glsl.mat4LookAt({0, 500, 0}, {0, 0, 0}, {0, 0, -1})

       render_target_bind(rt)
       gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
       shader_use(g.shaders.chart)
       shader_set_mat4(g.shaders.chart, "u_viewproj", proj * view)
       for &chunk in g.terrain.chunks do mesh_draw(chunk.mesh)   // no culling: draw all, once
       g.chart.base_tex = rt.color
   }
   ```

   Note the up-vector `{0,0,-1}`: it decides which way is "north" on your chart. Make it match the compass convention you committed to in ch37, in writing, in a comment.

2. **`chart.frag`** — the fun part. Height arrives from the vertex shader (world Y); everything else is banding and grading:

   ```glsl
   #version 430 core
   in float v_height;
   out vec4 frag;
   uniform float u_band_width;   // ~6.0 world units

   const vec3 SEA_DEEP = vec3(0.62, 0.66, 0.62), SEA_SHALLOW = vec3(0.72, 0.74, 0.66);
   const vec3 LAND_LO  = vec3(0.85, 0.78, 0.62), LAND_HI     = vec3(0.55, 0.45, 0.32);

   void main() {
       vec3 c;
       if (v_height <= 0.0) {
           c = mix(SEA_SHALLOW, SEA_DEEP, clamp(-v_height / 25.0, 0.0, 1.0));
           c = floor(c * 12.0) / 12.0;                  // posterize the washes
       } else {
           float band = floor(v_height / u_band_width);
           c = mix(LAND_LO, LAND_HI, clamp(band / 5.0, 0.0, 1.0));
           float edge = clamp(fwidth(band), 0.0, 1.0);  // 1 where band index jumps
           c *= 1.0 - 0.35 * edge;                      // contour line
       }
       frag = vec4(c, 1.0);
   }
   ```

   Paper grain and vignette go in the *composite* pass (step 4) so they don't zoom with the world. Iterate with hot-reload (ch4's gift, still giving): band width, palette, posterize steps — twenty minutes of pure aesthetic play. This is the screenshot people share.

3. **Chart mode.** Add `.Chart` handling to `game_set_mode`; toggle with M. One housekeeping note: ch36 gave M to mute. Demote mute to the options screen (ch81) and give M to the map — the key players press a hundred times a session wins the good letter. In `.Chart`, mouse drags pan (`chart_center -= drag_px / (chart_px * chart_scale)`), scroll zooms toward the cursor (the classic: convert cursor to UV, zoom, convert back, correct center), and the sim keeps running — you're reading a chart at the helm, not pausing the ocean. Clamp zoom to [1, 16] and center so the paper never leaves the screen.

4. **Composite pass,** drawn through the UI batcher's ortho space as one big textured quad plus decorations, in `game_render` when `.Chart`:

   - sample `base_tex` through pan/zoom UV transform;
   - multiply in the **coverage mask** (step 5): `mix(UNCHARTED_COLOR, paper, smoothstep(0.15, 0.5, coverage))`;
   - vignette + grain in screen space;
   - then immediate-mode decorations *on top* via `ui_push_quad`/`ui_text`: port names (only where coverage > 0.5 — undiscovered ports stay secret), a boat triangle rotated to heading, waypoint flag, and contract routes (step 6).

   A tiny dedicated `chart_composite.frag` for the quad keeps this clean — it samples two textures and does two lines of math; resist putting decorations in it.

5. **The discovered mask.** In `Game`: `discovered: []u8` (512×512), plus a GL texture. Stamp from `game_simulate` whenever the boat has moved a few meters:

   ```odin
   chart_stamp_discovered :: proc(g: ^Game) {
       uv := chart_uv_from_world(g.boat.position.xz)
       cx, cy := int(uv.x * 512), int(uv.y * 512)
       R :: 14   // ~110 m of visibility — tune with the Charts upgrade (ch77!)
       r := R + int(f32(R) * 0.5 * UPGRADES[.Charts].effect[g.upgrades[.Charts]])
       for y in max(cy-r, 0) ..< min(cy+r+1, 512) {
           for x in max(cx-r, 0) ..< min(cx+r+1, 512) {
               d := math.sqrt(f32((x-cx)*(x-cx) + (y-cy)*(y-cy))) / f32(r)
               if d > 1 do continue
               soft := u8(255.0 * (1.0 - d*d))            // soft brush falloff
               g.discovered[y*512 + x] = max(g.discovered[y*512 + x], soft)
           }
       }
       g.discovered_dirty = true
   }
   ```

   In `game_render`, if dirty, upload once with `gl.TexSubImage2D` (whole texture is fine — 256 KB) and clear the flag. The `max` is what makes the mask monotonic: charts remember.

6. **Waypoints and routes.** Left-click in chart mode → `world_from_chart_uv` → store `g.waypoint`; right-click clears. Draw active contract routes as dashed lines from `from` port to `to` port: step along the segment in UV, emit a 2-px quad every other step (dash!) via the batcher — 15 lines of code, and "great-circle-ish" here just means: bow the line slightly by offsetting the midpoint perpendicular to the segment, because straight chart lines look like debug output and curved ones look like a navigator drew them. Then surface waypoints in the sailing HUD: a marker on the ch48 compass strip at the waypoint's bearing, distance text beneath, and the existing wind arrow beside it — the full planning instrument cluster.

7. **Polish pass, 30 minutes, strictly timed:** a compass rose in a corner (one rotated textured quad or a few line quads), a scale bar that respects zoom, port flavor text on hover. Stop when the timer rings; ch80 is waiting and the chart is already lovely.

## Checkpoint

M opens a chart that looks pulled from a drawer and knows where you've been.

- The chart's north matches the compass: sail due N (heading 000) and the boat triangle points to the top of the chart.
- Sail a loop around an island, open the chart: a soft-edged ribbon of discovery traces your wake exactly; restart the program — it's gone (correct! persistence is ch80's job; feel the missing feature).
- Click beyond a strait to set a waypoint: the compass strip marker appears, distance counts down as you sail, and clicking at zoom 8× lands the waypoint where the cursor was (round-trip transforms agree).
- Accept a contract and open the chart: a dashed, slightly-bowed line connects the two ports — unless the destination port is undiscovered, in which case its name is hidden but the line still points the way (decide this rule consciously; either is defensible, mystery vs. usability).

## Pitfalls

- **The chart is mirrored or rotated relative to the world.** Ortho up-vector vs. compass convention vs. texture V-direction — three sign choices that must agree. Diagnose with one asymmetric island, not by staring at code; fix in `chart_bake`'s `mat4LookAt`, nowhere else.
- **Click-to-waypoint drifts as you zoom.** You stored screen coordinates somewhere, or applied pan before zoom on one path and after on the other. All state in UV (`chart_center`, `chart_scale`); screen coords exist only inside a transform call.
- **Contours shimmer or alias into stairsteps.** `fwidth` banding at high zoom on a 2048² bake — acceptable; if it bothers you, bake at 4096² or sample the base texture with bilinear + a half-texel mip bias. Do not raymarch your way into a week.
- **Fog of war reveals in squares.** Hard-edged brush (missing the `1 - d*d` falloff) or nearest-neighbor sampling of the mask — the mask texture wants `LINEAR` filtering even though the UI atlas wanted `NEAREST`.
- **Frame hitch every few seconds in chart mode.** You're re-uploading the mask every frame, or worse, re-baking the base. Dirty flag + upload-on-change; the bake happens once per *world*, ever.
- **A beautiful chart nobody opens.** If contracts and the compass already tell players everything, M goes unpressed (friend-testers will show you). The chart must own information nothing else has: routes, fog of war, port discovery, shallows. Guard that monopoly.

## Exercises

1. Stamp port icons as proper anchors and the boat as a little ship glyph — add them to your BMFont atlas as private-use glyphs and they ride the existing text path for free.
2. A "voyage trail": once per sim-minute, append the boat's UV to a ring buffer (last ~200 points) and draw it as a fading dotted line — your current session's actual track, the chart's answer to ch34's wake.
3. Depth soundings: scatter small depth numbers over sea areas (sampled from the heightfield at bake time, placed by jittered grid, drawn only where discovered). Charts feel *charted* when numbers live on them.
4. **Stretch:** port the fog stamp to a compute shader (ch61 skills): mask as `r8` image, one dispatch per stamp with `imageAtomicMax`-style update (or plain max in a single workgroup — stamps don't overlap themselves). Benchmark against the CPU loop and write one honest sentence in a comment about whether it was worth it.

## Commit

`git commit -m "ch79: nautical chart - paper shader bake, fog of war, waypoints, contract routes"`

← [Chapter 78 — Ports of Call](ch78-ports-of-call.md) · [Chapter 80 — Letters in a Bottle](ch80-letters-in-a-bottle.md) →
