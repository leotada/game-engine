// Persistent manifold pool — Bullet's btPersistentManifold cached by body
// pair. Stores up to MANIFOLD_CACHE_SIZE (4) points per pair with warm-
// started impulses that survive across frames.
//
// New contacts from narrowphase are merged in: existing points closer than
// CONTACT_BREAKING_THRESHOLD to the incoming world position keep their
// cached impulses (warm-start); everything else uses Bullet's "deepest +
// maximum triangle area" reduction to pick 4 of n candidates.
module engine.physics.manifold_pool;

import std.math : fabs, sqrt;
import engine.math.vec;
import engine.math.quat;
import engine.physics.types;

@safe:

/// Fixed-capacity open-addressed hash from (a,b) body pair → slot index.
/// Pairs are inserted with a < b so the same ordered key is used whether the
/// narrowphase was called (a,b) or (b,a).
struct ManifoldPool(uint Capacity) {
@safe:
    // Stored manifolds — pre-allocated, never moved so indices are stable.
    ContactManifold[Capacity] manifolds;
    // Packed (a,b) as a ulong; hashKeyEmpty == ulong.max marks free slot.
    // We must store the FULL 64-bit key — truncating to int32 causes
    // collisions whenever b > 0 (the upper half holds b), which makes
    // getOrCreate fail to find existing entries and allocate a new slot
    // every frame, exhausting the pool within a few frames.
    enum ulong hashKeyEmpty = ulong.max;
    ulong[Capacity * 2] hashKeys;
    int[Capacity * 2]   hashSlots;  // index into manifolds[]
    uint count = 0;                 // high-water mark of slots ever allocated

    // Free list of slots reclaimed by ageAndEvict. Without this the pool
    // only grows, so a long-running benchmark where pairs churn
    // (rain cubes pass over/past static colliders) exhausts Capacity even
    // though at any given instant far fewer than Capacity manifolds are
    // active. Using a LIFO stack keeps allocation O(1) and cache-friendly.
    int[Capacity] freeStack;
    uint freeCount = 0;

    void init_()  {
        count = 0;
        freeCount = 0;
        hashKeys[]  = hashKeyEmpty;
        hashSlots[] = -1;
        foreach (ref m; manifolds) { m.count = 0; m.framesSinceUse = 255; }
    }

    private static ulong packKey(uint a, uint b) pure  {
        return (cast(ulong) a) | ((cast(ulong) b) << 32);
    }

    private static uint hashKey(ulong k) pure  {
        // Wang hash.
        k = (~k) + (k << 18);
        k ^= k >>> 31;
        k *= 21;
        k ^= k >>> 11;
        k += k << 6;
        k ^= k >>> 22;
        return cast(uint) k;
    }

    /// Returns pointer to the manifold for (a,b). Creates one on first use.
    /// Caller must sort a < b before calling.
    /// Returns null if the pool is fully saturated (both `count` at Capacity
    /// and the free list empty). Callers MUST null-check — dropping one
    /// pair's contacts for a frame is preferable to an abort.
    ContactManifold* getOrCreate(uint a, uint b)  {
        immutable packed = packKey(a, b);
        immutable mask = cast(uint)(hashKeys.length - 1);
        uint idx = hashKey(packed) & mask;
        while (hashKeys[idx] != hashKeyEmpty) {
            if (hashKeys[idx] == packed) {
                return &manifolds[hashSlots[idx]];
            }
            idx = (idx + 1) & mask;
        }
        // Allocate a slot: prefer the free list (reclaimed via ageAndEvict),
        // fall back to the high-water mark.
        int slot;
        if (freeCount > 0) {
            slot = freeStack[--freeCount];
        } else if (count < Capacity) {
            slot = cast(int) count++;
        } else {
            return null;  // pool saturated — drop this pair this frame
        }
        manifolds[slot] = ContactManifold.init;
        manifolds[slot].a = a;
        manifolds[slot].b = b;
        manifolds[slot].framesSinceUse = 0;
        hashKeys[idx]  = packed;
        hashSlots[idx] = slot;
        return &manifolds[slot];
    }

    ContactManifold* find(uint a, uint b)  {
        immutable packed = packKey(a, b);
        immutable mask = cast(uint)(hashKeys.length - 1);
        uint idx = hashKey(packed) & mask;
        while (hashKeys[idx] != hashKeyEmpty) {
            if (hashKeys[idx] == packed) {
                return &manifolds[hashSlots[idx]];
            }
            idx = (idx + 1) & mask;
        }
        return null;
    }

    /// At the end of each frame, age every manifold; those unused for more
    /// than `maxAge` frames are dropped AND their slot is pushed onto the
    /// free list so a future `getOrCreate` can reuse it.
    void ageAndEvict(ubyte maxAge)  {
        immutable mask = cast(uint)(hashKeys.length - 1);
        foreach (slot, ref m; manifolds) {
            if (m.framesSinceUse >= 255) continue; // already free
            if (m.framesSinceUse < 255) m.framesSinceUse = cast(ubyte)(m.framesSinceUse + 1);
            if (m.framesSinceUse > maxAge) {
                // Locate the hash bucket for this (a,b) pair. Since we
                // inserted it we know the probe will terminate at the
                // matching key (hashKeys array is sized 2×Capacity so it
                // cannot be fully packed).
                immutable packed = packKey(m.a, m.b);
                uint idx = hashKey(packed) & mask;
                while (hashKeys[idx] != packed) {
                    if (hashKeys[idx] == hashKeyEmpty) { idx = uint.max; break; }
                    idx = (idx + 1) & mask;
                }
                if (idx != uint.max) removeHashAt(idx, mask);
                m.count = 0;
                m.framesSinceUse = 255;
                if (freeCount < Capacity) freeStack[freeCount++] = cast(int) slot;
            }
        }
    }

    /// Backward-shift deletion for an open-addressed table. Walks forward
    /// from the empty bucket and pulls back any entry whose probe distance
    /// can be reduced. Linear-probe-friendly and keeps `find` correct
    /// without tombstones.
    private void removeHashAt(uint hole, uint mask)  {
        hashKeys[hole]  = hashKeyEmpty;
        hashSlots[hole] = -1;
        uint j = (hole + 1) & mask;
        while (hashKeys[j] != hashKeyEmpty) {
            immutable natural = hashKey(hashKeys[j]) & mask;
            // Distance from natural bucket to the hole (circular).
            immutable dHole = (hole - natural) & mask;
            immutable dJ    = (j    - natural) & mask;
            if (dHole < dJ) {
                hashKeys[hole]  = hashKeys[j];
                hashSlots[hole] = hashSlots[j];
                hashKeys[j]  = hashKeyEmpty;
                hashSlots[j] = -1;
                hole = j;
            }
            j = (j + 1) & mask;
        }
    }

    /// Refresh existing contact world positions using the bodies' current
    /// transforms, then drop any point whose worldA/worldB are now too far
    /// apart (separation along normal or too much drift tangentially).
    /// Bullet btPersistentManifold::refreshContactPoints.
    static void refresh(ref ContactManifold m, Vec3 pa, Quat qa, Vec3 pb, Quat qb)  {
        enum float threshold  = CONTACT_BREAKING_THRESHOLD;
        enum float thresholdSq = threshold * threshold;
        ubyte write = 0;
        foreach (r; 0 .. m.count) {
            auto p = &m.points[r];
            immutable wa = pa + qa.rotate(p.localA);
            immutable wb = pb + qb.rotate(p.localB);
            // Normal-direction separation.
            immutable sep = p.normal.dot(wa - wb);
            if (sep > threshold) continue;                 // too far apart
            // Tangential drift.
            immutable projA = wa - p.normal * sep;
            immutable drift = projA - wb;
            if (drift.lengthSquared > thresholdSq) continue;
            // Keep.
            p.worldPosA = wa;
            p.worldPosB = wb;
            p.depth     = -sep;
            if (write != r) m.points[write] = *p;
            write++;
        }
        m.count = write;
    }
}

/// Merge `incoming` points into `m`, preserving cached impulses on any
/// existing point whose localA position matches the incoming point within
/// CONTACT_BREAKING_THRESHOLD. Reduces to at most MANIFOLD_CACHE_SIZE using
/// Bullet's "deepest + max triangle area" rule.
void mergeContacts(ref ContactManifold m, const ContactPoint[] incoming) @safe  {
    import std.math : fabs;
    enum float mergeDistSq = CONTACT_BREAKING_THRESHOLD * CONTACT_BREAKING_THRESHOLD;

    foreach (const ref inp; incoming) {
        // Try to match an existing point by localA proximity (warm-start).
        int matched = -1;
        foreach (j; 0 .. m.count) {
            if ((inp.localA - m.points[j].localA).lengthSquared <= mergeDistSq) {
                matched = cast(int) j;
                break;
            }
        }
        if (matched >= 0) {
            // Update geometry but preserve impulses.
            ContactPoint c = inp;
            c.normalImpulse   = m.points[matched].normalImpulse;
            c.tangent1Impulse = m.points[matched].tangent1Impulse;
            c.tangent2Impulse = m.points[matched].tangent2Impulse;
            m.points[matched] = c;
        } else if (m.count < MANIFOLD_CACHE_SIZE) {
            m.points[m.count++] = inp;
        } else {
            // Full — apply Bullet's reduction. Keep deepest point always;
            // for the 3 others pick the combination with the largest
            // triangle area.
            addReducedPoint(m, inp);
        }
    }
    m.framesSinceUse = 0;
    if (m.framesAlive < 255) m.framesAlive++;
}

private void addReducedPoint(ref ContactManifold m, const ContactPoint inp) @safe  {
    // Find current deepest index — always keep it.
    int deepest = 0;
    float maxDepth = m.points[0].depth;
    foreach (i; 1 .. MANIFOLD_CACHE_SIZE) if (m.points[i].depth > maxDepth) {
        maxDepth = m.points[i].depth;
        deepest = i;
    }
    // Pick which non-deepest slot to replace: the one whose replacement by
    // `inp` maximizes the spread of the 4 points (sum of squared pairwise
    // distances — cheap area proxy, Bullet uses exact triangle area).
    int replace = 0;
    float bestSpread = -1;
    foreach (cand; 0 .. MANIFOLD_CACHE_SIZE) {
        if (cand == deepest) continue;
        Vec3[4] pts;
        foreach (i; 0 .. MANIFOLD_CACHE_SIZE) {
            pts[i] = (i == cand) ? inp.localA : m.points[i].localA;
        }
        float s = 0;
        foreach (i; 0 .. 4) foreach (j; i + 1 .. 4) {
            s += (pts[i] - pts[j]).lengthSquared;
        }
        if (s > bestSpread) {
            bestSpread = s;
            replace = cast(int) cand;
        }
    }
    ContactPoint c = inp;
    c.normalImpulse   = m.points[replace].normalImpulse;
    c.tangent1Impulse = m.points[replace].tangent1Impulse;
    c.tangent2Impulse = m.points[replace].tangent2Impulse;
    m.points[replace] = c;
}
