/// Differential tests: the `core.simd` backend must agree with the scalar reference backend.
module engine.animation.math.simd_diff_tests;

version (unittest):

import ref_ = engine.animation.math.simd_ref;
import vec_ = engine.animation.math.simd_vec;
import std.math : abs, isNaN;
import std.random : Mt19937, uniform;

private float[4] lanes(F)(F v) { return [v.x, v.y, v.z, v.w]; }

private bool close(float[4] a, float[4] b, float rel) {
    foreach (i; 0 .. 4) {
        if (isNaN(a[i]) != isNaN(b[i])) return false;
        if (!isNaN(a[i]) && abs(a[i] - b[i]) > rel * (1 + abs(b[i]))) return false;
    }
    return true;
}

private float rnd(ref Mt19937 rng) { return uniform(-50.0f, 50.0f, rng); }

unittest {
    Mt19937 rng;
    rng.seed(1234);
    foreach (iter; 0 .. 10_000) {
        float[8] f;
        foreach (ref x; f) x = rnd(rng);
        auto ra = ref_.SimdFloat4(f[0], f[1], f[2], f[3]), rb = ref_.SimdFloat4(f[4], f[5], f[6], f[7]);
        auto va = vec_.SimdFloat4(f[0], f[1], f[2], f[3]), vb = vec_.SimdFloat4(f[4], f[5], f[6], f[7]);
        // Exact (IEEE) operations must be bit-identical.
        assert(lanes(ra + rb) == lanes(va + vb));
        assert(lanes(ra - rb) == lanes(va - vb));
        assert(lanes(ra * rb) == lanes(va * vb));
        assert(lanes(ra / rb) == lanes(va / vb));
        assert(lanes(ref_.max(ra, rb)) == lanes(vec_.max(va, vb)));
        assert(lanes(ref_.max0(ra)) == lanes(vec_.max0(va)));
        assert(lanes(ref_.abs(ra)) == lanes(vec_.abs(va)));
        assert(lanes(ref_.madd(ra, rb, ra)) == lanes(vec_.madd(va, vb, va)));
        // Bit ops.
        auto rs = ref_.sign(ra);
        auto vs = vec_.sign(va);
        assert([rs.x, rs.y, rs.z, rs.w] == [vs.x, vs.y, vs.z, vs.w]);
        assert(lanes(ref_.xorBits(rb, rs)) == lanes(vec_.xorBits(vb, vs)));
        assert(lanes(ref_.andNotBits(rb, rs)) == lanes(vec_.andNotBits(vb, vs)));
        // Estimates: same value within the hardware estimate precision.
        float[4] pos = [abs(f[0]) + 0.01f, abs(f[1]) + 0.01f, abs(f[2]) + 0.01f, abs(f[3]) + 0.01f];
        auto rp = ref_.SimdFloat4(pos[0], pos[1], pos[2], pos[3]);
        auto vp = vec_.SimdFloat4(pos[0], pos[1], pos[2], pos[3]);
        assert(close(lanes(vec_.rcpEst(vp)), lanes(ref_.rcpEst(rp)), 5e-4f));
        assert(close(lanes(vec_.rsqrtEst(vp)), lanes(ref_.rsqrtEst(rp)), 5e-4f));
        assert(close(lanes(vec_.rsqrtEstNR(vp)), lanes(ref_.rsqrtEstNR(rp)), 1e-5f));
        // Half floats.
        auto rh = ref_.SimdInt4(cast(int) uniform(0, 65536, rng), cast(int) uniform(0, 65536, rng),
                                cast(int) uniform(0, 65536, rng), cast(int) uniform(0, 65536, rng));
        auto vh = vec_.SimdInt4(rh.x, rh.y, rh.z, rh.w);
        auto rf = lanes(ref_.halfToFloat4(rh)), vf = lanes(vec_.halfToFloat4(vh));
        foreach (i; 0 .. 4) assert((isNaN(rf[i]) && isNaN(vf[i])) || rf[i] == vf[i]);
    }
}

unittest {
    // Matrix product and 16x16 transpose.
    Mt19937 rng;
    rng.seed(99);
    foreach (iter; 0 .. 2000) {
        ref_.Float4x4 ra, rb;
        vec_.Float4x4 va, vb;
        foreach (c; 0 .. 4) {
            float[8] f;
            foreach (ref x; f) x = rnd(rng);
            ra.cols[c] = ref_.SimdFloat4(f[0], f[1], f[2], f[3]);
            rb.cols[c] = ref_.SimdFloat4(f[4], f[5], f[6], f[7]);
            va.cols[c] = vec_.SimdFloat4(f[0], f[1], f[2], f[3]);
            vb.cols[c] = vec_.SimdFloat4(f[4], f[5], f[6], f[7]);
        }
        auto rm = ra * rb;
        auto vm = va * vb;
        foreach (c; 0 .. 4) assert(lanes(rm.cols[c]) == lanes(vm.cols[c]));

        ref_.SimdFloat4[16] rs, rd;
        vec_.SimdFloat4[16] vs, vd;
        foreach (i; 0 .. 16) {
            float[4] f = [rnd(rng), rnd(rng), rnd(rng), rnd(rng)];
            rs[i] = ref_.SimdFloat4(f[0], f[1], f[2], f[3]);
            vs[i] = vec_.SimdFloat4(f[0], f[1], f[2], f[3]);
        }
        ref_.transpose16x16(rs[], rd[]);
        vec_.transpose16x16(vs[], vd[]);
        foreach (i; 0 .. 16) assert(lanes(rd[i]) == lanes(vd[i]));
    }
}

unittest {
    // Default values are zero in both backends.
    ref_.SimdFloat4 r;
    vec_.SimdFloat4 v;
    assert(lanes(r) == [0, 0, 0, 0] && lanes(v) == [0, 0, 0, 0]);
}
