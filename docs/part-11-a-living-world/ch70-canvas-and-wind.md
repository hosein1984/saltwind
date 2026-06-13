# Chapter 70 — Canvas and Wind

*Part 11 — A Living World · Estimated time: 5h · learnopengl: no direct equivalent — canonical reference: Thomas Jakobsen, ["Advanced Character Physics"](https://www.cs.cmu.edu/afs/cs/academic/class/15462-s13/www/lec_slides/Jakobsen.pdf) (GDC 2001)*

**What you'll see when done:** your sail stops being a stiff triangle of geometry and becomes *canvas* — bellying full on a beam reach, straining at its seams in a gust, and flogging uselessly when you point too high.

## Where we are

Since ch18 the sail has been a rigid mesh on a scene node; ch33's exercise 2 made the boom swing with `sail_trim`, but the cloth itself is a board. Meanwhile the sailing model knows things the player can't *see*: the polar curve says you're in irons, but the sail looks exactly as healthy as it did on a broad reach. Today we simulate the sail as cloth — and the ch33 physics becomes visible. A luffing sail isn't a particle effect; it's the simulation telling the truth.

## Concepts

### Verlet integration: velocity is for suckers

The standard cloth disaster is springs + Euler integration: stiff springs demand tiny timesteps or they explode. Jakobsen's insight (this is the Hitman ragdoll paper) is to store **no velocity at all** — just current and previous position:

```
x_new = x + (x - x_prev) * damping + a * dt²
x_prev = x
```

Velocity is *implicit* in `x - x_prev`. Why this matters: when a constraint solver later shoves a point somewhere, the velocity automatically becomes consistent with the shove — there's no separate velocity variable left pointing the old way, which is exactly the desync that makes spring-mass cloth explode. Position-based dynamics is stable at game timesteps almost no matter what you do to it. (Your fixed timestep from ch10 makes `dt²` a constant — another decade-old decision paying rent.)

### Constraints by relaxation

Cloth-ness comes from distance constraints: "these two particles want to be `rest` apart." Enforcing one is two lines — move both points along their connecting line until the distance is right:

```
delta = p2 - p1
err   = (length(delta) - rest) / length(delta)
p1 += delta * 0.5 * err     // pinned points: skip, give the
p2 -= delta * 0.5 * err     // other point the full correction
```

Satisfying one constraint violates its neighbors — so you iterate the whole set several times (**relaxation**). It converges fast and degrades gracefully: too few iterations doesn't explode, it just makes stretchier cloth. 4–8 passes is the classic range; sails are stiff fabric, use 8.

On a grid, two constraint families are enough:

```
●──●──●   structural: each point to its right & down neighbor
│ ╲│ ╲│   shear: the diagonals — without them the grid
●──●──●          collapses sideways like a parallelogram
│ ╲│ ╲│   (bend constraints — skip-one-neighbor — make stiffer
●──●──●    cloth; sails barely need them. Exercise.)
```

### Pins and the rig

A sail is cloth with edges *attached to rigid spars*. For your Bermuda mainsail: the **luff** (leading edge, column 0) pins to the mast; the **foot** (bottom row) pins to the boom. Pinned particles don't integrate and don't yield in constraints — each step you *set* their positions from the boat's transform hierarchy (ch18): mast points from the hull node, foot points from the boom node, which rotates with `sail_trim`. Trim the sail and the boom swings; the boom drags the foot; relaxation propagates the change up the cloth in a wave. Nobody animates this. It just happens.

### Wind force per triangle

Per-particle wind is wrong — a cloth's response to wind depends on its *orientation*. For each triangle of the sail grid: compute its normal and area, find the wind velocity **relative to the moving cloth** (apparent wind — true wind minus boat velocity, ch33's stretch exercise now mandatory), and push along the normal by how squarely the wind hits it:

```
v_rel = wind_vec - particle_velocity        (velocity = (x - x_prev)/dt)
f     = n * dot(n, v_rel) * |v_rel| * area * C
```

`dot(n, v_rel)` is signed — wind from behind pushes one way, from ahead the other, and **near zero it flutters**: tiny normal oscillations flip the force sign, which feeds the oscillation. That *is* luffing. You don't code flapping; you code the force law honestly and flapping emerges precisely when the ch33 polar says `sail_power ≈ 0`. In irons, the cloth flogs. Distribute `f/3` to the triangle's three particles.

### CPU is plenty

A sail is a 20×15 grid: 300 particles, ~1,100 constraints, ~530 triangles. At 8 relaxation passes that's microseconds. Resist the urge to compute-shader this — the GPU is busy with the ocean, and you want the cloth positions CPU-side anyway (the boom, sound triggers, ch74's rain occlusion). The mesh uploads like the gull instance buffer: `gl.BufferSubData` of positions + normals each frame into a `DYNAMIC_DRAW` VBO, static index buffer.

## Odin notes

Index the grid flat (`i = y * W + x`) and keep particles in plain parallel-friendly arrays — a `#soa` slice works, but a simple AoS struct array is fine at 300 elements:

```odin
Cloth :: struct {
    w, h:      int,
    pos:       []glsl.vec3,
    prev:      []glsl.vec3,
    pinned:    []bool,
    constraints: []Cloth_Constraint,    // {a, b: i32, rest: f32}
    vbo_positions, vbo_normals: u32,
    mesh:      Mesh,
    iterations: int,                    // 8
}
```

Allocate once in `cloth_create` with `make`; this system never allocates at runtime. Normals: zero a scratch array, add each triangle's cross-product normal to its three vertices, normalize at the end — the same accumulation trick as your terrain normals (ch22), minus the central differences.

## Build

1. **`src/cloth.odin`: create and step.** Build the grid in the sail's local plane, generate structural + shear constraints, mark pins. The step, called from the fixed timestep:

   ```odin
   cloth_step :: proc(c: ^Cloth, wind_vec: glsl.vec3, dt: f32) {
       for i in 0 ..< len(c.pos) {
           if c.pinned[i] do continue
           vel := (c.pos[i] - c.prev[i]) * 0.995          // damping
           c.prev[i] = c.pos[i]
           c.pos[i] += vel + c.accel[i] * dt * dt          // accel from forces, below
           c.accel[i] = {0, -9.8, 0}                       // reset to gravity
       }
       for _ in 0 ..< c.iterations {
           for con in c.constraints {
               cloth_satisfy(c, con)                       // the two-liner from Concepts
           }
       }
   }
   ```

2. **Wind forces.** Before integration, loop the grid's triangles, apply the per-triangle force from Concepts into `accel` (divide by a nominal particle mass; `C ≈ 0.6` to start). `wind_vec` comes from ch33's `Wind` (direction + strength as a vector) **minus the boat's velocity vector** — apparent wind. Gust modulation: multiply strength by the same gust function ch73 will formalize; for now `1.0 + 0.3 * noise` of time is fine.

3. **Pin to the rig.** Each fixed step *before* `cloth_step`, write pinned positions from the scene graph: column 0 from mast-node world positions, row 0 (foot) from boom-node world positions at the current `sail_trim` angle. The boom swings on trim and on tacks (auto-trim crossing the wind) and the cloth follows with a satisfying one-step lag.

4. **Dynamic mesh upload.** `cloth_update_mesh`: recompute accumulated normals, then two `BufferSubData` calls. Use a vertex layout with positions and normals in separate VBOs so you can update both without interleaving gymnastics. UVs and indices never change.

5. **Render double-sided.** The ch38 audit already documented sails as the legitimate two-sided exception: draw with `gl.Disable(gl.CULL_FACE)` and flip the normal in the fragment shader on back faces (`if (!gl_FrontFacing) n = -n;`). Use your PBR shader with a high-roughness white "canvas" material; the belly's smooth shading gradient is what sells the curve.

6. **Sail.** Beam reach: the cloth fills into a clean aerofoil belly. Head up slowly toward irons and watch the luff (the mast edge) start to bubble and flutter *before* the whole sail flogs — exactly how a real sail warns you. Ease trim too far on a reach: the sail twists open and spills. Your ch33 HUD numbers now have a body.

## Checkpoint

A sail that is unmistakably cloth: filled and quiet when trimmed, luffing at the leading edge when pinched, flogging violently in irons, and swinging across with a whump on every tack (ch36 users: trigger a canvas-snap sample when average cloth speed spikes).

- In irons, the sail flaps chaotically and the ch33 model reads ~zero power — the two systems agree without sharing code.
- Trim from ideal to fully eased on a beam reach: the belly visibly empties; speed bleeds on the HUD.
- Cloth never explodes: ram the boat in circles at storm wind — stretchy at worst, never NaN.
- Frame cost of `cloth_step` is below 0.1 ms (put it on the ch49 CPU timer to prove it).

## Pitfalls

- **The cloth slowly sinks/stretches over time.** Too few relaxation iterations for your gravity + wind magnitude, or your constraint correction uses unnormalized `delta` math. Stiff sails want 8 passes; verify the `err` formula divides by current length.
- **Explodes on the first tack.** You're setting pinned positions *after* `cloth_step` instead of before, so constraints see a teleport with stale `prev`. Order: pins → forces → integrate → relax. Also set `prev = pos` for pins when you move them (they carry no velocity).
- **Cloth vibrates at rest.** `dt` isn't fixed (you called `cloth_step` from the render loop — it belongs in the ch10 accumulator), or damping is 1.0 exactly. 0.99–0.997 is the calm band.
- **Sail looks faceted, not curved.** You uploaded positions but forgot the normals `BufferSubData`, so it's lit by the bind-pose normals. The mesh moves; the light doesn't.
- **One side of the sail is black.** Culling still on for this draw, or you skipped the `gl_FrontFacing` flip — re-read ch38's exception note.
- **Wind does nothing.** Your triangle normal and `v_rel` are in different spaces. Do *everything* in world space — pins come from world transforms anyway, so the whole sim should live there.

## Exercises

1. Bend constraints: add skip-one structural constraints (`x` to `x+2`) at, say, 0.5 strength. Compare luffing character — stiffer cloth flutters at higher frequency, like heavier sailcloth.
2. A jib: second, triangular cloth pinned along the forestay. Two sails interacting with one wind model, zero new code paths — the system test that proves your abstractions.
3. Reefing: a key that re-pins the bottom third of the grid to the boom (and shortens the active grid). Storm seamanship, visible.
4. **Stretch:** tearing. Give each constraint a `max_strain` (e.g. 1.6× rest); in a storm gust, when strain exceeds it, remove the constraint (swap-remove from the slice) and rebuild triangle adjacency for normals. A blown-out sail flogging in ribbons is the most dramatic single frame this game can produce — pair it with ch74.

## Commit

`git commit -m "ch70: verlet cloth sail — constraints, per-triangle wind, visible luffing"`

[← Ch. 69: Castles of Vapor](ch69-castles-of-vapor.md) · [Ch. 71: Bones of the Gull →](ch71-bones-of-the-gull.md)

> ⚓ **Optional side quest:** [Interlude 70a — Ropes and Rigging](ch70a-ropes-and-rigging.md) — your cloth solver minus a dimension: sagging halyards, an anchor line that holds the boat, and a lantern swinging from the boom.
