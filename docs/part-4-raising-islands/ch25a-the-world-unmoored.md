# Interlude 25a — The World Unmoored

*⚓ Optional interlude · slots after [Chapter 25](ch25-milestone-the-archipelago.md) · Estimated time: 3h · learnopengl: no direct equivalent*

**Prerequisites:** Chapter 12 (the f32 precision warning and the camera-following sea tile) and Chapter 25 (a full world worth dragging around). · **Required downstream:** none — skip freely. One note for the far horizon: Part 15's Chapter 100 builds its endless-archipelago streaming on this interlude, but it recaps everything it needs.

**What you'll see when done:** you teleport 50 km out to sea, the bobbing crates shudder like a film projector losing its loop — then you flip one switch and the world snaps back to glassy stillness, with the title bar calmly insisting you're still 50 km from home.

## Why this is a side quest

Saltwind's archipelago spans a few thousand units — comfortably inside f32, which is why the main line never needs this. But the moment you want a world bigger than ~10 km (Chapter 100's endless streaming, or just the itch to sail *past* the map), f32 runs out of teeth, and the fix — a floating origin — is best built while your system count is still small.

## Concepts

### Mantissa math, made concrete

An `f32` is a sign bit, 8 exponent bits, and a 23-bit mantissa — 24 significant binary digits. The spacing between adjacent representable values doubles with every power of two:

| Position (units/meters) | Spacing to the next f32 |
|---|---|
| 1 | 0.00000012 (0.12 µm) |
| 1,024 | 0.000122 (0.12 mm) |
| **16,384** | **0.00195 (~2 mm)** |
| 65,536 | 0.0078 (~8 mm) |
| 1,048,576 | 0.125 (12.5 cm) |

At 16,384.0 the spacing is exactly `2^(14−23) = 2^-9` ≈ 2 mm — that's the whole computation, and it's worth doing once by hand. Two millimeters sounds survivable for a *position*. The problem is *arithmetic*: every frame, that position is rotated by the view matrix (mixing a huge x into y and z), subtracted from another huge number, interpolated, and animated. Each operation rounds to the nearest representable value, you lose two to four trailing bits across the chain, and the result wanders by several millimeters *differently each frame*. A few mm of frame-to-frame wander on something one meter from the camera is whole pixels: vertices jitter, bobbing animations stutter in steps, specular highlights crawl, and (once you have them in Chapter 39) shadow edges boil. That's why the practical pain threshold is ~10 km, not the 100 km the table might suggest.

### The fix: periodically rebase

The cure was already hiding in Chapter 12's sea tile: **keep everything that reaches the GPU small and camera-anchored**. A floating origin generalizes it. When the camera drifts more than a threshold from the origin of *render space*, pick a shift (essentially the camera's position, snapped), subtract it from **every world-space position in the game** — camera, boat, buoys, lantern lights, terrain origin — and remember the running total in an `f64` accumulator:

```
render space (f32, what the GPU sees)      logical space (f64, the "real" world)
camera at  (4900, 3, 120)    REBASE        logical = render + world_offset
        ── shift (4898.4, 0, 117.2) ──>    world_offset += shift
camera at  (1.6, 3, 2.8)                   seeds, saves, GPS all use logical
```

Nothing on screen moves — every relative distance is preserved exactly, because everything shifted by the *same* number. Only the coordinate labels changed. An `f64` has a 53-bit mantissa: at 16,000 km its spacing is still ~2 µm, so `world_offset` can accumulate for the lifetime of the sun. Logical coordinates (`render + world_offset`) are what noise seeds, save files, and the eventual chunk streamer consume.

### Rebase vs camera-relative rendering

What you're building is the **pragmatic fix**: positions stay world-space f32, just kept small by occasional rebasing. The **deep fix** — what AAA engines do — is *camera-relative rendering*: the camera is always exactly at the render-space origin, and every model matrix is built as model-*view* on the CPU in f64 before truncating to f32 for upload. No thresholds, no rebase events, no system ever forgets to enroll. It also touches every matrix upload in the codebase, which is why we file it under "stretch" and build the rebase: same precision payoff for our scale, a tenth of the surgery.

## Odin notes

`core:math/linalg/glsl` mirrors GLSL's double types: `glsl.dvec3` is `[3]f64` with the same swizzle-free field access as `vec3`. Converting is explicit and element-wise — there's no implicit f32→f64 widening of vectors, so write the three casts out: `glsl.dvec3{f64(v.x), f64(v.y), f64(v.z)}`. That noise is a feature: every place precision changes is visible in the diff.

## Build

1. **State.** In your game struct, add the accumulator and a debug switch:

   ```odin
   Game :: struct {
       // ...existing fields...
       world_offset:   glsl.dvec3, // logical position of render-space origin
       rebase_enabled: bool,       // start true; toggled by the teleport test
   }

   REBASE_DISTANCE :: 4096.0 // comfortably before precision, comfortably after "never"
   ```

2. **Give the terrain an origin.** Chunk meshes are baked in world space and drawn with an identity model — that bake is exactly what a rebase can't cheaply rewrite. Don't rewrite it: add `origin: glsl.vec3` to `Terrain` (zero-initialized), draw every chunk with `u_model = glsl.mat4Translate(terrain.origin)` instead of identity, and cull with shifted boxes:

   ```odin
   if !aabb_in_frustum(frustum, chunk.aabb_min + terrain.origin,
                                chunk.aabb_max + terrain.origin) do continue
   ```

   Likewise, `terrain_height_at` now samples at `p - terrain.origin`, and the sea shader's heightfield lookup gets the same subtraction (pass `u_terrain_origin`). The chunk data never changes; only where the whole landmass *sits* in render space does.

3. **The rebase proc.** One proc, one place, every system — this list *is* the design:

   ```odin
   world_rebase :: proc(game: ^Game) {
       cam := &game.camera
       if abs(cam.position.x) < REBASE_DISTANCE &&
          abs(cam.position.z) < REBASE_DISTANCE do return

       // snap the shift to whole sea-grid cells: the ch12 lattice never notices
       cell :: f32(SEA_SIZE) / f32(SEA_CELLS)
       shift := glsl.vec3{
           math.floor(cam.position.x / cell) * cell,
           0, // never rebase y — sea level must stay sea level
           math.floor(cam.position.z / cell) * cell,
       }

       // REBASE REGISTRY: every world-space position in the game, no exceptions.
       cam.position        -= shift
       game.boat.position  -= shift
       for &b in game.buoys do b.position -= shift   // lantern lights follow their buoys
       game.terrain.origin -= shift

       game.world_offset += {f64(shift.x), 0, f64(shift.z)}
   }
   ```

   Call it at exactly **one** point in the loop: top of frame, before the fixed update runs. Mark the registry comment loudly — Chapters 34 (wake points), 46 (particles), and anything else that ever stores a world-space position must add a line here the day it's born.

4. **World-position patterns in shaders.** The sea shimmer derives its pattern from `v_world_pos.xz`, which is now render space — after a rebase the paint would visibly snap by a fraction of a wavelength. Pass the offset back: `shader_set_vec2(sea.shader, "u_world_origin", {f32(game.world_offset.x), f32(game.world_offset.z)})` and pattern on `v_world_pos.xz + u_world_origin`. Millimeter-scale f32 error in a *color* phase is invisible — it was geometry and matrices that jittered, never tint. (If you someday stream past thousands of km, wrap the uniform modulo a large multiple of the pattern periods.)

5. **The GPS.** Put logical coordinates in the title bar next to the seed:

   ```odin
   logical := glsl.dvec3{f64(cam.position.x), f64(cam.position.y), f64(cam.position.z)}
            + game.world_offset
   ```

   Sanity: stand still, force a rebase by temporarily setting `REBASE_DISTANCE` to 100 — the readout must not change by even a millimeter.

6. **The teleport test.** Bind a debug key (say `J`) that adds `{50_000, 0, 0}` to the camera, boat, and buoy positions (taking the cast with you so there's something to look at), and a key to toggle `rebase_enabled` (gate step 3's proc on it). Jump with rebase **off**: get close to a bobbing crate — vertices wobble, the bob animation moves in coarse steps, lantern glints crawl, the sea shimmer looks chunky. Toggle rebase **on**: one frame later everything is at small coordinates again and the scene is glass. Title bar still reads x ≈ 50,000.

## Checkpoint

The world is unmoored and doesn't know it.

- Teleport 50 km out, rebase off: visible vertex jitter and stuttering bob on the crates. Rebase on: it vanishes within a frame. Teleport home: the islands are exactly where you left them.
- Sail (fly, for now) across `REBASE_DISTANCE`: the moment of rebase is *completely invisible* — no pop in terrain, sea pattern, foam, or shadows-to-be.
- The logical GPS readout is continuous across rebases and round-trips the teleport exactly.
- `R` still regenerates the identical world: seeds and worldgen never noticed any of this.

## Pitfalls

- **One system forgotten = one thing teleports.** Anything not in the registry stays behind by `shift` at the rebase — usually discovered as "the buoy vanished" or, later, "my wake trail snapped into the sky." When you build the wake in Chapter 34 and particles in Chapter 46, their stored world positions (including cached ones like the wake's `last_drop`!) must join `world_rebase` the same day.
- **Rebasing mid-frame.** If you shift between the physics update and the render, half your frame computed with old coordinates and half with new — one frame of everything lurching by `shift`. One call site, top of frame, nothing else.
- **Physics and animation popping.** Any phase or state derived from a world position — a bob phase like `sin(t + position.x)`, a noise-driven flicker — changes value at the rebase. Derive such phases from *logical* coordinates or store them per-object at spawn.
- **Snapping the shift to the wrong quantum.** Snap to sea-grid cells (the ch12 trick's quantum) and the sea lattice provably lands on itself. Snap to 1.0 or nothing and you reintroduce exactly the shimmer Chapter 12 cured.
- **Rebasing y.** Sea level is `y = 0` by construction everywhere (heights, foam bands, shoreline math). Shift only x and z.

## Exercises

1. Make the rebase observable: log each shift with before/after camera coordinates, then fly in a 10 km circle and verify `world_offset` integrates back to ~zero when you return (to within f32 snap quanta).
2. Add a `world_to_render` / `render_to_world` proc pair (`glsl.dvec3` ↔ `glsl.vec3`) and route the title-bar GPS, the seed-picker prints, and `terrain_height_at` callers through them — the type system now documents which space every coordinate lives in.
3. **Stretch:** prototype camera-relative rendering on one object: compute the boat's model-view matrix on the CPU in f64 (`f64` camera position subtracted before truncation), upload it, and use `u_view = identity` for that draw. Teleport to 200 km — past where the rebase's f32 render space itself gets coarse — and compare the boat against a rebase-only buoy.

## Commit

`git commit -m "ch25a: floating origin — f64 world offset, rebase registry, teleport test"`

← Back to [Chapter 25 — MILESTONE: The Archipelago](ch25-milestone-the-archipelago.md) · onward to [Chapter 26 — A Box of Sky](../part-5-the-living-sea/ch26-a-box-of-sky.md) →
