// Jolt — Math/Quat port. Quaternion stored as Vec4 in [x, y, z, w] order.
//
// Storage layout matches Jolt: `Vec4 mValue` with W as the real part. The
// basics — identity, axis-angle, rotation composition, vector rotation,
// length, normalize, conjugate, inverse, lerp, slerp — are ported. Twist
// decomposition, swizzle helpers, and compression are deferred.
//
// Source: ref/JoltPhysics/Jolt/Math/Quat.h + Quat.inl.
module engine.jph.math.quat;

import std.math : sin, cos, sqrt, fabs, atan2;
import engine.jph.math.vec3;
import engine.jph.math.vec4;

@safe:

align(16)
struct Quat {
@safe:
    Vec4 mValue;

    // ---------- ctors ------------------------------------------------------

    this(float inX, float inY, float inZ, float inW) pure nothrow @nogc {
        mValue = Vec4(inX, inY, inZ, inW);
    }
    this(Vec4 v) pure nothrow @nogc { mValue = v; }

    // ---------- defaults --------------------------------------------------

    static Quat sZero()     pure nothrow @nogc { return Quat(Vec4.sZero()); }
    static Quat sIdentity() pure nothrow @nogc { return Quat(0, 0, 0, 1); }

    // ---------- factories -------------------------------------------------

    /// Quaternion that rotates `inAngle` radians around `inAxis` (must be unit length).
    static Quat sRotation(Vec3 inAxis, float inAngle) pure nothrow @nogc {
        immutable half = 0.5f * inAngle;
        immutable float s = sin(half);
        immutable float c = cos(half);
        return Quat(s * inAxis.GetX(), s * inAxis.GetY(), s * inAxis.GetZ(), c);
    }

    /// Shortest-path rotation that maps `inFrom` (unit) onto `inTo` (unit).
    static Quat sFromTo(Vec3 inFrom, Vec3 inTo) pure nothrow @nogc {
        immutable lenSq = inFrom.LengthSq() * inTo.LengthSq();
        if (lenSq == 0.0f) return Quat.sIdentity();

        immutable float w = sqrt(lenSq) + inFrom.Dot(inTo);
        Vec3 axis;
        if (w < 1.0e-6f * sqrt(lenSq)) {
            // From and to are antiparallel — pick any perpendicular axis.
            axis = fabs(inFrom.GetX()) > fabs(inFrom.GetZ())
                 ? Vec3(-inFrom.GetY(), inFrom.GetX(), 0.0f)
                 : Vec3(0.0f, -inFrom.GetZ(), inFrom.GetY());
            return Quat(axis.GetX(), axis.GetY(), axis.GetZ(), 0.0f).Normalized();
        }

        axis = inFrom.Cross(inTo);
        return Quat(axis.GetX(), axis.GetY(), axis.GetZ(), w).Normalized();
    }

    // ---------- accessors -------------------------------------------------

    float GetX() const pure nothrow @nogc { return mValue.GetX(); }
    float GetY() const pure nothrow @nogc { return mValue.GetY(); }
    float GetZ() const pure nothrow @nogc { return mValue.GetZ(); }
    float GetW() const pure nothrow @nogc { return mValue.GetW(); }

    Vec3 GetXYZ()  const pure nothrow @nogc { return Vec3(GetX(), GetY(), GetZ()); }
    Vec4 GetXYZW() const pure nothrow @nogc { return mValue; }

    void SetX(float v) pure nothrow @nogc { mValue.SetX(v); }
    void SetY(float v) pure nothrow @nogc { mValue.SetY(v); }
    void SetZ(float v) pure nothrow @nogc { mValue.SetZ(v); }
    void SetW(float v) pure nothrow @nogc { mValue.SetW(v); }
    void Set(float x, float y, float z, float w) pure nothrow @nogc {
        mValue.Set(x, y, z, w);
    }

    // ---------- predicates ------------------------------------------------

    bool opEquals(const Quat r) const pure nothrow @nogc { return mValue == r.mValue; }
    bool IsClose(Quat r, float maxDistSq = 1.0e-12f) const pure nothrow @nogc {
        return mValue.IsClose(r.mValue, maxDistSq);
    }
    bool IsNormalized(float tol = 1.0e-5f) const pure nothrow @nogc {
        return mValue.IsNormalized(tol);
    }
    bool IsNaN() const pure nothrow @nogc { return mValue.IsNaN(); }

    // ---------- length / normalize ----------------------------------------

    float LengthSq() const pure nothrow @nogc { return mValue.LengthSq(); }
    float Length()   const pure nothrow @nogc { return mValue.Length(); }
    Quat  Normalized() const pure nothrow @nogc { return Quat(mValue.Normalized()); }

    float Dot(Quat r) const pure nothrow @nogc { return mValue.Dot(r.mValue); }

    // ---------- arithmetic ------------------------------------------------

    Quat opUnary(string op : "-")() const pure nothrow @nogc { return Quat(-mValue); }
    Quat opBinary(string op : "+")(Quat r) const pure nothrow @nogc { return Quat(mValue + r.mValue); }
    Quat opBinary(string op : "-")(Quat r) const pure nothrow @nogc { return Quat(mValue - r.mValue); }
    Quat opBinary(string op : "*")(float s) const pure nothrow @nogc { return Quat(mValue * s); }
    Quat opBinary(string op : "/")(float s) const pure nothrow @nogc { return Quat(mValue / s); }
    Quat opBinaryRight(string op : "*")(float s) const pure nothrow @nogc { return Quat(mValue * s); }

    /// Hamilton product (this * rhs).
    Quat opBinary(string op : "*")(Quat r) const pure nothrow @nogc {
        immutable lx = GetX(), ly = GetY(), lz = GetZ(), lw = GetW();
        immutable rx = r.GetX(), ry = r.GetY(), rz = r.GetZ(), rw = r.GetW();
        return Quat(
            lw*rx + lx*rw + ly*rz - lz*ry,
            lw*ry - lx*rz + ly*rw + lz*rx,
            lw*rz + lx*ry - ly*rx + lz*rw,
            lw*rw - lx*rx - ly*ry - lz*rz);
    }

    /// Rotate a vector by this (unit) quaternion: q * v * q^-1.
    Vec3 opBinary(string op : "*")(Vec3 v) const pure nothrow @nogc {
        immutable u = GetXYZ();
        immutable w = GetW();
        immutable t = 2.0f * u.Cross(v);
        return v + w * t + u.Cross(t);
    }

    void opOpAssign(string op : "+")(Quat r) pure nothrow @nogc { mValue += r.mValue; }
    void opOpAssign(string op : "-")(Quat r) pure nothrow @nogc { mValue -= r.mValue; }
    void opOpAssign(string op : "*")(float s) pure nothrow @nogc { mValue *= s; }
    void opOpAssign(string op : "/")(float s) pure nothrow @nogc { mValue /= s; }

    // ---------- conjugate / inverse ---------------------------------------

    Quat Conjugated() const pure nothrow @nogc {
        return Quat(-GetX(), -GetY(), -GetZ(), GetW());
    }
    Quat Inversed() const pure nothrow @nogc {
        return Conjugated() / Length();
    }

    Vec3 InverseRotate(Vec3 v) const pure nothrow @nogc {
        return Conjugated() * v;
    }

    // ---------- interpolation ---------------------------------------------

    /// Linear interpolation (no normalization). Caller usually wants SLERP.
    Quat LERP(Quat dest, float t) const pure nothrow @nogc {
        return Quat(mValue * (1.0f - t) + dest.mValue * t);
    }

    /// Shortest-path spherical interpolation.
    Quat SLERP(Quat dest, float t) const pure nothrow @nogc {
        float cosTheta = Dot(dest);
        Quat target = dest;
        if (cosTheta < 0.0f) { target = -dest; cosTheta = -cosTheta; }

        if (cosTheta > 0.9995f) {
            // Quaternions are very close — fall back to LERP and renormalize.
            return LERP(target, t).Normalized();
        }

        immutable float sinThetaSq = 1.0f - cosTheta * cosTheta;
        immutable float sinTheta = sqrt(sinThetaSq);
        immutable float angle = atan2(sinTheta, cosTheta);
        immutable float s0 = sin((1.0f - t) * angle) / sinTheta;
        immutable float s1 = sin(t * angle) / sinTheta;
        return Quat(mValue * s0 + target.mValue * s1);
    }
}
