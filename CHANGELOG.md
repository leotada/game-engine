# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Because the repository has not yet published tagged releases, entries are grouped chronologically under `[Unreleased]` by development milestone and commit history (`git log`).

## [Unreleased]

### Added

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

- Added [docs/export-guide.md](docs/export-guide.md) detailing every export target (`linux-x86_64`, `linux-arm64`, `windows-x86_64`, `macos-arm64`, `macos-x86_64`, `macos-universal`, `web-wasm32`), CLI options, static libraries, bundle layouts, and `SDL3_image`/`SDL3_ttf` formats (`2efdc97`).
- Updated [README.md](README.md), [AGENTS.md](AGENTS.md), [docs/README.md](docs/README.md), [docs/roadmap.md](docs/roadmap.md), [docs/editor-guide.md](docs/editor-guide.md), [docs/game-development-guide.md](docs/game-development-guide.md), [docs/multiplatform-and-shaders.md](docs/multiplatform-and-shaders.md), [docs/third-party-licenses.md](docs/third-party-licenses.md), and [docs/plan-sdl3-image-ttf-and-export.md](docs/plan-sdl3-image-ttf-and-export.md) (`cb565cc`, `2efdc97`).
