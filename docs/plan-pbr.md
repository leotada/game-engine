# Plan: PBR (Metallic / Roughness + IBL)

> **Status:** completed · Priority: medium · See [roadmap.md](roadmap.md)

## Objective

Extend the initial shading model (Lambert N·L + albedo) to full metallic-roughness (glTF 2.0 specification) with Image-Based Lighting (irradiance + prefiltered specular + BRDF LUT), preserving instancing and the `Material` / `Scene3DTextured` API. Includes sampling the existing shadow map (PCF) in the lit fragment path.

## Current State

Repository paths:

- Textured shader: **Cook-Torrance GGX + IBL + PCF** (HDR output, no clamp) ([`source/engine/gpu/shaders.d`](../source/engine/gpu/shaders.d) and `assets/shaders/textured3d_pbr.wgsl`)
- [`Material`](../source/engine/graphics/material.d) = `@group(1)` bind group with `MaterialParams` UBO + sampler + albedo + optional maps (bound with default 1×1 textures)
- [`ShadowMap`](../source/engine/gpu/shadow.d) = depth pass + comparison sampler; sampled in the textured path via `Scene3DTextured.setLighting`
- [`IblEnvironment`](../source/engine/gpu/ibl.d) = procedural cubemap + irradiance + specular mips + BRDF LUT (`@group(2)`)
- [`assets/gltf.d`](../source/engine/assets/gltf.d) = mesh + `pbrMetallicRoughness` (factors + BMP/TGA maps); example asset in `assets/models/pbr_cube.gltf`

Color pipeline: Scene renders offscreen in **`rgba16float`**; tone mapping ACES + bloom + FXAA in [plan-post-processing.md](plan-post-processing.md). Present format is SDR (`bgra8Unorm` / `rgba8Unorm`).

## Out of Scope

- Clearcoat / sheen / transmission (advanced glTF extensions)
- Dynamic area lights / real-time probe volumes (v1 = static IBL + directional/point/spot lights)
- Soft shadows beyond 3×3 PCF filtering

## Dependencies

- **Pre-requisite:** Phase PBR-0 (shadowed lit) utilizes `ShadowMap`
- **Post-Processing:** [plan-post-processing.md](plan-post-processing.md) PP-1–6 delivered — HDR + ACES tone mapping unlock unclamped IBL reflections

## Phases

### PBR-0 — Shadowed Lit (Lambert + PCF)

- [x] Sample `shadow.depthView` + comparison sampler in textured fragment shader
- [x] Bind light VP + shadow resources in frame bind group (`setLighting`)
- [x] Minimal demo using `ShadowMap.create(gpu, resolution)`

**DoD:** Visible shadows in the standard pipeline; API = `ShadowMap.create(gpu, resolution)` + `beginShadowPass` / `endShadowPass` / `directionalLightVP`.

### PBR-1 — Material Model

- [x] Uniform: `metallic`, `roughness`, `baseColorFactor`, flags
- [x] Optional textures: metallicRoughness, normal, occlusion, emissive
- [x] Backward-compatible "albedo-only" path for simple demos

**DoD:** Material without extra texture maps renders identically to previous baseline (+ shadows).

### PBR-2 — BRDF Shader Implementation

- [x] WGSL: Cook-Torrance GGX + energy-conserving diffuse
- [x] Validate using metal/dielectric sphere grid (roughness 0 → 1)

**DoD:** 5×2 sphere grid (metal/dielectric × roughness) validated in the `pbr` demo.

### PBR-3 — Image-Based Lighting (IBL)

- [x] Procedural sky → cubemap generation (no mandatory external HDR files)
- [x] Precompute irradiance + specular mips + BRDF LUT at startup
- [x] Bind groups: environment cubemap + LUT (`@group(2)`)

**DoD:** Smooth metallic sphere (roughness=0) mirrors the procedural environment stably.

### PBR-4 — glTF Materials Loader

- [x] Extend `assets/gltf.d` to parse `pbrMetallicRoughness` + textures
- [x] Graceful fallback when assets lack specific texture channels

**DoD:** glTF PBR model under `assets/` loads with full textures automatically.

### PBR-5 — Scene Integration & Demo

- [x] Updated `Scene3DTextured` / Material API (`setLighting`, `setEnvironment`)
- [x] `pbr` demo: PBR-2 spheres + glTF model + shadows + IBL

**DoD:** `dub run --config=pbr`, `dub run --config=showcase`, and `editor` run cleanly.

## Acceptance Criteria

1. Metallic-roughness shading renders accurately with and without IBL.
2. PCF shadow filtering in the standard lit path.
3. Standard glTF PBR assets load without manual pipeline adjustments.
4. Existing albedo/checker demos remain 100% backward-compatible.
5. Post-processing integration: internal HDR scene + ACES tone mapping to SDR swapchain.

## References

- `source/engine/gpu/shaders.d`, `graphics/material.d`, `assets/gltf.d`, `gpu/shadow.d`, `gpu/ibl.d`
- [graphics.md](graphics.md)
- [plan-post-processing.md](plan-post-processing.md)
