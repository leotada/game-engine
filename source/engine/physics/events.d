module engine.physics.events;

import bindings.box3d;
import core.stdc.math : sqrtf;
import engine.core.pod : isPod;
import engine.ecs.store : EntityId;
import engine.math.vec : Vec3;
import engine.physics.body : getBodyEntity, getMass, getShapeEntity, noPhysicsEntity;
import engine.physics.world : PhysicsWorld;

@safe:

struct PhysicsContactEvent {
    b3ShapeId shapeA;
    b3ShapeId shapeB;
    b3BodyId bodyA;
    b3BodyId bodyB;
    EntityId entityA = noPhysicsEntity;
    EntityId entityB = noPhysicsEntity;
}

struct PhysicsSensorEvent {
    b3ShapeId sensorShape;
    b3ShapeId visitorShape;
    b3BodyId sensorBody;
    b3BodyId visitorBody;
    EntityId sensorEntity = noPhysicsEntity;
    EntityId visitorEntity = noPhysicsEntity;
}

struct PhysicsHitEvent {
    b3ShapeId shapeA;
    b3ShapeId shapeB;
    b3BodyId bodyA;
    b3BodyId bodyB;
    EntityId entityA = noPhysicsEntity;
    EntityId entityB = noPhysicsEntity;
    ulong materialIdA = 0;
    ulong materialIdB = 0;
    Vec3 point;
    Vec3 normal;
    float approachSpeed = 0.0f;
    /// Sum of Box3D's `totalNormalImpulse` over the contact manifold points. Box3D accumulates it
    /// across solver sub-steps and includes speculative points, so it overestimates the real
    /// impact impulse and depends on the sub-step count. Use `approachImpulse` for damage.
    float normalImpulse = 0.0f;
    float frictionImpulse = 0.0f;
    /// Momentum change of a fully inelastic impact along the normal, in kg*m/s:
    /// `approachSpeed * reducedMass`, where the reduced mass is `mA*mB/(mA+mB)` and a static or
    /// kinematic body (zero mass) counts as infinite. Independent of sub-stepping; 0 when both
    /// bodies are massless.
    float approachImpulse = 0.0f;
}

/// Reduced mass of two bodies for a normal impact. A non-positive mass is treated as infinite
/// (static / kinematic), so the result is the other body's mass; 0 when both are non-positive.
float reducedMass(float massA, float massB) nothrow @nogc pure {
    immutable bool aFinite = massA > 0.0f;
    immutable bool bFinite = massB > 0.0f;
    if (aFinite && bFinite) return massA * massB / (massA + massB);
    if (aFinite) return massA;
    if (bFinite) return massB;
    return 0.0f;
}

static assert(isPod!PhysicsContactEvent);
static assert(isPod!PhysicsSensorEvent);
static assert(isPod!PhysicsHitEvent);

alias ContactEventCallback = void function(PhysicsContactEvent event, void* context) nothrow @nogc @safe;
alias SensorEventCallback = void function(PhysicsSensorEvent event, void* context) nothrow @nogc @safe;
alias HitEventCallback = void function(PhysicsHitEvent event, void* context) nothrow @nogc @safe;

struct ContactListener {
    ContactEventCallback onContactAdded;
    ContactEventCallback onContactRemoved;
    SensorEventCallback onSensorEnter;
    SensorEventCallback onSensorExit;
    HitEventCallback onContactHit;
    void* context;
}

void drainPhysicsEvents(ref PhysicsWorld world, scope ref ContactListener listener) nothrow @nogc @trusted {
    b3ContactEvents contacts = b3World_GetContactEventsD(world.handle);
    foreach (i; 0 .. contacts.beginCount) {
        if (listener.onContactAdded is null)
            break;
        const event = contacts.beginEvents[i];
        listener.onContactAdded(makeContactEvent(world, event.shapeIdA, event.shapeIdB), listener.context);
    }

    foreach (i; 0 .. contacts.endCount) {
        if (listener.onContactRemoved is null)
            break;
        const event = contacts.endEvents[i];
        listener.onContactRemoved(makeContactEvent(world, event.shapeIdA, event.shapeIdB), listener.context);
    }

    if (listener.onContactHit !is null) {
        foreach (i; 0 .. contacts.hitCount) {
            const event = contacts.hitEvents[i];
            listener.onContactHit(makeHitEvent(world, event), listener.context);
        }
    }

    b3SensorEvents sensors = b3World_GetSensorEventsD(world.handle);
    foreach (i; 0 .. sensors.beginCount) {
        if (listener.onSensorEnter is null)
            break;
        const event = sensors.beginEvents[i];
        listener.onSensorEnter(makeSensorEvent(world, event.sensorShapeId, event.visitorShapeId), listener.context);
    }

    foreach (i; 0 .. sensors.endCount) {
        if (listener.onSensorExit is null)
            break;
        const event = sensors.endEvents[i];
        listener.onSensorExit(makeSensorEvent(world, event.sensorShapeId, event.visitorShapeId), listener.context);
    }
}

private PhysicsContactEvent makeContactEvent(ref const PhysicsWorld world, const b3ShapeId shapeA, const b3ShapeId shapeB) nothrow @nogc @trusted {
    PhysicsContactEvent event;
    event.shapeA = shapeA;
    event.shapeB = shapeB;

    if (b3Shape_IsValidD(shapeA)) {
        event.bodyA = b3Shape_GetBodyD(shapeA);
        event.entityA = getBodyEntity(event.bodyA);
    } else {
        event.entityA = world.shapeOwner(shapeA);
    }

    if (b3Shape_IsValidD(shapeB)) {
        event.bodyB = b3Shape_GetBodyD(shapeB);
        event.entityB = getBodyEntity(event.bodyB);
    } else {
        event.entityB = world.shapeOwner(shapeB);
    }

    return event;
}

private PhysicsSensorEvent makeSensorEvent(ref const PhysicsWorld world, const b3ShapeId sensorShape, const b3ShapeId visitorShape) nothrow @nogc @trusted {
    PhysicsSensorEvent event;
    event.sensorShape = sensorShape;
    event.visitorShape = visitorShape;

    if (b3Shape_IsValidD(sensorShape)) {
        event.sensorBody = b3Shape_GetBodyD(sensorShape);
        event.sensorEntity = getShapeEntity(sensorShape);
    } else {
        event.sensorEntity = world.shapeOwner(sensorShape);
    }

    if (b3Shape_IsValidD(visitorShape)) {
        event.visitorBody = b3Shape_GetBodyD(visitorShape);
        event.visitorEntity = getShapeEntity(visitorShape);
    } else {
        event.visitorEntity = world.shapeOwner(visitorShape);
    }

    return event;
}

private PhysicsHitEvent makeHitEvent(ref const PhysicsWorld world, const b3ContactHitEvent raw) nothrow @nogc @trusted {
    PhysicsHitEvent event;
    event.shapeA = raw.shapeIdA;
    event.shapeB = raw.shapeIdB;
    event.materialIdA = raw.userMaterialIdA;
    event.materialIdB = raw.userMaterialIdB;
    event.point = Vec3(cast(float) raw.point.x, cast(float) raw.point.y, cast(float) raw.point.z);
    event.normal = Vec3(raw.normal.x, raw.normal.y, raw.normal.z);
    event.approachSpeed = raw.approachSpeed;

    if (b3Shape_IsValidD(raw.shapeIdA)) {
        event.bodyA = b3Shape_GetBodyD(raw.shapeIdA);
        event.entityA = getBodyEntity(event.bodyA);
    } else {
        event.entityA = world.shapeOwner(raw.shapeIdA);
    }

    if (b3Shape_IsValidD(raw.shapeIdB)) {
        event.bodyB = b3Shape_GetBodyD(raw.shapeIdB);
        event.entityB = getBodyEntity(event.bodyB);
    } else {
        event.entityB = world.shapeOwner(raw.shapeIdB);
    }

    event.approachImpulse = raw.approachSpeed * reducedMass(getMass(event.bodyA), getMass(event.bodyB));

    if (b3Contact_IsValidD(raw.contactId)) {
        b3ContactData data = b3Contact_GetDataD(raw.contactId);
        foreach (mi; 0 .. data.manifoldCount) {
            const m = data.manifolds[mi];
            foreach (pi; 0 .. m.pointCount)
                event.normalImpulse += m.points[pi].totalNormalImpulse;
            immutable fx = m.frictionImpulse.x;
            immutable fy = m.frictionImpulse.y;
            immutable fz = m.frictionImpulse.z;
            event.frictionImpulse += sqrtf(fx * fx + fy * fy + fz * fz);
        }
    }

    return event;
}

@safe nothrow @nogc unittest {
    static assert(isPod!PhysicsContactEvent);
    static assert(isPod!PhysicsSensorEvent);
    static assert(isPod!PhysicsHitEvent);
}

@safe nothrow @nogc unittest {
    import std.math : fabs;
    assert(fabs(reducedMass(1000.0f, 1000.0f) - 500.0f) < 1e-3f);
    assert(reducedMass(0.0f, 800.0f) == 800.0f);   // static wall: the dynamic body's mass
    assert(reducedMass(800.0f, 0.0f) == 800.0f);
    assert(reducedMass(0.0f, 0.0f) == 0.0f);
    assert(fabs(reducedMass(1.0f, 1.0e6f) - 1.0f) < 1e-3f);
}

@("physics events: end events of a destroyed body keep its entity id")
@safe unittest {
    import engine.physics.body : createDynamicBox, createStaticBox, destroyBody;
    static struct Seen { uint begins, ends; EntityId a, b; }
    static void onBegin(PhysicsContactEvent e, void* ctx) nothrow @nogc @trusted { (cast(Seen*) ctx).begins++; }
    static void onEnd(PhysicsContactEvent e, void* ctx) nothrow @nogc @trusted {
        auto s = cast(Seen*) ctx;
        s.ends++;
        s.a = e.entityA;
        s.b = e.entityB;
    }
    auto world = PhysicsWorld.createDefault();
    createStaticBox(world, Vec3(0, -0.5f, 0), Vec3(5, 0.5f, 5), 11u);
    auto crate = createDynamicBox(world, Vec3(0, 0.5f, 0), Vec3(0.5f, 0.5f, 0.5f), 1.0f, 22u);
    Seen seen;
    ContactListener l;
    l.onContactAdded = &onBegin;
    l.onContactRemoved = &onEnd;
    () @trusted { l.context = &seen; }();
    foreach (_; 0 .. 10) {
        world.step(1.0f / 60.0f);
        drainPhysicsEvents(world, l);
    }
    assert(seen.begins == 1);
    destroyBody(crate);
    world.step(1.0f / 60.0f);
    drainPhysicsEvents(world, l);
    if (seen.ends) // Box3D may report the end on this step
        assert((seen.a == 11 && seen.b == 22) || (seen.a == 22 && seen.b == 11));
    assert(seen.ends == 1);
}
