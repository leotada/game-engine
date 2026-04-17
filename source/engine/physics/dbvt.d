// Dynamic AABB tree (Dbvt) broadphase — Bullet's btDbvt style.
//
// Key perf techniques cribbed from Bullet:
//   * Nodes store min/max (not centre/extent) so AABB merge / overlap is a
//     handful of scalar min/max that LDC auto-vectorizes.
//   * Leaf AABBs are stored "fat" (margin 0.05 m, Bullet's DBVT_MARGIN) so
//     small motion doesn't require re-insertion.
//   * update() fast path: if the fat AABB still `contains` the new tight
//     AABB, do nothing. Otherwise rebuild the fat AABB from tight + margin
//     + signed-velocity expansion.
//   * findPairs walks two node-stacks (collideTT) rather than per-leaf
//     root-queries; for self-collision the same tree is descended with
//     `if(a==b)` short-circuits.
//   * Persistent arenas (node pool + traversal stack) — zero per-frame
//     allocation, zero GC in the hot path.
//
// The tree is bounded by `MaxNodes` and grows via `assert` if exceeded; for
// the benchmark (≤ 4096 bodies → ≤ 8192 nodes) this is plenty.
module engine.physics.dbvt;

import engine.math.vec;
import engine.physics.types;

@safe:

/// Bullet btDbvt::DBVT_MARGIN (2005a27 line 47) — AABB fattening radius.
enum float DBVT_MARGIN = 0.05f;
/// Bullet's velocity prediction multiplier for collideKDOP; we reuse it for
/// update(). Expands the fat AABB by `prediction * velocity` in the motion
/// direction so the tree survives several frames of steady motion.
enum float DBVT_VELOCITY_PREDICTION = 2.0f;

private enum int NULL_IDX = -1;

struct DbvtNode {
    Aabb aabb;
    int  parent = NULL_IDX;
    int  child0 = NULL_IDX;   // for leaves, == NULL_IDX
    int  child1 = NULL_IDX;
    uint leafBodyId = RigidBodyId.max;  // only valid for leaves
    bool isLeaf      = false;
    bool inUse       = false;
}

struct Dbvt(uint MaxNodes) {
@safe:
    DbvtNode[MaxNodes] nodes;
    int root       = NULL_IDX;
    int count      = 0;
    int freeHead   = NULL_IDX;

    // Persistent traversal stack for findPairs/raycast. Sized against
    // MaxNodes so a fully populated tree can't overflow the stack even in
    // pathological cases (e.g. hundreds of dynamic cubes piled into a
    // single region producing dense AABB overlap). A fixed 256-slot stack
    // was previously protected only by `assert`, which is disabled in
    // release builds \u2014 an overflow would silently corrupt adjacent struct
    // fields (root / count / freeHead) and then hang the whole frame.
    private enum uint TraversalStackSize = MaxNodes < 256 ? 256 : MaxNodes;
    private int[TraversalStackSize] pairStackA;
    private int[TraversalStackSize] pairStackB;
    private int[TraversalStackSize] singleStack;

    void clear()  {
        root = NULL_IDX;
        count = 0;
        freeHead = NULL_IDX;
        foreach (ref n; nodes) n.inUse = false;
    }

    uint nodeCount() const  { return cast(uint) count; }

    // -------- internal allocator (free list) -----------------------------

    private int allocNode()  {
        int idx;
        if (freeHead != NULL_IDX) {
            idx = freeHead;
            freeHead = nodes[idx].parent;  // reuse parent as free-list link
        } else {
            assert(count < cast(int) MaxNodes, "Dbvt capacity exhausted");
            idx = count++;
        }
        nodes[idx] = DbvtNode.init;
        nodes[idx].inUse = true;
        return idx;
    }

    private void freeNode(int idx)  {
        nodes[idx].inUse = false;
        nodes[idx].parent = freeHead;
        freeHead = idx;
    }

    private void refit(int idx)  {
        auto n = &nodes[idx];
        n.aabb = nodes[n.child0].aabb.merged(nodes[n.child1].aabb);
    }

    // -------- insertion (cost via surface area) --------------------------

    /// Insert a leaf holding `bodyId` with tight AABB `tight`. Returns the
    /// node index of the new leaf — keep it in the body's SoA so we can
    /// later `update(leafIdx, ...)` or `remove(leafIdx)`.
    int insertLeaf(uint bodyId, Aabb tight)  {
        immutable fat = tight.expanded(DBVT_MARGIN);
        immutable leafIdx = allocNode();
        auto leaf = &nodes[leafIdx];
        leaf.isLeaf = true;
        leaf.aabb = fat;
        leaf.leafBodyId = bodyId;

        if (root == NULL_IDX) {
            root = leafIdx;
            return leafIdx;
        }

        // Walk down picking child whose AABB grows least in surface area.
        int sibling = root;
        while (!nodes[sibling].isLeaf) {
            immutable mergedArea = nodes[sibling].aabb.merged(fat).surfaceArea();
            immutable branchCost = 2.0f * mergedArea;
            immutable inheritanceCost = 2.0f * (mergedArea - nodes[sibling].aabb.surfaceArea());

            immutable c0 = nodes[sibling].child0;
            immutable c1 = nodes[sibling].child1;
            float cost0 = fat.merged(nodes[c0].aabb).surfaceArea() + inheritanceCost;
            float cost1 = fat.merged(nodes[c1].aabb).surfaceArea() + inheritanceCost;
            if (!nodes[c0].isLeaf) cost0 -= nodes[c0].aabb.surfaceArea();
            if (!nodes[c1].isLeaf) cost1 -= nodes[c1].aabb.surfaceArea();

            if (branchCost < cost0 && branchCost < cost1) break;
            sibling = cost0 < cost1 ? c0 : c1;
        }

        // Create new internal parent = merged(sibling, leaf).
        immutable oldParent = nodes[sibling].parent;
        immutable newParent = allocNode();
        nodes[newParent].parent = oldParent;
        nodes[newParent].aabb = nodes[sibling].aabb.merged(fat);
        nodes[newParent].child0 = sibling;
        nodes[newParent].child1 = leafIdx;
        nodes[sibling].parent = newParent;
        nodes[leafIdx].parent = newParent;

        if (oldParent == NULL_IDX) {
            root = newParent;
        } else {
            if (nodes[oldParent].child0 == sibling) nodes[oldParent].child0 = newParent;
            else                                    nodes[oldParent].child1 = newParent;
            // Refit ancestors.
            int idx = oldParent;
            while (idx != NULL_IDX) {
                refit(idx);
                idx = nodes[idx].parent;
            }
        }
        return leafIdx;
    }

    void removeLeaf(int leafIdx)  {
        if (leafIdx == root) {
            root = NULL_IDX;
            freeNode(leafIdx);
            return;
        }
        immutable parent      = nodes[leafIdx].parent;
        immutable grandparent = nodes[parent].parent;
        immutable sibling     = nodes[parent].child0 == leafIdx
                                  ? nodes[parent].child1
                                  : nodes[parent].child0;

        if (grandparent == NULL_IDX) {
            root = sibling;
            nodes[sibling].parent = NULL_IDX;
        } else {
            if (nodes[grandparent].child0 == parent) nodes[grandparent].child0 = sibling;
            else                                     nodes[grandparent].child1 = sibling;
            nodes[sibling].parent = grandparent;
            int idx = grandparent;
            while (idx != NULL_IDX) {
                refit(idx);
                idx = nodes[idx].parent;
            }
        }
        freeNode(parent);
        freeNode(leafIdx);
    }

    /// Bullet's fast-path update. If `tight` still fits within the stored
    /// fat AABB → no work. Otherwise rebuild fat AABB with margin +
    /// signed-velocity expansion and re-insert.
    void updateLeaf(int leafIdx, Aabb tight, Vec3 velocity)  {
        if (nodes[leafIdx].aabb.contains(tight)) return;
        immutable bodyId = nodes[leafIdx].leafBodyId;
        removeLeaf(leafIdx);
        Aabb fat = tight.expanded(DBVT_MARGIN);
        fat = fat.signedExpanded(velocity * DBVT_VELOCITY_PREDICTION);
        immutable newIdx = insertLeaf(bodyId, fat);
        assert(newIdx >= 0);
        // Caller (physics world) must write newIdx back into the body's slot.
        // We return via side channel: store newIdx in freeHead? No — callers
        // track leaf indices themselves. Work-around: only the fast path
        // avoids re-insertion, so for this helper we return the new idx via
        // an out parameter variant below.
    }

    /// Variant that returns the new leaf index (since remove+insert can move
    /// the leaf to a different slot). Use this when you need to keep the
    /// body→leafIdx map in sync.
    int updateLeafReassign(int leafIdx, Aabb tight, Vec3 velocity)  {
        if (nodes[leafIdx].aabb.contains(tight)) return leafIdx;
        immutable bodyId = nodes[leafIdx].leafBodyId;
        removeLeaf(leafIdx);
        Aabb fat = tight.expanded(DBVT_MARGIN);
        fat = fat.signedExpanded(velocity * DBVT_VELOCITY_PREDICTION);
        return insertLeaf(bodyId, fat);
    }

    // -------- pair finding (collideTT self-descent) ----------------------

    /// Invoke `sink(idA, idB)` for every overlapping leaf pair (idA < idB).
    /// O(n log n) in practice; uses iterative explicit stack.
    void findPairs(scope void delegate(uint, uint) @safe  sink)  {
        if (root == NULL_IDX || nodes[root].isLeaf) return;
        int sp = 0;
        pairStackA[sp] = root;
        pairStackB[sp] = root;
        sp++;
        while (sp > 0) {
            sp--;
            int a = pairStackA[sp];
            int b = pairStackB[sp];
            if (a == b) {
                if (nodes[a].isLeaf) continue;
                immutable c0 = nodes[a].child0;
                immutable c1 = nodes[a].child1;
                // (c0, c0), (c1, c1), (c0, c1) — dedup'd via "a <= b" ordering.
                if (sp + 3 > cast(int) pairStackA.length) return;
                pairStackA[sp] = c0; pairStackB[sp] = c0; sp++;
                pairStackA[sp] = c1; pairStackB[sp] = c1; sp++;
                pairStackA[sp] = c0; pairStackB[sp] = c1; sp++;
            } else {
                if (!nodes[a].aabb.overlaps(nodes[b].aabb)) continue;
                if (nodes[a].isLeaf && nodes[b].isLeaf) {
                    immutable ida = nodes[a].leafBodyId;
                    immutable idb = nodes[b].leafBodyId;
                    if (ida < idb) sink(ida, idb); else sink(idb, ida);
                } else if (nodes[a].isLeaf) {
                    if (sp + 2 > cast(int) pairStackA.length) return;
                    pairStackA[sp] = a; pairStackB[sp] = nodes[b].child0; sp++;
                    pairStackA[sp] = a; pairStackB[sp] = nodes[b].child1; sp++;
                } else if (nodes[b].isLeaf) {
                    if (sp + 2 > cast(int) pairStackA.length) return;
                    pairStackA[sp] = nodes[a].child0; pairStackB[sp] = b; sp++;
                    pairStackA[sp] = nodes[a].child1; pairStackB[sp] = b; sp++;
                } else {
                    // Descend the side with the larger volume for better culling.
                    if (sp + 4 > cast(int) pairStackA.length) return;
                    pairStackA[sp] = nodes[a].child0; pairStackB[sp] = nodes[b].child0; sp++;
                    pairStackA[sp] = nodes[a].child0; pairStackB[sp] = nodes[b].child1; sp++;
                    pairStackA[sp] = nodes[a].child1; pairStackB[sp] = nodes[b].child0; sp++;
                    pairStackA[sp] = nodes[a].child1; pairStackB[sp] = nodes[b].child1; sp++;
                }
            }
        }
    }

    /// Query all leaves overlapping `aabb`. Used by the world to check a
    /// single body's AABB against all others (e.g. for rays too).
    void query(Aabb aabb, scope void delegate(uint) @safe  sink)  {
        if (root == NULL_IDX) return;
        int sp = 0;
        singleStack[sp++] = root;
        while (sp > 0) {
            immutable idx = singleStack[--sp];
            if (!nodes[idx].aabb.overlaps(aabb)) continue;
            if (nodes[idx].isLeaf) sink(nodes[idx].leafBodyId);
            else {
                if (sp + 2 > cast(int) singleStack.length) return;
                singleStack[sp++] = nodes[idx].child0;
                singleStack[sp++] = nodes[idx].child1;
            }
        }
    }
}
