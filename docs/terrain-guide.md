# Terrain Guide (`engine.terrain`)

Chunked heightmap terrain for outdoor scenes (OW-3 P3.2). It renders with PBR splatting, casts cascaded shadows, and has a Box3D collider that matches the visible surface exactly. One import pulls in everything:

```d
import engine.terrain;
```

| Module | Purpose |
|:---|:---|
| `heightmap.d` | `TerrainDesc` and `Heightmap`: 16-bit quantized heights, `heightAt` / `normalAt`, `.r16` loader |
| `splat.d` | `SplatMap`: 8 layer weights per texel, `dominantLayer` |
| `chunks.d` | `TerrainChunks`: per-chunk bounds, LOD with hysteresis, frustum culling, and the grid template indices |
| `material.d` | `TerrainLayer` parameters and `TerrainMaterial` (albedo, normal and ORM texture arrays) |
| `terrain.d` | `Terrain`: the CPU aggregate and gameplay queries |
| `generate.d` | Procedural heights (fBm + ridges + light erosion), a 4-biome splat map, and tileable layer textures |
| `renderer.d` | `TerrainRenderer`: GPU resources, opaque pass and shadow casting |
| `physics.d` | `buildTerrainColliders`: Box3D heightfield tiles with per-cell surface materials |

The complete example is `source/demo/outdoor.d` (`dub run --config=outdoor`).

## Quick start

```d
// 1. Data: 24 x 24 chunks of 128 cells at 1 m = 3 km.
TerrainDesc td;
td.chunkCells = 128;
td.samplesX = td.samplesZ = 24 * 128 + 1;      // must be chunks * chunkCells + 1
td.cellSize = 1.0f;
td.origin = Vec3(-1536, 0, -1536);
td.minHeight = -20;  td.maxHeight = 480;        // quantization range
auto heights = generateHeights(td);             // or Heightmap.fromR16(td, bytes) / fromFloats
auto splat   = generateBiomeSplat(heights, 1024, 1024);
auto terrain = Terrain.create(heights, splat);  // TerrainLodSettings optional

// 2. Layers (up to 8). Layer i is slice i of every texture array.
TerrainLayer[4] layers;
layers[1].triplanarSharpness = 6;               // rock: triplanar on cliffs
foreach (i, ref l; layers) l.physicsMaterial = cast(ubyte)(i + 1);
auto mat = TerrainMaterial.create(app.gpu, layers[], albedo[], normal[], orm[], 512);
// Albedo stored as sRGB color: pass srgbAlbedo = true as the last argument (the height in alpha stays linear).

// 3. Rendering: create, then attach once the struct is at its final address.
auto tr = TerrainRenderer.create(app.gpu, scene, terrain, mat);
tr.attach(scene, terrain);

// 4. Physics (load time; the world owns the cooked data).
buildTerrainColliders(physics, terrain, layers[]);

// Frame loop (zero GC):
tr.update(terrain, camera);      // cull + LOD + upload; before renderShadows / end
scene.begin(camera);
scene.renderShadows(frame, lights);
scene.end(frame);                // terrain draws in the opaque pass
```

Gameplay queries are `terrain.heightAt(x, z)`, `terrain.normalAt(x, z)`, `terrain.layerAt(x, z)`, `terrain.contains(x, z)` and `terrain.center()`.

## Data model

### Heights

- Heights are stored as `ushort` values quantized over `[minHeight, maxHeight]`. The quantizer is exactly Box3D's: `quantum = range / 65535`, with truncation.
- Choose the range to fit the content. 500 m of range gives a 7.6 mm step.
- Each cell is split along the diagonal from (x0, z1) to (x1, z0), the same as `b3CreateHeightField`.
- `heightAt` evaluates the same triangle the collider uses, and LOD0 renders. A unit test casts 10,000 rays and checks the error stays below 1 cm.
- Sources:
  - `Heightmap.fromR16` loads raw little-endian 16-bit files, such as World Machine or Gaea exports.
  - `fromFloats` quantizes any float array.
  - `generateHeights(desc, TerrainGenSettings)` is procedural. Its controls are seed, wavelength, hill and mountain height, mountain coverage, octaves, erosion passes, and a flattened spawn disc.

### Splat map

- `SplatMap` holds 8 weights per texel (0–255) and may be coarser than the height grid. The demo uses 1024² for 3 km, about 3 m per texel.
- `normalize()` makes the weights sum to 255.
- On the GPU the map is two RGBA8 planes in one texture array.
- `dominantLayer` picks the heaviest layer. Physics surface materials use it, so a raycast reports the layer that is visibly on top.

### Chunks and LOD

- `TerrainChunks` splits the grid into `chunkCells`² chunks and stores each chunk's world AABB (min/max height).
- `update(frustum, cameraPos)` does the following each frame:
  - frustum-culls the chunks;
  - picks each LOD from the distance to the AABB (LOD *i* is used up to `lod0Distance · 2^i`);
  - applies `hysteresis` before a chunk goes back to a finer LOD;
  - writes the visible instances grouped by LOD.
- `TerrainLodSettings`:

  | Field | Default |
  |:---|:---|
  | `lodCount` | 5 (steps 1, 2, 4, 8, 16) |
  | `lod0Distance` | 160 m |
  | `morphFraction` | 0.3 |
  | `hysteresis` | 0.08 |
  | `shadowMinLod` | 1 |
  | `maxDistance` | 0, unlimited |

## Rendering

### Mesh

- There is no vertex buffer and no per-chunk geometry.
- Vertex `i < G` (`G = (C+1)²`) is grid point `(i % (C+1), i / (C+1))` of a chunk. Vertex `G + i` is the same point lowered by `skirtDepth · step`, which forms the crack-hiding skirt.
- One 16-bit index buffer holds every LOD (cells plus skirt ring) as consecutive ranges.
- Each visible chunk is a 16-byte instance: `sampleX`, `sampleZ`, `lod`. A frame costs **one instanced draw per LOD**, at most 5.

### Heightmap and geomorphing

- The vertex shader reads the decoded heights from an `r32Float` texture with `textureLoad`, so no filtering is involved.
- Vertices near the end of their LOD band morph toward the next LOD. Odd vertices collapse onto their lower even neighbor, which reproduces the coarse mesh exactly.
- The band ends at `D · (1 − hysteresis)`. A neighbor that is already coarser therefore always meets fully morphed border vertices.
- Skirts are shaded with the unlowered surface position, so T-junction slivers never sample shadows from below the ground.

### Shading (`terrain_pbr.wgsl`)

- **Bind groups:**
  - Group 0 is the scene frame: cascades, lights, fog, wetness.
  - Group 1 is the terrain: params, layer sampler, heightmap (VS only), normal map, splat array, albedo/normal/ORM arrays, clamp sampler.
  - Group 2 is the scene IBL.
  - The fragment stage uses **15/16** sampled textures.
- **Layer blending:**
  - The four heaviest layers per pixel are height-blended using the albedo alpha × `heightBlend`, with `TerrainRenderSettings.blendDepth` as the transition depth.
  - Steep slopes switch to triplanar projection for layers with `triplanarSharpness > 0`.
  - Past about 40 m, a second UV scale (`detileScale`) is mixed into the albedo to break up tiling.
  - All fetches use `textureSampleGrad`, so the data-dependent loop is valid WGSL.
- **Normals and surface effects:**
  - The smooth normal comes from a mipmapped normal map (central differences at load). Layer normals add detail, scaled by `normalStrength`.
  - Rain wetness (`frame.globalWetness`) darkens and glosses upward-facing ground.
  - Detail normals are bent toward the camera at grazing angles.
- **Lighting:** `common/simple_pbr.wgsl` (`shadeSimplePbr`) provides the directional light with CSM, point and spot lights with shadows, and split-sum IBL. Terrain below a water body's level gets sun caustics ([water-guide.md](water-guide.md#caustics)). Fog is applied last.

### Shadows

- `attach` registers a `Scene3DTextured` shadow caster hook. Every directional (cascade) view culls the chunks against the light frustum and draws them with `terrain_shadow.wgsl`, at LOD ≥ `shadowMinLod`.
- Each view writes its own region of a pre-allocated shadow instance buffer (up to `TerrainRenderer.MAX_SHADOW_VIEWS = 8` views).

### Stats

`TerrainRenderer.stats()` returns `visibleChunks`, `drawCalls`, `shadowDrawCalls` and `shadowViews`.

### Lifetime

- `attach` stores pointers to the renderer, scene and terrain. Do not move any of them afterwards.
- `destroy()` calls `detach()`, which clears all opaque and shadow hooks of the scene.

## Physics (`buildTerrainColliders`)

- `buildTerrainColliders` creates one static heightfield body per `tileCells` tile (default 512 cells). The world owns the cooked data.
- Pass a `TerrainColliderDesc` to configure `tileCells`, `CollisionFilter filter`, `EntityId entityId`, and `enableHitEvents`, and optionally pass a `b3BodyId[]` slice (sized via `terrainColliderTileCount`) to collect the created tile bodies:

  ```d
  enum ulong LAYER_WORLD = 1UL << 0;

  TerrainColliderDesc cdesc;
  cdesc.tileCells = 512;
  cdesc.filter = CollisionFilter(LAYER_WORLD, ulong.max, 0);
  cdesc.entityId = terrainEntityId;
  cdesc.enableHitEvents = false;

  auto tileBodies = new b3BodyId[terrainColliderTileCount(terrain, cdesc.tileCells)];
  buildTerrainColliders(physics, terrain, layers[], cdesc, tileBodies);
  ```

- Every tile uses the terrain's global min/max height, so seams are exact.
- Heights get half a quantum of bias, so Box3D's truncating quantizer reproduces the terrain's own 16-bit values.
- Each cell's material index is the dominant splat layer, mapped to `PhysicsSurfaceMaterial { friction = layer.friction, userMaterialId = layer.physicsMaterial }`. `castRayClosest(...).surfaceMaterialId` therefore reports the visible layer (tested).
- Cooking is a load-time cost. A 3 km terrain at 1 m (36 tiles) takes a few seconds in debug builds.

## Procedural content (`generate.d` & `engine.math.noise`)

- `generateHeights(desc, settings)`: domain-warped fBm hills, ridged mountains behind a coverage mask, an optional flattened disc at the center, and an erosion-lite smoothing pass.
- `generateBiomeSplat(heights, w, h, sandLevel, snowLevel)` builds a 4-biome map:
  - `BiomeLayer.grass` covers the default ground;
  - `rock` goes on slopes;
  - `sand` sits below `sandLevel`;
  - `snow` sits above `snowLevel`.
- **Generic PBR texture synthesis (3 tiers, all tileable linear RGBA8 with height in albedo alpha + tangent-space normal + ORM):**
  1. **Declarative (`ProcLayerDesc`):** Describe any surface with `ProcLayerDesc` (`ProcNoiseBasis.fbm`, `ridged`, `voronoi`, or `brick`, plus domain warp, fine detail grain, mortar/bevel, cell color variation, roughness, AO, and metallic) and call `generateLayerTextures(desc, size, albedo, normal, orm)` — or `@nogc` `generateLayerTexturesInto(...)`. `biomeLayerDesc(BiomeLayer)` returns the presets for the 4 demo biomes.
  2. **Custom heightfield baking:** Synthesize any `size²` `float[]` heightfield in `[0, 1]` and convert it with `bakePbrMapsFromHeightField(heights, size, desc, albedo, normal, orm)` (or `@nogc` `bakePbrMapsFromHeightFieldInto` / `bakeNormalsFromHeightField`).
  3. **Tileable 2D primitives (`engine.math.noise`, re-exported by `engine.terrain.generate`):** `valueNoiseTiled2D`, `fbmTiled2D`, `ridgedTiled2D`, `voronoiTiled2D` (`VoronoiSample`), and `brickPatternTiled2D` (`BrickSample`).

### Example: Specific surface recipes with `ProcLayerDesc`

```d
import engine.terrain;

ProcLayerDesc makeDryAsphalt() {
    ProcLayerDesc d;
    d.basis = ProcNoiseBasis.fbm;
    d.color0 = [0.05f, 0.052f, 0.055f];
    d.color1 = [0.11f, 0.115f, 0.12f];
    d.periodX = 16;
    d.octaves = 5;
    d.contrast = 0.7f;
    d.detailAmp = 0.25f;
    d.detailFreqMul = 4;
    d.roughness = 0.86f;
    d.normalStrength = 2.5f;
    return d;
}

ProcLayerDesc makeWetAsphalt() {
    auto d = makeDryAsphalt();
    d.color0 = [0.02f, 0.022f, 0.025f];
    d.color1 = [0.05f, 0.055f, 0.06f];
    d.roughness = 0.22f;
    d.roughnessVariation = 0.15f;
    return d;
}

ProcLayerDesc makeCobblestone() {
    ProcLayerDesc d;
    d.basis = ProcNoiseBasis.brick;
    d.color0 = [0.10f, 0.09f, 0.08f];   // mortar joints
    d.color1 = [0.34f, 0.32f, 0.29f];   // stone face
    d.cellColorVariation = 0.25f;
    d.periodX = 6;
    d.periodY = 10;
    d.rowOffset = 0.5f;
    d.mortarWidth = 0.10f;
    d.bevelWidth = 0.14f;
    d.warp = 0.015f;
    d.detailAmp = 0.18f;
    d.detailFreqMul = 4;
    d.roughness = 0.78f;
    d.normalStrength = 5.0f;
    return d;
}

ProcLayerDesc makeSidewalkSlabs() {
    ProcLayerDesc d;
    d.basis = ProcNoiseBasis.brick;
    d.color0 = [0.20f, 0.20f, 0.20f];   // expansion joints
    d.color1 = [0.46f, 0.45f, 0.43f];   // concrete slab
    d.cellColorVariation = 0.08f;
    d.periodX = 4;
    d.periodY = 4;
    d.rowOffset = 0.0f;                 // aligned grid
    d.mortarWidth = 0.04f;
    d.bevelWidth = 0.04f;
    d.detailAmp = 0.12f;
    d.detailFreqMul = 6;
    d.roughness = 0.84f;
    d.normalStrength = 3.0f;
    return d;
}

ProcLayerDesc makeRedLatosolDirt() {
    ProcLayerDesc d;
    d.basis = ProcNoiseBasis.fbm;
    d.color0 = [0.38f, 0.16f, 0.08f];
    d.color1 = [0.66f, 0.30f, 0.15f];
    d.periodX = 10;
    d.octaves = 5;
    d.warp = 0.04f;
    d.detailAmp = 0.20f;
    d.roughness = 0.92f;
    d.normalStrength = 4.0f;
    return d;
}

ProcLayerDesc makeMud() {
    ProcLayerDesc d;
    d.basis = ProcNoiseBasis.ridged;
    d.color0 = [0.16f, 0.10f, 0.05f];
    d.color1 = [0.33f, 0.21f, 0.12f];
    d.periodX = 8;
    d.warp = 0.05f;
    d.detailAmp = 0.15f;
    d.roughness = 0.35f;
    d.roughnessVariation = 0.25f;
    d.normalStrength = 4.5f;
    return d;
}

ProcLayerDesc makeGravel() {
    ProcLayerDesc d;
    d.basis = ProcNoiseBasis.voronoi;
    d.color0 = [0.18f, 0.17f, 0.16f];
    d.color1 = [0.44f, 0.42f, 0.39f];
    d.cellColorVariation = 0.30f;
    d.periodX = 18;
    d.mortarWidth = 0.02f;
    d.bevelWidth = 0.14f;
    d.jitter = 0.90f;
    d.roughness = 0.88f;
    d.normalStrength = 5.0f;
    return d;
}

// Generate 512x512 RGBA8 textures and upload to TerrainMaterial:
ubyte[] a, n, o;
generateLayerTextures(makeCobblestone(), 512, a, n, o);
```

### Example: Custom heightfield synthesis + `bakePbrMapsFromHeightField`

```d
enum S = 256;
auto h = new float[S * S];
foreach (y; 0 .. S)
    foreach (x; 0 .. S) {
        immutable u = cast(float) x / S, v = cast(float) y / S;
        immutable base = fbmTiled2D(u, v, 8, 8, 4, 0.5f, 10);
        immutable stones = voronoiTiled2D(u, v, 14, 14, 0.85f, 20);
        h[y * S + x] = base * 0.6f + (1.0f - stones.f1) * 0.4f;
    }

ProcLayerDesc bakeDesc;
bakeDesc.color0 = [0.22f, 0.18f, 0.14f];
bakeDesc.color1 = [0.48f, 0.41f, 0.33f];
bakeDesc.roughness = 0.88f;
bakeDesc.normalStrength = 4.5f;

ubyte[] albedo, normal, orm;
bakePbrMapsFromHeightField(h, S, bakeDesc, albedo, normal, orm);
```

## Performance and limits

- The 3 km demo stays at 5 or fewer terrain draws and 0 GC bytes per frame (`dub run --config=outdoor -- --headless-frames=600 --assert-no-gc`).
- `chunkCells` ≤ 128 keeps the indices 16-bit. Up to 8 layers are supported.
- Brush editing, holes and runtime height edits are out of scope here (roadmap item #7, terrain and water editor).

See also: [graphics.md § Outdoor Rendering (OW-3)](graphics.md#outdoor-rendering-ow-3) · [game-development-guide.md § 3.7](game-development-guide.md#37-outdoor-scenes-terrain-sky-weather-and-decals).
