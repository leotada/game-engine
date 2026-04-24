// Jolt — Physics/Collision/BroadPhase/BroadPhaseBruteForce.cpp port (simple subset).
//
// Reference implementation that keeps a flat list of bodies currently in the
// broadphase and performs O(n^2) overlap checks during pair generation.
module engine.jph.physics.broadphase.broad_phase_brute_force;

import engine.jph.core.array : Array;
import engine.jph.geometry.aabox : AABox;
import engine.jph.math.vec3 : Vec3;
import engine.jph.math.quat : Quat;
import engine.jph.physics.body.body;
import engine.jph.physics.body.body_creation_settings : BodyCreationSettings;
import engine.jph.physics.body.body_manager : BodyManager;
import engine.jph.physics.body.bodyid : BodyID;
import engine.jph.physics.body.bodypair : BodyPair;
import engine.jph.physics.body.motiontype : EMotionType;
import engine.jph.physics.broadphase.broad_phase : BroadPhase;
import engine.jph.physics.collision.object_layer_pair_filter : ObjectLayerPairFilter;
import engine.jph.physics.collision.object_vs_broad_phase_layer_filter : ObjectVsBroadPhaseLayerFilter;
import engine.jph.physics.shape.box_shape : BoxShape;

@safe:

final class BroadPhaseBruteForce : BroadPhase {
    private Array!BodyID mBodyIDs;

    override void AddBodiesFinalize(scope const BodyID[] inBodyIDs) nothrow @nogc {
        auto bodyManager = getBodyManager();
        if (bodyManager is null)
            return;

        mBodyIDs.reserve(mBodyIDs.size + inBodyIDs.length);

        foreach (bodyID; inBodyIDs) {
            auto body = bodyManager.TryGetBody(bodyID);
            if (body is null || body.IsInBroadPhase())
                continue;
            BodyID storedBodyID = bodyID;
            mBodyIDs.push_back(storedBodyID);
            body.SetInBroadPhase(true);
        }
    }

    override void RemoveBodies(scope const BodyID[] inBodyIDs) nothrow @nogc {
        auto bodyManager = getBodyManager();
        if (bodyManager is null)
            return;

        foreach (bodyID; inBodyIDs) {
            auto body = bodyManager.TryGetBody(bodyID);
            if (body is null || !body.IsInBroadPhase())
                continue;

            foreach (index; 0 .. mBodyIDs.size) {
                if (mBodyIDs[index] == bodyID) {
                    mBodyIDs.erase(index);
                    break;
                }
            }

            body.SetInBroadPhase(false);
        }
    }

    override void FindCollidingPairs(scope const BodyID[] inActiveBodies,
                                     float inSpeculativeContactDistance,
                                     ObjectVsBroadPhaseLayerFilter inObjectVsBroadPhaseLayerFilter,
                                     ObjectLayerPairFilter inObjectLayerPairFilter,
                                     ref Array!BodyPair ioPairs) const nothrow @nogc {
        auto bodyManager = getBodyManagerConst();
        if (bodyManager is null) {
            ioPairs.clear();
            return;
        }

        ioPairs.clear();

        foreach (bodyID1; inActiveBodies) {
            auto body1 = bodyManager.TryGetBody(bodyID1);
            if (body1 is null)
                continue;

            auto bounds1 = body1.GetWorldSpaceBounds();
            if (inSpeculativeContactDistance > 0.0f)
                bounds1.ExpandBy(Vec3.sReplicate(inSpeculativeContactDistance));

            foreach (index; 0 .. mBodyIDs.size) {
                immutable bodyID2 = mBodyIDs[index];
                auto body2 = bodyManager.TryGetBody(bodyID2);
                if (body2 is null)
                    continue;
                if (!Body.sFindCollidingPairsCanCollide(body1[0], body2[0]))
                    continue;
                if (inObjectVsBroadPhaseLayerFilter !is null
                 && !inObjectVsBroadPhaseLayerFilter.ShouldCollide(body1.GetObjectLayer(), body2.GetBroadPhaseLayer()))
                    continue;
                if (inObjectLayerPairFilter !is null
                 && !inObjectLayerPairFilter.ShouldCollide(body1.GetObjectLayer(), body2.GetObjectLayer()))
                    continue;
                if (!bounds1.Overlaps(body2.GetWorldSpaceBounds()))
                    continue;
                ioPairs.push_back(BodyPair(bodyID1, bodyID2));
            }
        }
    }

    override uint GetNumBodies() const nothrow @nogc {
        return cast(uint) mBodyIDs.size;
    }

    override AABox GetBounds() const nothrow @nogc {
        auto bodyManager = getBodyManagerConst();
        if (bodyManager is null)
            return AABox();

        AABox bounds;
        foreach (index; 0 .. mBodyIDs.size) {
            auto body = bodyManager.TryGetBody(mBodyIDs[index]);
            if (body !is null)
                bounds.Encapsulate(body.GetWorldSpaceBounds());
        }
        return bounds;
    }
}

unittest {
    BodyManager bodyManager;
    bodyManager.Init(4);

    auto broadPhase = new BroadPhaseBruteForce();
    broadPhase.Init(&bodyManager);

    BodyCreationSettings a = BodyCreationSettings(
        new BoxShape(Vec3(1, 1, 1)),
        Vec3.sZero(),
        Quat.sIdentity(),
        EMotionType.Dynamic);
    BodyCreationSettings b = BodyCreationSettings(
        new BoxShape(Vec3(1, 1, 1)),
        Vec3(1, 0, 0),
        Quat.sIdentity(),
        EMotionType.Dynamic);

    immutable bodyA = bodyManager.CreateBody(a);
    immutable bodyB = bodyManager.CreateBody(b);
    assert(bodyManager.ActivateBody(bodyA));
    assert(bodyManager.ActivateBody(bodyB));

    BodyID[2] added = [bodyA, bodyB];
    broadPhase.AddBodiesFinalize(added[]);
    assert(broadPhase.GetNumBodies() == 2);

    Array!BodyPair pairs;
    BodyID[] activeBodies = [bodyA, bodyB];
    broadPhase.FindCollidingPairs(activeBodies, 0.0f, null, null, pairs);
    assert(pairs.size == 1);
    assert(pairs[0] == BodyPair(bodyA, bodyB));
}

unittest {
    BodyManager bodyManager;
    bodyManager.Init(4);

    auto broadPhase = new BroadPhaseBruteForce();
    broadPhase.Init(&bodyManager);

    BodyCreationSettings dynamicBox = BodyCreationSettings(
        new BoxShape(Vec3(1, 1, 1)),
        Vec3(0, 0, 0),
        Quat.sIdentity(),
        EMotionType.Dynamic);
    BodyCreationSettings staticBox = BodyCreationSettings(
        new BoxShape(Vec3(1, 1, 1)),
        Vec3(0.5f, 0, 0),
        Quat.sIdentity(),
        EMotionType.Static);

    immutable dynamicBody = bodyManager.CreateBody(dynamicBox);
    immutable staticBody = bodyManager.CreateBody(staticBox);
    assert(bodyManager.ActivateBody(dynamicBody));

    BodyID[2] added = [dynamicBody, staticBody];
    broadPhase.AddBodiesFinalize(added[]);

    Array!BodyPair pairs;
    BodyID[] activeBodies = [dynamicBody];
    broadPhase.FindCollidingPairs(activeBodies, 0.0f, null, null, pairs);
    assert(pairs.size == 1);
    assert(pairs[0] == BodyPair(dynamicBody, staticBody));

    BodyID[1] removed = [staticBody];
    broadPhase.RemoveBodies(removed[]);
    broadPhase.FindCollidingPairs(activeBodies, 0.0f, null, null, pairs);
    assert(pairs.size == 0);
}