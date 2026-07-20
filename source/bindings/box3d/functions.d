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

pragma(mangle, "b3DefaultBodyDef") b3BodyDef b3DefaultBodyDefD();
pragma(mangle, "b3CreateBody") b3BodyId b3CreateBodyD(b3WorldId worldId, const(b3BodyDef)* def);
pragma(mangle, "b3DestroyBody") void b3DestroyBodyD(b3BodyId bodyId);
pragma(mangle, "b3Body_IsValid") bool b3Body_IsValidD(b3BodyId id);
pragma(mangle, "b3Body_SetUserData") void b3Body_SetUserDataD(b3BodyId bodyId, void* userData);
pragma(mangle, "b3Body_GetUserData") void* b3Body_GetUserDataD(b3BodyId bodyId);
pragma(mangle, "b3Body_GetPosition") b3Pos b3Body_GetPositionD(b3BodyId bodyId);
pragma(mangle, "b3Body_GetRotation") b3Quat b3Body_GetRotationD(b3BodyId bodyId);
pragma(mangle, "b3Body_SetTransform") void b3Body_SetTransformD(b3BodyId bodyId, b3Pos position, b3Quat rotation);
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
pragma(mangle, "b3CreateHullShape") b3ShapeId b3CreateHullShapeD(b3BodyId bodyId, const(b3ShapeDef)* def, const(b3HullData)* hull);
pragma(mangle, "b3Shape_IsValid") bool b3Shape_IsValidD(b3ShapeId id);
pragma(mangle, "b3Shape_GetBody") b3BodyId b3Shape_GetBodyD(b3ShapeId shapeId);
pragma(mangle, "b3Shape_SetRestitution") void b3Shape_SetRestitutionD(b3ShapeId shapeId, float restitution);
pragma(mangle, "b3Shape_GetRestitution") float b3Shape_GetRestitutionD(b3ShapeId shapeId);
pragma(mangle, "b3Shape_EnableHitEvents") void b3Shape_EnableHitEventsD(b3ShapeId shapeId, bool flag);

pragma(mangle, "b3MakeBoxHull") b3BoxHull b3MakeBoxHullD(float hx, float hy, float hz);
pragma(mangle, "b3DefaultQueryFilter") b3QueryFilter b3DefaultQueryFilterD();
