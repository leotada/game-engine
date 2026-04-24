// Analytic capsule-vs-plane contact generation.
//
// A capsule is modelled as two sphere-endpoints at the top and bottom of its
// cylindrical segment. For each endpoint we run the same signed-distance test
// as CollideSphereVsPlane, then clamp the contact manifold to ≤4 points via
// ContactManifold.AddContactPoint (which already does the reduction).
module engine.jph.physics.collision.collide_capsule_vs_plane;

import engine.jph.geometry.plane : Plane;
import engine.jph.math.mat44 : Mat44;
import engine.jph.math.vec3 : Vec3;
import engine.jph.physics.body.body : Body;
import engine.jph.physics.collision.collide_shape : CollideShapeSettings,
													ContactManifold,
													InitializeContactManifold;
import engine.jph.physics.shape.capsule_shape : CapsuleShape;
import engine.jph.physics.shape.plane_shape : PlaneShape;

@safe:

bool CollideCapsuleVsPlane(ref const Body inCapsuleBody,
						   ref const Body inPlaneBody,
						   CollideShapeSettings inSettings,
						   ref ContactManifold ioManifold) nothrow @nogc {
	auto capsule = cast(const CapsuleShape) inCapsuleBody.GetShape();
	auto planeShape = cast(const PlaneShape) inPlaneBody.GetShape();
	if (capsule is null || planeShape is null)
		return false;

	immutable Plane worldPlane = planeShape.GetPlane().GetTransformed(inPlaneBody.GetCenterOfMassTransform());
	immutable Vec3 planeNormal = worldPlane.GetNormal();
	immutable float radius     = capsule.GetRadius();
	immutable float halfH      = capsule.GetHalfHeightOfCylinder();

	// Capsule endpoints in world space (CoM is the geometric centre).
	immutable Mat44 transform = inCapsuleBody.GetCenterOfMassTransform();
	immutable Vec3 endpointTop = transform * Vec3(0.0f,  halfH, 0.0f);
	immutable Vec3 endpointBot = transform * Vec3(0.0f, -halfH, 0.0f);

	InitializeContactManifold(ioManifold,
							  inCapsuleBody.GetID(),
							  inPlaneBody.GetID(),
							  planeNormal);

	bool any = false;
	foreach (endpoint; [endpointTop, endpointBot]) {
		immutable float signedDist = worldPlane.SignedDistance(endpoint);
		immutable float separation = signedDist - radius;
		if (separation > inSettings.mMaxSeparationDistance)
			continue;

		immutable Vec3 pointOnCapsule = endpoint - planeNormal * radius;
		immutable Vec3 pointOnPlane   = worldPlane.ProjectPointOnPlane(endpoint);
		immutable float penetration   = -separation; // positive when overlapping
		if (ioManifold.AddContactPoint(pointOnCapsule, pointOnPlane, penetration))
			any = true;
		else
			break; // manifold is full
	}

	return any;
}

bool CollidePlaneVsCapsule(ref const Body inPlaneBody,
						   ref const Body inCapsuleBody,
						   CollideShapeSettings inSettings,
						   ref ContactManifold ioManifold) nothrow @nogc {
	ContactManifold manifold;
	if (!CollideCapsuleVsPlane(inCapsuleBody, inPlaneBody, inSettings, manifold))
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
	import engine.jph.physics.collision.collide_shape : CollideShapeSettings;

	auto motionPool = new MotionProperties[1];

	// Upright capsule: CoM at (0, 0.8, 0), radius=0.3, halfH=0.5
	// Endpoints at y = 0.8 ± 0.5 → top=1.3, bot=0.3
	// Floor at y=0. bot endpoint at y=0.3: separation = 0.3 - 0.3 = 0.0 → touching.
	Body capsuleBody;
	Body planeBody;
	BodyCreationSettings capsuleSettings = BodyCreationSettings(
		new CapsuleShape(0.5f, 0.3f),
		Vec3(0.0f, 0.8f, 0.0f),
		Quat.sIdentity(),
		EMotionType.Dynamic);
	BodyCreationSettings planeSettings = BodyCreationSettings(
		new PlaneShape(Plane.sFromPointAndNormal(Vec3.sZero(), Vec3.sAxisY())),
		Vec3.sZero(),
		Quat.sIdentity(),
		EMotionType.Static);

	capsuleBody.Initialize(BodyID(1, 1), capsuleSettings, 0, &motionPool[0]);
	planeBody.Initialize(BodyID(2, 1), planeSettings, 0, null);

	ContactManifold manifold;
	CollideShapeSettings settings;
	// At exact contact (separation == 0) the default max separation distance
	// (1e-4) is positive so it should be included.
	bool hit = CollideCapsuleVsPlane(capsuleBody, planeBody, settings, manifold);
	assert(hit, "capsule touching plane should generate a contact");
	assert(manifold.GetNumContactPoints() >= 1);

	// Reversed variant must produce a mirrored manifold.
	ContactManifold reversed;
	bool hitRev = CollidePlaneVsCapsule(planeBody, capsuleBody, settings, reversed);
	assert(hitRev, "reversed must also hit");
	assert(reversed.mBody1ID == planeBody.GetID());
	assert(reversed.mBody2ID == capsuleBody.GetID());
}
