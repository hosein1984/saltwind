# Chapter 61 — The Parallel Sea

*Part 10 — The True Ocean · Estimated time: 4h · learnopengl: [Compute Shaders (guest)](https://learnopengl.com/Guest-Articles/2022/Compute-Shaders/Introduction)*

**What you'll see when done:** the exact same Gerstner swell you've sailed since Chapter 28 — but the wave math now runs in a compute shader writing displacement and normal textures, and RenderDoc shows two `glDispatchCompute` events where there used to be per-vertex arithmetic.

## Where we are

Welcome to the hardest, best part of the course. Over the next eight chapters you will replace the four hand-tuned Gerstner waves with a statistically-correct ocean synthesized from thousands of waves by a GPU FFT — the technique behind the water in *Titanic*, *Sea of Thieves*, and essentially every AAA ocean since Tessendorf's 1999 paper. This is the hardest fortnight in the course, and the single most impressive thing you will build.

But not today. Today is about the *machinery*. Chapter 50's Taster C gave you a compute shader that worked; this chapter makes sure you understand *why* it worked, then rebuilds the existing ocean on compute foundations. The discipline: change the engine, not the picture. When tonight's checkpoint is "it looks identical," that's victory — because everything from Chapter 62 onward slots into the textures you create today.

## Concepts

### The execution model: grids of grids

A compute shader has no pipeline — no vertices in, no fragments out. You ask the GPU to run a function N times, and the only structure is a two-level grid:

```
   dispatch (4×3 workgroups)            one workgroup (16×16 invocations)
  ┌─────┬─────┬─────┬─────┐            ┌─┬─┬─┬─ ... ─┬─┐
  │ WG  │ WG  │ WG  │ WG  │            │i│i│i│       │i│   invocations share
  ├─────┼─────┼─────┼─────┤            ├─┼─┼─┤       ├─┤   `shared` memory and
  │ WG  │ WG  │ WG  │ WG  │            │i│i│i│  ...  │i│   can barrier() with
  ├─────┼─────┼─────┼─────┤            └─┴─┴─┴─ ... ─┴─┘   each other; separate
  │ WG  │ WG  │ WG  │ WG  │                                workgroups CANNOT
  └─────┴─────┴─────┴─────┘
```

- The **workgroup size** is fixed in the shader: `layout(local_size_x = 16, local_size_y = 16) in;` — 256 invocations per group. The GPU schedules whole workgroups onto its cores; sizes that are multiples of 32/64 keep the hardware fed.
- The **dispatch size** is given at runtime: `gl.DispatchCompute(gx, gy, gz)` counts *workgroups*, not invocations.
- Inside the shader, `gl_GlobalInvocationID` is your coordinate in the full grid (`gl_WorkGroupID * gl_WorkGroupSize + gl_LocalInvocationID`). For image work it's simply "which texel am I."

**Dispatch math** is the off-by-one trap of compute: to cover `N` items with groups of `L`, dispatch `(N + L - 1) / L` groups (integer ceil-divide). When `N` isn't a multiple of `L`, the last group has invocations past the edge — bounds-check them (`if (id.x >= N) return;`). Our ocean textures are 256² with 16² groups: exactly `gl.DispatchCompute(16, 16, 1)`, no remainder, but write the helper anyway:

```odin
dispatch_size :: proc(items, local_size: i32) -> u32 {
    return u32((items + local_size - 1) / local_size)
}
```

### Getting data in and out: SSBO vs. image load/store

Two mechanisms, two shapes of data:

- **Shader Storage Buffer Objects (SSBOs)** are buffers exposed to shaders as arrays — readable *and writable*, with a flexible `std430` layout, sized up to GB. Use them for *structured* data: arrays of structs, particle pools, anything the CPU also wants to understand byte-for-byte.
- **Image load/store** (`imageLoad`/`imageStore` on `image2D` uniforms) is direct texel access to a texture, no filtering, no mipmap selection. Use it when the data *is* a texture — i.e., when a later pass will **sample** it with `texture()` and wants filtering, wrapping, and mips.

The rule of thumb that never fails: *if the consumer is a sampler, write an image; if the consumer is a loop, write an SSBO.* Our displacement map will be bilinearly sampled and `REPEAT`-wrapped by the ocean vertex shader — image. Our wave parameter table is an array of structs — SSBO (and moving it there retires the clunky per-field uniform upload from Chapter 28).

Layout qualifiers, side by side:

```glsl
layout(local_size_x = 16, local_size_y = 16) in;          // workgroup size

layout(std430, binding = 0) readonly buffer Waves {        // SSBO: binding =
    Wave waves[];                                          // BindBufferBase slot
};
layout(rgba16f, binding = 0) uniform image2D u_displacement; // image: format is
layout(rgba16f, binding = 1) uniform image2D u_normal;       // MANDATORY, binding
                                                             // = image unit
```

Note the format qualifier on images is not decoration — `imageStore` has no idea what it's writing into without it, and it must match the texture's actual internal format. SSBO and image bindings are *separate namespaces*; both can be 0.

### Memory barriers: you left the pipeline, you left its guarantees

In the raster pipeline, ordering is implicit: a fragment shader sampling a texture you rendered last pass just works. Compute writes via image/SSBO are **incoherent** — the GL gives no automatic guarantee that later commands see them. `gl.MemoryBarrier(bits)` draws the line: writes before the barrier become visible to the kind of access named by the bits, *after* it.

The bits name **how the data will be read next**, not how it was written. The ones you'll actually use this part:

| Barrier bit | Orders writes against subsequent... |
|---|---|
| `SHADER_IMAGE_ACCESS_BARRIER_BIT` | `imageLoad`/`imageStore` in another shader (FFT ping-pong: every stage) |
| `TEXTURE_FETCH_BARRIER_BIT` | `texture()`/`texelFetch` sampling (compute → vertex shader, tonight) |
| `SHADER_STORAGE_BARRIER_BIT` | SSBO reads/writes in another shader |
| `VERTEX_ATTRIB_ARRAY_BARRIER_BIT` | the buffer used as vertex attributes |
| `BUFFER_UPDATE_BARRIER_BIT` | `gl.GetBufferSubData` / `BufferSubData` from the CPU side |
| `PIXEL_BUFFER_BARRIER_BIT` | PBO pack/unpack operations (Chapter 65 readback) |

Tonight's pipeline is *compute writes images → vertex shader samples them*, so the correct call after dispatch is `gl.MemoryBarrier(gl.TEXTURE_FETCH_BARRIER_BIT)`. Passing `SHADER_IMAGE_ACCESS_BARRIER_BIT` there is the classic subtle bug: it orders against image *load/store*, not against *sampling* — it may appear to work on your driver and break on the next one.

### Know your budget: querying limits

Limits differ per GPU; query once at startup and print them to your debug panel:

```odin
inv, shared_mem: i32
counts: [3]i32
for i in 0 ..< 3 {
    gl.GetIntegeri_v(gl.MAX_COMPUTE_WORK_GROUP_COUNT, u32(i), &counts[i])
}
gl.GetIntegerv(gl.MAX_COMPUTE_WORK_GROUP_INVOCATIONS, &inv)       // ≥ 1024
gl.GetIntegerv(gl.MAX_COMPUTE_SHARED_MEMORY_SIZE, &shared_mem)    // ≥ 32 KiB
```

`MAX_COMPUTE_WORK_GROUP_COUNT` is per-axis (use the indexed query); `MAX_COMPUTE_WORK_GROUP_INVOCATIONS` caps `local_size_x*y*z`. Our 16×16 = 256 is comfortably legal everywhere.

### The one visual change: the wave field becomes a tile

Chapter 28 evaluated waves at world-space `xz` — an infinite, non-repeating field. A texture is finite: it covers one **tile** of size `L` meters and repeats. For the tile to wrap seamlessly, every wave must fit the tile a whole number of times: `k = 2π·n/L` for integer `n`. So we quantize: each Chapter 28 wavelength `λ` becomes `L/round(L/λ)`. With `L = 256`, your 55 m swell becomes 51.2 m, the 27 m wave 28.4 m — visually indistinguishable, and the CPU table is quantized at creation so `ocean_height_at` stays in perfect lockstep.

Remember this constraint. It is not a hack — it is *the* structural fact of Chapter 63: an FFT ocean is exactly a sum of waves whose wavenumbers are `2πn/L`. Tonight's quantization is you meeting the frequency grid early.

## Odin notes

`vendor:OpenGL` ships a compute loader, symmetric with the `load_shaders_file` you've used since Chapter 4: `gl.load_compute_file(filename) -> (program_id: u32, ok: bool)`. Wrap it so it returns your `Shader` type and plays with your uniform helpers and hot-reload:

```odin
shader_load_compute :: proc(path: string) -> (s: Shader, ok: bool) {
    s.id, ok = gl.load_compute_file(path)
    return
}
```

For the SSBO, mirror `std430` exactly. Rule worth tattooing: **pad every struct to a multiple of 16 bytes and keep `vec2`s 8-aligned, and std430, std140, and Odin will never disagree.** Our wave struct is 20 bytes of payload — pad to 32:

```odin
Wave_Std430 :: struct {
    direction:  glsl.vec2, // offset 0,  8-aligned
    amplitude:  f32,       // offset 8
    wavelength: f32,       // offset 12
    speed:      f32,       // offset 16
    _pad:       [3]f32,    // -> size 32, matches GLSL struct + 3 float pad
}
#assert(size_of(Wave_Std430) == 32)
```

That `#assert` is free insurance; use it on every GPU-shared struct from now on.

## Build

1. **Quantize the wave table.** In `ocean_default_waves` (or a wrapper), snap each wavelength to the tile: `w.wavelength = TILE_SIZE / math.round(TILE_SIZE / w.wavelength)` with `TILE_SIZE :: 256.0`. Run the game — Chapter 28 path, unchanged code — and confirm the sea still looks right. Commit this before touching compute; it isolates the only *visual* change of the chapter.

2. **Create the output textures.** Add to `Ocean`:

   ```odin
   Ocean_Maps :: struct {
       displacement: u32, // rgba16f: xyz = displacement, w = spare (ch64 takes it)
       normal:       u32, // rgba16f: xyz = normal
       size:         i32, // 256
   }

   ocean_maps_create :: proc(n: i32) -> (m: Ocean_Maps) {
       m.size = n
       for tex in ([]^u32{&m.displacement, &m.normal}) {
           gl.GenTextures(1, tex)
           gl.BindTexture(gl.TEXTURE_2D, tex^)
           gl.TexStorage2D(gl.TEXTURE_2D, 1, gl.RGBA16F, n, n) // immutable storage
           gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
           gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
           gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.REPEAT)
           gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.REPEAT)
       }
       return
   }
   ```

   `TexStorage2D` (GL 4.2+) allocates immutable storage — the format can never silently change, which is exactly what `BindImageTexture` wants. `REPEAT` is what makes one tile an endless sea.

3. **Move the wave table to an SSBO.** Define `Wave_Std430`, fill it from your quantized table, then:

   ```odin
   gl.GenBuffers(1, &o.wave_ssbo)
   gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, o.wave_ssbo)
   gl.BufferData(gl.SHADER_STORAGE_BUFFER, size_of(Wave_Std430) * 4,
                 raw_data(waves_430[:]), gl.STATIC_DRAW)
   gl.BindBufferBase(gl.SHADER_STORAGE_BUFFER, 0, o.wave_ssbo)
   ```

   Delete `ocean_upload_waves` — the per-field uniform shuffle from Chapter 28 retires tonight.

4. **Write `assets/shaders/ocean_gerstner.comp`.** It is your Chapter 28/29 vertex math, verbatim, evaluated per-texel instead of per-vertex:

   ```glsl
   #version 430
   layout(local_size_x = 16, local_size_y = 16) in;
   struct Wave { vec2 direction; float amplitude; float wavelength; float speed; float _p0, _p1, _p2; };
   layout(std430, binding = 0) readonly buffer Waves { Wave waves[]; };
   layout(rgba16f, binding = 0) uniform image2D u_displacement;
   layout(rgba16f, binding = 1) uniform image2D u_normal;
   uniform float u_time, u_steepness, u_tile_size;

   void main() {
       ivec2 id = ivec2(gl_GlobalInvocationID.xy);
       int   n  = imageSize(u_displacement).x;
       vec2  p  = (vec2(id) / float(n)) * u_tile_size;   // texel -> meters
       vec3 off = vec3(0.0); vec3 nrm = vec3(0.0, 1.0, 0.0);
       for (int i = 0; i < waves.length(); i++) {
           // ... your gerstner_offset + ch29 analytic-normal sums, verbatim ...
       }
       imageStore(u_displacement, id, vec4(off, 1.0));
       imageStore(u_normal, id, vec4(normalize(nrm), 0.0));
   }
   ```

   Note `waves.length()` — unsized SSBO arrays know their size from the buffer binding. Load it with your new `shader_load_compute`.

5. **Dispatch each frame**, before the ocean draw (this is a real pass — give it an entry and a GPU timer in your Chapter 60 pass list):

   ```odin
   gl.UseProgram(o.sim_shader.id)
   shader_set_f32(o.sim_shader, "u_time", sim_time)
   shader_set_f32(o.sim_shader, "u_steepness", o.steepness)
   shader_set_f32(o.sim_shader, "u_tile_size", TILE_SIZE)
   gl.BindImageTexture(0, o.maps.displacement, 0, false, 0, gl.WRITE_ONLY, gl.RGBA16F)
   gl.BindImageTexture(1, o.maps.normal,       0, false, 0, gl.WRITE_ONLY, gl.RGBA16F)
   gl.DispatchCompute(dispatch_size(o.maps.size, 16), dispatch_size(o.maps.size, 16), 1)
   gl.MemoryBarrier(gl.TEXTURE_FETCH_BARRIER_BIT)   // consumers SAMPLE these
   ```

6. **Rewire the water vertex shader.** Delete the Gerstner loop; sample instead:

   ```glsl
   uniform sampler2D u_displacement;   // unit 3 — keep 0..2 as ch30 left them
   uniform float u_tile_size;
   // in main():
   vec3 world = (model * vec4(a_pos, 1.0)).xyz;
   world += textureLod(u_displacement, world.xz / u_tile_size, 0.0).xyz;
   ```

   `textureLod(..., 0.0)` because vertex shaders have no derivatives for mip selection. In the fragment shader, replace the analytic normal computation with a sample of `u_normal` at the same UV — keep the Chapter 29 *detail* normal layered on top for close-range sparkle. The Chapter 30 projective reflections and everything downstream don't change at all.

7. **Keep the CPU mirror honest.** `ocean_height_at` still evaluates the closed-form Gerstner table — which is still *exactly* what the compute shader evaluates (you quantized the shared table in step 1). Update the mirror comment: `// MIRRORS assets/shaders/ocean_gerstner.comp — change both!` Re-run the Chapter 28 debug cubes: they must still surf perfectly.

## Checkpoint

The same ocean as yesterday. That's the point. Now prove the new machinery:

- In RenderDoc: two new events — your dispatch — and the displacement/normal textures inspectable as real resources. Scrub a frame and *watch* the displacement texture: a living wave field in texture form.
- Toggle old/new paths with a debug key (keep the Gerstner vertex shader around for one chapter): motion is identical, down to the debug cubes.
- Your pass panel shows the sim pass at ~0.05 ms or less. Note it; Chapter 63 will multiply this number and Chapter 68 will audit it.
- `steepness` and weather changes still work — uniforms now feed the compute pass.

## Pitfalls

- **Black or frozen ocean, no GL error.** Missing `gl.MemoryBarrier` after dispatch, or the wrong bit (`SHADER_IMAGE_ACCESS` when the consumer is `texture()` — see Concepts). Symptom is driver-dependent: some appear fine, some show stale or zero texels.
- **`imageStore` silently does nothing.** Format mismatch between the GLSL qualifier (`rgba16f`), the `BindImageTexture` format argument, and the texture's actual storage. With `TexStorage2D` the third one can't drift — check the other two.
- **Garbage waves / waves ignore parameters.** SSBO layout mismatch. Check `#assert(size_of(Wave_Std430) == 32)`, and that the GLSL struct carries the same three pad floats. RenderDoc's buffer viewer shows you the raw bytes — compare against your Odin array.
- **Seams every 256 m.** A wavelength escaped quantization (steepness `Q` derivation uses `k` — recompute it from the *quantized* λ), or texture wrap is `CLAMP_TO_EDGE` instead of `REPEAT`.
- **Boat drifts off the surface.** You quantized the GPU table but not the CPU one — they're the same array; quantize at creation, before either side reads it.
- **Crash on older machine.** You bumped to 4.3 in Chapter 53 with a fallback plan; compute must sit behind that gate. The Gerstner vertex path you kept in step 6 *is* the fallback (Chapter 83 formalizes this).

## Exercises

1. Set workgroup size to 8×8, then 32×32, and compare the pass timer. On most GPUs you'll see little difference at this tiny size — now try it on a 1024² texture and watch occupancy matter.
2. Print the three compute limits to your microui panel at startup. Sail on; it's your GPU's nameplate.
3. Add compute-shader hot-reload: your Chapter 4 file-watcher plus `shader_load_compute`. Tweak steepness math live, mid-sail.
4. **Stretch:** port the Chapter 50 Taster C ripple sim into this chapter's structure (SSBO-free, image ping-pong, proper barrier bits) as a dry run — Chapter 67 will build it for real, and you'll have met every bug once already.

## Commit

`git commit -m "ch61: ocean wave evaluation moved to compute — displacement/normal maps"`

← [Chapter 60 — Milestone: The Deep Engine](../part-9-the-deep-engine/ch60-milestone-the-deep-engine.md) · [Chapter 62 — The Spectrum of the Sea](ch62-the-spectrum-of-the-sea.md) →
