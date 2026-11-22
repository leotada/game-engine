# Plan: Port the Water Demo into Reusable Engine Features

> **Status:** implemented (WP-0–WP-10, 2026-11-22) · Follows [plan-water-realism.md](plan-water-realism.md) (WTR-0–WTR-6) · Covers the water part of [plan-terrain-water.md](plan-terrain-water.md) (TW-4, minus the editor gizmo) · See [roadmap.md](roadmap.md)

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

Reference images (`--capture=… --no-hud`, fixed 1/60 s step, 3 frames after
t = 1.8 s; captured from the pre-port code with only the fixed-step patch, so
later phases can compare pixel-for-pixel):
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

### WP-1 — Wave model (`engine/water/waves.d`) ✅ (2026-11-22)

Done as planned. `WaveChannel` is a general center line (origin + direction)
rather than a Z-only bank mask. `rockChop` (PBR constant 1.2 / 1.38 and the
obstacle boost in the vertex shader) and the distance/Nyquist attenuation are
rendering concerns and stay out of `WaveSet` (WP-2 / WP-4). Demo captures are
pixel-identical to the WP-0 reference (0 differing pixels, ocean and river).

- `WaveComponent`, `WaveSet` (up to 8 components, POD), presets `WaveSet.ocean()` / `WaveSet.river()`.
- Parameterized modifiers now hard-coded in the demo and shaders: wave-set modulation, phase warp, river bank mask (as a bank half-width + falloff), wave scale.
- `sampleWaves(ref const WaveSet, float x, float z, float time) -> WaveSample` (`pure nothrow @nogc`).
- Unit tests: flat set returns y=0 / normal +Y, presets match the demo's current output at fixed points.

### WP-2 — Shared wave buffer (single source of truth) ✅ (2026-11-22)

Done. Deviations: the buffer holds up to 4 **bodies** (bounds + level + own
`WaveSet` + wetline/caustics settings) instead of one global wave set, so
several water bodies can coexist; `GpuWaterData` lives in
`engine.water.gpu_data` and WGSL in `common/waves.wgsl` (shadows.wgsl is
unchanged). The PBR rock-chop constant became the per-body `contactChop`, and
the wetline early-out height is computed from the wave amplitudes instead of
the 0.75 / 0.38 constants. Added `Scene3DTextured.addTransparentHook` (needed
by WP-3). Demo captures match the WP-0 reference (< 0.1 differing pixel).

- `GpuWaveData` (std430) uploaded by the engine; frame bind group binding 10 (`storage, read`) in `pipeline.d`, `scene3d_textured.d` and `common/shadows.wgsl` (or a new `common/waves.wgsl`).
- `Scene3DTextured.setWaves(ref const WaveSet, float level)`.
- `textured3d_pbr.wgsl` (`evalExactWaveY`, `evalRecentWaterWetness`) and `water_surface.wgsl` read the buffer; hard-coded tables removed.
- Remove `MaterialFlags.waterRiverMode` (river-ness becomes data); keep `waterWetCaustics` as the per-material opt-in.

### WP-3 — `WaterRenderer` + `WaterBody` ✅ (2026-11-22, together with WP-4)

Done. Deviations:
- WP-3 and WP-4 shipped together: the surface shader samples the simulation
  texture, so splitting them would have needed a throwaway dummy path.
- Registered as a **transparent** hook (after the sky), not post-opaque, so
  the opaque snapshot contains the sky.
- `WaterBody` is square (`centerX/Z` + `halfExtent`) instead of arbitrary XZ
  bounds; `WaterStyle` ocean/river (like HDRP surface types) selects the
  surface algorithms, `WaterOptics` holds the colors. The grid is a unit
  `[-1, 1]` mesh scaled in the vertex shader. The camera basis was unused by
  the shaders and was dropped from the UBO (`WaterSurfaceUniforms`, 432 B).
- The simulation is submitted in its own command buffer inside `update`
  (before `beginFrame`), not in the frame encoder; disabled bodies still
  allocate their two 256² textures (2 MB per body; revisit if it matters).
- River bed fallback depth is flat (`bedDepth`) plus obstacle shoaling; the
  demo's bank profile is gone (only used when refraction is off).
- DMD crash root cause found: CTFE-built shader `enum`s used inside a
  function. Fixed with module-level `immutable string`s; the demo builds
  with DMD again.
- Performance work (WP-2 had regressed the river by +1.1 ms): wave `k`,
  `omega` and warp scale precomputed on the CPU; the PBR wetline loads the
  body's waves once per fragment (`WaterPoint`); `evalSky` split into base +
  sun so the water evaluates clouds once.

| LDC release 1280×720 | WP-0 (re-measured) | WP-3 |
|:---|---:|---:|
| Ocean | 5.49 ms | 5.71 ms (+4.0%) |
| River | 3.26 ms | 3.62 ms (+11%, open item for WP-10) |
| No-Water | 1.99 ms | 2.05 ms |

Original scope:
- `WaterBody` (POD): XZ bounds, water level, grid resolution, absorption/scatter colors, flags (refraction, SSR, transparent, horizon skirt, simulation).
- `WaterRenderer`: owns layouts, pipelines, UBO, grid mesh (`TexMesh` or an internal stride-32 mesh), cached surface bind groups; registers a post-opaque hook; draws N bodies with one opaque snapshot per frame.
- Water UBO packing moves here; camera basis comes from the `Camera`.
- `nothrow @nogc` frame path, no GC allocation per frame.

### WP-4 — `WaterSimulation` + obstacles ✅ (merged into WP-3)
- 256×256 ping-pong JONSWAP + advected foam, encoded in the frame encoder.
- `WaterRenderer.setObstacles(scope const(WaterObstacle)[])` (x, z, radius, strength; max 16).
- Disabled bodies pay nothing (no textures allocated).

### WP-5 — Generic caustics ✅ (2026-11-22)

Done: `common/caustics.wgsl` (`waterCausticsAt`), called from the sun term of
`textured3d_pbr.wgsl` and `common/simple_pbr.wgsl` (terrain and decals).
`caustics_bed.wgsl`, the demo's bed pipeline and the water surface's
screen-space prop caustics are gone; the demo seabed is a PBR quad with a
procedural sand texture. Deviations: the caustics use the body's rest level
(not the per-fragment wave height) and cheap early-outs (shadow, facing,
< 0.2 m depth, outside the river channel) run before the six Voronoi
layers. Submerged rocks now get the same physically scaled caustics as the
bed (dimmer than the old surface hack). Benchmark: Ocean 5.29 ms (WP-0
5.49), River 3.47 ms (WP-0 3.26, +6.5%), GC 0.

- Caustics evaluated in `textured3d_pbr.wgsl` and `terrain_pbr.wgsl` for fragments below the wave surface (reads binding 10), modulated by the sun shadow.
- Delete `caustics_bed.wgsl` and the bed quad; the demo seabed becomes a normal mesh or terrain.

### WP-6 — Sky unification ✅ (2026-11-22)

Done before WP-3 (the engine `WaterRenderer` should only ever use the engine
sky). The engine sky already had corona/halo, drifting clouds, stars and moon,
so nothing was ported into `sky.wgsl`; `frameSkyInputs` moved to
`common/sky_frame.wgsl` and the water surface reflects/fogs with `frameSky`.
`sky_dome.wgsl` and `evalWaterSky` are deleted. Deviation: the demo keeps its
fixed sun directions (no `TimeOfDay`); the golden-hour sun was lowered to ~7°
so the engine sky picks its dusk palette, and the demo sets cloud coverage
0.27 via `setWeather`. Not pixel-comparable with WP-0 (different sky model).

- Port sun corona and drifting clouds from `sky_dome.wgsl` into `sky.wgsl` (driven by frame uniforms / `Weather`).
- Demo uses `setSkyEnabled(true)` + `TimeOfDay`; the low-sun toggle maps to a time of day.
- Delete `sky_dome.wgsl` and its `shaders.d` / hot-reload registrations.

### WP-7 — Gameplay queries + buoyancy ✅ (2026-11-22)

Done: `engine.water.query` (`waterSurfaceAt`, `waterSurfaceHeight`,
`waterBodyContains`, `WaterQuery`, `WaterRenderer.surfaceAt`) and
`engine.water.buoyancy` (`applyBuoyancy`, `BuoyancyProbe`, `sphereProbes`,
`BuoyancySettings`, `sphereSubmergedVolume`). New physics helpers
`applyForce`, `getMass`, `getRotation` (+ `b3Body_ApplyForce` and
`b3Body_GetMass` bindings). The demo buoys are dynamic spheres (density
380 kg/m³). Deviations: forces go through `applyForce` at each probe (torque
from the ring probes) instead of `applyForceToCenter`; there is no separate
angular drag, since drag at the off-center probes already damps rotation;
the surface lookup is a callback, so the helper works with any water source.
Benchmark unchanged (Ocean 5.32 ms, River 3.49 ms, GC 0).

- `waterHeightAt(x, z)` / `waterSurfaceAt(x, z)` over the registered bodies (CPU, same `WaveSet` as the GPU).
- `applyBuoyancy(bodyId, ref const BuoyancyProbe[], ...)`: per-probe submerged depth → `applyForceToCenter` / force at point, plus linear and angular drag.
- Demo buoys become dynamic physics bodies.

### WP-8 — Wet material presets ✅ (2026-11-22)

Done: `engine/graphics/material_presets.d` (re-exported by
`engine.graphics`): `dryStoneParams`, `wetSurfaceParams`,
`mossSurfaceParams`, `submergedSurfaceParams`. Deviation: the variants take
a dry `MaterialParams` (not textures) plus an `openPbr` switch, so they apply
to any dry material; textures stay with `Material.create`. Demo captures are
pixel-identical.

- `engine/graphics/material_presets.d` (or `water/materials.d`): `wetRock`, `mossRock`, `submergedRock`, `dryRock` builders taking base textures.

### WP-9 — ECS + scene file + Inspector ✅ (2026-11-22)

Done: `engine/water/component.d` — `@component WaterSurface` (flat POD) +
`toWaterBody(surface, transform)`; registered in the editor and player,
saved and loaded through reflection (round-trip test in `scene_load.d`),
undo snapshots, **Criar > Água**, inspector section **Água** (preset
buttons + 4 drag fields), `SceneRenderer.enableWater` syncs entities to a
`WaterRenderer` and enables the sky while water exists. Deviations: the
component is `WaterSurface`, not `WaterBody` — the scene serializer skips
nested structs and fixed arrays, so the full body cannot be stored; the
transform supplies center, level and Y rotation. No per-entity obstacles
yet. Verified in the player and editor with a water scene (0 B GC).

- `@component struct WaterBody` registered in the editor components; serialized in `scene_file`; editable in the Inspector; the editor scene renderer feeds `WaterRenderer`.
- Elevation gizmo and `terrain_water.scene.json` remain in TW-4.

### WP-10 — Demo cleanup and docs ✅ (2026-11-22)

Done: the demo (1108 lines, from ~1880) holds game code only — procedural
textures, bank mesh, rock tables, buoys, bridge, lighthouse, keys, HUD and
bench/capture flags. The camera is the engine `OrbitCamera` (new
`minPitch`/`maxPitch`, `wheelZoomSpeed`, `dragToRotate`); the hand-written
shadow passes became `scene.renderShadows(frame, lights)` (banks, seabed and
submerged pebbles now cast and receive shadows like any mesh); `--no-hud`
hides the F1 hint. Captures vs WP-8: 46–48 dB PSNR. The lighthouse stays a
plain white tower (content, not engine).

Final benchmark (LDC release, 1280×720, `--bench=600`, GC delta 0):

| Scenario | WP-0 (re-measured) | WP-10 | Δ |
|:---|---:|---:|---:|
| Ocean | 5.49 ms | 5.32 ms | −3% |
| River | 3.26 ms | 3.47–3.56 ms | +7–9% |
| No-Water (ocean scene) | 1.99 ms | 1.71 ms | −14% |
| No-Water (river scene) | 1.86 ms | 1.81 ms | −3% |

River investigation: caustics cost nothing measurable (strength 0 → same
time); the PBR wet marks cost 0.63 ms of the river frame (wetline off →
2.82 ms). Halving the wet-history samples (24 → 12) saves only 0.05 ms, so
the cost is the per-fragment setup — wave data now comes from the shared
buffer with a dynamic count, where WP-0 had six constant waves the compiler
unrolled. Open item: a cheaper wetline (e.g. a low-resolution wet-history
texture written by the simulation) if the river budget matters.

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
