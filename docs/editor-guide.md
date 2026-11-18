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

### 2.4 Inspector Panel (`Inspector`)
- Dynamic compile-time reflection (`TypeRegistry` & `FieldDescriptor`):
  - Numeric fields with `@range(min, max)` sliders.
  - Vectors (`Vec2`, `Vec3`, `Vec4`) and Quaternions (`Quat`).
  - Colors (`Color4`) with color pickers.
  - Strings and interned `StringId` identifiers.
  - Generational handles (`Handle!T`, `EntityRef`, `AssetRef!T`).
- Prefab header with **Apply** and **Revert** actions for prefab instances.

### 2.5 Project & Asset Browser (`Project`)
- Directory tree and asset grid for `assets/` and `scripts/`.
- Automatic 128-bit persistent GUID assignment and `.meta` sidecar generation.
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
  2. Initializes Box3D physics simulation (`PhysicsSimSession.beginSimulate`).
  3. Dispatches `onStart` lifecycle callbacks to all script components.
  4. Runs fixed physics ticks (`fixedUpdate`) and per-frame logic (`update`, `lateUpdate`).
- **Pause ("Pause"):** Freezes physics simulation and script updates while keeping the viewport responsive.
- **Step ("Step"):** Advances the simulation by exactly one frame (1/60 s).
- **Stop ("Stop"):**
  1. Calls `onDestroy` on active script components.
  2. Terminates Box3D physics bodies.
  3. Restores the scene snapshot into `SceneWorld`, returning all entities, transforms, and properties to their exact pre-play state.

---

## 4. Prefabs

- **Prefab Format:** `*.prefab.json` shares the version 2 scene schema.
- **Instantiation:** Dragging a prefab into the scene or calling `instantiatePrefab(...)` creates the entity hierarchy and attaches a `PrefabInstance` component containing the asset's GUID.
- **Overrides:** Modifying fields on an instance stores localized overrides.
- **Apply to Prefab:** Updates the master `*.prefab.json` definition on disk with current instance values.
- **Revert:** Discards overrides and restores the instance to match the master prefab asset.

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
- **Target Bundle Outputs:**
  - **Linux (`linux-x86_64`, `linux-arm64`):** Static `game-player` ELF (`dub build --config=player-static --compiler=ldc2 --build=release` on host `x86_64`), executable `run.sh`, `game-player.desktop`, `assets/`, `THIRD-PARTY-LICENSES.txt`, and `.tar.gz` archive.
  - **Windows (`windows-x86_64`):** Standalone `game-player.exe` linked against static `.lib` archives, `assets/`, `THIRD-PARTY-LICENSES.txt`, and `.zip` archive.
  - **macOS (`macos-arm64`, `macos-x86_64`, `macos-universal`):** `<AppTitle>.app` bundle (`Contents/Info.plist`, `Contents/MacOS/game-player`, `Contents/Resources/assets/`, optional `lipo` universal binary + ad-hoc `codesign`) and `.zip` archive.
  - **Web (`web-wasm32`):** Compiled via `ldc2 -mtriple=wasm32-unknown-emscripten` + `emcc` (`-sUSE_WEBGPU=1 -sASYNCIFY=1 --preload-file assets@/assets`) using [tools/web/shell.html](../tools/web/shell.html), producing `<name>.html`, `.js`, `.wasm`, `.data`, and a `.zip` archive.
