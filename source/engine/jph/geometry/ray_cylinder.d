// Jolt — Geometry/RayCylinder.h port. Ray vs infinite cylinder along Y, plus
// the finite (cap-tested) variant.
//
// Source: ref/JoltPhysics/Jolt/Geometry/RayCylinder.h.
module engine.jph.geometry.ray_cylinder;

import std.math : fabs;
import engine.jph.math.vec3;
import engine.jph.math.scalar : Square;
import engine.jph.math.findroot : FindRoot;

@safe:

/// Infinite cylinder along the Y axis.
float RayCylinder(Vec3 inRayOrigin, Vec3 inRayDirection, float inCylinderRadius)
        pure nothrow @nogc {
    immutable float ox = inRayOrigin.GetX();
    immutable float oz = inRayOrigin.GetZ();
    immutable float dx = inRayDirection.GetX();
    immutable float dz = inRayDirection.GetZ();
    immutable float oxz_sq = ox * ox + oz * oz;
    immutable float r_sq = Square(inCylinderRadius);

    if (oxz_sq > r_sq) {
        // Solve |o_xz + t*d_xz|^2 = r^2.
        immutable float a = dx * dx + dz * dz;
        immutable float b = 2.0f * (ox * dx + oz * dz);
        immutable float c = oxz_sq - r_sq;
        float f1, f2;
        if (FindRoot!float(a, b, c, f1, f2) == 0)
            return float.max;
        immutable float f = f1 < f2 ? f1 : f2;
        if (f >= 0.0f)
            return f;
        return float.max;
    }
    // Origin inside the infinite cylinder.
    return 0.0f;
}

/// Finite cylinder centered at origin, axis Y, half-height inCylinderHalfHeight.
float RayCylinder(Vec3 inRayOrigin, Vec3 inRayDirection, float inCylinderHalfHeight,
                  float inCylinderRadius) pure nothrow @nogc {
    immutable float fraction = RayCylinder(inRayOrigin, inRayDirection, inCylinderRadius);
    if (fraction == float.max)
        return float.max;

    if (fabs(inRayOrigin.GetY() + fraction * inRayDirection.GetY()) <= inCylinderHalfHeight)
        return fraction;

    immutable float dy = inRayDirection.GetY();
    if (dy != 0.0f) {
        immutable float oy = inRayOrigin.GetY();
        immutable float pf = (dy < 0.0f)
                ?  (inCylinderHalfHeight - oy) / dy
                : -(inCylinderHalfHeight + oy) / dy;
        if (pf >= 0.0f) {
            immutable Vec3 pt = inRayOrigin + pf * inRayDirection;
            immutable float dsq = Square(pt.GetX()) + Square(pt.GetZ());
            if (dsq <= Square(inCylinderRadius))
                return pf;
        }
    }
    return float.max;
}

unittest {
    // Ray along +X hits cylinder of radius 1 at x=-1.
    immutable t = RayCylinder(Vec3(-3, 0, 0), Vec3(1, 0, 0), 1.0f);
    assert(t > 1.99f && t < 2.01f);

    // Finite cylinder cap hit (ray pointing down).
    immutable t2 = RayCylinder(Vec3(0, 5, 0), Vec3(0, -1, 0), 1.0f, 1.0f);
    assert(t2 > 3.99f && t2 < 4.01f);
}
