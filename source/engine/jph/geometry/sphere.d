// Jolt — Geometry/Sphere port.
//
// Source: ref/JoltPhysics/Jolt/Geometry/Sphere.h.
module engine.jph.geometry.sphere;

import std.math : sqrt;
import engine.jph.math.vec3;
import engine.jph.math.float3;
import engine.jph.math.scalar : Square;
import engine.jph.geometry.aabox;

@safe:

struct Sphere {
@safe:
    Float3 mCenter;
    float mRadius = 0.0f;

    this(Float3 inCenter, float inRadius) pure nothrow @nogc {
        mCenter = inCenter; mRadius = inRadius;
    }
    this(Vec3 inCenter, float inRadius) @trusted pure nothrow @nogc {
        inCenter.StoreFloat3(&mCenter);
        mRadius = inRadius;
    }

    Vec3  GetCenter() const pure nothrow @nogc { return Vec3.sLoadFloat3Unsafe(mCenter); }
    float GetRadius() const pure nothrow @nogc { return mRadius; }

    Vec3 GetSupport(Vec3 inDirection) const pure nothrow @nogc {
        immutable float l = inDirection.Length();
        return l > 0.0f ? GetCenter() + (mRadius / l) * inDirection : GetCenter();
    }

    bool Overlaps(const Sphere inB) const pure nothrow @nogc {
        return (GetCenter() - inB.GetCenter()).LengthSq() <= Square(mRadius + inB.mRadius);
    }
    bool Overlaps(const AABox inOther) const pure nothrow @nogc {
        return inOther.GetSqDistanceTo(GetCenter()) <= Square(mRadius);
    }

    void EncapsulatePoint(Vec3 inPoint) @trusted pure nothrow @nogc {
        Vec3 center = GetCenter();
        Vec3 d_vec = inPoint - center;
        immutable float d_sq = d_vec.LengthSq();
        if (d_sq > Square(mRadius)) {
            immutable float d = sqrt(d_sq);
            immutable float r = 0.5f * (mRadius + d);
            center += (r - mRadius) / d * d_vec;
            center.StoreFloat3(&mCenter);
            mRadius = r;
        }
    }
}
