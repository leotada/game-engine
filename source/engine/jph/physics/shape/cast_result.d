// Jolt — Physics/Collision/RayCast.h + CastResult.h port (subset).
//
// Phase 4 of the port only needs the simplest single-hit raycast result so
// `Shape.CastRay(ray, creator, ioHit) -> bool` can be implemented per shape.
// The collector-based variants and the broadphase cast result will be added
// in Phase 6 along with the broadphase implementation.
//
// Source: ref/JoltPhysics/Jolt/Physics/Collision/RayCast.h
//         ref/JoltPhysics/Jolt/Physics/Collision/CastResult.h
module engine.jph.physics.shape.cast_result;

import engine.jph.math.vec3;
import engine.jph.physics.body.bodyid : BodyID;
import engine.jph.physics.shape.sub_shape_id : SubShapeID;

@safe:

/// Single-precision ray segment used by all `Shape.CastRay` overrides.
/// `mDirection` carries direction *and* length — anything past it isn't
/// considered a hit.
struct RayCast {
@safe:
    Vec3 mOrigin;
    Vec3 mDirection;

    this(Vec3 inOrigin, Vec3 inDirection) pure nothrow @nogc {
        mOrigin = inOrigin;
        mDirection = inDirection;
    }

    /// Position along the ray for fraction `t ∈ [0, 1]`.
    Vec3 GetPointOnRay(float t) const pure nothrow @nogc {
        return mOrigin + Vec3.sReplicate(t) * mDirection;
    }
}

/// Single-hit broadphase-style result: fraction in [0, 1] and which body
/// produced the hit. Initialised to "no hit" (`mFraction > 1`).
struct BroadPhaseCastResult {
@safe:
    BodyID mBodyID;
    float  mFraction = 1.0f + 1.0e-7f;

    void Reset() pure nothrow @nogc {
        mBodyID   = BodyID();
        mFraction = 1.0f + 1.0e-7f;
    }
}

/// Single-hit raycast result, extended with the sub-shape ID inside the
/// hit body. Used as `ioHit` by `Shape.CastRay`.
struct RayCastResult {
@safe:
    BroadPhaseCastResult mBroad;
    alias mBroad this;
    SubShapeID mSubShapeID2;
}
