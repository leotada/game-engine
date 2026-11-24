/// ED-5a: Simulate / Esc restore. Transform owns outside of simulation;
/// Box3D dynamics drive transforms while simulating.
module engine.editor.physics_sim;

import bindings.box3d : b3BodyId;

import std.algorithm.comparison : max;
import std.algorithm.mutation : swap;

import engine.core.log : warn;
import engine.core.strings : StringId;
import engine.editor.components :
    Parent, PhysicsBody, PhysicsMotion, PhysicsShapeKind, PhysicsValidation,
    Visual, VisualKind, isMeshDynamicForbidden, noParent, refuseMeshDynamic,
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
    uint generation = 0; /// 0 = unknown: matches any live entity with that id
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
    uint[] bodyGenerations; /// Entity generation per body: ids are recycled

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
        bodyGenerations.length = 0;
        uint[] depths; // parent chain length per body

        foreach (id; world.query!(Transform, PhysicsBody)()) {
            if (!world.alive(id))
                continue;
            auto pb = world.get!PhysicsBody(id);
            if (pb.enabled == 0)
                continue;

            TransformSnapshot snap;
            snap.entity = id;
            snap.generation = world.generation(id);
            snap.transform = world.get!Transform(id);
            snapshots ~= snap;
            uint depth;
            immutable pose = worldPose(world, id, depth);

            Visual vis = Visual.init;
            if (world.has!Visual(id))
                vis = world.get!Visual(id);

            PhysicsAssetGeometry geo;
            if (!pb.assetPath.isNull && resolveAsset !is null) {
                if (!resolveAsset(pb.assetPath, geo))
                    warn("PhysicsSim: asset geometry missing for entity");
            }

            immutable bodyId = createBodyFromEditor(
                physics, id, pose, pb, vis, geo);
            if (isBodyValid(bodyId)) {
                bodyEntities ~= id;
                bodies ~= bodyId;
                bodyGenerations ~= snap.generation;
                depths ~= depth;
            }
        }

        // Parents before children: `tick` turns world poses into poses relative to the already updated parent.
        foreach (i; 1 .. depths.length) {
            for (size_t j = i; j > 0 && depths[j - 1] > depths[j]; j--) {
                swap(depths[j - 1], depths[j]);
                swap(bodyEntities[j - 1], bodyEntities[j]);
                swap(bodies[j - 1], bodies[j]);
                swap(bodyGenerations[j - 1], bodyGenerations[j]);
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
        bodyGenerations.length = 0;

        foreach (ref snap; snapshots) {
            if (world.alive(snap.entity) && (snap.generation == 0 || world.alive(snap.entity, snap.generation))) {
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
            if (!isBodyValid(bodyId))
                continue;
            if (!world.alive(id, bodyGenerations[i])) {
                // The entity is gone (its id may belong to another one by now): so is its collider.
                destroyBody(bodyId);
                bodies[i] = b3BodyId.init;
                continue;
            }
            if (!world.has!Transform(id))
                continue;

            immutable pt = readBodyTransform(bodyId);
            auto t = world.get!Transform(id);
            immutable parent = parentOf(world, id);
            if (parent == noParent) {
                t.position = pt.position;
                t.rotation = pt.rotation;
            } else {
                uint depth;
                immutable pp = worldPose(world, parent, depth);
                immutable inv = pp.rotation.conjugate();
                immutable local = inv.rotate(pt.position - pp.position);
                t.position = Vec3(
                    unscale(local.x, pp.scale.x), unscale(local.y, pp.scale.y), unscale(local.z, pp.scale.z));
                t.rotation = inv * pt.rotation;
            }
            // Scale stays under Transform ownership (not driven by physics).
            world.set(id, t);
        }
    }
}

/// Parent entity, or `noParent` for a root (also when the link is dead).
private EntityId parentOf(W)(ref W world, EntityId id) {
    if (!world.has!Parent(id))
        return noParent;
    immutable p = world.get!Parent(id).entity;
    return p != id && world.alive(p) ? p : noParent;
}

/// World position, rotation and scale along the `Parent` chain (shear from a rotated child of a non-uniformly scaled
/// parent is ignored: a rigid collider cannot represent it). `depth` is the number of ancestors.
private Transform worldPose(W)(ref W world, EntityId id, out uint depth) {
    Transform t = world.has!Transform(id) ? world.get!Transform(id) : Transform.init;
    EntityId p = parentOf(world, id);
    while (p != noParent && depth < 1024) {
        if (world.has!Transform(p)) {
            immutable pt = world.get!Transform(p);
            t.position = pt.position + pt.rotation.rotate(
                Vec3(t.position.x * pt.scale.x, t.position.y * pt.scale.y, t.position.z * pt.scale.z));
            t.rotation = pt.rotation * t.rotation;
            t.scale = Vec3(t.scale.x * pt.scale.x, t.scale.y * pt.scale.y, t.scale.z * pt.scale.z);
        }
        depth++;
        p = parentOf(world, p);
    }
    return t;
}

private float unscale(float v, float s) pure nothrow @nogc {
    return s != 0 ? v / s : v;
}

/// Create a Box3D body from editor components. `transform` is the world pose; its scale applies to the collider.
/// Returns null body on policy failure
/// (mesh+dynamic) or missing geometry.
b3BodyId createBodyFromEditor(
    ref PhysicsWorld physics,
    EntityId entityId,
    Transform transform,
    PhysicsBody body,
    Visual visual,
    ref const PhysicsAssetGeometry geo
) nothrow {
    import std.math : abs;
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
    immutable scale = transform.scale;
    immutable unitScale = scale.x == 1 && scale.y == 1 && scale.z == 1;
    enum minHalf = 0.005f; // a zero scale must not make a degenerate box
    half = Vec3(
        max(half.x * abs(scale.x), minHalf), max(half.y * abs(scale.y), minHalf), max(half.z * abs(scale.z), minHalf));

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
            const(Vec3)[] points = geo.hullPoints;
            if (!unitScale) {
                auto scaled = new Vec3[points.length];
                foreach (i, p; points)
                    scaled[i] = Vec3(p.x * scale.x, p.y * scale.y, p.z * scale.z);
                points = scaled;
            }
            id = createHullBodyMotion(physics, cast(PhysicsMotion) pb.motion, pos, rot,
                points, maxV, dens, entityId, fr, rest);
            break;
        case PhysicsShapeKind.triangleMesh:
            // Static only — dynamic already refused above.
            if (geo.meshVertices.length < 3 || geo.meshIndices.length < 3)
                return b3BodyId.init;
            id = createStaticMesh(physics, pos, geo.meshVertices, geo.meshIndices,
                entityId, fr, rest, false, scale);
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

@("physics sim: colliders follow scale and parents; bodies of destroyed entities go away")
@safe unittest {
    import std.math : abs;
    import engine.editor.components : EditorWorld;
    import engine.physics.queries : castRayClosest;

    EditorWorld world;
    auto physics = PhysicsWorld.createDefault();
    PhysicsSimSession sim;

    static PhysicsBody box(uint motion) {
        PhysicsBody pb;
        pb.enabled = 1;
        pb.motion = motion;
        pb.halfExtents = Vec3(0.5f, 0.5f, 0.5f);
        return pb;
    }
    auto floor = world.spawn();
    Transform ft;
    ft.scale = Vec3(40, 2, 40); // top at y = 1
    world.set(floor, ft);
    world.set(floor, box(PhysicsMotion.static_));

    auto group = world.spawn();
    Transform gt;
    gt.position = Vec3(10, 0, 0);
    gt.rotation = Quat.fromAxisAngle(Vec3(0, 1, 0), 1.5707964f);
    gt.scale = Vec3(2, 2, 2);
    world.set(group, gt);
    auto crate = world.spawn();
    Transform ct;
    ct.position = Vec3(0, 2, 1); // world (12, 4, 0), world half extent 1
    world.set(crate, ct);
    world.set(crate, Parent(group));
    world.set(crate, box(PhysicsMotion.dynamic_));

    sim.beginSimulate(world, physics);
    foreach (_; 0 .. 240) sim.tick(world, physics, 1.0f / 60.0f);
    auto hit = castRayClosest(physics, Vec3(15, 10, 0), Vec3(0, -1, 0), 20);
    assert(hit.hit && abs(hit.point.y - 1.0f) < 0.02f);
    immutable local = world.get!Transform(crate);
    assert(abs(local.position.x) < 0.02f && abs(local.position.z - 1) < 0.02f);
    assert(abs(local.position.y - 1.0f) < 0.03f); // resting at world y = 2
    assert(local.scale == Vec3(1, 1, 1));

    // A recycled id must not inherit the old body, nor be restored on stop.
    world.destroy(crate);
    auto other = world.spawn();
    assert(other == crate);
    Transform ot;
    ot.position = Vec3(-3, 7, 0);
    world.set(other, ot);
    sim.tick(world, physics, 1.0f / 60.0f);
    assert(world.get!Transform(other).position == Vec3(-3, 7, 0));
    assert(abs(castRayClosest(physics, Vec3(12, 10, 0), Vec3(0, -1, 0), 20).point.y - 1.0f) < 0.02f);
    sim.stopSimulate(world);
    assert(world.get!Transform(other).position == Vec3(-3, 7, 0));
}
