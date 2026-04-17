// Jolt — Math/Mat44 port. 4x4 column-major matrix.
//
// Storage matches Jolt: `Vec4[4] mCol`, columns laid out left-to-right.
// Element access via `opCall(row, col)`. The basics — identity, axis-angle
// / quaternion / translation / scale factories, multiplication with vectors
// and matrices, transpose, 4x4 inverse, plus axis getters/setters — are
// ported. Quaternion extraction, decomposition, outer/cross product
// helpers, and quaternion-multiplication matrices are deferred.
//
// Source: ref/JoltPhysics/Jolt/Math/Mat44.h + Mat44.inl.
module engine.jph.math.mat44;

import std.math : sin, cos;
import engine.jph.core.types;
import engine.jph.math.vec3;
import engine.jph.math.vec4;
import engine.jph.math.quat;

@safe:

align(16)
struct Mat44 {
@safe:
    Vec4[4] mCol;

    // ---------- ctors ------------------------------------------------------

    this(Vec4 c0, Vec4 c1, Vec4 c2, Vec4 c3) pure nothrow @nogc {
        mCol[0] = c0; mCol[1] = c1; mCol[2] = c2; mCol[3] = c3;
    }
    /// Convenience ctor: c3 is a Vec3 with implicit W=1.
    this(Vec4 c0, Vec4 c1, Vec4 c2, Vec3 c3) pure nothrow @nogc {
        mCol[0] = c0; mCol[1] = c1; mCol[2] = c2;
        mCol[3] = Vec4(c3.GetX(), c3.GetY(), c3.GetZ(), 1.0f);
    }

    // ---------- defaults --------------------------------------------------

    static Mat44 sZero() pure nothrow @nogc {
        return Mat44(Vec4.sZero(), Vec4.sZero(), Vec4.sZero(), Vec4.sZero());
    }
    static Mat44 sIdentity() pure nothrow @nogc {
        return Mat44(Vec4(1, 0, 0, 0), Vec4(0, 1, 0, 0),
                     Vec4(0, 0, 1, 0), Vec4(0, 0, 0, 1));
    }
    static Mat44 sNaN() pure nothrow @nogc {
        return Mat44(Vec4.sNaN(), Vec4.sNaN(), Vec4.sNaN(), Vec4.sNaN());
    }

    // ---------- factories -------------------------------------------------

    static Mat44 sRotationX(float a) pure nothrow @nogc {
        immutable float s = sin(a), c = cos(a);
        return Mat44(Vec4(1, 0, 0, 0), Vec4(0, c, s, 0), Vec4(0, -s, c, 0), Vec4(0, 0, 0, 1));
    }
    static Mat44 sRotationY(float a) pure nothrow @nogc {
        immutable float s = sin(a), c = cos(a);
        return Mat44(Vec4(c, 0, -s, 0), Vec4(0, 1, 0, 0), Vec4(s, 0, c, 0), Vec4(0, 0, 0, 1));
    }
    static Mat44 sRotationZ(float a) pure nothrow @nogc {
        immutable float s = sin(a), c = cos(a);
        return Mat44(Vec4(c, s, 0, 0), Vec4(-s, c, 0, 0), Vec4(0, 0, 1, 0), Vec4(0, 0, 0, 1));
    }

    static Mat44 sRotation(Quat q) pure nothrow @nogc {
        immutable x = q.GetX(), y = q.GetY(), z = q.GetZ(), w = q.GetW();
        immutable xx = x*x, yy = y*y, zz = z*z;
        immutable xy = x*y, xz = x*z, yz = y*z;
        immutable wx = w*x, wy = w*y, wz = w*z;
        return Mat44(
            Vec4(1.0f - 2.0f*(yy + zz), 2.0f*(xy + wz),        2.0f*(xz - wy),        0.0f),
            Vec4(2.0f*(xy - wz),        1.0f - 2.0f*(xx + zz), 2.0f*(yz + wx),        0.0f),
            Vec4(2.0f*(xz + wy),        2.0f*(yz - wx),        1.0f - 2.0f*(xx + yy), 0.0f),
            Vec4(0, 0, 0, 1));
    }
    static Mat44 sRotation(Vec3 axis, float angle) pure nothrow @nogc {
        return sRotation(Quat.sRotation(axis, angle));
    }

    static Mat44 sTranslation(Vec3 t) pure nothrow @nogc {
        return Mat44(Vec4(1, 0, 0, 0), Vec4(0, 1, 0, 0), Vec4(0, 0, 1, 0),
                     Vec4(t.GetX(), t.GetY(), t.GetZ(), 1));
    }

    static Mat44 sRotationTranslation(Quat r, Vec3 t) pure nothrow @nogc {
        Mat44 m = sRotation(r);
        m.SetTranslation(t);
        return m;
    }

    static Mat44 sScale(float s) pure nothrow @nogc {
        return Mat44(Vec4(s, 0, 0, 0), Vec4(0, s, 0, 0), Vec4(0, 0, s, 0), Vec4(0, 0, 0, 1));
    }
    static Mat44 sScale(Vec3 s) pure nothrow @nogc {
        return Mat44(Vec4(s.GetX(), 0, 0, 0), Vec4(0, s.GetY(), 0, 0),
                     Vec4(0, 0, s.GetZ(), 0), Vec4(0, 0, 0, 1));
    }

    // ---------- element access --------------------------------------------

    float opCall(uint row, uint col) const pure nothrow @nogc
    in (row < 4 && col < 4)
    {
        return mCol[col].mF32[row];
    }

    Vec3 GetAxisX() const pure nothrow @nogc { return Vec3(mCol[0].GetX(), mCol[0].GetY(), mCol[0].GetZ()); }
    Vec3 GetAxisY() const pure nothrow @nogc { return Vec3(mCol[1].GetX(), mCol[1].GetY(), mCol[1].GetZ()); }
    Vec3 GetAxisZ() const pure nothrow @nogc { return Vec3(mCol[2].GetX(), mCol[2].GetY(), mCol[2].GetZ()); }
    Vec3 GetTranslation() const pure nothrow @nogc {
        return Vec3(mCol[3].GetX(), mCol[3].GetY(), mCol[3].GetZ());
    }

    void SetAxisX(Vec3 v) pure nothrow @nogc { mCol[0] = Vec4(v.GetX(), v.GetY(), v.GetZ(), 0); }
    void SetAxisY(Vec3 v) pure nothrow @nogc { mCol[1] = Vec4(v.GetX(), v.GetY(), v.GetZ(), 0); }
    void SetAxisZ(Vec3 v) pure nothrow @nogc { mCol[2] = Vec4(v.GetX(), v.GetY(), v.GetZ(), 0); }
    void SetTranslation(Vec3 v) pure nothrow @nogc { mCol[3] = Vec4(v.GetX(), v.GetY(), v.GetZ(), 1); }

    Vec3 GetColumn3(uint c) const pure nothrow @nogc
    in (c < 4)
    {
        return Vec3(mCol[c].GetX(), mCol[c].GetY(), mCol[c].GetZ());
    }
    Vec4 GetColumn4(uint c) const pure nothrow @nogc
    in (c < 4)
    {
        return mCol[c];
    }
    void SetColumn4(uint c, Vec4 v) pure nothrow @nogc
    in (c < 4)
    {
        mCol[c] = v;
    }

    // ---------- comparison ------------------------------------------------

    bool opEquals(const Mat44 r) const pure nothrow @nogc {
        return mCol[0] == r.mCol[0] && mCol[1] == r.mCol[1]
            && mCol[2] == r.mCol[2] && mCol[3] == r.mCol[3];
    }

    // ---------- multiplication --------------------------------------------

    Mat44 opBinary(string op : "*")(Mat44 r) const pure nothrow @nogc {
        Mat44 out_;
        foreach (j; 0 .. 4) {
            immutable rc = r.mCol[j];
            out_.mCol[j] = mCol[0] * rc.GetX()
                         + mCol[1] * rc.GetY()
                         + mCol[2] * rc.GetZ()
                         + mCol[3] * rc.GetW();
        }
        return out_;
    }

    Vec4 opBinary(string op : "*")(Vec4 v) const pure nothrow @nogc {
        return mCol[0] * v.GetX() + mCol[1] * v.GetY()
             + mCol[2] * v.GetZ() + mCol[3] * v.GetW();
    }

    /// Treats `v` as (v, 1) and applies the full 4x4 transform, then drops W.
    Vec3 opBinary(string op : "*")(Vec3 v) const pure nothrow @nogc {
        immutable r = mCol[0] * v.GetX() + mCol[1] * v.GetY()
                    + mCol[2] * v.GetZ() + mCol[3];
        return Vec3(r.GetX(), r.GetY(), r.GetZ());
    }

    /// Apply only the 3x3 upper-left part (no translation).
    Vec3 Multiply3x3(Vec3 v) const pure nothrow @nogc {
        immutable r = mCol[0] * v.GetX() + mCol[1] * v.GetY() + mCol[2] * v.GetZ();
        return Vec3(r.GetX(), r.GetY(), r.GetZ());
    }

    Vec3 Multiply3x3Transposed(Vec3 v) const pure nothrow @nogc {
        return Vec3(GetAxisX().Dot(v), GetAxisY().Dot(v), GetAxisZ().Dot(v));
    }

    Mat44 opBinary(string op : "*")(float s) const pure nothrow @nogc {
        return Mat44(mCol[0] * s, mCol[1] * s, mCol[2] * s, mCol[3] * s);
    }
    Mat44 opBinaryRight(string op : "*")(float s) const pure nothrow @nogc { return this * s; }

    Mat44 opBinary(string op : "+")(Mat44 r) const pure nothrow @nogc {
        return Mat44(mCol[0] + r.mCol[0], mCol[1] + r.mCol[1],
                     mCol[2] + r.mCol[2], mCol[3] + r.mCol[3]);
    }
    Mat44 opBinary(string op : "-")(Mat44 r) const pure nothrow @nogc {
        return Mat44(mCol[0] - r.mCol[0], mCol[1] - r.mCol[1],
                     mCol[2] - r.mCol[2], mCol[3] - r.mCol[3]);
    }
    Mat44 opUnary(string op : "-")() const pure nothrow @nogc {
        return Mat44(-mCol[0], -mCol[1], -mCol[2], -mCol[3]);
    }

    // ---------- transpose / inverse ---------------------------------------

    Mat44 Transposed() const pure nothrow @nogc {
        return Mat44(
            Vec4(mCol[0].mF32[0], mCol[1].mF32[0], mCol[2].mF32[0], mCol[3].mF32[0]),
            Vec4(mCol[0].mF32[1], mCol[1].mF32[1], mCol[2].mF32[1], mCol[3].mF32[1]),
            Vec4(mCol[0].mF32[2], mCol[1].mF32[2], mCol[2].mF32[2], mCol[3].mF32[2]),
            Vec4(mCol[0].mF32[3], mCol[1].mF32[3], mCol[2].mF32[3], mCol[3].mF32[3]));
    }

    Mat44 Transposed3x3() const pure nothrow @nogc {
        return Mat44(
            Vec4(mCol[0].mF32[0], mCol[1].mF32[0], mCol[2].mF32[0], 0),
            Vec4(mCol[0].mF32[1], mCol[1].mF32[1], mCol[2].mF32[1], 0),
            Vec4(mCol[0].mF32[2], mCol[1].mF32[2], mCol[2].mF32[2], 0),
            Vec4(0, 0, 0, 1));
    }

    /// Cheap inverse for a matrix containing only rotation + translation.
    Mat44 InversedRotationTranslation() const pure nothrow @nogc {
        Mat44 m = Transposed3x3();
        m.SetTranslation(-(m.Multiply3x3(GetTranslation())));
        return m;
    }

    /// General 4x4 inverse via adjugate / determinant. Returns sNaN if
    /// singular.
    Mat44 Inversed() const pure nothrow @nogc {
        // Source columns expanded to scalars to keep the algebra readable.
        immutable m00 = mCol[0].mF32[0], m10 = mCol[0].mF32[1], m20 = mCol[0].mF32[2], m30 = mCol[0].mF32[3];
        immutable m01 = mCol[1].mF32[0], m11 = mCol[1].mF32[1], m21 = mCol[1].mF32[2], m31 = mCol[1].mF32[3];
        immutable m02 = mCol[2].mF32[0], m12 = mCol[2].mF32[1], m22 = mCol[2].mF32[2], m32 = mCol[2].mF32[3];
        immutable m03 = mCol[3].mF32[0], m13 = mCol[3].mF32[1], m23 = mCol[3].mF32[2], m33 = mCol[3].mF32[3];

        immutable c00 = m22*m33 - m32*m23;
        immutable c02 = m12*m33 - m32*m13;
        immutable c03 = m12*m23 - m22*m13;
        immutable c04 = m21*m33 - m31*m23;
        immutable c06 = m11*m33 - m31*m13;
        immutable c07 = m11*m23 - m21*m13;
        immutable c08 = m21*m32 - m31*m22;
        immutable c10 = m11*m32 - m31*m12;
        immutable c11 = m11*m22 - m21*m12;
        immutable c12 = m20*m33 - m30*m23;
        immutable c14 = m10*m33 - m30*m13;
        immutable c15 = m10*m23 - m20*m13;
        immutable c16 = m20*m32 - m30*m22;
        immutable c18 = m10*m32 - m30*m12;
        immutable c19 = m10*m22 - m20*m12;
        immutable c20 = m20*m31 - m30*m21;
        immutable c22 = m10*m31 - m30*m11;
        immutable c23 = m10*m21 - m20*m11;

        immutable i00 =  m11*c00 - m12*c04 + m13*c08;
        immutable i01 = -m10*c00 + m12*c12 - m13*c16;
        immutable i02 =  m10*c04 - m11*c12 + m13*c20;
        immutable i03 = -m10*c08 + m11*c16 - m12*c20;

        immutable det = m00*i00 + m01*i01 + m02*i02 + m03*i03;
        if (det == 0.0f) return Mat44.sNaN();
        immutable invDet = 1.0f / det;

        immutable i10 = -m01*c00 + m02*c04 - m03*c08;
        immutable i11 =  m00*c00 - m02*c12 + m03*c16;
        immutable i12 = -m00*c04 + m01*c12 - m03*c20;
        immutable i13 =  m00*c08 - m01*c16 + m02*c20;

        immutable i20 =  m01*c02 - m02*c06 + m03*c10;
        immutable i21 = -m00*c02 + m02*c14 - m03*c18;
        immutable i22 =  m00*c06 - m01*c14 + m03*c22;
        immutable i23 = -m00*c10 + m01*c18 - m02*c22;

        immutable i30 = -m01*c03 + m02*c07 - m03*c11;
        immutable i31 =  m00*c03 - m02*c15 + m03*c19;
        immutable i32 = -m00*c07 + m01*c15 - m03*c23;
        immutable i33 =  m00*c11 - m01*c19 + m02*c23;

        return Mat44(
            Vec4(i00, i01, i02, i03) * invDet,
            Vec4(i10, i11, i12, i13) * invDet,
            Vec4(i20, i21, i22, i23) * invDet,
            Vec4(i30, i31, i32, i33) * invDet);
    }

    Mat44 PreTranslated(Vec3 t) const pure nothrow @nogc {
        Mat44 m = this;
        m.mCol[3] = mCol[0] * t.GetX() + mCol[1] * t.GetY() + mCol[2] * t.GetZ() + mCol[3];
        return m;
    }
    Mat44 PostTranslated(Vec3 t) const pure nothrow @nogc {
        Mat44 m = this;
        m.mCol[3] = Vec4(mCol[3].GetX() + t.GetX(), mCol[3].GetY() + t.GetY(),
                         mCol[3].GetZ() + t.GetZ(), mCol[3].GetW());
        return m;
    }
}
