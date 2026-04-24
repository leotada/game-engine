// Jolt — Physics/Body/BodyManager.h port (single-threaded simple-rigidbody subset).
//
// This manager owns fixed-capacity body slots and a matching MotionProperties
// pool. Bodies are addressed through BodyID and slots are recycled through a
// free list, preserving sequence-number semantics.
module engine.jph.physics.body.body_manager;

import engine.jph.physics.body.body;
import engine.jph.physics.body.body_creation_settings;
import engine.jph.physics.body.bodyid;
import engine.jph.physics.body.bodytype;
import engine.jph.physics.body.motionproperties;
import engine.jph.physics.body.motiontype;
import engine.jph.physics.collision.broad_phase_layer;
import engine.jph.math.quat : Quat;
import engine.jph.math.vec3 : Vec3;
import engine.jph.physics.shape.shape : Shape;

@safe:

struct BodyManager {
@safe:
    enum uint cInvalidBodyIndex = uint.max;

    private Body[] mBodies;
    private MotionProperties[] mMotionPropertiesStorage;
    private bool[] mSlotUsed;
    private bool[] mHasMotionProperties;
    private uint[] mNextFree;
    private ubyte[] mSequenceNumbers;
    private BodyID[] mActiveDynamicBodies;
    private BodyID[] mActiveKinematicBodies;
    private uint mNumBodies = 0;
    private uint mNextBodyIndex = 0;
    private uint mFreeListStart = cInvalidBodyIndex;
    private uint mNumActiveDynamicBodies = 0;
    private uint mNumActiveKinematicBodies = 0;
    private BroadPhaseLayerInterface mBroadPhaseLayerInterface;

    void Init(uint inMaxBodies,
              BroadPhaseLayerInterface inBroadPhaseLayerInterface = null) {
        mBodies = new Body[inMaxBodies];
        mMotionPropertiesStorage = new MotionProperties[inMaxBodies];
        mSlotUsed = new bool[inMaxBodies];
        mHasMotionProperties = new bool[inMaxBodies];
        mNextFree = new uint[inMaxBodies];
        mSequenceNumbers = new ubyte[inMaxBodies];
        mActiveDynamicBodies = new BodyID[inMaxBodies];
        mActiveKinematicBodies = new BodyID[inMaxBodies];
        mNumBodies = 0;
        mNextBodyIndex = 0;
        mFreeListStart = cInvalidBodyIndex;
        mNumActiveDynamicBodies = 0;
        mNumActiveKinematicBodies = 0;
        mBroadPhaseLayerInterface = inBroadPhaseLayerInterface is null
            ? BroadPhaseLayerInterface.sDefault()
            : inBroadPhaseLayerInterface;
    }

    uint GetNumBodies() const nothrow @nogc {
        return mNumBodies;
    }

    uint GetMaxBodies() const nothrow @nogc {
        return cast(uint) mBodies.length;
    }

    uint GetNumActiveBodies(EMotionType inMotionType) const nothrow @nogc {
        final switch (inMotionType) {
        case EMotionType.Static:
            return 0;
        case EMotionType.Kinematic:
            return mNumActiveKinematicBodies;
        case EMotionType.Dynamic:
            return mNumActiveDynamicBodies;
        }
    }

    BodyID CreateBody(ref const BodyCreationSettings inSettings) nothrow @nogc {
        if (!isBodyCreationValid(inSettings))
            return BodyID();

        immutable index = allocateBodyIndex();
        if (index == cInvalidBodyIndex)
            return BodyID();

        immutable id = BodyID(index, nextSequenceNumber(index));
        initializeBody(index, id, inSettings);
        return id;
    }

    bool DestroyBody(BodyID inBodyID) nothrow @nogc {
        auto body = TryGetBody(inBodyID);
        if (body is null)
            return false;

        if (body.IsActive())
            DeactivateBody(inBodyID);

        body.SetInBroadPhase(false);
        freeBodyIndex(inBodyID.GetIndex());
        return true;
    }

    bool ActivateBody(BodyID inBodyID) nothrow @nogc {
        auto body = TryGetBody(inBodyID);
        if (body is null || body.IsStatic() || body.GetMotionPropertiesUnchecked() is null)
            return false;

        auto motionProperties = body.GetMotionPropertiesUnchecked();
        if (motionProperties.mIndexInActiveBodies != MotionProperties.cInactiveIndex) {
            body.ResetSleepTimer();
            return true;
        }

        final switch (body.mMotionType) {
        case EMotionType.Static:
            return false;
        case EMotionType.Kinematic:
            assert(mNumActiveKinematicBodies < mActiveKinematicBodies.length);
            motionProperties.mIndexInActiveBodies = mNumActiveKinematicBodies;
            mActiveKinematicBodies[mNumActiveKinematicBodies++] = inBodyID;
            break;
        case EMotionType.Dynamic:
            assert(mNumActiveDynamicBodies < mActiveDynamicBodies.length);
            motionProperties.mIndexInActiveBodies = mNumActiveDynamicBodies;
            mActiveDynamicBodies[mNumActiveDynamicBodies++] = inBodyID;
            break;
        }

        body.ResetSleepTimer();
        return true;
    }

    bool DeactivateBody(BodyID inBodyID) nothrow @nogc {
        auto body = TryGetBody(inBodyID);
        if (body is null || body.GetMotionPropertiesUnchecked() is null)
            return false;

        auto motionProperties = body.GetMotionPropertiesUnchecked();
        immutable indexInActiveBodies = motionProperties.mIndexInActiveBodies;
        if (indexInActiveBodies == MotionProperties.cInactiveIndex)
            return false;

        final switch (body.mMotionType) {
        case EMotionType.Static:
            return false;
        case EMotionType.Kinematic:
            assert(indexInActiveBodies < mNumActiveKinematicBodies);
            --mNumActiveKinematicBodies;
            swapRemoveActiveBody(mActiveKinematicBodies, mNumActiveKinematicBodies, indexInActiveBodies);
            break;
        case EMotionType.Dynamic:
            assert(indexInActiveBodies < mNumActiveDynamicBodies);
            --mNumActiveDynamicBodies;
            swapRemoveActiveBody(mActiveDynamicBodies, mNumActiveDynamicBodies, indexInActiveBodies);
            break;
        }

        motionProperties.mIndexInActiveBodies = MotionProperties.cInactiveIndex;
        return true;
    }

    const(Body)* TryGetBody(BodyID inBodyID) const nothrow @nogc @trusted {
        immutable index = inBodyID.GetIndex();
        if (index >= mBodies.length || !mSlotUsed[index])
            return null;

        auto body = &mBodies[index];
        return body.mID == inBodyID ? cast(const(Body)*) body : null;
    }

    Body* TryGetBody(BodyID inBodyID) nothrow @nogc @trusted {
        immutable index = inBodyID.GetIndex();
        if (index >= mBodies.length || !mSlotUsed[index])
            return null;

        auto body = &mBodies[index];
        return body.mID == inBodyID ? body : null;
    }

    const(BodyID)* GetActiveBodiesUnsafe(EMotionType inMotionType) const nothrow @nogc @trusted {
        final switch (inMotionType) {
        case EMotionType.Static:
            return null;
        case EMotionType.Kinematic:
            return mActiveKinematicBodies.ptr;
        case EMotionType.Dynamic:
            return mActiveDynamicBodies.ptr;
        }
    }

    void SetBodyObjectLayerInternal(BodyID inBodyID, BroadPhaseLayerInterface inBroadPhaseLayerInterface, ushort inLayer) nothrow @nogc {
        auto body = TryGetBody(inBodyID);
        if (body is null)
            return;
        body.SetObjectLayer(inLayer, inBroadPhaseLayerInterface.GetBroadPhaseLayer(inLayer));
    }

    void InvalidateContactCacheForBody(BodyID inBodyID) nothrow @nogc {
        auto body = TryGetBody(inBodyID);
        if (body !is null)
            body.InvalidateContactCache();
    }

    void ValidateContactCacheForAllBodies() nothrow @nogc {
        foreach (index, used; mSlotUsed)
            if (used)
                mBodies[index].ValidateContactCache();
    }

    private bool isBodyCreationValid(ref const BodyCreationSettings inSettings) const nothrow @nogc {
        const(Shape) shape = inSettings.GetShape();
        if (shape is null)
            return false;
        if (shape.MustBeStatic() && inSettings.mMotionType != EMotionType.Static)
            return false;
        return true;
    }

    private uint allocateBodyIndex() nothrow @nogc {
        if (mFreeListStart != cInvalidBodyIndex) {
            immutable index = mFreeListStart;
            mFreeListStart = mNextFree[index];
            return index;
        }

        if (mNextBodyIndex >= mBodies.length)
            return cInvalidBodyIndex;

        return mNextBodyIndex++;
    }

    private ubyte nextSequenceNumber(uint inBodyIndex) nothrow @nogc {
        ++mSequenceNumbers[inBodyIndex];
        return mSequenceNumbers[inBodyIndex];
    }

    private void initializeBody(uint inBodyIndex,
                                BodyID inBodyID,
                                ref const BodyCreationSettings inSettings) nothrow @nogc {
        MotionProperties* motionProperties = null;
        if (inSettings.HasMassProperties()) {
            resetMotionProperties(inBodyIndex, inSettings);
            motionProperties = getMotionPropertiesPtr(inBodyIndex);
        } else {
            mMotionPropertiesStorage[inBodyIndex] = MotionProperties.init;
            mHasMotionProperties[inBodyIndex] = false;
        }

        auto broadPhaseLayer = mBroadPhaseLayerInterface.GetBroadPhaseLayer(inSettings.mObjectLayer);
        mBodies[inBodyIndex] = Body.init;
        mBodies[inBodyIndex].Initialize(inBodyID, inSettings, broadPhaseLayer, motionProperties);
        mSlotUsed[inBodyIndex] = true;
        ++mNumBodies;
    }

    private void resetMotionProperties(uint inBodyIndex,
                                       ref const BodyCreationSettings inSettings) nothrow @nogc {
        auto motion = MotionProperties.init;
        motion.mMotionQuality = inSettings.mMotionQuality;
        motion.mAllowSleeping = inSettings.mAllowSleeping;
        motion.mAllowedDOFs = inSettings.mAllowedDOFs;
        motion.mGravityFactor = inSettings.mGravityFactor;
        motion.mCachedBodyType = EBodyType.RigidBody;
        motion.mCachedMotionType = inSettings.mMotionType;
        motion.SetLinearDamping(inSettings.mLinearDamping);
        motion.SetAngularDamping(inSettings.mAngularDamping);
        motion.SetMaxLinearVelocity(inSettings.mMaxLinearVelocity);
        motion.SetMaxAngularVelocity(inSettings.mMaxAngularVelocity);
        motion.SetNumVelocityStepsOverride(inSettings.mNumVelocityStepsOverride);
        motion.SetNumPositionStepsOverride(inSettings.mNumPositionStepsOverride);
        motion.mIndexInActiveBodies = MotionProperties.cInactiveIndex;
        motion.mIslandIndex = MotionProperties.cInactiveIndex;
        motion.SetLinearVelocityClamped(inSettings.mLinearVelocity);
        motion.SetAngularVelocityClamped(inSettings.mAngularVelocity);
        auto massProperties = inSettings.GetMassProperties();
        motion.SetMassProperties(inSettings.mAllowedDOFs, massProperties);
        mMotionPropertiesStorage[inBodyIndex] = motion;
        mHasMotionProperties[inBodyIndex] = true;
    }

    private void freeBodyIndex(uint inBodyIndex) nothrow @nogc {
        mBodies[inBodyIndex] = Body.init;
        mMotionPropertiesStorage[inBodyIndex] = MotionProperties.init;
        mSlotUsed[inBodyIndex] = false;
        mHasMotionProperties[inBodyIndex] = false;
        mNextFree[inBodyIndex] = mFreeListStart;
        mFreeListStart = inBodyIndex;
        assert(mNumBodies > 0);
        --mNumBodies;
    }

    private void swapRemoveActiveBody(BodyID[] inActiveBodies,
                                      uint inNewCount,
                                      uint inIndex) nothrow @nogc {
        immutable movedBodyID = inActiveBodies[inNewCount];
        inActiveBodies[inIndex] = movedBodyID;
        if (inIndex != inNewCount) {
            auto movedBody = TryGetBody(movedBodyID);
            assert(movedBody !is null && movedBody.GetMotionPropertiesUnchecked() !is null);
            movedBody.GetMotionPropertiesUnchecked().mIndexInActiveBodies = inIndex;
        }
        inActiveBodies[inNewCount] = BodyID();
    }

    private MotionProperties* getMotionPropertiesPtr(uint inBodyIndex) nothrow @nogc @trusted {
        return &mMotionPropertiesStorage[inBodyIndex];
    }
}

unittest {
    import engine.jph.math.vec3 : Vec3;
    import engine.jph.physics.body.motiontype : EMotionType;
    import engine.jph.physics.shape.box_shape : BoxShape;

    BodyManager manager;
    manager.Init(4);

    auto shape = new BoxShape(Vec3(0.5f, 0.5f, 0.5f));
    BodyCreationSettings settings = BodyCreationSettings(shape, Vec3(1, 2, 3), Quat.sIdentity(), EMotionType.Dynamic);
    immutable first = manager.CreateBody(settings);
    assert(!first.IsInvalid());
    assert(manager.GetNumBodies() == 1);
    assert(manager.TryGetBody(first) !is null);

    assert(manager.ActivateBody(first));
    assert(manager.GetNumActiveBodies(EMotionType.Dynamic) == 1);
    assert(manager.DeactivateBody(first));
    assert(manager.GetNumActiveBodies(EMotionType.Dynamic) == 0);

    assert(manager.DestroyBody(first));
    assert(manager.GetNumBodies() == 0);

    immutable second = manager.CreateBody(settings);
    assert(second.GetIndex() == first.GetIndex());
    assert(second.GetSequenceNumber() != first.GetSequenceNumber());
}

unittest {
    import engine.jph.geometry.plane : Plane;
    import engine.jph.physics.shape.plane_shape : PlaneShape;

    BodyManager manager;
    manager.Init(2);

    auto planeShape = new PlaneShape(Plane(Vec3.sAxisY(), 0.0f));
    BodyCreationSettings settings = BodyCreationSettings(planeShape, Vec3.sZero(), Quat.sIdentity(), EMotionType.Dynamic);
    assert(manager.CreateBody(settings).IsInvalid());
}