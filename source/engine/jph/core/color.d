// Jolt — Core/Color.h equivalent. POD 32-bit RGBA used by the profiler and
// debug renderer. We carry the same set of named constants (`sRed`, `sGreen`,
// ...) so ports of `JobSystem::CreateJob("name", Color::sRed, ...)` compile.
//
// Source: ref/JoltPhysics/Jolt/Core/Color.h.
module engine.jph.core.color;

import engine.jph.core.types : uint8, uint32;

@safe:

struct Color {
    uint8 r = 0;
    uint8 g = 0;
    uint8 b = 0;
    uint8 a = 255;

    this(uint8 inR, uint8 inG, uint8 inB, uint8 inA = 255) pure nothrow @nogc @safe {
        r = inR; g = inG; b = inB; a = inA;
    }

    /// Get/set as a single packed uint (ABGR layout matching Jolt).
    uint32 GetUInt32() const pure nothrow @nogc @safe {
        return (uint32(a) << 24) | (uint32(b) << 16) | (uint32(g) << 8) | uint32(r);
    }

    // Standard named colours (subset of the Jolt list).
    static immutable Color sBlack    = Color(0, 0, 0);
    static immutable Color sDarkRed  = Color(128, 0, 0);
    static immutable Color sRed      = Color(255, 0, 0);
    static immutable Color sDarkGreen= Color(0, 128, 0);
    static immutable Color sGreen    = Color(0, 255, 0);
    static immutable Color sDarkBlue = Color(0, 0, 128);
    static immutable Color sBlue     = Color(0, 0, 255);
    static immutable Color sYellow   = Color(255, 255, 0);
    static immutable Color sPurple   = Color(255, 0, 255);
    static immutable Color sCyan     = Color(0, 255, 255);
    static immutable Color sOrange   = Color(255, 128, 0);
    static immutable Color sGrey     = Color(128, 128, 128);
    static immutable Color sLightGrey= Color(192, 192, 192);
    static immutable Color sWhite    = Color(255, 255, 255);
}

/// `Color::ColorArg` in Jolt is `const Color &`. In D we pass by value (POD).
alias ColorArg = Color;
