// Jolt — Math/Vec3 port. 3-component float vector with W=Z invariant.
//
// Storage uses `float[4] mF32` (scalar fallback). The trailing W lane is kept
// equal to Z so that component-wise division never divides by zero. Setters
// that touch X/Y are cheap; SetZ and SetComponent restore the invariant.
//
// Source: ref/JoltPhysics/Jolt/Math/Vec3.h + Vec3.inl.
module engine.jph.math.vec3;

import std.math : sqrt, fabs, isNaN;
import engine.jph.core.types;
import engine.jph.math.float3;
import engine.jph.math.uvec4;
import engine.jph.math.vec4;

@safe:

align(16)
struct Vec3 {
@safe:
    float[4] mF32 = [0, 0, 0, 0];

    this(float inX, float inY, float inZ) pure nothrow @nogc {
        mF32[0] = inX; mF32[1] = inY; mF32[2] = inZ; mF32[3] = inZ;
    }
    this(const Float3 v) pure nothrow @nogc {
        mF32[0] = v.x; mF32[1] = v.y; mF32[2] = v.z; mF32[3] = v.z;
    }
    this(Vec4 v) pure nothrow @nogc {
        mF32[0] = v.mF32[0]; mF32[1] = v.mF32[1]; mF32[2] = v.mF32[2]; mF32[3] = v.mF32[2];
    }

    private void fixW() pure nothrow @nogc { mF32[3] = mF32[2]; }

    static Vec3 sZero() pure nothrow @nogc { return Vec3(0, 0, 0); }
    static Vec3 sOne()  pure nothrow @nogc { return Vec3(1, 1, 1); }
    static Vec3 sNaN()  pure nothrow @nogc { return Vec3(float.nan, float.nan, float.nan); }
    static Vec3 sAxisX() pure nothrow @nogc { return Vec3(1, 0, 0); }
    static Vec3 sAxisY() pure nothrow @nogc { return Vec3(0, 1, 0); }
    static Vec3 sAxisZ() pure nothrow @nogc { return Vec3(0, 0, 1); }
    static Vec3 sReplicate(float v) pure nothrow @nogc { return Vec3(v, v, v); }
    static Vec3 sLoadFloat3Unsafe(const Float3 v) pure nothrow @nogc { return Vec3(v); }

    static Vec3 sMin(Vec3 a, Vec3 b) pure nothrow @nogc {
        return Vec3(a.mF32[0] < b.mF32[0] ? a.mF32[0] : b.mF32[0],
                    a.mF32[1] < b.mF32[1] ? a.mF32[1] : b.mF32[1],
                    a.mF32[2] < b.mF32[2] ? a.mF32[2] : b.mF32[2]);
    }
    static Vec3 sMax(Vec3 a, Vec3 b) pure nothrow @nogc {
        return Vec3(a.mF32[0] > b.mF32[0] ? a.mF32[0] : b.mF32[0],
                    a.mF32[1] > b.mF32[1] ? a.mF32[1] : b.mF32[1],
                    a.mF32[2] > b.mF32[2] ? a.mF32[2] : b.mF32[2]);
    }
    static Vec3 sClamp(Vec3 v, Vec3 lo, Vec3 hi) pure nothrow @nogc {
        return sMin(sMax(v, lo), hi);
    }

    static UVec4 sEquals(Vec3 a, Vec3 b) pure nothrow @nogc {
        return UVec4(a.mF32[0] == b.mF32[0] ? 0xFFFFFFFFu : 0u,
                     a.mF32[1] == b.mF32[1] ? 0xFFFFFFFFu : 0u,
                     a.mF32[2] == b.mF32[2] ? 0xFFFFFFFFu : 0u,
                     a.mF32[3] == b.mF32[3] ? 0xFFFFFFFFu : 0u);
    }
    static UVec4 sLess(Vec3 a, Vec3 b) pure nothrow @nogc {
        return UVec4(a.mF32[0] <  b.mF32[0] ? 0xFFFFFFFFu : 0u,
                     a.mF32[1] <  b.mF32[1] ? 0xFFFFFFFFu : 0u,
                     a.mF32[2] <  b.mF32[2] ? 0xFFFFFFFFu : 0u,
                     a.mF32[3] <  b.mF32[3] ? 0xFFFFFFFFu : 0u);
    }
    static UVec4 sLessOrEqual(Vec3 a, Vec3 b) pure nothrow @nogc {
        return UVec4(a.mF32[0] <= b.mF32[0] ? 0xFFFFFFFFu : 0u,
                     a.mF32[1] <= b.mF32[1] ? 0xFFFFFFFFu : 0u,
                     a.mF32[2] <= b.mF32[2] ? 0xFFFFFFFFu : 0u,
                     a.mF32[3] <= b.mF32[3] ? 0xFFFFFFFFu : 0u);
    }
    static UVec4 sGreater(Vec3 a, Vec3 b) pure nothrow @nogc {
        return UVec4(a.mF32[0] >  b.mF32[0] ? 0xFFFFFFFFu : 0u,
                     a.mF32[1] >  b.mF32[1] ? 0xFFFFFFFFu : 0u,
                     a.mF32[2] >  b.mF32[2] ? 0xFFFFFFFFu : 0u,
                     a.mF32[3] >  b.mF32[3] ? 0xFFFFFFFFu : 0u);
    }
    static UVec4 sGreaterOrEqual(Vec3 a, Vec3 b) pure nothrow @nogc {
        return UVec4(a.mF32[0] >= b.mF32[0] ? 0xFFFFFFFFu : 0u,
                     a.mF32[1] >= b.mF32[1] ? 0xFFFFFFFFu : 0u,
                     a.mF32[2] >= b.mF32[2] ? 0xFFFFFFFFu : 0u,
                     a.mF32[3] >= b.mF32[3] ? 0xFFFFFFFFu : 0u);
    }

    static Vec3 sFusedMultiplyAdd(Vec3 a, Vec3 b, Vec3 c) pure nothrow @nogc {
        return Vec3(a.mF32[0]*b.mF32[0] + c.mF32[0],
                    a.mF32[1]*b.mF32[1] + c.mF32[1],
                    a.mF32[2]*b.mF32[2] + c.mF32[2]);
    }

    static Vec3 sSelect(Vec3 notSet, Vec3 set, UVec4 ctl) pure nothrow @nogc {
        Vec3 r;
        foreach (i; 0 .. 3) {
            r.mF32[i] = (ctl.mU32[i] & 0x80000000u) != 0 ? set.mF32[i] : notSet.mF32[i];
        }
        r.fixW();
        return r;
    }

    static Vec3 sOr(Vec3 a, Vec3 b) @trusted pure nothrow @nogc {
        Vec3 r;
        foreach (i; 0 .. 3) {
            immutable uint32 au = *cast(const uint32*) &a.mF32[i];
            immutable uint32 bu = *cast(const uint32*) &b.mF32[i];
            immutable uint32 ru = au | bu;
            r.mF32[i] = *cast(const float*) &ru;
        }
        r.fixW();
        return r;
    }
    static Vec3 sXor(Vec3 a, Vec3 b) @trusted pure nothrow @nogc {
        Vec3 r;
        foreach (i; 0 .. 3) {
            immutable uint32 au = *cast(const uint32*) &a.mF32[i];
            immutable uint32 bu = *cast(const uint32*) &b.mF32[i];
            immutable uint32 ru = au ^ bu;
            r.mF32[i] = *cast(const float*) &ru;
        }
        r.fixW();
        return r;
    }
    static Vec3 sAnd(Vec3 a, Vec3 b) @trusted pure nothrow @nogc {
        Vec3 r;
        foreach (i; 0 .. 3) {
            immutable uint32 au = *cast(const uint32*) &a.mF32[i];
            immutable uint32 bu = *cast(const uint32*) &b.mF32[i];
            immutable uint32 ru = au & bu;
            r.mF32[i] = *cast(const float*) &ru;
        }
        r.fixW();
        return r;
    }

    float GetX() const pure nothrow @nogc { return mF32[0]; }
    float GetY() const pure nothrow @nogc { return mF32[1]; }
    float GetZ() const pure nothrow @nogc { return mF32[2]; }

    void  SetX(float v) pure nothrow @nogc { mF32[0] = v; }
    void  SetY(float v) pure nothrow @nogc { mF32[1] = v; }
    void  SetZ(float v) pure nothrow @nogc { mF32[2] = v; mF32[3] = v; }

    void  Set(float x, float y, float z) pure nothrow @nogc {
        mF32[0] = x; mF32[1] = y; mF32[2] = z; mF32[3] = z;
    }
    void  SetComponent(uint i, float v) pure nothrow @nogc
    in (i < 3)
    {
        mF32[i] = v;
        fixW();
    }

    float opIndex(uint i) const pure nothrow @nogc
    in (i < 3)
    {
        return mF32[i];
    }

    bool opEquals(const Vec3 r) const pure nothrow @nogc {
        return mF32[0] == r.mF32[0] && mF32[1] == r.mF32[1] && mF32[2] == r.mF32[2];
    }

    bool IsClose(Vec3 r, float maxDistSq = 1.0e-12f) const pure nothrow @nogc {
        return (this - r).LengthSq() <= maxDistSq;
    }
    bool IsNearZero(float maxDistSq = 1.0e-12f) const pure nothrow @nogc {
        return LengthSq() <= maxDistSq;
    }
    bool IsNormalized(float tol = 1.0e-6f) const pure nothrow @nogc {
        immutable float d = LengthSq() - 1.0f;
        return (d < 0 ? -d : d) <= tol;
    }
    bool IsNaN() const pure nothrow @nogc {
        return isNaN(mF32[0]) || isNaN(mF32[1]) || isNaN(mF32[2]);
    }

    Vec3 opBinary(string op)(Vec3 r) const pure nothrow @nogc
    if (op == "+" || op == "-" || op == "*" || op == "/") {
        static if (op == "+") return Vec3(mF32[0]+r.mF32[0], mF32[1]+r.mF32[1], mF32[2]+r.mF32[2]);
        else static if (op == "-") return Vec3(mF32[0]-r.mF32[0], mF32[1]-r.mF32[1], mF32[2]-r.mF32[2]);
        else static if (op == "*") return Vec3(mF32[0]*r.mF32[0], mF32[1]*r.mF32[1], mF32[2]*r.mF32[2]);
        else                       return Vec3(mF32[0]/r.mF32[0], mF32[1]/r.mF32[1], mF32[2]/r.mF32[2]);
    }
    Vec3 opBinary(string op)(float s) const pure nothrow @nogc
    if (op == "*" || op == "/") {
        static if (op == "*") return Vec3(mF32[0]*s, mF32[1]*s, mF32[2]*s);
        else { immutable float inv = 1.0f / s; return Vec3(mF32[0]*inv, mF32[1]*inv, mF32[2]*inv); }
    }
    Vec3 opBinaryRight(string op)(float s) const pure nothrow @nogc
    if (op == "*") {
        return this * s;
    }
    Vec3 opUnary(string op)() const pure nothrow @nogc
    if (op == "-") {
        return Vec3(-mF32[0], -mF32[1], -mF32[2]);
    }

    ref Vec3 opOpAssign(string op)(Vec3 r) pure nothrow @nogc
    if (op == "+" || op == "-" || op == "*" || op == "/") {
        static if (op == "+") { mF32[0]+=r.mF32[0]; mF32[1]+=r.mF32[1]; mF32[2]+=r.mF32[2]; }
        else static if (op == "-") { mF32[0]-=r.mF32[0]; mF32[1]-=r.mF32[1]; mF32[2]-=r.mF32[2]; }
        else static if (op == "*") { mF32[0]*=r.mF32[0]; mF32[1]*=r.mF32[1]; mF32[2]*=r.mF32[2]; }
        else                       { mF32[0]/=r.mF32[0]; mF32[1]/=r.mF32[1]; mF32[2]/=r.mF32[2]; }
        fixW();
        return this;
    }
    ref Vec3 opOpAssign(string op)(float s) pure nothrow @nogc
    if (op == "*" || op == "/") {
        static if (op == "*") { mF32[0]*=s; mF32[1]*=s; mF32[2]*=s; }
        else                  { mF32[0]/=s; mF32[1]/=s; mF32[2]/=s; }
        fixW();
        return this;
    }

    Vec4 SplatX() const pure nothrow @nogc { return Vec4(mF32[0], mF32[0], mF32[0], mF32[0]); }
    Vec4 SplatY() const pure nothrow @nogc { return Vec4(mF32[1], mF32[1], mF32[1], mF32[1]); }
    Vec4 SplatZ() const pure nothrow @nogc { return Vec4(mF32[2], mF32[2], mF32[2], mF32[2]); }

    Vec3 Swizzle(uint X, uint Y, uint Z)() const pure nothrow @nogc
    if (X < 4 && Y < 4 && Z < 4)
    {
        return Vec3(mF32[X], mF32[Y], mF32[Z]);
    }

    Vec3 Abs() const pure nothrow @nogc {
        return Vec3(fabs(mF32[0]), fabs(mF32[1]), fabs(mF32[2]));
    }
    Vec3 Reciprocal() const pure nothrow @nogc { return sOne() / this; }
    Vec3 Sqrt() const pure nothrow @nogc {
        return Vec3(sqrt(mF32[0]), sqrt(mF32[1]), sqrt(mF32[2]));
    }
    Vec3 GetSign() const pure nothrow @nogc {
        return Vec3(mF32[0] < 0 ? -1 : 1, mF32[1] < 0 ? -1 : 1, mF32[2] < 0 ? -1 : 1);
    }

    Vec3 Cross(Vec3 r) const pure nothrow @nogc {
        return Vec3(mF32[1]*r.mF32[2] - mF32[2]*r.mF32[1],
                    mF32[2]*r.mF32[0] - mF32[0]*r.mF32[2],
                    mF32[0]*r.mF32[1] - mF32[1]*r.mF32[0]);
    }

    Vec3 DotV(Vec3 r) const pure nothrow @nogc {
        immutable float d = Dot(r);
        return Vec3(d, d, d);
    }
    Vec4 DotV4(Vec3 r) const pure nothrow @nogc {
        immutable float d = Dot(r);
        return Vec4(d, d, d, d);
    }
    float Dot(Vec3 r) const pure nothrow @nogc {
        return mF32[0]*r.mF32[0] + mF32[1]*r.mF32[1] + mF32[2]*r.mF32[2];
    }

    float LengthSq() const pure nothrow @nogc { return Dot(this); }
    float Length()   const pure nothrow @nogc { return sqrt(LengthSq()); }

    Vec3 Normalized() const pure nothrow @nogc { return this / Length(); }
    Vec3 NormalizedOr(Vec3 zeroValue) const pure nothrow @nogc {
        immutable float lsq = LengthSq();
        if (lsq == 0.0f) return zeroValue;
        return this / sqrt(lsq);
    }

    Vec3 GetNormalizedPerpendicular() const pure nothrow @nogc {
        immutable float ax = fabs(mF32[0]), ay = fabs(mF32[1]);
        if (ax > ay) {
            immutable float invLen = 1.0f / sqrt(mF32[0]*mF32[0] + mF32[2]*mF32[2]);
            return Vec3(mF32[2] * invLen, 0.0f, -mF32[0] * invLen);
        } else {
            immutable float invLen = 1.0f / sqrt(mF32[1]*mF32[1] + mF32[2]*mF32[2]);
            return Vec3(0.0f, mF32[2] * invLen, -mF32[1] * invLen);
        }
    }

    void StoreFloat3(Float3* outV) const @trusted pure nothrow @nogc {
        outV.x = mF32[0]; outV.y = mF32[1]; outV.z = mF32[2];
    }

    int GetLowestComponentIndex() const pure nothrow @nogc {
        if (mF32[0] <= mF32[1]) return mF32[0] <= mF32[2] ? 0 : 2;
        return mF32[1] <= mF32[2] ? 1 : 2;
    }
    int GetHighestComponentIndex() const pure nothrow @nogc {
        if (mF32[0] >= mF32[1]) return mF32[0] >= mF32[2] ? 0 : 2;
        return mF32[1] >= mF32[2] ? 1 : 2;
    }

    float ReduceMin() const pure nothrow @nogc {
        immutable float m01 = mF32[0] < mF32[1] ? mF32[0] : mF32[1];
        return m01 < mF32[2] ? m01 : mF32[2];
    }
    float ReduceMax() const pure nothrow @nogc {
        immutable float m01 = mF32[0] > mF32[1] ? mF32[0] : mF32[1];
        return m01 > mF32[2] ? m01 : mF32[2];
    }
}
