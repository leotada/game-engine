# Plan: Post-Processing

> **Status:** completed · Priority: medium · See [roadmap.md](roadmap.md)

## Objective

Offscreen post-processing pipeline: render the 3D scene into an intermediate HDR color target (`rgba16float`), followed by fullscreen passes (dual-filter bloom, ACES tone mapping, FXAA) before presenting to the SDR swapchain.

## Current State

Repository paths:

- [`source/engine/gpu/renderer.d`](../source/engine/gpu/renderer.d) — `beginFrame` → HDR offscreen target; `resolvePost` → bloom/tonemap/FXAA → swapchain; `endFrame` present. Scene depth format is `depth24Plus`.
- [`source/engine/gpu/post.d`](../source/engine/gpu/post.d) — `PostProcessor` + `PostSettings` (exposure, bloom, fxaa, tonemapMode).
- [`source/engine/gpu/shaders.d`](../source/engine/gpu/shaders.d) and `assets/shaders/post_*.wgsl` — fullscreen triangle + threshold/downsample/upsample/tonemap/FXAA WGSL shaders.
- PBR fragment shader: unclamped HDR (`max(0)` only); tone map compresses to SDR.

Frame execution order:

```
shadow depth pass (optional) → scene color HDR offscreen (+ depth)
  → bloom (when enabled) → tone map → FXAA → UI/text in present pass → present
```

## Out of Scope

- Screen-Space Reflections (SSR), Ambient Occlusion (SSAO), Temporal Anti-Aliasing (TAA)
- Visual post-processing stack editor ([plan-editor-ux.md](plan-editor-ux.md))
- Native monitor HDR10 swapchains

## Dependencies

- None. Reuses established patterns from `shadow.d` and `pipeline.d`.

## Phases

### PP-1 — Offscreen HDR Color + Scene Depth

- [x] HDR color texture matching window dimensions (`rgba16float`)
- [x] Resized alongside depth buffer in `Renderer.resize`
- [x] Scene3D / Scene3DTextured / gizmos render directly into the offscreen target (`Renderer.sceneFormat()`)

**DoD:** Scene color attachment is no longer the surface texture.

### PP-2 — Fullscreen Triangle Pass

- [x] Vertex shader for fullscreen triangle (no vertex buffer required)
- [x] `resolvePost`: closes HDR pass, executes post-processing, reopens present pass on the swapchain for UI

**DoD:** Final scene image reaches the swapchain surface via post-processing pipeline.

### PP-3 — Tone Mapping

- [x] Uniforms: exposure + operator mode (ACES Narkowicz default; Reinhard)
- [x] PBR color clamping removed; internal HDR mapped to SDR in tone mapping pass

**DoD:** Adjusting exposure at runtime changes image brightness (`+/-` keys in `pbr` demo).

### PP-4 — Bloom

- [x] Threshold + downsample + upsample (dual-filter chain)
- [x] Additive blend into tone mapping pass (`bloomStrength`)
- [x] Toggleable via `PostSettings.bloom`

**DoD:** Bloom can be toggled on/off at runtime (`B` key in `pbr` demo).

Quality and anti-firefly notes:
- Threshold utilizes a soft knee curve + `bloomClamp` (default 8.0) to suppress extreme HDR spikes.
- First downsampling pass uses **Karis average** weighting; subsequent mip levels use 13-tap box filtering.
- Direct specular GGX highlights in PBR are soft-clamped to 16.0.
- Defaults: `threshold=1.2`, `knee=0.7`, `strength=0.12`, `bloomClamp=8.0`.

### PP-5 — FXAA

- [x] FXAA applied to the final LDR image after tone mapping
- [x] Runtime toggle in `PostSettings.fxaa`

**DoD:** `F` key in `pbr` demo toggles FXAA anti-aliasing.

### PP-6 — Gameplay API & Settings

- [x] `PostSettings` exposed on `Renderer` and `App.post`
- [x] `pbr` demo features keyboard controls; other demos use sane defaults + `resolvePost`

**DoD:** Games configure post-processing effects without editing WGSL code.

## Acceptance Criteria

1. Scene renders through offscreen HDR without visual or performance regressions.
2. Tone mapping, bloom, and FXAA are independently toggleable.
3. Frame execution loop remains strictly `@nogc` inside GPU core.
4. Window resizing reallocates render targets cleanly without leaks (`Renderer.resize`).
5. UI and text overlay render into the final present pass (following `resolvePost`).

## References

- `source/engine/gpu/renderer.d`, `post.d`, `shadow.d`, `pipeline.d`
- [plan-pbr.md](plan-pbr.md) — internal HDR unlocks unclamped IBL reflections
- [graphics.md](graphics.md)
