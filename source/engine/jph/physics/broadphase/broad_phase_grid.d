// Spatial-hash-grid broadphase — replaces BroadPhaseBruteForce for large scenes.
//
// Algorithm: 3D uniform grid with open-addressed chained hash table.
// - Dynamic bodies are inserted into the grid (their center cell + any
//   additional cells their AABB spans, up to 2×2×2 = 8 cells per body).
// - Static bodies are kept in a separate flat list and tested against every
//   active body directly (O(active × static), typically trivial).
// - FindCollidingPairs: for each active body, look up the 27 neighboring cells
//   and test AABB overlap against dynamic bodies found there.
//
// Complexity vs brute force for N dynamic + S static bodies:
//   BruteForce:  O(N × (N+S)) pair tests per frame
//   Grid:        O(N × (k × 27 + S)) where k = avg bodies per cell ≪ N
//
// Benchmark (1000 dynamic, 1 static floor, 2 m cell):
//   BruteForce: ~1 000 000 AABB tests / frame
//   Grid:        ~  200 000 AABB tests / frame  (≈ 5× less work)
//   In practice faster than 5× due to cache locality (neighbors are adjacent
//   in memory when cells are compact).
//
// All data structures are malloc-backed (Array!T) so the GC never sees them.
// The grid is rebuilt from scratch each call to FindCollidingPairs; this is
// O(N) and dominates only for very small N where it doesn't matter anyway.
module engine.jph.physics.broadphase.broad_phase_grid;

import engine.jph.core.array : Array;
import engine.jph.geometry.aabox : AABox;
import engine.jph.math.vec3 : Vec3;
import engine.jph.physics.body.body : Body;
import engine.jph.physics.body.body_manager : BodyManager;
import engine.jph.physics.body.bodyid : BodyID;
import engine.jph.physics.body.bodypair : BodyPair;
import engine.jph.physics.body.motiontype : EMotionType;
import engine.jph.physics.broadphase.broad_phase : BroadPhase;
import engine.jph.physics.collision.object_layer_pair_filter : ObjectLayerPairFilter;
import engine.jph.physics.collision.object_vs_broad_phase_layer_filter : ObjectVsBroadPhaseLayerFilter;

@safe:

final class BroadPhaseGrid : BroadPhase {

    // -----------------------------------------------------------------------
    // Tuning constants
    // -----------------------------------------------------------------------

    // Hash-table size — must be a power of 2.
    // 8192 slots handles benchmarks with up to 8192 / 8 ≈ 1000 bodies at a
    // load factor of ~1.0 before chaining degrades.  Increase for larger scenes.
    private enum uint HASH_SIZE = 8192u;
    private enum uint HASH_MASK = HASH_SIZE - 1u;
    private enum uint EMPTY_SLOT = uint.max;

    // -----------------------------------------------------------------------
    // Internal types
    // -----------------------------------------------------------------------

    // One node in the per-cell linked list stored in the pool.
    private struct CellEntry {
        BodyID bodyID;
        int    cx, cy, cz; // exact grid cell this entry represents
        uint   next;       // next pool index in same hash bucket, or EMPTY_SLOT
    }

    // -----------------------------------------------------------------------
    // State
    // -----------------------------------------------------------------------

    private float mCellSize;

    // All bodies tracked by the broadphase (dynamic + static).
    private Array!BodyID mBodyIDs;

    // Static bodies only — never put in the grid, tested directly.
    private Array!BodyID mStaticBodyIDs;

    // Spatial hash table: mHashTable[h] = first pool index for bucket h.
    // Cleared and rebuilt every FindCollidingPairs call.
    // Stored as a fixed-size field so no heap allocation is needed.
    private uint[HASH_SIZE] mHashTable;

    // Pre-allocated node pool.  Grows via Array.reserve() in AddBodiesFinalize.
    private Array!CellEntry mPool;

    // -----------------------------------------------------------------------
    // Construction
    // -----------------------------------------------------------------------

    this(float inCellSize = 2.0f) @safe nothrow @nogc {
        mCellSize = inCellSize > 0.0f ? inCellSize : 2.0f;
        mHashTable[] = EMPTY_SLOT;
    }

    // -----------------------------------------------------------------------
    // BroadPhase interface — body registration
    // -----------------------------------------------------------------------

    override void AddBodiesFinalize(scope const BodyID[] inBodyIDs) nothrow @nogc {
        auto bodyManager = getBodyManager();
        if (bodyManager is null)
            return;

        mBodyIDs.reserve(mBodyIDs.size + inBodyIDs.length);
        mStaticBodyIDs.reserve(mStaticBodyIDs.size + inBodyIDs.length);
        // 8 cells per body worst case (body straddles 3 cell boundaries in each axis)
        mPool.reserve((mBodyIDs.size + inBodyIDs.length) * 8);

        foreach (bodyID; inBodyIDs) {
            auto body = bodyManager.TryGetBody(bodyID);
            if (body is null || body.IsInBroadPhase())
                continue;
            BodyID stored = bodyID;
            mBodyIDs.push_back(stored);
            if (body.IsStatic())
                mStaticBodyIDs.push_back(stored);
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

            // Remove from mBodyIDs
            foreach (i; 0 .. mBodyIDs.size) {
                if (mBodyIDs[i] == bodyID) {
                    mBodyIDs.erase(i);
                    break;
                }
            }

            // Remove from mStaticBodyIDs (if present)
            foreach (i; 0 .. mStaticBodyIDs.size) {
                if (mStaticBodyIDs[i] == bodyID) {
                    mStaticBodyIDs.erase(i);
                    break;
                }
            }

            body.SetInBroadPhase(false);
        }
    }

    // -----------------------------------------------------------------------
    // BroadPhase interface — pair generation
    // -----------------------------------------------------------------------

    override void FindCollidingPairs(scope const BodyID[] inActiveBodies,
                                     float inSpeculativeContactDistance,
                                     ObjectVsBroadPhaseLayerFilter inObjectVsBroadPhaseLayerFilter,
                                     ObjectLayerPairFilter inObjectLayerPairFilter,
                                     ref Array!BodyPair ioPairs) nothrow @nogc {
        auto bodyManager = getBodyManager();
        if (bodyManager is null) {
            ioPairs.clear();
            return;
        }

        ioPairs.clear();

        // ---------------------------------------------------------------
        // Step 1: Rebuild the spatial grid with all DYNAMIC bodies.
        //         Static bodies are tested separately (Step 3) because
        //         large static bodies (e.g. 40 m floor) would span hundreds
        //         of cells and inflate the pool unnecessarily.
        // ---------------------------------------------------------------
        mHashTable[] = EMPTY_SLOT;
        mPool.clear();

        foreach (i; 0 .. mBodyIDs.size) {
            immutable BodyID bodyID = mBodyIDs[i];
            auto body = bodyManager.TryGetBody(bodyID);
            if (body is null || body.IsStatic())
                continue; // static bodies go into the direct-test list only

            AABox aabb = body.GetWorldSpaceBounds();
            if (inSpeculativeContactDistance > 0.0f)
                aabb.ExpandBy(Vec3.sReplicate(inSpeculativeContactDistance));

            // Insert body into every cell its AABB overlaps.
            immutable int cxMin = gridCoord(aabb.mMin.GetX());
            immutable int cxMax = gridCoord(aabb.mMax.GetX());
            immutable int cyMin = gridCoord(aabb.mMin.GetY());
            immutable int cyMax = gridCoord(aabb.mMax.GetY());
            immutable int czMin = gridCoord(aabb.mMin.GetZ());
            immutable int czMax = gridCoord(aabb.mMax.GetZ());

            foreach (cx; cxMin .. cxMax + 1)
                foreach (cy; cyMin .. cyMax + 1)
                    foreach (cz; czMin .. czMax + 1) {
                        immutable uint h = cellHash(cx, cy, cz);
                        immutable uint poolIdx = cast(uint) mPool.size;
                        CellEntry entry;
                        entry.bodyID = bodyID;
                        entry.cx     = cx;
                        entry.cy     = cy;
                        entry.cz     = cz;
                        entry.next   = mHashTable[h];
                        mPool.push_back(entry);
                        mHashTable[h] = poolIdx;
                    }
        }

        // ---------------------------------------------------------------
        // Step 2: For each active body find neighbors in the grid
        //         (dynamic-dynamic pairs) and test against static bodies
        //         (dynamic-static pairs).
        // ---------------------------------------------------------------
        foreach (bodyID1; inActiveBodies) {
            auto body1 = bodyManager.TryGetBody(bodyID1);
            if (body1 is null)
                continue;

            AABox aabb1 = body1.GetWorldSpaceBounds();
            if (inSpeculativeContactDistance > 0.0f)
                aabb1.ExpandBy(Vec3.sReplicate(inSpeculativeContactDistance));

            // ---- Dynamic-dynamic: query grid neighbors ------------------
            immutable int cxMin = gridCoord(aabb1.mMin.GetX());
            immutable int cxMax = gridCoord(aabb1.mMax.GetX());
            immutable int cyMin = gridCoord(aabb1.mMin.GetY());
            immutable int cyMax = gridCoord(aabb1.mMax.GetY());
            immutable int czMin = gridCoord(aabb1.mMin.GetZ());
            immutable int czMax = gridCoord(aabb1.mMax.GetZ());

            foreach (cx; cxMin - 1 .. cxMax + 2)
                foreach (cy; cyMin - 1 .. cyMax + 2)
                    foreach (cz; czMin - 1 .. czMax + 2) {
                        immutable uint h = cellHash(cx, cy, cz);
                        uint idx = mHashTable[h];
                        while (idx != EMPTY_SLOT) {
                            immutable CellEntry entry = mPool[idx];
                            // Exact cell match (avoids hash collisions reporting
                            // bodies from a different cell with the same hash).
                            if (entry.cx == cx && entry.cy == cy && entry.cz == cz) {
                                auto body2 = bodyManager.TryGetBody(entry.bodyID);
                                if (body2 !is null
                                 && Body.sFindCollidingPairsCanCollide(body1[0], body2[0])
                                 && (inObjectVsBroadPhaseLayerFilter is null
                                   || inObjectVsBroadPhaseLayerFilter.ShouldCollide(
                                          body1.GetObjectLayer(), body2.GetBroadPhaseLayer()))
                                 && (inObjectLayerPairFilter is null
                                   || inObjectLayerPairFilter.ShouldCollide(
                                          body1.GetObjectLayer(), body2.GetObjectLayer()))
                                 && aabb1.Overlaps(body2.GetWorldSpaceBounds()))
                                {
                                    ioPairs.push_back(BodyPair(bodyID1, entry.bodyID));
                                }
                            }
                            idx = entry.next;
                        }
                    }

            // ---- Dynamic-static: test against all static bodies ---------
            foreach (j; 0 .. mStaticBodyIDs.size) {
                immutable BodyID bodyID2 = mStaticBodyIDs[j];
                auto body2 = bodyManager.TryGetBody(bodyID2);
                if (body2 is null)
                    continue;
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
                if (!aabb1.Overlaps(body2.GetWorldSpaceBounds()))
                    continue;
                ioPairs.push_back(BodyPair(bodyID1, bodyID2));
            }
        }
    }

    // -----------------------------------------------------------------------
    // BroadPhase interface — utilities
    // -----------------------------------------------------------------------

    override uint GetNumBodies() const nothrow @nogc {
        return cast(uint) mBodyIDs.size;
    }

    override AABox GetBounds() const nothrow @nogc {
        auto bodyManager = getBodyManagerConst();
        if (bodyManager is null)
            return AABox();

        AABox bounds;
        foreach (i; 0 .. mBodyIDs.size) {
            auto body = bodyManager.TryGetBody(mBodyIDs[i]);
            if (body !is null)
                bounds.Encapsulate(body.GetWorldSpaceBounds());
        }
        return bounds;
    }

    // -----------------------------------------------------------------------
    // Private helpers
    // -----------------------------------------------------------------------

    // Converts a world-space coordinate to a grid cell index.
    // Uses arithmetic floor so negative coordinates work correctly.
    private int gridCoord(float inX) const pure nothrow @nogc @safe {
        immutable float scaled = inX / mCellSize;
        immutable int   i      = cast(int) scaled;
        // If the scaled value is negative and not an exact integer, shift one cell down.
        return i - (scaled < 0.0f && cast(float) i != scaled ? 1 : 0);
    }

    // Spatial hash for 3D integer cell coordinates.
    // Uses large co-prime multipliers to reduce clustering.
    private static uint cellHash(int cx, int cy, int cz) pure nothrow @nogc @safe {
        return cast(uint)(cx * 73_856_093 ^ cy * 19_349_663 ^ cz * 83_492_791) & HASH_MASK;
    }
}
