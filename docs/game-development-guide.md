# Game Development Guide

A concise, practical guide to building 2D and 3D games with the engine's high-level D API (`@safe:` + DIP1000). Use this guide for quick-start usage, key options, and short examples, and follow the linked deep-dive docs for full architecture and edge cases.

---

## 1. Module Map & Imports

A single `import engine;` re-exports the core runtime (`core`, `ecs`, `math`, `platform`, `gpu`, `graphics`, `meshopt`, `scene`, `assets`, `audio`, `devtools`, `physics`, `app`). Subsystems outside the core runtime are imported explicitly when needed:

| Area | Primary Modules | Deep Dive |
|:---|:---|:---|
| **App, Window & Loop** | `engine.app`, `engine.platform.*` | [multiplatform-and-shaders.md](multiplatform-and-shaders.md) |
| **3D, OpenPBR, IBL, Shadows & Post** | `engine.scene.*`, `engine.graphics.*`, `engine.gpu.*` | [graphics.md](graphics.md) · [plan-openpbr.md](plan-openpbr.md) · [plan-post-processing.md](plan-post-processing.md) |
| **Outdoor: Terrain, Sky, Weather, Decals** | `engine.terrain`, `engine.scene.time_of_day`, `engine.scene.atmosphere`, `engine.gpu.ibl_dynamic`, `engine.graphics.decals` | [terrain-guide.md](terrain-guide.md) · [graphics.md](graphics.md#outdoor-rendering-ow-3) |
| **Water (waves, surface, buoyancy)** | `engine.water` (opt-in) | [water-guide.md](water-guide.md) |
| **2D Sprites & Cameras** | `engine.graphics.sprite` | [graphics.md](graphics.md) |
| **2D UI & Fonts (`SDL3_ttf`)** | `engine.ui` (opt-in), `engine.gpu.text` | [editor-guide.md](editor-guide.md) · [export-guide.md](export-guide.md) |
| **ECS, Scripts & GC-Safe Memory** | `engine.ecs.*`, `engine.core.*`, `engine.script` (opt-in) | [scripting-guide.md](scripting-guide.md) · [why-this-is-fast.md](why-this-is-fast.md) · [gc-safe-architecture-plan.md](gc-safe-architecture-plan.md) · [symgc-multiplatform-integration.md](symgc-multiplatform-integration.md) |
| **Assets & Mesh Optimization** | `engine.assets.*`, `engine.meshopt.*` | [export-guide.md](export-guide.md) · [plan-meshoptimizer.md](plan-meshoptimizer.md) |
| **Physics (Box3D)** | `engine.physics` | [physics-quickstart.md](physics-quickstart.md) |
| **Skeletal Animation (`ozz`)** | `engine.animation` (opt-in), `engine.animation.ecs` | [animation-guide.md](animation-guide.md) |
| **Audio (Buses, DSP, 3D, OGG)** | `engine.audio` | [audio-guide.md](audio-guide.md) |
| **Navigation (Recast/Detour)** | `engine.nav` (opt-in) | [navigation-guide.md](navigation-guide.md) |
| **DevTools & Hot-Reload** | `engine.devtools.*`, `engine.hotreload.*` (opt-in) | [multiplatform-and-shaders.md](multiplatform-and-shaders.md) |
| **Visual Editor & Release Export** | `source/editor/*`, `tools/export_main.d` | [editor-guide.md](editor-guide.md) · [export-guide.md](export-guide.md) |

---

## 2. Quick Start & Game Loop

`App` owns the SDL3 window, `GpuContext`, `Renderer` (offscreen HDR target + post-processing), `InputState`, and per-frame `FrameArena`. Every frame follows one pass order:

```
pollEvents -> handleResize -> logic/physics -> scene.begin / draw* -> beginFrame
  -> renderShadows / scene.end / gizmos / HDR sprites -> resolvePost -> LDR sprites / UI / text -> endFrame
```

```d
module mygame;

import engine;

@safe:

void main() {
    auto app = App.create("My Game", 1280, 720);
    scope(exit) app.destroy();

    auto scene = Scene3D.create(app.gpu);
    scope(exit) scene.destroy();
    auto cube = Mesh.cube(app.gpu);
    scope(exit) cube.destroy();
    auto text = TextRenderer.create(app.gpu, 1280, 720);
    scope(exit) text.destroy();

    auto camera = Camera.create(0.9f, 1280, 720);
    camera.lookAt(Vec3(0, 3, 6), Vec3(0, 0, 0));
    auto fps = FpsCounter.create();
    float angle = 0;

    app.run((float dt) {
        app.pollEvents();
        app.handleResize();
        fps.tick();
        if (app.input.keyPressed(Key.escape)) app.close();

        angle += dt;
        auto frame = app.beginFrame(Color4(0.06f, 0.08f, 0.12f));
        if (!frame.valid) return;

        scene.begin(camera);
        scene.draw(cube, Vec3(0, 0, 0), Vec3(1, 1, 1), Color4.white(), angle);
        scene.end(frame);

        app.resolvePost(frame); // closes HDR scene pass, runs bloom/tonemap/FXAA, opens LDR pass
        text.beginFrame();
        text.drawText(frame, fps.text(), 12, 12, 2);
        app.endFrame(frame);
    });
}
```

> **Tip:** Prefer `app.run((float dt) { ... })` over a raw `while (app.running())` loop — it drives native `MonoTime` delta time on desktop and a browser-paced frame on WebAssembly (call `app.pollEvents()` exactly once per frame). See [export-guide.md](export-guide.md) for web export. Calling `app.endFrame(frame)` runs `resolvePost(frame)` automatically if you omitted it.

### `App` & `Window` Key Options

- **Present mode & VSync:** `App.create(title, w, h, WGPUPresentMode.fifo)` (`fifo` = VSync, `mailbox` / `immediate` = uncapped). Toggle at runtime via `app.setVsync(bool)` or `app.setPresentMode(mode)`; a hidden or occluded window can make `fifo` block for a long time on Wayland (the compositor stops sending frame callbacks), so headless smoke tests and tools that hide the window should call `app.setVsync(false)` first; set frame budget for `steadygc` slack stepping with `app.setTargetFps(fps)` (`0` = uncapped).
- **Window flags & runtime controls:** `Window.create(title, w, h, WindowOptions(fullscreen, borderless, resizable, highPixelDensity, hidden))`; at runtime call `app.setFullscreen(bool)` or `app.setSize(w, h)` (windowed only; both reconfigure the swapchain and post targets, while `window.setFullscreen` / `window.setSize` alone leave them at the old size and do not update `width()/height()`; `setSize` takes SDL window coordinates, so read the drawable size back from `window.width/height`), `app.window.` `setTitle(text)`, `setResizable(bool)`, `setBordered(bool)`, `setIcon(rgba, w, h)`, `setCursorVisible(bool)`, `setCustomCursor(rgba, w, h, hotX, hotY)`, `resetCursor()`, and `setRelativeMouseMode(bool)`.
- **Screenshots:** Call `app.saveScreenshot("shot.png")` before `app.endFrame(frame)` to capture the presented frame via SDL3 (`SDL_SavePNG`).

---

## 3. 3D Rendering, OpenPBR Lighting & Shadows

### 3.1 Colored 3D (`Scene3D` + `Mesh`)

`Scene3D` batches up to **16 mesh kinds** and **8,192 instances per mesh** per frame:

```d
auto cube = Mesh.cube(app.gpu);        // also: pyramid, diamond, sphere, plane
auto custom = Mesh.fromData(app.gpu, verts[], indices[]); // Vert(pos, normal)
scene.begin(camera);
scene.draw(cube, pos, scale, color, rotationY);
scene.drawMatrix(cube, modelMatrix, color);
scene.end(frame);
```

### 3.2 Textured OpenPBR 3D (`Scene3DTextured` + `TexMesh` + `Material`)

`Scene3DTextured` batches `(TexMesh, Material)` pairs using single-pass **OpenPBR Surface v1.1** shading, multi-light PCF shadows, and split-sum IBL.

- **Key `MaterialParams` fields:** `baseColor`, `baseWeight`, `baseMetalness`, `baseDiffuseRoughness`, `specularWeight`, `specularRoughness`, `specularColor` ($F_{82}$ edge tint on metals), `specularIor`, `specularAnisotropy`, `anisotropyRotation`, `coatWeight`, `coatRoughness`, `coatIor`, `coatColor`, `coatDarkening`, `fuzzWeight`, `fuzzColor`, `fuzzRoughness`, `thinFilmWeight`, `thinFilmThicknessMin`, `thinFilmThickness`, `thinFilmIor`, `transmissionColor`, `transmissionWeight`, `transmissionDepth`, `transmissionDispersion`, `transmissionThickness`, `subsurfaceWeight`, `subsurfaceColor`, `subsurfaceRadius`, `subsurfaceRadiusScale`, `subsurfaceAnisotropy`, `emissionColor`, `emissionLuminance`, `geometryOpacity`, and `flags` (`MaterialFlags.metallicRoughness`, `normal`, `occlusion`, `emissive`, `coat`, `coatNormal`, `fuzz`, `anisotropy`, `thinFilm`, `transmission`, `thinWalled`, `subsurface`, `ssr`, `unlit`).
- **Key `Material` & reflection options:** Optional per-pixel layer maps via `MaterialLayerMaps(coat, coatNormal, fuzz, anisoFilm, transmission)` as the 10th argument to `Material.create(...)`, `mat.renderState = RenderState(BlendMode.alpha /* or additive/opaque */, depthWrite: true, doubleSided: false)`, `mat.updateParams(app.gpu, params)`, custom surface WGSL shaders via `scene.createSurfaceShader(wgsl)` (`mat.surfaceShader = id; mat.updateSurfaceParams(app.gpu, float16);`), and per-instance `custom` vec4 via `scene.drawMatrix(mesh, mat, model, tint, custom)`. Setting `transmissionWeight > 0` captures the 5-mip HDR opaque pyramid before Pass 2 and renders refraction with roughness blur, Beer-Lambert absorption, and chromatic dispersion; `subsurfaceWeight > 0` evaluates pre-integrated wrap SSS (or back-face translucency with `MaterialFlags.thinWalled`); `scene.setSsr(true)` + `MaterialFlags.ssr` enables screen-space reflections, and `scene.setReflectionProbes(...)` (or `@component ReflectionProbe` entities in `SceneWorld`) adds parallax-corrected local probes. Non-uniform scales on `model` transform normals accurately via the $3 \times 3$ adjugate in the vertex shader (`Mat4.transformNormal`).

- **Animated vertex shaders (wind, sway):** write a surface shader with `fn displace(localPos, localNormal)` or the richer `fn displaceEx(d: DisplaceIn)` (instance `custom` vec4, instance pivot/scale, mesh UV) and register it with `scene.createSurfaceShader(wgsl)`. The hook also runs in shadow passes, so cast shadows animate with the geometry. Example and reference: [docs/graphics.md](graphics.md#custom-surface-shaders-surface-displace-displaceex).

```d
auto scene = Scene3DTextured.create(app.gpu);
auto ibl = IblEnvironment.createGradient(
    app.gpu, scene.iblLayout(),
    [0.18f, 0.30f, 0.55f], [0.45f, 0.55f, 0.65f], [0.12f, 0.10f, 0.08f]
);
scene.setEnvironment(ibl);
scene.setIblIntensity(1.0f);

auto sampler = Sampler.create(app.gpu, TextureFilter.linear, TextureWrap.repeat);
auto albedo  = Texture.fromImageFile(app.gpu, "assets/crate.png");
auto mesh    = TexMesh.cube(app.gpu); // also: quad, sphere(segments, rings, withTangents)

MaterialParams p;
p.baseMetalness = 0.0f;
p.specularRoughness = 0.35f;
p.coatWeight = 0.4f;
auto mat = Material.create(app.gpu, scene.materialLayout(), sampler, albedo, p, null, null, null, null);
```

- **Second scene without its own IBL:** `Scene3DTextured.create(gpu, maxBatches, createIbl: false)` skips the procedural sky and prefilter (~1 s in debug builds) and starts with a flat-grey environment. Use it for an extra scene (for example unlit particle pools) and bind the shared environment right away with `scene.setEnvironment(ibl)` or `scene.setEnvironmentBindGroup(dynamicIbl.bindGroup())`.
- **What SSR reflects:** the opaque scene only (cars, buildings, terrain as standard opaque materials). Other `MaterialFlags.ssr` materials, transparent surfaces and off-screen objects need a `ReflectionProbe`. Details: [graphics.md](graphics.md).

### 3.3 Multi-Light (Clustered Forward) & Automatic Shadows

Clustered Forward rendering supports **1 directional**, up to **1,024 point**, and up to **256 spot** active lights per frame, with automatic shadow rendering across **1 dir (2048²)**, **4 point cubemaps (512²/face)**, and **2 spot (1024²)** shadow casters:

- Use stack-friendly `LightSet` for compact scenes (up to `32` point / `4` spot inline lights).
- Use `@nogc` `LightList` (or `scene.addPointLight()` / `scene.addSpotLight()` between `begin` and `end`) to scale up to `1,024` point + `256` spot lights with zero stack bloat and zero GC allocations.

```d
LightList lights; // reuse across frames; lights.release() on shutdown
scope(exit) lights.release();

lights.clear();
lights.dirEnabled = true;
lights.dir.direction = Vec3(0.45f, 1.0f, 0.35f).normalized(); // surface -> light
lights.dir.viewProj = directionalLightVP(lights.dir.direction, Vec3(0, 0, 0), 20.0f);
lights.dir.castShadows = true;
lights.addPoint(GpuPointLight(Vec3(-2, 3, 1), Vec3(0.3f, 0.8f, 1.0f), 12.0f, 18.0f, true));

scene.begin(camera);
scene.drawMatrix(mesh, mat, model, Color4.white());
scene.renderShadows(frame, lights); // automatic depth pass before color submission
scene.end(frame);                   // runs Clustered Forward GPU binning + PBR shading
```

> **Details & Benchmarks:** See [Clustered Forward Lighting](graphics.md#clustered-forward-lighting-enginegpuclustered-clustered_cull_cswgsl) and `dub run --config=clustered-bench` (`--lights=1024 --spots=128`, toggled live with `[C]`).

> **Water & Refraction:** Call `app.renderer.snapshotOpaque(frame)` after opaque geometry to capture HDR color and `depth32Float` for refractive/SSR shaders with zero cost on scenes that do not use it (`dub run --config=water`).

### 3.4 SceneGraph, Camera Controllers & Procedural Geometry

- **Transform hierarchy (`engine.scene.graph`):** Flat-array `SceneGraph` with O(N) world-matrix propagation:
  ```d
  auto graph = SceneGraph.create();
  auto sun   = graph.addChild(ROOT, Transform(Vec3(0, 0, 0), Vec3(2, 2, 2)));
  auto moon  = graph.addChild(sun,  Transform(Vec3(5, 0, 0), Vec3(0.4f, 0.4f, 0.4f)));
  graph.transform(sun).rotation = Quat.fromAxisAngle(Vec3(0, 1, 0), angle);
  graph.updateWorld();
  scene.drawMatrix(mesh, mat, graph.worldMatrix(moon), Color4.white());
  ```
- **Camera controllers (`engine.scene.controllers`):** `OrbitCamera.create(target, dist)` (options: `minPitch`/`maxPitch`, `wheelZoomSpeed`, `dragToRotate`), `FlyCamera.create(startPos)`, and `FirstPersonCamera.create()` — update via `.update(app.input, dt, camera)` (or `.update(app.input, dt, eyePos, camera)` for first-person).
- **Math, procedural shapes & noise:** `Mat4.trs(pos, rot, scale)` pairs with `engine.graphics.shapes` (`MeshData` builders: `box`, `quad`, `uvSphere`, `icosphere`, `cylinder`, `cone`, `frustum`, `capsule`, `prism`, `torus` with `.transform()`, `.merge()`, `.toTexMesh(gpu)`) and `engine.math.noise` (`valueNoise2D/3D`, `simplex2D/3D`, `fbm2D/3D`, `ridged2D/3D`).

### 3.5 Open-World Scenes: glTF Assets, Static Props, Culling & LOD

```d
import engine.graphics.model, engine.graphics.material_pool;
import engine.scene.static_instances;

// Multi-node glTF/GLB with mips and load-time LOD chains.
GltfLoadOptions lo; lo.generateLods = true;
auto car  = loadGltfAsset(app.gpu, "assets/models/car.glb", scene.materialLayout(), sampler, lo);
auto rock = loadGltfAsset(app.gpu, "assets/models/rock_boulder.gltf", scene.materialLayout(), sampler, lo);

// Thousands of static props: sorted into cells and uploaded once.
StaticInstanceDesc[] props;   // (meshIndex, materialIndex, model)
auto rocks = StaticInstanceBuffer.build(app.gpu, [&rock.subMeshes[0]], [rock.materialPtr(0)], props);

// Per-instance state is POD: hide parts, swap materials, detach a door.
ModelInstance inst;
inst.setMaterialOverride(0, pool.add(bluePaint));
auto door = detachSubMesh(car, inst, "door_fl", carWorld); // spawn a body from door.world / door.localBounds

// Frame loop (zero GC): culling and LOD are automatic.
scene.begin(camera);
scene.submitStatic(rocks);
drawModel(scene, car, inst, carWorld, pool);
scene.renderShadows(frame, lights);
scene.end(frame);
auto st = scene.stats();      // draw calls, visible instances, LOD histogram
auto bs = scene.batchStats(); // batches used this frame, peak, capacity, growths
```

- **Batch budget:** `Scene3DTextured.create(gpu, maxBatches)` sets only the initial size of the `(mesh, material, lod)` batch table. The table doubles when a frame needs more batches, so draws are not dropped. Use `batchStats().peak` in `--perf` output or a headless budget check, and raise `maxBatches` when `growths > 0`. Details: [graphics.md › Batch table](graphics.md#batch-table).

- **Culling:** frustum culling is on by default (`scene.setCulling(false)` to disable); add `scene.setDistanceCull(maxDistance, minPixelSize)` for small dynamic props and `StaticBuildOptions` / `sib.setMeshCull` for static ones.
- **LOD:** `drawMatrix` defaults to `LOD_AUTO` (screen-space error, `scene.setLodScreenHeight(h)`, `setLodBias`); static buffers pick one LOD per 128 m cell.
- **Textures:** `TextureDesc.mipped()`, `SamplerDesc.maxAnisotropy`, `TextureArray`, `Texture.fromR16` / `fromR32F`.
- **sRGB color textures:** `TextureDesc.mippedSrgb()` for albedo/emissive, `GltfLoadOptions.gltf.srgbColor = true` for glTF, and `app.post.outputTransfer = OutputTransfer.srgb` for the exact display curve. Off by default. See [graphics.md](graphics.md#textures-and-materials).
- **Dynamic queries:** `SpatialGrid` (64 m loose grid) returns the entity ids inside a frustum and distance.

Deep dive: [graphics.md § Open-World Rendering](graphics.md#open-world-rendering-ow-2) · benchmark: `dub run --config=openworld-bench`.

### 3.6 Billboard Particles (`engine.graphics.particles`)

```d
auto particles = ParticleSystem.create(2000);
ParticleEmitter plume;
plume.rate = 90.0f; plume.coneDeg = 12.0f; plume.speedMin = 4.0f; plume.speedMax = 8.0f;
plume.colorStart = Color4(0.4f, 1.2f, 1.8f, 1.0f);

// Per frame:
plume.position = emitterPos;
plume.emit(particles, dt); // or plume.burst(particles, 32)
particles.update(dt);
particles.draw(scene, quadMesh, glowMat, camera); // pair with Texture.softDisc + BlendMode.additive
```

Deep dive: [graphics.md](graphics.md) · [plan-openpbr.md](plan-openpbr.md) · [plan-water-realism.md](plan-water-realism.md).

---

### 3.7 Outdoor Scenes: Terrain, Sky, Weather and Decals

```d
import engine.terrain, engine.graphics.decals, engine.gpu.ibl_dynamic;
import engine.scene.time_of_day, engine.scene.atmosphere;

// Load time
auto h = generateHeights(td);                       // TerrainDesc: samples = chunks * 128 + 1
auto terrain = Terrain.create(h, generateBiomeSplat(h, 1024, 1024));
auto tr = TerrainRenderer.create(app.gpu, scene, terrain, terrainMat);
tr.attach(scene, terrain);                          // keep tr / scene / terrain in place afterwards
buildTerrainColliders(physics, terrain, layers[]);  // heightAt == physics surface (< 1 cm)
scene.setSkyEnabled(true);
auto ibl = DynamicIbl.create(app.gpu, scene.iblLayout());
auto decals = DecalSystem.create(1024);
auto dr = DecalRenderer.create(app.gpu, scene, decalAlbedo[], decalNormal[], 256, 1024);
dr.attach(scene, app.renderer, decals);

// Frame loop (zero GC)
tod.advance(dt); weather.update(dt);                // TimeOfDay / Weather (weather.setTarget(0.9, 1) = storm)
auto env = evaluateEnvironment(tod, weather);
LightSet lights; FogSettings fog;
applyEnvironment(env, lights, fog, 0.0003f);        // sun or moon light + fog color/density
lights.dir.castShadows = true;                      // 4 cascades by default (lights.dir.cascades)
fog.enabled = true;
applyEnvironmentToScene(env, scene);                // sky, stars, moon, wetness, clouds
scene.setFog(fog);
auto ip = skyIblParams(env, time);
ibl.request(ip); ibl.update();                      // one compute step per frame
scene.setEnvironmentBindGroup(ibl.bindGroup());
tr.update(terrain, camera);
decals.update(dt); dr.update(decals, camera);
scene.begin(camera);
// ... draws ...
scene.renderShadows(frame, lights);
scene.end(frame);

// Gameplay
float y = terrain.heightAt(x, z);
decals.spawn(hit.point, hit.normal, Vec2(2, 2), 1.0f, angle, layer);  // skid mark / impact
```

- **Shadows:**
  - `CascadeSettings` sets count, split lambda, `maxDistance` and resolution.
  - `lights.dir.debugCascades = true` tints the cascades.
- **Fog:** `FogSettings` sets density, height base and falloff, start distance and sun lobe. Scene files store it under `settings.fog`.
- **Wetness:** `scene.setWeather(wetness, rain, clouds)` drives it. Instances with `custom.w = 1` are sheltered.
- **Terrain:**
  - Up to 8 layers, using `TerrainLayer` (`uvScale`, `heightBlend`, `triplanarSharpness`, `physicsMaterial`).
  - Configure collider filtering, ECS `EntityId`, hit events, and tile body capture with `TerrainColliderDesc` (`buildTerrainColliders(physics, terrain, layers[], desc, outBodies)`).
  - Synthesize custom tileable PBR layers with `ProcLayerDesc` (`ProcNoiseBasis.fbm`, `ridged`, `voronoi`, `brick`) + `generateLayerTextures`, or bake custom heightfields via `bakePbrMapsFromHeightField` and `engine.math.noise` tiled primitives.
  - At most 5 draws per frame.
  - `TerrainRenderer.stats()` reports per-frame counts.
- **Decals:** `DecalStyle` sets tint, opacity, angle fade, roughness, metallic, wetness response, lifetime and fade-out.

Deep dives: [terrain-guide.md](terrain-guide.md) · [graphics.md § Outdoor Rendering](graphics.md#outdoor-rendering-ow-3) · demo: `dub run --config=outdoor` (`--tod=18.5 --rain --debug-cascades --decals=500 --view=1`).

### 3.8 Water (`engine.water`)

```d
import engine.water;

auto water = WaterRenderer.create(app.gpu, scene);
water.attach(scene, app.renderer);
immutable id = water.addBody(WaterBody.ocean());   // or WaterBody.river(); up to 4 bodies
// per frame, before beginFrame:
water.update(camera, time);

WaveSet waves = WaveSet.ocean();          // or WaveSet.river() / custom WaveComponents
waves.amplitudeScale = 1.0f;
float y = waveHeightAt(waves, x, z, time, 3);   // water height above world XZ (gameplay)
WaveSample s = sampleWaves(waves, gx, gz, time); // displaced surface point + normal + crest
```

- Up to 8 Gerstner components, plus optional wave-group modulation and a river channel taper.
- `WaterBody` (POD): position, level, `WaterStyle` ocean/river, `WaveSet`, `WaterOptics`, `WaterFeature` bits (refraction, SSR, transparency, simulation, OpenPBR, wet marks); `setObstacles` for rocks and piers.
- Enable the engine sky (`scene.setSkyEnabled(true)`); the water reflects it.
- Submerged meshes, terrain and decals get sun caustics automatically (`WaterBody.causticsStrength`).
- Gameplay: `water.surfaceAt(x, z, time, p)` gives height, normal and river current; `applyBuoyancy(physics, body, sphereProbes(r)[], surfaceFn)` keeps Box3D bodies afloat.
- Stone near water: `wetSurfaceParams(dryStoneParams())`, `mossSurfaceParams`, `submergedSurfaceParams` (`engine.graphics.material_presets`).
- Scenes / editor: `WaterSurface` component (**Criar > Água**, inspector section **Água**); the entity transform places the water.

Deep dive: [water-guide.md](water-guide.md) · demo: `dub run --config=water` (`--river`).

## 4. Post-Processing (`app.post()` & Custom Passes)

Scenes render into `rgba16Float` HDR and resolve into the swapchain inside `app.resolvePost(frame)`. Configure built-in effects via `app.post()`:

- **Tone mapping (`tonemapMode`):** `0` = ACES, `1` = Reinhard, `2` = Linear, `3` = AgX, plus `exposure`, `saturation`, and `contrast`.
- **Bloom & AA:** `bloom` (`bool`), `bloomThreshold`, `bloomKnee`, `bloomStrength`, `bloomClamp`, `bloomRadius` (`3..7` mip levels), `bloomScreen` (`bool`), and `fxaa` (`bool`).
- **Quality AA & sharpening:** `app.post.aaMode = AaMode.fxaaQuality` (edge search, `fxaaSubpix`, `fxaaEdgeThreshold`) and `app.post.sharpness = 0.5f` (contrast adaptive sharpening after any AA mode, 0 = off). See [graphics.md](graphics.md#antialiasing-and-sharpening).
- **Custom fullscreen WGSL passes:** Inject passes at `PostStage.beforeTonemap` (HDR), `PostStage.afterTonemap` (LDR pre-UI), or `PostStage.afterUi`:

```d
app.post.tonemapMode = 3; // AgX
app.post.bloomRadius = 6;
app.post.exposure    = 1.15f;

immutable passId = app.renderer.addPostPass(q{
    @fragment fn fs_main(@location(0) uv: vec2<f32>) -> @location(0) vec4<f32> {
        let c = textureSample(srcTex, srcSamp, uv);
        return vec4<f32>(c.rgb * params.p0.xyz, c.a);
    }
}, 64, PostStage.afterTonemap);
app.renderer.updatePostPassParams(passId, tintValues); // e.g. float[4] tintValues = [1, 0.95f, 0.9f, 1];
```

Deep dive: [graphics.md](graphics.md) · [plan-post-processing.md](plan-post-processing.md).

---

## 5. 2D Sprites & Cameras (`engine.graphics.sprite`)

`SpriteRenderer` batches and sorts 2D quads by `(layer, zOrder, sequence)` with `@nogc` draw-call coalescing. Choose HDR or LDR per draw pass based on `app.resolvePost(frame)`:

| Stage | Target | Best Used For |
|:---|:---|:---|
| **Before `resolvePost`** (`HDR`) | `rgba16Float` + `depth24Plus` (`depthCompare = always`) | Glowing particles/bullets (`Color4 > 1.0` + `SpriteBlendMode.additive`) that feed into bloom & tone mapping |
| **After `resolvePost`** (`LDR`) | Swapchain (no depth) | Crisp pixel art, 2D games, and HUD sprites with exact display colors |

```d
auto sprites = SpriteRenderer.create(app.gpu, maxSprites: 4096, defaultFilter: TextureFilter.nearest);
scope(exit) sprites.destroy();
auto sheet = Texture.fromImageFile(app.gpu, "assets/player_sheet.png");
scope(exit) sheet.destroy();
auto anim = SpriteAnim.create(columns: 4, rows: 2, startFrame: 0, frameCount: 4, fps: 10.0f);
auto cam2d = Camera2D.screen(app.window.width(), app.window.height()); // or Camera2D.world(w, h)

// Inside app.run:
anim.update(dt);
immutable mouseWorld = cam2d.screenToWorld(Vec2(app.input.mx(), app.input.my()));
app.resolvePost(frame);
sprites.begin(cam2d);
sprites.drawRect(Vec2(640, 360), Vec2(220, 120), Color4(0.12f, 0.14f, 0.22f, 0.9f), layer: 0);
sprites.drawAnim(sheet, anim, mouseWorld, Vec2(64, 64), layer: 1, zOrder: 1.0f);
sprites.end(frame);
```

Also includes POD ECS components `Transform2D` and `Sprite`, `SpriteRegion.fromPixels` / `fromGrid` / `fromFrameIndex`, `setFilter`, `setSorting`, and transactional `reloadShader`. Deep dive: [graphics.md](graphics.md).

---

## 6. 2D UI, Vector Primitives & Fonts (`engine.ui`, `engine.gpu.text`)

Import `engine.ui` for retained flexbox layouts, widgets, docking, vector primitives, and TrueType Unicode fonts via `SDL3_ttf` + FreeType 2:

- **Widgets (`engine.ui.widgets`):** `label`, `button`, `iconButton`, `checkbox`, `slider`, `dragValue`, `textField`, `image`, `imageRotated`, `minimapImage`, `scrollView`, `splitter`, `tabBar`, `treeView`, and `menu`, plus `DockSpace` (`engine.ui.dock`).
- **Fonts (`engine.ui.text.font.Font`):** `loadFromFile(path, pxHeight, useSdf = true)` or `loadFromMemory(...)`, `loadFromFileCached(path, cachePath, ...)` (keeps the baked atlas on disk, much faster from the second run on), `setHinting(TTF_HintingFlags.normal | light | mono | none | lightSubpixel)`, `addFallbackFont(bytes)`, and automatic kerning (`getKerning`).
- **Immediate 2D primitives (`UiBatchRenderer`):** `drawRect`, `drawRectRotated`, `drawLine`, `drawTriangle`, `drawPolygon`, `drawPolyline`, `drawArc`, `drawCircle`, `drawCircleOutline`, `drawImage`, `drawImageRotated`, `drawImageUvRotated`, `pushClip`/`popClip`, `pushCircleClip`/`popCircleClip`.

```d
import engine.ui;

Font font;
font.loadFromFile("assets/fonts/default.ttf", 16.0f, /*useSdf=*/true);
auto tree = UiTree.create();
UiBatchRenderer ui;
ui.init(app.gpu.getDevice(), app.gpu.getQueue(), app.gpu.getFormat(), font);

// Per frame after app.resolvePost(frame):
computeLayout(tree, tree.root, app.window.width(), app.window.height());
ui.begin();
ui.renderTree(tree, tree.root, font);
ui.flush(frame.pass, app.window.width(), app.window.height());
```

For zero-asset debug HUD text, use `TextRenderer` (`engine.gpu.text`, embedded 8×8 CP437 ASCII font). Testbed: `dub run --config=ui-gallery`. Deep dives: [editor-guide.md](editor-guide.md) · [export-guide.md](export-guide.md).

---

## 7. ECS, Scripting & GC-Safe Memory (`engine.ecs`, `engine.script`, `engine.core`)

### 7.1 Compile-Time ECS (`World!(Components...)`) & Gameplay Scripts (`SceneWorld`)

All components must pass `isPod!T` (no `string`, slices, classes, or delegates):

```d
struct Position { float x = 0, y = 0, z = 0; }
struct Velocity { float x = 0, y = 0, z = 0; }
alias GameWorld = World!(Position, Velocity);

GameWorld world;
auto e = world.spawn();
world.set(e, Position(0, 0, 0));
world.set(e, Velocity(1, 0, 0));
foreach (id; world.query!(Position, Velocity)()) {
    world.get!Position(id).x += world.get!Velocity(id).x * dt;
}
```

For editor-integrated dynamic ECS and hot-reloadable D gameplay scripts (`import engine.script;`), annotate POD structs with `@component` (`@export_`, `@range`, `@tooltip`, `@header`, `@hide`, `@formerlyNamed`, `@runInEditor`) and lifecycle hooks (`onStart`, `onUpdate`, `onFixedUpdate`, `onLateUpdate`, `onDestroy`, `onValidate`), or mark free functions `@system(Stage.update, 0)`.

### 7.2 GC-Safe Storage Primitives & Optional `steadygc`

- **Engine storage rules:** Use `Pod!T` for buffers, `Handle!T` for resource references, `StringId` + `StringTable` for interned identifiers, and `app.arena()` (`FrameArena`, reset automatically in `endFrame()`) for per-frame `alloc!T` and `fmt(...)` without GC allocations.
- **Optional 3-tier GC:** Stock DMD/LDC GC runs by default (Tier 1); pass `--DRT-gcopt=gc:sdcq` to enable `steadygc` concurrent sweeping (Tier 2), or build `--config=player-symgc` / `benchmark-symgc` with card barriers (`-preview=gcbarrier` / `-gc-card-marking`) for ~0.09–0.13 ms p99 pauses (Tier 3).

Deep dives: [scripting-guide.md](scripting-guide.md) · [why-this-is-fast.md](why-this-is-fast.md) · [gc-safe-architecture-plan.md](gc-safe-architecture-plan.md) · [symgc-multiplatform-integration.md](symgc-multiplatform-integration.md).

---

## 8. Input: Keyboard, Mouse, Gamepads & Action Maps (`engine.platform`)

Query devices directly or bind cross-device actions on `app.input.actions` (`InputMap`, max 32 actions × 4 bindings, JSON persistence):

```d
app.input.actions.bindKey("jump", Key.space);
app.input.actions.bindPadButton("jump", PadButton.a);
app.input.actions.bindAxis2D("left", "right", "down", "up", Key.a, Key.d, Key.s, Key.w);
app.input.actions.bindStick("left", "right", "down", "up", PadAxis.leftX, PadAxis.leftY);

// Per frame:
if (app.input.actionPressed("jump")) { ... }
immutable move = app.input.axis2D("left", "right", "down", "up");
if (app.input.padConnected(0) && app.input.padPressed(PadButton.x, 0)) {
    app.gamepads.rumble(0, 0.7f, 0.9f, 250);
    app.gamepads.rumbleTriggers(0, 0.8f, 0.8f, 250); // Xbox impulse triggers
}
```

For a key-remapping UI, read the table back instead of keeping a parallel copy: `numActions` / `actionName(i)` enumerate the actions, `bindingCount(action)` and `bindingAt(action, i, binding)` copy each `InputBinding` (`kind`, `code`, `scale`, `deadzone`). Change them with `unbind` / `clearAction` / `bind`. `bind` returns false for names longer than 64 bytes and for invalid kinds or codes. Triggers and sticks bound to an action also report `actionPressed` / `actionUp` (threshold 0.5).

Direct queries include `keyPressed`/`keyDown`/`keyUp`, `mousePressed`/`mouseDown`/`mouseUp`, `mx`/`my`/`mdx`/`mdy`, `wheelX`/`wheelY`, `textInput()`, `padLeftStick`/`padRightStick`, and `padLeftTrigger`/`padRightTrigger`. Gamepad demo: `dub run --config=gamepad`.

---

## 9. Timing, Tweens & Timers (`engine.core.clock`, `engine.core.tween`)

Zero-allocation POD utilities for fixed-step simulation (`GameClock`), eased interpolation (`Tweens`), and countdowns (`Timers`):

```d
auto clock = GameClock.create(60.0f); // optional: clock.timeScale = 0.5f;
Tweens tweens;
Timers timers;
auto fadeId = tweens.start(0.0f, 1.0f, 0.4f, Ease.outCubic);
auto tickId = timers.every(1.0f); // or timers.after(0.5f, &callback)

// Per frame:
immutable step = clock.advance(dt);
foreach (_; 0 .. step.steps) fixedTick(step.fixedDt);
tweens.update(step.scaledDt);
timers.update(step.scaledDt);
float alpha;
if (tweens.tryGet(fadeId, alpha)) { ... }
if (timers.fired(tickId)) { ... }
```

Available easing curves (`Ease`): `linear`, `inQuad`, `outQuad`, `inOutQuad`, `inCubic`, `outCubic`, `inOutCubic`, `outBack`, `outBounce`.

---

## 10. Assets & Mesh Optimization (`engine.assets`, `engine.meshopt`)

- **Images (`SDL3_image`):** `Texture.fromImageFile(gpu, path)`, `Texture.fromImageBytes(gpu, bytes)`, and `Texture.fromSvgBytes(gpu, svgBytes, w, h)` decode **PNG, JPG, QOI, SVG, BMP, TGA, GIF** (plus **WEBP/AVIF** when enabled on host). Raw helpers: `decodeImageFile`, `decodeSvgBytesSized`, `saveRgbaPng`, `saveRgbaJpg`, `loadBmpTexture`, `Texture.fromTgaFile`.
- **glTF 2.0:** `loadGltfMesh(app.gpu, path)` and `loadGltfPbr(app.gpu, path, scene.materialLayout(), sampler)` (returns `GltfModel` with `.mesh`, `.material`, `.destroy()`; imports `doubleSided`, `KHR_materials_{ior,specular,clearcoat,sheen,iridescence,emissive_strength,anisotropy}`, and `EXT_meshopt_compression`). For whole rigid models (all meshes, primitives, material names via `findMaterial`, and node hierarchy) use `loadGltfAsset` — see §3.5; for GPU-skinned multi-mesh characters use `loadGltfSkinnedCharacter` and `Scene3DTextured.drawSkinned` — see [animation-guide.md](animation-guide.md).
- **LOD chains from `.meta`:** add `"lod": {"enabled": true}` (optional `maxLods`, `ratio`, `maxError`) under `settings` in a glTF's `.meta` to build LODs at import in every loader; the editor and player then switch LODs automatically.
- **Mesh optimization (`engine.meshopt.pipeline`):** `loadGltfMesh` / `loadGltfPbr` automatically optimize imported geometry via `.meta` `MeshOptSettings`. For procedural or custom meshes at load time (never inside the frame loop), call `optimizeMesh(verts, indices, settings)` (`reindex`, `vertexCache`, `overdrawThreshold`, `vertexFetch`, `shadowIndices`; `stats = true` also fills the `before`/`after` ratios, which is slow).

Deep dives: [export-guide.md](export-guide.md) (media format matrix) · [plan-meshoptimizer.md](plan-meshoptimizer.md).

---

## 11. Physics (Box3D) & Skeletal Animation (`engine.physics`, `engine.animation`)

### 11.1 Rigid-Body Physics (`engine.physics`)

Import `engine.physics` (do not import `bindings.box3d` from game code):

```d
auto phys  = PhysicsWorld.createDefault(); // or PhysicsWorld(Vec3(0, -9.81f, 0))
auto floor = createGroundSlab(phys, 0.0f, Vec3(20, 0, 20), 0.5f);
auto ball  = createDynamicSphere(phys, Vec3(0, 5, 0), 0.5f, 1.0f);
auto hero  = CharacterController(Vec3(0, 1, 0), 1.8f, 0.35f);

// Per frame:
phys.step(dt);
drainPhysicsEvents(phys, contactListener);
hero.move(phys, wishDir, dt, jumpPressed);
immutable hit = castRayClosest(phys, origin, dir, 100.0f);
```

Supports boxes, spheres, capsules, cylinders, convex hulls, static meshes/heightfields, per-triangle surface materials, sensors, AABB/sphere overlaps, distance/revolute/weld/spherical/wheel/prismatic/filter/breakable joints, collision filters, CCD, and sleep control.

Override the mass properties of a body (for example a vehicle whose inertia comes from its bounding box) and use hit events for impact damage:

```d
// Mass, local center of mass and inertia tensor (diagonal helper):
setMassData(car, BodyMassData.diagonal(1200.0f, Vec3(0, -0.3f, 0), 600.0f, 900.0f, 300.0f));
immutable m = getMassData(car);          // m.mass, m.center, m.inertiaX/Y/Z
resetMassFromShapes(car);                // back to the shape densities

// Impact damage from a hit event (needs enableHitEvents on the body):
void onHit(PhysicsHitEvent e, void* ctx) nothrow @nogc @safe {
    immutable closing = e.approachSpeed;      // m/s along the normal, always >= 0
    immutable impulse = e.approachImpulse;    // kg*m/s, uses the reduced mass of the two bodies
    // e.normalImpulse is Box3D's sub-step-accumulated total: it overestimates, do not use it for damage
}
```

Deep dive: [physics-quickstart.md](physics-quickstart.md).

### 11.2 Skeletal Animation (`engine.animation`)

Pure-D runtime port of `ozz-animation` (`@nogc` evaluation jobs + `AnimAssets` / `PosePool` ECS integration + instanced OpenPBR & shadow-casting GPU skinning via `Scene3DTextured.drawSkinned` / `SkinnedCharacterAsset`, up to 1024 joints per skeleton):

```d
import engine.animation;
import engine.animation.ecs;

AnimAssets animAssets;
PosePool posePool;
string err;
auto sk   = loadSkeletonFile(animAssets.skeletons, "skeleton.ozz", err);
auto walk = loadAnimationFile(animAssets.animations, "walk.ozz", err);
// Spawn entity with AnimSkeleton(sk, posePool.acquire(numJoints)) + AnimPlayback(walk, 0, 1, true)
// Per frame: advancePlaybackSystem -> sampleSystem -> blendSystem -> localToModelSystem -> ragdollSystem -> boneSocketSystem -> skinPaletteSystem
// Optional OW-5 helpers: buildSubtreeMask + AnimLayerOverride, BoneSocket, RagdollAsset + RagdollComponent
```

Deep dive: [animation-guide.md](animation-guide.md).

---

## 12. Audio (`engine.audio`)

Load WAV clips with `AudioClip.loadWav` (or resample via `clip.convertTo(48_000, 2)` / synthesize with `AudioClip.fromInterleavedF32`), or stream compressed `.ogg` Vorbis files with `AudioStream.openOggFile` / `openOggMemory`. `AudioMixer` mixes up to 32 polyphonic voices across 8 independent buses (`sfx`, `music`, `voice`, `radio`, `ambient`, `ui`, `custom0`, `custom1`) with per-bus/per-voice `@nogc` DSP chains (`lowPass`, `highPass`, `bandPass`, `waveshaper`, `staticHiss`, and `DspChain.vhfRadio()`):

```d
auto mixer = AudioMixer.create();
scope(exit) mixer.destroy();

auto click = AudioClip.loadWav("assets/click.wav");
scope(exit) click.destroy();

mixer.setBusGain(AudioBus.sfx, 0.8f);
mixer.setBusDsp(AudioBus.radio, DspChain.vhfRadio());
immutable v = mixer.play(click, AudioBus.sfx, volume: 1.0f, pitch: 1.05f);

// OGG Vorbis streaming (call stream.pump() each frame on main thread):
auto music = AudioStream.openOggFile("assets/theme.ogg", loop: true);
scope(exit) music.close();
mixer.playStream(music, AudioBus.music, volume: 0.7f);
```

3D spatialization & Doppler shift (`engine.audio.spatial`): use `Listener3D` + `play3D` for lightweight one-shots, or `AudioListener3D` + `AudioSource3D` + `updateSource3D` for velocity-based Doppler pitch shifts and `spatialBlend`:

```d
AudioListener3D ear = { position: cam.position, forward: cam.forward, up: Vec3(0, 1, 0), velocity: playerVel };
AudioSource3D siren = { position: carPos, velocity: carVel, refDistance: 4, maxDistance: 120 };
VoiceId sv = play3D(mixer, sirenClip, siren, ear, loop: true);
updateSource3D(mixer, sv, siren, ear); // per frame
```

Deep dive: [audio-guide.md](audio-guide.md).

---

## 13. 3D Navigation (`engine.nav`)

Bake tiled Recast/Detour navigation meshes (`NavMesh` + `NavTileCache`), query A* / straight paths (`NavQuery`), add or remove runtime cylinder/AABB/OBB obstacles (`NavTileCache`), simulate multi-agent local avoidance (`NavCrowd`), or step ECS agents (`NavAgent`, `NavMoveRequest`, `stepNavAgents`):

```d
import engine.nav;

NavMesh navMesh;
NavTileCache tileCache;
scope(exit) { tileCache.destroy(); navMesh.destroy(); }

auto bakeCfg = NavBakeConfig.defaults();
bakeCfg.threads = 0; // bake tiles on all cores (1 = serial, the default); output is identical
bakeNavMesh(navMesh, tileCache, verts, indices, bakeCfg);

auto query = NavQuery.create(navMesh);
auto crowd = NavCrowd.create(maxAgents: 64, maxAgentRadius: 0.6f, navMesh);
scope(exit) { crowd.destroy(); query.destroy(); }

// In fixed update / frame loop (@nogc):
tileCache.flushUpdates(navMesh);
stepNavAgents!(GameWorld, Position)(world, crowd, query, dt);

// Debug overlay:
drawNavMesh(gizmos, navMesh);
```

Bake the whole area in one call (the bake replaces every tile its geometry touches) and do not query the mesh while it bakes. `threads` only changes bake time; the field table and the measured speedup are in [navigation-guide.md § `NavBakeConfig` reference](navigation-guide.md#navbakeconfig-reference).

Off-mesh links (jumps, ladders, drops) are baked in with the same call, and the obstacle cache can be saved with the mesh so a loaded `.navmesh` needs no re-bake:

```d
NavOffMeshConnection jump;
jump.start = Vec3(-3, 0, 0);
jump.end   = Vec3( 3, 0, 0);
jump.radius = 1.0f;
jump.userId = 42;                                            // your own link id
bakeNavMesh(navMesh, tileCache, verts, indices, cfg, null, [jump]);

saveNavMeshFile(navMesh, tileCache, "assets/nav/city.navmesh");   // mesh + obstacle cache (format v2)

NavMesh mesh2;
NavTileCache cache2;
loadNavMeshAndCacheFromBytes(cast(ubyte[]) read("assets/nav/city.navmesh"), mesh2, cache2);
cache2.addCylinderObstacle(pos, 1.0f, 2.0f, obstacleRef);    // obstacles are not stored: add them again
cache2.flushUpdates(mesh2);
```

`findStraightPath` marks the link crossing with `NavStraightPathFlags.offMeshConnection`; the game plays the jump or ladder animation. After pulling a version that changes `recast_shim.cpp`, rebuild `librecast_shim.a` with `tools/build_sdl3_deps.sh`.

Deep dive: [navigation-guide.md](navigation-guide.md).

---

## 14. DevTools, Shader Hot-Reload & Visual Editor

- **Gizmos & Debug Overlay (`engine.devtools`):**
  ```d
  auto gizmos  = GizmoRenderer.create(app.gpu);
  auto overlay = DebugOverlay.create();

  // In HDR pass (before resolvePost):
  gizmos.begin(camera.viewProjection());
  gizmos.axes(Vec3(0, 0, 0), 1.0f);
  gizmos.grid(20.0f, 20, Color4(0.3f, 0.3f, 0.3f, 1.0f));
  gizmos.render(frame);

  // In LDR pass (after resolvePost):
  overlay.beginFrame(dt);
  overlay.label("pos", camera.position.x, ",", camera.position.y, ",", camera.position.z);
  overlay.label("entities", world.entityCount());
  overlay.addGcStats();
  overlay.render(text, frame); // renders through TextRenderer
  ```
- **Frame Profiler (`engine.devtools.profiler`, `engine.gpu.gpu_profiler`):** hierarchical CPU zones, per-pass GPU timestamps and Box3D's step profile, with p50/p95/p99 and a Perfetto trace. Off by default.
  ```d
  enableProfiler(true);                         // once
  { auto z = profileZone!"mygame.ai"(); ... }   // scoped CPU zone, @nogc
  { auto g = gpuFrameScope!"gpu.mypass"(frame); ... } // GPU timestamps around your draws
  overlay.addProfiler(0.05);                    // live tree in DebugOverlay
  foreach (r; profilerReport()) ...;            // stats; startProfilerTrace() + profilerTraceJson() for traces
  ```
  The engine already instruments the renderer, scene passes, shadows, post, terrain, decals, water, UI and physics. Deep dive: [profiling.md](profiling.md).
- **WGSL Shader Hot-Reload (`engine.hotreload.shader_reload`):** `ShaderHotReloader` watches `assets/shaders/` (supporting `#include`, `#define`, `#ifdef`) and transactionally swaps pipelines without dropping frames on syntax errors. Deep dive: [multiplatform-and-shaders.md](multiplatform-and-shaders.md).
- **Scene rendering (editor + player):** both draw scenes with the shared `SceneRenderer` (OpenPBR, glTF/GLB mesh assets, scene lights with shadows, culling, LOD); `game-engine-player --headless-frames=600 --render --assert-no-gc` checks zero GC with real rendering. See [editor-guide.md §2.3.1](editor-guide.md).
- **Visual Editor (`dub run --config=editor`):** Unity/Godot-style docked editor with Hierarchy, Scene/Game View, reflected Inspector, Project Browser (128-bit GUIDs + `.meta`), Console, Prefabs (`*.prefab.json`), Scenes (`*.scene.json`), and non-destructive Play/Pause/Step mode. Deep dive: [editor-guide.md](editor-guide.md).
- **Additive Scenes, Prefabs & World Chunk Streaming (`OW-7`):**
  - **Generational Handles (`engine.ecs`):** `auto h = world.handle(e);` pairs `EntityId` with a generation counter (`world.aliveHandle(h)`) so recycled IDs never alias stale references.
  - **Additive Scenes & Prefabs (`engine.editor.scene_load`, `engine.scene.prefab`):** `loadSceneAdditive(world, chunkScene, offset)` merges chunks without clearing existing entities; `instantiatePrefab` is additive, `revertPrefab` destroys the full child hierarchy, `applyPrefabOverrides` exports only the prefab subtree, and `diffPrefabOverrides` / `applyPropertyOverrides` track per-field overrides.
  - **9 km² World Streaming (`engine.scene.streamer`, `SceneFile` v2):**
    ```d
    WorldStreamer streamer;
    if (sf.hasChunkManifest) {
        streamer.initFromManifest(sf.chunkManifest);
        streamer.startWorker(); // background GC-excluded file I/O + GESC decode (see docs/chunk-format.md)
    }
    // Per frame:
    streamer.update(world, camera.position, uploadBudgetMs: 2.0f);
    ```
    Deep dive: [plan-open-world-readiness.md](plan-open-world-readiness.md).
  - **Batched ECS insertion & binary chunks:** `world.spawnBatch(n)` / `world.setBatch(ids, comps)` (and `RawComponentStore.addBatch`) insert many entities/components in one pass. Chunks may be `.gesc` files; `encodeChunkWithComponents(scene, world.types, world.strings)` cooks your registered custom components into binary blocks (mapped by type name, tolerant of added/removed/renamed fields, `@entityRef uint` fields remapped), and `applyChunk` loads them. Details: [chunk-format.md](chunk-format.md), [world-pipeline-guide.md §5.3](world-pipeline-guide.md).
  - **GC-free decode, pak streaming & compression:** on the worker, `.gesc` chunks are decoded without the GC (`readChunkNoGc`); only `applyChunk` runs on the main thread. When an asset pak is mounted (`mountAssetPak`), chunks are read from it (disk fallback otherwise) and export packs them (`--pak-dir=<dir>` for extra chunk folders). Compression is the pure-D `zipd` codec behind `engine.assets.zstd` (levels 1..9). Cook your own component types with `encodeChunkWithComponents` to avoid per-chunk JSON parsing; the `game-engine-gesc` CLI does not know game types. See [chunk-format.md](chunk-format.md) and [export-guide.md](export-guide.md).
- **Asset & Tunable Hot-Reload (`OW-8`, `engine.hotreload`):** in the editor (always) and in the player (`--hot-reload`), edits to models/images/`.meta`, `*.prefab.json` (live instances rebuilt, per-instance overrides kept), the open `*.scene.json`, and `*.tune.json` apply within ~0.2 s. Failed loads keep the previous version. In your own loop:
  ```d
  TunableRegistry tunables;
  tunables.addFilesUnder("assets");                    // {"car": {"stiffness": 42000}}
  immutable k = tunables.key("car.stiffness");         // load time
  float s = tunables.getFloat(k, 30000);               // @nogc per frame
  tunables.applyToComponents!Suspension(world, "car"); // prefix.field -> live components

  AssetHotReloader hot;
  hot.init(["assets"]);                                // inotify, or mtime polling off Linux
  HotReloadTargets t = { gpu: &app.gpu, renderer: &sceneRenderer, world: &world, tunables: &tunables };
  hot.poll(dt, t);                                     // outside render(); never in --assert-no-gc runs
  ```
- **Road Splines & Blender World Export (`OW-8`):** `Spline3` (`engine.math.spline`) gives centripetal Catmull-Rom / Bézier curves with `rebuild()` (arc-length LUT), then `@nogc` `sampleAtDistance`, `frameAtDistance`, `closestPoint` (distance + lateral offset) and `extrudeRibbon` (road mesh → `TexMesh.fromData`). `*.splines.json` sets load via `loadSplineSetFile(sceneSplineSetPath(root))`. `tools/blender_export_scene.py` exports a Blender scene to GLB models + chunked v2 scenes + splines for `WorldStreamer`:
  ```bash
  blender -b level01.blend -P tools/blender_export_scene.py -- --name=level01 --cell-size=256
  game-engine-player --scene=assets/world/level01.scene.json
  ```
  Add `--format=gesc` (after `dub build --config=gesc`) to also emit compact binary `.gesc` chunks; see [docs/world-pipeline-guide.md](world-pipeline-guide.md) 5.1.1.
  Deep dive (custom properties `ge_physics` / `ge_surface` / `ge_role`, file layout, prefab reload rules): [world-pipeline-guide.md](world-pipeline-guide.md).

---

## 15. Building, External Projects & Multiplatform Export

### 14.1 Requirements & Common DUB Commands

- **Tools:** DMD (dev) or LDC2 (release), `libwgpu_native.a` and `libbox3d.a` in `libs/`, and `libSDL3.so` on the host (`SDL3_image` and `SDL3_ttf` load lazily via `SDL_LoadObject` in dev builds).
- **Linux Wayland/X11:** Wayland primary, automatic X11 fallback in standalone builds.

```bash
dub run --config=editor              # Visual Scene Editor
dub run --config=game                # Crystal Collector 3D gameplay demo
dub run --config=pbr                 # OpenPBR Surface v1.1 + multi-light shadows demo
dub run --config=water               # OpenPBR ocean/river water + SSR + compute foam
dub run --config=showcase            # SceneGraph + textured materials + shadows
dub run --config=benchmark           # 1000 instanced cubes benchmark
dub run --config=ui-gallery          # Retained UI & SDL3_ttf fonts gallery
dub run --config=anim-viewer         # Skeletal animation + GPU skinning viewer
dub run --config=pong3d              # Box3D physics demo
dub run --config=golf                # Drag + Magnus lift + wind physics demo
dub run --config=gamepad             # SDL3 gamepad & Xbox trigger rumble monitor
dub run --config=lint                # GC-safe storage static lint
dub test --config=library            # Engine unit test suite
```

### 14.2 External DUB Dependency

Consume `game-engine` from a separate game repository (see [examples/external-game/dub.json](../examples/external-game/dub.json)):

```json
{
    "name": "my-game",
    "dependencies": {
        "game-engine": { "path": "../path/to/game-engine" }
    }
}
```

### 14.3 Static Multiplatform Release Export & Protected Asset Packs

Build static `SDL3` / `SDL3_image` / `SDL3_ttf` / `FreeType` archives under `libs/<target>/` and package standalone bundles (including external `--project` games with embedded `GEPK` encrypted asset packs via `engine.assets.pak`) from the CLI or the Editor's **Arquivo → Exportar Release** menu:

```bash
./tools/build_sdl3_deps.sh linux-x86_64
dub build --config=player-static --compiler=dmd --build=plain
dub run --config=export --compiler=dmd -- --check-toolchains
dub run --config=export --compiler=dmd -- --target=linux-x86_64 --project=../my-game --assets=Assets --protect-assets --embed-pak
```

For standalone asset packing outside `export`, use `dub build --config=pak --compiler=dmd` (`game-engine-pak`) and mount via `mountAssetPak(import("assets.pak"), key, false)` at startup.

| `--target=<value>` | Aliases | LLVM Triple | Bundle Output |
|:---|:---|:---|:---|
| `linux-x86_64` | `linux`, `linux_x86_64` | `x86_64-unknown-linux-gnu` | Static ELF + `run.sh` + `.desktop` + `.tar.gz` |
| `linux-arm64` | `linux-aarch64` | `aarch64-unknown-linux-gnu` | Static ELF + `run.sh` + `.desktop` + `.tar.gz` |
| `windows-x86_64` | `windows`, `win64` | `x86_64-pc-windows-msvc` | `game-player.exe` + `.zip` |
| `macos-arm64` / `macos-x86_64` | `darwin-arm64` / `darwin-x86_64` | `arm64-apple-macos12.0` / `x86_64-apple-macos11.0` | `<Title>.app` + `.zip` |
| `macos-universal` | `macos`, `darwin` | `arm64` + `x86_64` | Universal `.app` (`lipo` + `codesign`) + `.zip` |
| `web-wasm32` | `web`, `wasm`, `wasm32` | `wasm32-unknown-emscripten` | `<name>.html` + `.js` + `.wasm` + `.data` + `.zip` |

Deep dive: [export-guide.md](export-guide.md) (per-target flags, `BuildExportOptions`, `engine.assets.pak` `GEPK` format, external project export, WebGPU shell, and media format matrix).
