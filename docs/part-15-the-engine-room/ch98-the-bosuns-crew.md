# Chapter 98 — The Bosun's Crew

*Part 15 — The Engine Room · Estimated time: 4–5h · learnopengl: no direct equivalent — this is engine material. The architecture echoes every job system since the GDC classic "Parallelizing the Naughty Dog Engine" (2015) — worth watching after you've built your own.*

**What you'll see when done:** press R to regenerate the world and watch the worldgen number in the panel drop from hundreds of milliseconds to a fraction of them — every chunk's fBm computed on a different core, every vertex identical to the single-threaded build.

## Where we are

Chapter 97 gave one worker one standing job. That doesn't scale: streaming (ch99), chunk generation (ch100), and culling prep all want background compute, and spawning a thread per task is wasteful (thread creation costs ~tens of microseconds and unbounded threads thrash the scheduler). The standard answer is a **job system**: a fixed pool of workers, sized to the machine, pulling small tasks from a shared queue. Every engine has one; today you build yours — small enough to fit in your head, real enough to power the rest of the part.

## Concepts

### Size the crew to the ship

How many workers? One per *logical core*, minus one for the main thread, is the classic default. Odin tells you the count in `core:sys/info`:

```odin
import si "core:sys/info"

physical, logical, ok := si.cpu_core_count()
worker_count := max(1, (logical if ok else 4) - 1)
```

(Verified at [pkg.odin-lang.org/core/sys/info](https://pkg.odin-lang.org/core/sys/info/) — `cpu_core_count` returns `(physical, logical, ok)`. `core:os` also exposes a `processor_core_count` on desktop targets; either is fine, we use the one that's documented cross-platform.) On a 8c/16t machine you get 15 workers; on a dual-core laptop, 1. Both are correct: the system *degrades* instead of assuming.

### A queue, a lock, a condvar — and why not lock-free

The queue is the heart, and we build it with the bluntest correct tools: a mutex around a `[dynamic]` array, a condition variable so idle workers sleep instead of spin. You will read that "real" engines use lock-free queues, work stealing, chase-lev deques. They do — and those structures are *legendarily* hard to get right (the ABA problem, memory reclamation, platform memory models), and their payoff appears at hundreds of thousands of jobs per frame. Our load is dozens to hundreds of jobs per *event*. A mutex held for nanoseconds while popping a pointer is not your bottleneck and never will be in Saltwind. Build the boring one; file lock-free under further reading (Dmitry Vyukov's queue writeups, if the itch ever becomes real) — and notice that `core:thread` ships a ready-made `thread.Pool` built exactly this way. We write our own because the next four chapters need us to *understand* it, not just call it.

### Jobs, counters, dependencies

A job is a proc, a data pointer, and a **completion counter** to decrement when done:

```
 submit 64 jobs ──> counter = 64
 workers chew   ──> each finished job: atomic_add(counter, -1)
 jobs_wait(&counter) returns when counter == 0
```

Counters are the entire dependency story: "B after all of A" = submit A's jobs against counter₁, `jobs_wait(&counter₁)`, submit B. No graphs, no futures — and good enough for shipping engines far bigger than ours. The one subtlety: while the main thread waits, it shouldn't *sleep* — it should pull jobs and help. That turns wait-time into work-time and, more importantly, makes `jobs_wait` deadlock-proof even with one worker.

### Parallel-for: the shape of almost everything

Most game parallelism is "do this for N things." A helper that chops a range into chunks and submits each as a job covers terrain generation today, chunk streaming in ch100, and anything else shaped like a loop. Chunk granularity matters: one job per *item* drowns in queue overhead; one job per *core* can't load-balance. A few jobs per worker is the sweet spot — we default to `count / (workers * 4)`.

### Determinism survives, if the seeds do

Chapter 21 made worldgen a pure function of `(seed, x, z)`; Chapter 45 derived per-island, per-species scatter seeds. That discipline now pays its biggest dividend: jobs finish in *scheduler order*, which differs every run — but since each chunk's result depends only on its own coordinates and the world seed, never on shared mutable state or call order, the assembled world is bit-identical no matter which worker built which chunk in which order. The rule for every job you will ever write into this system: **a job reads its inputs, writes only its own output slot, and consumes no shared random stream.** (Glenn Fiedler's determinism writing at [gafferongames.com](https://gafferongames.com) is the deeper well on this, as ever.)

## Odin notes

- The counter is a plain `int` touched only through `sync.atomic_add` / `sync.atomic_load`. Don't mix atomic and non-atomic access to the same variable — that's the ch97 race again with extra steps.
- Job data lifetime: the queue stores a `rawptr`; the pointee must outlive the job. For parallel-for we allocate one slice of per-job argument structs up front and pass `&args[i]` — alive until after the wait, freed once, no per-job allocations.
- Worker thread procs get a usable default context (heap allocator thread-safe, per-thread temp allocator auto-cleaned — ch97 notes apply). If a job uses `context.temp_allocator`, its garbage accumulates until that *worker* dies; have long-running workers `free_all(context.temp_allocator)` after each job. One line, saves a slow leak.

## Build

1. **The types**, in `src/jobs.odin`:

   ```odin
   Job_Proc :: proc(data: rawptr)

   Job :: struct {
   	procedure: Job_Proc,
   	data:      rawptr,
   	counter:   ^int, // may be nil for fire-and-forget
   }

   Job_System :: struct {
   	queue:   [dynamic]Job,    // guarded by mutex
   	mutex:   sync.Mutex,
   	cond:    sync.Cond,
   	threads: []^thread.Thread,
   	running: bool,
   }
   ```

2. **Init and the worker loop.** `jobs_init(js, worker_count)` sets `running`, then creates workers with `thread.create_and_start_with_data(js, jobs_worker_proc)`. The worker is ch97's pattern, generalized:

   ```odin
   jobs_worker_proc :: proc(raw: rawptr) {
   	js := (^Job_System)(raw)
   	for {
   		sync.mutex_lock(&js.mutex)
   		for len(js.queue) == 0 && js.running do sync.cond_wait(&js.cond, &js.mutex)
   		if !js.running && len(js.queue) == 0 { sync.mutex_unlock(&js.mutex); return }
   		job := pop(&js.queue)
   		sync.mutex_unlock(&js.mutex)

   		job.procedure(job.data)
   		if job.counter != nil do sync.atomic_add(job.counter, -1)
   		free_all(context.temp_allocator)
   	}
   }
   ```

3. **Submit and wait:**

   ```odin
   jobs_submit :: proc(js: ^Job_System, procedure: Job_Proc, data: rawptr, counter: ^int) {
   	if counter != nil do sync.atomic_add(counter, 1) // BEFORE it's visible to workers
   	sync.mutex_lock(&js.mutex)
   	append(&js.queue, Job{procedure, data, counter})
   	sync.mutex_unlock(&js.mutex)
   	sync.cond_signal(&js.cond)
   }

   jobs_wait :: proc(js: ^Job_System, counter: ^int) {
   	for sync.atomic_load(counter) > 0 {
   		// help instead of sleeping — also makes waiting deadlock-proof
   		sync.mutex_lock(&js.mutex)
   		job, got := pop_safe(&js.queue)
   		sync.mutex_unlock(&js.mutex)
   		if got {
   			job.procedure(job.data)
   			if job.counter != nil do sync.atomic_add(job.counter, -1)
   		} else {
   			thread.yield()
   		}
   	}
   }
   ```

   The increment-before-enqueue order in `jobs_submit` is load-bearing: enqueue first and a fast worker could finish and decrement *before* your increment, letting a concurrent `jobs_wait` see zero and return early.

4. **Parallel-for**, the helper you'll actually call:

   ```odin
   Range_Proc :: proc(lo, hi: int, user: rawptr)

   jobs_parallel_for :: proc(js: ^Job_System, count: int, user: rawptr, fn: Range_Proc) {
   	Args :: struct { lo, hi: int, user: rawptr, fn: Range_Proc }
   	chunk := max(1, count / (len(js.threads) * 4))
   	n := (count + chunk - 1) / chunk
   	args := make([]Args, n, context.temp_allocator)
   	counter: int
   	for i in 0 ..< n {
   		args[i] = {i * chunk, min((i + 1) * chunk, count), user, fn}
   		jobs_submit(js, proc(raw: rawptr) {
   			a := (^Args)(raw)
   			a.fn(a.lo, a.hi, a.user)
   		}, &args[i], &counter)
   	}
   	jobs_wait(js, &counter)
   }
   ```

   (Temp allocator is safe *here* because we wait before returning — the args never outlive the caller's frame. A fire-and-forget variant must heap-allocate; ch99 will.)

5. **Shutdown.** `jobs_destroy`: lock, `running = false`, unlock, `sync.cond_broadcast(&js.cond)`, then `thread.join` + `thread.destroy` each worker. Call it before any world teardown in your existing shutdown order.

6. **The first real win: parallel terrain regeneration.** Find your `terrain_build_chunks` (ch23). The per-chunk vertex build — fBm sampling via `core:math/noise` (pure, stateless: safe), normals, AABB tracking — moves into a `Range_Proc` over the chunk array, each chunk writing into its own pre-allocated vertex/index slot. The `mesh_upload` calls (VBO/EBO creation — **GL!**) stay in a second, sequential loop on main:

   ```odin
   // 1) CPU: all cores
   jobs_parallel_for(&game.jobs, len(t.chunks), t, proc(lo, hi: int, user: rawptr) {
   	t := (^Terrain)(user)
   	for i in lo ..< hi do terrain_build_chunk_vertices(t, i) // writes chunks[i] only
   })
   // 2) GL: main thread only
   for &chunk in t.chunks do mesh_upload(&chunk.mesh)
   ```

   This split — **generate on workers, upload on main** — is the load-bearing pattern of the whole part. Say it out loud once.

7. **Measure.** Bracket regeneration with `time.tick_now` (the ch49 CPU timers): press R, note total ms before and after, and the split between the parallel build and the sequential upload. On a 6-core machine expect the build portion to drop ~4–5× (not 6× — memory bandwidth and the sequential upload don't parallelize). Put both numbers in the commit message.

## Checkpoint

The crew works; the world doesn't notice.

- Press R with the same seed: the world is *pixel-identical* to the single-threaded build (toggle a `JOBS_DISABLED` debug path that runs the old loop and screenshot-diff if you're suspicious — you should be).
- Regen time in the panel: build portion dropped roughly by your core count's order; total dominated now by mesh upload.
- Submit 10,000 trivial jobs in a test (`counter` only): completes, counter hits exactly 0, no hang — run it 20 times.
- With the game idle, workers consume ~0% CPU (condvar sleeping, not spinning).
- Shutdown is clean with jobs mid-flight at quit (the `running && len==0` exit condition drains the queue first).

## Pitfalls

- **GL calls inside a job.** The pattern exists to prevent exactly this. If a job needs a texture or buffer, it produces the *bytes*; main does the `gl.*`. (Chapter 99 formalizes this with an upload queue.)
- **Jobs writing shared output.** Two chunks appending to one `[dynamic]` vertex array = ch97's race, in production. Pre-size outputs; each job owns its slot by index.
- **Counter incremented inside the job queue's lock... after enqueue.** The increment must happen-before any worker can decrement; submit-side increment first is the simplest correct order (step 3).
- **Waiting by sleeping.** A `jobs_wait` that just spins or sleeps deadlocks the single-worker laptop case when jobs submit jobs (the worker is busy; nobody runs the children). Help-while-waiting fixes correctness *and* performance.
- **Per-job heap allocations.** A thousand `new(Args)` per regen turns the allocator into the new bottleneck and fragments the heap. Batch the args slice (step 4) or pool them.
- **A shared `rand` stream inside jobs.** `rand.reset(seed)` then parallel scatter = run-order-dependent forests (and ch45's checkpoint catches it). Derive a seed per chunk/island/species; each job builds its own local generator or pure hash. Chapter 21's discipline is the dependency here — if your worldgen ever reads global mutable state, fix that first.

## Exercises

1. Add a panel line: jobs submitted / completed this frame, current queue depth, and per-worker "jobs done" counters. Watch load balancing happen (or fail to — try chunk = `count/workers` exactly and watch one worker finish late).
2. Parallelize the ch45 vegetation scatter with one job per (island, species) pair, each with its derived seed. Verify the determinism checkpoint from ch45 still passes — same seed, same forests, regardless of worker count. Try `worker_count = 1` and `= 15`.
3. Build `jobs_wait_any` returning when the counter drops *below* a threshold, and use it to overlap: start chunk-vertex jobs, and begin uploading finished chunks while later ones still compute (you'll need a per-chunk done flag set with `sync.atomic_store`). Measure the total-regen improvement.
4. **Stretch:** replace your queue with `thread.Pool` (`pool_init`/`pool_start`/`pool_add_task`/`pool_finish`) behind the same `jobs_*` interface and compare: behavior, code deleted, any timing change. Knowing when *not* to keep your own infrastructure is also an engine skill.

## Commit

```
git commit -m "ch98: job system (workers, mutex+condvar queue, counters, parallel-for); parallel terrain regen"
```

← [Chapter 97 — Many Hands](ch97-many-hands.md) · [Chapter 99 — Cargo Below Decks](ch99-cargo-below-decks.md) →
