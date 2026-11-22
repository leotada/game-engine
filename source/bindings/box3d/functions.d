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
pragma(mangle, "b3World_GetJointEvents") b3JointEvents b3World_GetJointEventsD(b3WorldId worldId);
pragma(mangle, "b3World_GetAwakeBodyCount") int b3World_GetAwakeBodyCountD(b3WorldId worldId);
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
pragma(mangle, "b3Body_SetType") void b3Body_SetTypeD(b3BodyId bodyId, b3BodyType type);
pragma(mangle, "b3Body_GetType") b3BodyType b3Body_GetTypeD(b3BodyId bodyId);
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
pragma(mangle, "b3Body_ApplyForce") void b3Body_ApplyForceD(b3BodyId bodyId, b3Vec3 force, b3Pos point, bool wake);
pragma(mangle, "b3Body_GetMass") float b3Body_GetMassD(b3BodyId bodyId);
pragma(mangle, "b3Body_ApplyLinearImpulse") void b3Body_ApplyLinearImpulseD(b3BodyId bodyId, b3Vec3 impulse, b3Pos point, bool wake);
pragma(mangle, "b3Body_ApplyLinearImpulseToCenter") void b3Body_ApplyLinearImpulseToCenterD(b3BodyId bodyId, b3Vec3 impulse, bool wake);
pragma(mangle, "b3Body_ApplyAngularImpulse") void b3Body_ApplyAngularImpulseD(b3BodyId bodyId, b3Vec3 impulse, bool wake);
pragma(mangle, "b3Body_ApplyMassFromShapes") void b3Body_ApplyMassFromShapesD(b3BodyId bodyId);
pragma(mangle, "b3Body_SetLinearDamping") void b3Body_SetLinearDampingD(b3BodyId bodyId, float linearDamping);
pragma(mangle, "b3Body_SetAngularDamping") void b3Body_SetAngularDampingD(b3BodyId bodyId, float angularDamping);
pragma(mangle, "b3Body_IsAwake") bool b3Body_IsAwakeD(b3BodyId bodyId);
pragma(mangle, "b3Body_SetAwake") void b3Body_SetAwakeD(b3BodyId bodyId, bool awake);
pragma(mangle, "b3Body_EnableSleep") void b3Body_EnableSleepD(b3BodyId bodyId, bool enableSleep);
pragma(mangle, "b3Body_IsSleepEnabled") bool b3Body_IsSleepEnabledD(b3BodyId bodyId);
pragma(mangle, "b3Body_SetSleepThreshold") void b3Body_SetSleepThresholdD(b3BodyId bodyId, float sleepThreshold);
pragma(mangle, "b3Body_GetSleepThreshold") float b3Body_GetSleepThresholdD(b3BodyId bodyId);
pragma(mangle, "b3Body_SetBullet") void b3Body_SetBulletD(b3BodyId bodyId, bool flag);
pragma(mangle, "b3Body_IsBullet") bool b3Body_IsBulletD(b3BodyId bodyId);
pragma(mangle, "b3Body_EnableHitEvents") void b3Body_EnableHitEventsD(b3BodyId bodyId, bool enableHitEvents);
pragma(mangle, "b3Body_GetShapes") int b3Body_GetShapesD(b3BodyId bodyId, b3ShapeId* shapeArray, int capacity);
pragma(mangle, "b3Body_GetContactData") int b3Body_GetContactDataD(b3BodyId bodyId, b3ContactData* contactData, int capacity);

pragma(mangle, "b3DefaultFilter") b3Filter b3DefaultFilterD();
pragma(mangle, "b3DefaultSurfaceMaterial") b3SurfaceMaterial b3DefaultSurfaceMaterialD();
pragma(mangle, "b3DefaultShapeDef") b3ShapeDef b3DefaultShapeDefD();
pragma(mangle, "b3CreateSphereShape") b3ShapeId b3CreateSphereShapeD(b3BodyId bodyId, const(b3ShapeDef)* def, const(b3Sphere)* sphere);
pragma(mangle, "b3CreateCapsuleShape") b3ShapeId b3CreateCapsuleShapeD(b3BodyId bodyId, const(b3ShapeDef)* def, const(b3Capsule)* capsule);
pragma(mangle, "b3CreateHullShape") b3ShapeId b3CreateHullShapeD(b3BodyId bodyId, const(b3ShapeDef)* def, const(b3HullData)* hull);
/// Mesh is not cloned — `mesh` must remain valid for the shape lifetime. Contacts only on static bodies.
pragma(mangle, "b3CreateMeshShape") b3ShapeId b3CreateMeshShapeD(b3BodyId bodyId, const(b3ShapeDef)* def, const(b3MeshData)* mesh, b3Vec3 scale);
/// HeightField is not cloned — `heightField` must remain valid for the shape lifetime. Static bodies only.
pragma(mangle, "b3CreateHeightFieldShape") b3ShapeId b3CreateHeightFieldShapeD(b3BodyId bodyId, const(b3ShapeDef)* def, const(b3HeightFieldData)* heightField);
pragma(mangle, "b3Shape_IsValid") bool b3Shape_IsValidD(b3ShapeId id);
pragma(mangle, "b3Shape_GetBody") b3BodyId b3Shape_GetBodyD(b3ShapeId shapeId);
pragma(mangle, "b3Shape_GetHeightField") const(b3HeightFieldData)* b3Shape_GetHeightFieldD(b3ShapeId shapeId);
pragma(mangle, "b3Shape_SetRestitution") void b3Shape_SetRestitutionD(b3ShapeId shapeId, float restitution);
pragma(mangle, "b3Shape_GetRestitution") float b3Shape_GetRestitutionD(b3ShapeId shapeId);
pragma(mangle, "b3Shape_SetDensity") void b3Shape_SetDensityD(b3ShapeId shapeId, float density, bool updateBodyMass);
pragma(mangle, "b3Shape_SetSurfaceMaterial") void b3Shape_SetSurfaceMaterialD(b3ShapeId shapeId, b3SurfaceMaterial surfaceMaterial);
pragma(mangle, "b3Shape_GetSurfaceMaterial") b3SurfaceMaterial b3Shape_GetSurfaceMaterialD(b3ShapeId shapeId);
pragma(mangle, "b3Shape_GetMeshMaterialCount") int b3Shape_GetMeshMaterialCountD(b3ShapeId shapeId);
pragma(mangle, "b3Shape_SetMeshMaterial") void b3Shape_SetMeshMaterialD(b3ShapeId shapeId, b3SurfaceMaterial surfaceMaterial, int index);
pragma(mangle, "b3Shape_GetMeshSurfaceMaterial") b3SurfaceMaterial b3Shape_GetMeshSurfaceMaterialD(b3ShapeId shapeId, int index);
pragma(mangle, "b3Shape_GetFilter") b3Filter b3Shape_GetFilterD(b3ShapeId shapeId);
pragma(mangle, "b3Shape_SetFilter") void b3Shape_SetFilterD(b3ShapeId shapeId, b3Filter filter, bool invokeContacts);
pragma(mangle, "b3Shape_EnableHitEvents") void b3Shape_EnableHitEventsD(b3ShapeId shapeId, bool flag);

pragma(mangle, "b3MakeBoxHull") b3BoxHull b3MakeBoxHullD(float hx, float hy, float hz);
pragma(mangle, "b3CreateCylinder") b3HullData* b3CreateCylinderD(float height, float radius, float yOffset, int sides);
pragma(mangle, "b3CreateHull") b3HullData* b3CreateHullD(const(b3Vec3)* points, int pointCount, int maxVertexCount);
pragma(mangle, "b3DestroyHull") void b3DestroyHullD(b3HullData* hull);
pragma(mangle, "b3CreateMesh") b3MeshData* b3CreateMeshD(const(b3MeshDef)* def, int* degenerateTriangleIndices, int degenerateCapacity);
pragma(mangle, "b3DestroyMesh") void b3DestroyMeshD(b3MeshData* mesh);
pragma(mangle, "b3CreateHeightField") b3HeightFieldData* b3CreateHeightFieldD(const(b3HeightFieldDef)* data);
pragma(mangle, "b3DestroyHeightField") void b3DestroyHeightFieldD(b3HeightFieldData* heightField);
pragma(mangle, "b3DefaultQueryFilter") b3QueryFilter b3DefaultQueryFilterD();

pragma(mangle, "b3Contact_IsValid") bool b3Contact_IsValidD(b3ContactId id);
pragma(mangle, "b3Contact_GetData") b3ContactData b3Contact_GetDataD(b3ContactId contactId);

pragma(mangle, "b3DefaultDistanceJointDef") b3DistanceJointDef b3DefaultDistanceJointDefD();
pragma(mangle, "b3DefaultRevoluteJointDef") b3RevoluteJointDef b3DefaultRevoluteJointDefD();
pragma(mangle, "b3DefaultWeldJointDef") b3WeldJointDef b3DefaultWeldJointDefD();
pragma(mangle, "b3DefaultSphericalJointDef") b3SphericalJointDef b3DefaultSphericalJointDefD();
pragma(mangle, "b3DefaultWheelJointDef") b3WheelJointDef b3DefaultWheelJointDefD();
pragma(mangle, "b3DefaultPrismaticJointDef") b3PrismaticJointDef b3DefaultPrismaticJointDefD();
pragma(mangle, "b3DefaultFilterJointDef") b3FilterJointDef b3DefaultFilterJointDefD();
pragma(mangle, "b3CreateDistanceJoint") b3JointId b3CreateDistanceJointD(b3WorldId worldId, const(b3DistanceJointDef)* def);
pragma(mangle, "b3CreateRevoluteJoint") b3JointId b3CreateRevoluteJointD(b3WorldId worldId, const(b3RevoluteJointDef)* def);
pragma(mangle, "b3CreateWeldJoint") b3JointId b3CreateWeldJointD(b3WorldId worldId, const(b3WeldJointDef)* def);
pragma(mangle, "b3CreateSphericalJoint") b3JointId b3CreateSphericalJointD(b3WorldId worldId, const(b3SphericalJointDef)* def);
pragma(mangle, "b3CreateWheelJoint") b3JointId b3CreateWheelJointD(b3WorldId worldId, const(b3WheelJointDef)* def);
pragma(mangle, "b3CreatePrismaticJoint") b3JointId b3CreatePrismaticJointD(b3WorldId worldId, const(b3PrismaticJointDef)* def);
pragma(mangle, "b3CreateFilterJoint") b3JointId b3CreateFilterJointD(b3WorldId worldId, const(b3FilterJointDef)* def);
pragma(mangle, "b3DestroyJoint") void b3DestroyJointD(b3JointId jointId, bool wakeAttached);

pragma(mangle, "b3Joint_IsValid") bool b3Joint_IsValidD(b3JointId id);
pragma(mangle, "b3Joint_GetBodyA") b3BodyId b3Joint_GetBodyAD(b3JointId jointId);
pragma(mangle, "b3Joint_GetBodyB") b3BodyId b3Joint_GetBodyBD(b3JointId jointId);
pragma(mangle, "b3Joint_SetUserData") void b3Joint_SetUserDataD(b3JointId jointId, void* userData);
pragma(mangle, "b3Joint_GetUserData") void* b3Joint_GetUserDataD(b3JointId jointId);
pragma(mangle, "b3Joint_GetConstraintForce") b3Vec3 b3Joint_GetConstraintForceD(b3JointId jointId);
pragma(mangle, "b3Joint_GetConstraintTorque") b3Vec3 b3Joint_GetConstraintTorqueD(b3JointId jointId);
pragma(mangle, "b3Joint_SetForceThreshold") void b3Joint_SetForceThresholdD(b3JointId jointId, float threshold);
pragma(mangle, "b3Joint_GetForceThreshold") float b3Joint_GetForceThresholdD(b3JointId jointId);
pragma(mangle, "b3Joint_SetTorqueThreshold") void b3Joint_SetTorqueThresholdD(b3JointId jointId, float threshold);
pragma(mangle, "b3Joint_GetTorqueThreshold") float b3Joint_GetTorqueThresholdD(b3JointId jointId);

pragma(mangle, "b3RevoluteJoint_EnableSpring") void b3RevoluteJoint_EnableSpringD(b3JointId jointId, bool enableSpring);
pragma(mangle, "b3RevoluteJoint_SetSpringHertz") void b3RevoluteJoint_SetSpringHertzD(b3JointId jointId, float hertz);
pragma(mangle, "b3RevoluteJoint_SetSpringDampingRatio") void b3RevoluteJoint_SetSpringDampingRatioD(b3JointId jointId, float dampingRatio);
pragma(mangle, "b3RevoluteJoint_GetAngle") float b3RevoluteJoint_GetAngleD(b3JointId jointId);
pragma(mangle, "b3RevoluteJoint_EnableLimit") void b3RevoluteJoint_EnableLimitD(b3JointId jointId, bool enableLimit);
pragma(mangle, "b3RevoluteJoint_SetLimits") void b3RevoluteJoint_SetLimitsD(b3JointId jointId, float lowerLimitRadians, float upperLimitRadians);
pragma(mangle, "b3RevoluteJoint_EnableMotor") void b3RevoluteJoint_EnableMotorD(b3JointId jointId, bool enableMotor);
pragma(mangle, "b3RevoluteJoint_SetMotorSpeed") void b3RevoluteJoint_SetMotorSpeedD(b3JointId jointId, float motorSpeed);
pragma(mangle, "b3RevoluteJoint_SetMaxMotorTorque") void b3RevoluteJoint_SetMaxMotorTorqueD(b3JointId jointId, float torque);

pragma(mangle, "b3SphericalJoint_EnableConeLimit") void b3SphericalJoint_EnableConeLimitD(b3JointId jointId, bool enableLimit);
pragma(mangle, "b3SphericalJoint_SetConeLimit") void b3SphericalJoint_SetConeLimitD(b3JointId jointId, float angleRadians);
pragma(mangle, "b3SphericalJoint_EnableTwistLimit") void b3SphericalJoint_EnableTwistLimitD(b3JointId jointId, bool enableLimit);
pragma(mangle, "b3SphericalJoint_SetTwistLimits") void b3SphericalJoint_SetTwistLimitsD(b3JointId jointId, float lowerLimitRadians, float upperLimitRadians);
pragma(mangle, "b3SphericalJoint_EnableSpring") void b3SphericalJoint_EnableSpringD(b3JointId jointId, bool enableSpring);
pragma(mangle, "b3SphericalJoint_SetSpringHertz") void b3SphericalJoint_SetSpringHertzD(b3JointId jointId, float hertz);
pragma(mangle, "b3SphericalJoint_SetSpringDampingRatio") void b3SphericalJoint_SetSpringDampingRatioD(b3JointId jointId, float dampingRatio);
pragma(mangle, "b3SphericalJoint_SetTargetRotation") void b3SphericalJoint_SetTargetRotationD(b3JointId jointId, b3Quat targetRotation);
pragma(mangle, "b3SphericalJoint_EnableMotor") void b3SphericalJoint_EnableMotorD(b3JointId jointId, bool enableMotor);
pragma(mangle, "b3SphericalJoint_SetMotorVelocity") void b3SphericalJoint_SetMotorVelocityD(b3JointId jointId, b3Vec3 motorVelocity);
pragma(mangle, "b3SphericalJoint_SetMaxMotorTorque") void b3SphericalJoint_SetMaxMotorTorqueD(b3JointId jointId, float torque);

pragma(mangle, "b3WeldJoint_SetLinearHertz") void b3WeldJoint_SetLinearHertzD(b3JointId jointId, float hertz);
pragma(mangle, "b3WeldJoint_SetLinearDampingRatio") void b3WeldJoint_SetLinearDampingRatioD(b3JointId jointId, float dampingRatio);
pragma(mangle, "b3WeldJoint_SetAngularHertz") void b3WeldJoint_SetAngularHertzD(b3JointId jointId, float hertz);
pragma(mangle, "b3WeldJoint_SetAngularDampingRatio") void b3WeldJoint_SetAngularDampingRatioD(b3JointId jointId, float dampingRatio);

pragma(mangle, "b3PrismaticJoint_EnableSpring") void b3PrismaticJoint_EnableSpringD(b3JointId jointId, bool enableSpring);
pragma(mangle, "b3PrismaticJoint_SetSpringHertz") void b3PrismaticJoint_SetSpringHertzD(b3JointId jointId, float hertz);
pragma(mangle, "b3PrismaticJoint_SetSpringDampingRatio") void b3PrismaticJoint_SetSpringDampingRatioD(b3JointId jointId, float dampingRatio);
pragma(mangle, "b3PrismaticJoint_EnableLimit") void b3PrismaticJoint_EnableLimitD(b3JointId jointId, bool enableLimit);
pragma(mangle, "b3PrismaticJoint_SetLimits") void b3PrismaticJoint_SetLimitsD(b3JointId jointId, float lower, float upper);
pragma(mangle, "b3PrismaticJoint_EnableMotor") void b3PrismaticJoint_EnableMotorD(b3JointId jointId, bool enableMotor);
pragma(mangle, "b3PrismaticJoint_SetMotorSpeed") void b3PrismaticJoint_SetMotorSpeedD(b3JointId jointId, float motorSpeed);
pragma(mangle, "b3PrismaticJoint_SetMaxMotorForce") void b3PrismaticJoint_SetMaxMotorForceD(b3JointId jointId, float force);

pragma(mangle, "b3WheelJoint_EnableSuspension") void b3WheelJoint_EnableSuspensionD(b3JointId jointId, bool flag);
pragma(mangle, "b3WheelJoint_SetSuspensionHertz") void b3WheelJoint_SetSuspensionHertzD(b3JointId jointId, float hertz);
pragma(mangle, "b3WheelJoint_SetSuspensionDampingRatio") void b3WheelJoint_SetSuspensionDampingRatioD(b3JointId jointId, float dampingRatio);
pragma(mangle, "b3WheelJoint_EnableSuspensionLimit") void b3WheelJoint_EnableSuspensionLimitD(b3JointId jointId, bool flag);
pragma(mangle, "b3WheelJoint_SetSuspensionLimits") void b3WheelJoint_SetSuspensionLimitsD(b3JointId jointId, float lower, float upper);
pragma(mangle, "b3WheelJoint_EnableSpinMotor") void b3WheelJoint_EnableSpinMotorD(b3JointId jointId, bool flag);
pragma(mangle, "b3WheelJoint_SetSpinMotorSpeed") void b3WheelJoint_SetSpinMotorSpeedD(b3JointId jointId, float speed);
pragma(mangle, "b3WheelJoint_SetMaxSpinTorque") void b3WheelJoint_SetMaxSpinTorqueD(b3JointId jointId, float torque);
pragma(mangle, "b3WheelJoint_EnableSteering") void b3WheelJoint_EnableSteeringD(b3JointId jointId, bool flag);
pragma(mangle, "b3WheelJoint_SetSteeringHertz") void b3WheelJoint_SetSteeringHertzD(b3JointId jointId, float hertz);
pragma(mangle, "b3WheelJoint_SetSteeringDampingRatio") void b3WheelJoint_SetSteeringDampingRatioD(b3JointId jointId, float dampingRatio);
pragma(mangle, "b3WheelJoint_SetTargetSteeringAngle") void b3WheelJoint_SetTargetSteeringAngleD(b3JointId jointId, float radians);
pragma(mangle, "b3WheelJoint_EnableSteeringLimit") void b3WheelJoint_EnableSteeringLimitD(b3JointId jointId, bool flag);
pragma(mangle, "b3WheelJoint_SetSteeringLimits") void b3WheelJoint_SetSteeringLimitsD(b3JointId jointId, float lowerRadians, float upperRadians);
pragma(mangle, "b3WheelJoint_SetMaxSteeringTorque") void b3WheelJoint_SetMaxSteeringTorqueD(b3JointId jointId, float torque);

pragma(mangle, "b3SolvePlanes") b3PlaneSolverResult b3SolvePlanesD(b3Vec3 targetDelta, b3CollisionPlane* planes, int count);
pragma(mangle, "b3ClipVector") b3Vec3 b3ClipVectorD(b3Vec3 vector, const(b3CollisionPlane)* planes, int count);
pragma(mangle, "b3ComputeQuatBetweenUnitVectors") b3Quat b3ComputeQuatBetweenUnitVectorsD(b3Vec3 from, b3Vec3 to);
