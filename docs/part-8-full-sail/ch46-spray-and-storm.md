# Chapter 46 — Spray & Storm

*Part 8 — Full Sail · Estimated time: 5h · learnopengl: [Particles (2D game series)](https://learnopengl.com/In-Practice/2D-Game/Particles) — our 3D treatment goes further; see also John Hable's [Why Are Particles Expensive?](http://filmicworlds.com/) and Wicked Engine's particle articles for production context*

**What you'll see when done:** white spray bursts from the bow every time it slaps a swell, drifts downwind, and fades into the sea — and a debug key summons rain.

## Where we are

Instancing gave you a thousand *things*; particles are a thousand *moments* — short-lived quads that together read as spray, rain, smoke. Technically this chapter is the instancing machinery from ch45 plus three new ideas: a CPU-simulated pool with spawn/age/kill, billboarding (quads that always face the camera), and soft particles — which finally cashes in the depth texture we deliberately attached to the HDR target in ch40.

## Concepts

### The pool: spawn, age, kill

A particle is data, not an object: position, velocity, age, lifetime, size, frame. A `Particle_Pool` owns a `[dynamic]Particle`, an emitter appends, the update integrates and ages, and the dead are removed. Removal order doesn't matter (we'll sort for rendering separately if needed), so use Odin's `unordered_remove` — O(1), swap-with-last:

```
pool: [A][B][C][D][E]   C dies
       unordered_remove(&pool.particles, 2)
pool: [A][B][E][D]      E swapped into C's slot — iterate index-carefully
```

Each frame after update, the pool writes per-instance data (position, size, fade, frame) into a dynamic VBO and the whole pool renders as **one instanced quad draw** — ch45's exact pattern with a 4-vertex quad mesh.

### Billboarding: reconstructing camera right/up

A particle quad must face the camera. You could build a per-particle rotation on the CPU; the elegant route uses a property of the view matrix: its upper-left 3×3 rows *are* the camera's right, up, and forward axes in world space. Pass camera right/up as uniforms (or read them in the shader) and inflate each instance's corner offsets along them:

```glsl
// a_corner is the quad vertex in {-0.5,0.5}^2; per-instance: i_pos, i_size
vec3 world = i_pos
           + u_cam_right * (a_corner.x * i_size)
           + u_cam_up    * (a_corner.y * i_size);
gl_Position = u_proj * u_view * vec4(world, 1.0);
```

On the CPU: `right = {view[0][0], view[1][0], view[2][0]}`, `up = {view[0][1], view[1][1], view[2][1]}` (columns indexed `view[col][row]` — these are the *rows* of the rotation, i.e. the camera basis). Rain wants a variant: cylindrical billboarding (up locked to world-up, stretched along velocity) so drops streak vertically.

### Atlas animation

One texture holds a grid of frames (a 4×4 spray puff sequence; free ones on [Kenney.nl](https://kenney.nl/assets) or render-your-own blobs). Per instance, `frame = age / lifetime * 16`, and the shader offsets UVs:

```glsl
vec2 frame_uv(float frame, vec2 uv) {     // 4x4 atlas
    float f = floor(frame);
    vec2 cell = vec2(mod(f, 4.0), floor(f / 4.0));
    return (cell + uv) / 4.0;
}
```

Blend between `floor(frame)` and `floor(frame)+1` by `fract(frame)` for smooth animation — two samples, one mix.

### Additive vs alpha blending

- **Alpha** (`gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA`): for things that *occlude* — smoke, spray, foam. Order-dependent; strictly you should sort back-to-front, but white-ish spray over white-ish foam hides ordering sins well, so we skip sorting until it visibly bites.
- **Additive** (`gl.SRC_ALPHA, gl.ONE`): for things that *emit* — sparks, magic, sun motes. Order-independent (addition commutes — no sorting ever!) but brightens stacked particles, which in HDR + bloom can be glorious or radioactive.

Spray is alpha; rain reads best as faint alpha streaks. Both passes: depth *test* on, depth *write* off (ch38 discipline — particles never occlude each other via the depth buffer).

### Soft particles: the depth payoff

Hard quads slicing through wave geometry is the #1 particle tell. Fix: in the particle fragment shader, compare this fragment's depth against the *scene* depth already rendered (the HDR FBO's depth texture), and fade alpha as they approach:

```glsl
float scene_z = linearize(texture(u_scene_depth, gl_FragCoord.xy / u_screen_size).r);
float frag_z  = linearize(gl_FragCoord.z);
float fade    = clamp((scene_z - frag_z) / u_soft_distance, 0.0, 1.0);
color.a *= fade;
```

(`linearize(d) = 2nf / (f + n - (d*2-1)*(f-n))` — the standard inverse of the projection's depth mapping.) One catch: you can't sample a depth texture that's *attached and being depth-tested against* — that's a feedback loop, undefined behavior. The standard fix: blit depth to a copy first (Build step 5).

### Emitters are game code

When does spray spawn? You already know, from ch32's buoyancy: each frame you sample `ocean_height_at` under the bow. When the bow's vertical velocity relative to the local wave surface goes sharply negative — a slap — burst 30–80 particles at the waterline with velocity ≈ boat velocity + outward fan + upward kick, then let gravity and a wind term (ch33's wind!) carry them. Rain is simpler: spawn in a disc above the camera, kill on `ocean_height_at` impact (or just on lifetime).

## Build

1. **Types and pool.**

   ```odin
   Particle :: struct {
       position: glsl.vec3,
       velocity: glsl.vec3,
       age:      f32,
       lifetime: f32,
       size:     f32,
   }

   Particle_Pool :: struct {
       particles: [dynamic]Particle,
       max:       int,
       quad:      Mesh,           // unit quad, 4 verts / 6 indices
       inst_vbo:  u32,            // per-instance: vec4(pos, size) + vec2(age01, pad)
       texture:   u32,
       additive:  bool,
   }
   ```

   Update (called from your fixed-timestep sim):

   ```odin
   particle_pool_update :: proc(p: ^Particle_Pool, dt: f32, wind: glsl.vec3) {
       for i := 0; i < len(p.particles); {
           pt := &p.particles[i]
           pt.age += dt
           if pt.age >= pt.lifetime {
               unordered_remove(&p.particles, i)
               continue                       // swapped element re-checked: don't i += 1
           }
           pt.velocity += (glsl.vec3{0, -9.8, 0} + wind * 0.3) * dt
           pt.position += pt.velocity * dt
           i += 1
       }
   }
   ```

   That `continue` without increment is *the* pool-iteration idiom — burn it in.

2. **Instance upload + draw.** Pack `[dynamic]` instance structs (`pos: vec3, size: f32, age01: f32, frame: f32`), `gl.BufferSubData` into `inst_vbo`, divisor 1, draw `gl.DrawElementsInstanced(gl.TRIANGLES, 6, gl.UNSIGNED_INT, nil, count)`. Render *after* all opaque geometry and the ocean, inside the HDR pass, with `gl.DepthMask(false)`.

3. **Billboard shader.** `particle.vert` with the corner math above; `particle.frag` samples the atlas via `frame_uv`, multiplies a tint, fades alpha in over the first 10% and out over the last 40% of life (`smoothstep` on `age01`).

4. **Bow spray emitter.** In the boat update, track `prev_bow_rel_h := bow.y - ocean_height_at(bow.xz)`; when it crosses below ~-0.15 with downward relative speed > threshold, burst:

   ```odin
   for _ in 0 ..< 50 {
       fan := glsl.normalize(glsl.vec3{
           rand.float32_range(-0.6, 0.6), rand.float32_range(0.8, 1.6),
           rand.float32_range(-0.6, 0.6)})
       append(&spray.particles, Particle{
           position = bow_waterline + jitter(0.3),
           velocity = boat.velocity * 0.7 + fan * rand.float32_range(1.0, 3.0),
           lifetime = rand.float32_range(0.6, 1.4),
           size     = rand.float32_range(0.15, 0.5),
       })
   }
   ```

5. **Depth copy for soft particles.** After opaque + ocean rendering, before particles:

   ```odin
   gl.BindFramebuffer(gl.READ_FRAMEBUFFER, r.hdr.fbo)
   gl.BindFramebuffer(gl.DRAW_FRAMEBUFFER, r.depth_copy_fbo) // FBO wrapping depth_copy_tex
   gl.BlitFramebuffer(0, 0, w, h, 0, 0, w, h, gl.DEPTH_BUFFER_BIT, gl.NEAREST)
   gl.BindFramebuffer(gl.FRAMEBUFFER, r.hdr.fbo)
   ```

   Bind `depth_copy_tex` as `u_scene_depth` and add the fade. Set `u_soft_distance` ≈ 0.5 m. Watch the hard line where spray meets hull and water simply *dissolve*.

6. **Rain.** Second pool, cylindrical billboard variant (stretch quad along world-up × 6), spawn 200/frame in a 30 m disc 15 m above the camera while a debug key is held, lifetime till splash. Faint blue-gray, alpha 0.25. (Chapter 47's storm state will own this key.)

## Checkpoint

Sailing upwind into chop: every few seconds the bow digs in and throws a white burst that drifts aft with the wind and melts into the water with no hard edges. Holding R: rain streaks fall around the camera, slightly slanted by wind.

- Spray timing matches visible bow impacts, not a constant dribble.
- Orbit the camera during a burst: quads never edge-on (billboarding works).
- Particles intersect the hull/waves with soft dissolves, no razor cuts (soft particles).
- Particle count on screen (print `len(particles)`) returns to ~0 between bursts — no leaks.

## Pitfalls

- **Particles vanish the frame they spawn.** Pool iteration bug: after `unordered_remove` you also did `i += 1`, skipping the swapped-in particle — or you spawned during iteration and grew the array mid-loop (spawn into a scratch list, append after).
- **Quads always face world +Z.** You used the view matrix *columns* as right/up instead of rows (or transposed your indexing). `view[0][0], view[1][0], view[2][0]` is right — `glsl.mat4` indexes as `m[col][row]`.
- **Black squares around every particle.** Blending disabled, or the texture has no alpha (check channels), or you wrote `frag.a = 1.0` after all that careful fading.
- **GPU artifacts / flicker where particles overlap scene.** You sampled the depth texture while it was attached to the active FBO — the feedback loop. Use the blit copy.
- **Soft fade affects the whole particle equally, not just intersections.** You linearized one depth but not the other; compare both linear or both raw-with-care, never mixed.
- **Spray bursts are square-ish clusters.** Velocities from `rand.float32_range` per axis make a cube distribution; normalize the fan vector (as above) or sample a cone properly.

## Exercises

1. Sail-luffing dust/spume: when the sail luffs (ch33 knows), emit a few faint particles from its leech. Tiny touches like this sell simulation depth.
2. Whitecap spume: when a Gerstner crest's steepness exceeds a threshold near the camera, emit drifting foam motes from the crest line. (You can evaluate crest sharpness analytically from the same wave sum.)
3. Add a `max` cap with eviction: when full, `unordered_remove` the *oldest* (track an age max scan, or just evict random — compare visual difference under heavy rain).
4. **Stretch:** sort the spray pool back-to-front along the view axis before upload (`slice.sort_by` on view-space z) and A/B the difference during dense bursts. Then read about order-independent transparency and feel good about deferring it.

## Commit

`git commit -m "ch46: particle pools — bow spray and rain with soft particles"`

[← Ch. 45: A Thousand Things](ch45-a-thousand-things.md) · [Ch. 47: The Breath of Distance →](ch47-the-breath-of-distance.md)

> ⚓ **Optional side quest:** [Interlude 46a — Glass Without Sorting](ch46a-glass-without-sorting.md) — weighted-blended OIT so sail, wake, and spray layer correctly from any angle, no sorting ever.
