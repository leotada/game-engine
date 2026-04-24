// Loose-AABB quad-tree broadphase data structure.
//
// Scalar, single-threaded port of Jolt's QuadTree (ref/JoltPhysics/Jolt/
// Physics/Collision/BroadPhase/QuadTree.{h,cpp}).
//
// Key differences from Jolt's implementation (intentional simplifications):
//   • No SIMD: 4 scalar overlaps() per node visit instead of Vec4 batch.
//   • No atomic fields: single-threaded only; no lock-free tree queries.
//   • No dynamic insert/remove: tree is rebuilt from scratch each step.
//     Incremental "mark changed path" rebuild is a future optimisation.
//   • Single-layer: BroadPhaseQuadTree wraps one QuadTree and forwards all
//     bodies to it regardless of BroadPhaseLayer.
//   • Leaf size = 1: each leaf slot holds one BodyID (mirrors Jolt).
//
// Build algorithm: Morton-code sort then bottom-up grouping of 4 bodies at a
// time until a single root node remains.  O(N log N), all temp work in
// malloc-backed buffers (no GC allocations).
//
// FindCollidingPairs: for each active body, descend from root, test 4 child
// AABBs, recurse into hits, emit leaf pairs.  Pair de-duplication uses
// Body.sFindCollidingPairsCanCollide (activeIndex1 < activeIndex2).
//
// IMPORTANT - Do NOT use core.simd.float4 or union{float4; float[4]} in
// this file.  DMD hangs at 99% CPU compiling such types in large compilation
// units.  All bounds are stored as plain float[4].
module engine.jph.physics.broadphase.quad_tree;

import engine.jph.core.array      : Array;
import engine.jph.core.memory     : jphAlloc, jphFree;
import engine.jph.geometry.aabox  : AABox;
import engine.jph.math.vec3       : Vec3;
import engine.jph.physics.body.body         : Body;
import engine.jph.physics.body.body_manager : BodyManager;
import engine.jph.physics.body.bodyid       : BodyID;
import engine.jph.physics.body.bodypair     : BodyPair;
import engine.jph.physics.collision.object_layer_pair_filter
    : ObjectLayerPairFilter;
import engine.jph.physics.collision.object_vs_broad_phase_layer_filter
    : ObjectVsBroadPhaseLayerFilter;

@safe:

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// Bit set in a slot value to distinguish an internal node index from a body
/// slot.  Matches BodyID.cBroadPhaseBit so valid BodyIDs never set this bit.
private enum uint cIsNodeBit   = 0x8000_0000u;
/// Sentinel for an empty / unused child slot.
private enum uint cInvalidSlot = 0xFFFF_FFFFu;
/// Number of children per internal node.
private enum int  cChildCount  = 4;

// ---------------------------------------------------------------------------
// Internal node structure
// ---------------------------------------------------------------------------

/// One internal node of the quad-tree.
///
/// Each child slot contains one of:
///   cInvalidSlot                       - unused padding slot
///   value | cIsNodeBit                 - index of a child Node
///   BodyID.GetIndexAndSequenceNumber() - leaf body (cIsNodeBit clear)
///
/// Bounds stored in SoA float[4] arrays (one per axis/min-max) matching
/// Jolt's layout for cache efficiency.  No SIMD union - see module doc.
private struct Node {
    float[cChildCount] mBoundsMinX = float.max;
    float[cChildCount] mBoundsMinY = float.max;
    float[cChildCount] mBoundsMinZ = float.max;
    float[cChildCount] mBoundsMaxX = -float.max;
    float[cChildCount] mBoundsMaxY = -float.max;
    float[cChildCount] mBoundsMaxZ = -float.max;
    uint[cChildCount]  mChildren   = cInvalidSlot;

    void setChildBounds(int i, ref const AABox b) pure nothrow @nogc {
        mBoundsMinX[i] = b.mMin.GetX();
        mBoundsMinY[i] = b.mMin.GetY();
        mBoundsMinZ[i] = b.mMin.GetZ();
        mBoundsMaxX[i] = b.mMax.GetX();
        mBoundsMaxY[i] = b.mMax.GetY();
        mBoundsMaxZ[i] = b.mMax.GetZ();
    }

    AABox getChildBounds(int i) const pure nothrow @nogc {
        return AABox(Vec3(mBoundsMinX[i], mBoundsMinY[i], mBoundsMinZ[i]),
                     Vec3(mBoundsMaxX[i], mBoundsMaxY[i], mBoundsMaxZ[i]));
    }

    /// Scalar AABB overlap test for child slot `i` against query box `q`.
    bool overlaps(int i, ref const AABox q) const pure nothrow @nogc {
        return mBoundsMinX[i] <= q.mMax.GetX()
            && mBoundsMaxX[i] >= q.mMin.GetX()
            && mBoundsMinY[i] <= q.mMax.GetY()
            && mBoundsMaxY[i] >= q.mMin.GetY()
            && mBoundsMinZ[i] <= q.mMax.GetZ()
            && mBoundsMaxZ[i] >= q.mMin.GetZ();
    }
}

// ---------------------------------------------------------------------------
// Morton-code helpers
// ---------------------------------------------------------------------------

/// Expand a 10-bit integer to 30 bits by inserting two 0-bits after each bit.
private uint mortonExpand(uint x) pure nothrow @nogc {
    x &= 0x3FFu;
    x = (x | x << 16) & 0x030000FFu;
    x = (x | x <<  8) & 0x0300F00Fu;
    x = (x | x <<  4) & 0x030C30C3u;
    x = (x | x <<  2) & 0x09249249u;
    return x;
}

/// 30-bit Morton code interleaving three 10-bit components (x, y, z).
private uint mortonCode3(uint x, uint y, uint z) pure nothrow @nogc {
    return mortonExpand(x) | (mortonExpand(y) << 1) | (mortonExpand(z) << 2);
}

// ---------------------------------------------------------------------------
// Scratch entry for the build phase
// ---------------------------------------------------------------------------

private struct BuildEntry {
    BodyID bodyID;
    AABox  bounds;
    uint   morton;
}

// ---------------------------------------------------------------------------
// QuadTree
// ---------------------------------------------------------------------------

/// Loose-AABB quad-tree for broadphase candidate-pair generation.
struct QuadTree {
@safe:
    Array!Node mNodes;
    uint       mRoot = cInvalidSlot;

    // -----------------------------------------------------------------------
    // Build
    // -----------------------------------------------------------------------

    /// Rebuild the entire tree from `inBodyIDs`.
    /// Both dynamic and static bodies should be passed in so that
    /// dynamic/static pairs are found during FindCollidingPairs.
    /// O(N log N) overall; all temporaries are malloc-backed (@nogc).
    void Build(const(BodyManager)* bodyManager,
               scope const BodyID[] inBodyIDs) nothrow @nogc @trusted {
        mRoot = cInvalidSlot;
        mNodes.clear();

        if (inBodyIDs.length == 0)
            return;

        // Phase 1: collect valid bodies
        auto scratch = cast(BuildEntry*) jphAlloc(inBodyIDs.length * BuildEntry.sizeof);
        if (scratch is null) return;

        size_t validCount = 0;
        AABox  sceneBounds;
        foreach (bodyID; inBodyIDs) {
            const(Body)* body = bodyManager.TryGetBody(bodyID);
            if (body is null || !body.IsInBroadPhase()) continue;
            AABox b = body.GetWorldSpaceBounds();
            if (!b.IsValid()) continue;
            scratch[validCount].bodyID = bodyID;
            scratch[validCount].bounds = b;
            scratch[validCount].morton = 0;
            sceneBounds.Encapsulate(b);
            ++validCount;
        }
        if (validCount == 0) { jphFree(scratch); return; }

        // Phase 2: Morton codes
        Vec3  szv = sceneBounds.GetSize();
        float sx  = szv.GetX() > 0.0f ? szv.GetX() : 1.0f;
        float sy  = szv.GetY() > 0.0f ? szv.GetY() : 1.0f;
        float sz  = szv.GetZ() > 0.0f ? szv.GetZ() : 1.0f;
        foreach (i; 0 .. validCount) {
            Vec3 c  = scratch[i].bounds.GetCenter();
            uint mx = cast(uint)((c.GetX() - sceneBounds.mMin.GetX()) / sx * 1023.0f);
            uint my = cast(uint)((c.GetY() - sceneBounds.mMin.GetY()) / sy * 1023.0f);
            uint mz = cast(uint)((c.GetZ() - sceneBounds.mMin.GetZ()) / sz * 1023.0f);
            scratch[i].morton = mortonCode3(mx, my, mz);
        }

        // Phase 3: sort by Morton code
        sortBuildEntries(scratch, validCount);

        // Phase 4: single-body fast path
        if (validCount == 1) {
            mNodes.resize(1);
            mNodes[0].mChildren[0] = scratch[0].bodyID.GetIndexAndSequenceNumber();
            mNodes[0].setChildBounds(0, scratch[0].bounds);
            mRoot = 0;
            jphFree(scratch);
            return;
        }

        // Phase 5: init first-level slot arrays while scratch is still live
        auto nodeLevel   = cast(uint*)  jphAlloc(validCount * uint.sizeof);
        auto boundsLevel = cast(AABox*) jphAlloc(validCount * AABox.sizeof);
        if (nodeLevel is null || boundsLevel is null) {
            jphFree(boundsLevel);
            jphFree(nodeLevel);
            jphFree(scratch);
            return;
        }
        foreach (i; 0 .. validCount) {
            nodeLevel[i]   = scratch[i].bodyID.GetIndexAndSequenceNumber();
            boundsLevel[i] = scratch[i].bounds;
        }
        jphFree(scratch);

        // Phase 6: bottom-up tree construction
        buildTree(nodeLevel, boundsLevel, validCount);
        // nodeLevel and boundsLevel are freed inside buildTree.
    }

    // -----------------------------------------------------------------------
    // FindCollidingPairs
    // -----------------------------------------------------------------------

    /// For each active body, descend the tree and emit candidate pairs.
    void FindCollidingPairs(
            const(BodyManager)* bodyManager,
            scope const BodyID[] inActiveBodies,
            float inSpeculativeContactDistance,
            ObjectVsBroadPhaseLayerFilter inObjectVsBroadPhaseLayerFilter,
            ObjectLayerPairFilter inObjectLayerPairFilter,
            ref Array!BodyPair ioPairs) const nothrow @nogc @trusted {

        if (mRoot == cInvalidSlot || mNodes.size == 0)
            return;

        foreach (bodyID1; inActiveBodies) {
            const(Body)* body1 = bodyManager.TryGetBody(bodyID1);
            if (body1 is null) continue;

            AABox query = body1.GetWorldSpaceBounds();
            if (inSpeculativeContactDistance > 0.0f)
                query.ExpandBy(Vec3.sReplicate(inSpeculativeContactDistance));

            walkNode(bodyManager, body1, query,
                     inObjectVsBroadPhaseLayerFilter,
                     inObjectLayerPairFilter,
                     mRoot, ioPairs);
        }
    }

    // -----------------------------------------------------------------------
    // GetBounds
    // -----------------------------------------------------------------------

    /// Tight AABB of all bodies in the tree (union of root node children).
    AABox GetBounds() const nothrow @nogc @trusted {
        if (mRoot == cInvalidSlot || mNodes.size == 0)
            return AABox();
        AABox bounds;
        const(Node)* root = &mNodes[mRoot];
        foreach (i; 0 .. cChildCount) {
            if (root.mChildren[i] == cInvalidSlot) continue;
            bounds.Encapsulate(root.getChildBounds(i));
        }
        return bounds;
    }

    // -----------------------------------------------------------------------
    // Private - bottom-up tree build
    // -----------------------------------------------------------------------

    /// Groups `n` items into nodes 4 at a time until one root remains.
    /// Takes ownership of nodeLevel and boundsLevel - always frees them.
    private void buildTree(uint* nodeLevel, AABox* boundsLevel,
                           size_t n) nothrow @nogc @trusted {
        size_t currentCount = n;
        while (currentCount > 1) {
            immutable size_t newCount = (currentCount + cChildCount - 1) / cChildCount;
            immutable size_t nodeBase = mNodes.size;
            mNodes.resize(nodeBase + newCount);

            auto newLevel  = cast(uint*)  jphAlloc(newCount * uint.sizeof);
            auto newBounds = cast(AABox*) jphAlloc(newCount * AABox.sizeof);
            if (newLevel is null || newBounds is null) {
                jphFree(newBounds);
                jphFree(newLevel);
                jphFree(boundsLevel);
                jphFree(nodeLevel);
                mRoot = cInvalidSlot;
                mNodes.clear();
                return;
            }

            foreach (g; 0 .. newCount) {
                immutable size_t first = g * cChildCount;
                immutable size_t last  = first + cChildCount < currentCount
                                       ? first + cChildCount : currentCount;
                immutable uint nodeIdx = cast(uint)(nodeBase + g);
                Node* node = &mNodes[nodeIdx];
                AABox parentBounds;
                foreach (slot; 0 .. cChildCount) {
                    immutable size_t src = first + slot;
                    if (src < last) {
                        node.mChildren[slot] = nodeLevel[src];
                        node.setChildBounds(slot, boundsLevel[src]);
                        parentBounds.Encapsulate(boundsLevel[src]);
                    }
                    // else: mChildren[slot] stays cInvalidSlot (field default)
                }
                newLevel[g]  = nodeIdx | cIsNodeBit;
                newBounds[g] = parentBounds;
            }

            jphFree(boundsLevel);
            jphFree(nodeLevel);
            nodeLevel    = newLevel;
            boundsLevel  = newBounds;
            currentCount = newCount;
        }

        // currentCount == 1 - the remaining entry must be an internal node
        assert((nodeLevel[0] & cIsNodeBit) != 0,
               "buildTree root must be a node");
        mRoot = nodeLevel[0] & ~cIsNodeBit;

        jphFree(boundsLevel);
        jphFree(nodeLevel);
    }

    // -----------------------------------------------------------------------
    // Private - tree walk
    // -----------------------------------------------------------------------

    private void walkNode(
            const(BodyManager)* bodyManager,
            const(Body)*        body1,
            ref const AABox     query,
            ObjectVsBroadPhaseLayerFilter inObjectVsBroadPhaseLayerFilter,
            ObjectLayerPairFilter         inObjectLayerPairFilter,
            uint                          nodeIdx,
            ref Array!BodyPair            ioPairs) const nothrow @nogc @trusted {

        const(Node)* node = &mNodes[nodeIdx];
        foreach (i; 0 .. cChildCount) {
            immutable uint slot = node.mChildren[i];
            if (slot == cInvalidSlot) continue;
            if (!node.overlaps(i, query)) continue;

            if ((slot & cIsNodeBit) != 0) {
                walkNode(bodyManager, body1, query,
                         inObjectVsBroadPhaseLayerFilter,
                         inObjectLayerPairFilter,
                         slot & ~cIsNodeBit, ioPairs);
            } else {
                // Leaf body.  Body IDs never set the broad-phase bit so
                // BodyID(slot) is always valid in this @trusted context.
                immutable BodyID bodyID2 = BodyID(slot);
                if (bodyID2 == body1.GetID()) continue;

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

                AABox b2 = body2.GetWorldSpaceBounds();
                if (!query.Overlaps(b2)) continue;

                ioPairs.push_back(BodyPair(body1.GetID(), bodyID2));
            }
        }
    }

    // -----------------------------------------------------------------------
    // Private - sort
    // -----------------------------------------------------------------------

    /// In-place sort of BuildEntry[] by Morton code.
    /// Insertion sort for N <= 64, shell sort (Knuth gap) for larger arrays.
    package(engine.jph.physics.broadphase)
    static void sortBuildEntries(BuildEntry* arr, size_t n) nothrow @nogc @trusted {
        if (n <= 1) return;
        if (n <= 64) {
            foreach (i; 1 .. n) {
                BuildEntry key = arr[i];
                long j = cast(long) i - 1;
                while (j >= 0 && arr[j].morton > key.morton) {
                    arr[j + 1] = arr[j];
                    --j;
                }
                arr[j + 1] = key;
            }
        } else {
            size_t gap = 1;
            while (gap < n / 9) gap = gap * 3 + 1;
            while (gap > 0) {
                foreach (i; gap .. n) {
                    BuildEntry key = arr[i];
                    size_t j = i;
                    while (j >= gap && arr[j - gap].morton > key.morton) {
                        arr[j] = arr[j - gap];
                        j -= gap;
                    }
                    arr[j] = key;
                }
                gap = (gap - 1) / 3;
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Unit tests for Morton helpers and sort
// ---------------------------------------------------------------------------

unittest {
    // mortonExpand: 10-bit input, 30-bit output with 2 zeros between bits.
    assert(mortonExpand(0) == 0);
    assert(mortonExpand(1) == 1);
    assert(mortonExpand(2) == 8);   // bit 1 -> position 3
    assert(mortonExpand(3) == 9);   // bits 0,1 -> positions 0,3

    // mortonCode3: x uses bits 0,3,6,...; y bits 1,4,7,...; z bits 2,5,8,...
    assert(mortonCode3(0, 0, 0) == 0);
    assert(mortonCode3(1, 0, 0) == 1); // x bit 0 -> morton bit 0
    assert(mortonCode3(0, 1, 0) == 2); // y bit 0 -> morton bit 1
    assert(mortonCode3(0, 0, 1) == 4); // z bit 0 -> morton bit 2
    assert(mortonCode3(1, 1, 1) == 7);
}

unittest {
    // sortBuildEntries: verify ascending order after sort.
    enum n = 5;
    auto arrPtr = (() @trusted => cast(BuildEntry*) jphAlloc(n * BuildEntry.sizeof))();
    auto arr    = (() @trusted => arrPtr[0 .. n])();
    arr[0].morton = 9;
    arr[1].morton = 3;
    arr[2].morton = 7;
    arr[3].morton = 1;
    arr[4].morton = 5;

    QuadTree.sortBuildEntries(arrPtr, n);

    assert(arr[0].morton == 1);
    assert(arr[1].morton == 3);
    assert(arr[2].morton == 5);
    assert(arr[3].morton == 7);
    assert(arr[4].morton == 9);

    (() @trusted => jphFree(arrPtr))();
}
