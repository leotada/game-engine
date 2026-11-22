# Engine Documentation

Index of documents in `docs/`. Guides describe existing features and architecture; plans describe pending milestones. Overview: [roadmap.md](roadmap.md).

## Guides (Current State)

| Document | Description |
|:---|:---|
| [game-development-guide.md](game-development-guide.md) | Concise practical guide to building 2D and 3D games across all engine subsystems |
| [physics-quickstart.md](physics-quickstart.md) | Box3D gameplay physics API: world, shapes, sensors, queries, joints, character |
| [animation-guide.md](animation-guide.md) | Skeletal animation (`ozz-animation` port), IK, ECS integration, and GPU skinning |
| [audio-guide.md](audio-guide.md) | 8-bus audio mixer, real-time `@nogc` DSP (VHF radio/biquads), 3D Doppler spatialization, and OGG Vorbis streaming |
| [navigation-guide.md](navigation-guide.md) | 3D Recast/Detour NavMesh baking, `.navmesh` persistence, `TileCache` dynamic obstacles, `NavCrowd`, and ECS integration |
| [graphics.md](graphics.md) | 3-layer GPU architecture (WGPU), open-world and outdoor rendering (CSM, fog, sky, weather, IBL, decals) |
| [water-guide.md](water-guide.md) | Water: `WaterRenderer` / `WaterBody`, Gerstner waves, shared GPU wave data, caustics, wet marks, gameplay queries, buoyancy, wet material presets, `WaterSurface` scene component |
| [terrain-guide.md](terrain-guide.md) | Chunked heightmap terrain: splat layers, LOD/geomorphing, shadows, Box3D colliders, procedural generation |
| [multiplatform-and-shaders.md](multiplatform-and-shaders.md) | Multiplatform support (Wayland/X11, Win32, Android, Metal) & modular shaders with hot-reload |
| [editor-guide.md](editor-guide.md) | Visual editor architecture, panels, play mode, and workflow |
| [world-pipeline-guide.md](world-pipeline-guide.md) | Asset/prefab/scene hot-reload, `*.tune.json` tunables, 3D road splines, `*.splines.json`, and the Blender chunk exporter |
| [export-guide.md](export-guide.md) | Multiplatform release export (`--target=<id>` specs, CLI flags, static deps, and media formats) |
| [scripting-guide.md](scripting-guide.md) | D scripting API, reflection attributes, lifecycle, and hot-reload rules |
| [why-this-is-fast.md](why-this-is-fast.md) | Why the ECS/SoA architecture is fast |
| [incremental-gc-research.md](incremental-gc-research.md) | Garbage collection research, pause metrics, and benchmarks |
| [physics-box3d-benchmark.md](physics-box3d-benchmark.md) | JPH-D vs Box3D physics migration benchmark |

## Roadmap and Plans

| Document | Status | Scope |
|:---|:---|:---|
| [roadmap.md](roadmap.md) | Active | Work backlog, priorities, and implementation order |
| [plan-physics-api.md](plan-physics-api.md) | Done (`P0–P6` + `OW-1`) | Complete gameplay API on top of Box3D (#1) |
| [gc-safe-architecture-plan.md](gc-safe-architecture-plan.md) | Done (#9 deferred) | GC-safe adoption + static lint (#2) |
| [plan-openpbr.md](plan-openpbr.md) | Phase 1 Done (`PBR-0–5`, `OPBR-1–5`); `OPBR-6–9` pending | Real-time OpenPBR Surface v1.1, IBL, PCF shadows, transmission, SSS & probes (#3) |
| [plan-meshoptimizer.md](plan-meshoptimizer.md) | Done through M9; M10 not started | Pure-D meshoptimizer v1.3: import optimization, tangents, LODs, codecs, meshlets |
| [plan-post-processing.md](plan-post-processing.md) | Done | Bloom, tone mapping, FXAA (#4) |
| [plan-animation.md](plan-animation.md) | Pending | Skeletal animation + glTF skinning (#5) |
| [plan-editor-ux.md](plan-editor-ux.md) | Delivered (v1) | Full scene editor UX (#6) |
| [plan-terrain-water.md](plan-terrain-water.md) | Pending | Terrain and water editor (#7) |
| [plan-water-engine-port.md](plan-water-engine-port.md) | Implemented (`WP-0–10`) | Water demo → `engine.water`: `WaterRenderer`/`WaterBody`, shared wave buffer, generic caustics, buoyancy, wet presets, `WaterSurface` editor component |
| [plan-water-realism.md](plan-water-realism.md) | Implemented (`WTR-0–6`) | Realistic water optical pipeline (`snapshotOpaque`, refraction, SSR, submerged caustics, horizon skirt, `256×256` JONSWAP + advected foam compute sim) + Before/After benchmarks |
| [plan-scripting-hot-reload.md](plan-scripting-hot-reload.md) | In Progress (Shaders done) | Asset and data hot-reload (#8) |
| [plan-parallel-ecs.md](plan-parallel-ecs.md) | Pending | Parallel system scheduler (#9) |
| [plan-networking.md](plan-networking.md) | Pending | Multiplayer primitives (#10) |
| [plan-split-screen.md](plan-split-screen.md) | Pending | Split-screen local co-op: multi-viewport rendering + gamepads (#11) |
| [plan-sdl3-image-ttf-and-export.md](plan-sdl3-image-ttf-and-export.md) | Delivered | SDL3_image & SDL3_ttf replacement + static multiplatform release export (Linux, Windows, macOS, Web) (#12) |
| [plan-navigation-recast.md](plan-navigation-recast.md) | Delivered (C shim `OW-6`; pure-D deferred) | 3D NavMesh, TileCache dynamic obstacles & Crowd navigation (`engine.nav`) |
| [plan-ow3-outdoor-rendering.md](plan-ow3-outdoor-rendering.md) | Done | OW-3 implementation plan: CSM, HDR fog, sky/day-night/runtime IBL/wetness, terrain, decals |
| [plan-open-world-readiness.md](plan-open-world-readiness.md) | Done (`OW-1..OW-8`) | Semi-open-world 9 km² readiness: Box3D physics (**Done**), open-world rendering (**Done**), CSM/terrain/fog/sky/decals (**Done**), spatial/DSP/OGG audio (**Done**), ragdoll/sockets + UI clip/rotate (**Done**), Recast nav (**Done**), chunk streaming & Windows steadygc (**Done**), asset/tunable hot-reload & Blender splines (**Done**) |

## History / Cancelled

| Document | Status | Note |
|:---|:---|:---|
| [jph-port-plan.md](jph-port-plan.md) | **Cancelled** | Jolt→D port abandoned; `engine.jph` tree removed in favor of Box3D (physics P6) |

## Plan Conventions

Every `plan-*.md` document follows:

1. **Objective**
2. **Current State** — with actual repository paths (no overclaiming)
3. **Out of Scope**
4. **Dependencies**
5. **Phases** — each with a single-line **Definition of Done (DoD)**
6. **Acceptance Criteria** (for the entire plan)
7. **Cross References**

**Language**: All documentation, architecture plans, and code comments must be written in English.
When updating any plan, verify the referenced code before marking anything as completed.
