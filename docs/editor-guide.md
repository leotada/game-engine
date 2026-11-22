# Visual Game Engine Editor Guide

This guide covers the architecture, workflow, and features of the Unity and Godot-grade visual game editor with D language scripting.

---

## 1. Overview & Architecture

The visual editor (`--config=editor`) is built natively using the engine's custom retained-mode UI system (`engine.ui`), WGPU rendering pipeline, and dynamic ECS (`SceneWorld`).

- **Architecture:** 100% native D, `@safe:` by default, DIP1000 enabled (`-preview=dip1000`).
- **Memory & GC:** Strictly `@nogc` in engine frame loops. Zero GC allocations over 600 continuous frames verified in benchmarks.
- **Docking System:** Recursive H/V split tree (`DockSpace`) supporting tab dragging, panel resizing, persistence, and default 4-zone layout (Hierarchy, Scene/Game View, Inspector, Project/Console).
- **Text & Glyph Atlas:** Dynamic FreeType 2 SDF and hinted bitmap font rendering via `SDL3_ttf` (`source/bindings/sdl3_ttf.d`), supporting kerning, fallback fonts, and full Unicode + Latin-1 Supplement (pt-BR accented characters: `á, é, í, ó, ú, ç, ã, õ`).
- **Input & Windowing:** SDL3 platform wrapper with full keyboard/mouse event dispatching and IME text input.

---

## 2. Editor Workspace & Panels

### 2.1 Hierarchy Panel (`Hierarchy`)
- Displays the active scene entity tree based on `Parent` and `Name` components.
- Live selection of entities; click to select, click background to deselect.
- "Criar" button allows instantly spawning 3D primitives (Cubo, Esfera, Plano) or custom entities.

### 2.2 Scene View (`Scene`)
- Interactive 3D viewport rendered via WGPU offscreen render target.
- Fly / Orbit camera navigation with mouse look and WASD movement.
- Transform Gizmos:
  - **W / 1:** Translate mode
  - **E / 2:** Rotate mode
  - **R / 3:** Scale mode
- Object picking and surface snapping.

### 2.3 Game View (`Game`)
- Preview of the gameplay camera as seen by the player.
- Active camera rendering with lighting, materials, and physics simulation.

### 2.3.1 Scene Rendering (`SceneRenderer`)
The Scene View, the Game View and the standalone player all draw the scene with the same `engine.editor.scene_renderer.SceneRenderer`, built on `Scene3DTextured`, so what you see in the editor is what the player shows:
- **Primitives** (Cubo, Esfera, Plano) use a white OpenPBR material; the entity's `MaterialOverride.baseColor` / `geometryOpacity` is applied as the instance tint. The other OpenPBR override fields (metalness, roughness, coat…) are not applied per entity yet.
- **Mesh entities** (`Visual.kind = mesh`, `*.asset.json`) load the asset's glTF/GLB `render.source` once with `loadGltfAsset` — every node, primitive, material and texture (mipmapped, 8× anisotropic sampler). Assets that fail to load are logged once and drawn as a cube.
- **Lights** come from the scene's `Light` components (`packLightsFromWorld`) with directional, point and spot shadows. A scene with no lights gets a default sun, so it is never black.
- **Water** (`WaterSurface` entities, **Criar > Água**) is drawn by an `engine.water.WaterRenderer` owned by the `SceneRenderer` (editor and player call `enableWater` once). The entity's position sets the center and water level, its Y rotation turns the waves, river channel and current. Up to 4 water entities are drawn; while any exists, the engine sky (which the water reflects) is shown. See [water-guide.md § Scenes and the editor](water-guide.md#scenes-and-the-editor-enginewatercomponent).
- **Culling and LOD** are automatic (frustum culling, per-view shadow caster culling, screen-space LOD for meshes with LOD chains). Call `renderer.unloadAsset(stringId)` to release cached `GltfAsset` slots when streamed chunks unload.
- **Environment (Scene / IBL panel, no entity selected):**
  - **Cascaded shadows** turns 4 cascades on or off for the scene sun.
  - **Shadow distance** sets the cascade max distance, 10–1000 m.
  - **Debug cascades** tints cascades 0–3 red, green, blue and yellow, to tune the distance.
  - **Fog** turns on linear HDR height fog, with **Fog density**, **Fog falloff** and **Fog base**. Fog is saved in the scene file under `settings.fog`.
  - See [graphics.md § Outdoor Rendering](graphics.md#outdoor-rendering-ow-3).
- **LOD chains:** add `"lod": {"enabled": true, "maxLods": 4, "ratio": 0.5, "maxError": 0.05}` under `settings` in the glTF's `.meta` sidecar (e.g. `assets/models/rock_cliff.gltf.meta`). Every loader (`loadGltfAsset`, `loadGltfMesh`, `loadGltfPbr`) then builds the chain at import time. Missing keys keep the `LodSettings` defaults.

See [graphics.md § Open-World Rendering](graphics.md#open-world-rendering-ow-2).

### 2.4 Inspector Panel (`Inspector`)
- Dynamic compile-time reflection (`TypeRegistry` & `FieldDescriptor`):
  - Numeric fields with `@range(min, max)` sliders.
  - Vectors (`Vec2`, `Vec3`, `Vec4`) and Quaternions (`Quat`).
  - Colors (`Color4`) with color pickers.
  - Strings and interned `StringId` identifiers.
  - Generational handles (`Handle!T`, `EntityRef`, `AssetRef!T`).
- Prefab header with **Apply** and **Revert** actions for prefab instances.
- **Água** section for `WaterSurface` entities: **Oceano** / **Rio** preset buttons and drag fields for half size (**Metade**), wave height (**Ondas**), current (**Correnteza**) and caustics (**Cáusticas**). Changes show live and are saved with the scene; undo/redo of spawn and delete keeps the component.

### 2.5 Project & Asset Browser (`Project`)
- Directory tree and asset grid for `assets/` and `scripts/`.
- Automatic 128-bit persistent GUID assignment and `.meta` sidecar generation.
- **Cena → Abrir cena... (`Ctrl+O`)**: opens a picker listing every `*.scene.json` under `assets/`. Click a scene to load it. Opening a scene discards unsaved changes, and the console warns when there were any.
- **Opening a scene frames the camera** on all of its entities (`engine.editor.scene_frame`, `framePose`), so the content is on screen instead of wherever the fly camera last was. An empty scene keeps the default camera.
- **Components the editor cannot render**: scene components whose type is not registered in the editor (for example a game-defined `viatura.prop`) are loaded with their entity but not drawn as geometry. The console warns with the component types, and each one is drawn as an orange wireframe box at its entity's world position, with the local scale as its size. Real geometry for those components still comes from the game's own runtime code.
- **+ Script D**: Creates a ready-to-use D script component from template in `scripts/`.
- **+ Material**: Creates a new `.material.json` material definition.
- **Refresh**: Re-scans the filesystem for external asset changes.

### 2.6 Console Panel (`Console`)
- Captures all engine logs (`info()`, `warn()`, `err()`) via a high-performance circular ring buffer.
- Filtering by severity (Info, Warning, Error) and clear functionality.

---

## 3. Play Mode & Simulation

The editor features a non-destructive Play Mode:
- **Play (`Ctrl+P` or Toolbar "Play"):**
  1. Captures a complete in-memory snapshot of the entire scene (`worldToSceneFile`).
  2. Initializes Box3D physics simulation (`PhysicsSimSession.beginSimulate(world, physics, makeAssetResolver(world))`), resolving `triangleMesh` and `convexHull` geometry from `*.asset.json` / `.gltf` assets in both Editor Play Mode and the standalone player.
  3. Dispatches `onStart` lifecycle callbacks to all script components.
  4. Runs fixed physics ticks (`fixedUpdate`) and per-frame logic (`update`, `lateUpdate`).
- **Pause ("Pause"):** Freezes physics simulation and script updates while keeping the viewport responsive.
- **Step ("Step"):** Advances the simulation by exactly one frame (1/60 s).
- **Stop ("Stop"):**
  1. Calls `onDestroy` on active script components.
  2. Terminates Box3D physics bodies.
  3. Restores the scene snapshot into `SceneWorld`, returning all entities, transforms, and properties to their exact pre-play state.

---

## 4. Prefabs & World Streaming

- **Prefab Format:** `*.prefab.json` shares the version 2 scene schema (`game-engine.scene`).
- **Additive Instantiation:** Dragging a prefab into the scene or calling `instantiatePrefab(world, prefab, strings, guid, offset)` loads the prefab additively via `loadSceneAdditive` (preserving existing world entities) and attaches `PrefabInstance(prefabGuid, sourceRoot, spawnOffset)` to the root.
- **Overrides (`PrefabPropertyOverride`):** `diffPrefabOverrides` compares a live prefab instance subtree against its source `SceneFile`; `applyPropertyOverridesToSceneFile` and `applyPropertyOverrides` apply captured per-field overrides to disk definitions or live instances.
- **Apply to Prefab (`applyPrefabOverrides`):** Uses `subtreeToSceneFile` to serialize only the prefab instance's subtree in prefab-local space (subtracting `spawnOffset` and omitting `PrefabInstance`) back to `*.prefab.json` without touching unrelated world entities.
- **Revert (`revertPrefab`):** Destroys the full child hierarchy (`destroyPrefabHierarchy`) and re-instantiates the prefab cleanly at `spawnOffset` (preserving any external parent link).

### 4.1 Additive Scenes & World Chunk Streaming (`SceneFile` v2)

- **Additive Scene Loading (`engine.editor.scene_load`):** `loadSceneAdditive(world, scene, rootOffset)` spawns entities into an existing `World` / `SceneWorld` and remaps file-local `id` and `parent` indices without wiping existing entities.
- **`SceneFile` v2 (`engine.scene.scene_file`):** Adds `ChunkManifest` (`cellSize`, `loadRadius`, `unloadRadius`, `chunks[]`), `SceneCellBounds`, `SceneAssetLink` (`AssetGuid` + `strings[]` path + `kind`), `visual.assetGuid`, and per-chunk light-cap validation.
- **Blender Worlds:** `tools/blender_export_scene.py` writes a root scene + per-cell chunk scenes + GLB models + `*.splines.json` that open directly in the editor and stream in the player. See [world-pipeline-guide.md §5](world-pipeline-guide.md#5-blender-scenechunk-exporter).
- **Runtime Streaming (`engine.scene.streamer`):** `WorldStreamer` loads/unloads cells with hysteresis (`unloaded → loading → active → unloading`), runs file I/O on a GC-excluded background worker (`ScopedGcExcludedThread`), bounds GPU/ECS uploads per frame (`processUploadQueue`), and reference-counts `GltfAsset`, `Texture`, `CookedMesh`, and `NavMesh` tiles. The standalone player ([tools/player/player_main.d](../tools/player/player_main.d)) activates `WorldStreamer` automatically when a scene embeds `ChunkManifest`.

### 4.2 Asset, Prefab, Scene & Tunable Hot-Reload

The editor polls an `AssetHotReloader` over `assets/` every frame. It is disabled in `--headless-frames` runs, so `--assert-no-gc` stays at 0 bytes.

- **Models:** edits to `*.asset.json`, glTF/GLB, `.bin`, `.meta` or any image a model uses re-import that model and swap it in place. A broken file keeps the previous model and logs the error.
- **Prefabs:** saving a `*.prefab.json`, from a text editor or with *Apply to Prefab*, rebuilds every live instance and keeps each instance's own overrides. Rebuilt instances get new entity IDs, so a selection pointing into one is cleared.
- **Open scene:** an external edit to the open `*.scene.json` reopens it. This is skipped for the editor's own saves, while there are unsaved edits (a warning is logged instead), and during Play.
- **Tunables:** every `assets/**/*.tune.json` is loaded at startup and reloads live, during Play too.

Details: [world-pipeline-guide.md §1](world-pipeline-guide.md#1-asset-hot-reload-hr-1).

---

## 5. Build & Multiplatform Release Export

Exporting a game compiles the standalone player ([tools/player/player_main.d](../tools/player/player_main.d)) with `-version=StaticSDLDeps` and packages a self-contained bundle with `assets/` and `THIRD-PARTY-LICENSES.txt` (`ExportPipeline` in [source/editor/build_export.d](../source/editor/build_export.d)):

- **Editor UI Workflow:** Open **Arquivo → Exportar Release (Linux / Windows / macOS / Web)** in the top menu bar.
- **CLI Export Tool:**
  ```bash
  dub run --config=export -- --list-targets
  dub run --config=export -- --check-toolchains
  dub run --config=export -- --target=linux-x86_64 --release --archive
  ```
- **Static Dependencies Setup:** Run `./tools/build_sdl3_deps.sh <target>` to build and stage `SDL3`, `SDL3_image`, `SDL3_ttf`, `FreeType`, `wgpu_native`, and `Box3D` static archives under `libs/<target>/`.
- **Target Export Matrix:**

| `--target=<value>` | Aliases | LLVM Triple | Static Libs (`libs/`) | Bundle & Archive Output |
|:---|:---|:---|:---|:---|
| `linux-x86_64` | `linux`, `linux_x86_64` | `x86_64-unknown-linux-gnu` | `libs/linux-x86_64/` | `game-player`, `run.sh`, `.desktop`, `.tar.gz` |
| `linux-arm64` | `linux-aarch64` | `aarch64-unknown-linux-gnu` | `libs/linux-arm64/` | `game-player`, `run.sh`, `.desktop`, `.tar.gz` |
| `windows-x86_64` | `windows`, `win64` | `x86_64-pc-windows-msvc` | `libs/windows-x86_64/` | `game-player.exe`, `assets/`, `.zip` |
| `macos-arm64` | `darwin-arm64` | `arm64-apple-macos12.0` | `libs/macos-arm64/` | `<Title>.app`, `assets/`, `.zip` |
| `macos-x86_64` | `darwin-x86_64` | `x86_64-apple-macos11.0` | `libs/macos-x86_64/` | `<Title>.app`, `assets/`, `.zip` |
| `macos-universal` | `macos`, `darwin` | `arm64` + `x86_64` (`lipo`) | `libs/macos-arm64/` + `macos-x86_64/` | `<Title>.app` (`lipo` + ad-hoc `codesign`), `.zip` |
| `web-wasm32` | `web`, `wasm`, `wasm32` | `wasm32-unknown-emscripten` | `libs/web-wasm32/` | `<name>.html`, `.js`, `.wasm`, `.data`, `.zip` |

Full per-target CLI options, required static libraries, linker flags, and shell details: [export-guide.md](export-guide.md).
