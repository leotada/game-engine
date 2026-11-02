// Ported from meshoptimizer v1.3 (src/quantization.cpp), Copyright (c) 2016-2026 Arseny Kapoulkine, MIT License.
/// Quantization helpers. Not `engine.animation.math.half` (that decoder keeps denormals).
module engine.meshopt.quantize;

import core.math : fabs;
import engine.meshopt.internal.bits : bitsFloat, floatBits;

@safe:

private float libmFloor(float x) pure nothrow @nogc @trusted {
    import core.stdc.math : floorf;
    alias F = float function(float) pure nothrow @nogc @trusted;
    return (cast(F) &floorf)(x);
}

private float libmCeil(float x) pure nothrow @nogc @trusted {
    import core.stdc.math : ceilf;
    alias F = float function(float) pure nothrow @nogc @trusted;
    return (cast(F) &ceilf)(x);
}

private float libmFrexp(float x, out int exp) pure nothrow @nogc @trusted {
    import core.stdc.math : frexpf;
    alias F = float function(float, int*) pure nothrow @nogc @trusted;
    return (cast(F) &frexpf)(x, &exp);
}

private float libmLdexp(float x, int exp) pure nothrow @nogc @trusted {
    import core.stdc.math : ldexpf;
    alias F = float function(float, int) pure nothrow @nogc @trusted;
    return (cast(F) &ldexpf)(x, exp);
}

private float floorF(float x) pure nothrow @nogc {
    if (__ctfe)
        return floorCtfe(x);
    return libmFloor(x);
}

private float ceilF(float x) pure nothrow @nogc {
    if (__ctfe)
        return ceilCtfe(x);
    return libmCeil(x);
}

private float frexpF(float x, out int exp) pure nothrow @nogc {
    if (__ctfe)
        return frexpCtfe(x, exp);
    return libmFrexp(x, exp);
}

private float ldexpF(float x, int exp) pure nothrow @nogc {
    if (__ctfe)
        return ldexpCtfe(x, exp);
    return libmLdexp(x, exp);
}

private float floorCtfe(float x) pure nothrow @nogc {
    if (x != x)
        return x;
    if (x == 0)
        return x;
    if (x >= 8388608.0f || x <= -8388608.0f)
        return x;
    long i = cast(long) x;
    float t = cast(float) i;
    if (x < 0 && t != x)
        return cast(float)(i - 1);
    return t;
}

private float ceilCtfe(float x) pure nothrow @nogc {
    if (x != x)
        return x;
    if (x == 0)
        return x;
    if (x >= 8388608.0f || x <= -8388608.0f)
        return x;
    long i = cast(long) x;
    float t = cast(float) i;
    if (x > 0 && t != x)
        return cast(float)(i + 1);
    return t;
}

private float frexpCtfe(float x, out int exp) pure nothrow @nogc {
    if (x == 0 || x != x) {
        exp = 0;
        return x;
    }
    uint u = floatBits(x);
    uint sign = u & 0x8000_0000;
    int e = cast(int)((u >> 23) & 255);
    uint m = u & 0x7f_ffff;
    if (e == 255) {
        exp = 0;
        return x;
    }
    if (e == 0) {
        int shift = 0;
        while ((m & 0x80_0000) == 0) {
            m <<= 1;
            shift++;
        }
        m &= 0x7f_ffff;
        exp = -125 - shift;
        return bitsFloat(sign | (126u << 23) | m);
    }
    exp = e - 126;
    return bitsFloat(sign | (126u << 23) | m);
}

private float ldexpCtfe(float x, int n) pure nothrow @nogc {
    if (x == 0 || x != x)
        return x;
    uint u = floatBits(x);
    uint sign = u & 0x8000_0000;
    int e = cast(int)((u >> 23) & 255);
    uint m = u & 0x7f_ffff;
    if (e == 255)
        return x;
    if (e == 0) {
        int xe;
        float frac = frexpCtfe(x, xe);
        return ldexpCtfe(frac, xe + n);
    }
    int ne = e + n;
    if (ne >= 255)
        return bitsFloat(sign | 0x7f80_0000);
    if (ne <= 0) {
        uint full = (1u << 23) | m;
        int shift = 1 - ne;
        if (shift >= 32)
            return bitsFloat(sign);
        full >>= shift;
        return bitsFloat(sign | full);
    }
    return bitsFloat(sign | (cast(uint) ne << 23) | m);
}

/// Quantize a float in `[0..1]` to an N-bit unorm. Header inline `meshopt_quantizeUnorm`.
/// Comparisons match C++ so a NaN input collapses to 0.
int quantizeUnorm(float v, int n) pure nothrow @nogc {
    float scale = cast(float)((1 << n) - 1);
    v = (v >= 0) ? v : 0;
    v = (v <= 1) ? v : 1;
    return cast(int)(v * scale + 0.5f);
}

/// Quantize a float in `[-1..1]` to an N-bit snorm. Header inline `meshopt_quantizeSnorm`.
/// Comparisons match C++ so a NaN input collapses to -1.
int quantizeSnorm(float v, int n) pure nothrow @nogc {
    float scale = cast(float)((1 << (n - 1)) - 1);
    float round = (v >= 0) ? 0.5f : -0.5f;
    v = (v >= -1) ? v : -1;
    v = (v <= 1) ? v : 1;
    return cast(int)(v * scale + round);
}

/// Half-precision quantize. Flushes denormals, canonicalizes NaN to qNaN.
ushort quantizeHalf(float v) pure nothrow @nogc {
    uint ui = floatBits(v);
    int s = (ui >> 16) & 0x8000;
    int em = cast(int)(ui & 0x7fff_ffff);

    // bias exponent and round to nearest; 112 is relative exponent bias (127-15)
    int h = (em - (112 << 23) + (1 << 12)) >> 13;

    // underflow: flush to zero; 113 encodes exponent -14
    h = (em < (113 << 23)) ? 0 : h;

    // overflow: infinity; 143 encodes exponent 16
    h = (em >= (143 << 23)) ? 0x7c00 : h;

    // NaN; note that we convert all types of NaN to qNaN
    h = (em > (255 << 23)) ? 0x7e00 : h;

    return cast(ushort)(s | h);
}

/// Quantize to `n` explicit mantissa bits. `n` is in `0 .. 23`.
float quantizeFloat(float v, int n) pure nothrow @nogc {
    assert(n >= 0 && n <= 23);
    uint ui = floatBits(v);
    int mask = (1 << (23 - n)) - 1;
    int round = (1 << (23 - n)) >> 1;
    int e = ui & 0x7f80_0000;
    uint rui = (ui + cast(uint) round) & cast(uint)~mask;

    // round all numbers except inf/nan; this is important to make sure nan doesn't overflow into -0
    ui = e == 0x7f80_0000 ? ui : rui;

    // flush denormals to zero
    ui = e == 0 ? 0 : ui;
    return bitsFloat(ui);
}

/// Inverse of `quantizeHalf`. Denormals flush to zero. NaN payload is preserved
/// for values this function itself did not canonicalize on the way in.
float dequantizeHalf(ushort h) pure nothrow @nogc {
    uint s = (h & 0x8000u) << 16;
    int em = h & 0x7fff;

    // bias exponent and pad mantissa with 0; 112 is relative exponent bias (127-15)
    int r = (em + (112 << 10)) << 13;

    // denormal: flush to zero
    r = (em < (1 << 10)) ? 0 : r;

    // infinity/NaN; note that we preserve NaN payload as a byproduct of unifying inf/nan cases
    // 112 is an exponent bias fixup; since we already applied it once, applying it twice converts 31 to 255
    r += (em >= (31 << 10)) ? (112 << 23) : 0;

    return bitsFloat(s | r);
}

/**
 * Shared exponent for a position bounding box.
 * `minExp >= -126`, `maxBits` is in `2 .. 24`.
 */
int computePositionExponent(const(float)[3] minv, const(float)[3] maxv, int minExp, int maxBits) pure nothrow @nogc {
    assert(minExp >= -126);
    assert(maxBits >= 2 && maxBits <= 24);

    int exp = minExp;
    float maxc = 0;
    foreach (k; 0 .. 3) {
        float a = fabs(minv[k]);
        float b = fabs(maxv[k]);
        if (maxc < a)
            maxc = a;
        if (maxc < b)
            maxc = b;
    }

    int maxcExp;
    float maxcFr = frexpF(maxc, maxcExp);

    // maxc is representable as 2^(maxc_exp-24) * 24-bit unsigned integer.
    // A 24-bit signed grid drops the last bit. Rounding when the mantissa is
    // 1.111... can bump the exponent, so offset that corner.
    int maxcOff = 23 - (maxcFr >= 1.0f - float.epsilon / 2);
    int candidate = maxcExp - maxcOff;
    if (exp < candidate)
        exp = candidate;

    float scale = ldexpF(1.0f, -exp);
    float range = 0;
    foreach (k; 0 .. 3) {
        float a = floorF(minv[k] * scale);
        float v = ceilF(maxv[k] * scale);
        float d = v - a;
        if (range < d)
            range = d;
    }

    int rangeExp;
    float rangeFr = frexpF(range, rangeExp);
    if (rangeExp > maxBits)
        exp += rangeExp - maxBits;
    if (rangeExp > maxBits && rangeFr >= 1.0f - 1.0f / cast(float)((1 << maxBits) - 1))
        exp += 1;
    return exp;
}

@safe pure nothrow @nogc unittest {
    static assert(quantizeHalf(1.0f) == 0x3c00);
    static assert(quantizeHalf(0.0f) == 0);
    static assert(quantizeUnorm(0.0f, 8) == 0);
    static assert(quantizeUnorm(1.0f, 8) == 255);
    static assert(quantizeSnorm(0.0f, 8) == 0);
    static assert(quantizeSnorm(1.0f, 8) == 127);
    static assert(quantizeSnorm(-1.0f, 8) == -127);
    static assert(dequantizeHalf(0x3c00) == 1.0f);

    // Upstream demo/tests.cpp quantizeFloat / quantizeHalf / dequantizeHalf.
    assert(quantizeFloat(1.2345f, 23) == 1.2345f);
    assert(quantizeFloat(1.2345f, 16) == 1.2344971f);
    assert(quantizeFloat(1.2345f, 8) == 1.2343750f);
    assert(quantizeFloat(1.2345f, 4) == 1.25f);
    assert(quantizeFloat(1.2345f, 1) == 1.0f);
    assert(quantizeFloat(1.0f, 0) == 1.0f);
    assert(quantizeFloat(float.infinity, 0) == float.infinity);
    assert(quantizeFloat(-float.infinity, 0) == -float.infinity);
    float nanf = quantizeFloat(float.nan, 8);
    assert(nanf != nanf);

    assert(quantizeHalf(1.2345f) == 0x3cf0);
    assert(quantizeHalf(65535.0f) == 0x7c00);
    assert(quantizeHalf(-65535.0f) == 0xfc00);
    assert(quantizeHalf(65000.0f) == 0x7bef);
    assert(quantizeHalf(-65000.0f) == 0xfbef);
    assert(quantizeHalf(0.125f) == 0x3000);
    assert(quantizeHalf(-0.125f) == 0xb000);
    assert(quantizeHalf(1e-4f) == 0x068e);
    assert(quantizeHalf(-1e-4f) == 0x868e);
    assert(quantizeHalf(1e-5f) == 0);
    assert(quantizeHalf(-1e-5f) == 0x8000);
    assert(quantizeHalf(1e-20f) == 0);
    assert(quantizeHalf(-1e-20f) == 0x8000);
    assert(quantizeHalf(1e20f) == 0x7c00);
    assert(quantizeHalf(-1e20f) == 0xfc00);
    assert(quantizeHalf(float.infinity) == 0x7c00);
    assert(quantizeHalf(-float.infinity) == 0xfc00);
    ushort nanh = quantizeHalf(float.nan);
    assert(nanh == 0x7e00 || nanh == 0xfe00);

    assert(dequantizeHalf(0x3cf0) == 1.234375f);
    assert(dequantizeHalf(0x7bef) == 64992.0f);
    assert(dequantizeHalf(0xfbef) == -64992.0f);
    assert(dequantizeHalf(0x3000) == 0.125f);
    assert(dequantizeHalf(0xb000) == -0.125f);
    assert(floatBits(dequantizeHalf(0x00ff)) == floatBits(0.0f));
    assert(floatBits(dequantizeHalf(0x80ff)) == 0x8000_0000);
    assert(dequantizeHalf(0x7c00) == float.infinity);
    assert(dequantizeHalf(0xfc00) == -float.infinity);
    float nanOut = dequantizeHalf(0x7e00);
    assert(nanOut != nanOut);

    assert(quantizeUnorm(-0.1f, 8) == 0);
    assert(quantizeUnorm(1.1f, 8) == 255);
    assert(quantizeUnorm(0.5f, 8) == 128);
    assert(quantizeSnorm(-1.1f, 8) == -127);
    assert(quantizeSnorm(1.1f, 8) == 127);

    // Upstream demo/tests.cpp computePositionExponent.
    assert(computePositionExponent([-1, 2, 10], [1, 2.5f, 20], -16, 16) == -12);
    assert(computePositionExponent([-1, 2, 10], [1, 2.5f, 20], -10, 16) == -10);
    assert(computePositionExponent(
        [-3.14159265f, -2.7182818f, -1.41321356f],
        [3.14159265f, 2.7182818f, 1.41321356f], -16, 16) == -13);
    assert(computePositionExponent([1_000_000, 0, 0], [1_000_000, 0, 0], -16, 16) == -3);
    assert(computePositionExponent([-1_000_000, 0, 0], [-1_000_000, 0, 0], -16, 16) == -3);
    assert(computePositionExponent([0, -1000, 0], [1e-3f, 1000, 1], -16, 16) == -5);
    assert(computePositionExponent([0, 0, 0], [0, 0, 0], -16, 16) == -16);
    assert(computePositionExponent([0, 0, 0], [65535, 0, 0], 0, 16) == 0);
    assert(computePositionExponent([0, 0, 0], [65536, 0, 0], 0, 16) == 1);
    assert(computePositionExponent([0.4f, 0, 0], [65535.5625f, 0, 0], 0, 16) == 1);
    assert(computePositionExponent([-1, 0, 0], [131069, 0, 0], 0, 16) == 2);
    assert(computePositionExponent([8388607, 0, 0], [8388607, 0, 0], 0, 16) == 0);
    assert(computePositionExponent([8388608, 0, 0], [8388608, 0, 0], 0, 16) == 1);
    assert(computePositionExponent([-8388608, 0, 0], [-8388608, 0, 0], 0, 16) == 1);
    assert(computePositionExponent([1, 0, 0], [1, 0, 0], -23, 16) == -22);
    assert(computePositionExponent([-1, 0, 0], [-1, 0, 0], -23, 16) == -22);
    assert(computePositionExponent([0.5f, -0.5f, 2.5f], [0.5f, -0.5f, 2.5f], 0, 16) == 0);
    assert(computePositionExponent([-0.5f, 0, 0], [0.5f, 0, 0], 0, 16) == 0);
    assert(computePositionExponent([0, 0, 0], [2097151, 0, 0], 0, 21) == 0);
    assert(computePositionExponent([8388607.5f, 0, 0], [8388607.5f, 0, 0], 0, 16) == 1);
}

version (MeshoptExhaustive)
@safe nothrow unittest {
    // Full 2^32 sweep. Compare against committed goldens is not this path:
    // the oracle tool runs the same loop against the C++ library.
    uint bits = 0;
    do {
        float f = bitsFloat(bits);
        ushort h = quantizeHalf(f);
        float back = dequantizeHalf(h);
        if (f == f && f != float.infinity && f != -float.infinity && fabs(f) >= 6e-5f && fabs(f) <= 65504.0f) {
            float err = fabs(back - f);
            float scale = fabs(f) > 1 ? fabs(f) : 1;
            assert(err / scale < 1e-3f);
        }
        if (bits == uint.max)
            break;
        bits++;
    } while (true);
}

@safe unittest {
    checkGolden("quantizeHalf");
    checkGolden("quantizeFloat");
    checkGolden("dequantizeHalf");
    checkGolden("quantizeUnorm");
    checkGolden("quantizeSnorm");
    checkGolden("computePositionExponent");
}

/// FNV-1a of a golden function name. The oracle writes the same hash.
uint goldenParamsHash(string name) pure nothrow @nogc {
    uint h = 2166136261;
    foreach (char c; name)
        h = (h ^ c) * 16777619;
    return h;
}

private void checkGolden(string name) @trusted {
    import std.file : read;
    ubyte[] file = cast(ubyte[]) read("tests/meshopt/golden/" ~ name ~ ".bin");
    assert(file.length >= 52, "golden too small: " ~ name);
    assert(file[0 .. 8] == cast(const(ubyte)[])"MOPTGLD1", name);
    assert(loadU32(file, 8) == 1030, name);
    char[32] got;
    got[] = cast(char[]) file[12 .. 44];
    char[32] expect;
    expect[] = 0;
    expect[0 .. name.length] = name[];
    assert(got == expect, name);
    assert(loadU32(file, 44) == goldenParamsHash(name), name);
    uint count = loadU32(file, 48);
    size_t at = 52;
    foreach (i; 0 .. count) {
        if (name == "quantizeHalf") {
            uint inBits = loadU32(file, at);
            uint half = loadU32(file, at + 4);
            at += 8;
            assert(quantizeHalf(bitsFloat(inBits)) == cast(ushort) half);
        } else if (name == "quantizeFloat") {
            uint inBits = loadU32(file, at);
            int n = cast(int) loadU32(file, at + 4);
            uint outBits = loadU32(file, at + 8);
            at += 12;
            assert(floatBits(quantizeFloat(bitsFloat(inBits), n)) == outBits);
        } else if (name == "dequantizeHalf") {
            uint half = loadU32(file, at);
            uint outBits = loadU32(file, at + 4);
            at += 8;
            assert(floatBits(dequantizeHalf(cast(ushort) half)) == outBits);
        } else if (name == "quantizeUnorm") {
            uint inBits = loadU32(file, at);
            int n = cast(int) loadU32(file, at + 4);
            int q = cast(int) loadU32(file, at + 8);
            at += 12;
            assert(quantizeUnorm(bitsFloat(inBits), n) == q);
        } else if (name == "quantizeSnorm") {
            uint inBits = loadU32(file, at);
            int n = cast(int) loadU32(file, at + 4);
            int q = cast(int) loadU32(file, at + 8);
            at += 12;
            assert(quantizeSnorm(bitsFloat(inBits), n) == q);
        } else if (name == "computePositionExponent") {
            float[3] minv = loadFloat3(file, at);
            float[3] maxv = loadFloat3(file, at + 12);
            int minExp = cast(int) loadU32(file, at + 24);
            int maxBits = cast(int) loadU32(file, at + 28);
            int exp = cast(int) loadU32(file, at + 32);
            at += 36;
            assert(computePositionExponent(minv, maxv, minExp, maxBits) == exp);
        } else {
            assert(0, name);
        }
    }
    assert(at == file.length, name);
}

private uint loadU32(const(ubyte)[] b, size_t at) pure nothrow @nogc {
    return b[at]
        | (cast(uint) b[at + 1] << 8)
        | (cast(uint) b[at + 2] << 16)
        | (cast(uint) b[at + 3] << 24);
}

private float[3] loadFloat3(const(ubyte)[] b, size_t at) pure nothrow @nogc {
    float[3] r;
    foreach (k; 0 .. 3)
        r[k] = bitsFloat(loadU32(b, at + k * 4));
    return r;
}
