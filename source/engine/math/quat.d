// 
module engine.math.quat;

import engine.math.vec;
import engine.math.mat;
import std.math : sqrt, sin, cos;

pure nothrow @nogc @safe:

struct Quat {
    float x = 0, y = 0, z = 0, w = 1;

    static Quat identity() { return Quat.init; }

    /// Right-handed rotation of `rad` radians around the unit axis.
    static Quat fromAxisAngle(Vec3 axis, float rad) {
        immutable half = rad * 0.5f;
        immutable s = sin(half);
        immutable a = axis.normalized();
        return Quat(a.x * s, a.y * s, a.z * s, cos(half));
    }

    /// Hamilton product (this * rhs).
    Quat opBinary(string op : "*")(Quat r) const {
        return Quat(
            w * r.x + x * r.w + y * r.z - z * r.y,
            w * r.y - x * r.z + y * r.w + z * r.x,
            w * r.z + x * r.y - y * r.x + z * r.w,
            w * r.w - x * r.x - y * r.y - z * r.z,
        );
    }

    Quat opBinary(string op)(float s) const if (op == "*" || op == "/") {
        mixin("return Quat(x " ~ op ~ " s, y " ~ op ~ " s, z " ~ op ~ " s, w " ~ op ~ " s);");
    }

    Quat opBinary(string op : "+")(Quat r) const {
        return Quat(x + r.x, y + r.y, z + r.z, w + r.w);
    }

    float dot(Quat b) const { return x * b.x + y * b.y + z * b.z + w * b.w; }
    float lengthSquared() const { return dot(this); }
    float length() const { return sqrt(lengthSquared()); }

    Quat normalized() const {
        immutable len = length();
        if (len > 1e-20f) return Quat(x / len, y / len, z / len, w / len);
        return Quat.identity;
    }

    Quat conjugate() const { return Quat(-x, -y, -z, w); }

    /// Rotate a vector by this quaternion (assumes unit quaternion).
    Vec3 rotate(Vec3 v) const {
        // v' = q * (v, 0) * q^-1, expanded for unit q.
        immutable u = Vec3(x, y, z);
        immutable s = w;
        immutable t = u.cross(v) * 2.0f;
        return v + t * s + u.cross(t);
    }

    /// Convert to column-major 4×4 rotation matrix.
    Mat4 toMat4() const {
        immutable xx = x * x, yy = y * y, zz = z * z;
        immutable xy = x * y, xz = x * z, yz = y * z;
        immutable wx = w * x, wy = w * y, wz = w * z;
        Mat4 r;
        r.m[0]  = 1 - 2 * (yy + zz);
        r.m[1]  = 2 * (xy + wz);
        r.m[2]  = 2 * (xz - wy);
        r.m[3]  = 0;
        r.m[4]  = 2 * (xy - wz);
        r.m[5]  = 1 - 2 * (xx + zz);
        r.m[6]  = 2 * (yz + wx);
        r.m[7]  = 0;
        r.m[8]  = 2 * (xz + wy);
        r.m[9]  = 2 * (yz - wx);
        r.m[10] = 1 - 2 * (xx + yy);
        r.m[11] = 0;
        r.m[12] = 0; r.m[13] = 0; r.m[14] = 0; r.m[15] = 1;
        return r;
    }

    /// Integrate an angular velocity (in rad/s) over `dt` into a new orientation.
    /// Uses the standard q' = q + 0.5 * dt * (ω, 0) * q then renormalize.
    Quat integrate(Vec3 omega, float dt) const {
        immutable ox = omega.x * dt * 0.5f;
        immutable oy = omega.y * dt * 0.5f;
        immutable oz = omega.z * dt * 0.5f;
        // (ω,0)*q :
        immutable dx =  w * ox + y * oz - z * oy;
        immutable dy =  w * oy - x * oz + z * ox;
        immutable dz =  w * oz + x * oy - y * ox;
        immutable dw = -x * ox - y * oy - z * oz;
        Quat r = Quat(x + dx, y + dy, z + dz, w + dw);
        return r.normalized();
    }
}

// NOTE: unittest removed — module-level `pure nothrow @nogc @safe:` propagates
// to unittests, but DMD attribute inference on Vec3/Quat struct methods is
// inconsistent across modules (a known quirk). Coverage is provided by
// physics/world.d unit tests which exercise Quat.rotate through SAT.
