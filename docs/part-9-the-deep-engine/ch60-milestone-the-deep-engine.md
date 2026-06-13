# Chapter 60 — MILESTONE: The Deep Engine

*Part 9 — The Deep Engine · Estimated time: 4–6h · learnopengl: review of [Deferred Shading](https://learnopengl.com/Advanced-Lighting/Deferred-Shading), [SSAO](https://learnopengl.com/Advanced-Lighting/SSAO), [CSM](https://learnopengl.com/Guest-Articles/2021/CSM)*

**What you'll see when done:** a night harbor under a hundred lantern flames — deferred light pooling on black water, god rays in the lamp-mist, every render pass listed in your panel with a checkbox and its price.

## Where we are

Count what one frame does now: shadow cascades ×4, planar reflection + refraction, G-buffer geometry, SSAO + blur, deferred lighting + light volumes, forward ocean/sky/transparents, SSR, two god-ray passes, bloom, tonemap, FXAA, UI. That's ~18 passes grown organically across 20 chapters — and `main`'s render section knows it. Milestone work: give the frame a *shape* (an ordered, toggleable, self-timing pass list), sweep the cross-system integrations that seven fast chapters left dangling, and stage the screenshot this part earned. Minimal new theory; mostly the honest carpentry that keeps a renderer alive.

## Concepts (brief)

### A pass list, deliberately not a render graph

Big engines build render *graphs*: passes declare resource reads/writes, a compiler derives execution order, lifetimes, and (on modern APIs) barriers, and transient targets share memory. You need none of that machinery: GL handles hazards in the driver, your target set is small and static, and your order is *known* — it's been the same diagram since ch55. What you actually need is what a graph would also give you, minus the compiler: **explicit ordering in data instead of code sprawl, per-pass toggles, and per-pass timing.** An array of structs does all three. Build the simple thing; you'll know precisely what a render graph automates if Vulkan ever calls (ch52's epilogue already pointed there).

```odin
Render_Pass :: struct {
    name:    string,
    enabled: bool,
    debug_only_off: bool,            // some passes can't really be skipped safely
    timing:  ^Pass_Timing,           // ch49 profiler slot
    execute: proc(r: ^Renderer, g: ^Game),
}
// Renderer gains: passes: [dynamic]Render_Pass
```

The frame loop becomes: for each enabled pass — push debug group, begin timing, `execute`, end, pop. One screen of code replacing a hundred lines of bespoke sequence, and the microui panel can now be *generated* from it.

For the record — and for future-you — the full frame as registered today:

```
 csm_update         CPU: splits, sphere fits, snapping
 shadow_cascades    4 layers, culled per cascade
 planar_reflect     half-res mirrored mini-frame (ocean's)
 planar_refract     half-res
 geometry           G-buffer: terrain, boat, props, instances
 ssao + ssao_blur   R8, ambient occlusion estimate
 deferred_light     fullscreen sun+IBL(×AO)+emissive, then volumes
 forward            sky, ocean (planar+CSM), wake, transparents
 particles          soft, vs shared depth
 ssr                half-res march + composite
 godrays_march      half-res volumetric (CSM), bilateral up
 godrays_radial     bright-pass + radial blur (sun on screen)
 bloom              ping-pong chain
 tonemap            ACES + grading + luma→alpha, into LDR
 fxaa               LDR → backbuffer
 ui                 text, panel, HUD
```

Sixteen named entries. If reading that list gives you a small proprietary thrill — that's the milestone.

Toggle semantics need one honest note: some passes compose additively (SSAO, SSR, god rays, bloom, FXAA — skip them and the frame degrades gracefully, which is exactly what makes the toggles such good debugging) while others are load-bearing (skip the geometry pass and lighting reads stale data; skip tonemap and you present raw HDR). Mark the load-bearing ones `debug_only_off` and let the panel show them dimmed. Knowing *which* passes are skippable is itself an understanding-check of your own frame.

## Build

1. **The pass list.** Move each pass's body into a `proc(r: ^Renderer, g: ^Game)` (most already are, near enough), register them in order at startup, and rewrite the frame loop:

   ```odin
   renderer_execute :: proc(r: ^Renderer, g: ^Game) {
       for &pass in r.passes {
           if !pass.enabled do continue
           gl.PushDebugGroup(gl.DEBUG_SOURCE_APPLICATION, 0, -1, cstring(raw_data(pass.name)))
           profiler_begin_pass(&g.profiler, pass.timing)
           pass.execute(r, g)
           profiler_end_pass(&g.profiler, pass.timing)
           gl.PopDebugGroup()
       }
   }
   ```

   (Keep pass names as string literals so the `cstring` cast is safe — literals are NUL-terminated in Odin.) One place now owns name/timing/label consistency. Diff a RenderDoc capture against last chapter's: identical event stream, tidier tree.

2. **The panel, generated.** Replace the hand-built Frame section:

   ```odin
   if .ACTIVE in mu.header(ctx, "Passes") {
       mu.layout_row(ctx, {140, 30, 60})
       total: f32
       for &pass in renderer.passes {
           mu.checkbox(ctx, pass.name, &pass.enabled)
           mu.label(ctx, pass.debug_only_off ? "*" : "")
           mu.label(ctx, fmt.tprintf("%.2f ms", pass.timing.gpu_ms))
           total += pass.timing.gpu_ms
       }
       mu.label(ctx, fmt.tprintf("gpu total: %.2f ms", total))
   }
   ```

   Flip everything off and back on one by one — this is now your fastest "which pass broke it" bisector, and your renderer's table of contents.

3. **Integration sweep — water shadows (ch39 → ch57).** The ocean shader still samples the *old single shadow map* through ch39's hook. Point it at the cascade array via the shared CSM `#include` (the forward path already links it — ch57 step 5). Sunset cliff shadows should now stretch across the water all the way out, in the right cascade.

4. **Integration sweep — SSAO ↔ everything.** Verify the checklist from ch56 holds after all the later passes landed: AO multiplies IBL ambient only — not direct sun, not emissive, not the SSR term twice (SSR replaces IBL *specular*; if you multiplied IBL spec by AO, multiply SSR's contribution the same way, once). The AO-only and SSR-confidence debug views make this a five-minute audit.

5. **Integration sweep — the reflection chain, end to end.** One sunset frame must show: deck = SSR (fading politely at screen edges), sea = planar through wave distortion, rough rock = prefiltered IBL — with no surface getting two of them added together. Check Fresnel weighting is applied once, in one place.

6. **Integration sweep — the tail order audit.** The post stack accreted across two parts; confirm the order is exactly: bloom (HDR) → tonemap + grading + vignette (HDR→LDR, luma→alpha) → FXAA (LDR) → photo-mode overlay and UI (after FXAA, never smeared). If ch51's grading ended up after FXAA, the luma alpha FXAA depends on is gone — this audit catches it.

7. **Integration sweep — air and weather.** God rays' density/g/extinction come from the Weather block (ch59 step 5); confirm storm → gloom-no-shafts, post-rain haze → drama. Then the interplay nobody scripted: rain wets the deck (ch58 hook) *while* the clearing sky throws shafts — your systems are now generating moments on their own. Let one happen.

8. **Night harbor — screenshot #7.** Stage it: time near midnight, weather light-mist, anchor in a cove (kill way and rudder input — a simple anchored flag), scatter ~100 lanterns along the shoreline and on buoys (ch55's fleet, swaying with exercise 2's wind sway if you did it), moon low. Deferred carries a hundred lights; SSAO seats every crate and cleat; lantern god-ray halos if you did ch59 exercise 2. Photo mode (ch51), shoot wide and one close-up of lamplight on wet planks.

9. **The honesty pass.** With the scene above on screen, read the panel top to bottom and confirm every number is believable and every toggle does what its name says. Write the frame total and the three fattest passes into the commit message. This is the baseline Part 10's compute work gets measured against.

## Checkpoint — Part 9 self-test

- The frame is data: passes execute from the list, in order, each with name, toggle, debug group, and GPU ms.
- Toggling SSAO / CSM-tint / SSR / god rays / FXAA each produces its expected, isolated visual change at 60 fps.
- Water receives cascaded shadows; no code references the ch39 single map anymore (delete it — actually delete it).
- 100-lantern night harbor renders with frame time in budget; you know its three most expensive passes without guessing.
- Screenshot #7 exists and you're proud of it.

## Quiz

Answers under each fold — write yours down first.

1. **In MSAA, why does a 4× target cost ~4× the memory but nowhere near 4× the shading time?**
   <details>Coverage, depth, and color storage are per-sample, but the fragment shader still runs once per pixel per covered primitive — only edge pixels touched by several primitives shade more than once. Storage scales with N; shading scales with coverage complexity. (Which is also why MSAA can't fix shading aliasing.)</details>

2. **Your G-buffer has no position attachment. Reconstruct: what exactly turns a depth-buffer value plus a pixel's uv back into a view-space position?**
   <details>uv and depth remapped from [0,1] to [−1,1] form an NDC point; multiplying by the inverse projection gives a homogeneous view-space point; dividing by the resulting w undoes the perspective divide. World space needs one more multiply by the inverse view matrix.</details>

3. **Why does the ocean stay forward in a deferred renderer?**
   <details>A G-buffer stores exactly one surface per pixel; transparency/blending needs contributions from multiple surfaces per pixel (water over seabed, particles over everything). The ocean also wants its own exotic inputs (planar FBOs, refraction, depth-tint) that don't fit the shared G-buffer material model.</details>

4. **A teammate multiplies the sun's direct lighting by the SSAO term and the corners "look amazing." What do you tell them?**
   <details>AO approximates occlusion of ambient (omnidirectional) light only; the sun's occlusion is the shadow map's job, computed against the actual sun direction. AO-on-direct double-darkens sunlit creases and reads as dirt — if shadowed corners need help, tune shadows or IBL, not AO scope.</details>

5. **What two properties must each cascade's ortho box have so shadow edges don't shimmer as the camera moves, and why?**
   <details>Constant size (fit the slice's enclosing sphere, not the tight corner AABB — size then doesn't change as the camera rotates) and texel-snapped position (translate only in whole-texel increments in light space). Both ensure the shadow map's world-space sampling grid never re-rasterizes the same geometry differently between frames.</details>

6. **Name the three SSR confidence fades and the failure each one hides.**
   <details>Screen-edge fade (hit data ends at the frame border — reflections would pop as the camera turns); facing fade for rays bent back toward the camera (they'd need backface/occluded data the buffer never stored); ray-length/no-hit fade (long marches accumulate error and misses must hand off to IBL rather than go black).</details>

7. **Build B god rays sample the CSM in mid-air. Why does ch39/ch57's slope-scaled bias make no sense there, and what replaces it?**
   <details>Slope-scaled bias compensates for a *surface's* angle relative to the light — a point in air has no surface or slope. A small constant bias suffices to clear depth quantization.</details>

8. **Why a flat pass list instead of a render graph — and what's the first *real* requirement that would change the answer?**
   <details>The order is static, targets are few and persistent, and GL's driver already handles hazards — a graph would automate decisions we never need to make. The answer flips when resources become transient/aliased or ordering becomes dynamic — e.g. explicit-API barriers (Vulkan) or memory pressure demanding target reuse between passes.</details>

## Screenshot checklist

- [ ] **#7 — Night harbor:** anchored in the cove, ~100 lanterns, moon, mist halos, lamplight pooling on dark water.
- [ ] Close-up: lantern light on wet deck planks — SSR + wetness + bloom in one frame.
- [ ] Debug beauty: the G-buffer quadrant view of the harbor — albedo/normals/roughness/depth. Engine programmers' pinup.
- [ ] The panel itself: full pass list with timings. Screenshot it for the before/after when Part 10 rewrites the ocean.

Share the harbor shot — the Odin Discord's #showcase and [r/odinlang](https://reddit.com/r/odinlang) have watched Saltwind grow since ch13, and "the renderer went deferred" posts with a hundred lights tend to start good conversations. Mention the forward-vs-deferred ms numbers from ch55; people love receipts.

## When you come back

*Recap for future-you:* Part 9 turned the renderer modern. The context is GL 4.3 with a debug callback; RenderDoc is your eyes. Opaques render to a G-buffer (albedo+metallic / normal+roughness / emissive, position from depth) and are lit deferred — fullscreen sun+IBL, sphere volumes per point light; ocean, sky, and particles stay forward sharing the depth buffer. SSAO darkens IBL ambient only. Shadows are 4 stabilized cascades in an array texture, shared by surfaces, water, and the volumetric god-ray march (HG phase, dithered, half-res). Reflections fall back SSR → planar (sea) → IBL. FXAA cleans edges post-tonemap. Every pass lives in `Renderer.passes` — name, toggle, GPU ms — and the panel is the map. Sail the night harbor for ten minutes before touching anything; then make for [Part 10](../part-10-the-true-ocean/ch61-the-parallel-sea.md), where compute shaders retire the Gerstner ocean for the real thing.

## Commit

`git commit -m "ch60: milestone — pass list with toggles+timings, integration sweep, night harbor (frame: Xms)"`

[← Ch. 59: Shafts of Light](ch59-shafts-of-light.md) · [Ch. 61: The Parallel Sea →](../part-10-the-true-ocean/ch61-the-parallel-sea.md)
