// Jolt — Physics/Collision/BroadPhase/BroadPhase.h port (simple runtime seam).
//
// The simple rigid-body MVP starts with a brute-force broadphase, but keeps a
// dedicated abstraction so PhysicsSystem and BodyInterface do not depend on a
// particular spatial structure.
module engine.jph.physics.broadphase.broad_phase;

import engine.jph.core.array : Array;
import engine.jph.geometry.aabox : AABox;
import engine.jph.physics.body.body_manager : BodyManager;
import engine.jph.physics.body.bodyid : BodyID;
import engine.jph.physics.body.bodypair : BodyPair;
import engine.jph.physics.collision.broad_phase_layer : BroadPhaseLayerInterface;
import engine.jph.physics.collision.object_layer_pair_filter : ObjectLayerPairFilter;
import engine.jph.physics.collision.object_vs_broad_phase_layer_filter : ObjectVsBroadPhaseLayerFilter;

@safe:

abstract class BroadPhase {
    private size_t mBodyManagerAddress = 0;
    protected BroadPhaseLayerInterface mBroadPhaseLayerInterface;

    void Init(scope BodyManager* inBodyManager,
              BroadPhaseLayerInterface inLayerInterface = null) @trusted nothrow @nogc {
        mBodyManagerAddress = cast(size_t) inBodyManager;
        mBroadPhaseLayerInterface = inLayerInterface;
    }

    void Optimize() nothrow @nogc {
    }

    void NotifyBodiesAABBChanged(scope const BodyID[] inBodyIDs) nothrow @nogc {
        cast(void) inBodyIDs;
    }

    void NotifyBodiesLayerChanged(scope const BodyID[] inBodyIDs) nothrow @nogc {
        cast(void) inBodyIDs;
    }

    abstract void AddBodiesFinalize(scope const BodyID[] inBodyIDs) nothrow @nogc;
    abstract void RemoveBodies(scope const BodyID[] inBodyIDs) nothrow @nogc;

    abstract void FindCollidingPairs(scope const BodyID[] inActiveBodies,
                                     float inSpeculativeContactDistance,
                                     ObjectVsBroadPhaseLayerFilter inObjectVsBroadPhaseLayerFilter,
                                     ObjectLayerPairFilter inObjectLayerPairFilter,
                                     ref Array!BodyPair ioPairs) nothrow @nogc;

    abstract uint GetNumBodies() const nothrow @nogc;
    abstract AABox GetBounds() const nothrow @nogc;

    protected const(BodyManager)* getBodyManagerConst() const nothrow @nogc @trusted {
        return mBodyManagerAddress == 0 ? null : cast(const(BodyManager)*) mBodyManagerAddress;
    }

    protected BodyManager* getBodyManager() nothrow @nogc @trusted {
        return mBodyManagerAddress == 0 ? null : cast(BodyManager*) mBodyManagerAddress;
    }
}