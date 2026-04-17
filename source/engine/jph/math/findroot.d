// Jolt — Math/FindRoot.h port. Quadratic root finder used by ray-vs-sphere
// and ray-vs-cylinder.
//
// Source: ref/JoltPhysics/Jolt/Math/FindRoot.h.
module engine.jph.math.findroot;

import std.math : sqrt;
import engine.jph.math.scalar : Square, Sign;

@safe:

/// Find roots of inA*x^2 + inB*x + inC = 0. Returns 0/1/2 root count.
int FindRoot(T)(const T inA, const T inB, const T inC, ref T outX1, ref T outX2) pure nothrow @nogc {
    if (inA == T(0)) {
        if (inB == T(0))
            return 0;
        outX1 = outX2 = -inC / inB;
        return 1;
    }
    T det = Square(inB) - T(4) * inA * inC;
    if (det < T(0))
        return 0;
    T q = (inB + Sign(inB) * cast(T) sqrt(cast(double) det)) / T(-2);
    outX1 = q / inA;
    if (q == T(0)) {
        outX2 = outX1;
        return 1;
    }
    outX2 = inC / q;
    return 2;
}

unittest {
    float a, b;
    // x^2 - 4 = 0 -> ±2
    immutable n = FindRoot!float(1.0f, 0.0f, -4.0f, a, b);
    assert(n == 2);
    immutable lo = a < b ? a : b;
    immutable hi = a < b ? b : a;
    assert(lo > -2.001f && lo < -1.999f);
    assert(hi >  1.999f && hi <  2.001f);
}
