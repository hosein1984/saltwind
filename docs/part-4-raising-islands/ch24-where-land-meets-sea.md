# Chapter 24 — Where Land Meets Sea

*Part 4 — Raising Islands · Estimated time: 2.5h · learnopengl: [Blending](https://learnopengl.com/Advanced-OpenGL/Blending) (preview — the full treatment lands in ch34)*

**What you'll see when done:** turquoise shallows deepening to navy, a ring of white foam hugging every coastline, and a dark wet-sand band at the waterline — the single biggest jump in "looks like a real place" so far.

## Where we are

Your sea is still the Part 2 plane: one color, opaque, sawing through the islands at `y = 0` like a sheet of blue glass. Real coastal water is a *function of depth* — and your sea shader can know the depth, because the terrain heightfield exists on the CPU and can be handed to the GPU as a texture. This chapter wires that up, and properly introduces alpha blending along the way.

## Concepts

### Water color is depth

Water absorbs light, reds first, blues last (which is *why* deep water is blue). Light reaching your eye from shallow water has also bounced off the bright sand below; from deep water, almost nothing returns. So the dominant visual rule of coasts is simply:

```
water_depth = sea_level − terrain_height(x, z)      (sea_level = 0 for us)

depth ≈ 0      →  bright turquoise (sand glowing through)
depth ≈ 10 m   →  deep navy
```

An exponential-ish ramp looks right (absorption is exponential); a `smoothstep` over the first ~8 m is a fine approximation. Two more depth-driven effects complete the coastline:

- **Foam** where waves meet land: a `smoothstep` band over the first ~40 cm of depth produces a ribbon that automatically traces every coastline, bay, and sandbar — geometry you never drew.
- **Wet sand**: real sand darkens (water fills the gaps between grains, less light scatters back) in a band just *above* the waterline. That one's a terrain-shader change: darken albedo for `0 < height < ~0.6 m`.

### The heightfield as a texture

The sea fragment shader needs `terrain_height(x, z)` per fragment. You already have those numbers — `terrain.heights`, a `[]f32`. Upload them as a single-channel float texture (`gl.R32F`) and the GPU's sampler becomes your `terrain_height_at`, bilinear interpolation included:

```
world xz  ──map──►  uv in [0,1]²  ──sample──►  height (meters, signed)

uv = (world.xz − terrain_origin.xz) / terrain_world_size
```

Two settings matter: **`gl.LINEAR` filtering** (NEAREST quantizes depth to cells — stair-stepped foam), and **`gl.CLAMP_TO_EDGE`** wrapping (REPEAT would tile phantom islands into the open sea). And note this is the Chapter 16 distinction with teeth: R32F is a *data* format; there is no sRGB anything here.

This texture is a workhorse, not a hack — Chapter 28's Gerstner waves keep it, Chapter 32's buoyancy and Chapter 34's foam refine on top of it.

### Alpha blending, done in the right order

Shallow water should also be *transparent* — you want to see sand through it. Transparency in OpenGL is **blending**: instead of replacing the framebuffer pixel, the new fragment mixes with it:

```
final = src.rgb * src.a  +  dst.rgb * (1 − src.a)
        └─ the sea ─┘       └─ whatever was behind ─┘
```

```odin
gl.Enable(gl.BLEND)
gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
```

The catch that fills half the [Blending](https://learnopengl.com/Advanced-OpenGL/Blending) article: blending reads *what's already in the framebuffer*, so **draw order is now part of correctness**. The rule:

1. Draw all **opaque** geometry first (terrain, boat, buoys) — any order, depth buffer sorts it out.
2. Draw **transparent** geometry after (the sea), so the things behind it are there to blend with.

We get off easy this chapter: one transparent surface, so there's no transparent-vs-transparent sorting problem yet (that, plus the depth-write question and order-independent approaches, is Chapter 34 when wakes and foam sprites arrive). One subtlety worth doing right now: keep depth *testing* on for the sea (islands must still occlude water behind them) — and since the sea is drawn last, leaving depth writes on is harmless today.

## Build

1. **Upload the heightfield.** In `terrain.odin`, after generation:

   ```odin
   terrain_create_heightfield_texture :: proc(t: ^Terrain) -> u32 {
       tex: u32
       gl.GenTextures(1, &tex)
       gl.BindTexture(gl.TEXTURE_2D, tex)
       gl.TexImage2D(gl.TEXTURE_2D, 0, gl.R32F,
                     i32(t.width), i32(t.depth), 0,
                     gl.RED, gl.FLOAT, raw_data(t.heights))
       gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
       gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
       gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
       gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
       return tex
   }
   ```

   Store the id on `Terrain`; regenerate it whenever the terrain regenerates (delete the old one first — `gl.DeleteTextures`).

2. **Feed the sea shader.** Bind the heightfield to a spare unit at sea-draw time and pass the mapping uniforms:

   ```odin
   shader_set_vec2(sea_shader, "terrain_origin", {t.origin.x, t.origin.z})
   shader_set_f32(sea_shader, "terrain_size", f32(t.width - 1) * t.cell_size)
   ```

   (Add `shader_set_vec2` if you haven't — `gl.Uniform2fv`, same pattern as vec3. Size uses `width − 1`: meters span cells, not vertices; being a half-texel honest here prevents a subtle coastline offset.)

3. **Rewrite `sea.frag`** around depth. Keep your existing distance-fade/tint logic as the *deep* base color:

   ```glsl
   uniform sampler2D u_heightfield;
   uniform vec2  terrain_origin;
   uniform float terrain_size;

   void main() {
       vec2  uv     = (v_world_pos.xz - terrain_origin) / terrain_size;
       float ground = texture(u_heightfield, uv).r;     // meters, signed
       float depth  = max(0.0 - ground, 0.0);           // sea level = 0

       vec3 shallow = vec3(0.10, 0.65, 0.60);           // turquoise
       vec3 deep    = vec3(0.02, 0.09, 0.22);           // navy
       vec3 water   = mix(shallow, deep, smoothstep(0.0, 8.0, depth));

       float foam   = 1.0 - smoothstep(0.05, 0.45, depth);
       water        = mix(water, vec3(0.95), foam * 0.85);

       float alpha  = mix(0.55, 0.96, smoothstep(0.0, 6.0, depth));
       alpha        = max(alpha, foam);                  // foam reads opaque

       frag_color = vec4(water * sun_tint(), alpha);     // your existing lighting/tint
   }
   ```

   Outside the heightfield (uv beyond 0..1) `CLAMP_TO_EDGE` returns border heights — your generator's `sea_floor` — so open ocean is automatically deep navy.

4. **Set up blend state and draw order.** In the render loop: terrain and all props first; then enable blending, draw the sea, disable blending (leaving stray state enabled is how Part 5 bugs are born):

   ```odin
   // opaque pass: terrain chunks (culled), boat, buoys, crates ...
   gl.Enable(gl.BLEND)
   gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
   mesh_draw(&game.sea_mesh)
   gl.Disable(gl.BLEND)
   ```

5. **Wet sand band** in `terrain.frag` — three lines after the splat blend:

   ```glsl
   float wet = 1.0 - smoothstep(0.05, 0.7, v_world_pos.y);
   albedo *= mix(1.0, 0.55, wet * step(0.0, v_world_pos.y));
   ```

   (The `step` keeps the darkening above the waterline only — below it, the water tint owns the look.)

6. **Walk the coast.** Fly low along a beach: foam ribbon at the waterline, sand visible through half a meter of turquoise, the bottom fading out by ~6–8 m. Tune the four magic depths (`8.0` color ramp, `0.45` foam, `6.0` alpha, `0.7` wet band) to taste — they're the personality of your sea.

## Checkpoint

Coastlines you want to anchor in: every island ringed by white foam, a turquoise apron fading to navy, dark wet sand right at the waterline, and underwater slopes visibly continuing down through the shallows.

- The foam ribbon follows *every* concavity of every island — including any sandbar your noise put just below sea level (look for foam patches in open water; they're real and they're wonderful).
- From altitude, shallows read as bright halos around the islands.
- Look from underwater up at an island slope: terrain renders solid (it's opaque); only the sea surface blends.
- Toggle blending off for one frame: shallows lose the see-through sand but foam/colors stay — confirming depth-tint and transparency are independent effects.

## Pitfalls

- **No transparency at all.** The sea is drawn *before* the terrain — there's nothing behind it to blend with except clear color. Opaque first, sea last.
- **Foam ring is stair-stepped.** Heightfield texture filtering is `NEAREST` (default `MIN_FILTER` is `NEAREST_MIPMAP_LINEAR` and you have no mips — which samples as garbage or black!). Set both filters to `LINEAR` explicitly.
- **Phantom islands tiled across the open sea.** Wrap mode is `REPEAT`. `CLAMP_TO_EDGE`, both axes.
- **Coastline colors offset from the actual coast.** The uv mapping disagrees with vertex placement — usually `width` vs `width − 1` in `terrain_size`, or origin sign. Sanity-check by outputting `ground` as grayscale (`frag_color = vec4(vec3(ground * 0.02 + 0.5), 1)`) and comparing against the islands through the water.
- **Whole sea went milky.** `depth` is negative over land but you forgot the `max(…, 0)` clamp somewhere, or heightfield uploaded *before* terrain regeneration overwrote `heights` — recreate the texture after every regen.
- **Everything drawn after the sea looks ghostly.** Blending left enabled for subsequent draws (next frame's terrain!). Disable after the sea, every frame.

## Exercises

1. Animate the foam: wobble the band threshold with `0.1 * sin(8.0 * v_world_pos.x + 2.0 * u_time)` (and a z term at a different frequency) so the ribbon breathes against the beach.
2. Add a second foam line slightly deeper (a thin `smoothstep` band around depth ≈ 1.2 m, weaker) — surf breaking on the outer bar.
3. Tint *underwater terrain* in `terrain.frag`: below `y = 0`, shift albedo toward blue-green by depth. The seabed stops looking like dry land seen through glass.
4. **Stretch:** Fake refraction — offset the heightfield uv by a small time-scrolled noise (`uv += 0.003 * vec2(noise…)`) so the shallows shimmer. Compare with the real thing when you build DuDv refraction in Chapter 30.

## Commit

`git commit -m "ch24: depth-tinted shallows, shoreline foam, sea blending"`

← [Chapter 23 — A World in Pieces](ch23-a-world-in-pieces.md) · [Chapter 25 — Milestone: The Archipelago](ch25-milestone-the-archipelago.md) →
