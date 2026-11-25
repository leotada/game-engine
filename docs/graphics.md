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
│  ├── Texture    → GPU texture + SDL3_image / TGA     │
│  ├── Material   → PBR bind group (params + maps)     │
│  ├── Sprite     → SpriteRenderer, Camera2D, SpriteAnim│
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
| Draw 2D sprites & spritesheets | `SpriteRenderer` + `Camera2D` + `SpriteRegion` + `SpriteAnim` (`engine.graphics.sprite`) |
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
2.   Scene3D / Scene3DTextured / GizmoRenderer (and optional HDR SpriteRenderer) draw into HDR target
3. resolvePost → end HDR pass
4.   bloom pass (threshold / downsample / upsample) when enabled
5.   tone map (ACES / Reinhard / Linear / AgX + exposure / saturation / contrast) → LDR
6.   FXAA pass when enabled → swapchain
7.   reopen present pass (load-op, no depth) for LDR SpriteRenderer / UiBatchRenderer / TextRenderer
8. endFrame → submit command buffer + wgpuSurfacePresent()
```

The optional shadow depth pass runs as a separate submit **before** `beginFrame`, or inside the frame via `Scene3DTextured.renderShadows(frame, lights)`.

#### HDR Scene Pass vs. LDR Present Pass

The renderer splits each frame across two color spaces and formats:

| Pass | Frame State | Color Format | Depth | Purpose & Renderers |
|:---|:---|:---|:---|:---|
| **HDR Scene Pass** | `frame.postResolved == false` (between `beginFrame` and `resolvePost`) | `WGPUTextureFormat.rgba16Float` (linear HDR) | `depth24Plus` | Linear scene lighting, values `> 1.0` for emissive glow and bloom. Runs `Scene3D`, `Scene3DTextured`, `GizmoRenderer`, and optionally `SpriteRenderer` (`hdrAlpha` / `hdrAdditive`). |
| **LDR Present Pass** | `frame.postResolved == true` (between `resolvePost` and `endFrame`) | Swapchain (`bgra8Unorm` / `rgba8Unorm`) | None | Post-processed display image (`[0.0, 1.0]`). Runs `UiBatchRenderer`, `TextRenderer`, and optionally `SpriteRenderer` (`ldrAlpha` / `ldrAdditive`) when crisp UI/2D colors without bloom or tone-map compression are desired. |

`PostProcessor` (`engine/gpu/post.d`) bridges the two passes inside `resolvePost`, converting the `rgba16Float` scene buffer into the swapchain format (with optional custom `PostStage.beforeTonemap`, `afterTonemap`, and `afterUi` passes).

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

### SpriteRenderer (2D Instanced Pipeline)

Pipeline for batched, sorted 2D sprites (`engine/graphics/sprite.d`):

- **Vertex buffer 0** — unit quad `float32x2 unitPos` in `[0, 1]²` (stride=8, 6 `uint16` indices)
- **Vertex buffer 1** — per-instance `SpriteInstance` (stride=64, `step=instance`): `posSize` (`vec4f`), `uvRect` (`vec4f`), `color` (`vec4f`), `originSinCos` (`vec4f`)
- **Bind group (`@group(0)`)** — `binding 0` = 64-byte `Mat4 viewProj` uniform, `binding 1` = `nearest` or `linear` clamp sampler, `binding 2` = `texture_2d<f32>`
- **Four pipeline variants** — `ldrAlpha` / `ldrAdditive` targeting swapchain format with no depth attachment (`frame.postResolved == true`), and `hdrAlpha` / `hdrAdditive` targeting `Renderer.sceneFormat()` (`rgba16Float`) with `depth24Plus`, `depthWriteEnabled = false`, `depthCompare = always` (`frame.postResolved == false`)
- **Sorting & Coalescing** — in-place `@nogc` ShellSort over `Pod!SpriteCmd` indices by `(layer, zOrder, sequence)`, merging consecutive runs with matching `(viewKey, blend, filter)` into single `drawIndexed(6, runCount)` calls

### Pipeline3D Textured (OpenPBR Surface v1.1)

Variant of Pipeline3D implementing the single-pass **OpenPBR Surface v1.1** shading model, PCF shadows, and IBL:

- **Vertex buffer 0** — geometry: `float32x3 position + float32x3 normal + float32x2 uv` (stride=32), tangent-extended (`MESH_TANGENT`, stride=48, `vec4f tangent`), or GPU-skinned (`MESH_TANGENT` + `SKINNED`, stride=80, `SkinnedVertex`: `pos + normal + uv + tangent + vec4u joints + vec4f weights`)
- **Vertex buffer 1** — instances: `TexInstanceData` (4×`float32x4` model + `vec4f` tint + `vec4f` custom, stride=96); vertex shaders transform normals with the $3 \times 3$ adjugate (cofactor transpose, `Mat4.transformNormal`) so non-uniform scaling preserves correct lighting
- **Bind groups:**
  - `@group(0) Frame` (`FRAME_BINDING_COUNT` = 16 entries, one layout shared by every scene-space pipeline) — 1024-byte `FrameUniforms` (viewProj, dirLight, cascades, SSR params, `ReflectionProbeData[4]`, atmosphere/sky, `viewportRect`, `clusterZParams`) at 0, comparison sampler at 1, directional/point/spot shadow maps at 2–8, point-light storage at 9, shared water data at 10 (`GpuWaterData`, `common/waves.wgsl`; see [Water](#water-enginewater)), 5-mip opaque HDR scene pyramid (`opaqueSceneColorMap`) at 11, resolved opaque scene depth (`opaqueSceneDepthMap`) at 12, spot-light storage at 13, cluster grid records (`16 × 9 × 24` clusters) at 14, and compacted per-cluster light index pool at 15
  - `@group(1) Material` (`MATERIAL_BINDING_COUNT` = 13 entries) — 208-byte `MaterialParams` UBO (`13 × vec4f`: Base, Specular/IOR/Anisotropy, `anisotropyRotation`, Coat, Fuzz, Thin-Film min/max thickness, Emission, Geometry Opacity, Transmission color/weight/depth/dispersion/thickness, Subsurface weight/color/radius/radiusScale/anisotropy), filtering sampler, albedo + MR/normal/occlusion/emissive maps (`2..6`), surface params UBO (`7`), and optional `MaterialLayerMaps` (`8..12`: `coat`, `coatNormal`, `fuzz`, `anisoFilm`, `transmission`, bound with 1×1 defaults when omitted)
  - `@group(2) IBL` — irradiance cubemap, prefiltered specular (mips), 3-channel BRDF LUT (`R`: GGX scale, `G`: GGX bias, `B`: Charlie sheen directional albedo), sampler
  - `@group(3) Skin` *(skinned variant only)* — read-only storage buffer of concatenated `mat4x4<f32>` joint palettes (`Scene3DTextured.drawSkinned`)
- **Fragment (`assets/shaders/common/pbr_brdf.wgsl`, `assets/shaders/textured3d_pbr.wgsl`)** — Complete OpenPBR v1.1 slabs (`OPBR-1`–`9`):
  - **Base & Specular:** Qualitative Fujii Oren-Nayar diffuse (`baseDiffuseRoughness`, attenuated by `1 - transmissionWeight` and `1 - subsurfaceWeight`), IOR-derived dielectric $F_0$ modulated by `coatIor` (`dielectricF0UnderCoat`), multi-scattering energy-compensated anisotropic GGX (with per-pixel `anisoFilm` tangent rotation and strength), and $F_{82}$-tint conductor Fresnel (`specularColor`)
  - **Thin-Film Iridescence:** Physical Airy thin-film reflectance modulating dielectric/conductor Fresnel (`thinFilmWeight`, `thinFilmThicknessMin`..`thinFilmThickness` driven by `anisoFilm.a`, `thinFilmIor`)
  - **Coat Slab:** Dielectric clearcoat GGX with per-pixel weight/roughness (`coatMap`), tangent-space `coatNormalMap`, optical absorption tint (`coatColor`), coat-induced base roughening (`coatRoughenBase`), and internal reflection darkening (`coatDarkening`)
  - **Fuzz / Sheen Slab:** Charlie microcylinder NDF + Ashikhmin visibility (`fuzzWeight`, `fuzzColor`, `fuzzRoughness`, modulated by `fuzzMap`) energy-conserved over coat and base
  - **Subsurface & Thin-Walled Translucency (`OPBR-8`):** Penner pre-integrated per-channel RGB wrap scattering + back-lit exponential profile (`subsurfaceWeight`, `subsurfaceColor`, `subsurfaceRadius`, `subsurfaceRadiusScale`, `subsurfaceAnisotropy`, modulated by `transmissionMap.b`), directional shadow blocker thickness estimation (`sampleDirShadowBackAndThickness`), and Henyey-Greenstein thin-walled back-face transmission (`MaterialFlags.thinWalled`)
  - **Refractive Transmission (`OPBR-7`):** 4-pass `Scene3DTextured.end()` (0 standard opaque → 1 SSR opaque + water → 2 `Material.transmissive` / alpha back-to-front → 3 additive), sampling `opaqueSceneColorMap` via screen-space refracted UVs with roughness-based mip selection, optional RGB dispersion (`transmissionDispersion`), Beer-Lambert volume absorption, and coat/fuzz attenuation
  - **Local Probes & SSR (`OPBR-9`):** Parallax-corrected box/sphere `@component ReflectionProbe` volumes (`MAX_REFLECTION_PROBES = 4`, `Scene3DTextured.setReflectionProbes`) + 16-step adaptive raymarched SSR with 3-step binary refinement (`Scene3DTextured.setSsr`, `MaterialFlags.ssr`) blended into base and coat specular IBL. SSR marches the resolved *opaque* scene (pass 0), so it reflects cars, buildings and terrain drawn as standard opaque materials, but not other `MaterialFlags.ssr` materials (pass 1), transparent/transmissive surfaces, or anything off-screen (use `ReflectionProbe` for those)
  - **glTF 2.0 Mapping (`engine.assets.gltf`):** Parses `doubleSided`, material `name`, and `KHR_materials_ior`, `KHR_materials_specular`, `KHR_materials_clearcoat`, `KHR_materials_sheen`, `KHR_materials_iridescence`, `KHR_materials_emissive_strength`, `KHR_materials_anisotropy`, `KHR_materials_transmission`, `KHR_materials_volume`, `KHR_materials_dispersion`, and `KHR_materials_diffuse_transmission` (`buildGltfLayerMaps` packs per-pixel layer maps at load time in `loadGltfAsset` and `loadGltfSkinnedCharacter`)
- **Usage** — `Scene3DTextured.setLighting` / `setEnvironment` / `setSsr` / `setReflectionProbes`; `Scene3DTextured.create(gpu, maxBatches, createIbl: false)` skips the procedural sky/IBL prefilter (~1 s in debug) and starts with a flat-grey environment, for scenes that bind a shared one via `setEnvironment` / `setEnvironmentBindGroup` right after creation (e.g. a second scene for unlit particle pools); `Material.create(gpu, scene.materialLayout, sampler, albedo, params, mr, norm, ao, emissive, layers)` (`GpuContext` requests `maxSampledTexturesPerShaderStage = 32` via `WGPULimits`)
- **Color target** — `Renderer.sceneFormat()` = `rgba16float` (offscreen, not swapchain); tone mapping in `resolvePost`

### Custom Surface Shaders: `surface`, `displace`, `displaceEx`

`Scene3DTextured.createSurfaceShader(wgsl)` splices game WGSL into the OpenPBR shader; assign the id to `Material.surfaceShader`. The snippet defines `fn surface(in: SurfaceIn, base: SurfaceOut) -> SurfaceOut` and may define **one** vertex hook. Read `frame.time`, `surfaceParams.p0 .. p3` (`Material.updateSurfaceParams`) and the vertex-visible material bindings from it.

| Hook | Signature | Receives |
|:---|:---|:---|
| `displace` (original) | `fn displace(localPos: vec3<f32>, localNormal: vec3<f32>) -> vec3<f32>` | object-space position and normal only |
| `displaceEx` (extended) | `fn displaceEx(d: DisplaceIn) -> vec3<f32>` | `d.localPos`, `d.localNormal`, `d.uv`, `d.custom` (per-instance vec4), `d.instancePos` (model translation), `d.objectScale` (model column lengths) |

- **Compatibility:** `displace` keeps compiling and behaving as before. When both are defined, `displaceEx` wins. Detection is textual (`fn displaceEx(` / `fn displace(`) in `composeSurfaceShader`, which emits an `engineDisplace(...)` wrapper that both the main vertex stage and the shadow stage call. Existing shaders need no change; a new hook is purely additive (no new binding, no pipeline-layout change), which is why it was chosen over a changed `displace` signature or an extra bind group.
- **Per-instance vec4:** `d.custom` is the instance `custom` vec4 that already rides in the 96-byte `TexInstanceData` (`StaticInstanceDesc.custom`, `drawMatrix(..., custom)`). Stock meaning is `x` emission multiplier, `y` white flash, `z` dissolve, `w` shelter; a surface shader may reinterpret the channels it does not use (zero emission makes `x` free; keep `z` out of reach of dissolve). Use it for a per-instance phase, e.g. `sin(frame.time * speed + d.custom.x)`. `d.instancePos` also differs per instance for a free phase seed.
- **Painted bend weight:** the mesh UV is exposed (`d.uv`), so a modeler can paint the weight into a UV channel (e.g. `uv.y`). Vertex color is **not** exposed: the engine vertex formats (`TexVert`, `TexTanVert`) carry no color attribute and adding one would change vertex strides and every vertex-buffer layout.
- **Shadow passes:** materials with either hook get a depth-only `vs_shadow` pipeline (cascades, point cube faces, spot maps; dynamic batches and `StaticInstanceBuffer`) built lazily from the same composed module, with the same `surfaceParams`, `frame.time` and instance data, so shadows follow the animation. Materials without a hook keep the stock shadow pipeline. Skinned meshes do not use surface shaders. Shadow group 0 holds the frame uniforms (binding 0) and the light matrix (binding 20, dynamic offset); group 1 is the material bind group.
- **Cost:** the per-instance vec4 needs no extra memory (it is part of the existing stride). A displaced caster re-reads the 16-byte `custom` attribute once per instance per shadow view (e.g. 4 cascades + local faces) and binds a second pipeline/bind group when switching between displaced and stock casters; there is no extra buffer or upload. Displacement ALU runs once per vertex per shadow view in addition to the main pass.

```wgsl
fn surface(in: SurfaceIn, base: SurfaceOut) -> SurfaceOut { return base; }
fn displaceEx(d: DisplaceIn) -> vec3<f32> {
    let bend = d.uv.y;                                   // painted weight
    let sway = sin(frame.time * 1.7 + d.custom.x) * surfaceParams.p0.x * bend;
    return d.localPos + vec3<f32>(sway / d.objectScale.x, 0.0, 0.0);
}
```

Verification: `dub run --config=surface-shadow-check` renders a top-down scene at two times and asserts, from a frame capture, that shadows of dynamic, static and legacy `displace` casters move by the analytic amount, that `displaceEx` separates instances (phase from `custom.x`) and that a stock control stays still. Unit tests in `engine.gpu.shaders` cover the composition.

### Alpha Mask

`Material.renderState.alphaMask = true` discards pixels whose opacity (albedo alpha × `geometryOpacity` × tint alpha, or the `surface()` opacity) is below `MaterialParams.alphaCutoff`, and writes the rest as opaque. No sorting is needed, so `blend` can stay `BlendMode.opaque`.

- **Color:** a pipeline variant with the WGSL constant `ALPHA_MASK` on; other materials compile it to false.
- **Shadows:** masked casters get their own depth pipelines with a discard, for cascades, point and spot maps, on the dynamic, skinned, `StaticInstanceBuffer` and `displace` / `displaceEx` paths. Opaque casters keep the depth-only pipelines. Masked casters read the full vertices, not the position-only shadow indices.
- **Limit:** shadow passes test the albedo alpha. Opacity computed by `surface()` is not evaluated there.
- **Mips:** `TextureDesc.alphaCoverage = cutoff` rescales the alpha of every mip so the fraction of the surface kept by the alpha test stays that of level 0. The fraction is measured with bilinear filtering and wrapped addressing (`alphaCoverageOf`), so thin shapes such as wire grids also keep their coverage. Distant foliage and fences do not thin out. Measured far away (512x512 mask, mip 2 to 3): noise 0.258 of 0.267, grid 0.171 of 0.179; plain mips give 0.002 and 0.113.
- **glTF:** `GltfImportOptions.alphaModes` applies `alphaMode` and `alphaCutoff`: `MASK` sets the mask and coverage mips, `OPAQUE` sets `BlendMode.opaque`, `BLEND` keeps the default state.

Verification: `dub run --config=render-check -- --check=mask`.

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

### sprite2d.wgsl

Instanced 2D sprite shader transforming unit quads around a normalized `origin` with per-instance rotation `(sin, cos)`, UV sub-rectangle interpolation (`mix(uvRect.xy, uvRect.zw, unitPos)`), RGBA tint, and alpha cutout (`tex.a <= 0.001`):

```wgsl
struct SpriteUniforms { viewProj: mat4x4<f32> };
@group(0) @binding(0) var<uniform> spriteU: SpriteUniforms;
@group(0) @binding(1) var spriteSampler: sampler;
@group(0) @binding(2) var spriteTexture: texture_2d<f32>;
```

## Textures and Materials

`engine/graphics/texture.d` encapsulates GPU RGBA8 texture creation, configurable samplers, and uncompressed TGA loading. It also provides procedural helpers (`checker`, `solid`) for testing.

`engine/graphics/material.d` creates a `@group(1)` bind group with the 208-byte OpenPBR Surface v1.1 `MaterialParams` UBO (Base, Specular/IOR/Anisotropy, Coat, Fuzz/Sheen, Thin-Film Iridescence, Emission, Geometry Opacity, Transmission/Volume/Dispersion, Subsurface/Thin-Walled Translucency, `flags`) + sampler + albedo, optional standard maps (`2..6`), surface params (`7`), and optional `MaterialLayerMaps` (`8..12`). Missing maps use default 1×1 textures (`MaterialDefaults`).

### Supported Image Formats

| Format | Module | Notes |
|:---|:---|:---|
| TGA (uncompressed) | `engine.graphics.texture` | 24/32-bpp, minimal loader |
| BMP (24/32-bpp, uncompressed) | `engine.assets.bmp` | Flips row order vertically |
| glTF 2.0 / GLB (mesh + OpenPBR) | `engine.assets.gltf`, `engine.graphics.model` | `loadGltfMesh` / `loadGltfPbr` (first primitive) and `loadGltfAsset` (all meshes, primitives, materials, node tree; `.glb`, `data:` buffers, embedded images) with `KHR_materials_{ior,specular,clearcoat,sheen,iridescence,emissive_strength,anisotropy,transmission,volume,dispersion,diffuse_transmission}` + layer texture maps |

## Open-World Rendering (OW-2)

Phase 2 of [plan-open-world-readiness.md](plan-open-world-readiness.md). Everything listed here is `nothrow @nogc` in the frame path; allocations happen only at load time. The DoD is proven by `dub run --config=openworld-bench -- --headless-frames=600 --assert-no-gc`.

### Textures: mips, anisotropy, arrays, formats

| API | Purpose |
|:---|:---|
| `TextureDesc{generateMips, normalMap}` (`TextureDesc.mipped()`, `.mippedNormal()`) | Opt-in CPU 2×2 box-filter mip chains, generated at load time (non-power-of-two safe; normal maps are renormalized per level). Passed to `fromPixels`, `fromImageFile`, `fromImageBytes`, `fromTgaFile`, `loadBmpTexture`. |
| `TextureDesc.srgb` (`TextureDesc.mippedSrgb()`) | Opt-in sRGB color texture (`rgba8UnormSrgb`) for `Texture` and `TextureArray`: the GPU decodes RGB on read and mips are averaged in linear light; alpha stays linear. Use it for albedo and emissive, never for normal, ORM or masks. glTF: `GltfImportOptions.srgbColor` (base color, emissive, sheen color). Terrain and decals: the `srgbAlbedo` argument of `TerrainMaterial.create` / `DecalRenderer.create`. sRGB textures drawn by the UI look darker, so keep UI images linear. |
| `PostSettings.outputTransfer` | `gamma22` (default, `pow(1/2.2)`) or `srgb` (exact curve). With `srgb`, an unlit sRGB texture and the linear tone mapper return the texture codes; `gamma22` is within 1 code for mid greys but lifts darks (10 becomes 18). |
| `Texture.fromR16` / `Texture.fromR32F` | Single-channel heightmaps (`r16Unorm`, `r32Float`). `r32Float` is not filterable without `float32-filterable`: use nearest sampling or `textureLoad`. |
| `TextureArray.fromLayers(gpu, layers, w, h, mips)` | `texture_2d_array` (`dim2DArray` view) for terrain splat layers. |
| `SamplerDesc{filter, wrap, maxAnisotropy}` + `Sampler.create(gpu, desc)` | Anisotropy is clamped to 1..16 and forced to 1 for nearest filtering (WebGPU rule). |

UI and 2D textures keep a single mip; the glTF loaders (`loadGltfPbr`, `loadGltfAsset`) mipmap by default.

### Zero-GC `Scene3DTextured`

- Batches are keyed by `(TexMesh*, Material*, lod)` in an open-addressed `BatchMap` with epoch reset (O(1) `begin`, up to `DEFAULT_MAX_BATCHES = 256`). Instance lists are malloc-backed `PodBuffer`s that only grow during warm-up.
- `setLights` rebuilds the frame bind group only when the sampler or one of the shadow views changes.
- `FrameContext.drawIndexed(indexCount, instanceCount, firstIndex = 0, baseVertex = 0, firstInstance = 0)` exposes the full WebGPU signature; the color pass now draws only the batch's LOD index range.

### Culling and LOD for dynamic draws

- `begin(camera)` extracts a `Frustum` (`engine.math.frustum`, Gribb–Hartmann for WebGPU `z ∈ [0,1]`, near = row 2). `TexMesh` and `Mesh` carry `localBounds` (`Aabb`) and `localSphere` computed at upload.
- In `renderShadows` / `end`, each batch is culled once and stably partitioned into `[camera | camera+light | light | culled]`, so the color pass and the directional shadow pass each draw one contiguous `firstInstance` range of a single upload.
- Point-light faces and spot views get their own caster lists: per light, each instance's world sphere is first tested against the light's range sphere, then against each view frustum (6 cube faces or the spot frustum); survivors are copied contiguously per view into one shared per-frame caster buffer, uploaded once (`gatherLightCasters`). In `openworld-bench` this cuts dynamic shadow casters from ~11,600 to ~110 per frame (one point + one spot light). With culling off, or for meshes without bounds, these views draw the whole batch.
- `RenderStats.shadowInstancesDrawn` counts dynamic casters over every shadow view.
- `setCulling(bool)` (default on) and `setDistanceCull(maxDistance, minPixelSize)` (0 disables either test).
- `drawMatrix(..., lod = LOD_AUTO)` picks the LOD per instance from `selectLod` (`engine.graphics.lod`): the coarsest level whose projected simplifier error stays under one pixel, given `setLodScreenHeight` (default 1080) and `setLodBias`. Pass an explicit level (e.g. `MeshLod.current` from `lodSelectSystem`) to get hysteresis.
- `stats()` returns `RenderStats`: batches, draw calls, shadow draw calls, dynamic submitted/visible, static visible/ranges, a per-LOD instance histogram, and `droppedDraws`.

### Batch table

Dynamic draws are grouped into one batch per `(TexMesh*, Material*, lod)` key (skinned draws use `(SkinnedMesh*, Material*)` and share the same table). A batch keeps its malloc-backed instance list and its GPU instance buffer across frames, and the buffer is created on the batch's first upload.

- **Grows on demand.** `create(gpu, maxBatches)` only sets the initial capacity (default 256). When a frame needs a new key and the table is full, the table doubles (`realloc`, `@nogc`, no GC allocation) and the lookup map is rebuilt from the frame's live batches. A small `maxBatches` costs a reallocation, never a missing draw. Pointers to batches are never held across a draw call, so moving them is safe. A hook that calls `draw*` while `end` is iterating batches is not supported.
- **Hard ceiling.** `Scene3DTextured.MAX_BATCHES_HARD` (65,536) bounds memory. Past it, new keys are dropped and counted in `RenderStats.droppedDraws`, and a warning is logged on every frame that drops a draw (existing keys still draw).
- **Stats.** `batchStats()` returns `BatchStats { used, peak, capacity, growths, droppedDraws }`:
  - `used`: batches used by the current frame, culled ones included;
  - `peak`: the highest `used` since `create`;
  - `capacity`: the current table size;
  - `growths`: how many times the table grew past the initial capacity;
  - `droppedDraws`: lifetime drops at the ceiling.

  Show `used`/`peak` in a perf overlay, or assert `peak <= budget` in a headless gate. A non-zero `growths` count means `maxBatches` can be raised to avoid the mid-frame reallocation.

### LOD chains at load time

`uploadLodMesh(gpu, vertices, indices, shadowIndices, tangents, LodSettings)` (`engine.assets.gltf_optimize`) runs `buildLodChain`, concatenates every level into one index buffer and records each level's `firstIndex`, count and relative error with `TexMesh.setLodChain`. `loadGltfAsset` calls it when `GltfLoadOptions.generateLods` is set. With a chain, shadows use the LOD index ranges instead of the welded shadow index buffer (the vertex buffer is reordered by the simplifier).

**Limitation:** `simplify` (topology-preserving) cannot reduce meshes made of independent closed boxes with duplicated vertices per face (it collapses edges, and every face edge is a border). Only `simplifySloppy` (`LodSettings.sloppyFallback = true`) reduces those, and it can shrink thin planes, so validate each level against the bounding box of the original (or weld vertices before building the chain).

### Retained static instancing (`engine.scene.static_instances`)

```d
TexMesh*[]  meshes = [&rock.subMeshes[0], &tree.subMeshes[0]];
Material*[] mats   = [rock.materialPtr(0), tree.materialPtr(0)];
StaticInstanceDesc[] props = ...;              // (mesh, material, model, tint)
StaticBuildOptions o; o.maxDistance = 1600; o.minPixelSize = 1.5f;
auto sib = StaticInstanceBuffer.build(gpu, meshes, mats, props, o);
sib.setMeshCull(1, 800, 2);                    // per-mesh override
// every frame, between scene.begin and scene.end:
scene.submitStatic(sib);
```

- Built once: instances are sorted by `(mesh × material group, 128 m cell)` and uploaded into one vertex buffer. Nothing is rebuilt per frame.
- Per frame, `collectVisibleRuns` tests each `(group, cell)` range's world AABB against the frustum and the group's distance / pixel-size limits, picks **one LOD per range** from its nearest distance, and merges adjacent ranges with the same group and LOD into one `drawIndexed(count, run, firstIndex = LOD range, 0, firstInstance = run start)`.
- Shadows reuse the same ranges culled against each light's frustum, with the LOD still chosen from the camera so shadows match the visible geometry.
- Static buffers draw in the opaque pass: use depth-writing materials. Up to `MAX_STATIC_SUBMISSIONS = 8` per frame. The meshes and materials must outlive the buffer.
- `updateInstance(i, model)` / `hideInstance(i)` rewrite one instance on the GPU (slow path for rare edits; keep the new position inside the original cell).

#### GPU culling and indirect draws (`StaticBuildOptions.gpuCull`, `engine.gpu.static_cull`)

Off by default. With `gpuCull = true` a compute shader (`static_cull_cs.wgsl`) culls every instance (frustum, cascade receivers, distance, pixel size), picks its LOD and writes a compacted instance buffer plus one indirect record per (group, LOD). The scene then issues one multi-draw per (material, vertex stride, index format); plain opaque shadow casters share one per (stride, format, culling). Output order equals input order, so coplanar surfaces do not flicker. Vertex shaders see the same `TexInstanceData`: surface shaders, `displaceEx` and alpha masks work unchanged.

- **Views:** camera and directional shadows (cascades or the fixed map). Point and spot shadows keep the CPU path.
- **Needs** the `indirectFirstInstance` and `multiDrawIndirectCount` features; otherwise (web included) the CPU path is used. `sib.gpuCulled` tells which one is active.
- **Displacement:** set `Material.displacementBound` to the largest movement of a `displace` / `displaceEx` hook, or instances can vanish at the screen border while their displaced vertices are still visible.
- **Memory:** each active view keeps `instances × 100` bytes plus about 32 bytes per 64 instances. 40,000 instances with the camera and three cascades take about 16 MB. The meshes are copied into shared pools at build, so later `TexMesh.updateVertices` calls are not seen.
- **Stats:** `drawCalls`, `shadowDrawCalls` and `staticRangesDrawn` (indirect records) are filled. Instance counts (`staticInstancesVisible`, `shadowStaticInstancesDrawn`, `lodHistogram`) stay on the GPU and are not counted.
- **`rangeLodParity`** takes the CPU path's per-range decisions, for comparisons.
- **Zones:** CPU `scene.staticCull`, GPU `gpu.staticCull`.

Measured (RX 6600, 1080p, LDC release, 40,000 instances, 3 cascades, two runs):

| Scene | Path | Draws color + shadow | `renderer.submit` | Static draw + shadow encode (CPU) | `gpu.scene.opaque.static` | `gpu.staticCull` | Frame |
|:---|:---|:---|:---|:---|:---|:---|:---|
| 64 materials | CPU | 1137 + 255 | 1.25 to 1.29 ms | 0.36 to 0.38 ms | 0.40 to 0.43 ms | none | 1.80 to 1.83 ms |
| 64 materials | GPU | 129 + 165 | 0.77 to 0.84 ms | 0.06 ms | 0.19 ms | 0.05 ms | 0.95 to 1.04 ms |
| 4 materials | CPU | 172 + 102 | 0.41 to 0.42 ms | 0.14 ms | 0.24 ms | none | 0.95 to 0.98 ms |
| 4 materials | GPU | 9 + 27 | 0.35 to 0.40 ms | 0.02 ms | 0.22 ms | 0.09 ms | 0.88 ms |

The gain follows the number of draws the CPU path issues. With few materials it is small.

Verification: `dub run --config=render-check -- --check=gpucull` (same image as the CPU path, and the same instances with `rangeLodParity`).

### `SpatialGrid` (`engine.scene.spatial_grid`)

A loose XZ grid (default 64 m cells) for dynamic objects: `insert(userId, sphere)`, `update`, `remove` are O(1) (intrusive per-cell lists, malloc storage, free-list reuse); `query(frustum, camPos, maxDistance, outIds)` writes visible ids into a caller buffer. Spheres larger than half a cell or outside the grid go to an always-tested overflow list. Use it to skip whole groups of gameplay entities before they reach `drawModel`.

### Editor and player scenes (`engine.editor.scene_renderer`)

`SceneRenderer` draws a `SceneWorld` (`Transform` + `Visual` + `MaterialOverride` + `Light`) through `Scene3DTextured`, and is shared by the editor's Scene/Game views and the standalone player:

```d
auto renderer = SceneRenderer.create(app.gpu);
renderer.syncAssets(app.gpu, world);            // import referenced *.asset.json models up front
// per frame, after frame.setViewport(...):
renderer.render(app.gpu, world, frame, camera, lightSettings, viewportHeight);
```

- Mesh entities load their asset's glTF/GLB once into a cached `GltfAsset` (failures are remembered and drawn as a cube); primitives use built-in `TexMesh`es. `MaterialOverride.baseColor` / `geometryOpacity` become the instance tint.
- Scene lights are packed with `packLightsFromWorld`; a scene without lights gets a default sun. Shadows, culling and LOD are the `Scene3DTextured` ones.
- Zero GC once every referenced asset is loaded: `game-engine-player --headless-frames=600 --render --assert-no-gc` renders 600 real frames and asserts 0 bytes.
- `FrameContext.resumeScenePass` (after shadow passes) re-applies the last `setViewport` rectangle, so panel viewports and split screens keep their rectangle.
- `.meta` `settings.lod` (`enabled`, `maxLods`, `ratio`, `maxError`) builds LOD chains in every glTF loader (`lodImportFor`, `uploadImportedMesh`).

### Multi-node glTF / GLB assets (`engine.graphics.model`)

- `parseGltfDocument` reads `.gltf` and `.glb` (binary chunk), `data:` base64 buffers, and images from a URI, a `bufferView` or a data URI. `parseGltfScene` returns every mesh, primitive, material and the node tree **without baking node transforms**. The legacy `parseGltfMesh` / `loadGltfMesh` / `loadGltfPbr` keep their first-primitive, baked-transform behavior.
- `GltfAsset` (move-only, shared): one `TexMesh` per primitive, materials (plus a trailing default, carrying `doubleSided` from glTF and lookup by name via `findMaterial` / `materialName`), textures, a parents-first `GltfNode` table (≤ `MAX_MODEL_NODES = 256`) and node names in a `StringTable`. Load with `loadGltfAsset(gpu, path, scene.materialLayout(), sampler, GltfLoadOptions)`.
- `ModelInstance` (POD, `isPod`): a 256-bit hidden-node mask (hiding a node hides its subtree), up to 8 `MaterialHandle` overrides per sub-mesh and 8 local transform overrides.
- `MaterialPool` (`engine.graphics.material_pool`): fixed-capacity generational pool; `add` moves a `Material` in and returns a `MaterialHandle`, `get` returns null for stale handles (the asset material is used instead).
- `drawModel(scene, asset, inst, world, pool)` computes node worlds on the stack and submits each visible sub-mesh through `drawMatrix` (culling + auto LOD apply).
- `detachSubMesh(asset, inst, "door_fl", world)` hides the node in the instance and returns a `DetachedPart` (world matrix, sub-mesh range, local bounds) to spawn an independent rigid body; draw it with `drawSubMesh`.
- For GPU-skinned characters (`SkinnedCharacterAsset`, `loadGltfSkinnedCharacter`, `drawSkinnedCharacter`, `Scene3DTextured.drawSkinned`), see [animation-guide.md §7](animation-guide.md#7-gpu-skinning).

## Outdoor Rendering (OW-3)

OW-3 adds:
- cascaded shadows;
- linear HDR height fog;
- an engine sky driven by a day/night and weather model;
- runtime HDR IBL;
- global rain wetness;
- chunked terrain;
- projected decals.

Everything stays zero-GC in the frame loop. The reference scene is `dub run --config=outdoor`.

### `FrameUniforms` (1024 bytes)

`Scene3DTextured.FrameUniforms` (`common/shadows.wgsl` `FrameUniforms`) carries global frame data:

- cascade matrices, splits and texel sizes;
- `invViewProj`, camera forward/near/far, `viewportSize`, `viewportRect` (active pixel sub-viewport) and `clusterZParams` (logarithmic Z slicing);
- fog, moon, sky and sky-sun parameters, SSR params, and `ReflectionProbeData[4]`;
- `globalWetness`, `rainIntensity`, `cloudCoverage`, and `clusteredFlags`.

`FRAME_UNIFORMS_SIZE` in `engine/gpu/pipeline.d` must match.

### Clustered Forward Lighting (`engine.gpu.clustered`, `clustered_cull_cs.wgsl`)

`Scene3DTextured` scales active unshadowed local lights to **1,024 point lights** (`@group(0) @binding(9)`) and **256 spot lights** (`@group(0) @binding(13)`) while retaining deterministic shadow budgets (**1** dir, **4** point cubemaps, **2** spot maps):

- **Frustum Grid (`16 × 9 × 24` = 3,456 clusters):** Screen tiles map via `frame.viewportRect` (preserving Editor dock panel offsets), and depth slices partition `[nearZ, farZ]` logarithmically via `frame.clusterZParams` ($d_k = \text{near} \cdot (\text{far}/\text{near})^{k/24}$).
- **Compute Culling (`ClusteredLightCuller`):** At the start of `Scene3DTextured.end()`, when `clusteredEnabled` is true and at least one local light is active, the HDR scene pass suspends cleanly (`FrameContext.suspendScenePass` / `resumeScenePass`) to run two compute passes:
  1. `cs_reset` `(1, 1, 1)` clears the GPU atomic index counter in `ClusterState`.
  2. `cs_cull` `(16, 9, 24)` dispatches one 64-thread workgroup per cluster; thread 0 builds the view-space cluster AABB, all 64 threads test point spheres (`sphereIntersectsAabb`) and spot cones (exact minimum bounding sphere + behind-apex half-space check), and the cluster appends compacted indices into `clusterLightIndices` (`@binding(15)`) while writing its `{offset, pointCount, spotCount}` `ClusterRecord` (`@binding(14)`).
- **Shader Evaluation:** `textured3d_pbr.wgsl`, `common/simple_pbr.wgsl` (`terrain_pbr.wgsl`, `decal_pbr.wgsl`), and `water_surface.wgsl` all evaluate only the fragment's cluster list via `clusterIndexAt(worldPos, screenXY)` (`common/shadows.wgsl`), with explicit-LOD shadow comparisons (`textureSampleCompareLevel`) for WGSL uniformity compliance and optional runtime linear fallback (`Scene3DTextured.setClusteredCulling(false)`).
- **Stress Benchmark (`dub run --config=clustered-bench`):** Verified at `1280×720` with **1,024 dynamic point lights + 128 spot lights**: **6.386 ms p50** (`6.974 ms` p95, `103.5 FPS` avg with screenshot frame) vs **15.707 ms p50** (`52.7 FPS`) unclustered (**2.46× median speedup**), with **0 bytes** GC allocation.

### Cascaded shadow maps (`engine.scene.cascades`)

- Turn on the directional light with `lights.dir.castShadows = true`. The automatic `scene.renderShadows(frame, lights)` path then renders `GpuDirLight.cascades` into a `depth32Float` array.
- `CascadeSettings` fields:

  | Field | Default |
  |:---|:---|
  | `count` | 4 |
  | `lambda` | 0.75 (log/linear PSSM blend) |
  | `maxDistance` | 400 m |
  | `blendFraction` | 0.1 |
  | `casterMargin` | 250 m |
  | `resolution` | 2048 |
  | `receiverCulling` | true |
  | `receiverDrop` | 30 m |

- Cascades are fitted to a sphere and texel-snapped, so they do not shimmer. Each cascade culls its own casters.
- **Receiver-aware caster culling** (`receiverCulling`, `ReceiverCull`):
  - The light box encloses the slice's bounding sphere and reaches `casterMargin` toward the light, so it also contains casters behind and beside the camera.
  - A caster is drawn into a cascade only when its bounds, swept along the shadow direction down to `receiverDrop` below their bottom, touch the camera slice that cascade shades (`[splitNear, splitFar]`).
  - This applies to static ranges and cells and to dynamic instances.
  - In viatura-VI it halves the shadow draws and removes ~84% of the static shadow instances, with an identical image.
  - Raise `receiverDrop` if shadows must land on receivers far below their casters (cliffs).
- The shader blends between cascades and fades out at `maxDistance`. The foliage thickness read from the cascades (`sampleDirShadowBackAndThickness`) fades out with the shadow, so nothing past the shadow range reads the map.
- `lights.dir.debugCascades = true` tints the cascades red, green, blue and yellow.
- A caller-owned `ShadowMap` passed to `setLights` keeps the legacy single fixed map.
- Extra casters (terrain) register with `scene.addShadowCasterHook`, using `shadowVpLayout()` as `@group(0)`.

### Height fog (`engine.scene.atmosphere`)

- `FogSettings` fields: `enabled`, `color`, `density`, `heightBase`, `heightFalloff`, `startDistance`, `maxOpacity`, `sunColor`, `sunPower`.
- Fog is analytic exponential height fog with a sun in-scattering lobe, evaluated in linear HDR before bloom and tonemapping. It applies in `textured3d_pbr.wgsl`, `water_surface.wgsl`, the terrain, decals and the sky (`common/atmosphere.wgsl`, `applyFog`).
- Set it with `scene.setFog(fog)` before `begin`. Scene files store it under `settings.fog`; the editor light panel has Fog, density, falloff and base.

### Engine sky (`engine.gpu.sky`, `sky.wgsl`)

- `scene.setSkyEnabled(true)` draws a fullscreen far-plane sky after the opaque pass. It is driven only by frame uniforms:
  - the sun is the directional light, or `setSkySun` when the directional light is the moon;
  - `setSkyState(moonDir, moonIntensity, starIntensity, exposure)`;
  - cloud coverage from `setWeather`.
- `common/sky_eval.wgsl` (`evalSky`) blends night, dusk and day gradients. It adds Mie scattering, overcast grey, stars, the moon, fBm clouds, and the sun halo and disc.
- Stars are round dots with a jittered center and a radial falloff, one per equiangular cube-face cell at most. They never get smaller than one pixel (`SkyInputs.pixelAngle`, from screen derivatives in `sky.wgsl`), and a widened star keeps its energy.
- `common/sky_frame.wgsl` builds `SkyInputs` from the frame uniforms (`frameSkyInputs()`, `frameSky(dir)`). Include it (after `shadows.wgsl` and `sky_eval.wgsl`) in any shader that reflects the sky, such as water, so reflections and fog match the visible sky exactly.

### Day/night and weather (`engine.scene.time_of_day`)

- `TimeOfDay`:
  - fields `hours`, `latitudeDeg`, `declinationDeg`, `dayLengthSec`, `northOffsetDeg`, `sunIntensity`, `moonLightIntensity`;
  - `advance(dt)` moves the clock;
  - `sunDirection` computes the solar path.
- `Weather`:
  - fields `cloudCoverage`, `rainIntensity`, `wetness`, `fogScale`;
  - `setTarget(clouds, rain)`, then `update(dt)` blends toward the target;
  - rain only starts once the sky is overcast, surfaces wet while it rains and dry afterwards.
- `evaluateEnvironment(tod, weather)` returns an `EnvironmentState` with sun, moon, stars, the light to use (sun by day, moon by night), fog color and weather values.
- Apply it with:
  - `applyEnvironment(env, lights, fog, baseDensity)` for the directional light and fog;
  - `applyEnvironmentToScene(env, scene)` for the sky and weather uniforms;
  - `skyIblParams(env, time)` for runtime IBL.

### Runtime HDR IBL (`engine.gpu.ibl_dynamic`)

- `DynamicIbl.create(gpu, scene.iblLayout())` renders the sky into a 64² `rgba16Float` environment cube with a compute shader (`ibl_sky_cs.wgsl`). It then convolves irradiance (16²) and 5 GGX specular mips.
- Work is amortized: `request(params)` starts a cycle when the sky changed visibly (`SkyIblParams.differsFrom`), and `update()` runs at most one step per frame. The cubes are double-buffered and the bind group swaps only when a cycle completes.
- `bakeNow` is for start-up. The BRDF LUT is baked into the binary (`assets/shaders/common/brdf_lut_128.bin`); after changing the integrator in `ibl.d`, rebake it with `dub test --config=library --d-version=BakeBrdfLut`.
- Call `scene.setEnvironmentBindGroup(ibl.bindGroup())` every frame.
- The CPU-prefiltered `IblEnvironment` paths remain `rgba8Unorm`.

### Rain wetness

- `scene.setWeather(wetness, rain, clouds)` feeds `frame.globalWetness`.
- `textured3d_pbr.wgsl` applies a water coat: darker albedo, low coat roughness, IOR 1.333. It is weighted by an upward-facing mask and skipped for instances with `custom.w = 1` (sheltered or indoor).
- Terrain and decals darken and gloss rain-facing surfaces the same way.

### Terrain (`engine.terrain`)

The terrain is a chunked heightmap with PBR splatting:
- one instanced draw per LOD with geomorphing and skirts;
- an `r32Float` heightmap read in the vertex shader;
- top-4 height-blended layers out of 8, triplanar cliffs and de-tiling;
- shadows in every cascade;
- Box3D colliders that match `heightAt` within 1 cm.

Full guide: [terrain-guide.md](terrain-guide.md).

### Projected decals (`engine.graphics.decals`)

- `DecalSystem.create(capacity)` is a POD ring buffer:
  - `spawn(pos, normal, size, depth, rotation, layer, DecalStyle)` overwrites the oldest decal when full;
  - `update(dt)` handles `lifetime` and `fadeOut`.
- `DecalRenderer.create(gpu, scene, albedoLayers, normalLayers, size, capacity)`, then `attach(scene, app.renderer, system)`.
- Per frame, before `scene.end`: `decals.update(dt); dr.update(decals, camera)`.
- Decals draw in a `Scene3DTextured.addPostOpaqueHook`, after terrain and opaque geometry and before the sky and transparent objects:
  - the hook snapshots the opaque depth (`Renderer.snapshotOpaque`);
  - it draws instanced unit boxes with front-face culling and no depth test;
  - the fragment shader reconstructs the surface with `invViewProj`;
  - it discards outside the box and fades by edge and by angle (`DecalStyle.angleFade`), which prevents stretching on steep faces.
- Decals are lit with the scene lights, CSM, IBL, fog and wetness, and use premultiplied blending.
- `proceduralDecalLayers(size, albedo, normal)` gives four demo layers: skid, crack, mud and arrow.
- `openworld-bench --decals=500` and `outdoor --decals=N` exercise the system.

### Scene draw order

The scene renders in this order:
1. shadows (cascades, local lights and hooks);
2. opaque batches, static buffers and opaque hooks (terrain);
3. post-opaque hooks (decals);
4. sky;
5. transparent hooks (`addTransparentHook`: refractive surfaces such as water,
   which need the sky in their opaque snapshot);
6. alpha-blended batches, then additive batches.

## Water (`engine.water`)

Water is being moved from the water demo into the engine
([plan-water-engine-port.md](plan-water-engine-port.md)). Usage and the
current API are in [water-guide.md](water-guide.md).

- **Wave model:** `engine.water.waves` (`WaveSet`, `sampleWaves`,
  `waveHeightAt`) on the CPU.
- **Shared water data (frame binding 10):** `GpuWaterData` holds up to
  `MAX_WATER_BODIES` (4) bodies. Each body has XZ bounds, a water level and
  its own wave set. `Scene3DTextured.setWaterData` uploads it; scenes without
  water keep zero bodies. `common/waves.wgsl` declares the binding and the
  shader-side wave functions (`waterBodyAt`, `waterWaveY`, `waterSurfaceY`,
  `waterEnvelope`, `waterPhaseWarp`, `waterChannelScale`), which match the D
  evaluators. Wave animation uses the frame time (`Scene3DTextured.setTime`).
- **PBR wetline:** materials with `MaterialFlags.waterWetCaustics` get
  wave-contact wet marks only inside a body whose wetline is enabled. Waves,
  time, contact chop and the recent peak scale come from the shared data.
  Outside every body the material is shaded normally. Wet, mossy and
  submerged stone presets: `engine.graphics.material_presets`
  ([water-guide.md](water-guide.md#wet-material-presets-enginegraphicsmaterial_presets)).
- **Sky reflection:** the water surface reflects and fogs toward the engine sky
  (`frameSky`, `common/sky_frame.wgsl`); enable it with
  `scene.setSkyEnabled(true)`. The old demo sky dome is gone.
- **Surface rendering:** `WaterRenderer` (`engine.water.renderer`) draws up to
  4 `WaterBody` values in a transparent hook after the sky (one opaque
  snapshot shared by all bodies), steps a 256² compute wave/foam simulation
  per body and handles up to 16 obstacles per body. The surface shader takes
  per-body uniforms (center, size, level, style, optics), so it no longer
  assumes water at the origin or at Y = 0.
- **Caustics:** `common/caustics.wgsl` (`waterCausticsAt`) adds animated sun
  caustics to every fragment below the level of a body with
  `causticsStrength > 0`. `textured3d_pbr.wgsl` and `common/simple_pbr.wgsl`
  (terrain, decals) call it in their directional-light term, scaled by the
  sun shadow. Rivers scroll the pattern with the current and fade it outside
  the channel. Submerged props reach the water surface already lit through
  the opaque snapshot; the surface shader does not add caustics itself.

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

`OrbitCamera` options: `minDistance` / `maxDistance`, `minPitch` / `maxPitch` (keep the view above ground or water), `wheelZoomSpeed` (0 = wheel ignored) and `dragToRotate` (rotate only while a mouse button is held, for windowed apps without a captured mouse).

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

# OpenPBR Surface v1.1 validation (6×5 spheres + layer maps + transmission + SSS/thin-walled + probes/SSR + IBL + glTF cube)
dub run --config=pbr

# OpenPBR Ocean & River water showcase (Gerstner waves + wet rocks + Fresnel blend)
dub run --config=water -- --river

# Outdoor (OW-3): 3 km terrain, CSM, fog, sky, day/night + rain, dynamic IBL, 500 decals
dub run --config=outdoor -- --headless-frames=600 --assert-no-gc

# Open-world bench: 12k static props over 3 km², 200 multi-node vehicles, LOD + culling stats
dub run --config=openworld-bench
dub run --config=openworld-bench -- --headless-frames=600 --assert-no-gc
# Extra flags: --debug-cascades --fog --tod=H (sky + day/night + dynamic IBL) --rain
#              --wetness=X --no-env-fog --decals=N --screenshot=PATH --props=N --no-cull

# Visual editor (gizmos + debug overlay + shadows + docking)
dub run --config=editor

# Optimized release builds
dub build --config=demo --build=release
dub build --config=benchmark --build=release
```

## Antialiasing and Sharpening

`PostSettings.aaMode` selects the filter applied to the tone-mapped image. Every mode is a single-frame
filter: nothing accumulates between frames. Pipelines and targets are created on first use.

| `AaMode` | Filter | Cost at 1920x1080 (RX 6600) |
|---|---|---|
| `legacy` (default) | `fxaa` when `PostSettings.fxaa` is on, otherwise `off` | — |
| `off` | None: tone map writes the display target | 0 |
| `fxaa` | Original short-blur FXAA | 0.05 ms |
| `fxaaQuality` | FXAA with edge-end search (12 steps each way). `fxaaSubpix` (0..1) sets the smoothing of thin features, `fxaaEdgeThreshold` the minimum relative contrast | 0.09 ms |

`PostSettings.sharpness` (0..1) runs contrast adaptive sharpening (`post_cas.wgsl`) after any mode, including
`off`; 0 skips the pass and 0.05 ms. Profiler zones: `gpu.post.fxaa`, `gpu.post.fxaaQuality`,
`gpu.post.sharpen` (CPU: `post.*`). In the `render-check` scene the edge error is 0.31 px without AA, 0.10 px
with `fxaa` and 0.05 px with `fxaaQuality`.

## Post pass inputs (`PostPassDesc`)

`Renderer.addPostPass(PostPassDesc)` adds a fullscreen pass that can read the scene and write intermediate targets. The older `addPostPass(wgsl, uniformBytes, stage)` is unchanged.

```d
PostPassDesc fog;
fog.wgsl = fogWgsl;                 // fs_main; helpers below are in scope
fog.stage = PostStage.beforeTonemap;
fog.sceneInputs = true;
fog.output = "fog"; fog.scale = 2;  // half resolution, rgba16Float
app.renderer.addPostPass(fog);

PostPassDesc composite;
composite.wgsl = compositeWgsl;     // reads input0 and srcTex
composite.stage = PostStage.beforeTonemap;
composite.inputs[0] = "fog";
app.renderer.addPostPass(composite);
```

| Available with `sceneInputs` (`common/post_scene.wgsl`, `@group(1)`) | |
|:---|:---|
| `sceneCamera` | `view`, `proj`, `viewProj` and their inverses, `position` (w = `setTime` seconds), `planes` (near, far, z = 1 when a scene was drawn this frame), `viewport` |
| `sceneDepthTex`, `sceneDepth(uv)`, `sceneDepthAt(pixel)` | scene depth, 1 = nothing drawn |
| `sceneLinearDepth(depth)` | distance along the view axis |
| `sceneViewPosition(pixel)`, `sceneWorldPosition(pixel)` | position of a depth texel (`scenePixel(uv)`) |
| `sceneViewNormal(pixel)`, `sceneWorldNormal(pixel)` | normal rebuilt from depth: on each axis the neighbor closest in depth. Geometric only, flat per triangle, no normal maps |
| `input0` to `input3` | named targets, in the order of `inputs` |

- Passes of a stage run in insertion order. A pass with `output` does not touch the picture.
- `inputs` must be written by a pass added earlier; otherwise `addPostPass` returns 0. A disabled writer leaves its last content, and a removed one reads as black.
- Target formats: `r8Unorm`, `rg8Unorm`, `rgba8Unorm`, `r16Float`, `rg16Float`, `rgba16Float`. Up to 8 targets, created on first use and recreated on resize.
- The depth is the final scene depth: transparent surfaces that do not write depth are not in it. In `afterUi` it is still the 3D scene's.
- With several scenes in a frame, the camera is the last one ended. World positions lose precision far from the origin (32-bit matrices, 24-bit depth).
- Cost when unused: none. `gpu.post.customBeforeTonemap`, `gpu.post.customAfterTonemap` and `gpu.post.afterUi` time the passes.

Verification: `dub run --config=render-check -- --check=passinputs`.
