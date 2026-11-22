# World Pipeline: Asset Hot-Reload, Tunables, Splines & Blender Export (`OW-8`)

This guide covers the productivity tools built for large (9 km²) worlds:

1. [Asset hot-reload](#1-asset-hot-reload-hr-1): models, textures, surface shaders, prefabs and scenes change in the running editor/player.
2. [Gameplay tunables](#2-gameplay-tunables-hr-2): JSON parameter files reload live into structs and components.
3. [3D splines](#3-3d-splines-enginemathspline): Catmull-Rom/Bézier curves with arc-length sampling, stable frames and road meshes.
4. [Spline sets](#4-spline-sets-splinesjson): the `*.splines.json` file for roads, traffic paths and rivers.
5. [Blender exporter](#5-blender-scenechunk-exporter): Blender scenes → chunked `*.scene.json` + GLB models + splines, loaded through `WorldStreamer`.

All of these tools run at load time or dev time. Their frame-path queries are `@nogc`; the reload work is not. Never poll a hot-reloader from a `--assert-no-gc` run. The editor and player skip hot-reload in headless mode.

---

## 1. Asset Hot-Reload (HR-1)

### 1.1 Components

| Piece | Module | Role |
|:---|:---|:---|
| `FileWatcher` | `engine.hotreload.watcher` | Debounced change detection. Backends: `inotify` on Linux (watches new subdirectories too), and `polling` (mtime rescan, every platform; used on Windows/macOS/Web and as the Linux fallback). `poll(dt)` returns true once a batch has been quiet for the debounce window, and `changedPaths()` lists that batch. |
| `AssetHotReloader` | `engine.hotreload.asset_reload` | Owns one watcher over the asset roots and routes each batch to the owner of each file. |
| `SceneRenderer.reloadChangedFiles` | `engine.editor.scene_renderer` | Re-imports every cached model built from a changed file and swaps it in place. |
| `reloadPrefabInstances` | `engine.scene.prefab` | Rebuilds the live instances of an edited prefab and keeps each instance's overrides. |
| `TunableRegistry` | `engine.hotreload.tunables` | Gameplay values; see §2. |

### 1.2 What reloads, and how

| Changed file | Action |
|:---|:---|
| `*.asset.json`, `.gltf`, `.glb`, `.bin`, `.meta`, any image a model uses | Every model whose dependency list contains the file is re-imported and swapped (`SceneRenderer`). |
| Image registered with `watchTexture(path, &tex, desc, onSwapped)` | The image is re-decoded into a new `Texture`. The old one is destroyed, and `onSwapped(tex)` lets the owner rebuild bind groups/materials that captured the old view. |
| `.wgsl` registered with `watchSurfaceShader(path, id)` | `Scene3DTextured.reloadSurfaceShader(id, source)`. |
| `*.prefab.json` | Every live `PrefabInstance` with the prefab's GUID is rebuilt (see §1.4). |
| `*.scene.json` | `onSceneChanged(path)` is called. The owner decides whether to reopen the scene (see §1.5). |
| `*.tune.json` registered in the `TunableRegistry` | `TunableRegistry.loadFile`. |

Stock engine shaders (`assets/shaders/`) keep their own `ShaderHotReloader` ([multiplatform-and-shaders.md](multiplatform-and-shaders.md)).

**Transactional swaps.** If a file fails to load, parse or compile, the previous resource stays in use, the error is logged, and `lastStats.failures` counts the failure. A model that previously failed to import is retried on the next change batch.

**Ownership and cleanup.** Loaders stay in `engine.assets` / `engine.graphics`. The owner destroys a replaced GPU resource right after the swap, between frames. Call `poll` outside `render`, as the editor and player do.

**Dependency tracking** is off by default because it parses each glTF a second time at load. `AssetHotReloader` turns it on automatically when it is given a `SceneRenderer`. You can also call `renderer.enableDependencyTracking()` yourself. `assetDependencies(path)` / `gltfFileDependencies(path)` expose the lists: the asset file, the glTF/GLB, its `.meta`, and external buffers and images.

### 1.3 Using it in your own loop

```d
import engine.hotreload.asset_reload : AssetHotReloader, HotReloadTargets;
import engine.hotreload.tunables : TunableRegistry;

AssetHotReloader hot;
TunableRegistry tunables;
tunables.addFilesUnder("assets");          // every *.tune.json
hot.init(["assets"]);                      // inotify on Linux, polling elsewhere
hot.watchTexture("assets/ui/minimap.png", &minimapTex, TextureDesc.init,
                 (ref Texture t) { minimapMaterial = rebuildMaterial(t); });

// Per frame, outside render():
HotReloadTargets t;
t.gpu = &app.gpu;
t.renderer = &sceneRenderer;
t.world = &world;
t.tunables = &tunables;
t.assetDb = &assetDb;                      // optional: prefab GUIDs (falls back to .meta)
hot.poll(dt, t);
```

`applyChanges(paths, targets)` applies a batch directly, without the watcher (tools, tests). `batchContains(hot.watcher.changedPaths, path)` checks a path regardless of spelling.

### 1.4 Prefab reload semantics

`AssetHotReloader.init` snapshots every `*.prefab.json` under its roots. When a prefab file changes:

1. Overrides are measured per instance against the **old** definition (`diffPrefabOverrides`): root/child transforms (pos/rot/scale), names, `MaterialOverride` color/opacity, light intensity/color, and physics mass.
2. Each instance is re-instantiated from the **new** definition under its external parent (`revertPrefab`).
3. The overrides are applied again (`applyPropertyOverrides`).

As a result, fields edited in the prefab file reach every instance, while values changed on a single instance survive. Instance entities get **new IDs**: re-resolve raw `EntityId`s that point into an instance subtree. The editor clears a selection that died. A prefab that fails to parse leaves every instance untouched.

### 1.5 Editor and player behavior

- **Editor** (`dub run --config=editor`): always on, except in headless mode.
  - Models, prefabs and tunables reload while editing and during Play.
  - The open scene is reopened when it changes on disk. This does not happen for the editor's own saves, while there are unsaved edits (a warning is logged instead), or during Play.
- **Player**: opt in with `game-engine-player --hot-reload`.
  - Assets, prefabs and tunables reload live.
  - An edited root scene restarts the simulation on the new file. For streamed (`ChunkManifest`) worlds, a root-scene edit needs a restart.
  - `--headless-frames` runs ignore the flag, so `--assert-no-gc` stays at 0 bytes.

Edits land within one debounce window: 0.2 s by default, well under the 0.5 s target. The test `assetReload.watcherEndToEndWithin500ms` checks this.

---

## 2. Gameplay Tunables (HR-2)

A tunable file is plain JSON named `*.tune.json`. Nested objects flatten into dotted keys:

```json
{ "vehicle": { "suspension": { "stiffness": 42000, "damping": 3100 },
               "breakImpulse": 900.5, "lights": true, "comOffset": [0, -0.4, 0.1] } }
```

Supported values are numbers, booleans and arrays of 1–4 numbers. Any other value is skipped with a warning. A file that fails to parse keeps **all** previous values.

```d
TunableRegistry tunables;
tunables.addFile("assets/data/vehicle.tune.json");   // or addFilesUnder("assets")

// Load time: intern the key once.
immutable stiffKey = tunables.key("vehicle.suspension.stiffness");

// Frame path: @nogc nothrow reads by StringId.
float k = tunables.getFloat(stiffKey, 30000);
Vec3 com = tunables.getVec3("vehicle.comOffset");     // by name (load time / tools)

// Copy prefix.field values into a struct or into every live component:
struct Suspension { float stiffness = 1, damping = 1; }
tunables.applyTo(mySuspension, "vehicle.suspension");
tunables.applyToComponents!Suspension(world, "vehicle.suspension");

// React to reloads:
tunables.onReloaded ~= (string path) {
    tunables.applyToComponents!Suspension(world, "vehicle.suspension");
};
// Cheap change check: tunables.generation() increments on every successful load.
// Debug label without GC: tunables.describe(stiffKey, frameArena) -> "vehicle.suspension.stiffness=42000"
```

`applyTo` supports integral, floating-point, `bool`, `Vec3` and `float[N]` (N ≤ 4) fields. Missing keys leave the field unchanged. Values are stored in a POD array indexed by `StringId.id`, so the engine-side storage passes `Pod!T`.

---

## 3. 3D Splines (`engine.math.spline`)

```d
import engine.math.spline;

Spline3 road;
road.kind = SplineKind.catmullRom;   // or SplineKind.bezier: P0, C0, C1, P1, C2, C3, P2, ...
road.alpha = 0.5f;                   // centripetal (no cusps); 0 uniform, 1 chordal
road.closed = false;
road.points = [Vec3(0, 0, 0), Vec3(120, 2, 40), Vec3(260, 4, 40)];
road.rebuild();                      // load time: arc-length LUT + rotation-minimizing frames

// Frame path (@nogc nothrow):
Vec3 p = road.sampleAtDistance(57.0f);                 // constant-speed placement
SplineFrame f = road.frameAtDistance(57.0f);           // position, tangent, normal (up), binormal (right)
SplineHit h = road.closestPoint(car.position);         // h.distance along, h.lateral (+right / -left)
```

- **Parameterization**: `u ∈ [0, segmentCount]`, one unit per segment (`evaluate`, `derivative`, `tangentAt`). `paramAtDistance` and `distanceAtParam` convert between `u` and arc length. Closed curves wrap both `u` and the distance.
- **Frames**: `FrameMode.upVector` (default) keeps the frame level (`right = tangent × world up`), which is what roads and rivers want. It falls back to the rotation-minimizing frame where the tangent is vertical. `FrameMode.rotationMinimizing` is twist-free parallel transport (double reflection) for loops, rails and tubes. On closed curves the residual twist is spread evenly.
- **Closest point**: a coarse search over the baked samples, refined by golden-section search on the parameter.
- **Road meshes**: `extrudeRibbon` builds a flat ribbon of `TexVert`s with counter-clockwise winding seen from the normal. `u` runs across (0 = left, 1 = right) and `v = distance / uvLength`.

  ```d
  RibbonOptions o;
  o.width = 9; o.step = 2; o.widthSegments = 2; o.verticalOffset = 0.05f; o.uvLength = 8;
  auto ribbon = extrudeRibbon(road, o);
  auto mesh = TexMesh.fromData(app.gpu, ribbon.vertices, ribbon.indices);
  ```

  Use `lateralOffset` for lanes and sidewalks. Closed curves get a duplicated seam row so `v` stays continuous.

---

## 4. Spline Sets (`*.splines.json`)

```json
{"format":"game-engine.splines","version":1,
 "splines":[
   {"name":"main_road","role":"road","kind":"bezier","closed":false,"alpha":0.5,
    "width":9,"lanes":2,"speedLimit":22.2,"points":[[5,0.1,380], ...]},
   {"name":"desert_loop","role":"traffic","kind":"bezier","closed":true,"points":[...]},
   {"name":"forest_river","role":"river","kind":"catmullRom","width":14,"lanes":0,"points":[...]}]}
```

`role` is free-form (`road`, `traffic`, `river`, `rail`, ...). Unknown keys are rejected. A root scene links the file through `assetLinks` with `"kind":"splines"`. `WorldStreamer` ignores that kind, because it is CPU data and not a GPU asset.

```d
import engine.scene.splines;

auto root = loadSceneFile("assets/world/level01.scene.json");
auto set = loadSplineSetFile(sceneSplineSetPath(root));   // every curve already baked
auto road = set.find("main_road");
SplineHit hit;
auto idx = set.closest(carPos, hit, "road");               // or closest(pos, hit, roleStringId) — @nogc
writeln(set.text(set.paths[idx].name), " lateral=", hit.lateral);
```

Names and roles are interned as `StringId` in `SplineSet.strings`. `splineSetToJson` writes the format back.

---

## 5. Blender Scene/Chunk Exporter

`tools/blender_export_scene.py` turns a Blender scene into a streamed world.

```bash
blender -b level01.blend -P tools/blender_export_scene.py -- --name=level01
# Flatpak (absolute paths; the sandbox does not keep the working directory):
flatpak run org.blender.Blender -b $PWD/level01.blend -P $PWD/tools/blender_export_scene.py -- \
    --name=level01 --project-root=$PWD
```

For large worlds, convert the exported chunks to `.gesc` (`game-engine-gesc encode|split`, or
`encodeChunkWithComponents` from your game's own tool so that its component types are cooked as binary blocks).
The `.scene.json` output stays the editable source. See [chunk-format.md](chunk-format.md).

Options: `--out=assets/world`, `--cell-size=256`, `--load-radius` (default 1.5 × cell), `--unload-radius` (default 2 × cell), `--collection=NAME`, `--dump-json=FILE`, `--from-json=FILE` (pure-Python backend, no Blender), `--build-test-level`, `--format=json|gesc`, `--gesc-tool=PATH`, `--gesc-level=N`.

### 5.1 Output

| Path (under `--out`) | Content |
|:---|:---|
| `<name>.scene.json` | Root v2 scene: suns and `ge_global` objects, `chunks` manifest, `splines` asset link |
| `<name>/chunks/chunk_<x>_<z>.scene.json` | One v2 scene per occupied cell, with `cellBounds` (XZ = the cell, Y = content height ±1 m) and `model` asset links |
| `<name>/meshes/<mesh>.glb` + `.asset.json` | One Y-up GLB per unique mesh (linked duplicates share it; objects with modifiers get their own), plus an engine model asset with triangle-mesh and convex-hull collision |
| `<name>/<name>.splines.json` | Every curve object |
| `<name>/export_report.json` | Chunk / entity / biome counts and warnings |
| `*.meta` | GUIDs derived from the project-relative path, so re-exports and other machines keep asset identities (existing sidecars are kept) |

Each object goes to the cell that contains its origin: `floor(x / cellSize), floor(z / cellSize)` in engine space. Blender Z-up is converted to engine Y-up as `(x, y, z) → (x, z, -y)`, with quaternions and scales converted to match. Object hierarchies are flattened to world transforms. Sun lights always go to the root scene. Point and spot lights are streamed with their cell.

### 5.1.1 Binary chunks (`--format=gesc`)

The default output is JSON only. With `--format=gesc` the exporter still writes every `chunk_<x>_<z>.scene.json` (the editable source) and also encodes each one to `chunk_<x>_<z>.gesc` ([GESC](chunk-format.md): columnar, zstd, CRC-checked). Each `.gesc` is verified right after encoding. The root manifest `scenePath` entries then point at the `.gesc` files, which `WorldStreamer` loads by content; the root scene stays JSON. `export_report.json` lists both `scenePath` (streamed file) and `sourcePath` (JSON source) per chunk.

```bash
dub build --config=gesc    # once: builds ./game-engine-gesc
blender -b level01.blend -P tools/blender_export_scene.py -- --name=level01 --format=gesc
```

The tool is looked up in this order: `--gesc-tool=PATH`, `$GAME_ENGINE_GESC`, `<project-root>/game-engine-gesc`, `<repo>/game-engine-gesc`, then `PATH`. If none exists (or `--gesc-tool` is not executable) the export stops before writing anything with an error that says how to build it. Chunk size is the existing `--cell-size`: the exporter already emits one chunk per cell, so no separate split step is needed. `--gesc-level` sets the zstd level (default 6).

### 5.2 Custom properties

| Property | Values | Effect |
|:---|:---|:---|
| `ge_physics` | `static` (meshes default), `dynamic`, `kinematic`, `none` | Physics body. Dynamic or kinematic `triangleMesh` is coerced to `convexHull`, with a warning |
| `ge_shape` | `triangleMesh` (static default), `convexHull` (dynamic default), `primitive` | Collider shape |
| `ge_surface` | `asphalt`, `concrete`, `dirt`, `gravel`, `grass`, `sand`, `snow`, `ice`, `mud`, `wood`, `metal`, `rubber` | Friction/restitution preset |
| `ge_friction`, `ge_restitution`, `ge_mass` | numbers | Explicit overrides |
| `ge_global` | bool | Put the object in the always-loaded root scene |
| `ge_biome` | string | Report tag (defaults to the first `Biome_<name>` collection) |
| `ge_skip` | bool | Do not export |
| Curves: `ge_role`, `ge_width`, `ge_lanes`, `ge_speed_limit` | | Spline attributes. Bézier curves export as `bezier` (handles included); poly/NURBS curves export as `catmullRom` through their points |

### 5.3 Loading the result

Chunks load through `engine.scene.chunk_components.applyChunk` (used by `WorldStreamer`): entities are spawned with
`SceneWorld.spawnBatch` and the `Transform` / `Name` columns and every binary component block are inserted with
`RawComponentStore.addBatch` (one growth of the sparse set, one pass over the dense array, ids and order identical
to per-entity inserts). Pre-cooked `.gesc` chunks with binary component blocks skip the per-component JSON parse;
see [chunk-format.md](chunk-format.md). On the 22.5 MB / 55 k-entity Viatura VI map (debug build) decode +
apply drops from about 540 ms to about 105 ms.

The output is a regular v2 world. Open the root scene in the editor, or run `game-engine-player --scene=assets/world/level01.scene.json`. The player starts `WorldStreamer` from the manifest.

`--build-test-level` generates `assets/world/ow8_test_level`: forest, desert and snow biomes over 3 × 3 cells of 256 m, with a Bézier main road, a closed traffic loop, a river, dynamic crates and a sun. `engine.scene.world_export_tests` validates every chunk, model and spline, and streams the whole level through `WorldStreamer` (load all, partial unload, full unload with shared models released). The backend has Python tests: `python3 -m unittest tools/test_blender_export_scene.py`.

---

### 5.4 Shipping chunks in an asset pak

In production exports (`--protect-assets` / `--embed-pak`) chunk files are read from the encrypted `GEPK` pak instead of loose files: `WorldStreamer` asks the mounted pak first (`engine.assets.pak.readMountedAssetNoGc`, `@nogc`, decrypting into a malloc buffer on the worker thread) and falls back to disk otherwise. Chunk `scenePath` values in the manifest are the pak keys, so keep them relative to the project root as exported (for example `Assets/world/chunk_0_0.gesc`). Use `--pak-dir=<dir>` to pack chunk folders outside the assets directory. Details: [export-guide.md](export-guide.md).

### 5.5 Streaming tests for GESC and the pak

- `engine.scene.gesc_soak_tests` repeats the 100-cycle load/unload soak (`streamer.soak100Cycles9Km2`) for `.gesc` chunks: plain v1 files and v2 files with binary component blocks (mixed in one grid). The resulting world digest (entity count, positions, component values) must equal the JSON soak's, with no entity leak and bounded `EntityId` capacity. The same soak runs against a mounted pak (virtual paths absent on disk) and must match the disk run.
- A corruption soak damages chunks mid-run (truncated, CRC mismatch, bad magic, truncated header): the damaged chunks spawn nothing, the streamer keeps running, undamaged chunks are unaffected and nothing leaks.
- `worldExport.gescExportRoundTripThroughStreamer` mirrors `--format=gesc`: it encodes the Blender test level's chunks to `.gesc`, rewrites the manifest `scenePath` values, saves and reloads the root scene, and checks the streamed world equals the JSON one.
- Default soak size is 6 x 6 cells and 20 cycles; set `GESC_SOAK_FULL=1` for 12 x 12 cells (9.4 km2) and 100 cycles.

---

## 6. API Reference

Load time = allocates, call outside the frame loop. `@nogc` = safe per frame.

### `engine.hotreload.watcher`

| Symbol | Notes |
|:---|:---|
| `enum WatchBackend { automatic, inotify, polling }` | `automatic` = `inotify` on Linux, `polling` elsewhere; `inotify` falls back to `polling` when it cannot start |
| `FileWatcher.init(roots, debounceSeconds = 0.3, backend = automatic)` | Recursive; skips missing roots; false when none exists |
| `poll(dt)` → `bool` | True when a batch has settled; read it with `changedPaths()` (valid until the next true) |
| `changedPaths()`, `backend()`, `active()` | Batch, chosen backend, running state |
| `pollInterval` | Seconds between polling rescans (default 0.25) |
| `addDirectory(path)`, `addDirectoryRecursive(root)`, `watchedDirectoryCount()` | Manual `inotify` watches (no-ops for polling) |
| `shutdown()` | Releases watches; idempotent |

### `engine.hotreload.asset_reload`

| Symbol | Notes |
|:---|:---|
| `AssetHotReloader.init(roots, debounceSeconds = 0.2, backend = automatic)` | Also caches every `*.prefab.json` below `roots` |
| `poll(dt, ref HotReloadTargets)` → `uint` | Resources/instances reloaded this frame (0 most frames) |
| `applyChanges(paths, ref HotReloadTargets)` → `uint` | Apply a batch without the watcher |
| `watchTexture(path, Texture*, desc, onSwapped)` / `unwatchTexture(Texture*)` | Registered texture slot |
| `watchSurfaceShader(path, id)` | Custom surface shader from `Scene3DTextured.createSurfaceShader` |
| `trackPrefab(path)`, `cachedPrefabCount()` | Snapshot a prefab definition (instances spawned later diff against it) |
| `onSceneChanged(string path)` | Owner callback for a changed `*.scene.json` |
| `onFilesChanged(const(string)[] paths)` | Called with every settled batch, after the built-in handlers |
| `lastStats` (`AssetReloadStats`: `files`, `models`, `textures`, `shaders`, `prefabInstances`, `scenes`, `tunableFiles`, `failures`, `total()`) | Counters of the last batch |
| `batchCount` | Batches applied since `init`; compare it before and after `poll` to detect a batch |
| `HotReloadTargets { gpu, renderer, world, assetDb, tunables, surfaceScene }` | Null members are skipped; `surfaceScene` defaults to `&renderer.scene` |
| `classifyAssetPath(path)` → `AssetChangeKind { other, model, texture, shader, prefab, scene, tunable }` | Classifies by suffix |
| `batchContains(batch, path)` | Path comparison that ignores spelling (normalized) |
| `guidForAsset(path, const(AssetDatabase)*)` | GUID from the database, else from the `.meta` sidecar |

### `engine.hotreload.tunables`

| Symbol | Notes |
|:---|:---|
| `addFile(path)`, `addFilesUnder(root)`, `loadFile(path)`, `loadText(path, json)` | Register / (re)load; paths are normalized; parse errors keep the old values |
| `key(name)` → `StringId`, `findKey(name)`, `keyName(id)` | Intern once at load time |
| `getFloat` / `getInt` / `getBool` / `getVec3` (`StringId` or name, fallback) | The `StringId` overloads are `@nogc nothrow` |
| `value(id)` → `TunableValue { type, count, file, v[4] }`, `has(id)` | Raw access (`TunableType { missing, number, boolean, vector }`) |
| `setNumber(name, value)` | Code-side default |
| `applyTo(ref T, prefix)`, `applyToComponents!C(world, prefix)` | Copy `prefix.field` values |
| `onReloaded`, `generation()`, `fileVersion(path)`, `files()`, `watches(path)`, `keyCount()` | Change tracking |
| `describe(id, ref FrameArena)` | `key=value` debug label without GC |
| `isTunablePath(path)`, `tunableFileSuffix` | `*.tune.json` convention |

### Model and prefab reload

| Symbol | Notes |
|:---|:---|
| `SceneRenderer.enableDependencyTracking()`, `tracksDependencies()` | Turn on dependency lists (one extra glTF parse per model) |
| `SceneRenderer.reloadChangedFiles(gpu, paths)` → `uint` | Transactional swap of affected models; retries failed imports |
| `SceneRenderer.dependenciesOf(assetJsonPath)` | Files a loaded model depends on |
| `assetDependencies(assetJsonPath)`, `gltfFileDependencies(gltfPath)` | Normalized dependency lists |
| `reloadPrefabInstances(world, guid, oldPrefab, newPrefab)` → `uint` | Rebuild instances and keep their overrides (`engine.scene.prefab`) |

### `engine.math.spline`

| Symbol | Notes |
|:---|:---|
| `Spline3 { kind, closed, alpha, up, points }` | `rebuild(samplesPerSegment = 32)` bakes the LUT (load time) |
| `segmentCount()`, `baked()`, `length()`, `samples()` | Introspection |
| `evaluate(u)`, `derivative(u)`, `tangentAt(u)` | Parameter space `u ∈ [0, segmentCount]` |
| `paramAtDistance(s)`, `distanceAtParam(u)` | Arc-length conversion |
| `sampleAtDistance`, `tangentAtDistance`, `frameAtDistance(s, FrameMode)` → `SplineFrame { position, tangent, normal, binormal }` | `@nogc` |
| `closestPoint(p, FrameMode)` → `SplineHit { param, distance, position, separation, lateral }` | `@nogc` |
| `extrudeRibbon(spline, RibbonOptions { width, step, widthSegments, lateralOffset, verticalOffset, uvLength, frameMode })` → `RibbonMesh { vertices, indices }` | Load time |
| `bezierPoint`, `bezierDerivative`, `catmullRomPoint(p0..p3, t, alpha)` | Free curve primitives (pure, `@nogc`) |

### `engine.scene.splines`

| Symbol | Notes |
|:---|:---|
| `loadSplineSetFile(path)`, `parseSplineSetJson(text, samplesPerSegment = 32)`, `splineSetToJson(set)` | Load (and bake) / write |
| `SplineSet { paths, strings }`: `find(name)`, `countRole(role)`, `closest(pos, hit, role)`, `text(id)` | The `closest(pos, hit, StringId role)` overload is `@nogc` |
| `SplinePath { name, role (StringId), width, lanes, speedLimit, curve }` | One path |
| `sceneSplineSetPath(scene)`, `splineAssetLinkKind` | Spline set linked from a root scene |

### `tools/blender_export_scene.py` (Python)

| Symbol | Notes |
|:---|:---|
| `export_world(desc, project_root, out_dir, cell_size, load_radius, unload_radius, log)` | Pure backend; the `desc` format is in its docstring |
| `gather_blender_scene(name, project_root, out_dir, collection)` | Blender frontend: writes the GLBs and returns `desc` |
| `build_test_level()` | Generates the multi-biome test scene |
| `blender_to_engine_vec` / `_quat` / `_scale`, `cell_of`, `guid_for`, `SURFACES` | Helpers (Z-up → Y-up, cell index, deterministic GUID, surface presets) |

---

## See also

- [plan-open-world-readiness.md](plan-open-world-readiness.md): `OW-8` status and decisions.
- [plan-scripting-hot-reload.md](plan-scripting-hot-reload.md): HR-0..HR-3 roadmap.
- [editor-guide.md](editor-guide.md) · [scripting-guide.md](scripting-guide.md) · [game-development-guide.md](game-development-guide.md).

#### Streaming decode path

`WorldStreamer` splits loading in two. The worker thread (GC-excluded) reads the chunk bytes (pak or disk) and, for
GESC files, also validates, inflates and decodes them with `readChunkNoGc` into malloc-owned columns; the main thread
only runs `applyChunkNoGc` (instancing into the `SceneWorld`, `GescBlockHandler`s). Decoded chunks are freed right
after they spawn, and when a load is cancelled, fails, or the streamer is destroyed. A corrupt `.gesc` is reported
with a warning and the cell activates empty. `*.scene.json` chunks keep the old path (parse on the main thread), as
does the JSON text of non-cooked custom components. `WorldStreamer.stats()` reports `workerDecodeUsecs`,
`mainPrepareUsecs` and `mainApplyUsecs`. Measured on the 144 chunks (55 k entities, debug build) of the Viatura VI map,
per chunk: main thread 5.2 ms before (GC decode + apply) to 4.2 ms after, worker 1.0 ms. In that map every chunk
still carries custom JSON components, and parsing them is 3.7 ms of the remaining main-thread time; with binary
component blocks the apply is about 0.4 ms (`loadSceneAdditive` alone). Re-measure with
`GESC_BENCH_DIR=<chunk dir> dub test --config=library`.
