// Ported from ozz-animation (MIT), (c) Guillaume Blanc,
// include/ozz/base/maths/soa_{float,quaternion,transform,float4x4}.h @ 744eb9d
/// Structure-of-arrays math: each field holds the same component of 4 independent values.
module engine.animation.math.soa;

import engine.animation.math.simd;

@safe pure nothrow @nogc:

struct SoaFloat3 {
    pure nothrow @nogc @safe:
    SimdFloat4 x, y, z;

    static SoaFloat3 zero() { return SoaFloat3(SimdFloat4.zero(), SimdFloat4.zero(), SimdFloat4.zero()); }
    static SoaFloat3 one() { return SoaFloat3(SimdFloat4.one(), SimdFloat4.one(), SimdFloat4.one()); }

    SoaFloat3 opBinary(string op)(SoaFloat3 o) const if (op == "+" || op == "-" || op == "*") {
        mixin("return SoaFloat3(x " ~ op ~ " o.x, y " ~ op ~ " o.y, z " ~ op ~ " o.z);");
    }
    SoaFloat3 opBinary(string op : "*")(SimdFloat4 f) const { return SoaFloat3(x * f, y * f, z * f); }
}

/// `(b - a) * f + a`.
SoaFloat3 lerp(SoaFloat3 a, SoaFloat3 b, SimdFloat4 f) {
    return SoaFloat3((b.x - a.x) * f + a.x, (b.y - a.y) * f + a.y, (b.z - a.z) * f + a.z);
}

struct SoaQuaternion {
    pure nothrow @nogc @safe:
    SimdFloat4 x, y, z, w;

    static SoaQuaternion identity() {
        return SoaQuaternion(SimdFloat4.zero(), SimdFloat4.zero(), SimdFloat4.zero(), SimdFloat4.one());
    }

    SoaQuaternion opBinary(string op : "+")(SoaQuaternion o) const {
        return SoaQuaternion(x + o.x, y + o.y, z + o.z, w + o.w);
    }
    SoaQuaternion opBinary(string op : "*")(SimdFloat4 f) const {
        return SoaQuaternion(x * f, y * f, z * f, w * f);
    }
    /// Hamilton product.
    SoaQuaternion opBinary(string op : "*")(SoaQuaternion b) const {
        return SoaQuaternion(
            w * b.x + x * b.w + y * b.z - z * b.y,
            w * b.y + y * b.w + z * b.x - x * b.z,
            w * b.z + z * b.w + x * b.y - y * b.x,
            w * b.w - x * b.x - y * b.y - z * b.z);
    }
}

SoaQuaternion conjugate(SoaQuaternion q) { return SoaQuaternion(-q.x, -q.y, -q.z, q.w); }

SimdFloat4 dot(SoaQuaternion a, SoaQuaternion b) {
    return a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w;
}

SoaQuaternion normalizeEst(SoaQuaternion q) {
    immutable len2 = q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w;
    immutable inv = rsqrtEstNR(len2);
    return SoaQuaternion(q.x * inv, q.y * inv, q.z * inv, q.w * inv);
}

/// Lerp followed by an estimated normalization (shortest path assumed by the caller).
SoaQuaternion nlerpEst(SoaQuaternion a, SoaQuaternion b, SimdFloat4 f) {
    immutable l = SoaQuaternion((b.x - a.x) * f + a.x, (b.y - a.y) * f + a.y,
                                (b.z - a.z) * f + a.z, (b.w - a.w) * f + a.w);
    return normalizeEst(l);
}

/// Four transforms (joints) in SoA layout. Default value is identity.
struct SoaTransform {
    pure nothrow @nogc @safe:
    SoaFloat3 translation = SoaFloat3.zero();
    SoaQuaternion rotation = SoaQuaternion.identity();
    SoaFloat3 scale = SoaFloat3.one();

    static SoaTransform identity() { return SoaTransform.init; }
}

/// Four 4x4 matrices in SoA layout: `cols[c]` holds component rows x,y,z,w of column `c`.
struct SoaFloat4x4 {
    pure nothrow @nogc @safe:
    struct Col { SimdFloat4 x, y, z, w; }
    Col[4] cols;

    pragma(inline, true) static SoaFloat4x4 fromAffine(SoaFloat3 t, SoaQuaternion q, SoaFloat3 s) {
        immutable zero = SimdFloat4.zero();
        immutable one = SimdFloat4.one();
        immutable two = one + one;
        immutable xx = q.x * q.x, xy = q.x * q.y, xz = q.x * q.z, xw = q.x * q.w;
        immutable yy = q.y * q.y, yz = q.y * q.z, yw = q.y * q.w;
        immutable zz = q.z * q.z, zw = q.z * q.w;
        SoaFloat4x4 r;
        r.cols[0] = Col(s.x * (one - two * (yy + zz)), s.x * two * (xy + zw), s.x * two * (xz - yw), zero);
        r.cols[1] = Col(s.y * two * (xy - zw), s.y * (one - two * (xx + zz)), s.y * two * (yz + xw), zero);
        r.cols[2] = Col(s.z * two * (xz + yw), s.z * two * (yz - xw), s.z * (one - two * (xx + yy)), zero);
        r.cols[3] = Col(t.x, t.y, t.z, one);
        return r;
    }
}

/// Converts 4 SoA matrices into 4 AoS matrices (upstream `Transpose16x16` on the SoA columns).
pragma(inline, true) void toAos(const SoaFloat4x4 soa, ref Float4x4[4] aos) {
    SimdFloat4[16] src = void;
    foreach (c; 0 .. 4) {
        src[c * 4 + 0] = soa.cols[c].x;
        src[c * 4 + 1] = soa.cols[c].y;
        src[c * 4 + 2] = soa.cols[c].z;
        src[c * 4 + 3] = soa.cols[c].w;
    }
    SimdFloat4[16] dst = void;
    transpose16x16(src[], dst[]);
    foreach (m; 0 .. 4) {
        foreach (c; 0 .. 4) aos[m].cols[c] = dst[m * 4 + c];
    }
}

static assert(SoaTransform.sizeof == 160);

unittest {
    // Identity transform -> identity matrices.
    SoaTransform t;
    auto m = SoaFloat4x4.fromAffine(t.translation, t.rotation, t.scale);
    Float4x4[4] aos;
    toAos(m, aos);
    foreach (i; 0 .. 4) assert(aos[i].cols == Float4x4.identity().cols);
}

unittest {
    // Translation + scale land in the right lanes/matrices.
    SoaTransform t;
    t.translation = SoaFloat3(SimdFloat4.load(1, 2, 3, 4), SimdFloat4.load(5, 6, 7, 8), SimdFloat4.load(9, 10, 11, 12));
    t.scale = SoaFloat3(SimdFloat4.load1(2), SimdFloat4.load1(3), SimdFloat4.load1(4));
    auto m = SoaFloat4x4.fromAffine(t.translation, t.rotation, t.scale);
    Float4x4[4] aos;
    toAos(m, aos);
    assert(aos[2].cols[3] == SimdFloat4(3, 7, 11, 1));
    assert(aos[1].cols[0] == SimdFloat4(2, 0, 0, 0));
    assert(aos[1].cols[1] == SimdFloat4(0, 3, 0, 0));
    assert(aos[3].cols[2] == SimdFloat4(0, 0, 4, 0));
}

unittest {
    // 90 degree rotation around Z: x axis maps to y axis.
    import std.math : sqrt, abs;
    immutable s = sqrt(0.5f);
    auto q = SoaQuaternion(SimdFloat4.zero(), SimdFloat4.zero(), SimdFloat4.load1(s), SimdFloat4.load1(s));
    auto m = SoaFloat4x4.fromAffine(SoaFloat3.zero(), q, SoaFloat3.one());
    Float4x4[4] aos;
    toAos(m, aos);
    assert(abs(aos[0].cols[0].x) < 1e-6f && abs(aos[0].cols[0].y - 1) < 1e-6f);
}

unittest {
    // Hamilton product with identity, conjugate, nlerp.
    import std.math : abs;
    auto q = normalizeEst(SoaQuaternion(SimdFloat4.load1(1), SimdFloat4.load1(2), SimdFloat4.load1(3), SimdFloat4.load1(4)));
    auto id = q * conjugate(q);
    assert(abs(id.w.x - 1) < 1e-6f && abs(id.x.x) < 1e-6f && abs(id.y.x) < 1e-6f);
    auto n = nlerpEst(SoaQuaternion.identity(), q, SimdFloat4.zero());
    assert(abs(n.w.x - 1) < 1e-6f);
    auto n1 = nlerpEst(SoaQuaternion.identity(), q, SimdFloat4.one());
    assert(abs(n1.x.x - q.x.x) < 1e-6f);
    assert(abs(dot(q, q).x - 1) < 1e-6f);
}

unittest {
    auto a = SoaFloat3.zero();
    auto b = SoaFloat3(SimdFloat4.load1(2), SimdFloat4.load1(4), SimdFloat4.load1(6));
    auto l = lerp(a, b, SimdFloat4.load1(0.5f));
    assert(l.x == SimdFloat4.load1(1) && l.y == SimdFloat4.load1(2) && l.z == SimdFloat4.load1(3));
}
