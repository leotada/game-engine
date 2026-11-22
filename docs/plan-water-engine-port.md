# Plan: Port the Water Demo into Reusable Engine Features

> **Status:** pending · Follows [plan-water-realism.md](plan-water-realism.md) (WTR-0–WTR-6) · Covers the water part of [plan-terrain-water.md](plan-terrain-water.md) (TW-4, minus the editor gizmo) · See [roadmap.md](roadmap.md)

## Objective

`source/demo/water.d` (~1880 lines) contains the whole water system: raw WGPU
pipelines, uniform packing, the compute simulation, the CPU wave sampler,
grid meshes, obstacle wiring and the old `sky_dome.wgsl`. The engine only
owns the low-level pieces (shader sources, `Renderer.snapshotOpaque`,
`MaterialFlags.waterWetCaustics`/`waterRiverMode`).

This plan moves every reusable feature into a new `engine/water/` package
and rewrites the demo so it contains **game code only** (scene layout, rocks,
buoys, input, HUD, benchmark flags). Target: the demo shrinks to roughly
600–700 lines.

## Decisions (2026-11-22)

| Topic | Decision |
|:---|:---|
| Core surface (Gerstner, refraction, SSR, absorption, shore foam) | Engine feature |
| Compute wave/foam simulation + obstacles/wakes | Engine feature, optional per water body |
| Caustics | Engine feature, **generic**: applied by the PBR and terrain shaders below the water line, replacing the dedicated bed quad |
| Height query + buoyancy | Engine feature: `waterHeightAt` / `waterSurfaceAt` + buoyancy helper on Box3D bodies |
| Wet material presets (dry / wet / moss / submerged rock) | Engine feature (`MaterialParams` presets) |
| Wave data source | **Single buffer** in the frame bind group (`@group(0) @binding(10)`), read by water, PBR wetline, terrain and the CPU sampler |
| Sky | Demo migrates to `SkyRenderer` (`sky.wgsl`); missing visuals (sun corona, drifting clouds) are ported into `sky.wgsl`; `sky_dome.wgsl` is deleted |
| ECS / editor | POD `WaterBody` component + scene-file serialization + Inspector editing. The elevation gizmo stays in TW-4 |

## Stays in the demo (game content)

- Procedural bank / timber / masonry textures and the river-bank mesh.
- `SEA_ROCKS` / `RIVER_ROCKS` placements, buoys, bridge, lighthouse.
- Key bindings, HUD, benchmark flags (`--bench`, `--stage`, `--no-water`, `--capture`).
- Camera: replaced by the engine `OrbitCamera` (`engine/scene/controllers.d`).

## Integration Points (already in the engine)

- `Scene3DTextured.addPostOpaqueHook` — the water surface draws here; the hook may call `Renderer.snapshotOpaque`.
- `Scene3DTextured.addShadowCasterHook` — not needed for water (water casts no shadows); used by buoys through the normal batches.
- `FrameContext.encoder` + the auxiliary-pass helper — the compute simulation is encoded in the frame encoder instead of a separate `wgpuQueueSubmit`.
- Frame bind group layout (`engine/gpu/pipeline.d`, bindings 0–9) — gains binding 10 for wave data.

## Phases

Each phase is one or more small commits with tests green.

### WP-0 — Reference capture ✅ (2026-11-22)

Build: `dub build --config=water --compiler=ldc2 --build=release`, 1280×720,
`--bench=600` (120 warm-up frames, immediate present, device poll per frame).
Two runs per scenario differed by < 1%.

| Scenario | Command | avg ms | p50 | p95 | p99 | GC delta |
|:---|:---|---:|---:|---:|---:|---:|
| Ocean | `--bench=600` | 5.58 | 5.54 | 5.89 | 6.15 | 0 |
| River | `--bench=600 --river` | 3.22 | 3.19 | 3.37 | 3.69 | 0 |
| No-Water (ocean scene) | `--bench=600 --no-water` | 2.04 | 1.98 | 2.33 | 3.27 | 0 |
| No-Water (river scene) | `--bench=600 --river --no-water` | 1.86 | 1.83 | 2.18 | 2.73 | 0 |

Reference images (`--capture=… --no-hud`, time ≈ 1.8 s):
[ocean](images/water-wp0-ocean.jpg) · [river](images/water-wp0-river.jpg).
Both scenes render correctly after the recent shader/material layout changes.

Findings:
- **DMD 2.113 segfaults** compiling the water config (backend stack overflow
  in `cgcod.codelem` ↔ `cod2.cdcomma`, while generating
  `demo.water.WaterShaderPipelines.create`). LDC builds fine; other configs
  build with DMD. WP-3 must not reproduce this function shape: split pipeline
  creation into small per-pipeline functions in the engine `WaterRenderer`.
- `--no-hud` still draws the "[F1] Show Controls HUD" hint.
- The ocean lighthouse renders as an untextured white box.

### WP-1 — Wave model (`engine/water/waves.d`)
- `WaveComponent`, `WaveSet` (up to 8 components, POD), presets `WaveSet.ocean()` / `WaveSet.river()`.
- Parameterized modifiers now hard-coded in the demo and shaders: wave-set modulation, phase warp, river bank mask (as a bank half-width + falloff), wave scale.
- `sampleWaves(ref const WaveSet, float x, float z, float time) -> WaveSample` (`pure nothrow @nogc`).
- Unit tests: flat set returns y=0 / normal +Y, presets match the demo's current output at fixed points.

### WP-2 — Shared wave buffer (single source of truth)
- `GpuWaveData` (std430) uploaded by the engine; frame bind group binding 10 (`storage, read`) in `pipeline.d`, `scene3d_textured.d` and `common/shadows.wgsl` (or a new `common/waves.wgsl`).
- `Scene3DTextured.setWaves(ref const WaveSet, float level)`.
- `textured3d_pbr.wgsl` (`evalExactWaveY`, `evalRecentWaterWetness`) and `water_surface.wgsl` read the buffer; hard-coded tables removed.
- Remove `MaterialFlags.waterRiverMode` (river-ness becomes data); keep `waterWetCaustics` as the per-material opt-in.

### WP-3 — `WaterRenderer` + `WaterBody`
- `WaterBody` (POD): XZ bounds, water level, grid resolution, absorption/scatter colors, flags (refraction, SSR, transparent, horizon skirt, simulation).
- `WaterRenderer`: owns layouts, pipelines, UBO, grid mesh (`TexMesh` or an internal stride-32 mesh), cached surface bind groups; registers a post-opaque hook; draws N bodies with one opaque snapshot per frame.
- Water UBO packing moves here; camera basis comes from the `Camera`.
- `nothrow @nogc` frame path, no GC allocation per frame.

### WP-4 — `WaterSimulation` + obstacles
- 256×256 ping-pong JONSWAP + advected foam, encoded in the frame encoder.
- `WaterRenderer.setObstacles(scope const(WaterObstacle)[])` (x, z, radius, strength; max 16).
- Disabled bodies pay nothing (no textures allocated).

### WP-5 — Generic caustics
- Caustics evaluated in `textured3d_pbr.wgsl` and `terrain_pbr.wgsl` for fragments below the wave surface (reads binding 10), modulated by the sun shadow.
- Delete `caustics_bed.wgsl` and the bed quad; the demo seabed becomes a normal mesh or terrain.

### WP-6 — Sky unification
- Port sun corona and drifting clouds from `sky_dome.wgsl` into `sky.wgsl` (driven by frame uniforms / `Weather`).
- Demo uses `setSkyEnabled(true)` + `TimeOfDay`; the low-sun toggle maps to a time of day.
- Delete `sky_dome.wgsl` and its `shaders.d` / hot-reload registrations.

### WP-7 — Gameplay queries + buoyancy
- `waterHeightAt(x, z)` / `waterSurfaceAt(x, z)` over the registered bodies (CPU, same `WaveSet` as the GPU).
- `applyBuoyancy(bodyId, ref const BuoyancyProbe[], ...)`: per-probe submerged depth → `applyForceToCenter` / force at point, plus linear and angular drag.
- Demo buoys become dynamic physics bodies.

### WP-8 — Wet material presets
- `engine/graphics/material_presets.d` (or `water/materials.d`): `wetRock`, `mossRock`, `submergedRock`, `dryRock` builders taking base textures.

### WP-9 — ECS + scene file + Inspector
- `@component struct WaterBody` registered in the editor components; serialized in `scene_file`; editable in the Inspector; the editor scene renderer feeds `WaterRenderer`.
- Elevation gizmo and `terrain_water.scene.json` remain in TW-4.

### WP-10 — Demo cleanup and docs
- Demo keeps only game code (see list above).
- New `docs/water-guide.md`; update `docs/graphics.md`, `docs/game-development-guide.md`, `docs/README.md`, `CHANGELOG.md`; mark `plan-water-realism.md` and `plan-terrain-water.md` accordingly.
- Verify: `dub test --config=library`, `dub run --config=lint`, `dub run --config=water -- --bench=…` vs WP-0 numbers, visual comparison against WP-0 captures.

## Risks

- **Frame layout change (WP-2)** touches every pipeline using `frameLayout` (PBR, terrain, decals, sky). Must land in one commit with all consumers updated.
- **Visual drift**: generic caustics and the unified sky will not be pixel-identical; compare against WP-0 captures and accept documented differences.
- **Buoyancy stability**: probe-based forces need damping tuning; keep the CPU sampler cheap (6–8 components).

## Acceptance Criteria

1. `source/demo/water.d` contains no WGPU calls, no WGSL references and no wave math.
2. One wave definition drives the water surface, the PBR wetline, caustics and `waterHeightAt`.
3. A scene file with a `WaterBody` entity renders water in the editor and the player.
4. No per-frame GC allocation added (`--assert-no-gc` in the player).
5. Ocean/river benchmark frame time within ±5% of WP-0.
