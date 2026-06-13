# Chapter 18 — The Family Tree

*Part 3 — Let There Be Light · Estimated time: 2h · learnopengl: no direct equivalent — this is engine/game material*

**What you'll see when done:** a boat assembled from parts — hull, mast, lantern — that rotates, heels, and drifts as one object, because the parts know who their parent is.

## Where we are

Chapter 17 gave you a hull and a buoy, each drawn with a hand-built model matrix. Now try to put a mast *on* the hull and rotate the boat: suddenly you're manually recomputing the mast's position from the hull's rotation every frame, and it's wrong twice before it's right. The fix is one of the oldest ideas in 3D engines: the transform hierarchy. We build it now, small and concrete, because Chapter 32 will float the entire boat on waves by touching exactly *one* root transform.

## Concepts

### Local space is where you want to think

The mast's position is "2 units up, 1 unit forward of the hull's center" — *forever*, no matter where the boat sails or how it heels. That statement is the mast's **local transform**, expressed relative to its **parent**, the hull. The hull's transform is relative to *its* parent — the world (or later, a "boat root" that buoyancy drives).

```
boat_root                      world = M_root
└── hull                       world = M_root · M_hull
    ├── mast                   world = M_root · M_hull · M_mast
    │   └── lantern            world = M_root · M_hull · M_mast · M_lantern
    └── tiller                 world = M_root · M_hull · M_tiller
```

A node's **world matrix** is its parent's world matrix times its own local matrix. That's the entire theory. Read the chain left to right as "first apply my local placement, then carry me along with everything my ancestors do."

### TRS: composing one local matrix

A transform decomposes into translate, rotate, scale. The conventional composition is:

```
M_local = T · R · S
```

Order matters and trips everyone at least once. Matrices apply right-to-left to a vertex: scale first (while the model is at the origin, so scaling doesn't also move it), then rotate (still about its own origin), then translate into place. Write `S · R · T` instead and you'll scale and rotate *around the parent's origin* — masts orbiting hulls like moons.

For rotation we start with **Euler angles** — a `vec3` of radians around X, Y, Z — because they're readable and you can type them. Their genuine problems (gimbal lock, interpolation artifacts) don't bite at our usage level; when they do (smooth boat physics, Chapter 32–33), know that `core:math/linalg` has full quaternion support (`linalg.quaternion_from_euler_angles`, `mat4` conversion) waiting. Storing rotation as "whatever is convenient now, upgradeable later" is exactly why we wrap it in a struct.

### Evaluation order

To compute world matrices, every parent must be evaluated before its children. The cheapest correct scheme — and the one we use — is to store nodes in a flat array where **a parent's index is always less than its children's** (true automatically if you only ever append children after their parents), then evaluate in one forward pass. No recursion, no tree pointers, cache-friendly, trivially serializable. This flat-array-with-parent-index layout is quietly one of the most load-bearing patterns in game engines.

### Normals, again

World matrices feed the same draw path as before — including Chapter 16's normal matrix. Note that scale *inherits*: a scaled hull scales the mast too. That's usually what you want (scale the whole boat), but it means non-uniform scale anywhere in the chain makes the inverse-transpose genuinely necessary down the whole subtree. You already pass it per draw; nothing new to do — just understand why it matters more now.

## Build

1. **Define `Transform` and its matrix** in `src/transform.odin`:

   ```odin
   Transform :: struct {
       position: glsl.vec3,
       rotation: glsl.vec3,   // euler radians: x=pitch, y=yaw, z=roll
       scale:    glsl.vec3,
   }

   TRANSFORM_IDENTITY :: Transform{ scale = {1, 1, 1} }

   transform_to_matrix :: proc(t: Transform) -> glsl.mat4 {
       T := glsl.mat4Translate(t.position)
       R := glsl.mat4Rotate({0, 1, 0}, t.rotation.y) *
            glsl.mat4Rotate({1, 0, 0}, t.rotation.x) *
            glsl.mat4Rotate({0, 0, 1}, t.rotation.z)
       S := glsl.mat4Scale(t.scale)
       return T * R * S
   }
   ```

   (Y-then-X-then-Z is a sane order for vehicles: heading, then pitch, then roll. Any fixed order is fine as long as you never change it.)

2. **Define the node and the scene array** — parent by index, `-1` for root:

   ```odin
   Scene_Node :: struct {
       name:      string,
       transform: Transform,
       parent:    int,         // index into the nodes array; -1 = world
       mesh:      ^Mesh,       // nil = pure grouping node
       material:  Material,
       world:     glsl.mat4,   // computed each frame
   }
   ```

   Keep them in `nodes: [dynamic]Scene_Node` on your `Game` struct, with a helper `scene_add(game, node, parent_index) -> int` that appends and returns the new index (enforcing parent < child by construction).

3. **Write the one-pass world update.** Call it each frame before drawing:

   ```odin
   scene_update_world :: proc(nodes: []Scene_Node) {
       for &node in nodes {
           local := transform_to_matrix(node.transform)
           node.world = local if node.parent < 0 else nodes[node.parent].world * local
       }
   }
   ```

   Five lines. This is the whole engine feature.

4. **Write `scene_draw`.** Loop nodes, skip `mesh == nil`, apply material, compute the normal matrix from `node.world`, upload `world` as the `model` uniform, draw. Your existing per-object draw code collapses into this loop — delete the old hand-rolled model matrices as you go.

5. **Assemble the boat** at startup, from Chapter 17's parts (Kenney's kit has mast pieces; a stretched cube works too):

   ```odin
   root := scene_add(game, { name = "boat",
       transform = { position = {0, 0, 0}, scale = {1,1,1} } }, -1)
   hull := scene_add(game, { name = "hull", mesh = &game.hull_mesh,
       material = MATERIAL_WOOD, transform = TRANSFORM_IDENTITY }, root)
   mast := scene_add(game, { name = "mast", mesh = &game.mast_mesh,
       material = MATERIAL_WOOD,
       transform = { position = {0, 0.4, 0.3}, scale = {1,1,1} } }, hull)
   lantern := scene_add(game, { name = "lantern", mesh = &game.lantern_mesh,
       transform = { position = {0, 1.8, 0}, scale = {0.3, 0.3, 0.3} } }, mast)
   ```

   Note the empty root above the hull: buoyancy (ch32) will drive *that*, leaving the hull free for cosmetic offsets.

6. **Make the lantern light follow the node.** A node's world position is the translation column of its world matrix:

   ```odin
   lantern_world_pos := game.nodes[lantern].world[3].xyz
   ```

   Feed that into the `Point_Light` position each frame. Hierarchy and lighting now compose for free.

7. **Prove the hierarchy** with a temporary test: each frame, `game.nodes[root].transform.rotation.y += 0.3 * dt` and `rotation.z = 0.1 * math.sin(t)`. The whole boat should swing and heel as a rigid unit, lantern light gliding along with it.

## Checkpoint

A boat with a mast and a glowing lantern at the masthead, slowly turning in place and heeling gently — all driven by two numbers on one root node.

- Pause the root rotation, rotate only the *mast* node: mast and lantern move, hull doesn't.
- The lantern's light pool on the deck moves with the boat's rotation.
- `scene_update_world` runs before `scene_draw` (reorder them and watch everything lag a frame — then put it back).

## Pitfalls

- **Children orbit the parent's origin instead of sitting on it.** Composition order is backwards (`S·R·T`, or `local * parent_world` instead of `parent_world * local`). The correct chain reads `parent.world * T * R * S`.
- **Mast floats off at a strange angle when the boat heels.** You composed Euler rotations in a different axis order in two places. One `transform_to_matrix`, used everywhere, no exceptions.
- **A child renders one frame behind its parent.** World matrices computed during drawing, child drawn before parent updated — keep update and draw as two separate full passes.
- **Everything at the origin in a clump.** Default-zero `scale`. Odin zero-initializes; a `{0,0,0}` scale collapses the matrix. Always start from `TRANSFORM_IDENTITY`.
- **Rotation suddenly jumps at certain angles.** You stored degrees somewhere and radians elsewhere. The struct is radians; convert at the edge with `math.to_radians_f32`.

## Exercises

1. Add a `scene_find(nodes, name) -> int` helper and use it instead of stashing raw indices.
2. Hang a second, smaller buoy node off the boat by a "rope" (just parent it at an offset astern) and watch it trail the rotation.
3. Add `transform_forward(t: Transform) -> glsl.vec3` (rotate `{0,0,-1}` by the rotation matrix) — you'll want it for sailing in Chapter 33.
4. **Stretch:** Swap `rotation` to a `linalg` quaternion internally while keeping Euler get/set procs at the API surface. Verify the boat test scene is pixel-identical.

## Commit

`git commit -m "ch18: transform hierarchy, boat assembled from nodes"`

← [Chapter 17 — Shapes from Elsewhere](ch17-shapes-from-elsewhere.md) · [Chapter 19 — Milestone: Sunlit Waters](ch19-milestone-sunlit-waters.md) →
