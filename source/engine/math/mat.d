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
}
