// Jolt — Math/UVec4.h port. Minimal subset used by Vec3/Vec4 comparisons.
//
// The full UVec4 has 50+ operations including byte/word expansions, gather,
// shifts, and SIMD sort helpers. Only the essentials needed by the basic
// math types are ported here; the rest will land alongside the consumers
// that need them.
//
// Source: ref/JoltPhysics/Jolt/Math/UVec4.h.
module engine.jph.math.uvec4;

import engine.jph.core.types;

@safe:

align(16)
struct UVec4 {
@safe:
    union {
        uint32[4] mU32 = [0, 0, 0, 0];
    }

    this(uint32 inX, uint32 inY, uint32 inZ, uint32 inW) pure nothrow @nogc {
        mU32[0] = inX; mU32[1] = inY; mU32[2] = inZ; mU32[3] = inW;
    }

    static UVec4 sZero() pure nothrow @nogc { return UVec4(0, 0, 0, 0); }

    static UVec4 sReplicate(uint32 inV) pure nothrow @nogc {
        return UVec4(inV, inV, inV, inV);
    }

    static UVec4 sEquals(UVec4 a, UVec4 b) pure nothrow @nogc {
        return UVec4(
            a.mU32[0] == b.mU32[0] ? 0xFFFFFFFFu : 0,
            a.mU32[1] == b.mU32[1] ? 0xFFFFFFFFu : 0,
            a.mU32[2] == b.mU32[2] ? 0xFFFFFFFFu : 0,
            a.mU32[3] == b.mU32[3] ? 0xFFFFFFFFu : 0);
    }

    static UVec4 sOr (UVec4 a, UVec4 b) pure nothrow @nogc {
        return UVec4(a.mU32[0]|b.mU32[0], a.mU32[1]|b.mU32[1],
                     a.mU32[2]|b.mU32[2], a.mU32[3]|b.mU32[3]);
    }
    static UVec4 sXor(UVec4 a, UVec4 b) pure nothrow @nogc {
        return UVec4(a.mU32[0]^b.mU32[0], a.mU32[1]^b.mU32[1],
                     a.mU32[2]^b.mU32[2], a.mU32[3]^b.mU32[3]);
    }
    static UVec4 sAnd(UVec4 a, UVec4 b) pure nothrow @nogc {
        return UVec4(a.mU32[0]&b.mU32[0], a.mU32[1]&b.mU32[1],
                     a.mU32[2]&b.mU32[2], a.mU32[3]&b.mU32[3]);
    }
    static UVec4 sNot(UVec4 a) pure nothrow @nogc {
        return UVec4(~a.mU32[0], ~a.mU32[1], ~a.mU32[2], ~a.mU32[3]);
    }

    /// Component-wise select. Highest bit of inControl picks `set`, else `notSet`.
    static UVec4 sSelect(UVec4 notSet, UVec4 set, UVec4 ctl) pure nothrow @nogc {
        UVec4 r;
        foreach (i; 0 .. 4) {
            immutable mask = (ctl.mU32[i] & 0x80000000u) ? 0xFFFFFFFFu : 0u;
            r.mU32[i] = (notSet.mU32[i] & ~mask) | (set.mU32[i] & mask);
        }
        return r;
    }

    bool opEquals(const UVec4 r) const pure nothrow @nogc {
        return mU32[0] == r.mU32[0] && mU32[1] == r.mU32[1]
            && mU32[2] == r.mU32[2] && mU32[3] == r.mU32[3];
    }

    uint32 GetX() const pure nothrow @nogc { return mU32[0]; }
    uint32 GetY() const pure nothrow @nogc { return mU32[1]; }
    uint32 GetZ() const pure nothrow @nogc { return mU32[2]; }
    uint32 GetW() const pure nothrow @nogc { return mU32[3]; }

    void SetX(uint32 v) pure nothrow @nogc { mU32[0] = v; }
    void SetY(uint32 v) pure nothrow @nogc { mU32[1] = v; }
    void SetZ(uint32 v) pure nothrow @nogc { mU32[2] = v; }
    void SetW(uint32 v) pure nothrow @nogc { mU32[3] = v; }

    uint32 opIndex(uint i) const pure nothrow @nogc
    in (i < 4)
    {
        return mU32[i];
    }

    UVec4 SplatX() const pure nothrow @nogc { return sReplicate(mU32[0]); }
    UVec4 SplatY() const pure nothrow @nogc { return sReplicate(mU32[1]); }
    UVec4 SplatZ() const pure nothrow @nogc { return sReplicate(mU32[2]); }
    UVec4 SplatW() const pure nothrow @nogc { return sReplicate(mU32[3]); }

    UVec4 opBinary(string op : "+")(UVec4 r) const pure nothrow @nogc {
        return UVec4(mU32[0]+r.mU32[0], mU32[1]+r.mU32[1],
                     mU32[2]+r.mU32[2], mU32[3]+r.mU32[3]);
    }
    UVec4 opBinary(string op : "-")(UVec4 r) const pure nothrow @nogc {
        return UVec4(mU32[0]-r.mU32[0], mU32[1]-r.mU32[1],
                     mU32[2]-r.mU32[2], mU32[3]-r.mU32[3]);
    }
    UVec4 opBinary(string op : "*")(UVec4 r) const pure nothrow @nogc {
        return UVec4(mU32[0]*r.mU32[0], mU32[1]*r.mU32[1],
                     mU32[2]*r.mU32[2], mU32[3]*r.mU32[3]);
    }

    /// True iff every lane has its high bit set.
    bool TestAllTrue() const pure nothrow @nogc {
        return ((mU32[0] & mU32[1] & mU32[2] & mU32[3]) & 0x80000000u) != 0;
    }
    /// True iff X, Y or Z lane has its high bit set.
    bool TestAnyXYZTrue() const pure nothrow @nogc {
        return ((mU32[0] | mU32[1] | mU32[2]) & 0x80000000u) != 0;
    }
    bool TestAnyTrue() const pure nothrow @nogc {
        return ((mU32[0] | mU32[1] | mU32[2] | mU32[3]) & 0x80000000u) != 0;
    }
    bool TestAllXYZTrue() const pure nothrow @nogc {
        return ((mU32[0] & mU32[1] & mU32[2]) & 0x80000000u) != 0;
    }

    int CountTrues() const pure nothrow @nogc {
        int n = 0;
        foreach (i; 0 .. 4) if (mU32[i] & 0x80000000u) ++n;
        return n;
    }

    /// Bit i is set when lane i's high bit is set.
    int GetTrues() const pure nothrow @nogc {
        int b = 0;
        foreach (i; 0 .. 4) if (mU32[i] & 0x80000000u) b |= (1 << i);
        return b;
    }
}
