# Plan: Terrain and Water Editor

> **Status:** pending · Priority: low–medium · See [roadmap.md](roadmap.md)

## Objective

Level design tools for **heightfield terrain** and **water surfaces** (simple lakes and oceans), integrated into the scene editor ([plan-editor-ux.md](plan-editor-ux.md)) — height brushes, basic texture splatting, Box3D heightfield colliders, and water plane rendering with adjustable water level.

This is a focused level authoring tool, not a sprawling AAA procedural world generator (no hydraulic erosion simulation, no full SPH fluids).

## Dependencies

- Visual scene editor v1 (picking, gizmos, save/load, asset DB) — [plan-editor-ux.md](plan-editor-ux.md)
- Physics: Box3D heightfield colliders (extension of P5) — [plan-physics-api.md](plan-physics-api.md)
- Multi-light + shadows for viewport preview

## Scope (v1)

### Terrain

- [ ] Heightmap grid stored as an asset (`*.asset.json` with `terrain` kind or dedicated height data file)
- [ ] GPU grid mesh generated from heightmap + optional distance LOD
- [ ] Sculpting brushes: raise / lower / smooth / flatten (radius + strength parameters)
- [ ] Texture splatting for 1–4 surface layers (albedo + tiling scale)
- [ ] Static Box3D `heightfield` collider synchronized with the sculpted heightmap
- [ ] Serialized in the asset; scene references the terrain entity

### Water

- [ ] Water plane / grid mesh with adjustable Y elevation and XZ bounds
- [ ] Water material (tint color, roughness, alpha transparency or basic screen refraction)
- [ ] Subtle surface motion (UV scrolling normal maps or low-cost vertex displacement waves)
- [ ] Optional depth/stencil underwater absorption tint
- [ ] `Water` entity in scene with elevation gizmo handle

## Out of Scope (v1)

- Hydraulic / thermal erosion simulation, procedural river splines
- Full FFT ocean simulation with Gerstner wave spectrums
- Real-time caustics, dynamic shoreline foam simulation, underwater volumetric fog
- Voxel terrain / CSG geometry
- Open-world streaming terrain tiles

## Draft Phases

| Phase | Deliverable |
|:---|:---|
| TW-1 | Heightmap asset format + GPU mesh generator + load/save pipeline |
| TW-2 | Editor sculpting brushes + brush stroke undo/redo |
| TW-3 | Box3D heightfield collider generation and synchronization |
| TW-4 | Water plane mesh + water shader material + scene entity |
| TW-5 | Polish: 2–4 layer texture splatting, wave animation, golden test scene |

## Acceptance Criteria

1. Sculpting terrain in the editor, saving, and reopening reproduces the exact surface relief.
2. Character controller and physics bodies collide accurately with the heightfield.
3. Placing a water plane allows editing its level and seeing live updates in the viewport.
4. Reference scene available in `assets/scenes/terrain_water.scene.json`.

## References

- [plan-editor-ux.md](plan-editor-ux.md)
- [plan-physics-api.md](plan-physics-api.md)
- [plan-pbr.md](plan-pbr.md)
