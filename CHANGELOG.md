# Changelog

## Unreleased

### Engine bug fixes

- **Log formatting** (`engine.core.log`): `%s`/`%d`/`%08x`/`%.3f` placeholders are now substituted (they were printed
  literally); arguments without a placeholder are still appended. Floats, `bool`, `long.min` and `ensure()` messages
  print correctly.

### Other changes

- **Web export rework** (`docs/export-guide.md` 4.7): `--target=web` now builds with one LDC 1.43+ command linking
  through `emcc` (emdawnwebgpu, JSPI), supports `--project`, asset paks, `--scene` and `--link-flag`, and writes
  `index.html`. `App.pollEvents` paces frames on web, streaming decodes without threads, and the player sources
  compile for 32-bit targets. Not yet verified with a real Emscripten toolchain or in a browser.
- **Native frame profiler** (`docs/profiling.md`): `engine.devtools.profiler` adds hierarchical CPU zones
  (`profileZone!"name"()`, `@nogc`, off by default), external samples (`profileSample`), mean/p50/p95/p99/max per zone
  (`profilerReport`, `profilerVisit`, `DebugOverlay.addProfiler`) and Chrome Trace Event export (`startProfilerTrace`,
  `profilerTraceJson`, opens in Perfetto). `engine.gpu.gpu_profiler` measures GPU passes with timestamp queries
  (`gpuScope`, `gpuPassScope`, `gpuComputeScope`, `gpuFrameScope`), resolved into async readback buffers, no stalls.
  `GpuContext` now requests `TimestampQuery` + the native in-encoder / in-pass features when available
  (`timestampsSupported()`; `ENGINE_NO_GPU_TIMESTAMPS=1` opts out). The renderer, `Scene3DTextured` (shadows, every
  scene pass and segment), post, terrain, decals, water, IBL, UI and `PhysicsWorld.step` (Box3D `b3World_GetProfile`
  as `box3d.*` samples) are instrumented. New bindings: timestamp queries, `ResolveQuerySet`, `CopyBufferToBuffer`,
  `HasFeature`, `QueueGetTimestampPeriod`, `b3World_GetProfileD`.
- **Static props: fewer redundant state changes.** `drawStatic` and `encodeStaticShadow` bind pipeline, material,
  vertex and index buffers once per (mesh × material) group instead of once per visible cell run, and the shared
  instance buffer once per pass. Same draw count, same image; in viatura-VI (~2,500 draws/frame)
  `renderer.submit.finish` dropped from 2.61 to 1.96 ms and the frame from 10.0 to 9.15 ms.
- **Static props: cell-level culling.** `StaticInstanceBuffer` keeps per-cell bounds; each view (camera and every
  shadow cascade) tests the cells first (`markVisibleCells`) and skips the ranges of invisible cells in
  `collectVisibleRuns`. Same runs, same order. viatura-VI (25k ranges): `scene.shadows.encode` 1.08 → 0.49 ms,
  `scene.end.opaque.static` 0.34 → 0.20 ms.
- **Dynamic batches share one per-frame instance buffer.**
  - Previously every (mesh, material, lod) batch owned a vertex buffer and uploaded it with its own
    `wgpuQueueWriteBuffer`, about 300 per frame in viatura-VI. Each write costs a staging allocation in wgpu.
  - Batches now get regions of one buffer, written once per upload phase (shadows, `end`). The transparent re-sort
    rewrites its region in place.
  - `scene.shadows.prepare` 0.58 → 0.30 ms, same image.
- **Partial opaque snapshots** (`Renderer.snapshotOpaque(frame, SnapshotParts)`): decals copy only depth, and water
  copies color level 0 and depth, without the mip pyramid. `gpu.snapshotOpaque` 1.05 → 0.78 ms (debug), same image.
- **Receiver-aware cascade caster culling** (`CascadeSettings.receiverCulling`, on by default; `receiverDrop` = 30 m):
  - Casters go into a cascade only if their bounds, swept along the shadow direction, reach the camera slice that
    cascade shades. This covers static ranges and cells and dynamic instances.
  - viatura-VI: shadow draws 1512 → 751, static shadow instances 25.2k → 4.1k, cascade GPU 1.44 → 0.74 ms.
    The image is pixel-identical.
- **Fix: foliage SSS thickness past the shadow range.** `sampleDirShadowBackAndThickness` read the last cascade even
  beyond `fadeEnd`, where shadows are already off. Distant foliage translucency therefore depended on how far that
  cascade's light box happened to reach, and changed as the camera turned. It now fades out with the shadow.
- **Shadow diagnostics:** `RenderStats.shadowStaticInstancesDrawn` and per-cascade `cascadeDrawCalls` /
  `cascadeDynamicInstances` / `cascadeStaticInstances`; profiler zones `scene.shadows.encode.cascadeN` and GPU scopes
  `gpu.shadows.cascades.cN`.
- **LDC 1.43.0 verified** (`docs/dmd-inline-crash.md` › Installing a newer LDC than the distro ships): release builds of
  `player` / `gesc`, `dub test --config=library` and `--assert-no-gc` pass. The editor must be linked against the shared
  druntime (`-link-defaultlib-shared`) because the static druntime of 1.43 has no `rt_loadLibrary` (hot reload).
- **DMD 2.114.0 support** (`docs/dmd-inline-crash.md` › Status on DMD 2.114.0): the debug build segfaulted (backend
  stack overflow) in `engine.gpu.sky`, `engine.graphics.decals` and `engine.terrain.renderer`. The preprocessed shader
  sources in `engine.gpu.shaders` are now `immutable string` globals instead of `enum`s. **Rebuild
  `libsymgc-cards.a`** (`tools/build_symgc.sh dmd`) after upgrading DMD: the 2.113 build does not link against the
  2.114 druntime. The 2.113 `-inline` SIMD crash is still present in 2.114; keep its workaround.
- **`Scene3DTextured` batch table grows on demand** (`docs/graphics.md` › Batch table): a full `(mesh, material, lod)`
  table used to drop extra draws for the rest of the frame and warned only once per scene. It now doubles (`@nogc`,
  malloc) up to `Scene3DTextured.MAX_BATCHES_HARD` (65,536). `create(gpu, maxBatches, createIbl)` keeps its signature;
  `maxBatches` is now the initial capacity. The new `batchStats()` returns `BatchStats { used, peak, capacity, growths,
  droppedDraws }`. Drops past the ceiling are counted in `RenderStats.droppedDraws` and warned on every frame that drops.
  Per-batch GPU instance buffers are now created on first upload instead of in `create`.
- **Multithreaded NavMesh bake** (`NavBakeConfig.threads`, `docs/navigation-guide.md`): tiles are built on worker
  threads and committed serially in tile order, so the `.navmesh` is byte-identical to the serial bake (tested on the
  direct and TileCache paths). `1` = serial (default), `0` = all hardware threads. ~6-8x faster on a 16-thread machine
  in the test terrain. `NavBakeConfig` (C) gains a trailing `threads` field: **rebuild `librecast_shim.a`**
  (`tools/build_sdl3_deps.sh`) after pulling.
- **Restore the `NavTileCache` from a `.navmesh`** (`saveNavMeshToBytes(mesh, tc, out)`, `saveNavMeshFile(mesh, tc, path)`,
  `loadNavMeshAndCacheFromBytes`, `navSaveMeshAndTileCacheToBuffer` / `navLoadMeshAndTileCacheFromBuffer` in the shim):
  format v2 appends the cache params, compressed layers and off-mesh links, so dynamic obstacles work after loading
  without a re-bake. v1 files and the mesh-only readers are unchanged; truncated data is rejected.
  **Rebuild `librecast_shim.a`** (`tools/build_sdl3_deps.sh`) after pulling.
- **Navigation off-mesh links** (`engine.nav.types.NavOffMeshConnection`, `bakeNavMesh(..., triAreas, links)`,
  `navBakeGeometryEx` in the Recast shim, `docs/navigation-guide.md`): bake jump / ladder / drop connections into the
  navmesh. They are stored in the tile data (kept by `.navmesh` save/load) and in the `NavTileCache` (kept across
  obstacle tile rebuilds). **Rebuild `librecast_shim.a`** (`tools/build_sdl3_deps.sh`) after pulling.
- **Physics mass data and calibrated hit impulse** (`engine.physics.body`, `engine.physics.events`, `docs/physics-quickstart.md`):
  `getMassData` / `setMassData` / `resetMassFromShapes` / `getLocalCenterOfMass` / `getLocalInertiaDiagonal` and the
  `BodyMassData` POD (`BodyMassData.diagonal`) expose and override mass, center of mass and inertia through the Box3D
  `b3Body_*MassData` bindings. `PhysicsHitEvent.approachImpulse` (= `approachSpeed` x reduced mass, kg*m/s) is a
  sub-step independent impact measure; `normalImpulse` is documented as Box3D's sub-step-accumulated total.
- **`Scene3DTextured.create(gpu, maxBatches, createIbl)`**: `createIbl = false` skips the procedural sky + IBL prefilter
  (~1 s in debug builds) and uses `IblEnvironment.createSolid` (flat grey) until the game binds its own environment with
  `setEnvironment` / `setEnvironmentBindGroup`. Default `true` keeps existing behavior. See `docs/graphics.md`.
- **`App.setSize(w, h)` / `Window.setSize`** (`engine.app`, `engine.platform.window`, `bindings.sdl3.SDL_SetWindowSize`): request a
  new windowed size at runtime and reconfigure the swapchain and post targets immediately, like `setFullscreen`.
  Returns false for a zero size, while fullscreen, or when SDL refuses. See `docs/game-development-guide.md`.
- **`InputMap` read-back** (`engine.platform.input_map`): `numActions`, `actionName(i)`, `bindingCount(action)` and
  `bindingAt(action, i, out binding)` (all `nothrow @nogc`) expose the bindings of an action so remap UIs no longer need
  a parallel table. See `docs/game-development-guide.md` section 8.
- **Export: pure-D zstd codec on the direct compile commands** (`source/editor/build_export.d`): the external-project
  compile (`buildProjectCompileArgs`), the LDC `-i` command and the web command now pass `-I vendor/zipd`, and the
  project compile also lists the `vendor/zipd` sources. Fixes `unable to read module scratch` (`zipd.compressor.scratch`)
  when exporting a game after the zstd -> zipd migration. Covered by unit tests in `build_export.d`.
- **LDC fix** (`engine.scene.chunk_components`): `sameLayout` no longer uses a local `ref` variable (only valid for
  parameters and `foreach`), so the engine compiles with LDC 1.40.1 again.
- **GESC soak and export tests** (`engine.scene.gesc_soak_tests`, `engine.scene.world_export_tests`): 100-cycle streaming soak
  for `.gesc` chunks (v1 and v2 binary components) compared against the JSON soak, the same soak from a mounted pak, a
  corrupt-chunk robustness soak, and an export -> GESC -> streamer round trip. `GESC_SOAK_FULL=1` selects the full 9 km2 size.
- **GC-free GESC decoding on the streamer worker** (`engine.scene.chunk_binary_nogc`, `docs/chunk-format.md`,
  `docs/world-pipeline-guide.md`): `readChunkNoGc` validates, CRC-checks, inflates and decodes a `.gesc` into a
  malloc-owned, move-only `GescChunkNoGc` on the GC-excluded worker; the main thread only runs `applyChunkNoGc`.
  `decodeChunk` is unchanged and equivalent. Chunks are freed on spawn, cancel, failure and streamer destruction
  (allocation counters in tests). `StreamerStats` gains `workerDecodeUsecs` / `mainPrepareUsecs` / `mainApplyUsecs`.
  JSON chunks and non-cooked custom-component JSON still parse on the main thread.
- **Blender exporter `--format=gesc`** (`tools/blender_export_scene.py`, `docs/world-pipeline-guide.md` 5.1.1): also encodes each
  chunk to a verified `.gesc` through `game-engine-gesc` (located via `--gesc-tool`, `$GAME_ENGINE_GESC`, project/repo root or
  `PATH`, with a clear error if missing); `.scene.json` stays the editable default and the manifest points at the `.gesc` files.
- **Surface-shader `displace` in shadow passes + `displaceEx`**: materials with a `displace` / `displaceEx` hook now
  get a depth-only `vs_shadow` pipeline (cascades, point, spot; dynamic and static instances) that reuses the composed
  surface shader, so cast shadows follow animated geometry. New optional `fn displaceEx(d: DisplaceIn)` exposes the
  per-instance `custom` vec4, instance translation / scale and mesh UV; the original `displace(localPos, localNormal)`
  is unchanged. `composeSurfaceShader` now emits an `engineDisplace` wrapper (`surfaceDisplaceKind`, `DisplaceKind`).
  New `surface-shadow-check` GPU regression config. See `docs/graphics.md`.
- **GESC binary chunks** (`engine.scene.chunk_binary`, `docs/chunk-format.md`): columnar, zstd-compressed,
  CRC-checked scene chunks with game-defined user blocks; `WorldStreamer` loads GESC or JSON chunks by content
  and calls `GescBlockHandler`s on load/unload. `game-engine-gesc` tool (`encode`, `decode`, `info`, `verify`,
  `split`, `bench`).
- **Chunk streaming from the asset pak**: `WorldStreamer` reads chunk bytes from a mounted GEPK pak (new `@nogc`
  `readMountedAssetNoGc` in `engine.assets.pak`) with disk fallback; the exporter verifies and counts packed
  chunks and gains `--pak-dir=<dir>` (extra directories in the pak, e.g. chunk folders outside `Assets`).
- `engine.assets.zstd`: `@nogc` one-shot zstd. Backed by the pure-D zipd codec vendored in `vendor/zipd` (levels
  clamped to 1..9, standard frames interoperable with `zstd`/libzstd); the C zstd 1.5.7 (`vendor/zstd`,
  `libzstd_engine.a`, `bindings.zstd`) was removed along with its build step.
- **Batched ECS insertion** (`engine.ecs.scene_world`, `engine.ecs.store`): `SceneWorld.spawnBatch`,
  `rawAddBatch` / `setBatch`, `RawComponentStore.addBatch` / `reserve`, `ComponentStore.addBatch`; `loadSceneAdditive`
  uses them for the Transform and Name columns.
- **GESC v2 binary component blocks** (`engine.scene.chunk_components`, `docs/chunk-format.md`): `types` + per-type
  `component` blocks mapped by type name, memcpy when the layout matches and field-by-field (with `@formerlyNamed`
  and numeric conversion) when it differs, `StringId` and `@entityRef` remapping; `applyChunk` separates decode from
  apply. Chunks without the blocks stay version 1 and still load; JSON remains the fallback. Adds
  `TypeRegistry.registerRuntime` and `@entityRef`. Decode + apply of the 55 k-entity map: ~540 ms to ~105 ms (debug).

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Because the repository has not yet published tagged releases, entries are grouped chronologically under `[Unreleased]` by development milestone and commit history (`git log`).

## [Unreleased]

### Fixed

- **DMD release build crash (`dmd -inline` SIGSEGV)**: `SimdFloat4.opBinary` (`engine.animation.math.simd_backend`) builds its result in a local to avoid a DMD 2.113 inliner bug that crashed `dub build --build=release` (gesc, editor, player, games); details and reproducer in `docs/dmd-inline-crash.md`.
- **Normal transformation under non-uniform scale (`2026-11-22`)**: `textured3d_pbr.wgsl`, `colored3d.wgsl`, and `cube3d.wgsl` now transform normals using the $3 \times 3$ adjugate (cofactor transpose) of the model matrix (and re-orthogonalize tangents against the corrected normal) so scaled objects shade accurately; added `Mat4.transformNormal` / `transformNormalAdjugate` (`engine.math.mat`).
- **glTF 2.0 `doubleSided` and material names (`2026-11-22`)**: `parseGltfMaterialAt` (`engine.assets.gltf`) now parses `materials[i].doubleSided` and `name`, propagating `doubleSided` to `Material.renderState.doubleSided` in `loadGltfPbr` and `loadGltfAsset`; `GltfAsset` exposes `findMaterial(name)` and `materialName(index)`.
- **Script hot-reload skipped components on high entity IDs (`2026-11-21`)**: `HotReloadManager.snapshotScriptData` scanned IDs `0 .. entityCount() + 1000`, so components on recycled or late entities were lost on reload. It now walks the component's dense store.
- **Fullscreen toggle crashed with a wgpu scissor validation error (`2026-11-20`)**:
  - `Window.setFullscreen` refreshed the window size itself, so the next `App.handleResize()` saw no change and never reconfigured the swapchain. The UI then drew at the new size onto the old-size target (`Scissor Rect ... is not contained in the render target`) and wgpu aborted.
  - `Window.setFullscreen` no longer touches `width()/height()`; the new `App.setFullscreen(bool)` toggles it and reconfigures the swapchain and post targets immediately. Games should call the `App` method.

### Added

- **Clustered Forward Rendering & Light Scaling (`2026-11-22`)**:
  - **WGPU Compute Light Culling (`engine.gpu.clustered`, `assets/shaders/clustered_cull_cs.wgsl`, `assets/shaders/common/light_types.wgsl`):** Added `ClusteredLightCuller` dispatching `cs_reset` + `cs_cull` (`16 × 9 × 24 = 3,456` frustum clusters, logarithmic Z slicing, 64-thread workgroup-per-cluster cooperative culling up to `1024` point / `256` spot hits per tile, exact minimum spotlight cone bounding spheres + behind-apex half-space rejection, and compacted atomic index storage).
  - **1,024 Point + 256 Spot Lights (`engine.scene.light`, `engine.scene.scene_file`, `engine.editor.light_panel`, `engine.editor.scene_renderer`, `engine.scene.scene3d_textured`):** Raised active local light caps from `32/4` to `1,024` point lights and `256` spot lights while keeping shadow caster limits deterministic (`1 / 4 / 2`); moved spot lights into a GPU storage buffer (`@group(0) @binding(13)`), expanded `@group(0)` to `FRAME_BINDING_COUNT = 16` (cluster grid @ `14`, index pool @ `15`), shrank `FrameUniforms` to `1024` bytes with active sub-viewport `viewportRect` mapping (`FrameContext.activeViewportRect`), and added `@nogc` `LightList` + `Scene3DTextured.addPointLight()` / `addSpotLight()` / `setClusteredCulling()` APIs with generation-tracked buffer rebinding.
  - **Full Scene Shader Coverage & Benchmark (`shadows.wgsl`, `textured3d_pbr.wgsl`, `common/simple_pbr.wgsl`, `terrain_pbr.wgsl`, `decal_pbr.wgsl`, `water_surface.wgsl`, `demo/clustered_bench.d`):** Wired clustered point + spot shading across OpenPBR meshes, terrain, projected decals, and water using explicit-LOD `textureSampleCompareLevel` for WGSL uniformity; added `dub run --config=clustered-bench` (1,024 point + 128 spot lights: `6.39 ms` p50 vs `15.71 ms` linear, **2.46× faster**, `0 B` GC allocations).

- **OpenPBR Phase 2 Completed: Subsurface Scattering, Thin-Walled Translucency, Reflection Probes & SSR (`OPBR-8` & `OPBR-9`, `2026-11-22`)**:
  - **208-byte `MaterialParams`, glTF diffuse transmission & zero-lint fixes (`OPBR-8`, `engine.graphics.material`, `engine.gpu.pipeline`, `engine.assets.gltf`, `engine.meshopt.cluster`, `tools/lint.d`):** Expanded `MaterialParams` to **208 bytes** (`13 × vec4f`) with `subsurfaceWeight`, `subsurfaceColor`, `subsurfaceRadius`, `subsurfaceRadiusScale`, `subsurfaceAnisotropy`, and `MaterialFlags.{thinWalled, subsurface, ssr}`; added `sampleDirShadowBackAndThickness` (`shadows.wgsl`), Henyey-Greenstein thin-walled back-face translucency + Penner RGB wrap subsurface scattering (`pbr_brdf.wgsl`, `textured3d_pbr.wgsl`), back-hemisphere IBL wrapping, `KHR_materials_diffuse_transmission` parsing and channel-B packing (`gltf.d`), `AssetMaterialSlot`/`SceneMaterialData`/`MaterialOverride`/Inspector support, DMD 2.113 module-level shader immutables (`shaders.d`, `pipeline.d`), and zero-violation `dub run --config=lint` cleanup.
  - **Local parallax reflection probes & Screen-Space Reflections (`OPBR-9`, `engine.editor.components`, `engine.editor.scene_renderer`, `engine.scene.scene3d_textured`, `textured3d_pbr.wgsl`, `source/demo/pbr.d`):** Added `@component ReflectionProbe` (`MAX_REFLECTION_PROBES = 4`), `SceneRenderer` ECS probe upload, `FRAME_UNIFORMS_SIZE = 1504` (`FRAME_BINDING_COUNT = 13` with `@binding(12) opaqueSceneDepthMap`), 4-pass `Scene3DTextured.end()` (0 opaque → 1 SSR opaque + water → 2 transmissive/alpha → 3 additive), `Scene3DTextured.setSsr` / `setReflectionProbes`, parallax-corrected box/sphere probe sampling (`evalLocalReflectionProbes`), and 16-step + 3-step binary raymarched SSR (`evalScreenSpaceReflection`) blended into base and coat specular IBL; expanded `demo/pbr.d` to a 6×5 showcase grid.

- **OpenPBR Phase 2: Per-pixel Layer Maps & Refractive Transmission (`OPBR-6` & `OPBR-7`, `2026-11-22`)**:
  - **WebGPU limits & 176-byte OpenPBR UBO (`source/bindings/wgpu.d`, `engine.gpu.context`, `engine.gpu.pipeline`, `engine.graphics.material`):** Added `WGPULimits` / `wgpuAdapterGetLimits` / `wgpuDeviceGetLimits` and requested `maxSampledTexturesPerShaderStage = 32` at device creation; expanded `MaterialParams` from 144 to **176 bytes** (`11 × vec4f`) with `anisotropyRotation`, `thinFilmThicknessMin`, `transmissionColor`, `transmissionWeight`, `transmissionDepth`, `transmissionDispersion`, `transmissionThickness`, and `MaterialFlags.{coat, coatNormal, fuzz, anisotropy, thinFilm, transmission}`; added `MaterialLayerMaps` at `@group(1) @binding(8..12)` (`MATERIAL_BINDING_COUNT = 13`) and `Material.transmissive`.
  - **5-mip opaque HDR pyramid & multi-pass transmission (`engine.gpu.renderer`, `engine.scene.scene3d_textured`):** `Renderer.snapshotOpaque` downsamples the `rgba16Float` HDR color buffer across 5 mip levels (`OPAQUE_COLOR_MIPS = 5`) via `post_bloom_down.wgsl`; bumped `@group(0)` `FRAME_BINDING_COUNT` to 12 with `@binding(11) opaqueSceneColorMap`; `Scene3DTextured.end()` routes `Material.transmissive` batches into back-to-front Pass 1 (`renderPassOf`), snapshots and binds the opaque pyramid on demand, and restores the 1×1 placeholder outside Pass 1.
  - **Shaders, glTF packing, serialization & showcase (`textured3d_pbr.wgsl`, `common/pbr_brdf.wgsl`, `engine.assets.gltf`, `engine.graphics.model`, `engine.graphics.skinned_model`, `source/demo/pbr.d`):** Added per-pixel clearcoat/coat-normal/fuzz/anisotropy/thin-film evaluation (with `textureSampleLevel` for WGSL uniform control flow), IOR screen-space refraction with roughness-driven mip selection, Beer-Lambert volume absorption, RGB dispersion, and coat/fuzz transmittance; parsed and packed `clearcoat{,Roughness,Normal}Texture`, `sheen{Color,Roughness}Texture`, `anisotropyTexture`, `anisotropyRotation`, `iridescenceThicknessMinimum`, `iridescenceThicknessTexture`, `KHR_materials_transmission`, `KHR_materials_volume`, and `KHR_materials_dispersion`; added serialization/Inspector controls and expanded `demo/pbr.d` to a 5×5 showcase.

- **Instanced OpenPBR GPU skinning, shadow casting & multi-mesh character glTF import (`2026-11-22`)**:
  - `SkinnedVertex` (`engine.graphics.types`, 80 bytes) now includes `uv` and `tangent` alongside `position`, `normal`, `joints`, and `weights`; added `SkinnedMesh` (`engine.gpu.skinned`).
  - `Scene3DTextured.drawSkinned` renders skinned meshes through the full OpenPBR pipeline (`textured3d_pbr.wgsl` `SKINNED` + `MESH_TANGENT`, IBL, CSM, point/spot lights, fog, rain wetness, bloom) and shadow passes (`shadow_depth.wgsl` `SKINNED`), batching multiple characters per `(SkinnedMesh, Material)` using a concatenated `@group(3)` palette storage buffer and culling via the live `poseBoundingSphere`.
  - `loadGltfSkinnedCharacterCpu` (`engine.animation.gltf_skin`) and `loadGltfSkinnedCharacter` / `SkinnedCharacterAsset` / `drawSkinnedCharacter` / `setCharacterMaterialOverride` (`engine.graphics.skinned_model`) import all skinned meshes and primitives from `.gltf`/`.glb` files with material names, `doubleSided`, `byteStride`, normalized weights, and auto-generated tangents.
  - Added `poseBoundingSphere` and `jointWorldMatrix` (`engine.animation.ecs.systems`), plus `--pbr`, `--crowd=N`, and `--bench=FRAMES` modes in `anim-viewer` (`40` animated characters + ground in `2` color draw calls with `0` GC allocations).

- **Water demo is game code only (WP-10, `2026-11-22`)**: the water demo uses the engine `OrbitCamera` and automatic `renderShadows` instead of its own camera and shadow passes; `--no-hud` also hides the F1 hint. `OrbitCamera` gains `minPitch` / `maxPitch`, `wheelZoomSpeed` and `dragToRotate`. The water engine port (`plan-water-engine-port.md`) is complete.

- **Water in scenes and the editor (WP-9, `2026-11-22`)**: `engine.water.component.WaterSurface` (`@component`, flat POD saved in scene files) and `toWaterBody`; the editor's **Criar > Água** and inspector section **Água**; `SceneRenderer.enableWater` draws `WaterSurface` entities in the editor and the player and shows the engine sky while water exists. Undo snapshots keep the component.

- **Wet material presets (WP-8, `2026-11-22`)**: `engine.graphics.material_presets` — `dryStoneParams`, `wetSurfaceParams`, `mossSurfaceParams`, `submergedSurfaceParams` (OpenPBR water coat / moss fuzz, with a non-OpenPBR fallback). The water demo uses them instead of its own builders.

- **Water gameplay queries and buoyancy (WP-7, `2026-11-22`)**: `engine.water.query` (`waterSurfaceAt` / `waterSurfaceHeight` → height, normal and river current; `WaterRenderer.surfaceAt`; `WaterQuery`) and `engine.water.buoyancy` (`applyBuoyancy` with spherical `BuoyancyProbe`s, `sphereProbes`, `BuoyancySettings`). Physics: `applyForce` (at a world point), `getMass`, `getRotation`. The water demo's buoys are now Box3D bodies.

- **Generic underwater caustics (WP-5, `2026-11-22`)**: `assets/shaders/common/caustics.wgsl` (`waterCausticsAt`) lights every PBR mesh, terrain and decal fragment below a water body's level with animated sun caustics (strength `WaterBody.causticsStrength`, river flow and channel fade from the shared water data). **Removed:** `caustics_bed.wgsl` / `causticsBedShaderSource`, `evalCausticsRgb` / `voronoiCausticLayer` (`common/water_env.wgsl`) and the water surface's screen-space prop caustics. The water demo's seabed is now a PBR mesh.

- **`WaterRenderer` + `WaterBody` (WP-3/WP-4 of [plan-water-engine-port.md](docs/plan-water-engine-port.md), `2026-11-22`)**:
  - `engine.water.water_body`: POD `WaterBody` (center, half extent, level, grid resolution, `WaterStyle` ocean/river, `WaveSet`, `WaterOptics`, `WaterFeature` bits, current, bed depth, wet-mark and caustics settings) with `ocean()` / `river()` presets; `WaterObstacle`.
  - `engine.water.renderer`: `WaterRenderer` draws up to 4 bodies after the sky (transparent hook, one shared opaque snapshot), steps a 256² compute wave/foam simulation per body, takes up to 16 obstacles per body and fills the shared water data. `water_surface.wgsl` / `water_sim_cs.wgsl` take per-body uniforms (`WaterSurfaceUniforms`) instead of assuming water at the origin and Y = 0.
  - `common/sky_eval.wgsl` splits `evalSky` into `evalSkyBase` + `evalSkySun` (same result) so water evaluates clouds once and the sun glitter per exact direction.
  - Wave constants (`k`, `omega`, warp scale) are precomputed on the CPU, and the PBR wetline loads a body's waves once per fragment (`WaterPoint`): wetline history ~2× cheaper.
  - The water demo now uses `WaterRenderer` and builds with DMD again. Root cause of the DMD 2.113 crash: a CTFE-built shader `enum` used directly inside a function; use a module-level `immutable string`.

- **Water reflects the engine sky (WP-6, `2026-11-22`)**: new `assets/shaders/common/sky_frame.wgsl` (`frameSkyInputs`, `frameSky`) shared by `sky.wgsl` and `water_surface.wgsl`. **Removed:** `assets/shaders/sky_dome.wgsl`, `skyDomeShaderSource` and `evalWaterSky` (`common/water_env.wgsl`); `WaterUniforms.flags0.w` (low sun) is unused. The water demo now uses `scene.setSkyEnabled(true)`.

- **Shared GPU water data (WP-2 of [plan-water-engine-port.md](docs/plan-water-engine-port.md), `2026-11-22`)**:
  - Frame bind group gains `@binding(10)`: `GpuWaterData` (`engine.water.gpu_data`), up to 4 water bodies with XZ bounds, level and their own `WaveSet`; `Scene3DTextured.setWaterData`; WGSL side in `assets/shaders/common/waves.wgsl` (`waterBodyAt`, `waterWaveY`, `waterSurfaceY`, …). `FRAME_BINDING_COUNT` = 11.
  - The PBR wetline and the water surface read waves, time (`frame.time`), contact chop and recent peak scale from it, so the wave tables are no longer duplicated in `textured3d_pbr.wgsl` and the water UBO.
  - `Scene3DTextured.addTransparentHook`: draw stage after the sky and before alpha batches (for refractive water).
  - **Breaking:** `MaterialFlags.waterRiverMode` removed (bit 5 reserved); river vs ocean waves come from the body's `WaveSet`. `waterWetCaustics` no longer reads `MaterialParams._pad0/_pad1`.

- **Water wave model (`engine.water.waves`, WP-1 of [plan-water-engine-port.md](docs/plan-water-engine-port.md), `2026-11-22`)**:
  - `WaveSet` (POD, up to 8 Gerstner `WaveComponent`s) with `WaveModulation` (wave-group envelope + phase warp), `WaveChannel` (river bank taper) and `amplitudeScale`; presets `WaveSet.ocean()` / `WaveSet.river()`.
  - `sampleWaves` (displaced point, normal, tangent, crest factor with Jacobian folding) and `waveHeightAt` (world-XZ height via fixed-point pullback; 1 iteration matches the PBR wetline).
  - The water demo now uses them instead of its own wave tables and `sampleGerstner`; captures are pixel-identical. `--capture` uses a fixed 1/60 s step so captures are reproducible.
  - Guide: [docs/water-guide.md](docs/water-guide.md).

- **Productivity Multipliers: Asset/Tunable Hot-Reload, Splines & Blender Export (`OW-8`, `2026-11-21`):**
  - **P8.1 watcher & hot-reload** (`engine.hotreload`, `engine.editor.scene_renderer`, `engine.scene.prefab`, editor, player):
    - `FileWatcher` now reports `changedPaths()` per debounced batch, watches subdirectories created after `init`, and adds a portable mtime polling backend (`WatchBackend`) for Windows/macOS/Web and as the Linux fallback;
    - **HR-1** `AssetHotReloader` routes edits to their owners: `SceneRenderer.reloadChangedFiles` (models via `assetDependencies` / `gltfFileDependencies`), `watchTexture`, `watchSurfaceShader`, `reloadPrefabInstances` (live instances rebuilt with per-instance overrides kept), a scene callback, and registered tunables. All swaps are transactional;
    - **HR-2** `TunableRegistry`: `*.tune.json` flattened to dotted `StringId` keys, `@nogc` reads, `applyTo` / `applyToComponents`, `onReloaded`, `generation`, `FrameArena` labels;
    - wired into the editor (always, except headless) and the player (`--hot-reload`); `applyPropertyOverrides` now restores Transform rotation and Light color.
  - **P8.2 splines & Blender pipeline** (`engine.math.spline`, `engine.scene.splines`, `tools/blender_export_scene.py`):
    - `Spline3`: centripetal Catmull-Rom / cubic Bézier, open or closed, arc-length LUT, `upVector` / rotation-minimizing frames, `closestPoint` with lateral offset, `extrudeRibbon` road meshes (all `@nogc` after `rebuild`);
    - `*.splines.json` spline sets linked from root scenes (`assetLinks` kind `splines`, ignored by `WorldStreamer`);
    - Blender exporter: GLB + `*.asset.json` per unique mesh, per-cell v2 chunk scenes, root `ChunkManifest`, curve → spline export, `ge_*` custom properties, deterministic GUIDs, and `--build-test-level`;
    - `assets/world/ow8_test_level` (forest/desert/snow, 3 × 3 cells, road/traffic/river) is validated and streamed through `WorldStreamer` in `engine.scene.world_export_tests`.
  - Guide: [docs/world-pipeline-guide.md](docs/world-pipeline-guide.md).

- **World Chunk Streaming (9 km²), ECS/Prefab Fixes & `steadygc` Windows (`OW-7`, `2026-11-21`):**
  - **P7.1 `EntityId` recycling, generations & additive scene/prefabs** (`engine.ecs`, `engine.editor.scene_load`, `engine.scene.prefab`): added `EntityHandle`, free-list `EntityId` recycling, generation counters (`generation`, `handle`, `aliveHandle`, `capacity`, `freeCount`, `clearEntities`), `loadSceneAdditive`, `collectSubtreeEntities`, `subtreeToSceneFile`, additive `instantiatePrefab`, full-hierarchy `revertPrefab`, subtree-scoped `applyPrefabOverrides`, and `diffPrefabOverrides`/`applyPropertyOverrides`.
  - **P7.2 `SceneFile` v2, `WorldStreamer` & standalone player** (`engine.scene.scene_file`, `engine.scene.streamer`, `engine.editor.scene_renderer`, `tools/player/player_main.d`): extended `SceneFile` to v2 (`ChunkManifest`, `SceneCellBounds`, `SceneAssetLink`, `visual.assetGuid`, per-chunk light validation); implemented `WorldStreamer` with hysteresis (`unloaded → loading → active → unloading`), GC-excluded background worker I/O/decode (`ScopedGcExcludedThread`), frame-budgeted upload queue, `SceneRenderer.unloadAsset`, reference-counted unloading of `GltfAsset`/`Texture`/`CookedMesh`/`NavMesh` tiles, and a 100-cycle 9 km² soak test; wired `makeAssetResolver` and `WorldStreamer` into the standalone player and `PlayMode`.
  - **P7.3 Windows `steadygc` & cross-compile parity** (`dub.json`, `tools/build_symgc.sh`, `source/editor/build_export.d`, `vendor/symgc`): moved Linux-only libs to `libs-linux` and added `libs-windows`/`lflags-windows`; updated `build_symgc.sh` to emit `symgc-cards.lib` for `windows-x86_64` without `-fPIC` or clobbering the host symlink; updated `ExportPipeline` to pass `-i`, C import files, `synchronization.lib`, and `/EXPORT:__sd_gc_card_*`; cached thread-local `CreateWaitableTimerExW` handles in `d.gc.time`; implemented Windows Tier 2 `MEM_WRITE_WATCH` + `GetWriteWatch`/`ResetWriteWatch` dirty-page tracking in `d.gc.dirty` and `d.gc.memmap`.

- **Animation (`ozz`) ↔ Physics Bridge & Minimap/Compass UI (`OW-5`, `2026-11-21`):**
  - **P5.1 math helpers & world-space bone sockets** (`engine.math`, `engine.animation.ecs`): added `Quat.fromMat4`, `decomposeAffine` / `Mat4.decompose`, POD `BoneSocket` component, and `@nogc` `boneSocketSystem` attaching entity `Transform`s to skeleton joints in world space.
  - **P5.2 partial bone masks & ECS wiring** (`engine.animation.blending`, `ecs.assets`, `ecs.components`, `ecs.systems`): added `fillJointWeights`, `setJointWeight`, `getJointWeight`, `setSubtreeWeights`, `buildSubtreeMask`, `JointMaskStore` (`AnimAssets.jointMasks`), `maskA`/`maskB` on `AnimBlend2`, `mask` on `AnimAdditive`, and `AnimLayerOverride` processed by `advancePlaybackSystem` / `sampleSystem` / `blendSystem`.
  - **P5.3 bidirectional ragdoll ↔ skeleton bridge** (`engine.animation.ragdoll`, `ecs.pose_pool`): added `Pose.ragdollPose`, `modelToLocalSoa`, POD `RagdollAsset` / `RagdollAssetStore` / `RagdollComponent` (`animated` / `ragdoll` / `blendingToAnim`), `spawnRagdollBodies` / `destroyRagdollBodies` (Box3D spherical joints + negative `collisionGroupIndex` filtering), `activateRagdoll` (linear/angular velocity inheritance), `beginRagdollGetUp` (pelvis alignment + face-up/face-down clip selection + `BlendingJob` crossfade), `syncSkeletonToPhysics`, `syncPhysicsToSkeleton`, and `ragdollSystem`.
  - **P5.4 UI analytical circular clipping & image rotation** (`assets/shaders/ui2d.wgsl`, `engine.ui`, `engine.graphics.texture`, `demo.ui_gallery`): added `pushCircleClip` / `popCircleClip` with 1 px smoothstep AA via 256-byte strided dynamic uniform offsets, `drawImageRotated`, `drawImageUvRotated`, `UiStyle` (`clipCircle`, `imageRotation`, `rotateImageUv`), `UiNode` (`imageUvRect`, `imageTint`), `imageRotated` / `minimapImage` widgets, `Texture.createRenderTarget`, and a rotating circular minimap + clipped POI marker showcase in `ui-gallery`.

- **Configurable terrain colliders & generic procedural PBR texture toolkit (`2026-11-21`):**
  - `engine.terrain.physics`: added `TerrainColliderDesc` (`tileCells`, `filter`, `entityId`, `enableHitEvents`), `terrainColliderTileCount`, and `buildTerrainColliders` overloads accepting `TerrainColliderDesc` and an optional `b3BodyId[] outBodies` buffer (backwards-compatible with the original signature).
  - `engine.math.noise`: added tileable 2D `@nogc` primitives (`valueNoiseTiled2D`, `fbmTiled2D`, `ridgedTiled2D`, `VoronoiSample`/`voronoiTiled2D`, `BrickSample`/`brickPatternTiled2D`).
  - `engine.terrain.generate`: added `ProcNoiseBasis` (`fbm`, `ridged`, `voronoi`, `brick`), POD `ProcLayerDesc`, `biomeLayerDesc`, `evaluateProcLayer`, `generateLayerTextures` / `@nogc` `generateLayerTexturesInto`, and low-level heightfield bakers (`bakeNormalsFromHeightField`, `bakePbrMapsFromHeightField`, `bakePbrMapsFromHeightFieldInto`).

- **Outdoor rendering: CSM, fog, sky, day/night, runtime IBL, wetness, terrain and decals (`OW-3`, `2026-11-21`):**
  - **P3.1 cascaded shadows** (`engine.scene.cascades`, `shadows.wgsl`):
    - 4 PSSM cascades, sphere-fitted and texel-snapped, in one `depth32Float` array (frame binding 2 is now `texture_depth_2d_array`);
    - per-cascade caster culling, cascade blending, max-distance fade, `GpuDirLight.cascades` / `debugCascades`;
    - `Scene3DTextured.addShadowCasterHook`.
  - **P3.3 linear HDR height fog** (`engine.scene.atmosphere`, `common/atmosphere.wgsl`):
    - `FogSettings`, `scene.setFog`, sun in-scattering;
    - applied in PBR, water, terrain, decals and sky;
    - `settings.fog` in scene files and editor controls.
  - **P3.4 engine sky** (`engine.gpu.sky`, `sky.wgsl`, `common/sky_eval.wgsl`, `scene.setSkyEnabled`) and **day/night + weather** (`engine.scene.time_of_day`: `TimeOfDay`, `Weather`, `evaluateEnvironment`, `applyEnvironment`, `applyEnvironmentToScene`).
  - **P3.4 runtime HDR IBL** (`engine.gpu.ibl_dynamic.DynamicIbl`, `ibl_sky_cs.wgsl`):
    - compute sky → `rgba16Float` cube → irradiance + GGX mips;
    - one step per frame, double-buffered.
  - **P3.4 global rain wetness:** `scene.setWeather`, coat darkening and gloss in `textured3d_pbr.wgsl`, `custom.w = 1` shelters an instance.
  - **P3.2 chunked terrain** (`engine.terrain`, `terrain_pbr.wgsl`, `terrain_shadow.wgsl`):
    - Box3D-identical 16-bit heights and cell diagonal;
    - vertex-buffer-less grid template with per-LOD index ranges, skirts and geomorphing, so at most 5 instanced draws;
    - top-4 height-blended layers out of 8, triplanar cliffs, distance de-tiling, wetness;
    - casts into every cascade;
    - `buildTerrainColliders` heightfield tiles with dominant-layer surface materials;
    - procedural heights, 4-biome splat and layer textures. See `docs/terrain-guide.md`.
  - **P3.5 projected decals** (`engine.graphics.decals`, `decal_pbr.wgsl`):
    - `DecalSystem` ring buffer with lifetime fades;
    - `DecalRenderer` reconstructs from the opaque depth snapshot, lit with CSM, IBL, fog and wetness;
    - `Scene3DTextured.addPostOpaqueHook`.
  - **Renderer and API additions:**
    - `FrameUniforms` grew to 1280 bytes (camera, cascade, fog, sky and weather fields);
    - `Scene3DTextured.addOpaqueHook`, `setEnvironmentBindGroup`, `setSkyState`, `setSkySun`, `setWeather`;
    - `FrameContext.draw`;
    - `common/simple_pbr.wgsl`.
  - **Demos:**
    - new `outdoor` config (3 km terrain, 12k rocks, day/night, rain, dynamic IBL, 500 decals; `--headless-frames --assert-no-gc --time-scale --tod --rain --debug-cascades --decals --view`);
    - `openworld-bench` gains `--debug-cascades --fog --tod --rain --wetness --decals --screenshot`.
  - **Deviations from the plan:**
    - the terrain heightmap texture is `r32Float` (exact physics surface, no 16-bit-norm feature needed);
    - the CPU-prefiltered `IblEnvironment` stays `rgba8Unorm`, while `DynamicIbl` is HDR.

- **3D Navigation & Dynamic Obstacles (`OW-6`, `2026-11-20`):**
  - Vendored `recastnavigation` `v1.6.0` (`Recast`, `Detour`, `DetourTileCache`, `DetourCrowd`, `fastlz`) in `vendor/recastnavigation/` compiled with `-DDT_POLYREF64` into `libs/librecast_shim.a`, wrapped via `source/bindings/recast/` (`recast_shim.h`/`.cpp`, `recast_import.c`, `package.d`) and wired into `dub.json`, `tools/build_sdl3_deps.sh`, and `source/editor/build_export.d`.
  - Implemented `@safe nothrow @nogc` `Pod!T` `engine.nav` (`types.d`, `mesh.d`, `bake.d`, `ecs.d`, `debugdraw.d`): RAII `NavMesh`, `NavTileCache` (cylinder, AABB, OBB dynamic obstacles), `NavQuery` (`findNearestPoly`, `findPath`, `findStraightPath`, `raycast`), `NavCrowd` (50-agent `@nogc` update verified), binary `.navmesh` serialization + `AssetDatabase` `.navmesh` importer, and POD ECS components (`NavMeshSurface`, `NavAgent`, `NavMoveRequest`, `NavObstacle`, `NavOffMeshLink`, `NavModifierVolume`, `stepNavAgents`).
  - Added alpha-blended filled `trianglelist` pipeline (`GizmoRenderer.triangle`) to `source/engine/devtools/gizmos.d` and `drawNavMesh` helper.

- **3D Spatial Audio, Doppler, Real-Time VHF DSP & OGG Vorbis Streaming (`OW-4`, `2026-11-20`):**
  - Completed `P4.1` in `source/engine/audio/spatial.d` and `engine.d`: POD `AudioListener3D` and `AudioSource3D`, relative radial `dopplerPitch`, `play3D` / `playStream3D` / `updateSource3D`, `spatialBlend` mono downmix, per-chunk parameter smoothing (volume, pitch, pan), and `excludeAudioThreadFromGc()` on SDL3 audio callback startup.
  - Added 8-bus routing (`sfx`, `music`, `voice`, `radio`, `ambient`, `ui`, `custom0`, `custom1`) with independent per-bus accumulation buffers and `@nogc` POD `DspEffectSlot` / `DspChain` (`source/engine/audio/dsp.d`: biquad HPF/LPF/BPF, waveshaper, squelch-gated `staticHiss`, and `DspChain.vhfRadio()` preset) attachable per bus (`setBusDsp`) or per voice (`setVoiceDsp`).
  - Added compressed OGG Vorbis streaming (`vendor/stb/stb_vorbis.c`, `source/bindings/stb_vorbis/`, `source/engine/audio/stream.d`): lock-free SPSC `PcmRingBuffer`, `AudioStream` (`openOggFile`, `openOggMemory`, `pump`, `seekStart`), and `AudioMixer.playStream`, wired into `dub.json` and `source/editor/build_export.d`.

- **Audio: per-voice panning and 3D one-shot SFX (`2026-11-19`)**:
  - `AudioMixer.setPan(VoiceId, float)` and a `pan` argument on `AudioMixer.play` (`-1` left … `+1` right; mono sources panned, stereo sources balanced, unity at center).
  - `engine.audio.spatial`: `Listener3D`, `SpatialParams`, `distanceGain` (logarithmic inverse-distance model with smooth max-distance taper), `emitterPan`, `play3D` and `updateVoice3D`. Panning is applied in the mixer per voice, so no pre-panned clip pool is required.

- **Editor: Abrir cena (`Ctrl+O`) (`2026-11-19`)**:
  - Cena → Abrir cena... and `Ctrl+O` open a centered picker listing every `*.scene.json` under `assets/` (`engine.editor.scene_picker`, `findScenePaths`). `Ctrl+O` previously only showed the Project panel.
  - Opening a scene over unsaved changes now logs a warning naming the scene whose changes are discarded.
  - The Cena menu lists its seven items; it previously reported two, which clipped the export entries.

- **Editor: scene objects that were invisible after opening (`2026-11-19`)**:
  - `loadSceneIntoWorld` reports custom components whose type is not registered (`SceneLoadResult.unresolvedComponents`). It used to skip them silently, so a scene with game-defined components showed only entity names.
  - The editor logs one warning per scene naming those component types, and draws each one as an orange wireframe box at its world position (positions are stored, not entity ids, so Play/Stop keeps them).
  - Opening a scene frames the camera on its entities (`engine.editor.scene_frame`, `framePose`) instead of the fixed default pose.
  - Scene-open messages now format their arguments correctly; they printed `%s` literally before.

- **Open-World Rendering Foundation & Multi-Node glTF (`OW-2`, `2026-11-19`)** — commits `1629ea4`, `cb53446`, `3067572`, `ad31363`:
  - Textures: opt-in CPU mip chains (`TextureDesc`), `SamplerDesc` anisotropy, `TextureArray`, `Texture.fromR16` / `fromR32F`, and `r16Unorm`/`r32Float`/`r16Float`/`rg16Float`/`rgba32Float` formats in `source/bindings/wgpu.d`.
  - Zero-GC `Scene3DTextured`: malloc-backed `PodBuffer` instance lists, open-addressed `BatchMap` keyed by `(mesh, material, lod)`, cached frame bind group, and the full `FrameContext.drawIndexed(indexCount, instanceCount, firstIndex, baseVertex, firstInstance)` signature (the color pass now draws only the batch's LOD range).
  - glTF: `.glb` containers, `data:` buffers, embedded images, all meshes/primitives/materials and the node tree (`parseGltfDocument`, `parseGltfScene`); `GltfAsset`, POD `ModelInstance` (visibility, `MaterialHandle` overrides, transform overrides), `MaterialPool`, `drawModel`, `detachSubMesh` and `loadGltfAsset` in `engine.graphics.model`.
  - Culling: `Aabb`/`BoundingSphere` (`engine.math.bounds`), `Frustum` (`engine.math.frustum`), mesh bounds, per-instance frustum and distance/min-pixel culling partitioned for the color and directional shadow passes, `SpatialGrid` (`engine.scene.spatial_grid`), `RenderStats`.
  - LOD: shared `selectLod` (`engine.graphics.lod`), `uploadLodMesh` load-time LOD chains, `LOD_AUTO` per-instance selection in `drawMatrix`.
  - Point-light faces and spot shadow views cull dynamic casters per view (light range sphere + view frustum) into one shared per-frame caster buffer (`gatherLightCasters`, `RenderStats.shadowInstancesDrawn`); `openworld-bench` adds a shadowed point + spot light and `--no-cull` for comparison (~11,600 → ~110 dynamic casters per frame).
  - Editor and player render through the shared `SceneRenderer` (`engine.editor.scene_renderer`) on `Scene3DTextured`: `*.asset.json` mesh entities load their glTF/GLB as cached `GltfAsset`s (previously drawn as cubes), scene `Light`s render with shadows (default sun when none), `MaterialOverride` tint, culling and LOD. `FrameContext.resumeScenePass` re-applies the last viewport. `.meta` `settings.lod` builds LOD chains in every glTF loader (`lodImportFor`, `uploadImportedMesh`). Player `--render` runs headless frames with real rendering (0 GC bytes over 600 frames).
  - `StaticInstanceBuffer` (`engine.scene.static_instances`) with per-cell culling, per-cell LOD and run merging; `Scene3DTextured.submitStatic`.
  - `openworld-bench` demo (`source/demo/openworld_bench.d`): 12,000 props over 3 km × 3 km + 200 multi-node vehicles, **0 GC bytes** over 600 frames with LOD0/1/2 in use.
  - `Mat4`, `Quat` and `Camera` members are now `pure nothrow @nogc`; the editor picking `Aabb` is now `engine.math.bounds.Aabb`.

- **Encrypted Asset Packs (`engine.assets.pak`) & External Static Project Export (`2026-11-19`):**
  - Added `source/engine/assets/pak.d` (re-exported by `engine.assets`) implementing the `GEPK` v1 container format with FNV-1a 64-bit normalized path hashing, SplitMix64 XOR stream encryption for both TOC (with 64-bit verification tag) and payloads, and a mounted VFS (`mountAssetPak`, `mountAssetPakFile`, `readAssetBytes`, `assetExists`, `packDirectoryToPak`).
  - Integrated transparent VFS asset loading into `Font.loadFromFile` (`source/engine/ui/text/font.d`), `Texture.fromImageFile` (`source/engine/graphics/texture.d`), and `source/engine/assets/gltf.d` (`parseGltfMaterial`, `parseGltfMesh`, `loadImageTexture`).
  - Added standalone `game-engine-pak` CLI (`tools/pak_main.d`, DUB config `pak`) with `--verify` round-trip and header-obfuscation validation.
  - Fixed `player-static` in `dub.json` to link Phobos statically under DMD (`-defaultlib=libphobos2.a`), pass `-link-defaultlib-shared=false` under LDC, exclude `hotreload/loader.d` & `hotreload/reload.d`, and link static `libwgpu_native.a` / `libbox3d.a`.
  - Extended `ExportPipeline` (`source/editor/build_export.d`) and `tools/export_main.d` with external project static export (`--project`, `--engine`, `--source`, `--assets`, `--protect-assets`, `--embed-pak`, `--pak-key`, `--version`), compiler auto-detection (`hasLdcStaticPhobos()`), `verifyPakObfuscation()`, and post-build ELF verification (`verifyStaticBinary()` checking `readelf -d` and `ldd`).

- **Complete Box3D Physics API (`OW-1`, `2026-11-19`):**
  - Expanded `source/bindings/box3d/functions.d` with native Box3D C99 bindings for heightfields, per-shape/mesh surface materials, collision filters, contact manifold data (`b3Contact_GetData`, `b3Body_GetContactData`), body type/CCD/sleep/mass controls, and spherical/wheel/prismatic/filter joints plus constraint force/torque queries and joint events.
  - Replaced the fixed `retainedMeshes[256]` leak in `source/engine/physics/body.d` with move-only RAII `CookedMesh` and `CookedHeightField` handles plus world-owned cleanup in `PhysicsWorld.~this()` (`source/engine/physics/world.d`), and added `createHeightField` (with `heightFieldHole` and per-cell `PhysicsSurfaceMaterial[]`).
  - Added POD descriptors (`BodyDesc`, `CollisionFilter`, `PhysicsSurfaceMaterial`, `PhysicsBodyType`) and `@nogc` runtime helpers (`setBodyType`, `setBodyDensity`, `isBodyAwake`/`setBodyAwake`, `setBodyBullet`, `setBodyFilter`, `setShapeSurfaceMaterial`, `applyLinearImpulse`, `applyAngularImpulse`, `PhysicsWorld.awakeBodyCount`).
  - Extended `RayCastHit` (`source/engine/physics/queries.d`) with `entityId` and `surfaceMaterialId` + `makeQueryFilter`, and `PhysicsHitEvent` (`source/engine/physics/events.d`) with `materialIdA`, `materialIdB`, `normalImpulse`, and `frictionImpulse`.
  - Added `createSphericalJoint`, `createWheelJoint`, `createPrismaticJoint`, `createFilterJoint`, joint config structs, runtime joint motor/angle/reaction helpers, and `@nogc` `BreakableJointTracker` in `source/engine/physics/joints.d`.
  - Fixed the `test-physics-box3d` DUB configuration in `dub.json` and expanded `source/demo/test_physics_box3d.d` with headless tests covering heightfields, surface materials, hit impulses, breakable weld joints, spherical ragdoll chains, filter joints, dynamic type toggles, sleeping/wake, and CCD.

- **2D Instanced `SpriteRenderer`, `Camera2D`, `SpriteRegion` & `SpriteAnim` (`2026-11-19`)** — commit `f614d28`:
  - Created `source/engine/graphics/sprite.d` (re-exported by `engine.graphics`) and `assets/shaders/sprite2d.wgsl` (`sprite2dShaderSource` in `source/engine/gpu/shaders.d`).
  - Added POD 2D primitives (`Camera2D`, `Transform2D`, `SpriteRegion`, `SpriteAnim`, `Sprite`, `SpriteBlendMode`) and instanced `@nogc` `SpriteRenderer` supporting both the HDR scene pass (pre-`resolvePost`) and the LDR present pass (post-`resolvePost`), `(layer, zOrder, sequence)` sorting, draw-call coalescing, `nearest`/`linear` sampling, `drawRect`, and transactional `reloadShader`.
- **Multiplatform Static Release Exporter (`EXPORT-NATIVE`, `EXPORT-WEB`, `2026-11-18`)** — commits `751c1fd`, `ea382cb`, `ade89b7`, `2efdc97`:
  - Dependency build script `tools/build_sdl3_deps.sh` to clone and compile static `SDL3` (`release-3.4.0`), `SDL3_image` (`release-3.2.4`), `SDL3_ttf` (`release-3.2.2`), and `FreeType 2` (`VER-2-13-3`) archives under `libs/<target>/` (with host `linux-x86_64` build and dev `.so` symlinks).
  - Dual-mode C linkage (`version (StaticSDLDeps)` static release linkage vs. lazy `SDL_LoadObject` dynamic loading during local development) in `source/bindings/sdl3_image.d` and `source/bindings/sdl3_ttf.d`.
  - DUB configurations `player-static` (`StaticSDLDeps`, `--as-needed`, static `SDL3`/`SDL3_image`/`SDL3_ttf`/`FreeType` archives) and `export` (`tools/export_main.d`) in `dub.json`.
  - Expanded `source/editor/build_export.d` (`ExportPipeline`, `ExportTarget`, `ToolchainCheck`, `BuildExportOptions`) supporting 7 targets (`linux-x86_64`, `linux-arm64`, `windows-x86_64`, `macos-arm64`, `macos-x86_64`, `macos-universal`, `web-wasm32`), preflight checks (`--check-toolchains`), bundle packaging (`.tar.gz`, `.zip`, macOS `.app` with `Info.plist`, `lipo`, ad-hoc `codesign`), and `THIRD-PARTY-LICENSES.txt` generation.
  - Emscripten WebGPU canvas support via `WGPUSurfaceSourceCanvasHTMLSelector` (`WGPUSType.surfaceSourceCanvasHTMLSelector = 0x0004_0000` in `source/bindings/wgpu.d`), `NativeSurfaceBackend.webCanvas` (`source/engine/platform/window.d`), async `emscripten_sleep(1)` adapter/device polling (`source/engine/gpu/context.d`), and `tools/web/shell.html`.
  - Export release actions wired into the Editor File menu (`MenuAction.exportLinux`, `exportWindows`, `exportMacOS`, `exportWeb`) in `source/editor/editor_app.d`.
- **Standalone Player 3D Scene Loop & `App.run` (`PLAYER-RENDER`, `2026-11-18`)** — commit `3f32b46`:
  - `App.run(scope void delegate(float dt) frameFn)` in `source/engine/app.d` with native `MonoTime` delta-time loop on desktop and `emscripten_set_main_loop_arg` thunk on `WebAssembly`.
  - `tools/player/player_main.d` upgraded to render loaded `.scene.json` entities (`Transform`, `Visual`, `MaterialOverride`, `Camera3D`) through `Scene3D` and post-processing inside `App.run`, while preserving `0 bytes` GC allocation in `--headless-frames=600 --assert-no-gc`.
- **Unified Image Pipeline (`SDL3_image`, `SDL-IMG`, `2026-11-18`)** — commit `bfbc2ab`:
  - Expanded `source/bindings/sdl3.d` with `SDL_Surface`, `SDL_Color`, `SDL_IOStream`, `SDL_SharedObject`, `SDL_ConvertSurface`, `SDL_LoadPNG_IO`, `SDL_LoadBMP_IO`, `SDL_LoadSurface_IO`, and `SDL_SetWindowIcon`.
  - Created `source/engine/assets/image.d` (`surfaceToRgba8`, `decodeImageBytes`, `decodeImageFile`, `decodeSvgBytesSized`, `saveRgbaJpg`), `Texture.fromSurface` / `fromSvgBytes` in `source/engine/graphics/texture.d`, and `Window.setIcon` in `source/engine/platform/window.d`.
  - Updated `source/engine/assets/gltf.d` (`loadImageTexture`) to load `.png`, `.jpg`, `.jpeg`, `.webp`, `.qoi`, `.gif`, `.avif`, `.svg`, `.tga`, and `.bmp` textures via `Texture.fromImageFile`.
- **Gameplay Utilities, Audio Mixer, Window Controls, Noise & Shapes (`2026-11-16`–`2026-11-17`)** — commits `4421e67`, `759f3a4`, `24d8882`, `bc57a23`:
  - `GameClock`, `Tweens`, `Timers`, SDL3 PNG screenshots (`app.saveScreenshot`), and external DUB dependency support (`examples/external-game`).
  - Window/VSync runtime controls, polyphonic `AudioMixer`, and action `InputMap`.
  - Procedural noise (`engine.math.noise`), `Mat4.trs`, and procedural 3D shape builders (`engine.graphics.shapes`).
  - 2D UI SDF font atlas, `UiBatchRenderer` 2D primitives, and `Font` fallback chain support.
- **Post-Processing, Particles, Batch Shadows & PBR Water Showcase (`2026-11-13`–`2026-11-16`)** — commits `c20749b`..`f22e616`:
  - AgX tonemapper, configurable `bloomRadius`, saturation/contrast controls, and custom post-processing passes (`PostStage`).
  - 32 point lights storage buffer, gradient IBL, custom PBR surface shaders, automatic batch shadow pass (`Scene3DTextured.renderShadows`), and billboard `ParticleSystem` / `ParticleEmitter`.
  - Interactive OpenPBR ocean & mountain river water showcase (`dub run --config=water`) with Gerstner waves, compute foam simulation (`WTR-6`), refraction, SSR, submerged caustics, wave-contact rock wetness, and SDL3 Xbox gamepad/haptics (`dub run --config=gamepad`).
- **Pure-D `meshoptimizer` v1.3 Port** — commits `353670f`..`1d46612`:
  - Cache/overdraw/fetch/strip optimizers, scalar & SSSE3 vertex/index codecs, `EXT_meshopt_compression` glTF decode, MikkTSpace-style tangent generation, LOD simplification, shadow LODs, collision proxies, and meshlet clustering (`source/engine/meshopt/`).
- **Skeletal Animation Runtime (`ozz-animation` Port)** — commits `4bbbe7f`..`083457f`:
  - Core runtime, SIMD math (`core.simd`), keyframe/track evaluation, IK, blending, CPU & GPU skinning, glTF skin importer (`gltf2ozz`), ECS pose pool & systems, and animation bench/viewer tools (`docs/animation-guide.md`).
- **Optional `steadygc` (`symgc`) Concurrent Card-Marking GC** — commits `da8cf8a`..`0e13fd0`:
  - 3-tier GC model (`source/engine/core/gc.d`, `vendor/symgc/`, `tools/build_symgc.sh`), `symgc` DUB configurations, adaptive frame-slack stepping, and zero-overhead compatibility with stock DMD/LDC GC.
- **OpenPBR Surface v1.1 Shading & Modular Shader Hot-Reload** — commits `7711b08`, `5426464`:
  - Single-pass OpenPBR Surface v1.1 pipeline (`assets/shaders/textured3d_pbr.wgsl`, `common/pbr_brdf.wgsl`) with 3-channel GGX + Charlie BRDF LUT and PCF multi-light shadows (`assets/shaders/common/shadows.wgsl`).
  - Modular WGSL preprocessor (`#include`, `#define`, `#ifdef`), CTFE shader embedding, and transactional `inotify` shader hot-reloading (`source/engine/hotreload/`).
- **Visual Scene Editor UX v1 & Physics (`Box3D`)** — commits `19b00af`..`6dcfb6b`:
  - Retained-mode UI and docking system (`engine.ui`), Unity/Godot-style scene editor (`dub run --config=editor`), raycast picking, TRS gizmos, undo/redo command stack, inspector reflection (`engine.reflect`), non-destructive Play/Pause/Step mode, `*.scene.json` / `*.asset.json` / `*.prefab.json` I/O, and rigid-body physics via Box3D (`engine.physics`).

### Changed

- **Font Rasterization Migrated to `SDL3_ttf` (`SDL-TTF`, `2026-11-18`)** — commit `70b51fd`:
  - Refactored `Font` (`source/engine/ui/text/font.d`) onto `TTF_Font*` (`TTF_OpenFontIO`, `TTF_SetFontSDF`, `TTF_SetFontHinting`, `TTF_AddFallbackFont`, `TTF_GetGlyphMetrics`, `TTF_GetGlyphImage`, `TTF_GetGlyphKerning`, `loadFromFile`, `destroy()`).
  - Updated `assets/shaders/ui2d.wgsl` Mode 1 SDF math to calibrated FreeType SDF parameters (`(alphaMask - 0.50196078) * 15.9375 * in.rectParams.x`, `SDF_PADDING = 8`).
  - Integrated glyph kerning into `Font.measure`, `shaping.truncateWithEllipsis`, and `UiBatchRenderer.drawText`.
- **Cross-Platform Guards for Windows, macOS & WebAssembly (`2026-11-18`)** — commits `3f32b46`, `ea382cb`:
  - Guarded Linux-only `inotify` (`watcher.d`), POSIX `dlfcn` / Windows `GetProcAddress` (`loader.d`), and subprocess shell runners (`build_runner.d`) for multi-target builds.
  - Added compile-time `hasSteadyGcSymbols` guard in `source/engine/core/gc.d` so `LDC`, `StaticSDLDeps`, and `WebAssembly` builds avoid referencing DMD-compiled `libsymgc-cards.a` symbols.
  - Replaced `std.math.cbrt` with `@safe pure` `pow` in `source/engine/graphics/particles.d` so `ldc2 --build=release` compiles cleanly.
- **Physics Backend Migration & MIT Licensing** — commits `a3357d8`, `8015568`:
  - Replaced native Jolt (`engine.jph`) port with Box3D (`vendor/box3d`, ImportC bindings) and relicensed repository under MIT (`LICENSE`).

### Removed

- **`stb` Legacy Code & Archive (`2026-11-18`)** — commits `bfbc2ab`, `70b51fd`:
  - Deleted `source/bindings/stb_image.d`, `source/bindings/stb_truetype.d`, `vendor/stb/` (`stb_image.h`, `stb_truetype.h`, `stb_impl.c`), `libs/libstb.a`, and removed `"stb"` from `dub.json`.

### Documentation

- Revised [docs/game-development-guide.md](docs/game-development-guide.md) to follow the concise, practical overview + deep-dive link structure defined in [AGENTS.md](AGENTS.md), covering all 2D/3D rendering, OpenPBR/IBL/shadows, post-processing, UI/fonts, ECS/scripting/GC-safe primitives, input/gamepads, clock/tweens, assets/meshopt, Box3D physics, skeletal animation, audio, hot-reload/editor, and multiplatform release export while fixing stale API examples (`Scene3DTextured`, `Sampler.create`, `loadGltfPbr`, `DebugOverlay.beginFrame`, `GizmoRenderer.grid`, `Timers`).
- Updated [docs/README.md](docs/README.md) guide index (updated `game-development-guide.md` summary and added [docs/animation-guide.md](docs/animation-guide.md)).
- Added [docs/export-guide.md](docs/export-guide.md) detailing every export target (`linux-x86_64`, `linux-arm64`, `windows-x86_64`, `macos-arm64`, `macos-x86_64`, `macos-universal`, `web-wasm32`), CLI options, static libraries, bundle layouts, and `SDL3_image`/`SDL3_ttf` formats (`2efdc97`).
- Updated [README.md](README.md), [AGENTS.md](AGENTS.md), [docs/README.md](docs/README.md), [docs/roadmap.md](docs/roadmap.md), [docs/editor-guide.md](docs/editor-guide.md), [docs/game-development-guide.md](docs/game-development-guide.md), [docs/multiplatform-and-shaders.md](docs/multiplatform-and-shaders.md), [docs/third-party-licenses.md](docs/third-party-licenses.md), and [docs/plan-sdl3-image-ttf-and-export.md](docs/plan-sdl3-image-ttf-and-export.md) (`cb565cc`, `2efdc97`).
