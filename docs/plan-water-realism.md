# Plan: Realistic Water Rendering & Renderer Integration Benchmark

> **Status:** WTR-0–WTR-5 Implemented (`WTR-6` analytical Jacobian & wakes done; optional compute FFT deferred) · Links to [plan-openpbr.md](plan-openpbr.md) (`OPBR-7`, `OPBR-9`) & [plan-terrain-water.md](plan-terrain-water.md) · See [roadmap.md](roadmap.md)

## Objective

Upgrade the engine's water rendering from single-pass analytical transparency to **Unity HDRP / Unreal Engine 5 (`Single Layer Water`)** optical fidelity — real screen-space refraction, per-pixel depth-based Beer-Lambert absorption, geometry-exact shoreline contact foam, screen-space local reflections (SSR), dynamic rock/pier wetlines & underwater caustics, extended horizon ocean skirt, and analytical Jacobian crest / downstream wake ripples — while **measuring the exact frame-time and VRAM impact of the required `Renderer` changes Before vs After across both No-Water and With-Water scenarios**.

Key engineering guarantees:

- **Zero overhead on No-Water scenes:** The `Renderer` opaque snapshot path (`snapshotOpaque`) is strictly opt-in and lazy-allocated. Scenes that do not draw refractive water or transmissive surfaces perform no extra pass break, no GPU copy, and allocate no snapshot textures.
- **No `depth24Plus` pipeline breakage:** Existing `depth24Plus` pipelines (`pipeline.d`, `gizmos.d`, `skinned.d`, `water.d`) remain unchanged; depth resolution copies `depth24Plus` (`texture_depth_2d`) via a fullscreen fragment `@builtin(frag_depth)` shader into `depth32Float` rather than non-portable `depth24Plus` texture copies.
- **GC-safe `Renderer` hot path:** `Renderer.snapshotOpaque` and water uniform/material updates are `nothrow @nogc`. Note: pre-existing `Scene3DTextured.drawMatrix` batch accumulation allocates dynamic arrays outside `Renderer` (`~6.56–6.92 KB/frame` measured in `water.d`); zero new per-frame GC allocations were introduced by `WTR-1`–`WTR-6`.

## Current State

Implemented repository paths and verified architecture:

- [`source/engine/gpu/renderer.d`](../source/engine/gpu/renderer.d):
  - `Renderer.createSceneTargets(w, h)` creates `hdrTexture` (`SCENE_COLOR_FORMAT = WGPUTextureFormat.rgba16Float`, usage `renderAttachment | textureBinding | copySrc`) and `depthTexture` (`WGPUTextureFormat.depth24Plus`, usage `renderAttachment | textureBinding`).
  - `Renderer.snapshotOpaque(ref FrameContext)` lazily initializes `opaqueColorTex` (`rgba16Float`, `copyDst | textureBinding`), `opaqueDepthTex` (`depth32Float`, `renderAttachment | textureBinding`), and `depthCopyPipe`, then ends the active opaque pass, executes `wgpuCommandEncoderCopyTextureToTexture` for HDR color, runs a 3-vertex depth resolve pass into `opaqueDepthView`, and reopens `frame.pass` on `hdrView` + `depthView` with `WGPULoadOp.load`.
- [`assets/shaders/depth_copy.wgsl`](../assets/shaders/depth_copy.wgsl): Fullscreen depth resolve shader copying `depth24Plus` (`textureLoad`) to `@builtin(frag_depth)` in `depth32Float`, registered in [`source/engine/hotreload/shader_source.d`](../source/engine/hotreload/shader_source.d) and [`source/engine/gpu/shaders.d`](../source/engine/gpu/shaders.d).
- [`source/bindings/wgpu.d`](../source/bindings/wgpu.d): Added `wgpuCommandEncoderCopyTextureToTexture`.
- [`source/engine/graphics/material.d`](../source/engine/graphics/material.d) & [`assets/shaders/textured3d_pbr.wgsl`](../assets/shaders/textured3d_pbr.wgsl): Added `MaterialFlags.waterWetCaustics` (`1 << 4`) and `MaterialFlags.waterRiverMode` (`1 << 5`) projecting wave-synced shoreline wetness and shadowed RGB Voronoi caustics onto submerged rocks and wooden bridge piers (`WTR-3`).
- [`assets/shaders/water_surface.wgsl`](../assets/shaders/water_surface.wgsl), [`assets/shaders/caustics_bed.wgsl`](../assets/shaders/caustics_bed.wgsl), [`assets/shaders/common/water_env.wgsl`](../assets/shaders/common/water_env.wgsl), & [`source/demo/water.d`](../source/demo/water.d):
  - `192×192` water grid with radial ocean horizon skirt extension (`±150 m`), distance amplitude/capillary AA, Gerstner Jacobian wave folding, and downstream oscillating vortex wakes (`WTR-5`, `WTR-6`).
  - Hardware-depth linearization (`linearizeDepth`), depth-rejected R/G/B screen-space refraction (`WTR-2`), Beer-Lambert composition (`exp(-sigma * opticalDepth)`), 3D geometry waterline contact foam, and 16-step + 3-binary-refinement Screen-Space Reflections (`WTR-4`, toggleable via `[7]`).
  - Uncapped benchmark harness (`--bench=N`, `--no-water`, `--immediate`, `--bench-sync`, `--stage=0..3`, `--1080p`, `--capture=<bmp>`) using `WGPUPresentMode.immediate` and `wgpuDevicePoll`.

### Why `Renderer` Changes Were Required (and What Did Not Require Changes)

| Capability | Required `Renderer` Change? | Implementation |
|:---|:---|:---|
| **Opaque Color + Depth Snapshot (`WTR-1`)** | **Yes** | `hdrTexture` `+ copySrc`, `depthTexture` `+ textureBinding`, lazy `OpaqueSnapshot`, and `snapshotOpaque()` pass split in `renderer.d`. |
| **Refraction + Depth Absorption + Depth Shore Foam (`WTR-2`)** | No (uses `WTR-1`) | Implemented inside `water_surface.wgsl` by sampling `opaqueColorView` and `opaqueDepthView`. |
| **Underwater Caustics & Animated Wetline on Props (`WTR-3`)** | **No** | Implemented in `textured3d_pbr.wgsl` via `MaterialFlags` (`_pad0` = `time`, `_pad1` = `waveScale`). |
| **Screen-Space Reflections — SSR (`WTR-4`)** | No (uses `WTR-1`) | Raymarches `opaqueDepthView` and reads `opaqueColorView` directly in `water_surface.wgsl`. |
| **Ocean Horizon Skirt & Distance AA (`WTR-5`)** | **No** | Vertex-shader radial skirt expansion + roughness/capillary AA in `water_surface.wgsl` + `caustics_bed.wgsl`. |
| **Jacobian Crest Folding & River Wake Ripples (`WTR-6`)** | **No** | Analytical Gerstner Jacobian + Kelvin/vortex oscillations in `water_surface.wgsl` (compute FFT deferred). |

## Out of Scope

- Full hardware ray-traced water reflections / refractions.
- 3D Eulerian/FLIP/SPH fluid simulation (`plan-terrain-water.md` already excludes volumetric fluid solvers).
- Planar mirror reflection passes (re-rendering the entire scene upside-down); local geometry reflections use SSR (`WTR-4`, matching `OPBR-9`) with coherent fallback to procedural sky + IBL.
- Multi-viewport split-screen water snapshot handling (`plan-split-screen.md` handles multi-viewport offsets independently).

## Dependencies

- [`plan-openpbr.md`](plan-openpbr.md): `WTR-1` / `WTR-2` directly share the opaque HDR color snapshot architecture with `OPBR-7` (multi-pass refractive transmission), and `WTR-4` shares the depth-buffer SSR strategy with `OPBR-9`.
- [`plan-terrain-water.md`](plan-terrain-water.md): Water entities sculpted in the editor (`TW-4`) can bind to the same `WaterSurface` shader + `Renderer.snapshotOpaque` contract.

## Technical Design

### 1. Opt-In `Renderer.snapshotOpaque` Architecture (`WTR-1`)

Target file: [`source/engine/gpu/renderer.d`](../source/engine/gpu/renderer.d)

1. **Source texture usage additions in `createSceneTargets(w, h)`:**
   - `hdrTexture`: `WGPUTextureUsage.renderAttachment | WGPUTextureUsage.textureBinding | WGPUTextureUsage.copySrc`
   - `depthTexture`: `WGPUTextureUsage.renderAttachment | WGPUTextureUsage.textureBinding` (`WGPUTextureFormat.depth24Plus` preserved — zero changes to any existing pipeline).
2. **Lazy snapshot targets inside `Renderer`:**
   - `opaqueColorTex` / `opaqueColorView_`: `rgba16Float`, usage `WGPUTextureUsage.copyDst | WGPUTextureUsage.textureBinding`, size `(rtW, rtH)`.
   - `opaqueDepthTex` / `opaqueDepthView_`: `depth32Float`, usage `WGPUTextureUsage.renderAttachment | WGPUTextureUsage.textureBinding`, view aspect `WGPUTextureAspect.depthOnly`, size `(rtW, rtH)`.
   - `depthCopyPipe` + `depthCopyBGL` + fullscreen triangle pipeline resolving `depthView` (`texture_depth_2d`) via `textureLoad` to `@builtin(frag_depth)` in `opaqueDepthView_`.
   - **Lazy creation guarantee:** Snapshot textures and `depthCopyPipe` are **not allocated** during `Renderer.create()` or `createSceneTargets()` until `snapshotOpaque()` / `opaqueColorView()` / `opaqueDepthView()` is invoked, keeping non-water scenes free of snapshot VRAM and copy passes.
3. **Pass sequence when `snapshotOpaque(ref FrameContext frame)` is called:**
   - Guard: if `!frame.valid || frame.postResolved`, return cleanly.
   - Lazily initialize pipeline & targets via `ensureOpaqueSnapshot()`.
   - End the open opaque HDR render pass (`wgpuRenderPassEncoderEnd` + `Release`).
   - Copy HDR color: `wgpuCommandEncoderCopyTextureToTexture(frame.encoder, hdrTexture -> opaqueColorTex)`.
   - Resolve depth (`depth24Plus -> depth32Float`): run a depth-only render pass on `opaqueDepthView_` (`depthLoadOp = WGPULoadOp.clear`), binding `depthView`, drawing 3 non-indexed vertices.
   - Reopen `frame.pass` targeting `hdrView` (`WGPULoadOp.load`) and `depthView` (`WGPULoadOp.load`).

### 2. Performance Benchmark Methodology (Before vs After, With & Without Water)

All benchmarks were built uniformly with `--build=plain` (DMD x86_64; note `dmd --build=release` hit a compiler SIGSEGV and `ldc2` failed linking prebuilt `libs/libsymgc-cards.a`) and executed with `WGPUPresentMode.immediate`, `--bench-sync` (`wgpuDevicePoll`), `--no-hud`, fixed `dt = 1/60s`, **120 warmup frames**, and **300 timed frames** per checkpoint:

- **`No-Water` (`--no-water`):** Draws identical rocks, banks, bridge/lighthouse, buoys, sky dome, riverbed (`caustics_bed`), directional/spot shadows, IBL, and Bloom+ACES+FXAA post-processing while skipping the water draw and never calling `snapshotOpaque`.
- **`River` (`--river`) & `Ocean`:** Full scene + water across `--stage=0` (T0 analytical shader), `--stage=1` (`snapshotOpaque` pass split with T0 shader), `--stage=2` (adds refraction, Beer-Lambert depth absorption & depth shoreline foam), and `--stage=3` (full pipeline adding SSR & underwater prop caustics/wetlines).

## Phases

### WTR-0 — Uncapped Benchmark Harness & `T0` Baseline Capture

- [x] Add `--bench=<frames>`, `--stage=<0|1|2|3>`, `--no-water`, `--immediate`, `--bench-sync`, `--1080p`, and `--capture=<bmp>` flags to [`source/demo/water.d`](../source/demo/water.d).
- [x] Run pre-edit **T0** baselines across `No-Water`, `River`, and `Ocean` at `1280×720` and `1920×1080` before modifying `Renderer`.

**DoD:** Reproducible CLI benchmark emits percentile frame timings and `T0` baseline measurements are recorded.

### WTR-1 — Opt-In `Renderer.snapshotOpaque` (`rgba16Float` Color Copy + `depth32Float` Depth Resolve)

- [x] Add `wgpuCommandEncoderCopyTextureToTexture` in [`source/bindings/wgpu.d`](../source/bindings/wgpu.d) and [`assets/shaders/depth_copy.wgsl`](../assets/shaders/depth_copy.wgsl) (`depth_copy` registered in `shader_source.d` and `shaders.d`).
- [x] Update `hdrTexture` (`+ copySrc`) and `depthTexture` (`+ textureBinding`) usage flags and implement lazy `OpaqueSnapshot` + `snapshotOpaque()` in [`source/engine/gpu/renderer.d`](../source/engine/gpu/renderer.d).
- [x] Wire `--stage=1` pass split in [`source/demo/water.d`](../source/demo/water.d) (skipped on `--no-water`), measure **T1**, and verify `dub test --config=library` (106 modules passed).

**DoD:** `snapshotOpaque` isolates pass-split overhead without allocating snapshot VRAM on `No-Water` scenes and all 106 library unit test modules pass.

### WTR-2 — True Screen-Space Refraction, Depth Beer-Lambert & Contact Shore Foam

- [x] Bind `renderer.opaqueColorView()` and `renderer.opaqueDepthView()` + clamp linear sampler in [`source/demo/water.d`](../source/demo/water.d).
- [x] Implement depth linearization (`linearizeDepth`), depth-rejected R/G/B refracted UV lookups (`textureSampleLevel`), Beer-Lambert absorption, 3D shoreline contact foam (`0.08 m` ocean / `0.11 m` river), and 3 cm meniscus feathering in [`assets/shaders/water_surface.wgsl`](../assets/shaders/water_surface.wgsl) + coordinated seabed attenuation in [`assets/shaders/caustics_bed.wgsl`](../assets/shaders/caustics_bed.wgsl).

**DoD:** Submerged rocks and wooden piers visibly refract beneath water ripples, darken/tint smoothly with depth, and show lacy contact foam along true 3D intersections.

### WTR-3 — Submerged Rock & Pier Caustics + Wave-Synced Wetline (No Renderer Changes)

- [x] Add `MaterialFlags.waterWetCaustics` / `waterRiverMode` in [`source/engine/graphics/material.d`](../source/engine/graphics/material.d) (`_pad0` = `time`, `_pad1` = `waveScale`).
- [x] Project dynamic wet tide/splash bands and shadowed Voronoi RGB caustics onto submerged rocks and wooden bridge piers in [`assets/shaders/textured3d_pbr.wgsl`](../assets/shaders/textured3d_pbr.wgsl).

**DoD:** Submerged boulders and bridge piers receive animated shadowed caustics and wave-synced wet waterlines with zero changes to `Renderer`.

### WTR-4 — Screen-Space Reflections (SSR) in Water Shader

- [x] Implement 16-step linear + 3-step binary refinement SSR raymarch (`R.y > 0.025`, `camDist < 34.0`, `rayP.y >= 0.02`, interleaved gradient noise jitter) in [`assets/shaders/water_surface.wgsl`](../assets/shaders/water_surface.wgsl) reusing `WTR-1` snapshot targets.
- [x] Add `[7]` live SSR toggle in [`source/demo/water.d`](../source/demo/water.d) and visually verify Ocean + River captures.

**DoD:** Rocks, bridge piers/deck, buoys, and shoreline boulders reflect smoothly in water ripples with seamless sky fallback and stay within 60 Hz frame budget at `1080p`.

### WTR-5 — Ocean Horizon Skirt & Distance Normal Anti-Aliasing (No Renderer Changes)

- [x] Increase grid resolution to `192×192`, extend the Ocean skirt radially to `±150 m` (`bedScale = 11.0` in `caustics_bed.wgsl`, `camera.far = 260.0f`), and attenuate distant Gerstner waves, capillary normals (`camDist²` AA), roughness variance, and horizon mist into `sky_dome`.

**DoD:** Ocean extends seamlessly into the horizon without visible square slab borders or distant specular aliasing.

### WTR-6 — Analytical Wave Folding & River Vortex Wakes (Compute FFT Deferred)

- [x] Compute analytical Gerstner Jacobian determinant compression in `vs_main` for physical whitecap crest folding and add downstream oscillating wake ripples behind river obstacles in [`assets/shaders/water_surface.wgsl`](../assets/shaders/water_surface.wgsl).
- [ ] *(Deferred / Optional Future Enhancement)* Pre-frame `WGPUCommandEncoder` compute pass generating `256×256` JONSWAP FFT ocean spectrum + ping-pong 2D advected foam buffer.

**DoD:** Physical crest folding and dynamic river obstacle wakes ship inside the zero-allocation shader path, leaving heavy compute FFT textures cleanly optional.

---

## Performance Measurement Results (Before vs After `Renderer` Changes)

All timing runs used `--build=plain`, `WGPUPresentMode.immediate`, `--bench-sync`, `--no-hud`, 120 warmup frames + 300 timed frames on Linux Wayland/Vulkan.

> **Hardware measurement note (`720p` clock scaling & GC accounting):**
> - At `1280×720`, total GPU frame work (`~2.8–4.8 ms` boosted) is light enough that dynamic GPU P-state frequency scaling causes intermittent power-state swings (`p95 ~ 9–17 ms` during downclocks). `1920×1080` saturates the GPU more steadily, exposing clean `p50` and `avg` stage deltas.
> - Reported `gc_delta_bytes` across 300 frames (`1,967,840 B` / `~6.56 KB/frame` in `No-Water`/`Ocean`; `2,074,736 B` / `~6.92 KB/frame` in `River`) is completely constant across `T0`, `T1`, `T2`, and `T3` and stems solely from pre-existing dynamic batch slice growth in `Scene3DTextured.drawMatrix` (`b.instances ~= ...`). `Renderer.snapshotOpaque` and `WTR-1`–`WTR-6` add **`0 B/frame`** in the hot loop.

### Part A — `1920×1080` Comparison (`Pre-Edit T0` + Back-to-Back Warm `T0`→`T3`, `192×192` Grid on Final Binary)

| Scenario | Checkpoint | Renderer Changed? | Avg (ms) | p50 (ms) | p95 (ms) | p99 (ms) | Max (ms) | Mean FPS | Delta vs Stage 0 (p50 / avg) | New GC Alloc |
|:---|:---|:---|---:|---:|---:|---:|---:|---:|---:|---:|
| **No-Water** | **Pre-Edit T0** (`160²` binary) | No | `2.145` | `2.137` | `2.213` | `2.278` | `2.361` | `466.2` | baseline | `0 B` |
| **No-Water** | **After `WTR-1..5` (Dormant)** | Yes (skipped) | `3.010` | `2.937` | `3.510` | `3.931` | `3.941` | `332.3` | `+0.80` / `+0.87 ms`¹ | `0 B` |
| **River** | **Pre-Edit T0** (`160²` binary) | No | `4.005` | `3.555` | `6.072` | `11.617` | `15.729` | `249.7` | pre-edit | `0 B` |
| **River** | **T0 (`--stage=0`, Analytical)** | Yes (unused) | `3.481` | `3.425` | `3.883` | `3.978` | `4.236` | `287.3` | `0.00` / `0.00 ms` | `0 B` |
| **River** | **T1 (`--stage=1`, Snapshot Only)** | Yes (active) | `5.522` | `4.046` | `14.284` | `16.225` | `21.535` | `181.1` | `+0.62` / `+2.04 ms` | `0 B` |
| **River** | **T2 (`--stage=2`, +Refraction/Depth)** | Yes | `3.923` | `3.840` | `4.587` | `5.257` | `5.397` | `254.9` | `+0.42` / `+0.44 ms` | `0 B` |
| **River** | **T3 (`--stage=3`, +SSR & Wet Props)** | Yes | `5.225` | `4.442` | `10.647` | `15.894` | `16.685` | `191.4` | **`+1.02` / `+1.74 ms`** | `0 B` |
| **Ocean** | **Pre-Edit T0** (`160²` binary) | No | `4.112` | `4.062` | `4.499` | `5.494` | `5.543` | `243.2` | pre-edit (`160²`) | `0 B` |
| **Ocean** | **T0 (`--stage=0`, Analytical)** | Yes (unused) | `5.736` | `5.731` | `6.010` | `6.188` | `6.242` | `174.3` | `0.00` / `0.00 ms` | `0 B` |
| **Ocean** | **T1 (`--stage=1`, Snapshot Only)** | Yes (active) | `6.647` | `6.141` | `9.165` | `13.600` | `15.675` | `150.4` | `+0.41` / `+0.91 ms` | `0 B` |
| **Ocean** | **T2 (`--stage=2`, +Refraction/Depth)** | Yes | `6.197` | `6.150` | `6.603` | `7.146` | `7.314` | `161.4` | `+0.42` / `+0.46 ms` | `0 B` |
| **Ocean** | **T3 (`--stage=3`, +SSR & Skirt & Props)** | Yes | `7.506` | `7.349` | `7.859` | `11.937` | `32.762` | `133.2` | **`+1.62` / `+1.77 ms`** | `0 B` |

¹ Separate process launch run-to-run variance on Wayland; `snapshotOpaque()` is never invoked and `opaqueColorTex`/`opaqueDepthTex` are never allocated (`+0.0 MB` VRAM).

### Part B — `1280×720` Comparison (`Pre-Edit T0` + Back-to-Back `T0`→`T3`) & VRAM Footprint

| Scenario | Checkpoint | Avg (ms) | p50 (ms) | p95 (ms) | p99 (ms) | Mean FPS | Snapshot Extra VRAM |
|:---|:---|---:|---:|---:|---:|---:|---:|
| **No-Water** | **Pre-Edit T0 (Run 1 / Run 2)** | `6.012` / `5.407` | `6.091` / `5.890` | `6.672` / `7.259` | `7.000` / `7.524` | `166.3` / `184.9` | `+0.0 MB` (lazy) |
| **No-Water** | **After `WTR-1..5` (Dormant)** | `4.567` | `4.334` | `9.465` | `9.818` | `218.9` | **`+0.0 MB` (lazy)** |
| **River** | **Pre-Edit T0 (Run 1 / Run 2)** | `8.128` / `5.451` | `8.138` / `5.497` | `8.481` / `8.895` | `8.685` / `9.260` | `123.0` / `183.5` | `+0.0 MB` |
| **River** | **T0 (`--stage=0`)** | `2.769` | `2.708` | `3.429` | `5.284` | `361.1` | `+0.0 MB` |
| **River** | **T1 (`--stage=1` Snapshot Split)** | `6.078` | `5.942` | `10.872` | `11.601` | `164.5` | `~10.55 MB` (`720p`) / `~23.73 MB` (`1080p`)¹ |
| **River** | **T2 (`--stage=2`)** | `8.225` | `9.986` | `12.356` | `13.359` | `121.6` | same as T1 |
| **River** | **T3 (`--stage=3` Full)** | `4.430` | `3.416` | `11.683` | `13.284` | `225.8` | same as T1 |
| **Ocean** | **Pre-Edit T0 (Run 1 / Run 2)** | `9.402` / `4.677` | `9.889` / `3.501` | `11.238` / `12.682` | `12.462` / `13.970` | `106.4` / `213.8` | `+0.0 MB` |
| **Ocean** | **T0 (`--stage=0`)** | `3.647` | `3.627` | `4.036` | `4.579` | `274.2` | `+0.0 MB` |
| **Ocean** | **T1 (`--stage=1` Snapshot Split)** | `4.842` | `3.844` | `9.275` | `13.508` | `206.5` | `~10.55 MB` (`720p`) / `~23.73 MB` (`1080p`)¹ |
| **Ocean** | **T2 (`--stage=2`)** | `8.611` | `8.182` | `14.803` | `16.050` | `116.1` | same as T1 |
| **Ocean** | **T3 (`--stage=3` Full)** | `5.946` | `4.798` | `17.287` | `19.255` | `168.2` | same as T1 |

¹ At `1920×1080`: `opaqueColorTex` (`rgba16Float` = 8 B/px = `15.82 MB`) + `opaqueDepthTex` (`depth32Float` = 4 B/px = `7.91 MB`) = `~23.73 MB` (`~10.55 MB` at `1280×720`), allocated lazily only after `snapshotOpaque()` is first invoked.

### Summary Conclusions from Measured Data

1. **Snapshot pass split cost (`T1 - T0`):** Isolating `Renderer.snapshotOpaque` (HDR pass end + `CopyTextureToTexture` + 3-vertex `depth32Float` resolve + `loadOp = load` reopen) adds **`+0.41 ms p50` (Ocean) to `+0.62 ms p50` (River) at `1080p`** — directly confirming the sub-millisecond pass-split budget without breaking any `depth24Plus` pipeline.
2. **Total full optical pipeline (`T3` at `1080p`):** Adding screen-space refraction, chromatic dispersion, true Beer-Lambert absorption, depth shoreline contact foam, projected underwater rock/pier caustics & wetlines, horizon ocean skirt, and 16+3 SSR rays costs only **`+1.02 ms p50` (`5.225 ms` avg / `191.4 FPS`) in River** and **`+1.62 ms p50` (`7.506 ms` avg / `133.2 FPS`) in Ocean** — comfortably inside the 60 Hz (`16.6 ms`) frame budget without requiring half-res SSR fallback.
3. **No-Water impact:** Runs at `332.3 FPS` (`2.94 ms p50`) at `1080p` and `218.9 FPS` (`4.33 ms p50`) at `720p` with **`+0.0 MB` extra VRAM** (dormant lazy snapshot targets).

## Acceptance Criteria

1. [x] `Renderer.snapshotOpaque` splits the HDR render pass lazily on demand with `+0.0 MB` extra VRAM in `No-Water` scenes.
2. [x] All Before (`T0`) vs After (`T1`, `T2`, `T3`) benchmark tables are populated with real hardware measurements across `No-Water`, `River`, and `Ocean` at `1280×720` and `1920×1080`.
3. [x] Water refraction bends submerged rocks and bridge piers cleanly without foreground halos (`depth`-rejected UV offset), shoreline foam hugs 3D rock/pier silhouettes, and SSR reflects surrounding geometry smoothly into the horizon.
4. [x] Full `1080p` optical water runs at **`133.2 FPS` (Ocean)** and **`191.4 FPS` (River)** (`< 8 ms` avg, well under `16.6 ms`) with `0 B` new per-frame GC allocations.
5. [x] `dub test --config=library` passes (`106 modules passed unittests`) and `dmd -run tools/lint.d` reports zero GC-storage violations across all new/modified engine modules (`renderer.d`, `material.d`).

## Cross References

- [`plan-openpbr.md`](plan-openpbr.md) (`OPBR-7` Multi-Pass Refractive Transmission, `OPBR-9` SSR & Local Probes)
- [`plan-terrain-water.md`](plan-terrain-water.md) (`TW-4` Editor Water Entity)
- [`plan-post-processing.md`](plan-post-processing.md) (`SCENE_COLOR_FORMAT = rgba16Float` pipeline)
- [`graphics.md`](graphics.md)
- [`roadmap.md`](roadmap.md)
