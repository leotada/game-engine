module engine.physics.body;

import bindings.box3d;
import engine.core.pod : isPod;
import engine.ecs.store : EntityId;
import engine.math.quat : Quat;
import engine.math.vec : Vec3;
import engine.physics.convert : toB3Pos, toB3Quat, toB3Vec3, toEngineQuat, toEngineVec3;
import engine.physics.world : PhysicsWorld;

@safe:

enum EntityId noPhysicsEntity = EntityId.max;

/// Material index reserved by Box3D heightfields to punch holes in terrain grids.
enum ubyte heightFieldHole = 0xFF;

/// Rigid body motion category.
enum PhysicsBodyType : ubyte {
    static_,
    kinematic,
    dynamic
}

/// Physical surface material properties attached to a shape or per-triangle slot.
struct PhysicsSurfaceMaterial {
    float friction = 0.7f;
    float restitution = 0.0f;
    float rollingResistance = 0.0f;
    ulong userMaterialId = 0;
}

/// Bitmask and group index used to filter shape-vs-shape and query collisions.
/// A negative `groupIndex` disables collisions among shapes sharing that index.
struct CollisionFilter {
    ulong categoryBits = ulong.max;
    ulong maskBits = ulong.max;
    int groupIndex = 0;
}

/// Complete POD descriptor for creating a physics body and its primary shape.
struct BodyDesc {
    PhysicsBodyType type = PhysicsBodyType.dynamic;
    Vec3 position = Vec3(0.0f, 0.0f, 0.0f);
    Quat rotation = Quat.init;
    float density = 1.0f;
    EntityId entityId = noPhysicsEntity;
    PhysicsSurfaceMaterial material = PhysicsSurfaceMaterial.init;
    CollisionFilter filter = CollisionFilter.init;
    bool isSensor = false;
    bool enableHitEvents = false;
    bool isBullet = false;
    bool startAwake = true;
    bool enableSleep = true;
    float sleepThreshold = 0.05f;
    float linearDamping = 0.0f;
    float angularDamping = 0.0f;
}

static assert(isPod!PhysicsSurfaceMaterial);
static assert(isPod!CollisionFilter);
static assert(isPod!BodyDesc);

/// Move-only RAII wrapper owning cooked Box3D static triangle mesh data.
/// Must outlive any static body/shape created from it.
struct CookedMesh {
    @disable this(this);

    private b3MeshData* _data;

    static CookedMesh create(scope const(Vec3)[] vertices,
                             scope const(int)[] indices,
                             scope const(ubyte)[] materialIndices = null,
                             bool weldVertices = false,
                             float weldTolerance = 0.0f,
                             bool useMedianSplit = false,
                             bool identifyEdges = true) nothrow @nogc @trusted {
        CookedMesh result;
        result._data = cookMeshData(vertices, indices, materialIndices,
            weldVertices, weldTolerance, useMedianSplit, identifyEdges);
        return result;
    }

    ~this() nothrow @nogc @trusted {
        destroy();
    }

    bool valid() const pure nothrow @nogc {
        return _data !is null;
    }

    const(b3MeshData)* handle() const pure nothrow @nogc {
        return _data;
    }

    void destroy() nothrow @nogc @trusted {
        if (_data !is null) {
            b3DestroyMeshD(_data);
            _data = null;
        }
    }
}

/// Move-only RAII wrapper owning cooked Box3D heightfield terrain data.
/// Must outlive any static body/shape created from it.
struct CookedHeightField {
    @disable this(this);

    private b3HeightFieldData* _data;

    static CookedHeightField create(scope const(float)[] heights,
                                    int countX,
                                    int countZ,
                                    Vec3 scale = Vec3(1.0f, 1.0f, 1.0f),
                                    scope const(ubyte)[] materialIndices = null,
                                    float globalMinHeight = float.nan,
                                    float globalMaxHeight = float.nan,
                                    bool clockwiseWinding = false) nothrow @nogc @trusted {
        CookedHeightField result;
        result._data = cookHeightFieldData(heights, countX, countZ, scale,
            materialIndices, globalMinHeight, globalMaxHeight, clockwiseWinding);
        return result;
    }

    ~this() nothrow @nogc @trusted {
        destroy();
    }

    bool valid() const pure nothrow @nogc {
        return _data !is null;
    }

    const(b3HeightFieldData)* handle() const pure nothrow @nogc {
        return _data;
    }

    void destroy() nothrow @nogc @trusted {
        if (_data !is null) {
            b3DestroyHeightFieldD(_data);
            _data = null;
        }
    }
}

b3BodyType toB3BodyType(PhysicsBodyType type) pure nothrow @nogc {
    final switch (type) {
        case PhysicsBodyType.static_: return b3_staticBody;
        case PhysicsBodyType.kinematic: return b3_kinematicBody;
        case PhysicsBodyType.dynamic: return b3_dynamicBody;
    }
}

PhysicsBodyType fromB3BodyType(b3BodyType type) pure nothrow @nogc {
    if (type == b3_staticBody)
        return PhysicsBodyType.static_;
    if (type == b3_kinematicBody)
        return PhysicsBodyType.kinematic;
    return PhysicsBodyType.dynamic;
}

b3SurfaceMaterial toB3SurfaceMaterial(const PhysicsSurfaceMaterial mat) nothrow @nogc @trusted {
    b3SurfaceMaterial raw = b3DefaultSurfaceMaterialD();
    raw.friction = mat.friction;
    raw.restitution = mat.restitution;
    raw.rollingResistance = mat.rollingResistance;
    raw.userMaterialId = mat.userMaterialId;
    return raw;
}

PhysicsSurfaceMaterial fromB3SurfaceMaterial(const b3SurfaceMaterial raw) pure nothrow @nogc {
    PhysicsSurfaceMaterial mat;
    mat.friction = raw.friction;
    mat.restitution = raw.restitution;
    mat.rollingResistance = raw.rollingResistance;
    mat.userMaterialId = raw.userMaterialId;
    return mat;
}

b3Filter toB3Filter(const CollisionFilter filter) pure nothrow @nogc {
    b3Filter raw;
    raw.categoryBits = filter.categoryBits;
    raw.maskBits = filter.maskBits;
    raw.groupIndex = filter.groupIndex;
    return raw;
}

CollisionFilter fromB3Filter(const b3Filter raw) pure nothrow @nogc {
    return CollisionFilter(raw.categoryBits, raw.maskBits, raw.groupIndex);
}

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

// --- Full BodyDesc creation helpers ---

/// Create a box rigid body configured by `BodyDesc`.
b3BodyId createBoxBody(ref PhysicsWorld world, const BodyDesc desc, Vec3 halfExtent) nothrow @nogc @trusted {
    b3BodyId bodyId = createBodyShell(world, desc);
    if (!isBodyValid(bodyId))
        return b3BodyId.init;
    b3BoxHull hull = b3MakeBoxHullD(halfExtent.x, halfExtent.y, halfExtent.z);
    b3ShapeDef shapeDef = makeShapeDef(desc);
    b3CreateHullShapeD(bodyId, &shapeDef, &hull.base);
    return bodyId;
}

/// Create a sphere rigid body configured by `BodyDesc`.
b3BodyId createSphereBody(ref PhysicsWorld world, const BodyDesc desc, float radius) nothrow @nogc @trusted {
    b3BodyId bodyId = createBodyShell(world, desc);
    if (!isBodyValid(bodyId))
        return b3BodyId.init;
    b3Sphere sphere;
    sphere.center = b3Vec3(0.0f, 0.0f, 0.0f);
    sphere.radius = radius;
    b3ShapeDef shapeDef = makeShapeDef(desc);
    b3CreateSphereShapeD(bodyId, &shapeDef, &sphere);
    return bodyId;
}

/// Create a Y-axis capsule rigid body configured by `BodyDesc`.
b3BodyId createCapsuleBody(ref PhysicsWorld world, const BodyDesc desc, float height, float radius) nothrow @nogc @trusted {
    b3BodyId bodyId = createBodyShell(world, desc);
    if (!isBodyValid(bodyId))
        return b3BodyId.init;
    b3Capsule capsule = makeYAxisCapsule(height, radius);
    b3ShapeDef shapeDef = makeShapeDef(desc);
    b3CreateCapsuleShapeD(bodyId, &shapeDef, &capsule);
    return bodyId;
}

/// Create a cylinder hull rigid body configured by `BodyDesc`.
b3BodyId createCylinderBody(ref PhysicsWorld world,
                            const BodyDesc desc,
                            float height,
                            float radius,
                            int sides = 12) nothrow @nogc @trusted {
    b3BodyId bodyId = createBodyShell(world, desc);
    if (!isBodyValid(bodyId))
        return b3BodyId.init;
    immutable sideCount = sides < 3 ? 3 : sides;
    b3HullData* hull = b3CreateCylinderD(height, radius, 0.0f, sideCount);
    if (hull is null)
        return bodyId;
    b3ShapeDef shapeDef = makeShapeDef(desc);
    b3CreateHullShapeD(bodyId, &shapeDef, hull);
    b3DestroyHullD(hull);
    return bodyId;
}

/// Create a convex hull rigid body from local points configured by `BodyDesc`.
b3BodyId createHullBody(ref PhysicsWorld world,
                        const BodyDesc desc,
                        scope const(Vec3)[] points,
                        int maxVertexCount = 64) nothrow @nogc @trusted {
    b3BodyId bodyId = createBodyShell(world, desc);
    if (!isBodyValid(bodyId))
        return b3BodyId.init;
    if (points.length < 3 || maxVertexCount < 3)
        return bodyId;

    immutable pointCount = cast(int) points.length;
    immutable maxVerts = maxVertexCount < pointCount ? maxVertexCount : pointCount;
    b3HullData* hull = b3CreateHullD(cast(const(b3Vec3)*) points.ptr, pointCount, maxVerts);
    if (hull is null)
        return bodyId;

    b3ShapeDef shapeDef = makeShapeDef(desc);
    b3CreateHullShapeD(bodyId, &shapeDef, hull);
    b3DestroyHullD(hull);
    return bodyId;
}

// --- Convenience primitive helpers (backwards compatible) ---

b3BodyId createStaticBox(ref PhysicsWorld world,
                         Vec3 position,
                         Vec3 halfExtent,
                         EntityId entityId = noPhysicsEntity,
                         float friction = 0.7f,
                         float restitution = 0.0f,
                         bool enableHitEvents = false) nothrow @nogc {
    return createBoxBody(world, makeSimpleDesc(PhysicsBodyType.static_, position, Quat.init,
        0.0f, entityId, friction, restitution, false, enableHitEvents), halfExtent);
}

b3BodyId createStaticBox(ref PhysicsWorld world,
                         Vec3 position,
                         Vec3 halfExtent,
                         Quat rotation,
                         EntityId entityId = noPhysicsEntity,
                         float friction = 0.7f,
                         float restitution = 0.0f,
                         bool enableHitEvents = false) nothrow @nogc {
    return createBoxBody(world, makeSimpleDesc(PhysicsBodyType.static_, position, rotation,
        0.0f, entityId, friction, restitution, false, enableHitEvents), halfExtent);
}

b3BodyId createKinematicBox(ref PhysicsWorld world,
                            Vec3 position,
                            Vec3 halfExtent,
                            EntityId entityId = noPhysicsEntity,
                            float friction = 0.7f,
                            float restitution = 0.0f,
                            bool enableHitEvents = false) nothrow @nogc {
    return createBoxBody(world, makeSimpleDesc(PhysicsBodyType.kinematic, position, Quat.init,
        1.0f, entityId, friction, restitution, false, enableHitEvents), halfExtent);
}

b3BodyId createKinematicBox(ref PhysicsWorld world,
                            Vec3 position,
                            Vec3 halfExtent,
                            Quat rotation,
                            EntityId entityId = noPhysicsEntity,
                            float friction = 0.7f,
                            float restitution = 0.0f,
                            bool enableHitEvents = false) nothrow @nogc {
    return createBoxBody(world, makeSimpleDesc(PhysicsBodyType.kinematic, position, rotation,
        1.0f, entityId, friction, restitution, false, enableHitEvents), halfExtent);
}

b3BodyId createDynamicBox(ref PhysicsWorld world,
                          Vec3 position,
                          Vec3 halfExtent,
                          float density = 1.0f,
                          EntityId entityId = noPhysicsEntity,
                          float friction = 0.7f,
                          float restitution = 0.0f,
                          bool enableHitEvents = false) nothrow @nogc {
    return createBoxBody(world, makeSimpleDesc(PhysicsBodyType.dynamic, position, Quat.init,
        density, entityId, friction, restitution, false, enableHitEvents), halfExtent);
}

b3BodyId createDynamicBox(ref PhysicsWorld world,
                          Vec3 position,
                          Vec3 halfExtent,
                          Quat rotation,
                          float density = 1.0f,
                          EntityId entityId = noPhysicsEntity,
                          float friction = 0.7f,
                          float restitution = 0.0f,
                          bool enableHitEvents = false) nothrow @nogc {
    return createBoxBody(world, makeSimpleDesc(PhysicsBodyType.dynamic, position, rotation,
        density, entityId, friction, restitution, false, enableHitEvents), halfExtent);
}

b3BodyId createDynamicSphere(ref PhysicsWorld world,
                             Vec3 position,
                             float radius,
                             float density = 1.0f,
                             EntityId entityId = noPhysicsEntity,
                             float friction = 0.7f,
                             float restitution = 0.0f,
                             bool enableHitEvents = false) nothrow @nogc {
    return createSphereBody(world, makeSimpleDesc(PhysicsBodyType.dynamic, position, Quat.init,
        density, entityId, friction, restitution, false, enableHitEvents), radius);
}

b3BodyId createStaticSphere(ref PhysicsWorld world,
                            Vec3 position,
                            float radius,
                            EntityId entityId = noPhysicsEntity,
                            float friction = 0.7f,
                            float restitution = 0.0f,
                            bool enableHitEvents = false) nothrow @nogc {
    return createSphereBody(world, makeSimpleDesc(PhysicsBodyType.static_, position, Quat.init,
        0.0f, entityId, friction, restitution, false, enableHitEvents), radius);
}

b3BodyId createKinematicSphere(ref PhysicsWorld world,
                               Vec3 position,
                               float radius,
                               EntityId entityId = noPhysicsEntity,
                               float friction = 0.7f,
                               float restitution = 0.0f,
                               bool enableHitEvents = false) nothrow @nogc {
    return createSphereBody(world, makeSimpleDesc(PhysicsBodyType.kinematic, position, Quat.init,
        1.0f, entityId, friction, restitution, false, enableHitEvents), radius);
}

b3BodyId createDynamicCapsule(ref PhysicsWorld world,
                              Vec3 position,
                              float height,
                              float radius,
                              float density = 1.0f,
                              EntityId entityId = noPhysicsEntity,
                              float friction = 0.7f,
                              float restitution = 0.0f,
                              bool enableHitEvents = false) nothrow @nogc {
    return createCapsuleBody(world, makeSimpleDesc(PhysicsBodyType.dynamic, position, Quat.init,
        density, entityId, friction, restitution, false, enableHitEvents), height, radius);
}

b3BodyId createStaticCapsule(ref PhysicsWorld world,
                             Vec3 position,
                             float height,
                             float radius,
                             EntityId entityId = noPhysicsEntity,
                             float friction = 0.7f,
                             float restitution = 0.0f,
                             bool enableHitEvents = false) nothrow @nogc {
    return createCapsuleBody(world, makeSimpleDesc(PhysicsBodyType.static_, position, Quat.init,
        0.0f, entityId, friction, restitution, false, enableHitEvents), height, radius);
}

b3BodyId createSensorCapsule(ref PhysicsWorld world,
                             Vec3 position,
                             float height,
                             float radius,
                             EntityId entityId = noPhysicsEntity) nothrow @nogc {
    return createCapsuleBody(world, makeSimpleDesc(PhysicsBodyType.static_, position, Quat.init,
        0.0f, entityId, 0.0f, 0.0f, true, false), height, radius);
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
                               int sides = 12) nothrow @nogc {
    return createCylinderBody(world, makeSimpleDesc(PhysicsBodyType.dynamic, position, Quat.init,
        density, entityId, friction, restitution, false, enableHitEvents), height, radius, sides);
}

b3BodyId createStaticCylinder(ref PhysicsWorld world,
                              Vec3 position,
                              float height,
                              float radius,
                              EntityId entityId = noPhysicsEntity,
                              float friction = 0.7f,
                              float restitution = 0.0f,
                              bool enableHitEvents = false,
                              int sides = 12) nothrow @nogc {
    return createCylinderBody(world, makeSimpleDesc(PhysicsBodyType.static_, position, Quat.init,
        0.0f, entityId, friction, restitution, false, enableHitEvents), height, radius, sides);
}

b3BodyId createSensorBox(ref PhysicsWorld world,
                         Vec3 position,
                         Vec3 halfExtent,
                         EntityId entityId = noPhysicsEntity) nothrow @nogc {
    return createBoxBody(world, makeSimpleDesc(PhysicsBodyType.static_, position, Quat.init,
        0.0f, entityId, 0.0f, 0.0f, true, false), halfExtent);
}

b3BodyId createGroundSlab(ref PhysicsWorld world,
                          float y,
                          Vec3 halfExtentXZ,
                          float halfExtentY,
                          EntityId entityId = noPhysicsEntity) nothrow @nogc {
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
                          bool enableHitEvents = false) nothrow @nogc {
    return createHullBody(world, makeSimpleDesc(PhysicsBodyType.static_, position, Quat.init,
        0.0f, entityId, friction, restitution, false, enableHitEvents), points, maxVertexCount);
}

b3BodyId createDynamicHull(ref PhysicsWorld world,
                           Vec3 position,
                           scope const(Vec3)[] points,
                           int maxVertexCount = 64,
                           float density = 1.0f,
                           EntityId entityId = noPhysicsEntity,
                           float friction = 0.7f,
                           float restitution = 0.0f,
                           bool enableHitEvents = false) nothrow @nogc {
    return createHullBody(world, makeSimpleDesc(PhysicsBodyType.dynamic, position, Quat.init,
        density, entityId, friction, restitution, false, enableHitEvents), points, maxVertexCount);
}

b3BodyId createKinematicHull(ref PhysicsWorld world,
                             Vec3 position,
                             scope const(Vec3)[] points,
                             int maxVertexCount = 64,
                             EntityId entityId = noPhysicsEntity,
                             float friction = 0.7f,
                             float restitution = 0.0f,
                             bool enableHitEvents = false) nothrow @nogc {
    return createHullBody(world, makeSimpleDesc(PhysicsBodyType.kinematic, position, Quat.init,
        1.0f, entityId, friction, restitution, false, enableHitEvents), points, maxVertexCount);
}

// --- Static triangle mesh & heightfield colliders (dynamic mesh intentionally forbidden) ---

/// Attach a caller-owned `CookedMesh` to a new static rigid body.
/// `mesh` must remain alive while the created body/shape exists in `world`.
b3BodyId createStaticMesh(ref PhysicsWorld world,
                          Vec3 position,
                          ref const CookedMesh mesh,
                          scope const(PhysicsSurfaceMaterial)[] materials = null,
                          EntityId entityId = noPhysicsEntity,
                          Vec3 scale = Vec3(1.0f, 1.0f, 1.0f),
                          CollisionFilter filter = CollisionFilter.init,
                          bool enableHitEvents = false) nothrow @nogc @trusted {
    if (!mesh.valid())
        return b3BodyId.init;
    return createStaticMeshShapeBody(world, position, mesh.handle, 0.7f, 0.0f,
        materials, entityId, scale, filter, enableHitEvents);
}

/// Triangle mesh collider (static only). `indices` length must be `triangleCount * 3`.
/// Triangles are single-sided — winding must face the colliding side (normals outward/up).
/// Cooked mesh lifetime is owned by `world` and freed when `world` is destroyed.
/// Dynamic mesh is intentionally not exposed — Box3D only generates mesh contacts on static bodies.
b3BodyId createStaticMesh(ref PhysicsWorld world,
                          Vec3 position,
                          scope const(Vec3)[] vertices,
                          scope const(int)[] indices,
                          EntityId entityId = noPhysicsEntity,
                          float friction = 0.7f,
                          float restitution = 0.0f,
                          bool enableHitEvents = false,
                          Vec3 scale = Vec3(1.0f, 1.0f, 1.0f),
                          scope const(ubyte)[] materialIndices = null,
                          scope const(PhysicsSurfaceMaterial)[] materials = null,
                          CollisionFilter filter = CollisionFilter.init) nothrow @nogc @trusted {
    b3MeshData* mesh = cookMeshData(vertices, indices, materialIndices, false, 0.0f, false, true);
    if (mesh is null)
        return b3BodyId.init;

    if (!world.adoptCookedMesh(mesh)) {
        b3DestroyMeshD(mesh);
        return b3BodyId.init;
    }

    return createStaticMeshShapeBody(world, position, mesh, friction, restitution,
        materials, entityId, scale, filter, enableHitEvents);
}

/// Attach a caller-owned `CookedHeightField` to a new static rigid body.
/// `hf` must remain alive while the created body/shape exists in `world`.
b3BodyId createHeightField(ref PhysicsWorld world,
                           Vec3 position,
                           ref const CookedHeightField hf,
                           scope const(PhysicsSurfaceMaterial)[] materials = null,
                           EntityId entityId = noPhysicsEntity,
                           CollisionFilter filter = CollisionFilter.init,
                           bool enableHitEvents = false) nothrow @nogc @trusted {
    if (!hf.valid())
        return b3BodyId.init;
    return createHeightFieldShapeBody(world, position, hf.handle, materials,
        entityId, filter, enableHitEvents);
}

/// Static heightfield terrain collider (`heights.length == countX * countZ`).
/// Optional `materialIndices` has `(countX - 1) * (countZ - 1)` entries (`heightFieldHole` punches holes).
/// Cooked heightfield lifetime is owned by `world` and freed when `world` is destroyed.
b3BodyId createHeightField(ref PhysicsWorld world,
                           Vec3 position,
                           scope const(float)[] heights,
                           int countX,
                           int countZ,
                           Vec3 scale = Vec3(1.0f, 1.0f, 1.0f),
                           scope const(ubyte)[] materialIndices = null,
                           scope const(PhysicsSurfaceMaterial)[] materials = null,
                           EntityId entityId = noPhysicsEntity,
                           float globalMinHeight = float.nan,
                           float globalMaxHeight = float.nan,
                           bool clockwiseWinding = false,
                           CollisionFilter filter = CollisionFilter.init,
                           bool enableHitEvents = false) nothrow @nogc @trusted {
    b3HeightFieldData* hf = cookHeightFieldData(heights, countX, countZ, scale,
        materialIndices, globalMinHeight, globalMaxHeight, clockwiseWinding);
    if (hf is null)
        return b3BodyId.init;

    if (!world.adoptCookedHeightField(hf)) {
        b3DestroyHeightFieldD(hf);
        return b3BodyId.init;
    }

    return createHeightFieldShapeBody(world, position, hf, materials,
        entityId, filter, enableHitEvents);
}

// --- Runtime body and shape manipulation ---

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

/// Force (N) at a world point: also produces torque around the center of mass.
void applyForce(const b3BodyId bodyId, Vec3 force, Vec3 worldPoint, bool wake = true) nothrow @nogc @trusted {
    if (b3Body_IsValidD(bodyId))
        b3Body_ApplyForceD(bodyId, toB3Vec3(force), toB3Pos(worldPoint), wake);
}

/// Body mass (kg), from its shapes' densities.
float getMass(const b3BodyId bodyId) nothrow @nogc @trusted {
    return b3Body_IsValidD(bodyId) ? b3Body_GetMassD(bodyId) : 0.0f;
}

/// Mass properties of a body in its local space. `inertiaX/Y/Z` are the columns of the
/// symmetric 3x3 inertia tensor about the center of mass (kg*m^2).
struct BodyMassData {
    float mass = 0.0f;
    Vec3 center;      /// local center of mass
    Vec3 inertiaX;
    Vec3 inertiaY;
    Vec3 inertiaZ;

    /// Mass data with a diagonal inertia tensor (principal moments `ix`, `iy`, `iz`),
    /// the common case for boxes, cylinders and vehicles.
    static BodyMassData diagonal(float mass, Vec3 center, float ix, float iy, float iz) nothrow @nogc pure @safe {
        BodyMassData d;
        d.mass = mass;
        d.center = center;
        d.inertiaX = Vec3(ix, 0.0f, 0.0f);
        d.inertiaY = Vec3(0.0f, iy, 0.0f);
        d.inertiaZ = Vec3(0.0f, 0.0f, iz);
        return d;
    }
}

static assert(isPod!BodyMassData);

/// Current mass, local center of mass and inertia tensor. A default-initialized value
/// (zero mass) is returned for an invalid body.
BodyMassData getMassData(const b3BodyId bodyId) nothrow @nogc @trusted {
    BodyMassData d;
    if (!b3Body_IsValidD(bodyId)) return d;
    const raw = b3Body_GetMassDataD(bodyId);
    d.mass = raw.mass;
    d.center = toEngineVec3(raw.center);
    d.inertiaX = toEngineVec3(raw.inertia.cx);
    d.inertiaY = toEngineVec3(raw.inertia.cy);
    d.inertiaZ = toEngineVec3(raw.inertia.cz);
    return d;
}

/// Override mass, center of mass and inertia (e.g. a vehicle whose inertia is computed from its
/// bounding box instead of the collision shapes). Box3D discards the override when a shape is
/// added or removed or the body type changes; call `resetMassFromShapes` to undo it.
void setMassData(const b3BodyId bodyId, const BodyMassData data) nothrow @nogc @trusted {
    if (!b3Body_IsValidD(bodyId)) return;
    b3MassData raw;
    raw.mass = data.mass;
    raw.center = toB3Vec3(data.center);
    raw.inertia.cx = toB3Vec3(data.inertiaX);
    raw.inertia.cy = toB3Vec3(data.inertiaY);
    raw.inertia.cz = toB3Vec3(data.inertiaZ);
    b3Body_SetMassDataD(bodyId, raw);
}

/// Recompute mass properties from the shapes' densities, discarding a `setMassData` override.
void resetMassFromShapes(const b3BodyId bodyId) nothrow @nogc @trusted {
    if (b3Body_IsValidD(bodyId)) b3Body_ApplyMassFromShapesD(bodyId);
}

/// Center of mass in the body's local space.
Vec3 getLocalCenterOfMass(const b3BodyId bodyId) nothrow @nogc @trusted {
    return b3Body_IsValidD(bodyId) ? toEngineVec3(b3Body_GetLocalCenterOfMassD(bodyId)) : Vec3.init;
}

/// Local-space rotational inertia diagonal (Ixx, Iyy, Izz) in kg*m^2.
Vec3 getLocalInertiaDiagonal(const b3BodyId bodyId) nothrow @nogc @trusted {
    if (!b3Body_IsValidD(bodyId)) return Vec3.init;
    const m = b3Body_GetLocalRotationalInertiaD(bodyId);
    return Vec3(m.cx.x, m.cy.y, m.cz.z);
}

/// Body orientation.
Quat getRotation(const b3BodyId bodyId) nothrow @nogc @trusted {
    return toEngineQuat(b3Body_GetRotationD(bodyId));
}

void applyLinearImpulse(const b3BodyId bodyId, Vec3 impulse, Vec3 worldPoint, bool wake = true) nothrow @nogc @trusted {
    if (b3Body_IsValidD(bodyId))
        b3Body_ApplyLinearImpulseD(bodyId, toB3Vec3(impulse), toB3Pos(worldPoint), wake);
}

void applyLinearImpulseToCenter(const b3BodyId bodyId, Vec3 impulse, bool wake = true) nothrow @nogc @trusted {
    b3Body_ApplyLinearImpulseToCenterD(bodyId, toB3Vec3(impulse), wake);
}

void applyAngularImpulse(const b3BodyId bodyId, Vec3 impulse, bool wake = true) nothrow @nogc @trusted {
    if (b3Body_IsValidD(bodyId))
        b3Body_ApplyAngularImpulseD(bodyId, toB3Vec3(impulse), wake);
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

void setBodyType(const b3BodyId bodyId, PhysicsBodyType type) nothrow @nogc @trusted {
    if (b3Body_IsValidD(bodyId))
        b3Body_SetTypeD(bodyId, toB3BodyType(type));
}

PhysicsBodyType getBodyType(const b3BodyId bodyId) nothrow @nogc @trusted {
    if (!b3Body_IsValidD(bodyId))
        return PhysicsBodyType.static_;
    return fromB3BodyType(b3Body_GetTypeD(bodyId));
}

bool isBodyAwake(const b3BodyId bodyId) nothrow @nogc @trusted {
    if (!b3Body_IsValidD(bodyId))
        return false;
    return b3Body_IsAwakeD(bodyId);
}

void setBodyAwake(const b3BodyId bodyId, bool awake) nothrow @nogc @trusted {
    if (b3Body_IsValidD(bodyId))
        b3Body_SetAwakeD(bodyId, awake);
}

void enableBodySleep(const b3BodyId bodyId, bool enabled) nothrow @nogc @trusted {
    if (b3Body_IsValidD(bodyId))
        b3Body_EnableSleepD(bodyId, enabled);
}

bool isBodySleepEnabled(const b3BodyId bodyId) nothrow @nogc @trusted {
    if (!b3Body_IsValidD(bodyId))
        return false;
    return b3Body_IsSleepEnabledD(bodyId);
}

void setBodySleepThreshold(const b3BodyId bodyId, float threshold) nothrow @nogc @trusted {
    if (b3Body_IsValidD(bodyId))
        b3Body_SetSleepThresholdD(bodyId, threshold);
}

void setBodyBullet(const b3BodyId bodyId, bool isBullet) nothrow @nogc @trusted {
    if (b3Body_IsValidD(bodyId))
        b3Body_SetBulletD(bodyId, isBullet);
}

bool isBodyBullet(const b3BodyId bodyId) nothrow @nogc @trusted {
    if (!b3Body_IsValidD(bodyId))
        return false;
    return b3Body_IsBulletD(bodyId);
}

void setBodyFilter(const b3BodyId bodyId, CollisionFilter filter, bool invokeContacts = true) nothrow @nogc @trusted {
    if (!b3Body_IsValidD(bodyId))
        return;
    b3ShapeId[16] shapes;
    immutable count = b3Body_GetShapesD(bodyId, shapes.ptr, cast(int) shapes.length);
    immutable raw = toB3Filter(filter);
    foreach (i; 0 .. count) {
        if (b3Shape_IsValidD(shapes[i]))
            b3Shape_SetFilterD(shapes[i], raw, invokeContacts);
    }
}

void setShapeFilter(const b3ShapeId shapeId, CollisionFilter filter, bool invokeContacts = true) nothrow @nogc @trusted {
    if (b3Shape_IsValidD(shapeId))
        b3Shape_SetFilterD(shapeId, toB3Filter(filter), invokeContacts);
}

CollisionFilter getShapeFilter(const b3ShapeId shapeId) nothrow @nogc @trusted {
    if (!b3Shape_IsValidD(shapeId))
        return CollisionFilter.init;
    return fromB3Filter(b3Shape_GetFilterD(shapeId));
}

void setBodyRestitution(const b3BodyId bodyId, float restitution) nothrow @nogc @trusted {
    if (!b3Body_IsValidD(bodyId))
        return;
    b3ShapeId[16] shapes;
    immutable count = b3Body_GetShapesD(bodyId, shapes.ptr, cast(int) shapes.length);
    foreach (i; 0 .. count) {
        if (b3Shape_IsValidD(shapes[i]))
            b3Shape_SetRestitutionD(shapes[i], restitution);
    }
}

void setBodyDensity(const b3BodyId bodyId, float density) nothrow @nogc @trusted {
    if (!b3Body_IsValidD(bodyId))
        return;
    b3ShapeId[16] shapes;
    immutable count = b3Body_GetShapesD(bodyId, shapes.ptr, cast(int) shapes.length);
    foreach (i; 0 .. count) {
        if (b3Shape_IsValidD(shapes[i]))
            b3Shape_SetDensityD(shapes[i], density, false);
    }
    b3Body_ApplyMassFromShapesD(bodyId);
}

void setBodySurfaceMaterial(const b3BodyId bodyId, PhysicsSurfaceMaterial material) nothrow @nogc @trusted {
    if (!b3Body_IsValidD(bodyId))
        return;
    b3ShapeId[16] shapes;
    immutable count = b3Body_GetShapesD(bodyId, shapes.ptr, cast(int) shapes.length);
    immutable raw = toB3SurfaceMaterial(material);
    foreach (i; 0 .. count) {
        if (b3Shape_IsValidD(shapes[i]))
            b3Shape_SetSurfaceMaterialD(shapes[i], raw);
    }
}

void setShapeSurfaceMaterial(const b3ShapeId shapeId, PhysicsSurfaceMaterial material) nothrow @nogc @trusted {
    if (b3Shape_IsValidD(shapeId))
        b3Shape_SetSurfaceMaterialD(shapeId, toB3SurfaceMaterial(material));
}

PhysicsSurfaceMaterial getShapeSurfaceMaterial(const b3ShapeId shapeId) nothrow @nogc @trusted {
    if (!b3Shape_IsValidD(shapeId))
        return PhysicsSurfaceMaterial.init;
    return fromB3SurfaceMaterial(b3Shape_GetSurfaceMaterialD(shapeId));
}

void setShapeMeshMaterial(const b3ShapeId shapeId, PhysicsSurfaceMaterial material, int index) nothrow @nogc @trusted {
    if (b3Shape_IsValidD(shapeId) && index >= 0 && index < b3Shape_GetMeshMaterialCountD(shapeId))
        b3Shape_SetMeshMaterialD(shapeId, toB3SurfaceMaterial(material), index);
}

void destroyBody(const b3BodyId bodyId) nothrow @nogc @trusted {
    if (b3Body_IsValidD(bodyId))
        b3DestroyBodyD(bodyId);
}

Vec3 getPosition(const b3BodyId bodyId) nothrow @nogc @trusted {
    immutable p = b3Body_GetPositionD(bodyId);
    return Vec3(cast(float) p.x, cast(float) p.y, cast(float) p.z);
}

// --- Private helpers ---

private BodyDesc makeSimpleDesc(PhysicsBodyType type,
                                Vec3 position,
                                Quat rotation,
                                float density,
                                EntityId entityId,
                                float friction,
                                float restitution,
                                bool isSensor,
                                bool enableHitEvents) pure nothrow @nogc {
    BodyDesc desc;
    desc.type = type;
    desc.position = position;
    desc.rotation = rotation;
    desc.density = density;
    desc.entityId = entityId;
    desc.material.friction = friction;
    desc.material.restitution = restitution;
    desc.isSensor = isSensor;
    desc.enableHitEvents = enableHitEvents;
    return desc;
}

private b3BodyId createBodyShell(ref PhysicsWorld world, const BodyDesc desc) nothrow @nogc @trusted {
    b3BodyDef bodyDef = b3DefaultBodyDefD();
    bodyDef.type = toB3BodyType(desc.type);
    bodyDef.position = toB3Pos(desc.position);
    bodyDef.rotation = toB3Quat(desc.rotation);
    bodyDef.userData = encodeEntityUserData(desc.entityId);
    bodyDef.isBullet = desc.isBullet;
    bodyDef.isAwake = desc.startAwake;
    bodyDef.enableSleep = desc.enableSleep;
    bodyDef.sleepThreshold = desc.sleepThreshold;
    bodyDef.linearDamping = desc.linearDamping;
    bodyDef.angularDamping = desc.angularDamping;
    return b3CreateBodyD(world.handle, &bodyDef);
}

private b3ShapeDef makeShapeDef(const BodyDesc desc) nothrow @nogc @trusted {
    b3ShapeDef shapeDef = b3DefaultShapeDefD();
    shapeDef.userData = encodeEntityUserData(desc.entityId);
    shapeDef.density = desc.density;
    shapeDef.baseMaterial = toB3SurfaceMaterial(desc.material);
    shapeDef.filter = toB3Filter(desc.filter);
    shapeDef.isSensor = desc.isSensor;
    shapeDef.enableSensorEvents = true;
    shapeDef.enableContactEvents = !desc.isSensor;
    shapeDef.enableHitEvents = desc.enableHitEvents && !desc.isSensor;
    return shapeDef;
}

private void populateShapeMaterials(ref b3ShapeDef shapeDef,
                                    ref b3SurfaceMaterial[256] buf,
                                    scope const(PhysicsSurfaceMaterial)[] materials) nothrow @nogc @trusted {
    if (materials.length == 0)
        return;
    immutable count = materials.length <= buf.length ? cast(int) materials.length : cast(int) buf.length;
    foreach (i; 0 .. count)
        buf[i] = toB3SurfaceMaterial(materials[i]);
    shapeDef.materials = buf.ptr;
    shapeDef.materialCount = count;
}

private b3BodyId createStaticMeshShapeBody(ref PhysicsWorld world,
                                           Vec3 position,
                                           const(b3MeshData)* mesh,
                                           float friction,
                                           float restitution,
                                           scope const(PhysicsSurfaceMaterial)[] materials,
                                           EntityId entityId,
                                           Vec3 scale,
                                           CollisionFilter filter,
                                           bool enableHitEvents) nothrow @nogc @trusted {
    auto desc = makeSimpleDesc(PhysicsBodyType.static_, position, Quat.init, 0.0f,
        entityId, friction, restitution, false, enableHitEvents);
    desc.filter = filter;
    b3BodyId bodyId = createBodyShell(world, desc);
    if (!isBodyValid(bodyId))
        return b3BodyId.init;

    b3SurfaceMaterial[256] b3Mats;
    b3ShapeDef shapeDef = makeShapeDef(desc);
    populateShapeMaterials(shapeDef, b3Mats, materials);

    immutable shapeId = b3CreateMeshShapeD(bodyId, &shapeDef, mesh, toB3Vec3(scale));
    if (!b3Shape_IsValidD(shapeId)) {
        destroyBody(bodyId);
        return b3BodyId.init;
    }
    return bodyId;
}

private b3BodyId createHeightFieldShapeBody(ref PhysicsWorld world,
                                            Vec3 position,
                                            const(b3HeightFieldData)* hf,
                                            scope const(PhysicsSurfaceMaterial)[] materials,
                                            EntityId entityId,
                                            CollisionFilter filter,
                                            bool enableHitEvents) nothrow @nogc @trusted {
    auto desc = makeSimpleDesc(PhysicsBodyType.static_, position, Quat.init, 0.0f,
        entityId, 0.7f, 0.0f, false, enableHitEvents);
    desc.filter = filter;
    b3BodyId bodyId = createBodyShell(world, desc);
    if (!isBodyValid(bodyId))
        return b3BodyId.init;

    b3SurfaceMaterial[256] b3Mats;
    b3ShapeDef shapeDef = makeShapeDef(desc);
    populateShapeMaterials(shapeDef, b3Mats, materials);

    immutable shapeId = b3CreateHeightFieldShapeD(bodyId, &shapeDef, hf);
    if (!b3Shape_IsValidD(shapeId)) {
        destroyBody(bodyId);
        return b3BodyId.init;
    }
    return bodyId;
}

private b3MeshData* cookMeshData(scope const(Vec3)[] vertices,
                                 scope const(int)[] indices,
                                 scope const(ubyte)[] materialIndices,
                                 bool weldVertices,
                                 float weldTolerance,
                                 bool useMedianSplit,
                                 bool identifyEdges) nothrow @nogc @trusted {
    if (vertices.length < 3 || indices.length < 3 || (indices.length % 3) != 0)
        return null;
    immutable triCount = indices.length / 3;
    if (materialIndices.length > 0 && materialIndices.length != triCount)
        return null;

    b3MeshDef meshDef;
    meshDef.vertices = cast(b3Vec3*) vertices.ptr;
    meshDef.indices = cast(int*) indices.ptr;
    meshDef.materialIndices = materialIndices.length > 0 ? cast(ubyte*) materialIndices.ptr : null;
    meshDef.weldTolerance = weldTolerance;
    meshDef.vertexCount = cast(int) vertices.length;
    meshDef.triangleCount = cast(int) triCount;
    meshDef.weldVertices = weldVertices;
    meshDef.useMedianSplit = useMedianSplit;
    meshDef.identifyEdges = identifyEdges;

    return b3CreateMeshD(&meshDef, null, 0);
}

private b3HeightFieldData* cookHeightFieldData(scope const(float)[] heights,
                                               int countX,
                                               int countZ,
                                               Vec3 scale,
                                               scope const(ubyte)[] materialIndices,
                                               float globalMinHeight,
                                               float globalMaxHeight,
                                               bool clockwiseWinding) nothrow @nogc @trusted {
    if (countX < 2 || countZ < 2)
        return null;
    immutable expectedHeights = cast(size_t) countX * cast(size_t) countZ;
    if (heights.length != expectedHeights)
        return null;
    if (scale.x <= 0.0f || scale.y <= 0.0f || scale.z <= 0.0f)
        return null;

    immutable expectedCells = cast(size_t)(countX - 1) * cast(size_t)(countZ - 1);
    if (materialIndices.length > 0 && materialIndices.length != expectedCells)
        return null;

    float minH = globalMinHeight;
    float maxH = globalMaxHeight;
    if (minH != minH || maxH != maxH) {
        minH = heights[0];
        maxH = heights[0];
        foreach (h; heights) {
            if (h < minH) minH = h;
            if (h > maxH) maxH = h;
        }
    }
    if (minH >= maxH) {
        minH -= 1.0f;
        maxH += 1.0f;
    }

    b3HeightFieldDef hfDef;
    hfDef.heights = cast(float*) heights.ptr;
    hfDef.materialIndices = materialIndices.length > 0 ? cast(ubyte*) materialIndices.ptr : null;
    hfDef.scale = toB3Vec3(scale);
    hfDef.countX = countX;
    hfDef.countZ = countZ;
    hfDef.globalMinimumHeight = minH;
    hfDef.globalMaximumHeight = maxH;
    hfDef.clockwiseWinding = clockwiseWinding;

    return b3CreateHeightFieldD(&hfDef);
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

@safe nothrow @nogc unittest {
    static assert(isPod!PhysicsSurfaceMaterial);
    static assert(isPod!CollisionFilter);
    static assert(isPod!BodyDesc);
    CollisionFilter f;
    assert(f.categoryBits == ulong.max);
    assert(f.maskBits == ulong.max);
    assert(f.groupIndex == 0);
}

unittest {
    // Mass data: read back, override (diagonal inertia + shifted center), and reset from shapes.
    import std.math : fabs;

    auto world = PhysicsWorld.createDefault();
    BodyDesc desc;
    desc.position = Vec3(0.0f, 5.0f, 0.0f);
    desc.density = 100.0f;
    auto box = createBoxBody(world, desc, Vec3(1.0f, 0.5f, 2.0f));
    assert(isBodyValid(box));

    immutable base = getMassData(box);
    // 2 x 1 x 4 m box at 100 kg/m^3.
    assert(fabs(base.mass - 800.0f) < 1.0f);
    assert(base.inertiaX.x > 0.0f && base.inertiaY.y > 0.0f && base.inertiaZ.z > 0.0f);
    assert(fabs(getMass(box) - base.mass) < 1e-3f);
    immutable diag = getLocalInertiaDiagonal(box);
    assert(fabs(diag.x - base.inertiaX.x) < 1e-3f);

    setMassData(box, BodyMassData.diagonal(1200.0f, Vec3(0.0f, -0.25f, 0.0f), 10.0f, 20.0f, 30.0f));
    immutable over = getMassData(box);
    assert(fabs(over.mass - 1200.0f) < 1e-3f);
    assert(fabs(getMass(box) - 1200.0f) < 1e-3f);
    assert(fabs(getLocalCenterOfMass(box).y + 0.25f) < 1e-4f);
    immutable od = getLocalInertiaDiagonal(box);
    assert(fabs(od.x - 10.0f) < 1e-3f && fabs(od.y - 20.0f) < 1e-3f && fabs(od.z - 30.0f) < 1e-3f);

    resetMassFromShapes(box);
    assert(fabs(getMass(box) - base.mass) < 1.0f);

    destroyBody(box);
    // Invalid body: harmless defaults.
    assert(getMassData(box).mass == 0.0f);
}
