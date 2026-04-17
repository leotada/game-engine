// Jolt — Math/Float3.h port. POD storage for 3 floats.
//
// Source: ref/JoltPhysics/Jolt/Math/Float3.h.
module engine.jph.math.float3;

@safe:

/// Class that holds 3 floats. Used as a storage class. Convert to Vec3 for
/// calculations.
struct Float3 {
@safe:
    float x = 0;
    float y = 0;
    float z = 0;

    this(float inX, float inY, float inZ) pure nothrow @nogc {
        x = inX; y = inY; z = inZ;
    }

    float opIndex(int inCoord) const pure nothrow @nogc
    in (inCoord >= 0 && inCoord < 3)
    {
        return inCoord == 0 ? x : (inCoord == 1 ? y : z);
    }

    bool opEquals(const Float3 r) const pure nothrow @nogc {
        return x == r.x && y == r.y && z == r.z;
    }
}
