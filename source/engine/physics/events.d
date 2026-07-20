module engine.physics.events;

import bindings.box3d;
import engine.ecs.store : EntityId;
import engine.math.vec : Vec3;
import engine.physics.body : getBodyEntity, getShapeEntity, noPhysicsEntity;
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
    Vec3 point;
    Vec3 normal;
    float approachSpeed = 0.0f;
}

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
        listener.onContactAdded(makeContactEvent(event.shapeIdA, event.shapeIdB), listener.context);
    }

    foreach (i; 0 .. contacts.endCount) {
        if (listener.onContactRemoved is null)
            break;
        const event = contacts.endEvents[i];
        listener.onContactRemoved(makeContactEvent(event.shapeIdA, event.shapeIdB), listener.context);
    }

    if (listener.onContactHit !is null) {
        foreach (i; 0 .. contacts.hitCount) {
            const event = contacts.hitEvents[i];
            listener.onContactHit(makeHitEvent(event), listener.context);
        }
    }

    b3SensorEvents sensors = b3World_GetSensorEventsD(world.handle);
    foreach (i; 0 .. sensors.beginCount) {
        if (listener.onSensorEnter is null)
            break;
        const event = sensors.beginEvents[i];
        listener.onSensorEnter(makeSensorEvent(event.sensorShapeId, event.visitorShapeId), listener.context);
    }

    foreach (i; 0 .. sensors.endCount) {
        if (listener.onSensorExit is null)
            break;
        const event = sensors.endEvents[i];
        listener.onSensorExit(makeSensorEvent(event.sensorShapeId, event.visitorShapeId), listener.context);
    }
}

private PhysicsContactEvent makeContactEvent(const b3ShapeId shapeA, const b3ShapeId shapeB) nothrow @nogc @trusted {
    PhysicsContactEvent event;
    event.shapeA = shapeA;
    event.shapeB = shapeB;

    if (b3Shape_IsValidD(shapeA)) {
        event.bodyA = b3Shape_GetBodyD(shapeA);
        event.entityA = getBodyEntity(event.bodyA);
    }

    if (b3Shape_IsValidD(shapeB)) {
        event.bodyB = b3Shape_GetBodyD(shapeB);
        event.entityB = getBodyEntity(event.bodyB);
    }

    return event;
}

private PhysicsSensorEvent makeSensorEvent(const b3ShapeId sensorShape, const b3ShapeId visitorShape) nothrow @nogc @trusted {
    PhysicsSensorEvent event;
    event.sensorShape = sensorShape;
    event.visitorShape = visitorShape;

    if (b3Shape_IsValidD(sensorShape)) {
        event.sensorBody = b3Shape_GetBodyD(sensorShape);
        event.sensorEntity = getShapeEntity(sensorShape);
    }

    if (b3Shape_IsValidD(visitorShape)) {
        event.visitorBody = b3Shape_GetBodyD(visitorShape);
        event.visitorEntity = getShapeEntity(visitorShape);
    }

    return event;
}

private PhysicsHitEvent makeHitEvent(const b3ContactHitEvent raw) nothrow @nogc @trusted {
    PhysicsHitEvent event;
    event.shapeA = raw.shapeIdA;
    event.shapeB = raw.shapeIdB;
    event.point = Vec3(cast(float) raw.point.x, cast(float) raw.point.y, cast(float) raw.point.z);
    event.normal = Vec3(raw.normal.x, raw.normal.y, raw.normal.z);
    event.approachSpeed = raw.approachSpeed;

    if (b3Shape_IsValidD(raw.shapeIdA)) {
        event.bodyA = b3Shape_GetBodyD(raw.shapeIdA);
        event.entityA = getBodyEntity(event.bodyA);
    }

    if (b3Shape_IsValidD(raw.shapeIdB)) {
        event.bodyB = b3Shape_GetBodyD(raw.shapeIdB);
        event.entityB = getBodyEntity(event.bodyB);
    }

    return event;
}
