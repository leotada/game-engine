// Ported from ozz-animation (MIT), (c) Guillaume Blanc,
// include/ozz/base/maths/internal/simd_math_ref-inl.h @ 744eb9d
/// Half-precision float decoding (IEEE 754 binary16), bit-compatible with upstream.
module engine.animation.math.half;

@safe pure nothrow @nogc:

private union FloatBits {
    uint u;
    float f;
}

/// Converts a binary16 value to float. Denormals, infinities and NaN are preserved.
float halfToFloat(ushort h) {
    immutable FloatBits magic = {u: (254 - 15) << 23};
    immutable FloatBits infnan = {u: (127 + 16) << 23};
    immutable uint sign = h & 0x8000;
    FloatBits expMant = {u: (h & 0x7fffu) << 13};
    FloatBits adjust = {f: expMant.f * magic.f};
    immutable uint bits = (adjust.f >= infnan.f ? (adjust.u | (255u << 23)) : adjust.u)
        | (sign << 16);
    FloatBits r = {u: bits};
    return r.f;
}

unittest {
    assert(halfToFloat(0x0000) == 0.0f);
    assert(halfToFloat(0x3c00) == 1.0f);
    assert(halfToFloat(0xc000) == -2.0f);
    assert(halfToFloat(0x3800) == 0.5f);
    assert(halfToFloat(0x7bff) == 65504.0f);
    assert(halfToFloat(0x7c00) == float.infinity);
    assert(halfToFloat(0xfc00) == -float.infinity);
    assert(halfToFloat(0x7e00) != halfToFloat(0x7e00)); // NaN
    // Smallest denormal: 2^-24.
    assert(halfToFloat(0x0001) == 5.9604645e-8f);
}
