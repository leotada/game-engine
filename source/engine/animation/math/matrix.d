// Ported from ozz-animation (MIT), (c) Guillaume Blanc,
// include/ozz/base/maths/internal/simd_math_ref-inl.h (Invert, TransformPoint/Vector) @ 744eb9d
/// 4x4 matrix helpers on `Float4x4` that work with scalar `Vec3`s.
module engine.animation.math.matrix;

import engine.animation.math.scalar : Vec3;
import engine.animation.math.simd;

@safe pure nothrow @nogc:

/// Inverse of `m`. If `m` is not invertible, returns an all-zero matrix and sets `invertible`
/// to false (so dependent quaternions end up identity, like upstream).
Float4x4 invert(const Float4x4 m, out bool invertible) {
    const c = m.cols;
    immutable a00 = c[2].z * c[3].w - c[3].z * c[2].w;
    immutable a01 = c[2].y * c[3].w - c[3].y * c[2].w;
    immutable a02 = c[2].y * c[3].z - c[3].y * c[2].z;
    immutable a03 = c[2].x * c[3].w - c[3].x * c[2].w;
    immutable a04 = c[2].x * c[3].z - c[3].x * c[2].z;
    immutable a05 = c[2].x * c[3].y - c[3].x * c[2].y;
    immutable a06 = c[1].z * c[3].w - c[3].z * c[1].w;
    immutable a07 = c[1].y * c[3].w - c[3].y * c[1].w;
    immutable a08 = c[1].y * c[3].z - c[3].y * c[1].z;
    immutable a09 = c[1].x * c[3].w - c[3].x * c[1].w;
    immutable a10 = c[1].x * c[3].z - c[3].x * c[1].z;
    immutable a11 = c[1].y * c[3].w - c[3].y * c[1].w;
    immutable a12 = c[1].x * c[3].y - c[3].x * c[1].y;
    immutable a13 = c[1].z * c[2].w - c[2].z * c[1].w;
    immutable a14 = c[1].y * c[2].w - c[2].y * c[1].w;
    immutable a15 = c[1].y * c[2].z - c[2].y * c[1].z;
    immutable a16 = c[1].x * c[2].w - c[2].x * c[1].w;
    immutable a17 = c[1].x * c[2].z - c[2].x * c[1].z;
    immutable a18 = c[1].x * c[2].y - c[2].x * c[1].y;

    immutable b0x = c[1].y * a00 - c[1].z * a01 + c[1].w * a02;
    immutable b1x = -c[1].x * a00 + c[1].z * a03 - c[1].w * a04;
    immutable b2x = c[1].x * a01 - c[1].y * a03 + c[1].w * a05;
    immutable b3x = -c[1].x * a02 + c[1].y * a04 - c[1].z * a05;

    immutable b0y = -c[0].y * a00 + c[0].z * a01 - c[0].w * a02;
    immutable b1y = c[0].x * a00 - c[0].z * a03 + c[0].w * a04;
    immutable b2y = -c[0].x * a01 + c[0].y * a03 - c[0].w * a05;
    immutable b3y = c[0].x * a02 - c[0].y * a04 + c[0].z * a05;

    immutable b0z = c[0].y * a06 - c[0].z * a07 + c[0].w * a08;
    immutable b1z = -c[0].x * a06 + c[0].z * a09 - c[0].w * a10;
    immutable b2z = c[0].x * a11 - c[0].y * a09 + c[0].w * a12;
    immutable b3z = -c[0].x * a08 + c[0].y * a10 - c[0].z * a12;

    immutable b0w = -c[0].y * a13 + c[0].z * a14 - c[0].w * a15;
    immutable b1w = c[0].x * a13 - c[0].z * a16 + c[0].w * a17;
    immutable b2w = -c[0].x * a14 + c[0].y * a16 - c[0].w * a18;
    immutable b3w = c[0].x * a15 - c[0].y * a17 + c[0].z * a18;

    immutable det = c[0].x * b0x + c[0].y * b1x + c[0].z * b2x + c[0].w * b3x;
    invertible = det != 0.0f;
    immutable invDet = invertible ? 1.0f / det : 0.0f;

    Float4x4 r;
    r.cols[0] = SimdFloat4(b0x * invDet, b0y * invDet, b0z * invDet, b0w * invDet);
    r.cols[1] = SimdFloat4(b1x * invDet, b1y * invDet, b1z * invDet, b1w * invDet);
    r.cols[2] = SimdFloat4(b2x * invDet, b2y * invDet, b2z * invDet, b2w * invDet);
    r.cols[3] = SimdFloat4(b3x * invDet, b3y * invDet, b3z * invDet, b3w * invDet);
    return r;
}

/// Transforms a point (translation applied). Whole-vector arithmetic: the lanes are extracted once
/// at the end, not per term.
pragma(inline, true) Vec3 transformPoint(const Float4x4 m, Vec3 p) {
    immutable r = m.cols[0] * SimdFloat4.load1(p.x) + m.cols[1] * SimdFloat4.load1(p.y)
                + m.cols[2] * SimdFloat4.load1(p.z) + m.cols[3];
    return Vec3(r.x, r.y, r.z);
}

/// Transforms a direction (translation ignored).
pragma(inline, true) Vec3 transformVector(const Float4x4 m, Vec3 v) {
    immutable r = m.cols[0] * SimdFloat4.load1(v.x) + m.cols[1] * SimdFloat4.load1(v.y)
                + m.cols[2] * SimdFloat4.load1(v.z);
    return Vec3(r.x, r.y, r.z);
}

/// Translation part of `m`.
Vec3 translationOf(const Float4x4 m) { return Vec3(m.cols[3].x, m.cols[3].y, m.cols[3].z); }

unittest {
    import std.math : abs;
    Float4x4 m = Float4x4.identity();
    m.cols[0] = SimdFloat4(2, 0, 0, 0);
    m.cols[1] = SimdFloat4(0, 0, 3, 0);
    m.cols[2] = SimdFloat4(0, 4, 0, 0);
    m.cols[3] = SimdFloat4(5, 6, 7, 1);
    bool ok;
    immutable inv = invert(m, ok);
    assert(ok);
    immutable p = transformPoint(inv, transformPoint(m, Vec3(1, 2, 3)));
    assert(abs(p.x - 1) < 1e-5f && abs(p.y - 2) < 1e-5f && abs(p.z - 3) < 1e-5f);
    immutable id = m * inv;
    foreach (c; 0 .. 4) foreach (r; 0 .. 4) {
        assert(abs(id.cols[c][r] - (c == r ? 1.0f : 0.0f)) < 1e-5f);
    }
    // Singular matrix -> zero matrix, flagged.
    Float4x4 z;
    immutable zi = invert(z, ok);
    assert(!ok && zi.cols[0] == SimdFloat4.zero());
    assert(transformVector(m, Vec3(1, 0, 0)) == Vec3(2, 0, 0));
}
