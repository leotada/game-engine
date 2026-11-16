# Plan: Realistic Water Rendering & Renderer Integration Benchmark

> **Status:** pending · Priority: medium · Links to [plan-openpbr.md](plan-openpbr.md) (`OPBR-7`, `OPBR-9`) & [plan-terrain-water.md](plan-terrain-water.md) · See [roadmap.md](roadmap.md)

## Objective

Upgrade the engine's water rendering from single-pass analytical transparency to **Unity HDRP / Unreal Engine 5 (`Single Layer Water`)** optical fidelity — real screen-space refraction, per-pixel depth-based Beer-Lambert absorption, geometry-exact shoreline contact foam, screen-space local reflections (SSR), dynamic rock/pier wetlines & underwater caustics, horizon clipmaps, and optional FFT / advected wake simulation — while **measuring the exact frame-time and VRAM impact of the required `Renderer` changes Before vs After across both No-Water and With-Water scenarios**.

Key engineering guarantees:

- **Zero overhead on No-Water scenes:** The new `Renderer` opaque snapshot path (`snapshotOpaque`) is strictly opt-in and lazy-allocated. Scenes that do not draw refractive water or transmissive surfaces perform no extra pass break, no GPU copy, and allocate no snapshot textures.
- **No `depth24Plus` pipeline breakage:** Existing `depth24Plus` pipelines (`pipeline.d`, `gizmos.d`, `skinned.d`, `water.d`) remain unchanged; depth resolution uses WebGPU-portable `r32Float` resolve rather than non-portable `depth24Plus` texture copies.
- **GC-safe hot loop:** Zero heap allocations between `pollEvents()` and `endFrame()`, enforced by `--assert-no-gc` and `dub run --config=lint`.

## Current State

Relevant repository paths and verified architectural constraints:

- [`source/engine/gpu/renderer.d`](../source/engine/gpu/renderer.d):
  - `Renderer.createSceneTargets(w, h)` creates `hdrTexture` (`SCENE_COLOR_FORMAT = WGPUTextureFormat.rgba16Float`, usage `renderAttachment | textureBinding`) and `depthTexture` (`WGPUTextureFormat.depth24Plus`, usage `renderAttachment` only).
  - `Renderer.beginFrameImpl` opens **one** uninterrupted `WGPURenderPass` into `hdrView` + `depthView` and keeps it open until `resolvePost(frame)`.
  - Because WebGPU/WGPU forbids copying or sampling render pass attachments while a pass is active, `water_surface.wgsl` currently has no access to opaque `SceneColor` or `SceneDepth`.
- [`source/engine/gpu/context.d`](../source/engine/gpu/context.d):
  - `GpuContext.create(..., presentMode)` negotiates surface capabilities and supports `WGPUPresentMode.immediate` (falling back to `fifo` when unsupported). Default `App.create` uses `WGPUPresentMode.fifo` (60 Hz VSync-capped), which hides sub-millisecond to few-millisecond GPU deltas unless overridden in benchmark mode.
- [`source/engine/scene/scene3d_textured.d`](../source/engine/scene/scene3d_textured.d):
  - Exposes `frameLayout()`, `frameGroup()`, `iblLayout()`, and `iblGroup()`, enabling custom water/sky/bed draws inside the HDR frame pass without duplicating lighting/shadow/IBL state.
- [`source/demo/water.d`](../source/demo/water.d) & water WGSL shaders:
  - [`assets/shaders/water_surface.wgsl`](../assets/shaders/water_surface.wgsl): GPU 6-octave Gerstner wave vertex displacement (`160×160` grid, `WATER_HALF = 14.0f`), 4-octave capillary micro-normals, analytical `evalRiverFlowAndWake`, analytical `evalRiverBedY` Beer-Lambert alpha blending (`outAlpha`), backlit crest SSS, lacy whitecaps, and procedural `sky_dome` reflection.
  - [`assets/shaders/caustics_bed.wgsl`](../assets/shaders/caustics_bed.wgsl): riverbed with Beer-Lambert transmittance and RGB Voronoi caustics modulated by PCF shadows (submerged rocks/piers using `textured3d_pbr.wgsl` do not receive underwater caustics or animated wetlines yet).
  - [`assets/shaders/common/water_env.wgsl`](../assets/shaders/common/water_env.wgsl) & [`assets/shaders/sky_dome.wgsl`](../assets/shaders/sky_dome.wgsl): shared `WaterUniforms`, analytical seabed, Voronoi caustics, and procedural atmosphere/clouds/sun disc.

### Why `Renderer` Changes Are Required (and What Does Not Require Changes)

| Capability | Requires `Renderer` Change? | Reason |
|:---|:---|:---|
| **Opaque Color + Depth Snapshot (`WTR-1`)** | **Yes** | Must add `copySrc` to `hdrTexture`, `textureBinding` to `depthTexture`, manage `opaqueColorTex` + `opaqueDepthTex`, and split the HDR render pass (`snapshotOpaque`). |
| **Refraction + Depth Absorption + Depth Shore Foam (`WTR-2`)** | No (uses `WTR-1`) | Implemented inside `water_surface.wgsl` by sampling `opaqueColorView` and `opaqueDepthView`. |
| **Underwater Caustics & Animated Wetline on Props (`WTR-3`)** | **No** | Implemented in `textured3d_pbr.wgsl` + material/uniform bindings inside the opaque pass. |
| **Screen-Space Reflections — SSR (`WTR-4`)** | No (uses `WTR-1`) | Raymarches `opaqueDepthView` and reads `opaqueColorView` directly in `water_surface.wgsl`. |
| **Ocean Horizon Clipmap (`WTR-5`)** | **No** | Camera-snapped concentric ring geometry + vertex shader LOD fading in `water.d` / `water_surface.wgsl`. |
| **Compute FFT Waves & Advected Foam Buffer (`WTR-6`)** | **No** | Compute / ping-pong passes run on their own command encoder before `app.beginFrame()`. |

## Out of Scope

- Full hardware ray-traced water reflections / refractions.
- 3D Eulerian/FLIP/SPH fluid simulation (`plan-terrain-water.md` already excludes volumetric fluid solvers).
- Planar mirror reflection passes (re-rendering the entire scene upside-down); local geometry reflections use SSR (`WTR-4`, matching `OPBR-9`) with coherent fallback to procedural sky + IBL.
- Multi-viewport split-screen water snapshot handling (`plan-split-screen.md` will handle viewport-rect UVs later).

## Dependencies

- [`plan-openpbr.md`](plan-openpbr.md): `WTR-1` / `WTR-2` directly provide the opaque HDR color snapshot architecture needed by `OPBR-7` (multi-pass refractive transmission), and `WTR-4` provides the depth-buffer SSR path for `OPBR-9`.
- [`plan-terrain-water.md`](plan-terrain-water.md): Water entities sculpted in the editor (`TW-4`) can later bind to the same `WaterSurface` shader + `Renderer.snapshotOpaque` contract.

## Technical Design

### 1. Opt-In `Renderer.snapshotOpaque` Architecture (`WTR-1`)

Target file: [`source/engine/gpu/renderer.d`](../source/engine/gpu/renderer.d)

1. **Source texture usage additions in `createSceneTargets(w, h)`:**
   - `hdrTexture`: `WGPUTextureUsage.renderAttachment | WGPUTextureUsage.textureBinding | WGPUTextureUsage.copySrc`
   - `depthTexture`: `WGPUTextureUsage.renderAttachment | WGPUTextureUsage.textureBinding` (remains `WGPUTextureFormat.depth24Plus` — zero changes to any existing 3D pipeline).
2. **Lazy snapshot targets (`OpaqueSnapshot` struct inside `Renderer`):**
   - `opaqueColorTex` / `opaqueColorView`: `rgba16Float`, usage `WGPUTextureUsage.copyDst | WGPUTextureUsage.textureBinding`, size `(rtW, rtH)`.
   - `opaqueDepthTex` / `opaqueDepthView`: `r32Float`, usage `WGPUTextureUsage.renderAttachment | WGPUTextureUsage.textureBinding`, size `(rtW, rtH)`.
   - `depthCopyPipe` + `depthCopyBGL` + fullscreen triangle pipeline resolving `depthView` (`texture_depth_2d`) via `textureLoad` to `r32Float` `opaqueDepthView`.
   - **Lazy creation guarantee:** Snapshot textures and `depthCopyPipe` are **not allocated** during `Renderer.create()` or `createSceneTargets()` until `snapshotOpaque()` is called for the first time (only resized/recreated in `createSceneTargets` if `snapshotActive == true`), so **scenes without water pay zero extra VRAM and zero pass overhead**.
3. **Pass sequence when `snapshotOpaque(ref FrameContext frame)` is called:**
   - Guard: if `!frame.valid || frame.postResolved`, return cleanly.
   - lazily initialize `opaqueColorTex` / `opaqueDepthTex` / `depthCopyPipe` if needed (`snapshotActive = true`).
   - End the open opaque HDR render pass (`wgpuRenderPassEncoderEnd` + `Release`).
   - Copy HDR color: `wgpuCommandEncoderCopyTextureToTexture(frame.encoder, hdrTexture -> opaqueColorTex)`.
   - Resolve depth (`depth24Plus -> r32Float`): open a tiny fullscreen render pass on `opaqueDepthView` (`loadOp = clear` / `dontCare`), bind `depthView`, draw 3 non-indexed vertices, end pass.
   - Reopen `frame.pass` targeting `hdrView` (`WGPULoadOp.load`) and `depthView` (`WGPULoadOp.load`, read-write depth test so water still depth-tests cleanly against opaque geometry).
   - Provide read-only getters `opaqueColorView()` and `opaqueDepthView()` on `Renderer` so water/transmissive passes bind them cleanly.

### 2. Performance Benchmark Methodology (Before vs After, With & Without Water)

To isolate the **exact CPU + GPU performance cost of the `Renderer` changes** from both VSync clamping and new shader complexity, all measurements use a deterministic uncapped harness (`WTR-0`) across **3 controlled scenarios** and **4 code checkpoints**:

#### Test Scenarios

1. **`No-Water` (Opaque Baseline Control):**
   - Exact same `water.d` scene geometry (all sculpted rocks, wooden bridge / lighthouse, buoys, banks, seabed `caustics_bed`, sky dome, 2048² dir shadow + 1024² spot shadow, IBL, Bloom + ACES + FXAA), **with water draw skipped and `snapshotOpaque` NOT called**.
   - Purpose: Proves that modifying `Renderer` (`copySrc`/`textureBinding` usage flags, `snapshotOpaque` dormant state) causes **≤ 0.05 ms (noise-floor) overhead** when water/transmission is absent.
2. **`River` (With Water — Complex Obstacles + Submerged Geometry):**
   - `--river`: Bridge piers, emergent wet/mossy rocks, submerged boulders beneath translucent water, running stream (`160×160` water mesh).
3. **`Ocean` (With Water — Full-Screen 6-Octave Gerstner Swell):**
   - Default ocean mode: 6 Gerstner waves across the full viewport, high pixel coverage, bright sun/sky Fresnel + SSR paths.

#### Benchmark Execution Protocol

- Build in release mode with LDC/DMD consistent across runs (`--build=release`, fixed camera, fixed animation time step `dt = 1/60` per frame or locked orbit, `WGPUPresentMode.immediate` with fallback check logged, `--no-hud` during timed runs to isolate 3D rendering).
- Per run: **120 warmup frames** (ignored) + **600 measured frames** at **1280×720** and **1920×1080**.
- Synchronization mode (`--bench-sync`): optional `wgpuDevicePoll(device, WGPU_TRUE, null)` or `WGPUQuerySet` timestamp pass markers (when `timestampQuery` is enabled on adapter) so GPU execution time is captured in the frame timing rather than hidden by queue pipelining.
- Assert `--assert-no-gc` (`0` GC bytes allocated in frames 120–720).

#### 4 Checkpoints (`Before` → `After`)

| Checkpoint | Code State | What It Measures |
|:---|:---|:---|
| **T0 (Before)** | Unmodified `Renderer` (`commit a226fac`), single uninterrupted HDR pass, analytical water shader | True baseline before any `Renderer` change |
| **T1 (Renderer Only)** | `WTR-1` landed: `No-Water` skips `snapshotOpaque`; `River`/`Ocean` call `snapshotOpaque` **with identical `T0` water shader** | Pure pass-break + `rgba16Float` copy + `r32Float` depth resolve tax (`T1 - T0`) and zero-cost proof on `No-Water` |
| **T2 (+Refraction & Depth)** | `WTR-2`: `water_surface.wgsl` samples `opaqueColor` + `opaqueDepth` for refraction, dispersion, Beer-Lambert, & shore foam | Marginal shader cost of optical refraction + depth lookups (`T2 - T1`) |
| **T3 (+SSR & Wet Props)** | `WTR-3` + `WTR-4`: SSR raymarching in `water_surface.wgsl` + submerged rock/pier caustics/wetline in `textured3d_pbr.wgsl` | Full Unity/UE5-grade visual target cost (`T3 - T0`) |

## Phases

### WTR-0 — Uncapped Benchmark Harness & `T0` Baseline Capture

- [ ] Add `--bench=<frames>`, `--no-water`, `--immediate`, and `--bench-sync` CLI flags to [`source/demo/water.d`](../source/demo/water.d) (using fixed `dt = 1/60`, `WGPUPresentMode.immediate`, 120 warmup frames, printing `avg`, `p50`, `p95`, `p99`, `max` ms, mean FPS, and GC alloc count to stdout; zero heap allocations inside loop).
- [ ] Optional helper in [`source/engine/gpu/renderer.d`](../source/engine/gpu/renderer.d) or `water.d`: check adapter `timestampQuery` support (`WGPUQuerySet`) to log pure GPU pass durations (`Opaque`, `Snapshot`, `Water`, `Post`) when supported.
- [ ] Run **T0** across `No-Water`, `River`, and `Ocean` at `1280×720` and `1920×1080` and populate the `T0 (Before)` column of the results table below before modifying `Renderer`.

**DoD:** Reproducible CLI benchmark emits deterministic percentile stats (`--assert-no-gc` green) and `T0` baseline values are recorded.

### WTR-1 — Opt-In `Renderer.snapshotOpaque` (`rgba16Float` Color Copy + `r32Float` Depth Resolve)

- [ ] Update `hdrTexture` (`+ copySrc`) and `depthTexture` (`+ textureBinding`) usage flags in [`source/engine/gpu/renderer.d`](../source/engine/gpu/renderer.d).
- [ ] Implement lazy `OpaqueSnapshot` resources (`opaqueColorTex`, `opaqueDepthTex` in `r32Float`, `depthCopyPipe`) resized automatically in `createSceneTargets` only once activated, released cleanly in `releaseSceneTargets`.
- [ ] Implement `Renderer.snapshotOpaque(ref FrameContext)` (`endPass -> CopyTextureToTexture(hdr) -> 3-vert depthCopyPass -> reopen HDR+depth with loadOp = load`) and read-only getters `opaqueColorView()` / `opaqueDepthView()`.
- [ ] Wire `snapshotOpaque` in [`source/demo/water.d`](../source/demo/water.d) (called only when water is enabled; skipped for `--no-water`) while keeping the `T0` water shader unchanged, then measure **T1** (`No-Water`, `River`, `Ocean`) and log `T1 - T0`.
- [ ] Run `dub test --config=library` and `dub run --config=lint` to verify zero regressions and `@nogc` compliance.

**DoD:** `T1` benchmark shows `No-Water` frame delta within noise (`≤ 0.05 ms`), `River`/`Ocean` isolate exact `snapshotOpaque` cost, and `dub test --config=library` passes.

### WTR-2 — True Screen-Space Refraction, Depth Beer-Lambert & Contact Shore Foam

- [ ] Bind `renderer.opaqueColorView()` and `renderer.opaqueDepthView()` (plus a linear clamp sampler) into the water bind group in [`source/demo/water.d`](../source/demo/water.d).
- [ ] Update [`assets/shaders/water_surface.wgsl`](../assets/shaders/water_surface.wgsl):
  - Linearize `sceneDepth` vs fragment depth to compute exact 3D water column thickness `waterDepth` (`worldRayThickness` along view ray), replacing `evalRiverBedY` approximations where opaque geometry exists.
  - Sample `opaqueColorView` with normal-perturbed refracted screen UVs (`clamp` + edge attenuation so refractions never pull off-screen foreground objects incorrectly; dual-tap or depth-rejected sample if sample depth `< waterDepth`!).
  - Add subtle chromatic dispersion across R/G/B refraction offsets in shallow water.
  - Multiply refracted background HDR radiance by physical Beer-Lambert `exp(-sigma * waterDepth)` and replace `outAlpha` transparency tricks with direct optical composition (`refractedUnderwater + reflection + sss + foam`, `alpha = 1.0` inside coverage).
  - Replace hardcoded obstacle circles with `waterDepth`-driven shoreline foam hugging the true 3D silhouette of every rock, bridge abutment, pier, and bank.
- [ ] Capture screenshots (`--capture`) and record **T2** benchmark numbers.

**DoD:** Submerged rocks and wooden piers visually bend under wave refraction, tint continuously with true depth, and show crisp foam along real 3D rock edges; `T2` performance is recorded.

### WTR-3 — Submerged Rock & Pier Caustics + Wave-Synced Wetline (No Renderer Changes)

- [ ] Extend [`assets/shaders/common/water_env.wgsl`](../assets/shaders/common/water_env.wgsl) helpers (`evalCausticsRgb`, Gerstner surface elevation estimate or water plane height + `time`) so [`assets/shaders/textured3d_pbr.wgsl`](../assets/shaders/textured3d_pbr.wgsl) can opt in via shader uniform flag.
- [ ] Project animated RGB Voronoi caustics onto submerged portions (`worldPos.y < waterLevel`) of rocks and bridge piers modulated by `dirShadow` and depth attenuation.
- [ ] Modulate porous albedo darkening and coat/specular roughness smoothly above the instantaneous wave height for a dynamic wet tide/splash band.

**DoD:** Submerged boulders and bridge piers receive animated shadowed caustics and wave-synced wet waterlines with zero changes to `Renderer`.

### WTR-4 — Screen-Space Reflections (SSR) in Water Shader

- [ ] Implement linear + binary-refinement screen-space raymarching in [`assets/shaders/water_surface.wgsl`](../assets/shaders/water_surface.wgsl) using `opaqueDepthView` and `opaqueColorView` (reusing `WTR-1` targets — **zero additional `Renderer` passes**).
- [ ] Tune step count (`16`–`24` linear steps + `4` binary refinement steps, jittered with blue/interleaved noise + roughness fade + smooth screen-border vignette) falling back seamlessly to procedural `evalWaterSky` / `specularMap` IBL on miss.
- [ ] Add `[7]` toggle (SSR On/Off) in `water.d` for instant visual & FPS A/B comparison, record **T3** benchmark timings (`1280×720` and `1920×1080`), and verify visual captures in Ocean + River modes.

**DoD:** Rocks, bridge deck/piers, buoys, and lighthouse visibly reflect on calm and rippled water; `T3` vs `T0` measurements are complete in the table below.

### WTR-5 — Ocean Horizon Clipmap & Distance Normal Anti-Aliasing (No Renderer Changes)

- [ ] Replace the fixed `160×160` (`WATER_HALF = 14.0f`) quad in Ocean mode with a multi-ring camera-snapped clipmap extending smoothly toward the horizon (`~250 m+`), eliminating the exposed ocean slab edge while keeping vertex count compact near the camera.
- [ ] Smoothly fade Gerstner displacement amplitude with distance (`smoothstep`) into GGX specular roughness (`Toksvig` / normal variance filtering) so the distant horizon remains shimmer-free.

**DoD:** Ocean extends seamlessly to the atmospheric horizon at any camera zoom/orbit height without vertex swimming or distant specular aliasing.

### WTR-6 — Optional Compute FFT Ocean Spectrum & Advected River Wake Foam (No Renderer Changes)

- [ ] Add an optional pre-frame `WGPUCommandEncoder` compute pass generating a periodic JONSWAP height/displacement/folding-foam texture (`256×256` `rgba16Float`) before `app.beginFrame()` in Ocean mode.
- [ ] Add a lightweight ping-pong 2D advection/dissipation buffer around river obstacles so wakes and foam trails flow downstream naturally around rocks and bridge piers.

**DoD:** Ocean swells show non-repeating wind-driven spectrum detail and river wakes stream dynamically downstream, runnable alongside `@nogc` frame loop.

---

## Performance Measurement Table (Before vs After `Renderer` Changes)

> Fill this table sequentially as `WTR-0`, `WTR-1`, `WTR-2`, and `WTR-4` land. Never estimate unmeasured numbers.

### Part A — Frame-Time Comparison (`1280×720`, 600 frames after 120 warmup, `--immediate --bench-sync --no-hud`)

| Scenario | Checkpoint | Renderer Changed? | Avg (ms) | p50 (ms) | p95 (ms) | p99 (ms) | Mean FPS | Delta vs T0 (ms) | GC Alloc / Frame |
|:---|:---|:---|---:|---:|---:|---:|---:|---:|---:|
| **No-Water** | **T0 (Before)** | No | _TBD_ | _TBD_ | _TBD_ | _TBD_ | _TBD_ | `0.00` | `0 B` |
| **No-Water** | **T1 (After `WTR-1`)** | Yes (dormant) | _TBD_ | _TBD_ | _TBD_ | _TBD_ | _TBD_ | _target ≤ +0.05_ | `0 B` |
| **River** | **T0 (Before)** | No | _TBD_ | _TBD_ | _TBD_ | _TBD_ | _TBD_ | `0.00` | `0 B` |
| **River** | **T1 (`WTR-1` Pass Split Only)** | Yes (active) | _TBD_ | _TBD_ | _TBD_ | _TBD_ | _TBD_ | _target ≤ +0.35_ | `0 B` |
| **River** | **T2 (+Refraction & Depth)** | Yes | _TBD_ | _TBD_ | _TBD_ | _TBD_ | _TBD_ | _TBD_ | `0 B` |
| **River** | **T3 (+Caustics Props & SSR)** | Yes | _TBD_ | _TBD_ | _TBD_ | _TBD_ | _TBD_ | _TBD_ | `0 B` |
| **Ocean** | **T0 (Before)** | No | _TBD_ | _TBD_ | _TBD_ | _TBD_ | _TBD_ | `0.00` | `0 B` |
| **Ocean** | **T1 (`WTR-1` Pass Split Only)** | Yes (active) | _TBD_ | _TBD_ | _TBD_ | _TBD_ | _TBD_ | _target ≤ +0.35_ | `0 B` |
| **Ocean** | **T2 (+Refraction & Depth)** | Yes | _TBD_ | _TBD_ | _TBD_ | _TBD_ | _TBD_ | _TBD_ | `0 B` |
| **Ocean** | **T3 (+Caustics Props & SSR)** | Yes | _TBD_ | _TBD_ | _TBD_ | _TBD_ | _TBD_ | _TBD_ | `0 B` |

### Part B — High-Resolution Scaling & Pass Breakdown (`1920×1080`)

| Scenario | Checkpoint | Opaque Pass (ms) | Snapshot Copy + Depth Resolve (ms) | Water Pass (ms) | Post Pass (ms) | Total Frame (ms) | Extra VRAM (MB) |
|:---|:---|---:|---:|---:|---:|---:|---:|
| **No-Water** | **T0 → T1** | _TBD_ | `0.00` (skipped) | `0.00` | _TBD_ | _TBD_ | `+0.0 MB` (lazy) |
| **River** | **T1 (`WTR-1`)** | _TBD_ | _TBD_ | _TBD_ | _TBD_ | _TBD_ | `~23.7 MB`¹ |
| **River** | **T3 (Full)** | _TBD_ | _TBD_ | _TBD_ | _TBD_ | _TBD_ | `~23.7 MB`¹ |
| **Ocean** | **T1 (`WTR-1`)** | _TBD_ | _TBD_ | _TBD_ | _TBD_ | _TBD_ | `~23.7 MB`¹ |
| **Ocean** | **T3 (Full)** | _TBD_ | _TBD_ | _TBD_ | _TBD_ | _TBD_ | `~23.7 MB`¹ |

¹ At `1920×1080`: `opaqueColorTex` (`rgba16Float` = 8 B/px = `15.82 MB`) + `opaqueDepthTex` (`r32Float` = 4 B/px = `7.91 MB`) = `~23.73 MB` (`~10.55 MB` at `1280×720`), allocated only when `snapshotOpaque()` is called.

### Performance Acceptance Targets & Contingencies

- **`No-Water` regression guard:** `T1 - T0` must stay within measurement noise (`≤ 0.05 ms` average, `+0 MB` VRAM). Any measurable regression blocks merging `WTR-1`.
- **`WTR-1` pass split budget:** `Snapshot Copy + Depth Resolve` should stay `≤ 0.35 ms` at `1280×720` (`≤ 0.70 ms` at `1920×1080`).
- **SSR contingency (`WTR-4`):** If full-res SSR adds `> 2.0 ms` at `1080p` on target integrated/mid-range GPUs, switch SSR trace to **half-resolution (`w/2 × h/2`)** or reduce step count (`12` linear + `4` binary) before keeping SSR on by default.

## Acceptance Criteria

1. `Renderer.snapshotOpaque` cleanly splits the HDR render pass on demand with zero regressions in non-water scenes (`--no-water` delta within noise and zero extra VRAM when unused).
2. All Before (`T0`) vs After (`T1`, `T2`, `T3`) benchmark tables are populated with real hardware measurements on both **No-Water** and **With-Water** (`River` + `Ocean`) scenarios at `1280×720` and `1920×1080`.
3. Water refraction bends submerged rocks and bridge piers smoothly without edge halos or background bleed from foreground objects (`depth`-rejected UV offset).
4. Shoreline foam, Beer-Lambert absorption, underwater prop caustics, and SSR reflections operate within the target frame budget (`≤ 16.6 ms` / ≥ 60 FPS at `1080p`) with `0` GC allocations in the frame loop (`--assert-no-gc`).
5. `dub test --config=library` and `dub run --config=lint` pass cleanly after every phase, and `OPBR-7` / `OPBR-9` reuse the `WTR-1` `Renderer` snapshot primitives without duplicating targets.

## Cross References

- [`plan-openpbr.md`](plan-openpbr.md) (`OPBR-7` Multi-Pass Refractive Transmission, `OPBR-9` SSR & Local Probes)
- [`plan-terrain-water.md`](plan-terrain-water.md) (`TW-4` Editor Water Entity)
- [`plan-post-processing.md`](plan-post-processing.md) (`SCENE_COLOR_FORMAT = rgba16Float` pipeline)
- [`graphics.md`](graphics.md)
- [`roadmap.md`](roadmap.md)
