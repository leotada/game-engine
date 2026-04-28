// Jolt — minimal sphere-vs-box contact generation for the MVP path.
module engine.jph.physics.collision.collide_sphere_vs_box;

import std.math : fabs, sqrt;
import engine.jph.math.vec3 : Vec3;
import engine.jph.math.mat44 : Mat44;
import engine.jph.physics.body.body : Body;
import engine.jph.physics.collision.collide_shape : CollideShapeSettings,
                                                    ContactManifold,
                                                    InitializeContactManifold;
import engine.jph.physics.shape.box_shape : BoxShape;
import engine.jph.physics.shape.sphere_shape : SphereShape;

@safe:

private float fmin(float a, float b) pure nothrow @nogc { return a < b ? a : b; }
private float fmax(float a, float b) pure nothrow @nogc { return a > b ? a : b; }

bool CollideSphereVsBox(ref const Body inSphereBody,
                        ref const Body inBoxBody,
                        CollideShapeSettings inSettings,
                        ref ContactManifold ioManifold) nothrow @nogc {
    auto sphere = cast(const SphereShape) inSphereBody.GetShape();
    auto box = cast(const BoxShape) inBoxBody.GetShape();
    if (sphere is null || box is null)
        return false;

    immutable Vec3 sphereCenterWorld = inSphereBody.GetCenterOfMassPosition();
    immutable float sphereRadius = sphere.GetRadius();

    immutable Mat44 boxTransform = inBoxBody.GetCenterOfMassTransform();
    immutable Vec3 boxHalfExtent = box.GetHalfExtent();
    immutable float boxConvexRadius = box.GetConvexRadius();

    // Box outer bounds are boxHalfExtent. Inner bounds are boxHalfExtent - boxConvexRadius.
    // The physics shape is the inner AABB minkowski summed with a sphere of boxConvexRadius.
    immutable Vec3 innerHalfExtent = Vec3.sMax(boxHalfExtent - Vec3.sReplicate(boxConvexRadius), Vec3.sZero());

    // Sphere center relative to Box's frame.
    immutable Mat44 boxInv = boxTransform.InversedRotationTranslation();
    immutable Vec3 sphereCenterLocal = boxInv * sphereCenterWorld;

    // Find closest point on the inner AABB to the sphere center.
    immutable Vec3 closestInnerLocal = Vec3(
        fmin(fmax(sphereCenterLocal.GetX(), -innerHalfExtent.GetX()), innerHalfExtent.GetX()),
        fmin(fmax(sphereCenterLocal.GetY(), -innerHalfExtent.GetY()), innerHalfExtent.GetY()),
        fmin(fmax(sphereCenterLocal.GetZ(), -innerHalfExtent.GetZ()), innerHalfExtent.GetZ())
    );

    // Vector from closest point to sphere center
    immutable Vec3 distVecLocal = sphereCenterLocal - closestInnerLocal;
    immutable float distSq = distVecLocal.LengthSq();
    immutable float collisionRadius = sphereRadius + boxConvexRadius;

    if (distSq > collisionRadius * collisionRadius + inSettings.mMaxSeparationDistance)
        return false; // Separated

    Vec3 normalLocal;
    float penetrationDepth;

    if (distSq > 1.0e-12f) {
        // Outside or on boundary of inner AABB.
        immutable float dist = sqrt(distSq);
        normalLocal = distVecLocal / dist;
        penetrationDepth = collisionRadius - dist;
    } else {
        // Deep penetration: sphere center is inside the inner AABB.
        // Find the closest face of the inner AABB.
        immutable float dx = innerHalfExtent.GetX() - fabs(sphereCenterLocal.GetX());
        immutable float dy = innerHalfExtent.GetY() - fabs(sphereCenterLocal.GetY());
        immutable float dz = innerHalfExtent.GetZ() - fabs(sphereCenterLocal.GetZ());

        if (dx <= dy && dx <= dz) {
            normalLocal = sphereCenterLocal.GetX() > 0 ? Vec3.sAxisX() : -Vec3.sAxisX();
            penetrationDepth = collisionRadius + dx;
        } else if (dy <= dz) {
            normalLocal = sphereCenterLocal.GetY() > 0 ? Vec3.sAxisY() : -Vec3.sAxisY();
            penetrationDepth = collisionRadius + dy;
        } else {
            normalLocal = sphereCenterLocal.GetZ() > 0 ? Vec3.sAxisZ() : -Vec3.sAxisZ();
            penetrationDepth = collisionRadius + dz;
        }
    }

    if (penetrationDepth < -inSettings.mPenetrationTolerance)
        return false;

    // Normal points from body2 (Box) toward body1 (Sphere)
    immutable Vec3 normalWorld = boxTransform.Multiply3x3(normalLocal);

    InitializeContactManifold(ioManifold,
                              inSphereBody.GetID(),
                              inBoxBody.GetID(),
                              normalWorld);

    immutable Vec3 pointOnSphere = sphereCenterWorld - normalWorld * sphereRadius;
    immutable Vec3 pointOnBox = pointOnSphere - normalWorld * penetrationDepth;

    return ioManifold.AddContactPoint(pointOnSphere, pointOnBox, penetrationDepth);
}

bool CollideBoxVsSphere(ref const Body inBoxBody,
                        ref const Body inSphereBody,
                        CollideShapeSettings inSettings,
                        ref ContactManifold ioManifold) nothrow @nogc {
    ContactManifold manifold;
    if (!CollideSphereVsBox(inSphereBody, inBoxBody, inSettings, manifold))
        return false;

    ioManifold = manifold.Reversed();
    return true;
}