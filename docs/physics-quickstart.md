# Physics quickstart (Box3D)

Gameplay physics lives in `engine.physics`. Import that module — **do not**
import `bindings.box3d` from game code.

Backend: Box3D (C). Thin D wrappers use `Vec3` / `Quat` from `engine.math` and enforce `@safe nothrow @nogc` + POD storage.

## Happy path

```d
import engine.physics;
import engine.math.vec : Vec3;

auto world = PhysicsWorld(Vec3(0, -9.81f, 0));
auto floor = createGroundSlab(world, 0.0f, Vec3(20, 0, 20), 0.5f);
auto ball  = createDynamicSphere(world, Vec3(0, 5, 0), 0.5f, 1.0f);

ContactListener listener; // fill callbacks as needed

// each frame:
world.step(dt);
drainPhysicsEvents(world, listener);
immutable hit = castRayClosest(world, origin, dir, 100.0f);
immutable xform = readBodyTransform(ball); // sync mesh / camera
```

Frame order: **step → drain events → read transforms** (or write kinematic
transforms before step).

## Bodies, descriptors, and shapes

| Helper | Motion |
|:---|:---|
| `createStaticBox` / `createKinematicBox` / `createDynamicBox` | box (hull) |
| `createStaticSphere` / `createKinematicSphere` / `createDynamicSphere` | sphere |
| `createStaticCapsule` / `createDynamicCapsule` / `createSensorCapsule` | capsule (Y axis) |
| `createStaticCylinder` / `createDynamicCylinder` | cylinder hull |
| `createStaticHull` / `createKinematicHull` / `createDynamicHull` | convex hull from point cloud |
| `createStaticMesh` | static triangle mesh (RAII `CookedMesh` or world-owned) |
| `createHeightField` | static terrain heightfield (RAII `CookedHeightField` or world-owned) |
| `createSensorBox` / `createGroundSlab` | static sensor box / large static floor |

For full control over filters, surface material IDs, CCD (`isBullet`), initial sleep state (`startAwake`), sleep threshold, and damping, pass `BodyDesc` to `createBoxBody`, `createSphereBody`, `createCapsuleBody`, `createCylinderBody`, or `createHullBody`:

```d
BodyDesc bulletDesc;
bulletDesc.type = PhysicsBodyType.dynamic;
bulletDesc.position = Vec3(-5, 2, 0);
bulletDesc.isBullet = true; // continuous collision detection
bulletDesc.startAwake = true;
bulletDesc.enableHitEvents = true;
bulletDesc.material = PhysicsSurfaceMaterial(0.6f, 0.1f, 0.0f, /*userMaterialId*/ 42);
bulletDesc.filter = CollisionFilter(/*category*/ 0x2, /*mask*/ 0x1, /*groupIndex*/ -7);
auto b = createBoxBody(world, bulletDesc, Vec3(0.2f, 0.2f, 0.2f));
```

Pass an optional `EntityId` to map bodies to ECS entities (stored in Box3D
userData). Recover with `getBodyEntity` / `getShapeEntity`.

Runtime body and shape helpers: `set/getLinearVelocity`, `set/getAngularVelocity`,
`applyForceToCenter`, `applyForce` (at a world point), `applyLinearImpulse`, `applyLinearImpulseToCenter`, `applyAngularImpulse`,
`getMass`, `getMassData` / `setMassData` / `resetMassFromShapes` (mass, local center of mass and inertia tensor; `BodyMassData.diagonal(...)` overrides them, e.g. a vehicle whose inertia comes from its bounding box), `getLocalCenterOfMass`, `getLocalInertiaDiagonal`, `getRotation`, `setLinearDamping`, `setAngularDamping`, `setBodyRestitution`, `setBodyDensity`,
`setBodyType` / `getBodyType`, `isBodyAwake` / `setBodyAwake`, `enableBodySleep` /
`setBodySleepThreshold`, `setBodyBullet` / `isBodyBullet`, `setBodyFilter` / `setShapeFilter`,
`setBodySurfaceMaterial` / `setShapeSurfaceMaterial`, `destroyBody`, and
`writeBodyTransform` / `readBodyTransform`. `world.awakeBodyCount()` reports awake bodies.

## Static meshes & heightfields

Dynamic triangle meshes are intentionally forbidden (Box3D only generates mesh contacts on static bodies). Both `createStaticMesh` and `createHeightField` accept per-triangle / per-cell `materialIndices` plus a `PhysicsSurfaceMaterial[]` table:

```d
PhysicsSurfaceMaterial[2] mats = [
    PhysicsSurfaceMaterial(0.95f, 0.0f, 0.0f, /*asphalt*/ 101),
    PhysicsSurfaceMaterial(0.25f, 0.0f, 0.0f, /*mud*/ 202),
];
// Use `heightFieldHole` (0xFF) in `cellMaterials` to punch terrain holes.
auto terrain = createHeightField(world, Vec3.init, heights, countX, countZ,
    Vec3(2.0f, 1.0f, 2.0f), cellMaterials, mats, terrainEntity);
```

For streaming chunks where geometry lifetime is managed explicitly across reloads, pre-cook once into move-only RAII handles `CookedMesh.create(...)` or `CookedHeightField.create(...)` (keep the cooked object alive while shapes reference it).

## Sensors and contact events

```d
auto trigger = createSensorBox(world, Vec3(0, 1, 0), Vec3(2, 2, 2), sensorEntity);

ContactListener listener;
listener.onSensorEnter = &onEnter;
listener.onSensorExit  = &onExit;
listener.onContactHit  = &onHit;   // needs enableHitEvents / setHitEventThreshold
listener.context = &myState;

world.step(dt);
drainPhysicsEvents(world, listener);
```

`PhysicsHitEvent` includes `materialIdA`, `materialIdB`, `approachSpeed`, `approachImpulse`, `normalImpulse`, and `frictionImpulse`.

For impact damage, prefer `approachSpeed` (closing speed along the normal, m/s, always positive) or `approachImpulse` (`approachSpeed` times the reduced mass `mA*mB/(mA+mB)`, kg*m/s; a static body counts as infinite mass). `normalImpulse` is the sum of Box3D's `totalNormalImpulse` over the manifold points, which accumulates across solver sub-steps and includes speculative points, so it overestimates the impact and changes with the sub-step count; use it only to detect that a contact interacted.

## Queries

```d
// Closest ray (returns `hit.entityId` and `hit.surfaceMaterialId`)
auto hit = castRayClosest(world, origin, direction, maxDist);

// Filtered ray or AABB / sphere overlap (callback returns false to stop early)
auto filter = makeQueryFilter(/*category*/ 0x1, /*mask*/ 0x3);
auto filteredHit = castRayClosest(world, origin, direction, maxDist, filter);
overlapAabb(world, minCorner, maxCorner, &onOverlap, &ctx);
overlapSphere(world, center, radius, &onOverlap, &ctx);
```

## Joints & breakable constraints

| Helper | Purpose |
|:---|:---|
| `createDistanceJoint` | fixed or bounded distance constraint |
| `createRevoluteJoint` | hinge with optional `RevoluteJointConfig` (limits, spring, motor) |
| `createWeldJoint` | rigid or compliant (`WeldJointConfig`) attachment |
| `createSphericalJoint` | ball-socket / ragdoll cone-twist limits & damping (`SphericalJointConfig`) |
| `createWheelJoint` | vehicle suspension + steering + spin motor (`WheelJointConfig`) |
| `createPrismaticJoint` | linear slider along axis (`PrismaticJointConfig`) |
| `createFilterJoint` | disable collisions between a specific pair of bodies |

Use `@nogc` `BreakableJointTracker` to break welds/hinges automatically when reaction forces exceed thresholds:

```d
BreakableJointTracker breakables;
breakables.registerJoint(weld, /*breakForce*/ 500.0f, /*breakTorque*/ 250.0f, /*tag*/ 7);

// After `world.step(dt)`:
breakables.update(world, &onJointBroken, &ctx);
```

## Character controller

Kinematic capsule mover (not a rigid body). Application drives wish direction;
Box3D `CastMover` / `CollideMover` / `SolvePlanes` resolve collisions.

```d
auto player = CharacterController(Vec3(0, 1, 0), 1.8f, 0.35f);

// each frame (after or interleaved with world.step as you prefer):
player.move(world, wishDir, dt, jumpPressed);
// player.position / player.velocity / player.onGround
```

## Demos

| Demo / config | Teaches |
|:---|:---|
| `dub run --config=pong3d` | kinematic paddles, sensors, hits, zero gravity |
| `dub run --config=marble-run` | dynamics, impulses, sensors |
| `dub run --config=test-physics-box3d` | headless suite: primitives, heightfields, materials, hit impulses, breakable/ragdoll joints, filters, sleeping, CCD |

## Rules of thumb

1. Game code: `import engine.physics;` only.
2. Components stay POD; store `b3BodyId` / `b3JointId` / `EntityId`, not class refs.
3. No allocations inside the physics step path in engine code (`@nogc`).
4. Keep `CookedMesh` / `CookedHeightField` alive longer than any bodies referencing them (or let `PhysicsWorld` own convenience meshes/heightfields).

History & planning: [plan-physics-api.md](plan-physics-api.md),
[plan-open-world-readiness.md](plan-open-world-readiness.md),
[physics-box3d-benchmark.md](physics-box3d-benchmark.md).
