# Chapter 87 — Cargo Overboard

*Part 13 — The Captain's Appendices · Standalone: requires Part 6 (the sailing boat) · Estimated time: 6h · learnopengl: no direct equivalent — canonical references: Erin Catto's GDC sequential-impulses talks and the Gaffer On Games physics series*

**What you'll see when done:** cargo crates standing on your deck until a gust heels her over — then sliding to leeward, tumbling against the bulwark, and going overboard to float away in your wake; and a cannonball that arcs, splashes, and sends a crate spinning.

## Where we are

This appendix is readable the moment you finish Part 6: it needs the fixed timestep (ch10), the boat with heel (ch32–33), and `ocean_height_at`. If you've done ch46 (particles) and ch67 (ripples), the cannonball splash gets its full glory; without them it just splashes more modestly.

Why this question always comes up: every game eventually wants *one thing* to tumble convincingly — a crate, a barrel, a ragdoll's ancestor — and the learner peeks inside a physics engine and recoils. The pitch of this chapter: 3D rigid-body physics the *practical-game* way is maybe 400 lines, and you already own its two hardest prerequisites — a fixed timestep and a reason to care. Scope, stated honestly up front: rigid boxes and spheres, the 15-axis SAT, one-point contacts, sequential impulses. No joints, no sleeping, no continuous collision, no convex hulls — a physics-engine *thesis* would need all four; sliding cargo doesn't.

## Concepts

### A rigid body is twelve numbers and two matrices

Linear motion you know: position, velocity, mass. A rigid body adds the rotational mirror of each: **orientation** (a quaternion), **angular velocity** `ω` (a vector: axis × radians/sec), and the rotational analogue of mass — the **inertia tensor** `I`, a 3×3 matrix describing how hard the body is to spin *about each axis*. A broomstick spins easily along its length and reluctantly end-over-end; the tensor encodes that. For the shapes we need, closed forms suffice (about the center of mass, axis-aligned):

```
box  (half-extents h):  I = (m/3) * diag(h.y²+h.z², h.x²+h.z², h.x²+h.y²)
sphere (radius r):      I = (2/5) m r² * identity
```

Two practical facts and we're done with tensor math: you only ever need the **inverse** (store `inv_inertia_body` as a `glsl.vec3` diagonal), and it must rotate with the body — world-space inverse inertia is `R * I_body⁻¹ * Rᵀ`, rebuilt from the orientation whenever you use it.

### Integration: semi-implicit Euler, the ch10 payoff

```
v += (F/m) * dt        // velocity FIRST
x += v * dt            // then position uses the NEW velocity
ω += I⁻¹ τ * dt
q  = rotate(q, ω*dt); normalize(q)
```

Updating velocity before position — *semi-implicit* (symplectic) Euler — is the entire difference between a sim that slowly gains energy until it explodes and one that's stable for hours. It's also only trustworthy with a **fixed dt**: Chapter 10's architecture decision was made, it turns out, for this chapter. Orientation integrates by converting `ω*dt` to an angle-axis quaternion and composing — then normalizing, every step, or numerical drift slowly turns your rotation into a shear.

### Collision detection: three tests, in order of difficulty

- **Sphere–sphere:** distance between centers vs. sum of radii. One line.
- **Sphere–AABB:** clamp the sphere center to the box, measure to the clamped point. Three lines; this is also "cannonball vs. deck."
- **OBB–OBB** — the real one — via the **separating axis theorem**: two convex shapes are disjoint iff *some* axis exists onto which their projections don't overlap. For two boxes, it's provable you only need to test 15 candidate axes:

```
 box A axes: A0 A1 A2            the 15 candidate axes:
 box B axes: B0 B1 B2              3  face normals of A      (A0, A1, A2)
                                   3  face normals of B      (B0, B1, B2)
       A1                          9  edge-edge crosses      (Ai × Bj)
       │ ┌─────┐      ╱╲
       │ │  A  │     ╱B ╲        project both boxes onto each axis:
       └─┼───> A0    ╲  ╱        ANY axis with a gap  -> separated, done
         └─────┘      ╲╱         no gaps              -> colliding, and the
   ── axis L ──────────────────     axis of MINIMUM overlap is the contact
      |--A--|   gap  |-B-|          normal (push apart the cheapest way)
```

A box's projection radius onto axis `L` is `r = Σ hᵢ·|Aᵢ·L|` (half-extents times how much each box axis leans along `L`). Fifteen interval tests; if all overlap, the minimum-overlap axis is your contact normal and the overlap is your penetration depth.

- **Contact point**, kept deliberately simple: the **deepest point** of one body inside the other (for box-vs-plane: each penetrating corner; for OBB-OBB: the support point of B along −normal). Real engines build multi-point *manifolds* and cache them across frames for warm-starting — that's the genuine next step, and Catto's talks are where it's taught. One point per pair plus per-corner plane contacts is enough for cargo.

### Impulse resolution: the j formula

An impulse is an instant change in momentum. At a contact with normal `n`, with `r_a, r_b` the vectors from each center of mass to the contact point, the relative velocity *at the point* is:

```
v_rel = (v_b + ω_b × r_b) − (v_a + ω_a × r_a)
```

If `v_rel · n < 0` the bodies are approaching. We want the post-impulse approach speed to be `−e` times the pre-impulse one (`e` = restitution: 0 dead, 1 superball). Solving for the scalar impulse magnitude gives the most useful formula in game physics:

```
            −(1 + e) (v_rel · n)
j = ─────────────────────────────────────────────────────
    1/m_a + 1/m_b + n · ( (I_a⁻¹(r_a×n))×r_a + (I_b⁻¹(r_b×n))×r_b )
```

The denominator is the *effective mass* seen along `n`: the two `1/m` terms you'd expect, plus two angular terms that say "hitting a body far from its center is easier, because some of the blow goes into spin." Apply it symmetrically:

```
v_a -= j·n / m_a;   ω_a -= I_a⁻¹ (r_a × j·n)
v_b += j·n / m_b;   ω_b += I_b⁻¹ (r_b × j·n)
```

**Friction** is the same formula along the tangent `t` (the contact-plane direction of sliding), with `e = 0` — but clamped by Coulomb's law: `|j_t| ≤ μ·j`. Below the clamp the contact *sticks*; at the clamp it *slides*. That clamp is the entire static-vs-kinetic distinction, and it's why crates will sit still on a gently heeled deck and let go in a gust.

**Positional correction:** impulses fix velocities, not positions, so resting stacks slowly sink. The standard patch (Baumgarte stabilization): each solve, push positions apart by a fraction of the penetration beyond a small tolerance — `correction = max(depth − slop, 0) · β / (1/m_a + 1/m_b) · n` with `slop ≈ 5 mm`, `β ≈ 0.2`. The slop prevents jitter at exact rest; the fraction prevents pop.

**Sequential impulses:** with several simultaneous contacts, solving one disturbs another. The fix that powers Box2D and most engines: just iterate — solve every contact, in any order, 6–10 times per step. Each pass redistributes the error; it converges fast in practice. That loop *is* `contacts_solve`.

### The delicious part: physics in the boat's frame

Simulating crates in world space means every wave jolt becomes a collision problem. The trick that makes deck cargo tractable: **simulate in boat-local space**, where the deck is a fixed horizontal plane forever — and instead, *rotate gravity*. Transform world gravity `(0,−9.8,0)` by the inverse of the boat's rotation: when she heels 15°, local gravity tilts 15° to leeward, and the crates respond exactly as your inner ear would. We deliberately ignore the fictitious forces a non-inertial frame adds (centrifugal, Euler) — a sailboat's angular rates are small and gravity tilt dominates; that's the honest engineering call, and it buys you a perfectly stable deck.

One readymade joy: a crate on a heeling deck stays put while `tan(heel) < μ` and slides when the gust pushes past it. You can *measure* your friction coefficient by reading the heel angle at the moment cargo lets go.

## Odin notes

`core:math/linalg` has the quaternion kit: `linalg.Quaternionf32`, `linalg.quaternion_angle_axis_f32`, `linalg.quaternion_normalize`, `linalg.quaternion_mul_vector3` (rotate a vector), `linalg.quaternion_inverse`, and `linalg.matrix4_from_quaternion` / `linalg.matrix4_from_trs` for rendering. Mixing it with `glsl.vec3` is painless — `linalg.Vector3f32` and `glsl.vec3` are the same `[3]f32` underneath; `linalg.cross` works on either. Identity quaternion: `linalg.QUATERNIONF32_IDENTITY`.

## Build

1. **`Rigid_Body` and `body_integrate`, `src/physics.odin`:**

   ```odin
   Rigid_Body :: struct {
       position:    glsl.vec3,      // boat-local (crates) or world (cannonball)
       orientation: linalg.Quaternionf32,
       velocity:    glsl.vec3,
       omega:       glsl.vec3,      // angular velocity, rad/s
       inv_mass:    f32,            // 0 = immovable (the deck)
       inv_inertia_body: glsl.vec3, // diagonal, body space
       half_extents: glsl.vec3,     // box collider
       restitution, friction: f32,  // 0.1, 0.5 for wooden crates
   }

   body_integrate :: proc(b: ^Rigid_Body, gravity: glsl.vec3, dt: f32) {
       if b.inv_mass == 0 do return
       b.velocity += gravity * dt                      // velocity first:
       b.position += b.velocity * dt                   // semi-implicit Euler
       w := linalg.length(b.omega)
       if w > 1e-6 {
           dq := linalg.quaternion_angle_axis_f32(w * dt, b.omega / w)
           b.orientation = dq * b.orientation
       }
       b.orientation = linalg.quaternion_normalize(b.orientation)
   }
   ```

   `body_make_box(size, mass)` fills `inv_inertia_body` from the closed form above. Per house rules: `physics_create` / `physics_destroy` for whatever owns the `[dynamic]Rigid_Body`.

2. **The deck world.** A `Deck_Sim` holding crates (boat-local), the deck plane height, and the bulwark as four immovable AABB walls (or just clamp planes). Each fixed step:

   ```odin
   deck_gravity :: proc(boat: ^Boat) -> glsl.vec3 {
       inv := linalg.quaternion_inverse(boat_orientation_quat(boat)) // yaw*roll*pitch, as ch32 composes it
       return linalg.quaternion_mul_vector3(inv, glsl.vec3{0, -9.8, 0})
   }
   ```

   Build `boat_orientation_quat` by composing the ch32 yaw/roll/pitch as `quaternion_angle_axis` products in the *same order* as the ch32 matrix. Verify before going further: print `deck_gravity` while she heels — the x-component should grow with the heel angle, sign toward leeward.

3. **Contact generation.** A `Contact :: struct { a, b: ^Rigid_Body, point, normal: glsl.vec3, depth: f32 }` and `contacts_find` appending into a `[dynamic]Contact`:

   - **Crate vs. deck plane:** transform the 8 corners by the crate's orientation; every corner below the deck plane adds a contact (point = corner, normal = deck up, depth = how far below). Per-corner contacts are the cheap manifold that lets a box *rest flat* instead of rocking on one point.
   - **Crate vs. crate:** the 15-axis SAT. The core helper:

   ```odin
   // overlap of two OBBs projected on axis L (assumed normalized); negative = gap
   sat_overlap :: proc(a, b: ^Rigid_Body, axes_a, axes_b: [3]glsl.vec3, l: glsl.vec3) -> f32 {
       ra := a.half_extents.x * abs(linalg.dot(axes_a[0], l)) +
             a.half_extents.y * abs(linalg.dot(axes_a[1], l)) +
             a.half_extents.z * abs(linalg.dot(axes_a[2], l))
       rb := b.half_extents.x * abs(linalg.dot(axes_b[0], l)) +
             b.half_extents.y * abs(linalg.dot(axes_b[1], l)) +
             b.half_extents.z * abs(linalg.dot(axes_b[2], l))
       return ra + rb - abs(linalg.dot(b.position - a.position, l))
   }
   ```

   Loop the 15 axes (skip near-zero cross products — parallel edges; normalize the rest), track the minimum positive overlap; any negative → early out, no collision. Contact point: the corner of B deepest along −normal. Orient the normal from A toward B (`dot(normal, b.pos − a.pos) > 0` or flip).

4. **`contacts_solve` — sequential impulses:**

   ```odin
   contacts_solve :: proc(contacts: []Contact, iterations := 8) {
       for _ in 0 ..< iterations do for &c in contacts {
           ra := c.point - c.a.position
           rb := c.point - c.b.position
           v_rel := (c.b.velocity + linalg.cross(c.b.omega, rb)) -
                    (c.a.velocity + linalg.cross(c.a.omega, ra))
           vn := linalg.dot(v_rel, c.normal)
           if vn > 0 do continue                         // separating already
           e := min(c.a.restitution, c.b.restitution)
           inv_ia := body_world_inv_inertia(c.a)         // R * diag * R^T
           inv_ib := body_world_inv_inertia(c.b)
           ang := linalg.dot(c.normal,
                  linalg.cross(inv_ia * linalg.cross(ra, c.normal), ra) +
                  linalg.cross(inv_ib * linalg.cross(rb, c.normal), rb))
           j := -(1 + e) * vn / (c.a.inv_mass + c.b.inv_mass + ang)
           body_apply_impulse(c.a, -j * c.normal, ra)
           body_apply_impulse(c.b,  j * c.normal, rb)
           // friction: same machinery along the tangent, clamped to mu*j
           t := v_rel - vn * c.normal
           if linalg.length(t) > 1e-6 {
               t = linalg.normalize(t)
               jt := -linalg.dot(v_rel, t) / (c.a.inv_mass + c.b.inv_mass + /* ang term with t */ )
               mu := math.sqrt(c.a.friction * c.b.friction)
               jt = clamp(jt, -mu * j, mu * j)
               body_apply_impulse(c.a, -jt * t, ra)
               body_apply_impulse(c.b,  jt * t, rb)
           }
       }
       // Baumgarte: one positional pass after the velocity iterations
       for &c in contacts do contact_correct_positions(&c) // slop 0.005, beta 0.2
   }
   ```

   `body_apply_impulse(b, p, r)` is `velocity += p * inv_mass; omega += inv_inertia_world * cross(r, p)`. Solve friction *after* the normal impulse of the same contact — the clamp needs `j`.

5. **The fixed-step loop**, after `boat_update_buoyancy`: compute `deck_gravity`, `body_integrate` each crate, `contacts_find`, `contacts_solve`. Render crates with `linalg.matrix4_from_trs(local_pos, orientation, 1)` *parented to the boat's ch18 node* — the hierarchy turns boat-local physics into world rendering for free.

6. **Overboard — the handoff.** When a crate's local position leaves the deck bounds (beyond the bulwark and below deck height), retire it from `Deck_Sim`: transform position and velocity to world space (rotate by the boat quaternion, add boat position and boat velocity), and spawn it as a ch32-style floater — the same `ocean_height_at` buoyancy that bobs your buoys (or the ch65 drifting-cargo path if you've built Part 10). The moment of handoff is invisible if you match velocities; do match velocities. Now heel hard in a gust and watch the cargo you forgot to lash go over the side and fall astern, bobbing in your wake. This is the screenshot.

7. **The cannonball.** A world-space `Rigid_Body` sphere. Fire (key B) from the bow with the boat's velocity plus muzzle velocity along a 20° elevation:

   ```odin
   ball_update :: proc(b: ^Rigid_Body, o: Ocean, t, dt: f32) -> (splashed: bool) {
       drag := -0.02 * linalg.length(b.velocity) * b.velocity   // quadratic, cartoon coefficient
       b.velocity += (glsl.vec3{0, -9.8, 0} + drag * b.inv_mass) * dt
       b.position += b.velocity * dt
       return b.position.y < ocean_height_at(o, b.position.xz, t)
   }
   ```

   On splash: `ripple_splat` at the impact (ch67, strength from impact speed) and a spray burst from the ch46 pool — then despawn or let it sink. On the way, test the ball (transformed into boat space) against each crate with sphere-vs-OBB (clamp to the box, compare to radius); on hit, apply the j-formula impulse at the contact point to the crate and watch it *spin away from where you hit it* — the angular term in the denominator, suddenly visible and deeply satisfying.

### Flatland note

Everything above minus one axis *is* 2D physics: orientation becomes a single angle, `ω` and torque become scalars, the inertia tensor becomes one number (`m(w²+h²)/12` for a box), the cross products collapse to `perp_dot`, and SAT needs 4 axes instead of 15. The j formula is unchanged. If you ever want a 2D side project, you now know Box2D's heart — same Catto algorithm, fewer components.

### When to reach for a real engine

The moment you want stacks of ten, ragdolls, joints, vehicles, or thousands of bodies, use an engine: **Jolt** (C++, open source, ships in AAA games), **Box2D** (2D — and Odin ships official bindings as `vendor:box2d`), **Rapier** (Rust, usable via its C API). For Jolt from Odin, community bindings have existed but move around — search the Odin package lists and the Odin Discord rather than trusting a chapter to stay current. What this chapter bought you is that an engine's documentation now reads as a menu of things you've built small versions of: broadphase (you skipped it — n² pairs), manifolds and warm starting (your "next step"), solver iterations (your `iterations := 8`), sleeping, CCD. You'll configure engines better forever for having written the 400-line one.

## Checkpoint

Stack three crates on deck in harbor: they settle and *stay*, no jitter (slop and friction working). Sail close-hauled into a gust: heel passes the `atan(μ)` threshold and the stack lets go to leeward, tumbling — corners catching, boxes rotating — until the bulwark stops them or doesn't. One goes over: it splashes into world space without a velocity pop and floats astern. Fire the cannonball: ballistic arc bent slightly by drag, a ripple-ringed splash, and on a direct hit a crate kicks away spinning about the impact point, not its center.

- Pause (ch10) freezes crates mid-tumble; stepping one tick at a time looks continuous.
- A crate dropped from 2 m bounces once dully (`e = 0.1`) and stops dead.
- Double `μ` to 1.0: cargo survives gusts that previously cleared the deck.

## Pitfalls

- **Resting crates hum/jitter.** No slop in the positional correction, or restitution applied to tiny contact speeds — add a velocity threshold below which `e = 0`.
- **Crates slowly sink through the deck.** Velocity-only resolution; the Baumgarte pass is missing or `β` too small.
- **A crate spins up forever after one collision.** Orientation not renormalized each step, or you applied the impulse with `r` measured from the contact instead of *to* it (sign of `cross(r, p)`).
- **Everything explodes on the first contact.** The angular term's inertia is in body space — you skipped the `R I⁻¹ Rᵀ` world transform, so torques are computed about the wrong axes.
- **Fast cannonball passes through a crate.** Tunneling: at 40 m/s and 60 Hz it moves 0.66 m per step — bigger than a crate. Substep the ball (4 sub-integrations per tick) or raycast its swept segment; real engines call the general solution CCD.
- **Cargo slides on a *level* deck.** Your `deck_gravity` composition order doesn't match the ch32 matrix order — yaw must come first, exactly as the matrix does, or pitch leaks into roll.

## Exercises

1. Per-material properties: barrels (`e=0.3, μ=0.3`, cylinder ≈ box for now) skitter and roll farther than crates. Two constants, distinct personalities.
2. **Sleeping:** if a body's linear+angular speed stays under thresholds for 1 s, freeze it (skip integration) until something touches it. Watch your crate stack's cost drop to ~zero — this is why engine demos can show 10,000 resting bodies.
3. Lashing points: a max-distance constraint (an impulse pulling a crate toward a deck anchor when the rope is taut). Lashed cargo survives the storm; the rope is ten lines of the same impulse math.
4. **Stretch — warm-started manifolds:** cache up to 4 contact points per OBB pair across frames (match by feature/position), and start each solve from last frame's accumulated impulses. Stack five crates and compare settle time and jitter against the cold solver — this single technique is most of the gap between tonight's solver and Box2D, and Catto's GDC slides walk every line of it.

## Commit

`git commit -m "ch87: rigid bodies - deck cargo in boat frame, SAT, impulses, cannonball"`

[← Ch. 86: Postcards from Another Renderer](ch86-postcards-from-another-renderer.md) · [Ch. 88: Charts of the Modern World →](ch88-charts-of-the-modern-world.md)
