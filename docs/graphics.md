# Graphics Architecture

The engine uses **WGPU-native** as its GPU abstraction and **SDL3** for windowing/input, running natively on Linux Wayland (with transparent X11 fallback), Windows, Android, and macOS/iOS.

## 3-Layer Model (Godot-Inspired)

```
┌──────────────────────────────────────────────────────┐
│  Scene Layer — Gameplay API (engine/scene/*)         │
│  ├── Scene3D          → batched instanced (colored)  │
│  ├── Scene3DTextured  → batched instanced (textures) │
│  ├── SceneGraph       → Transform hierarchy          │
│  ├── Camera           → perspective projection       │
│  └── Controllers      → Orbit / Fly / FirstPerson    │
├──────────────────────────────────────────────────────┤
│  Graphics Layer — Graphic assets (engine/graphics/*) │
│  ├── Mesh       → vertex/index (pos+normal)          │
│  ├── TexMesh    → vertex/index (pos+normal+uv)       │
│  ├── Texture    → GPU texture + TGA loader           │
│  ├── Material   → PBR bind group (params + maps)     │
│  ├── Color4     → RGBA float                         │
│  └── primitives → cube, pyramid, diamond, quad, etc. │
├──────────────────────────────────────────────────────┤
│  GPU Layer — Low-level WGPU wrappers (engine/gpu/*)  │
│  ├── App/Renderer → beginFrame / resolvePost / end   │
│  ├── PostProcessor → bloom + ACES + FXAA             │
│  ├── Pipeline3D   → colored + textured PBR instanced │
│  ├── PipelineText → alpha-blended bitmap text        │
│  ├── ShadowMap    → depth32Float + depth-only pass   │
│  ├── IblEnvironment → cubemap + irradiance + LUT    │
│  ├── TextRenderer → bitmap font atlas (8×8 CP437)   │
│  ├── Buffers      → vertex, index, uniform, dynamic  │
│  ├── Shaders      → modular WGSL sources + preprocessor│
│  └── GpuContext   → Instance→Adapter→Device→Queue   │
├──────────────────────────────────────────────────────┤
│  Assets + DevTools                                   │
│  ├── assets/bmp.d   → 24/32-bpp BMP → Texture        │
│  ├── assets/gltf.d  → glTF mesh + PBR materials     │
│  ├── devtools/gizmos.d  → 3D line overlay primitives │
│  └── devtools/overlay.d → FPS + structured HUD       │
├──────────────────────────────────────────────────────┤
│  Bindings (bindings/wgpu.d + sdl3.d + box3d/)        │
│  └── extern(C) nothrow @nogc — direct C99 ABI        │
├──────────────────────────────────────────────────────┤
│  libwgpu_native.a          │  libSDL3.so             │
│  (Vulkan/Metal/DX12)       │  (Wayland/X11 + audio)  │
└──────────────────────────────────────────────────────┘
```

### When to Use Each Layer

| Goal | Target API |
|:---|:---|
| Draw colored 3D meshes | `Scene3D` + `Mesh` + `Camera` |
| Draw textured 3D meshes | `Scene3DTextured` + `TexMesh` + `Material` |
| Transform hierarchy (solar systems, joints, attachments) | `SceneGraph` |
| Orbital / Fly / First-person camera control | `engine.scene.controllers` |
| Directional shadows | `ShadowMap` + textured pipeline |
| Load BMP / glTF from disk | `engine.assets.bmp`, `engine.assets.gltf` |
| Play WAV sound effects | `engine.audio.engine` |
| Debug HUD / bitmap text | `TextRenderer` |
| Debug lines, grids, axes | `engine.devtools.gizmos` |
| Debug FPS + structured labels | `engine.devtools.overlay` |
| Custom procedural shapes | `Mesh.fromData` + `Vert` |
| Custom pipeline / shader | `engine.gpu.pipeline`, `engine.gpu.shader` |
| Direct GPU buffer control | `engine.gpu.buffer` |
| Raw WGPU API calls | `bindings.wgpu` |

## WGPU-native

GPU backend based on the WebGPU specification, implemented in Rust by the [wgpu-native](https://github.com/gfx-rs/wgpu-native) project. Advantages over bgfx or direct OpenGL:

- **Vulkan, Metal, and DX12** via a unified, modern interface.
- **Strict validation** in debug builds — clear errors instead of silent GL state corruption.
- **Declarative API** — explicit descriptors for pipelines, buffers, and textures.
- **Native compute shader support** (for future GPU simulation systems).

### Integration

We maintain **manual `extern(C)` bindings** rather than third-party bindbc packages for three reasons:

1. Full control over included functions and structs.
2. No external dub package dependencies that could fall out of sync with webgpu.h.
3. Zero wrapper overhead — direct calls into the C ABI.

Bindings are located in `source/bindings/wgpu.d`, based directly on official `webgpu.h` headers.

### GPU Lifecycle & Multiplatform Surfaces

```
wgpuCreateInstance()
  └─→ wgpuInstanceCreateSurface()     ← NativeSurfaceInfo (Wayland / fallback X11, Win32, Android, Metal)
  └─→ wgpuInstanceRequestAdapter()    ← compatible with surface, high-performance
        └─→ wgpuAdapterRequestDevice()
              └─→ wgpuDeviceGetQueue()
              └─→ wgpuSurfaceGetCapabilities() ← dynamic format (BGRA8/RGBA8) and present mode (mailbox/fifo)
              └─→ wgpuSurfaceConfigure()       ← safe, negotiated configuration
```

For detailed multiplatform architecture, see [multiplatform-and-shaders.md](multiplatform-and-shaders.md).

### Frame Loop

```
1. beginFrame → offscreen HDR render pass (rgba16float + depth24Plus)
2.   Scene3D / Scene3DTextured / gizmos draw into HDR target
3. resolvePost → end HDR pass
4.   bloom pass (threshold / downsample / upsample) when enabled
5.   tone map ACES (+ exposure) → LDR
6.   FXAA pass when enabled → swapchain
7.   reopen present pass (load-op) for text/UI overlay
8. endFrame → submit command buffer + wgpuSurfacePresent()
```

The optional shadow depth pass runs as a separate submit **before** `beginFrame`.

## Render Pipelines

### Pipeline3D

Pipeline for colored 3D geometry with instanced rendering:

- **Vertex buffer 0** — geometry: `float32x3 position + float32x3 normal` (stride=24)
- **Vertex buffer 1** — instances: `4×float32x4` model matrix columns (stride=64, step=instance)
- **Depth** — depth24Plus, depthWriteEnabled, depthCompare=less
- **Primitive** — triangleList, CCW front face, back-face culling
- **Shader** — WGSL with VP × model transformation and directional N·L lighting

### PipelineText

Pipeline for bitmap text (FPS overlay, debug text):

- **Vertex buffer** — `float32x2 position + float32x2 texcoord` (stride=16)
- **Blend** — srcAlpha / oneMinusSrcAlpha (alpha blending)
- **Depth** — depth24Plus, depthWrite=false, depthCompare=always (overlay)
- **Font atlas** — 128×48 R8Unorm texture, 8×8 CP437 glyphs (ASCII 32-127)
- **Shader** — WGSL with screen size uniform, sampler + texture binding

### Pipeline3D Textured (PBR)

Variant of Pipeline3D with metallic-roughness PBR, PCF shadows, and IBL:

- **Vertex buffer 0** — geometry: `float32x3 position + float32x3 normal + float32x2 uv` (stride=32)
- **Vertex buffer 1** — instances: 4×`float32x4` model + tint `float32x4` (stride=80)
- **Bind groups:**
  - `@group(0) Frame` — `FrameUniforms` (viewProj, lightViewProj, lightDir, shadowBias, cameraPos), comparison sampler, `texture_depth_2d`
  - `@group(1) Material` — `MaterialParams` UBO, filtering sampler, albedo + optional MR/normal/occlusion/emissive maps (bound with 1×1 defaults when omitted)
  - `@group(2) IBL` — irradiance cubemap, prefiltered specular (mips), BRDF LUT, sampler
- **Fragment** — Cook-Torrance GGX + IBL (HDR output); tone mapping in `resolvePost`
- **Usage** — `Scene3DTextured.setLighting` / `setEnvironment`; `Material.create(gpu, scene.materialLayout, sampler, albedo)`
- **Color target** — `Renderer.sceneFormat()` = `rgba16float` (offscreen, not swapchain)

### ShadowMap (Depth-Only Pipeline)

Depth map for directional shadows:

- **Target** — 2D texture `depth32Float` (default 2048×2048)
- **Pipeline** — dedicated depth-only pipeline with no fragment stage
- **Light VP** — `directionalLightVP()` computes an orthographic + lookAt `Mat4` from light direction and scene bounding sphere
- **Workflow** — (1) `submitShadowPass` / depth render into shadow map, (2) `Scene3DTextured.setLighting(lightDir, lightVP, shadow)` before color pass, (3) PCF 3×3 sampling in textured fragment shader

## Benchmark

The 3D benchmark demonstrates the instanced pipeline with 1,000 spinning cubes:

- **1,000 cubes** arranged in a 10×10×10 grid, spacing 1.5
- **Instanced rendering** — one draw call for all cubes
- **~1800 FPS** (Linux/Vulkan, mailbox present mode, vsync disabled)
- **FPS overlay** — bitmap text updated every frame
- **Perspective camera** — FOV 45°, lookAt, near=0.1, far=200.0

## SDL3

SDL3 is used strictly for:

- **Windowing** — `SDL_CreateWindow()` with native Wayland support
- **Events** — keyboard, mouse, window close, quit
- **Native properties** — `SDL_GetWindowProperties()` extracts platform handles (`wl_display`, `wl_surface`, Win32 HWND, Android window, or Metal layer)

We do not use SDL_Renderer or SDL_gpu. SDL acts as a thin platform layer; all rendering flows through WGPU.

### SDL3 Bindings

In `source/bindings/sdl3.d`:

- Init/Quit, Window, Events, Properties, Timer, Metal
- `SDL_Scancode` with USB HID values
- `SDL_Event` union (128 bytes, SDL3 compatible)
- Property strings for Wayland, X11, Win32, Android, and Metal

## Shaders

The engine uses **WGSL** (WebGPU Shading Language), compiled directly by the WGPU runtime. Shaders are organized in `assets/shaders/` with an include preprocessor, compile-time CTFE embedding, and transactional runtime hot-reloading.

### cube3d.wgsl

Vertex shader transforming positions by VP × model matrix (instanced) and passing normals to fragment shader. Fragment shader computes directional N·L lighting:

```wgsl
@group(0) @binding(0) var<uniform> vp: mat4x4f;

@vertex
fn vs_main(
    @location(0) pos: vec3f,
    @location(1) normal: vec3f,
    @location(2) model0: vec4f,  // model matrix columns (per-instance)
    @location(3) model1: vec4f,
    @location(4) model2: vec4f,
    @location(5) model3: vec4f,
) -> VSOut {
    let model = mat4x4f(model0, model1, model2, model3);
    var out: VSOut;
    out.position = vp * model * vec4f(pos, 1.0);
    out.normal = (model * vec4f(normal, 0.0)).xyz;
    return out;
}
```

### text2d.wgsl

Vertex shader for text quads in screen space. Fragment shader samples R8Unorm atlas and applies color:

```wgsl
@group(0) @binding(0) var<uniform> screenSize: vec2f;
@group(0) @binding(1) var fontSampler: sampler;
@group(0) @binding(2) var fontTexture: texture_2d<f32>;
```

## Textures and Materials

`engine/graphics/texture.d` encapsulates GPU RGBA8 texture creation, configurable samplers, and uncompressed TGA loading. It also provides procedural helpers (`checker`, `solid`) for testing.

`engine/graphics/material.d` creates a `@group(1)` bind group with `MaterialParams` (metallic/roughness/baseColor/flags) + sampler + albedo and optional maps. Missing maps use default 1×1 textures.

### Supported Image Formats

| Format | Module | Notes |
|:---|:---|:---|
| TGA (uncompressed) | `engine.graphics.texture` | 24/32-bpp, minimal loader |
| BMP (24/32-bpp, uncompressed) | `engine.assets.bmp` | Flips row order vertically |
| glTF 2.0 (mesh + PBR) | `engine.assets.gltf` | `loadGltfMesh` / `loadGltfPbr`; skinning/anim/`.glb` deferred |

## SceneGraph

Transform hierarchy for composite objects (solar systems, body + limbs, cockpit camera, etc.).

- **Nodes** are indices (`uint`) into parallel arrays — `parent[]`, `local[]`, `world[]`
- **Single pass** propagates `world = parent.world × local` in topological order
- **No pointers** — zero GC pressure, cache-friendly, strictly `@nogc` compatible
- Useful with `Scene3DTextured.drawMatrix(mesh, world, material)`

## Camera Controllers

`engine/scene/controllers.d` provides three ready-to-use controllers:

| Controller | Input | Typical Use |
|:---|:---|:---|
| `OrbitCamera` | mouse drag + scroll | editor, model viewer, RTS |
| `FlyCamera` | WASD + mouse look | debug, showcase, editor viewport |
| `FirstPersonCamera` | WASD + mouse look + optional gravity | FPS gameplay |

All controllers update the internal `Camera` via `lookAt` — they are controllers, not cameras themselves.

## Audio

`engine/audio/engine.d` provides a simple API built on SDL3 audio streams:

- **`AudioEngine.create()`** — initializes the SDL3 audio subsystem
- **`AudioClip.loadWav(path)`** — decodes a WAV file into memory (PCM)
- **`engine.play(clip)`** — plays the clip non-blockingly; multiple instances overlap cleanly

Audio is designed for gameplay systems — it runs outside the graphics frame loop and does not require `@nogc`.

## DevTools

Debugging tools and editor components in `engine/devtools/`:

- **`Gizmos`** — immediate-mode 3D primitives (lines, XYZ axes, grid, bounding box). Uses `lineList` topology with depth overlay so lines remain visible over the scene. `begin/end` per frame, zero allocations on hot paths.
- **`DebugOverlay`** — structured FPS counter and arbitrary labels rendered via `TextRenderer`. Ideal for camera positions, frame counters, and runtime state flags.

## Library Structure

```
libs/
└── libwgpu_native.a    # WGPU-native (Vulkan backend on Linux)
```

Installation:

```bash
curl -sL https://github.com/gfx-rs/wgpu-native/releases/latest/download/wgpu-linux-x86_64-release.zip \
  -o /tmp/wgpu.zip
unzip -o /tmp/wgpu.zip -d /tmp/wgpu
cp /tmp/wgpu/lib/libwgpu_native.a libs/
```

## Build

```bash
# Clear screen demo
dub build --config=demo

# 3D benchmark (1000 cubes + FPS)
dub build --config=benchmark
dub run --config=benchmark

# Crystal Collector (gameplay)
dub run --config=game

# Solar system (scene graph + textures + PCF shadows)
dub run --config=showcase

# PBR validation (5×2 spheres + IBL + glTF cube)
dub run --config=pbr

# Visual editor (gizmos + debug overlay + shadows + docking)
dub run --config=editor

# Optimized release builds
dub build --config=demo --build=release
dub build --config=benchmark --build=release
```
