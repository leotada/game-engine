# Physics quickstart (Box3D)

Gameplay physics lives in `engine.physics`. Import that module — **do not**
import `bindings.box3d` from game code.

Backend: Box3D (C). Thin D wrappers use `Vec3` / `Quat` from `engine.math`.

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

## Bodies and shapes

| Helper | Motion |
|:---|:---|
| `createStaticBox` / `createKinematicBox` / `createDynamicBox` | box (hull) |
| `createStaticSphere` / `createKinematicSphere` / `createDynamicSphere` | sphere |
| `createStaticCapsule` / `createDynamicCapsule` / `createSensorCapsule` | capsule (Y axis) |
| `createStaticCylinder` / `createDynamicCylinder` | cylinder hull |
| `createSensorBox` | static sensor box |
| `createGroundSlab` | large static floor |

Pass an optional `EntityId` to map bodies to ECS entities (stored in Box3D
userData). Recover with `getBodyEntity` / `getShapeEntity`.

Motion helpers: `set/getLinearVelocity`, `set/getAngularVelocity`,
`applyForceToCenter`, `applyLinearImpulseToCenter`, damping, restitution,
`destroyBody`, `writeBodyTransform` / `readBodyTransform`.

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

## Queries

```d
// Closest ray
auto hit = castRayClosest(world, origin, direction, maxDist);

// AABB / sphere overlap (callback may stop early by returning false)
overlapAabb(world, minCorner, maxCorner, &onOverlap, &ctx);
overlapSphere(world, center, radius, &onOverlap, &ctx);
```

`defaultPhysicsQueryFilter()` sets default category/mask bits. Pass a custom
`b3QueryFilter` overload when you need layers.

## Joints

```d
auto j = createDistanceJoint(world, bodyA, bodyB, anchorA, anchorB);
auto h = createRevoluteJoint(world, bodyA, bodyB, worldAnchor, axis);
auto w = createWeldJoint(world, bodyA, bodyB, worldAnchor);
destroyJoint(j);
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
| `dub run --config=test-physics-box3d` | headless smoke: stack, sensors, ray, capsule, overlap, joints, character |

## Rules of thumb

1. Game code: `import engine.physics;` only.
2. Components stay POD; store `b3BodyId` / entity ids, not class refs.
3. No allocations inside the physics step path in engine code (`@nogc`).
4. Mesh / heightfield colliders are not wrapped yet (see plan P5).

Remaining work / history: [plan-physics-api.md](plan-physics-api.md),
[physics-box3d-benchmark.md](physics-box3d-benchmark.md).
