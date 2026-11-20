# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Because the repository has not yet published tagged releases, entries are grouped chronologically under `[Unreleased]` by development milestone and commit history (`git log`).

## [Unreleased]

### Added

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
