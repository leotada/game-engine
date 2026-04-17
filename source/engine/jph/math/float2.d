// Jolt — Math/Float2.h port. POD storage for 2 floats.
//
// Source: ref/JoltPhysics/Jolt/Math/Float2.h.
module engine.jph.math.float2;

@safe:

/// Class that holds 2 floats. Used as a storage class. Convert to Vec2 for
/// calculations.
struct Float2 {
@safe:
    float x = 0;
    float y = 0;

    this(float inX, float inY) pure nothrow @nogc { x = inX; y = inY; }

    float opIndex(int inCoord) const pure nothrow @nogc
    in (inCoord >= 0 && inCoord < 2)
    {
        return inCoord == 0 ? x : y;
    }

    bool opEquals(const Float2 r) const pure nothrow @nogc {
        return x == r.x && y == r.y;
    }
}
