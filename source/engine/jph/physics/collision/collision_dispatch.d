// Jolt — minimal collision dispatch for the MVP contact path.
module engine.jph.physics.collision.collision_dispatch;

import engine.jph.physics.body.body : Body;
import engine.jph.physics.collision.collide_box_vs_box : CollideBoxVsBox;
import engine.jph.physics.collision.collide_box_vs_plane : CollideBoxVsPlane,
														   CollidePlaneVsBox;
import engine.jph.physics.collision.collide_capsule_vs_plane : CollideCapsuleVsPlane,
																CollidePlaneVsCapsule;
import engine.jph.physics.collision.collide_shape : CollideShapeSettings, ContactManifold;
import engine.jph.physics.collision.collide_sphere_vs_plane : CollidePlaneVsSphere,
															  CollideSphereVsPlane;
import engine.jph.physics.shape.shape : EShapeSubType;

@safe:

bool CollideBodies(ref const Body inBody1,
				   ref const Body inBody2,
				   CollideShapeSettings inSettings,
				   ref ContactManifold ioManifold) nothrow @nogc {
	auto shape1 = inBody1.GetShape();
	auto shape2 = inBody2.GetShape();
	if (shape1 is null || shape2 is null)
		return false;

	immutable subType1 = shape1.GetSubType();
	immutable subType2 = shape2.GetSubType();

	if (subType1 == EShapeSubType.Sphere && subType2 == EShapeSubType.Plane)
		return CollideSphereVsPlane(inBody1, inBody2, inSettings, ioManifold);

	if (subType1 == EShapeSubType.Plane && subType2 == EShapeSubType.Sphere)
		return CollidePlaneVsSphere(inBody1, inBody2, inSettings, ioManifold);

	if (subType1 == EShapeSubType.Box && subType2 == EShapeSubType.Plane)
		return CollideBoxVsPlane(inBody1, inBody2, inSettings, ioManifold);

	if (subType1 == EShapeSubType.Box && subType2 == EShapeSubType.Box)
		return CollideBoxVsBox(inBody1, inBody2, inSettings, ioManifold);

	if (subType1 == EShapeSubType.Plane && subType2 == EShapeSubType.Box)
		return CollidePlaneVsBox(inBody1, inBody2, inSettings, ioManifold);

	if (subType1 == EShapeSubType.Capsule && subType2 == EShapeSubType.Plane)
		return CollideCapsuleVsPlane(inBody1, inBody2, inSettings, ioManifold);

	if (subType1 == EShapeSubType.Plane && subType2 == EShapeSubType.Capsule)
		return CollidePlaneVsCapsule(inBody1, inBody2, inSettings, ioManifold);

	return false;
}
