module demo.test_physics_box3d;

import std.math : fabs;
import std.stdio : writefln, writeln;

import bindings.box3d;
import engine.ecs.store : EntityId;
import engine.math.vec : Vec3;
import engine.physics;

@safe:

private struct EventState {
    EntityId sensorEntity;
    EntityId rollerEntity;
    bool sensorEntered;
    bool sensorExited;
    bool printedEnter;
    bool printedExit;
}

private struct OverlapState {
    int hits;
    bool sawGround;
}

private void onSensorEnter(PhysicsSensorEvent event, void* context) nothrow @nogc @trusted {
    auto state = cast(EventState*) context;
    if (state !is null &&
        event.sensorEntity == state.sensorEntity &&
        event.visitorEntity == state.rollerEntity)
        state.sensorEntered = true;
}

private void onSensorExit(PhysicsSensorEvent event, void* context) nothrow @nogc @trusted {
    auto state = cast(EventState*) context;
    if (state !is null &&
        event.sensorEntity == state.sensorEntity &&
        event.visitorEntity == state.rollerEntity)
        state.sensorExited = true;
}

private bool onOverlap(b3ShapeId shapeId, b3BodyId bodyId, EntityId entityId, void* context) nothrow @nogc @trusted {
    auto state = cast(OverlapState*) context;
    if (state is null)
        return false;
    state.hits += 1;
    if (entityId == 1)
        state.sawGround = true;
    cast(void) shapeId;
    cast(void) bodyId;
    return true;
}

private bool testShapesJointsCharacter() {
    enum float dt = 1.0f / 60.0f;
    auto world = PhysicsWorld(Vec3(0.0f, -9.81f, 0.0f));

    createGroundSlab(world, 0.0f, Vec3(40.0f, 0.0f, 40.0f), 0.5f, 1);
    auto staticBall = createStaticSphere(world, Vec3(5.0f, 0.5f, 5.0f), 0.5f, 20);
    auto capsule = createDynamicCapsule(world, Vec3(2.0f, 3.0f, 0.0f), 1.6f, 0.3f, 1.0f, 21);
    auto cylinder = createStaticCylinder(world, Vec3(-5.0f, 1.0f, 0.0f), 2.0f, 0.5f, 22);

    // Distance joint pendulum: static anchor + dynamic bob
    auto anchor = createStaticBox(world, Vec3(8.0f, 4.0f, 0.0f), Vec3(0.2f, 0.2f, 0.2f), 30);
    auto bob = createDynamicSphere(world, Vec3(8.0f, 1.5f, 0.0f), 0.3f, 1.0f, 31);
    auto distJoint = createDistanceJoint(world, anchor, bob,
        Vec3(8.0f, 4.0f, 0.0f), Vec3(8.0f, 1.5f, 0.0f));

    // Revolute door hinge
    auto hingeBase = createStaticBox(world, Vec3(12.0f, 1.0f, 0.0f), Vec3(0.2f, 1.0f, 0.2f), 32);
    auto door = createDynamicBox(world, Vec3(13.0f, 1.0f, 0.0f), Vec3(1.0f, 1.0f, 0.1f), 1.0f, 33);
    auto revJoint = createRevoluteJoint(world, hingeBase, door,
        Vec3(12.0f, 1.0f, 0.0f), Vec3(0.0f, 1.0f, 0.0f));

    OverlapState overlap;
    immutable overlapCount = overlapAabb(world,
        Vec3(-1.0f, -1.0f, -1.0f), Vec3(1.0f, 2.0f, 1.0f), &onOverlap, &overlap);
    immutable sphereHits = overlapSphere(world, Vec3(5.0f, 0.5f, 5.0f), 1.0f, &onOverlap, &overlap);

    auto character = CharacterController(Vec3(0.0f, 1.0f, 8.0f), 1.8f, 0.35f);
    foreach (_; 0 .. 120) {
        world.step(dt, 4);
        character.move(world, Vec3(1.0f, 0.0f, 0.0f), dt);
    }

    bool pass = true;

    if (!isBodyValid(staticBall) || !isBodyValid(capsule) || !isBodyValid(cylinder)) {
        writeln("[test-physics-box3d] FAIL: shape bodies invalid");
        pass = false;
    }

    immutable capPos = getPosition(capsule);
    if (capPos.y < 0.5f || capPos.y > 4.0f) {
        writefln("[test-physics-box3d] FAIL: capsule y=%.3f", capPos.y);
        pass = false;
    }

    immutable bobPos = getPosition(bob);
    if (bobPos.y < 0.5f || bobPos.y > 4.5f || fabs(bobPos.x - 8.0f) > 3.0f) {
        writefln("[test-physics-box3d] FAIL: pendulum bob at (%.3f, %.3f, %.3f)",
            bobPos.x, bobPos.y, bobPos.z);
        pass = false;
    }

    if (overlapCount < 1 || sphereHits < 1 || !overlap.sawGround) {
        writefln("[test-physics-box3d] FAIL: overlap aabb=%d sphere=%d ground=%s hits=%d",
            overlapCount, sphereHits, overlap.sawGround, overlap.hits);
        pass = false;
    }

    if (character.position.x < 0.5f) {
        writefln("[test-physics-box3d] FAIL: character did not advance x=%.3f", character.position.x);
        pass = false;
    }
    if (character.position.y < 0.5f || character.position.y > 3.0f) {
        writefln("[test-physics-box3d] FAIL: character tunneled/fell y=%.3f", character.position.y);
        pass = false;
    }

    destroyJoint(distJoint);
    destroyJoint(revJoint);
    cast(void) door;
    cast(void) hingeBase;
    return pass;
}

/// Convex hull points for a unit box centered at origin (half-extent 0.5).
private immutable Vec3[8] boxHullPoints = [
    Vec3(-0.5f, -0.5f, -0.5f),
    Vec3( 0.5f, -0.5f, -0.5f),
    Vec3( 0.5f,  0.5f, -0.5f),
    Vec3(-0.5f,  0.5f, -0.5f),
    Vec3(-0.5f, -0.5f,  0.5f),
    Vec3( 0.5f, -0.5f,  0.5f),
    Vec3( 0.5f,  0.5f,  0.5f),
    Vec3(-0.5f,  0.5f,  0.5f),
];

/// Flat floor mesh in XZ (two triangles), local space y = 0.
private immutable Vec3[4] meshFloorVerts = [
    Vec3(-4.0f, 0.0f, -4.0f),
    Vec3( 4.0f, 0.0f, -4.0f),
    Vec3( 4.0f, 0.0f,  4.0f),
    Vec3(-4.0f, 0.0f,  4.0f),
];
private immutable int[6] meshFloorIndices = [0, 2, 1, 0, 3, 2];

private bool testHullAndMesh() {
    enum float dt = 1.0f / 60.0f;
    auto world = PhysicsWorld(Vec3(0.0f, -9.81f, 0.0f));

    auto meshFloor = createStaticMesh(world, Vec3(0.0f, 0.0f, 0.0f), meshFloorVerts[], meshFloorIndices[], 40);
    auto ball = createDynamicSphere(world, Vec3(0.0f, 5.0f, 0.0f), 0.5f, 1.0f, 41);

    // Dynamic convex hull drops onto a static hull pedestal.
    auto pedestal = createStaticHull(world, Vec3(6.0f, 0.5f, 0.0f), boxHullPoints[], 64, 42);
    auto hullDyn = createDynamicHull(world, Vec3(6.0f, 4.0f, 0.0f), boxHullPoints[], 64, 1.0f, 43);

    // Policy: dynamic triangle mesh must not be a public API.
    static assert(!__traits(compiles, createDynamicMesh(world, Vec3.init, meshFloorVerts[], meshFloorIndices[])),
        "createDynamicMesh must not be exposed (mesh colliders are static-only)");

    foreach (_; 0 .. 240)
        world.step(dt, 4);

    bool pass = true;

    if (!isBodyValid(meshFloor) || !isBodyValid(ball) || !isBodyValid(pedestal) || !isBodyValid(hullDyn)) {
        writeln("[test-physics-box3d] FAIL: hull/mesh bodies invalid");
        pass = false;
    }

    immutable ballPos = getPosition(ball);
    if (fabs(ballPos.y - 0.5f) > 0.4f || fabs(ballPos.x) > 1.5f || fabs(ballPos.z) > 1.5f) {
        writefln("[test-physics-box3d] FAIL: ball vs mesh rested at (%.3f, %.3f, %.3f)",
            ballPos.x, ballPos.y, ballPos.z);
        pass = false;
    }

    immutable hullPos = getPosition(hullDyn);
    if (fabs(hullPos.y - 1.5f) > 0.5f || fabs(hullPos.x - 6.0f) > 1.5f) {
        writefln("[test-physics-box3d] FAIL: dynamic hull rested at (%.3f, %.3f, %.3f)",
            hullPos.x, hullPos.y, hullPos.z);
        pass = false;
    }

    return pass;
}

private bool testHeightFieldAndMaterials() {
    enum float dt = 1.0f / 60.0f;
    auto world = PhysicsWorld(Vec3(0.0f, -9.81f, 0.0f));

    // 5x5 flat grid at y=0, scale=(2,1,2) => covers X=[0,8], Z=[0,8]
    float[25] heights = 0.0f;
    ubyte[16] cellMaterials = 0;
    cellMaterials[0] = 0;                 // col 0, row 0 => X=[0,2], Z=[0,2] (asphalt)
    cellMaterials[1] = 1;                 // col 1, row 0 => X=[2,4], Z=[0,2] (mud)
    cellMaterials[2] = heightFieldHole;   // col 2, row 0 => X=[4,6], Z=[0,2] (hole)

    PhysicsSurfaceMaterial[2] mats;
    mats[0] = PhysicsSurfaceMaterial(0.95f, 0.0f, 0.0f, 101);
    mats[1] = PhysicsSurfaceMaterial(0.25f, 0.0f, 0.0f, 202);

    auto hfBody = createHeightField(world, Vec3(0.0f, 0.0f, 0.0f),
        heights[], 5, 5, Vec3(2.0f, 1.0f, 2.0f), cellMaterials[], mats[], 500);

    // 300-iteration RAII Cook/Destroy loop + 280 world-owned static meshes (> 256 old cap).
    foreach (_; 0 .. 300) {
        auto cookedHf = CookedHeightField.create(heights[], 5, 5, Vec3(2.0f, 1.0f, 2.0f), cellMaterials[]);
        if (!cookedHf.valid()) {
            writeln("[test-physics-box3d] FAIL: CookedHeightField.create failed");
            return false;
        }
        auto cookedMesh = CookedMesh.create(meshFloorVerts[], meshFloorIndices[]);
        if (!cookedMesh.valid()) {
            writeln("[test-physics-box3d] FAIL: CookedMesh.create failed");
            return false;
        }
    }
    foreach (i; 0 .. 280) {
        auto mBody = createStaticMesh(world, Vec3(1000.0f + cast(float) i * 20.0f, -50.0f, 0.0f),
            meshFloorVerts[], meshFloorIndices[], cast(EntityId)(5000 + i));
        if (!isBodyValid(mBody)) {
            writefln("[test-physics-box3d] FAIL: static mesh #%d invalid", i);
            return false;
        }
    }

    // Cast rays against the bare heightfield before dropping spheres over those coordinates.
    immutable rayAsphalt = castRayClosest(world, Vec3(1.0f, 5.0f, 1.0f), Vec3(0.0f, -1.0f, 0.0f), 10.0f);
    immutable rayMud     = castRayClosest(world, Vec3(3.0f, 5.0f, 1.0f), Vec3(0.0f, -1.0f, 0.0f), 10.0f);
    immutable rayHole    = castRayClosest(world, Vec3(5.0f, 5.0f, 1.0f), Vec3(0.0f, -1.0f, 0.0f), 10.0f);

    auto solidSphere = createDynamicSphere(world, Vec3(1.0f, 2.0f, 1.0f), 0.35f, 1.0f, 501);
    auto holeSphere  = createDynamicSphere(world, Vec3(5.0f, 2.0f, 1.0f), 0.35f, 1.0f, 502);

    foreach (_; 0 .. 120)
        world.step(dt, 4);

    bool pass = true;
    if (!isBodyValid(hfBody)) {
        writeln("[test-physics-box3d] FAIL: heightfield body invalid");
        pass = false;
    }
    if (!rayAsphalt.hit || rayAsphalt.entityId != 500 || rayAsphalt.surfaceMaterialId != 101) {
        writefln("[test-physics-box3d] FAIL: asphalt ray hit=%s ent=%u mat=%u",
            rayAsphalt.hit, rayAsphalt.entityId, rayAsphalt.surfaceMaterialId);
        pass = false;
    }
    if (!rayMud.hit || rayMud.surfaceMaterialId != 202) {
        writefln("[test-physics-box3d] FAIL: mud ray hit=%s mat=%u",
            rayMud.hit, rayMud.surfaceMaterialId);
        pass = false;
    }
    if (rayHole.hit) {
        writeln("[test-physics-box3d] FAIL: ray hit hole cell");
        pass = false;
    }
    immutable solidY = getPosition(solidSphere).y;
    immutable holeY  = getPosition(holeSphere).y;
    if (fabs(solidY - 0.35f) > 0.25f) {
        writefln("[test-physics-box3d] FAIL: sphere on heightfield rested at y=%.3f", solidY);
        pass = false;
    }
    if (holeY > -2.0f) {
        writefln("[test-physics-box3d] FAIL: sphere over hole did not fall y=%.3f", holeY);
        pass = false;
    }
    return pass;
}

private struct HitImpulseState {
    bool gotHit;
    float maxNormalImpulse = 0.0f;
    ulong matA;
    ulong matB;
}

private void onImpulseHit(PhysicsHitEvent event, void* context) nothrow @nogc @trusted {
    auto s = cast(HitImpulseState*) context;
    if (s is null)
        return;
    s.gotHit = true;
    if (event.normalImpulse > s.maxNormalImpulse) {
        s.maxNormalImpulse = event.normalImpulse;
        s.matA = event.materialIdA;
        s.matB = event.materialIdB;
    }
}

private bool testHitEventImpulseAndMaterials() {
    enum float dt = 1.0f / 60.0f;
    auto world = PhysicsWorld(Vec3(0.0f, -9.81f, 0.0f));
    world.setHitEventThreshold(0.5f);

    BodyDesc floorDesc;
    floorDesc.type = PhysicsBodyType.static_;
    floorDesc.position = Vec3(0.0f, 0.0f, 0.0f);
    floorDesc.entityId = 601;
    floorDesc.material.userMaterialId = 20;
    floorDesc.enableHitEvents = true;
    createBoxBody(world, floorDesc, Vec3(5.0f, 0.5f, 5.0f));

    BodyDesc boxDesc;
    boxDesc.type = PhysicsBodyType.dynamic;
    boxDesc.position = Vec3(0.0f, 5.0f, 0.0f);
    boxDesc.entityId = 602;
    boxDesc.material.userMaterialId = 10;
    boxDesc.enableHitEvents = true;
    createBoxBody(world, boxDesc, Vec3(0.5f, 0.5f, 0.5f));

    HitImpulseState hitState;
    ContactListener listener;
    listener.onContactHit = &onImpulseHit;
    listener.context = &hitState;

    foreach (_; 0 .. 120) {
        world.step(dt, 4);
        drainPhysicsEvents(world, listener);
    }

    immutable matsMatch = (hitState.matA == 10 && hitState.matB == 20) ||
                          (hitState.matA == 20 && hitState.matB == 10);
    if (!hitState.gotHit || hitState.maxNormalImpulse <= 0.0f || !matsMatch) {
        writefln("[test-physics-box3d] FAIL: hit impulse=%s normImp=%.3f mats=(%u,%u)",
            hitState.gotHit, hitState.maxNormalImpulse, hitState.matA, hitState.matB);
        return false;
    }
    return true;
}

private struct BrokenJointState {
    int count;
    ulong lastTag;
}

private void onJointBroken(BreakableJointEvent event, void* context) nothrow @nogc @trusted {
    auto s = cast(BrokenJointState*) context;
    if (s is null)
        return;
    s.count += 1;
    s.lastTag = event.userTag;
}

private bool testBreakableJoint() {
    enum float dt = 1.0f / 60.0f;
    auto world = PhysicsWorld(Vec3(0.0f, -9.81f, 0.0f));

    auto pillar = createStaticBox(world, Vec3(0.0f, 3.0f, 0.0f), Vec3(0.3f, 0.3f, 0.3f), 700);
    auto block  = createDynamicBox(world, Vec3(0.8f, 3.0f, 0.0f), Vec3(0.4f, 0.4f, 0.4f), 1.0f, 701);
    auto weld   = createWeldJoint(world, pillar, block, Vec3(0.4f, 3.0f, 0.0f));

    BreakableJointTracker tracker;
    if (!tracker.registerJoint(weld, 50.0f, 50.0f, 777)) {
        writeln("[test-physics-box3d] FAIL: registerJoint failed");
        return false;
    }

    auto projectile = createDynamicSphere(world, Vec3(0.8f, 3.0f, -3.5f), 0.5f, 5.0f, 702);
    setLinearVelocity(projectile, Vec3(0.0f, 0.0f, 35.0f));

    BrokenJointState broken;
    foreach (_; 0 .. 90) {
        world.step(dt, 4);
        tracker.update(world, &onJointBroken, &broken);
    }

    immutable blockPos = getPosition(block);
    if (broken.count != 1 || broken.lastTag != 777 || tracker.count != 0 || isJointValid(weld)) {
        writefln("[test-physics-box3d] FAIL: breakable joint count=%d tag=%u rem=%u valid=%s",
            broken.count, broken.lastTag, tracker.count, isJointValid(weld));
        return false;
    }
    if (blockPos.z < 1.0f && blockPos.y > 2.5f) {
        writefln("[test-physics-box3d] FAIL: detached block stayed put (%.3f, %.3f, %.3f)",
            blockPos.x, blockPos.y, blockPos.z);
        return false;
    }
    return true;
}

private bool testSphericalRagdollAndFilters() {
    enum float dt = 1.0f / 60.0f;
    auto world = PhysicsWorld(Vec3(0.0f, -9.81f, 0.0f));

    createGroundSlab(world, 0.0f, Vec3(20.0f, 0.0f, 20.0f), 0.5f, 800);

    // 3-body spherical ragdoll chain sharing negative groupIndex=-7 (no self-collision).
    BodyDesc limbDesc;
    limbDesc.type = PhysicsBodyType.dynamic;
    limbDesc.filter = CollisionFilter(0x2, 0x1, -7);

    limbDesc.position = Vec3(0.0f, 4.0f, 0.0f);
    limbDesc.entityId = 801;
    auto pelvis = createCapsuleBody(world, limbDesc, 0.6f, 0.2f);

    limbDesc.position = Vec3(0.0f, 4.4f, 0.0f);
    limbDesc.entityId = 802;
    auto torso = createCapsuleBody(world, limbDesc, 0.6f, 0.2f);

    limbDesc.position = Vec3(0.0f, 4.8f, 0.0f);
    limbDesc.entityId = 803;
    auto head = createSphereBody(world, limbDesc, 0.2f);

    SphericalJointConfig jcfg;
    jcfg.enableConeLimit = true;
    jcfg.coneAngle = 0.45f;
    jcfg.enableTwistLimit = true;
    jcfg.lowerTwistAngle = -0.3f;
    jcfg.upperTwistAngle = 0.3f;
    jcfg.enableSpring = true;
    jcfg.hertz = 4.0f;
    jcfg.dampingRatio = 0.7f;
    jcfg.collideConnected = true; // groupIndex=-7 still suppresses self-collision.

    auto j1 = createSphericalJoint(world, pelvis, torso, Vec3(0.0f, 4.2f, 0.0f), Vec3(0.0f, 1.0f, 0.0f), jcfg);
    auto j2 = createSphericalJoint(world, torso, head, Vec3(0.0f, 4.6f, 0.0f), Vec3(0.0f, 1.0f, 0.0f), jcfg);

    // Filter joint disables collision between two overlapping dynamic boxes.
    auto overlapA = createDynamicBox(world, Vec3(5.0f, 3.0f, 0.0f), Vec3(0.4f, 0.4f, 0.4f), 1.0f, 804);
    auto overlapB = createDynamicBox(world, Vec3(5.1f, 3.0f, 0.0f), Vec3(0.4f, 0.4f, 0.4f), 1.0f, 805);
    auto fJoint = createFilterJoint(world, overlapA, overlapB);

    // Kinematic -> Dynamic type transition.
    auto toggleBall = createKinematicSphere(world, Vec3(10.0f, 4.0f, 0.0f), 0.35f, 806);

    foreach (_; 0 .. 30)
        world.step(dt, 4);

    if (fabs(getPosition(toggleBall).y - 4.0f) > 0.01f) {
        writefln("[test-physics-box3d] FAIL: kinematic ball moved y=%.3f", getPosition(toggleBall).y);
        return false;
    }

    setBodyType(toggleBall, PhysicsBodyType.dynamic);
    setBodyDensity(toggleBall, 2.0f);
    setBodyAwake(toggleBall, true);

    foreach (_; 0 .. 90)
        world.step(dt, 4);

    bool pass = true;
    if (!isJointValid(j1) || !isJointValid(j2) || !isJointValid(fJoint)) {
        writeln("[test-physics-box3d] FAIL: spherical/filter joint invalid");
        pass = false;
    }
    immutable headY = getPosition(head).y;
    if (headY < 0.1f || headY > 4.0f) {
        writefln("[test-physics-box3d] FAIL: ragdoll head settled at y=%.3f", headY);
        pass = false;
    }
    immutable sepX = fabs(getPosition(overlapA).x - getPosition(overlapB).x);
    if (sepX > 0.25f) {
        writefln("[test-physics-box3d] FAIL: filter joint boxes pushed apart sepX=%.3f", sepX);
        pass = false;
    }
    if (getBodyType(toggleBall) != PhysicsBodyType.dynamic || getPosition(toggleBall).y > 3.0f) {
        writefln("[test-physics-box3d] FAIL: dynamic toggle ball y=%.3f", getPosition(toggleBall).y);
        pass = false;
    }
    return pass;
}

private bool testSleepingAndWake() {
    enum float dt = 1.0f / 60.0f;
    auto world = PhysicsWorld(Vec3(0.0f, -9.81f, 0.0f));
    createGroundSlab(world, 0.0f, Vec3(20.0f, 0.0f, 20.0f), 0.5f, 900);

    BodyDesc sleepDesc;
    sleepDesc.type = PhysicsBodyType.dynamic;
    sleepDesc.position = Vec3(0.0f, 0.5f, 0.0f);
    sleepDesc.entityId = 901;
    sleepDesc.startAwake = false;
    sleepDesc.enableSleep = true;
    auto sleepBox = createBoxBody(world, sleepDesc, Vec3(0.5f, 0.5f, 0.5f));

    foreach (_; 0 .. 10)
        world.step(dt, 4);

    if (isBodyAwake(sleepBox)) {
        writeln("[test-physics-box3d] FAIL: sleeping box woke up prematurely");
        return false;
    }

    auto wakeBall = createDynamicSphere(world, Vec3(0.0f, 3.0f, 0.0f), 0.4f, 2.0f, 902);
    setLinearVelocity(wakeBall, Vec3(0.0f, -10.0f, 0.0f));

    bool wokeOnImpact = false;
    foreach (_; 0 .. 45) {
        world.step(dt, 4);
        if (isBodyAwake(sleepBox)) {
            wokeOnImpact = true;
            break;
        }
    }
    if (!wokeOnImpact) {
        writeln("[test-physics-box3d] FAIL: sleeping box did not wake on impact");
        return false;
    }

    setBodyAwake(sleepBox, false);
    if (isBodyAwake(sleepBox)) {
        writeln("[test-physics-box3d] FAIL: setBodyAwake(false) failed");
        return false;
    }
    setBodyAwake(sleepBox, true);
    if (!isBodyAwake(sleepBox)) {
        writeln("[test-physics-box3d] FAIL: setBodyAwake(true) failed");
        return false;
    }
    return true;
}

private bool testCcdBullet() {
    enum float dt = 1.0f / 60.0f;
    auto world = PhysicsWorld(Vec3(0.0f, 0.0f, 0.0f));

    createStaticBox(world, Vec3(0.0f, 2.0f, 0.0f), Vec3(0.05f, 2.0f, 4.0f), 1000);

    BodyDesc bulletDesc;
    bulletDesc.type = PhysicsBodyType.dynamic;
    bulletDesc.position = Vec3(-5.0f, 2.0f, 0.0f);
    bulletDesc.entityId = 1001;
    bulletDesc.isBullet = true;
    auto bullet = createBoxBody(world, bulletDesc, Vec3(0.2f, 0.2f, 0.2f));
    setLinearVelocity(bullet, Vec3(120.0f, 0.0f, 0.0f));

    foreach (_; 0 .. 30)
        world.step(dt, 4);

    immutable x = getPosition(bullet).x;
    if (!isBodyBullet(bullet) || x > 0.0f) {
        writefln("[test-physics-box3d] FAIL: CCD bullet tunneled or flag unset bullet=%s x=%.3f",
            isBodyBullet(bullet), x);
        return false;
    }
    return true;
}

int main() {
    enum float dt = 1.0f / 60.0f;
    enum int totalFrames = 240;

    auto world = PhysicsWorld(Vec3(0.0f, -9.81f, 0.0f));

    immutable EntityId groundEntity = 1;
    immutable EntityId sphereEntity = 2;
    immutable EntityId sensorEntity = 3;
    immutable EntityId rollerEntity = 4;

    b3BodyId ground = createGroundSlab(world, 0.0f, Vec3(40.0f, 0.0f, 40.0f), 0.5f, groundEntity);
    b3BodyId sphere = createDynamicSphere(world, Vec3(-4.0f, 8.0f, 0.0f), 0.5f, 1.0f, sphereEntity);
    b3BodyId sensor = createSensorBox(world, Vec3(-10.0f, 1.0f, 0.0f), Vec3(2.0f, 2.0f, 2.0f), sensorEntity);
    b3BodyId roller = createDynamicBox(world, Vec3(-16.0f, 0.5f, 0.0f), Vec3(0.4f, 0.4f, 0.4f), 1.0f, rollerEntity, 0.0f);
    setLinearVelocity(roller, Vec3(12.0f, 0.0f, 0.0f));

    b3BodyId[5] stack;
    foreach (i; 0 .. stack.length) {
        immutable y = 0.5f + cast(float) i * 1.05f;
        stack[i] = createDynamicBox(world, Vec3(0.0f, y, 0.0f), Vec3(0.5f, 0.5f, 0.5f), 1.0f, cast(EntityId)(10 + i));
    }

    EventState events;
    events.sensorEntity = sensorEntity;
    events.rollerEntity = rollerEntity;
    ContactListener listener;
    listener.onSensorEnter = &onSensorEnter;
    listener.onSensorExit = &onSensorExit;
    listener.context = &events;

    bool rayHitGround = false;
    float lastRayFraction = 1.0f;

    writeln("[test-physics-box3d] headless smoke test");

    foreach (frame; 1 .. totalFrames + 1) {
        world.step(dt, 4);
        drainPhysicsEvents(world, listener);

        auto ray = castRayClosest(world, Vec3(0.0f, 20.0f, 0.0f), Vec3(0.0f, -1.0f, 0.0f), 40.0f);
        if (ray.hit) {
            rayHitGround = true;
            lastRayFraction = ray.fraction;
        }

        if (events.sensorEntered && !events.printedEnter) {
            writefln("[test-physics-box3d] frame %3d: SENSOR ENTER", frame);
            events.printedEnter = true;
        }

        if (events.sensorExited && !events.printedExit) {
            writefln("[test-physics-box3d] frame %3d: SENSOR EXIT", frame);
            events.printedExit = true;
        }

        if (frame % 30 == 0) {
            immutable sp = getPosition(sphere);
            immutable rp = getPosition(roller);
            immutable top = getPosition(stack[$ - 1]);
            writefln("frame %3d | sphere.y=%6.3f stackTop.y=%6.3f roller.x=%6.3f ray.frac=%5.3f",
                frame, sp.y, top.y, rp.x, lastRayFraction);
        }
    }

    bool pass = true;

    immutable spherePos = getPosition(sphere);
    if (fabs(spherePos.y - 0.5f) > 0.35f) {
        writefln("[test-physics-box3d] FAIL: sphere rested at y=%.3f", spherePos.y);
        pass = false;
    }

    foreach (i, body; stack) {
        immutable p = getPosition(body);
        if (p.y < 0.35f || p.y > 8.0f || fabs(p.x) > 2.0f || fabs(p.z) > 2.0f) {
            writefln("[test-physics-box3d] FAIL: stack-%u unstable at pos=(%.3f, %.3f, %.3f)",
                i, p.x, p.y, p.z);
            pass = false;
        }
    }

    if (!events.sensorEntered || !events.sensorExited) {
        writefln("[test-physics-box3d] FAIL: sensor events enter=%s exit=%s",
            events.sensorEntered, events.sensorExited);
        pass = false;
    }

    if (!rayHitGround || lastRayFraction >= 1.0f) {
        writefln("[test-physics-box3d] FAIL: raycast hit=%s fraction=%.3f", rayHitGround, lastRayFraction);
        pass = false;
    }

    if (getBodyEntity(sphere) != sphereEntity || getBodyEntity(sensor) != sensorEntity) {
        writeln("[test-physics-box3d] FAIL: body userData entity mapping mismatch");
        pass = false;
    }

    cast(void) ground;

    if (!testShapesJointsCharacter())
        pass = false;

    if (!testHullAndMesh())
        pass = false;

    if (!testHeightFieldAndMaterials())
        pass = false;

    if (!testHitEventImpulseAndMaterials())
        pass = false;

    if (!testBreakableJoint())
        pass = false;

    if (!testSphericalRagdollAndFilters())
        pass = false;

    if (!testSleepingAndWake())
        pass = false;

    if (!testCcdBullet())
        pass = false;

    if (pass) {
        writeln("[test-physics-box3d] PASS");
        return 0;
    }

    writeln("[test-physics-box3d] FAIL");
    return 1;
}
