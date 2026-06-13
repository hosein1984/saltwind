# Chapter 50 — Deeper Waters *(optional)*

*Part 8 — Full Sail · Estimated time: each taster ≈ a weekend · learnopengl: [Geometry Shader](https://learnopengl.com/Advanced-OpenGL/Geometry-Shader), [Tessellation (guest)](https://learnopengl.com/Guest-Articles/2021/Tessellation/Tessellation), [Compute Shaders (guest)](https://learnopengl.com/Guest-Articles/2022/Compute-Shaders/Introduction)*

**What you'll see when done:** whichever you pick — a GPU-extruded wake ribbon, terrain that densifies under your bow, or rings rippling outward from your hull through a simulated water surface.

## Where we are

**This entire chapter is optional.** Saltwind is feature-complete without it; chapters 51–52 don't depend on anything here. These are three *tasters* of pipeline stages beyond the vertex/fragment world you've mastered — each sized to a curious weekend, each with the concept, the key shader code, and honest commentary about whether the industry still uses it. Two of the three need an OpenGL 4.x context, so we start there.

### Bumping the context safely (for tasters B and C)

Your ch1 window requests 3.3 core. Request higher *with a fallback* so the main game keeps running everywhere:

```odin
try_context :: proc(major, minor: i32) -> glfw.WindowHandle {
    glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, major)
    glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, minor)
    glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
    return glfw.CreateWindow(WIDTH, HEIGHT, "saltwind", nil, nil)
}
// in init:
window := try_context(4, 3)
gl_major, gl_minor := 4, 3
if window == nil { window = try_context(3, 3); gl_major, gl_minor = 3, 3 }
gl.load_up_to(gl_major, gl_minor, glfw.gl_set_proc_address)
```

Gate 4.x features on `gl_major >= 4` at runtime. Keep the 3.3 path working — that's the discipline that separates "I tried compute once" from "my renderer supports both." (Driver reality in 2026: any desktop GPU from the last decade does 4.3+; macOS is stuck at 4.1 — no compute — which is one reason the industry moved to Metal/Vulkan there.)

---

## Taster A — Geometry shaders: GPU wake extrusion *(GL 3.3 — no bump needed)*

### Concept

A geometry shader (GS) sits between vertex and fragment stages: it receives whole primitives and may **emit different ones** — amplify a point into a quad, a line into a ribbon. Your ch34 wake builds a triangle-strip mesh on the CPU every frame from the boat's trail points. A GS version uploads only the *centerline* (a line strip of trail points + widths) and grows the ribbon on the GPU:

```
CPU:  P0──P1──P2──P3   (line strip, ~64 verts)
GS :     emits per segment:
      L0══L1══L2══L3   (camera-facing... no — water-plane-facing
      R0══R1══R2══R3    quad strip, widening + fading with age)
```

```glsl
// wake.geom — key excerpt
layout(lines) in;                            // consume segments
layout(triangle_strip, max_vertices = 4) out;
in float v_age[];                            // per trail point
void main() {
    for (int i = 0; i < 2; ++i) {
        vec3 p   = gl_in[i].gl_Position.xyz; // world space here; project last
        vec3 dir = normalize(gl_in[1].gl_Position.xyz - gl_in[0].gl_Position.xyz);
        vec3 side = normalize(cross(dir, vec3(0, 1, 0)));
        float w = mix(0.4, 3.0, v_age[i]);   // wake widens as it ages
        g_uv = vec2(0.0, v_age[i]); gl_Position = u_vp * vec4(p - side * w, 1.0); EmitVertex();
        g_uv = vec2(1.0, v_age[i]); gl_Position = u_vp * vec4(p + side * w, 1.0); EmitVertex();
    }
    EndPrimitive();
}
```

Declare it in your shader loader (`gl.load_shaders_file` handles vertex+fragment; for the GS, compile/attach the extra stage yourself with `gl.CreateShader(gl.GEOMETRY_SHADER)` — a 15-line extension to ch4's `shader_load`).

### The honest caveat

GS performance is notoriously poor on real hardware: outputs are written through memory, parallelism collapses, and per-primitive amplification defeats the rasterizer's assumptions. The industry verdict came in years ago — instancing (which you know) and compute-generated geometry (taster C's cousin) won; Vulkan-era "mesh shaders" formalized the replacement. Learn the GS as a *concept* — "stages can create primitives" — and as a fine tool for debug visualizations (normals-as-lines is the classic, see the learnopengl article), not as a production technique.

**Build sketch:** keep the CPU trail point list (it's your data model), upload as `GL_LINE_STRIP` with age attribute, GS as above, fragment shader = your existing wake foam texture/fade. **Checkpoint:** identical-looking wake, CPU wake-mesh code deleted, draw data 10× smaller. **Exercise:** the normals-visualizer GS — 20 minutes, useful forever.

---

## Taster B — Tessellation: distance-adaptive terrain *(GL 4.0+)*

### Concept

Two new stages between vertex and geometry: the **tessellation control shader (TCS)** decides *how finely* to subdivide each patch; fixed-function hardware subdivides; the **tessellation evaluation shader (TES)** positions the new vertices — for terrain, by sampling your heightmap. Net effect: a coarse patch grid becomes dense exactly where the camera is. It's ch49's chunk LOD, continuous and per-patch, with crack-free seams if neighboring edges agree on tessellation level:

```glsl
// terrain.tcs — outer levels from edge-midpoint distance to camera
float lvl(vec3 a, vec3 b) {
    float d = distance(u_cam_pos, (a + b) * 0.5);
    return clamp(64.0 * exp(-0.01 * d), 1.0, 64.0);
}
gl_TessLevelOuter[0] = lvl(p1, p3);  // shared edges -> shared levels -> no cracks
...
```

```glsl
// terrain.tes — bilinear patch interp + heightmap displacement
layout(quads, fractional_odd_spacing, ccw) in;
vec3 p = mix(mix(p0, p1, gl_TessCoord.x), mix(p3, p2, gl_TessCoord.x), gl_TessCoord.y);
p.y = texture(u_heightmap, p.xz / u_world_size).r * u_height_scale;
```

Draw with `gl.PatchParameteri(gl.PATCH_VERTICES, 4)` and `gl.DrawArrays(gl.PATCHES, ...)`. You'll need your terrain heights in a *texture* (you have the data; upload it R16F or R32F per island) since the TES displaces by sampling, and normals from the heightmap in the fragment shader (central differences — ch22's math, moved to GLSL).

This one *is* production-relevant — many engines tessellate terrain and water. The cost is restructuring: heights move from baked vertices to textures. Treat it as a parallel experiment off a git branch; the guest article walks the full setup. **Checkpoint:** wireframe toggle (`gl.PolygonMode(gl.FRONT_AND_BACK, gl.LINE)`) shows triangle density blooming around the camera and starving at distance, no cracks at patch seams, and your ch49 panel shows scene vertex cost flat as you sail toward mountains. **Exercise:** drive level also by terrain *roughness* (precomputed slope-variance texture) so flat beaches stay coarse even up close.

---

## Taster C — Compute shaders: interactive water ripples *(GL 4.3+)*

### Concept

A compute shader is a GPU program with **no pipeline attached** — no vertices, no fragments; just "run N×M threads, here are some textures/buffers." It's the most important of the three tasters: compute is the future (and present) of GPU work, and this is the foundation your eventual FFT-ocean (ch52's expansion map) stands on.

The project: a classic height-field ripple simulation in a texture, displacing your ocean near the boat. Two ping-pong R32F textures (prev/curr height), one compute dispatch per frame running the wave equation stencil, result sampled additively in the ocean vertex shader:

```glsl
// ripple.comp
#version 430
layout(local_size_x = 16, local_size_y = 16) in;
layout(r32f, binding = 0) uniform image2D u_prev;
layout(r32f, binding = 1) uniform image2D u_curr;
layout(r32f, binding = 2) uniform image2D u_next;

void main() {
    ivec2 p = ivec2(gl_GlobalInvocationID.xy);
    float c  = imageLoad(u_curr, p).r;
    float sum = imageLoad(u_curr, p + ivec2( 1, 0)).r
              + imageLoad(u_curr, p + ivec2(-1, 0)).r
              + imageLoad(u_curr, p + ivec2(0,  1)).r
              + imageLoad(u_curr, p + ivec2(0, -1)).r;
    float next = (sum * 0.5 - imageLoad(u_prev, p).r) * 0.996; // wave eq + damping
    imageStore(u_next, p, vec4(next, 0, 0, 0));
}
```

```odin
gl.UseProgram(ripple_program)             // compiled with gl.COMPUTE_SHADER
gl.BindImageTexture(0, prev_tex, 0, false, 0, gl.READ_ONLY,  gl.R32F)
gl.BindImageTexture(1, curr_tex, 0, false, 0, gl.READ_ONLY,  gl.R32F)
gl.BindImageTexture(2, next_tex, 0, false, 0, gl.WRITE_ONLY, gl.R32F)
gl.DispatchCompute(SIM_SIZE / 16, SIM_SIZE / 16, 1)
gl.MemoryBarrier(gl.SHADER_IMAGE_ACCESS_BARRIER_BIT | gl.TEXTURE_FETCH_BARRIER_BIT)
// rotate prev <- curr <- next
```

The pieces: a 512² sim grid mapped to a 60 m square that **follows the boat** (offset uniform; fade the field at grid edges); each frame *splat* a disturbance under the hull (a tiny second dispatch writing a Gaussian bump at the boat's grid position, scaled by speed); the ocean vertex shader adds `texture(u_ripple, world_to_sim_uv(p.xz)).r` to the Gerstner height, masked to the sim region. The `MemoryBarrier` is the new concept worth internalizing: compute writes aren't visible to later reads until you say so — implicit ordering is a rasterization-pipeline luxury you just left behind.

**Checkpoint:** circular wavefronts expand from your moving hull, reflect subtly off... nothing (open boundary), and lap visibly against the Gerstner swell; a buoy dropped in (debug key splat) rings like a struck bell. **Exercise:** sample the ripple field's gradient in the water fragment shader and perturb the normal — the rings catch sunlight. **Stretch:** make terrain shorelines reflect ripples (zero out propagation where `terrain_height_at > sea level` — sample a mask texture).

---

## Pitfalls (all three tasters)

- **GS: nothing renders.** Input primitive declaration mismatches the draw mode (`layout(lines) in` requires `GL_LINES`/strip draws), or you forgot `EndPrimitive()`.
- **Tessellation: nothing renders.** Drawing `gl.TRIANGLES` instead of `gl.PATCHES`, or no TCS *and* no default patch levels set. Also: with tessellation active, your vertex shader runs per *control point* — don't apply MVP there; project in the TES.
- **Tessellation: cracks between patches.** Outer levels computed from non-shared data (e.g. patch center distance). Edge levels must derive *only* from that edge's endpoints, which neighbors share.
- **Compute: stale or garbage data.** Missing `gl.MemoryBarrier` between dispatch and consumption, or wrong barrier bit (image access for `imageLoad`, texture fetch for `texture()` sampling).
- **Compute: black sim after resize/alt-tab.** R32F image binding with a format mismatch fails silently on some drivers — re-check `BindImageTexture` formats match the texture's actual internal format.
- **Everything: it works on your machine, crashes on a 3.3-only laptop.** You gated on compile-time, not runtime context version. Keep the fallback honest.

## Commit

`git commit -m "ch50: taster(s) — <gs-wake|tessellated-terrain|compute-ripples>"`

[← Ch. 49: The Cost of Beauty](ch49-the-cost-of-beauty.md) · [Ch. 51: The Finish Coat →](ch51-the-finish-coat.md)
