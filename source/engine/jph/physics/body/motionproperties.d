// Jolt — Physics/Body/MotionProperties.{h,inl} port.
//
// Per-body dynamic state: linear/angular velocity, mass and inverse inertia,
// damping and gravity, allowed DOFs, sleep timer, force/torque accumulators,
// and the integration helpers used by the physics solver.
//
// Notable trims vs the C++ original:
//   * `MoveKinematic` is deferred — needs `Quat::GetAngularVelocity(dt)`
//     which we have not ported yet.
//   * `ApplyGyroscopicForceInternal` is deferred (Tennis-racket effect).
//   * Sleep test "spheres" are reduced to a plain timer; the bounding
//     sphere drift estimator can be added when BroadPhase needs it.
//   * BodyAccess thread-safety asserts are dropped — Phase 8 will introduce
//     them along with the BodyManager.
//   * Stats and serialization are dropped.
//   * UVec4 lane masking is replaced with scalar per-axis masking; D's
//     UVec4 (256-bit integer SIMD) hasn't been ported yet.
//
// Source: ref/JoltPhysics/Jolt/Physics/Body/MotionProperties.h + .inl.
module engine.jph.physics.body.motionproperties;

import std.math : sqrt, isFinite;
import engine.jph.core.types : uint32, uint8;
import engine.jph.math.scalar : Square;
import engine.jph.math.vec3;
import engine.jph.math.vec4;
import engine.jph.math.quat;
import engine.jph.math.mat44;
import engine.jph.physics.body.alloweddofs;
import engine.jph.physics.body.motiontype;
import engine.jph.physics.body.motionquality;
import engine.jph.physics.body.bodytype;
import engine.jph.physics.body.massproperties;

@safe:

/// Whether a body is allowed to go to sleep this frame.
enum ECanSleep : ubyte {
    CannotSleep = 0,
    CanSleep    = 1,
}

/// Per-body dynamic state. POD — no GC pointers.
struct MotionProperties {
@safe:
    enum uint32 cInactiveIndex = uint32.max;

    // -- 1st cache line ------------------------------------------------------

    Vec3 mLinearVelocity   = Vec3(0, 0, 0);
    Vec3 mAngularVelocity  = Vec3(0, 0, 0);
    Vec3 mInvInertiaDiagonal = Vec3(0, 0, 0);
    Quat mInertiaRotation    = Quat.sIdentity();

    // -- 2nd cache line ------------------------------------------------------

    Vec3   mForce  = Vec3(0, 0, 0);
    Vec3   mTorque = Vec3(0, 0, 0);
    float  mInvMass            = 0.0f;
    float  mLinearDamping      = 0.0f;
    float  mAngularDamping     = 0.0f;
    float  mMaxLinearVelocity  = 500.0f;
    float  mMaxAngularVelocity = 0.25f * 3.141592653589793f * 60.0f;
    float  mGravityFactor      = 1.0f;
    uint32 mIndexInActiveBodies = cInactiveIndex;
    uint32 mIslandIndex         = cInactiveIndex;

    EMotionQuality mMotionQuality = EMotionQuality.Discrete;
    bool           mAllowSleeping = true;
    EAllowedDOFs   mAllowedDOFs   = EAllowedDOFs.All;
    uint8          mNumVelocityStepsOverride = 0;
    uint8          mNumPositionStepsOverride = 0;

    // -- 3rd cache line (least used) ----------------------------------------

    float mSleepTestTimer = 0.0f;

    // Cached for assertion / dispatch.
    EBodyType   mCachedBodyType   = EBodyType.RigidBody;
    EMotionType mCachedMotionType = EMotionType.Static;

    // ====================================================================
    // Accessors
    // ====================================================================

    EMotionQuality GetMotionQuality()  const pure nothrow @nogc { return mMotionQuality; }
    EAllowedDOFs   GetAllowedDOFs()    const pure nothrow @nogc { return mAllowedDOFs; }
    bool           GetAllowSleeping()  const pure nothrow @nogc { return mAllowSleeping; }

    Vec3 GetLinearVelocity()  const pure nothrow @nogc { return mLinearVelocity; }
    Vec3 GetAngularVelocity() const pure nothrow @nogc { return mAngularVelocity; }

    void SetLinearVelocity(Vec3 inV) pure nothrow @nogc {
        assert(inV.Length() <= mMaxLinearVelocity, "linear velocity exceeds limit");
        mLinearVelocity = LockTranslation(inV);
    }
    void SetLinearVelocityClamped(Vec3 inV) pure nothrow @nogc {
        mLinearVelocity = LockTranslation(inV);
        ClampLinearVelocity();
    }
    void SetAngularVelocity(Vec3 inV) pure nothrow @nogc {
        assert(inV.Length() <= mMaxAngularVelocity, "angular velocity exceeds limit");
        mAngularVelocity = LockAngular(inV);
    }
    void SetAngularVelocityClamped(Vec3 inV) pure nothrow @nogc {
        mAngularVelocity = LockAngular(inV);
        ClampAngularVelocity();
    }

    float GetMaxLinearVelocity()  const pure nothrow @nogc { return mMaxLinearVelocity; }
    void  SetMaxLinearVelocity(float v) pure nothrow @nogc {
        assert(v >= 0.0f); mMaxLinearVelocity = v;
    }
    float GetMaxAngularVelocity() const pure nothrow @nogc { return mMaxAngularVelocity; }
    void  SetMaxAngularVelocity(float v) pure nothrow @nogc {
        assert(v >= 0.0f); mMaxAngularVelocity = v;
    }

    float GetLinearDamping()  const pure nothrow @nogc { return mLinearDamping; }
    void  SetLinearDamping(float v) pure nothrow @nogc {
        assert(v >= 0.0f); mLinearDamping = v;
    }
    float GetAngularDamping() const pure nothrow @nogc { return mAngularDamping; }
    void  SetAngularDamping(float v) pure nothrow @nogc {
        assert(v >= 0.0f); mAngularDamping = v;
    }

    float GetGravityFactor()  const pure nothrow @nogc { return mGravityFactor; }
    void  SetGravityFactor(float v) pure nothrow @nogc { mGravityFactor = v; }

    float GetInverseMass()           const pure nothrow @nogc {
        assert(mCachedMotionType == EMotionType.Dynamic);
        return mInvMass;
    }
    float GetInverseMassUnchecked()  const pure nothrow @nogc { return mInvMass; }
    void  SetInverseMass(float inInverseMass) pure nothrow @nogc { mInvMass = inInverseMass; }

    Vec3 GetInverseInertiaDiagonal() const pure nothrow @nogc {
        assert(mCachedMotionType == EMotionType.Dynamic);
        return mInvInertiaDiagonal;
    }
    Quat GetInertiaRotation() const pure nothrow @nogc { return mInertiaRotation; }
    void SetInverseInertia(Vec3 inDiagonal, Quat inRot) pure nothrow @nogc {
        mInvInertiaDiagonal = inDiagonal;
        mInertiaRotation    = inRot;
    }

    Vec3 GetAccumulatedForce()  const pure nothrow @nogc { return mForce; }
    Vec3 GetAccumulatedTorque() const pure nothrow @nogc { return mTorque; }
    void ResetForce()                pure nothrow @nogc { mForce = Vec3(0, 0, 0); }
    void ResetTorque()               pure nothrow @nogc { mTorque = Vec3(0, 0, 0); }
    void ResetMotion() pure nothrow @nogc {
        mLinearVelocity = Vec3(0, 0, 0);
        mAngularVelocity = Vec3(0, 0, 0);
        mForce = mTorque = Vec3(0, 0, 0);
    }

    /// Velocity of a point on the body, expressed relative to the centre of
    /// mass.
    Vec3 GetPointVelocityCOM(Vec3 inPointRelToCOM) const pure nothrow @nogc {
        return mLinearVelocity + mAngularVelocity.Cross(inPointRelToCOM);
    }

    void  SetNumVelocityStepsOverride(uint inN) pure nothrow @nogc {
        assert(inN < 256);
        mNumVelocityStepsOverride = cast(uint8) inN;
    }
    uint  GetNumVelocityStepsOverride() const pure nothrow @nogc {
        return mNumVelocityStepsOverride;
    }
    void  SetNumPositionStepsOverride(uint inN) pure nothrow @nogc {
        assert(inN < 256);
        mNumPositionStepsOverride = cast(uint8) inN;
    }
    uint  GetNumPositionStepsOverride() const pure nothrow @nogc {
        return mNumPositionStepsOverride;
    }

    uint32 GetIslandIndexInternal() const pure nothrow @nogc { return mIslandIndex; }
    void   SetIslandIndexInternal(uint32 inIndex) pure nothrow @nogc { mIslandIndex = inIndex; }
    uint32 GetIndexInActiveBodiesInternal() const pure nothrow @nogc {
        return mIndexInActiveBodies;
    }

    // ====================================================================
    // DOF masking
    // ====================================================================

    /// Zero out the components of `inV` that this body's allowed DOFs forbid.
    Vec3 LockTranslation(Vec3 inV) const pure nothrow @nogc {
        return Vec3(dofHas(mAllowedDOFs, EAllowedDOFs.TranslationX) ? inV.GetX() : 0.0f,
                    dofHas(mAllowedDOFs, EAllowedDOFs.TranslationY) ? inV.GetY() : 0.0f,
                    dofHas(mAllowedDOFs, EAllowedDOFs.TranslationZ) ? inV.GetZ() : 0.0f);
    }
    Vec3 LockAngular(Vec3 inV) const pure nothrow @nogc {
        return Vec3(dofHas(mAllowedDOFs, EAllowedDOFs.RotationX) ? inV.GetX() : 0.0f,
                    dofHas(mAllowedDOFs, EAllowedDOFs.RotationY) ? inV.GetY() : 0.0f,
                    dofHas(mAllowedDOFs, EAllowedDOFs.RotationZ) ? inV.GetZ() : 0.0f);
    }

    // ====================================================================
    // Velocity clamping
    // ====================================================================

    void ClampLinearVelocity() pure nothrow @nogc {
        immutable float lenSq = mLinearVelocity.LengthSq();
        assert(isFinite(lenSq));
        if (lenSq > Square(mMaxLinearVelocity))
            mLinearVelocity = mLinearVelocity * (mMaxLinearVelocity / sqrt(lenSq));
    }
    void ClampAngularVelocity() pure nothrow @nogc {
        immutable float lenSq = mAngularVelocity.LengthSq();
        assert(isFinite(lenSq));
        if (lenSq > Square(mMaxAngularVelocity))
            mAngularVelocity = mAngularVelocity * (mMaxAngularVelocity / sqrt(lenSq));
    }

    // ====================================================================
    // Mass & inertia
    // ====================================================================

    /// Set both mass and inertia from a `MassProperties`. If the body's
    /// allowed DOFs forbid translation along an axis, the inverse mass is
    /// kept finite (1/m) but the integrator's own DOF mask is what zeroes
    /// out motion. Inertia rotation comes from the principal axes; here we
    /// assume the inertia tensor is already diagonal in `mp.mInertia` and
    /// extract the diagonal directly.
    void SetMassProperties(EAllowedDOFs inAllowedDOFs, ref const MassProperties mp) pure nothrow @nogc {
        mAllowedDOFs = inAllowedDOFs;
        if (mp.mMass > 0.0f)
            mInvMass = 1.0f / mp.mMass;
        else
            mInvMass = 0.0f;

        // Diagonal-only port. Off-diagonal handling will arrive with
        // DecomposePrincipalMomentsOfInertia in a later phase.
        immutable float ix = mp.mInertia(0, 0);
        immutable float iy = mp.mInertia(1, 1);
        immutable float iz = mp.mInertia(2, 2);
        mInvInertiaDiagonal = Vec3(ix > 0.0f ? 1.0f / ix : 0.0f,
                                   iy > 0.0f ? 1.0f / iy : 0.0f,
                                   iz > 0.0f ? 1.0f / iz : 0.0f);
        mInertiaRotation = Quat.sIdentity();
    }

    /// Adjusts mass to `inMass` while scaling inertia proportionally. The
    /// body must be dynamic (non-zero current mass).
    void ScaleToMass(float inMass) pure nothrow @nogc {
        assert(mInvMass > 0.0f, "body must have finite mass");
        assert(inMass   > 0.0f, "new mass cannot be zero");
        immutable float newInvMass = 1.0f / inMass;
        mInvInertiaDiagonal = mInvInertiaDiagonal * (newInvMass / mInvMass);
        mInvMass = newInvMass;
    }

    // ====================================================================
    // Inverse inertia matrices
    // ====================================================================

    Mat44 GetLocalSpaceInverseInertiaUnchecked() const pure nothrow @nogc {
        immutable Mat44 R = Mat44.sRotation(mInertiaRotation);
        // R * D where D = diag(mInvInertiaDiagonal). Per-column scale of R.
        immutable Mat44 RD = Mat44(
            R.GetColumn4(0) * mInvInertiaDiagonal.GetX(),
            R.GetColumn4(1) * mInvInertiaDiagonal.GetY(),
            R.GetColumn4(2) * mInvInertiaDiagonal.GetZ(),
            Vec4(0, 0, 0, 1));
        return R.Multiply3x3RightTransposed(RD);
    }
    Mat44 GetLocalSpaceInverseInertia() const pure nothrow @nogc {
        assert(mCachedMotionType == EMotionType.Dynamic);
        return GetLocalSpaceInverseInertiaUnchecked();
    }

    /// I^-1 transformed into world space by `inRotation`. Forbidden angular
    /// DOFs zero out their corresponding rows and columns.
    Mat44 GetInverseInertiaForRotation(Mat44 inRotation) const pure nothrow @nogc {
        assert(mCachedMotionType == EMotionType.Dynamic);

        immutable Mat44 R = inRotation * Mat44.sRotation(mInertiaRotation);
        immutable Mat44 RD = Mat44(
            R.GetColumn4(0) * mInvInertiaDiagonal.GetX(),
            R.GetColumn4(1) * mInvInertiaDiagonal.GetY(),
            R.GetColumn4(2) * mInvInertiaDiagonal.GetZ(),
            Vec4(0, 0, 0, 1));
        Mat44 inv = R.Multiply3x3RightTransposed(RD);

        // Mask out forbidden angular axes (both rows and columns).
        immutable bool keepX = dofHas(mAllowedDOFs, EAllowedDOFs.RotationX);
        immutable bool keepY = dofHas(mAllowedDOFs, EAllowedDOFs.RotationY);
        immutable bool keepZ = dofHas(mAllowedDOFs, EAllowedDOFs.RotationZ);
        // Column mask
        if (!keepX) inv.SetColumn4(0, Vec4(0, 0, 0, 0));
        if (!keepY) inv.SetColumn4(1, Vec4(0, 0, 0, 0));
        if (!keepZ) inv.SetColumn4(2, Vec4(0, 0, 0, 0));
        // Row mask: zero each column's forbidden component.
        foreach (j; 0 .. 3) {
            Vec4 c = inv.GetColumn4(j);
            inv.SetColumn4(j, Vec4(keepX ? c.GetX() : 0.0f,
                                   keepY ? c.GetY() : 0.0f,
                                   keepZ ? c.GetZ() : 0.0f,
                                   c.GetW()));
        }
        return inv;
    }

    /// Multiply a vector by I_world^-1. Zero for static / kinematic bodies
    /// or restricted angular DOFs.
    Vec3 MultiplyWorldSpaceInverseInertiaByVector(Quat inBodyRotation, Vec3 inV) const pure nothrow @nogc {
        assert(mCachedMotionType == EMotionType.Dynamic);

        // Mask forbidden angular axes in the input.
        immutable Vec3 v = LockAngular(inV);

        // Move v into inertia-local space, scale by D, move back.
        immutable Mat44 R = Mat44.sRotation(inBodyRotation * mInertiaRotation);
        immutable Vec3 r = R.Multiply3x3(mInvInertiaDiagonal * R.Multiply3x3Transposed(v));
        return LockAngular(r);
    }

    // ====================================================================
    // Sleep handling (simplified)
    // ====================================================================

    void ResetSleepTestTimer() pure nothrow @nogc { mSleepTestTimer = 0.0f; }

    /// Accumulate the time the body has been considered "at rest"; once the
    /// timer crosses `inTimeBeforeSleep` the body is allowed to sleep.
    ECanSleep AccumulateSleepTime(float inDeltaTime, float inTimeBeforeSleep) pure nothrow @nogc {
        mSleepTestTimer += inDeltaTime;
        return mSleepTestTimer >= inTimeBeforeSleep ? ECanSleep.CanSleep
                                                    : ECanSleep.CannotSleep;
    }

    // ====================================================================
    // Solver-side velocity updates
    // ====================================================================

    void ApplyLinearVelocityStep(Vec3 inLinearVelocity) pure nothrow @nogc {
        assert(mCachedMotionType == EMotionType.Dynamic);
        assert(!inLinearVelocity.IsNaN());
        mLinearVelocity = LockTranslation(inLinearVelocity);
    }
    void AddLinearVelocityStep(Vec3 d) pure nothrow @nogc {
        ApplyLinearVelocityStep(mLinearVelocity + d);
    }
    void SubLinearVelocityStep(Vec3 d) pure nothrow @nogc {
        ApplyLinearVelocityStep(mLinearVelocity - d);
    }

    void ApplyAngularVelocityStep(Vec3 inAngularVelocity) pure nothrow @nogc {
        assert(mCachedMotionType == EMotionType.Dynamic);
        assert(!inAngularVelocity.IsNaN());
        mAngularVelocity = inAngularVelocity;
    }
    void AddAngularVelocityStep(Vec3 d) pure nothrow @nogc {
        ApplyAngularVelocityStep(mAngularVelocity + d);
    }
    void SubAngularVelocityStep(Vec3 d) pure nothrow @nogc {
        ApplyAngularVelocityStep(mAngularVelocity - d);
    }

    /// One-shot symplectic Euler integration of the accumulated force /
    /// torque plus gravity, then apply linear & angular damping. Called by
    /// the physics system once per substep, not by user code.
    void ApplyForceTorqueAndDragInternal(Quat inBodyRotation, Vec3 inGravity, float inDeltaTime) pure nothrow @nogc {
        assert(mCachedBodyType   == EBodyType.RigidBody);
        assert(mCachedMotionType == EMotionType.Dynamic);

        mLinearVelocity = LockTranslation(
            mLinearVelocity + inDeltaTime * (mGravityFactor * inGravity
                                             + mInvMass * mForce));

        mAngularVelocity = mAngularVelocity
            + inDeltaTime * MultiplyWorldSpaceInverseInertiaByVector(inBodyRotation, mTorque);

        // Exponential damping approximated with first-order Taylor.
        immutable float ld = 1.0f - mLinearDamping  * inDeltaTime;
        immutable float ad = 1.0f - mAngularDamping * inDeltaTime;
        mLinearVelocity  = mLinearVelocity  * (ld < 0.0f ? 0.0f : ld);
        mAngularVelocity = mAngularVelocity * (ad < 0.0f ? 0.0f : ad);

        ClampLinearVelocity();
        ClampAngularVelocity();
    }
}

unittest {
    MotionProperties mp;
    mp.mCachedMotionType = EMotionType.Dynamic;
    mp.mCachedBodyType   = EBodyType.RigidBody;

    // 1 kg unit cube (diagonal inertia 1/6 along each axis).
    MassProperties props;
    props.SetMassAndInertiaOfSolidBox(Vec3(1, 1, 1), 1.0f);
    mp.SetMassProperties(EAllowedDOFs.All, props);

    assert(mp.mInvMass > 0.999f && mp.mInvMass < 1.001f);
    immutable float invDiag = mp.mInvInertiaDiagonal.GetX();
    assert(invDiag > 6.0f - 1.0e-3f && invDiag < 6.0f + 1.0e-3f);

    // Apply gravity-only step for 1 s on a body at rest: velocity ≈ g.
    mp.ResetForce();
    mp.ResetTorque();
    mp.SetLinearVelocity(Vec3(0, 0, 0));
    mp.ApplyForceTorqueAndDragInternal(Quat.sIdentity(), Vec3(0, -9.81f, 0), 1.0f);
    immutable Vec3 v = mp.GetLinearVelocity();
    assert(v.GetY() < -9.8f && v.GetY() > -9.82f);

    // Lock translation along Y: velocity component is zeroed on set.
    mp.mAllowedDOFs = dofAnd(EAllowedDOFs.All, dofNot(EAllowedDOFs.TranslationY));
    mp.SetMaxLinearVelocity(100.0f);
    mp.SetLinearVelocity(Vec3(1, 2, 3));
    immutable Vec3 vl = mp.GetLinearVelocity();
    assert(vl.GetX() == 1.0f && vl.GetY() == 0.0f && vl.GetZ() == 3.0f);

    // Clamp angular velocity at the configured maximum.
    mp.SetMaxAngularVelocity(2.0f);
    mp.mAngularVelocity = Vec3(10, 0, 0);
    mp.ClampAngularVelocity();
    assert(mp.mAngularVelocity.Length() < 2.0f + 1.0e-4f);

    // GetInverseInertia: diagonal in identity rotation should equal the
    // stored diagonal.
    immutable Mat44 inv = mp.GetInverseInertiaForRotation(Mat44.sIdentity());
    foreach (i; 0 .. 3) {
        immutable float want = (i == 1) ? 0.0f /* RotationY allowed but check diag */
                                        : 6.0f;
        // All rotations are allowed, so all diagonals should be ~6.
        assert(inv(i, i) > 5.99f && inv(i, i) < 6.01f);
    }
}
