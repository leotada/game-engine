// Jolt — Geometry/RayCapsule.h port. Capsule axis along Y, centered at origin.
//
// Source: ref/JoltPhysics/Jolt/Geometry/RayCapsule.h.
module engine.jph.geometry.ray_capsule;

import std.math : fabs;
import engine.jph.math.vec3;
import engine.jph.geometry.ray_cylinder : RayCylinder;
import engine.jph.geometry.ray_sphere   : RaySphere;

@safe:

/// Capsule along Y. inHalfHeight = distance from origin to top sphere center.
float RayCapsule(Vec3 inRayOrigin, Vec3 inRayDirection, float inHalfHeight, float inRadius)
        pure nothrow @nogc {
    immutable float cyl = RayCylinder(inRayOrigin, inRayDirection, inRadius);
    if (cyl == float.max)
        return float.max;

    if (fabs(inRayOrigin.GetY() + cyl * inRayDirection.GetY()) <= inHalfHeight)
        return cyl;

    immutable Vec3 top = Vec3(0, inHalfHeight, 0);
    immutable float upper = RaySphere(inRayOrigin, inRayDirection,  top, inRadius);
    immutable float lower = RaySphere(inRayOrigin, inRayDirection, -top, inRadius);
    return upper < lower ? upper : lower;
}

unittest {
    // Capsule h=1, r=0.5; ray along +X at y=0 hits at x = -0.5.
    immutable t = RayCapsule(Vec3(-3, 0, 0), Vec3(1, 0, 0), 1.0f, 0.5f);
    assert(t > 2.49f && t < 2.51f);

    // Hit upper hemisphere from above.
    immutable t2 = RayCapsule(Vec3(0, 5, 0), Vec3(0, -1, 0), 1.0f, 0.5f);
    assert(t2 > 3.49f && t2 < 3.51f);
}
