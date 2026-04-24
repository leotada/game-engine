// Jolt — minimal box-vs-box contact generation for the benchmark path.
module engine.jph.physics.collision.collide_box_vs_box;

import engine.jph.geometry.aabox : AABox;
import engine.jph.geometry.convexsupport : AddConvexRadius, TransformedConvexObject;
import engine.jph.geometry.epa : EPAPenetrationDepth;
import engine.jph.geometry.orientedbox : OrientedBox;
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

@safe:

private Vec3 reduceHalfExtent(Vec3 inHalfExtent, float inConvexRadius) pure nothrow @nogc {
    immutable Vec3 radius = Vec3.sReplicate(inConvexRadius);
    return Vec3.sMax(inHalfExtent - radius, Vec3.sZero());
}

bool CollideBoxVsBox(ref const Body inBody1,
                     ref const Body inBody2,
                     CollideShapeSettings inSettings,
                     ref ContactManifold ioManifold) nothrow @nogc {
    auto box1 = cast(const BoxShape) inBody1.GetShape();
    auto box2 = cast(const BoxShape) inBody2.GetShape();
    if (box1 is null || box2 is null)
        return false;

    immutable Vec3 halfExtent1 = box1.GetHalfExtent();
    immutable Vec3 halfExtent2 = box2.GetHalfExtent();
    immutable Mat44 transform1 = inBody1.GetCenterOfMassTransform();
    immutable Mat44 transform2 = inBody2.GetCenterOfMassTransform();

    immutable OrientedBox oriented1 = OrientedBox(transform1, halfExtent1);
    immutable OrientedBox oriented2 = OrientedBox(transform2, halfExtent2);
    if (!oriented1.Overlaps(oriented2))
        return false;

    immutable float convexRadius1 = box1.GetConvexRadius();
    immutable float convexRadius2 = box2.GetConvexRadius();
    immutable AABox localBox1 = AABox.sFromTwoPoints(-reduceHalfExtent(halfExtent1, convexRadius1),
                                                     reduceHalfExtent(halfExtent1, convexRadius1));
    immutable AABox localBox2 = AABox.sFromTwoPoints(-reduceHalfExtent(halfExtent2, convexRadius2),
                                                     reduceHalfExtent(halfExtent2, convexRadius2));

    auto box1WithRadius = AddConvexRadius!AABox(localBox1, convexRadius1);
    auto box2WithRadius = AddConvexRadius!AABox(localBox2, convexRadius2);
    auto box1Excl = TransformedConvexObject!AABox(transform1, localBox1);
    auto box2Excl = TransformedConvexObject!AABox(transform2, localBox2);
    auto box1Incl = TransformedConvexObject!(AddConvexRadius!AABox)(transform1, box1WithRadius);
    auto box2Incl = TransformedConvexObject!(AddConvexRadius!AABox)(transform2, box2WithRadius);

    EPAPenetrationDepth epa;
    Vec3 separatingAxis = inBody1.GetCenterOfMassPosition() - inBody2.GetCenterOfMassPosition();
    if (separatingAxis.IsNearZero())
        separatingAxis = Vec3.sAxisY();

    Vec3 pointOn1;
    Vec3 pointOn2;
    if (!epa.GetPenetrationDepth(box1Excl, box1Incl, convexRadius1,
                                 box2Excl, box2Incl, convexRadius2,
                                 inSettings.mCollisionTolerance,
                                 inSettings.mPenetrationTolerance,
                                 separatingAxis,
                                 pointOn1,
                                 pointOn2))
        return false;

    immutable Vec3 centerDelta = inBody1.GetCenterOfMassPosition() - inBody2.GetCenterOfMassPosition();
    immutable Vec3 delta = pointOn1 - pointOn2;
    immutable Vec3 normal = centerDelta.NormalizedOr(delta.NormalizedOr(Vec3.sAxisY()));
    float penetrationDepth = delta.Dot(normal);
    if (penetrationDepth < 0.0f)
        penetrationDepth = -penetrationDepth;
    if (penetrationDepth <= inSettings.mPenetrationTolerance)
        penetrationDepth = delta.Length();
    if (penetrationDepth <= inSettings.mPenetrationTolerance)
        return false;

    InitializeContactManifold(ioManifold,
                              inBody1.GetID(),
                              inBody2.GetID(),
                              normal);
    return ioManifold.AddContactPoint(pointOn1, pointOn2, penetrationDepth);
}

unittest {
    auto motionPool = new MotionProperties[1];

    Body body1;
    Body body2;
    BodyCreationSettings settings1 = BodyCreationSettings(
        new BoxShape(Vec3(0.5f, 0.5f, 0.5f)),
        Vec3(0.0f, 0.9f, 0.0f),
        Quat.sIdentity(),
        EMotionType.Dynamic);
    BodyCreationSettings settings2 = BodyCreationSettings(
        new BoxShape(Vec3(1.0f, 0.5f, 1.0f)),
        Vec3(0.0f, 0.0f, 0.0f),
        Quat.sIdentity(),
        EMotionType.Static);

    body1.Initialize(BodyID(1, 1), settings1, 0, &motionPool[0]);
    body2.Initialize(BodyID(2, 1), settings2, 0, null);

    ContactManifold manifold;
    assert(CollideBoxVsBox(body1, body2, CollideShapeSettings.init, manifold));
    assert(manifold.GetNumContactPoints() == 1);
    assert(manifold.mWorldSpaceNormal.GetY() > 0.5f);
    assert(manifold.GetContactPoint(0).mPenetrationDepth > 0.05f);
}