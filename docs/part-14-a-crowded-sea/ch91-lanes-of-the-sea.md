# Chapter 91 — Lanes of the Sea

*Part 14 — A Crowded Sea · Estimated time: 5h · learnopengl: no direct equivalent — this is game-systems material (Amit Patel's Red Blob Games A* pages are the reference-depth backup)*

**What you'll see when done:** press a debug key, and a search floods across the water — green open cells, dimming closed cells — then collapses into a single golden route that visibly bows downwind around an island, because beating upwind is expensive and your pathfinder knows it.

## Where we are

A housekeeping note first: this part is numbered after Part 13's appendices, but it *reads* directly after Part 12 — the appendices sit between us in numbering only, and nothing here needs them. What this part does need is the shipped game: the economy and ports of ch77–78, the sailing model of ch33, the four-phase frame of ch35. Part 14 reopens ch77's cut list and un-cuts the biggest line item: **AI trader ships**. The cut was correct then — "they'd need docking, pathing, economy participation" was a month of systems standing between you and shipping. You shipped. Now we build the month, properly, one system per chapter. Today: pathing. Before any captain can sail from Gullhaven to Kelpmouth, something must answer the question *which way is round the island?* — and answer it cheaply, hundreds of times per session.

## Concepts

### The sea as a graph

Pathfinding algorithms run on graphs, and the first design decision is always *what are the nodes?* For an archipelago the honest answer is a coarse grid: lay cells of ~20–30 m over the world, mark each cell walkable if the sea there is deep enough, and connect each walkable cell to its 8 neighbors. That's the whole graph. You already own the only function it needs — `terrain_height_at` (ch20/ch24) tells you the seabed height anywhere, so a cell is sailable when the seabed sits comfortably below sea level:

```
walkable(cell) = terrain_height_at(center) < SEA_LEVEL - draft_margin
```

The `draft_margin` (~1.5 m) keeps routes off the sandbars, and an extra one-cell *erosion* pass (a cell is only walkable if its neighbors are too) keeps 20-m-wide ships from clipping headlands the grid technically permits. Diagonal steps cost √2, straight steps cost 1 — get this wrong and every path develops a suspicious taste for staircases.

### A*, taught properly

A* maintains, for every node it has touched, three numbers:

- **g** — the *known* cheapest cost from the start to this node (built up as the search expands),
- **h** — a *heuristic estimate* of the remaining cost to the goal,
- **f = g + h** — the estimated total through this node.

The algorithm is: keep an **open set** of frontier nodes prioritized by lowest `f`; repeatedly pop the most promising one, mark it **closed**, and *relax* its neighbors — if reaching a neighbor through this node is cheaper than any way found so far, record the better `g` and where it came from. When you pop the goal, walk the `came_from` chain backward and you have the optimal path.

The load-bearing word is **admissible**: `h` must never *overestimate* the true remaining cost. If it can't overestimate, then when the goal is popped no cheaper route can still be hiding in the open set — that's the optimality proof in one sentence. Straight-line distance is admissible for travel on a plane; for an 8-connected grid the tight version is **octile distance** (`max + (√2−1)·min` of the axis deltas). And here is the cleanest way to *understand* A*: set `h = 0`. The estimate is now uselessly pessimistic but trivially admissible, the open set is ordered by `g` alone, and the search expands in cost-order rings outward from the start — that's **Dijkstra's algorithm**. A* *is* Dijkstra plus a hunch about direction. The better the hunch, the fewer cells you touch; with `h = 0` you touch them all.

### The wind enters the graph

Here's the chapter's flourish, and it costs five lines: edge costs don't have to be distance. Yours will be *time* — distance divided by the speed a boat could make on that heading, which you already know how to compute, because `sail_power` (ch33) is exactly that curve. An edge heading upwind scores near the polar's floor and costs dearly; a beam-reach edge is cheap. Two consequences fall out for free. Routes visibly **curve downwind** around obstacles — given equal distances, the pathfinder picks the side of the island it can reach instead of beat. And admissibility survives: clamp the speed multiplier so cost-per-meter is never *less* than 1× (speed ≤ 1), and octile distance remains a guaranteed underestimate. (Floor the speed above zero, too — dead-upwind edges should be *expensive*, not infinite, because real boats tack; ch92 teaches them how.)

### The priority queue

The open set needs two fast operations: *insert* and *pop-minimum*. The textbook structure is a **binary min-heap**: a complete binary tree flattened into an array, parent of `i` at `(i−1)/2`, children at `2i+1, 2i+2`, with one invariant — every parent ≤ its children. Insert appends and **sifts up**; pop swaps the last element into the root and **sifts down**. Both O(log n), zero pointers, one `[dynamic]` array. You'll build it by hand — it's maybe 30 lines of pure Odin and one of those structures everyone should have written once — and then we'll note the stdlib's version.

### Smoothing: from staircase to sailing line

Grid paths are optimal *on the grid* but jagged in the world. **String pulling** fixes it: walk the path keeping an anchor at the start; greedily advance a probe as far as line-of-sight allows (sample the segment against `walkable` every half-cell); when sight breaks, emit the last visible cell as a waypoint and re-anchor there. The result is a handful of waypoints hugging the headlands — a course a sailor might actually draw on the ch79 chart.

## Odin notes

After you've built the heap, know that the stdlib has one: `core:container/priority_queue` provides `Priority_Queue(T)` with `init` (you supply `less` and `swap` — `pq.default_swap_proc(T)` covers the latter), `push`, `pop`, `peek`, `len`, `clear`, `destroy`, plus `fix`/`remove` for the decrease-key dance we sidestep below. Swapping your 30 lines for it is a five-minute exercise; building yours first is the point. Also: A* allocates nothing per-search here — all scratch arrays live in `Sea_Graph` and are reset by memset, which matters once ch93 runs searches every few seconds.

## Build

1. **The graph,** in `src/sea_graph.odin`. Grid plus per-search scratch, allocated once:

   ```odin
   Cell :: struct { x, z: i32 }

   Sea_Graph :: struct {
       origin:    glsl.vec2,   // world XZ of cell (0,0)'s corner
       cell_size: f32,         // ~24 m; coarser = faster + dumber
       w, h:      i32,
       walkable:  []bool,
       // per-search scratch, reused — A* allocates nothing per call
       g_cost:    []f32,
       came_from: []i32,       // flat index of predecessor, -1 = none
       state:     []u8,        // 0 unvisited, 1 open, 2 closed
       open:      [dynamic]Open_Node,
   }

   cell_index  :: proc(g: ^Sea_Graph, c: Cell) -> i32 { return c.z * g.w + c.x }
   cell_center :: proc(g: ^Sea_Graph, c: Cell) -> glsl.vec2 {
       return g.origin + glsl.vec2{f32(c.x) + 0.5, f32(c.z) + 0.5} * g.cell_size
   }
   ```

   `sea_graph_build` fills `walkable` from `terrain_height_at(cell_center) < SEA_LEVEL - 1.5`, then erodes once (a walkable cell with any unwalkable 8-neighbor becomes unwalkable — keep a copy, don't erode in place). Size the grid to your playable area; at 24 m cells a 6×6 km world is a 250×250 grid — 62,500 cells, trivial memory.

2. **The heap.** A min-heap of `Open_Node :: struct { idx: i32, f: f32 }` ordered by `f`:

   ```odin
   heap_push :: proc(h: ^[dynamic]Open_Node, n: Open_Node) {
       append(h, n)
       i := len(h) - 1
       for i > 0 {                              // sift up
           p := (i - 1) / 2
           if h[p].f <= h[i].f do break
           h[p], h[i] = h[i], h[p]
           i = p
       }
   }

   heap_pop :: proc(h: ^[dynamic]Open_Node) -> Open_Node {
       top := h[0]
       h[0] = h[len(h) - 1]
       pop(h)
       i := 0
       for {                                    // sift down
           l, r, m := 2*i + 1, 2*i + 2, i
           if l < len(h) && h[l].f < h[m].f do m = l
           if r < len(h) && h[r].f < h[m].f do m = r
           if m == i do break
           h[i], h[m] = h[m], h[i]
           i = m
       }
       return top
   }
   ```

   Test it standalone before wiring A*: push 1,000 random floats, pop them all, assert the sequence never decreases. Thirty seconds of paranoia, hours of saved debugging.

3. **Edge cost from the wind.** Time, not distance:

   ```odin
   edge_cost :: proc(g: ^Sea_Graph, from, to: Cell, w: Wind) -> f32 {
       dx, dz := f32(to.x - from.x), f32(to.z - from.z)
       base    := math.sqrt(dx*dx + dz*dz)               // 1 or SQRT_TWO
       heading := math.atan2(dx, dz)                     // +Z = 0, matching ch33
       rel     := angle_wrap(w.direction - heading - math.PI)
       speed   := clamp(sail_power(rel), 0.18, 1.0)      // floor: tacking isn't free, but possible
       return base / speed                               // ≥ base, so octile h stays admissible
   }
   ```

4. **`astar_find`.** Reset scratch (`mem.zero_slice` on `state`, `clear(&g.open)`), seed the start, then the loop:

   ```odin
   for len(g.open) > 0 {
       cur := heap_pop(&g.open)
       if g.state[cur.idx] == 2 do continue        // stale duplicate — see below
       g.state[cur.idx] = 2                        // closed
       if cur.idx == goal_idx do break
       for n_idx, step in graph_neighbors(g, cur.idx) {   // 8 dirs, walkable only
           if g.state[n_idx] == 2 do continue
           tentative := g.g_cost[cur.idx] + edge_cost(g, idx_cell(g, cur.idx), idx_cell(g, n_idx), w)
           if g.state[n_idx] == 0 || tentative < g.g_cost[n_idx] {
               g.g_cost[n_idx]    = tentative
               g.came_from[n_idx] = cur.idx
               g.state[n_idx]     = 1
               heap_push(&g.open, {n_idx, tentative + octile(g, n_idx, goal_idx)})
           }
       }
   }
   ```

   Note the duplicate trick: when a node's `g` improves we just push *again* rather than implementing decrease-key; the stale entry surfaces later with a worse `f` and the `state == 2` check discards it. Simpler, and for grid graphs measurably no slower. Reconstruct by walking `came_from` from the goal and reversing.

5. **String pulling.** `los_clear(g, a, b)` samples the segment `cell_center(a) → cell_center(b)` every `cell_size/2` against `walkable`; the pull is a dozen lines (anchor, probe forward, emit on break). Output `[dynamic]glsl.vec2` waypoints — this is what ch92's path-following consumes.

6. **The debug draw** — the payoff. Instanced flat quads (ch45 machinery) at cell centers, drawn just above the water in the forward pass: open = sea-green, closed = dim rust, path cells = gold, waypoints = white markers. Then make it *animate*: a debug mode that runs only N expansions of step 4 per frame (hoist the loop state into the graph; the scratch arrays already persist). Press F8: the search blooms across the bay, feels its way around the headland, and snaps into the golden line. Press F9 to toggle `h = 0` and watch Dijkstra flood the whole sound to find the same path. This visualization is mesmerizing for a reason — it's the algorithm's actual shape, and you will never again forget what the heuristic *buys*.

7. **Try the wind.** Route between two ports with an island between them, wind abeam. Flip the wind 180° (ch76's debug key): the route swaps sides of the island. That's the moment the sea gets lanes.

## Checkpoint

- A route between any two ports computes in well under a millisecond (time it — ch96 budgets it) and never touches land or shallows.
- The animated search shows A* clearly *directional* versus Dijkstra's flood; both end with identical path cost (print `g_cost[goal]` for each — admissibility's receipt).
- With a strong wind across the route, the chosen lane bends downwind around obstacles, and flipping the wind flips the lane.
- Smoothed waypoints number ~5–15 for a cross-archipelago route, hugging headlands without clipping them.

## Pitfalls

- **Paths hug walls and clip corners diagonally.** You allow a diagonal step when both adjacent orthogonal cells are blocked — the path slips between two land cells touching at a corner. Permit a diagonal only if both its orthogonal flanks are walkable.
- **Search explores almost everything even with the heuristic.** Your `h` is in different units than `g` — distance versus wind-time. Multiply octile distance by your *best possible* per-meter cost (1.0 with speed clamped ≤ 1) so the units match; an `h` that's accidentally tiny degenerates toward Dijkstra.
- **Occasional suboptimal paths.** The other direction: `h` overestimates. Classic causes — forgetting the √2 term (using Chebyshev), or multiplying `h` by an "aggression" factor > 1. The latter is a real technique (weighted A*), but it forfeits optimality; do it knowingly or not at all.
- **The heap returns wrong minimums.** Sift-down compared only one child, or your indices are off by one. Run the standalone heap test from step 2 before doubting A* — in practice it's the heap or the reset, almost never the algorithm.
- **Second search returns garbage.** Stale scratch: `state` not zeroed, or the open heap not cleared. If you forget `came_from`, paths from a previous search splice into this one — very entertaining, very wrong.
- **Routes are fine until low tide… er, until you regenerate terrain.** The graph is baked from `terrain_height_at`; rebuild it whenever the seed changes (hook it next to ch80's load path).

## Exercises

1. Add a **depth preference**: edges through cells barely deeper than the margin cost 1.3× more. Routes start respecting the fairway, and groundings in ch92's steering get rarer for free.
2. Port the open set to `core:container/priority_queue` (`init` with a `less` comparing `f`, `pq.default_swap_proc(Open_Node)`). Diff the two implementations' line counts and decide which you'd maintain.
3. Bidirectional flavor: run your animated debug mode from both endpoints simultaneously (two scratch sets) and stop when the frontiers meet. Compare cells-touched against single-ended A* — then delete it, because the next three chapters only need the simple one. (Knowing what you're *not* using is also knowledge.)
4. **Stretch:** time-varying lanes. Recompute a route's cost under the ch33 exercise-3 wandering wind every sim-minute; when the current route's cost exceeds the fresh optimum by 25%, replan. Log how often it triggers — this is exactly the replanning policy ch93's captains will adopt.

## Commit

`git commit -m "ch91: sea graph, binary heap, wind-aware A*, string pulling, search visualization"`

← [Chapter 84 — Finale: Flotilla](../part-12-shipping-a-game/ch84-finale-flotilla.md) *(Part 13's appendices sit between us in numbering, not in the journey)* · [Chapter 92 — Rules of the Road](ch92-rules-of-the-road.md) →
