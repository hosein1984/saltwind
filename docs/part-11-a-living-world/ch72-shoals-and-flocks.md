# Chapter 72 — Shoals and Flocks

*Part 11 — A Living World · Estimated time: 5–6h · learnopengl: no direct equivalent — canonical reference: Craig Reynolds, ["Flocks, Herds, and Schools: A Distributed Behavioral Model"](https://www.red3d.com/cwr/papers/1987/boids.html) (SIGGRAPH 1987)*

**What you'll see when done:** silver fish schooling under your hull, parting around the keel and snapping back — and gulls that trail your wake, wheel, and drop onto the masthead one by one.

## Where we are

The ch45 gulls fly ellipses around a drifting center: convincing at a glance, hollow the moment you watch one. Today they get Reynolds' boids — three local rules from which flocking *emerges* — plus the data structure that makes hundreds of agents affordable (a spatial hash) and a small behavior state machine so they're animals, not particles. Then we do it again underwater. Two of your oldest investments pay out together here: the ch10 fixed timestep makes the sim deterministic and stable, and ch45's instanced rendering means 400 fish cost two draw calls. This chapter is almost pure Odin — the GPU barely notices.

## Concepts

### Three rules, no leader

Each boid looks only at neighbors within a radius and steers by three accumulated urges:

```
  separation                alignment                cohesion
  (don't crowd)             (match heading)          (stay with the group)

   ←·   ·→                   ↗ ↗ ↗                    ·   ·
     \ /                      ↗ ↗                      ↘ ↙
      ✕  push AWAY from       ↗   steer toward          ·→ steer toward
     / \  too-close           mean neighbor             neighbor center
   ·     ·  neighbors         velocity                  of mass
```

The magic is that *flocking is not in the code*. No formation logic, no leader — yet the group turns as one, splits around obstacles, and rejoins. Three tuning handles per rule: **radius** (separation sees ~2 m, cohesion ~8 m), **weight** (separation strongest — overlapping birds is the one unforgivable artifact), and a **max steering force** so urges bend velocity rather than teleporting it. Cap speed between a min and max (fish never hover; gulls stall below ~3 m/s) and clamp turn rate — that clamp alone is most of the difference between "particles" and "animals."

### The spatial hash: O(n) neighborhoods

Naive neighbor search is O(n²) — 400 boids = 160,000 distance checks per step, per rule. The fix: chop space into cells the size of your largest rule radius, bucket boids by cell, and only test the 27 surrounding cells. The **cell-key trick** packs integer cell coordinates into one map key:

```
cell = floor(position / CELL_SIZE)          CELL_SIZE = max rule radius (8 m)
key  = (i64(cell.x) << 42) | (i64(cell.y & 0x1FFFFF) << 21) | i64(cell.z & 0x1FFFFF)
```

21 bits per axis spans ±a million cells — the archipelago fits with room for sequels. Rebuild the table every step (clearing and refilling is cheaper than incremental updates at this scale), then each boid queries its 3×3×3 neighborhood. Cost goes from O(n²) to O(n·k) where k ≈ neighbors actually nearby — the same idea ch23's chunk culling applied to triangles, now applied to agents.

### Species are data, behaviors are states

Fish and gulls run the *same* `boids_update` with different parameter blocks and different **steering extras** layered on top of the three rules:

- **Fish:** repulsor sphere at the hull (weight spikes inside 6 m — the school *parts* around you), soft attractors at reef points (ch66's coral placements), a hard ceiling at `ocean_height_at(x, z) - 0.5` and floor at the seabed. That surface clamp is your Part 10 CPU ocean mirror earning another customer.
- **Gulls:** a gentle attractor toward a point trailing the boat, altitude band 5–25 m, and a **perch** behavior targeting mast/spreader anchor points.

On top, a tiny per-boid state machine:

```
        ┌──────── timer / boat far ────────┐
        ▼                                   │
   ┌─ Cruise ─→ Feed (fish: reef nibble;   │
   │     │       gulls: circle wake)  ──────┘
   │   boat too close
   │     ▼
   │   Flee  (sprint away, ignore cohesion)
   └── calm again ──┘          gulls also: Perch (kill velocity, stick to anchor,
                                           burst off when boat near — ch73 hooks this)
```

States don't replace the rules — they *reweight* them (Flee: separation ×3, cohesion 0, max_speed ×1.6) and pick the attractor. Parameters, not branches, just like ch47's weather lesson.

### Rendering: LODs from parts past

Nearest birds/fish (LOD0, ~8 of them) use the ch71 skeletal path — real flap keyframes, individually sampled with per-boid phase. Everything farther (LOD1+) renders with ch45 instancing and the old vertex-sine wing bend — which at 30+ meters is indistinguishable and costs one draw call for the whole flock. Partition per frame by camera distance, update two instance buffers. (The production trick that removes even the LOD0 cost — baking skeletal animation into a **vertex animation texture** the instanced shader samples — is the Stretch.)

## Odin notes

A `map[i64][dynamic]int` works and reads clearly — but it allocates per cell. The allocation-free upgrade is the flat **counting-sort grid**: count boids per cell, prefix-sum into offsets, scatter indices into one flat array. Same query interface, zero per-frame allocations:

```odin
Boid_System :: struct {
    boids:        []Boid,                 // fixed capacity, make() once
    params:       Boid_Params,            // radii, weights, speed/turn caps
    cell_of:      []i64,                  // parallel: key per boid
    grid:         map[i64][dynamic]int,   // v1: clear + refill each step
}
```

Ship v1 with the map (`clear(&grid)` keeps buckets' capacity across frames, so steady-state allocation is near zero anyway); profile before bothering with v2. For wander noise use `rand.float32_range(-1, 1)` per axis per second — boids without a touch of jitter converge into eerily perfect lattices.

## Build

1. **Types and the grid.**

   ```odin
   Boid :: struct {
       position, velocity: glsl.vec3,
       state:              Boid_State,    // enum { Cruise, Feed, Flee, Perch }
       state_timer:        f32,
       phase:              f32,           // animation desync
   }

   cell_key :: proc(p: glsl.vec3, cell: f32) -> i64 {
       x, y, z := i64(math.floor(p.x / cell)), i64(math.floor(p.y / cell)), i64(math.floor(p.z / cell))
       return (x << 42) | ((y & 0x1FFFFF) << 21) | (z & 0x1FFFFF)
   }
   ```

2. **`boids_update`** (fixed timestep). Rebuild grid; per boid, accumulate over the 27 neighbor cells:

   ```odin
   for key_off in neighbor_offsets {           // precomputed 27 key deltas? No —
       k := cell_key(b.position + off, cell)   // offset in space, then key. Simpler, correct.
       for j in sys.grid[k] {
           d := boids[j].position - b.position
           dist := glsl.length(d)
           if j == i || dist > p.cohesion_radius { continue }
           if dist < p.separation_radius { sep -= d / max(dist * dist, 0.01) }
           ali += boids[j].velocity
           coh += boids[j].position
           n += 1
       }
   }
   ```

   Combine: `steer = sep*w_sep + norm(ali/n - vel)*w_ali + norm(coh/n - pos)*w_coh + extras`, clamp `steer` to `max_force`, integrate, clamp speed to `[min_speed, max_speed]`, and clamp the *angle* between old and new velocity to `max_turn * dt` (slerp-style on the direction — `linalg.vector_slerp` exists, or rotate toward with axis-angle).

3. **Species extras.** `boids_update_fish`: hull repulsor (`1/d²` from the boat position, only within 6 m), reef attractors, depth clamp via `ocean_height_at`. `boids_update_gulls`: wake-trailing attractor (boat position minus heading × 15 m, up 10 m), altitude band. Both: the state machine from Concepts as a `switch` that *writes weights into a copy of params* before the rules run.

4. **Perching.** Author 3–4 anchor points on the boat (mast top, spreaders — locals on the ch18 nodes). A Cruise gull within 10 m of a free anchor rolls a chance per second to claim it; Perch zeroes the rules, eases position onto the (moving!) anchor, folds wings (LOD0: blend to the ch71 idle clip — your blend machinery's first real customer). Boat speed > 2 m/s or proximity flush → release anchor, Flee burst, rejoin.

5. **Spawn and render.** 30 gulls, 2–3 fish schools of ~120 around reefs. Each frame (render side): partition by distance, write LOD1+ matrices into the instance VBO (`BufferSubData`, exactly ch45 step 5 — orient each matrix along `velocity`, bank by lateral steer), draw LOD0 through the skinned path with per-boid `phase` offsetting the clip time.

6. **Watch.** Sail through a school: it parts around the bow wave's pressure and seals behind you like mercury. Anchor near gulls: within a minute the mast is occupied. This is the chapter where people stop asking what you're building and start asking *how*.

## Checkpoint

Fish beneath the hull schooling as one organism — splitting, flowing, rejoining; gulls trailing the boat, wheeling, and perching in ones and twos when you slow.

- Profile (ch49 CPU timer): 400 boids well under 1 ms; comment out the grid (brute force) and verify it's measurably worse — earn the data structure.
- No boid ever overlaps another on screen (separation weight is winning, as it must).
- Pause (ch10): the flock freezes mid-bank; single-step and watch a turn propagate across the school neighbor by neighbor — emergence, visible.
- Draw calls: flock + school = LOD0 count + 2 instanced draws, confirmed in RenderDoc.

## Pitfalls

- **Flock collapses into a singularity, then explodes.** Cohesion overpowering separation, or separation lacks the `1/d²` falloff. Separation must dominate at close range by an order of magnitude.
- **Everyone vibrates in place.** Max force too high relative to max speed (urges overshoot every step), or you applied steering in the render loop with variable dt. Fixed step; force ≈ 3–5 × less than what reaches max speed in one second.
- **Grid returns nothing / misses diagonal neighbors.** You offset the *key* by ±1 instead of offsetting the *position* by ±cell — with packed keys, `key + 1` is a different z-cell, not "the next cell in x." Offset in space, then hash (as in the excerpt).
- **Fish surface like dolphins or sink into terrain.** Depth clamps applied before the rules, which then push back out. Clamp position *and* zero the offending velocity component after integration, last.
- **Perched gulls slide off the moving mast.** You stored the anchor's world position at claim time. Store the *node*, evaluate its world position every step — the boat moves under the bird.
- **The school flaps in lockstep.** You forgot per-boid `phase` in the LOD1 sine and the LOD0 clip sampling. ch45 pitfall, same fix, new actors.

## Exercises

1. Predator flash: when the boat enters Flee radius, propagate alarm — a fleeing fish raises a `panic` value on neighbors (one extra accumulated term), so the flinch ripples outward faster than the boat moves. Schools do this in real life; it's two lines.
2. Feeding frenzy: when the boat sits anchored, occasionally spawn a "bait ball" attractor — fish converge, gulls dive (Feed state gets a swoop toward the surface + ch46 splash particles). Your first emergent *scene*.
3. Expose `Boid_Params` in the ch48 microui panel with live sliders. Ten minutes of slider play teaches flock dynamics better than any paper — find the settings where it stops looking like birds, and learn why.
4. **Stretch:** vertex animation texture — bake the ch71 flap clip's bone matrices (or directly the posed vertex positions) into a float texture, one row per frame; the instanced vertex shader samples it by `phase`. Skeletal-quality motion at instanced cost, LOD0 retired entirely. Search "VAT vertex animation texture" for the layout conventions.

## Commit

`git commit -m "ch72: boids with spatial hash — fish schools, gull flock, behavior states"`

[← Ch. 71: Bones of the Gull](ch71-bones-of-the-gull.md) · [Ch. 73: The Green and the Gale →](ch73-the-green-and-the-gale.md)
