module bindings.box3d.functions;

import bindings.box3d.raw;

extern(C):
nothrow:
@nogc:

pragma(mangle, "b3DefaultWorldDef") b3WorldDef b3DefaultWorldDefD();
pragma(mangle, "b3CreateWorld") b3WorldId b3CreateWorldD(const(b3WorldDef)* def);
pragma(mangle, "b3DestroyWorld") void b3DestroyWorldD(b3WorldId worldId);
pragma(mangle, "b3World_IsValid") bool b3World_IsValidD(b3WorldId id);
pragma(mangle, "b3World_Step") void b3World_StepD(b3WorldId worldId, float timeStep, int subStepCount);
pragma(mangle, "b3World_SetGravity") void b3World_SetGravityD(b3WorldId worldId, b3Vec3 gravity);
pragma(mangle, "b3World_GetGravity") b3Vec3 b3World_GetGravityD(b3WorldId worldId);
pragma(mangle, "b3World_EnableSleeping") void b3World_EnableSleepingD(b3WorldId worldId, bool flag);
pragma(mangle, "b3World_EnableContinuous") void b3World_EnableContinuousD(b3WorldId worldId, bool flag);
pragma(mangle, "b3World_GetContactEvents") b3ContactEvents b3World_GetContactEventsD(b3WorldId worldId);
pragma(mangle, "b3World_GetSensorEvents") b3SensorEvents b3World_GetSensorEventsD(b3WorldId worldId);
pragma(mangle, "b3World_SetHitEventThreshold") void b3World_SetHitEventThresholdD(b3WorldId worldId, float value);
pragma(mangle, "b3World_CastRayClosest") b3RayResult b3World_CastRayClosestD(b3WorldId worldId, b3Pos origin, b3Vec3 translation, b3QueryFilter filter);
pragma(mangle, "b3World_OverlapAABB") b3TreeStats b3World_OverlapAABBD(b3WorldId worldId, b3AABB aabb, b3QueryFilter filter,
    b3OverlapResultFcn* fcn, void* context);
pragma(mangle, "b3World_OverlapShape") b3TreeStats b3World_OverlapShapeD(b3WorldId worldId, b3Pos origin, const(b3ShapeProxy)* proxy,
    b3QueryFilter filter, b3OverlapResultFcn* fcn, void* context);
pragma(mangle, "b3World_CastMover") float b3World_CastMoverD(b3WorldId worldId, b3Pos origin, const(b3Capsule)* mover,
    b3Vec3 translation, b3QueryFilter filter, b3MoverFilterFcn* fcn, void* context);
pragma(mangle, "b3World_CollideMover") void b3World_CollideMoverD(b3WorldId worldId, b3Pos origin, const(b3Capsule)* mover,
    b3QueryFilter filter, b3PlaneResultFcn* fcn, void* context);

pragma(mangle, "b3DefaultBodyDef") b3BodyDef b3DefaultBodyDefD();
pragma(mangle, "b3CreateBody") b3BodyId b3CreateBodyD(b3WorldId worldId, const(b3BodyDef)* def);
pragma(mangle, "b3DestroyBody") void b3DestroyBodyD(b3BodyId bodyId);
pragma(mangle, "b3Body_IsValid") bool b3Body_IsValidD(b3BodyId id);
pragma(mangle, "b3Body_SetUserData") void b3Body_SetUserDataD(b3BodyId bodyId, void* userData);
pragma(mangle, "b3Body_GetUserData") void* b3Body_GetUserDataD(b3BodyId bodyId);
pragma(mangle, "b3Body_GetPosition") b3Pos b3Body_GetPositionD(b3BodyId bodyId);
pragma(mangle, "b3Body_GetRotation") b3Quat b3Body_GetRotationD(b3BodyId bodyId);
pragma(mangle, "b3Body_SetTransform") void b3Body_SetTransformD(b3BodyId bodyId, b3Pos position, b3Quat rotation);
pragma(mangle, "b3Body_GetLocalPoint") b3Vec3 b3Body_GetLocalPointD(b3BodyId bodyId, b3Pos worldPoint);
pragma(mangle, "b3Body_GetLocalVector") b3Vec3 b3Body_GetLocalVectorD(b3BodyId bodyId, b3Vec3 worldVector);
pragma(mangle, "b3Body_GetLinearVelocity") b3Vec3 b3Body_GetLinearVelocityD(b3BodyId bodyId);
pragma(mangle, "b3Body_GetAngularVelocity") b3Vec3 b3Body_GetAngularVelocityD(b3BodyId bodyId);
pragma(mangle, "b3Body_SetLinearVelocity") void b3Body_SetLinearVelocityD(b3BodyId bodyId, b3Vec3 linearVelocity);
pragma(mangle, "b3Body_SetAngularVelocity") void b3Body_SetAngularVelocityD(b3BodyId bodyId, b3Vec3 angularVelocity);
pragma(mangle, "b3Body_ApplyForceToCenter") void b3Body_ApplyForceToCenterD(b3BodyId bodyId, b3Vec3 force, bool wake);
pragma(mangle, "b3Body_ApplyLinearImpulseToCenter") void b3Body_ApplyLinearImpulseToCenterD(b3BodyId bodyId, b3Vec3 impulse, bool wake);
pragma(mangle, "b3Body_SetLinearDamping") void b3Body_SetLinearDampingD(b3BodyId bodyId, float linearDamping);
pragma(mangle, "b3Body_SetAngularDamping") void b3Body_SetAngularDampingD(b3BodyId bodyId, float angularDamping);
pragma(mangle, "b3Body_EnableHitEvents") void b3Body_EnableHitEventsD(b3BodyId bodyId, bool enableHitEvents);
pragma(mangle, "b3Body_GetShapes") int b3Body_GetShapesD(b3BodyId bodyId, b3ShapeId* shapeArray, int capacity);

pragma(mangle, "b3DefaultShapeDef") b3ShapeDef b3DefaultShapeDefD();
pragma(mangle, "b3CreateSphereShape") b3ShapeId b3CreateSphereShapeD(b3BodyId bodyId, const(b3ShapeDef)* def, const(b3Sphere)* sphere);
pragma(mangle, "b3CreateCapsuleShape") b3ShapeId b3CreateCapsuleShapeD(b3BodyId bodyId, const(b3ShapeDef)* def, const(b3Capsule)* capsule);
pragma(mangle, "b3CreateHullShape") b3ShapeId b3CreateHullShapeD(b3BodyId bodyId, const(b3ShapeDef)* def, const(b3HullData)* hull);
/// Mesh is not cloned — `mesh` must remain valid for the shape lifetime. Contacts only on static bodies.
pragma(mangle, "b3CreateMeshShape") b3ShapeId b3CreateMeshShapeD(b3BodyId bodyId, const(b3ShapeDef)* def, const(b3MeshData)* mesh, b3Vec3 scale);
pragma(mangle, "b3Shape_IsValid") bool b3Shape_IsValidD(b3ShapeId id);
pragma(mangle, "b3Shape_GetBody") b3BodyId b3Shape_GetBodyD(b3ShapeId shapeId);
pragma(mangle, "b3Shape_SetRestitution") void b3Shape_SetRestitutionD(b3ShapeId shapeId, float restitution);
pragma(mangle, "b3Shape_GetRestitution") float b3Shape_GetRestitutionD(b3ShapeId shapeId);
pragma(mangle, "b3Shape_EnableHitEvents") void b3Shape_EnableHitEventsD(b3ShapeId shapeId, bool flag);

pragma(mangle, "b3MakeBoxHull") b3BoxHull b3MakeBoxHullD(float hx, float hy, float hz);
pragma(mangle, "b3CreateCylinder") b3HullData* b3CreateCylinderD(float height, float radius, float yOffset, int sides);
pragma(mangle, "b3CreateHull") b3HullData* b3CreateHullD(const(b3Vec3)* points, int pointCount, int maxVertexCount);
pragma(mangle, "b3DestroyHull") void b3DestroyHullD(b3HullData* hull);
pragma(mangle, "b3CreateMesh") b3MeshData* b3CreateMeshD(const(b3MeshDef)* def, int* degenerateTriangleIndices, int degenerateCapacity);
pragma(mangle, "b3DestroyMesh") void b3DestroyMeshD(b3MeshData* mesh);
pragma(mangle, "b3DefaultQueryFilter") b3QueryFilter b3DefaultQueryFilterD();

pragma(mangle, "b3DefaultDistanceJointDef") b3DistanceJointDef b3DefaultDistanceJointDefD();
pragma(mangle, "b3DefaultRevoluteJointDef") b3RevoluteJointDef b3DefaultRevoluteJointDefD();
pragma(mangle, "b3DefaultWeldJointDef") b3WeldJointDef b3DefaultWeldJointDefD();
pragma(mangle, "b3CreateDistanceJoint") b3JointId b3CreateDistanceJointD(b3WorldId worldId, const(b3DistanceJointDef)* def);
pragma(mangle, "b3CreateRevoluteJoint") b3JointId b3CreateRevoluteJointD(b3WorldId worldId, const(b3RevoluteJointDef)* def);
pragma(mangle, "b3CreateWeldJoint") b3JointId b3CreateWeldJointD(b3WorldId worldId, const(b3WeldJointDef)* def);
pragma(mangle, "b3DestroyJoint") void b3DestroyJointD(b3JointId jointId, bool wakeAttached);

pragma(mangle, "b3SolvePlanes") b3PlaneSolverResult b3SolvePlanesD(b3Vec3 targetDelta, b3CollisionPlane* planes, int count);
pragma(mangle, "b3ClipVector") b3Vec3 b3ClipVectorD(b3Vec3 vector, const(b3CollisionPlane)* planes, int count);
pragma(mangle, "b3ComputeQuatBetweenUnitVectors") b3Quat b3ComputeQuatBetweenUnitVectorsD(b3Vec3 from, b3Vec3 to);
