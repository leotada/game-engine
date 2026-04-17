// Jolt — Math/Math.h port. Scalar utilities and constants.
//
// Source: ref/JoltPhysics/Jolt/Math/Math.h.
//
// Notes on omissions: bit-twiddling builtins (CountTrailingZeros,
// CountLeadingZeros, CountBits) use `core.bitop` instead of compiler
// intrinsics. BitCast is implemented via union, matching Jolt's union-cast.
module engine.jph.math.scalar;

import core.bitop : bsf, bsr, popcnt;
import engine.jph.core.types;

@safe:

/// The constant π.
enum float JPH_PI = 3.14159265358979323846f;

/// A large floating point value which, when squared, is still much smaller than FLT_MAX.
enum float cLargeFloat = 1.0e15f;

/// Convert a value from degrees to radians.
pragma(inline, true)
float DegreesToRadians(float inV) pure nothrow @nogc {
    return inV * (JPH_PI / 180.0f);
}

/// Convert a value from radians to degrees.
pragma(inline, true)
float RadiansToDegrees(float inV) pure nothrow @nogc {
    return inV * (180.0f / JPH_PI);
}

/// Convert angle in radians to the range [-π, π].
float CenterAngleAroundZero(float inV) pure nothrow @nogc {
    if (inV < -JPH_PI) {
        do inV += 2.0f * JPH_PI; while (inV < -JPH_PI);
    } else if (inV > JPH_PI) {
        do inV -= 2.0f * JPH_PI; while (inV > JPH_PI);
    }
    return inV;
}

/// Clamp a value between two values.
pragma(inline, true)
T Clamp(T)(T inV, T inMin, T inMax) pure nothrow @nogc {
    return inV < inMin ? inMin : (inV > inMax ? inMax : inV);
}

/// Square a value.
pragma(inline, true)
T Square(T)(T inV) pure nothrow @nogc { return inV * inV; }

/// Cube of inV.
pragma(inline, true)
T Cubed(T)(T inV) pure nothrow @nogc { return inV * inV * inV; }

/// Get the sign of a value.
pragma(inline, true)
T Sign(T)(T inV) pure nothrow @nogc { return inV < 0 ? cast(T) -1 : cast(T) 1; }

/// Check if inV is a power of 2.
pragma(inline, true)
bool IsPowerOf2(T)(T inV) pure nothrow @nogc {
    return inV > 0 && (inV & (inV - 1)) == 0;
}

/// Align inV up to the next inAlignment bytes.
pragma(inline, true)
T AlignUp(T)(T inV, ulong inAlignment) pure nothrow @nogc {
    return cast(T) ((cast(ulong) inV + inAlignment - 1) & ~(inAlignment - 1));
}

/// Check if inV is inAlignment aligned.
pragma(inline, true)
bool IsAligned(T)(T inV, ulong inAlignment) pure nothrow @nogc {
    return (cast(ulong) inV & (inAlignment - 1)) == 0;
}

/// Compute number of trailing zero bits.
pragma(inline, true)
uint CountTrailingZeros(uint32 inValue) pure nothrow @nogc {
    return inValue == 0 ? 32 : cast(uint) bsf(inValue);
}

/// Compute number of leading zero bits.
pragma(inline, true)
uint CountLeadingZeros(uint32 inValue) pure nothrow @nogc {
    return inValue == 0 ? 32 : 31u - cast(uint) bsr(inValue);
}

/// Count the number of 1 bits in a value.
pragma(inline, true)
uint CountBits(uint32 inValue) pure nothrow @nogc {
    return cast(uint) popcnt(inValue);
}

/// Get the next higher power of 2 of a value, or the value itself if it
/// is already a power of 2.
pragma(inline, true)
uint32 GetNextPowerOf2(uint32 inValue) pure nothrow @nogc {
    return inValue <= 1 ? 1u : 1u << (32 - CountLeadingZeros(inValue - 1));
}

/// Bit-cast (Jolt's BitCast<To>(from)). D has a built-in `*cast(To*)&from`
/// for this; the templated form mirrors Jolt's signature.
pragma(inline, true)
To BitCast(To, From)(auto ref const From inValue) @trusted pure nothrow @nogc
in (From.sizeof == To.sizeof)
{
    union U { From f; To t; }
    U u; u.f = inValue; return u.t;
}
