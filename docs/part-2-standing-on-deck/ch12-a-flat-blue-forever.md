# Chapter 12 — A Flat Blue Forever

*Part 2 — Standing on Deck · Estimated time: 3h · learnopengl: no direct equivalent — this is engine/game material*

**What you'll see when done:** an ocean without edges — shimmering, drifting blue from your feet to a hazy horizon in every direction, no matter how far or fast you fly.

## Where we are

The placeholder grid from Chapter 11 is an 800-unit tabletop: fly far enough and you fall off the edge of the world. This chapter builds the sea, take one — a dense grid, a water shader with moving color, distance fade into the horizon, and the camera-following tile trick that makes the ocean *endless*. No real waves yet: vertices stay at y=0 until Gerstner waves displace them in Chapter 28. What we build here is the canvas Gerstner will paint on — and the chapter where Saltwind first feels like open water.

## Concepts

### Why a dense grid for flat water?

A flat blue plane needs 2 triangles, and ours will spend 131,072. The investment is entirely for later: Chapter 28 animates *vertices* in the vertex shader, and wave detail can't exceed vertex density. We pay the geometry bill now (it's cheap — Chapter 11's stretch exercise proved your GPU shrugs at it), establish the structures, and Chapter 28 becomes "edit the vertex shader" instead of "rebuild the sea." 256×256 cells over 1000×1000 units ≈ one vertex every 3.9 m: enough for ocean swell, and a tunable constant when you disagree.

### Faking water with two layers of moving tint

Real water shading (fresnel, reflection, refraction — Chapters 29–30) needs machinery we don't have. But "obviously water, pleasantly alive" needs only this old trick: combine **two** scrolling sinusoidal patterns at different scales and directions, and use the sum to blend between a deep color and a crest color:

```
 layer 1: coarse pattern, drifting NE  ~~~~~ + ~~~~~  →  interference
 layer 2: fine pattern, drifting SW    ~~~~          patterns that never
                                                     visibly repeat
```

One layer reads as a conveyor belt; two layers beating against each other read as *water*. (The same superposition idea, applied to actual displacement, literally *is* the sum-of-sines ocean of Chapter 28 — today's shader is its color-only rehearsal.)

The pattern coordinates come from **world position**, not mesh uvs — `v_world_pos.xz`, available because the vertex shader multiplies by `u_model` anyway. This matters for the next trick:

### The endless ocean: a camera-following tile

A 1000-unit sea still has edges. Option A — make it 100,000 units: kills depth precision *and* float precision (see below). Option B — the trick every open-water game uses: **keep the sea centered on the camera**. The mesh never grows; it just goes wherever you go, and since the *color pattern* is derived from world position, the water "scrolls through" the relocated mesh seamlessly — like a treadmill belt whose texture is painted on the gym floor.

One subtlety: translate the tile *continuously* with the camera and the horizon is fine, but in Chapter 28 — when vertices have wave shapes — a smoothly sliding grid means vertices sample the wave field at slightly different spots each frame: visible swimming and shimmer at grazing angles. The fix costs one `floor`: **snap the tile's center to whole grid-cell increments**. The vertex *lattice* then always occupies the exact same world positions; moving the camera just swaps which patch of lattice you're standing over. Build the habit now while it's free, so the Gerstner chapter inherits it.

```
 tile size 1000, 256 cells → cell = 3.90625
 camera at x = 137.2  →  snapped center x = floor(137.2 / 3.90625) * 3.90625 = 135.16
 camera moves +1.0    →  same center (no vertex moved)
 camera moves +3.0    →  center jumps one whole cell (every vertex lands exactly
                          where another vertex used to be → visually nothing happens)
```

### Precision: the first warning

This chapter is your first brush with the deep problem of big worlds: `f32` has ~7 significant digits. At a position of 100,000 units, adjacent representable floats are ~0.0078 apart — vertex positions quantize, animation stutters, and at 1,000,000 everything visibly jitters. The camera-following tile is one instance of the general medicine: **keep coordinates that reach the GPU small and camera-relative**, even when the *logical* world is huge. Saltwind's archipelago will span a few thousand units — safely inside f32 — but when you sail past the map edge in Chapter 37 and the world keeps going, it's because of patterns established here. (File the term "camera-relative rendering" away; serious engines do *everything* this way.)

### Distance fade: dissolving the edge

The tile still ends 500 units out. Hide the edge by fading the water color into the sky/horizon color as distance from the camera grows — atmospheric perspective, crudely but effectively:

```glsl
float dist = length(v_world_pos.xz - u_camera_pos.xz);
float fade = smoothstep(280.0, 470.0, dist);   // 0 near … 1 by the tile edge
vec3 color = mix(water_color, u_horizon_color, fade);
```

`smoothstep` (clamped, eased 0→1 ramp) starts the fade well inside the tile and completes it *before* the geometric edge, which therefore is never seen. For the illusion to hold, `u_horizon_color` must match what the sky shows at the horizon — with our clear-color sky, that's simply the clear color. One color, two uniforms, total agreement: the seam vanishes.

## Odin notes

Nothing new — this chapter *spends* the toolkit: `mesh_grid` (ch11), `Shader` + hot-reload (ch4), `shader_set_vec3` (finally earning its keep), `sim_time` (ch10), `math.floor`. If hot-reload is wired, do the entire shader-tuning half of this chapter with Saltwind running.

## Build

1. **Create `src/sea.odin`:**

   ```odin
   package saltwind

   import "core:math"
   import "core:math/linalg/glsl"

   SEA_SIZE :: 1000.0
   SEA_CELLS :: 256

   Sea :: struct {
   	mesh:   Mesh,
   	shader: Shader,
   }

   sea_create :: proc() -> (sea: Sea, ok: bool) {
   	sea.mesh = mesh_grid(SEA_CELLS, SEA_SIZE)
   	sea.shader, ok = shader_load("assets/shaders/sea.vert", "assets/shaders/sea.frag")
   	return
   }

   sea_model_matrix :: proc(camera_pos: glsl.vec3) -> glsl.mat4 {
   	cell :: f32(SEA_SIZE) / f32(SEA_CELLS)
   	return glsl.mat4Translate({
   		math.floor(camera_pos.x / cell) * cell,
   		0,
   		math.floor(camera_pos.z / cell) * cell,
   	})
   }
   ```

   (Plus `sea_destroy`. Note `cell` is a constant — Odin computes it at compile time.)

2. **`assets/shaders/sea.vert`** — standard MVP, but exporting world position:

   ```glsl
   #version 330 core
   layout (location = 0) in vec3 a_position;
   layout (location = 1) in vec3 a_normal;
   layout (location = 2) in vec2 a_uv;

   out vec3 v_world_pos;

   uniform mat4 u_model;
   uniform mat4 u_view;
   uniform mat4 u_projection;

   void main() {
   	vec4 world = u_model * vec4(a_position, 1.0);
   	v_world_pos = world.xyz;
   	gl_Position = u_projection * u_view * world;
   }
   ```

3. **`assets/shaders/sea.frag`** — the two-layer tint and the fade:

   ```glsl
   #version 330 core
   in vec3 v_world_pos;
   out vec4 frag_color;

   uniform float u_time;
   uniform vec3  u_camera_pos;
   uniform vec3  u_horizon_color;

   void main() {
   	vec2 p1 = v_world_pos.xz * 0.16 + u_time * vec2( 0.13,  0.09); // coarse, drifting NE
   	vec2 p2 = v_world_pos.xz * 0.51 + u_time * vec2(-0.07, -0.11); // fine, drifting SW
   	float w1 = sin(p1.x) * sin(p1.y);
   	float w2 = sin(p2.x + 1.7) * sin(p2.y + 4.2);
   	float shimmer = 0.5 + 0.5 * (0.65 * w1 + 0.35 * w2);

   	vec3 deep  = vec3(0.02, 0.08, 0.15);
   	vec3 crest = vec3(0.06, 0.22, 0.29);
   	vec3 water = mix(deep, crest, shimmer);

   	float dist = length(v_world_pos.xz - u_camera_pos.xz);
   	float fade = smoothstep(280.0, 470.0, dist);
   	frag_color = vec4(mix(water, u_horizon_color, fade), 1.0);
   }
   ```

4. **Wire it into `main`.** Replace the placeholder grid + `flat_shader` sea draw with:

   ```odin
   	sea, sea_ok := sea_create()
   	if !sea_ok do return
   ```

   and in the render section:

   ```odin
   		gl.UseProgram(sea.shader.id)
   		shader_set_mat4(sea.shader, "u_model", sea_model_matrix(camera.position))
   		shader_set_mat4(sea.shader, "u_view", view)
   		shader_set_mat4(sea.shader, "u_projection", projection)
   		shader_set_f32(sea.shader, "u_time", f32(sim_time))
   		shader_set_vec3(sea.shader, "u_camera_pos", camera.position)
   		shader_set_vec3(sea.shader, "u_horizon_color", HORIZON_COLOR)
   		mesh_draw(sea.mesh)
   ```

   Define `HORIZON_COLOR :: glsl.vec3{0.45, 0.62, 0.74}` *once* and use it for **both** `gl.ClearColor` and the uniform — the agreement is the illusion.

5. **Fly the world's edge off.** Sprint (ch9 exercise) in one direction for a minute. The sea simply… continues. Press P: shimmer freezes (it reads `sim_time`), the proof that water motion is world state, not wallpaper.

6. **Tune by hot-reload.** With Saltwind running, edit `sea.frag` live: pattern scales (0.16/0.51), drift vectors, `deep`/`crest`, fade distances. Twenty minutes here is the difference between "tech demo" and "place." This tuning loop *is* the course's promised payoff for the Chapter 4 stretch exercise.

## Checkpoint

Open water to the horizon in every direction, alive with slow interference shimmer; crates and buoy floating on it; no visible edge, seam, or repeat anywhere.

- Fly hard in any direction for 60+ seconds: ocean never ends, horizon stays put, no pop or hitch as the tile snaps cell to cell.
- Stop and stare at one patch: the two drift layers visibly slide *through* each other — and (hold position) the pattern doesn't repeat on any obvious cycle.
- Hold TAB at a shallow angle: the dense lattice is *stationary in world space* while you drift over it — the snap trick, visible.
- Look straight down, then at the horizon: deep water below, hazing smoothly to exactly the sky color far away; you cannot point at where sea ends and sky begins.

## Pitfalls

- **Visible hard edge or a "wall" at distance?** Fade completes after the tile edge — `smoothstep`'s second number must be comfortably less than `SEA_SIZE/2` (470 < 500). Or your `u_horizon_color` ≠ clear color, leaving a tinted seam line.
- **Water pattern slides along WITH you when you move?** You derived the pattern from mesh `a_uv` instead of `v_world_pos.xz` — the treadmill's paint is on the belt, not the floor. Re-read the Concepts trick.
- **Stutter or shimmer in the pattern each time the tile snaps?** You snapped to *something other than whole cells* (e.g. `math.round(camera_pos.x)` — snapping to 1.0 increments while a cell is 3.90625). The snap quantum must be exactly `SEA_SIZE / SEA_CELLS`.
- **Sea renders black?** `u_camera_pos`/`u_horizon_color` never set (location −1 is silent; `length(huge garbage)` saturates the fade) — or you forgot `u_time` and `sin(NaN)`-ish weirdness. Set every uniform every frame; it's cheap.
- **Crates now z-fight with the sea?** They bob to y≈0 with sea exactly at y=0 — coplanar contact moments. Float them a touch higher (bob between 0.15 and 0.55) until buoyancy does it properly in Chapter 32.

## Exercises

1. Add a third, very coarse layer (`* 0.03`, barely drifting) modulating the *blend of the other two* — large slow "weather patches" roaming the sea surface. Three sines, ocean moods.
2. Make fade distances uniforms (`u_fade_near`, `u_fade_far`) and play: fog rolling in (pull both close) versus crystal day (push far). You've prototyped Chapter 47's weather state with two floats.
3. Tint shallow vs. deep by camera height: blend the water toward a greener tone when `u_camera_pos.y` is low (skimming) vs. bluer high up. Subtle, but it teaches view-dependent color — fresnel's opening act.
4. **Stretch:** The full belt-and-floor proof: log `sea_model_matrix`'s translation each time it changes, sprint diagonally, and verify x and z each move in exact 3.90625 steps while on-screen water shows zero discontinuity. Then break it on purpose (snap to `cell * 0.5`) and *see* the shimmer the snap prevents. Understanding-by-sabotage — the best kind.

## Commit

```
git commit -m "ch12: endless sea — 256x256 grid, scrolling tint, camera-following tile"
```

Prev: [Chapter 11 — Meshes that Matter](ch11-meshes-that-matter.md) · Next: [Chapter 13 — MILESTONE: First Voyage](ch13-milestone-first-voyage.md)
