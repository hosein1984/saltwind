# Chapter 34 — Cutting the Water

*Part 6 — Setting Sail · Estimated time: 2.5h · learnopengl: [Blending](https://learnopengl.com/Advanced-OpenGL/Blending)*

**What you'll see when done:** a white wake trailing from your stern, fading and widening behind you across the swells — turn hard and your own curved history is written on the sea.

## Where we are

The boat sails but leaves no mark on the water — and the eye notices: motion without consequence reads as floating, not sailing. The wake fixes that, and it forces us to finally do **transparency properly**, a topic we've dodged since the Chapter 24 shoreline preview.

## Concepts

### Blending, the contract

When a fragment passes the depth test, blending decides how it combines with the pixel already in the framebuffer:

```
result = src_color * src_factor  (+)  dst_color * dst_factor
```

Standard "alpha blending" is `gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)`: a fragment with α = 0.3 contributes 30% of itself over 70% of what was there. Fine print that bites everyone, per the [Blending article](https://learnopengl.com/Advanced-OpenGL/Blending):

- **Order matters.** Blending math depends on what's already in the buffer, so transparent surfaces must draw **after** all opaque geometry, and among themselves **back-to-front** (farthest first).
- **Depth writes off, depth test on.** A transparent fragment must not write depth (it would occlude things visible *through* it), but must still *test* (so an island hides the wake behind it). `gl.DepthMask(false)` … draw … `gl.DepthMask(true)`.
- **Premultiplied alpha** — the grown-up alternative you should know exists: store/output color already multiplied by α and blend with `(ONE, ONE_MINUS_SRC_ALPHA)`. It composites correctly under texture filtering and stacking, which classic alpha doesn't quite. We'll stay classic here (one effect, no stacked textures); file the term away for the particle system in Chapter 46.

Saltwind's draw order from today onward: **opaque scene → water → transparent effects → sky-already-drawn? No —** sky stays before water (water blends against it), so: scene → sky → water → wake. Within "wake" alone, the strip's own triangles overlap only slightly and share one alpha ramp, so internal sorting is a non-issue — one of the reasons the trail design below is pleasant.

### A wake as geometry, not particles

Two classic builds: scrolling foam *textures* pinned near the hull in boat-local space, or a **trail** — a ribbon of world-space geometry left behind by the stern. We build the trail (the texture variant is an exercise): it curves when you turn, persists where you've been, and teaches a reusable pattern (ring buffer → dynamic mesh) that also powers tracer effects, skid marks, and gull flight lines.

```
 stern drops a point every D meters:     ribbon built across pairs:
                                          L0──L1──L2──L3
   p0   p1   p2   p3  (oldest → newest)    │ ╲ │ ╲ │ ╲ │   triangle strip
     ●────●────●────●                      R0──R1──R2──R3
                                          width & alpha from point AGE
```

Each recorded point stores position and birth time. Per frame, each pair of consecutive points is widened into left/right vertices (perpendicular to the segment), with **age** driving both width (wakes spread) and alpha (wakes fade). Old points expire; a **ring buffer** holds the last N without ever allocating.

### Dynamic vertex data

Until now every `Mesh` was uploaded once (`gl.STATIC_DRAW`) and drawn forever. The trail rebuilds its vertices every frame: allocate the VBO once at maximum size with `gl.DYNAMIC_DRAW`, then per frame overwrite with `gl.BufferSubData`. (Re-creating buffers per frame is the classic beginner leak — never `GenBuffers` in a loop.)

## Build

1. **The ring buffer**, in `src/wake.odin`:

   ```odin
   MAX_WAKE_POINTS :: 64

   Wake_Point :: struct {
       position: glsl.vec3,
       time:     f32,       // birth, sim clock
   }

   Wake :: struct {
       points:      [MAX_WAKE_POINTS]Wake_Point,
       head, count: int,
       last_drop:   glsl.vec3,
       vao, vbo:    u32,
       shader:      Shader,
   }
   ```

   In the fixed update: when the boat moves > 0.6 m from `last_drop` and `speed > 0.5`, write a point at the stern position (`boat.position - forward * boat.half_length`) into `points[head]`, advance `head = (head + 1) % MAX_WAKE_POINTS`, saturate `count`. ~64 points × 0.6 m ≈ a 38 m wake.

2. **Build the strip on the CPU** each render frame. Iterate points oldest → newest (that's `head - count` forward, mod N — get the iteration order right once, in one helper). For each point: age `t - p.time`, normalized `a = age / WAKE_LIFETIME` (use 7 s), skip if expired. Direction from neighbor points; perpendicular `side = {-dir.z, 0, dir.x}`:

   ```odin
   half_w := 0.5 + a * 2.2                       // spreads as it ages
   alpha  := (1.0 - a) * (1.0 - a) * 0.6         // quadratic fade reads better
   y      := ocean_height_at(game.ocean, {p.position.x, p.position.z}, t) + 0.06
   l := glsl.vec3{p.position.x, y, p.position.z} - side * half_w
   r := glsl.vec3{p.position.x, y, p.position.z} + side * half_w
   append(&verts, Wake_Vertex{l, {0, a}, alpha}, Wake_Vertex{r, {1, a}, alpha})
   ```

   Crucial detail: re-sample the water height at each point *now* — the wake must ride today's waves, not the wave that existed when the point dropped. The `+0.06` lifts it off the surface (see Pitfalls). `Wake_Vertex` is position + uv + alpha; a fresh small layout, not the shared `Vertex` — wakes don't need normals.

3. **Upload and draw.** Once at init: create VAO/VBO sized `MAX_WAKE_POINTS * 2 * size_of(Wake_Vertex)` with `gl.DYNAMIC_DRAW`, set up attributes. Per frame:

   ```odin
   gl.BindBuffer(gl.ARRAY_BUFFER, wake.vbo)
   gl.BufferSubData(gl.ARRAY_BUFFER, 0, len(verts) * size_of(Wake_Vertex), raw_data(verts))
   // ... after water, in the transparent stage:
   gl.Enable(gl.BLEND)
   gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
   gl.DepthMask(false)
   gl.BindVertexArray(wake.vao)
   gl.DrawArrays(gl.TRIANGLE_STRIP, 0, i32(len(verts)))
   gl.DepthMask(true)
   gl.Disable(gl.BLEND)
   ```

   A triangle strip consumes L0,R0,L1,R1,… exactly as emitted — no index buffer needed.

4. **The wake shader.** Vertex: standard MVP (model = identity; points are world-space). Fragment — procedural foam, no texture yet:

   ```glsl
   in vec2 v_uv;        // uv.x: 0..1 across, uv.y: age
   in float v_alpha;
   out vec4 frag_color;

   void main() {
       float across = 1.0 - abs(v_uv.x * 2.0 - 1.0);   // 1 center, 0 at edges
       float edge   = smoothstep(0.0, 0.35, across);    // soft sides
       frag_color = vec4(vec3(0.92, 0.96, 0.97), v_alpha * edge);
   }
   ```

5. **Handle the ring-buffer seam.** When the buffer wraps, the oldest and newest points are adjacent in memory but 38 m apart in the world. If you build the strip in buffer order you'll get one giant smeared quad. Building in *age order* (step 2) avoids it; also break the strip (emit a degenerate pair — repeat a vertex) anywhere two consecutive points are further apart than, say, 3 m (happens after teleporting the boat, too).

6. **Sail and look back.** Straight line: a clean fading ribbon. Hard turn: the ribbon curves and the outer edge stretches. Stop: the wake dissolves over ~7 s where you left it.

A note for the future: the wake's hard intersection with steep wave flanks is visible if you look for it. The proper fix — fading by per-pixel depth difference against the scene — is **soft particles**, arriving with the depth-texture machinery in Chapter 46. Today's `+0.06` lift is the honest interim.

## Checkpoint

A white ribbon trails the stern, widening and fading with age, riding up and over swells, curving through your turns.

- Stop the boat: the trail ages out in place. No trail is emitted below walking pace.
- Sail a tight circle: no spiral-of-doom artifacts where the ring buffer wraps (step 5 working).
- The wake is hidden behind islands (depth *test* on) but never cuts a hole in the water (depth *write* off).
- Look at the wake against the sun glitter: it blends, both stay visible — transparency ordering is right.

## Pitfalls

- **Wake invisible.** Drawn before the water (water overwrote it — it writes depth and color), or blending disabled, or alpha is 0 because your sim clock and birth times use different clocks (everything is older than `WAKE_LIFETIME` instantly).
- **Z-fighting sparkle along the trail.** It's coplanar with the water. Raise the lift; if camera-distance makes it reappear, scale lift slightly with distance. (Chapter 38's depth deep-dive explains exactly why far coplanar surfaces fight harder.)
- **One huge triangle smearing across the sea.** Ring-buffer seam (step 5) — you're stripping buffer-order, not age-order, or missing the gap-break.
- **The wake doesn't follow waves / floats above troughs.** You stored the y at drop time instead of re-sampling `ocean_height_at` during strip building.
- **Trail flickers or corrupts when count hits 64.** Classic off-by-one in modulo iteration. Unit-test the index helper in a scratch proc: `for i in 0..<count { idx := (head - count + i + MAX) % MAX }`.
- **Dark gray fringe around the foam.** You're blending an un-premultiplied white with a dark edge from filtering or from `vec3 * alpha` applied twice. Output pure foam color and let `BlendFunc` apply alpha exactly once.

## Exercises

1. Modulate foam alpha by a noise function of `v_uv` and time (`fract(sin(dot(...)))` hash is fine) — broken, bubbly edges instead of an airbrushed band.
2. Scale drop distance and initial width with `boat.speed` — a fast boat tears a wider, longer wake; a drifting boat barely whispers.
3. **Bow foam variant** (the chapter's alternate build): two small quads pinned at the bow in *boat-local* space, scrolling a foam texture by `speed * time` with alpha ramped by speed. Compare maintenance burden vs. the trail — notice how boat-local effects and world-space effects complement each other.
4. **Stretch:** second trail layer — a wider, fainter "disturbed water" band under the foam using the same points but 2.5× width, 0.15× alpha, and a longer lifetime, which darkens rather than whitens (`frag_color = vec4(vec3(0.0, 0.05, 0.08), …)`). Layered cheap effects beat one expensive one; this is the whole philosophy of Part 8.

## Commit

`git commit -m "ch34: blended wake trail with ring buffer"`

← [Chapter 33 — The Wind in Your Sail](ch33-the-wind-in-your-sail.md) · [Chapter 35 — A Place for Everything](ch35-a-place-for-everything.md) →
