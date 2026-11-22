# Multiplatform Release Export & Media Formats Guide

This guide documents the standalone multiplatform release exporter (`ExportPipeline` in [source/editor/build_export.d](../source/editor/build_export.d), CLI in [tools/export_main.d](../tools/export_main.d)), every supported `--target=<value>` export format, toolchain requirements, and the `SDL3_image` / `SDL3_ttf` media formats supported across development and release builds.

---

## 1. Two-Mode Linkage Model (`dev` vs `StaticSDLDeps`)

The engine separates fast local iteration from self-contained release builds:

| Mode | Trigger | `SDL3` | `SDL3_image` & `SDL3_ttf` | Typical Use Case |
|:---|:---|:---|:---|:---|
| **Engine Development** | Default (`dub run --config=editor`, `player`, `library`) | Shared (`-lSDL3` host library) | Lazy runtime load via `SDL_LoadObject` (`libSDL3_image.so.0`, `libSDL3_ttf.so.0`, fallback to SDL 3.4 PNG/BMP) | Fast incremental `dmd` debug compiles and editor iteration |
| **Static Release Export** | `-version=StaticSDLDeps` (`--config=player-static` or `ExportPipeline`) | Static (`libSDL3.a` / `SDL3-static.lib`) | Direct `extern(C) nothrow @nogc` linked statically with vendored `FreeType 2`, `wgpu_native`, and `Box3D` | Portable game distributions without bundling `.so` / `.dll` / `.dylib` media runtimes |

Static archives for each target live under `libs/<target>/` and are built via [tools/build_sdl3_deps.sh](../tools/build_sdl3_deps.sh):

```bash
./tools/build_sdl3_deps.sh <target>
# Supported targets: linux-x86_64 | linux-arm64 | windows-x86_64 | macos-arm64 | macos-x86_64 | web-wasm32
```

---

## 2. Master Export Target Matrix

`ExportPipeline` and `tools/export_main.d` accept 7 export targets via `--target=<value>`:

| Primary `--target` Value | Accepted CLI Aliases (`parseExportTarget`) | `ExportTarget` Enum | Editor Menu (`Arquivo`) | LLVM Triple (`ldc2 -mtriple`) | Static Libs Dir | Archive Format |
|:---|:---|:---|:---|:---|:---|:---|
| `linux-x86_64` | `linux`, `linux-x86_64`, `linux_x86_64` | `ExportTarget.linuxX86_64` | Exportar Release (Linux) | `x86_64-unknown-linux-gnu` | `libs/linux-x86_64/` | `.tar.gz` |
| `linux-arm64` | `linux-arm64`, `linux-aarch64` | `ExportTarget.linuxArm64` | — (CLI / API) | `aarch64-unknown-linux-gnu` | `libs/linux-arm64/` | `.tar.gz` |
| `windows-x86_64` | `windows`, `win64`, `windows-x86_64` | `ExportTarget.windowsX86_64` | Exportar Release (Windows) | `x86_64-pc-windows-msvc` | `libs/windows-x86_64/` | `.zip` |
| `macos-arm64` | `macos-arm64`, `darwin-arm64` | `ExportTarget.macosArm64` | — (CLI / API) | `arm64-apple-macos12.0` | `libs/macos-arm64/` | `.zip` (`.app`) |
| `macos-x86_64` | `macos-x86_64`, `darwin-x86_64` | `ExportTarget.macosX86_64` | — (CLI / API) | `x86_64-apple-macos11.0` | `libs/macos-x86_64/` | `.zip` (`.app`) |
| `macos-universal` | `macos`, `darwin`, `macos-universal` | `ExportTarget.macosUniversal` | Exportar Release (macOS) | `arm64-apple-macos12.0` + `x86_64-apple-macos11.0` | `libs/macos-arm64/` + `libs/macos-x86_64/` | `.zip` (`.app`) |
| `web-wasm32` | `web`, `wasm`, `wasm32`, `web-wasm32` | `ExportTarget.webWasm32` | Exportar Release (Web) | `wasm32-unknown-emscripten` | `libs/web-wasm32/` | `.zip` |

---

## 3. CLI Flags & `BuildExportOptions` Reference

### 3.1 CLI Usage (`dub run --config=export`)

```bash
dub run --config=export -- --list-targets
dub run --config=export -- --check-toolchains
dub run --config=export -- --target=<id> [options]
```

| CLI Flag | Default | Description |
|:---|:---|:---|
| `--target=<id>` | `linux-x86_64` | Target platform ID or alias (see table above) |
| `--output=<dir>` | `build/<target>` | Output bundle directory |
| `--scene=<path>` | `assets/scenes/arena_01.scene.json` | Startup `.scene.json` passed to the launcher |
| `--name=<bin>` | `game-player` | Executable / HTML stem name inside the bundle |
| `--title=<title>` | `Game Engine Player` | Window, `.desktop`, macOS `Info.plist`, and Web `<title>` display name |
| `--compiler=<bin>` | `ldc2` | D compiler binary (`ldc2` recommended for release/cross builds; `dmd` for host Linux dev) |
| `--release` | `false` | Enables release optimizations (`--build=release` / `-O3`) |
| `--archive` | `false` | Packages the exported bundle into `<output>.tar.gz` (Linux) or `<output>.zip` (Windows/macOS/Web) |
| `--symgc` | `false` | Enables `steadygc` (`Symgc_cards`, `Symgc_druntime_hooks`) and requires `libsymgc-cards.a` / `symgc-cards.lib` |
| `--list-targets` | — | Lists every supported `--target=<id>` and LLVM triple |
| `--check-toolchains` | — | Verifies compiler, linker, and `libs/<target>/` static archives on the current host |

### 3.2 `BuildExportOptions` Fields (`source/editor/build_export.d`)

| Field | Type | Default | Description |
|:---|:---|:---|:---|
| `target` | `ExportTarget` | `ExportTarget.linuxX86_64` | Typed export target enum |
| `targetPlatform` | `string` | `"linux-x86_64"` | String identifier (fallback parser if `target` is left default) |
| `outputDir` | `string` | `"build/linux-x86_64"` | Destination bundle directory |
| `startScene` | `string` | `"assets/scenes/arena_01.scene.json"` | Initial scene path loaded by launchers |
| `includedScenes` | `string[]` | `[]` | Optional explicit scene list |
| `binaryName` | `string` | `"game-player"` | Binary or `.html` filename stem |
| `appTitle` | `string` | `"Game Engine Player"` | Human-readable application title |
| `appId` | `string` | `"com.gameengine.player"` | Reverse-DNS identifier (`CFBundleIdentifier` on macOS) |
| `appVersion` | `string` | `"1.0.0"` | Bundle version (`CFBundleVersion` / `CFBundleShortVersionString`) |
| `iconPath` | `string` | `""` | Optional icon path reserved for bundle metadata |
| `compiler` | `string` | `"ldc2"` | Compiler executable (`ldc2` or `dmd`) |
| `release` | `bool` | `false` | Build in release mode |
| `packageArchive` | `bool` | `false` | Emit `.tar.gz` or `.zip` after bundle assembly |
| `useStaticDeps` | `bool` | `true` | Link against `-version=StaticSDLDeps` static archives |
| `enableSymGc` / `useCardBarrier` | `bool` | `false` | Opt into `steadygc` card-marking write barriers |

---

## 4. Per-Target Export Format Details

### 4.1 `linux-x86_64` (`ExportTarget.linuxX86_64`)

- **Value:** `--target=linux-x86_64` (aliases: `linux`, `linux_x86_64`)
- **LLVM Triple:** `x86_64-unknown-linux-gnu`
- **Build Dependencies:** `./tools/build_sdl3_deps.sh linux-x86_64`
- **Preflight Tools:** Compiler `ldc2` (or `dmd`), linker `clang` / `gcc` / `cc`
- **Required Static Archives (`libs/linux-x86_64/`):**
  - `libSDL3_ttf.a`, `libSDL3_image.a`, `libfreetype.a`, `libSDL3.a`, `libwgpu_native.a`, `libbox3d.a` (plus `libsymgc-cards.a` when `--symgc` is enabled)
- **System Libraries / Flags:** `-lm`, `-ldl`, `-lpthread`, `-lrt`, `--as-needed` (SDL3 still loads Wayland/X11/Audio system libraries at runtime via `dlopen`)
- **Compile Command (`useStaticDeps=true`):**
  ```bash
  dub build --config=player-static --compiler=ldc2 --build=release
  ```
- **Export Command & Output Structure:**
  ```bash
  dub run --config=export -- --target=linux-x86_64 --release --archive
  ```
  ```text
  build/linux-x86_64/
  ├── assets/                     # Game assets copied from assets/
  ├── project.json                # Copied when present at project root
  ├── game-player                 # Statically linked ELF binary (--name overrides stem)
  ├── game-player.desktop         # Freedesktop desktop entry
  ├── run.sh                      # chmod +x launcher (sets SDL_VIDEODRIVER=wayland,x11)
  └── THIRD-PARTY-LICENSES.txt    # Required SDL3 zlib + FreeType FTL attribution
  build/linux-x86_64.tar.gz       # Created when --archive is passed
  ```
- **Verification:** Run `ldd build/linux-x86_64/game-player` to confirm zero runtime dependencies on `libSDL3*`, `libSDL3_image*`, `libSDL3_ttf*`, `libfreetype*`, `libwgpu*`, or `libbox3d*`. *(Note: if host `ldc2` packages only shared `libphobos2-ldc-shared.so` / `libdruntime-ldc-shared.so`, such as Fedora RPM LDC, those D standard library `.so` files are linked dynamically while all C/engine libraries remain static; hosts with static Phobos/LDC archives link Phobos statically as well.)*

---

### 4.2 `linux-arm64` (`ExportTarget.linuxArm64`)

- **Value:** `--target=linux-arm64` (alias: `linux-aarch64`)
- **LLVM Triple:** `aarch64-unknown-linux-gnu`
- **Build Dependencies:** `./tools/build_sdl3_deps.sh linux-arm64`
- **Preflight Tools:** Compiler `ldc2`, cross-linker `aarch64-linux-gnu-gcc` / `zig` / `clang`
- **Required Static Archives (`libs/linux-arm64/`):**
  - `libSDL3_ttf.a`, `libSDL3_image.a`, `libfreetype.a`, `libSDL3.a`, `libwgpu_native.a`, `libbox3d.a` (plus `libsymgc-cards.a` with `--symgc`)
- **System Libraries:** `-lm`, `-ldl`, `-lpthread`, `-lrt`
- **Generated `ldc2` Command Pattern:**
  ```bash
  ldc2 -mtriple=aarch64-unknown-linux-gnu -O3 -release -preview=dip1000 \
    -I=source -I=source/bindings/box3d -J=assets/shaders -d-version=StaticSDLDeps \
    tools/player/player_main.d ... -of=build/linux-arm64/game-player
  ```
- **Output Structure:** Same bundle layout as `linux-x86_64/` (`assets/`, `game-player`, `run.sh`, `game-player.desktop`, `THIRD-PARTY-LICENSES.txt`) plus `build/linux-arm64.tar.gz` when `--archive` is set.

---

### 4.3 `windows-x86_64` (`ExportTarget.windowsX86_64`)

- **Value:** `--target=windows-x86_64` (aliases: `windows`, `win64`)
- **LLVM Triple:** `x86_64-pc-windows-msvc`
- **Build Dependencies:** `./tools/build_sdl3_deps.sh windows-x86_64`
- **Preflight Tools:** Compiler `ldc2`, linker `lld-link` / `x86_64-w64-mingw32-gcc` / `zig`
- **Required Static Archives (`libs/windows-x86_64/`):**
  - `SDL3_ttf-static.lib`, `SDL3_image-static.lib`, `freetype.lib`, `SDL3-static.lib`, `wgpu_native.lib`, `box3d.lib`, `recast_shim.lib`, `stb_vorbis.lib` (plus `symgc-cards.lib` built via `./tools/build_symgc.sh ldc2 windows-x86_64` when `--symgc` is enabled)
- **System Libraries / Flags:** `user32.lib`, `gdi32.lib`, `winmm.lib`, `imm32.lib`, `ole32.lib`, `oleaut32.lib`, `version.lib`, `uuid.lib`, `advapi32.lib`, `setupapi.lib`, `shell32.lib`, `d3d12.lib`, `dxgi.lib`, `dxguid.lib`, `synchronization.lib`, `/SUBSYSTEM:WINDOWS` (plus `-i`, C import files `box3d_import.c` / `stb_vorbis_import.c` / `recast_import.c`, and `/EXPORT:__sd_gc_card_lo` / `__sd_gc_card_n` / `__sd_gc_card_base` when `--symgc` is enabled)
- **Output Structure:**
  ```text
  build/windows-x86_64/
  ├── assets/
  ├── project.json
  ├── game-player.exe             # Standalone Windows PE executable
  └── THIRD-PARTY-LICENSES.txt
  build/windows-x86_64.zip        # Created when --archive is passed
  ```

---

### 4.4 `macos-arm64` (`ExportTarget.macosArm64`)

- **Value:** `--target=macos-arm64` (alias: `darwin-arm64`)
- **LLVM Triple:** `arm64-apple-macos12.0`
- **Build Dependencies:** `./tools/build_sdl3_deps.sh macos-arm64`
- **Preflight Tools:** Compiler `ldc2`, linker `clang` (on macOS) or `ld64.lld` / `zig` / `oa64-clang` (cross)
- **Required Static Archives (`libs/macos-arm64/`):**
  - `libSDL3_ttf.a`, `libSDL3_image.a`, `libfreetype.a`, `libSDL3.a`, `libwgpu_native.a`, `libbox3d.a` (plus `libsymgc-cards.a` with `--symgc`)
- **Apple Frameworks & Link Flags:** `-framework Metal`, `-framework QuartzCore`, `-framework Cocoa`, `-framework IOKit`, `-framework CoreVideo`, `-framework CoreAudio`, `-framework AudioToolbox`, `-framework GameController`, `-framework ForceFeedback`, `-framework Carbon`, `-framework UniformTypeIdentifiers`, `-liconv`, `-lc++`, `-ObjC`
- **Output Structure:** `.app` bundle + optional `.zip` (see `macos-universal` layout below, without `lipo`).

---

### 4.5 `macos-x86_64` (`ExportTarget.macosX86_64`)

- **Value:** `--target=macos-x86_64` (alias: `darwin-x86_64`)
- **LLVM Triple:** `x86_64-apple-macos11.0`
- **Build Dependencies:** `./tools/build_sdl3_deps.sh macos-x86_64`
- **Preflight Tools:** Compiler `ldc2`, linker `clang` (on macOS) or `ld64.lld` / `zig` / `o64-clang` (cross)
- **Required Static Archives (`libs/macos-x86_64/`):**
  - `libSDL3_ttf.a`, `libSDL3_image.a`, `libfreetype.a`, `libSDL3.a`, `libwgpu_native.a`, `libbox3d.a` (plus `libsymgc-cards.a` with `--symgc`)
- **Apple Frameworks & Link Flags:** Identical to `macos-arm64`.

---

### 4.6 `macos-universal` (`ExportTarget.macosUniversal`)

- **Value:** `--target=macos-universal` (aliases: `macos`, `darwin`)
- **LLVM Triples:** `arm64-apple-macos12.0` + `x86_64-apple-macos11.0`
- **Build Dependencies:** Both `./tools/build_sdl3_deps.sh macos-arm64` and `./tools/build_sdl3_deps.sh macos-x86_64`
- **Preflight Tools:** `ldc2`, `lipo` (`llvm-lipo` when cross-bundling), optional `codesign` for ad-hoc signing (`codesign --force --deep -s -`)
- **Bundle Structure:**
  ```text
  build/macos-universal/
  └── Game-Engine-Player.app/     # Sanitized from --title
      └── Contents/
          ├── Info.plist          # CFBundleIdentifier, CFBundleExecutable, NSHighResolutionCapable=true
          ├── MacOS/
          │   └── game-player     # Universal Mach-O fat binary created via `lipo -create`
          └── Resources/
              ├── assets/
              ├── project.json
              └── THIRD-PARTY-LICENSES.txt
  build/macos-universal.zip       # Created when --archive is passed
  ```

---

### 4.7 `web-wasm32` (`ExportTarget.webWasm32`)

- **Value:** `--target=web-wasm32` (aliases: `web`, `wasm`, `wasm32`)
- **LLVM Triple:** `wasm32-unknown-emscripten`
- **Build Dependencies:** `./tools/build_sdl3_deps.sh web-wasm32` (requires `emcmake` / Emscripten SDK activated in `PATH`)
- **Preflight Tools:** `ldc2`, `emcc`
- **Required Static Archives (`libs/web-wasm32/`):**
  - `libSDL3_ttf.a`, `libSDL3_image.a`, `libfreetype.a`, `libSDL3.a`, `libbox3d.a` *(WebGPU comes from Emscripten `-sUSE_WEBGPU=1`; `SteadyGC` is automatically stubbed under `version (WebAssembly)`)*
- **Two-Stage Build Commands (`ExportPipeline.buildWebExportCommands`):**
  ```bash
  # Stage 1: Compile D player/engine to Emscripten object file
  ldc2 -c -mtriple=wasm32-unknown-emscripten -O3 -release -preview=dip1000 \
    -I=source -I=source/bindings/box3d -J=assets/shaders \
    -d-version=WebAssembly -d-version=StaticSDLDeps \
    -od=build/web-wasm32/obj tools/player/player_main.d

  # Stage 2: Link WebGPU + SDL3 + virtual asset filesystem via emcc
  emcc build/web-wasm32/obj/player_main.o \
    libs/web-wasm32/libSDL3_ttf.a libs/web-wasm32/libSDL3_image.a \
    libs/web-wasm32/libfreetype.a libs/web-wasm32/libSDL3.a libs/web-wasm32/libbox3d.a \
    -sUSE_WEBGPU=1 -sASYNCIFY=1 -sALLOW_MEMORY_GROWTH=1 -sINITIAL_MEMORY=67108864 \
    --shell-file build/web-wasm32/shell.generated.html \
    --preload-file assets@/assets \
    -o build/web-wasm32/game-player.html
  ```
- **HTML Shell Template (`tools/web/shell.html`):** Dark studio viewport canvas (`id="canvas"`), `navigator.gpu` capability warning banner, asset download progress bar, fullscreen toggle, and `{{APP_TITLE}}` / `{{{ SCRIPT }}}` substitution into `shell.generated.html`.
- **Output Structure & Local Serving:**
  ```text
  build/web-wasm32/
  ├── game-player.html            # Entry HTML page (stem from --name)
  ├── game-player.js              # Emscripten glue JS
  ├── game-player.wasm            # WebAssembly module
  ├── game-player.data            # Preloaded assets/ VFS payload
  └── THIRD-PARTY-LICENSES.txt
  build/web-wasm32.zip            # Created when --archive is passed
  ```
  Serve over HTTP (required by browser WebGPU / WASM `fetch`):
  ```bash
  python3 -m http.server 8080 --directory build/web-wasm32
  ```

---

## 5. Supported Image & Font Formats (`SDL3_image` & `SDL3_ttf`)

### 5.1 Image Formats (`bindings.sdl3_image`, `engine.assets.image`, `Texture`, `gltf.d`)

| Format | Decode Entry Points | Encode Entry Point | Static Build (`build_sdl3_deps.sh`) | Dev Shared Lib (`libSDL3_image.so`) |
|:---|:---|:---|:---|:---|
| **PNG** | `decodeImageFile`, `decodeImageBytes`, `Texture.fromImageFile`, `gltf.d` | `saveRgbaPng` (`engine.assets.png`), `IMG_SavePNG` | Enabled (`-DSDLIMAGE_BACKEND_STB=ON` + SDL3 PNG fallback) | Enabled |
| **JPG / JPEG** | `decodeImageFile`, `decodeImageBytes`, `Texture.fromImageFile`, `gltf.d` | `saveRgbaJpg` (`engine.assets.image`), `IMG_SaveJPG` | Enabled | Enabled |
| **SVG** | `decodeSvgBytesSized` (`IMG_LoadSizedSVG_IO`), `Texture.fromSvgBytes`, `decodeImageFile` | — | Enabled (`-DSDLIMAGE_SVG=ON`) | Enabled |
| **QOI** | `decodeImageFile`, `decodeImageBytes`, `Texture.fromImageFile`, `gltf.d` | — | Enabled (`-DSDLIMAGE_QOI=ON`) | Enabled |
| **BMP** | `decodeImageFile`, `decodeImageBytes`, `Texture.fromImageFile`, `engine.assets.bmp`, `gltf.d` | `SDL_SaveBMP` | Enabled (plus SDL3 core fallback) | Enabled |
| **TGA** | `decodeImageFile`, `decodeImageBytes`, `Texture.fromImageFile`, `gltf.d` | — | Enabled | Enabled |
| **GIF** | `decodeImageFile`, `IMG_LoadAnimation_IO`, `gltf.d` | — | Enabled | Enabled |
| **WEBP** | `decodeImageFile`, `decodeImageBytes`, `Texture.fromImageFile`, `gltf.d` | — | Disabled by default in static script (`-DSDLIMAGE_WEBP=OFF`) | Host-dependent (enabled on Fedora system `libSDL3_image.so.0`) |
| **AVIF** | `decodeImageFile`, `decodeImageBytes`, `Texture.fromImageFile`, `gltf.d` | `IMG_SaveAVIF` | Disabled by default in static script (`-DSDLIMAGE_AVIF=OFF`) | Host-dependent |

### 5.2 Font Rasterization Modes & Hinting (`engine.ui.text.font`, `bindings.sdl3_ttf`)

| Mode / Option | API | Shader Constants (`assets/shaders/ui2d.wgsl`) | Best For |
|:---|:---|:---|:---|
| **FreeType SDF (Default)** | `font.loadFromFile(path, pxHeight, useSdf = true)` / `font.loadFromMemory(...)` | `SDF_BASE_HEIGHT = 48.0f`, `SDF_PADDING = 8`, `onedge = 128/255 (0.50196078)`, `pixel_dist_scale = 16/255` (`slope = 15.9375`) | Arbitrary zoom/UI scaling from a single atlas (`sdfScaleForSize`) |
| **Hinted Bitmap** | `font.loadFromFile(path, pxHeight, useSdf = false)` | Bitmap mask path (`in.rectParams.x == 0`) | Pixel-aligned small HUD / inspector labels |
| **Hinting Flags** | `font.setHinting(TTF_HintingFlags.<flag>)` | `normal (0)`, `light (1)`, `mono (2)`, `none (3)`, `lightSubpixel (4)` | Fine-tuning glyph sharpness (`light`/`normal` recommended) |
| **Kerning & Fallbacks** | `font.getKerning(prevCp, cp, pxHeight)`, `font.addFallbackFont(bytes)` | Applied automatically in `Font.measure`, `shaping.truncateWithEllipsis`, `UiBatchRenderer.drawText` | Proper spacing (`VA`, `To`) and multi-font Unicode glyph coverage |

---

## 6. External Game Project Static Export & Protected Asset Packs (`engine.assets.pak`)

### 6.1 Encrypted / Obfuscated Asset Containers (`GEPK` v1)

Games built on `game-engine` can pack their asset directory into a single encrypted binary container (`GEPK` v1) using `engine.assets.pak` and the standalone `game-engine-pak` CLI:

```bash
dub build --config=pak --compiler=dmd
./game-engine-pak --input=/path/to/game/Assets --output=build/assets.pak --key=0x454F544F56455354 --verify
```

- **Path Hashing (`FNV-1a 64-bit`):** Normalized forward-slash relative paths are hashed; no plaintext filenames or directory names are written to the `.pak` table of contents.
- **Stream Encryption (`SplitMix64` XOR):** Both the TOC (`tocSeed` + 64-bit integrity verification tag) and every asset payload (`key ^ pathHash ^ (offset * 0x9E3779B97F4A7C15)`) are stream-encrypted, stripping raw `.glb` (`glTF`), `.png`, and `.ttf` file headers.
- **Transparent VFS Loading:** Call `mountAssetPak(cast(immutable(ubyte)[]) import("assets.pak"), key, false)` (or `mountAssetPakFile(...)`) once at startup. Engine loaders (`Font.loadFromFile`, `Texture.fromImageFile`, `parseGltfMesh`, `parseGltfMaterial`, `loadImageTexture`) and `readAssetBytes` / `assetExists` automatically decrypt assets in memory without reading loose files from disk.

### 6.2 Exporting External Games (`--project`) with Embedded Assets & ELF Verification

`ExportPipeline` (`game-engine-export`) can compile external D game repositories directly against the engine sources and static archives, pack and verify their assets, embed `assets.pak` inside the binary (`-J` + `-version=ProtectedAssets`), and validate the resulting Linux ELF binary:

```bash
dub run --config=export --compiler=dmd -- \
  --target=linux-x86_64 \
  --project=/path/to/my-game \
  --engine=/path/to/game-engine \
  --source=source \
  --assets=Assets \
  --protect-assets \
  --embed-pak \
  --pak-key=0x454F544F56455354 \
  --name=my-game \
  --title="My Game" \
  --output=/path/to/dist/my-game
```

- **Streamed World Chunks in the Pak:** every `.gesc` / `.scene.json` chunk under `--assets` is packed with the rest of the assets, and `--pak-dir=<dir>` (repeatable, relative to `--project`) packs extra directories such as a chunk folder outside `Assets`, keyed `<dir>/<relative path>`. The export verifies each chunk is present in the pak and logs the count. At runtime `WorldStreamer` reads chunk bytes through the mounted pak (`readMountedAssetNoGc`, a `@nogc` malloc-based variant of `readAssetBytes` safe on the GC-excluded worker thread) and falls back to disk when no pak is mounted or when the pak was mounted with `allowDiskFallback`. Manifest `scenePath` / `navmeshPath` values must match the pak keys (for example `Assets/world/chunk_0_0.gesc`). Do not unmount the pak while streaming. See [world-pipeline-guide.md](world-pipeline-guide.md).
- **Compiler Auto-Selection & Static Phobos:** `ExportPipeline.hasLdcStaticPhobos()` checks for `libphobos2-ldc.a`. On Linux hosts where system `ldc2` only ships shared Phobos (`libphobos2-ldc-shared.so`), `--compiler=dmd` (or omitting `--compiler`) links `/usr/lib64/libphobos2.a` statically (`-defaultlib=libphobos2.a`) and excludes `hotreload/loader.d` + `hotreload/reload.d` so `rt_loadLibrary` is never referenced.
- **Post-Build Verification (`verifyStaticBinary` & `verifyPakObfuscation`):** Unless `--no-verify` is passed, `ExportPipeline` inspects `readelf -d` (rejecting any `RPATH`/`RUNPATH` or non-base `DT_NEEDED` libraries outside `libc.so.6`, `libm.so.6`, `libgcc_s.so.1`, `ld-linux-x86-64.so.2`, `libpthread.so.0`, `libdl.so.2`, `librt.so.1`), verifies `ldd` has zero unresolved or engine/D shared libraries, and ensures plaintext asset names/headers do not leak into the `.pak`.

### 6.3 Known Limitations (`GEPK` v1 Memory & Key Model)

- **Full-Archive Memory Footprint:** `mountAssetPakFile` currently reads the entire `.pak` file into RAM via `std.file.read`, and `--embed-pak` (`import("assets.pak")`) embeds the container in the executable's `.rodata` section (OS demand-paged, though large paks slow down compilation and inflate binary size). This is ideal for compact projects (under ~100 MB); for larger games or streamed levels (>100–250 MB), update `mountAssetPakFile` in `source/engine/assets/pak.d` to keep an open `File` handle and `seek` + `rawRead(size)` per entry using the `offset`/`size` fields already stored in the `GEPK` v1 TOC.
- **Client-Side Obfuscation Key:** For offline builds, the 64-bit decryption key lives in the game binary. `GEPK` v1 prevents casual asset browsing and automated file-carver extraction (`strings`, `binwalk`, `foremost`), not dedicated reverse engineering of the executable.

---

## 7. Third-Party License Attribution

Every bundle produced by `ExportPipeline` copies/writes `THIRD-PARTY-LICENSES.txt` alongside the executable ([docs/third-party-licenses.md](third-party-licenses.md)), preserving MIT notices (engine & `meshoptimizer`), the zlib notice (`SDL3`, `SDL3_image`, `SDL3_ttf`), and the **FreeType License (FTL)** attribution required by FreeType 2.
