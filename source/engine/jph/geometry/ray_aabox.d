// Jolt — Geometry/RayAABox.h port. Slab method for ray vs axis-aligned box.
// Returns FLT_MAX when no hit. Negative values mean the ray starts inside.
//
// We omit the SIMD `RayAABox4` (4 boxes at once) — the broadphase that
// consumes it isn't ported yet. Add it alongside BroadPhaseQuadTree.
//
// Source: ref/JoltPhysics/Jolt/Geometry/RayAABox.h.
module engine.jph.geometry.ray_aabox;

import std.math : abs, isFinite;
import engine.jph.math.vec3;

@safe:

/// Reciprocal of a ray direction with explicit "is parallel to slab" mask.
struct RayInvDirection {
@safe:
    Vec3 mInvDirection;
    bool[3] mIsParallel = [false, false, false];

    this(Vec3 inDirection) pure nothrow @nogc { Set(inDirection); }

    void Set(Vec3 inDirection) pure nothrow @nogc {
        enum float kEps = 1.0e-20f;
        float[3] d = [inDirection.GetX(), inDirection.GetY(), inDirection.GetZ()];
        float[3] inv;
        foreach (i; 0 .. 3) {
            mIsParallel[i] = abs(d[i]) <= kEps;
            inv[i] = mIsParallel[i] ? 1.0f : 1.0f / d[i];
        }
        mInvDirection = Vec3(inv[0], inv[1], inv[2]);
    }
}

private void minMaxSlab(float bMin, float bMax, float origin, float invDir, bool parallel,
                        ref float tMin, ref float tMax, ref bool noIntersect) pure nothrow @nogc {
    if (parallel) {
        // Ray parallel to slab — must lie inside it.
        if (origin < bMin || origin > bMax)
            noIntersect = true;
        // Don't update tMin/tMax (parallel slab contributes ±FLT_MAX, which
        // can never tighten the running interval).
        return;
    }
    immutable float t1 = (bMin - origin) * invDir;
    immutable float t2 = (bMax - origin) * invDir;
    immutable float lo = t1 < t2 ? t1 : t2;
    immutable float hi = t1 < t2 ? t2 : t1;
    if (lo > tMin) tMin = lo;
    if (hi < tMax) tMax = hi;
}

/// Returns the entry fraction or FLT_MAX. Negative if the ray starts in the box.
float RayAABox(Vec3 inOrigin, const ref RayInvDirection inInv, Vec3 inMin, Vec3 inMax) pure nothrow @nogc {
    float tMin = -float.max, tMax = float.max;
    bool noIntersect = false;
    immutable float[3] o = [inOrigin.GetX(), inOrigin.GetY(), inOrigin.GetZ()];
    immutable float[3] mn = [inMin.GetX(),    inMin.GetY(),    inMin.GetZ()];
    immutable float[3] mx = [inMax.GetX(),    inMax.GetY(),    inMax.GetZ()];
    immutable float[3] iv = [inInv.mInvDirection.GetX(), inInv.mInvDirection.GetY(), inInv.mInvDirection.GetZ()];
    foreach (i; 0 .. 3)
        minMaxSlab(mn[i], mx[i], o[i], iv[i], inInv.mIsParallel[i], tMin, tMax, noIntersect);
    if (noIntersect || tMin > tMax || tMax < 0.0f)
        return float.max;
    return tMin;
}

/// As above but also returns the exit fraction. Both are FLT_MAX/-FLT_MAX on miss.
void RayAABox(Vec3 inOrigin, const ref RayInvDirection inInv, Vec3 inMin, Vec3 inMax,
              ref float outMin, ref float outMax) pure nothrow @nogc {
    float tMin = -float.max, tMax = float.max;
    bool noIntersect = false;
    immutable float[3] o = [inOrigin.GetX(), inOrigin.GetY(), inOrigin.GetZ()];
    immutable float[3] mn = [inMin.GetX(),    inMin.GetY(),    inMin.GetZ()];
    immutable float[3] mx = [inMax.GetX(),    inMax.GetY(),    inMax.GetZ()];
    immutable float[3] iv = [inInv.mInvDirection.GetX(), inInv.mInvDirection.GetY(), inInv.mInvDirection.GetZ()];
    foreach (i; 0 .. 3)
        minMaxSlab(mn[i], mx[i], o[i], iv[i], inInv.mIsParallel[i], tMin, tMax, noIntersect);
    if (noIntersect || tMin > tMax || tMax < 0.0f) {
        outMin =  float.max;
        outMax = -float.max;
        return;
    }
    outMin = tMin;
    outMax = tMax;
}

/// True if the slab intersection is closer than `inClosest`.
bool RayAABoxHits(Vec3 inOrigin, const ref RayInvDirection inInv, Vec3 inMin, Vec3 inMax,
                  float inClosest) pure nothrow @nogc {
    immutable float t = RayAABox(inOrigin, inInv, inMin, inMax);
    return t != float.max && t <= inClosest;
}

/// Separating-axis variant — no fraction, just hit/miss. Cheaper when only the
/// answer matters. See http://www.codercorner.com/RayAABB.cpp for derivation.
bool RayAABoxHits(Vec3 inOrigin, Vec3 inDirection, Vec3 inMin, Vec3 inMax) pure nothrow @nogc {
    immutable Vec3 ext = inMax - inMin;
    immutable Vec3 diff = 2.0f * inOrigin - inMin - inMax;
    immutable Vec3 absDiff = diff.Abs();
    immutable Vec3 absDir  = inDirection.Abs();
    immutable float[3] e = [ext.GetX(), ext.GetY(), ext.GetZ()];
    immutable float[3] d = [diff.GetX(), diff.GetY(), diff.GetZ()];
    immutable float[3] ad = [absDiff.GetX(), absDiff.GetY(), absDiff.GetZ()];
    immutable float[3] dir = [inDirection.GetX(), inDirection.GetY(), inDirection.GetZ()];
    immutable float[3] adir = [absDir.GetX(), absDir.GetY(), absDir.GetZ()];

    // Slab tests
    foreach (i; 0 .. 3)
        if (ad[i] > e[i] && d[i] * dir[i] >= 0.0f)
            return false;

    // Cross-product tests for the three coordinate planes
    static immutable size_t[3] yzx = [1, 2, 0];
    static immutable size_t[3] xyx = [0, 1, 0];
    static immutable size_t[3] yzz = [1, 2, 2];
    foreach (i; 0 .. 3) {
        immutable float lhs = abs(dir[i] * d[yzx[i]] - dir[yzx[i]] * d[i]);
        immutable float rhs = e[xyx[i]] * adir[yzz[i]] + e[yzz[i]] * adir[xyx[i]];
        if (lhs > rhs)
            return false;
    }
    return true;
}

unittest {
    immutable o = Vec3(-2, 0, 0);
    immutable d = Vec3(1, 0, 0);
    auto inv = RayInvDirection(d);
    immutable mn = Vec3(-0.5f, -0.5f, -0.5f);
    immutable mx = Vec3( 0.5f,  0.5f,  0.5f);
    immutable t = RayAABox(o, inv, mn, mx);
    assert(t > 1.49f && t < 1.51f);

    // Miss
    immutable o2 = Vec3(-2, 5, 0);
    auto inv2 = RayInvDirection(Vec3(1, 0, 0));
    assert(RayAABox(o2, inv2, mn, mx) == float.max);

    // Inside box -> negative tMin
    immutable o3 = Vec3(0, 0, 0);
    auto inv3 = RayInvDirection(Vec3(1, 0, 0));
    immutable t3 = RayAABox(o3, inv3, mn, mx);
    assert(t3 <= 0.0f);
}
