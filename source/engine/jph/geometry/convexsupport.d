// Jolt — Geometry/ConvexSupport port. Templated wrappers for the GJK/EPA
// support function pattern (`Vec3 GetSupport(Vec3)`).
//
// Source: ref/JoltPhysics/Jolt/Geometry/ConvexSupport.h.
module engine.jph.geometry.convexsupport;

import std.math : sqrt;
import engine.jph.math.vec3;
import engine.jph.math.mat44;

@safe:

/// Wraps a convex object together with a transform. The wrapped object is
/// borrowed by pointer — caller must keep it alive for the lifetime of the
/// wrapper.
struct TransformedConvexObject(O) {
@safe:
    Mat44 mTransform;
    const(O)* mObject;

    this(Mat44 inTransform, ref const O inObject) @trusted pure nothrow @nogc {
        mTransform = inTransform;
        mObject = &inObject;
    }

    Vec3 GetSupport(Vec3 inDirection) const pure nothrow @nogc {
        return mTransform * mObject.GetSupport(mTransform.Multiply3x3Transposed(inDirection));
    }
}

/// Inflates a convex object by a sphere of radius `mRadius`.
struct AddConvexRadius(O) {
@safe:
    const(O)* mObject;
    float mRadius;

    this(ref const O inObject, float inRadius) @trusted pure nothrow @nogc {
        mObject = &inObject;
        mRadius = inRadius;
    }

    Vec3 GetSupport(Vec3 inDirection) const pure nothrow @nogc {
        immutable float l = inDirection.Length();
        return l > 0.0f
            ? mObject.GetSupport(inDirection) + (mRadius / l) * inDirection
            : mObject.GetSupport(inDirection);
    }
}

/// Minkowski difference A - B.
struct MinkowskiDifference(A, B) {
@safe:
    const(A)* mA;
    const(B)* mB;

    this(ref const A a, ref const B b) @trusted pure nothrow @nogc {
        mA = &a; mB = &b;
    }

    Vec3 GetSupport(Vec3 inDirection) const pure nothrow @nogc {
        return mA.GetSupport(inDirection) - mB.GetSupport(-inDirection);
    }
}

/// A single point treated as a degenerate convex shape.
struct PointConvexSupport {
@safe:
    Vec3 mPoint;

    Vec3 GetSupport(Vec3 inDirection) const pure nothrow @nogc {
        cast(void) inDirection;
        return mPoint;
    }
}

/// Triangle as a convex shape.
struct TriangleConvexSupport {
@safe:
    Vec3 mV1, mV2, mV3;

    this(Vec3 v1, Vec3 v2, Vec3 v3) pure nothrow @nogc {
        mV1 = v1; mV2 = v2; mV3 = v3;
    }

    Vec3 GetSupport(Vec3 inDirection) const pure nothrow @nogc {
        immutable float d1 = mV1.Dot(inDirection);
        immutable float d2 = mV2.Dot(inDirection);
        immutable float d3 = mV3.Dot(inDirection);
        if (d1 > d2) {
            return d1 > d3 ? mV1 : mV3;
        } else {
            return d2 > d3 ? mV2 : mV3;
        }
    }
}
