// Jolt — Geometry/Triangle + IndexedTriangle port.
//
// Source: ref/JoltPhysics/Jolt/Geometry/Triangle.h, IndexedTriangle.h.
module engine.jph.geometry.triangle;

import engine.jph.core.types;
import engine.jph.math.vec3;
import engine.jph.math.float3;

@safe:

struct Triangle {
@safe:
    Float3[3] mV;
    uint32 mMaterialIndex = 0;
    uint32 mUserData = 0;

    this(Float3 inV1, Float3 inV2, Float3 inV3,
         uint32 inMaterialIndex = 0, uint32 inUserData = 0) pure nothrow @nogc {
        mV[0] = inV1; mV[1] = inV2; mV[2] = inV3;
        mMaterialIndex = inMaterialIndex; mUserData = inUserData;
    }
    this(Vec3 inV1, Vec3 inV2, Vec3 inV3,
         uint32 inMaterialIndex = 0, uint32 inUserData = 0) @trusted pure nothrow @nogc {
        inV1.StoreFloat3(&mV[0]);
        inV2.StoreFloat3(&mV[1]);
        inV3.StoreFloat3(&mV[2]);
        mMaterialIndex = inMaterialIndex; mUserData = inUserData;
    }

    Vec3 GetCentroid() const pure nothrow @nogc {
        return (Vec3.sLoadFloat3Unsafe(mV[0]) + Vec3.sLoadFloat3Unsafe(mV[1]) + Vec3.sLoadFloat3Unsafe(mV[2])) * (1.0f / 3.0f);
    }
}

/// 32-bit indexed triangle (no material).
struct IndexedTriangleNoMaterial {
@safe:
    uint32[3] mIdx;

    this(uint32 i1, uint32 i2, uint32 i3) pure nothrow @nogc {
        mIdx[0] = i1; mIdx[1] = i2; mIdx[2] = i3;
    }

    bool opEquals(const IndexedTriangleNoMaterial r) const pure nothrow @nogc {
        return mIdx[0] == r.mIdx[0] && mIdx[1] == r.mIdx[1] && mIdx[2] == r.mIdx[2];
    }

    bool IsEquivalent(const IndexedTriangleNoMaterial r) const pure nothrow @nogc {
        return (mIdx[0] == r.mIdx[0] && mIdx[1] == r.mIdx[1] && mIdx[2] == r.mIdx[2])
            || (mIdx[0] == r.mIdx[1] && mIdx[1] == r.mIdx[2] && mIdx[2] == r.mIdx[0])
            || (mIdx[0] == r.mIdx[2] && mIdx[1] == r.mIdx[0] && mIdx[2] == r.mIdx[1]);
    }
    bool IsOpposite(const IndexedTriangleNoMaterial r) const pure nothrow @nogc {
        return (mIdx[0] == r.mIdx[0] && mIdx[1] == r.mIdx[2] && mIdx[2] == r.mIdx[1])
            || (mIdx[0] == r.mIdx[1] && mIdx[1] == r.mIdx[0] && mIdx[2] == r.mIdx[2])
            || (mIdx[0] == r.mIdx[2] && mIdx[1] == r.mIdx[1] && mIdx[2] == r.mIdx[0]);
    }

    void Rotate() pure nothrow @nogc {
        uint32 t = mIdx[0]; mIdx[0] = mIdx[1]; mIdx[1] = mIdx[2]; mIdx[2] = t;
    }
}

/// 32-bit indexed triangle plus material/user data.
struct IndexedTriangle {
@safe:
    uint32[3] mIdx;
    uint32 mMaterialIndex = 0;
    uint32 mUserData = 0;

    this(uint32 i1, uint32 i2, uint32 i3,
         uint32 inMaterialIndex = 0, uint32 inUserData = 0) pure nothrow @nogc {
        mIdx[0] = i1; mIdx[1] = i2; mIdx[2] = i3;
        mMaterialIndex = inMaterialIndex; mUserData = inUserData;
    }

    bool opEquals(const IndexedTriangle r) const pure nothrow @nogc {
        return mIdx[0] == r.mIdx[0] && mIdx[1] == r.mIdx[1] && mIdx[2] == r.mIdx[2]
            && mMaterialIndex == r.mMaterialIndex && mUserData == r.mUserData;
    }
}
