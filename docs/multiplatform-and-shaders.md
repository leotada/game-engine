# Multiplatform Architecture and Modular Shader System

This document details the multiplatform WGPU/SDL3 surface creation architecture and the modular WGSL shader pipeline with preprocessor directives and transactional hot-reload.

---

## 1. Multiplatform Support and Swapchain Negotiation

The engine is engineered for high-performance execution across Linux (Wayland as the primary development target with transparent fallback to X11 in the standalone executable), Windows, Android, macOS, and iOS.

### 1.1 Native Surface Abstraction Layer (`NativeSurfaceInfo`)

In `source/engine/platform/window.d`, the `NativeSurfaceInfo` struct encapsulates platform window properties from SDL3 as a POD, GC-safe data structure:

```d
struct NativeSurfaceInfo {
    NativePlatform platform;
    void* display; // wl_display (Wayland) or Display* (X11)
    void* surface; // wl_surface (Wayland) or uint Window (X11 cast)
    void* window;  // HWND (Win32), ANativeWindow* (Android), or CALayer* (Metal)
    void* instance;// HINSTANCE (Win32)
}
```

When calling `window.nativeSurface()`, the engine detects the active platform via SDL3 window properties (`SDL_GetPointerProperty` / `SDL_GetNumberProperty`):

1. **Linux Wayland (Default for development)**:
   - Extracts `SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER` and `SDL_PROP_WINDOW_WAYLAND_SURFACE_POINTER`.
   - Configures `WGPUSurfaceSourceWaylandSurface`.

2. **Linux X11 (Automatic fallback for the standalone game executable)**:
   - If Wayland is unavailable or driver initialization fails, SDL3 automatically falls back to X11 (`x11`).
   - Extracts `SDL_PROP_WINDOW_XLIB_DISPLAY_POINTER` and `SDL_PROP_WINDOW_XLIB_WINDOW_NUMBER`.
   - Configures `WGPUSurfaceSourceXlibWindow`.
   - In the exported distribution script (`run.sh` in `source/editor/build_export.d`), we enforce `export SDL_VIDEODRIVER="${SDL_VIDEODRIVER:-wayland,x11}"`, ensuring immediate compatibility with legacy X11 desktops and headless Xvfb servers without manual user configuration.

3. **Windows (DirectX 12 / Vulkan)**:
   - Extracts `SDL_PROP_WINDOW_WIN32_HWND_POINTER` and `SDL_PROP_WINDOW_WIN32_HINSTANCE_POINTER`.
   - Configures `WGPUSurfaceSourceWindowsHWND`.

4. **Android (Vulkan)**:
   - Extracts `SDL_PROP_WINDOW_ANDROID_WINDOW_POINTER`.
   - Configures `WGPUSurfaceSourceAndroidNativeWindow`.

5. **macOS / iOS (Metal)**:
   - Creates a Metal view via `SDL_Metal_CreateView` and obtains the `CAMetalLayer` pointer via `SDL_Metal_GetLayer`.
   - Configures `WGPUSurfaceSourceMetalLayer`.

### 1.2 Dynamic Swapchain Negotiation

Rather than assuming rigid pixel formats that break on mobile GPUs or specific driver stacks, `GpuContext.create` in `source/engine/gpu/context.d` queries `wgpuSurfaceGetCapabilities`:

```d
WGPUSurfaceCapabilities caps;
wgpuSurfaceGetCapabilities(surface, adapter, &caps);
```

- **Texture Format**: Prefers `bgra8Unorm` or `rgba8Unorm` based on surface and adapter capabilities.
- **Present Mode**: Prefers `mailbox` (low latency, tearing-free) when supported, gracefully falling back to `fifo` (standard V-Sync mandatory under the WebGPU specification).

---

## 2. Modular WGSL Shader System and Preprocessor

Shaders previously existed as monolithic string literals in D source code (`shaders.d`). The modular system introduces distinct `.wgsl` files in `assets/shaders/` with an embedded preprocessor.

### 2.1 Directory Structure

```
assets/shaders/
├── common/
│   ├── fullscreen_vs.wgsl    # Fullscreen triangle vertex shader (post-processing)
│   ├── pbr_brdf.wgsl         # PBR BRDF functions: Cook-Torrance, GGX, Fresnel Schlick
│   └── shadows.wgsl          # Directional, point, and spot PCF shadow filtering
├── colored3d.wgsl            # 3D instanced pipeline with per-vertex/instance colors
├── textured3d_pbr.wgsl       # 3D instanced textured pipeline with full PBR
├── shadow_depth.wgsl         # Shadow depth pass
├── gizmo_line.wgsl           # 3D debug lines and grid
├── ui2d.wgsl                 # Vector / UI box renderer
├── text2d.wgsl               # Bitmap font text renderer
├── cube3d.wgsl               # Simple cube demonstration pipeline
├── post_bloom_threshold.wgsl # HDR brightness extraction with soft knee
├── post_bloom_down_karis.wgsl# Karis average downsampling (anti-firefly)
├── post_bloom_down.wgsl      # 13-tap box bilinear downsampling
├── post_bloom_up.wgsl        # 9-tap tent filter upsampling
├── post_tonemap.wgsl         # ACES / Reinhard tone mapping + exposure
├── post_fxaa.wgsl            # Fast LDR edge anti-aliasing
└── post_blit.wgsl            # Direct swapchain blit
```

### 2.2 Preprocessor Directives (`engine.hotreload.shader_source`)

The preprocessor supports:

1. **`#include "path/to/file.wgsl"`**:
   - Recursive inclusion with path normalization.
   - Strict protection against circular inclusion.
   - Automatic deduplication: shared headers (`common/pbr_brdf.wgsl`, `common/shadows.wgsl`) are emitted only once per translation unit.

2. **`#define SYMBOL` and `#undef SYMBOL`**:
   - Macro definition and undefinition for conditional compilation.

3. **`#ifdef SYMBOL` / `#ifndef SYMBOL` / `#else` / `#endif`**:
   - Nested conditional evaluation to arbitrary depth.
   - Enables material feature flags (e.g. optional emission, roughness, or shadow maps) inside a unified shader file.

### 2.3 Hybrid Compilation: CTFE + Runtime

For optimal performance and zero-dependency distribution:
1. **At Compile Time (CTFE)**: During `dub build`, shaders in `assets/shaders/` are embedded directly into the binary via `stringImportPaths: ["assets/shaders"]` and evaluated at compile time. The final game binary runs completely standalone without requiring shader files on disk.
2. **At Runtime (Hot-Reload)**: During development and inside the visual editor, the module dynamically reads files from disk when modifications occur.

---

## 3. Transactional, Safe Shader Hot-Reload

### 3.1 Architecture

`ShaderHotReloader` (`source/engine/hotreload/shader_reload.d`) monitors filesystem modifications using `FileWatcher` (Linux inotify):

```
File .wgsl modified on disk (assets/shaders/)
      │
      ▼
Inotify event detected (debounced 200ms)
      │
      ▼
loadAndPreprocessShader(file)
      │
      ├─► Syntax / Include Error? ──► Log error via err(), retain active pipeline (Zero Crash)
      │
      ▼
Compile WGPUShaderModule
      │
      ├─► GPU driver rejected WGSL? ──► Release new module, retain active pipeline
      │
      ▼
Transactional creation of new WGPURenderPipeline
      │
      ▼
Release old pipeline and atomically swap pointers
```

### 3.2 Zero-Interruption Guarantee

Shader hot-reloading never leaves the scene in an invalid or half-initialized state:
- If a shader contains a WGSL syntax or typing error, rendering continues smoothly using the existing valid pipeline.
- When the correction is saved in the external editor, the reloader recompiles and swaps the pipeline instantly.
- If a header in `common/` (such as `pbr_brdf.wgsl` or `shadows.wgsl`) is edited, all dependent pipelines are recompiled and hot-swapped in cascade.

### 3.3 Editor Integration

`EditorApp` initializes the hot-reloader in interactive mode:

```d
if (!headless) {
    shaderReloader.init("assets/shaders");
}
```

And polls it on every update frame:

```d
if (!isHeadless) {
    shaderReloader.pollAndReload(&scene, null, &gizmos, &uiRenderer, &app.renderer, dt);
}
```

### 3.4 GC Compliance and Performance

- All frame loop call paths strictly adhere to `@nogc`.
- In headless benchmark mode (`--headless-frames=600 --assert-no-gc`), GC allocations remain strictly **0 bytes**, verified in continuous integration benchmarks for both the editor and standalone player.
