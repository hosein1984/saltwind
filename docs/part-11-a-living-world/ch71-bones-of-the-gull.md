# Chapter 71 — Bones of the Gull

*Part 11 — A Living World · Estimated time: 7–9h · learnopengl: [Skeletal Animation (guest)](https://learnopengl.com/Guest-Articles/2020/Skeletal-Animation)*

**What you'll see when done:** a gull on your masthead actually *flying* — wings beating from real keyframes, blending smoothly into a glide — loaded from a glTF file an artist rigged.

## Where we are

Your ch45 gulls flap by scaling wing vertices with a sine in the vertex shader — charming at fifty meters, cardboard at five. Real character animation means a **skeleton**: artists pose a hierarchy of bones in keyframes, and vertices follow the bones they're bound to. This chapter builds the whole pipeline — glTF skinned-mesh loading via `vendor:cgltf` (the sidebar from ch17 finally graduates), keyframe sampling, quaternion rotations done properly, GPU skinning — and it's the densest *data plumbing* chapter in the course. The reward: every rigged model on the internet becomes loadable. Saltwind gains an actor system.

## Concepts

### Skeleton, bind pose, and the inverse bind matrix

A skeleton is a tree of **joints** (bones), each with a transform relative to its parent. The mesh was modeled around the skeleton in one specific pose — the **bind pose** (wings out, the classic T-pose for humanoids). The skinning question is: *when joint J moves, where does a vertex bound to J go?*

A vertex's position is stored in **model space of the bind pose**. To follow a joint it must first be expressed relative to that joint — that's the **inverse bind matrix**, the inverse of the joint's bind-pose global transform — and then pushed back out by the joint's *current* global transform:

```
                    inverse_bind[j]           global[j] (animated)
  vertex (model) ────────────────→ joint-local ────────────────→ vertex (posed)

  final[j] = global[j] * inverse_bind[j]      ← "the bone matrix"
  global[j] = global[parent(j)] * local[j]    ← walk the tree
```

When the pose equals the bind pose, `global[j] * inverse_bind[j] = identity` and the mesh doesn't move — the sanity check you'll lean on all chapter. glTF hands you the inverse bind matrices precomputed; you never invert anything.

### Vertex skinning: four influences

A wing-shoulder vertex shouldn't follow one bone rigidly — it belongs ~70% to the wing, ~30% to the body, or it creases like paper. Each vertex carries up to **4 joint indices + 4 weights** (summing to 1), and the shader blends the four bone matrices:

```glsl
mat4 skin = a_weights.x * u_bones[a_joints.x]
          + a_weights.y * u_bones[a_joints.y]
          + a_weights.z * u_bones[a_joints.z]
          + a_weights.w * u_bones[a_joints.w];
vec4 world = u_model * skin * vec4(a_pos, 1.0);
```

Blending *matrices* linearly is mathematically scandalous (it shears under big rotation differences) and universally shipped — four influences keep the error invisible. Normals go through `mat3(skin)` (fine while bones don't scale non-uniformly).

### Quaternions, properly this time

Bone rotations interpolate constantly, and Euler angles interpolate *terribly*: gimbal lock, axis-order dependence, and paths that swing wide instead of rotating directly. The fix is the **unit quaternion**: four numbers `(x, y, z, w)` encoding an axis-angle rotation as

```
q = ( sin(θ/2)·axis , cos(θ/2) )         |q| = 1, always
      └── x,y,z ──┘    └ w ┘
```

What you need operationally: composition is quaternion multiplication; `q` and `-q` are the *same rotation* (double cover — this fact will bite you in interpolation, see below); and **slerp** (spherical lerp) interpolates between two quaternions along the shortest great-circle arc at constant angular speed — exactly what "blend these two keyframed rotations" should mean. Cheaper cousin **nlerp** (lerp + normalize) is fine for close keyframes.

Odin has quaternions in the language: `quaternion128` is the f32 one (`linalg.Quaternionf32` is its alias), with `.x .y .z .w` fields. Everything you need is in `core:math/linalg` — verified names: `quaternion_slerp`, `quaternion_nlerp`, `quaternion_angle_axis`, `quaternion_normalize`, `matrix4_from_quaternion`, and the workhorse `matrix4_from_trs(t, r, s)` which builds translate·rotate·scale in one call. `linalg.Matrix4f32` and `glsl.mat4` are both `matrix[4, 4]f32` — the same type, freely mixable.

### Animation clips: channels and keyframe sampling

A glTF animation is a set of **channels**, each targeting one node's translation, rotation, *or* scale, each owning a **sampler**: an array of keyframe times (`input`) and matching values (`output`). Sampling at time `t`:

1. Wrap `t` into the clip (`math.mod(t, duration)`).
2. Find keyframes `k, k+1` bracketing `t` (linear scan is fine at gull scale; binary search when you load a 200-key Mixamo clip).
3. `alpha = (t - time[k]) / (time[k+1] - time[k])`.
4. **Lerp** translations and scales; **slerp** rotations — and if `dot(q_a, q_b) < 0`, negate one first (double cover!) or the bone takes the 350° scenic route. (`linalg.quaternion_slerp` handles this internally — verified in the source — but your hand-rolled nlerp won't unless you do it.)

Channels write into a **pose** (per-joint TRS); joints without channels keep their bind-pose locals. Then the tree walk from Concepts #1 turns pose → bone matrices.

### Blending two clips

Flap and glide shouldn't cut — they should crossfade. Sample *both* clips into two poses, then per joint: lerp T and S, slerp R, by blend weight `w`. Drive `w` toward 0/1 over ~0.25 s when the state machine (ch72 will own one) switches. That's full animation blending — two pose buffers and one loop.

## Odin notes

`vendor:cgltf` is a thin binding to the C single-header library, so it speaks `cstring`, multi-pointers, and C-style call pairs. The load dance (names verified at [pkg.odin-lang.org/vendor/cgltf](https://pkg.odin-lang.org/vendor/cgltf/)):

```odin
import "vendor:cgltf"

options: cgltf.options                                  // zero-init = auto-detect glTF/GLB
data, res := cgltf.parse_file(options, "assets/models/gull.glb")
if res != .success { return {}, false }
defer cgltf.free(data)
if cgltf.load_buffers(options, data, "assets/models/gull.glb") != .success { return {}, false }
```

`parse_file` reads the JSON skeleton of the file; `load_buffers` pulls the binary payloads (it needs the path again to find external `.bin` files). The binding converts C pointer+count pairs into Odin slices — `data.meshes`, `data.skins`, `data.animations`, `data.nodes` are real `[]T` you can `for` over. **Accessors** are the typed windows into raw buffers; never touch buffer bytes directly — use the helpers, which decode component types, strides, and sparse storage for you:

- `cgltf.accessor_unpack_floats(acc, raw_data(dst), uint(len(dst)))` — bulk-convert any accessor to floats. Size `dst` as `acc.count * cgltf.num_components(acc.type)`.
- `cgltf.accessor_read_uint(acc, i, &out[0], 4)` — one element as up-to-4 `u32`s (joint indices, which glTF stores as u8 or u16 — this normalizes them).
- `cgltf.accessor_unpack_indices(acc, raw_data(dst), 4, acc.count)` — index buffer straight into `[]u32`.

Quaternion construction in Odin uses named arguments: `quaternion(x = v[0], y = v[1], z = v[2], w = v[3])`. glTF stores rotations as `(x, y, z, w)` — same component order, scalar last.

## Build

1. **`Skinned_Vertex` and the skinned mesh path.** New vertex type and a `mesh_create_skinned` that sets up the two extra attributes — note joints use `VertexAttribIPointer` (integer, no normalization):

   ```odin
   Skinned_Vertex :: struct {
       position: glsl.vec3,
       normal:   glsl.vec3,
       uv:       glsl.vec2,
       joints:   [4]u16,
       weights:  glsl.vec4,
   }
   // attribute 3: gl.VertexAttribIPointer(3, 4, gl.UNSIGNED_SHORT, size_of(Skinned_Vertex), offset_of(Skinned_Vertex, joints))
   // attribute 4: regular VertexAttribPointer, 4 floats
   ```

2. **`src/model_gltf.odin`: geometry.** Take the first mesh's first primitive; loop `prim.attributes`, switch on `attr.type` (`.position`, `.normal`, `.texcoord`, `.joints`, `.weights` — an enum, no string comparisons), unpack each into the vertex array. Joints via `accessor_read_uint` per vertex; everything else via `accessor_unpack_floats`. Indices via `accessor_unpack_indices`. Print the summary line like ch17 did — loader hygiene never retires.

3. **Skeleton extraction.** From `data.skins[0]`:

   ```odin
   Skeleton :: struct {
       parents:      []i32,                       // -1 = root
       inverse_bind: []glsl.mat4,
       bind_local:   []Transform_TRS,             // {t: vec3, r: Quaternionf32, s: vec3}
   }
   ```

   `skin.joints` is `[]^cgltf.node`; build a `map[^cgltf.node]i32` from node pointer → joint index, then fill `parents` by looking up each joint's `node.parent` (not in the map → root). Inverse bind matrices: one `accessor_unpack_floats` of `16 * len(joints)` floats — glTF matrices are column-major, exactly like `glsl.mat4`, so they transmute straight in. Bind locals come from each node's `translation/rotation/scale` fields. **Assert parents come before children** in `skin.joints` (true for virtually every exporter); if it ever fails, reorder at load.

4. **Animation clips.** For each `data.animations[i]`, for each channel: map `channel.target_node` through your node map (skip channels targeting non-joints), copy `channel.sampler.input` (times) and `.output` (values) via `accessor_unpack_floats` into your own `Animation_Clip` arrays, tag with `channel.target_path` (`.translation`, `.rotation`, `.scale`). Duration = max input time. We support `.linear` interpolation and treat `.step`/`.cubic_spline` as linear for now — log a warning, don't crash.

5. **Sampling and the tree walk.** `animation_sample(clip, t, pose)` fills per-joint TRS (start from `bind_local`, overwrite channeled joints), then:

   ```odin
   skeleton_pose_matrices :: proc(sk: ^Skeleton, pose: []Transform_TRS, out: []glsl.mat4) {
       for i in 0 ..< len(pose) {
           local := linalg.matrix4_from_trs(pose[i].t, pose[i].r, pose[i].s)
           out[i] = local if sk.parents[i] < 0 else out[sk.parents[i]] * local
       }
       for i in 0 ..< len(out) { out[i] = out[i] * sk.inverse_bind[i] }
   }
   ```

   The in-order walk works *because* parents precede children — that's what step 3's assert bought.

6. **The skinning shader** (`skinned.vert`, GLSL 430): the 4-matrix blend from Concepts, then your standard PBR fragment shader unchanged. Upload bones with one call: `gl.UniformMatrix4fv(loc, i32(bone_count), false, &bones[0][0, 0])` — a `[]glsl.mat4` is contiguous, the array uniform `uniform mat4 u_bones[64];` eats it whole. *Sidebar:* at one gull, plain uniforms are perfect; when ch72 wants thirty skinned birds, a UBO (`layout(std140) uniform Bones {...}`) shared via `glBindBufferBase` updates once and serves every draw — file that thought.

7. **Get a gull and fly it.** [Quaternius](https://quaternius.com) has CC0 rigged, animated low-poly birds (and fish — buy one stone, feed ch72); [Kenney](https://kenney.nl) has rigged characters; for a sailor idle on deck, export any Mixamo animation from Blender as glTF (import FBX → export .glb, "the Mixamo-to-glTF route"). Load the flap clip, perch the gull on the masthead node (ch18), `t += dt` in the fixed step, sample, upload, draw. Then load the glide clip and bind a debug key to crossfade — watch the wings ease from beating to locked-out soaring.

## Checkpoint

A gull on the mast beating its wings from artist keyframes, smoothly blending to a glide on keypress; optionally a sailor idling on deck, breathing.

- Sample the clip at `t = 0` with no animation applied: mesh exactly matches the file viewed in any glTF viewer (bind-pose identity check).
- Wing tips travel smooth arcs — no 350°-flip glitch at any point in the loop (double cover handled).
- Crossfade is a fade, not a pop, and mid-blend the pose is plausible (slerp, not component lerp on rotations).
- Loader survives a second model (the sailor) without code changes — only asset paths.

## Pitfalls

- **Mesh renders as a crumpled ball.** Bone matrices missing the `inverse_bind` multiply — you're applying global pose transforms to model-space vertices. Re-read Concepts #1; run the bind-pose identity check.
- **Mesh fine, but tearing at joints.** Joints attribute uploaded with `VertexAttribPointer` instead of `VertexAttribIPointer` — the indices got normalized to ~0 floats and every vertex skins to bone 0. The classic.
- **Animation correct in slow motion, wrong at speed.** You sampled with render `dt` accumulation in two places, or wrapped time with `int` math. One clock: `t = math.mod(f32(sim_time), clip.duration)`.
- **A bone rotates the long way around once per loop.** Hand-rolled interpolation without the `dot < 0` negate. Use `linalg.quaternion_slerp`, which handles it.
- **Everything double-transforms (gull orbits the mast twice over).** The gull node's model matrix *and* a root-joint channel both contain the placement. Convention: the entity transform places the actor; animation moves bones relative to it. Strip root motion or don't author it.
- **cgltf returns `.success` but accessors read zeros.** You skipped `load_buffers` — `parse_file` alone leaves buffer data unloaded. The pair is mandatory.

## Exercises

1. Pose debug view: draw a line (your ch53 debug-draw) from each joint's global position to its parent's. Watching the skeleton flap inside the mesh is the fastest way to localize every future skinning bug.
2. Playback rate per instance: a `rate` multiplier and per-gull phase offset — your future flock must not flap in unison (ch45 taught the same lesson with sines).
3. Animation events: detect the downbeat (wing-root joint's local rotation crossing a threshold) and emit a tiny ch46 feather-dust puff or a ch36 wing sound. Data-driven later; hardcode the threshold today.
4. **Stretch:** additive blending — sample a "look around" clip as a *delta* from bind pose and add it on top of the idle (compose rotations: `q_add * q_base`). This is how the sailor's head tracks your boat while his body keeps idling.

## Commit

`git commit -m "ch71: glTF skeletal animation — cgltf loader, quaternion sampling, GPU skinning"`

[← Ch. 70: Canvas and Wind](ch70-canvas-and-wind.md) · [Ch. 72: Shoals and Flocks →](ch72-shoals-and-flocks.md)

> ⚓ **Optional side quest:** [Interlude 71a — Feet on the Deck](ch71a-feet-on-the-deck.md) — two-bone IK and blend layers: a sailor whose feet stay planted on the heeling deck while he waves and watches the gull.
