# Plan: Editor UX (Scene / Level Editor)

> **Status:** delivered (v1) · Priority: medium · See [roadmap.md](roadmap.md)
>
> **Stream J Delivery:** `dub run --config=editor` runs the visual level editor (picking, gizmos+snapping, multi-selection, undo/redo stack, hierarchy/inspector panels, lights+shadows, physics Simulate/Esc, Ctrl+S/O/N scene I/O).

## Objective

Interactive scene editor for **3D level design** built atop existing gizmo and overlay systems: place and manipulate objects, configure lights (directional / point / spot) with **shadows**, edit attributes (mesh + PBR material + Box3D physics with static mesh and convex hull static/dynamic), versioned asset files decoupled from scenes, and scene save/load — focused on rapid level assembly rather than a full modeling DCC.

v1 Scope:

| Pillar | Features Delivered |
|:---|:---|
| **Level Design** | Spawning, picking, gizmos, grid snapping, hierarchy tree, duplicate/delete |
| **Lighting** | POD ECS `Light` component (UI: dedicated entity); dir/point/spot; **shadows required** on all shipped types; IBL presets |
| **Primitives / Meshes** | Built-in primitives + `meshAsset` + PBR materials |
| **Physics** | Primitives + **convex hull** (static **and** dynamic) + **triangle mesh** (static only) |
| **Assets** | Versioned `*.asset.json` format (render + collider + hull bake) — geometry is **never** embedded in the scene file |
| **Scene I/O** | Minified, versioned `*.scene.json`; asset paths referenced by `StringId`; rotations serialized as quaternions |

## Core Architectural Decisions

| # | Topic | Decision |
|---:|:---|:---|
| 1 | Light Limits | **1** directional + **8** point + **4** spot (UBO slots; exceeding budget is blocked in UI) |
| 2 | Shadows | **Mandatory** for every light type shipped in v1. |
| 3 | Light in ECS | POD `Light` component on entities; UI spawns dedicated entities (`Transform` + `Light`). Runtime gameplay can attach `Light` to any entity |
| 4 | Triangle Mesh | **Static only** (and kinematic where useful). Dynamic triangle meshes are **rejected** by API and inspector |
| 4b | Convex Hull | **Static and dynamic** (mandatory) |
| 5 | Geometry/Hull Storage | **Separate asset** (`*.asset.json`), not loose vertices inside scene files. Scenes only reference `StringId` paths |
| 6 | Collider Mesh | Default = asset visual mesh; optional override for alternate collision mesh or baked hull |
| 7 | Disk Format | **Minified** JSON (no pretty-printing); binary format deferred |
| 8 | Rotation | Disk + engine = **quaternion** `[x,y,z,w]`. Editor UI displays **Euler angles** (degrees), converting on input and serialization |

---

## Current State

Repository paths:

- [`engine.devtools.gizmos`](../source/engine/devtools/gizmos.d) — immediate 3D line overlay
- [`engine.devtools.overlay`](../source/engine/devtools/overlay.d) — FPS counter + text HUD labels
- [`engine.editor`](../source/engine/editor/) — ED-1 through ED-8 (picking, selection, gizmos, command stack, hierarchy/inspector, lighting, physics, scene I/O)
- [`source/editor/editor_app.d`](../source/editor/editor_app.d) — visual editor application (`dub run --config=editor`)

| Subsystem | Current API | Backlog / Evolution |
|:---|:---|:---|
| Scene Graph | `Transform` (quaternion) / `SceneGraph` | — |
| Lit Rendering | Multi-light UBO + dir/point/spot shadows | CSM, clustered forward, static shadow caching |
| Material | `Material` / `MaterialParams` + editor overrides | Material graph |
| Primitives / glTF | `primitives`, `TexMesh`, `loadGltf*` + `*.asset.json` | — |
| Physics | box/sphere/capsule/cylinder + hull + static mesh | VHACD dynamic convex decomposition |
| Editor App | `dub run --config=editor` level editor | Complete PIE, native OS file dialogs |

## Out of Scope

- Node-based material graph / shader graph editor
- Skeletal animation timeline ([plan-animation.md](plan-animation.md))
- Multi-user collaborative editing
- Area lights / light probe volumes / offline light baking
- Soft bodies, joints editor, character controller authoring UI
- Terrain and water editor in **v1** — see [plan-terrain-water.md](plan-terrain-water.md) (#7)
- Voxel terrain / CSG geometry / spline extrusion
- Deeply nested prefab inheritance browser
- Dynamic triangle meshes / runtime VHACD
- JSON pretty-printing in production save files

## Dependencies

- 3D gizmos and debug overlay
- Raycast picking (AABB, triangle mesh, Box3D colliders)
- Multi-light rendering and shadows
- Convex hull and static mesh physics
- Versioned asset and scene serialization

---

## Data Model (ECS + Editor)

The runtime and editor share POD components. The UI represents entities cleanly while data stays in cache-friendly ECS stores:

```text
Entity
├── Transform          // Always present; rot = quaternion
├── Name (StringId)    // Optional entity label
├── Parent / hierarchy // SceneGraph
├── Visual?            // Built-in primitive or asset reference
├── MaterialOverride?  // Optional material parameters override
├── PhysicsBody?       // Motion + shape reference via asset
└── Light?             // Directional | point | spot + shadow flags
```

Rules:
- Editor: `Transform` controls placement; physics simulation writes back via `readBodyTransform`.
- UI Euler angles ↔ quaternion conversions occur at the inspector boundary (`eulerToQuat` / `quatToEuler`); gizmos and save files only manipulate quaternions.
- Default collider = visual mesh of asset; override = alternate collision mesh or baked hull.
- Persistence: scenes reference assets; asset files hold geometry and baked hull vertices.

---

## Lighting — Directional / Point / Spot (+ Shadows)

### Specifications

| Type | Parameters | Attenuation | Shadows |
|:---|:---|:---|:---|
| **Directional** | `direction`, `color`, `intensity` | None | Orthographic shadow map; 1 caster (`castShadows`) |
| **Point** | `position`, `color`, `intensity`, `range` | Smooth inverse-square up to `range` | Depth cubemap (6 faces) + PCF; mandatory |
| **Spot** | `position`, `direction`, `color`, `intensity`, `range`, `innerConeDeg`, `outerConeDeg` | Inverse-square + angular falloff | Perspective shadow map + PCF |

UBO Limits: **1 directional + 8 point + 4 spot**. Creating lights beyond limits triggers a UI error.

### Shadow Budget

| Resource | Default Allocation |
|:---|:---|
| Directional map | 2048² depth texture |
| Point cubemap | Up to **2–4** point lights with `castShadows` @ 512²/face |
| Spot map | Up to **1–2** spot lights @ 1024² |

The editor provides a `castShadows` toggle. If the active shadow caster budget is exceeded, the editor warns the user and falls back to unshadowed lighting for surplus casters.

### Gizmos

- Directional: arrow + orthographic shadow bounding box
- Point: `range` wireframe sphere + light icon
- Spot: inner/outer cone wireframes + shadow camera frustum

---

## Colliders — Static Mesh + Static/Dynamic Convex Hull

### Supported Shapes

| Shape | Static | Kinematic | Dynamic |
|:---|:---|:---|:---|
| Primitives | ✅ | ✅ | ✅ |
| **Convex Hull** | ✅ | ✅ | ✅ |
| **Triangle Mesh** | ✅ | ✅ | ❌ |

### Collider Source Pipeline

```text
Asset
├── renderMesh          // Visual geometry
├── collisionMesh?      // Optional override; default = renderMesh
└── convexHull?         // Baked vertices for static or dynamic simulation
```

Convex Hull Workflow:
```text
Mesh (visual or collision override)
  → Extract unique vertex positions (object space)
  → b3CreateHull(points, count, maxVertexCount)
  → Store baked hull in *.asset.json
  → Instantiate static or dynamic hull at runtime
```

---

## Assets — Versioned Format (Decoupled from Scene)

Scene files **never** embed geometry or hull point arrays. All reusable model data lives in minified `*.asset.json` files referenced by path.

### Asset File Schema (`game-engine.asset` v1)

```json
{"format":"game-engine.asset","version":1,"kind":"model","meta":{"name":"crate"},"render":{"source":"assets/models/crate.gltf","primitive":null},"materials":[{"baseColor":[1,1,1,1],"metallic":0,"roughness":0.5,"albedo":"assets/tex/crate.bmp","flags":0}],"collision":{"triangleMesh":{"source":"render"},"convexHull":{"maxVertexCount":64,"points":[[0,0,0],[1,0,0]]}}}
```

---

## Persistence — Versioned Scene (Minified JSON)

### Objectives

- Lossless round-trip between editor, disk, and runtime loader
- Explicit schema `version` with migration chaining
- Quaternion storage on disk; no embedded geometry

### Scene File Schema (`game-engine.scene` v1)

Example (expanded for documentation readability; production disk files omit whitespace):

```json
{
  "format": "game-engine.scene",
  "version": 1,
  "meta": { "name": "arena_01", "units": "meters" },
  "strings": ["Sun", "assets/models/crate.asset.json", "Lamp"],
  "settings": {
    "gravity": [0, -9.81, 0],
    "iblPreset": "procedural_default"
  },
  "entities": [
    {
      "id": 1,
      "name": 0,
      "parent": 0,
      "transform": {
        "pos": [0, 1, 0],
        "rot": [0, 0, 0, 1],
        "scale": [1, 1, 1]
      },
      "visual": { "asset": 1 },
      "physics": {
        "enabled": true,
        "motion": "static",
        "shape": "triangleMesh",
        "friction": 0.5,
        "restitution": 0.1
      }
    },
    {
      "id": 2,
      "name": 2,
      "parent": 0,
      "transform": {
        "pos": [0, 5, 0],
        "rot": [0, 0, 0, 1],
        "scale": [1, 1, 1]
      },
      "light": {
        "type": "point",
        "color": [1, 0.9, 0.8],
        "intensity": 40.0,
        "range": 12.0,
        "castShadows": true
      }
    }
  ]
}
```

---

## Consolidated Milestones (All Completed in v1)

- [x] **ED-1 (Picking)**: Ray vs AABB / mesh raycasting, selection outline, closest hit detection.
- [x] **ED-2 (Transforms & Tools)**: Translate/rotate/scale gizmos, local/world coordinate spaces, grid snapping, primitive spawning, duplicate/delete.
- [x] **ED-3 (Hierarchy & Inspector)**: Tree view, POD component inspector, entity renaming, parenting.
- [x] **ED-4 (Materials)**: PBR parameter sliders (albedo, metallic, roughness), texture assignment.
- [x] **ED-5a (Primitive Physics)**: Body configuration, mass/friction/damping, simulation test mode.
- [x] **ED-5b (Hulls & Mesh Colliders)**: Convex hull baking into asset files, static mesh colliders.
- [x] **ED-6 (Lighting & Shadows)**: Directional, point, and spot light placement, shadow caster toggles, cubemap shadows.
- [x] **ED-7 (Scene File)**: Versioned minified JSON serialization, schema migrations, Ctrl+S / Ctrl+O workflows.
- [x] **ED-8 (Editor Polish)**: Multi-selection, command stack with full undo/redo, camera frame focusing.

## Backlog & Future Evolution

- **Static Shadow Caching**: Cubemap reuse for static lights and objects to avoid rendering 6 faces per frame.
- **Clustered Forward Rendering**: WGPU compute pass for light binning into 3D view-space clusters (supporting 100+ active point lights).
- Octahedral shadow map packing / shadow atlas.
- Cascaded Shadow Maps (CSM) for large directional outdoor scenes.
- Dynamic mesh convex decomposition via VHACD.
- Prefabs, full play-in-editor mode, joints editor.
- Terrain and water editing tools — see [plan-terrain-water.md](plan-terrain-water.md).
