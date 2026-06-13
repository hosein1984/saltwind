# Chapter 47 — The Breath of Distance

*Part 8 — Full Sail · Estimated time: 4h · learnopengl: no direct equivalent — this is engine/game material*

**What you'll see when done:** far islands dissolve into the sky instead of pasting against it, and pressing a key rolls a storm in — wind rises, waves steepen, the world grays out — over thirty smooth seconds.

## Where we are

Stand on deck and look at the horizon: your farthest islands are pin-sharp, which is exactly how you can tell they're fake. Real air is *stuff* — it scatters light into the view path, washing distant things toward the sky's color. That's aerial perspective, painters have faked it since the 1400s, and we get it nearly free because chapter 27 gave us the key ingredient: a function that knows the sky's color in any direction. Then we put all our atmosphere knobs — wind, waves, fog, sky tint — under one authority: a weather state machine. This is the chapter where Saltwind gets *moods*.

## Concepts

### Exponential fog: the physics-flavored fade

Light traveling distance *d* through uniform haze keeps `exp(-density · d)` of its original color (Beer-Lambert). Two standard profiles:

```glsl
float f1 = exp(-u_fog_density * dist);           // exp:  gentle, long tail
float f2 = exp(-pow(u_fog_density * dist, 2.0)); // exp2: clearer near, harder wall
color = mix(fog_color, color, f);                 // f = fraction SURVIVING
```

`exp²` keeps the near field crisp and rolls off faster at range — usually the right pick for an ocean horizon. Densities are tiny: 0.002–0.01 for clear-to-hazy at our world scale. Use the *true* distance `length(world_pos - cam_pos)`, not view-space z, or fog will visibly swing as you turn the camera.

### Height fog: haze hugs the water

Real haze pools low: marine layer, morning mist in valleys. Multiply density by an exponential falloff in the *fragment's* height — `density *= exp(-max(world_pos.y, 0.0) * u_height_falloff)` — and mist sits on the sea while peaks rise clear above it. (The exact-integral version along the view ray is lovely calculus and overkill here; the per-fragment approximation reads identically at our scales.)

### Fog color IS the sky: aerial perspective

The classic mistake is a constant `u_fog_color = gray`. But fog isn't gray — fog is *the sky, seen through miles of air*. The scattered-in light comes from the same atmosphere your ch27 sky shader models. So compute fog color per fragment from the **view direction**, using the same logic:

```glsl
vec3 view_dir  = normalize(v_world_pos - u_cam_pos);
vec3 fog_color = sky_color(view_dir);   // ch27's function, shared via your
                                         // shader-include concat from ch44
color = mix(fog_color, color, f);
```

Now islands toward the sun fade into *orange* haze at sunset and *blue-gray* away from it; the horizon seam between sea and sky disappears because both converge to the same function. This single change is worth the whole chapter. (Cheaper variant if `sky_color` is heavy: sample your ch43 sky cubemap's lowest mip with `view_dir`.)

### Underwater is just very dense fog

When the camera dips below `ocean_height_at(cam.xz)`: swap the regime — density ×100, fog color deep blue-green, and a screen tint in the tonemap pass (a `u_underwater` uniform mixing toward `vec3(0.1, 0.3, 0.35)` before the curve). Ten lines, and falling overboard stops breaking the illusion. (Proper underwater — refraction at the surface from below, god rays — is epilogue material; the fog regime is the 90% version.)

### The weather state machine

You now own at least six "mood" parameters scattered across systems: wind strength (ch33), wave amplitude/steepness (ch28), fog density, sky tint/cloudiness (ch27), rain emission (ch46), sun dimming. A **weather system** owns named presets and *transitions* between them:

```
        30s                60s
Clear ─────► Overcast ─────► Storm
  ▲              │             │
  └──────────────┴─────────────┘
       (any state may roll back)
```

The crucial design point: systems don't read "the weather state" — they read **interpolated parameters**. During a transition you lerp the whole parameter block from the old preset to the new over `transition_seconds`, and downstream systems never know states exist. Wave amplitude eases up, rain fades in by emission *rate* (existing drops live out their lives), the sky grays. Sudden parameter snaps are how weather systems announce they're fake; the lerp is the entire trick.

## Odin notes

The parameter block wants to be a struct you can lerp field-wise. Odin makes the preset table pleasant — and note `math.lerp` works on any float type:

```odin
Weather_Params :: struct {
    wind_strength:  f32,
    wave_amplitude: f32,
    wave_steepness: f32,
    fog_density:    f32,
    sky_gray:       f32,   // 0 = ch27 sky, 1 = flat overcast
    rain_rate:      f32,   // particles/sec
    sun_dim:        f32,
}

Weather_State :: enum { Clear, Overcast, Storm }

WEATHER_PRESETS := [Weather_State]Weather_Params{
    .Clear    = {1.0, 1.0, 1.0, 0.003, 0.0,   0, 1.0},
    .Overcast = {1.6, 1.4, 1.2, 0.010, 0.7,   0, 0.5},
    .Storm    = {2.8, 2.2, 1.6, 0.022, 1.0, 400, 0.2},
}
```

That `[Weather_State]Weather_Params` is an enumerated array — exhaustive by construction; add a state and the compiler demands a preset.

## Build

1. **Fog in every "world" fragment shader** (terrain, ocean, PBR objects, instanced vegetation — not sky, not particles yet): compute distance, exp² with height falloff, `sky_color(view_dir)` mix as the *last* operation before output (after all lighting, in linear HDR space — fog is light too, and bloom should see a foggy bright horizon). Share the snippet via your shader-include concat.

2. **`Weather` struct and update.**

   ```odin
   Weather :: struct {
       state, target: Weather_State,
       blend:         f32,  // 0..1 through the transition
       duration:      f32,
       current:       Weather_Params, // what everyone reads
   }

   weather_update :: proc(w: ^Weather, dt: f32) {
       if w.state != w.target {
           w.blend = min(w.blend + dt / w.duration, 1.0)
           a, b := WEATHER_PRESETS[w.state], WEATHER_PRESETS[w.target]
           w.current = weather_lerp(a, b, ease_in_out(w.blend))
           if w.blend >= 1.0 { w.state = w.target; w.blend = 0 }
       }
   }
   ```

   `weather_lerp` is seven `math.lerp` lines (or get clever with reflection later; don't today). `ease_in_out(t) = t*t*(3-2*t)` — smoothstep — so transitions breathe instead of ramping.

3. **Rewire consumers.** The honest work: wherever wind strength, wave params, fog density, and rain emission were constants or ad-hoc uniforms, route them through `game.weather.current`. Ocean uniforms (`u_amplitude`, `u_steepness`) update per frame now — they were already uniforms, so this is plumbing, not surgery. Sky shader gets `u_sky_gray` and desaturates/flattens toward overcast (mix the gradient toward a gray ramp, shrink the sun disk's intensity by `sun_dim`).

4. **Rain hookup.** Replace ch46's debug key with `rain_rate`: accumulate `rate * dt` into a float, spawn `int(acc)` particles, keep the fraction. Storm = rain on, automatically, mid-transition.

5. **Underwater regime.** In the camera update, `submerged := cam.position.y < ocean_height_at(...)`; pass to shaders; swap fog constants and add the tonemap tint. Clamp the chase camera (ch33) above the surface *unless* the player flies under deliberately.

6. **Controls + drama.** Keys 1/2/3 set `target` with `duration = 30`. Then sail a full Clear→Storm→Clear cycle. Watch the swells grow *while* the horizon closes in. This is the best the game has ever felt, and you should sit with that for a minute.

## Checkpoint

Clear day: far islands tinted faintly blue, melting into the horizon rather than pasted on it; toward the sun the haze warms. Press 3: over half a minute the wind moans up (audio from ch36 if you built it), waves steepen and whitecap, rain sweeps in, the world closes to a gray 200-meter sphere. Press 1 and the sun carves it open again.

- Spin the camera 360° in haze: fog density doesn't pulse with view angle (true distance, not view-z).
- The sea/sky horizon line is *gone* in any weather — both converge to `sky_color`.
- During a transition, nothing snaps: waves, fog, rain, sky all ease together.
- Dunk the camera: instant blue-green murk, not the void between the ocean's underside and the skybox.

## Pitfalls

- **Fog brightens distant objects at night.** Your `sky_color` includes the sun disk / bright tint that shouldn't scatter at this density. Sample the sky function *without* the sun disk term for fog (pass a flag), or clamp fog color luminance.
- **Horizon seam survives.** The ocean's far fade (ch12/24 tricks) is fighting the fog, or the sky shader and fog use different `sky_color` parameterizations. One function, one set of uniforms, shared include.
- **Fog applied before lighting/reflections.** If the planar reflections (ch30) don't fog, reflected islands stay sharp inside foggy ones — apply the same fog in the reflection-pass renders too (it's the same shaders, so this usually just works; the bug appears when someone "optimizes" the reflection shader variants).
- **Storm waves pop.** You routed amplitude through weather but a cached CPU-side `ocean_height_at` (buoyancy!) still uses old constants — boat floats *under* visual waves. Buoyancy and vertex shader must read the same `weather.current` values each frame.
- **exp vs exp² confusion: "my density does nothing."** At density 0.005 and 100 m, exp² survives `exp(-0.25)` ≈ 0.78 but exp survives 0.61 — recheck which curve your constant was tuned for.
- **Rain continues forever after returning to Clear.** You gated spawning on `state == .Storm` instead of `rain_rate > 0` — mid-transition the state is still the *old* one. Parameters, not states, drive systems.

## Exercises

1. Lightning: during Storm, every 4–12 s, spike the sun-light intensity ×40 for two frames from a random azimuth, with a thunder sample (ch36) delayed by distance/340 m·s⁻¹. Cheap and *fantastic*.
2. Add a `Fog_Bank` — a localized density multiplier (smoothstepped sphere or noise patch) anchored in the world, so you can sail *into* a fog bank that was visible from miles off.
3. Weather autopilot: a Markov chain ticking every few minutes (Clear→Overcast 0.3, Overcast→Storm 0.4, …) so the world has weather without keypresses. Keep the keys as override.
4. **Stretch:** wind *direction* shifts with weather fronts (lerp the angle too) — and suddenly your ch33 sailing model means storms change your tactics, not just your visibility. This is the moment Saltwind's systems start talking to each other on their own.

## Commit

`git commit -m "ch47: aerial-perspective fog, underwater tint, weather state machine"`

[← Ch. 46: Spray & Storm](ch46-spray-and-storm.md) · [Ch. 48: Words on Glass →](ch48-words-on-glass.md)
