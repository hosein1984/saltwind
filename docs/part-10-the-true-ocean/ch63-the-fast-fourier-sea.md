# Chapter 63 — The Fast Fourier Sea

*Part 10 — The True Ocean · Estimated time: 8h (two sessions recommended) · learnopengl: no direct equivalent — canonical references: Tessendorf, ["Simulating Ocean Water"](https://people.computing.clemson.edu/~jtessen/reports/papers_files/coursenotes2004.pdf); Fynn-Jorin Flügge, ["Realtime GPGPU FFT Ocean Water Simulation"](https://tore.tuhh.de/entities/publication/1cd390d3-732b-41c1-aa2b-07b71a64edd2) (TU Hamburg thesis, 2017); Keith Lantz, ["Ocean simulation part two: using the FFT"](https://www.keithlantz.net/2011/11/ocean-simulation-part-two-using-the-fast-fourier-transform/)*

**What you'll see when done:** the Gerstner sea is gone — in its place, sixty-five thousand waves: an open ocean with swell trains that never repeat, chop riding on chop, every wavelength moving at its own physical speed.

## Where we are

You have a spectrum texture full of complex amplitudes (Chapter 62) and a compute pipeline that feeds displacement/normal maps to the ocean shader (Chapter 61). Between them stands one algorithm: the inverse Fourier transform, which turns "energy per frequency" into "height per position." Today you build it on the GPU. This is the summit chapter of the course — when the checkpoint passes, you will have built the same ocean tech that ships in AAA games, and you will have *validated it against your own CPU reference*, which is how you'll know it's right rather than merely pretty.

Fair warning, honestly meant: this chapter has more moving parts than any other in the course. Every one of them is small. Take the two-session split seriously: session one through Build step 5 (validated FFT), session two the rest (the ocean).

## Concepts

### From DFT to FFT

The (inverse, unnormalized) discrete Fourier transform we need, in 1D:

```
h(x_j) = Σ  h̃(m) · e^{+2πi·mj/N}        j, m ∈ [0, N)
        m
```

N outputs, each a sum over N inputs: O(N²). For N = 256 in 2D that's ~4 billion complex multiplies per map per frame. The **fast** Fourier transform computes the same numbers in O(N log N) through one observation, applied recursively: a DFT of size N splits into two DFTs of size N/2 (even-indexed and odd-indexed inputs), stitched together with N/2 "twiddle factor" rotations. Recursion depth log₂N; total work N·log₂N. For our 256² maps: ~50× cheaper, and embarrassingly parallel at every stage.

Unrolled iteratively (how everyone implements it), the data flows through log₂N stages of **butterflies**:

```
input, in BIT-REVERSED order:
x0  x4  x2  x6  x1  x5  x3  x7
 │   │   │   │   │   │   │   │
 ├─●─┤   ├─●─┤   ├─●─┤   ├─●─┤    stage 1: 4 butterflies, partner distance 1
 │   │   │   │   │   │   │   │
 ├─●─────●─┤ │   ├─●─────●─┤ │    stage 2: partner distance 2, twiddles W₄ʲ
 │   │   │   │   │   │   │   │
 ├─●─────────────●─┤ │   │   │    stage 3: partner distance 4, twiddles W₈ʲ
 │   │   │   │   │   │   │   │
X0  X1  X2  X3  X4  X5  X6  X7    output, in natural order

one butterfly:    a ───►(+)──► a + W·b        W = e^{+2πi·j/M}
                      ╳                        ("twiddle": a rotation)
                  b ──W►(−)──► a − W·b
```

Two things to internalize:

- **Bit reversal.** Feeding the iterative network in-order requires the *inputs* shuffled by reversed binary index: element 6 = `110` goes to slot `011` = 3. It's the bookkeeping residue of recursively splitting even/odd. We'll bake it into stage one's lookup table rather than doing a separate shuffle pass.
- **Each stage is a gather.** Every output element of a stage reads exactly two elements of the previous stage and writes one. That's a perfect compute-shader shape: one invocation per element, ping-ponging between two textures, log₂N = 8 dispatches per dimension.

### 2D = rows, then columns

The 2D transform is **separable**: `e^{i(k_x x + k_z z)} = e^{ik_x x}·e^{ik_z z}`, so a 2D IFFT is a 1D IFFT along every row, then a 1D IFFT along every column of the result (order doesn't matter). No new math — the same butterfly shader run horizontally 8 times, then vertically 8 times. 16 dispatches over 256² texels: well under 0.2 ms on anything that can run Saltwind at 4.3.

### The permutation sign: why your first ocean will be a checkerboard

Chapter 62 defined `k = 2π(m − N/2)/L` — frequencies *centered* on the texture, negative frequencies on the left. The FFT, however, computes the sum with `m ∈ [0, N)` uncentered. Substitute `m' = m − N/2` and watch the shift theorem fall out, with `x_j = jL/N`:

```
k·x = 2π(m − N/2)·j/N = 2π·mj/N − πj
        ⇒   h(x_j) = (−1)^j · [plain IFFT of the texel array]
```

In 2D: multiply texel `(x, z)` of the *output* by **`(−1)^(x+z)`**. Forget it, and adjacent output texels alternate sign — the infamous checkerboard ocean, the #1 bug of every FFT-water implementation ever written (screenshot it when it happens to you; it's a rite of passage). We fold this correction into the final assembly pass.

### Three fields, four lanes

The spectrum yields more than height. Following Tessendorf:

- **Height:** `h̃(k, t)` — Chapter 62's time evolution.
- **Choppy displacement** (the Gerstner horizontal pinch, now done right): `D̃(k) = −i·k̂·h̃(k)`, transformed per component (`D̃x = −i(k_x/k)h̃`, `D̃z = −i(k_z/k)h̃`). Multiplying by `−i` is a 90° phase shift: for `h = (a, b)`, `−i·h = (b, −a)` — no trig.
- **Normals:** the exact route is slope spectra `i·k_x·h̃`, `i·k_z·h̃`; the pragmatic route is central differences on the finished displacement map in the assembly pass. We take the pragmatic route (you need the assembly pass anyway for the permutation sign and Chapter 64's Jacobian) and leave exact slopes as an exercise.

That's three complex signals: `h`, `Dx`, `Dz`. One `rgba32f` texel carries two complex numbers, so we use **two ping-pong texture pairs** processed by the same dispatch: texture 0 carries `h` in `.xy` and `Dx` in `.zw`; texture 1 carries `Dz` in `.xy` (`.zw` spare — exercise bait). One set of butterfly passes transforms all three signals at once for ~2× ALU and zero extra dispatches.

### Per-frame anatomy

```
        (once)  h̃₀(k)  ──┐
                          ▼
 [1] evolve:    h̃(k,t), D̃x(k,t), D̃z(k,t)        1 dispatch
 [2] IFFT rows:  8 ping-pong butterfly dispatches
 [3] IFFT cols:  8 more
 [4] assemble:  ×(−1)^(x+z), pack displacement map,
                finite-difference normals → normal map   1 dispatch
        then the ch61 vertex shader samples, as before
```

The Chapter 61 contract — "ocean shader samples a displacement map and a normal map" — doesn't change *at all*. We're swapping the producer, not the product. (Note your buoyancy cubes will stop matching the surface today: `ocean_height_at` still speaks Gerstner. Chapter 65 fixes it properly; live with the lie for two chapters.)

## Odin notes

For CPU-side complex math (the butterfly table and the validation DFT), use Odin's builtin `complex64`: construct with `complex(re, im)`, extract with `real(z)` / `imag(z)`, and `+`/`*` just work. No import needed; it mirrors the `vec2`-as-complex convention in the GLSL (`cmul` below) closely enough to compare side by side.

## Build

1. **Precompute the butterfly table** in `src/ocean_fft.odin` — a `log₂N × N` `rgba32f` texture: for output element `i` at stage `s`, which two indices do I read, and what twiddle multiplies the second one? Folding the `±` of the butterfly into the stored twiddle makes the shader sign-free:

   ```odin
   // texel (s, i) = (twiddle.re, twiddle.im, index_a, index_b):  out[i] = in[a] + W*in[b]
   fft_build_butterfly :: proc(n: int) -> [][4]f32 {
       stages := int(math.log2(f64(n)))
       data := make([][4]f32, stages * n)
       for s in 0 ..< stages {
           m    := 1 << uint(s + 1)            // butterfly block size this stage
           half := m >> 1
           for i in 0 ..< n {
               pos := i % m
               top := pos < half
               j   := top ? pos : pos - half
               w   := complex(math.cos(2*math.PI*f32(j)/f32(m)),
                              math.sin(2*math.PI*f32(j)/f32(m)))   // +i: INVERSE transform
               if !top do w = -w                                   // bottom wire: a − W·b
               a := top ? i : i - half
               b := top ? i + half : i
               if s == 0 { a = bit_reverse(a, stages); b = bit_reverse(b, stages) }
               data[s*n + i] = {real(w), imag(w), f32(a), f32(b)}
           }
       }
       return data
   }
   ```

   `bit_reverse(x, bits)` is a six-line loop (or `bits.reverse` on a shifted `u32` — your call). Upload as `RGBA32F`, `NEAREST`, size `stages × n`. Build it for *any* n — step 5 runs it at n=8.

2. **Write `assets/shaders/ocean_evolve.comp`** — spectrum at time t (this replaces nothing yet; it *feeds* the FFT):

   ```glsl
   layout(rgba32f, binding = 0) uniform readonly  image2D u_h0;     // ch62 texture
   layout(rgba32f, binding = 1) uniform writeonly image2D u_spec0;  // h.xy, Dx.zw
   layout(rgba32f, binding = 2) uniform writeonly image2D u_spec1;  // Dz.xy
   uniform float u_time; uniform float u_tile_size;
   vec2 cmul(vec2 a, vec2 b) { return vec2(a.x*b.x - a.y*b.y, a.x*b.y + a.y*b.x); }

   void main() {
       ivec2 id = ivec2(gl_GlobalInvocationID.xy);
       int n = imageSize(u_h0).x;
       vec2 k = 2.0 * 3.14159265 * (vec2(id) - float(n)/2.0) / u_tile_size;
       float klen = max(length(k), 1e-6);
       float w = sqrt(9.81 * klen);                       // dispersion ω = √(gk)
       vec4 h0 = imageLoad(u_h0, id);
       vec2 e  = vec2(cos(w * u_time), sin(w * u_time));  // e^{iωt}
       vec2 h  = cmul(h0.xy, e) + cmul(h0.zw, vec2(e.x, -e.y));
       vec2 dx = (k.x / klen) * vec2(h.y, -h.x);          // −i·k̂x·h
       vec2 dz = (k.y / klen) * vec2(h.y, -h.x);
       imageStore(u_spec0, id, vec4(h, dx));
       imageStore(u_spec1, id, vec4(dz, 0.0, 0.0));
   }
   ```

3. **Write `assets/shaders/ocean_butterfly.comp`** — one stage, both textures, either axis:

   ```glsl
   layout(rgba32f, binding = 0) uniform readonly  image2D u_butterfly;
   layout(rgba32f, binding = 1) uniform readonly  image2D u_in0;
   layout(rgba32f, binding = 2) uniform readonly  image2D u_in1;
   layout(rgba32f, binding = 3) uniform writeonly image2D u_out0;
   layout(rgba32f, binding = 4) uniform writeonly image2D u_out1;
   uniform int u_stage; uniform int u_horizontal;

   void main() {
       ivec2 p   = ivec2(gl_GlobalInvocationID.xy);
       int  line = (u_horizontal == 1) ? p.x : p.y;
       vec4 bf   = imageLoad(u_butterfly, ivec2(u_stage, line));
       ivec2 ia  = (u_horizontal == 1) ? ivec2(int(bf.z), p.y) : ivec2(p.x, int(bf.z));
       ivec2 ib  = (u_horizontal == 1) ? ivec2(int(bf.w), p.y) : ivec2(p.x, int(bf.w));
       vec4 a0 = imageLoad(u_in0, ia), b0 = imageLoad(u_in0, ib);
       vec4 a1 = imageLoad(u_in1, ia), b1 = imageLoad(u_in1, ib);
       imageStore(u_out0, p, vec4(a0.xy + cmul(bf.xy, b0.xy), a0.zw + cmul(bf.xy, b0.zw)));
       imageStore(u_out1, p, vec4(a1.xy + cmul(bf.xy, b1.xy), a1.zw));
   }
   ```

4. **Drive it from Odin.** `Ocean_Fft` owns the butterfly texture, two ping-pong pairs, and the three programs. The loop is bookkeeping — get the barrier and the swap right:

   ```odin
   ocean_fft_execute :: proc(f: ^Ocean_Fft) {
       gl.UseProgram(f.butterfly_shader.id)
       gl.BindImageTexture(0, f.tex_butterfly, 0, false, 0, gl.READ_ONLY, gl.RGBA32F)
       src := 0
       for axis in 0 ..< 2 {
           shader_set_i32(f.butterfly_shader, "u_horizontal", i32(1 - axis))
           for s in 0 ..< f.stages {
               shader_set_i32(f.butterfly_shader, "u_stage", i32(s))
               gl.BindImageTexture(1, f.pp0[src],   0, false, 0, gl.READ_ONLY,  gl.RGBA32F)
               gl.BindImageTexture(2, f.pp1[src],   0, false, 0, gl.READ_ONLY,  gl.RGBA32F)
               gl.BindImageTexture(3, f.pp0[1-src], 0, false, 0, gl.WRITE_ONLY, gl.RGBA32F)
               gl.BindImageTexture(4, f.pp1[1-src], 0, false, 0, gl.WRITE_ONLY, gl.RGBA32F)
               gl.DispatchCompute(f.groups, f.groups, 1)
               gl.MemoryBarrier(gl.SHADER_IMAGE_ACCESS_BARRIER_BIT)  // next stage imageLoads
               src = 1 - src
           }
       }
       f.result = src   // which side of the ping-pong holds the answer
   }
   ```

   Note the barrier bit: between stages the consumer is `imageLoad`, so *here* `SHADER_IMAGE_ACCESS_BARRIER_BIT` is correct — compare Chapter 61's `TEXTURE_FETCH` and make sure you can say why they differ. With `stages = 8`, `2×8 = 16` dispatches: result lands back in side 0; with N=8 (3 stages, 6 dispatches) it also lands in side 0 — even total stages. Don't hardcode that; trust `f.result`.

5. **Validate against a CPU reference — the chapter's backbone.** Write the naive DFT (it's the *definition*, so it can't be subtly wrong) and a self-test that runs the entire GPU pipeline at N=8:

   ```odin
   dft_2d_reference :: proc(in_: []complex64, n: int) -> []complex64 {
       out := make([]complex64, n*n)
       for zj in 0 ..< n do for xj in 0 ..< n {
           sum: complex64
           for q in 0 ..< n do for p in 0 ..< n {
               theta := 2.0 * math.PI * (f32(xj*p) + f32(zj*q)) / f32(n)
               sum += in_[q*n + p] * complex(math.cos(theta), math.sin(theta))
           }
           out[zj*n + xj] = sum
       }
       return out
   }
   ```

   The self-test (run under `when ODIN_DEBUG` at startup): fill an 8×8 `[4]f32` array with known randoms; upload into an 8×8 ping-pong pair; run `ocean_fft_execute` with the 8-point butterfly table; read back with `gl.GetTexImage(gl.TEXTURE_2D, 0, gl.RGBA, gl.FLOAT, raw_data(buf))`; compare `.xy` against `dft_2d_reference` of the same input. Print the worst absolute error:

   ```
   fft self-test: n=8  max |gpu − cpu| = 3.2e-05   PASS (tolerance 1e-3)
   ```

   If it fails, print both 8×8 grids side by side. With 64 numbers in front of you, every bug confesses: wrong bit-reversal scrambles *positions*, wrong twiddle sign transposes the spectrum (output is the *forward* transform — compare against the reference with `−θ` to confirm), a missing barrier gives different garbage each run. **Do not proceed until PASS.** This tiny harness is the difference between debugging 64 numbers and debugging 65,536 moving ones.

6. **Write the assembly pass** `assets/shaders/ocean_assemble.comp`, replacing `ocean_gerstner.comp` as the producer of Chapter 61's maps:

   ```glsl
   float perm(ivec2 p) { return ((p.x + p.y) & 1) == 0 ? 1.0 : -1.0; }  // ×(−1)^(x+z)
   float height_at(ivec2 p, int n) {
       p = (p + n) % n;                                  // toroidal neighbors
       return imageLoad(u_fft0, p).x * perm(p);
   }
   void main() {
       ivec2 id = ivec2(gl_GlobalInvocationID.xy);
       int n = imageSize(u_fft0).x;  float s = perm(id);
       vec3 disp = vec3(imageLoad(u_fft0, id).z * s * u_choppy,   // λ·Dx
                        imageLoad(u_fft0, id).x * s,              // h
                        imageLoad(u_fft1, id).x * s * u_choppy);  // λ·Dz
       float dx = u_tile_size / float(n);
       vec3 nrm = normalize(vec3(-(height_at(id+ivec2(1,0),n) - height_at(id-ivec2(1,0),n)) / (2.0*dx),
                                 1.0,
                                 -(height_at(id+ivec2(0,1),n) - height_at(id-ivec2(0,1),n)) / (2.0*dx)));
       imageStore(u_displacement, id, vec4(disp, 1.0));
       imageStore(u_normal, id, vec4(nrm, 0.0));
   }
   ```

   `u_choppy` (Tessendorf's λ) ≈ 1.0–1.5 to start. Neighbors get *their own* perm sign via `height_at` — adjacent texels have opposite signs by construction. End the frame's ocean compute with `gl.MemoryBarrier(gl.TEXTURE_FETCH_BARRIER_BIT)` exactly as Chapter 61 did.

7. **Swap the producer and tune.** Frame order: evolve → fft → assemble → (rest of frame). Delete the gerstner dispatch (keep the `.comp` file — it's the 4.3-capable fallback aesthetic, and Chapter 83 wants options). Feed `u_time` from the same wrapped sim clock as ever. Now tune like a sailor: `amplitude` until swells reach believable height for the wind, `u_choppy` until crests pinch like Chapter 28's best steepness but stop short of self-intersection (the Jacobian in Chapter 64 measures this *exactly* — for now, eyes). Expect to spend a happy half hour here; normalization constants differ between every FFT-ocean writeup, which is why everyone tunes `A` rather than deriving it.

8. **Confront the tiling.** Sail up high: the 256 m tile repeats, and at altitude you can see the wallpaper. Mitigations now: keep the Chapter 29 detail normals breaking up speculars, and fade ocean normal strength with distance (you did similar for shadow cascades). Mention of the real fix: production oceans run **2–3 cascades** — the same pipeline at different tile sizes (e.g. 256 m / 17 m), summed in the vertex shader, frequency bands split between them so no wave is in two cascades. It's a loop around everything you built today, and it's this chapter's Stretch.

## Checkpoint

An endless, organic ocean. Stand at deck height in a fresh breeze: long swell trains roll through with smaller seas riding them; nothing visibly loops, ever; crests pinch and stretch with chop. The startup log says `fft self-test ... PASS`.

- RenderDoc: ~18 dispatches under your ocean-sim pass marker; step through the ping-pong and watch the spectrum *become* a sea, stage by stage. (Genuinely one of the best things you will ever watch in a graphics debugger.)
- Pass timer: evolve+fft+assemble ≈ 0.2–0.4 ms total at 256².
- Freeze time (`u_time` paused): the surface holds perfectly still — any crawling means a barrier or ping-pong index bug.
- `u_choppy = 0` gives round, sine-like waves; raising it pinches crests — the Gerstner intuition transplanted to 65,536 waves.

## Pitfalls

- **Checkerboard ocean.** You skipped the Concepts section, didn't you. The `(−1)^(x+z)` permutation sign — apply it once, in assembly, to every transformed value (including the neighbors used for normals).
- **Solid NaN sea (often: black ocean, or the HDR pass dies).** One NaN at `k=0` in evolve (the `max(length(k), 1e-6)` guard) or upstream in the Chapter 62 texture, spread to everything by the FFT. RenderDoc shows NaN texels in white/magenta in the pixel inspector — check the *evolve output* first, then h0.
- **Different garbage every frame, or flicker.** Missing `MemoryBarrier` between butterfly stages, or read/write bound to the same side of the ping-pong (binding 1 == binding 3 after a swap bug). Freeze-time is the test.
- **Output is mirrored/transposed, or motion runs backward.** Twiddle sign: inverse transform uses `e^{+iθ}` in both the butterfly table *and* the evolve pass. Mixed signs = waves that propagate the wrong way against the wind.
- **Self-test passes at 8 but the 256 ocean is wrong.** Almost always the butterfly *texture* at full size: `log2` computed as `f32` truncating to 7 stages, or the stage-0 bit-reversal using the wrong bit count. Assert `1 << stages == n`.
- **Everything works but amplitudes are absurd (mm or km).** Normalization conventions (the missing `1/N²` of the unnormalized IFFT) folded into `A`. Don't chase the "correct" constant across three references that all disagree — tune `A` and move on; the *spectrum shape*, which is what your eye reads, is independent of it.

## Exercises

1. Add a debug view cycling through the intermediate textures (h̃₀ → evolved → after-rows → final). The after-rows image — coherent horizontally, noise vertically — is the separability proof, live.
2. Use the spare `.zw` of `u_spec1`/ping-pong 1 to carry the slope spectrum `i·k_x·h̃`, and build normals exactly instead of by finite differences. Compare in a split-screen toggle: finite differences soften the sharpest chop. Decide which you keep (both are defensible; that's rendering).
3. Wire `u_choppy` and `amplitude` into the microui ocean panel with live sliders. You'll thank yourself during Chapter 64 foam tuning.
4. **Stretch (the real one):** cascades. Two instances of the whole pipeline — tiles 256 m and ~17 m (coprime-ish scales hide alignment), spectrum band-limited so each wavelength lives in exactly one cascade, vertex shader sums two displacement samples, fragment blends two normal maps. This is the difference between "great ocean" and "I can't tell it from Sea of Thieves," and everything you need is already on screen.

## Commit

`git commit -m "ch63: tessendorf FFT ocean — gpu butterflies, cpu-validated"`

← [Chapter 62 — The Spectrum of the Sea](ch62-the-spectrum-of-the-sea.md) · [Chapter 64 — Whitecaps](ch64-whitecaps.md) →
