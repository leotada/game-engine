// 
module engine.math.mat3;

import engine.math.vec;

pure nothrow @nogc @safe:

// 
struct Mat3 {
    float[9] m = [
        1, 0, 0,
        0, 1, 0,
        0, 0, 1,
    ];

    static Mat3 identity() { return Mat3.init; }
    static Mat3 zero() {
        Mat3 r;
        r.m[] = 0;
        return r;
    }

    /// Diagonal matrix from three values.
    static Mat3 diagonal(float a, float b, float c) {
        Mat3 r = zero();
        r.m[0] = a;
        r.m[4] = b;
        r.m[8] = c;
        return r;
    }

    /// Transpose.
    Mat3 transposed() const {
        Mat3 r;
        foreach (col; 0 .. 3)
            foreach (row; 0 .. 3)
                r.m[col * 3 + row] = m[row * 3 + col];
        return r;
    }

    /// Matrix * vector.
    Vec3 opBinary(string op : "*")(Vec3 v) const {
        return Vec3(
            m[0] * v.x + m[3] * v.y + m[6] * v.z,
            m[1] * v.x + m[4] * v.y + m[7] * v.z,
            m[2] * v.x + m[5] * v.y + m[8] * v.z,
        );
    }

    /// Matrix * matrix.
    Mat3 opBinary(string op : "*")(Mat3 b) const {
        Mat3 r;
        r.m[] = 0;
        foreach (col; 0 .. 3)
            foreach (row; 0 .. 3)
                foreach (k; 0 .. 3)
                    r.m[col * 3 + row] += m[k * 3 + row] * b.m[col * 3 + k];
        return r;
    }
}
