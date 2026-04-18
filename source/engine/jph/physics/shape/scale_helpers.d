// Jolt — Physics/Collision/Shape/ScaleHelpers.h port.
//
// Free functions used by Shape implementations to validate, sanitise and
// transform the per-shape `Vec3 mScale` vector. The Jolt original lives
// inside a `namespace ScaleHelpers`; in D we expose the same surface as
// free functions in this module.
//
// Source: ref/JoltPhysics/Jolt/Physics/Collision/Shape/ScaleHelpers.h.
module engine.jph.physics.shape.scale_helpers;

import std.math : fabs;
import engine.jph.math.vec3;
import engine.jph.math.quat;
import engine.jph.math.mat44;

@safe:

/// Minimum valid scale value. Avoids divide-by-zero when scaling shapes.
enum float cMinScale         = 1.0e-6f;
/// Tolerance used to compare scale components.
enum float cScaleToleranceSq = 1.0e-8f;

/// True if `inScale` is (1, 1, 1) within `cScaleToleranceSq`.
bool IsNotScaled(Vec3 inScale) pure nothrow @nogc {
    return inScale.IsClose(Vec3.sOne(), cScaleToleranceSq);
}

/// True if all three components are equal within `cScaleToleranceSq`.
bool IsUniformScale(Vec3 inScale) pure nothrow @nogc {
    immutable float x = inScale.GetX();
    immutable float y = inScale.GetY();
    immutable float z = inScale.GetZ();
    immutable float dxy = x - y;
    immutable float dyz = y - z;
    return dxy * dxy <= cScaleToleranceSq && dyz * dyz <= cScaleToleranceSq;
}

/// True if X and Z components are equal within `cScaleToleranceSq`.
bool IsUniformScaleXZ(Vec3 inScale) pure nothrow @nogc {
    immutable float dx = inScale.GetX() - inScale.GetZ();
    return dx * dx <= cScaleToleranceSq;
}

/// True if an odd number of components are negative — flipping winding.
bool IsInsideOut(Vec3 inScale) pure nothrow @nogc {
    int neg = 0;
    if (inScale.GetX() < 0.0f) ++neg;
    if (inScale.GetY() < 0.0f) ++neg;
    if (inScale.GetZ() < 0.0f) ++neg;
    return (neg & 1) != 0;
}

/// True if any |component| is below `cMinScale`.
bool IsZeroScale(Vec3 inScale) pure nothrow @nogc {
    return fabs(inScale.GetX()) < cMinScale
        || fabs(inScale.GetY()) < cMinScale
        || fabs(inScale.GetZ()) < cMinScale;
}

/// Scale convex radius by the smallest |component| of `inScale`, clamped to
/// `inDefaultConvexRadius` (0.05 mm in Jolt).
float ScaleConvexRadius(float inConvexRadius, Vec3 inScale,
                        float inDefaultConvexRadius = 0.05f) pure nothrow @nogc {
    immutable float s = inScale.Abs().ReduceMin();
    immutable float r = inConvexRadius * s;
    return r < inDefaultConvexRadius ? r : inDefaultConvexRadius;
}

/// Replace any |component| < `cMinScale` with `±cMinScale` keeping the sign.
Vec3 MakeNonZeroScale(Vec3 inScale) pure nothrow @nogc {
    static float fix(float v) pure nothrow @nogc {
        immutable float a = fabs(v);
        immutable float c = a < cMinScale ? cMinScale : a;
        return v < 0.0f ? -c : c;
    }
    return Vec3(fix(inScale.GetX()), fix(inScale.GetY()), fix(inScale.GetZ()));
}

/// Replicate the average of the three components.
Vec3 MakeUniformScale(Vec3 inScale) pure nothrow @nogc {
    immutable float a = (inScale.GetX() + inScale.GetY() + inScale.GetZ()) * (1.0f / 3.0f);
    return Vec3.sReplicate(a);
}

/// Average X and Z, leaving Y untouched (used for shapes that require
/// uniform scale only in the XZ plane, e.g. cylinders, capsules).
Vec3 MakeUniformScaleXZ(Vec3 inScale) pure nothrow @nogc {
    immutable float xz = 0.5f * (inScale.GetX() + inScale.GetZ());
    return Vec3(xz, inScale.GetY(), xz);
}

/// True if `inScale` can be propagated through `inRotation` without
/// introducing shear. Computes R^T * diag(s) * R and checks that its
/// off-diagonal entries are within 1e-6.
bool CanScaleBeRotated(Quat inRotation, Vec3 inScale) pure nothrow @nogc {
    immutable Mat44 R = Mat44.sRotation(inRotation);

    // Build M[i][j] = sum_k R[k,i] * s[k] * R[k,j].
    immutable float sx = inScale.GetX();
    immutable float sy = inScale.GetY();
    immutable float sz = inScale.GetZ();

    immutable float eps = 1.0e-6f;
    foreach (i; 0 .. 3) {
        foreach (j; 0 .. 3) {
            if (i == j) continue;
            immutable float m =
                R(0, i) * sx * R(0, j) +
                R(1, i) * sy * R(1, j) +
                R(2, i) * sz * R(2, j);
            if (fabs(m) > eps) return false;
        }
    }
    return true;
}

/// Adjust `inScale` for a rotated child shape: returns the diagonal of
/// R^T * diag(s) * R. Only meaningful when `CanScaleBeRotated` is true.
Vec3 RotateScale(Quat inRotation, Vec3 inScale) pure nothrow @nogc {
    immutable Mat44 R = Mat44.sRotation(inRotation);
    immutable float sx = inScale.GetX();
    immutable float sy = inScale.GetY();
    immutable float sz = inScale.GetZ();
    Vec3 diag;
    foreach (i; 0 .. 3) {
        immutable float v =
            R(0, i) * sx * R(0, i) +
            R(1, i) * sy * R(1, i) +
            R(2, i) * sz * R(2, i);
        if (i == 0)      diag = Vec3(v, diag.GetY(), diag.GetZ());
        else if (i == 1) diag = Vec3(diag.GetX(), v, diag.GetZ());
        else             diag = Vec3(diag.GetX(), diag.GetY(), v);
    }
    return diag;
}

unittest {
    assert(IsNotScaled(Vec3(1, 1, 1)));
    assert(!IsNotScaled(Vec3(1, 2, 1)));

    assert(IsUniformScale(Vec3(2, 2, 2)));
    assert(!IsUniformScale(Vec3(2, 1, 2)));

    assert(IsUniformScaleXZ(Vec3(2, 7, 2)));
    assert(!IsUniformScaleXZ(Vec3(2, 7, 3)));

    assert(IsZeroScale(Vec3(0, 1, 1)));
    assert(!IsZeroScale(Vec3(1, 1, 1)));

    assert(IsInsideOut(Vec3(-1, 1, 1)));
    assert(!IsInsideOut(Vec3(-1, -1, 1)));
    assert(IsInsideOut(Vec3(-1, -1, -1)));

    immutable Vec3 fixed = MakeNonZeroScale(Vec3(0, -2, 0));
    assert(fabs(fixed.GetX()) >= cMinScale);
    assert(fixed.GetY() == -2.0f);

    immutable Vec3 avg = MakeUniformScale(Vec3(1, 2, 3));
    assert(fabs(avg.GetX() - 2.0f) < 1.0e-5f);

    immutable Vec3 xz = MakeUniformScaleXZ(Vec3(1, 5, 3));
    assert(fabs(xz.GetX() - 2.0f) < 1.0e-5f);
    assert(xz.GetY() == 5.0f);
    assert(fabs(xz.GetZ() - 2.0f) < 1.0e-5f);

    // Identity rotation: any scale is preserved unchanged.
    immutable Vec3 s = Vec3(1, 2, 3);
    assert(CanScaleBeRotated(Quat.sIdentity(), s));
    immutable Vec3 r = RotateScale(Quat.sIdentity(), s);
    assert(r.IsClose(s, 1.0e-6f));
}
