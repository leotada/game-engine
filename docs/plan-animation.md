# Plan: Skeletal Animation

> **Status:** pending · Priority: medium · See [roadmap.md](roadmap.md)

## Objective

GPU skinning loaded from glTF files: joints, weights, inverse bind matrices, animation clips, and time sampling — sufficient for animated characters and props.

Chosen API design: **POD ECS components** (`SkeletonPose`, `AnimationPlayer`), not a heavy `AnimatedModel` class.

## Current State

Real repository paths:

- [`assets/gltf.d`](../source/engine/assets/gltf.d) — static mesh → `TexMesh`; no `JOINTS_0` / `WEIGHTS_0`, no `skin`, no `animations`, no `.glb`
- No vertex skinning pipeline
- [`scene/graph.d`](../source/engine/scene/graph.d) — transform hierarchy; **not** a bone skeleton

## Out of Scope

- Morph targets / blend shapes (future phase)
- Skeleton retargeting
- Physics ragdolls — depends on Box3D joints ([plan-physics-api.md](plan-physics-api.md) P3); outside the scope of this plan

## Dependencies

- Existing glTF loader (to be extended)
- [gc-safe-architecture-plan.md](gc-safe-architecture-plan.md) — poses and clips stored in engine storage must pass `isPod!T`

## Phases

### AN-1 — POD Data Structures

- [ ] `Skeleton` / joints indexed by integer ID (no heap class references)
- [ ] `Skin` — inverse bind matrices (IBM) + joint index arrays
- [ ] `AnimationClip` — keyframes in contiguous arrays
- [ ] `StringId` for joint and clip names
- [ ] Components: `SkeletonPose`, `AnimationPlayer`

**DoD:** Types compile with `isPod` / `Pod!T` where stored within the ECS.

### AN-2 — glTF Loader Extensions

- [ ] Parse `skins` + accessors for `JOINTS_0` / `WEIGHTS_0`
- [ ] Parse `animations` (LINEAR interpolation; CUBICSPLINE later if needed)
- [ ] Documented test asset under `assets/models/`

**DoD:** Loading 1 skinned glTF file populates `Skin` + clips without rendering yet.

### AN-3 — Pose Evaluation

- [ ] Sample clip(s) → local joint transforms → skeleton world matrices
- [ ] Minimum 2-clip blend (linear interpolation / spherical quaternion slerp)
- [ ] Strictly `@nogc` on hot evaluation path; transient scratch allocations via `FrameArena`

**DoD:** Bone matrices update over time in a headless unit test or benchmark.

### AN-4 — GPU Skinning Pipeline

- [ ] Vertex shader with UBO/storage buffer of bone matrices
- [ ] Dedicated skinning pipeline or feature permutation in textured pipeline
- [ ] Documented maximum active bone limit (e.g. 64 or 128 joints)

**DoD:** Skinned mesh renders on screen following the sampled pose.

### AN-5 — Demo & ECS Systems

- [ ] Gameplay systems updating `AnimationPlayer` / `SkeletonPose`
- [ ] Executable demo: animated idle/walk character or prop

**DoD:** Running `dub run --config=anim` displays a looping skinned animation.

## Acceptance Criteria

1. Skinned glTF model reproduces the reference animation correctly.
2. Pose evaluation and bone buffer uploads in the frame path are `@nogc`.
3. All animation components stored in ECS are strictly POD.

## References

- `source/engine/assets/gltf.d`, `graphics/texmesh.d`, `scene/graph.d`
- [gc-safe-architecture-plan.md](gc-safe-architecture-plan.md)
