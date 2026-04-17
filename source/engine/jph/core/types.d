// Jolt — Core/Core.h equivalent: integer typedefs, JPH_INLINE alias,
// JPH_ASSERT macro replacement.
//
// Source: ref/JoltPhysics/Jolt/Core/Core.h (typedefs and macros only).
module engine.jph.core.types;

import core.stdc.stdint : int8_t, int16_t, int32_t, int64_t,
    uint8_t, uint16_t, uint32_t, uint64_t;

@safe:

// ---------------------------------------------------------------------------
// Jolt integer typedefs (Jolt/Core/Core.h)
// ---------------------------------------------------------------------------
alias int8   = byte;
alias int16  = short;
alias int32  = int;
alias int64  = long;
alias uint8  = ubyte;
alias uint16 = ushort;
alias uint32 = uint;
alias uint64 = ulong;
alias uint_  = uint;   // Jolt `uint` (32-bit on 64-bit systems)

// JPH_INLINE has no D equivalent because `pragma(inline, true)` is statement-
// level. Functions that should be inlined use `pragma(inline, true)` inside
// their body. Marker enum keeps the source greppable.
enum JPH_INLINE = 0;

/// Replacement for JPH_ASSERT(expr). In release builds compiles out.
void JPH_ASSERT(bool cond,
                string file = __FILE__, size_t line = __LINE__) pure nothrow @nogc {
    assert(cond);
}

void JPH_ASSERT(bool cond, string msg,
                string file = __FILE__, size_t line = __LINE__) pure nothrow @nogc {
    assert(cond, msg);
}
