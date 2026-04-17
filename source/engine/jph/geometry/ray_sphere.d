// Jolt — Geometry/RaySphere.h port. Standard quadratic ray-sphere test.
//
// Source: ref/JoltPhysics/Jolt/Geometry/RaySphere.h.
module engine.jph.geometry.ray_sphere;

import engine.jph.math.vec3;
import engine.jph.math.findroot : FindRoot;

@safe:

/// Returns the entry fraction (0 if origin is inside) or FLT_MAX on miss.
float RaySphere(Vec3 inRayOrigin, Vec3 inRayDirection, Vec3 inSphereCenter, float inSphereRadius)
        pure nothrow @nogc {
    immutable Vec3 co = inRayOrigin - inSphereCenter;
    immutable float a = inRayDirection.LengthSq();
    immutable float b = 2.0f * inRayDirection.Dot(co);
    immutable float c = co.LengthSq() - inSphereRadius * inSphereRadius;
    float f1, f2;
    immutable n = FindRoot!float(a, b, c, f1, f2);
    if (n == 0)
        return c <= 0.0f ? 0.0f : float.max;
    if (f1 > f2) { immutable t = f1; f1 = f2; f2 = t; }
    if (f1 >= 0.0f) return f1;     // sphere ahead of ray start
    if (f2 >= 0.0f) return 0.0f;   // origin inside sphere
    return float.max;
}

/// Two-fraction variant. Returns 0/1/2 hits and writes the interval into the
/// output references when applicable.
int RaySphere(Vec3 inRayOrigin, Vec3 inRayDirection, Vec3 inSphereCenter, float inSphereRadius,
              ref float outMinFraction, ref float outMaxFraction) pure nothrow @nogc {
    immutable Vec3 co = inRayOrigin - inSphereCenter;
    immutable float a = inRayDirection.LengthSq();
    immutable float b = 2.0f * inRayDirection.Dot(co);
    immutable float c = co.LengthSq() - inSphereRadius * inSphereRadius;
    float f1, f2;
    immutable n = FindRoot!float(a, b, c, f1, f2);
    final switch (n) {
        case 0:
            if (c <= 0.0f) {
                outMinFraction = outMaxFraction = 0.0f;
                return 1;
            }
            return 0;
        case 1:
            outMinFraction = outMaxFraction = f1;
            return 1;
        case 2:
            if (f1 > f2) { immutable t = f1; f1 = f2; f2 = t; }
            outMinFraction = f1;
            outMaxFraction = f2;
            return 2;
    }
}

unittest {
    immutable t = RaySphere(Vec3(-5, 0, 0), Vec3(1, 0, 0), Vec3(0, 0, 0), 1.0f);
    assert(t > 3.99f && t < 4.01f);

    // Miss
    assert(RaySphere(Vec3(-5, 5, 0), Vec3(1, 0, 0), Vec3(0, 0, 0), 1.0f) == float.max);

    // Origin inside
    assert(RaySphere(Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 0, 0), 1.0f) == 0.0f);
}
