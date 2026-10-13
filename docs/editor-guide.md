# Visual Game Engine Editor Guide

This guide covers the architecture, workflow, and features of the Unity and Godot-grade visual game editor with D language scripting.

---

## 1. Overview & Architecture

The visual editor (`--config=editor`) is built natively using the engine's custom retained-mode UI system (`engine.ui`), WGPU rendering pipeline, and dynamic ECS (`SceneWorld`).

- **Architecture:** 100% native D, `@safe:` by default, DIP1000 enabled (`-preview=dip1000`).
- **Memory & GC:** Strictly `@nogc` in engine frame loops. Zero GC allocations over 600 continuous frames verified in benchmarks.
- **Docking System:** Recursive H/V split tree (`DockSpace`) supporting tab dragging, panel resizing, persistence, and default 4-zone layout (Hierarchy, Scene/Game View, Inspector, Project/Console).
- **Text & Glyph Atlas:** Dynamic SDF text rendering via `stb_truetype` compiled in `libs/libstb.a`, supporting full Latin-1 Supplement (pt-BR accented characters: `á, é, í, ó, ú, ç, ã, õ`).
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

## 5. Build & Standalone Export

Exporting a game produces a standalone bundle that runs without the editor:
- **Output:** `build/linux-x86_64/`
- **Included Content:**
  - Standalone player binary `game-player` compiled via `--config=player`.
  - Cooked assets in `assets/`.
  - Required runtime shared libraries in `libs/`.
  - Portable launcher script `run.sh` (`chmod +x`).
- **Execution:** Run `./run.sh` from any terminal or file manager.
