# Chapter 7 — The Mathematics of Motion

*Part 1 — First Light · Estimated time: 3h · learnopengl: [Transformations](https://learnopengl.com/Getting-started/Transformations)*

**What you'll see when done:** the crate quad orbiting and spinning under matrix control — geometry finally moved by math instead of by editing vertex arrays.

## Where we are

Everything so far was placed by typing NDC coordinates. That stops scaling immediately: Saltwind needs a crate *here*, rotated *so*, while the camera looks from *there* — and re-typing vertices per frame is obviously absurd. The answer is the linear algebra you learned once and half-remember. This chapter is the refresher, tuned for someone who knew it years ago, plus the Odin-specific mechanics of `core:math/linalg/glsl`. No new GL concepts — one new uniform type, `mat4`, and your `shader_set_mat4` stub finally runs.

## Concepts

### Vectors: arrows and points

A `vec3` is three numbers meaning either a *point* (position) or a *direction with length* (velocity, offset, normal). Addition chains offsets; scalar multiply scales length; `length(v)` is Pythagoras; `normalize(v)` keeps direction, sets length 1 (unit vectors are the currency of lighting and cameras).

Two products, and your geometric intuition for them is 80% of graphics math:

**Dot product** — *how aligned are two vectors?* For unit vectors, `dot(a, b) = cos(angle between)`:

```
  a·b = +1   same direction          a →   → b
  a·b =  0   perpendicular           a →   ↑ b
  a·b = −1   opposite                a →   ← b
```

Read every future lighting equation through this lens: Chapter 14's diffuse term is literally `dot(surface_normal, sun_direction)` — "how squarely does this surface face the sun?" Projections, visibility ("is this in front of me?"), and falloffs are all dots.

**Cross product** — *manufacture a perpendicular.* `cross(a, b)` is a vector perpendicular to both, right-hand rule, length = parallelogram area (zero when parallel — degeneracy you must respect). It's how you get a camera's "right" from its "forward" and "up" (Chapter 9), and surface normals from triangle edges (Chapter 22).

### Matrices: transforms as objects

A 4×4 matrix *is* a transformation — rotation, scale, translation, projection, or any composition of them — packaged as a value. Multiply a vector by a matrix: transformed vector. Multiply two matrices: a *new matrix doing both transforms*. That closure property is the whole reason graphics runs on matrices: an arbitrarily long chain of transforms collapses into one mat4, applied to thousands of vertices for one cost each.

**Homogeneous coordinates** — the reason it's 4×4 and not 3×3: a 3×3 matrix can rotate and scale but *cannot translate* (linear maps fix the origin). The fix: a fourth component, w. Points get w=1, and the matrix's fourth column — which multiplies w — adds translation. Directions get w=0 and are correctly immune to it (moving the world shouldn't change "north"). That's why the vertex shader says `vec4(a_position, 1.0)`. (w's second job, perspective division, is Chapter 8's punchline.)

**Composition order** — the one that bites everyone. With column vectors (OpenGL convention), the matrix nearest the vector applies *first*:

```
v' = T * R * S * v      reads RIGHT to LEFT:
                        scale → then rotate → then translate
```

T·R·S is the standard object order — scale in place, rotate in place, then move into the world. Reverse it and you get R·T: rotation applied *after* translation rotates the object around the *world origin*, not its own center — the classic "my object orbits instead of spins" bug. (Or, the orbit *is* what you want; see the build.)

**Column-major storage**: GL and `linalg/glsl` store matrices column-by-column in memory. Mostly invisible to you — except when uploading (see Odin notes) and when printing a matrix flat and wondering why it looks transposed.

### The library: `core:math/linalg/glsl`

Deliberately mirrors GLSL, so shader math and CPU math read identically:

| You want | You write |
|---|---|
| types | `glsl.vec2/vec3/vec4`, `glsl.mat4` |
| build transforms | `glsl.mat4Translate(v)`, `glsl.mat4Rotate(axis, radians)`, `glsl.mat4Scale(v)` |
| camera/projection (ch8/9) | `glsl.mat4LookAt(eye, centre, up)`, `glsl.mat4Perspective(fovy, aspect, near, far)` |
| vector ops | `glsl.dot(a, b)`, `glsl.cross(a, b)`, `glsl.normalize(v)`, `glsl.length(v)` |
| compose / apply | plain `*` — Odin has real matrix multiplication |

Angles are radians everywhere; `math.to_radians_f32(45)` converts (`core:math`).

## Odin notes

- Matrices and vectors are first-class in Odin: `m1 * m2` is matrix multiplication, `m * v` matrix-vector. No operator-overloading library, no `.mul()` chains — the math reads like the textbook.
- Component-wise vector arithmetic comes free from array programming: `a + b`, `v * 2.0`, `a * b` (component-wise — *not* a dot; use `glsl.dot`).
- **Uploading a mat4:** `gl.UniformMatrix4fv(loc, 1, false, &m[0, 0])` — count 1, **transpose `false`** because Odin's matrices are already column-major like GL wants, and `&m[0, 0]` is the address of the first element. Your `shader_set_mat4` from Chapter 4 already does exactly this. If you ever "fix" a broken transform by passing `true`, you've hidden a real bug upstream — find it instead.
- `glsl.vec3{0, 0, 1}` literals coerce nicely; `{0, 0, 1}` works wherever the type is known from context.

## Build

1. **A transform uniform in the vertex shader.** `basic.vert` becomes:

   ```glsl
   #version 330 core
   layout (location = 0) in vec3 a_position;
   layout (location = 1) in vec2 a_uv;

   out vec2 v_uv;

   uniform mat4 u_transform;

   void main() {
   	v_uv = a_uv;
   	gl_Position = u_transform * vec4(a_position, 1.0);
   }
   ```

2. **Build and upload a transform each frame.** In the render loop (import `core:math` and `core:math/linalg/glsl` in `main.odin` if not already):

   ```odin
   		t := f32(glfw.GetTime())

   		transform := glsl.mat4Rotate({0, 0, 1}, t)          // spin about screen-z
   		transform  = glsl.mat4Scale({0.6, 0.6, 0.6}) * transform

   		gl.UseProgram(shader.id)
   		shader_set_mat4(shader, "u_transform", transform)
   ```

   The crate spins in place, smaller. Note the build direction: we *left-multiplied* the scale, so reading right-to-left it's rotate-then-scale — for uniform scale the order is invisible, which is why step 3 exists.

3. **Feel composition order in your hands.** This is the point of the chapter — run all three, watch carefully:

   ```odin
   		// A: translate * rotate — spin in place, then move. Crate spins at upper-right.
   		ta := glsl.mat4Translate({0.5, 0.4, 0}) * glsl.mat4Rotate({0, 0, 1}, t)

   		// B: rotate * translate — move first, then rotate the *moved* crate
   		//    around the origin. The crate ORBITS the center.
   		tb := glsl.mat4Rotate({0, 0, 1}, t) * glsl.mat4Translate({0.5, 0.4, 0})

   		// C: orbit AND spin — compose three:
   		tc := glsl.mat4Rotate({0, 0, 1}, t) * glsl.mat4Translate({0.5, 0.4, 0}) * glsl.mat4Rotate({0, 0, 1}, -3 * t)
   	```

   Upload `ta`, run; then `tb`; then `tc`. Same ingredients, different order, completely different motion. When a hull, mast, and flag move together in Chapter 18, it's all this.

4. **Settle on the final look:** keep the crate spinning in place at a slight non-uniform scale, proving scale and rotation interact sanely:

   ```odin
   		transform := glsl.mat4Rotate({0, 0, 1}, t * 0.8) * glsl.mat4Scale({0.7, 0.7, 1.0})
   ```

5. **One non-obvious check** — aspect distortion: the window isn't square but NDC is, so the spinning square crate appears wider than tall, and visibly *changes shape* as it rotates through 45°. Don't fix it by hand. Notice it, name it, and know that the projection matrix kills it for good in Chapter 8.

## Checkpoint

The crate spins smoothly in place at ~0.13 revolutions/second, scaled to about 70% of its old size.

- Replay step 3's variant B: crate orbits the window center instead. You can predict A vs. B vs. C *before* running them — that's the skill this chapter exists to build.
- Set the rotation axis to `{0, 1, 0}` (y): the crate "spins" in 3D, collapsing to a sliver edge-on twice per revolution. You're seeing 3D rotation with no depth handling — Chapter 8 territory.
- Pass `true` as the transpose flag in `shader_set_mat4` temporarily: motion goes visibly insane. Restore `false`, permanently.

## Pitfalls

- **Crate vanished entirely?** A zero somewhere in `mat4Scale`, or you uploaded an uninitialized `glsl.mat4` (zero matrix — every vertex maps to the origin). Note the identity is `glsl.mat4(1)`, not `glsl.mat4{}`.
- **Spins around a corner / orbits when it should spin?** Composition order — re-read step 3. With column vectors, the rightmost matrix happens first.
- **Rotation speed climbs over minutes?** You're feeding accumulated `t` into something that expected a delta (`dt`), or rotating an already-rotated matrix each frame: `transform = rot * transform` compounds. Rebuild from identity every frame — matrices are cheap; drift is not.
- **Everything works but degrees/radians chaos?** `mat4Rotate` wants radians. `math.to_radians_f32` at every literal-angle call site, no exceptions — future chapters assume it.
- **`mat4 * vec3` won't compile?** Correct — dimensions must agree. Promote: `(m * glsl.vec4{p.x, p.y, p.z, 1}).xyz` when you need it on the CPU side.

## Exercises

1. Pulse the scale with time — `glsl.mat4Scale({s, s, 1})` where `s = 0.6 + 0.1 * math.sin(2 * t)` — composed *inside* the spin (right of the rotation). Bobbing, breathing cargo.
2. Two crates from one VAO: upload transform A, `DrawElements`; change the uniform to transform B, `DrawElements` again. Two instances, one mesh — the mental model for *every* repeated object in Saltwind (the "fleet" in Chapter 11 is exactly this in a loop).
3. On the CPU, rotate the +X axis by 90° about z — `(glsl.mat4Rotate({0,0,1}, math.to_radians_f32(90)) * glsl.vec4{1,0,0,0})` — and `fmt.println` it. Confirm it's ~(0,1,0). Now you know how to unit-test a transform without rendering anything.
4. **Stretch:** Write `transform_trs :: proc(translation: glsl.vec3, axis: glsl.vec3, radians: f32, scale: glsl.vec3) -> glsl.mat4` returning the canonical T·R·S product. Park it in a new `src/transform.odin` — Chapter 8 starts calling it `model` and never stops.

## Commit

```
git commit -m "ch07: transforms — linalg/glsl, composition, spinning crate"
```

Prev: [Chapter 6 — Pixels from Disk](ch06-pixels-from-disk.md) · Next: [Chapter 8 — Into the Third Dimension](ch08-into-the-third-dimension.md)
