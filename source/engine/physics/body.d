module engine.physics.body;

import bindings.box3d;
import engine.ecs.store : EntityId;
import engine.math.quat : Quat;
import engine.math.vec : Vec3;
import engine.physics.convert : toB3Pos, toB3Quat, toB3Vec3, toEngineVec3;
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
                         float friction = 0.7f,
                         float restitution = 0.0f,
                         bool enableHitEvents = false) nothrow @nogc @trusted {
    return createBoxBody(world, b3_staticBody, position, halfExtent, Quat.init, 0.0f,
        entityId, friction, restitution, false, enableHitEvents);
}

b3BodyId createStaticBox(ref PhysicsWorld world,
                         Vec3 position,
                         Vec3 halfExtent,
                         Quat rotation,
                         EntityId entityId = noPhysicsEntity,
                         float friction = 0.7f,
                         float restitution = 0.0f,
                         bool enableHitEvents = false) nothrow @nogc @trusted {
    return createBoxBody(world, b3_staticBody, position, halfExtent, rotation, 0.0f,
        entityId, friction, restitution, false, enableHitEvents);
}

b3BodyId createKinematicBox(ref PhysicsWorld world,
                            Vec3 position,
                            Vec3 halfExtent,
                            EntityId entityId = noPhysicsEntity,
                            float friction = 0.7f,
                            float restitution = 0.0f,
                            bool enableHitEvents = false) nothrow @nogc @trusted {
    return createBoxBody(world, b3_kinematicBody, position, halfExtent, Quat.init, 0.0f,
        entityId, friction, restitution, false, enableHitEvents);
}

b3BodyId createKinematicBox(ref PhysicsWorld world,
                            Vec3 position,
                            Vec3 halfExtent,
                            Quat rotation,
                            EntityId entityId = noPhysicsEntity,
                            float friction = 0.7f,
                            float restitution = 0.0f,
                            bool enableHitEvents = false) nothrow @nogc @trusted {
    return createBoxBody(world, b3_kinematicBody, position, halfExtent, rotation, 0.0f,
        entityId, friction, restitution, false, enableHitEvents);
}

b3BodyId createDynamicBox(ref PhysicsWorld world,
                          Vec3 position,
                          Vec3 halfExtent,
                          float density = 1.0f,
                          EntityId entityId = noPhysicsEntity,
                          float friction = 0.7f,
                          float restitution = 0.0f,
                          bool enableHitEvents = false) nothrow @nogc @trusted {
    return createBoxBody(world, b3_dynamicBody, position, halfExtent, Quat.init, density,
        entityId, friction, restitution, false, enableHitEvents);
}

b3BodyId createDynamicBox(ref PhysicsWorld world,
                          Vec3 position,
                          Vec3 halfExtent,
                          Quat rotation,
                          float density = 1.0f,
                          EntityId entityId = noPhysicsEntity,
                          float friction = 0.7f,
                          float restitution = 0.0f,
                          bool enableHitEvents = false) nothrow @nogc @trusted {
    return createBoxBody(world, b3_dynamicBody, position, halfExtent, rotation, density,
        entityId, friction, restitution, false, enableHitEvents);
}

b3BodyId createDynamicSphere(ref PhysicsWorld world,
                             Vec3 position,
                             float radius,
                             float density = 1.0f,
                             EntityId entityId = noPhysicsEntity,
                             float friction = 0.7f,
                             float restitution = 0.0f,
                             bool enableHitEvents = false) nothrow @nogc @trusted {
    return createSphereBody(world, b3_dynamicBody, position, radius, density,
        entityId, friction, restitution, false, enableHitEvents);
}

b3BodyId createStaticSphere(ref PhysicsWorld world,
                            Vec3 position,
                            float radius,
                            EntityId entityId = noPhysicsEntity,
                            float friction = 0.7f,
                            float restitution = 0.0f,
                            bool enableHitEvents = false) nothrow @nogc @trusted {
    return createSphereBody(world, b3_staticBody, position, radius, 0.0f,
        entityId, friction, restitution, false, enableHitEvents);
}

b3BodyId createKinematicSphere(ref PhysicsWorld world,
                               Vec3 position,
                               float radius,
                               EntityId entityId = noPhysicsEntity,
                               float friction = 0.7f,
                               float restitution = 0.0f,
                               bool enableHitEvents = false) nothrow @nogc @trusted {
    return createSphereBody(world, b3_kinematicBody, position, radius, 0.0f,
        entityId, friction, restitution, false, enableHitEvents);
}

b3BodyId createDynamicCapsule(ref PhysicsWorld world,
                              Vec3 position,
                              float height,
                              float radius,
                              float density = 1.0f,
                              EntityId entityId = noPhysicsEntity,
                              float friction = 0.7f,
                              float restitution = 0.0f,
                              bool enableHitEvents = false) nothrow @nogc @trusted {
    return createCapsuleBody(world, b3_dynamicBody, position, height, radius, density,
        entityId, friction, restitution, false, enableHitEvents);
}

b3BodyId createStaticCapsule(ref PhysicsWorld world,
                             Vec3 position,
                             float height,
                             float radius,
                             EntityId entityId = noPhysicsEntity,
                             float friction = 0.7f,
                             float restitution = 0.0f,
                             bool enableHitEvents = false) nothrow @nogc @trusted {
    return createCapsuleBody(world, b3_staticBody, position, height, radius, 0.0f,
        entityId, friction, restitution, false, enableHitEvents);
}

b3BodyId createSensorCapsule(ref PhysicsWorld world,
                             Vec3 position,
                             float height,
                             float radius,
                             EntityId entityId = noPhysicsEntity) nothrow @nogc @trusted {
    return createCapsuleBody(world, b3_staticBody, position, height, radius, 0.0f,
        entityId, 0.0f, 0.0f, true, false);
}

b3BodyId createDynamicCylinder(ref PhysicsWorld world,
                               Vec3 position,
                               float height,
                               float radius,
                               float density = 1.0f,
                               EntityId entityId = noPhysicsEntity,
                               float friction = 0.7f,
                               float restitution = 0.0f,
                               bool enableHitEvents = false,
                               int sides = 12) nothrow @nogc @trusted {
    return createCylinderBody(world, b3_dynamicBody, position, height, radius, density,
        entityId, friction, restitution, false, enableHitEvents, sides);
}

b3BodyId createStaticCylinder(ref PhysicsWorld world,
                              Vec3 position,
                              float height,
                              float radius,
                              EntityId entityId = noPhysicsEntity,
                              float friction = 0.7f,
                              float restitution = 0.0f,
                              bool enableHitEvents = false,
                              int sides = 12) nothrow @nogc @trusted {
    return createCylinderBody(world, b3_staticBody, position, height, radius, 0.0f,
        entityId, friction, restitution, false, enableHitEvents, sides);
}

b3BodyId createSensorBox(ref PhysicsWorld world,
                         Vec3 position,
                         Vec3 halfExtent,
                         EntityId entityId = noPhysicsEntity) nothrow @nogc @trusted {
    return createBoxBody(world, b3_staticBody, position, halfExtent, Quat.init, 0.0f,
        entityId, 0.0f, 0.0f, true, false);
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

/// Convex hull from point cloud. `points` are body-local. Hull geometry is cloned by Box3D.
b3BodyId createStaticHull(ref PhysicsWorld world,
                          Vec3 position,
                          scope const(Vec3)[] points,
                          int maxVertexCount = 64,
                          EntityId entityId = noPhysicsEntity,
                          float friction = 0.7f,
                          float restitution = 0.0f,
                          bool enableHitEvents = false) nothrow @nogc @trusted {
    return createHullBody(world, b3_staticBody, position, Quat.init, points, maxVertexCount, 0.0f,
        entityId, friction, restitution, false, enableHitEvents);
}

b3BodyId createDynamicHull(ref PhysicsWorld world,
                           Vec3 position,
                           scope const(Vec3)[] points,
                           int maxVertexCount = 64,
                           float density = 1.0f,
                           EntityId entityId = noPhysicsEntity,
                           float friction = 0.7f,
                           float restitution = 0.0f,
                           bool enableHitEvents = false) nothrow @nogc @trusted {
    return createHullBody(world, b3_dynamicBody, position, Quat.init, points, maxVertexCount, density,
        entityId, friction, restitution, false, enableHitEvents);
}

b3BodyId createKinematicHull(ref PhysicsWorld world,
                             Vec3 position,
                             scope const(Vec3)[] points,
                             int maxVertexCount = 64,
                             EntityId entityId = noPhysicsEntity,
                             float friction = 0.7f,
                             float restitution = 0.0f,
                             bool enableHitEvents = false) nothrow @nogc @trusted {
    return createHullBody(world, b3_kinematicBody, position, Quat.init, points, maxVertexCount, 0.0f,
        entityId, friction, restitution, false, enableHitEvents);
}

/// Triangle mesh collider (static only). `indices` length must be `triangleCount * 3`.
/// Triangles are single-sided — winding must face the colliding side (normals outward/up).
/// Cooked mesh data is retained for the shape lifetime (Box3D does not clone it).
/// Dynamic mesh is intentionally not exposed — Box3D only generates mesh contacts on static bodies.
b3BodyId createStaticMesh(ref PhysicsWorld world,
                          Vec3 position,
                          scope const(Vec3)[] vertices,
                          scope const(int)[] indices,
                          EntityId entityId = noPhysicsEntity,
                          float friction = 0.7f,
                          float restitution = 0.0f,
                          bool enableHitEvents = false,
                          Vec3 scale = Vec3(1.0f, 1.0f, 1.0f)) nothrow @nogc @trusted {
    if (vertices.length < 3 || indices.length < 3 || (indices.length % 3) != 0)
        return b3BodyId.init;

    b3BodyId bodyId = createBodyShell(world, b3_staticBody, position, Quat.init, entityId);

    b3MeshDef meshDef;
    meshDef.vertices = cast(b3Vec3*) vertices.ptr;
    meshDef.indices = cast(int*) indices.ptr;
    meshDef.materialIndices = null;
    meshDef.weldTolerance = 0.0f;
    meshDef.vertexCount = cast(int) vertices.length;
    meshDef.triangleCount = cast(int)(indices.length / 3);
    meshDef.weldVertices = false;
    meshDef.useMedianSplit = false;
    meshDef.identifyEdges = true;

    b3MeshData* mesh = b3CreateMeshD(&meshDef, null, 0);
    if (mesh is null) {
        destroyBody(bodyId);
        return b3BodyId.init;
    }

    // Retain mesh: b3CreateMeshShape holds a reference (not a clone).
    retainCookedMesh(mesh);

    b3ShapeDef shapeDef = defaultShapeDef(0.0f, entityId, friction, restitution, false, enableHitEvents);
    immutable shapeId = b3CreateMeshShapeD(bodyId, &shapeDef, mesh, toB3Vec3(scale));
    if (!b3Shape_IsValidD(shapeId)) {
        destroyBody(bodyId);
        return b3BodyId.init;
    }
    return bodyId;
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

void enableBodyHitEvents(const b3BodyId bodyId, bool enabled) nothrow @nogc @trusted {
    if (b3Body_IsValidD(bodyId))
        b3Body_EnableHitEventsD(bodyId, enabled);
}

void setBodyRestitution(const b3BodyId bodyId, float restitution) nothrow @nogc @trusted {
    if (!b3Body_IsValidD(bodyId))
        return;
    b3ShapeId[8] shapes;
    immutable count = b3Body_GetShapesD(bodyId, shapes.ptr, cast(int) shapes.length);
    foreach (i; 0 .. count) {
        if (b3Shape_IsValidD(shapes[i]))
            b3Shape_SetRestitutionD(shapes[i], restitution);
    }
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
                               float restitution,
                               bool sensor,
                               bool enableHitEvents) nothrow @nogc @trusted {
    b3BodyId bodyId = createBodyShell(world, type, position, rotation, entityId);
    b3BoxHull hull = b3MakeBoxHullD(halfExtent.x, halfExtent.y, halfExtent.z);
    b3ShapeDef shapeDef = defaultShapeDef(density, entityId, friction, restitution, sensor, enableHitEvents);
    b3CreateHullShapeD(bodyId, &shapeDef, &hull.base);
    return bodyId;
}

private b3BodyId createSphereBody(ref PhysicsWorld world,
                                  b3BodyType type,
                                  Vec3 position,
                                  float radius,
                                  float density,
                                  EntityId entityId,
                                  float friction,
                                  float restitution,
                                  bool sensor,
                                  bool enableHitEvents) nothrow @nogc @trusted {
    b3BodyId bodyId = createBodyShell(world, type, position, Quat.init, entityId);
    b3Sphere sphere;
    sphere.center = b3Vec3(0.0f, 0.0f, 0.0f);
    sphere.radius = radius;
    b3ShapeDef shapeDef = defaultShapeDef(density, entityId, friction, restitution, sensor, enableHitEvents);
    b3CreateSphereShapeD(bodyId, &shapeDef, &sphere);
    return bodyId;
}

private b3BodyId createCapsuleBody(ref PhysicsWorld world,
                                   b3BodyType type,
                                   Vec3 position,
                                   float height,
                                   float radius,
                                   float density,
                                   EntityId entityId,
                                   float friction,
                                   float restitution,
                                   bool sensor,
                                   bool enableHitEvents) nothrow @nogc @trusted {
    b3BodyId bodyId = createBodyShell(world, type, position, Quat.init, entityId);
    b3Capsule capsule = makeYAxisCapsule(height, radius);
    b3ShapeDef shapeDef = defaultShapeDef(density, entityId, friction, restitution, sensor, enableHitEvents);
    b3CreateCapsuleShapeD(bodyId, &shapeDef, &capsule);
    return bodyId;
}

private b3BodyId createCylinderBody(ref PhysicsWorld world,
                                    b3BodyType type,
                                    Vec3 position,
                                    float height,
                                    float radius,
                                    float density,
                                    EntityId entityId,
                                    float friction,
                                    float restitution,
                                    bool sensor,
                                    bool enableHitEvents,
                                    int sides) nothrow @nogc @trusted {
    b3BodyId bodyId = createBodyShell(world, type, position, Quat.init, entityId);
    immutable sideCount = sides < 3 ? 3 : sides;
    b3HullData* hull = b3CreateCylinderD(height, radius, 0.0f, sideCount);
    if (hull is null)
        return bodyId;
    b3ShapeDef shapeDef = defaultShapeDef(density, entityId, friction, restitution, sensor, enableHitEvents);
    b3CreateHullShapeD(bodyId, &shapeDef, hull);
    b3DestroyHullD(hull);
    return bodyId;
}

private b3BodyId createHullBody(ref PhysicsWorld world,
                                b3BodyType type,
                                Vec3 position,
                                Quat rotation,
                                scope const(Vec3)[] points,
                                int maxVertexCount,
                                float density,
                                EntityId entityId,
                                float friction,
                                float restitution,
                                bool sensor,
                                bool enableHitEvents) nothrow @nogc @trusted {
    b3BodyId bodyId = createBodyShell(world, type, position, rotation, entityId);
    if (points.length < 3 || maxVertexCount < 3)
        return bodyId;

    immutable pointCount = cast(int) points.length;
    immutable maxVerts = maxVertexCount < pointCount ? maxVertexCount : pointCount;
    b3HullData* hull = b3CreateHullD(cast(const(b3Vec3)*) points.ptr, pointCount, maxVerts);
    if (hull is null)
        return bodyId;

    b3ShapeDef shapeDef = defaultShapeDef(density, entityId, friction, restitution, sensor, enableHitEvents);
    b3CreateHullShapeD(bodyId, &shapeDef, hull);
    b3DestroyHullD(hull);
    return bodyId;
}

/// Process-lifetime retain for cooked triangle meshes referenced by shapes.
private enum size_t MAX_RETAINED_MESHES = 256;
private __gshared b3MeshData*[MAX_RETAINED_MESHES] retainedMeshes;
private __gshared size_t retainedMeshCount;

private void retainCookedMesh(b3MeshData* mesh) nothrow @nogc @trusted {
    if (mesh is null)
        return;
    if (retainedMeshCount < MAX_RETAINED_MESHES)
        retainedMeshes[retainedMeshCount++] = mesh;
    // Overflow: still leave mesh alive (leak) so the shape stays valid.
}

private b3BodyId createBodyShell(ref PhysicsWorld world,
                                 b3BodyType type,
                                 Vec3 position,
                                 Quat rotation,
                                 EntityId entityId) nothrow @nogc @trusted {
    b3BodyDef bodyDef = b3DefaultBodyDefD();
    bodyDef.type = type;
    bodyDef.position = toB3Pos(position);
    bodyDef.rotation = toB3Quat(rotation);
    bodyDef.userData = encodeEntityUserData(entityId);
    return b3CreateBodyD(world.handle, &bodyDef);
}

private b3Capsule makeYAxisCapsule(float height, float radius) pure nothrow @nogc {
    immutable half = height * 0.5f;
    immutable inner = half > radius ? (half - radius) : 0.0f;
    b3Capsule capsule;
    capsule.center1 = b3Vec3(0.0f, -inner, 0.0f);
    capsule.center2 = b3Vec3(0.0f, inner, 0.0f);
    capsule.radius = radius;
    return capsule;
}

private b3ShapeDef defaultShapeDef(float density,
                                   EntityId entityId,
                                   float friction,
                                   float restitution,
                                   bool sensor,
                                   bool enableHitEvents) nothrow @nogc @trusted {
    b3ShapeDef shapeDef = b3DefaultShapeDefD();
    shapeDef.userData = encodeEntityUserData(entityId);
    shapeDef.density = density;
    shapeDef.baseMaterial.friction = friction;
    shapeDef.baseMaterial.restitution = restitution;
    shapeDef.isSensor = sensor;
    shapeDef.enableSensorEvents = true;
    shapeDef.enableContactEvents = !sensor;
    shapeDef.enableHitEvents = enableHitEvents && !sensor;
    return shapeDef;
}
