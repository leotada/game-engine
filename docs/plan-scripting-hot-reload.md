# Plan: Hot-Reload (Assets + Data + Shaders)

> **Status:** in progress · Priority: medium · See [roadmap.md](roadmap.md)

## Objective

Iterate on content without restarting the process: reload textures/meshes/WAVs, data tunables, and shaders during development.

## Current State

- **WGSL Shaders**: Fully implemented modular system with include preprocessor (`#include`, `#define`, `#ifdef`), CTFE compile-time embedding, and **transactional runtime hot-reload** via `ShaderHotReloader` (`source/engine/hotreload/shader_reload.d`). See [multiplatform-and-shaders.md](multiplatform-and-shaders.md).
- Gameplay in D within the same binary (`dub run --config=…`) or via dynamic modules using `HotReloadManager`.
- Disk assets (BMP/glTF/WAV) are load-once without an active file watcher.

## Out of Scope (v1)

- Hot-reload of low-level GPU core bindings (`bindings/wgpu.d`, `bindings/sdl3.d`)
- Embedded scripting language VMs (Lua, Wren, etc.)
- Play-in-editor engine core rebuilds

## Dependencies

- GPU handles / `StringId` for safe resource swapping
- Reload UX surfaced in the Editor console and overlay

## Phases

### HR-0 — Shader Hot-Reload (Completed)

- [x] File watcher (inotify) for `assets/shaders/`
- [x] Preprocessor supporting `#include`, `#define`, `#ifdef`, `#ifndef`
- [x] Transactional pipeline compilation that preserves existing bind group layouts and keeps the active pipeline upon syntax/validation errors
- [x] Integration with Editor app loop

**DoD:** Editing any `.wgsl` file updates the rendering in real time without crashing or interrupting frames.

### HR-1 — Asset Hot-Reload (Textures, Meshes, Audio)

- [x] Filesystem watcher for textures / glTF (`FileWatcher` with `changedPaths()`, `inotify` + portable mtime polling) — WAV/OGG audio clips are **not** reloaded yet
- [x] Re-import + swap of GPU resources and handles (`AssetHotReloader`, `SceneRenderer.reloadChangedFiles`, `watchTexture`, `watchSurfaceShader`, prefab instances via `reloadPrefabInstances`)
- [x] Explicit ownership: loaders in `engine.assets`; upload in `engine.gpu` / `engine.graphics` — the owner destroys the replaced resource right after the swap, between frames ([world-pipeline-guide.md §1](world-pipeline-guide.md#1-asset-hot-reload-hr-1))
- [x] Clear diagnostic logs on parse failure (retaining the previous asset)

**DoD:** Editing a BMP/TGA on disk refreshes the texture in-engine without restarting. ✅ (`OW-8`)

### HR-2 — Game Data Tunables

- [x] Simple data format (JSON) for tunables: speeds, HP, spawn intervals (`*.tune.json`, `TunableRegistry`)
- [x] Hot-reload applies to alive components via `StringId` keys (`applyToComponents`)
- [x] Transient debug strings allocated via `FrameArena` (`TunableRegistry.describe`)

**DoD:** Changing a float in a data file alters gameplay behavior on the next reload tick. ✅ (`OW-8`)

### HR-3 — Developer Experience (DX)

- [ ] "Reload All" command and shortcut in the editor
- [ ] Debug overlay / console displays last reload timestamp and diagnostics
- [ ] Section in the game development guide

**DoD:** A keyboard shortcut refreshes all observed assets and data files.

## Acceptance Criteria

1. Modifying a texture on disk updates the scene without restart (HR-1).
2. Changing a tunable in a data file updates runtime values immediately (HR-2).
3. Shader hot-reload remains strictly transactional and non-destructive (HR-0).

## References

- `source/engine/hotreload/shader_reload.d`
- `source/engine/assets/`, `devtools/overlay.d`, `core/strings.d`
- [multiplatform-and-shaders.md](multiplatform-and-shaders.md)
- [plan-editor-ux.md](plan-editor-ux.md)
