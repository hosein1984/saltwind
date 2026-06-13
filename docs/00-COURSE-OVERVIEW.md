# SALTWIND
## Building an Island Sailing World in Odin + OpenGL — A Project Course

> *You start with a black window. Fifty-two chapters later you're sailing a boat through a procedural archipelago at golden hour, with Gerstner waves under the hull, shadows stretching across the islands, bloom on the sun, and foam trailing in your wake. Every chapter makes the world visibly better — that's the deal.*

---

## 1. What this course is

[learnopengl.com](https://learnopengl.com) is the best OpenGL reference on the internet, but it's a *reference*: isolated demos with a containerized cube or backpack model, no thread pulling you forward. This course re-sequences essentially all of its material (plus terrain, water, procedural generation, and game architecture that it doesn't cover) into **one continuous project**: a small open-water sailing world called **Saltwind**, written in **Odin**.

Three rules govern the design:

1. **Every chapter ends with something visible.** No chapter is "infrastructure only". If you must build plumbing, the chapter bends the plumbing into a visual payoff the same day.
2. **The project is the curriculum.** You never write throwaway demo code. The triangle from Chapter 3 becomes the quad in Chapter 5, becomes the sea surface in Chapter 12, becomes the Gerstner ocean in Chapter 28.
3. **Milestones, not marathons.** Every part ends in a *Milestone chapter* — a deliberately satisfying checkpoint with a "screenshot moment", a self-test checklist, and a natural place to pause for days or weeks without losing the thread.

The course has two arcs: the **core course** (Parts 1–8, Ch. 1–52) takes you from a black window to a finished, gorgeous, sailable world covering all of learnopengl and more. The **Far Horizon expansion** (Parts 9–12, Ch. 53–84) then takes that world to professional-grade: a modern multi-pass renderer, a Tessendorf FFT ocean, volumetric clouds and living systems, and an actual itch.io release. Chapter 52 is a real ending — the expansion is for when finishing makes you hungrier.

**You write the code.** Chapters explain the concept, show the key Odin/GLSL excerpts, and give you explicit build steps and verification checkpoints — but the full program is yours. When you're stuck, the corresponding learnopengl article (linked in every chapter) is your reference-depth backup.

## 2. Why a sailing world?

It is the rare project that *naturally* demands nearly every topic in real-time graphics, in a sensible order:

| You want... | ...so you must learn |
|---|---|
| A sea | huge meshes, vertex animation, transparency, fresnel, reflections |
| Islands | heightmaps, procedural noise, normals, texture splatting, culling |
| A sky | cubemaps, atmospheric scattering, day/night, HDR |
| A boat | model loading, scene transforms, physics, buoyancy, cameras |
| Wind & weather | particles, fog, instancing, simulation |
| Beauty | shadow mapping, bloom, PBR, IBL, tone mapping |
| Playability | input architecture, fixed timesteps, game state, UI |

And it has the motivation profile of a good hobby project: the loop "make the water 5% nicer → sail around in it for ten minutes" is dangerously compelling.

## 3. Prerequisites & toolchain

You: comfortable writing Odin, did OpenGL long ago (we re-teach all graphics from zero; we do *not* teach Odin syntax, though we flag Odin-specific idioms whenever they matter for GL work).

- **Odin** (latest release) + **OLS** for your editor
- **OpenGL 3.3 core profile** as the baseline (matching learnopengl), with clearly-marked "modern GL (4.x)" sidebars where DSA or compute would be used in production
- Everything else ships *with* Odin — no dependency hunt:
  - `vendor:glfw` — windowing/input
  - `vendor:OpenGL` — loader + handy `load_shaders_file` helpers
  - `vendor:stb/image` — texture loading
  - `core:math/linalg/glsl` — vectors/matrices that mirror GLSL types
  - `core:math/noise` — simplex noise for terrain
  - `vendor:cgltf` (optional, Ch. 17), `vendor:microui` (Ch. 48), `vendor:miniaudio` (Ch. 36)
- The `ash-main/` ECS library already in this folder gets an optional starring role in Chapter 35.

API references you'll live in: [pkg.odin-lang.org/vendor/glfw](https://pkg.odin-lang.org/vendor/glfw/), [pkg.odin-lang.org/vendor/OpenGL](https://pkg.odin-lang.org/vendor/OpenGL/), [docs.gl](https://docs.gl), and learnopengl chapter links throughout.

## 4. How to work the course

- **Pace:** 1–3 chapters/week is sustainable. Milestone parts are sized to ~2–5 weeks each. The core course is realistically **6–12 months** of hobby time; the Far Horizon expansion adds another 4–8. That is a feature: it's a journey, not a sprint.
- **Per chapter:** read Concepts → do Build Steps → pass the Checkpoint → do at least one Exercise → commit with the suggested message. The git history becomes your progress bar.
- **When stuck >45 min:** read the linked learnopengl article in full, then return. Still stuck → the chapter's *Pitfalls* section lists the classic failure modes (black screen, inverted normals, etc.) and how to diagnose each.
- **Don't skip Milestone chapters.** They contain the integration work and refactors that keep the codebase healthy enough to survive 52 chapters.

## 5. The roadmap

*Rows marked ⚓ are **optional interludes** — self-contained side quests slotted where their prerequisite is freshest. Skip them freely on a first pass; each one's host chapter points to it, and nothing downstream requires them.*

### Part 1 — First Light *(Ch. 1–8)*
*From a black window to a textured, transformed scene in 3D. Maps to learnopengl "Getting Started".*

| Ch. | Title | You build | learnopengl |
|---|---|---|---|
| 1 | The Shoreline Ahead | Project setup, Odin + GLFW window, the vision | Creating a window |
| 2 | Heartbeat | Render loop, GL loading, clear color = sea blue, delta time, input polling | Hello Window |
| 3 | First Triangle | VBO/VAO, vertex+fragment shaders, the pipeline | Hello Triangle |
| 4 | The Shader Forge | `Shader` abstraction: load from file, error reporting, uniform helpers | Shaders |
| 5 | Quads & Indices | EBO, interleaved attributes, a sea-colored quad filling the horizon | Hello Triangle (EBO) |
| 6 | Pixels from Disk | Textures via stb_image, filtering, mipmaps, a sand texture | Textures |
| 7 | The Mathematics of Motion | Vectors, matrices, `linalg/glsl`, transform composition | Transformations |
| 8 | Into the Third Dimension | MVP matrices, depth buffer, perspective — a crate floating above a blue plane | Coordinate Systems |

### Part 2 — Standing on Deck *(Ch. 9–13)*
*A camera, a real mesh system, and an endless flat sea. The world becomes a place.*

| Ch. | Title | You build | learnopengl |
|---|---|---|---|
| 9 | Free as a Gull | Fly camera: mouse look, WASD, zoom | Camera |
| 10 | The Pulse of the World | Input architecture, fixed timestep vs render delta, pause | (none — game arch.) |
| 11 | Meshes that Matter | `Mesh` type, vertex layout descriptors, procedural cube/sphere/grid | (none — engine arch.) |
| 12 | A Flat Blue Forever | Large sea grid, horizon, simple distance fade, camera-following sea tile | (none) |
| 13 | **MILESTONE: First Voyage** | Fly endlessly over open water with floating crates; screenshot moment #1 | review |

### Part 3 — Let There Be Light *(Ch. 14–19)*
*The sun rises on Saltwind. Maps to learnopengl "Lighting" + model loading.*

| Ch. | Title | You build | learnopengl |
|---|---|---|---|
| 14 | One Sun | Phong: ambient/diffuse/specular, normals on your primitives | Basic Lighting |
| 15 | Materials of the Sea-World | Material structs, sun as directional light, lantern point lights, attenuation | Materials, Light Casters |
| 16 | Honest Colors | Normal matrix, gamma correction, sRGB textures | Adv. Lighting: Gamma |
| 17 | Shapes from Elsewhere | Hand-rolled OBJ loader (+ `vendor:cgltf` sidebar); load a buoy & boat hull | Model Loading |
| 18 | The Family Tree | Transform hierarchy / scene nodes (mast on hull on sea) | (none) |
| 19 | **MILESTONE: Sunlit Waters** | Lit buoys bobbing (sine for now) on the sea, movable sun; screenshot #2 | review |

### Part 4 — Raising Islands *(Ch. 20–25)*
*Procedural terrain: the archipelago is born.*

| Ch. | Title | You build | learnopengl |
|---|---|---|---|
| 20 | Land from Numbers | Heightmap → indexed terrain grid, height-based color | (Guest: Tessellation heightmap article) |
| 21 | The Noise of Creation | fBm simplex noise (`core:math/noise`), island falloff masks, seeds | (none) |
| 22 | The Lay of the Land | Terrain normals (central differences), slope/height texture splatting | (none) |
| 23 | A World in Pieces | Terrain chunks, AABBs, frustum culling | (Guest: Frustum culling) |
| 24 | Where Land Meets Sea | Shoreline blending, depth-tinted shallows, sand-to-grass gradients | Blending (preview) |
| 25 | **MILESTONE: The Archipelago** | Fly over a seeded island chain; pick your world seed; screenshot #3 | review |
| 25a ⚓ | The World Unmoored | Floating origin: rebase the world around the camera; f32 precision made safe | (none) |

### Part 5 — The Living Sea & Sky *(Ch. 26–31)*
*The flat blue plane becomes an ocean under a real sky.*

| Ch. | Title | You build | learnopengl |
|---|---|---|---|
| 26 | A Box of Sky | Cubemaps, skybox rendering, early-depth trick | Cubemaps |
| 27 | The Procedural Heavens | Gradient/scattering sky shader, sun disk, day/night cycle, moving sun dir | (none) |
| 28 | Waves that Roll | Sum-of-sines → Gerstner waves in the vertex shader, wave params | (none) |
| 29 | The Color of Water | Analytic normals, fresnel, sky reflection, depth-based color, specular sun glitter | Cubemaps (env mapping) |
| 30 | Through the Looking Glass | Framebuffers, render-to-texture, planar reflection+refraction, distortion (DuDv) | Framebuffers |
| 31 | **MILESTONE: Ocean at Sunset** | The signature shot: rolling reflective sea at dusk; screenshot #4 | review |

### Part 6 — Setting Sail *(Ch. 32–37)*
*From flycam spectator to sailor. This is where it becomes a game.*

| Ch. | Title | You build | learnopengl |
|---|---|---|---|
| 32 | She Floats | Buoyancy: sample wave height/normal at hull points, bobbing & alignment | (none) |
| 33 | The Wind in Your Sail | Wind model, sail trim & rudder controls, simple sailing physics, follow camera | (none) |
| 34 | Cutting the Water | Bow foam, stern wake (scrolling textures + alpha), blending for real | Blending |
| 35 | A Place for Everything | Game architecture: systems & state — optionally with the `ash` ECS in this folder | (none) |
| 36 | The Sound of the Sea *(optional)* | `vendor:miniaudio`: wind/wave loops, positional gull cries | (none) |
| 37 | **MILESTONE: Maiden Voyage** | Sail boat between two named islands; a compass course; screenshot #5 | review |

### Part 7 — Advanced Light *(Ch. 38–44)*
*The "Advanced Lighting" + PBR arc: from nice to gorgeous.*

| Ch. | Title | You build | learnopengl |
|---|---|---|---|
| 38 | Depths & Stencils | Depth functions deep-dive, stencil outline of the boat, face culling audit | Depth/Stencil Testing, Face Culling |
| 39 | Shadows on the Water | Directional shadow mapping, PCF, bias tuning, follow-the-camera shadow box | Shadow Mapping |
| 39a ⚓ | Lanterns in the Dark | Omnidirectional (cube-map) point shadows — your lanterns finally cast them | Point Shadows |
| 40 | More Light than Screen | HDR pipeline, floating-point framebuffer, tone mapping (Reinhard → ACES) | HDR |
| 40a ⚓ | The Eye Adjusts | Auto-exposure: luminance reduction, eye-adaptation lag, exposure compensation | (none) |
| 41 | The Sun Bleeds | Bloom: bright-pass, separable Gaussian blur, additive composite | Bloom |
| 42 | Physically Based | PBR theory: BRDF, metallic/roughness; convert boat & lantern materials | PBR Theory/Lighting |
| 42a ⚓ | Depth in the Planks | Parallax occlusion mapping on deck planks and rock faces | Parallax Mapping |
| 43 | Light from Everywhere | IBL: irradiance map, prefiltered environment, BRDF LUT — from your own sky | PBR IBL (both) |
| 44 | **MILESTONE: Golden Hour** | The screenshot you'll show people. Tune until proud; screenshot #6 | review |

### Part 8 — Full Sail *(Ch. 45–52)*
*Scale, life, weather, polish — and where to sail next.*

| Ch. | Title | You build | learnopengl |
|---|---|---|---|
| 45 | A Thousand Things | Instancing: palms, rocks, grass tufts, a flock of gulls | Instancing |
| 46 | Spray & Storm | Particle system: sea spray, rain; billboarding, soft particles | (Guest: particles) |
| 46a ⚓ | Glass Without Sorting | Weighted-blended order-independent transparency for sails, wake, spray | OIT (guest) |
| 47 | The Breath of Distance | Height/distance fog, atmospheric perspective, weather state machine | (none) |
| 48 | Words on Glass | Debug UI with `vendor:microui`, bitmap font text, compass & wind HUD | Text Rendering |
| 49 | The Cost of Beauty | Profiling, GPU timers, draw-call batching, terrain LOD, the frame budget | (Guest: debugging) |
| 50 | Deeper Waters *(optional)* | Tasters: geometry shaders (wake trails), tessellated terrain, compute-shader ripples | Geometry Shader, Compute |
| 51 | The Finish Coat | Color grading, vignette, screenshot mode, gamma audit, packaging a build | review |
| 52 | **EPILOGUE: Beyond the Horizon** | Retrospective + expansion map: FFT oceans, volumetric clouds, Vulkan, trading-game ideas | — |

### ⛵ THE FAR HORIZON — Expansion Parts 9–12 *(Ch. 53–84)*

*The core course (Parts 1–8) ends with a finished, beautiful, sailable world. The Far Horizon takes it to "shining": a modern multi-pass renderer, an FFT ocean, a living sky and sea, and an actual shipped game. Recommended order is 9 → 10 → 11 → 12 (Part 9's GL 4.3 bump and RenderDoc skills underpin 10 and 11; Part 12 can technically start any time after Ch. 37). Each remains milestone-gated, so each is a legitimate stopping point.*

### Part 9 — The Deep Engine *(Ch. 53–60)*
*The modern-renderer arc: from "forward renderer with passes" to a real pipeline.*

| Ch. | Title | You build | learnopengl |
|---|---|---|---|
| 53 | Seeing Like the GPU | RenderDoc mastery, `glDebugMessageCallback`, raising the context to 4.3 core (with fallback plan) | Debugging |
| 54 | Smooth Sailing Edges | Aliasing theory, MSAA on FBOs + resolve, FXAA post pass, TAA survey | Anti Aliasing |
| 54a ⚓ | Ghosts & How to Bust Them | Full TAA: velocity buffer, history reprojection, neighborhood clamping | (none) |
| 55 | The Deferred Fleet | G-buffer, geometry/lighting split, light volumes, 100 lanterns at night; why the ocean stays forward | Deferred Shading |
| 56 | Shadows in Corners | SSAO: hemisphere kernel, noise rotation, blur, wiring into ambient/IBL | SSAO |
| 57 | Shadows Far and Near | Cascaded shadow maps: splits, per-cascade fit, seam blending, stabilization | CSM (guest) |
| 58 | Mirrors of the Sea | Screen-space reflections, fade heuristics, SSR ⊕ planar ⊕ IBL fallback chain | (none) |
| 59 | Shafts of Light | Volumetric god rays: radial blur version, then shadow-map raymarch, blue-noise dithering | (none) |
| 59a ⚓ | The Physical Lens | Depth of field, motion blur (uses 54a's velocity buffer), lens flare | (none) |
| 60 | **MILESTONE: The Deep Engine** | Render-graph cleanup, per-pass debug toggles, night-harbor screenshot #7 | review |

### Part 10 — The True Ocean *(Ch. 61–68)*
*Retire the Gerstners: the Tessendorf FFT ocean, above and below the surface.*

| Ch. | Title | You build | learnopengl |
|---|---|---|---|
| 61 | The Parallel Sea | Compute shaders properly: dispatch, SSBOs, image load/store, barriers | Compute (guest) |
| 62 | The Spectrum of the Sea | Wave statistics, Phillips/JONSWAP spectra, Tessendorf in human terms | (none) |
| 63 | The Fast Fourier Sea | GPU FFT: butterfly passes, ping-pong, displacement + derivative maps; CPU reference FFT to validate | (none) |
| 64 | Whitecaps | Foam from the Jacobian, persistent foam accumulation, sea state from wind | (none) |
| 65 | Floating on Data | Buoyancy v2: async readback strategies, boat + drifting cargo on the FFT sea | (none) |
| 66 | Beneath the Surface | Underwater rendering: absorption, caustics, underwater god rays, seabed + coral | (none) |
| 67 | The Boat Writes on Water | Interactive ripple sim (wave equation in compute) blended into the ocean | (none) |
| 68 | **MILESTONE: The True Ocean** | Calm-to-storm showcase driven by Weather; screenshot #8 | review |

### Part 11 — A Living World *(Ch. 69–76)*
*Things that move on their own: the world stops being a diorama.*

| Ch. | Title | You build | learnopengl |
|---|---|---|---|
| 69 | Castles of Vapor | Raymarched volumetric clouds (Worley+Perlin, Beer's law, powder), quarter-res tricks | (none) |
| 70 | Canvas and Wind | Verlet cloth sails with constraints — sails that luff, fill, and strain with trim | (none) |
| 70a ⚓ | Ropes and Rigging | Verlet rope chains: halyards, anchor line, swinging lantern | (none) |
| 71 | Bones of the Gull | Skeletal animation: glTF skinning via `vendor:cgltf`, sampling, blending | Skeletal Anim. (guest) |
| 71a ⚓ | Feet on the Deck | Two-bone IK and blend trees: a sailor who stands on a heeling deck | (none) |
| 72 | Shoals and Flocks | Real boids with spatial hashing: fish schools, gulls that follow the boat | (none) |
| 73 | The Green and the Gale | Vegetation wind fields, gust-coupled palm sway, grass interaction | (none) |
| 74 | The Tempest | Storms v2: lightning flash lighting, bolt rendering, thunder delay, churning seas | (none) |
| 75 | Many Shores | Biomes: volcanic / atoll / mangrove worldgen, biome palettes & vegetation sets | (none) |
| 76 | **MILESTONE: A Living World** | "The world breathes" showcase; screenshot #9 | review |

### Part 12 — Shipping a Game *(Ch. 77–84)*
*No new GL. The part no graphics tutorial teaches: making it a game people play.*

| Ch. | Title | You build | learnopengl |
|---|---|---|---|
| 77 | The Shape of the Game | Game-design pass: the trading/exploration loop on paper, scope discipline | — |
| 78 | Ports of Call | Docks, cargo & inventory, port trade UI, a drifting supply/demand economy | — |
| 79 | The Chart Room | Nautical-chart map render (paper shader), discovered-area fog, waypoints | — |
| 80 | Letters in a Bottle | Save/load: Odin serialization, save versioning, autosave, settings file | — |
| 81 | The Front Door | Main menu, pause, settings & key rebinding, gamepad support | — |
| 82 | The Ship's Orchestra | Music layers & crossfades, mixing buses, ducking | — |
| 83 | Min-Spec & the Art of Not Crashing | Capability checks, graceful fallbacks (no 4.3 → Gerstner path!), logging, quality presets | — |
| 84 | **FINALE: Flotilla** | itch.io release: packaging, trailer capture, store page, postmortem | — |

### Part 13 — The Captain's Appendices *(Ch. 85–88)*
*Standalone appendices, off the main line — read any of them any time their prerequisite part is behind you. They cover the questions every graphics learner eventually asks that the main voyage didn't need.*

| Ch. | Title | You build | Prerequisite |
|---|---|---|---|
| 85 | The Resolution Illusion | Render scale + FSR1-style spatial upscaling & sharpening; the honest DLSS/FSR2/XeSS/TAAU story (and why DLSS can't run on OpenGL) | Part 7 (HDR pipeline) |
| 86 | Postcards from Another Renderer | A progressive compute-shader path tracer "postcard mode": Monte Carlo, the rendering equation in human terms, your sky as the light source | Part 10 (compute) |
| 87 | Cargo Overboard | Rigid-body physics: integration, sphere/AABB/OBB collision, impulse resolution — crates sliding on a heeling deck, cannonball ballistics | Part 6 (boat) |
| 88 | Charts of the Modern World | Orientation essay: Vulkan/DX12/Metal/wgpu, hardware ray tracing, mesh shaders, GPU-driven rendering — where OpenGL stands and what transfers | Part 8 |
| 89 | The Sea in a Browser | Port Saltwind to WASM/WebGL2: Odin's wasm target, the ch83 fallback ladder pays off, a shareable link | Part 12 |
| 90 | Light Remembered | Global illumination via irradiance probes: baked probe grid, SH/ambient-cube encoding, night-port lighting | Part 9 |

### Part 14 — A Crowded Sea *(Ch. 91–96)*
*Other sails on the horizon: AI, pathfinding, and company. Reads directly after Part 12 (needs the economy); numbered after the appendices only because it arrived later.*

| Ch. | Title | You build | learnopengl |
|---|---|---|---|
| 91 | Lanes of the Sea | Sea-lane graph over the archipelago, A* with wind/depth costs, a priority queue in Odin | — |
| 92 | Rules of the Road | Steering behaviors: seek/arrive/avoid, ship-vs-ship avoidance, blending with sail physics | — |
| 93 | Other Captains | NPC captains: route selection from the economy, docking behavior, schedules, visible loading | — |
| 94 | The Invisible Hand, Visible | NPC trades move prices; the player competes; events ripple through the market | — |
| 95 | Two Sails, One Sea | Co-op multiplayer with `vendor:ENet`: client/server, state sync, interpolation | — |
| 96 | **MILESTONE: A Crowded Sea** | Harbor traffic at dawn; screenshot #11 | review |

### Part 15 — The Engine Room *(Ch. 97–102)*
*The engineering arc: threads, streaming, and GPU-driven rendering — retrofitted into a shipped game, which is exactly how it happens in the real world.*

| Ch. | Title | You build | learnopengl |
|---|---|---|---|
| 97 | Many Hands | Threads & sync in Odin: `core:thread`, `core:sync`, data races, the mental model | — |
| 98 | The Bosun's Crew | A job system: worker pool, queues, dependency counters; parallel terrain generation | — |
| 99 | Cargo Below Decks | Async asset streaming: load thread, main-thread GL upload queue, PBO uploads | — |
| 100 | A Sea Without Edges | Chunk streaming for an endless archipelago (builds on ⚓25a's floating origin) | — |
| 101 | What the Eye Can't See | Occlusion culling: Hi-Z depth pyramid, GPU occlusion tests | — |
| 102 | **MILESTONE: Ten Thousand Things** | MultiDrawIndirect + bindless, compute-built draw lists; screenshot #12 | review |

## 6. Codebase conventions (read once, used everywhere)

All chapters assume these shared conventions, so excerpts always fit your code:

- Project root `saltwind/`, single package in `src/` (package name `saltwind`), assets in `assets/{shaders,textures,models}/`.
- **Types** are `Ada_Case`: `Shader`, `Mesh`, `Camera`, `Terrain_Chunk`, `Ocean`, `Boat`, `Sky`. **Procs** are `snake_case` with type prefixes: `shader_load`, `mesh_upload`, `camera_view_matrix`.
- Math types come from `core:math/linalg/glsl`: `glsl.vec3`, `glsl.mat4`, `glsl.mat4Perspective`, `glsl.mat4LookAt`. Matrices are column-major and map 1:1 to GLSL — upload with `gl.UniformMatrix4fv(loc, 1, false, &m[0, 0])`, never transpose.
- GL objects live in plain structs with `u32` handles; every `*_create` has a `*_destroy`; use `defer` aggressively in scopes, explicit destroy in long-lived systems.
- Shaders are files, not string literals, from Chapter 4 onward — enabling the Chapter 4 exercise everyone loves: **shader hot-reload**.
- One commit per chapter minimum, message format `ch12: camera-following sea tile`.

## 7. A note on motivation (the real boss fight)

The dropout pattern for graphics projects is always the same: three weekends of fast progress, then a chapter of invisible plumbing, then silence. This course's countermeasures, so you can hold yourself to them: visible output every chapter; milestone screenshots you're encouraged to share (r/odinlang, the Odin Discord, learnopengl's screenshots thread); optional chapters clearly marked so you never feel behind; and Part epilogues that explicitly say *"this is a good place to rest — here's the one-paragraph recap to reread when you return."*

If you only remember one thing: **when motivation dips, sail around in what you've already built.** That's what it's for.

---

*Chapters live in `course/part-N-…/`. Start with [Chapter 1](part-1-first-light/ch01-the-shoreline-ahead.md).*
