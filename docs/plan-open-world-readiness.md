# Plan: Semi-Open-World Engine Readiness (9 km² Scale)

> **Status:** Done — Phase 1 (`OW-1`: Complete Box3D Physics API) **Done** · Phase 2 (`OW-2`: Open-World Rendering & Multi-Node glTF) **Done** · Phase 3 (`OW-3`: CSM, Terrain, Fog, Sky/Weather, Decals) **Done** · Phase 4 (`OW-4`: 3D Spatial Audio, DSP & OGG) **Done** · Phase 5 (`OW-5`: Animation ↔ Physics & Minimap UI) **Done** · Phase 6 (`OW-6`: 3D Navigation & Dynamic Obstacles) **Done** · Phase 7 (`OW-7`: World Chunk Streaming, Prefabs & Windows `steadygc`) **Done** · Phase 8 (`OW-8`: Asset/Tunable Hot-Reload, Splines & Blender Exporter) **Done** · See [roadmap.md](roadmap.md)

## Objective

Bring `game-engine` to production readiness for semi-open-world 3D action and vehicle games (3 km × 3 km / 9 km² multi-biome maps, vehicle destruction, ragdolls, 3D spatial/VHF radio audio, dynamic AI navigation, circular minimap HUD, day/night + rain weather, and seamless world chunk streaming) while strictly preserving the engine's core invariants:

- **Safety & DIP1000:** Every module starts with `@safe:`, C interop is wrapped in minimal `@trusted` blocks, and `-preview=dip1000` compiles cleanly.
- **Zero-GC Frame Loop:** Everything inside `engine/` executed between `pollEvents()` and `endFrame()` remains `nothrow @nogc`.
- **GC-Safe Engine Storage:** All engine-owned containers and components use `Pod!T`, `Handle!T`, `StringId`/`StringTable`, and `FrameArena` (`dub run --config=lint` stays green).
- **Clean Engine / Game Boundary:** The engine delivers reusable, data-agnostic primitives (`engine.physics`, `engine.gpu`, `engine.graphics`, `engine.terrain`, `engine.audio`, `engine.animation`, `engine.nav`, `engine.ui`, `engine.scene`, `engine.hotreload`, and export/authoring tools). Game-specific rules — vehicle suspension/handling curves, traffic/police AI behavior trees, dispatch missions, UI screen layouts/forms, and game-specific destruction rules — remain outside the engine repository.

---

## Architectural Decisions (Locked)

### AD-1 — Physics Backend: Stay on Box3D (No Jolt Migration)

An audit of `vendor/box3d/include/box3d/` (`box3d.h`, `types.h`, `collision.h`) confirmed that Box3D already implements natively in C every physics capability required for open-world terrain, vehicles, breakable structures, and ragdolls:

- **Terrain & Static Geometry:** `b3CreateHeightField` / `b3CreateHeightFieldShape` (with per-cell `materialIndices`, `B3_HEIGHT_FIELD_HOLE = 0xFF`, and `globalMinimumHeight`/`globalMaximumHeight` for seamless multi-tile alignment) alongside `b3CreateMesh` / `b3CreateMeshShape` (with per-triangle `materialIndices`).
- **Surface Material Identification:** `uint64_t userMaterialId` on `b3SurfaceMaterial`, returned directly on `b3RayResult` (`castRayClosest`) and `b3ContactHitEvent`, plus runtime setters (`b3Shape_SetSurfaceMaterial`, `b3Shape_SetMeshMaterial`).
- **Constraint Forces & Contact Impulses:** `b3Joint_GetConstraintForce`, `b3Joint_GetConstraintTorque`, and `b3Contact_GetData` (`b3ManifoldPoint.normalImpulse` / `totalNormalImpulse` and `b3Manifold.frictionImpulse`).
- **Ragdoll & Vehicle Joints:** `b3SphericalJointDef` (cone + twist angular limits, rotational spring, damping, motor), `b3WheelJointDef` (suspension spring/limits, steering, spin motor), `b3PrismaticJointDef`, and `b3FilterJointDef` (disable pair collisions cleanly).
- **Filtering, CCD, Sleep & Body Type Control:** `b3Filter` (`categoryBits`, `maskBits`, negative `groupIndex` for non-self-colliding ragdolls/parts), `b3Body_SetBullet` (CCD), `b3Body_SetAwake` / `b3Body_IsAwake` / `b3Body_EnableSleep`, and `b3Body_SetType` (kinematic ↔ dynamic transitions).

**Decision:** Stay on Box3D and expose these native C capabilities through [source/bindings/box3d/functions.d](../source/bindings/box3d/functions.d) and [source/engine/physics/](../source/engine/physics/package.d). A Jolt Physics port is not needed.

### AD-2 — Navigation Backend (`engine.nav`): Option A First (Vendored C++ Recast/Detour Thin C Shim), Pure-D Deferred

Delivering a pure-D port of Recast/Detour (`N0–N16` in [plan-navigation-recast.md](plan-navigation-recast.md), ~33k LOC) before shipping open-world gameplay creates unnecessary schedule risk.

**Decision:** Integrate upstream `recastnavigation` (zlib license, `vendor/recastnavigation/`) behind a thin `extern "C"` shim and manual bindings (`source/bindings/recast/`), wrapped behind the exact `@safe nothrow @nogc Pod!T` public D API specified in [plan-navigation-recast.md](plan-navigation-recast.md) (`NavWorld`, `NavMesh`, `NavTileCache`, `NavCrowd`, `.navmesh` asset, and ECS components). Once open-world gameplay is validated in production, the pure-D port can swap behind the `engine.nav` boundary with zero game-code changes.

### AD-3 — Compressed Audio Streaming Codec

Core SDL3 (`SDL_audio.h`, bound in [source/bindings/sdl3.d](../source/bindings/sdl3.d)) natively decodes only uncompressed WAV files (`SDL_LoadWAV`) and does not decode OGG Vorbis or Opus streams. Furthermore, adding `SDL3_mixer` or multiple heavyweight external C codec build trees would conflict with our custom real-time `@nogc` per-bus software mixer and complicate static cross-target exports (`linux-*`, `windows-x86_64`, `macos-*`, `web-wasm32`).

**Decision:** Keep SDL3 (`SDL_OpenAudioDeviceStream`) as the audio output/resampling backend and introduce an `AudioStreamDecoder` abstraction backed by **single-file `stb_vorbis.c` (public domain / MIT) for OGG Vorbis**, compiled/imported via the same cross-platform C-source/ImportC pattern used by [source/bindings/box3d/box3d_import.c](../source/bindings/box3d/box3d_import.c). Decoded PCM feeds a lock-free SPSC ring buffer consumed by `AudioMixer`. `libopus` / `libopusfile` can be added later as an optional backend behind `AudioStreamDecoder` if ultra-low speech bitrates are needed.

### AD-4 — WebGPU 16-Texture-Per-Stage Budget Enforcement

`assets/shaders/textured3d_pbr.wgsl` already binds **15 of 16** sampled textures (`@group(0)`: 7 shadow depth maps; `@group(1)`: 5 material maps; `@group(2)`: 3 IBL maps), leaving only 1 spare sampled texture slot under standard WebGPU limits.

**Decision:** Enforce the ≤ 16 sampled textures budget across all new shaders:
1. **Cascaded Shadow Maps (CSM)** must replace `@group(0) @binding(2)` (`texture_depth_2d`) with a single `texture_depth_2d_array` (keeping total sampled textures at 15/16).
2. **Terrain PBR Splatting** must pack biome layer textures into `texture_2d_array` (`splatmap`, `heightmap`, `albedoArray`, `normalArray`, `ormArray` = 5 slots in `@group(1)`, staying at 15/16 when sharing `@group(0)` and `@group(2)`).
3. **Projected Decals** reuse `@group(0)` (7) + `@group(2)` (3) + `opaqueDepthView` (1), leaving up to 5 `@group(1)` slots for decal albedo/normal/material maps (≤ 16).

### AD-5 — UI Circular Clipping Without a Present-Pass Stencil Attachment

The UI/present render pass in [source/engine/gpu/renderer.d](../source/engine/gpu/renderer.d) currently uses no depth-stencil attachment (`depthStencilAttachment = null`), and `UiBatchRenderer` (`source/engine/ui/render/batch.d`) uses a single pipeline without stencil-write/stencil-test variants.

**Decision:** Implement multi-draw circular clipping (`pushCircleClip` / `popCircleClip`) analytically in `assets/shaders/ui2d.wgsl` using per-segment uniform data (smoothstep 1 px anti-aliased edge), combined with CPU-rotated UV/quad emitters (`drawImageRotated`, `drawImageUvRotated`). This preserves the depthless present pass with zero extra attachments or pipeline permutations.

---

## Current State (Verified Codebase Audit)

Audit verified against `master` across all relevant engine, shader, vendor, and tooling directories:

| Subsystem | What Already Exists | Real Gaps & Pre-Existing Bugs Found |
| :--- | :--- | :--- |
| **Physics (`source/engine/physics/`, `source/bindings/box3d/`)** | `PhysicsWorld`, primitive bodies (`box`/`sphere`/`capsule`/`cylinder`/`hull`), `createStaticMesh`, sensors, `castRayClosest`, `overlapAabb`/`overlapSphere`, `distance`/`revolute`/`weld` joints, `CharacterController`, `ContactListener`. | `createStaticMesh` ([body.d](../source/engine/physics/body.d)) leaks `b3MeshData*` into a fixed 256-slot `__gshared` array and passes `materialIndices = null`; `RayCastHit`/`PhysicsHitEvent` drop `userMaterialId` and contact impulses; native Box3D heightfields, spherical/wheel/filter joints, constraint force/torque, filters, CCD, and sleep/wake are missing from `functions.d` and `engine.physics`. |
| **Rendering (`source/engine/gpu/`, `source/engine/graphics/`, `source/engine/scene/`, `source/engine/assets/gltf.d`)** | Instanced `Scene3DTextured` (96-byte `TexInstanceData` with free `custom.w` slot), OpenPBR v1.1 shading (`textured3d_pbr.wgsl`), 720-byte `FrameUniforms` with 3 free floats (`_padFrame0..2`), `TexMesh` `lodFirst`/`lodDrawCount` + `MeshLod`/`lodSelectSystem` ([components.d](../source/engine/editor/components.d)), `Renderer.snapshotOpaque()` (`opaqueDepthView`), procedural `sky_dome.wgsl` + OpenPBR wetness math in water paths. | `Scene3DTextured` allocates per-frame via GC `~=` (`begin`/`drawMatrix`), `setLights()` rebuilds `frameBindGroup` unconditionally every call, and `batches` uses O(N) linear scan capped at 64; `Texture` lacks mipmaps, anisotropy, and `texture_2d_array`; `FrameContext.drawIndexed` hardcodes `firstIndex = 0, firstInstance = 0` (color LODs non-functional); `gltf.d` only reads `meshes[0].primitives[0]` + `materials[0]`, bakes node transforms destructively, and lacks `.glb`; no frustum culling, spatial grid, retained static instancing, CSM, HDR fog, decals, or engine-level sky/weather. |
| **Audio (`source/engine/audio/engine.d`)** | `AudioEngine` and real-time `@nogc` 32-voice `AudioMixer` on SDL3 audio callback with fractional resampling (`setPitch`), loop, pause, and 2 buses (`sfx`, `music`). | No `AudioListener3D` / `AudioSource3D`, no distance attenuation or equal-power stereo panning, no Doppler modulation, no per-bus accumulation buffers or DSP filter chain (VHF radio), `mixerStreamCallback` does not call `excludeAudioThreadFromGc()`, and no compressed streaming (OGG/Opus). |
| **Animation (`source/engine/animation/`)** | Complete pure-D `ozz-animation` runtime (`SamplingJob`, **`BlendingJob.Layer.jointWeights`** already implemented & tested in [blending.d](../source/engine/animation/blending.d), `LocalToModelJob`, IK), ECS `PosePool` and `AnimAssets`. | No joint-mask helper builders or ECS wiring in `blendSystem`; no `Quat.fromMat4` / `decomposeAffine` in `engine.math`; no world-space `BoneSocket` component/system; no `ragdollPose` slot in `PosePool`; zero Physics ↔ Skeleton sync bridge. |
| **UI (`source/engine/ui/render/batch.d`, `assets/shaders/ui2d.wgsl`)** | 80-byte `UiVertex`, hardware scissor `pushClip`/`popClip`, `drawRectRotated` (Mode 0), and single-quad circular image AA via `cornerRadius = w*0.5` (Mode 2). | No `drawImageRotated`, no `drawImageUvRotated` (rotating minimap texture inside fixed circle), no multi-draw circular clip (`pushCircleClip`/`popCircleClip`), and no `Texture.createRenderTarget`. |
| **Navigation (`engine.nav`)** | Comprehensive 17-phase pure-D design in [plan-navigation-recast.md](plan-navigation-recast.md). | `source/engine/nav/` does not exist; `vendor/recastnavigation/` is not present; `AssetDatabase` has no `.navmesh` importer; `engine.devtools.gizmos` lacks filled `trianglelist` rendering. |
| **ECS, Prefabs, Streaming, Player & Windows `steadygc`** | `World!(...)`, `SceneWorld`, `SceneFile` v1 (`scene_file.d`), `PrefabInstance` (`prefab.d`), `AssetGuid`/`AssetDatabase`, `steadygc` (`vendor/symgc/`, `engine/core/gc.d`). | `World`/`SceneWorld.spawn()` increment `_nextId++` monotonically with no ID recycling or generations; `instantiatePrefab` wipes the entire world via `loadSceneIntoWorld` and `applyPrefabOverrides` serializes the entire world; `tools/player/player_main.d` only draws `Scene3D` primitives; no chunk streaming or ref-counted asset unloading; `steadygc` has never been linked/run on Windows (`dub.json`, `build_symgc.sh`, `build_export.d`, `time.d` have Windows MSVC bugs/gaps). |
| **Hot-Reload & Authoring (`source/engine/hotreload/`, `tools/`)** | Linux `inotify` watcher (`watcher.d`), transactional WGSL shader reload (`HR-0`), D script module reload (`HotReloadManager`), `tools/blender_generate_rocks.py`. | `watcher.d` is a no-op on Windows/macOS/WASM and never populates `_changedPaths`; `HotReloadManager.snapshotScriptData` loops `0 .. entityCount + 1000` (breaks after ID growth); HR-1 (asset/scene/prefab reload) and HR-2 (JSON tunable reload) are missing; no splines (`engine/math/spline.d`) or Blender `.scene.json`/road exporter. |

---

## Out of Scope

- **Game-Specific Systems (kept in the game repository):** Vehicle handling/gearbox/tire curves, traffic and pedestrian AI behavior, police dispatch/wanted state machines, mission progression, B.O./HUD UI layouts, and gameplay-specific damage thresholds.
- **Pure-D Recast/Detour Rewrite (`N0–N16` in [plan-navigation-recast.md](plan-navigation-recast.md)):** Deferred until after Option A (`vendor/recastnavigation` C shim) validates open-world gameplay.
- **GPU Cluster DAG LOD (Meshopt M10 / Nanite-style):** Deferred beyond CPU/spatial-grid LOD selection + retained static GPU instancing.
- **Deferred G-Buffer Renderer Rewrite:** Rendering stays Forward HDR (`rgba16Float`) + Forward-Z depth (`depth24Plus`).
- **Soft Bodies, Cloth & Multiplayer Networking:** Tracked separately in [plan-networking.md](plan-networking.md).

---

## Dependencies

```
Phase 1 (OW-1: Box3D Physics) ──┬────────────────────────► Phase 5 (OW-5: Anim ↔ Physics + UI)
                                ├────────────────────────► Phase 3 (OW-3: CSM, Terrain, Fog, Decals, Weather)
Phase 2 (OW-2: Render & glTF) ──┘                        └──► Phase 7 (OW-7: World Streaming, Prefabs & Win GC)
                                                               └──► Phase 8 (OW-8: Hot-Reload & Splines/Blender)
Phase 4 (OW-4: Spatial Audio, DSP & OGG) ── [Independent; parallelizable with Phases 2–3]
Phase 6 (OW-6: NavMesh & TileCache) ─────── [Depends only on OW-1 Static Mesh / Heightfield; parallelizable]
```

- **Start Immediately:** Phase 1 (`OW-1`) has zero upstream dependencies and unblocks terrain collision, vehicle physics, destructible props, ragdolls, and navigation bake geometry.
- **Parallel Lanes:** Phase 4 (`OW-4`) is fully independent; Phase 6 (`OW-6`) can begin as soon as `CookedMesh` / `CookedHeightField` settle in `OW-1`.

---

## Phases

### Phase 1 — Complete Box3D Physics API (`OW-1`, Blocking — Done)

Expose native Box3D capabilities through [source/bindings/box3d/functions.d](../source/bindings/box3d/functions.d) and [source/engine/physics/](../source/engine/physics/package.d) with zero GC allocations on the frame path.

- [x] **P1.1 — Missing Box3D C Bindings (`source/bindings/box3d/functions.d`):**
  - Heightfields: `b3CreateHeightField`, `b3DestroyHeightField`, `b3CreateHeightFieldShape`, `b3Shape_GetHeightField`.
  - Surface materials & contacts: `b3Shape_SetSurfaceMaterial`, `b3Shape_GetSurfaceMaterial`, `b3Shape_SetMeshMaterial`, `b3Shape_GetMeshSurfaceMaterial`, `b3Contact_GetData`, `b3Body_GetContactData`.
  - Filters, CCD, sleeping & body type: `b3Shape_GetFilter`, `b3Shape_SetFilter`, `b3Body_SetBullet`, `b3Body_IsBullet`, `b3Body_IsAwake`, `b3Body_SetAwake`, `b3Body_EnableSleep`, `b3Body_IsSleepEnabled`, `b3Body_SetSleepThreshold`, `b3Body_SetType`, `b3Body_ApplyMassFromShapes`, `b3Shape_SetDensity`, `b3World_GetAwakeBodyCount`.
  - Advanced joints & reaction forces: `b3DefaultSphericalJointDef`, `b3CreateSphericalJoint`, `b3DefaultWheelJointDef`, `b3CreateWheelJoint`, `b3DefaultPrismaticJointDef`, `b3CreatePrismaticJoint`, `b3DefaultFilterJointDef`, `b3CreateFilterJoint`, `b3Joint_GetConstraintForce`, `b3Joint_GetConstraintTorque`, and limit/spring/motor setters for spherical, revolute, wheel, weld, and prismatic joints.
- [x] **P1.2 — RAII `CookedMesh` & `CookedHeightField` + Per-Triangle/Cell Materials (`source/engine/physics/body.d`, `world.d`):**
  - Replaced the fixed leaking `retainedMeshes[256]` array with move-only RAII resources (`CookedMesh` calling `b3DestroyMeshD`, `CookedHeightField` calling `b3DestroyHeightFieldD`, `@disable this(this)`), plus world-owned cleanup in `PhysicsWorld.~this()`.
  - Extended `createStaticMesh` and added `createHeightField` accepting `const(ubyte)[] materialIndices` and `const(PhysicsSurfaceMaterial)[] materials`, supporting `heightFieldHole` (`0xFF`) and `globalMinHeight`/`globalMaxHeight` for seamless tile borders.
- [x] **P1.3 — Surface Material IDs & Contact Impulses (`queries.d`, `events.d`):**
  - Populated `entityId` and `ulong surfaceMaterialId` on `RayCastHit` (`result.userMaterialId`), plus `makeQueryFilter`.
  - Populated `ulong materialIdA`, `ulong materialIdB`, `float normalImpulse`, and `float frictionImpulse` on `PhysicsHitEvent` via `b3Contact_GetDataD` when `contactId` is valid.
- [x] **P1.4 — Filters, CCD, Explicit Sleeping & Body Type Control (`body.d`):**
  - Added POD `CollisionFilter` (`categoryBits`, `maskBits`, `groupIndex`), `PhysicsSurfaceMaterial`, `PhysicsBodyType`, and `BodyDesc` overloads (`createBoxBody`, `createSphereBody`, `createCapsuleBody`, `createCylinderBody`, `createHullBody`).
  - Added `@nogc` helpers `setBodyAwake`, `isBodyAwake`, `enableBodySleep`, `setBodySleepThreshold`, `setBodyBullet`, `isBodyBullet`, `setBodyType`, `getBodyType`, `setBodyDensity`, `setBodyFilter`, `setShapeFilter`, `setBodySurfaceMaterial`, and `setShapeSurfaceMaterial`.
- [x] **P1.5 — Ragdoll, Vehicle & Breakable Joints (`joints.d`):**
  - Added `createSphericalJoint` (cone + twist limits, spring hertz, damping ratio), `createWheelJoint`, `createPrismaticJoint`, `createFilterJoint`, and `RevoluteJointConfig`/`WeldJointConfig` options plus runtime motor/angle helpers.
  - Implemented `@nogc` POD `BreakableJointTracker`: registers `(b3JointId, breakForce, breakTorque, userTag)` entries, inspects `b3World_GetJointEventsD` and `b3Joint_GetConstraintForceD`/`TorqueD` after `PhysicsWorld.step()`, destroys exceeded joints, and dispatches `onJointBroken` callbacks.
- [x] **P1.6 — Headless Verification (`source/demo/test_physics_box3d.d`):**
  - Added automated headless tests covering multi-material heightfield raycasts, `heightFieldHole` drop-through, 300-iteration RAII mesh/heightfield cleanup, hit impulses + material IDs, `BreakableJointTracker` breaking a weld joint under impact, limited `SphericalJoint` ragdoll chain with negative `groupIndex` non-self-collision, `createFilterJoint`, `setBodyType`/`setBodyDensity`, sleeping wake-on-impact, and CCD bullet collision (`dub run --config=test-physics-box3d` + `dub test --config=library` passing).

**DoD:** All new physics features work exclusively through `engine.physics` (no direct `bindings.box3d` imports required in user code), `CookedMesh`/`CookedHeightField` leak zero memory across load/unload cycles, and `dub run --config=test-physics-box3d` + `dub test --config=library` pass. ✅

---

### Phase 2 — Open-World Rendering Foundation & Multi-Node glTF (`OW-2`, Blocking)

Remove GC allocations from 3D rendering, introduce multi-sub-mesh glTF models for vehicle destruction, and make 9 km² scenes scale at 60 FPS.

- [x] **P2.1 — GPU Texture Infrastructure & Zero-GC Frame Submission (`texture.d`, `bindings/wgpu.d`, `scene3d_textured.d`, `renderer.d`):**
  - Add `WGPUTextureFormat.r16Unorm` / `r32Float` bindings in [source/bindings/wgpu.d](../source/bindings/wgpu.d).
  - Upgrade `Texture` / `Sampler` ([source/engine/graphics/texture.d](../source/engine/graphics/texture.d)) with mipmap generation (`mipLevelCount > 1`), configurable `maxAnisotropy` (4×/8×), and `TextureArray` (`dim2DArray`).
  - Eliminate GC allocations in `Scene3DTextured` ([source/engine/scene/scene3d_textured.d](../source/engine/scene/scene3d_textured.d)): replace `b.instances ~= inst` with pre-allocated `Pod!TexInstanceData[]` pools + counters; replace the 64-entry linear batch scan with an open-addressed POD hash map; cache shadow/sampler `WGPUTextureView` handles in `setLights()` so `rebuildFrameBindGroup()` only fires when handles actually change.
  - Expose `FrameContext.drawIndexed(indexCount, instanceCount, firstIndex, baseVertex, firstInstance)` in [source/engine/gpu/renderer.d](../source/engine/gpu/renderer.d).
- [x] **P2.2 — Multi-Node / Multi-Primitive glTF + `.glb` (`gltf.d`, `engine/graphics/model.d`):**
  - Upgrade [source/engine/assets/gltf.d](../source/engine/assets/gltf.d) to parse `.glb` binary containers, embedded `bufferView` images, multiple `meshes`, multiple `primitives` per mesh with distinct `material` assignments, and the node hierarchy (`nodes[]` names + TRS matrices) without destructively baking node transforms into vertices.
  - Split shared immutable GPU ownership **`GltfAsset`** (meshes, textures, default materials, `StringTable` mapping `StringId → nodeIndex`) from lightweight POD **`ModelInstance`** (per-node visibility bitmask, per-sub-mesh `MaterialHandle` overrides, local transform overrides).
  - Implement `detachSubMesh(nodeName)` helper returning world transform + mesh/material references to spawn an independent rigid body/entity (e.g., `door_fl`, `wheel_fr`, `bumper_f`, `lightbar`).
- [x] **P2.3 — Frustum Culling & Spatial Partitioning (`engine/math/frustum.d`, `engine/scene/spatial_grid.d`):**
  - Implement `Frustum` (6-plane Gribb-Hartmann extraction calibrated for WebGPU clip space Z ∈ `[0, 1]`, where near plane = `row2`) + `@nogc` `intersectsAabb` and `intersectsSphere`.
  - Compute and cache `localBounds` (`Aabb` + bounding sphere) on `TexMesh` and `Mesh`.
  - Implement `@nogc` POD `SpatialGrid` / loose BVH over 64 m × 64 m world cells culling main camera draws and per-cascade shadow draws.
- [x] **P2.4 — Retained Static GPU Instancing, Runtime LODs & Distance Culling (`scene3d_textured.d`, `texmesh.d`, `components.d`):**
  - Add `StaticInstanceBuffer` storing static world prop instances in GPU buffers without per-frame CPU reconstruction or re-upload, submitting visible cell ranges via `firstInstance`/`instanceCount`.
  - Wire existing `TexMesh.lodFirst`/`lodDrawCount` and `lodSelectSystem` ([source/engine/editor/components.d](../source/engine/editor/components.d)) into `Scene3DTextured` color and shadow passes: key batches by `(TexMesh*, Material*, ubyte lod)`, pass `firstIndex = lodFirst[lod]`, run `buildLodChain` on asset import/load, and enforce `maxDistance` / `minPixelSize` culling on small props.

**DoD:** 10,000+ instanced glTF props distributed across 3 km × 3 km render with frustum culling, automatic LOD0/1/2 switching, sub-mesh visibility/override/detach passing unit tests, and 0 bytes GC allocation in `--headless-frames=600 --assert-no-gc`.

**Status: Done** (commits `1629ea4`, `cb53446`, `3067572`, `ad31363`). `dub run --config=openworld-bench -- --headless-frames=600 --assert-no-gc` renders 12,000 static rock props (1,697 cell ranges) plus 200 multi-node vehicles: 0 GC bytes over 600 frames, LOD0/1/2/3+ all used, ~38 draw calls and ~13 ms/frame on the dev machine. Deviations and open items:
- ~~Point/spot shadow views draw every dynamic caster~~ — resolved: per-view caster lists (light range sphere + face/spot frustum) in one shared per-frame buffer; static ranges are culled against every light view.
- `SpatialGrid` is a standalone query structure for gameplay entities; `Scene3DTextured` culls per instance and `StaticInstanceBuffer` per cell instead of consuming a grid bitset. Per-cascade culling arrives with CSM in `OW-3`.
- ~~`.meta` LOD switch / editor-player pipeline~~ — resolved: `.meta` `settings.lod` drives every glTF loader, and the editor and player render through the shared `SceneRenderer` (`Scene3DTextured`, `GltfAsset`, lights + shadows, culling, LOD). Static props placed in the editor are still drawn per instance (no automatic `StaticInstanceBuffer` baking) and `MaterialOverride` applies only `baseColor`/opacity.
- Static buffers render in the opaque pass only (depth-writing materials).

---

### Phase 3 — CSM, Terrain Splatting, HDR Fog, Decals & Day/Night Weather (`OW-3`, Blocking + Visual Polish — Done)

Deliver open-world outdoor rendering across 4 biomes while staying strictly within the 16-texture/stage budget (AD-4).

- [x] **P3.1 — Cascaded Shadow Maps (`engine/gpu/shadow.d`, `assets/shaders/common/shadows.wgsl`, `scene/light.d`):**
  - Replace `@group(0) @binding(2)` `texture_depth_2d` with a single `texture_depth_2d_array` (3–4 cascades, keeping total sampled textures at **15/16**).
  - Implement PSSM logarithmic/linear split calculation, tight camera-frustum ortho fitting with texel-snapping stabilization, per-cascade frustum culling, cascade blending, and max-distance fade.
  - Update all consumers of `common/shadows.wgsl` (`textured3d_pbr.wgsl`, `water_surface.wgsl`, `caustics_bed.wgsl`, `sky_dome.wgsl`).
- [x] **P3.2 — Chunked Terrain + PBR Splatting (`engine/terrain/`):**
  - Implement chunked terrain mesh patches (e.g., 128 m × 128 m patches over 3 km × 3 km) with distance LODs and crack-hiding skirts.
  - Author terrain PBR WGSL pipeline reusing `@group(0)` (CSM) + `@group(2)` (IBL) and binding `texture_2d_array` in `@group(1)` (`splatmap`, `heightmap`, `albedoArray`, `normalArray`, `ormArray` = 5 slots → **15/16 total**), supporting 4–8 surface layers, height-blend transitions, and triplanar steep-slope projection.
  - Sync terrain heightmaps and dominant cell splat weights directly into Phase 1 Box3D `CookedHeightField` + `materialIndices`.
- [x] **P3.3 — Linear HDR Atmospheric Fog (`FrameUniforms`, `textured3d_pbr.wgsl`, terrain shader):**
  - Add fog uniforms (color, exponential density, height base/falloff, sun in-scattering color/power) to `FrameUniforms` and evaluate distance + height fog in linear HDR before bloom/tonemapping across opaque, transparent, and terrain shaders.
- [x] **P3.4 — Engine Sky, Cheap Runtime HDR IBL & Global OpenPBR Wetness (`engine/gpu/sky.d`, `ibl.d`, `textured3d_pbr.wgsl`):**
  - Promote [assets/shaders/sky_dome.wgsl](../assets/shaders/sky_dome.wgsl) into `engine/gpu/sky.d` (decoupled from `WaterUniforms`), driven continuously by sun elevation, moon/stars, and weather cloud coverage.
  - Upgrade `IblEnvironment` ([source/engine/gpu/ibl.d](../source/engine/gpu/ibl.d)) to `rgba16Float` cubemaps and add cheap runtime IBL updates (interpolating pre-baked time-of-day/weather probes or GPU compute prefilter amortized across frames, never rebuilding `brdfLut` or allocating on CPU).
  - Expose `globalWetness` / `rainIntensity` in `FrameUniforms` (reusing `_padFrame0..2`) and apply the OpenPBR coat darkening/roughness modulation already present in `textured3d_pbr.wgsl` globally, masked by surface-up normal and `TexInstanceData.custom.w` (0 = exposed to rain, 1 = sheltered/indoor).
- [x] **P3.5 — Projected Decals (`engine/graphics/decals.d`, `assets/shaders/decal_pbr.wgsl`):**
  - Implement `@nogc` POD ring-buffered OBB `DecalSystem` (skid marks, oil spills, graffiti, worn crosswalks, cracked glass).
  - Add `invViewProj` and `viewportSize` to `FrameUniforms`; render instanced OBB boxes (`cullMode = front`, `depthWrite = false`) reading `Renderer.opaqueDepthView()` after `snapshotOpaque()`, reconstructing world position and screen-space normal (`dpdx`/`dpdy`), with angle/edge attenuation.

**DoD:** A 3 km × 3 km test scene renders chunked splatted terrain aligned with Box3D heightfields, 4-cascade CSM, HDR fog, dynamic day/night + rain wetness, and 500+ projected decals at target frame rate with zero WebGPU validation errors.

**Result:** Done. See [plan-ow3-outdoor-rendering.md](plan-ow3-outdoor-rendering.md), [terrain-guide.md](terrain-guide.md) and [graphics.md § Outdoor Rendering](graphics.md#outdoor-rendering-ow-3). `dub run --config=outdoor -- --headless-frames=600 --assert-no-gc` runs a 3 km terrain with 4-cascade CSM, fog, sky, day/night + rain, dynamic IBL and 500 decals at ≤ 5 terrain draws and 0 GC bytes.

---

### Phase 4 — 3D Spatial Audio, Doppler, VHF DSP Pipeline & Compressed Streaming (`OW-4`, Blocking — Done)

Extend [source/engine/audio/engine.d](../source/engine/audio/engine.d) while keeping SDL3's audio thread (`mixerStreamCallback`) strictly lock-free, `nothrow`, and `@nogc`.

- [x] **P4.1 — 3D Spatialization & Doppler (`source/engine/audio/engine.d`, `spatial.d`):**
  - Added POD `AudioListener3D` (`position`, `forward`, `up`, `velocity`) and `AudioSource3D` (`position`, `velocity`, `refDistance`, `maxDistance`, `rolloffFactor`, `dopplerFactor`, `spatialBlend`, `baseVolume`, `basePitch`, `bus`) alongside `dopplerPitch`, `play3D`, `playStream3D`, and `updateSource3D`.
  - Updated `mixVoicesInto`: `spatialBlend` mono-downmix + stereo panning, separated `basePitch` and `dopplerPitch`, per-chunk linear parameter smoothing (`curVolume`, `curPitch`, `curPan`) to eliminate zipper noise, and `excludeAudioThreadFromGc()` in `mixerStreamCallback`.
- [x] **P4.2 — Multi-Bus Routing & POD Real-Time DSP Chain (`source/engine/audio/engine.d`, `dsp.d`):**
  - Expanded `AudioBus` to 8 buses (`sfx`, `music`, `voice`, `radio`, `ambient`, `ui`, `custom0`, `custom1`) with independent per-bus accumulation buffers (`busAccum`).
  - Implemented `@nogc` POD `DspEffectSlot` / `DspChain` (`DspChain.vhfRadio()` preset: 800 Hz HPF + 3 kHz LPF + waveshaper clipping + band-limited squelch-gated `staticHiss`) attachable per bus (`setBusDsp`) or per voice (`setVoiceDsp`).
- [x] **P4.3 — Compressed Streaming (`AudioStream` + `PcmRingBuffer` + `stb_vorbis.c`):**
  - Vendored single-file `vendor/stb/stb_vorbis.c` (Public Domain / MIT) compiled cleanly via ImportC (`source/bindings/stb_vorbis/`) and wired into `dub.json` and `source/editor/build_export.d`.
  - Added lock-free SPSC `PcmRingBuffer`, `AudioStreamDecoder` interface, `AudioStream` (`openOggFile`, `openOggMemory`, `pump`, `seekStart`, `close`), and `AudioMixer.playStream` with fractional pitch resampling.

**DoD:** Unit tests verify biquad frequency rolloff, 3D attenuation/panning, Doppler shift math, and sustained ring-buffered streaming + VHF DSP output with zero audio-thread allocations. ✅

---

### Phase 5 — Animation (`ozz`) ↔ Physics Bridge & Minimap/Compass UI (`OW-5`, **Done**)

Connect `engine.animation` to `engine.physics` and complete UI clipping/rotation primitives for circular minimaps and compasses.

- [x] **P5.1 — Math Helpers & World-Space Bone Sockets (`engine/math/`, `engine/animation/ecs/`):**
  - Added `Quat.fromMat4` and `decomposeAffine` / `Mat4.decompose` to [source/engine/math/quat.d](../source/engine/math/quat.d) / [mat.d](../source/engine/math/mat.d).
  - Added POD `BoneSocket` component (`targetEntity`, `jointIndex`, `localOffset`, `localRot`, `localScale`) and `boneSocketSystem` computing `targetWorld * pose.model[jointIndex] * localSocket` and writing `Transform`.
- [x] **P5.2 — Partial Bone Mask Builders & ECS Wiring (`blending.d`, `ecs/assets.d`, `ecs/systems.d`):**
  - Added mask helpers atop `BlendingJob.Layer.jointWeights` (`fillJointWeights`, `setJointWeight`, `getJointWeight`, `setSubtreeWeights`, `buildSubtreeMask`), `JointMaskStore` in `AnimAssets`, and `maskA`/`maskB` on `AnimBlend2`, `mask` on `AnimAdditive`, and `AnimLayerOverride` processed by `blendSystem`.
- [x] **P5.3 — Bidirectional Ragdoll ↔ Skeleton Bridge (`source/engine/animation/ragdoll.d`, `pose_pool.d`):**
  - Defined POD `RagdollAsset` / `RagdollComponent` mapping skeleton joints ↔ `b3BodyId` + bind offsets + `SphericalJoint` constraints + state machine (`animated`, `ragdoll`, `blendingToAnim`, `blendTimer`).
  - Added persistent `ragdollPose` (`Pod!SoaTransform[]`) slot to `Pose` in [source/engine/animation/ecs/pose_pool.d](../source/engine/animation/ecs/pose_pool.d).
  - Implemented **Skeleton → Physics** sync (`syncSkeletonToPhysics`, `activateRagdoll` velocity inheritance) and **Physics → Skeleton** sync (`modelToLocalSoa`, `syncPhysicsToSkeleton`, `beginRagdollGetUp` pelvis alignment + face-up/face-down clip selection + `BlendingJob` crossfade in `ragdollSystem`).
- [x] **P5.4 — UI Circular Clipping & Image Rotation (`source/engine/ui/render/batch.d`, `assets/shaders/ui2d.wgsl`):**
  - Added `drawImageRotated` and `drawImageUvRotated` (rotating minimap texture inside a circular aperture).
  - Implemented analytical `pushCircleClip(cx, cy, radius)` / `popCircleClip()` (AD-5) via per-segment dynamic uniforms in `ui2d.wgsl` with 1 px smoothstep AA.
  - Exposed `clipCircle`, `imageRotation`, `rotateImageUv` on `UiStyle`, `imageUvRect`/`imageTint` on `UiNode`, `imageRotated`/`minimapImage` in `widgets/image.d`, and `Texture.createRenderTarget`.

**DoD:** Automated tests validate `decomposeAffine`, `BoneSocket`, subtree mask blending, and `Model → Local SoaTransform` ragdoll pose roundtrip; `ui_gallery` demonstrates a rotating circular minimap clipping child icons/markers cleanly.

---

### Phase 6 — 3D Navigation & Dynamic Obstacles (`OW-6`, **Done**)

Implemented `engine.nav` using **Option A (AD-2)**: vendored C++ `recastnavigation` (`v1.6.0`, `DT_POLYREF64`) wrapped behind a thin `extern "C"` shim and the `@safe nothrow @nogc Pod!T` D API defined in [plan-navigation-recast.md](plan-navigation-recast.md).

- [x] **P6.1 — Vendor `recastnavigation` & Build Integration (`vendor/recastnavigation/`, `source/bindings/recast/`):**
  - Vendored upstream `recastnavigation` (`v1.6.0`: `Recast`, `Detour`, `DetourTileCache`, `DetourCrowd`, `fastlz`, zlib/MIT licenses) and added static `librecast_shim.a` compilation across targets in [tools/build_sdl3_deps.sh](../tools/build_sdl3_deps.sh), `dub.json`, and [source/editor/build_export.d](../source/editor/build_export.d).
  - Wrote flat `extern "C"` wrapper (`recast_shim.h` / `recast_shim.cpp` / `recast_import.c`) and `@nogc nothrow` D bindings in `source/bindings/recast/package.d`.
- [x] **P6.2 — `engine.nav` Core, Tiled NavMesh & `TileCache` Dynamic Obstacles (`source/engine/nav/`):**
  - Implemented `@safe nothrow @nogc` RAII `NavMesh`, `NavTileCache` (cylinder, AABB, and OBB obstacles), `NavQuery` (`findNearestPoly`, `findPath`, `findStraightPath`, `raycast`), and `NavCrowd` (local velocity-obstacle avoidance) using `Pod!T` types (`64-bit PolyRef` enabled).
  - Added tiled baking (`bakeNavMesh`), binary `.navmesh` serialization (`saveNavMeshToBytes`/`loadNavMeshFromBytes`/`saveNavMeshFile`/`loadNavMeshFile`), and `.navmesh` importer in [source/engine/project/asset_db.d](../source/engine/project/asset_db.d).
- [x] **P6.3 — ECS Components & Filled Gizmo Debug Draw (`source/engine/nav/ecs.d`, `devtools/gizmos.d`):**
  - Added POD `NavMeshSurface`, `NavAgent`, `NavMoveRequest`, `NavObstacle`, `NavOffMeshLink`, `NavModifierVolume`, and `stepNavAgents` ECS helper.
  - Added filled `trianglelist` alpha-blended pipeline (`GizmoRenderer.triangle`) to [source/engine/devtools/gizmos.d](../source/engine/devtools/gizmos.d) and `drawNavMesh` in [source/engine/nav/debugdraw.d](../source/engine/nav/debugdraw.d).

**DoD:** Headless multi-tile navigation test (`source/engine/nav/tests.d`) proves agents pathfind across tiled geometry, reroute around dynamically added/removed OBB/cylinder obstacles at runtime, round-trip `.navmesh` binaries, and update 50 `NavCrowd` agents with zero GC allocations (`@nogc`).

---

### Phase 7 — World Chunk Streaming (9 km²), ECS/Prefab Fixes & `steadygc` Windows (`OW-7`, **Done**)

Fix foundational ECS/prefab/player bugs blocking open-world streaming and bring `windows-x86_64` `steadygc` to verified parity.

- [x] **P7.1 — Entity ID Recycling, Generations & Additive Scene/Prefab Fixes (`ecs/`, `prefab.d`, `scene_load.d`):**
  - Added `EntityHandle`, free-list `EntityId` recycling, and generation counters (`generation`, `handle`, `aliveHandle`, `capacity`, `freeCount`, `clearEntities`) to `World` ([world.d](../source/engine/ecs/world.d)) and `SceneWorld` ([scene_world.d](../source/engine/ecs/scene_world.d)) so repeated chunk load/unload cycles keep `_alive[]` and sparse arrays bounded.
  - Added `loadSceneAdditive`, `collectSubtreeEntities`, and `subtreeToSceneFile` in [source/engine/editor/scene_load.d](../source/engine/editor/scene_load.d) (preserving existing entities and remapping `id`/`parent` indices).
  - Fixed [source/engine/scene/prefab.d](../source/engine/scene/prefab.d): made `instantiatePrefab` additive, scoped `applyPrefabOverrides` to the prefab subtree only, made `revertPrefab` destroy the full child hierarchy via `destroyPrefabHierarchy`, and implemented `diffPrefabOverrides`, `applyPropertyOverridesToSceneFile`, and `applyPropertyOverrides`.
- [x] **P7.2 — World Chunk Streaming & Standalone Player Upgrade (`scene_file.d`, `engine/scene/streamer.d`, `tools/player/player_main.d`):**
  - Extended `SceneFile` to v2 (`ChunkManifest`, `SceneCellBounds`, `SceneAssetLink`, `visual.assetGuid`, and per-chunk rather than global light-cap validation errors).
  - Built `WorldStreamer` ([source/engine/scene/streamer.d](../source/engine/scene/streamer.d)) dividing the map into cells (e.g., 256 m × 256 m) with hysteresis states (`unloaded → loading → active → unloading`), background worker I/O/decode (`ScopedGcExcludedThread`), frame-time-budgeted upload queue (`processUploadQueue`), `SceneRenderer.unloadAsset`, and reference-counted unloading of `GltfAsset`, `Texture`, `CookedMesh`, and `NavMesh` tiles.
  - Upgraded [tools/player/player_main.d](../tools/player/player_main.d) (and [source/editor/play_mode.d](../source/editor/play_mode.d)) with `makeAssetResolver(world)` for `triangleMesh`/`convexHull` physics bodies and `WorldStreamer` support for v2 `ChunkManifest` scenes while preserving `0 bytes` GC allocation in `--headless-frames=600 --assert-no-gc`.
- [x] **P7.3 — `steadygc` & Cross-Compile Fixes for `windows-x86_64` (`dub.json`, `build_symgc.sh`, `build_export.d`, `vendor/symgc/`):**
  - Fixed `dub.json` root `"libs"` (`stdc++` and `m` moved to `libs-linux`; added `libs-windows` and `lflags-windows`).
  - Fixed [tools/build_symgc.sh](../tools/build_symgc.sh) to emit `symgc-cards.lib` for Windows MSVC without `-fPIC`, pass `-oq` to avoid object collisions, and avoid overwriting the Linux host symlink.
  - Fixed [source/editor/build_export.d](../source/editor/build_export.d) Windows cross-compile command (pass `-i`, `box3d_import.c` / `stb_vorbis_import.c` / `recast_import.c`, `synchronization.lib`, and `/EXPORT:__sd_gc_card_*` when `--symgc` is enabled).
  - Cached a thread-local `CreateWaitableTimerExW` handle with TLS cleanup in [vendor/symgc/source/d/gc/time.d](../vendor/symgc/source/d/gc/time.d) instead of allocating/closing per sleep.
  - Implemented Windows Tier 2 `MEM_WRITE_WATCH` + `GetWriteWatch`/`ResetWriteWatch` dirty-page tracking in [vendor/symgc/source/d/gc/dirty.d](../vendor/symgc/source/d/gc/dirty.d) and [memmap.d](../vendor/symgc/source/d/gc/memmap.d), alongside LDC 1.40.1 (`druntime` 2.110) compatibility in `symthread.d`, `gcobj.d`, and `intrinsics.d`.

**DoD:** 100 chunk load/unload soak cycles complete with flat RSS/VRAM and bounded `EntityId` arrays (`streamer.soak100Cycles9Km2` verified across 144 cells / 9 km²); `tools/player` renders full OpenPBR glTF scenes with `makeAssetResolver` + `WorldStreamer`; `dub test --config=export` (155 modules) and Windows `steadygc` Tier 2 & Tier 3 library cross-builds (`libs/windows-x86_64/symgc-cards.lib`) pass. ✅

---

### Phase 8 — Productivity Multipliers: Asset/JSON Hot-Reload & Splines/Blender Pipeline (`OW-8`, **Done**)

Accelerate vehicle/destruction tuning and large-scale 9 km² level assembly. Usage guide: [world-pipeline-guide.md](world-pipeline-guide.md).

- [x] **P8.1 — Cross-Platform Watcher, Asset & Tunable Hot-Reload (`source/engine/hotreload/`):**
  - [watcher.d](../source/engine/hotreload/watcher.d): `FileWatcher.changedPaths()` reports each debounced batch; `inotify` watches subdirectories created after `init` (and reports files already inside them); a portable mtime `polling` backend covers Windows/macOS/Web and is the Linux fallback (`WatchBackend`).
  - **HR-1** `AssetHotReloader` ([asset_reload.d](../source/engine/hotreload/asset_reload.d)): models are re-imported and swapped through `SceneRenderer.reloadChangedFiles`, which tracks every file a `*.asset.json` model depends on (`assetDependencies` / `gltfFileDependencies`). Also covered: registered `Texture` slots (`watchTexture` + `onSwapped`), custom surface shaders (`watchSurfaceShader`), `*.prefab.json` (`reloadPrefabInstances` keeps per-instance overrides), `*.scene.json` (owner callback) and registered `*.tune.json`. All swaps are transactional.
  - **HR-2** `TunableRegistry` ([tunables.d](../source/engine/hotreload/tunables.d)): nested JSON flattened to dotted `StringId` keys, `@nogc` reads, `applyTo` / `applyToComponents`, reload callbacks, `FrameArena` labels.
  - Fixed `HotReloadManager.snapshotScriptData` to walk the component's dense store (it missed components on IDs above `entityCount + 1000`).
  - Wired into the editor (always, except headless) and the player (`--hot-reload`).
- [x] **P8.2 — 3D Road Splines & Blender Scene/Chunk Exporter (`engine/math/spline.d`, `tools/blender_export_scene.py`):**
  - [spline.d](../source/engine/math/spline.d) `Spline3`: centripetal Catmull-Rom and piecewise cubic Bézier, open or closed. Provides an arc-length LUT (`sampleAtDistance`, `paramAtDistance`), stable frames (`FrameMode.upVector` / rotation-minimizing with closed-loop twist correction), `closestPoint` with a signed lateral offset, and `extrudeRibbon`. Every query after `rebuild()` is `@nogc`.
  - `*.splines.json` spline sets ([splines.d](../source/engine/scene/splines.d)), linked from root scenes by an `assetLinks` entry of kind `splines`.
  - [blender_export_scene.py](../tools/blender_export_scene.py): one Y-up GLB + `*.asset.json` (triangle mesh + convex hull) per unique mesh, per-cell v2 chunk scenes with bounds, a root scene with the `ChunkManifest`, curve objects → splines, `ge_*` custom properties for physics/surface/placement, and deterministic GUID `.meta` sidecars. `--build-test-level` generates the multi-biome test level.

**DoD:** Editing a `.prefab.json` or tunable `.json` updates live entities in the running editor/player within 0.5 s without restarting; a multi-biome Blender test level exports cleanly into chunked `.scene.json` + road splines and loads via `WorldStreamer`. ✅
- `assetReload.watcherEndToEndWithin500ms`: a tunable edit applies within 0.5 s of simulated frames. The debounce is 0.2 s.
- `assetReload.prefabTunableSceneDispatch` / `prefab.hotReloadKeepsInstanceOverrides`: live prefab instances are rebuilt with their overrides kept.
- `assets/world/ow8_test_level`: exported by Blender 5.3 (forest/desert/snow, 3 × 3 cells, road + traffic loop + river; re-export is byte-identical). `engine.scene.world_export_tests` validates it and streams it through `WorldStreamer`.

**Status: Done** (`feat/ow-8`). Deviations and open items:
- Windows uses the mtime polling backend rather than `ReadDirectoryChangesW`. Polling is portable and fast enough for asset folders; a native backend can slot in behind `WatchBackend` later.
- Rebuilt prefab instances get new entity IDs. Gameplay code holding raw `EntityId`s into an instance subtree must re-resolve them (the editor drops a dead selection).
- `.scene.json` reload: the editor reopens the open scene (skipped when it has unsaved edits or during Play); the player restarts non-streamed scenes. Editing a streamed chunk file on disk does not reload that chunk live.
- Surface materials export as friction/restitution presets: the scene format has no surface-material component yet.
- The exporter flattens Blender parenting to world transforms and does not export Blender materials into `*.asset.json` slots: the GLB carries the materials.
- The editor/player do not load `*.splines.json` automatically. Gameplay loads them with `loadSplineSetFile(sceneSplineSetPath(root))`.

---

## Acceptance Criteria

1. **Compliance & Static Checks:** All engine modules pass `dub build --config=library`, `dub test --config=library`, `dub test --config=export`, and `dub run --config=lint` (`@safe:`, DIP1000, `Pod!T` engine storage).
2. **Zero-GC Frame Loop:** Both `editor` and `player` pass `--headless-frames=600 --assert-no-gc` with 0 bytes allocated in the frame loop under open-world rendering and physics workloads.
3. **WGPU Budget Compliance:** All new and updated PBR/terrain/decal/CSM shaders stay at **≤ 16 sampled textures per shader stage** and run without WebGPU validation warnings.
4. **Cross-Platform Parity:** Linux (`linux-x86_64`) and Windows (`windows-x86_64`) builds link cleanly (`libs/<target>/`), including `stb_vorbis`, `recastnavigation`, `box3d`, and `steadygc`.
5. **Documentation & Changelog Hygiene:** Each completed phase updates the relevant guides in `docs/` (`physics-quickstart.md`, `graphics.md`, `game-development-guide.md`, `export-guide.md`) and `CHANGELOG.md` in English.

---

## Cross References

- [roadmap.md](roadmap.md) — Consolidated engine work backlog and priority order
- [plan-physics-api.md](plan-physics-api.md) · [physics-quickstart.md](physics-quickstart.md) — Box3D physics API and usage guide
- [plan-navigation-recast.md](plan-navigation-recast.md) — Full `engine.nav` API design (Option A C shim now; pure-D port deferred)
- [plan-terrain-water.md](plan-terrain-water.md) — Terrain & water editor plan
- [plan-meshoptimizer.md](plan-meshoptimizer.md) — Meshopt optimization, tangents, LODs, and meshlets
- [plan-openpbr.md](plan-openpbr.md) — OpenPBR Surface v1.1 architecture
- [plan-scripting-hot-reload.md](plan-scripting-hot-reload.md) — HR-0..HR-3 hot-reload architecture
- [symgc-multiplatform-integration.md](symgc-multiplatform-integration.md) — `steadygc` (`symgc`) multiplatform integration
- [plan-sdl3-image-ttf-and-export.md](plan-sdl3-image-ttf-and-export.md) · [export-guide.md](export-guide.md) — Static multiplatform export pipeline
- [animation-guide.md](animation-guide.md) — `ozz-animation` port and ECS animation system
- [graphics.md](graphics.md) · [game-development-guide.md](game-development-guide.md) — GPU layers and gameplay development guide
