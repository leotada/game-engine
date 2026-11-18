# Plan: SDL3_image, SDL3_ttf Integration & Static Multiplatform Release Export (Linux, Windows, macOS, Web)

> **Status:** Pending (Planned) · Priority: High · See [roadmap.md](roadmap.md)

## 1. Objective

1. **Full replacement of `stb_image` and `stb_truetype`** (`vendor/stb/`, `libs/libstb.a`, `source/bindings/stb_image.d`, `source/bindings/stb_truetype.d`) with **`SDL3_image`** (`source/bindings/sdl3_image.d`) and **`SDL3_ttf`** (`source/bindings/sdl3_ttf.d`), consolidating windowing, input, audio, surface/I/O streams, image decoding/encoding, and FreeType/HarfBuzz font rendering under the SDL3 ecosystem.
2. **Two-Mode Linkage Model (Dynamic in Engine Development, Static in Final Game Release Export)**:
   - **Engine Development (`dub build`, `dub test`, `dub run --config=editor`)**: Dynamic linkage against host or local shared libraries (`libSDL3.so`, `libSDL3_image.so`, `libSDL3_ttf.so`) or runtime `SDL_LoadObject` loading so incremental `dmd` rebuilds remain fast.
   - **Final Game Release Export (`ExportPipeline` / `ldc2 --build=release`)**: Mandatory **static linkage** (`libSDL3.a`, `libSDL3_image.a`, `libSDL3_ttf.a` + `libfreetype.a`, `libwgpu_native.a`, `libbox3d.a`, `libsymgc-cards.a`) so exported games ship with zero third-party `.so` / `.dll` / `.dylib` runtime environment errors on end-user machines.
3. **Multiplatform Release Export Pipeline (`Linux`, `Windows`, `macOS`, `Web`)**:
   - Upgrade `source/editor/build_export.d` (`ExportPipeline`) and `tools/player/player_main.d` to render full scenes and compile, statically link, and package standalone release builds for **Linux (`x86_64`, `arm64`)**, **Windows (`x86_64`)**, **macOS (`arm64`, `x86_64`, Universal `.app` bundle)**, and **Web (`wasm32-unknown-emscripten` + WebGPU + HTML5 shell)**.

---

## 2. Trade-Off Evaluation: `stb_image` + `stb_truetype` vs `SDL3_image` + `SDL3_ttf`

Replacing `stb` with `SDL3_image` and `SDL3_ttf` is a clean architectural win for a commercial-grade multiplatform engine, provided the SDF shader convention, lifecycle ownership, and static dependency bundling are handled explicitly.

### 2.1 `stb_image` vs `SDL3_image`

| Dimension | Current (`stb_image` + custom BMP/TGA) | Target (`SDL3_image`) | Verdict |
|---|---|---|---|
| **Supported Formats** | PNG, JPG, TGA, BMP, PSD, GIF, HDR (`stb_image`); glTF loader only accepts `.bmp` & `.tga` | PNG, JPG, WEBP, AVIF, QOI, SVG (rasterized at target size via `IMG_LoadSizedSVG_IO`), TGA, BMP, ICO/CUR, PNM, XPM, XCF, PCX, GIF/WEBP animations (`IMG_LoadAnimation_IO`) | `SDL3_image` strictly supersedes `stb_image` |
| **Underlying Codec Engine** | `stb_image.h` compiled in `vendor/stb/stb_impl.c` (`libs/libstb.a`) | `SDL3_image` 3.x internally uses `stb_image` as its default codec backend (`SDLIMAGE_BACKEND_STB=ON`) while wrapping everything in `SDL_Surface*` & `SDL_IOStream*` | Zero decoding regression + extra formats |
| **I/O Abstraction** | Raw `std.file.read` + `stbi_load_from_memory` | `SDL_IOStream` (`SDL_IOFromFile`, `SDL_IOFromConstMem`) works uniformly across disk, memory slices, Android `AAsset`, and Emscripten `MEMFS` | Better cross-platform I/O |
| **Image Writing / Cursors / Icons** | `stb_image` is read-only; PNG screenshot saving already moved to `SDL_SavePNG` (`source/engine/assets/png.d`) | Native `IMG_SavePNG`/`IMG_SaveJPG` + direct `SDL_Surface*` integration with `SDL_CreateColorCursor`, `SDL_SetWindowIcon`, `SDL_ScaleSurface`, `SDL_ConvertSurface` | Unifies surface pipeline |
| **Distro / Build Availability** | Single header vendored in `vendor/stb/` | `libSDL3_image.so` may not be preinstalled in all Linux repos (not installed on current dev host alongside `/usr/lib64/libSDL3_ttf.so.0.2.2`) | Mitigated via `tools/build_sdl3_deps.sh` + SDL 3.4 core PNG/BMP fallback in dev |

**Notes on `source/engine/assets/bmp.d` and `source/engine/graphics/texture.d`:**
- `Texture.fromImageBytes` / `Texture.fromImageFile` / `Texture.decodeImageBytes` migrate directly to `SDL3_image`.
- `source/engine/assets/gltf.d` (`loadImageTexture`, lines 324–339) currently rejects `.png` and `.jpg` with an error (`use .bmp or .tga`); switching it to `Texture.fromImageFile` immediately unlocks standard glTF PBR textures (`.png`, `.jpg`, `.webp`, `.qoi`, `.tga`, `.bmp`).
- `source/engine/assets/bmp.d` can delegate to `Texture.fromImageFile` / `SDL_LoadBMP_IO` or remain as a thin `@safe` compatibility wrapper over `engine.assets.image`.

### 2.2 `stb_truetype` vs `SDL3_ttf`

| Dimension | Current (`stb_truetype`) | Target (`SDL3_ttf` 3.2.x / FreeType 2) | Verdict |
|---|---|---|---|
| **Rasterization & Hinting** | Unhinted `stbtt_MakeCodepointBitmap`; small UI text (11–14 px) can look soft or uneven | FreeType 2 auto-hinter (`TTF_HINTING_NORMAL`, `TTF_HINTING_LIGHT`, `TTF_HINTING_LIGHT_SUBPIXEL`) + LCD subpixel option (`TTF_RenderText_LCD`) | Major readability upgrade in Editor & HUD |
| **SDF Rendering** | `stbtt_GetCodepointSDF` (`SDF_ONEDGE = 180`, `SDF_PADDING = 5`, `SDF_PIXEL_DIST_SCALE = 36.0`) | Native FreeType `bsdf` via `TTF_SetFontSDF(font, true)` (`TTF_IMAGE_SDF`, `onedge = 128`, default spread = `8`, `pixel_dist_scale = 16.0`) | Requires 1-line constant update in `ui2d.wgsl` |
| **Typography & Shaping** | Single codepoint lookup, no kerning applied in `Font.measure`/`UiBatchRenderer.drawText` | `TTF_GetGlyphKerning`, native `TTF_AddFallbackFont`, bold/italic/underline/strikethrough (`TTF_SetFontStyle`), stroke outlines (`TTF_SetFontOutline`), HarfBuzz shaping when built with HarfBuzz | Far richer typography |
| **Lifecycle & Memory** | Stateless `stbtt_fontinfo` pointing into D `ubyte[]` | Stateful C `TTF_Font*` via `TTF_OpenFontIO` + `TTF_Init`/`TTF_Quit`; backing `ubyte[]` in `FontSource` must remain alive until `TTF_CloseFont` | Requires explicit `Font.destroy()` / cleanup |
| **Dependency Footprint** | Zero external libs (`libstb.a` ~300 KB) | `libSDL3_ttf.so` links `libfreetype.so.6`, `libpng16`, `libz`, `libbz2`, `libbrotlidec` dynamically | Mitigated by static vendored FreeType build (`-DSDLTTF_VENDORED=ON`) for exports |

**Critical Technical Detail — FreeType SDF Math in `assets/shaders/ui2d.wgsl`:**
- Currently (`source/engine/ui/text/font.d:46-48` and `assets/shaders/ui2d.wgsl:70-71`), `stb_truetype` encodes SDF alpha with `onedge = 180` (`180/255 = 0.70588235`) and `pixel_dist_scale = 36.0` (`255/36 = 7.0833333`):
  ```wgsl
  let sdPx = (alphaMask - 0.70588235) * 7.0833333 * in.rectParams.x;
  ```
- FreeType's `bsdf` renderer used by `SDL3_ttf` (`TTF_SetFontSDF(font, true)`) encodes the glyph edge at `0.5` (`128 / 255 = 0.50196078`, or `128.0 / 255.0`) with a default spread of `8` pixels (`pixel_dist_scale = 128.0 / 8.0 = 16.0`, so `255.0 / 16.0 = 15.9375`, or calibrated directly against `SDL_ttf` glyph surface pixel inspection in unit tests).
- Updating `Font` and `assets/shaders/ui2d.wgsl` together keeps SDF sharp text and `outlineWidth` working seamlessly at all sizes (`14 px`, `24 px`, `48 px+`).

**Conclusion of Evaluation:** Total replacement of `stb_image` and `stb_truetype` with `SDL3_image` and `SDL3_ttf` is strongly recommended and eliminates `vendor/stb/` and `libs/libstb.a` completely, unifying all native media decoding, text rasterization, and static export packaging on SDL3.

---

## 3. Current State

Verified repository paths:

- [`source/bindings/sdl3.d`](../source/bindings/sdl3.d) — Manual `extern(C) nothrow @nogc` bindings for SDL 3.2/3.4. Currently defines `alias SDL_Surface = void;`, `SDL_CreateSurfaceFrom`, `SDL_DestroySurface`, `SDL_SavePNG`, `SDL_PIXELFORMAT_RGBA32`. Missing `SDL_Surface` struct layout, `SDL_Color`, `SDL_IOStream` (`SDL_IOFromFile`, `SDL_IOFromConstMem`, `SDL_CloseIO`), `SDL_ConvertSurface`, `SDL_LoadPNG_IO`, `SDL_LoadBMP_IO`, `SDL_LoadSurface_IO`, `SDL_SetWindowIcon`, and `SDL_LoadObject` / `SDL_LoadFunction` / `SDL_UnloadObject`.
- [`source/bindings/stb_image.d`](../source/bindings/stb_image.d), [`source/bindings/stb_truetype.d`](../source/bindings/stb_truetype.d), [`source/bindings/package.d`](../source/bindings/package.d), `vendor/stb/`, `libs/libstb.a` — Legacy `stb` bindings and static archive linked in [`dub.json`](../dub.json).
- [`source/engine/graphics/texture.d`](../source/engine/graphics/texture.d) — Uses `bindings.stb_image` in `Texture.decodeImageBytes`, `fromImageBytes`, and `fromImageFile`; also holds manual TGA decoder (`fromTgaFile`, `fromTgaBytes`).
- [`source/engine/assets/bmp.d`](../source/engine/assets/bmp.d), [`source/engine/assets/png.d`](../source/engine/assets/png.d), [`source/engine/assets/package.d`](../source/engine/assets/package.d) — Manual 24/32-bpp BMP decoder and SDL3 `SDL_SavePNG` screenshot saver.
- [`source/engine/assets/gltf.d`](../source/engine/assets/gltf.d) — `loadImageTexture` (lines 324–339) only accepts `.tga` and `.bmp` textures and rejects `.png` and `.jpg`.
- [`source/engine/ui/text/font.d`](../source/engine/ui/text/font.d) — `Font` uses `bindings.stb_truetype` for SDF + bitmap glyph rasterization into a dynamic `R8Unorm` shelf-packed atlas (`512×512` up to `2048×2048`).
- [`assets/shaders/ui2d.wgsl`](../assets/shaders/ui2d.wgsl) — Mode 1 text shader (lines 66–94) hardcoded to `stb_truetype` SDF constants.
- [`source/engine/platform/window.d`](../source/engine/platform/window.d) & [`source/engine/gpu/context.d`](../source/engine/gpu/context.d) — Multiplatform `NativeSurfaceBackend` (`wayland`, `x11`, `win32`, `android`, `metal`). No WebGPU HTML canvas backend yet.
- [`source/engine/app.d`](../source/engine/app.d) — `App` provides `pollEvents()`, `beginFrame()`, `endFrame()`; lacks a callback-driven `App.run()` abstraction for Emscripten's non-blocking main loop.
- [`source/engine/hotreload/`](../source/engine/hotreload/) — `watcher.d` uses Linux `core.sys.linux.sys.inotify` and `loader.d` uses POSIX `core.sys.posix.dlfcn` without `version(linux)` / `version(Posix)` platform guards, blocking cross-compilation to Windows and Web.
- [`source/editor/build_export.d`](../source/editor/build_export.d) — `ExportPipeline.exportGame` only builds `dub build --config=player` for `linux-x86_64` with dynamic `.so` copying and a `run.sh` launcher; not exposed in `EditorApp` menus yet.
- [`tools/player/player_main.d`](../tools/player/player_main.d) — Standalone player loads `.scene.json` and steps `PhysicsSimSession`, but its window loop currently clears the screen without rendering `SceneWorld` 3D meshes, lights, or UI.
- [`tools/build_symgc.sh`](../tools/build_symgc.sh) — Builds `libsymgc-cards.a` for `linux-x86_64`, `linux-arm64`, `windows-x86_64`, `macos-arm64`, and `android`.
- Host system libraries verified: `/usr/lib64/libSDL3.so.0.4.0` and `/usr/lib64/libSDL3_ttf.so.0.2.2` (with headers under `/usr/include/SDL3/` and `/usr/include/SDL3_ttf/`) are installed; `libSDL3_image` is not installed system-wide on this host.

---

## 4. Out of Scope

- **Mobile Export Targets (Android APK/AAB and iOS Xcode bundles):** Surface extraction already exists in `window.d` and `context.d`, but Gradle/NDK and Xcode packaging belong to a dedicated mobile export plan.
- **Console Platforms (PlayStation, Xbox, Nintendo Switch):** Excluded due to proprietary NDA toolchains.
- **Automated Hardware-Token Code Signing & App Store Notarization:** The exporter performs ad-hoc `codesign -s -` on macOS when available and emits clean `.exe` / `.app` bundles ready for external signing pipelines.

---

## 5. Dependencies

- **C/C++ Toolchains & Libraries:**
  - `SDL3` (3.2+ / 3.4+), `SDL3_image` (3.0+), `SDL3_ttf` (3.2+) + `FreeType 2` (vendored for static exports)
  - `wgpu-native` (`libwgpu_native.a` / `wgpu_native.lib` per native target; Emscripten WebGPU port for Web)
  - `Box3D` (`vendor/box3d` cross-compiled per target)
  - `steadygc` (`vendor/symgc` via `tools/build_symgc.sh` for 64-bit native targets)
- **D & Cross-Compilation Toolchains:**
  - `DMD` for rapid local Linux development
  - `LDC2` (`ldc2`) for `--build=release` and cross-target object/executable compilation (`-mtriple=...`)
  - `clang` / `lld` (or `zig cc` as cross-linker/sysroot for Windows MSVC and macOS Darwin targets when exporting from Linux)
  - `Emscripten SDK` (`emcc`) for `wasm32-unknown-emscripten` Web exports

---

## 6. Technical Design

### 6.1 `source/bindings/sdl3.d` Additions

Expand `bindings.sdl3` matching exact C99 headers (`/usr/include/SDL3/SDL_surface.h`, `SDL_iostream.h`, `SDL_loadso.h`, `SDL_pixels.h`):

- Replace opaque `alias SDL_Surface = void;` with the real C struct (`SDL_Surface` with `flags`, `format`, `w`, `h`, `pitch`, `pixels`, `refcount`, `reserved`) and `SDL_Color { ubyte r, g, b, a; }`.
- Expand `SDL_PixelFormat` enum (`SDL_PIXELFORMAT_UNKNOWN`, `SDL_PIXELFORMAT_INDEX8`, `SDL_PIXELFORMAT_RGB24`, `SDL_PIXELFORMAT_BGR24`, `SDL_PIXELFORMAT_ARGB8888`, `SDL_PIXELFORMAT_RGBA8888`, `SDL_PIXELFORMAT_ABGR8888`, `SDL_PIXELFORMAT_BGRA8888`).
- Add `SDL_IOStream` (`SDL_IOFromFile`, `SDL_IOFromMem`, `SDL_IOFromConstMem`, `SDL_CloseIO`).
- Add `SDL_CreateSurface`, `SDL_ConvertSurface`, `SDL_ConvertPixels`, `SDL_FlipSurface`, `SDL_ScaleSurface`, `SDL_LockSurface`, `SDL_UnlockSurface`, `SDL_LoadBMP`, `SDL_LoadBMP_IO`, `SDL_SaveBMP`, `SDL_SaveBMP_IO`, `SDL_LoadPNG`, `SDL_LoadPNG_IO`, `SDL_SavePNG_IO`, `SDL_LoadSurface`, `SDL_LoadSurface_IO`, `SDL_SetWindowIcon`.
- Add `SDL_SharedObject` (`SDL_LoadObject`, `SDL_LoadFunction`, `SDL_UnloadObject`).

### 6.2 `source/bindings/sdl3_image.d` & `source/bindings/sdl3_ttf.d`

- **Dual Linkage Strategy (`StaticSDLDeps` version flag):**
  - **`version (StaticSDLDeps)` (Release Exports & Static Builds):** Direct `extern(C) nothrow @nogc` function prototypes linked statically against `libSDL3_image.a` and `libSDL3_ttf.a` (+ `libfreetype.a` + `libSDL3.a`). Zero runtime symbol lookup overhead and zero external shared libraries.
  - **Default Engine Development Mode:** Dynamic loading via `SDL_LoadObject` (`libSDL3_image.so.0` / `libSDL3_image.so` / `SDL3_image.dll` / `libSDL3_image.dylib` and `libSDL3_ttf.so.0` / ...) with clean helper checks (`imgIsAvailable()`, `ttfIsAvailable()`). For `SDL3_image`, if `libSDL3_image` is not present on a developer host, `bindings.sdl3_image` transparently falls back to SDL 3.4's built-in `SDL_LoadSurface_IO` / `SDL_LoadPNG_IO` / `SDL_LoadBMP_IO` for PNG and BMP so tests never fail before running `tools/build_sdl3_deps.sh`.
- **Bound API Surface:**
  - `bindings.sdl3_image`: `IMG_Version`, `IMG_Load`, `IMG_Load_IO`, `IMG_LoadTyped_IO`, `IMG_LoadPNG_IO`, `IMG_LoadJPG_IO`, `IMG_LoadWEBP_IO`, `IMG_LoadQOI_IO`, `IMG_LoadTGA_IO`, `IMG_LoadBMP_IO`, `IMG_LoadSVG_IO`, `IMG_LoadSizedSVG_IO`, `IMG_isPNG`..`IMG_isSVG`, `IMG_SavePNG`, `IMG_SavePNG_IO`, `IMG_SaveJPG`, `IMG_SaveJPG_IO`, `IMG_Animation`, `IMG_LoadAnimation`, `IMG_LoadAnimation_IO`, `IMG_FreeAnimation`.
  - `bindings.sdl3_ttf`: `TTF_Version`, `TTF_Init`, `TTF_Quit`, `TTF_WasInit`, `TTF_OpenFont`, `TTF_OpenFontIO`, `TTF_OpenFontWithProperties`, `TTF_CopyFont`, `TTF_CloseFont`, `TTF_AddFallbackFont`, `TTF_RemoveFallbackFont`, `TTF_ClearFallbackFonts`, `TTF_SetFontSize`, `TTF_SetFontSizeDPI`, `TTF_GetFontSize`, `TTF_SetFontStyle`, `TTF_GetFontStyle`, `TTF_SetFontOutline`, `TTF_GetFontOutline`, `TTF_SetFontHinting`, `TTF_GetFontHinting`, `TTF_SetFontSDF`, `TTF_GetFontSDF`, `TTF_SetFontKerning`, `TTF_GetFontKerning`, `TTF_GetFontHeight`, `TTF_GetFontAscent`, `TTF_GetFontDescent`, `TTF_GetFontLineSkip`, `TTF_SetFontLineSkip`, `TTF_FontHasGlyph`, `TTF_GetGlyphMetrics`, `TTF_GetGlyphKerning`, `TTF_GetGlyphImage`, `TTF_GetStringSize`, `TTF_GetStringSizeWrapped`, `TTF_MeasureString`, `TTF_RenderGlyph_Solid`, `TTF_RenderGlyph_Shaded`, `TTF_RenderGlyph_Blended`, `TTF_RenderGlyph_LCD`, `TTF_RenderText_Solid`, `TTF_RenderText_Blended`, `TTF_RenderText_Blended_Wrapped`, `TTF_RenderText_LCD`.

### 6.3 Image Pipeline (`engine.assets.image`, `Texture`, `gltf.d`)

- Create [`source/engine/assets/image.d`](../source/engine/assets/image.d):
  - `decodeImageBytes(const(ubyte)[] bytes, out ubyte[] outRgba, out uint outWidth, out uint outHeight, const(char)* typeHint = null)` via `SDL_IOFromConstMem` → `IMG_LoadTyped_IO` (or `IMG_Load_IO`) → `SDL_ConvertSurface(..., SDL_PIXELFORMAT_RGBA32)` → row copy respecting `surf.pitch` → `SDL_DestroySurface`.
  - `decodeImageFile(scope const(char)[] path, ...)`
  - `decodeSvgBytesSized(const(ubyte)[] svgBytes, uint width, uint height, out ubyte[] outRgba)` via `IMG_LoadSizedSVG_IO`.
  - `saveRgbaJpg(...)` alongside existing `saveRgbaPng(...)` in `engine.assets.png`.
- Update `Texture` (`source/engine/graphics/texture.d`) with `fromSurface`, `fromSvgBytes`, and `SDL3_image`-backed `decodeImageBytes` / `fromImageBytes` / `fromImageFile`.
- Update `source/engine/assets/gltf.d` (`loadImageTexture`) to route all extensions (`.png`, `.jpg`, `.jpeg`, `.webp`, `.qoi`, `.tga`, `.bmp`) through `Texture.fromImageFile(gpu, path)`.
- Update `Window.setIcon(const(ubyte)[] rgba, uint w, uint h)` / `Window.setIconFromFile(path)` using `SDL_SetWindowIcon`.
- Delete `source/bindings/stb_image.d` and remove `stb_image` references from `source/bindings/package.d`.

### 6.4 Font Pipeline (`engine.ui.text.font`, `ui2d.wgsl`)

- Refactor `Font` in [`source/engine/ui/text/font.d`](../source/engine/ui/text/font.d) to back every `FontSource` with a `TTF_Font*`:
  - Preserve existing API (`loadFromMemory`, `addFallbackFont`, `getGlyph`, `measure`, `lineHeight`, `sdfScaleForSize`, `pixels`, `atlasW`, `atlasH`, `atlasVersion`, `isDirty`, `clearDirty`) and add `loadFromFile`, `setHinting`, `getKerning`, and deterministic `destroy()` + `~this()` cleanup (`TTF_CloseFont`).
  - Keep `ubyte[] fontBytes` alive inside `FontSource` while `TTF_Font*` is open (required by `TTF_OpenFontIO` over `SDL_IOFromConstMem`).
  - Support both **FreeType SDF** (`TTF_SetFontSDF(font, true)` baked once at `SDF_BASE_HEIGHT = 48.0f`, scaling cleanly to any height in `ui2d.wgsl`) and **FreeType Hinted Bitmap** (`useSdf = false`, `TTF_HINTING_LIGHT` / `TTF_HINTING_NORMAL`) for ultra-crisp small UI text.
  - Rasterize glyphs via `TTF_RenderGlyph_Blended` (or `TTF_GetGlyphImage`), convert/read `ARGB8888`/`RGBA32` alpha channel into the `R8Unorm` `atlasPixels` shelf rectangle (`gx, gy, gw, gh`), and record FreeType `minx, maxy, advance` offsets relative to the baseline.
  - Wire `TTF_AddFallbackFont(sources[0].handle, sources[i].handle)` so Unicode symbols and fallback glyphs resolve natively inside `SDL3_ttf`.
  - Apply `TTF_GetGlyphKerning` in `Font.measure`, `shaping.truncateWithEllipsis`, and `UiBatchRenderer.drawText`.
- Update [`assets/shaders/ui2d.wgsl`](../assets/shaders/ui2d.wgsl) Mode 1 SDF math from `stb_truetype`'s `(alphaMask - 0.70588235) * 7.0833333` to FreeType's SDF encoding (`onedge = 128/255`, `spread = 8 px` → `(alphaMask - 0.50196078) * 15.9375 * in.rectParams.x`).
- Delete `source/bindings/stb_truetype.d`, `vendor/stb/`, and `libs/libstb.a`, and remove `"stb"` from `"libs"` in [`dub.json`](../dub.json).

### 6.5 Static Dependency Build & Multiplatform Release Export (`Linux`, `Windows`, `macOS`, `Web`)

#### 6.5.1 Unified Static Dependency Directory Layout (`libs/<target>/`)

Create `tools/build_sdl3_deps.sh` (mirroring `tools/build_symgc.sh`) to fetch/build static archives into `libs/<target>/`:

| Target Directory | Compiler Triple | Libraries Staged |
|---|---|---|
| `libs/linux-x86_64/` | `x86_64-unknown-linux-gnu` | `libSDL3.a`, `libSDL3_image.a`, `libSDL3_ttf.a`, `libfreetype.a`, `libwgpu_native.a`, `libbox3d.a`, `libsymgc-cards.a` (plus `.so` dev copies) |
| `libs/linux-arm64/` | `aarch64-unknown-linux-gnu` | Same static `.a` set for Linux ARM64 |
| `libs/windows-x86_64/` | `x86_64-pc-windows-msvc` | `SDL3-static.lib`, `SDL3_image-static.lib`, `SDL3_ttf-static.lib`, `freetype.lib`, `wgpu_native.lib`, `box3d.lib`, `symgc-cards.lib` |
| `libs/macos-arm64/` | `arm64-apple-macos12.0` | `libSDL3.a`, `libSDL3_image.a`, `libSDL3_ttf.a`, `libfreetype.a`, `libwgpu_native.a`, `libbox3d.a`, `libsymgc-cards.a` |
| `libs/macos-x86_64/` | `x86_64-apple-macos11.0` | Same static `.a` set for Intel macOS (supports `lipo` Universal) |
| `libs/web-wasm32/` | `wasm32-unknown-emscripten` | `libSDL3.a`, `libSDL3_image.a`, `libSDL3_ttf.a`, `libfreetype.a`, `libbox3d.a` (WebGPU comes from Emscripten WebGPU port) |

Build flags used for static `SDL3_image` and `SDL3_ttf`:
- `SDL3`: `-DSDL_STATIC=ON -DSDL_SHARED=OFF` (on Linux, SDL3 loads Wayland/X11/PipeWire/Pulse/ALSA via `dlopen` at runtime, so static `libSDL3.a` introduces zero non-`glibc` `.so` dependencies).
- `SDL3_image`: `-DBUILD_SHARED_LIBS=OFF -DSDLIMAGE_BACKEND_STB=ON -DSDLIMAGE_SVG=ON -DSDLIMAGE_QOI=ON -DSDLIMAGE_AVIF=OFF -DSDLIMAGE_WEBP=OFF -DSDLIMAGE_JXL=OFF -DSDLIMAGE_TIF=OFF` (keeps binary small and free of external `libpng`/`libjpeg`/`libtiff` dynamic deps while supporting PNG, JPG, TGA, BMP, QOI, SVG, GIF).
- `SDL3_ttf`: `-DBUILD_SHARED_LIBS=OFF -DSDLTTF_VENDORED=ON -DSDLTTF_HARFBUZZ=OFF` (builds static `libSDL3_ttf.a` + vendored `libfreetype.a` with zero external FreeType/HarfBuzz/Brotli/BZ2 `.so`/`.dll` dependencies; HarfBuzz can be enabled optionally via `--with-harfbuzz`).

#### 6.5.2 Per-Platform Export Specifications (`source/editor/build_export.d`)

Define `enum ExportTarget { linuxX86_64, linuxArm64, windowsX86_64, macosArm64, macosX86_64, macosUniversal, webWasm32 }` and `ExportPipeline.checkToolchain(ExportTarget target)`:

1. **Linux (`linux-x86_64`, `linux-arm64`)**:
   - Compile with `ldc2 --build=release -mtriple=... --d-version=StaticSDLDeps` (plus `--d-version=Symgc_cards` when card-barrier LDC is enabled).
   - Link statically against `libs/<target>/lib{SDL3_image,SDL3_ttf,freetype,SDL3,wgpu_native,box3d,symgc-cards}.a` (`-Wl,-Bstatic ... -Wl,-Bdynamic -lm -ldl -lpthread -lrt`).
   - Package `<game-name>`, `assets/`, `run.sh`, `<game-name>.desktop` into `<outputDir>/<game-name>-linux-<arch>.tar.gz`.
   - Verify with `ldd` that the binary has zero dependencies on `libSDL3*.so`, `libfreetype.so`, `libwgpu*.so`, `libbox3d.so`, or `libstb.so`.

2. **Windows (`windows-x86_64`)**:
   - Compile with `ldc2 --build=release -mtriple=x86_64-pc-windows-msvc --d-version=StaticSDLDeps` (invoking `lld-link` / `zig cc` or MSVC toolchain).
   - Link statically against `SDL3_image-static.lib`, `SDL3_ttf-static.lib`, `freetype.lib`, `SDL3-static.lib`, `wgpu_native.lib`, `box3d.lib`, `symgc-cards.lib` plus standard Windows system import libs (`user32.lib`, `gdi32.lib`, `winmm.lib`, `imm32.lib`, `ole32.lib`, `oleaut32.lib`, `version.lib`, `uuid.lib`, `advapi32.lib`, `setupapi.lib`, `shell32.lib`, `d3d12.lib`, `dxgi.lib`, `d3dcompiler.lib`, `bcrypt.lib`, `ws2_32.lib`, `userenv.lib`, `ntdll.lib`, `propsys.lib`) with `/SUBSYSTEM:WINDOWS /ENTRY:mainCRTStartup`.
   - Package `<game-name>.exe` + `assets/` into `<outputDir>/<game-name>-windows-x86_64.zip` (zero third-party `.dll` files required).

3. **macOS (`macos-arm64`, `macos-x86_64`, `macos-universal`)**:
   - Compile with `ldc2 --build=release -mtriple=arm64-apple-macos12.0` (and/or `x86_64-apple-macos11.0`) + `--d-version=StaticSDLDeps`, optionally merging slices via `lipo -create`.
   - Link statically against `lib{SDL3_image,SDL3_ttf,freetype,SDL3,wgpu_native,box3d,symgc-cards}.a` and Apple system frameworks (`Metal`, `QuartzCore`, `Cocoa`, `IOKit`, `CoreVideo`, `CoreAudio`, `AudioToolbox`, `GameController`, `ForceFeedback`, `Carbon`, `UniformTypeIdentifiers`, `-liconv`, `-lc++`).
   - Emit standard `<GameName>.app` bundle (`Contents/Info.plist`, `Contents/MacOS/<game-name>`, `Contents/Resources/assets/`, optional `.icns` icon), run ad-hoc `codesign --force --deep -s -` when available, and archive to `<game-name>-macos-<arch>.zip`.

4. **Web (`web-wasm32` — Emscripten + WebGPU)**:
   - **Engine Adaptations Required for WebAssembly**:
     - `source/bindings/wgpu.d`: Add `WGPUSType.surfaceSourceCanvasHTMLSelector` and `WGPUSurfaceSourceCanvasHTMLSelector`.
     - `source/engine/platform/window.d` & `source/engine/gpu/context.d`: Add `NativeSurfaceBackend.webCanvas` under `version (WebAssembly)` / `version (Emscripten)` targeting CSS selector `"#canvas"`, and handle async adapter/device promises with `emscripten_sleep(0)` (`-sASYNCIFY=1`).
     - `source/engine/app.d`: Add `App.run(scope void delegate(float dt) frameFn)` — runs `while (running())` on desktop and delegates to `emscripten_set_main_loop_arg` on WebAssembly so the browser tab never freezes.
     - `source/engine/hotreload/`: Guard Linux `inotify` (`watcher.d`) and POSIX `dlopen` (`loader.d`) under `version (linux)` / `version (Posix)` so Windows and Web builds compile cleanly using CTFE-embedded `.wgsl` shaders.
     - `source/engine/core/gc.d`: Under `version (WebAssembly)`, short-circuit `steadygc` externs so Web builds gracefully use the stock Tier-1 GC without 64-bit pointer-window assumptions.
   - **Web Build & Packaging**:
     - Compile D modules to objects via `ldc2 -mtriple=wasm32-unknown-emscripten -O3 -release --d-version=Emscripten --d-version=StaticSDLDeps -c`.
     - Link with `emcc` against `libs/web-wasm32/lib{SDL3_image,SDL3_ttf,freetype,SDL3,box3d}.a`, `-sUSE_WEBGPU=1` (or `--use-port=emdawnwebgpu`), `-sASYNCIFY=1`, `-sALLOW_MEMORY_GROWTH=1`, `--preload-file assets@/assets`, and a clean responsive WebGPU HTML5 shell (`tools/web/shell.html`).
     - Output `index.html`, `<game-name>.js`, `<game-name>.wasm`, `<game-name>.data`, and `<game-name>-web.zip`.

#### 6.5.3 Standalone Player Rendering & Editor/CLI Export Access

- Upgrade [`tools/player/player_main.d`](../tools/player/player_main.d) to render the loaded `SceneWorld` (`Scene3DTextured` / `Scene3D`, directional/point/spot lights, shadows, post-processing, and `App.run(...)`) instead of just clearing the frame buffer, while preserving `--headless-frames=600 --assert-no-gc` at 0 bytes of GC allocation.
- Add a standalone CLI export configuration in `dub.json` (`dub run --config=export -- --target=linux-x86_64 --release`) and wire `Export Release...` targets into [`source/editor/editor_app.d`](../source/editor/editor_app.d) (`PopupKind.arquivo`).

---

## 7. Phases

### Phase 1 (`SDL-DEPS`) — Static & Dynamic SDL3 / SDL3_image / SDL3_ttf Dependency Builder

- [x] Add `tools/build_sdl3_deps.sh` to build static (`libSDL3.a`, `libSDL3_image.a`, `libSDL3_ttf.a` + `libfreetype.a`) and Linux dev shared libraries into `libs/<target>/`
- [x] Add cross-compilation support in `tools/build_sdl3_deps.sh` (and `vendor/box3d` helper target) for `linux-x86_64`, `linux-arm64`, `windows-x86_64`, `macos-arm64`, `macos-x86_64`, and `web-wasm32`
- [x] Verify host build produces static archives in `libs/linux-x86_64/` and stages `libwgpu_native.a` / `libsymgc-cards.a`

**DoD:** `tools/build_sdl3_deps.sh` builds and stages static `SDL3`, `SDL3_image`, `SDL3_ttf`, and `freetype` archives into `libs/linux-x86_64/` and accepts cross-target triples for Windows, macOS, and Web.

### Phase 2 (`SDL-IMG`) — `SDL3_image` Bindings, Unified Image Pipeline & `stb_image` Removal

- [x] Expand `source/bindings/sdl3.d` with full `SDL_Surface`, `SDL_Color`, `SDL_IOStream`, `SDL_SharedObject`, `SDL_ConvertSurface`, `SDL_LoadPNG_IO`, `SDL_LoadBMP_IO`, `SDL_LoadSurface_IO`, and `SDL_SetWindowIcon`
- [x] Create `source/bindings/sdl3_image.d` with `version (StaticSDLDeps)` static bindings and `SDL_LoadObject` dynamic bindings (+ SDL 3.4 PNG/BMP fallback)
- [x] Create `source/engine/assets/image.d` (`decodeImageBytes`, `decodeImageFile`, `decodeSvgBytesSized`, `saveRgbaJpg`) and update `Texture` (`source/engine/graphics/texture.d`) + `Window.setIcon` (`source/engine/platform/window.d`)
- [x] Update `source/engine/assets/gltf.d` (`loadImageTexture`) to load `.png`, `.jpg`, `.webp`, `.qoi`, `.tga`, and `.bmp` via `Texture.fromImageFile`
- [x] Remove `source/bindings/stb_image.d` and its re-export in `source/bindings/package.d`

**DoD:** `Texture.fromImageFile`/`fromImageBytes`, `Texture.fromSvgBytes`, and `gltf.d` decode PNG/JPG/WEBP/QOI/SVG/TGA/BMP via `SDL3_image`, `stb_image.d` is removed, and all asset/texture unit tests pass.

### Phase 3 (`SDL-TTF`) — `SDL3_ttf` Bindings, FreeType SDF/Hinted Font Atlas & `stb_truetype` Removal

- [x] Create `source/bindings/sdl3_ttf.d` (`TTF_Init`, `TTF_OpenFontIO`, `TTF_SetFontSDF`, `TTF_SetFontHinting`, `TTF_AddFallbackFont`, `TTF_GetGlyphMetrics`, `TTF_GetGlyphKerning`, `TTF_RenderGlyph_Blended`, `TTF_RenderText_Blended_Wrapped`, `TTF_CloseFont`, `TTF_Quit`) with `StaticSDLDeps` and dynamic `SDL_LoadObject` modes
- [x] Refactor `Font` (`source/engine/ui/text/font.d`), `measure.d`, `shaping.d`, and `UiBatchRenderer.drawText` (`source/engine/ui/render/batch.d`) to use `SDL3_ttf`, FreeType SDF + hinted bitmap rasterization, fallback fonts, and kerning
- [x] Update `assets/shaders/ui2d.wgsl` Mode 1 SDF constants to match FreeType `TTF_SetFontSDF` encoding
- [x] Delete `source/bindings/stb_truetype.d`, `vendor/stb/`, `libs/libstb.a`, and remove `"stb"` from `dub.json`; update `docs/third-party-licenses.md`

**DoD:** `SDL3_ttf` powers all SDF and bitmap font rendering with kerning and Unicode fallback, `vendor/stb/` and `libstb.a` are completely removed, and all unit tests + UI/Editor visual smoke tests pass with 0 bytes frame-loop GC allocation.

### Phase 4 (`PLAYER-RENDER`) — Standalone Player Rendering, Platform Guards & `App.run`

- [x] Add `App.run(scope void delegate(float dt) frameFn)` in `source/engine/app.d` (native loop on desktop, `emscripten_set_main_loop_arg` on WebAssembly)
- [x] Guard Linux-only `inotify`/`dlopen` modules in `source/engine/hotreload/` with `version (linux)` / `version (Posix)` and add `version (WebAssembly)` fallback in `source/engine/core/gc.d` so engine library compiles cleanly across Linux, Windows, macOS, and Web
- [x] Upgrade `tools/player/player_main.d` to render the loaded `SceneWorld` (`Scene3D`, entity visuals/materials, scene camera, post-processing) inside `App.run`

**DoD:** `tools/player/player_main.d` renders a full `.scene.json` interactively via `App.run` and passes `--headless-frames=600 --assert-no-gc` with 0 bytes allocated.

### Phase 5 (`EXPORT-NATIVE`) — Static Multiplatform Release Exporter (Linux, Windows, macOS)

- [x] Extend `source/editor/build_export.d` (`ExportTarget`, `BuildExportOptions`, `ExportPipeline.checkToolchain`, `ExportPipeline.exportGame`) with `StaticSDLDeps` + `ldc2 --build=release` static linking for `linux-x86_64`, `linux-arm64`, `windows-x86_64`, `macos-arm64`, `macos-x86_64`, and `macos-universal`
- [x] Add platform bundle generators: Linux ELF + `run.sh` + `.desktop` + `.tar.gz`, Windows single `.exe` + `.zip`, macOS `.app` (`Info.plist`, `MacOS/`, `Resources/assets/`, optional `lipo` + ad-hoc `codesign`) + `.zip`
- [x] Add unit tests validating toolchain preflight diagnostics, static link command generation per target, and Linux static bundle creation

**DoD:** Exporting a release for Linux produces a standalone binary with zero non-`glibc` dynamic library dependencies (verified via `ldd`), and Windows/macOS cross-export bundles compile and package cleanly when target sysroots/libs are present in `libs/<target>/`.

### Phase 6 (`EXPORT-WEB`) — WebAssembly (Emscripten + WebGPU) Target & Editor/CLI Export Integration

- [ ] Add `WGPUSurfaceSourceCanvasHTMLSelector` (`source/bindings/wgpu.d`), `NativeSurfaceBackend.webCanvas` (`source/engine/platform/window.d`, `source/engine/gpu/context.d`), and async adapter/device `emscripten_sleep(0)` polling
- [ ] Add `tools/web/shell.html` and `ExportTarget.webWasm32` in `source/editor/build_export.d` compiling D objects via `ldc2 -mtriple=wasm32-unknown-emscripten` and linking via `emcc` with WebGPU + `SDL3` + `SDL3_image` + `SDL3_ttf` + `--preload-file assets@/assets`
- [ ] Add CLI export tool (`dub run --config=export`) and wire `Export Release...` menu actions into `source/editor/editor_app.d`

**DoD:** `ExportTarget.webWasm32` generates a runnable `<game>.html` + `.js` + `.wasm` + `.data` bundle served cleanly via local HTTP, and both CLI and Editor export menus support Linux, Windows, macOS, and Web targets.

---

## 8. Acceptance Criteria

1. **Zero `stb` Leftovers:** `vendor/stb/`, `libs/libstb.a`, `source/bindings/stb_image.d`, and `source/bindings/stb_truetype.d` are completely removed from the repository and `dub.json`.
2. **Unified Media & Text Stack:** `dub test --config=library` passes all unit tests using `SDL3_image` (PNG, JPG, WEBP, QOI, SVG, TGA, BMP) and `SDL3_ttf` (FreeType SDF + hinted bitmap, kerning, fallback fonts); `glTF` models with `.png`/`.jpg` textures load cleanly.
3. **Engine Hygiene:** `dub run --config=lint` introduces zero new violations; `dub run --config=editor -- --headless-frames=600 --assert-no-gc` and `dub run --config=player -- --headless-frames=600 --assert-no-gc` report **0 bytes** of GC allocations in the frame loop.
4. **Static Release Portability:** Exported Linux release binary shows no runtime dependency on `libSDL3.so`, `libSDL3_image.so`, `libSDL3_ttf.so`, `libfreetype.so`, `libwgpu_native.so`, or `libbox3d.so` under `ldd`, and runs cleanly without `LD_LIBRARY_PATH`.
5. **4-Platform Export Coverage:** `ExportPipeline` cleanly handles `Linux`, `Windows`, `macOS`, and `Web`, producing platform-native release archives (`.tar.gz`, `.zip`, `.app`, and HTML5/WASM/WebGPU bundle) with clear preflight diagnostics if a cross-toolchain SDK is missing on the host.

---

## 9. Cross References

- [`docs/multiplatform-and-shaders.md`](multiplatform-and-shaders.md) — Native surface creation (`Wayland`, `X11`, `Win32`, `Android`, `Metal`) and CTFE WGSL shader embedding
- [`docs/symgc-multiplatform-integration.md`](symgc-multiplatform-integration.md) — `steadygc` (`symgc`) cross-platform card-marking build matrix and `tools/build_symgc.sh`
- [`docs/roadmap.md`](roadmap.md) — Prioritized engine backlog
- [`docs/game-development-guide.md`](game-development-guide.md) — Texture, font, asset, and external DUB dependency usage
- [`docs/editor-guide.md`](editor-guide.md) — Editor panels and export workflow
