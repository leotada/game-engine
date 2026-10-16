# Port Plan: JoltPhysics → D (`engine.jph.*`)

> ## Status: CANCELLED
>
> This native D port was **abandoned**. The official physics engine is
> **Box3D** via `bindings/box3d` + gameplay API in `engine.physics`.
>
> Rationale: the native D port of Jolt lagged significantly in simulation throughput
> (see [physics-box3d-benchmark.md](physics-box3d-benchmark.md) — ~4× slower
> with LDC2 release, ~30× slower with DMD release) and still lacked a complete
> high-level gameplay API. Box3D provided superior performance and all needed features
> (sensors, raycasts, CCD, joints) without maintaining a secondary physics engine in D.
>
> **Removed from tree:** purged in Phase P6 (`source/engine/jph/` deleted;
> `public import engine.jph` removed from `source/engine/package.d`).
> Do not execute the pending phases in this document.
>
> Active physics: [physics-quickstart.md](physics-quickstart.md) ·
> [plan-physics-api.md](plan-physics-api.md). Overview: [roadmap.md](roadmap.md).
>
> The text below is preserved for **historical context**.

---

Incremental, commit-by-phase port of Jolt Physics (C++) to native D under the `engine.jph` namespace. Source of truth: `ref/JoltPhysics/Jolt/`.

## Global Port Conventions

- **One phase per commit.** Each phase concludes with `dub test --config=library` passing and all build configurations clean.
- **POD-first.** No classes, no GC pointers inside hot internal data structures; `!hasIndirections!T` is the benchmark.
- **`@safe:` at module top.** Unsafe C interop isolated in minimal `@trusted` blocks.
- **Strictly `@nogc` in engine frame path.** Engine core frame loop remains `@nogc`; gameplay API is permitted to allocate.
- **Index-based handles instead of pointers** for pooled structures (e.g. EPA triangles, Shape references).
- **No bindbc-* dependencies.** Bindings are manual `extern(C) nothrow @nogc` declarations in `source/bindings/`.

## Two-Epic Structure

The port was organized into **two epics** with segregated scopes:

### Epic 1 — Rigid Body Physics for Games (MVP Focus)

Minimal yet complete feature set for physics gameplay: multiple rigid bodies colliding at 60+ FPS, area triggers (sensors), and scene raycasting. Excluded joints, contact islands, multithreading, QuadTrees, mesh/heightfield/softbody shapes, decorated/compound shapes.

| #     | Phase                                                             | Status       | Commit    |
| ----- | ----------------------------------------------------------------- | ------------ | --------- |
| 0     | Backup + removal of old `engine.physics`                          | ✅ Completed | `7ce026b` |
| 1     | `jph.core` (Ref, Array, JobSystem, …)                             | ✅ Completed | `0fe3b25` |
| 2a    | `jph.geometry` primitives + GJK                                   | ✅ Completed | `5fd5f5c` |
| 2b    | `jph.geometry` EPA + rays                                         | ✅ Completed | `17d259a` |
| 3     | `jph.physics.body` (IDs, MP, enums, MotionProperties)             | ✅ Completed | `a325c5a` |
| 4a.0  | Base shape infrastructure (`Shape`, `ShapeSettings`, `SubShapeID`)| ✅ Completed | —         |
| 4a.1  | `ConvexShape` + Sphere/Box/Capsule                                | ✅ Completed | —         |
| 4a.2  | Cylinder, TaperedCylinder, TaperedCapsule, Triangle               | ✅ Completed | —         |
| 4a.3  | Degenerate (`PlaneShape`, `EmptyShape`)                           | ✅ Completed | —         |
| E1-1  | `MassProperties.Rotate`                                           | ✅ Completed | —         |
| E1-2  | Lean narrowphase (Box/Sphere/Capsule × Box/Plane + GJK fallback)  | ✅ Completed | —         |
| E1-3  | Brute-force broadphase                                            | ✅ Completed | —         |
| E1-3b | `BroadPhaseGrid` (spatial hash O(n·k))                            | ✅ Completed | —         |
| E1-P  | Performance tuning (pair dedup, ERP, iterations)                  | ⏳ In Progress| —        |
| E1-4  | `ContactConstraintManager` + PGS solver                           | ✅ Completed | —         |
| E1-5  | `BodyManager` + `BodyInterface` + `PhysicsSystem.Step()`          | ✅ Completed | —         |
| E1-6  | Sensors (triggers) + `ContactListener`                           | ⏳ In Progress| —        |
| E1-7  | Scene-level raycast (`NarrowPhaseQuery.CastRay`)                  | ⬜ Pending   | —         |
| E1-8  | Simple sleeping (no islands)                                      | ✅ Completed | —         |
| E1-9  | Migrate `test_physics.d` and `benchmark.d`                        | ✅ Completed | —         |
| E1-10 | Document gameplay API                                             | ⬜ Pending   | —         |

### Epic 2 — Complete Jolt Feature Set (Post-MVP)

Advanced capabilities, planned for after Epic 1 reached performance parity:

| #     | Phase                                                             | Status       |
| ----- | ----------------------------------------------------------------- | ------------ |
| E2-1  | `IslandBuilder` (island convergence + sleeping under contact)     | ⬜ Pending   |
| E2-2  | `BroadPhaseQuadTree` (O(n log n))                                 | ⏳ In Progress|
| E2-3  | Batched SIMD (`RayAABox4`, `RayTriangle4`, `Vec4` ops)            | ⏳ In Progress|
| E2-4  | Decorated shapes (Scaled, RotatedTranslated, OffsetCOM)           | ⬜ Pending   |
| E2-5  | `StaticCompoundShape` (BVH)                                       | ⬜ Pending   |
| E2-6  | Named constraints (Fixed, Point, Distance, Hinge, Slider, …)      | ⬜ Pending   |
| E2-7  | `ConvexHullShape` + builder                                       | ⬜ Pending   |
| E2-8  | `MeshShape`, `HeightFieldShape`, `MutableCompoundShape`           | ⬜ Pending   |
| E2-9  | `SoftBodyShape` + soft body solver                                | ⬜ Pending   |
| E2-10 | `JobSystemTaskPool` (multithreading)                              | ⬜ Pending   |
| E2-11 | Double-precision world + binary serialization + step listeners    | ⬜ Pending   |

---

## Phase 0 — Backup, Removal, Stubs ✅

**Commit:** `7ce026b`

- [x] Create `pre-jph-port` branch preserving previous implementation.
- [x] Remove `source/engine/physics/` (legacy class-based version).
- [x] Remove `import engine.physics.*;` from demos; build stubs.
- [x] Create empty `source/engine/jph/package.d` (re-exports only).
- [x] Confirm all 7 dub configurations compile cleanly.

---

## Phase 1 — `jph.core` ✅

**Commit:** `0fe3b25`. Core data structures and utilities:

- [x] `engine.jph.core.types` — scalar aliases (`uint_`, `uint8`, `uint16`, `uint32`, `uint64`, `Float3`, `Double3`).
- [x] `engine.jph.core.scalar` — numeric helpers (`Min`, `Max`, `Square`, `Sign`, `DegreesToRadians`, `RadiansToDegrees`).
- [x] `engine.jph.core.staticarray` — `StaticArray(T, N)` with `size()`, `push_back(auto ref)`, `pop_back`, `resize`, `data()`, index operator, `@disable this(this)`.
- [x] `engine.jph.core.array` — `Array(T)` (dynamic array wrapper with Jolt invariants).
- [x] `engine.jph.core.refcount` — `Ref(T)` intrusive reference counting.
- [x] `engine.jph.core.jobsystem` — `JobSystem` static interface + `JobSystemSingleThreaded` stub.
- [x] `engine.jph.core.tempallocator` — per-frame linear bump allocator.
- [x] Unittests covering `StaticArray`, `Array`, and `Ref`.

---

## Phase 2 — `jph.geometry` ✅

### Phase 2a — Primitives + GJK ✅

**Commit:** `5fd5f5c`

- [x] `plane.d` — `Plane` (`n·p + d = 0`).
- [x] `triangle.d` — `Triangle { Vec3[3] mV; }`.
- [x] `sphere.d` — `Sphere { Vec3 mCenter; float mRadius; }`.
- [x] `aabox.d` — `AABox` with `Contains`, `Overlaps`, `Expand`, `Transformed`.
- [x] `orientedbox.d` — OBB (center + half-extent axes).
- [x] `convexsupport.d` — `TransformedConvexObject`, `AddConvexRadius`, `PointConvexSupport`, `TriangleConvexSupport`.
- [x] `closestpoint.d` — point-simplex distance (2/3/4 vertices).
- [x] `gjk.d` — `GJKClosestPoint` with `GetClosestPoints`, `GetClosestPointsSimplex`, `Intersects`, `CastShape`.
- [x] `Vec4` additional constructors; re-exports in math and geometry packages.

### Phase 2b — EPA + Rays ✅

**Commit:** `17d259a`

- [x] `epa_hull.d` — `EPAConvexHullBuilder` (~430 LOC): fixed pool of 256 triangles, free-stack, manual max-heap by `mClosestLenSq`, shortest edge pair selection, `FindEdge` with explicit DFS.
- [x] `epa.d` — `EPAPenetrationDepth` (GJK → EPA), `EStatus {NotColliding, Colliding, Indeterminate}`, combined `GetPenetrationDepth`, `CastShape`.
- [x] `ray_aabox.d` — slab method raycast.
- [x] `ray_sphere.d`, `ray_triangle.d` (Möller–Trumbore), `ray_cylinder.d`, `ray_capsule.d`.
- [x] `math/findroot.d` — quadratic root solver.
- [x] Deferred: SIMD batched ray variants (`RayAABox4`, `RayTriangle4`).

---

## Phase 3 — `jph.physics.body` ✅

**Commit:** `a325c5a`

- [x] `bodyid.d` — 32-bit packed `BodyID` (23-bit index + 8-bit sequence + 1-bit reserved).
- [x] `bodytype.d`, `motiontype.d`, `motionquality.d` — motion enums.
- [x] `alloweddofs.d` — degrees-of-freedom bitmask helpers.
- [x] `bodypair.d` — packed 8-byte body pair with fast comparison.
- [x] `massproperties.d` — `SetMassAndInertiaOfSolidBox`, `ScaleToMass`, parallel axis theorem translation.
- [x] `motionproperties.d` — linear/angular velocities, force/torque accumulators, inverse mass, diagonal inverse inertia + orientation, damping, gravity factor, DOF locking masks, sleep timers.
- [x] `Mat44` algebraic helpers: `+= / -=`, `Multiply3x3RightTransposed`, `sOuterProduct`.

---

## Phase 4 — Shapes ✅

Polymorphic base + convex primitive shapes. Ref-counted classes via `mixin RefTargetMixin!T`.

- [x] `sub_shape_id.d` — packed `SubShapeID`, `SubShapeIDCreator`, `SubShapeIDPair`.
- [x] `scale_helpers.d` — scale validity, uniform scale checks, `RotateScale`.
- [x] `physics_material.d` — `PhysicsMaterial` ref-counted base and defaults.
- [x] `cast_result.d` — `RayCast`, `BroadPhaseCastResult`, `RayCastResult`.
- [x] `shape.d` — `EShapeType`, `EShapeSubType`, `ShapeResult`, abstract `ShapeSettings`, `ShapeFilter`, abstract `Shape` virtual interface.
- [x] `convex_shape.d` — abstract `ConvexShape : Shape` with support buffers.
- [x] `sphere_shape.d` — `SphereShape`.
- [x] `box_shape.d` — `BoxShape` with margin deduction.
- [x] `capsule_shape.d` — `CapsuleShape`.
- [x] `cylinder_shape.d`, `tapered_cylinder_shape.d`, `tapered_capsule_shape.d`, `triangle_shape.d`.
- [x] `plane_shape.d` — infinite static plane half-space.
- [x] `empty_shape.d` — collisionless trigger placeholder shape.

---

## Phase E1 — Rigid Body Simulation Pipeline

- [x] **E1-1** — `MassProperties.Rotate(Mat44)` world-space inertia transformation.
- [x] **E1-2** — SAT analytic collision tests: Box×Box, Box×Plane, Sphere×Plane, Capsule×Plane, with GJK+EPA fallback for mixed shapes.
- [x] **E1-3 / E1-3b** — Broadphase: `BroadPhaseBruteForce` and `BroadPhaseGrid` (uniform spatial hash).
- [x] **E1-4** — `ContactConstraintManager` with sequential impulse Projected Gauss-Seidel (PGS) contact solver and warm-starting.
- [x] **E1-5** — `BodyManager`, `BodyInterface`, and `PhysicsSystem.Step(dt)` simulation loop.
- [x] **E1-8** — Velocity sleep threshold and timers.
- [x] **E1-9** — Verified demos (`test_physics.d`, `benchmark.d`).

---

## Migration Conclusion

The native D Jolt port was decommissioned in favor of Box3D due to throughput advantages and complete feature parity in gameplay physics. Active development and maintenance occur in `engine.physics` (see [physics-quickstart.md](physics-quickstart.md)).
