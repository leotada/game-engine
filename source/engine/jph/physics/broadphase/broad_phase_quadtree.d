// BroadPhase adapter that wraps a QuadTree and satisfies the BroadPhase
// interface used by PhysicsSystem.
//
// Dynamic and kinematic bodies go into the QuadTree (rebuilt each step).
// Static bodies are kept in a flat list and checked against active bodies
// via a direct AABB linear scan.  This avoids the pathological case where a
// large static body (e.g. a 40 m floor) contaminates every ancestor node of
// the QuadTree, turning every active-body query into O(N) instead of O(log N).
//
// Jolt's production solution maintains two separate trees (static + dynamic).
// This single-tree + flat-static design is the minimal correct approach that
// achieves the same asymptotic improvement.
module engine.jph.physics.broadphase.broad_phase_quadtree;

import engine.jph.core.array : Array;
import engine.jph.geometry.aabox : AABox;
import engine.jph.math.vec3 : Vec3;
import engine.jph.physics.body.body : Body;
import engine.jph.physics.body.body_manager : BodyManager;
import engine.jph.physics.body.bodyid : BodyID;
import engine.jph.physics.body.bodypair : BodyPair;
import engine.jph.physics.broadphase.broad_phase : BroadPhase;
import engine.jph.physics.broadphase.quad_tree : QuadTree;
import engine.jph.physics.collision.object_layer_pair_filter : ObjectLayerPairFilter;
import engine.jph.physics.collision.object_vs_broad_phase_layer_filter
    : ObjectVsBroadPhaseLayerFilter;

@safe:

final class BroadPhaseQuadTree : BroadPhase {

    // Dynamic + kinematic bodies → rebuilt into QuadTree each frame.
    private Array!BodyID mDynKinBodyIDs;
    // Static bodies → flat list; scanned linearly for active-vs-static pairs.
    // Kept out of the tree: large static AABBs would pollute ancestor nodes.
    private Array!BodyID mStaticBodyIDs;

    // Reused across steps; rebuilt on each FindCollidingPairs call.
    private QuadTree mTree;

    // -----------------------------------------------------------------------
    // BroadPhase interface - body registration
    // -----------------------------------------------------------------------

    override void AddBodiesFinalize(scope const BodyID[] inBodyIDs) nothrow @nogc {
        auto bodyManager = getBodyManager();
        if (bodyManager is null) return;

        foreach (bodyID; inBodyIDs) {
            auto body = bodyManager.TryGetBody(bodyID);
            if (body is null || body.IsInBroadPhase()) continue;
            BodyID stored = bodyID;
            if (body.IsStatic())
                mStaticBodyIDs.push_back(stored);
            else
                mDynKinBodyIDs.push_back(stored);
            body.SetInBroadPhase(true);
        }
    }

    override void RemoveBodies(scope const BodyID[] inBodyIDs) nothrow @nogc {
        auto bodyManager = getBodyManager();
        if (bodyManager is null) return;

        foreach (bodyID; inBodyIDs) {
            auto body = bodyManager.TryGetBody(bodyID);
            if (body is null || !body.IsInBroadPhase()) continue;

            // Remove from dynamic/kinematic list first; fall through to static.
            bool found = false;
            foreach (i; 0 .. mDynKinBodyIDs.size) {
                if (mDynKinBodyIDs[i] == bodyID) {
                    mDynKinBodyIDs.erase(i);
                    found = true;
                    break;
                }
            }
            if (!found) {
                foreach (i; 0 .. mStaticBodyIDs.size) {
                    if (mStaticBodyIDs[i] == bodyID) {
                        mStaticBodyIDs.erase(i);
                        break;
                    }
                }
            }
            body.SetInBroadPhase(false);
        }
    }

    // -----------------------------------------------------------------------
    // BroadPhase interface - pair generation
    // -----------------------------------------------------------------------

    override void FindCollidingPairs(
            scope const BodyID[] inActiveBodies,
            float inSpeculativeContactDistance,
            ObjectVsBroadPhaseLayerFilter inObjectVsBroadPhaseLayerFilter,
            ObjectLayerPairFilter inObjectLayerPairFilter,
            ref Array!BodyPair ioPairs) nothrow @nogc @trusted {

        ioPairs.clear();

        auto bodyManager = getBodyManager();
        if (bodyManager is null) return;

        // Pass 1: dynamic/kinematic vs dynamic/kinematic via QuadTree.
        mTree.Build(bodyManager, mDynKinBodyIDs[]);
        mTree.FindCollidingPairs(bodyManager,
                                 inActiveBodies,
                                 inSpeculativeContactDistance,
                                 inObjectVsBroadPhaseLayerFilter,
                                 inObjectLayerPairFilter,
                                 ioPairs);

        // Pass 2: active vs static — linear scan (O(active × statics)).
        // Static bodies are typically few; linear is fine even for 100s.
        if (mStaticBodyIDs.size == 0) return;

        foreach (bodyID1; inActiveBodies) {
            const(Body)* body1 = bodyManager.TryGetBody(bodyID1);
            if (body1 is null) continue;

            AABox bounds1 = body1.GetWorldSpaceBounds();
            if (inSpeculativeContactDistance > 0.0f)
                bounds1.ExpandBy(Vec3.sReplicate(inSpeculativeContactDistance));

            foreach (i; 0 .. mStaticBodyIDs.size) {
                const BodyID bodyID2 = mStaticBodyIDs[i];
                const(Body)* body2 = bodyManager.TryGetBody(bodyID2);
                if (body2 is null) continue;

                if (!Body.sFindCollidingPairsCanCollide(body1[0], body2[0]))
                    continue;

                if (inObjectVsBroadPhaseLayerFilter !is null
                 && !inObjectVsBroadPhaseLayerFilter.ShouldCollide(
                        body1.GetObjectLayer(), body2.GetBroadPhaseLayer()))
                    continue;

                if (inObjectLayerPairFilter !is null
                 && !inObjectLayerPairFilter.ShouldCollide(
                        body1.GetObjectLayer(), body2.GetObjectLayer()))
                    continue;

                AABox bounds2 = body2.GetWorldSpaceBounds();
                if (!bounds1.Overlaps(bounds2)) continue;

                ioPairs.push_back(BodyPair(bodyID1, bodyID2));
            }
        }
    }

    // -----------------------------------------------------------------------
    // BroadPhase interface - utilities
    // -----------------------------------------------------------------------

    override uint GetNumBodies() const nothrow @nogc {
        return cast(uint)(mDynKinBodyIDs.size + mStaticBodyIDs.size);
    }

    override AABox GetBounds() const nothrow @nogc @trusted {
        return mTree.GetBounds();
    }
}

// ---------------------------------------------------------------------------
// Integration tests
// ---------------------------------------------------------------------------

unittest {
    // Tests use PhysicsSystem which owns a BroadPhase.  We exercise the
    // QuadTree indirectly by building a PhysicsSystem with BroadPhaseQuadTree.
    import engine.jph.physics.body.body_creation_settings : BodyCreationSettings;
    import engine.jph.physics.body.motiontype : EMotionType;
    import engine.jph.physics.eactivation : EActivation;
    import engine.jph.physics.shape.box_shape : BoxShape;
    import engine.jph.math.quat : Quat;
    import engine.jph.math.vec3 : Vec3;
    import engine.jph.physics.physics_system : PhysicsSystem;

    // Helper: initialise a PhysicsSystem with BroadPhaseQuadTree.
    static PhysicsSystem makeSystem(uint maxBodies = 16) {
        PhysicsSystem sys;
        sys.InitWithBroadPhase(maxBodies, new BroadPhaseQuadTree());
        return sys;
    }

    auto shape = new BoxShape(Vec3(0.5f, 0.5f, 0.5f));

    // ── Test 1: empty scene yields 0 pairs ──────────────────────────────
    {
        auto sys = makeSystem();
        sys.Step(1.0f / 60.0f);
        assert(sys.mStats.mBroadphasePairs == 0, "empty scene must have 0 pairs");
    }

    // ── Test 2: single body yields 0 pairs ─────────────────────────────
    {
        auto sys = makeSystem();
        auto bi = &sys.GetBodyInterface();
        auto s1 = BodyCreationSettings(shape, Vec3(0, 5, 0), Quat.sIdentity(), EMotionType.Dynamic);
        bi.CreateAndAddBody(s1, EActivation.Activate);
        sys.Step(1.0f / 60.0f);
        assert(sys.mStats.mBroadphasePairs == 0, "single body must have 0 pairs");
    }

    // ── Test 3: two non-overlapping bodies yield 0 pairs ───────────────
    {
        auto sys = makeSystem();
        auto bi = &sys.GetBodyInterface();
        auto s1 = BodyCreationSettings(shape, Vec3(-5, 5, 0), Quat.sIdentity(), EMotionType.Dynamic);
        auto s2 = BodyCreationSettings(shape, Vec3( 5, 5, 0), Quat.sIdentity(), EMotionType.Dynamic);
        bi.CreateAndAddBody(s1, EActivation.Activate);
        bi.CreateAndAddBody(s2, EActivation.Activate);
        sys.Step(1.0f / 60.0f);
        assert(sys.mStats.mBroadphasePairs == 0,
               "non-overlapping bodies must yield 0 pairs");
    }

    // ── Test 4: two overlapping dynamic bodies yield 1 pair ─────────────
    {
        auto sys = makeSystem();
        auto bi = &sys.GetBodyInterface();
        auto s1 = BodyCreationSettings(shape, Vec3(-0.3f, 5, 0), Quat.sIdentity(), EMotionType.Dynamic);
        auto s2 = BodyCreationSettings(shape, Vec3( 0.3f, 5, 0), Quat.sIdentity(), EMotionType.Dynamic);
        bi.CreateAndAddBody(s1, EActivation.Activate);
        bi.CreateAndAddBody(s2, EActivation.Activate);
        sys.Step(1.0f / 60.0f);
        assert(sys.mStats.mBroadphasePairs == 1,
               "two overlapping dynamics must yield exactly 1 pair");
    }

    // ── Test 5: one dynamic + one static at same position yield 1 pair ──
    {
        auto sys = makeSystem();
        auto bi = &sys.GetBodyInterface();
        auto s1 = BodyCreationSettings(shape, Vec3(0, 0, 0), Quat.sIdentity(), EMotionType.Dynamic);
        auto s2 = BodyCreationSettings(shape, Vec3(0, 0, 0), Quat.sIdentity(), EMotionType.Static);
        bi.CreateAndAddBody(s1, EActivation.Activate);
        bi.CreateAndAddBody(s2, EActivation.DontActivate);
        sys.Step(1.0f / 60.0f);
        assert(sys.mStats.mBroadphasePairs == 1,
               "dynamic+static at same position must yield 1 pair");
    }
}

