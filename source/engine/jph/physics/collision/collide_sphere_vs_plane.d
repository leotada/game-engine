// Jolt — minimal sphere-vs-plane contact generation for the MVP path.
module engine.jph.physics.collision.collide_sphere_vs_plane;

import engine.jph.geometry.plane : Plane;
import engine.jph.math.vec3 : Vec3;
import engine.jph.physics.body.body : Body;
import engine.jph.physics.collision.collide_shape : CollideShapeSettings,
													ContactManifold,
													InitializeContactManifold;
import engine.jph.physics.shape.plane_shape : PlaneShape;
import engine.jph.physics.shape.sphere_shape : SphereShape;

@safe:

bool CollideSphereVsPlane(ref const Body inSphereBody,
						  ref const Body inPlaneBody,
						  CollideShapeSettings inSettings,
						  ref ContactManifold ioManifold) nothrow @nogc {
	auto sphere = cast(const SphereShape) inSphereBody.GetShape();
	auto planeShape = cast(const PlaneShape) inPlaneBody.GetShape();
	if (sphere is null || planeShape is null)
		return false;

	immutable Plane worldPlane = planeShape.GetPlane().GetTransformed(inPlaneBody.GetCenterOfMassTransform());
	immutable Vec3 planeNormal = worldPlane.GetNormal();
	immutable Vec3 sphereCenter = inSphereBody.GetCenterOfMassPosition();
	immutable float sphereRadius = sphere.GetRadius();
	immutable float signedDistance = worldPlane.SignedDistance(sphereCenter);
	immutable float separation = signedDistance - sphereRadius;
	if (separation > inSettings.mMaxSeparationDistance)
		return false;

	InitializeContactManifold(ioManifold,
							  inSphereBody.GetID(),
							  inPlaneBody.GetID(),
							  planeNormal);

	immutable Vec3 pointOnSphere = sphereCenter - planeNormal * sphereRadius;
	immutable Vec3 pointOnPlane = worldPlane.ProjectPointOnPlane(sphereCenter);
	immutable float penetrationDepth = -separation;
	return ioManifold.AddContactPoint(pointOnSphere, pointOnPlane, penetrationDepth);
}

bool CollidePlaneVsSphere(ref const Body inPlaneBody,
						  ref const Body inSphereBody,
						  CollideShapeSettings inSettings,
						  ref ContactManifold ioManifold) nothrow @nogc {
	ContactManifold manifold;
	if (!CollideSphereVsPlane(inSphereBody, inPlaneBody, inSettings, manifold))
		return false;

	ioManifold = manifold.Reversed();
	return true;
}

unittest {
	import engine.jph.geometry.plane : Plane;
	import engine.jph.math.quat : Quat;
	import engine.jph.physics.body.body_creation_settings : BodyCreationSettings;
	import engine.jph.physics.body.bodyid : BodyID;
	import engine.jph.physics.body.motionproperties : MotionProperties;
	import engine.jph.physics.body.motiontype : EMotionType;

	auto motionPool = new MotionProperties[1];

	Body sphereBody;
	Body planeBody;
	BodyCreationSettings sphereSettings = BodyCreationSettings(
		new SphereShape(0.5f),
		Vec3(0, 0.25f, 0),
		Quat.sIdentity(),
		EMotionType.Dynamic);
	BodyCreationSettings planeSettings = BodyCreationSettings(
		new PlaneShape(Plane.sFromPointAndNormal(Vec3.sZero(), Vec3.sAxisY())),
		Vec3.sZero(),
		Quat.sIdentity(),
		EMotionType.Static);

	sphereBody.Initialize(BodyID(1, 1), sphereSettings, 0, &motionPool[0]);
	planeBody.Initialize(BodyID(2, 1), planeSettings, 0, null);

	ContactManifold manifold;
	assert(CollideSphereVsPlane(sphereBody, planeBody, CollideShapeSettings.init, manifold));
	assert(manifold.GetNumContactPoints() == 1);
	assert(manifold.mWorldSpaceNormal == Vec3.sAxisY());
	assert(manifold.GetContactPoint(0).mPenetrationDepth > 0.24f);
	assert(manifold.GetContactPoint(0).mPenetrationDepth < 0.26f);
}
