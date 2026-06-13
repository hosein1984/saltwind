# Chapter 65 — Floating on Data

*Part 10 — The True Ocean · Estimated time: 5h · learnopengl: no direct equivalent — relevant API reading: [docs.gl glFenceSync](https://docs.gl/gl4/glFenceSync), [glMapBufferRange](https://docs.gl/gl4/glMapBufferRange)*

**What you'll see when done:** the boat — and a scatter of drifting cargo crates — riding the FFT swell in perfect contact again, pitching over crests that no closed-form formula can describe.

## Where we are

Since Chapter 63 you've been living with a lie: the sea on screen is the FFT, but `ocean_height_at` still evaluates the retired Gerstner table, so the boat floats on a ghost ocean. Sail into a big FFT swell and watch the hull clip through it. The Chapter 28 problem is back, harder: the wave math no longer *has* a closed form the CPU can mirror — the surface exists only as the output of 18 GPU dispatches. Today we choose how the CPU learns the height of the water, and the choice is a genuinely interesting engineering decision — so we'll make it honestly, with the alternatives on the table.

## Concepts

### Three ways to know where the water is

**(a) CPU mirror: run a small FFT on the CPU.** The sea is deterministic: same `h̃₀`, same dispersion, same time → same surface. So the CPU can compute its *own* low-resolution version of the same ocean — say 64×64 instead of 256×256 — using the same spectrum data for the lowest 64×64 frequencies. Buoyancy only cares about waves longer than the hull; the missing top frequencies are texture, not tonnage.

- ✅ Deterministic, zero latency, zero GPU traffic, works with fixed-timestep physics, works when the window is minimized.
- ❌ You maintain a second implementation (mitigated: you'll *validate* it against the GPU, and you already wrote the reference DFT).
- Cost: a 64² complex 2D FFT × 3 fields ≈ tens of microseconds per tick. Free.

**(b) GPU readback, done properly: a PBO ring.** Ask the GPU to copy the displacement texture into a **Pixel Buffer Object**, let the copy run asynchronously, and map the buffer *a few frames later* when it's certainly done — fences tell you. 

- ✅ One implementation; CPU reads the *exact* rendered surface, cascades and all.
- ❌ The data is 2+ frames stale (at 8 m/s in a storm sea, ~0.3 m of wave movement — visible hull float), it couples physics to render rate, and one accidental early map = a full pipeline stall.

**(c) `glReadPixels`/`GetTexImage` straight into CPU memory, every frame.** The trap. A synchronous readback forces the CPU to wait for *every command in flight* before the copy returns — you serialize the entire pipeline and your frame time doubles or worse. It's the single most common "why is my game 20 fps" in GPU-simulation projects. Never per-frame; only in debug paths (your Chapter 63 self-test is exactly the legitimate use: once, at startup).

We implement **(a)**, and also build **(b)** as a working debug path — partly because the API (PBOs, fences) is exactly what you need for Chapter 84's screenshot/trailer capture anyway, and partly because knowing *why* (a) wins requires having held (b) in your hands.

### The payoff of an old discipline

Chapter 28 made one rule: all wave queries go through `ocean_height_at(o, p, t)`. Chapter 32's buoyancy, the buoys, every floating crate — none of them know what an ocean is; they know that function. Today that function gets its third backend (sine → Gerstner → FFT mirror) and **none of the callers change**. Not a line of Chapter 32 is touched. When people say "program to an interface," this chapter is what they're hoping for.

### The mirror's anatomy

Per physics tick: evolve the central 64×64 block of the spectrum to time `t` (same `h̃(k,t)` formula, same dispersion — CPU edition), run three 2D IFFTs (height, Dx, Dz), store three 64×64 `f32` grids. A height query then does what Chapter 28's did: undo the horizontal choppy displacement by fixed-point iteration, then bilinearly sample height — all wrapped toroidally, because the tile repeats.

```
GPU: 256×256 spectrum ──► 256² maps ──► what you SEE
            │ same h̃₀, same ω(k), same t
CPU:  central 64×64   ──►  64² grids ──► what you FLOAT ON
       (the swell — all waves longer than ~4 m)
```

The two agree on every wave the CPU keeps, exactly — same amplitudes, same phases, forever, because both sides are deterministic functions of the same seed and clock. The CPU just low-passes the chop. A hull doesn't respond to 2 m chop anyway; if anything the filtered surface gives *better*-feeling boat motion.

## Odin notes

The radix-2 FFT below uses builtin `complex64` (`complex(re, im)`, `real()`, `imag()`, arithmetic built in). One idiom worth naming: Odin's multiple assignment makes the butterfly swap clean — `a[i], a[j] = a[j], a[i]` — and `bits.log2(u32)` from `core:math/bits` gives you integer stage counts without float `log2` truncation worries.

## Build

1. **Upgrade the reference DFT to a real FFT.** In `src/ocean_fft_cpu.odin`, the iterative radix-2 (this is the textbook form — keep it; you'll reuse it for audio, for convolution, forever):

   ```odin
   fft_1d :: proc(a: []complex64) {          // in-place, INVERSE convention (+i)
       n := len(a)
       j := 0                                 // bit-reversal permutation
       for i in 1 ..< n {
           bit := n >> 1
           for ; j & bit != 0; bit >>= 1 { j &~= bit }
           j |= bit
           if i < j { a[i], a[j] = a[j], a[i] }
       }
       for m := 2; m <= n; m <<= 1 {          // stages: m = butterfly block size
           wm := complex(math.cos(2*math.PI/f32(m)), math.sin(2*math.PI/f32(m)))
           for k := 0; k < n; k += m {
               w := complex64(1)
               for l in 0 ..< m/2 {
                   t := w * a[k + l + m/2]
                   a[k + l + m/2] = a[k + l] - t
                   a[k + l]       = a[k + l] + t
                   w *= wm
               }
           }
       }
   }
   ```

   `fft_2d` is "fft_1d every row, transpose-or-stride, fft_1d every column" — write it with a strided copy into a scratch row, ~15 lines. **Validate immediately** against `dft_2d_reference` from Chapter 63 (8×8, print max error, assert < 1e-3). You wrote the harness; use it.

2. **Build the mirror state and update.** The mirror keeps its own copy of the central spectrum block, sliced from the Chapter 62/64 CPU-side arrays (noise + Phillips at current weather — recompute the 64² block's `h̃₀` whenever Weather's wind params change, mirroring `ocean_spectrum.comp`):

   ```odin
   Ocean_Mirror :: struct {
       n:         int,            // 64
       tile_size: f32,            // SAME L as the GPU — 256.0
       h0:        [][4]f32,       // central block: h̃0(k).xy, conj h̃0(−k).zw
       h, dx, dz: []f32,          // the output grids, n×n
       spec:      []complex64,    // scratch
   }

   mirror_update :: proc(mir: ^Ocean_Mirror, t: f32, choppy: f32) {
       n := mir.n
       for field in 0 ..< 3 {                       // h, Dx, Dz
           for zi in 0 ..< n do for xi in 0 ..< n {
               k    := k_for_texel(xi, zi, n, mir.tile_size)
               h    := evolve(mir.h0[zi*n+xi], k, t) // same formula as ocean_evolve.comp
               mir.spec[zi*n+xi] = field == 0 ? h : choppy_component(h, k, field)
           }
           fft_2d(mir.spec)
           out := field == 0 ? mir.h : field == 1 ? mir.dx : mir.dz
           for i in 0 ..< n*n {
               s := ((i%n + i/n) & 1) == 0 ? f32(1) : f32(-1)   // the perm sign — CPU too!
               out[i] = real(mir.spec[i]) * s * (field == 0 ? 1.0 : choppy)
           }
       }
   }
   ```

   `k_for_texel` here maps the *64*-grid index to `2π(idx − 32)/L` — the same physical frequencies the GPU's central block carries (`dm = idx − 32` corresponds to GPU texel `dm + 128`). Slice `h0` accordingly: GPU texel `(dm+128, dn+128) → mirror texel (dm+32, dn+32)`.

3. **Re-back `ocean_height_at` — signature untouched:**

   ```odin
   ocean_height_at :: proc(o: Ocean, p: glsl.vec2, t: f32) -> f32 {
       s := p                                   // ch28's fixed-point inversion, verbatim
       for _ in 0 ..< 3 {
           d := mirror_displace(o.mirror, s)    // bilinear, toroidal wrap, returns (dx,h,dz)
           s = p - glsl.vec2{d.x, d.z}
       }
       return mirror_displace(o.mirror, s).y
   }
   ```

   `mirror_displace` is bilinear filtering by hand over the wrapped grids (`uv = p / tile_size`, frac/floor, four taps, lerp — ~15 lines). Call `mirror_update` once per fixed timestep with the same wrapped sim clock the GPU gets. Chapter 32's buoyancy, the Chapter 19 buoys, all of it: **runs unmodified.** Run the Chapter 28 debug cubes: they surf the FFT sea. Take a second to enjoy that.

4. **Build the readback path anyway (debug-gated).** A ring of 3 PBOs + fences around the displacement texture:

   ```odin
   // frame i: kick an async copy into pbo[i % 3]
   gl.BindBuffer(gl.PIXEL_PACK_BUFFER, rb.pbo[i % 3])
   gl.BindTexture(gl.TEXTURE_2D, ocean.maps.displacement)
   gl.GetTexImage(gl.TEXTURE_2D, 0, gl.RGBA, gl.FLOAT, nil)   // nil = "into the PBO", async
   rb.fence[i % 3] = gl.FenceSync(gl.SYNC_GPU_COMMANDS_COMPLETE, 0)

   // frame i (same frame): harvest the copy kicked at frame i−2
   j := (i + 1) % 3
   if rb.fence[j] != nil {
       status := gl.ClientWaitSync(rb.fence[j], 0, 0)          // timeout 0: just ask
       if status == gl.ALREADY_SIGNALED || status == gl.CONDITION_SATISFIED {
           gl.BindBuffer(gl.PIXEL_PACK_BUFFER, rb.pbo[j])
           ptr := gl.MapBufferRange(gl.PIXEL_PACK_BUFFER, 0, rb.size, gl.MAP_READ_BIT)
           // ... copy out, compare against the mirror ...
           gl.UnmapBuffer(gl.PIXEL_PACK_BUFFER)
           gl.DeleteSync(rb.fence[j]); rb.fence[j] = nil
       }
   }
   ```

   With `GetTexImage`'s data pointer `nil` and a `PIXEL_PACK_BUFFER` bound, the "pointer" is an offset into the PBO and the copy is queued, not executed — that's the entire trick. The fence is a marker in the command stream; `ClientWaitSync` with timeout 0 is a poll. Two-frame latency is structural: kick at frame i, harvest at i+2.

5. **Use (b) to validate (a).** Debug overlay: each frame, compare `ocean_height_at(p)` against the readback texture bilinearly sampled at the same `p` for the boat's position. Expect agreement within the chop the mirror filters out — typically < 15 cm at moderate weather, with the readback value *jittering ahead/behind* by its 2-frame latency as the boat moves. Print both. That number is the honest answer to "did the mirror really match?" — and watching the latency wobble is the visceral argument for why (a) drives the physics.

6. **Drifting cargo: the stress test.** A `Crate` array (you have the mesh since Chapter 8 — full circle): spawn 20 around the start island, each with the Chapter 32 buoyancy applied at its four corners plus a slow wind-drift force and a yaw torque from wave slope. Sail through the field in Storm weather: every crate pitches over every swell independently. If something explodes (a crate launched to orbit), your buoyancy spring constants meet the FFT sea's steeper accelerations — clamp the spring force and add velocity damping; note it for Chapter 68's integration sweep.

## Checkpoint

The boat rides the visible sea again — bow lifting into each swell at the moment the swell arrives — and a debris field of crates bobs convincingly around the harbor.

- Debug cubes glued to the surface across Calm and Storm presets (weather changes reshape the mirror too — step 2 recomputes its `h̃₀`).
- Mirror-vs-readback delta on the overlay: small, chop-sized, *unbiased* (centered on zero — a constant offset means a perm sign or `k` mapping bug).
- Minimize-then-restore the window: physics never hiccuped (the mirror doesn't need the GPU).
- Frame time unchanged with the readback path *disabled*; enabled, it costs ~0.1 ms and two frames of latency — read the numbers off your pass panel.

## Pitfalls

- **Boat rides a plausible but *wrong* sea (offset or mirrored).** The mirror's `k`-to-texel mapping disagrees with the GPU's: the central-block slice must map mirror texel 32 to GPU texel 128 (`k = 0`) exactly. One-off here = the CPU ocean is the GPU ocean *shifted half a tile*.
- **CPU sea is upside-down checkerboard chop.** You forgot the `(−1)^(x+z)` perm sign on the CPU side too. Both transforms uncenter the same spectrum; both need the correction.
- **Crates fine in calm, explode in storm.** Stiff buoyancy springs + steep waves + fixed dt = energy injection. Clamp forces, damp velocity, or substep the buoyancy integration — this is a physics-tuning issue, not an ocean bug.
- **`MapBufferRange` stalls 5+ ms.** You mapped the same PBO you just kicked (ring index math), or skipped the fence poll and mapped unconditionally. The ring exists so you never wait.
- **Readback texture is all zeros.** Missing `gl.MemoryBarrier(gl.PIXEL_BUFFER_BARRIER_BIT)` between the ocean compute and `GetTexImage` — Chapter 61's table told you PBO ops have their own bit; this is where it matters.
- **Mirror drifts out of sync after minutes.** Different time values again (Chapter 28's oldest enemy): the mirror must use the *same wrapped* sim clock uploaded to `ocean_evolve.comp`, wrapped at the same modulus.

## Exercises

1. Expose the mirror as a debug heightfield: draw a 64×64 wireframe grid over the water from the CPU arrays. Watching the wireframe swell match the rendered sea is the chapter's proof, live.
2. Two real FFTs for the price of one complex: pack `h` into the real part and `Dx` into the imaginary part of one complex grid, transform once, and untangle using conjugate symmetry. Classic trick; cuts mirror cost ~33%.
3. Give crates a water-drag torque so they slowly align beam-on to the swell, like real flotsam. Five lines, oddly satisfying.
4. **Stretch:** sample the mirror at the boat's four hull points *plus* predicted position 0.25 s ahead, and blend — a poor man's wave anticipation that noticeably calms hull jitter in short steep seas. Compare against raw sampling in Storm.

## Commit

`git commit -m "ch65: cpu fft mirror — ocean_height_at backend #3, buoyancy untouched"`

← [Chapter 64 — Whitecaps](ch64-whitecaps.md) · [Chapter 66 — Beneath the Surface](ch66-beneath-the-surface.md) →
