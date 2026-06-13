# Chapter 51 — The Finish Coat

*Part 8 — Full Sail · Estimated time: 4h · learnopengl: no direct equivalent — this is shipping material*

**What you'll see when done:** a color-graded, gently vignetted Saltwind that saves a PNG when you press F11 — and a `saltwind.zip` a friend can run on a machine that has never heard of Odin.

## Where we are

Everything works. This chapter is the difference between *works* and *finished*: the last 2% of image polish (grading, vignette, grain), a photo mode for the screenshots this course has been promising you, one end-to-end correctness audit of the color pipeline you've been assembling since chapter 16, and a build a stranger can run. Polish is not vanity — it's the respect a project pays to its own effort.

## Concepts

### Color grading: the film look, programmable

Tone mapping (ch40) made the image *correct*; grading makes it *yours*. Two industry-standard approaches:

**Lift / gamma / gain** — three color controls applied post-tonemap (in display space, before final gamma is also defensible; pick one and be consistent — we grade after tonemap, before gamma):

```glsl
// shadows (lift), midtones (gamma), highlights (gain)
vec3 grade(vec3 c) {
    c = u_gain * (c + u_lift * (1.0 - c));   // lift raises blacks, gain scales whites
    return pow(max(c, 0.0), 1.0 / u_gamma_rgb); // per-channel midtone curve
}
```

A teal-shadow/warm-highlight grade — `lift = (0.0, 0.015, 0.03)`, `gain = (1.05, 1.0, 0.95)` — is the entire "cinematic ocean game" look. Subtle numbers; if anyone can name the colors you added, halve them.

**3D LUT** — the production approach: a 32³ RGB cube texture mapping input color → output color. You bake any grade (from DaVinci, Photoshop, or code) into the LUT once, and the shader is just `color = texture(u_lut, color.rgb)` (with a half-texel scale-offset so the cube's edges sample correctly: `uvw = c * (31.0/32.0) + 0.5/32.0`). GL 3.3 supports `gl.TEXTURE_3D` fine. We build lift/gamma/gain (more instructive); the exercise bakes it into a LUT.

### Vignette and grain: the lens admits it's a lens

- **Vignette:** darken toward corners — `c *= 1.0 - u_vignette * smoothstep(0.4, 1.4, length(v_uv - 0.5) * 2.0)`. Strength 0.15–0.3. It focuses the eye centerward; every film and game you've ever loved does it.
- **Film grain:** a whisper of per-pixel noise — `c += (hash(v_uv * u_time) - 0.5) * u_grain` with `u_grain` ≈ 0.008 (any cheap hash works: `fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453)`). Grain dithers away banding in sky gradients (a real fix, not just mood) — but keep it *under* perception at normal viewing. All three land in `tonemap.frag`, which has quietly become your "post stack."

### Screenshots done right

`gl.ReadPixels` reads the default framebuffer after the frame is drawn — but GL's origin is bottom-left, so the raw bytes are upside down for PNG. Odin's stb bindings handle both halves: the PNG writer lives in **`vendor:stb/image`** (the same package as the loader — there is no separate `vendor:stb/image_write` package, despite the C library split; verified at [pkg.odin-lang.org/vendor/stb/image](https://pkg.odin-lang.org/vendor/stb/image/)), and it includes `stbi.flip_vertically_on_write` so you don't even flip manually.

### Photo mode

Screenshot-worthy moments die to HUD clutter. Photo mode = one state: HUD/panel hidden, optionally simulation paused (your ch10 pause), free camera unlocked (your ch9 flycam — it never stopped existing), and F11 to capture. Twenty lines, infinite goodwill.

### The gamma/sRGB end-to-end audit

Color bugs are quiet and cumulative. Walk this checklist once, deliberately, with the code open — it covers every conversion in the now-complete pipeline:

- [ ] **Albedo/diffuse textures** load as sRGB (`gl.SRGB8_ALPHA8` internal format, ch16) → linear in shader. ✓ for boat, buoys, terrain splats, vegetation, particle atlas tint textures.
- [ ] **Data textures are linear**: normal maps, metallic, roughness, AO, heightmaps, the BMFont/microui atlases, LUTs. No `SRGB8` on any of them.
- [ ] **Hand-authored colors** (sun radiance, fog tints, material factors, UI colors): decided policy? Ours: world-space colors are *linear*; UI colors are display-space (drawn after tonemap, untouched). Check the weather presets and lantern colors against this.
- [ ] **All lighting math in linear HDR** — no `pow(2.2)` anywhere except the single one at the end of `tonemap.frag` (grep proves it: `grep -rn "2.2" assets/shaders/` should return exactly one line. Run it. Really.)
- [ ] **Intermediate FBOs** (HDR, bloom, reflections) are float formats, no `GL_FRAMEBUFFER_SRGB` enabled anywhere (we gamma manually; mixing both = double-correction).
- [ ] **Screenshots** capture *after* tonemap+gamma (read the default framebuffer, not the HDR target) so PNGs match the screen.

### Shipping a Windows build

Odin compiles to a single exe, but your *game* is exe + `assets/`. The recipe:

- `odin build src -out:saltwind.exe -o:speed` — optimized build (`-o:speed` ≈ `-O2`; also consider `-disable-assert` for release; keep a debug build script too).
- `-subsystem:windows` — makes it a GUI app: **no console window** flashes up behind the game. Caveat: `fmt.println` output vanishes; gate your logging or write a logfile in release.
- Ship the folder: `saltwind.exe` + `assets/` side by side. Asset paths must be relative to the *exe*, not the working directory — resolve once at startup via `os.args[0]`'s directory (or `core:os/os2` executable-path helpers) and prefix all loads; double-clicking from Explorer vs running from a shell must both work.
- Zip it. Send it to a friend with a GPU and zero developer tools. *That moment — someone else sailing your ocean — is the actual final milestone.*

## Build

1. **Extend `tonemap.frag` into the post stack.** Order matters and is worth a comment block in the shader:

   ```glsl
   vec3 c = (hdr + bloom * u_bloom_strength) * u_exposure;  // scene-referred
   c = aces(c);                                             // tonemap -> [0,1]
   c = grade(c);                                            // lift/gamma/gain
   c *= vignette(v_uv);                                     // lens
   c += grain(v_uv, u_time);                                // sensor
   frag = vec4(pow(c, vec3(1.0 / 2.2)), 1.0);               // display
   ```

   Add `u_lift, u_gamma_rgb, u_gain, u_vignette, u_grain` uniforms and microui sliders under a "Grade" header. Spend twenty real minutes finding Saltwind's grade at golden hour *and* in storm gray — one grade must serve both (or lerp a second grade in with weather, exercise 2).

2. **F11 capture.**

   ```odin
   import stbi "vendor:stb/image"

   screenshot :: proc(w, h: i32) {
       pixels := make([]u8, int(w * h * 3), context.temp_allocator)
       gl.PixelStorei(gl.PACK_ALIGNMENT, 1)  // rows tightly packed: w*3 isn't always %4
       gl.ReadPixels(0, 0, w, h, gl.RGB, gl.UNSIGNED_BYTE, raw_data(pixels))
       stbi.flip_vertically_on_write(true)
       name := fmt.ctprintf("screenshot_%v.png", time.time_to_unix(time.now()))
       ok := stbi.write_png(name, w, h, 3, raw_data(pixels), w * 3)
       fmt.println(ok != 0 ? "saved" : "FAILED", name)
   }
   ```

   Call it at end-of-frame (after UI, before swap) when F11 was pressed. The `PACK_ALIGNMENT` line prevents the classic sheared-screenshot bug at odd window widths.

3. **Photo mode.** A `photo_mode: bool` toggled by P: hides HUD+panel, swaps to flycam, optionally `game.paused = true`. In photo mode, F11 should capture *before* any debug UI would draw (it already does, since UI is hidden). Bonus: slow time to 10% instead of pausing — drifting spray mid-burst photographs beautifully.

4. **Run the gamma audit.** The checklist above, every box, with findings fixed. Budget 30 minutes; expect to find at least one quiet bug (the usual suspects: a non-sRGB grass texture, a weather fog tint authored in display space, grain applied before tonemap).

5. **Release build script.** `build_release.bat` (or `.sh` for the road): build with the flags above, `robocopy assets` into `dist/`, zip. Add an `assets`-relative path resolver at startup if you've been load-bearing on the working directory. Test by double-clicking the exe from Explorer in `dist/` — *not* from your shell in the project root.

6. **Ship it.** Zip → a friend. Watch them play it badly and love it anyway. Take notes on everything they don't understand; that's your post-course backlog.

## Checkpoint

Golden hour through the finished post stack: blacks faintly teal, highlights faintly warm, corners gently dark, sky gradient band-free. P enters photo mode (HUD gone, camera free), F11 clicks like a camera and a correctly-oriented, correctly-colored PNG appears next to the exe.

- The screenshot PNG, opened in an image viewer, is pixel-identical in tone to the live game (no double gamma, not upside down).
- `grep -rn "2.2" assets/shaders/` returns exactly one line.
- The release zip runs on a machine (or at minimum a clean directory + double-click) with no Odin installed, no console window, assets loading.
- Grading sliders at defaults = ch44's image (polish is opt-in, not drift).

## Pitfalls

- **Screenshot is upside down.** You skipped `flip_vertically_on_write` (or flipped manually *and* called it — double flip is also upside down... no, it's right side up twice; the bug report you'll get is "sometimes upside down" — pick one mechanism).
- **Screenshot is sheared/diagonal garbage.** Row alignment: default `PACK_ALIGNMENT` is 4 and your width×3 bytes isn't a multiple of 4. The `PixelStorei` line above.
- **Screenshot colors darker than screen.** You read the HDR FBO (linear, pre-gamma) instead of the default framebuffer — bind FBO 0 before `ReadPixels`.
- **Release exe opens then instantly exits, no error.** Asset path failure with `-subsystem:windows` eating the panic message. Run the same exe from a terminal to see stderr, then fix the exe-relative paths; also write a `log.txt` in release builds.
- **Grain visibly crawls/swims in dark scenes.** Grain added *before* tonemap (it's getting exposure-scaled), or too strong. Display-space, ≤ 0.01.
- **Banding came back in the sky after grading.** Aggressive gamma-curve grading re-quantized the 8-bit output; nudge grain up slightly (its dithering role) or keep `u_gamma_rgb` within 0.8–1.25.

## Exercises

1. Bake your grade into a 32³ LUT: generate an identity cube in Odin, run it through `grade()` on the CPU, upload as `TEXTURE_3D`, swap the shader to one LUT sample. Verify it matches lift/gamma/gain to the eye, then keep whichever you prefer.
2. Weather-coupled grading: a second grade preset for Storm, lerped by the ch47 weather blend. Gray-green storms vs golden clears — the mood difference is startling.
3. Photo-mode extras: camera roll (Q/E), FOV zoom (scroll), and a composition-grid overlay (rule-of-thirds lines via the UI batcher) that hides in the capture.
4. **Stretch:** 4× supersampled screenshots — render one frame into a temporary 2×-size HDR target + post stack, read *that* back, downsample on the CPU (box filter). Your `Renderer` owning all targets (ch40) makes this a parameter, not a rewrite. Wallpapers ensue.

## Commit

`git commit -m "ch51: post stack (grade/vignette/grain), photo mode, F11 PNG, release build"`

[← Ch. 50: Deeper Waters](ch50-deeper-waters.md) · [Ch. 52: Beyond the Horizon →](ch52-epilogue-beyond-the-horizon.md)
