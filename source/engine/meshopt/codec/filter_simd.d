// Ported from meshoptimizer v1.3 (src/vertexfilter.cpp), Copyright (c) 2016-2026 Arseny Kapoulkine, MIT License.
/// SSE2 octahedral 8-bit decode. `version(LDC)` and x86-64 only. DMD keeps the
/// scalar path in `filter.d`.
///
/// Upstream's SSE kernel multiplies by `rsqrtps`. That result, and the same
/// estimate after one or two Newton steps, is not byte-exact with the scalar
/// `sqrtf` path. This kernel uses IEEE `sqrt` and truncates after adding ±0.5,
/// so the stored bytes match `decodeOct8`. On the measured host that is
/// 1.83 GB/s versus 2.26 GB/s for the C++ `rsqrtps` kernel.
module engine.meshopt.codec.filter_simd;

@safe:

version (LDC) version (X86_64):

import core.simd : float4, int4;
import ldc.attributes : target;
import ldc.gccbuiltins_x86;
import ldc.llvmasm : __ir_pure;
import ldc.simd : shufflevector;

private float4 splatf(float x) pure nothrow @nogc {
    float4 v = float4(x);
    return shufflevector!(float4, 0, 0, 0, 0)(v, v);
}

private int4 splati(int x) pure nothrow @nogc {
    int4 v = int4(x);
    return shufflevector!(int4, 0, 0, 0, 0)(v, v);
}

private float4 fadd(float4 a, float4 b) pure nothrow @nogc {
    return __ir_pure!(`%r = fadd <4 x float> %0, %1
ret <4 x float> %r`, float4, float4, float4)(a, b);
}

private float4 fsub(float4 a, float4 b) pure nothrow @nogc {
    return __ir_pure!(`%r = fsub <4 x float> %0, %1
ret <4 x float> %r`, float4, float4, float4)(a, b);
}

private float4 fmul(float4 a, float4 b) pure nothrow @nogc {
    return __ir_pure!(`%r = fmul <4 x float> %0, %1
ret <4 x float> %r`, float4, float4, float4)(a, b);
}

private float4 fdiv(float4 a, float4 b) pure nothrow @nogc {
    return __ir_pure!(`%r = fdiv <4 x float> %0, %1
ret <4 x float> %r`, float4, float4, float4)(a, b);
}

private float4 fsqrt(float4 a) pure nothrow @nogc {
    return __ir_pure!(`%r = call <4 x float> @llvm.sqrt.v4f32(<4 x float> %0)
ret <4 x float> %r`, float4, float4)(a);
}

private float4 sitofp(int4 a) pure nothrow @nogc {
    return __ir_pure!(`%r = sitofp <4 x i32> %0 to <4 x float>
ret <4 x float> %r`, float4, int4)(a);
}

private float4 xorSign(float4 v, int4 mask, int4 signBit) pure nothrow @nogc {
    return cast(float4)(cast(int4) v ^ (mask & signBit));
}

@target("sse2")
private int4 cmplt(float4 a, float4 b) pure nothrow @nogc {
    return __ir_pure!(`%c = fcmp olt <4 x float> %0, %1
%r = sext <4 x i1> %c to <4 x i32>
ret <4 x i32> %r`, int4, float4, float4)(a, b);
}

@target("sse2")
private int4 load4(scope const(ubyte)* p) nothrow @nogc @trusted {
    int4 v = void;
    import core.stdc.string : memcpy;
    memcpy(&v, p, 16);
    return v;
}

@target("sse2")
private void store4(scope ubyte* p, int4 v) nothrow @nogc @trusted {
    import core.stdc.string : memcpy;
    memcpy(p, &v, 16);
}

/// Invariants: `data.length >= count * 4`. Writes a multiple of 4 vectors and
/// returns how many. The caller decodes the tail with `decodeOct8`.
@target("sse2")
size_t decodeOct8SimdPrefix(scope ubyte[] data, size_t count) nothrow @nogc @trusted {
    if (count < 4)
        return 0;
    immutable n = count & ~3;
    immutable signBit = splati(cast(int) 0x80000000);
    immutable zero = splatf(0.0f);
    immutable half = splatf(0.5f);
    immutable maxv = splatf(127.0f);
    immutable keepW = splati(cast(int) 0xff000000);
    immutable low8 = splati(0xff);
    void at(size_t base) {
        int4 n4 = load4(data.ptr + base);
        int4 xf = __builtin_ia32_psradi128(__builtin_ia32_pslldi128(n4, 24), 24);
        int4 yf = __builtin_ia32_psradi128(__builtin_ia32_pslldi128(n4, 16), 24);
        int4 zf = __builtin_ia32_psradi128(__builtin_ia32_pslldi128(n4, 8), 24);
        float4 x = sitofp(xf);
        float4 y = sitofp(yf);
        float4 ax = __ir_pure!(`%r = call <4 x float> @llvm.fabs.v4f32(<4 x float> %0)
ret <4 x float> %r`, float4, float4)(x);
        float4 ay = __ir_pure!(`%r = call <4 x float> @llvm.fabs.v4f32(<4 x float> %0)
ret <4 x float> %r`, float4, float4)(y);
        float4 z = fsub(sitofp(zf), fadd(ax, ay));
        float4 t = __builtin_ia32_minps(z, zero);
        x = fadd(x, xorSign(t, cmplt(x, zero), signBit));
        y = fadd(y, xorSign(t, cmplt(y, zero), signBit));
        float4 ll = fadd(fmul(x, x), fadd(fmul(y, y), fmul(z, z)));
        float4 s = fdiv(maxv, fsqrt(ll));
        int4 xr = __builtin_ia32_cvttps2dq(fadd(fmul(x, s), xorSign(half, cmplt(x, zero), signBit)));
        int4 yr = __builtin_ia32_cvttps2dq(fadd(fmul(y, s), xorSign(half, cmplt(y, zero), signBit)));
        int4 zr = __builtin_ia32_cvttps2dq(fadd(fmul(z, s), xorSign(half, cmplt(z, zero), signBit)));
        int4 res = (n4 & keepW)
            | (xr & low8)
            | __builtin_ia32_pslldi128(yr & low8, 8)
            | __builtin_ia32_pslldi128(zr & low8, 16);
        store4(data.ptr + base, res);
    }
    // Two independent groups per iteration so the sqrt latency can overlap.
    immutable groups = n / 4;
    size_t g;
    for (; g + 1 < groups; g += 2) {
        at(g * 16);
        at((g + 1) * 16);
    }
    if (g < groups)
        at(g * 16);
    return n;
}

@system unittest {
    import engine.meshopt.codec.filter : decodeOct8;

    enum nBatch = 4096;
    ubyte[] simd = new ubyte[nBatch * 4];
    ubyte[] scalar = new ubyte[nBatch * 4];
    size_t filled;
    size_t bad;
    void flush() {
        if (filled == 0)
            return;
        scalar[0 .. filled * 4] = simd[0 .. filled * 4];
        immutable got = decodeOct8SimdPrefix(simd, filled);
        assert(got == filled);
        decodeOct8(scalar, filled);
        foreach (b; 0 .. filled * 4) {
            if (simd[b] != scalar[b])
                bad++;
        }
        filled = 0;
    }
    foreach (x; 0 .. 256) {
        foreach (y; 0 .. 256) {
            foreach (z; 0 .. 256) {
                immutable o = filled * 4;
                simd[o] = cast(ubyte) x;
                simd[o + 1] = cast(ubyte) y;
                simd[o + 2] = cast(ubyte) z;
                simd[o + 3] = cast(ubyte)(x ^ z);
                filled++;
                if (filled == nBatch)
                    flush();
            }
        }
    }
    flush();
    assert(bad == 0);
}
