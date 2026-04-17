// Jolt — Geometry/RayTriangle.h port. Möller–Trumbore intersection.
//
// Source: ref/JoltPhysics/Jolt/Geometry/RayTriangle.h.
module engine.jph.geometry.ray_triangle;

import std.math : fabs;
import engine.jph.math.vec3;

@safe:

/// Returns the hit fraction or FLT_MAX on miss/back-face.
float RayTriangle(Vec3 inOrigin, Vec3 inDirection, Vec3 inV0, Vec3 inV1, Vec3 inV2)
        pure nothrow @nogc {
    enum float kEps = 1.0e-12f;

    immutable Vec3 e1 = inV1 - inV0;
    immutable Vec3 e2 = inV2 - inV0;
    immutable Vec3 p  = inDirection.Cross(e2);
    immutable float det = e1.Dot(p);
    if (fabs(det) < kEps)
        return float.max;
    immutable float invDet = 1.0f / det;

    immutable Vec3 s = inOrigin - inV0;
    immutable float u = s.Dot(p) * invDet;
    if (u < 0.0f || u > 1.0f)
        return float.max;

    immutable Vec3 q = s.Cross(e1);
    immutable float v = inDirection.Dot(q) * invDet;
    if (v < 0.0f || u + v > 1.0f)
        return float.max;

    immutable float t = e2.Dot(q) * invDet;
    if (t < 0.0f)
        return float.max;
    return t;
}

unittest {
    immutable v0 = Vec3(-1, 0, 0);
    immutable v1 = Vec3( 1, 0, 0);
    immutable v2 = Vec3( 0, 1, 0);
    immutable t = RayTriangle(Vec3(0, 0.25f, -2), Vec3(0, 0, 1), v0, v1, v2);
    assert(t > 1.99f && t < 2.01f);

    // Miss (off the triangle)
    assert(RayTriangle(Vec3(5, 5, -2), Vec3(0, 0, 1), v0, v1, v2) == float.max);
}
