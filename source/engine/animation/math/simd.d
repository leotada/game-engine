// Ported from ozz-animation (MIT), (c) Guillaume Blanc,
// include/ozz/base/maths/simd_math.h + internal/simd_math_ref-inl.h @ 744eb9d
/// 4-wide float/int vectors and 4x4 matrices. This is the scalar *reference* backend: plain
/// per-lane arithmetic, deterministic across platforms. The estimate functions (`rcpEst`,
/// `rsqrtEst`) use exact division / square root here, so results may differ from upstream's SSE
/// backend within estimate precision; tests compare with tolerances.
module engine.animation.math.simd;

import std.math : sqrt;
import engine.animation.math.half : halfToFloat;

@safe pure nothrow @nogc:

private union FloatBits {
    float f;
    int i;
}

private int bitsOf(float f) { FloatBits b = {f: f}; return b.i; }
private float floatOf(int i) { FloatBits b = {i: i}; return b.f; }

struct SimdInt4 {
    pure nothrow @nogc @safe:
    int x, y, z, w;

    static SimdInt4 load(int x, int y, int z, int w) { return SimdInt4(x, y, z, w); }
    static SimdInt4 load1(int v) { return SimdInt4(v, v, v, v); }

    // Lane masks (all bits set in the selected lanes).
    static SimdInt4 maskF000() { return SimdInt4(-1, 0, 0, 0); }
    static SimdInt4 mask0F00() { return SimdInt4(0, -1, 0, 0); }
    static SimdInt4 mask00F0() { return SimdInt4(0, 0, -1, 0); }
    static SimdInt4 mask000F() { return SimdInt4(0, 0, 0, -1); }
    static SimdInt4 maskSign() { return SimdInt4.load1(cast(int) 0x80000000); }

    ref inout(int) opIndex(size_t i) inout return {
        switch (i) {
            case 0: return x;
            case 1: return y;
            case 2: return z;
            default: return w;
        }
    }

    SimdInt4 opBinary(string op : "&")(SimdInt4 o) const { return SimdInt4(x & o.x, y & o.y, z & o.z, w & o.w); }
    SimdInt4 opBinary(string op : "|")(SimdInt4 o) const { return SimdInt4(x | o.x, y | o.y, z | o.z, w | o.w); }
    SimdInt4 opBinary(string op : "^")(SimdInt4 o) const { return SimdInt4(x ^ o.x, y ^ o.y, z ^ o.z, w ^ o.w); }
}

SimdInt4 shiftL(SimdInt4 v, int bits) {
    return SimdInt4(v.x << bits, v.y << bits, v.z << bits, v.w << bits);
}

struct SimdFloat4 {
    pure nothrow @nogc @safe:
    float x = 0, y = 0, z = 0, w = 0;

    static SimdFloat4 zero() { return SimdFloat4(0, 0, 0, 0); }
    static SimdFloat4 one() { return SimdFloat4(1, 1, 1, 1); }
    static SimdFloat4 load(float x, float y, float z, float w) { return SimdFloat4(x, y, z, w); }
    static SimdFloat4 load1(float v) { return SimdFloat4(v, v, v, v); }
    static SimdFloat4 fromInt(SimdInt4 v) { return SimdFloat4(v.x, v.y, v.z, v.w); }

    SimdFloat4 opBinary(string op)(SimdFloat4 o) const if (op == "+" || op == "-" || op == "*" || op == "/") {
        mixin("return SimdFloat4(x " ~ op ~ " o.x, y " ~ op ~ " o.y, z " ~ op ~ " o.z, w " ~ op ~ " o.w);");
    }
    SimdFloat4 opUnary(string op : "-")() const { return SimdFloat4(-x, -y, -z, -w); }

    ref inout(float) opIndex(size_t i) inout return {
        switch (i) {
            case 0: return x;
            case 1: return y;
            case 2: return z;
            default: return w;
        }
    }
}

/// `a * b + c`.
SimdFloat4 madd(SimdFloat4 a, SimdFloat4 b, SimdFloat4 c) { return a * b + c; }

SimdFloat4 max0(SimdFloat4 v) {
    return SimdFloat4(v.x > 0 ? v.x : 0, v.y > 0 ? v.y : 0, v.z > 0 ? v.z : 0, v.w > 0 ? v.w : 0);
}

SimdFloat4 max(SimdFloat4 a, SimdFloat4 b) {
    return SimdFloat4(a.x > b.x ? a.x : b.x, a.y > b.y ? a.y : b.y, a.z > b.z ? a.z : b.z, a.w > b.w ? a.w : b.w);
}

SimdFloat4 abs(SimdFloat4 v) {
    return SimdFloat4(v.x < 0 ? -v.x : v.x, v.y < 0 ? -v.y : v.y, v.z < 0 ? -v.z : v.z, v.w < 0 ? -v.w : v.w);
}

/// Estimated reciprocal (exact here; 12-bit precision in upstream SSE).
SimdFloat4 rcpEst(SimdFloat4 v) { return SimdFloat4(1 / v.x, 1 / v.y, 1 / v.z, 1 / v.w); }

/// Estimated reciprocal square root.
SimdFloat4 rsqrtEst(SimdFloat4 v) {
    return SimdFloat4(1 / sqrt(v.x), 1 / sqrt(v.y), 1 / sqrt(v.z), 1 / sqrt(v.w));
}

/// Same as `rsqrtEst` followed by a Newton-Raphson step in upstream; exact here.
alias rsqrtEstNR = rsqrtEst;

/// Sign bit of each lane as an integer mask (0 or 0x80000000).
SimdInt4 sign(SimdFloat4 v) {
    return SimdInt4(bitsOf(v.x) & 0x80000000, bitsOf(v.y) & 0x80000000,
                    bitsOf(v.z) & 0x80000000, bitsOf(v.w) & 0x80000000);
}

/// Bitwise operations between a float vector and an integer mask.
SimdFloat4 xorBits(SimdFloat4 v, SimdInt4 m) {
    return SimdFloat4(floatOf(bitsOf(v.x) ^ m.x), floatOf(bitsOf(v.y) ^ m.y),
                      floatOf(bitsOf(v.z) ^ m.z), floatOf(bitsOf(v.w) ^ m.w));
}
SimdFloat4 orBits(SimdFloat4 v, SimdInt4 m) {
    return SimdFloat4(floatOf(bitsOf(v.x) | m.x), floatOf(bitsOf(v.y) | m.y),
                      floatOf(bitsOf(v.z) | m.z), floatOf(bitsOf(v.w) | m.w));
}
SimdFloat4 andBits(SimdFloat4 v, SimdInt4 m) {
    return SimdFloat4(floatOf(bitsOf(v.x) & m.x), floatOf(bitsOf(v.y) & m.y),
                      floatOf(bitsOf(v.z) & m.z), floatOf(bitsOf(v.w) & m.w));
}
SimdFloat4 andNotBits(SimdFloat4 v, SimdInt4 m) {
    return SimdFloat4(floatOf(bitsOf(v.x) & ~m.x), floatOf(bitsOf(v.y) & ~m.y),
                      floatOf(bitsOf(v.z) & ~m.z), floatOf(bitsOf(v.w) & ~m.w));
}

/// Four binary16 values (low 16 bits of each lane) to floats.
SimdFloat4 halfToFloat4(SimdInt4 h) {
    return SimdFloat4(halfToFloat(cast(ushort)(h.x & 0xffff)), halfToFloat(cast(ushort)(h.y & 0xffff)),
                      halfToFloat(cast(ushort)(h.z & 0xffff)), halfToFloat(cast(ushort)(h.w & 0xffff)));
}

/// Upstream's `Transpose16x16`: `out[4*i + j][k] = in[4*j + k][i]`. With `in` holding 4 SoA
/// matrix columns (4 component vectors each), `out` receives 4 AoS matrices (4 column vectors each).
void transpose16x16(const(SimdFloat4)[] input, SimdFloat4[] output) {
    assert(input.length >= 16 && output.length >= 16);
    foreach (i; 0 .. 4) {
        foreach (j; 0 .. 4) {
            foreach (k; 0 .. 4) {
                output[i * 4 + j][k] = input[j * 4 + k][i];
            }
        }
    }
}

/// 4x4 matrix, four column vectors. Layout-compatible with `engine.math.Mat4` (column-major).
struct Float4x4 {
    pure nothrow @nogc @safe:
    SimdFloat4[4] cols;

    static Float4x4 identity() {
        Float4x4 r;
        r.cols[0] = SimdFloat4(1, 0, 0, 0);
        r.cols[1] = SimdFloat4(0, 1, 0, 0);
        r.cols[2] = SimdFloat4(0, 0, 1, 0);
        r.cols[3] = SimdFloat4(0, 0, 0, 1);
        return r;
    }

    Float4x4 opBinary(string op : "*")(const Float4x4 b) const {
        Float4x4 r;
        foreach (i; 0 .. 4) {
            r.cols[i] = cols[0] * SimdFloat4.load1(b.cols[i].x)
                      + cols[1] * SimdFloat4.load1(b.cols[i].y)
                      + cols[2] * SimdFloat4.load1(b.cols[i].z)
                      + cols[3] * SimdFloat4.load1(b.cols[i].w);
        }
        return r;
    }
}

unittest {
    // Vector ops.
    auto a = SimdFloat4.load(1, 2, 3, 4);
    auto b = SimdFloat4.load(4, 3, 2, 1);
    assert(a + b == SimdFloat4.load1(5));
    assert(a * b == SimdFloat4.load(4, 6, 6, 4));
    assert(madd(a, b, SimdFloat4.one()) == SimdFloat4.load(5, 7, 7, 5));
    assert(max0(SimdFloat4.load(-1, 2, -0.5f, 3)) == SimdFloat4.load(0, 2, 0, 3));
    assert(rcpEst(SimdFloat4.load1(4)) == SimdFloat4.load1(0.25f));
    assert(rsqrtEst(SimdFloat4.load1(4)) == SimdFloat4.load1(0.5f));
}

unittest {
    // Sign mask + xor flips only negative lanes' sign (used for shortest-path quaternions).
    auto v = SimdFloat4.load(-1, 2, -3, 4);
    auto s = sign(v);
    assert(s.x != 0 && s.y == 0 && s.z != 0 && s.w == 0);
    assert(xorBits(SimdFloat4.load(1, 1, 1, 1), s) == SimdFloat4.load(-1, 1, -1, 1));
    assert(andNotBits(SimdFloat4.load(1, 2, 3, 4), SimdInt4.maskF000()) == SimdFloat4.load(0, 2, 3, 4));
    assert(orBits(SimdFloat4.zero(), SimdInt4.maskSign()).x == -0.0f);
    assert(shiftL(SimdInt4.load1(1), 31) == SimdInt4.maskSign());
}

unittest {
    // halfToFloat4 only looks at the low 16 bits.
    auto h = SimdInt4.load(0x3c00, 0xffff_c000, 0x3800, 0);
    assert(halfToFloat4(h) == SimdFloat4.load(1, -2, 0.5f, 0));
}

unittest {
    // transpose16x16: 4 SoA columns -> 4 AoS matrices.
    SimdFloat4[16] src;
    foreach (i; 0 .. 16) src[i] = SimdFloat4.load(i * 4, i * 4 + 1, i * 4 + 2, i * 4 + 3);
    SimdFloat4[16] dst;
    transpose16x16(src[], dst[]);
    // out[i*4 + j][k] == in[j*4 + k][i]
    assert(dst[0] == SimdFloat4.load(0, 4, 8, 12));
    assert(dst[1] == SimdFloat4.load(16, 20, 24, 28));
    assert(dst[4] == SimdFloat4.load(1, 5, 9, 13));
}

unittest {
    auto id = Float4x4.identity();
    auto m = Float4x4.identity();
    m.cols[3] = SimdFloat4(1, 2, 3, 1);
    assert((id * m).cols == m.cols);
    assert((m * id).cols == m.cols);
    auto mm = m * m;
    assert(mm.cols[3] == SimdFloat4(2, 4, 6, 1));
    static assert(Float4x4.sizeof == 64);
}
