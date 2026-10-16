# Plan: Gameplay Physics API (Box3D)

> **Status:** P0–P4 + P6 completed · P5 (mesh) deferred · See [roadmap.md](roadmap.md)

## Objective

Complete the high-level D layer `engine.physics` on top of Box3D so games can utilize physics without directly importing or invoking `bindings.box3d` — common shapes, spatial queries, basic joints, character controller, and comprehensive documentation.

Backend: **Box3D** (C). Manual C99 bindings in `source/bindings/box3d/`.
High-level gameplay API in `source/engine/physics/`.

Quickstart Guide: [physics-quickstart.md](physics-quickstart.md).
The previous native Jolt port was cancelled ([jph-port-plan.md](jph-port-plan.md)).
Migration benchmark report: [physics-box3d-benchmark.md](physics-box3d-benchmark.md).

## Current State

| Module | Features & Capabilities |
|:---|:---|
| [`world.d`](../source/engine/physics/world.d) | Create/destroy world, simulation stepping, gravity, sleeping bodies, CCD, hit threshold |
| [`body.d`](../source/engine/physics/body.d) | Box / sphere / capsule / cylinder (static/kinematic/dynamic), sensors, ground slab, velocities, impulses |
| [`events.d`](../source/engine/physics/events.d) | Contact begin/end, sensor enter/exit, hit events → `ContactListener` |
| [`queries.d`](../source/engine/physics/queries.d) | `castRayClosest`, `overlapAabb`, `overlapSphere`, query filters |
| [`joints.d`](../source/engine/physics/joints.d) | Distance, revolute, and weld joints |
| [`character.d`](../source/engine/physics/character.d) | `CharacterController` (CastMover + CollideMover + SolvePlanes) |
| [`convert.d`](../source/engine/physics/convert.d) | Conversion utilities between `Vec3`/`Quat` and Box3D types |

Demos: `pong3d`, `marble_run`, `test_physics_box3d`.

## Out of Scope / Deferred

- Soft bodies / cloth simulation
- Multithreaded Box3D tasks beyond the `workerCount` already exposed on the world
- Visual collider authoring UI — see [plan-editor-ux.md](plan-editor-ux.md) ED-5a/5b
- Heightfield terrain (P5 partial; static triangle meshes are the focus for editor v1)

## Phases

### P0 — Quickstart Documentation

- [x] Physics section in [game-development-guide.md](game-development-guide.md)
- [x] Dedicated [physics-quickstart.md](physics-quickstart.md)
- [x] Minimal working examples aligned with gameplay demos

**DoD:** Dedicated quickstart guide + cross-links. ✅

### P1 — Common Shapes

- [x] C bindings for capsule / cylinder / hull
- [x] Capsule static/dynamic/sensor bodies
- [x] Static / kinematic spheres
- [x] Cylinder via convex hull representation
- [x] Smoke test in `test_physics_box3d`

**DoD:** Common shape primitives implemented and tested. ✅

### P2 — Spatial Queries

- [x] `overlapAabb` / `overlapSphere`
- [x] Documented default collision filter

**DoD:** Spatial overlap queries working and tested. ✅

### P3 — Physics Joints

- [x] Bindings + `engine.physics.joints` (distance, revolute, weld)
- [x] Pendulum and hinge tests in `test_physics_box3d`

**DoD:** Joints functional and verified. ✅

### P4 — Character Controller

- [x] `CharacterController` with Box3D kinematic mover
- [x] Walking controller smoke test in `test_physics_box3d`

**DoD:** Character controller functional. ✅

### P5 — Static Mesh & Terrain Colliders (Deferred)

Pre-requisite for [plan-editor-ux.md](plan-editor-ux.md) ED-5b. Generic convex hulls (PHY-H) use existing bindings; triangle meshes require new bindings.

- [ ] **Static** triangle mesh from `TexMesh` / glTF (`b3CreateMeshShape`)
- [ ] Generic hull helpers: `createStaticHull` / `createDynamicHull` (PHY-H)
- [ ] API deliberately **forbids** dynamic triangle meshes in v1 (engine stability policy)
- [ ] Heightfield colliders when required by terrain editor

**DoD:** Bouncing dynamic sphere against static glTF mesh collider; dynamic convex hull smoke test passes.

### P6 — Jolt Physics Cleanup

- [x] Remove `public import engine.jph` from `source/engine/package.d`
- [x] Delete `source/engine/jph/` tree
- [x] Ensure `import engine;` re-exports exclusively Box3D physics

**DoD:** JPH code completely purged from the repository. ✅

## Acceptance Criteria

1. New games configure world + bodies + sensors + raycast/overlap + joints + character controller **without** `import bindings.box3d`.
2. `docs/physics-quickstart.md` covers the standard workflow.
3. `dub test` and `test_physics_box3d` pass cleanly.
4. No build configuration references JPH as an active backend.

## References

- Source: `source/engine/physics/`, `source/bindings/box3d/`
- Demos: `source/demo/pong3d.d`, `marble_run.d`, `test_physics_box3d.d`
- Usage: [physics-quickstart.md](physics-quickstart.md)
- Benchmark: [physics-box3d-benchmark.md](physics-box3d-benchmark.md)
