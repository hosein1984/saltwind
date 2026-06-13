# Chapter 73 — The Green and the Gale

*Part 11 — A Living World · Estimated time: 4h · learnopengl: no direct equivalent — this is engine/game material*

**What you'll see when done:** a gust front sweeping visibly across an island — grass bowing in a traveling wave, palm crowns thrashing a half-second after their trunks lean — all from one wind, the same one filling your sail.

## Where we are

Ch45's exercise 1 gave vegetation a `sin(time + x)` shiver — vegetation-flavored noise, uncoupled from anything. But Saltwind has had *one true wind* since ch33: it fills the sail (now literally, ch70), drifts the clouds (ch69), and leans the gulls. Today the land joins the same system. The technical content is one well-designed GLSL function and some weighting craft; the payoff is the course's quietest "wow": you watch a gust arrive across the water, cross the beach, and climb the hill — and you *believe* the island is outdoors.

## Concepts

### One wind function to rule every shader

Scattered per-shader sway code drifts apart — palm and grass end up in different winds. Instead, define wind *once*, in an include (`assets/shaders/wind.glsl`, via your ch44 `#include` concat), as a function any vertex shader can call:

```glsl
// uniforms: u_wind_dir (vec2, normalized XZ), u_wind_strength, u_time, u_gust_tex
vec3 wind_at(vec3 world_pos) {
    vec2 dir = u_wind_dir;
    // two octaves of gust noise, scrolling WITH the wind:
    vec2 uv1 = (world_pos.xz - dir * u_time * 12.0) * 0.008;  // big slow fronts
    vec2 uv2 = (world_pos.xz - dir * u_time * 30.0) * 0.05;   // small fast flutter
    float gust = texture(u_gust_tex, uv1).r * 0.7
               + texture(u_gust_tex, uv2).r * 0.3;
    float strength = u_wind_strength * (0.55 + 0.9 * gust);
    return vec3(dir.x, 0.0, dir.y) * strength;
}
```

Two design decisions carry everything. First, **the noise scrolls along the wind direction** — so a bright patch in the gust texture is a *front* that physically travels downwind across the island at gust speed. Stand on a hill and watch it come. Second, **two octaves at different speeds and scales**: the slow large one is the gust envelope (the thing you see traveling), the fast small one is local flutter (the thing that makes leaves busy). The gust texture is any tiling grayscale fBm — generate a 256² one in compute at startup next to ch69's weather texture, or reuse a channel of it. Uniforms come straight from `game.wind` and `game.weather.current` — the same numbers the sail cloth reads. One wind.

### Sway weighting: where a plant is allowed to move

A vertex's response to wind must vary across the plant — roots don't move, tips do, leaves do more. Two ways to encode the weight:

- **Derive from height:** `w = pow(local_pos.y / plant_height, k)` — free, works for grass and simple palms; `k ≈ 2` keeps bases planted (a linear ramp makes plants pivot rigidly at the root, the #1 amateur tell).
- **Paint into vertex color:** the artist's channel. Convention (borrowed from every foliage pipeline since Crysis): **R = trunk/branch sway weight, G = leaf flutter weight**. For Kenney/Quaternius models you "paint" it in Blender's vertex-paint mode in minutes — or generate it on load (R from height, G = 1 for leaf-material submeshes, 0 for trunk).

### Two frequencies: bend and flutter

Trees move at two distinct tempos, and conflating them is why bad vegetation looks like seaweed:

```
trunk bend:  slow (~0.5–1 Hz), follows the gust envelope, whole tree leans
leaf flutter: fast (~4–8 Hz), small amplitude, only G-weighted verts,
              amplitude scaled by gust — leaves go frantic INSIDE a gust
```

```glsl
vec3 w      = wind_at(world_pos);
float speed = length(w);
// trunk: lean downwind, quadratic in height (R weight)
pos.xz += w.xz * 0.02 * v_color.r;
// flutter: high-frequency wobble, leaves only (G weight), gust-scaled
pos    += normalize(vec3(w.z, 0.3, -w.x) + 0.001)
        * sin(u_time * 6.0 + world_pos.x * 3.1 + world_pos.z * 1.7)
        * 0.04 * v_color.g * speed;
```

The flutter axis is deliberately *perpendicular-ish* to the wind (plus some lift) — leaves flap across the flow, not along it. The per-vertex phase from world position keeps neighboring palms out of sync — ch45's lesson, third appearance.

### Grass: bowing with stiffness falloff

Grass blades aren't springs at one frequency — they *bow*: displacement grows superlinearly toward the tip, and a strong gust pins them over to a maximum (grass saturates; it doesn't keep oscillating harder). For the crossed-quad tufts:

```glsl
float h    = uv.y;                          // 0 root, 1 tip (or local_pos.y / height)
float bow  = pow(h, 2.2);                   // stiffness falloff: stiff base, soft tip
vec2 lean  = w.xz * bow * 0.06;
lean       = lean / (1.0 + length(lean));   // saturate: gusts flatten, never windmill
pos.xz    += lean;
pos.y     -= length(lean) * 0.5 * h;        // bowing shortens height — the detail
                                            // that makes it grass, not a flag
```

That `pos.y` drop is small but load-bearing: a blade leaning 30° gets *shorter* in world Y, and the eye knows it.

### Ambient interaction: the world answers you

Two cheap hooks turn shader motion into *ecology*. First, **gulls flush**: ch72's Flee state already triggers on boat proximity — make perched gulls extra skittish (Perch → Flee radius larger than Cruise's), so gliding close to a resting flock scatters it. Second (the Stretch): **boat-wash** — when your ch67 wake ripples reach the shoreline, shoreline grass reacts, closing the loop boat → water → land.

## Build

1. **`wind.glsl` + gust texture.** Write the include exactly once; generate the 256² tiling fBm gust texture in a startup compute dispatch (or pack it as channel B of ch69's weather texture — one bind serves both). Add `wind_uniforms_apply(shader)` in Odin that sets the four uniforms — call it for every vegetation shader, the cloth's gust factor (retire ch70's placeholder noise), and ch69's weather scroll. One source.

2. **Vertex weights.** Extend the instanced vertex layout with color if your models have it; otherwise compute R/G weights at load (`R = pow(y / height, 2.0)`, `G = is_leaf_submesh ? 1 : 0`) and bake them into the vertex buffer. Grass tufts: derive from UV, no data needed.

3. **Palm shader.** Add the trunk-bend + leaf-flutter block to `pbr_instanced.vert` (guard with `#ifdef VEGETATION` or make a variant — your call; the shader count is becoming real, which is ch77's problem). Displace *before* the model transform's translation is applied — i.e., bend in local-ish space then place — or tall palms on hills bend differently than beach palms for no reason.

4. **Grass shader.** The bowing block. Also fade flutter with distance (`* smoothstep(150.0, 60.0, dist)`) — sub-pixel motion at range is pure shimmer-aliasing, and ch54 taught you to hate shimmer.

5. **Weather coupling.** `u_wind_strength` already routes through `weather.current.wind_strength` if you did ch47 step 3 — verify, don't assume. Storm: palms should *thrash* (the saturating grass math keeps blades sane automatically; palms may want a lean clamp too).

6. **The money-shot test.** Anchor off a beach at wind 8 m/s. Watch the water (ch64's sea state shows gust darkening if you hooked it), then the beach grass, then the palms upslope — the same bright patch of gust texture hits each in sequence as it scrolls. If the front doesn't *travel*, your uv scroll sign is fighting your wind direction convention (ch33: direction is *toward*).

7. **Gull flush.** Bump the Perch state's flee radius (ch72) to ~15 m and give the launch a vertical velocity kick. Sail close to a settled flock: they burst off the spreaders. Free drama, two constants.

## Checkpoint

The island moves: grass in traveling waves, palms leaning and recovering with frantic crowns, everything downwind of everything else at the right delay — and a storm turns it from breeze to thrash without a single new line.

- Stand still and watch one gust front cross from shore to ridge — visibly the *same* front (the slow octave is doing its job).
- Toggle wind direction 180° (debug key): all motion reverses, including scroll direction — no hardcoded axes survived.
- Sail + sails + clouds + palms all answer the same wind change within one transition (the ch47 lerp drives every consumer).
- No shimmer carpet at distance (step 4's fade is working).

## Pitfalls

- **Vegetation "swims" — bases slide on the ground.** Linear height weight, or you displaced after translation so the whole instance moves. Quadratic weight, root weight exactly 0.
- **Everything oscillates in lockstep.** Missing world-position phase in the flutter term — the classic. Also check you didn't sample both gust octaves at the same scale/speed (typo collapses them into one).
- **Gusts strobe instead of travel.** Gust texture isn't tiling (hard seams read as flicker as they scroll), or your two octaves scroll in *opposite* directions — both must move downwind, at different speeds.
- **Storm grass turns into spinning propellers.** No saturation on the lean. The `lean / (1 + |lean|)` clamp is what keeps strength unbounded-safe; never scale amplitude raw by wind strength.
- **Palms bend at the lighting, not the geometry.** You displaced the position but not the normal. For small sway, skip normal correction (fine); for storm-grade bend, rotate the normal by the same lean — or accept it and note that nobody has ever shipped fully correct foliage normals.
- **Wind on land disagrees with the sail.** Two definitions of the wind vector (one `f32` angle, one `vec2`, converted with different conventions). `wind_uniforms_apply` exists precisely so there is exactly one conversion in the codebase.

## Exercises

1. Character/boat brush: a `u_push_pos` uniform — grass within 1.5 m of it leans radially away (smoothstep falloff). Hook it to the boat's bow at beach landings; later, to walking characters in Part 12's ports.
2. Wind-direction debug overlay: arrows on the ch48 HUD sampling `wind_at` at 9 points across the screen-projected ground — the gust field made visible. Keep it; ch74's storm tuning wants it.
3. Falling leaves/spume: a small ch46 emitter per palm whose spawn rate reads the local gust value (CPU-side: sample the same fBm formula in Odin). Gusts shake leaves loose — the systems agreeing again.
4. **Stretch:** boat-wash. When a ch67 ripple's amplitude at the shoreline cells exceeds a threshold (you have the ripple field CPU-side or can read it back coarsely), inject a radial `u_push_pos` impulse into nearby grass for a second. Wake → shore → grass: the full circuit, and nobody who sees it will know why the island feels haunted by your passage.

## Commit

`git commit -m "ch73: global wind function — gust fronts, palm sway, grass bowing"`

[← Ch. 72: Shoals and Flocks](ch72-shoals-and-flocks.md) · [Ch. 74: The Tempest →](ch74-the-tempest.md)
