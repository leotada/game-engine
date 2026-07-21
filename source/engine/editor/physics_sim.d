/// ED-5a: Simulate / Esc restore. Transform owns outside of simulation;
/// Box3D dynamics drive transforms while simulating.
module engine.editor.physics_sim;

import bindings.box3d : b3BodyId;

import engine.core.log : warn;
import engine.core.strings : StringId;
import engine.editor.components :
    PhysicsBody, PhysicsMotion, PhysicsShapeKind, PhysicsValidation,
    Visual, VisualKind, isMeshDynamicForbidden, refuseMeshDynamic,
    validatePhysicsBody;
import engine.ecs.store : EntityId;
import engine.math.quat : Quat;
import engine.math.vec : Vec3;
import engine.physics.body :
    createDynamicBox, createDynamicHull, createDynamicSphere,
    createKinematicBox, createKinematicHull, createKinematicSphere,
    createStaticBox, createStaticHull, createStaticMesh, createStaticSphere,
    destroyBody, isBodyValid, setAngularDamping, setLinearDamping;
import engine.physics.convert : readBodyTransform, writeBodyTransform;
import engine.physics.world : PhysicsWorld;
import engine.scene.graph : Transform;

@safe:

/// Snapshot of an entity transform for Esc restore.
struct TransformSnapshot {
    EntityId entity = EntityId.max;
    Transform transform = Transform.init;
}

/// Optional CPU geometry resolved from a `*.asset.json` (hull / mesh).
struct PhysicsAssetGeometry {
    Vec3[] hullPoints;   /// Object-space hull bake (may be empty)
    Vec3[] meshVertices; /// Triangle mesh vertices (may be empty)
    int[] meshIndices;   /// Triangle indices (length % 3 == 0)
    uint maxHullVertices = 64;
}

/// Lookup geometry for an interned asset path. Return false if missing.
alias PhysicsAssetResolver = bool delegate(StringId assetPath, ref PhysicsAssetGeometry outGeo);

/// Active play-mode physics session for the level editor.
struct PhysicsSimSession {
    bool simulating = false;
    TransformSnapshot[] snapshots; /// GC ok — editor tooling
    EntityId[] bodyEntities;
    b3BodyId[] bodies;

    bool active() const pure nothrow @nogc { return simulating; }

    /// Snapshot transforms, spawn Box3D bodies for enabled `PhysicsBody` entities.
    /// Returns false if already simulating.
    bool beginSimulate(W)(
        ref W world,
        ref PhysicsWorld physics,
        PhysicsAssetResolver resolveAsset = null
    ) {
        if (simulating)
            return false;

        snapshots.length = 0;
        bodyEntities.length = 0;
        bodies.length = 0;

        foreach (id; world.query!(Transform, PhysicsBody)()) {
            if (!world.alive(id))
                continue;
            auto pb = world.get!PhysicsBody(id);
            if (pb.enabled == 0)
                continue;

            TransformSnapshot snap;
            snap.entity = id;
            snap.transform = world.get!Transform(id);
            snapshots ~= snap;

            Visual vis = Visual.init;
            if (world.has!Visual(id))
                vis = world.get!Visual(id);

            PhysicsAssetGeometry geo;
            if (!pb.assetPath.isNull && resolveAsset !is null) {
                if (!resolveAsset(pb.assetPath, geo))
                    warn("PhysicsSim: asset geometry missing for entity");
            }

            immutable bodyId = createBodyFromEditor(
                physics, id, snap.transform, pb, vis, geo);
            if (isBodyValid(bodyId)) {
                bodyEntities ~= id;
                bodies ~= bodyId;
            }
        }

        simulating = true;
        return true;
    }

    /// Destroy bodies and restore snapshotted transforms. No-op if idle.
    void stopSimulate(W)(ref W world) {
        if (!simulating)
            return;

        foreach (b; bodies) {
            if (isBodyValid(b))
                destroyBody(b);
        }
        bodies.length = 0;
        bodyEntities.length = 0;

        foreach (ref snap; snapshots) {
            if (world.alive(snap.entity)) {
                Transform t = snap.transform;
                world.set(snap.entity, t);
            }
        }
        snapshots.length = 0;
        simulating = false;
    }

    /// Esc → restore. Returns true if simulation was stopped.
    bool handleEscape(W)(ref W world, bool escapePressed) {
        if (!simulating || !escapePressed)
            return false;
        stopSimulate(world);
        return true;
    }

    /// Step physics and copy body transforms into ECS (only while simulating).
    void tick(W)(ref W world, ref PhysicsWorld physics, float dt, int subSteps = 4) {
        if (!simulating)
            return;

        physics.step(dt, subSteps);

        immutable n = bodies.length < bodyEntities.length ? bodies.length : bodyEntities.length;
        foreach (i; 0 .. n) {
            immutable id = bodyEntities[i];
            immutable bodyId = bodies[i];
            if (!world.alive(id) || !isBodyValid(bodyId))
                continue;
            if (!world.has!Transform(id))
                continue;

            immutable pt = readBodyTransform(bodyId);
            auto t = world.get!Transform(id);
            t.position = pt.position;
            t.rotation = pt.rotation;
            // Scale stays under Transform ownership (not driven by physics).
            world.set(id, t);
        }
    }
}

/// Create a Box3D body from editor components. Returns null body on policy failure
/// (mesh+dynamic) or missing geometry.
b3BodyId createBodyFromEditor(
    ref PhysicsWorld physics,
    EntityId entityId,
    Transform transform,
    PhysicsBody body,
    Visual visual,
    ref const PhysicsAssetGeometry geo
) nothrow {
    PhysicsBody pb = body;
    refuseMeshDynamic(pb);
    if (validatePhysicsBody(pb) != PhysicsValidation.ok)
        return b3BodyId.init;

    immutable pos = transform.position;
    immutable rot = transform.rotation;
    immutable dens = pb.mass > 0 ? pb.mass : 1.0f;
    immutable fr = pb.friction;
    immutable rest = pb.restitution;

    Vec3 half = pb.halfExtents;
    if (half.x <= 0 && half.y <= 0 && half.z <= 0)
        half = visual.localHalfExtents;

    b3BodyId id = b3BodyId.init;

    final switch (cast(PhysicsShapeKind) pb.shape) {
        case PhysicsShapeKind.primitive:
            id = createPrimitiveBody(physics, cast(PhysicsMotion) pb.motion, visual.kind,
                pos, rot, half, dens, entityId, fr, rest);
            break;
        case PhysicsShapeKind.convexHull:
            if (geo.hullPoints.length < 3)
                return b3BodyId.init;
            immutable maxV = pb.maxHullVertices > 0 ? pb.maxHullVertices : geo.maxHullVertices;
            id = createHullBodyMotion(physics, cast(PhysicsMotion) pb.motion, pos, rot,
                geo.hullPoints, maxV, dens, entityId, fr, rest);
            break;
        case PhysicsShapeKind.triangleMesh:
            // Static only — dynamic already refused above.
            if (geo.meshVertices.length < 3 || geo.meshIndices.length < 3)
                return b3BodyId.init;
            id = createStaticMesh(physics, pos, geo.meshVertices, geo.meshIndices,
                entityId, fr, rest);
            if (isBodyValid(id))
                writeBodyTransform(id, pos, rot);
            break;
    }

    if (isBodyValid(id)) {
        setLinearDamping(id, pb.linearDamping);
        setAngularDamping(id, pb.angularDamping);
    }
    return id;
}

/// Public policy gate used by UI + spawn paths.
bool trySetPhysicsShapeMotion(ref PhysicsBody body, uint shape, uint motion) pure nothrow @nogc {
    if (isMeshDynamicForbidden(shape, motion))
        return false;
    body.shape = shape;
    body.motion = motion;
    return true;
}

private b3BodyId createPrimitiveBody(
    ref PhysicsWorld physics,
    PhysicsMotion motion,
    VisualKind kind,
    Vec3 pos,
    Quat rot,
    Vec3 half,
    float density,
    EntityId entityId,
    float friction,
    float restitution
) nothrow {
    immutable useSphere = kind == VisualKind.sphere;
    immutable radius = half.x > half.y
        ? (half.x > half.z ? half.x : half.z)
        : (half.y > half.z ? half.y : half.z);

    final switch (motion) {
        case PhysicsMotion.static_:
            if (useSphere)
                return createStaticSphere(physics, pos, radius, entityId, friction, restitution);
            {
                auto id = createStaticBox(physics, pos, half, rot, entityId, friction, restitution);
                return id;
            }
        case PhysicsMotion.dynamic_:
            if (useSphere)
                return createDynamicSphere(physics, pos, radius, density, entityId, friction, restitution);
            {
                auto id = createDynamicBox(physics, pos, half, rot, density, entityId, friction, restitution);
                return id;
            }
        case PhysicsMotion.kinematic:
            if (useSphere)
                return createKinematicSphere(physics, pos, radius, entityId, friction, restitution);
            {
                auto id = createKinematicBox(physics, pos, half, rot, entityId, friction, restitution);
                return id;
            }
    }
}

private b3BodyId createHullBodyMotion(
    ref PhysicsWorld physics,
    PhysicsMotion motion,
    Vec3 pos,
    Quat rot,
    scope const(Vec3)[] points,
    uint maxVerts,
    float density,
    EntityId entityId,
    float friction,
    float restitution
) nothrow {
    immutable mv = cast(int)(maxVerts > 0 ? maxVerts : 64);
    b3BodyId id = b3BodyId.init;
    final switch (motion) {
        case PhysicsMotion.static_:
            id = createStaticHull(physics, pos, points, mv, entityId, friction, restitution);
            break;
        case PhysicsMotion.dynamic_:
            id = createDynamicHull(physics, pos, points, mv, density, entityId, friction, restitution);
            break;
        case PhysicsMotion.kinematic:
            id = createKinematicHull(physics, pos, points, mv, entityId, friction, restitution);
            break;
    }
    if (isBodyValid(id))
        writeBodyTransform(id, pos, rot);
    return id;
}

@safe unittest {
    PhysicsBody pb;
    pb.shape = PhysicsShapeKind.triangleMesh;
    pb.motion = PhysicsMotion.dynamic_;
    assert(validatePhysicsBody(pb) == PhysicsValidation.meshDynamicForbidden);
    assert(!trySetPhysicsShapeMotion(pb, PhysicsShapeKind.triangleMesh, PhysicsMotion.dynamic_));
    refuseMeshDynamic(pb);
    assert(pb.motion == PhysicsMotion.static_);
    assert(validatePhysicsBody(pb) == PhysicsValidation.ok);
}

@safe unittest {
    // Esc restore path: snapshot round-trip without Box3D step.
    import engine.editor.components : EditorWorld;

    EditorWorld world;
    PhysicsSimSession sim;
    auto id = world.spawn();
    Transform t;
    t.position = Vec3(0, 5, 0);
    world.set(id, t);
    PhysicsBody pb;
    pb.enabled = 1;
    pb.motion = PhysicsMotion.dynamic_;
    pb.shape = PhysicsShapeKind.primitive;
    world.set(id, pb);

    // Manually mimic snapshot/restore without creating bodies.
    TransformSnapshot snap;
    snap.entity = id;
    snap.transform = world.get!Transform(id);
    sim.snapshots ~= snap;
    sim.simulating = true;

    auto moved = world.get!Transform(id);
    moved.position = Vec3(1, 0, 1);
    world.set(id, moved);

    assert(sim.handleEscape(world, true));
    assert(!sim.simulating);
    assert(world.get!Transform(id).position.y == 5);
}
