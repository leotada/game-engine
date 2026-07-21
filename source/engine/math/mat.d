/// 4×4 column-major matrix for 3D transforms.
module engine.math.mat;

import engine.math.vec;
import std.math : sin, cos, tan;

pure nothrow @nogc @safe:

/// Column-major 4×4 matrix stored as float[16].
/// Layout: m[col * 4 + row], matching OpenGL/Vulkan/WGSL conventions.
struct Mat4 {
    float[16] m = [
        1,0,0,0,
        0,1,0,0,
        0,0,1,0,
        0,0,0,1,
    ];

    static Mat4 identity() {
        return Mat4.init;
    }

    static Mat4 translation(float tx, float ty, float tz) {
        Mat4 r;
        r.m[12] = tx;
        r.m[13] = ty;
        r.m[14] = tz;
        return r;
    }

    static Mat4 scaling(float sx, float sy, float sz) {
        Mat4 r;
        r.m[0]  = sx;
        r.m[5]  = sy;
        r.m[10] = sz;
        return r;
    }

    static Mat4 rotationX(float rad) {
        Mat4 r;
        immutable c = cos(rad), s = sin(rad);
        r.m[5]  =  c; r.m[6]  = s;
        r.m[9]  = -s; r.m[10] = c;
        return r;
    }

    static Mat4 rotationY(float rad) {
        Mat4 r;
        immutable c = cos(rad), s = sin(rad);
        r.m[0]  = c;  r.m[2]  = -s;
        r.m[8]  = s;  r.m[10] =  c;
        return r;
    }

    static Mat4 rotationZ(float rad) {
        Mat4 r;
        immutable c = cos(rad), s = sin(rad);
        r.m[0] =  c; r.m[1] = s;
        r.m[4] = -s; r.m[5] = c;
        return r;
    }

    static Mat4 perspective(float fovY, float aspect, float near, float far) {
        Mat4 r;
        r.m[] = 0;
        immutable f = 1.0f / tan(fovY * 0.5f);
        r.m[0]  = f / aspect;
        r.m[5]  = f;
        r.m[10] = far / (near - far);
        r.m[11] = -1.0f;
        r.m[14] = (near * far) / (near - far);
        return r;
    }

    static Mat4 lookAt(Vec3 eye, Vec3 target, Vec3 up) {
        immutable f = (target - eye).normalized();
        immutable s = f.cross(up).normalized();
        immutable u = s.cross(f);

        Mat4 r;
        r.m[0] = s.x;  r.m[4] = s.y;  r.m[8]  = s.z;  r.m[12] = -s.dot(eye);
        r.m[1] = u.x;  r.m[5] = u.y;  r.m[9]  = u.z;  r.m[13] = -u.dot(eye);
        r.m[2] = -f.x; r.m[6] = -f.y; r.m[10] = -f.z; r.m[14] =  f.dot(eye);
        r.m[3] = 0;    r.m[7] = 0;    r.m[11] = 0;    r.m[15] = 1;
        return r;
    }

    /// Orthographic projection for WebGPU/WGSL clip space (Z in [0,1], Y up).
    /// Used primarily for directional-light shadow maps.
    static Mat4 ortho(float left, float right, float bottom, float top,
                      float near, float far) {
        Mat4 r;
        r.m[] = 0;
        r.m[0]  =  2.0f / (right - left);
        r.m[5]  =  2.0f / (top - bottom);
        r.m[10] = -1.0f / (far  - near);
        r.m[12] = -(right + left)  / (right - left);
        r.m[13] = -(top   + bottom)/ (top   - bottom);
        r.m[14] = -near  / (far - near);
        r.m[15] =  1.0f;
        return r;
    }

    Mat4 opBinary(string op : "*")(Mat4 b) const {
        Mat4 r;
        r.m[] = 0;
        foreach (col; 0 .. 4)
            foreach (row; 0 .. 4)
                foreach (k; 0 .. 4)
                    r.m[col * 4 + row] += m[k * 4 + row] * b.m[col * 4 + k];
        return r;
    }

    Vec4 opBinary(string op : "*")(Vec4 v) const {
        Vec4 r;
        r.x = m[0]*v.x + m[4]*v.y + m[8]*v.z  + m[12]*v.w;
        r.y = m[1]*v.x + m[5]*v.y + m[9]*v.z  + m[13]*v.w;
        r.z = m[2]*v.x + m[6]*v.y + m[10]*v.z + m[14]*v.w;
        r.w = m[3]*v.x + m[7]*v.y + m[11]*v.z + m[15]*v.w;
        return r;
    }

    /// General 4×4 inverse via cofactors. Returns identity if singular.
    Mat4 inverse() const {
        immutable a00 = m[0],  a01 = m[4],  a02 = m[8],  a03 = m[12];
        immutable a10 = m[1],  a11 = m[5],  a12 = m[9],  a13 = m[13];
        immutable a20 = m[2],  a21 = m[6],  a22 = m[10], a23 = m[14];
        immutable a30 = m[3],  a31 = m[7],  a32 = m[11], a33 = m[15];

        immutable b00 = a00 * a11 - a01 * a10;
        immutable b01 = a00 * a12 - a02 * a10;
        immutable b02 = a00 * a13 - a03 * a10;
        immutable b03 = a01 * a12 - a02 * a11;
        immutable b04 = a01 * a13 - a03 * a11;
        immutable b05 = a02 * a13 - a03 * a12;
        immutable b06 = a20 * a31 - a21 * a30;
        immutable b07 = a20 * a32 - a22 * a30;
        immutable b08 = a20 * a33 - a23 * a30;
        immutable b09 = a21 * a32 - a22 * a31;
        immutable b10 = a21 * a33 - a23 * a31;
        immutable b11 = a22 * a33 - a23 * a32;

        immutable det = b00 * b11 - b01 * b10 + b02 * b09
                      + b03 * b08 - b04 * b07 + b05 * b06;
        if (det > -1e-20f && det < 1e-20f)
            return Mat4.init;

        immutable invDet = 1.0f / det;
        Mat4 r;
        r.m[0]  = ( a11 * b11 - a12 * b10 + a13 * b09) * invDet;
        r.m[1]  = (-a10 * b11 + a12 * b08 - a13 * b07) * invDet;
        r.m[2]  = ( a10 * b10 - a11 * b08 + a13 * b06) * invDet;
        r.m[3]  = (-a10 * b09 + a11 * b07 - a12 * b06) * invDet;
        r.m[4]  = (-a01 * b11 + a02 * b10 - a03 * b09) * invDet;
        r.m[5]  = ( a00 * b11 - a02 * b08 + a03 * b07) * invDet;
        r.m[6]  = (-a00 * b10 + a01 * b08 - a03 * b06) * invDet;
        r.m[7]  = ( a00 * b09 - a01 * b07 + a02 * b06) * invDet;
        r.m[8]  = ( a31 * b05 - a32 * b04 + a33 * b03) * invDet;
        r.m[9]  = (-a30 * b05 + a32 * b02 - a33 * b01) * invDet;
        r.m[10] = ( a30 * b04 - a31 * b02 + a33 * b00) * invDet;
        r.m[11] = (-a30 * b03 + a31 * b01 - a32 * b00) * invDet;
        r.m[12] = (-a21 * b05 + a22 * b04 - a23 * b03) * invDet;
        r.m[13] = ( a20 * b05 - a22 * b02 + a23 * b01) * invDet;
        r.m[14] = (-a20 * b04 + a21 * b02 - a23 * b00) * invDet;
        r.m[15] = ( a20 * b03 - a21 * b01 + a22 * b00) * invDet;
        return r;
    }
}
