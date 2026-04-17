// Jolt — Math/Vec4 port. 4-component float vector.
// Source: ref/JoltPhysics/Jolt/Math/Vec4.h + Vec4.inl.
module engine.jph.math.vec4;

import std.math : sqrt, fabs, isNaN;
import engine.jph.core.types;
import engine.jph.math.float4;
import engine.jph.math.uvec4;
import engine.jph.math.vec3 : Vec3;

@safe:

align(16)
struct Vec4 {
@safe:
    float[4] mF32 = [0, 0, 0, 0];

    this(float inX, float inY, float inZ, float inW) pure nothrow @nogc {
        mF32[0] = inX; mF32[1] = inY; mF32[2] = inZ; mF32[3] = inW;
    }
    /// Construct from a 3-vector and explicit W. Mirrors Jolt's `Vec4(Vec3Arg, float)`.
    this(Vec3 v, float inW) pure nothrow @nogc {
        mF32[0] = v.GetX(); mF32[1] = v.GetY(); mF32[2] = v.GetZ(); mF32[3] = inW;
    }

    static Vec4 sZero()      pure nothrow @nogc { return Vec4(0, 0, 0, 0); }
    static Vec4 sOne()       pure nothrow @nogc { return Vec4(1, 1, 1, 1); }
    static Vec4 sNaN()       pure nothrow @nogc { return Vec4(float.nan, float.nan, float.nan, float.nan); }
    static Vec4 sReplicate(float v) pure nothrow @nogc { return Vec4(v, v, v, v); }

    static Vec4 sLoadFloat4(const(Float4)* v) @trusted pure nothrow @nogc {
        return Vec4(v.x, v.y, v.z, v.w);
    }
    static Vec4 sLoadFloat4Aligned(const(Float4)* v) @trusted pure nothrow @nogc {
        return Vec4(v.x, v.y, v.z, v.w);
    }

    static Vec4 sMin(Vec4 a, Vec4 b) pure nothrow @nogc {
        return Vec4(a.mF32[0] < b.mF32[0] ? a.mF32[0] : b.mF32[0],
                    a.mF32[1] < b.mF32[1] ? a.mF32[1] : b.mF32[1],
                    a.mF32[2] < b.mF32[2] ? a.mF32[2] : b.mF32[2],
                    a.mF32[3] < b.mF32[3] ? a.mF32[3] : b.mF32[3]);
    }
    static Vec4 sMax(Vec4 a, Vec4 b) pure nothrow @nogc {
        return Vec4(a.mF32[0] > b.mF32[0] ? a.mF32[0] : b.mF32[0],
                    a.mF32[1] > b.mF32[1] ? a.mF32[1] : b.mF32[1],
                    a.mF32[2] > b.mF32[2] ? a.mF32[2] : b.mF32[2],
                    a.mF32[3] > b.mF32[3] ? a.mF32[3] : b.mF32[3]);
    }
    static Vec4 sClamp(Vec4 v, Vec4 lo, Vec4 hi) pure nothrow @nogc {
        return sMin(sMax(v, lo), hi);
    }

    static UVec4 sEquals(Vec4 a, Vec4 b) pure nothrow @nogc {
        return UVec4(a.mF32[0] == b.mF32[0] ? 0xFFFFFFFFu : 0u,
                     a.mF32[1] == b.mF32[1] ? 0xFFFFFFFFu : 0u,
                     a.mF32[2] == b.mF32[2] ? 0xFFFFFFFFu : 0u,
                     a.mF32[3] == b.mF32[3] ? 0xFFFFFFFFu : 0u);
    }
    static UVec4 sLess(Vec4 a, Vec4 b) pure nothrow @nogc {
        return UVec4(a.mF32[0] <  b.mF32[0] ? 0xFFFFFFFFu : 0u,
                     a.mF32[1] <  b.mF32[1] ? 0xFFFFFFFFu : 0u,
                     a.mF32[2] <  b.mF32[2] ? 0xFFFFFFFFu : 0u,
                     a.mF32[3] <  b.mF32[3] ? 0xFFFFFFFFu : 0u);
    }
    static UVec4 sLessOrEqual(Vec4 a, Vec4 b) pure nothrow @nogc {
        return UVec4(a.mF32[0] <= b.mF32[0] ? 0xFFFFFFFFu : 0u,
                     a.mF32[1] <= b.mF32[1] ? 0xFFFFFFFFu : 0u,
                     a.mF32[2] <= b.mF32[2] ? 0xFFFFFFFFu : 0u,
                     a.mF32[3] <= b.mF32[3] ? 0xFFFFFFFFu : 0u);
    }
    static UVec4 sGreater(Vec4 a, Vec4 b) pure nothrow @nogc {
        return UVec4(a.mF32[0] >  b.mF32[0] ? 0xFFFFFFFFu : 0u,
                     a.mF32[1] >  b.mF32[1] ? 0xFFFFFFFFu : 0u,
                     a.mF32[2] >  b.mF32[2] ? 0xFFFFFFFFu : 0u,
                     a.mF32[3] >  b.mF32[3] ? 0xFFFFFFFFu : 0u);
    }
    static UVec4 sGreaterOrEqual(Vec4 a, Vec4 b) pure nothrow @nogc {
        return UVec4(a.mF32[0] >= b.mF32[0] ? 0xFFFFFFFFu : 0u,
                     a.mF32[1] >= b.mF32[1] ? 0xFFFFFFFFu : 0u,
                     a.mF32[2] >= b.mF32[2] ? 0xFFFFFFFFu : 0u,
                     a.mF32[3] >= b.mF32[3] ? 0xFFFFFFFFu : 0u);
    }

    static Vec4 sFusedMultiplyAdd(Vec4 a, Vec4 b, Vec4 c) pure nothrow @nogc {
        return Vec4(a.mF32[0]*b.mF32[0] + c.mF32[0],
                    a.mF32[1]*b.mF32[1] + c.mF32[1],
                    a.mF32[2]*b.mF32[2] + c.mF32[2],
                    a.mF32[3]*b.mF32[3] + c.mF32[3]);
    }

    static Vec4 sSelect(Vec4 notSet, Vec4 set, UVec4 ctl) pure nothrow @nogc {
        Vec4 r;
        r.mF32[0] = (ctl.mU32[0] & 0x80000000u) != 0 ? set.mF32[0] : notSet.mF32[0];
        r.mF32[1] = (ctl.mU32[1] & 0x80000000u) != 0 ? set.mF32[1] : notSet.mF32[1];
        r.mF32[2] = (ctl.mU32[2] & 0x80000000u) != 0 ? set.mF32[2] : notSet.mF32[2];
        r.mF32[3] = (ctl.mU32[3] & 0x80000000u) != 0 ? set.mF32[3] : notSet.mF32[3];
        return r;
    }

    static Vec4 sOr(Vec4 a, Vec4 b) @trusted pure nothrow @nogc {
        Vec4 r;
        foreach (i; 0 .. 4) {
            immutable uint32 au = *cast(const uint32*) &a.mF32[i];
            immutable uint32 bu = *cast(const uint32*) &b.mF32[i];
            immutable uint32 ru = au | bu;
            r.mF32[i] = *cast(const float*) &ru;
        }
        return r;
    }
    static Vec4 sXor(Vec4 a, Vec4 b) @trusted pure nothrow @nogc {
        Vec4 r;
        foreach (i; 0 .. 4) {
            immutable uint32 au = *cast(const uint32*) &a.mF32[i];
            immutable uint32 bu = *cast(const uint32*) &b.mF32[i];
            immutable uint32 ru = au ^ bu;
            r.mF32[i] = *cast(const float*) &ru;
        }
        return r;
    }
    static Vec4 sAnd(Vec4 a, Vec4 b) @trusted pure nothrow @nogc {
        Vec4 r;
        foreach (i; 0 .. 4) {
            immutable uint32 au = *cast(const uint32*) &a.mF32[i];
            immutable uint32 bu = *cast(const uint32*) &b.mF32[i];
            immutable uint32 ru = au & bu;
            r.mF32[i] = *cast(const float*) &ru;
        }
        return r;
    }

    float GetX() const pure nothrow @nogc { return mF32[0]; }
    float GetY() const pure nothrow @nogc { return mF32[1]; }
    float GetZ() const pure nothrow @nogc { return mF32[2]; }
    float GetW() const pure nothrow @nogc { return mF32[3]; }

    void  SetX(float v) pure nothrow @nogc { mF32[0] = v; }
    void  SetY(float v) pure nothrow @nogc { mF32[1] = v; }
    void  SetZ(float v) pure nothrow @nogc { mF32[2] = v; }
    void  SetW(float v) pure nothrow @nogc { mF32[3] = v; }

    void  Set(float x, float y, float z, float w) pure nothrow @nogc {
        mF32[0]=x; mF32[1]=y; mF32[2]=z; mF32[3]=w;
    }

    float opIndex(uint i) const pure nothrow @nogc
    in (i < 4)
    {
        return mF32[i];
    }

    bool opEquals(const Vec4 r) const pure nothrow @nogc {
        return mF32[0] == r.mF32[0] && mF32[1] == r.mF32[1]
            && mF32[2] == r.mF32[2] && mF32[3] == r.mF32[3];
    }

    bool IsClose(Vec4 r, float maxDistSq = 1.0e-12f) const pure nothrow @nogc {
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
        foreach (f; mF32) if (isNaN(f)) return true;
        return false;
    }

    Vec4 opBinary(string op)(Vec4 r) const pure nothrow @nogc
    if (op == "+" || op == "-" || op == "*" || op == "/") {
        Vec4 o;
        static if (op == "+") { o.mF32[0]=mF32[0]+r.mF32[0]; o.mF32[1]=mF32[1]+r.mF32[1]; o.mF32[2]=mF32[2]+r.mF32[2]; o.mF32[3]=mF32[3]+r.mF32[3]; }
        else static if (op == "-") { o.mF32[0]=mF32[0]-r.mF32[0]; o.mF32[1]=mF32[1]-r.mF32[1]; o.mF32[2]=mF32[2]-r.mF32[2]; o.mF32[3]=mF32[3]-r.mF32[3]; }
        else static if (op == "*") { o.mF32[0]=mF32[0]*r.mF32[0]; o.mF32[1]=mF32[1]*r.mF32[1]; o.mF32[2]=mF32[2]*r.mF32[2]; o.mF32[3]=mF32[3]*r.mF32[3]; }
        else static if (op == "/") { o.mF32[0]=mF32[0]/r.mF32[0]; o.mF32[1]=mF32[1]/r.mF32[1]; o.mF32[2]=mF32[2]/r.mF32[2]; o.mF32[3]=mF32[3]/r.mF32[3]; }
        return o;
    }
    Vec4 opBinary(string op)(float s) const pure nothrow @nogc
    if (op == "*" || op == "/") {
        Vec4 o;
        static if (op == "*") { o.mF32[0]=mF32[0]*s; o.mF32[1]=mF32[1]*s; o.mF32[2]=mF32[2]*s; o.mF32[3]=mF32[3]*s; }
        else { immutable float inv=1.0f/s; o.mF32[0]=mF32[0]*inv; o.mF32[1]=mF32[1]*inv; o.mF32[2]=mF32[2]*inv; o.mF32[3]=mF32[3]*inv; }
        return o;
    }
    Vec4 opBinaryRight(string op)(float s) const pure nothrow @nogc
    if (op == "*") {
        return this * s;
    }
    Vec4 opUnary(string op)() const pure nothrow @nogc
    if (op == "-") {
        return Vec4(-mF32[0], -mF32[1], -mF32[2], -mF32[3]);
    }

    ref Vec4 opOpAssign(string op)(Vec4 r) pure nothrow @nogc
    if (op == "+" || op == "-" || op == "*" || op == "/") {
        static if (op == "+") { mF32[0]+=r.mF32[0]; mF32[1]+=r.mF32[1]; mF32[2]+=r.mF32[2]; mF32[3]+=r.mF32[3]; }
        else static if (op == "-") { mF32[0]-=r.mF32[0]; mF32[1]-=r.mF32[1]; mF32[2]-=r.mF32[2]; mF32[3]-=r.mF32[3]; }
        else static if (op == "*") { mF32[0]*=r.mF32[0]; mF32[1]*=r.mF32[1]; mF32[2]*=r.mF32[2]; mF32[3]*=r.mF32[3]; }
        else static if (op == "/") { mF32[0]/=r.mF32[0]; mF32[1]/=r.mF32[1]; mF32[2]/=r.mF32[2]; mF32[3]/=r.mF32[3]; }
        return this;
    }
    ref Vec4 opOpAssign(string op)(float s) pure nothrow @nogc
    if (op == "*" || op == "/") {
        static if (op == "*") { mF32[0]*=s; mF32[1]*=s; mF32[2]*=s; mF32[3]*=s; }
        else                  { mF32[0]/=s; mF32[1]/=s; mF32[2]/=s; mF32[3]/=s; }
        return this;
    }

    Vec4 SplatX() const pure nothrow @nogc { return sReplicate(mF32[0]); }
    Vec4 SplatY() const pure nothrow @nogc { return sReplicate(mF32[1]); }
    Vec4 SplatZ() const pure nothrow @nogc { return sReplicate(mF32[2]); }
    Vec4 SplatW() const pure nothrow @nogc { return sReplicate(mF32[3]); }

    Vec4 Swizzle(uint X, uint Y, uint Z, uint W)() const pure nothrow @nogc
    if (X < 4 && Y < 4 && Z < 4 && W < 4)
    {
        return Vec4(mF32[X], mF32[Y], mF32[Z], mF32[W]);
    }

    Vec4 Abs() const pure nothrow @nogc {
        return Vec4(fabs(mF32[0]), fabs(mF32[1]), fabs(mF32[2]), fabs(mF32[3]));
    }
    Vec4 Reciprocal() const pure nothrow @nogc { return sOne() / this; }
    Vec4 Sqrt() const pure nothrow @nogc {
        return Vec4(sqrt(mF32[0]), sqrt(mF32[1]), sqrt(mF32[2]), sqrt(mF32[3]));
    }
    Vec4 GetSign() const pure nothrow @nogc {
        return Vec4(mF32[0] < 0 ? -1 : 1, mF32[1] < 0 ? -1 : 1,
                    mF32[2] < 0 ? -1 : 1, mF32[3] < 0 ? -1 : 1);
    }

    Vec4 DotV(Vec4 r) const pure nothrow @nogc {
        immutable float d = Dot(r);
        return Vec4(d, d, d, d);
    }
    float Dot(Vec4 r) const pure nothrow @nogc {
        return mF32[0]*r.mF32[0] + mF32[1]*r.mF32[1] + mF32[2]*r.mF32[2] + mF32[3]*r.mF32[3];
    }

    float LengthSq() const pure nothrow @nogc { return Dot(this); }
    float Length()   const pure nothrow @nogc { return sqrt(LengthSq()); }

    Vec4 Normalized() const pure nothrow @nogc { return this / Length(); }

    void StoreFloat4(Float4* outV) const @trusted pure nothrow @nogc {
        outV.x = mF32[0]; outV.y = mF32[1]; outV.z = mF32[2]; outV.w = mF32[3];
    }

    int GetLowestComponentIndex() const pure nothrow @nogc {
        int idx = 0; float best = mF32[0];
        foreach (i; 1 .. 4) if (mF32[i] < best) { best = mF32[i]; idx = i; }
        return idx;
    }
    int GetHighestComponentIndex() const pure nothrow @nogc {
        int idx = 0; float best = mF32[0];
        foreach (i; 1 .. 4) if (mF32[i] > best) { best = mF32[i]; idx = i; }
        return idx;
    }

    float ReduceMin() const pure nothrow @nogc {
        float m = mF32[0];
        foreach (i; 1 .. 4) if (mF32[i] < m) m = mF32[i];
        return m;
    }
    float ReduceMax() const pure nothrow @nogc {
        float m = mF32[0];
        foreach (i; 1 .. 4) if (mF32[i] > m) m = mF32[i];
        return m;
    }
    float ReduceSum() const pure nothrow @nogc {
        return mF32[0] + mF32[1] + mF32[2] + mF32[3];
    }

    int GetSignBits() const @trusted pure nothrow @nogc {
        int b = 0;
        foreach (i; 0 .. 4) {
            immutable uint32 u = *cast(const uint32*) &mF32[i];
            if (u & 0x80000000u) b |= (1 << i);
        }
        return b;
    }
}
