# Interlude 71a — Feet on the Deck

*⚓ Optional interlude · slots after [Chapter 71](ch71-bones-of-the-gull.md) · Estimated time: 7–9h · learnopengl: no direct equivalent — canonical references: [Ryan Juckett, "Analytic Two-Bone IK in 2D"](https://www.ryanjuckett.com/analytic-two-bone-ik-in-2d/) (the 3D version is that plus a plane) and the [GDC Animation Bootcamp archive](https://www.gdcvault.com/free/gdc-bootcamp)*

**Prerequisites:** Chapter 71 — the skeleton, clip sampling, two-pose blending, and a rigged sailor (the Mixamo-to-glTF route) standing on deck. · **Required downstream:** none — skip freely.

**What you'll see when done:** one sailor who *lives* on the boat: feet planted on the heeling deck with knees flexing to match, head tracking the gull, walking when he moves and idling when he doesn't, and waving at you mid-stride without his legs noticing.

## Why this is a side quest

Chapter 71 made the sailor *play animations*. This interlude makes him *respond to the world* — and the gap between those two is an entire discipline (animation programming) that rendering courses never enter. The main line doesn't need it: the gull flies, the milestone ships. But a character on a deck that heels ±15° is the perfect forcing function for the two tools every animated game is built from — **inverse kinematics** (given where a hand or foot must *be*, solve the joints) and **blend logic** (mix clips by gameplay state, in layers, through masks). Scope discipline up front: one sailor, two legs, one head, one wave. No animation graph editor, no state-machine framework — arrays and procs.

## Concepts

### Two-bone IK is a triangle

Forward kinematics (ch71) goes rotations → positions. IK inverts it, and for a two-bone chain — thigh `L1`, shin `L2`, hip-to-target distance `d` — the inversion is closed-form, because three lengths determine a triangle. Law of cosines, twice:

```
cos(knee_interior) = (L1² + L2² − d²) / (2·L1·L2)      → knee bend angle
cos(hip_offset)    = (L1² + d² − L2²) / (2·L1·d)       → hip aims at target, then tips by this
```

Clamp `d` into `[|L1 − L2| + ε, L1 + L2 − ε]` *before* solving — `acos` of a value outside [−1, 1] is NaN, and a fully straight knee pops; the ε keeps a soft bend at full reach.

The triangle fixes the knee's *angle* but not its *direction*: the solution can spin freely around the hip→target axis. The **pole vector** resolves it — a world-space hint ("knees point toward the bow-ish forward of the pelvis") that picks the plane the triangle lies in. Knees get a forward pole; if you later IK arms, elbows get a backward one. Every IK glitch you'll ever see in a shipped game is one of these two things: an unclamped `d` or a degenerate pole.

### Where IK lives in the pipeline

This is the load-bearing sentence of the chapter: **IK edits the pose between sampling and skinning.** The order, every frame:

```
sample/blend clips → pose (per-joint TRS)
   → layer upper-body action (masked)
   → tree walk → global joint transforms
   → IK pass: edit globals (feet, pelvis, head), convert edits back to locals
   → final walk → × inverse_bind → bone matrices
```

IK operates on *global* transforms (targets are in world/boat space), but the skeleton stores *locals* — so each IK edit converts back via the parent: `local = inverse(global[parent]) * desired_global`. For rotations alone, that's one quaternion: `q_local = quaternion_inverse(q_parent_global) * q_desired_global`.

### Foot planting on a heeling deck

The deck is a plane in boat space (flat-ish; the plane is honest enough). Per foot: take the animated foot position, cast a ray straight down *in boat space*, intersect the deck plane — that's the plant target. Two refinements turn it from demo to believable: **pelvis adjust** — when the deck drops away on the downhill side, a leg can't reach, so lower the pelvis by the worst-case shortfall (then both knees bend, which is exactly what your own body does on a heeled deck) — and **ankle alignment**, rotating the foot so its sole matches the deck normal instead of staying parallel to the world horizon.

### Look-at is IK with a cone

Head tracking is one-bone IK: build the rotation that swings the head's forward axis toward the target, clamp the swing to a cone (~60° — past that, real necks recruit the spine or give up), and **rate-limit** it by slerping toward the goal at a few radians per second. Unclamped, instant look-at is the "owl-neck horror" every implementation produces first; the cone and the rate limit are what make it a person noticing a bird.

### The 1D blend, and layers over it

Locomotion: sample idle and walk into two poses, blend by `w = clamp(speed / walk_speed, 0, 1)` — ch71's crossfade machinery, driven by gameplay instead of a debug key. One new subtlety: scale the walk clip's playback rate by speed too, or feet slide at half-pace (the classic).

Layering: the wave shouldn't *replace* walking — it should override the upper body only. A **per-bone mask** (`f32` weight per joint: 1 from spine2 up through the arms, 0 below) makes the layer blend per joint: `pose[j] = mix(base[j], layer[j], mask[j] * layer_weight)` (slerp the rotations; ch71's double-cover rule still applies). Set the mask boundary joint (spine1) to ~0.5 so the seam breathes instead of creasing. That's a blend tree: base 1D blend, one masked layer, post-process IK. Real engines have graph editors for this; the runtime underneath is these same loops.

## Odin notes

You need joint indices by *name* now (`"LeftLeg"`, `"Head"`...). Build a `map[string]i32` from `skin.joints` node names at load, then resolve a small config struct once — Mixamo names differ from Quaternius names, so the lookup proc should warn-and-disable a feature rather than crash when a name misses (ch83's policy, early). The "rotation from vector a to b" helper IK leans on everywhere:

```odin
quat_from_to :: proc(a, b: glsl.vec3) -> linalg.Quaternionf32 {
    an, bn := glsl.normalize(a), glsl.normalize(b)
    c := glsl.cross(an, bn)
    d := glsl.dot(an, bn)
    if d < -0.9999 {    // opposite: rotate π around any perpendicular axis
        return linalg.quaternion_angle_axis(math.PI, perpendicular(an))
    }
    return linalg.quaternion_normalize(quaternion(x = c.x, y = c.y, z = c.z, w = 1 + d))
}
```

(That last construction is the standard half-angle shortcut — normalizing `(cross, 1 + dot)` gives the rotation from `a` to `b` without a single trig call.)

## Build

1. **Joint lookup + rig config.** `Rig :: struct { hips, leg_upper, leg_lower, foot: [2]i32, spine, neck, head: i32, mask: []f32 }` resolved by name at load. Print what resolved; warn on misses.

2. **`ik_two_bone`.** Inputs: global positions of hip/knee/foot from the posed skeleton, target, pole, the two bone lengths (measure once from bind pose). Solve the two angles from Concepts, build the hip rotation with `quat_from_to` (current hip→foot direction onto hip→target) composed with the pole-plane correction and the law-of-cosines tip; build the knee rotation likewise; convert both back to locals via parent inverses. ~40 lines. Test it long before the deck: a debug slider target in front of the standing sailor, ch71's exercise-1 skeleton lines on. Drag the target around until the leg tracks it with a sane knee.

3. **Foot plant.** Each frame after sampling: transform animated foot positions into boat space, ray down onto the deck plane, get targets and the deck normal. Run `ik_two_bone` per leg. Then ankle: rotate each foot joint so its bind-pose "sole" axis aligns with the deck normal (`quat_from_to` again).

4. **Pelvis adjust.** Before the leg IK: compute each leg's shortfall `needed = distance(hip, target) - (L1 + L2)`; lower the hips joint by `max(0, max(shortfall_l, shortfall_r)) + 1cm`, smoothed over ~0.15s so deck motion doesn't pump the pelvis. Re-walk the tree (or just recompute the leg globals) after moving it, *then* IK.

5. **Locomotion.** Give the sailor a patrol path along the deck (two points, ping-pong) or debug-drive him with keys. `w = clamp(speed / walk_speed, 0, 1)`, blend idle/walk, scale walk playback rate by `speed / walk_speed`. Watch the feet at w = 0.5 — if they slide, the rate scaling is missing.

6. **The wave layer.** Load a wave/greet clip. On keypress, ease `layer_weight` 0→1 over 0.25s, sample it into a second pose buffer, and fold it in through the mask:

   ```odin
   pose_apply_layer :: proc(base, layer: []Transform_TRS, mask: []f32, w: f32) {
       for i in 0 ..< len(base) {
           a := mask[i] * w
           if a <= 0 do continue
           base[i].t = math.lerp(base[i].t, layer[i].t, a)
           base[i].r = linalg.quaternion_slerp(base[i].r, layer[i].r, a)
           base[i].s = math.lerp(base[i].s, layer[i].s, a)
       }
   }
   ```

   Ease `w` back to 0 when the clip ends. He now waves while walking, and his stride doesn't hitch — masks working.

7. **Head look-at.** Target = the gull's masthead position (or the camera). Cone-clamp, rate-limit, applied to neck (30% of the swing) and head (70%) — splitting it over two joints is the cheap trick that reads as natural.

8. **The money shot.** Sail close-hauled in a stiff breeze so the deck heels hard, stand the sailor amidships, orbit the camera. Knees asymmetric, pelvis dipped, soles flush to the planks, eyes on the gull. Toggle IK off and on (panel switch). Off, he's a mannequin nailed to a tilted floor. On, he's crew.

## Checkpoint

The toggle in step 8 is the checkpoint: the difference should be embarrassing.

- Heel sweep ±15°: feet never float or sink; knees flex smoothly; no pop at full reach (clamps working).
- Walk → stop → walk: blend eases both ways, no T-pose flash, no foot slide at intermediate speeds.
- Wave while walking: legs identical with/without the wave (mask correct); spine seam doesn't crease (boundary weight working).
- Head tracks the gull through a full orbit, gives up gracefully behind him (cone), and never snaps (rate limit).
- All of it costs ~zero: one skeleton's IK is a dozen quaternion ops; the ch49 CPU timer won't even see it.

## Pitfalls

- **Knee bends backward.** Pole vector points the wrong way (or degenerates when target, hip, and pole go collinear as the boat rolls). Flip it; fall back to the pelvis-forward axis when near-collinear.
- **Leg snaps straight then pops at full reach.** Unclamped `d`. Clamp to `L1 + L2 − ε` and the pop becomes a soft press — also why the pelvis adjust runs *first*.
- **Foot is planted but spins with the walk cycle.** You solved leg rotations and kept the clip's ankle — step 3's ankle alignment is missing or applied before the leg IK overwrote it. IK order within the pass matters: pelvis → legs → ankles → head.
- **Everything works until the boat heels, then targets drift.** You mixed spaces — animated foot in *model* space intersected against deck in *boat* space. Do the whole IK pass in boat space; the sailor's placement node is on the boat anyway (ch18 pays again).
- **Wave layer makes the arms jitter.** You lerped rotation components instead of slerping, or forgot the `dot < 0` negate in the masked blend — ch71's double cover, third appearance, still undefeated.
- **He breathes wrong after IK (chest stops moving).** Your mask covers spine joints with weight 1.0 and the wave clip has a static torso. Author the mask from the shoulders out, not the whole upper body.

## Exercises

1. **Hands on the tiller:** two-bone IK for the arms (elbow pole points back-and-down) with targets on the tiller. He now steers when the rudder moves — your input system is suddenly *visible* in a character.
2. **Lean into the heel:** an additive spine rotation (ch71's exercise 4 machinery) proportional to deck heel, opposing it — sailors lean uphill. Compare with it off; the difference is "standing on" vs "belonging to."
3. **Stretch — foot locking:** detect each foot's plant phase from the walk clip (height below threshold), latch its boat-space target when planted, release on swing. This kills the last bit of skate during turns — and it's the doorstep of every full locomotion system; read about motion matching and know where the road continues.

## Commit

`git commit -m "ch71a: two-bone IK foot planting on the heeling deck, look-at, 1D locomotion blend, masked wave layer"`

[← back to Ch. 71: Bones of the Gull](ch71-bones-of-the-gull.md) · [onward to Ch. 72: Shoals and Flocks →](ch72-shoals-and-flocks.md)
