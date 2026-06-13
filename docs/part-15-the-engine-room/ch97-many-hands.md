# Chapter 97 — Many Hands

*Part 15 — The Engine Room · Estimated time: 4h · learnopengl: no direct equivalent — this is engine material. Reference depth: [pkg.odin-lang.org/core/thread](https://pkg.odin-lang.org/core/thread/) and [core/sync](https://pkg.odin-lang.org/core/sync/).*

**What you'll see when done:** your gull and fish boids thinking on a second CPU core — the panel shows the boids line at ~0.0 ms on the main thread, the flocks still wheel and school, and a debug readout proves the worker is doing the math.

## Where we are

Welcome to the engine room. Saltwind *shipped* in Chapter 84 — single-threaded, every byte of it — and Part 14 made its sea crowded, still on one core. That was the right call for 96 chapters: a single thread means every bug is reproducible, every crash has one call stack, and you spent your complexity budget on water and light instead of on mutexes. Most indie games ship exactly this way.

But you now own a shipped game with real costs — worldgen hitches on regeneration, big textures stall loads, NPC simulation grows with the fleet — and this part retrofits engine infrastructure into it: threading (this chapter and next), streaming (99–100), and GPU-driven rendering (101–102). Retrofitting into working software is how this *actually happens* in the industry; greenfield engines are the exception. The discipline of this part: every chapter must leave the game looking identical and measuring faster.

One rule governs everything, so it goes first and loudest:

> **OpenGL is single-threaded. One context, one thread.** Every `gl.*` call in this entire part happens on the main thread. Worker threads compute *data* — vertices, pixels, decisions — and the main thread is the only one that ever talks to the driver. (Context sharing and multi-context GL exist; they are a famous tar pit and we will not step in it.) This single constraint shapes the architecture of all six chapters: **workers produce, main thread uploads.**

## Concepts

### A data race, demonstrated honestly

Run this before reading any theory. Two threads, one counter, no synchronization:

```odin
import "core:thread"
import "core:fmt"

race_counter: int

race_demo :: proc() {
	bump :: proc(_: rawptr) {
		for _ in 0 ..< 1_000_000 do race_counter += 1
	}
	t1 := thread.create_and_start_with_data(nil, bump)
	t2 := thread.create_and_start_with_data(nil, bump)
	thread.join(t1); thread.join(t2)
	thread.destroy(t1); thread.destroy(t2)
	fmt.println("expected 2000000, got", race_counter)
}
```

On any real machine this prints something like `got 1268473` — wrong, and *differently* wrong each run. `race_counter += 1` is three operations (load, add, store), and two cores interleave them freely: both load 5, both store 6, an increment evaporates. This is a **data race**: two threads access the same memory, at least one writes, nothing orders them. In Odin, as in C, a data race is not "you get a stale value" — it is undefined behavior. The compiler is allowed to assume it doesn't happen and optimize accordingly (hoisting the variable into a register for the whole loop, for instance — try `-o:speed` and watch the result get *more* wrong).

### The mental model: happens-before

Forget "which line runs first." Between threads there is no global order of operations — each core has store buffers and caches, the compiler reorders, and *the only ordering that exists is the ordering you create*. Synchronization primitives (mutexes, atomics, thread join) create **happens-before** edges: everything thread A did before releasing a mutex is visible to thread B after it acquires the same mutex. Everything a thread did before you `join` it is visible after the join returns. No edge — no guarantee, regardless of how the timing "obviously" works out on your machine.

This is also why **printf debugging lies** in threaded code: `fmt.println` takes internal locks and does syscalls, which both *slows the racing thread* and *injects accidental happens-before edges*. Add prints, the race hides; remove them, it returns. Heisenbug is the technical term. Trust the model and the tools (a counter test like the one above, asserts on invariants), not the absence of symptoms.

### The toolbox, verified against current Odin

- **`core:thread`** — `thread.create(proc(^Thread))` makes a suspended thread; stash your payload in `t.data` (a `rawptr`), then `thread.start(t)`, later `thread.join(t)` and `thread.destroy(t)` (destroy joins and frees). The convenience family `thread.create_and_start`, `create_and_start_with_data` (a `rawptr` + `proc(rawptr)`), and `create_and_start_with_poly_data` (any typed value + `proc($T)`) skips the two-step dance. `thread.IS_SUPPORTED` guards exotic targets.
- **`core:sync`** — `sync.Mutex` (zero value = unlocked, never copy after use): `sync.mutex_lock`/`sync.mutex_unlock`, or the lovely `sync.guard(&m)` which locks and *defers* the unlock — `if sync.guard(&m) { …critical section… }`. `sync.Cond` with `sync.cond_wait(&c, &m)` / `sync.cond_signal` / `sync.cond_broadcast` (Chapter 98 builds the job queue on these). Also there when you want them: `sync.Sema`, `sync.Wait_Group`, `sync.Barrier`.
- **Atomics** also live in **`core:sync`** — `sync.atomic_add`, `sync.atomic_load`, `sync.atomic_store`, `sync.atomic_compare_exchange_strong` (they're re-exports of `base:intrinsics` atomics, so you'll see both spellings in the wild). The plain forms are sequentially consistent; `_explicit` variants take a `sync.Atomic_Memory_Order` (`.Acquire`, `.Release`, …). Rule for this course: **use the plain forms.** Relaxed orderings are a sharp tool for a measured need we do not have.

The fix for the race, for completeness: `sync.atomic_add(&race_counter, 1)`. Run it — exactly 2,000,000, every time, at about a tenth of the unsynchronized speed per-op. Atomics are correct, not free.

## Odin notes

- **The `context` crosses with you, mostly.** By default a `core:thread` thread proc receives the same context `main` got — same `context.allocator` (Odin's default heap allocator is thread-safe) — **but a fresh per-thread temp allocator**, cleaned up automatically when the thread dies. If you pass an explicit `init_context`, that automatic cleanup is *off* and you must call `runtime.default_temp_allocator_destroy()` in the thread proc yourself, or leak. Simplest policy: don't pass `init_context`.
- **The temp-allocator trap:** `context.temp_allocator` memory belongs to *one thread*. Never return a `fmt.tprintf` string or temp-allocated slice from a worker to the main thread — main's `free_all(context.temp_allocator)` (running since Chapter 10) won't free it, and the worker's cleanup may free it *while main reads it*. Cross-thread data gets `make`/`new` on the heap, with clear ownership of who deletes it.
- **Your tracking allocator is not thread-safe.** If you wired `mem.Tracking_Allocator` into debug builds back in the early chapters, it guards nothing internally. Either give workers the plain heap allocator or accept that leak reports get fuzzy in threaded builds.
- `loc := #caller_location` defaults and `fmt` printing are fine on any thread — `fmt` locks internally. Fine for logging; see "printf lies" above for debugging.

## Build

The payoff target: Chapter 72's boids (gulls + fish, spatial hashing) move to a worker thread with **double-buffered results**. The pattern — worker writes one buffer while main reads the other — is the simplest correct way to share bulk results, and it returns in every remaining chapter.

1. **Run the race.** Type in the `race_demo` above, run it three times in debug, then with `-o:speed`. Write the three results in a comment above it. Then change `race_counter += 1` to `sync.atomic_add(&race_counter, 1)` and run again. Keep this file (`src/race_demo.odin`, called behind a debug flag) — it's your team's threading orientation in 20 lines.

2. **The mailbox.** In `src/boids_worker.odin`:

   ```odin
   Boids_Result :: struct {
   	gull_mats: []glsl.mat4, // sized once at init
   	fish_mats: []glsl.mat4,
   	sim_time:  f64,         // which tick this snapshot represents
   }

   Boids_Worker :: struct {
   	thread:    ^thread.Thread,
   	mutex:     sync.Mutex,
   	cond:      sync.Cond,
   	inbox:     Boids_Inputs,  // boat pos, wind, sim_time target — written by main
   	results:   [2]Boids_Result,
   	front:     int,           // main reads results[front]
   	fresh:     bool,          // back buffer has a newer snapshot
   	running:   bool,
   	work_due:  bool,
   }
   ```

3. **The worker proc.** It owns the *entire* boids state (positions, velocities, the spatial hash) — no other thread ever touches it. Per iteration: wait for work, copy the inbox out under the lock, simulate *outside* the lock (this is the whole point — the expensive part holds no lock), then publish into the back buffer under the lock:

   ```odin
   boids_worker_proc :: proc(raw: rawptr) {
   	w := (^Boids_Worker)(raw)
   	for {
   		sync.mutex_lock(&w.mutex)
   		for !w.work_due && w.running do sync.cond_wait(&w.cond, &w.mutex)
   		if !w.running { sync.mutex_unlock(&w.mutex); return }
   		inputs := w.inbox // copy out
   		w.work_due = false
   		sync.mutex_unlock(&w.mutex)

   		boids_step(&local_state, inputs, FIXED_DT) // heavy; NO lock held

   		sync.mutex_lock(&w.mutex)
   		back := 1 - w.front
   		boids_write_matrices(&local_state, &w.results[back])
   		w.fresh = true
   		sync.mutex_unlock(&w.mutex)
   	}
   }
   ```

   Note the `for !w.work_due … cond_wait` *loop* — condition variables can wake spuriously; the loop re-check is mandatory, not style (the `core:sync` docs say exactly this).

4. **Main-thread integration.** In the fixed update (the Chapter 10 loop): write `inbox` (boat position, wind, target sim_time), set `work_due = true`, `sync.cond_signal(&w.cond)` — all under the mutex, a few microseconds. At render time: under the mutex, if `fresh`, flip `front` and clear the flag; then upload `results[front]` matrices with the Chapter 45 `BufferSubData` path. Delete the old synchronous `boids_step` call from the main update.

5. **Start and stop.** At init: `w.running = true; w.thread = thread.create_and_start_with_data(&w, boids_worker_proc)`. At shutdown: under the mutex set `running = false`, `sync.cond_broadcast`, then `thread.join(w.thread)` and `thread.destroy(w.thread)` — *before* you destroy any state the worker reads. An unjoined worker touching freed memory is a shutdown crash that only happens on Tuesdays.

6. **Prove it.** Add to the ch49 panel: boids CPU ms on main (should read ~0.00 — it's a buffer flip), plus a counter the worker increments per step (read with `sync.atomic_load`). Watch flocks: identical behavior, one frame of extra latency (the snapshot you draw is the one finished last frame). For gulls, invisible; that latency tolerance is *why* boids were the right first candidate.

## Checkpoint

The flocks live on another core and nothing on screen betrays it.

- Race demo: wrong without atomics (three different wrong answers recorded), exactly 2,000,000 with — in both debug and `-o:speed`.
- Boids panel line on main thread ≈ 0.0 ms; the worker's step counter climbs; gulls bank and fish school as in Chapter 72.
- Pause (P) freezes the flocks: pause stops feeding `work_due`, and the worker waits silently — zero CPU when idle (check Task Manager / `top`).
- Quit cleanly ten times in a row: no crash, no hang (join order right), no leak report change.
- Grep your diff for `gl.`: zero GL calls anywhere in `boids_worker.odin`.

## Pitfalls

- **Any `gl.*` call on a worker.** Crashes if you're lucky; silently corrupts driver state if you're not. Workers make data; main makes GL calls. Recite it.
- **`if` instead of `for` around `cond_wait`.** Spurious wakeups are real and permitted; the predicate loop is part of the condvar contract. The bug presents as once-a-session weirdness.
- **Returning temp-allocated memory from a worker.** `tprintf`/temp slices die with the wrong thread's `free_all`. Heap-allocate anything that crosses; decide who frees it and write it in a comment.
- **Sharing `[dynamic]` arrays or maps across threads.** `append` can reallocate — the other thread now reads freed memory. Either fixed-size buffers (our mailbox) or full ownership transfer.
- **Forgetting the join at shutdown.** The worker outlives the data it reads; the crash is in `boids_step` with a garbage `this` and you'll blame the boids. Join workers before tearing down state, always.
- **"It works on my machine."** With races that sentence is a tautology — it works until the interleaving changes. The absence of a crash is not evidence of correctness; only the model (who owns what, where the happens-before edges are) is.

## Exercises

1. Make the race demo's wrongness *visible*: run the unsynchronized version 50 times in a loop and print min/max/mean of the result. The spread is the scheduler's fingerprint, different on every machine.
2. Add a `sync.Mutex` version of the counter alongside the atomic one and time all three (single-threaded baseline, mutex, atomic) with `time.tick_now`. Write the ratios in the comment — your intuition for sync costs starts here.
3. Move Chapter 94's economy drift tick (if you built Part 14) onto the same pattern: inputs in, double-buffered price table out. It runs once per game-minute — latency tolerance doesn't get better than that.
4. **Stretch:** instrument the mailbox with `sync.atomic_add` counters for "snapshots produced" vs "snapshots consumed". If produced outruns consumed by more than 1, the worker is wasting work — add backpressure (only signal `work_due` when the previous snapshot has been consumed) and verify the counters lock to ±1.

## Commit

```
git commit -m "ch97: core:thread + core:sync, race demo, boids on a worker with double-buffered results"
```

← [Chapter 96 — MILESTONE: A Crowded Sea](../part-14-a-crowded-sea/ch96-milestone-a-crowded-sea.md) · [Chapter 98 — The Bosun's Crew](ch98-the-bosuns-crew.md) →
