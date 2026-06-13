# Chapter 25 — MILESTONE: The Archipelago

*Part 4 — Raising Islands · Estimated time: 2h · learnopengl: review of Part 4's articles*

**What you'll see when done:** a world with a name — a seeded island chain you can regenerate with a keystroke, fly over for as long as you like, and prove is rendering efficiently with a single held key.

## Where we are

Part 4 took Saltwind from "open water with props" to "a *place*": noise-born islands, splatted and sunlit, chunked and culled, ringed with foam and turquoise. This milestone bolts on the last quality-of-life pieces — regeneration at runtime, a seed picker, a world name — and runs the performance receipts. Then you rest.

## Build: integration

1. **Make regeneration a first-class operation.** Everything the world derives from `World_Gen_Params` must rebuild cleanly. Write the one proc that does it all, releasing GL resources before recreating them:

   ```odin
   world_regenerate :: proc(game: ^Game, params: World_Gen_Params) {
       for &chunk in game.terrain.chunks do mesh_destroy(&chunk.mesh)
       delete(game.terrain.chunks)
       delete(game.terrain.heights)
       gl.DeleteTextures(1, &game.terrain.heightfield_tex)

       game.params = params
       terrain_generate(&game.terrain, params)            // heights + normals
       terrain_build_chunks(&game.terrain)                // meshes + AABBs
       game.terrain.heightfield_tex =
           terrain_create_heightfield_texture(&game.terrain)
   }
   ```

   If this leaks (watch GPU memory in your OS tools while hammering regenerate), some `*_create` is missing its `*_destroy` — find it now, not in Chapter 40.

2. **Seed picker.** Bind keys: `N` for a fresh pseudo-random seed (current time works: `time.now()._nsec`, or just increment), `R` to re-roll the *same* seed (verifying determinism — the world must come back identical). Print the seed prominently; a seed you can't read is a world you can't revisit.

3. **Name your world.** Worlds deserve names more than numbers. Hash a name string to a seed with FNV-1a — six lines, no dependencies:

   ```odin
   seed_from_name :: proc(name: string) -> i64 {
       h: u64 = 0xcbf29ce484222325
       for b in transmute([]u8)name {
           h = (h ~ u64(b)) * 0x100000001b3
       }
       return i64(h)
   }
   ```

   Hardcode a few favorites behind number keys (`1` = "Saltwind", `2` = "Tortuga", `3` = your call) and let `N` keep rolling anonymous seeds between them. When you find a world you love, name the seed in code and commit it — it's canon now.

4. **Performance sanity: culling receipts.** Add a held-key comparison — hold `C` to bypass culling, release to restore:

   ```odin
   for &chunk in game.terrain.chunks {
       visible := game.cull_disabled ||
                  aabb_in_frustum(frustum, chunk.aabb_min, chunk.aabb_max)
       if visible { mesh_draw(&chunk.mesh); drawn += 1 }
   }
   ```

   Put frame milliseconds next to the chunk fraction in the title (you have frame delta already — average it over ~30 frames so it's readable):

   ```
   Saltwind [Tortuga #7741…] — chunks 21/64 — 2.1 ms    (culling on)
   Saltwind [Tortuga #7741…] — chunks 64/64 — 5.8 ms    (holding C)
   ```

   Your numbers will differ; what matters is that the gap exists, grows with world size, and shrinks to nothing when you stare straight down at one chunk. If culling *on* is ever slower, your per-chunk state changes are the villain (Chapter 23, last pitfall).

5. **Place the Part 3 cast.** Move the boat and lantern buoys to a pleasant anchorage in your named world's best bay (use `terrain_height_at` to make sure you've picked water, not a sandbar — or rather, *check* for the sandbar; they're scenic). Confirm bobbing, lanterns, and the sun arc all still work over the new seabed.

6. **Regression sweep.** Regenerate ten worlds in a row while flying — no crashes, no leaks, foam and shallows correct on each (heightfield texture is being recreated), normals seamless across chunks, window title updating.

## Checkpoint

Fly a slow circuit of your named archipelago at golden hour: foam-ringed coasts, grass and rock reading correctly on the slopes, the boat at anchor in a bay, frame time flat, and the chunk fraction breathing as you turn your head.

- `R` reproduces the world exactly; `N` makes a new one in well under a second.
- Holding `C` visibly raises frame time (or at minimum the chunk count) and changes *nothing* on screen.
- Ten regenerations: memory flat, no GL errors.
- The seed/name in the title matches what regenerates.

## Screenshot moment #3

- High altitude, three-quarter angle, sun low — the whole chain in frame with foam halos visible around every island.
- A second shot from deck height in the anchorage: boat, lantern, beach, shallows. (This pair — map view and human view — is the classic "I made a world" post.)
- Save as `screenshots/03-the-archipelago.png` (and `03b-…` for the bay).

Post them — [Odin Discord](https://discord.com/invite/sVBPHEv) #showcase, [r/odinlang](https://www.reddit.com/r/odinlang/), or learnopengl's community screenshots thread — and include your favorite seed in the post. Procedural worlds are uniquely shareable: someone else typing your seed and flying your islands is a small, real magic, and the encouragement loop matters for the chapters ahead.

## Self-test quiz

From memory first; answers below.

1. Your terrain `heights` array stores world-space meters rather than 0–255 texel values. What downstream systems did that decision quietly simplify?
2. Why does `noise.noise_2d` take an `i64` seed *and* `f64` coordinates — what role does each play in "same world every time"?
3. In fBm, what visual quality do *lacunarity* and *persistence* each control? What happens with persistence 0.9?
4. Why do central-difference normals stay seamless across chunk borders when face-averaged normals wouldn't?
5. The frustum's left plane is `row4 + row1` of the VP matrix. In one sentence, where does that formula come from?
6. In the AABB positive-vertex test, why is it sufficient to test a single corner per plane?
7. Why must the sea be drawn after the terrain once blending is enabled — what exactly does the blend equation read?
8. Your foam band came out stair-stepped along cell boundaries. Two texture parameters are suspects — which, and why?

<details>
<summary>Answers</summary>

1. Anything that consumes heights as physical quantities: `terrain_height_at` (camera clamping, future buoyancy), normal computation (the `2·cell_size` Y term needs consistent units), AABB y-bounds, the R32F heightfield texture, and the sea shader's depth math — none needed a conversion factor.
2. The seed selects which infinite noise field you're sampling (the lattice gradient assignment); the coordinates select where in it you sample. Same seed + same coordinates + same params = identical heights on every run and machine.
3. Lacunarity scales feature *size* between octaves (frequency multiplier); persistence scales feature *strength* (amplitude multiplier). Persistence 0.9 lets high octaves nearly match the base swell — jagged, noisy, "crumpled foil" terrain.
4. Central differences differentiate the *global heightfield*, which is identical on both sides of a border; face averaging differentiates each chunk's *mesh*, and a border vertex sees a different set of faces in each chunk, creasing the lighting.
5. Clip-space visibility requires `x ≥ −w`; expanding both via the matrix rows gives `(row4 + row1) · world ≥ 0`, which is a plane equation in world space.
6. The chosen corner (the p-vertex) is the one farthest in the plane normal's direction — the box's *most inside* point for that plane. If even it is outside, every other point of the box must be too.
7. `ONE_MINUS_SRC_ALPHA` blending mixes the sea fragment with the *current framebuffer contents* at that pixel; if the terrain isn't there yet, the sea blends with the clear color and the terrain later draws over or z-fails against it.
8. `TEXTURE_MIN_FILTER`/`MAG_FILTER` set to `NEAREST` (or min-filter left at its mipmap default with no mips) quantizes height samples to texel centers; `LINEAR` interpolates between cells, smoothing depth and therefore the foam threshold.

</details>

## If you're returning after a break

Here's Saltwind as you left it. The world is generated, not painted: `world_regenerate` turns a `World_Gen_Params` (seed, fBm settings, falloff blobs) into a `Terrain` — heights from **seeded OpenSimplex2 fBm** (`fbm_2d`, octave seeds offset, normalized by total amplitude) shaped by **radial falloff masks** (`max` of smooth bumps = archipelago, `sea_floor` below). Normals come from **central differences** over the global heights; the fragment shader splats **sand/grass/rock by height and slope** smoothsteps. The terrain lives as **64-cell chunks** (65×65 shared-border verts) with height-aware AABBs, culled per frame against a **frustum extracted from the VP matrix** (rows gathered column-major — `m[col, row]`!); the title bar shows `chunks drawn/total` and frame ms, `C` bypasses culling for comparison. The sea samples the heights as an **R32F texture** for depth-tinted shallows, a smoothstep **foam band**, and alpha **blending** drawn after all opaques; wet sand darkens just above `y = 0`. `N`/`R`/number keys drive the **seed picker**, names hash to seeds via FNV-1a. Run it, regenerate a couple of worlds, re-find your favorite seed — then make for Part 5, where the sky becomes real and the flat sea finally learns to roll.

## Commit

`git commit -m "ch25: milestone — the archipelago"`

← [Chapter 24 — Where Land Meets Sea](ch24-where-land-meets-sea.md) · [Chapter 26 — A Box of Sky](../part-5-the-living-sea/ch26-a-box-of-sky.md) →

> ⚓ **Optional side quest:** [Interlude 25a — The World Unmoored](ch25a-the-world-unmoored.md) — teleport 50 km out, watch f32 precision shake the world apart, then fix it with a floating origin.
