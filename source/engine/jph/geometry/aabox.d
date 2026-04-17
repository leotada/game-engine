// Jolt — Geometry/AABox port.
//
// Source: ref/JoltPhysics/Jolt/Geometry/AABox.h.
module engine.jph.geometry.aabox;

import engine.jph.math.vec3;
import engine.jph.math.uvec4;
import engine.jph.math.mat44;
import engine.jph.geometry.plane;
import engine.jph.geometry.triangle;

@safe:

struct AABox {
@safe:
    Vec3 mMin = Vec3(float.max, float.max, float.max);
    Vec3 mMax = Vec3(-float.max, -float.max, -float.max);

    this(Vec3 inMin, Vec3 inMax) pure nothrow @nogc { mMin = inMin; mMax = inMax; }
    this(Vec3 inCenter, float inRadius) pure nothrow @nogc {
        mMin = inCenter - Vec3.sReplicate(inRadius);
        mMax = inCenter + Vec3.sReplicate(inRadius);
    }

    static AABox sFromTwoPoints(Vec3 inP1, Vec3 inP2) pure nothrow @nogc {
        return AABox(Vec3.sMin(inP1, inP2), Vec3.sMax(inP1, inP2));
    }

    /// AABox of half-extent 0.5 * float.max so GetSize() stays finite.
    static AABox sBiggest() pure nothrow @nogc {
        return AABox(Vec3.sReplicate(-0.5f * float.max),
                     Vec3.sReplicate(0.5f * float.max));
    }

    bool opEquals(const AABox r) const pure nothrow @nogc {
        return mMin == r.mMin && mMax == r.mMax;
    }

    void SetEmpty() pure nothrow @nogc {
        mMin = Vec3.sReplicate(float.max);
        mMax = Vec3.sReplicate(-float.max);
    }

    bool IsValid() const pure nothrow @nogc {
        return mMin.GetX() <= mMax.GetX() && mMin.GetY() <= mMax.GetY() && mMin.GetZ() <= mMax.GetZ();
    }

    void Encapsulate(Vec3 inPos) pure nothrow @nogc {
        mMin = Vec3.sMin(mMin, inPos);
        mMax = Vec3.sMax(mMax, inPos);
    }
    void Encapsulate(const AABox r) pure nothrow @nogc {
        mMin = Vec3.sMin(mMin, r.mMin);
        mMax = Vec3.sMax(mMax, r.mMax);
    }
    void Encapsulate(const Triangle inT) pure nothrow @nogc {
        Encapsulate(Vec3.sLoadFloat3Unsafe(inT.mV[0]));
        Encapsulate(Vec3.sLoadFloat3Unsafe(inT.mV[1]));
        Encapsulate(Vec3.sLoadFloat3Unsafe(inT.mV[2]));
    }

    AABox Intersect(const AABox o) const pure nothrow @nogc {
        return AABox(Vec3.sMax(mMin, o.mMin), Vec3.sMin(mMax, o.mMax));
    }

    void EnsureMinimalEdgeLength(float inMinEdgeLength) pure nothrow @nogc {
        Vec3 minLen = Vec3.sReplicate(inMinEdgeLength);
        mMax = Vec3.sSelect(mMax, mMin + minLen, Vec3.sLess(mMax - mMin, minLen));
    }

    void ExpandBy(Vec3 v) pure nothrow @nogc { mMin -= v; mMax += v; }

    Vec3 GetCenter() const pure nothrow @nogc { return 0.5f * (mMin + mMax); }
    Vec3 GetExtent() const pure nothrow @nogc { return 0.5f * (mMax - mMin); }
    Vec3 GetSize()   const pure nothrow @nogc { return mMax - mMin; }

    float GetSurfaceArea() const pure nothrow @nogc {
        Vec3 e = mMax - mMin;
        return 2.0f * (e.GetX()*e.GetY() + e.GetX()*e.GetZ() + e.GetY()*e.GetZ());
    }
    float GetVolume() const pure nothrow @nogc {
        Vec3 e = mMax - mMin;
        return e.GetX() * e.GetY() * e.GetZ();
    }

    bool Contains(const AABox o) const pure nothrow @nogc {
        return UVec4.sAnd(Vec3.sLessOrEqual(mMin, o.mMin),
                          Vec3.sGreaterOrEqual(mMax, o.mMax)).TestAllXYZTrue();
    }
    bool Contains(Vec3 p) const pure nothrow @nogc {
        return UVec4.sAnd(Vec3.sLessOrEqual(mMin, p),
                          Vec3.sGreaterOrEqual(mMax, p)).TestAllXYZTrue();
    }

    bool Overlaps(const AABox o) const pure nothrow @nogc {
        return !UVec4.sOr(Vec3.sGreater(mMin, o.mMax),
                          Vec3.sLess(mMax, o.mMin)).TestAnyXYZTrue();
    }
    bool Overlaps(const Plane p) const pure nothrow @nogc {
        Vec3 n = p.GetNormal();
        immutable float d1 = p.SignedDistance(GetSupport(n));
        immutable float d2 = p.SignedDistance(GetSupport(-n));
        return d1 * d2 <= 0.0f;
    }

    void Translate(Vec3 t) pure nothrow @nogc { mMin += t; mMax += t; }

    AABox Transformed(Mat44 m) const pure nothrow @nogc {
        Vec3 newMin = m.GetTranslation();
        Vec3 newMax = newMin;
        foreach (c; 0 .. 3) {
            Vec3 col = m.GetColumn3(c);
            Vec3 a = col * mMin[c];
            Vec3 b = col * mMax[c];
            newMin += Vec3.sMin(a, b);
            newMax += Vec3.sMax(a, b);
        }
        return AABox(newMin, newMax);
    }

    AABox Scaled(Vec3 s) const pure nothrow @nogc {
        return AABox.sFromTwoPoints(mMin * s, mMax * s);
    }

    /// Support point of the box in the given direction.
    Vec3 GetSupport(Vec3 inDirection) const pure nothrow @nogc {
        return Vec3.sSelect(mMax, mMin, Vec3.sLess(inDirection, Vec3.sZero()));
    }

    Vec3 GetClosestPoint(Vec3 inPoint) const pure nothrow @nogc {
        return Vec3.sMin(Vec3.sMax(inPoint, mMin), mMax);
    }
    float GetSqDistanceTo(Vec3 inPoint) const pure nothrow @nogc {
        return (GetClosestPoint(inPoint) - inPoint).LengthSq();
    }
}

unittest {
    // Construct, encapsulate, intersect.
    AABox a;
    assert(!a.IsValid());
    a.Encapsulate(Vec3(0, 0, 0));
    a.Encapsulate(Vec3(2, 4, 6));
    assert(a.IsValid());
    assert(a.mMin == Vec3(0, 0, 0));
    assert(a.mMax == Vec3(2, 4, 6));
    assert(a.GetCenter() == Vec3(1, 2, 3));
    assert(a.Contains(Vec3(1, 1, 1)));
    assert(!a.Contains(Vec3(3, 1, 1)));

    // Overlap test.
    auto b = AABox(Vec3(1, 1, 1), Vec3(3, 5, 7));
    assert(a.Overlaps(b));
    auto c = AABox(Vec3(10, 10, 10), Vec3(11, 11, 11));
    assert(!a.Overlaps(c));

    // Closest point on a box.
    assert(a.GetClosestPoint(Vec3(-1, 2, 3)) == Vec3(0, 2, 3));
    assert(a.GetClosestPoint(Vec3(1, 2, 3)) == Vec3(1, 2, 3)); // inside
}

