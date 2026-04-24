// Jolt — Physics/Body/BodyInterface.h port (simple rigid-body subset).
//
// This first pass keeps the public surface ID-based and single-threaded.
// Broadphase integration is represented by the IsInBroadPhase flag for now;
// the actual broadphase object will plug in behind the same methods later.
module engine.jph.physics.body.body_interface;

import engine.jph.geometry.aabox : AABox;
import engine.jph.math.mat44 : Mat44;
import engine.jph.math.quat : Quat;
import engine.jph.math.vec3 : Vec3;
import engine.jph.physics.broadphase.broad_phase : BroadPhase;
import engine.jph.physics.body.body;
import engine.jph.physics.body.body_creation_settings;
import engine.jph.physics.body.bodyid;
import engine.jph.physics.body.body_manager;
import engine.jph.physics.eactivation;

@safe:

struct BodyInterface {
@safe:
    private size_t mBodyManagerAddress = 0;
    private BroadPhase mBroadPhase;

    void Init(scope BodyManager* inBodyManager,
              BroadPhase inBroadPhase = null) @trusted nothrow @nogc {
        mBodyManagerAddress = cast(size_t) inBodyManager;
        mBroadPhase = inBroadPhase;
    }

    bool IsInitialized() const nothrow @nogc {
        return mBodyManagerAddress != 0;
    }

    BodyID CreateBody(ref const BodyCreationSettings inSettings) nothrow @nogc {
        auto bodyManager = getBodyManager();
        return bodyManager is null ? BodyID() : bodyManager.CreateBody(inSettings);
    }

    bool DestroyBody(BodyID inBodyID) nothrow @nogc {
        auto bodyManager = getBodyManager();
        if (bodyManager is null)
            return false;
        if (IsAdded(inBodyID))
            RemoveBody(inBodyID);
        return bodyManager.DestroyBody(inBodyID);
    }

    void AddBody(BodyID inBodyID, EActivation inActivationMode) nothrow @nogc {
        auto body = TryGetBody(inBodyID);
        if (body is null || body.IsInBroadPhase())
            return;

        if (mBroadPhase !is null) {
            BodyID[1] bodyIDs = [inBodyID];
            mBroadPhase.AddBodiesFinalize(bodyIDs[]);
        } else {
            body.SetInBroadPhase(true);
            body.UpdateWorldBounds();
        }

        if (inActivationMode == EActivation.Activate && !body.IsStatic())
            getBodyManager().ActivateBody(inBodyID);
    }

    void RemoveBody(BodyID inBodyID) nothrow @nogc {
        auto body = TryGetBody(inBodyID);
        if (body is null || !body.IsInBroadPhase())
            return;

        if (body.IsActive())
            getBodyManager().DeactivateBody(inBodyID);

        if (mBroadPhase !is null) {
            BodyID[1] bodyIDs = [inBodyID];
            mBroadPhase.RemoveBodies(bodyIDs[]);
        } else {
            body.SetInBroadPhase(false);
        }
    }

    bool IsAdded(BodyID inBodyID) const nothrow @nogc {
        auto body = TryGetBodyConst(inBodyID);
        return body !is null && body.IsInBroadPhase();
    }

    BodyID CreateAndAddBody(ref const BodyCreationSettings inSettings,
                            EActivation inActivationMode) nothrow @nogc {
        immutable bodyID = CreateBody(inSettings);
        if (!bodyID.IsInvalid())
            AddBody(bodyID, inActivationMode);
        return bodyID;
    }

    void ActivateBody(BodyID inBodyID) nothrow @nogc {
        auto bodyManager = getBodyManager();
        if (bodyManager !is null)
            bodyManager.ActivateBody(inBodyID);
    }

    void DeactivateBody(BodyID inBodyID) nothrow @nogc {
        auto bodyManager = getBodyManager();
        if (bodyManager !is null)
            bodyManager.DeactivateBody(inBodyID);
    }

    bool IsActive(BodyID inBodyID) const nothrow @nogc {
        auto body = TryGetBodyConst(inBodyID);
        return body !is null && body.IsActive();
    }

    void SetPositionAndRotation(BodyID inBodyID,
                                Vec3 inPosition,
                                Quat inRotation,
                                EActivation inActivationMode) nothrow @nogc {
        auto body = TryGetBody(inBodyID);
        if (body is null)
            return;
        body.SetPositionAndRotation(inPosition, inRotation);
        notifyBodyAABBChanged(inBodyID, body);
        if (inActivationMode == EActivation.Activate && !body.IsStatic())
            getBodyManager().ActivateBody(inBodyID);
    }

    void SetPosition(BodyID inBodyID,
                     Vec3 inPosition,
                     EActivation inActivationMode) nothrow @nogc {
        auto body = TryGetBody(inBodyID);
        if (body is null)
            return;
        body.SetPosition(inPosition);
        notifyBodyAABBChanged(inBodyID, body);
        if (inActivationMode == EActivation.Activate && !body.IsStatic())
            getBodyManager().ActivateBody(inBodyID);
    }

    Vec3 GetPosition(BodyID inBodyID) const nothrow @nogc {
        auto body = TryGetBodyConst(inBodyID);
        return body is null ? Vec3.sZero() : body.GetPosition();
    }

    Vec3 GetCenterOfMassPosition(BodyID inBodyID) const nothrow @nogc {
        auto body = TryGetBodyConst(inBodyID);
        return body is null ? Vec3.sZero() : body.GetCenterOfMassPosition();
    }

    void SetRotation(BodyID inBodyID,
                     Quat inRotation,
                     EActivation inActivationMode) nothrow @nogc {
        auto body = TryGetBody(inBodyID);
        if (body is null)
            return;
        body.SetRotation(inRotation);
        notifyBodyAABBChanged(inBodyID, body);
        if (inActivationMode == EActivation.Activate && !body.IsStatic())
            getBodyManager().ActivateBody(inBodyID);
    }

    Quat GetRotation(BodyID inBodyID) const nothrow @nogc {
        auto body = TryGetBodyConst(inBodyID);
        return body is null ? Quat.sIdentity() : body.GetRotation();
    }

    Mat44 GetWorldTransform(BodyID inBodyID) const nothrow @nogc {
        auto body = TryGetBodyConst(inBodyID);
        return body is null ? Mat44.sIdentity() : body.GetWorldTransform();
    }

    Mat44 GetCenterOfMassTransform(BodyID inBodyID) const nothrow @nogc {
        auto body = TryGetBodyConst(inBodyID);
        return body is null ? Mat44.sIdentity() : body.GetCenterOfMassTransform();
    }

    AABox GetWorldSpaceBounds(BodyID inBodyID) const nothrow @nogc {
        auto body = TryGetBodyConst(inBodyID);
        return body is null ? AABox() : body.GetWorldSpaceBounds();
    }

    void SetLinearVelocity(BodyID inBodyID, Vec3 inLinearVelocity) nothrow @nogc {
        auto body = TryGetBody(inBodyID);
        if (body is null)
            return;
        body.SetLinearVelocityClamped(inLinearVelocity);
        if (!body.IsStatic())
            getBodyManager().ActivateBody(inBodyID);
    }

    Vec3 GetLinearVelocity(BodyID inBodyID) const nothrow @nogc {
        auto body = TryGetBodyConst(inBodyID);
        return body is null ? Vec3.sZero() : body.GetLinearVelocity();
    }

    void SetAngularVelocity(BodyID inBodyID, Vec3 inAngularVelocity) nothrow @nogc {
        auto body = TryGetBody(inBodyID);
        if (body is null)
            return;
        body.SetAngularVelocityClamped(inAngularVelocity);
        if (!body.IsStatic())
            getBodyManager().ActivateBody(inBodyID);
    }

    Vec3 GetAngularVelocity(BodyID inBodyID) const nothrow @nogc {
        auto body = TryGetBodyConst(inBodyID);
        return body is null ? Vec3.sZero() : body.GetAngularVelocity();
    }

    void AddForce(BodyID inBodyID,
                  Vec3 inForce,
                  EActivation inActivationMode = EActivation.Activate) nothrow @nogc {
        auto body = TryGetBody(inBodyID);
        if (body is null)
            return;
        body.AddForce(inForce);
        if (inActivationMode == EActivation.Activate && !body.IsStatic())
            getBodyManager().ActivateBody(inBodyID);
    }

    void AddForce(BodyID inBodyID,
                  Vec3 inForce,
                  Vec3 inPoint,
                  EActivation inActivationMode = EActivation.Activate) nothrow @nogc {
        auto body = TryGetBody(inBodyID);
        if (body is null)
            return;
        body.AddForce(inForce, inPoint);
        if (inActivationMode == EActivation.Activate && !body.IsStatic())
            getBodyManager().ActivateBody(inBodyID);
    }

    void AddTorque(BodyID inBodyID,
                   Vec3 inTorque,
                   EActivation inActivationMode = EActivation.Activate) nothrow @nogc {
        auto body = TryGetBody(inBodyID);
        if (body is null)
            return;
        body.AddTorque(inTorque);
        if (inActivationMode == EActivation.Activate && !body.IsStatic())
            getBodyManager().ActivateBody(inBodyID);
    }

    private const(Body)* TryGetBodyConst(BodyID inBodyID) const nothrow @nogc {
        auto bodyManager = getBodyManagerConst();
        return bodyManager is null ? null : bodyManager.TryGetBody(inBodyID);
    }

    private Body* TryGetBody(BodyID inBodyID) nothrow @nogc {
        auto bodyManager = getBodyManager();
        return bodyManager is null ? null : bodyManager.TryGetBody(inBodyID);
    }

    private const(BodyManager)* getBodyManagerConst() const nothrow @nogc @trusted {
        return mBodyManagerAddress == 0 ? null : cast(const(BodyManager)*) mBodyManagerAddress;
    }

    private BodyManager* getBodyManager() nothrow @nogc @trusted {
        return mBodyManagerAddress == 0 ? null : cast(BodyManager*) mBodyManagerAddress;
    }

    private void notifyBodyAABBChanged(BodyID inBodyID, Body* inBody) nothrow @nogc {
        if (mBroadPhase !is null && inBody !is null && inBody.IsInBroadPhase()) {
            BodyID[1] bodyIDs = [inBodyID];
            mBroadPhase.NotifyBodiesAABBChanged(bodyIDs[]);
        }
    }
}

unittest {
    import engine.jph.physics.broadphase.broad_phase_brute_force : BroadPhaseBruteForce;
    import engine.jph.physics.body.motiontype : EMotionType;
    import engine.jph.physics.shape.box_shape : BoxShape;

    BodyManager manager;
    manager.Init(8);
    auto broadPhase = new BroadPhaseBruteForce();
    broadPhase.Init(&manager);

    BodyInterface bodyInterface;
    bodyInterface.Init(&manager, broadPhase);

    auto shape = new BoxShape(Vec3(1, 1, 1));
    BodyCreationSettings settings = BodyCreationSettings(shape, Vec3(1, 2, 3), Quat.sIdentity(), EMotionType.Dynamic);
    immutable bodyID = bodyInterface.CreateAndAddBody(settings, EActivation.Activate);
    assert(!bodyID.IsInvalid());
    assert(bodyInterface.IsAdded(bodyID));
    assert(bodyInterface.IsActive(bodyID));
    assert(bodyInterface.GetPosition(bodyID) == Vec3(1, 2, 3));

    bodyInterface.SetPosition(bodyID, Vec3(4, 5, 6), EActivation.DontActivate);
    assert(bodyInterface.GetPosition(bodyID) == Vec3(4, 5, 6));
    bodyInterface.RemoveBody(bodyID);
    assert(!bodyInterface.IsAdded(bodyID));
    assert(!bodyInterface.IsActive(bodyID));
    assert(bodyInterface.DestroyBody(bodyID));
    assert(manager.GetNumBodies() == 0);
}

unittest {
    import engine.jph.physics.broadphase.broad_phase_brute_force : BroadPhaseBruteForce;
    import engine.jph.physics.body.motiontype : EMotionType;
    import engine.jph.physics.shape.box_shape : BoxShape;

    BodyManager manager;
    manager.Init(2);
    auto broadPhase = new BroadPhaseBruteForce();
    broadPhase.Init(&manager);

    BodyInterface bodyInterface;
    bodyInterface.Init(&manager, broadPhase);

    BodyCreationSettings settings = BodyCreationSettings(new BoxShape(Vec3(0.5f, 0.5f, 0.5f)), Vec3.sZero(), Quat.sIdentity(), EMotionType.Static);
    immutable staticBody = bodyInterface.CreateAndAddBody(settings, EActivation.Activate);
    assert(!bodyInterface.IsActive(staticBody));
}