# Plan: OW-3 — CSM, Terrain Splatting, HDR Fog, Sky/Weather & Decals

Implementation plan for Phase 3 of [plan-open-world-readiness.md](plan-open-world-readiness.md) (`P3.1`–`P3.5`).

## Context

OW-1 (Box3D physics), OW-2 (zero-GC submission, culling, LOD, static instancing), OW-4 (audio) and OW-6 (navigation) are done. A 3 km × 3 km outdoor scene still has no terrain renderer, one 2048² directional shadow map fitted to a fixed sphere (`directionalLightVP` in `engine/gpu/shadow.d`), no fog, a sky that exists only inside the water demo (`sky_dome.wgsl` bound to `WaterUniforms`), an `rgba8Unorm` IBL baked once on the CPU, and no decals. OW-3 closes these gaps. OW-5 (ragdoll, minimap), OW-7 (world streaming) and OW-8 depend on it.

**Phase DoD (unchanged):** a 3 km × 3 km test scene renders chunked splatted terrain aligned with Box3D heightfields, 4-cascade CSM, HDR fog, dynamic day/night with rain wetness, and 500+ projected decals at target frame rate. It must have zero WebGPU validation errors and 0 GC bytes in `--headless-frames=600 --assert-no-gc`.

## Starting point (verified in code)

| Area | Current state | File |
|---|---|---|
| Frame bind group | `@group(0)` holds 7 depth textures (dir 2D, 4 point cubes, 2 spot 2D) plus a comparison sampler and a point-light SSBO. The layout is built once and shared by the PBR, water, sky and caustics pipelines. | `engine/gpu/pipeline.d:~430`, `assets/shaders/common/shadows.wgsl` |
| Texture budget | PBR fragment stage uses 7 (group 0) + 5 (group 1) + 3 (group 2, IBL) = **15/16** | `textured3d_pbr.wgsl` |
| `FrameUniforms` | 720 bytes (`FRAME_UNIFORMS_SIZE`) with 3 free floats `_padFrame0..2`. The WGSL definition lives in `common/shadows.wgsl`. | `scene3d_textured.d:161`, `pipeline.d:378` |
| Directional shadow | A single `ShadowMap` at `DIR_SHADOW_RESOLUTION = 2048`. The VP is supplied by the caller (`GpuDirLight.viewProj`), and shadow slot 0 of `shadowVpBuf` (256-byte stride) is the dir view. Casters are culled with `Frustum.fromViewProj(dir.viewProj)`. | `scene3d_textured.d:247–260, 620–760`, `light.d` |
| Camera | `Scene3DTextured.begin(ref const Camera)`. `Camera` already carries `fovY/aspect/near/far/position/target`, so CSM can be fitted inside the engine with no new user input. | `scene/camera.d` |
| IBL | `IblEnvironment.create/createGradient/createSolid`, CPU-prefiltered, `rgba8Unorm`, env 64², 5 specular mips | `engine/gpu/ibl.d` |
| Sky | `sky_dome.wgsl` + `evalWaterSky` in `common/water_env.wgsl`, fed by `WaterUniforms` | `assets/shaders/` |
| Fog | Only inside `water_surface.wgsl:695` | — |
| Depth snapshot | `Renderer.snapshotOpaque()` → `opaqueDepthView_` (used by water) | `engine/gpu/renderer.d:251` |
| Texture arrays | `TextureArray.fromLayers` (OW-2) | `engine/graphics/texture.d:451` |
| Heightfield physics | `createHeightField(world, pos, heights, countX, countZ, scale, materialIndices, materials…)` + `CookedHeightField` RAII with `globalMin/MaxHeight` | `engine/physics/body.d:573+` |
| Perf harness | `dub run --config=openworld-bench -- --headless-frames=600 --assert-no-gc` | `source/demo/openworld_bench.d` |

## Implementation order

Dependencies decide the order. That makes it different from the P3.x numbering:

1. **P3.1 CSM.** It changes `@group(0)` and `FrameUniforms`. Every later shader builds on those.
2. **P3.3 Fog.** This is small, and it establishes the `common/atmosphere.wgsl` include that terrain and decals reuse.
3. **P3.4 Sky, runtime IBL and wetness.** The sun state drives both fog in-scattering and the shadow direction.
4. **P3.2 Terrain.** This is the largest item. It consumes CSM, fog and wetness.
5. **P3.5 Decals.** These need `invViewProj`, which is added in step 1, and are drawn over terrain.
6. **Outdoor DoD demo and docs.**

Each step is one commit (or a few), with `dub test --config=library` green. Each step also gets an ai-memory note recording the decisions made and any deviations from this plan.

## `FrameUniforms` growth (done once, in step 1)

All new fields are appended after `spots`. Keeping 16-byte alignment, the size goes from 720 to **1152 bytes**, which is still far below the uniform buffer limit. The WGSL struct stays the single definition in `common/shadows.wgsl`, so water, sky and caustics pick it up automatically.

| Field | Bytes | Used by |
|---|---:|---|
| `cascadeViewProj: array<mat4x4<f32>, 4>` | 256 | CSM |
| `cascadeSplits: vec4<f32>` (view-depth far distance per cascade) | 16 | CSM |
| `cascadeParams: vec4<f32>` (count, blend width, fade start, fade end) | 16 | CSM |
| `invViewProj: mat4x4<f32>` | 64 | decals, sky |
| `cameraForward: vec3<f32>` + `cameraNear: f32` | 16 | cascade select, sky |
| `viewportSize: vec2<f32>` + `cameraFar: f32` + `_pad` | 16 | decals |
| `fogColorDensity`, `fogHeight` (base, falloff, start, maxOpacity), `fogSun` (rgb, power) | 48 | fog |
| `_padFrame0..2` → `globalWetness`, `rainIntensity`, `cloudCoverage` | (existing) | wetness, sky |

`GpuDirLight.viewProj` stays and mirrors cascade 0, so existing callers and `setLighting()` keep compiling.

---

## Step 1 — P3.1 Cascaded Shadow Maps

**Files:** `engine/gpu/shadow.d`, `engine/gpu/pipeline.d`, `engine/scene/light.d`, `engine/scene/scene3d_textured.d`, `assets/shaders/common/shadows.wgsl`, `engine/editor/scene_renderer.d`, `source/demo/water.d`.

- **Resource:** a new `CascadedShadowMap` in `shadow.d` (move-only, `@disable this(this)`). It holds one `depth32Float` texture with `depthOrArrayLayers = cascadeCount`, one `dim2DArray` sampling view, and one `dim2D` render view per layer (`baseArrayLayer = i`). It reuses the existing comparison sampler. `ShadowMap` stays for spot and legacy use.
- **Layout:** in `pipeline.d`, set `frameEntries[2].texture.viewDimension` to `dim2DArray`. The texture count stays at **15/16**. The 1×1 default placeholder becomes a 1-layer array.
- **Settings (POD):** `CascadeSettings { uint count = 4; float lambda = 0.75 (log/linear PSSM blend); float maxDistance = 600; float blendFraction = 0.1; uint resolution = 2048; }`. It is stored in `LightSet.dir.cascades` (`light.d`). `MAX_CASCADES = 4`.
- **Fitting (`@nogc`, CPU, in `shadow.d`):**
  - `computeCascadeSplits(near, min(far, maxDistance), count, lambda)` uses the practical split scheme.
  - `fitCascade(camera, splitNear, splitFar, lightDir, resolution)` takes the 8 sub-frustum corners from the `Camera` and builds a bounding sphere around them, which keeps the cascade size stable under rotation. It then builds a light-space ortho and **snaps the origin to whole texels** so the shadows do not shimmer.
  - Z range: extend the near plane toward the light by a caster margin, so tall casters behind the camera still land in the map.
  - Unit-test both functions: monotonic splits, coverage of all sub-frustum corners, and a snapped origin that does not change for sub-texel camera moves.
- **Shadow pass:** `renderShadows` runs one depth pass per cascade into its layer view. `MAX_SHADOW_PASS_SLOTS` gains `MAX_CASCADES - 1` slots. Static `StaticInstanceBuffer` cell ranges and dynamic instances are culled **per cascade** with `Frustum.fromViewProj(cascadeVP[i])`, reusing the per-view caster-list machinery added for point and spot shadows in OW-2.
- **Shader (`shadows.wgsl`):** replace `sampleDirShadowPCF` with `sampleDirShadowCSM(worldPos, normal, L)`:
  - pick the cascade by `dot(worldPos - cameraPos, cameraForward)` against `cascadeSplits`;
  - scale the bias per cascade by texel world size;
  - use 3×3 PCF on `textureSampleCompare(dirShadowMap, s, uv, layer, depth)`;
  - blend linearly into the next cascade over `blendFraction`;
  - fade to lit between `fadeStart` and `fadeEnd`.
  - Keep the function name used by consumers, so `textured3d_pbr.wgsl`, `water_surface.wgsl`, `caustics_bed.wgsl` and `sky_dome.wgsl` only need recompiling.
- **Compatibility:** if a caller passes an explicit `ShadowMap*` through `setLights`/`setLighting` (the legacy path), the engine treats it as `count = 1` with the caller's VP. `renderShadows` with `castShadows` on the directional light owns a CSM automatically.
- **Debug:** `cascadeDebug` flag (in `FrameUniforms` `cascadeParams.w` sign bit or a separate uint) tints the cascades. Add a toggle in the editor light panel (`engine/editor/light_panel.d`).

**Done when:** the unit tests pass, `openworld-bench` shows stable shadows from 1 m to 600 m, the editor and the `pbr`, `water` and `golf` demos run with no validation errors, and `--assert-no-gc` holds.

## Step 2 — P3.3 Linear HDR atmospheric fog

**Files:** `assets/shaders/common/atmosphere.wgsl` (new), `textured3d_pbr.wgsl`, `water_surface.wgsl`, `scene/light.d` or new `scene/atmosphere.d`, `scene3d_textured.d`.

- POD `FogSettings { Vec3 color; float density; float heightBase; float heightFalloff; float startDistance; float maxOpacity; Vec3 sunColor; float sunPower; bool enabled; }` with `Scene3DTextured.setFog(ref const FogSettings)` (`@nogc`, writes into `frameData`).
- `fn applyFog(color, worldPos) -> vec3` evaluates exponential height fog analytically along the view ray, `∫ density·exp(-falloff·(h − base))`, with a guard for horizontal rays. Sun in-scattering comes from `pow(max(dot(viewDir, sunDir), 0), sunPower)`. Everything stays linear HDR, applied in the fragment shader before output, so it runs ahead of bloom and tonemap.
- Apply it in the opaque PBR and transparent PBR shaders, and later in terrain and decals (decals inherit fog because they are composited over fogged color: decal output is fogged with the same function).
- Water: replace its private fog with `applyFog` so the two match.

**Done when:** fog density 0 is pixel-identical to the current output (golden comparison in the `pbr` demo screenshot), and editor exposure of `FogSettings` in the scene/environment panel round-trips through `*.scene.json`.

## Step 3 — P3.4 Engine sky, runtime HDR IBL and global wetness

**Files:** `engine/gpu/sky.d` (new), `assets/shaders/sky.wgsl` (new, replaces `sky_dome.wgsl` usage), `assets/shaders/common/sky_eval.wgsl` (extracted from `water_env.wgsl`), `engine/gpu/ibl.d`, `assets/shaders/ibl_prefilter_cs.wgsl` (new), `engine/scene/time_of_day.d` (new), `textured3d_pbr.wgsl`.

- **Sky evaluation:** move `evalWaterSky` into `common/sky_eval.wgsl` as `evalSky(rayDir, sunDir, sunColor, cloudCoverage, time)`. Add moon, stars (hash on direction, faded by sun elevation) and cloud coverage. `water_env.wgsl` includes it, so the water look is unchanged.
- **`SkyRenderer` (`sky.d`):** a fullscreen triangle at far depth that reads only `@group(0)` (`invViewProj`, sun, `cloudCoverage`). `WaterUniforms` is no longer needed. It is drawn by `Scene3DTextured` when `setSky(true)` is set, before the opaque batches.
- **`TimeOfDay` / `Weather` (POD, `@nogc`):**
  - `TimeOfDay { float hours; float latitudeDeg; float dayLengthSec; }` produces `sunDir`, a sun color and intensity that warm at the horizon, the moon direction and an ambient scale.
  - `Weather { float cloudCoverage, rainIntensity, wetness, fogDensityScale; }` blends toward a target, with wetness rising and drying over time.
  - `applyEnvironment(ref LightSet, ref FogSettings, ref Scene3DTextured)` writes the directional light, fog and the frame floats.
- **Runtime HDR IBL (`ibl.d`):**
  - Switch the env, irradiance and specular cubemaps to `rgba16Float`. The `brdfLut` stays as it is and is never rebuilt.
  - Add `IblEnvironment.createDynamic(gpu, layout)` and `IblUpdater`. These compute passes render the sky into the 64² env cube (6 faces written through a `dim2DArray` storage view), then prefilter irradiance and the specular mips.
  - Amortization: one cube face and mip level per frame, about 6 × 6 dispatches in a cycle, driven only when the sun angle or `cloudCoverage` changes past a threshold. It writes into a back set and swaps the bind group when the set is complete, so the IBL never shows a half-updated state. This needs one extra set of cube textures. The set is not bound while it is being written, so the 16-texture budget is not affected.
  - No CPU allocation per update. The existing CPU paths (`create`, `createGradient`, `createSolid`) keep working.
- **Wetness:** `globalWetness` and `rainIntensity` use `_padFrame0..1`, and `cloudCoverage` uses `_padFrame2`. In `textured3d_pbr.wgsl`, compute `exposure = smoothstep(0.3, 0.8, N.y) * (1 − inst.custom.w)` and feed `globalWetness * exposure` into the existing OpenPBR coat darkening and roughness path that the water wet-line already uses (`evalRecentWaterWetness` output path). Add rain ripples or streaks only if they stay within the instruction budget (optional).

**Done when:**
- A day/night cycle at 60× speed shows a continuous sky, sun shadows that follow the light, and IBL that tracks the sky.
- The `water` demo looks unchanged.
- Wetness 0 leaves the output unchanged.
- No validation errors, and 0 GC bytes during IBL updates.

## Step 4 — P3.2 Chunked terrain with PBR splatting

**New package `engine/terrain/`:** `package.d`, `heightmap.d`, `chunks.d`, `material.d`, `renderer.d`, `physics.d`, `generate.d`. Shaders `assets/shaders/terrain_pbr.wgsl` and `terrain_shadow.wgsl`.

- **Data (`heightmap.d`):** `TerrainDesc { uint samplesX, samplesZ; float cellSize = 1.0; float heightScale; Vec3 origin; uint chunkCells = 128; }`. Heights are `Pod!float[]`. Sources:
  - a raw little-endian `.r16` loader (16-bit PNG through SDL3_image is not reliable);
  - `generate.d`, a procedural fBm with ridges and an erosion-lite pass, so tests and the demo need no assets.
  - 3 km at 1 m spacing is 3073² samples.
- **GPU:** an `r16Unorm` heightmap texture (about 18 MB). The `r16Unorm` binding was added in OW-2. Vertices read it with `textureLoad` (no filtering), and normals come from central differences in the vertex shader. A shared **grid template mesh** of (chunkCells+1)² vertices has per-LOD index ranges (LOD0–4: step 1, 2, 4, 8, 16) and a **skirt** ring per LOD to hide cracks. This uses no per-chunk vertex buffers.
- **Chunks (`chunks.d`, `@nogc`):** a 24 × 24 grid of 128 m chunks, with min/max height per chunk computed at load. Each frame:
  - frustum-cull the chunk AABBs;
  - pick the LOD by distance, with hysteresis;
  - write a `Pod!TerrainChunkInstance { origin xz, lod, morph }` buffer;
  - issue **one instanced draw per LOD**, using `firstIndex` from the LOD ranges.
  - Geomorph between LODs in the vertex shader removes popping.
- **Materials (`material.d`):** `TerrainLayer { StringId name; float uvScale; float heightBlend; float triplanarSharpness; ubyte physicsMaterial; }`, with 4–8 layers. `TerrainMaterial` builds three `TextureArray`s (albedo with height in alpha, normal, ORM) plus a splatmap `TextureArray` of 2 layers of RGBA8 (8 weights).
- **Pipeline (`renderer.d`):**
  - It reuses `scene.frameLayout()` (group 0: CSM, lights, fog, wetness) and `scene.iblLayout()` (group 2).
  - Group 1 holds the uniform, sampler, `heightmap`, `splatmap[]`, `albedoArray`, `normalArray` and `ormArray`. That is **5 textures, so 7 + 5 + 3 = 15/16**.
  - Height-blend picks the top-k layers by `weight × height`. Triplanar projection is used when `N.y` is below a threshold, for cliffs. Distance-based UV de-tiling uses two scales.
  - Lighting uses the same OpenPBR functions from `common/pbr_brdf.wgsl`, plus `applyFog` and the wetness mask.
  - The terrain casts shadows: `terrain_shadow.wgsl` draws the chunks into each CSM cascade with per-cascade culling. A hook is needed in `Scene3DTextured.renderShadows`, either an `extraShadowCasters` callback or a `ShadowCasterSet` the terrain registers into.
  - Integration point: `TerrainRenderer.draw(ref FrameContext, ref Scene3DTextured)` runs inside the opaque pass. `Scene3DTextured` exposes `frameBindGroup()` and `iblBindGroup()` getters.
- **Physics sync (`physics.d`):** `buildTerrainColliders(ref PhysicsWorld, ref const Terrain)` creates one `CookedHeightField` per 512 m tile (the 129/513-sample limit is checked against Box3D). It shares `globalMin/MaxHeight` so the tile borders are seamless. `materialIndices` comes from the dominant splat layer per cell, mapped to `TerrainLayer.physicsMaterial`, and holes come from a splat or hole mask (`heightFieldHole`). `terrain.heightAt(x, z)` and `normalAt` on the CPU must match the GPU bilinear interpolation for gameplay.
- **Editor / scene file:** a `Terrain` component referencing heightmap, splat and layer assets by `AssetGuid` gets inspector fields and serialization. Brush editing belongs to the separate roadmap item #7 (terrain and water editor) and is **out of scope** here.

**Done when:**
- A unit test checks that `heightAt` matches the Box3D raycast within 1 cm at 10,000 random points.
- There are no visible cracks at LOD transitions.
- The 3 km terrain uses at most 6 draw calls (5 LODs plus skirts) and 0 GC bytes per frame.
- Raycast `surfaceMaterialId` matches the visible dominant layer.

## Step 5 — P3.5 Projected decals

**Files:** `engine/graphics/decals.d` (new), `assets/shaders/decal_pbr.wgsl` (new), `engine/gpu/renderer.d` (pass ordering), `scene3d_textured.d` (hook).

- **`DecalSystem` (`@nogc`, POD ring buffer):** capacity is set at creation (for example 1024), the oldest decal is overwritten, and it supports `fadeOut` over time. Each `DecalInstance` holds `float[16] model` (the OBB), `float[16] invModel`, `uint layer` (atlas array index), `float[4] tint`, `float opacity`, `float angleFade`, `float normalStrength`, `float roughnessOverride` and `float age, lifetime`. API: `spawn(Vec3 pos, Vec3 normal, Vec2 size, float depth, float rotation, uint layer, …)` and `update(dt)`. Spawning from a physics `RayCastHit` is a one-liner, which suits skid marks and impacts.
- **Rendering:**
  - Unit cubes are instanced, with `cullMode = front` so they still draw when the camera is inside the box, `depthWrite = false`, and `depthCompare = always`. Depth is tested in the shader against the snapshot.
  - Pass order: opaque, including terrain, then `snapshotOpaque()`, then **decals**, then transparent and water. Decals blend into HDR color with premultiplied alpha.
  - The fragment shader reconstructs world position from `opaqueDepthView` using `invViewProj` and `viewportSize`, transforms it into decal space with `invModel`, discards outside the unit box, and derives an edge fade from the box coordinates. The surface normal comes from `dpdx`/`dpdy` of the reconstructed position. Angle fade is `dot(surfaceN, decalForward)`.
  - Decals are lit with the same OpenPBR plus fog functions, which needs the frame (group 0) and IBL (group 2) bind groups. Group 1 holds the depth snapshot, an `albedoArray` and a `normalArray`, so 3 + 7 + 3 = **13/16**.
- **Culling:** frustum-cull against the decal OBB spheres on the CPU, then upload the visible ones into a pre-allocated instance buffer.

**Done when:** 500 decals (`openworld-bench --decals=500`) render with correct projection on terrain and props and no stretching on steep faces, at 0 GC bytes and with no validation errors. A unit test covers ring-buffer wraparound and expiry.

## Step 6 — Outdoor DoD demo, perf gate and docs

- **New config `outdoor` (`source/demo/outdoor.d`):** a 3 km procedural terrain with 4 biomes (grass, rock, sand, snow) by height and slope, the 12k rocks from `openworld-bench`, `TimeOfDay` plus rain, 500 decals, and a fly camera.
  - It accepts `--headless-frames=600 --assert-no-gc` and a `--time-scale` flag.
  - It prints draw calls, cascade casters and GPU timing if available.
- **Docs:**
  - New `docs/terrain-guide.md`.
  - `docs/graphics.md` gets CSM, fog, sky, IBL, wetness and decals.
  - `docs/game-development-guide.md` gets short entries linking to the above.
  - `docs/editor-guide.md` gets the environment panel and the cascade debug view.
  - Update the `CHANGELOG.md` entry.
  - Mark `P3.x` done in `plan-open-world-readiness.md` and update `roadmap.md` #13.

## Verification (each step and final)

```bash
dub test --config=library                                   # unit tests (splits, fitting, heightAt, ring buffer)
dub run --config=lint                                       # GC-safe storage lint (Pod!T on every new buffer)
dub run --config=openworld-bench -- --headless-frames=600 --assert-no-gc
dub run --config=outdoor -- --headless-frames=600 --assert-no-gc   # from step 4 on
dub run --config=test-physics-box3d                         # heightfield regression
dub run --config=editor -- --headless-frames=600 --assert-no-gc
dub run --config=water   # visual: unchanged look after CSM/fog/sky refactors
dub run --config=pbr     # visual: fog=0 / wetness=0 identical
```

Also check: zero WGPU validation messages in logs, and a WASM export (`dub run --config=export -- --target=web`) that still compiles the shaders. That covers WebGPU limits: 16 sampled textures and `dim2DArray` depth comparison.

## Risks and decisions to confirm

- **Uniform layout churn:** every pipeline sharing `@group(0)` changes at once in step 1. The mitigation is to land it alone, then test all demos plus the editor before going further.
- **Storage writes to cube faces (`rgba16Float`)** go through `dim2DArray` storage views, which is core WebGPU. If a backend rejects it, the fallback is a fragment-shader render pass per face.
- **Box3D heightfield sample limit per shape** must be checked in step 4 before tile size is fixed (512 m vs 256 m).
- **Terrain brush editing** stays in roadmap item #7. This phase loads only heightmaps and splatmaps that are procedural or on disk.
