// Ported from ozz-animation (MIT), (c) Guillaume Blanc,
// include/ozz/base/maths/{vec_float,quaternion,transform}.h @ 744eb9d
/// Scalar (AoS) math used by tracks, motion blending, IK and skinning. The vector and quaternion
/// types are the engine's own (`engine.math`), which are layout-identical to upstream's.
module engine.animation.math.scalar;

public import engine.math.vec : Vec2, Vec3, Vec4;
public import engine.math.quat : Quat;
import std.math : sqrt;

@safe pure nothrow @nogc:

alias Float2 = Vec2;
alias Float3 = Vec3;
alias Float4 = Vec4;
alias Quaternion = Quat;

float lerp(float a, float b, float f) { return (b - a) * f + a; }
Vec2 lerp(Vec2 a, Vec2 b, float f) { return Vec2(lerp(a.x, b.x, f), lerp(a.y, b.y, f)); }
Vec3 lerp(Vec3 a, Vec3 b, float f) {
    return Vec3(lerp(a.x, b.x, f), lerp(a.y, b.y, f), lerp(a.z, b.z, f));
}
Vec4 lerp(Vec4 a, Vec4 b, float f) {
    return Vec4(lerp(a.x, b.x, f), lerp(a.y, b.y, f), lerp(a.z, b.z, f), lerp(a.w, b.w, f));
}

float dot(Quat a, Quat b) { return a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w; }

Quat normalize(Quat q) {
    immutable inv = 1.0f / sqrt(dot(q, q));
    return Quat(q.x * inv, q.y * inv, q.z * inv, q.w * inv);
}

Quat conjugate(Quat q) { return Quat(-q.x, -q.y, -q.z, q.w); }

/// Hamilton product (apply `b` first, then `a`).
Quat mul(Quat a, Quat b) {
    return Quat(a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
                a.w * b.y + a.y * b.w + a.z * b.x - a.x * b.z,
                a.w * b.z + a.z * b.w + a.x * b.y - a.y * b.x,
                a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z);
}

/// Lerp + normalize. `a` and `b` must be in the same hemisphere (dot >= 0).
Quat nlerp(Quat a, Quat b, float f) {
    return normalize(Quat((b.x - a.x) * f + a.x, (b.y - a.y) * f + a.y,
                          (b.z - a.z) * f + a.z, (b.w - a.w) * f + a.w));
}

Vec3 add(Vec3 a, Vec3 b) { return Vec3(a.x + b.x, a.y + b.y, a.z + b.z); }
Vec3 sub(Vec3 a, Vec3 b) { return Vec3(a.x - b.x, a.y - b.y, a.z - b.z); }
Vec3 scale(Vec3 a, float f) { return Vec3(a.x * f, a.y * f, a.z * f); }
Vec3 mul(Vec3 a, Vec3 b) { return Vec3(a.x * b.x, a.y * b.y, a.z * b.z); }
float dot(Vec3 a, Vec3 b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
Vec3 cross(Vec3 a, Vec3 b) {
    return Vec3(a.y * b.z - b.y * a.z, a.z * b.x - b.z * a.x, a.x * b.y - b.x * a.y);
}

/// Rotates `v` by unit quaternion `q`.
Vec3 rotate(Quat q, Vec3 v) {
    immutable a = q.w * q.w - 0.5f;
    immutable b = v.x * q.x + v.y * q.y + v.z * q.z;
    return Vec3((v.x * a + q.x * b + (q.y * v.z - q.z * v.y) * q.w) * 2.0f,
                (v.y * a + q.y * b + (q.z * v.x - q.x * v.z) * q.w) * 2.0f,
                (v.z * a + q.z * b + (q.x * v.y - q.y * v.x) * q.w) * 2.0f);
}

/// Translation / rotation / scale transform.
struct Transform {
    Vec3 translation = Vec3(0, 0, 0);
    Quat rotation = Quat(0, 0, 0, 1);
    Vec3 scale = Vec3(1, 1, 1);

    static Transform identity() { return Transform.init; }
}

unittest {
    import std.math : abs, PI, sin, cos;
    assert(lerp(2.0f, 4.0f, 0.5f) == 3.0f);
    assert(lerp(Vec3(0, 0, 0), Vec3(2, 4, 6), 0.5f) == Vec3(1, 2, 3));
    immutable h = sin(PI / 4);
    immutable q = Quat(0, 0, cast(float) h, cast(float) cos(PI / 4)); // 90 degrees around Z
    immutable r = rotate(q, Vec3(1, 0, 0));
    assert(abs(r.x) < 1e-6f && abs(r.y - 1) < 1e-6f);
    immutable id = mul(q, conjugate(q));
    assert(abs(id.w - 1) < 1e-6f && abs(id.z) < 1e-6f);
    immutable n = nlerp(Quat(0, 0, 0, 1), q, 1.0f);
    assert(abs(n.z - q.z) < 1e-6f);
    assert(cross(Vec3(1, 0, 0), Vec3(0, 1, 0)) == Vec3(0, 0, 1));
}
