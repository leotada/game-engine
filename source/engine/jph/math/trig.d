// Jolt — Math/Trigonometry port (scalar wrappers).
//
// Jolt routes trig through Vec4::SinCos / Tan / ASin / ACos / ATan to keep
// determinism across compilers; we use libm directly for now since the
// vectorized polynomial paths in `Vec4.inl` are deferred. ACosApproximate
// follows Jolt's closed-form formula exactly.
//
// Source: ref/JoltPhysics/Jolt/Math/Trigonometry.h.
module engine.jph.math.trig;

import std.math : sin, cos, tan, asin, acos, atan, atan2, sqrt, fabs;
import engine.jph.math.scalar : JPH_PI;

@safe:

float Sin(float x) pure nothrow @nogc { return sin(x); }
float Cos(float x) pure nothrow @nogc { return cos(x); }
float Tan(float x) pure nothrow @nogc { return tan(x); }

/// Clamps x to [-1, 1] before delegating, so it never returns NaN.
float ASin(float x) pure nothrow @nogc {
    immutable float c = x < -1.0f ? -1.0f : (x > 1.0f ? 1.0f : x);
    return asin(c);
}
float ACos(float x) pure nothrow @nogc {
    immutable float c = x < -1.0f ? -1.0f : (x > 1.0f ? 1.0f : x);
    return acos(c);
}

/// Polynomial approximation, max error ~4.2e-3 across [-1, 1], ~2.5x faster
/// than libm `acos`. Useful for hot loops where exactness is not required.
float ACosApproximate(float x) pure nothrow @nogc {
    immutable float abs_x = fabs(x) < 1.0f ? fabs(x) : 1.0f;
    immutable float val = sqrt(1.0f - abs_x) * (JPH_PI / 2.0f - 0.175394f * abs_x);
    return x < 0.0f ? JPH_PI - val : val;
}

float ATan(float x) pure nothrow @nogc { return atan(x); }
float ATan2(float y, float x) pure nothrow @nogc { return atan2(y, x); }
