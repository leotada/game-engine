// Jolt — Physics/PhysicsSystem.h port (minimal owner for the simple-rigidbody path).
//
// This first pass owns BodyManager, BodyInterface, and a broadphase seam.
// Stepping, narrowphase, and solver orchestration will be layered on top of
// this runtime owner in subsequent slices.
module engine.jph.physics.physics_system;

import std.math : fabs;
import engine.jph.core.array : Array;
import engine.jph.physics.broadphase : BroadPhase, BroadPhaseBruteForce;
import engine.jph.physics.body.bodyid : BodyID;
import engine.jph.physics.body.bodypair : BodyPair;
import engine.jph.math.quat : Quat;
import engine.jph.math.vec3 : Vec3;
import engine.jph.physics.body.body : Body;
import engine.jph.physics.body.body_interface : BodyInterface;
import engine.jph.physics.body.body_manager : BodyManager;
import engine.jph.physics.body.motiontype : EMotionType;
import engine.jph.physics.collision.broad_phase_layer : BroadPhaseLayerInterface;
import engine.jph.physics.collision.collide_shape : CollideShapeSettings, ContactManifold;
import engine.jph.physics.collision.collision_dispatch : CollideBodies;
import engine.jph.physics.constraints.contact_constraint_manager : ContactConstraintManager;
import engine.jph.physics.collision.object_layer_pair_filter : ObjectLayerPairFilter;
import engine.jph.physics.collision.object_vs_broad_phase_layer_filter : ObjectVsBroadPhaseLayerFilter;
import engine.jph.physics.eactivation : EActivation;
import engine.jph.physics.physics_settings : PhysicsSettings;

@safe:

struct PhysicsStats {
@safe:
    uint mActiveBodies = 0;
    uint mSleepingBodies = 0;
    uint mManifoldCount = 0;
    uint mBroadphasePairs = 0;
}

struct PhysicsSystem {
@safe:
    private BodyManager mBodyManager;
    private BroadPhase mBroadPhase;
    private BodyInterface mBodyInterface;
    private ContactConstraintManager mContactConstraintManager;
    private Array!BodyID mActiveBodiesScratch;
    private Array!BodyPair mBroadPhasePairs;
    private Array!ContactManifold mContactManifolds;

    Vec3 mGravity = Vec3(0, -9.81f, 0);
    PhysicsStats mStats;

    void Init(uint inMaxBodies,
              BroadPhaseLayerInterface inBroadPhaseLayerInterface = null) {
        mBodyManager.Init(inMaxBodies, inBroadPhaseLayerInterface);
        mBroadPhase = new BroadPhaseBruteForce();
        mBroadPhase.Init(&mBodyManager, inBroadPhaseLayerInterface);
        mBodyInterface.Init(&mBodyManager, mBroadPhase);
        mContactConstraintManager.Init(&mBodyManager, mBroadPhase);
        RefreshStats();
    }

    ref BodyInterface GetBodyInterface() return {
        return mBodyInterface;
    }

    uint GetNumBodies() const nothrow @nogc {
        return mBodyManager.GetNumBodies();
    }

    uint GetMaxBodies() const nothrow @nogc {
        return mBodyManager.GetMaxBodies();
    }

    uint GetNumActiveBodies() const nothrow @nogc {
        return mBodyManager.GetNumActiveBodies(EMotionType.Dynamic)
             + mBodyManager.GetNumActiveBodies(EMotionType.Kinematic);
    }

    void Step(float inDeltaTime,
              PhysicsSettings inSettings = PhysicsSettings.init) nothrow @nogc {
        cast(void) inSettings;
        if (inDeltaTime <= 0.0f) {
            RefreshStats();
            return;
        }

        collectActiveBodiesScratch();

        foreach (bodyID; mActiveBodiesScratch[]) {
            auto body = mBodyManager.TryGetBody(bodyID);
            if (body is null)
                continue;

            if (body.IsDynamic()) {
                auto motionProperties = body.GetMotionPropertiesUnchecked();
                if (motionProperties !is null)
                    motionProperties.ApplyForceTorqueAndDragInternal(
                        body.GetRotation(),
                        mGravity,
                        inDeltaTime);
            }

            body.IntegrateMotion(inDeltaTime);
            notifyBodyAABBChanged(bodyID, body);
            body.ResetForce();
            body.ResetTorque();
        }

        auto manifolds = CollectContactManifolds(CollideShapeSettings(
            1.0e-4f,
            1.0e-4f,
            inSettings.mPenetrationSlop));
        mContactConstraintManager.Solve(manifolds, inSettings);
        mStats.mBroadphasePairs = cast(uint) mBroadPhasePairs.size;
        mStats.mManifoldCount = cast(uint) manifolds.length;
    }

    const(BodyPair)[] CollectBroadPhasePairs(float inSpeculativeContactDistance = 0.0f,
                                             ObjectVsBroadPhaseLayerFilter inObjectVsBroadPhaseLayerFilter = null,
                                             ObjectLayerPairFilter inObjectLayerPairFilter = null) nothrow @nogc {
        collectActiveBodiesScratch();

        if (mBroadPhase !is null)
            mBroadPhase.FindCollidingPairs(mActiveBodiesScratch[],
                                           inSpeculativeContactDistance,
                                           inObjectVsBroadPhaseLayerFilter,
                                           inObjectLayerPairFilter,
                                           mBroadPhasePairs);
        else
            mBroadPhasePairs.clear();

        RefreshStats();
        mStats.mBroadphasePairs = cast(uint) mBroadPhasePairs.size;
        return mBroadPhasePairs[];
    }

    const(BodyPair)[] GetBroadPhasePairs() const nothrow @nogc {
        return mBroadPhasePairs[];
    }

    const(ContactManifold)[] CollectContactManifolds(
        CollideShapeSettings inSettings = CollideShapeSettings.init) nothrow @nogc {
        auto broadPhasePairs = CollectBroadPhasePairs(inSettings.mMaxSeparationDistance);
        mContactManifolds.clear();

        foreach (pair; broadPhasePairs) {
            auto body1 = mBodyManager.TryGetBody(pair.mBodyA);
            auto body2 = mBodyManager.TryGetBody(pair.mBodyB);
            if (body1 is null || body2 is null)
                continue;

            ContactManifold manifold;
            if (!CollideBodies(body1[0], body2[0], inSettings, manifold))
                continue;

            mContactManifolds.push_back(manifold);
        }

        mStats.mManifoldCount = cast(uint) mContactManifolds.size;
        return mContactManifolds[];
    }

    const(ContactManifold)[] GetContactManifolds() const nothrow @nogc {
        return mContactManifolds[];
    }

    void RefreshStats() nothrow @nogc {
        immutable active = GetNumActiveBodies();
        mStats.mActiveBodies = active;
        mStats.mSleepingBodies = GetNumBodies() > active ? GetNumBodies() - active : 0;
        mStats.mManifoldCount = 0;
        mStats.mBroadphasePairs = 0;
    }

    private static const(BodyID)[] sliceFromPtr(const(BodyID)* inBodies,
                                                size_t inCount) nothrow @nogc @trusted {
        return inBodies is null ? null : inBodies[0 .. inCount];
    }

    private void collectActiveBodiesScratch() nothrow @nogc {
        immutable dynamicCount = mBodyManager.GetNumActiveBodies(EMotionType.Dynamic);
        immutable kinematicCount = mBodyManager.GetNumActiveBodies(EMotionType.Kinematic);
        immutable totalActive = dynamicCount + kinematicCount;

        mActiveBodiesScratch.resize(totalActive);

        size_t outIndex = 0;
        foreach (bodyID; sliceFromPtr(mBodyManager.GetActiveBodiesUnsafe(EMotionType.Dynamic), dynamicCount))
            mActiveBodiesScratch[outIndex++] = bodyID;

        foreach (bodyID; sliceFromPtr(mBodyManager.GetActiveBodiesUnsafe(EMotionType.Kinematic), kinematicCount))
            mActiveBodiesScratch[outIndex++] = bodyID;
    }

    private void notifyBodyAABBChanged(BodyID inBodyID,
                                       Body* inBody) nothrow @nogc {
        if (mBroadPhase is null || inBody is null || !inBody.IsInBroadPhase())
            return;

        BodyID[1] bodyIDs = [inBodyID];
        mBroadPhase.NotifyBodiesAABBChanged(bodyIDs[]);
    }
}

unittest {
    import engine.jph.physics.body.body_creation_settings : BodyCreationSettings;
    import engine.jph.physics.shape.box_shape : BoxShape;

    PhysicsSystem system;
    system.Init(8);

    auto shape = new BoxShape(Vec3(1, 1, 1));
    BodyCreationSettings settings = BodyCreationSettings(shape);
    immutable bodyID = system.GetBodyInterface().CreateAndAddBody(settings, EActivation.Activate);
    assert(!bodyID.IsInvalid());
    system.RefreshStats();
    assert(system.GetNumBodies() == 1);
    assert(system.GetNumActiveBodies() == 1);
    assert(system.mStats.mSleepingBodies == 0);
}

unittest {
    import engine.jph.physics.body.body_creation_settings : BodyCreationSettings;
    import engine.jph.physics.body.motiontype : EMotionType;
    import engine.jph.physics.shape.box_shape : BoxShape;

    PhysicsSystem system;
    system.Init(8);

    auto bodyInterface = &system.GetBodyInterface();
    BodyCreationSettings settingsA = BodyCreationSettings(
        new BoxShape(Vec3(1, 1, 1)),
        Vec3(0, 0, 0),
        Quat.sIdentity(),
        EMotionType.Dynamic);
    BodyCreationSettings settingsB = BodyCreationSettings(
        new BoxShape(Vec3(1, 1, 1)),
        Vec3(1, 0, 0),
        Quat.sIdentity(),
        EMotionType.Dynamic);

    immutable a = bodyInterface.CreateAndAddBody(settingsA, EActivation.Activate);
    immutable b = bodyInterface.CreateAndAddBody(settingsB, EActivation.Activate);

    auto pairs = system.CollectBroadPhasePairs();
    assert(pairs.length == 1);
    assert(pairs[0] == BodyPair(a, b));
    assert(system.mStats.mBroadphasePairs == 1);
}

unittest {
    import engine.jph.physics.body.body_creation_settings : BodyCreationSettings;
    import engine.jph.physics.body.motiontype : EMotionType;
    import engine.jph.physics.shape.box_shape : BoxShape;

    PhysicsSystem system;
    system.Init(8);

    auto bodyInterface = &system.GetBodyInterface();
    BodyCreationSettings dynamicSettings = BodyCreationSettings(
        new BoxShape(Vec3(1, 1, 1)),
        Vec3(0, 0, 0),
        Quat.sIdentity(),
        EMotionType.Dynamic);
    BodyCreationSettings staticSettings = BodyCreationSettings(
        new BoxShape(Vec3(1, 1, 1)),
        Vec3(0.5f, 0, 0),
        Quat.sIdentity(),
        EMotionType.Static);

    immutable dynamicBody = bodyInterface.CreateAndAddBody(dynamicSettings, EActivation.Activate);
    immutable staticBody = bodyInterface.CreateAndAddBody(staticSettings, EActivation.DontActivate);

    auto pairs = system.CollectBroadPhasePairs();
    assert(pairs.length == 1);
    assert(pairs[0] == BodyPair(dynamicBody, staticBody));
}

unittest {
    import engine.jph.physics.body.body_creation_settings : BodyCreationSettings;
    import engine.jph.physics.body.motiontype : EMotionType;
    import engine.jph.physics.shape.sphere_shape : SphereShape;

    PhysicsSystem system;
    system.Init(8);

    auto bodyInterface = &system.GetBodyInterface();
    BodyCreationSettings settings = BodyCreationSettings(
        new SphereShape(0.5f),
        Vec3(0, 5, 0),
        Quat.sIdentity(),
        EMotionType.Dynamic);
    immutable bodyID = bodyInterface.CreateAndAddBody(settings, EActivation.Activate);

    system.Step(0.5f);

    auto body = system.mBodyManager.TryGetBody(bodyID);
    assert(body !is null);
    assert(body.GetCenterOfMassPosition().GetY() < 5.0f);
    assert(body.GetLinearVelocity().GetY() < 0.0f);
    assert(body.GetAccumulatedForce() == Vec3.sZero());
    assert(body.GetAccumulatedTorque() == Vec3.sZero());
}

unittest {
    import engine.jph.geometry.plane : Plane;
    import engine.jph.physics.body.body_creation_settings : BodyCreationSettings;
    import engine.jph.physics.body.motiontype : EMotionType;
    import engine.jph.physics.shape.box_shape : BoxShape;
    import engine.jph.physics.shape.plane_shape : PlaneShape;
    import engine.jph.physics.shape.sphere_shape : SphereShape;

    PhysicsSystem system;
    system.Init(8);

    auto bodyInterface = &system.GetBodyInterface();
    BodyCreationSettings sphereSettings = BodyCreationSettings(
        new SphereShape(0.5f),
        Vec3(0, 0.25f, 0),
        Quat.sIdentity(),
        EMotionType.Dynamic);
    BodyCreationSettings planeSettings = BodyCreationSettings(
        new PlaneShape(Plane.sFromPointAndNormal(Vec3.sZero(), Vec3.sAxisY())),
        Vec3.sZero(),
        Quat.sIdentity(),
        EMotionType.Static);

    bodyInterface.CreateAndAddBody(sphereSettings, EActivation.Activate);
    bodyInterface.CreateAndAddBody(planeSettings, EActivation.DontActivate);

    auto manifolds = system.CollectContactManifolds();
    assert(manifolds.length == 1);
    assert(manifolds[0].GetNumContactPoints() == 1);
    assert(manifolds[0].mWorldSpaceNormal == Vec3.sAxisY());
    assert(system.mStats.mBroadphasePairs == 1);
    assert(system.mStats.mManifoldCount == 1);
}

unittest {
    import engine.jph.geometry.plane : Plane;
    import engine.jph.physics.body.body_creation_settings : BodyCreationSettings;
    import engine.jph.physics.body.motiontype : EMotionType;
    import engine.jph.physics.shape.box_shape : BoxShape;
    import engine.jph.physics.shape.plane_shape : PlaneShape;

    PhysicsSystem system;
    system.Init(8);

    auto bodyInterface = &system.GetBodyInterface();
    BodyCreationSettings boxSettings = BodyCreationSettings(
        new BoxShape(Vec3(0.5f, 0.5f, 0.5f)),
        Vec3(0, 0.25f, 0),
        Quat.sIdentity(),
        EMotionType.Dynamic);
    BodyCreationSettings planeSettings = BodyCreationSettings(
        new PlaneShape(Plane.sFromPointAndNormal(Vec3.sZero(), Vec3.sAxisY())),
        Vec3.sZero(),
        Quat.sIdentity(),
        EMotionType.Static);

    bodyInterface.CreateAndAddBody(boxSettings, EActivation.Activate);
    bodyInterface.CreateAndAddBody(planeSettings, EActivation.DontActivate);

    auto manifolds = system.CollectContactManifolds();
    assert(manifolds.length == 1);
    assert(manifolds[0].GetNumContactPoints() == 4);
    assert(manifolds[0].mWorldSpaceNormal == Vec3.sAxisY());
}

unittest {
    import std.math : fabs;
    import engine.jph.physics.body.body_creation_settings : BodyCreationSettings;
    import engine.jph.physics.body.motiontype : EMotionType;
    import engine.jph.physics.shape.box_shape : BoxShape;

    PhysicsSystem system;
    system.Init(8);

    auto bodyInterface = &system.GetBodyInterface();
    BodyCreationSettings dynamicSettings = BodyCreationSettings(
        new BoxShape(Vec3(0.5f, 0.5f, 0.5f)),
        Vec3(0, 2.0f, 0),
        Quat.sIdentity(),
        EMotionType.Dynamic);
    BodyCreationSettings staticSettings = BodyCreationSettings(
        new BoxShape(Vec3(2.0f, 0.5f, 2.0f)),
        Vec3(0, 0.0f, 0),
        Quat.sIdentity(),
        EMotionType.Static);

    immutable dynamicID = bodyInterface.CreateAndAddBody(dynamicSettings, EActivation.Activate);
    bodyInterface.CreateAndAddBody(staticSettings, EActivation.DontActivate);

    foreach (_; 0 .. 180)
        system.Step(1.0f / 60.0f);

    assert(bodyInterface.GetCenterOfMassPosition(dynamicID).GetY() > 0.95f);
    assert(fabs(bodyInterface.GetLinearVelocity(dynamicID).GetY()) < 0.5f);
}

unittest {
    import std.math : fabs;
    import engine.jph.geometry.plane : Plane;
    import engine.jph.physics.body.body_creation_settings : BodyCreationSettings;
    import engine.jph.physics.body.motiontype : EMotionType;
    import engine.jph.physics.shape.plane_shape : PlaneShape;
    import engine.jph.physics.shape.sphere_shape : SphereShape;

    PhysicsSystem system;
    system.Init(8);

    auto bodyInterface = &system.GetBodyInterface();
    BodyCreationSettings sphereSettings = BodyCreationSettings(
        new SphereShape(0.5f),
        Vec3(0, 2, 0),
        Quat.sIdentity(),
        EMotionType.Dynamic);
    BodyCreationSettings planeSettings = BodyCreationSettings(
        new PlaneShape(Plane.sFromPointAndNormal(Vec3.sZero(), Vec3.sAxisY())),
        Vec3.sZero(),
        Quat.sIdentity(),
        EMotionType.Static);

    immutable sphereID = bodyInterface.CreateAndAddBody(sphereSettings, EActivation.Activate);
    bodyInterface.CreateAndAddBody(planeSettings, EActivation.DontActivate);

    foreach (_; 0 .. 120)
        system.Step(1.0f / 60.0f);

    auto body = system.mBodyManager.TryGetBody(sphereID);
    assert(body !is null);
    assert(body.GetCenterOfMassPosition().GetY() > 0.47f);
    assert(fabs(body.GetLinearVelocity().GetY()) < 0.2f);
}
