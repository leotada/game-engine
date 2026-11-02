// Ported from meshoptimizer v1.3 (src/vertexcodec.cpp, src/indexcodec.cpp), Copyright (c) 2016-2026 Arseny Kapoulkine, MIT License.
/// Bit helpers shared by the meshoptimizer port: float punning, zigzag, varint.
module engine.meshopt.internal.bits;

@safe:

/// IEEE-754 binary32 bit pattern. Union pun at runtime; arithmetic in CTFE.
uint floatBits(float f) pure nothrow @nogc {
    if (__ctfe)
        return ctfeFloatBits(f);
    union Pun { float f; uint u; }
    Pun p;
    p.f = f;
    return p.u;
}

/// Inverse of `floatBits`.
float bitsFloat(uint u) pure nothrow @nogc {
    if (__ctfe)
        return ctfeBitsFloat(u);
    union Pun { float f; uint u; }
    Pun p;
    p.u = u;
    return p.f;
}

private uint ctfeFloatBits(float f) pure nothrow @nogc {
    if (f != f)
        return 0x7fc0_0000;
    uint sign;
    if (f < 0 || (f == 0 && 1 / f < 0)) {
        sign = 0x8000_0000;
        f = -f;
    }
    if (f == 0)
        return sign;
    if (f > 3.402823466e+38f)
        return sign | 0x7f80_0000;
    int exp;
    if (f >= 2) {
        while (f >= 2) {
            f *= 0.5f;
            exp++;
        }
    } else {
        while (f < 1 && exp > -150) {
            f *= 2;
            exp--;
        }
    }
    if (exp <= -127) {
        // Denormals are not required for the CTFE static asserts.
        return sign;
    }
    f -= 1;
    uint mant;
    foreach (i; 0 .. 23) {
        f *= 2;
        if (f >= 1) {
            mant |= 1u << (22 - i);
            f -= 1;
        }
    }
    int biased = exp + 127;
    if (biased >= 255)
        return sign | 0x7f80_0000;
    return sign | (cast(uint) biased << 23) | mant;
}

private float ctfeBitsFloat(uint u) pure nothrow @nogc {
    uint sign = u >> 31;
    int exp = cast(int)((u >> 23) & 255);
    uint mant = u & 0x7f_ffff;
    if (exp == 255)
        return mant ? float.nan : (sign ? -float.infinity : float.infinity);
    if (exp == 0)
        return sign ? -0.0f : 0.0f;
    float value = 1;
    float bit = 0.5f;
    foreach (i; 0 .. 23) {
        if (mant & (1u << (22 - i)))
            value += bit;
        bit *= 0.5f;
    }
    int e = exp - 127;
    if (e > 0) {
        foreach (_; 0 .. e)
            value *= 2;
    } else if (e < 0) {
        foreach (_; 0 .. -e)
            value *= 0.5f;
    }
    return sign ? -value : value;
}

/// Zigzag from `vertexcodec.cpp`. Unsigned values; the sign bit is the high bit of `T`.
T zigzag(T)(T v) pure nothrow @nogc
if (is(T == ubyte) || is(T == ushort) || is(T == uint) || is(T == ulong)) {
    static if (T.sizeof < 4) {
        enum bits = T.sizeof * 8;
        int vi = v;
        int r = (0 - (vi >> (bits - 1))) ^ (vi << 1);
        return cast(T) r;
    } else static if (is(T == uint)) {
        return (0 - (v >> 31)) ^ (v << 1);
    } else {
        return (0UL - (v >> 63)) ^ (v << 1);
    }
}

/// Inverse of `zigzag`.
T unzigzag(T)(T v) pure nothrow @nogc
if (is(T == ubyte) || is(T == ushort) || is(T == uint) || is(T == ulong)) {
    static if (T.sizeof < 4) {
        int vi = v;
        int r = (0 - (vi & 1)) ^ (vi >> 1);
        return cast(T) r;
    } else static if (is(T == uint)) {
        return (0 - (v & 1)) ^ (v >> 1);
    } else {
        return (0UL - (v & 1)) ^ (v >> 1);
    }
}

/// Rotate left, matching `vertexcodec.cpp` `rotate` for `r` in `0 .. 31`.
uint rotl(uint v, int r) pure nothrow @nogc {
    return (v << r) | (v >> ((32 - r) & 31));
}

/// Rotate left of a 64-bit word (`vertexfilter.cpp` `_rotl64` fallback).
ulong rotl64(ulong v, int r) pure nothrow @nogc {
    int s = r & 63;
    if (s == 0)
        return v;
    return (v << s) | (v >> (64 - s));
}

/// Population count of the low 32 bits.
int popcount(uint x) pure nothrow @nogc {
    x -= (x >> 1) & 0x5555_5555;
    x = (x & 0x3333_3333) + ((x >> 2) & 0x3333_3333);
    x = (x + (x >> 4)) & 0x0f0f_0f0f;
    return cast(int)((x * 0x0101_0101) >> 24);
}

/// 7-bit group varint from `indexcodec.cpp` `encodeVByte`. Returns the new offset.
size_t encodeVarint(ubyte[] dst, size_t offset, uint v) pure nothrow @nogc {
    do {
        assert(offset < dst.length);
        dst[offset++] = cast(ubyte)((v & 127) | (v > 127 ? 128 : 0));
        v >>= 7;
    } while (v);
    return offset;
}

/// Inverse of `encodeVarint`. Stops at `src.length` so a short buffer cannot be read past.
uint decodeVarint(const(ubyte)[] src, ref size_t offset) pure nothrow @nogc {
    assert(offset < src.length);
    ubyte lead = src[offset++];
    if (lead < 128)
        return lead;
    uint result = lead & 127;
    uint shift = 7;
    foreach (_; 0 .. 4) {
        if (offset >= src.length)
            break;
        ubyte group = src[offset++];
        result |= (group & 127u) << shift;
        shift += 7;
        if (group < 128)
            break;
    }
    return result;
}

/// Signed index delta zigzag used by `encodeIndex` (`(d << 1) ^ (int(d) >> 31)`).
uint encodeIndexDelta(uint index, uint last) pure nothrow @nogc {
    uint d = index - last;
    return (d << 1) ^ (cast(uint)(cast(int) d >> 31));
}

/// Inverse of `encodeIndexDelta` given the already-decoded varint and the previous index.
uint decodeIndexDelta(uint v, uint last) pure nothrow @nogc {
    uint d = (v >> 1) ^ cast(uint)(-cast(int)(v & 1));
    return last + d;
}

@safe pure nothrow @nogc unittest {
    assert(floatBits(1.0f) == 0x3f80_0000);
    assert(bitsFloat(0x3f80_0000) == 1.0f);
    assert(floatBits(bitsFloat(0x8000_0000)) == 0x8000_0000);

    assert(zigzag(0u) == 0);
    assert(zigzag(1u) == 2);
    assert(zigzag(2u) == 4);
    assert(zigzag(uint.max) == 1);
    assert(unzigzag(zigzag(0u)) == 0);
    assert(unzigzag(zigzag(1u)) == 1);
    assert(unzigzag(zigzag(uint.max)) == uint.max);
    assert(zigzag(cast(ubyte) 1) == 2);
    assert(unzigzag(cast(ubyte) 1) == ubyte.max);

    assert(rotl(0x1234_5678, 0) == 0x1234_5678);
    assert(rotl(0x1234_5678, 4) == 0x2345_6781);
    assert(rotl64(1, 1) == 2);
    assert(rotl64(0x8000_0000_0000_0000, 1) == 1);

    assert(popcount(0) == 0);
    assert(popcount(1) == 1);
    assert(popcount(0x0f0f_0f0f) == 16);
    assert(popcount(uint.max) == 32);

    ubyte[8] buf;
    size_t n = encodeVarint(buf[], 0, 0);
    assert(n == 1 && buf[0] == 0);
    n = encodeVarint(buf[], 0, 127);
    assert(n == 1 && buf[0] == 127);
    n = encodeVarint(buf[], 0, 128);
    assert(n == 2 && buf[0] == 0x80 && buf[1] == 1);
    n = encodeVarint(buf[], 0, uint.max);
    size_t o = 0;
    assert(decodeVarint(buf[0 .. n], o) == uint.max && o == n);

    assert(decodeIndexDelta(encodeIndexDelta(5, 3), 3) == 5);
    assert(decodeIndexDelta(encodeIndexDelta(1, 4), 4) == 1);
}
