// Ported from meshoptimizer v1.3 (src/vertexfilter.cpp), Copyright (c) 2016-2026 Arseny Kapoulkine, MIT License.
/// Octahedral, quaternion, exponential, and color filters. Scalar encode and decode.
module engine.meshopt.codec.filter;

import engine.meshopt.internal.bits : bitsFloat, floatBits;
import engine.meshopt.quantize : quantizeSnorm, quantizeUnorm;
import engine.meshopt.types : EncodeExpMode;

@safe:

private float libmFabs(float x) pure nothrow @nogc @trusted {
    import core.stdc.math : fabsf;
    alias F = float function(float) pure nothrow @nogc @trusted;
    return (cast(F) &fabsf)(x);
}

private float libmSqrt(float x) pure nothrow @nogc @trusted {
    import core.stdc.math : sqrtf;
    alias F = float function(float) pure nothrow @nogc @trusted;
    return (cast(F) &sqrtf)(x);
}

private int optlog2(float v) pure nothrow @nogc {
    uint ui = floatBits(v);
    return cast(int)((ui >> 23) & 0xff) - 127 + 1;
}

private float optexp2(int e) pure nothrow @nogc {
    return bitsFloat(cast(uint)(e + 127) << 23);
}

private short loadI16(const(ubyte)[] b, size_t o) pure nothrow @nogc {
    return cast(short)(b[o] | (b[o + 1] << 8));
}

private void storeI16(ubyte[] b, size_t o, short v) pure nothrow @nogc {
    b[o] = cast(ubyte) v;
    b[o + 1] = cast(ubyte)(cast(ushort) v >> 8);
}

private ushort loadU16(const(ubyte)[] b, size_t o) pure nothrow @nogc {
    return cast(ushort)(b[o] | (b[o + 1] << 8));
}

private void storeU16(ubyte[] b, size_t o, ushort v) pure nothrow @nogc {
    b[o] = cast(ubyte) v;
    b[o + 1] = cast(ubyte)(v >> 8);
}

private int roundSnorm(float x, float s) pure nothrow @nogc {
    float round = x >= 0.0f ? 0.5f : -0.5f;
    return cast(int)(x * s + round);
}

package void decodeOct8(scope ubyte[] data, size_t count) pure nothrow @nogc {
    enum float maxv = 127.0f;
    foreach (i; 0 .. count) {
        size_t o = i * 4;
        float x = cast(byte) data[o + 0];
        float y = cast(byte) data[o + 1];
        float z = cast(float)(cast(byte) data[o + 2]) - libmFabs(x) - libmFabs(y);
        float t = z >= 0.0f ? 0.0f : z;
        x += x >= 0.0f ? t : -t;
        y += y >= 0.0f ? t : -t;
        float l = libmSqrt(x * x + y * y + z * z);
        float s = maxv / l;
        data[o + 0] = cast(ubyte) cast(byte) roundSnorm(x, s);
        data[o + 1] = cast(ubyte) cast(byte) roundSnorm(y, s);
        data[o + 2] = cast(ubyte) cast(byte) roundSnorm(z, s);
    }
}

private void decodeOct16(ubyte[] data, size_t count) pure nothrow @nogc {
    enum float maxv = 32767.0f;
    foreach (i; 0 .. count) {
        size_t o = i * 8;
        float x = loadI16(data, o + 0);
        float y = loadI16(data, o + 2);
        float z = cast(float) loadI16(data, o + 4) - libmFabs(x) - libmFabs(y);
        float t = z >= 0.0f ? 0.0f : z;
        x += x >= 0.0f ? t : -t;
        y += y >= 0.0f ? t : -t;
        float l = libmSqrt(x * x + y * y + z * z);
        float s = maxv / l;
        storeI16(data, o + 0, cast(short) roundSnorm(x, s));
        storeI16(data, o + 2, cast(short) roundSnorm(y, s));
        storeI16(data, o + 4, cast(short) roundSnorm(z, s));
    }
}

/// Decode octahedral unit vectors in place. `stride` is 4 (snorm8) or 8 (snorm16).
void decodeFilterOct(scope ubyte[] buffer, size_t count, size_t stride) nothrow @nogc {
    assert(stride == 4 || stride == 8);
    assert(buffer.length >= count * stride);
    if (stride == 4) {
        size_t done = 0;
        version (LDC)
        version (X86_64) {
            import engine.meshopt.codec.filter_simd : decodeOct8SimdPrefix;
            done = decodeOct8SimdPrefix(buffer, count);
        }
        if (done < count)
            decodeOct8(buffer[done * 4 .. $], count - done);
    } else
        decodeOct16(buffer, count);
}

/// Decode 16-bit quaternion filter in place. `stride` must be 8.
void decodeFilterQuat(ubyte[] buffer, size_t count, size_t stride) pure nothrow @nogc {
    assert(stride == 8);
    assert(buffer.length >= count * stride);
    float scale = 32767.0f / libmSqrt(2.0f);
    foreach (i; 0 .. count) {
        size_t o = i * 8;
        short s0 = loadI16(buffer, o + 0);
        short s1 = loadI16(buffer, o + 2);
        short s2 = loadI16(buffer, o + 4);
        short s3 = loadI16(buffer, o + 6);
        int sf = s3 | 3;
        float s = cast(float) sf;
        float x = s0;
        float y = s1;
        float z = s2;
        float ws = s * s;
        float ww = ws * 2.0f - x * x - y * y - z * z;
        float w = libmSqrt(ww >= 0.0f ? ww : 0.0f);
        float ss = scale / s;
        int xf = roundSnorm(x, ss);
        int yf = roundSnorm(y, ss);
        int zf = roundSnorm(z, ss);
        int wf = cast(int)(w * ss + 0.5f);
        int qc = s3 & 3;
        short[4] q;
        q[(qc + 1) & 3] = cast(short) xf;
        q[(qc + 2) & 3] = cast(short) yf;
        q[(qc + 3) & 3] = cast(short) zf;
        q[(qc + 0) & 3] = cast(short) wf;
        storeI16(buffer, o + 0, q[0]);
        storeI16(buffer, o + 2, q[1]);
        storeI16(buffer, o + 4, q[2]);
        storeI16(buffer, o + 6, q[3]);
    }
}

/// Decode exponential floats in place. `stride` is a multiple of 4.
void decodeFilterExp(ubyte[] buffer, size_t count, size_t stride) pure nothrow @nogc {
    assert(stride > 0 && stride % 4 == 0);
    assert(buffer.length >= count * stride);
    size_t words = count * (stride / 4);
    foreach (i; 0 .. words) {
        size_t o = i * 4;
        uint v = buffer[o] | (cast(uint) buffer[o + 1] << 8) | (cast(uint) buffer[o + 2] << 16) | (cast(uint) buffer[o + 3] << 24);
        int m = cast(int)(v << 8) >> 8;
        int e = cast(int) v >> 24;
        float f = bitsFloat(cast(uint)(e + 127) << 23) * cast(float) m;
        uint bits = floatBits(f);
        buffer[o + 0] = cast(ubyte) bits;
        buffer[o + 1] = cast(ubyte)(bits >> 8);
        buffer[o + 2] = cast(ubyte)(bits >> 16);
        buffer[o + 3] = cast(ubyte)(bits >> 24);
    }
}

private void decodeColor8(ubyte[] data, size_t count) pure nothrow @nogc {
    enum float maxv = 255.0f;
    foreach (i; 0 .. count) {
        size_t o = i * 4;
        int as_ = data[o + 3];
        as_ |= as_ >> 1;
        as_ |= as_ >> 2;
        as_ |= as_ >> 4;
        as_ |= as_ >> 8;
        int y = data[o + 0];
        int co = cast(byte) data[o + 1];
        int cg = cast(byte) data[o + 2];
        int r = y + co - cg;
        int g = y + cg;
        int b = y - co - cg;
        int a = data[o + 3];
        a = ((a << 1) & as_) | (a & 1);
        float ss = maxv / cast(float) as_;
        data[o + 0] = cast(ubyte) cast(int)(cast(float) r * ss + 0.5f);
        data[o + 1] = cast(ubyte) cast(int)(cast(float) g * ss + 0.5f);
        data[o + 2] = cast(ubyte) cast(int)(cast(float) b * ss + 0.5f);
        data[o + 3] = cast(ubyte) cast(int)(cast(float) a * ss + 0.5f);
    }
}

private void decodeColor16(ubyte[] data, size_t count) pure nothrow @nogc {
    enum float maxv = 65535.0f;
    foreach (i; 0 .. count) {
        size_t o = i * 8;
        int a0 = loadU16(data, o + 6);
        int as_ = a0;
        as_ |= as_ >> 1;
        as_ |= as_ >> 2;
        as_ |= as_ >> 4;
        as_ |= as_ >> 8;
        int y = loadU16(data, o + 0);
        int co = loadI16(data, o + 2);
        int cg = loadI16(data, o + 4);
        int r = y + co - cg;
        int g = y + cg;
        int b = y - co - cg;
        int a = a0;
        a = ((a << 1) & as_) | (a & 1);
        float ss = maxv / cast(float) as_;
        storeU16(data, o + 0, cast(ushort) cast(int)(cast(float) r * ss + 0.5f));
        storeU16(data, o + 2, cast(ushort) cast(int)(cast(float) g * ss + 0.5f));
        storeU16(data, o + 4, cast(ushort) cast(int)(cast(float) b * ss + 0.5f));
        storeU16(data, o + 6, cast(ushort) cast(int)(cast(float) a * ss + 0.5f));
    }
}

/// Decode YCoCg colors in place. `stride` is 4 or 8.
void decodeFilterColor(ubyte[] buffer, size_t count, size_t stride) pure nothrow @nogc {
    assert(stride == 4 || stride == 8);
    assert(buffer.length >= count * stride);
    if (stride == 4)
        decodeColor8(buffer, count);
    else
        decodeColor16(buffer, count);
}

/// Encode unit vectors as octahedral snorm pairs. `data` is `count` xyzw floats.
void encodeFilterOct(ubyte[] destination, size_t count, size_t stride, int bits, const(float)[] data) pure nothrow @nogc {
    assert(stride == 4 || stride == 8);
    assert(bits >= 2 && bits <= 16);
    assert(stride == 8 || bits <= 8);
    assert(destination.length >= count * stride);
    assert(data.length >= count * 4);
    int bytebits = cast(int)(stride * 2);
    foreach (i; 0 .. count) {
        float nx = data[i * 4 + 0];
        float ny = data[i * 4 + 1];
        float nz = data[i * 4 + 2];
        float nw = data[i * 4 + 3];
        float nl = libmFabs(nx) + libmFabs(ny) + libmFabs(nz);
        float ns = nl == 0.0f ? 0.0f : 1.0f / nl;
        nx *= ns;
        ny *= ns;
        float u = nz >= 0.0f ? nx : (1 - libmFabs(ny)) * (nx >= 0.0f ? 1.0f : -1.0f);
        float v = nz >= 0.0f ? ny : (1 - libmFabs(nx)) * (ny >= 0.0f ? 1.0f : -1.0f);
        int fu = quantizeSnorm(u, bits);
        int fv = quantizeSnorm(v, bits);
        int fo = quantizeSnorm(1.0f, bits);
        int fw = quantizeSnorm(nw, bytebits);
        if (stride == 4) {
            size_t o = i * 4;
            destination[o + 0] = cast(ubyte) cast(byte) fu;
            destination[o + 1] = cast(ubyte) cast(byte) fv;
            destination[o + 2] = cast(ubyte) cast(byte) fo;
            destination[o + 3] = cast(ubyte) cast(byte) fw;
        } else {
            size_t o = i * 8;
            storeI16(destination, o + 0, cast(short) fu);
            storeI16(destination, o + 2, cast(short) fv);
            storeI16(destination, o + 4, cast(short) fo);
            storeI16(destination, o + 6, cast(short) fw);
        }
    }
}

/// Encode unit quaternions. `stride` must be 8. `data` is `count` xyzw floats.
void encodeFilterQuat(ubyte[] destination, size_t count, size_t stride, int bits, const(float)[] data) pure nothrow @nogc {
    assert(stride == 8);
    assert(bits >= 4 && bits <= 16);
    assert(destination.length >= count * stride);
    assert(data.length >= count * 4);
    float scaler = libmSqrt(2.0f);
    foreach (i; 0 .. count) {
        float q0 = data[i * 4 + 0];
        float q1 = data[i * 4 + 1];
        float q2 = data[i * 4 + 2];
        float q3 = data[i * 4 + 3];
        float[4] q = [q0, q1, q2, q3];
        int qc = 0;
        if (libmFabs(q[1]) > libmFabs(q[qc]))
            qc = 1;
        if (libmFabs(q[2]) > libmFabs(q[qc]))
            qc = 2;
        if (libmFabs(q[3]) > libmFabs(q[qc]))
            qc = 3;
        float sign = q[qc] < 0.0f ? -1.0f : 1.0f;
        short d0 = cast(short) quantizeSnorm(q[(qc + 1) & 3] * scaler * sign, bits);
        short d1 = cast(short) quantizeSnorm(q[(qc + 2) & 3] * scaler * sign, bits);
        short d2 = cast(short) quantizeSnorm(q[(qc + 3) & 3] * scaler * sign, bits);
        short d3 = cast(short)((quantizeSnorm(1.0f, bits) & ~3) | qc);
        size_t o = i * 8;
        storeI16(destination, o + 0, d0);
        storeI16(destination, o + 2, d1);
        storeI16(destination, o + 4, d2);
        storeI16(destination, o + 6, d3);
    }
}

/// Encode finite floats as an 8-bit exponent plus a K-bit mantissa. `stride` is 4..256 and a multiple of 4.
void encodeFilterExp(ubyte[] destination, size_t count, size_t stride, int bits, const(float)[] data, EncodeExpMode mode) pure nothrow @nogc {
    assert(stride > 0 && stride % 4 == 0 && stride <= 256);
    assert(bits >= 1 && bits <= 24);
    assert(destination.length >= count * stride);
    size_t strideFloat = stride / 4;
    assert(data.length >= count * strideFloat);
    int[64] componentExp;
    enum int minExp = -100;
    foreach (j; 0 .. strideFloat)
        componentExp[j] = mode == EncodeExpMode.separate ? 0 : minExp;

    if (mode == EncodeExpMode.sharedComponent) {
        foreach (i; 0 .. count) {
            foreach (j; 0 .. strideFloat) {
                int e = optlog2(data[i * strideFloat + j]);
                if (componentExp[j] < e)
                    componentExp[j] = e;
            }
        }
    }

    foreach (i; 0 .. count) {
        int vectorExp = minExp;
        if (mode == EncodeExpMode.sharedVector) {
            foreach (j; 0 .. strideFloat) {
                int e = optlog2(data[i * strideFloat + j]);
                if (vectorExp < e)
                    vectorExp = e;
            }
        } else if (mode == EncodeExpMode.separate) {
            foreach (j; 0 .. strideFloat) {
                float v = data[i * strideFloat + j];
                int e = optlog2(v);
                if (v != 0)
                    componentExp[j] = minExp < e ? e : minExp;
            }
        } else if (mode == EncodeExpMode.clamped) {
            foreach (j; 0 .. strideFloat) {
                int e = optlog2(data[i * strideFloat + j]);
                componentExp[j] = 0 < e ? e : 0;
            }
        }

        foreach (j; 0 .. strideFloat) {
            int exp = mode == EncodeExpMode.sharedVector ? vectorExp : componentExp[j];
            exp -= bits - 1;
            enum int mmask = (1 << 24) - 1;
            enum int mmax = mmask >> 1;
            float v = data[i * strideFloat + j];
            int m = cast(int)(v * optexp2(-exp) + (v >= 0 ? 0.5f : -0.5f));
            if (m > mmax)
                m = mmax;
            uint word = (m & mmask) | (cast(uint) exp << 24);
            size_t o = (i * strideFloat + j) * 4;
            destination[o + 0] = cast(ubyte) word;
            destination[o + 1] = cast(ubyte)(word >> 8);
            destination[o + 2] = cast(ubyte)(word >> 16);
            destination[o + 3] = cast(ubyte)(word >> 24);
        }
    }
}

/// Encode RGBA colors into YCoCg. `data` is `count` rgba floats in 0..1. `stride` is 4 or 8.
void encodeFilterColor(ubyte[] destination, size_t count, size_t stride, int bits, const(float)[] data) pure nothrow @nogc {
    assert(stride == 4 || stride == 8);
    assert(bits >= 2 && bits <= 16);
    assert(stride == 8 || bits <= 8);
    assert(destination.length >= count * stride);
    assert(data.length >= count * 4);
    foreach (i; 0 .. count) {
        int fr = quantizeUnorm(data[i * 4 + 0], bits);
        int fg = quantizeUnorm(data[i * 4 + 1], bits);
        int fb = quantizeUnorm(data[i * 4 + 2], bits);
        int fco = (fr - fb) / 2;
        int tmp = fb + fco;
        int fcg = (fg - tmp) / 2;
        int fy = tmp + fcg;
        assert((cast(uint)((fy + fco - fcg) | (fy + fcg) | (fy - fco - fcg))) < (1u << bits));
        int fa = (quantizeUnorm(data[i * 4 + 3], bits) >> 1) | (1 << (bits - 1));
        if (stride == 4) {
            size_t o = i * 4;
            destination[o + 0] = cast(ubyte) fy;
            destination[o + 1] = cast(ubyte) fco;
            destination[o + 2] = cast(ubyte) fcg;
            destination[o + 3] = cast(ubyte) fa;
        } else {
            size_t o = i * 8;
            storeU16(destination, o + 0, cast(ushort) fy);
            storeU16(destination, o + 2, cast(ushort) fco);
            storeU16(destination, o + 4, cast(ushort) fcg);
            storeU16(destination, o + 6, cast(ushort) fa);
        }
    }
}

@safe nothrow unittest {
    float[8] nrm = [0, 1, 0, 0, 0, 0, 1, 1];
    ubyte[8] oct;
    encodeFilterOct(oct[], 2, 4, 8, nrm[]);
    ubyte[8] back = oct;
    decodeFilterOct(back[], 2, 4);
    // Octahedral decode of +Y / +Z stays finite and inside the snorm byte range.
    foreach (b; back)
        assert(cast(byte) b >= -127);

    float[8] rgba = [1, 0, 0, 1, 0, 1, 0, 0.5f];
    ubyte[8] col;
    encodeFilterColor(col[], 2, 4, 8, rgba[]);
    ubyte[8] cdec = col;
    decodeFilterColor(cdec[], 2, 4);
    assert(cdec[0] > 200 && cdec[3] == 255);

    float[4] expv = [1.0f, -2.0f, 0.5f, 0];
    ubyte[16] expb;
    foreach (mode; 0 .. 4) {
        encodeFilterExp(expb[], 1, 16, 15, expv[], cast(EncodeExpMode) mode);
        ubyte[16] edec = expb;
        decodeFilterExp(edec[], 1, 16);
    }

    float[4] q = [0, 0, 0, 1];
    ubyte[8] qb;
    encodeFilterQuat(qb[], 1, 8, 16, q[]);
    decodeFilterQuat(qb[], 1, 8);
}
