// Jolt — minimal box-vs-plane contact generation for the MVP path.
module engine.jph.physics.collision.collide_box_vs_plane;

import engine.jph.geometry.plane : Plane;
import engine.jph.math.mat44 : Mat44;
import engine.jph.math.quat : Quat;
import engine.jph.math.vec3 : Vec3;
import engine.jph.physics.body.body : Body;
import engine.jph.physics.body.body_creation_settings : BodyCreationSettings;
import engine.jph.physics.body.bodyid : BodyID;
import engine.jph.physics.body.motionproperties : MotionProperties;
import engine.jph.physics.body.motiontype : EMotionType;
import engine.jph.physics.collision.collide_shape : CollideShapeSettings,
													ContactManifold,
													InitializeContactManifold;
import engine.jph.physics.shape.box_shape : BoxShape;
import engine.jph.physics.shape.plane_shape : PlaneShape;

@safe:

private Vec3 getBoxCorner(Mat44 inTransform,
						  Vec3 inHalfExtent,
						  float inSignX,
						  float inSignY,
						  float inSignZ) nothrow @nogc {
	immutable Vec3 localCorner = Vec3(
		inHalfExtent.GetX() * inSignX,
		inHalfExtent.GetY() * inSignY,
		inHalfExtent.GetZ() * inSignZ);
	return inTransform * localCorner;
}

bool CollideBoxVsPlane(ref const Body inBoxBody,
					   ref const Body inPlaneBody,
					   CollideShapeSettings inSettings,
					   ref ContactManifold ioManifold) nothrow @nogc {
	auto box = cast(const BoxShape) inBoxBody.GetShape();
	auto planeShape = cast(const PlaneShape) inPlaneBody.GetShape();
	if (box is null || planeShape is null)
		return false;

	immutable Plane worldPlane = planeShape.GetPlane().GetTransformed(inPlaneBody.GetCenterOfMassTransform());
	immutable Vec3 planeNormal = worldPlane.GetNormal();
	immutable Mat44 boxTransform = inBoxBody.GetCenterOfMassTransform();
	immutable Vec3 halfExtent = box.GetHalfExtent();

	InitializeContactManifold(ioManifold,
							  inBoxBody.GetID(),
							  inPlaneBody.GetID(),
							  planeNormal);

	foreach (signX; [-1.0f, 1.0f]) {
		foreach (signY; [-1.0f, 1.0f]) {
			foreach (signZ; [-1.0f, 1.0f]) {
				immutable Vec3 corner = getBoxCorner(boxTransform, halfExtent, signX, signY, signZ);
				immutable float separation = worldPlane.SignedDistance(corner);
				if (separation > inSettings.mMaxSeparationDistance)
					continue;

				immutable Vec3 pointOnPlane = worldPlane.ProjectPointOnPlane(corner);
				if (!ioManifold.AddContactPoint(corner, pointOnPlane, -separation))
					return true;
			}
		}
	}

	return !ioManifold.IsEmpty();
}

bool CollidePlaneVsBox(ref const Body inPlaneBody,
					   ref const Body inBoxBody,
					   CollideShapeSettings inSettings,
					   ref ContactManifold ioManifold) nothrow @nogc {
	ContactManifold manifold;
	if (!CollideBoxVsPlane(inBoxBody, inPlaneBody, inSettings, manifold))
		return false;

	ioManifold = manifold.Reversed();
	return true;
}

unittest {
	auto motionPool = new MotionProperties[1];

	Body boxBody;
	Body planeBody;
	BodyCreationSettings boxSettings = BodyCreationSettings(
		new BoxShape(Vec3(0.5f, 0.5f, 0.5f)),
		Vec3(0, 0.25f, 0),
		Quat.sIdentity(),
		EMotionType.Dynamic);
	BodyCreationSettings planeSettings = BodyCreationSettings(
		new PlaneShape(Plane.sFromPointAndNormal(Vec3.sZero(), Vec3.sAxisY())),
		Vec3.sZero(),
		Quat.sIdentity(),
		EMotionType.Static);

	boxBody.Initialize(BodyID(1, 1), boxSettings, 0, &motionPool[0]);
	planeBody.Initialize(BodyID(2, 1), planeSettings, 0, null);

	ContactManifold manifold;
	assert(CollideBoxVsPlane(boxBody, planeBody, CollideShapeSettings.init, manifold));
	assert(manifold.GetNumContactPoints() == 4);
	assert(manifold.mWorldSpaceNormal == Vec3.sAxisY());
	assert(manifold.GetContactPoint(0).mPenetrationDepth > 0.24f);
	assert(manifold.GetContactPoint(0).mPenetrationDepth < 0.26f);
}
