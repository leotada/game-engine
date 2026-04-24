// Jolt — Physics/Body/Body.h port (simple rigid-body subset).
//
// The simple-rigid-body MVP keeps a compact body record while storing motion
// properties separately in BodyManager. This avoids the old class-heavy world
// surface and keeps the BodyID-based API intact.
module engine.jph.physics.body.body;

import engine.jph.core.types                      : uint64;
import engine.jph.geometry.aabox                  : AABox;
import engine.jph.math.mat44                      : Mat44;
import engine.jph.math.quat                       : Quat;
import engine.jph.math.vec3                       : Vec3;
import engine.jph.math.vec4                       : Vec4;
import engine.jph.physics.body.body_creation_settings : BodyCreationSettings;
import engine.jph.physics.body.bodyid             : BodyID;
import engine.jph.physics.body.bodytype           : EBodyType;
import engine.jph.physics.body.motionproperties   : MotionProperties;
import engine.jph.physics.body.motiontype         : EMotionType;
import engine.jph.physics.collision.broad_phase_layer : BroadPhaseLayer;
import engine.jph.physics.collision.object_layer  : ObjectLayer;
import engine.jph.physics.shape.shape             : Shape;

@safe:

struct Body {
@safe:
    BodyID mID;
    EBodyType mBodyType = EBodyType.RigidBody;
    EMotionType mMotionType = EMotionType.Static;
    ObjectLayer mObjectLayer = 0;
    BroadPhaseLayer mBroadPhaseLayer = 0;
    Shape mShape = null;
    MotionProperties* mMotionProperties = null;
    Vec3 mPosition = Vec3.sZero();
    Quat mRotation = Quat.sIdentity();
    AABox mBounds;
    uint64 mUserData = 0;
    float mFriction = 0.2f;
    float mRestitution = 0.0f;
    bool mIsSensor = false;
    bool mCollideKinematicVsNonDynamic = false;
    bool mUseManifoldReduction = true;
    bool mApplyGyroscopicForce = false;
    bool mEnhancedInternalEdgeRemoval = false;
    bool mInvalidateContactCache = false;
    bool mIsInBroadPhase = false;

    void Initialize(BodyID inID,
                    ref const BodyCreationSettings inSettings,
                    BroadPhaseLayer inBroadPhaseLayer,
                    MotionProperties* inMotionProperties) nothrow @nogc {
        mID = inID;
        mBodyType = EBodyType.RigidBody;
        mMotionType = inSettings.mMotionType;
        mObjectLayer = inSettings.mObjectLayer;
        mBroadPhaseLayer = inBroadPhaseLayer;
        mShape = inSettings.GetShapeMutable();
        mMotionProperties = inMotionProperties;
        mRotation = inSettings.mRotation;
        mUserData = inSettings.mUserData;
        mFriction = inSettings.mFriction;
        mRestitution = inSettings.mRestitution;
        mIsSensor = inSettings.mIsSensor;
        mCollideKinematicVsNonDynamic = inSettings.mCollideKinematicVsNonDynamic;
        mUseManifoldReduction = inSettings.mUseManifoldReduction;
        mApplyGyroscopicForce = inSettings.mApplyGyroscopicForce;
        mEnhancedInternalEdgeRemoval = inSettings.mEnhancedInternalEdgeRemoval;
        mInvalidateContactCache = false;
        mIsInBroadPhase = false;

        mPosition = toCenterOfMassPosition(inSettings.mPosition, mRotation, mShape);
        UpdateWorldBounds();
    }

    BodyID GetID() const nothrow @nogc { return mID; }
    EBodyType GetBodyType() const nothrow @nogc { return mBodyType; }
    bool IsRigidBody() const nothrow @nogc { return mBodyType == EBodyType.RigidBody; }
    bool IsStatic() const nothrow @nogc { return mMotionType == EMotionType.Static; }
    bool IsKinematic() const nothrow @nogc { return mMotionType == EMotionType.Kinematic; }
    bool IsDynamic() const nothrow @nogc { return mMotionType == EMotionType.Dynamic; }
    bool CanBeKinematicOrDynamic() const nothrow @nogc { return mMotionProperties !is null; }
    bool IsActive() const nothrow @nogc {
        return mMotionProperties !is null
            && mMotionProperties.mIndexInActiveBodies != MotionProperties.cInactiveIndex;
    }
    bool IsInBroadPhase() const nothrow @nogc { return mIsInBroadPhase; }
    bool IsSensor() const nothrow @nogc { return mIsSensor; }
    bool GetCollideKinematicVsNonDynamic() const nothrow @nogc { return mCollideKinematicVsNonDynamic; }

    ObjectLayer GetObjectLayer() const nothrow @nogc { return mObjectLayer; }
    BroadPhaseLayer GetBroadPhaseLayer() const nothrow @nogc { return mBroadPhaseLayer; }
    const(Shape) GetShape() const nothrow @nogc { return mShape; }

    uint GetIndexInActiveBodiesInternal() const nothrow @nogc {
        return mMotionProperties !is null
            ? mMotionProperties.GetIndexInActiveBodiesInternal()
            : MotionProperties.cInactiveIndex;
    }

    Vec3 GetPosition() const nothrow @nogc {
        return mPosition - rotatedCenterOfMass(mRotation, mShape);
    }

    Vec3 GetCenterOfMassPosition() const nothrow @nogc {
        return mPosition;
    }

    Quat GetRotation() const nothrow @nogc {
        return mRotation;
    }

    Mat44 GetWorldTransform() const nothrow @nogc {
        return Mat44.sRotationTranslation(mRotation, GetPosition());
    }

    Mat44 GetCenterOfMassTransform() const nothrow @nogc {
        return Mat44.sRotationTranslation(mRotation, mPosition);
    }

    AABox GetWorldSpaceBounds() const nothrow @nogc {
        return mBounds;
    }

    const(MotionProperties)* GetMotionPropertiesUnchecked() const nothrow @nogc {
        return mMotionProperties;
    }

    MotionProperties* GetMotionPropertiesUnchecked() nothrow @nogc {
        return mMotionProperties;
    }

    uint64 GetUserData() const nothrow @nogc { return mUserData; }
    void SetUserData(uint64 inUserData) nothrow @nogc { mUserData = inUserData; }

    float GetFriction() const nothrow @nogc { return mFriction; }
    void SetFriction(float inFriction) nothrow @nogc { mFriction = inFriction; }

    float GetRestitution() const nothrow @nogc { return mRestitution; }
    void SetRestitution(float inRestitution) nothrow @nogc { mRestitution = inRestitution; }

    bool GetAllowSleeping() const nothrow @nogc {
        return mMotionProperties !is null && mMotionProperties.mAllowSleeping;
    }

    void SetAllowSleeping(bool inAllow) nothrow @nogc {
        if (mMotionProperties !is null)
            mMotionProperties.mAllowSleeping = inAllow;
    }

    void ResetSleepTimer() nothrow @nogc {
        if (mMotionProperties !is null)
            mMotionProperties.mSleepTestTimer = 0.0f;
    }

    Vec3 GetLinearVelocity() const nothrow @nogc {
        return mMotionProperties !is null ? mMotionProperties.GetLinearVelocity() : Vec3.sZero();
    }

    void SetLinearVelocity(Vec3 inLinearVelocity) nothrow @nogc {
        if (mMotionProperties !is null)
            mMotionProperties.SetLinearVelocity(inLinearVelocity);
    }

    void SetLinearVelocityClamped(Vec3 inLinearVelocity) nothrow @nogc {
        if (mMotionProperties !is null)
            mMotionProperties.SetLinearVelocityClamped(inLinearVelocity);
    }

    Vec3 GetAngularVelocity() const nothrow @nogc {
        return mMotionProperties !is null ? mMotionProperties.GetAngularVelocity() : Vec3.sZero();
    }

    void SetAngularVelocity(Vec3 inAngularVelocity) nothrow @nogc {
        if (mMotionProperties !is null)
            mMotionProperties.SetAngularVelocity(inAngularVelocity);
    }

    void SetAngularVelocityClamped(Vec3 inAngularVelocity) nothrow @nogc {
        if (mMotionProperties !is null)
            mMotionProperties.SetAngularVelocityClamped(inAngularVelocity);
    }

    void AddForce(Vec3 inForce) nothrow @nogc {
        if (mMotionProperties !is null && IsDynamic())
            mMotionProperties.mForce += inForce;
    }

    void AddForce(Vec3 inForce, Vec3 inPosition) nothrow @nogc {
        if (mMotionProperties !is null && IsDynamic()) {
            mMotionProperties.mForce += inForce;
            mMotionProperties.mTorque += (inPosition - mPosition).Cross(inForce);
        }
    }

    void AddTorque(Vec3 inTorque) nothrow @nogc {
        if (mMotionProperties !is null && IsDynamic())
            mMotionProperties.mTorque += inTorque;
    }

    Vec3 GetAccumulatedForce() const nothrow @nogc {
        return mMotionProperties !is null ? mMotionProperties.GetAccumulatedForce() : Vec3.sZero();
    }

    Vec3 GetAccumulatedTorque() const nothrow @nogc {
        return mMotionProperties !is null ? mMotionProperties.GetAccumulatedTorque() : Vec3.sZero();
    }

    void ResetForce() nothrow @nogc {
        if (mMotionProperties !is null)
            mMotionProperties.ResetForce();
    }

    void ResetTorque() nothrow @nogc {
        if (mMotionProperties !is null)
            mMotionProperties.ResetTorque();
    }

    void ResetMotion() nothrow @nogc {
        if (mMotionProperties !is null)
            mMotionProperties.ResetMotion();
    }

    void IntegrateMotion(float inDeltaTime) nothrow @nogc {
        if (mMotionProperties is null || IsStatic() || inDeltaTime <= 0.0f)
            return;

        mPosition += mMotionProperties.GetLinearVelocity() * inDeltaTime;
        immutable Quat rotationStep = Quat.sAngularVelocityStep(
            mMotionProperties.GetAngularVelocity(),
            inDeltaTime);
        mRotation = (rotationStep * mRotation).Normalized();
        InvalidateContactCache();
        UpdateWorldBounds();
    }

    Mat44 GetInverseInertia() const nothrow @nogc {
        if (mMotionProperties is null)
            return zeroInertiaMatrix();
        return mMotionProperties.GetInverseInertiaForRotation(Mat44.sRotation(mRotation));
    }

    void SetPositionAndRotation(Vec3 inPosition, Quat inRotation) nothrow @nogc {
        mRotation = inRotation;
        mPosition = toCenterOfMassPosition(inPosition, mRotation, mShape);
        UpdateWorldBounds();
    }

    void SetPosition(Vec3 inPosition) nothrow @nogc {
        mPosition = toCenterOfMassPosition(inPosition, mRotation, mShape);
        UpdateWorldBounds();
    }

    void SetRotation(Quat inRotation) nothrow @nogc {
        immutable position = GetPosition();
        mRotation = inRotation;
        mPosition = toCenterOfMassPosition(position, mRotation, mShape);
        UpdateWorldBounds();
    }

    void SetObjectLayer(ObjectLayer inLayer, BroadPhaseLayer inBroadPhaseLayer) nothrow @nogc {
        mObjectLayer = inLayer;
        mBroadPhaseLayer = inBroadPhaseLayer;
    }

    void SetInBroadPhase(bool inInBroadPhase) nothrow @nogc {
        mIsInBroadPhase = inInBroadPhase;
    }

    void InvalidateContactCache() nothrow @nogc {
        mInvalidateContactCache = true;
    }

    void ValidateContactCache() nothrow @nogc {
        mInvalidateContactCache = false;
    }

    void UpdateWorldBounds() nothrow @nogc {
        if (mShape is null)
            mBounds = AABox.sFromTwoPoints(mPosition, mPosition);
        else
            mBounds = mShape.GetWorldSpaceBounds(GetCenterOfMassTransform(), Vec3.sOne());
    }

    private static Vec3 rotatedCenterOfMass(Quat inRotation, const(Shape) inShape) nothrow @nogc {
        return inShape is null ? Vec3.sZero() : inRotation * inShape.GetCenterOfMass();
    }

    private static Vec3 toCenterOfMassPosition(Vec3 inPosition,
                                               Quat inRotation,
                                               const(Shape) inShape) nothrow @nogc {
        return inPosition + rotatedCenterOfMass(inRotation, inShape);
    }

    private static Mat44 zeroInertiaMatrix() nothrow @nogc {
        Mat44 inertia = Mat44.sZero();
        inertia.SetColumn4(3, Vec4(0, 0, 0, 1));
        return inertia;
    }

    static bool sFindCollidingPairsCanCollide(ref const Body inBody1,
                                              ref const Body inBody2) nothrow @nogc {
        if (inBody1.GetID() == inBody2.GetID())
            return false;

        if (!inBody1.GetCollideKinematicVsNonDynamic()
         && !inBody2.GetCollideKinematicVsNonDynamic()
         && !inBody1.IsDynamic()
         && !inBody2.IsDynamic()
         && !(inBody1.IsKinematic() && inBody2.IsSensor())
         && !(inBody2.IsKinematic() && inBody1.IsSensor()))
            return false;

        immutable body1IndexInActiveBodies = inBody1.GetIndexInActiveBodiesInternal();
        if (body1IndexInActiveBodies == MotionProperties.cInactiveIndex)
            return false;

        if (body1IndexInActiveBodies >= inBody2.GetIndexInActiveBodiesInternal())
            return false;

        return true;
    }
}

unittest {
    import engine.jph.physics.shape.box_shape : BoxShape;

    auto shape = new BoxShape(Vec3(1, 2, 3));
    BodyCreationSettings settings = BodyCreationSettings(shape, Vec3(4, 5, 6), Quat.sIdentity(), EMotionType.Dynamic);
    auto motionPool = new MotionProperties[1];
    Body body;
    body.Initialize(BodyID(3, 1), settings, 0, &motionPool[0]);

    assert(body.GetID() == BodyID(3, 1));
    assert(body.IsDynamic());
    assert(body.GetPosition() == Vec3(4, 5, 6));
    assert(body.GetCenterOfMassPosition() == Vec3(4, 5, 6));
    assert(body.GetWorldSpaceBounds().IsValid());
}

unittest {
    import engine.jph.physics.shape.empty_shape : EmptyShape;

    auto shape = new EmptyShape(Vec3(1, 0, 0));
    BodyCreationSettings settings = BodyCreationSettings(shape, Vec3(10, 0, 0), Quat.sIdentity(), EMotionType.Kinematic);
    auto motionPool = new MotionProperties[1];
    Body body;
    body.Initialize(BodyID(0, 1), settings, 0, &motionPool[0]);
    assert(body.GetCenterOfMassPosition() == Vec3(11, 0, 0));
    assert(body.GetPosition() == Vec3(10, 0, 0));
    body.SetRotation(Quat.sRotation(Vec3.sAxisZ(), 0.5f * 3.141592653589793f));
    assert(body.GetPosition().IsClose(Vec3(10, 0, 0), 1.0e-5f));
}

unittest {
    import engine.jph.physics.shape.box_shape : BoxShape;

    auto shape = new BoxShape(Vec3(1, 1, 1));
    BodyCreationSettings settings = BodyCreationSettings(shape, Vec3.sZero(), Quat.sIdentity(), EMotionType.Dynamic);
    auto motionPool = new MotionProperties[1];

    Body body;
    body.Initialize(BodyID(1, 1), settings, 0, &motionPool[0]);
    body.SetLinearVelocity(Vec3(2, 0, 0));
    body.SetAngularVelocity(Vec3(0, 0, 3.141592653589793f));

    body.IntegrateMotion(0.5f);

    assert(body.GetCenterOfMassPosition().IsClose(Vec3(1, 0, 0), 1.0e-5f));
    assert((body.GetRotation() * Vec3(1, 0, 0)).IsClose(Vec3(0, 1, 0), 1.0e-5f));
}