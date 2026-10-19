# Roadmap — Work Backlog

Consolidated overview of remaining engine work. The initial roadmap (phases 1–12 of the README) is **complete**. Gameplay rigid body physics is powered by **Box3D** (`engine.physics`) — see [physics-quickstart.md](physics-quickstart.md).

The native Jolt port (`engine.jph`) was **cancelled** and removed — see [jph-port-plan.md](jph-port-plan.md).

## Suggested Priority

Prioritization by **dependency unblocking**: gameplay → GC hygiene → graphics & shaders (shadow infrastructure, modular shaders, hot-reload) → animated content → iteration tooling → scale.

| # | Feature | Document | Priority | Dependencies / Rationale |
|---:|:---|:---|:---|:---|
| 1 | Gameplay physics API (Box3D) | [plan-physics-api.md](plan-physics-api.md) · [physics-quickstart.md](physics-quickstart.md) | **Done** (P5 mesh deferred) | Gameplay foundation; `pong3d` demo, etc. |
| 2 | Complete GC-safe adoption (lint) | [gc-safe-architecture-plan.md](gc-safe-architecture-plan.md) | **Done** (#9 Handle API deferred) | Storage POD + static lint |
| 2b | steadygc (symgc) Multiplatform GC | [symgc-multiplatform-integration.md](symgc-multiplatform-integration.md) | **In Progress** | Compiler card-marking across Linux/Win/Android/macOS/iOS |
| 3 | PBR + shadow sampling | [plan-pbr.md](plan-pbr.md) | **Done** (PBR-0–5) | Textured path: GGX + IBL + PCF; `pbr` demo |
| 4 | Post-processing | [plan-post-processing.md](plan-post-processing.md) | **Done** (PP-1–6) | HDR offscreen + bloom + ACES + FXAA; `App.post` |
| 5 | Skeletal animation | [plan-animation.md](plan-animation.md) | Medium | glTF loader; engine storage poses must be `isPod` |
| 6 | Scene editor / level design | [plan-editor-ux.md](plan-editor-ux.md) | **Done** (v1) | `dub run --config=editor`; multi-light with shadows; hull+mesh; asset DB; multi-select + undo |
| 7 | Terrain and water editor | [plan-terrain-water.md](plan-terrain-water.md) | Medium | After scene editor; heightfield (P5); brushes + water plane |
| 8 | Hot reload (assets + data + shaders) | [plan-scripting-hot-reload.md](plan-scripting-hot-reload.md) · [multiplatform-and-shaders.md](multiplatform-and-shaders.md) | Medium (Shaders Done) | Day-to-day iteration; shader hot-reload complete |
| 9 | Parallel ECS | [plan-parallel-ecs.md](plan-parallel-ecs.md) | Low | Stable serial API; opt-in scheduler |
| 10 | Networking | [plan-networking.md](plan-networking.md) | Low | `engine.ser` + stable physics |

### Ordering Notes

- **steadygc (#2b):** Direct compiler card barrier (`-version=Symgc_cards`) and custom runtime integration across all 5 engine target platforms; pairs with engine's `Pod!T` DOD storage (`BlkAttr.NO_SCAN`) for sub-millisecond GC pauses.
- **PBR + Post:** Scene renders into `rgba16float`; bloom + ACES + FXAA detailed in [`plan-post-processing.md`](plan-post-processing.md). Swapchain presentation remains SDR.
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
- **Scene:** SceneGraph, camera controllers (orbit/fly/fps), PBR materials (metallic-roughness)
- **Assets:** BMP + glTF mesh + `pbrMetallicRoughness` (`loadGltfPbr`)
- **PBR + IBL:** Cook-Torrance GGX, procedural IBL, `dub run --config=pbr` demo
- **Post-Processing:** HDR scene RT (`rgba16float`), bloom (Karis average downsample + tent upsample), ACES tone mapping, FXAA; `app.resolvePost(frame)` before UI
- **Audio:** WAV playback via SDL3 audio streams
- **DevTools:** 3D gizmos + FPS/label debug overlay
- **Gameplay Physics:** `PhysicsWorld`, boxes/spheres/capsules/cylinders, sensors, raycasts + overlaps, joints (distance/revolute/weld), character controller, contact/sensor/hit events (Box3D) — [physics-quickstart.md](physics-quickstart.md)
- **GC-Safe Primitives:** `Pod!T`, `Handle!T`, `StringId`, `FrameArena`, static lint (`dub run --config=lint`) — see [gc-safe-architecture-plan.md](gc-safe-architecture-plan.md)
- **Editor UX v1:** Full level editor (`dub run --config=editor`) — raycast picking, TRS gizmos + snapping, multi-selection, undo/redo stack, hierarchy/inspector panels, lighting + shadows, play/pause physics simulation, `*.scene.json` and `*.asset.json` pipelines — see [plan-editor-ux.md](plan-editor-ux.md)

## Pending Maintenance (Non-Feature)

- Static mesh collider (plan-physics-api P5) — optional, when required by specific game use cases
