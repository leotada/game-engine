// Jolt — Geometry/Plane port. Infinite plane defined by `X . Normal + Constant = 0`.
//
// Storage matches Jolt: a single `Vec4` where XYZ is the (unit) normal and W
// is the plane constant.
//
// Source: ref/JoltPhysics/Jolt/Geometry/Plane.h.
module engine.jph.geometry.plane;

import engine.jph.math.vec3;
import engine.jph.math.vec4;
import engine.jph.math.mat44;
import engine.jph.math.float4;

@safe:

struct Plane {
@safe:
    Vec4 mNormalAndConstant;

    this(Vec4 inNormalAndConstant) pure nothrow @nogc {
        mNormalAndConstant = inNormalAndConstant;
    }
    this(Vec3 inNormal, float inConstant) pure nothrow @nogc {
        mNormalAndConstant = Vec4(inNormal, inConstant);
    }

    static Plane sFromPointAndNormal(Vec3 inPoint, Vec3 inNormal) pure nothrow @nogc {
        return Plane(Vec4(inNormal, -inNormal.Dot(inPoint)));
    }
    static Plane sFromPointsCCW(Vec3 inV1, Vec3 inV2, Vec3 inV3) pure nothrow @nogc {
        return sFromPointAndNormal(inV1, (inV2 - inV1).Cross(inV3 - inV1).Normalized());
    }

    Vec3 GetNormal() const pure nothrow @nogc { return Vec3(mNormalAndConstant); }
    void SetNormal(Vec3 inNormal) pure nothrow @nogc {
        mNormalAndConstant = Vec4(inNormal, mNormalAndConstant.GetW());
    }
    float GetConstant() const pure nothrow @nogc { return mNormalAndConstant.GetW(); }
    void  SetConstant(float inConstant) pure nothrow @nogc { mNormalAndConstant.SetW(inConstant); }

    void StoreFloat4(Float4* outV) const @trusted pure nothrow @nogc {
        mNormalAndConstant.StoreFloat4(outV);
    }

    Plane Offset(float inDistance) const pure nothrow @nogc {
        return Plane(mNormalAndConstant - Vec4(Vec3.sZero(), inDistance));
    }

    Plane GetTransformed(Mat44 inTransform) const pure nothrow @nogc {
        Vec3 n = inTransform.Multiply3x3(GetNormal());
        return Plane(n, GetConstant() - inTransform.GetTranslation().Dot(n));
    }

    Plane Scaled(Vec3 inScale) const pure nothrow @nogc {
        Vec3 sn = GetNormal() / inScale;
        immutable float l = sn.Length();
        return Plane(sn / l, GetConstant() / l);
    }

    float SignedDistance(Vec3 inPoint) const pure nothrow @nogc {
        return inPoint.Dot(GetNormal()) + GetConstant();
    }
    Vec3  ProjectPointOnPlane(Vec3 inPoint) const pure nothrow @nogc {
        return inPoint - GetNormal() * SignedDistance(inPoint);
    }

    /// Intersection of three planes (Cramer's rule). Returns false when degenerate.
    static bool sIntersectPlanes(Plane inP1, Plane inP2, Plane inP3, ref Vec3 outPoint) pure nothrow @nogc {
        Vec3 a = inP1.GetNormal();
        Vec3 b = inP2.GetNormal();
        Vec3 c = inP3.GetNormal();
        immutable float aw = inP1.GetConstant();
        immutable float bw = inP2.GetConstant();
        immutable float cw = inP3.GetConstant();

        immutable float denom = a.Dot(b.Cross(c));
        if (denom == 0.0f) return false;

        // Numerator = aw*(b x c) + bw*(c x a) + cw*(a x b), all negated to solve normal . p + const = 0.
        Vec3 num = b.Cross(c) * (-aw) + c.Cross(a) * (-bw) + a.Cross(b) * (-cw);
        outPoint = num / denom;
        return true;
    }
}
