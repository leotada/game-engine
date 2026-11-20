# Roadmap — Work Backlog

Consolidated overview of remaining engine work. The initial roadmap (phases 1–12 of the README) is **complete**. Gameplay rigid body physics is powered by **Box3D** (`engine.physics`) — see [physics-quickstart.md](physics-quickstart.md).

The native Jolt port (`engine.jph`) was **cancelled** and removed — see [jph-port-plan.md](jph-port-plan.md).

Mesh processing is the pure-D port of meshoptimizer v1.3 in `engine.meshopt`. Import optimization, tangents, LOD chains, glTF `EXT_meshopt_compression`, and meshlets are landed. GPU cluster LOD, the compressed `.asset` mesh blob, and the editor LOD slider are not. See [plan-meshoptimizer.md](plan-meshoptimizer.md).

## Suggested Priority

Prioritization by **dependency unblocking**: gameplay → GC hygiene → graphics & shaders (shadow infrastructure, modular shaders, hot-reload) → animated content → iteration tooling → scale.

| # | Feature | Document | Priority | Dependencies / Rationale |
|---:|:---|:---|:---|:---|
| 1 | Gameplay physics API (Box3D) | [plan-physics-api.md](plan-physics-api.md) · [physics-quickstart.md](physics-quickstart.md) | **Done** (`P0–P6` + `OW-1`) | Gameplay foundation + heightfields, per-triangle materials, breakable/spherical/wheel joints, filters, CCD, sleep |
| 2 | Complete GC-safe adoption (lint) | [gc-safe-architecture-plan.md](gc-safe-architecture-plan.md) | **Done** (#9 Handle API deferred) | Storage POD + static lint |
| 2b | steadygc (symgc) Multiplatform GC | [symgc-multiplatform-integration.md](symgc-multiplatform-integration.md) | **In Progress** | Compiler card-marking across Linux/Win/Android/macOS/iOS |
| 3 | OpenPBR Surface v1.1 + IBL + Shadows | [plan-openpbr.md](plan-openpbr.md) | **Phase 1 Done** (`PBR-0–5`, `OPBR-1–5`); **Phase 2 Pending** (`OPBR-6–9`) | Single-pass OpenPBR v1.1 + IBL + PCF done; remaining: per-pixel layer maps (`OPBR-6`), refractive transmission (`OPBR-7`), SSS/translucency (`OPBR-8`), local probes/SSR (`OPBR-9`) |
| 4 | Post-processing | [plan-post-processing.md](plan-post-processing.md) | **Done** (PP-1–6) | HDR offscreen + bloom + ACES + FXAA; `App.post` |
| 5 | Skeletal animation | [plan-animation.md](plan-animation.md) | Medium | glTF loader; engine storage poses must be `isPod` |
| 6 | Scene editor / level design | [plan-editor-ux.md](plan-editor-ux.md) | **Done** (v1) | `dub run --config=editor`; multi-light with shadows; hull+mesh; asset DB; multi-select + undo |
| 7 | Terrain and water editor | [plan-terrain-water.md](plan-terrain-water.md) | Medium | After scene editor; heightfield (P5); brushes + water plane |
| 8 | Hot reload (assets + data + shaders) | [plan-scripting-hot-reload.md](plan-scripting-hot-reload.md) · [multiplatform-and-shaders.md](multiplatform-and-shaders.md) | Medium (Shaders Done) | Day-to-day iteration; shader hot-reload complete |
| 9 | Parallel ECS | [plan-parallel-ecs.md](plan-parallel-ecs.md) | Low | Stable serial API; opt-in scheduler |
| 10 | Networking | [plan-networking.md](plan-networking.md) | Low | `engine.ser` + stable physics |
| 11 | Split-screen local co-op | [plan-split-screen.md](plan-split-screen.md) | Medium | Multi-view renderers (dynamic uniform offsets) + SDL3 gamepads; no blockers for rendering phases |
| 12 | SDL3_image, SDL3_ttf & Multiplatform Release Export | [plan-sdl3-image-ttf-and-export.md](plan-sdl3-image-ttf-and-export.md) | **Done** | Replaced `stb_image`/`stb_truetype` with `SDL3_image`/`SDL3_ttf` (dynamic dev, static release) and added release exporter for Linux, Windows, macOS, and Web |
| 13 | Semi-open-world readiness (9 km²) | [plan-open-world-readiness.md](plan-open-world-readiness.md) | **In Progress (`OW-1`, `OW-2` Done · `OW-3` next)** | 8-phase plan (`OW-1..OW-8`): complete Box3D physics (**Done**), culling/LOD/CSM/terrain/decals/weather, 3D/DSP/OGG audio, ozz-physics ragdoll + UI circle clip/rotate, Recast C-shim nav, chunk streaming, Windows `steadygc`, hot-reload & Blender splines |

### Ordering Notes

- **Open-World Readiness (#13) — Phases 1–2 (`OW-1`, `OW-2`) Done · Phase 3 (`OW-3`) next:** Phase 1 completed Box3D bindings and `@nogc` wrappers in `engine.physics` (RAII `CookedMesh`/`CookedHeightField`, per-triangle/cell surface materials, `RayCastHit.surfaceMaterialId`, `PhysicsHitEvent` contact impulses, spherical/wheel/prismatic/filter joints, `BreakableJointTracker`, collision filters, CCD, and sleep/body-type control). Phase 2 (`OW-2`) delivered zero-GC `Scene3DTextured` submission, texture mips/anisotropy/arrays, `.glb` + multi-node glTF (`GltfAsset`/`ModelInstance`/`detachSubMesh`), frustum + distance culling, `SpatialGrid`, retained `StaticInstanceBuffer`, and runtime LODs (`dub run --config=openworld-bench`). Phase 3 (`OW-3`) covers CSM, terrain splatting, fog, decals and weather.

- **steadygc (#2b):** Direct compiler card barrier (`-version=Symgc_cards`) and custom runtime integration across all 5 engine target platforms; pairs with engine's `Pod!T` DOD storage (`BlkAttr.NO_SCAN`) for sub-millisecond GC pauses.
- **PBR + Post:** Scene renders into `rgba16float`; bloom + ACES + FXAA detailed in [`plan-post-processing.md`](plan-post-processing.md). Swapchain presentation remains SDR.
- **OpenPBR Surface (#3):** Phase 1 (`PBR-0–5`, `OPBR-1–5`) is complete — 144-byte OpenPBR v1.1 `MaterialParams`, layered single-pass WGSL slabs, PCF shadows, and 3-channel GGX + Charlie BRDF LUT (`plan-openpbr.md`). Phase 2 (`OPBR-6–9`) covers per-pixel layer texture maps, multi-pass refractive transmission, SSS/thin-translucency, and local reflection probes / SSR.
- **Hot-Reload before Parallel ECS:** Day-to-day productivity boost; parallelism addresses scaling, but does not unblock gameplay content creation.
- **Terrain/Water (#7) after Scene Editor (#6):** Reuses picking, asset database, serialization, and gizmos; Box3D heightfield unblocks terrain collision.
- **Rendering Evolution (GFX Backlog):** Editor v1 ships Forward rendering with shadow caster limits (`MAX_POINT_SHADOW_CASTERS`). Future evolution: **Static Shadow Caching** (cubemap reuse for static lights) and **Clustered Forward Rendering** (WGPU Compute) for light scaling.
- **GC-Safe (#2) Completed:** `Pod!T[]` engine storage, `World.strings`, `App.frameArena`, `dub run --config=lint`. All new buffers must use `Pod!T` / `Handle!T` / `StringId`.

## Already Delivered (Do Not Reopen)

- **Core:** SDL3 + WGPU + ECS SoA + vector/matrix math
- **Multiplatform Surface:** Linux (Wayland primary, X11 fallback for standalone), Windows (HWND), Android (ANativeWindow), macOS/iOS (Metal layer) + dynamic swapchain capabilities
- **Rendering:** Meshes, instancing, scene depth, directional N·L lighting, bitmap text
- **ShadowMap Infrastructure:** `depth32Float` depth pass + comparison sampler + PCF filtering in textured pipeline (`Scene3DTextured.setLighting`)
- **Modular Shaders & Hot-Reload:** WGSL include preprocessor (`#include`, `#define`, `#ifdef`), CTFE compile-time embedding, transactional non-destructive hot-reloading
- **Scene:** SceneGraph, camera controllers (orbit/fly/fps), OpenPBR Surface v1.1 materials
- **Assets:** BMP + glTF mesh + OpenPBR (`loadGltfPbr` with `KHR_materials_*` extensions)
- **OpenPBR + IBL:** Single-pass OpenPBR Surface v1.1 (144-byte `MaterialParams`, 3-channel GGX + Charlie BRDF LUT, procedural IBL, `dub run --config=pbr` 4×5 showcase)
- **Post-Processing:** HDR scene RT (`rgba16float`), bloom (Karis average downsample + tent upsample), ACES tone mapping, FXAA; `app.resolvePost(frame)` before UI
- **Audio:** WAV playback via SDL3 audio streams
- **DevTools:** 3D gizmos + FPS/label debug overlay
- **Gameplay Physics:** `PhysicsWorld`, primitives, convex hulls, static triangle meshes (`CookedMesh`), heightfield terrain (`CookedHeightField`), per-triangle/cell `PhysicsSurfaceMaterial`, sensors, raycasts (`surfaceMaterialId`) + overlaps, distance/revolute/weld/spherical/wheel/prismatic/filter joints, `@nogc` `BreakableJointTracker`, collision filters, CCD, sleep/body-type control, character controller, and contact impulses (`PhysicsHitEvent`) — [physics-quickstart.md](physics-quickstart.md)
- **GC-Safe Primitives:** `Pod!T`, `Handle!T`, `StringId`, `FrameArena`, static lint (`dub run --config=lint`) — see [gc-safe-architecture-plan.md](gc-safe-architecture-plan.md)
- **Editor UX v1:** Full level editor (`dub run --config=editor`) — raycast picking, TRS gizmos + snapping, multi-selection, undo/redo stack, hierarchy/inspector panels, lighting + shadows, play/pause physics simulation, `*.scene.json` and `*.asset.json` pipelines — see [plan-editor-ux.md](plan-editor-ux.md)
- **Media Pipeline & Multiplatform Export:** `SDL3_image` + `SDL3_ttf` (`FreeType` SDF & hinted bitmap, kerning, fallback fonts; `stb` removed), static `player-static` builds via `ldc2`, and `ExportPipeline` + CLI (`dub run --config=export`) / Editor File menu release export for Linux, Windows, macOS, and Web (WASM + WebGPU) — see [plan-sdl3-image-ttf-and-export.md](plan-sdl3-image-ttf-and-export.md)
