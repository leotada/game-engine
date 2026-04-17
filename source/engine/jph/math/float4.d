// Jolt — Math/Float4.h port. POD storage for 4 floats.
//
// Source: ref/JoltPhysics/Jolt/Math/Float4.h.
module engine.jph.math.float4;

@safe:

struct Float4 {
@safe:
    float x = 0, y = 0, z = 0, w = 0;

    this(float inX, float inY, float inZ, float inW) pure nothrow @nogc {
        x = inX; y = inY; z = inZ; w = inW;
    }

    float opIndex(int inCoord) const pure nothrow @nogc
    in (inCoord >= 0 && inCoord < 4)
    {
        final switch (inCoord) {
            case 0: return x;
            case 1: return y;
            case 2: return z;
            case 3: return w;
        }
    }

    bool opEquals(const Float4 r) const pure nothrow @nogc {
        return x == r.x && y == r.y && z == r.z && w == r.w;
    }
}
