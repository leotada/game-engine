module engine.physics.events;

import bindings.box3d;
import engine.ecs.store : EntityId;
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

alias ContactEventCallback = void function(PhysicsContactEvent event, void* context) nothrow @nogc @safe;
alias SensorEventCallback = void function(PhysicsSensorEvent event, void* context) nothrow @nogc @safe;

struct ContactListener {
    ContactEventCallback onContactAdded;
    ContactEventCallback onContactRemoved;
    SensorEventCallback onSensorEnter;
    SensorEventCallback onSensorExit;
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
