module engine.physics.body;

import bindings.box3d;
import engine.ecs.store : EntityId;
import engine.math.quat : Quat;
import engine.math.vec : Vec3;
import engine.physics.convert : readBodyTransform, toB3Pos, toB3Quat, toB3Vec3, toEngineVec3;
import engine.physics.world : PhysicsWorld;

@safe:

enum EntityId noPhysicsEntity = EntityId.max;

void* encodeEntityUserData(const EntityId entityId) nothrow @nogc @trusted {
    if (entityId == noPhysicsEntity)
        return null;
    return cast(void*) cast(size_t)(cast(ulong) entityId + 1UL);
}

EntityId decodeEntityUserData(const void* userData) pure nothrow @nogc @trusted {
    immutable raw = cast(size_t) userData;
    if (raw == 0)
        return noPhysicsEntity;
    return cast(EntityId)(raw - 1);
}

EntityId getBodyEntity(const b3BodyId bodyId) nothrow @nogc @trusted {
    if (!b3Body_IsValidD(bodyId))
        return noPhysicsEntity;
    return decodeEntityUserData(b3Body_GetUserDataD(bodyId));
}

EntityId getShapeEntity(const b3ShapeId shapeId) nothrow @nogc @trusted {
    if (!b3Shape_IsValidD(shapeId))
        return noPhysicsEntity;
    immutable bodyId = b3Shape_GetBodyD(shapeId);
    return getBodyEntity(bodyId);
}

bool isBodyValid(const b3BodyId bodyId) nothrow @nogc @trusted {
    return b3Body_IsValidD(bodyId);
}

b3BodyId createStaticBox(ref PhysicsWorld world,
                         Vec3 position,
                         Vec3 halfExtent,
                         EntityId entityId = noPhysicsEntity,
                         float friction = 0.7f) nothrow @nogc @trusted {
    return createBoxBody(world, b3_staticBody, position, halfExtent, Quat.init, 0.0f, entityId, friction, false);
}

b3BodyId createStaticBox(ref PhysicsWorld world,
                         Vec3 position,
                         Vec3 halfExtent,
                         Quat rotation,
                         EntityId entityId = noPhysicsEntity,
                         float friction = 0.7f) nothrow @nogc @trusted {
    return createBoxBody(world, b3_staticBody, position, halfExtent, rotation, 0.0f, entityId, friction, false);
}

b3BodyId createDynamicBox(ref PhysicsWorld world,
                          Vec3 position,
                          Vec3 halfExtent,
                          float density = 1.0f,
                          EntityId entityId = noPhysicsEntity,
                          float friction = 0.7f) nothrow @nogc @trusted {
    return createBoxBody(world, b3_dynamicBody, position, halfExtent, Quat.init, density, entityId, friction, false);
}

b3BodyId createDynamicBox(ref PhysicsWorld world,
                          Vec3 position,
                          Vec3 halfExtent,
                          Quat rotation,
                          float density = 1.0f,
                          EntityId entityId = noPhysicsEntity,
                          float friction = 0.7f) nothrow @nogc @trusted {
    return createBoxBody(world, b3_dynamicBody, position, halfExtent, rotation, density, entityId, friction, false);
}

b3BodyId createDynamicSphere(ref PhysicsWorld world,
                             Vec3 position,
                             float radius,
                             float density = 1.0f,
                             EntityId entityId = noPhysicsEntity,
                             float friction = 0.7f) nothrow @nogc @trusted {
    b3BodyDef bodyDef = b3DefaultBodyDefD();
    bodyDef.type = b3_dynamicBody;
    bodyDef.position = toB3Pos(position);
    bodyDef.rotation = toB3Quat(Quat.init);
    bodyDef.userData = encodeEntityUserData(entityId);
    b3BodyId bodyId = b3CreateBodyD(world.handle, &bodyDef);

    b3Sphere sphere;
    sphere.center = b3Vec3(0.0f, 0.0f, 0.0f);
    sphere.radius = radius;

    b3ShapeDef shapeDef = defaultShapeDef(density, entityId, friction, false);
    b3CreateSphereShapeD(bodyId, &shapeDef, &sphere);
    return bodyId;
}

b3BodyId createSensorBox(ref PhysicsWorld world,
                         Vec3 position,
                         Vec3 halfExtent,
                         EntityId entityId = noPhysicsEntity) nothrow @nogc @trusted {
    return createBoxBody(world, b3_staticBody, position, halfExtent, Quat.init, 0.0f, entityId, 0.0f, true);
}

b3BodyId createGroundSlab(ref PhysicsWorld world,
                          float y,
                          Vec3 halfExtentXZ,
                          float halfExtentY,
                          EntityId entityId = noPhysicsEntity) nothrow @nogc @trusted {
    immutable pos = Vec3(0.0f, y - halfExtentY, 0.0f);
    immutable extents = Vec3(halfExtentXZ.x, halfExtentY, halfExtentXZ.z);
    return createStaticBox(world, pos, extents, entityId, 1.0f);
}

void setLinearVelocity(const b3BodyId bodyId, Vec3 velocity) nothrow @nogc @trusted {
    b3Body_SetLinearVelocityD(bodyId, toB3Vec3(velocity));
}

Vec3 getLinearVelocity(const b3BodyId bodyId) nothrow @nogc @trusted {
    return toEngineVec3(b3Body_GetLinearVelocityD(bodyId));
}

void setAngularVelocity(const b3BodyId bodyId, Vec3 velocity) nothrow @nogc @trusted {
    b3Body_SetAngularVelocityD(bodyId, toB3Vec3(velocity));
}

Vec3 getAngularVelocity(const b3BodyId bodyId) nothrow @nogc @trusted {
    return toEngineVec3(b3Body_GetAngularVelocityD(bodyId));
}

void applyForceToCenter(const b3BodyId bodyId, Vec3 force, bool wake = true) nothrow @nogc @trusted {
    b3Body_ApplyForceToCenterD(bodyId, toB3Vec3(force), wake);
}

void applyLinearImpulseToCenter(const b3BodyId bodyId, Vec3 impulse, bool wake = true) nothrow @nogc @trusted {
    b3Body_ApplyLinearImpulseToCenterD(bodyId, toB3Vec3(impulse), wake);
}

void setLinearDamping(const b3BodyId bodyId, float damping) nothrow @nogc @trusted {
    b3Body_SetLinearDampingD(bodyId, damping);
}

void setAngularDamping(const b3BodyId bodyId, float damping) nothrow @nogc @trusted {
    b3Body_SetAngularDampingD(bodyId, damping);
}

void destroyBody(const b3BodyId bodyId) nothrow @nogc @trusted {
    if (b3Body_IsValidD(bodyId))
        b3DestroyBodyD(bodyId);
}

Vec3 getPosition(const b3BodyId bodyId) nothrow @nogc @trusted {
    immutable p = b3Body_GetPositionD(bodyId);
    return Vec3(cast(float) p.x, cast(float) p.y, cast(float) p.z);
}

private b3BodyId createBoxBody(ref PhysicsWorld world,
                               b3BodyType type,
                               Vec3 position,
                               Vec3 halfExtent,
                               Quat rotation,
                               float density,
                               EntityId entityId,
                               float friction,
                               bool sensor) nothrow @nogc @trusted {
    b3BodyDef bodyDef = b3DefaultBodyDefD();
    bodyDef.type = type;
    bodyDef.position = toB3Pos(position);
    bodyDef.rotation = toB3Quat(rotation);
    bodyDef.userData = encodeEntityUserData(entityId);
    b3BodyId bodyId = b3CreateBodyD(world.handle, &bodyDef);

    b3BoxHull hull = b3MakeBoxHullD(halfExtent.x, halfExtent.y, halfExtent.z);
    b3ShapeDef shapeDef = defaultShapeDef(density, entityId, friction, sensor);
    b3CreateHullShapeD(bodyId, &shapeDef, &hull.base);
    return bodyId;
}

private b3ShapeDef defaultShapeDef(float density,
                                   EntityId entityId,
                                   float friction,
                                   bool sensor) nothrow @nogc @trusted {
    b3ShapeDef shapeDef = b3DefaultShapeDefD();
    shapeDef.userData = encodeEntityUserData(entityId);
    shapeDef.density = density;
    shapeDef.baseMaterial.friction = friction;
    shapeDef.baseMaterial.restitution = 0.0f;
    shapeDef.isSensor = sensor;
    shapeDef.enableSensorEvents = true;
    shapeDef.enableContactEvents = !sensor;
    return shapeDef;
}
