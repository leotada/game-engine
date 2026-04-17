// 
module engine.physics.narrowphase;

import engine.math.vec;
import engine.math.quat;
import engine.physics.types;
import std.math : abs, sqrt;

@safe:

// -----------------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------------

// 
private Vec3 localAxis(Quat q, int axis) {
    Vec3 v;
    if (axis == 0) v = Vec3(1, 0, 0);
    else if (axis == 1) v = Vec3(0, 1, 0);
    else v = Vec3(0, 0, 1);
    return q.rotate(v);
}

private float projectBox(Vec3 axis, Vec3[3] boxAxes, Vec3 halfExt) {
    return halfExt.x * abs(axis.dot(boxAxes[0]))
         + halfExt.y * abs(axis.dot(boxAxes[1]))
         + halfExt.z * abs(axis.dot(boxAxes[2]));
}

private Vec3 closestPointOnSegment(Vec3 p, Vec3 a, Vec3 b) {
    immutable ab = b - a;
    immutable denom = ab.dot(ab);
    if (denom < 1e-20f) return a;
    float t = (p - a).dot(ab) / denom;
    if (t < 0) t = 0;
    else if (t > 1) t = 1;
    return a + ab * t;
}

private Vec3 closestPointOnBox(Vec3 p, Vec3 center, Vec3[3] axes, Vec3 halfExt) {
    immutable d = p - center;
    Vec3 q = center;
    // Project onto each axis, clamp to half extent, walk out from center.
    float dx = d.dot(axes[0]);
    if (dx > halfExt.x) dx = halfExt.x;
    else if (dx < -halfExt.x) dx = -halfExt.x;
    float dy = d.dot(axes[1]);
    if (dy > halfExt.y) dy = halfExt.y;
    else if (dy < -halfExt.y) dy = -halfExt.y;
    float dz = d.dot(axes[2]);
    if (dz > halfExt.z) dz = halfExt.z;
    else if (dz < -halfExt.z) dz = -halfExt.z;
    q = q + axes[0] * dx + axes[1] * dy + axes[2] * dz;
    return q;
}

// -----------------------------------------------------------------------------
// Box vs Box (SAT, 15 axes, single contact)
// -----------------------------------------------------------------------------

bool satBoxBox(Vec3 centerA, Quat orientA, Vec3 halfA,
               Vec3 centerB, Quat orientB, Vec3 halfB,
               out ContactManifold manifold) {
    Vec3[3] axesA = [localAxis(orientA, 0), localAxis(orientA, 1), localAxis(orientA, 2)];
    Vec3[3] axesB = [localAxis(orientB, 0), localAxis(orientB, 1), localAxis(orientB, 2)];
    immutable t = centerB - centerA;

    Vec3  bestAxis;
    float minOverlap = float.max;

    // Test a single axis; returns false if separating, else tracks min overlap.
    bool test(Vec3 axis) {
        immutable axLenSq = axis.dot(axis);
        if (axLenSq < 1e-12f) return true; // skip degenerate
        immutable invLen = 1.0f / sqrt(axLenSq);
        immutable n = axis * invLen;
        immutable projT = abs(t.dot(n));
        immutable projA = projectBox(n, axesA, halfA);
        immutable projB = projectBox(n, axesB, halfB);
        immutable overlap = projA + projB - projT;
        if (overlap <= 0.0f) return false;
        if (overlap < minOverlap) {
            minOverlap = overlap;
            // Ensure axis points from A to B (normal convention).
            bestAxis = t.dot(n) < 0 ? -n : n;
        }
        return true;
    }

    // 3 face normals of A
    foreach (i; 0 .. 3) if (!test(axesA[i])) return false;
    // 3 face normals of B
    foreach (i; 0 .. 3) if (!test(axesB[i])) return false;
    // 9 edge-edge cross products
    foreach (i; 0 .. 3)
        foreach (j; 0 .. 3) {
            if (!test(axesA[i].cross(axesB[j]))) return false;
        }

    // Contact point: closest point on B to A's center, biased by normal.
    immutable contactOnB = closestPointOnBox(centerA, centerB, axesB, halfB);
    immutable contactOnA = closestPointOnBox(centerB, centerA, axesA, halfA);
    immutable worldPos = (contactOnA + contactOnB) * 0.5f;

    manifold.points[0] = ContactPoint(worldPos, bestAxis, minOverlap);
    manifold.count = 1;
    return true;
}

// -----------------------------------------------------------------------------
// Box vs Capsule (reduce to sphere-vs-box sweep along the capsule segment)
// -----------------------------------------------------------------------------

bool satBoxCapsule(Vec3 centerBox, Quat orientBox, Vec3 halfBox,
                   Vec3 centerCap, Quat orientCap, float radius, float halfHeight,
                   out ContactManifold manifold) {
    Vec3[3] axesB = [localAxis(orientBox, 0), localAxis(orientBox, 1), localAxis(orientBox, 2)];
    immutable capDir = localAxis(orientCap, 1); // capsule axis = local Y
    immutable segA = centerCap - capDir * halfHeight;
    immutable segB = centerCap + capDir * halfHeight;

    // Find the segment point closest to the box, then do sphere-vs-box.
    // Sample segment endpoints plus midpoint; use iterative shrink.
    Vec3 bestSegPt = segA;
    float bestDistSq = float.max;

    // Parametric sweep (fixed samples — 9 gives plenty of resolution without
    // allocations; refine to two quick bisections around the best).
    float bestT = 0;
    foreach (i; 0 .. 9) {
        immutable tt = cast(float) i / 8.0f;
        immutable p  = segA + (segB - segA) * tt;
        immutable cp = closestPointOnBox(p, centerBox, axesB, halfBox);
        immutable d  = (p - cp);
        immutable dsq = d.dot(d);
        if (dsq < bestDistSq) {
            bestDistSq = dsq;
            bestSegPt = p;
            bestT = tt;
        }
    }

    // Two bisection refinements.
    foreach (_; 0 .. 6) {
        immutable tL = bestT - 0.0625f < 0 ? 0 : bestT - 0.0625f;
        immutable tR = bestT + 0.0625f > 1 ? 1 : bestT + 0.0625f;
        immutable pL = segA + (segB - segA) * tL;
        immutable pR = segA + (segB - segA) * tR;
        immutable dL = pL - closestPointOnBox(pL, centerBox, axesB, halfBox);
        immutable dR = pR - closestPointOnBox(pR, centerBox, axesB, halfBox);
        immutable dLsq = dL.dot(dL);
        immutable dRsq = dR.dot(dR);
        if (dLsq < bestDistSq) { bestDistSq = dLsq; bestSegPt = pL; bestT = tL; }
        if (dRsq < bestDistSq) { bestDistSq = dRsq; bestSegPt = pR; bestT = tR; }
    }

    immutable closestOnBox = closestPointOnBox(bestSegPt, centerBox, axesB, halfBox);
    Vec3 diff = bestSegPt - closestOnBox;
    float dist = sqrt(diff.dot(diff));
    if (dist >= radius) return false;

    Vec3 normal;
    if (dist > 1e-6f) normal = diff * (1.0f / dist);
    else normal = Vec3(0, 1, 0); // degenerate: pick up as fallback

    // Convention: normal points from box (A) to capsule (B).
    immutable depth = radius - dist;
    immutable worldPos = closestOnBox + normal * (radius - depth * 0.5f);

    manifold.points[0] = ContactPoint(worldPos, normal, depth);
    manifold.count = 1;
    return true;
}

// -----------------------------------------------------------------------------
// Capsule vs Capsule
// -----------------------------------------------------------------------------

private void closestPointsSegSeg(Vec3 p1, Vec3 q1, Vec3 p2, Vec3 q2,
                                 out Vec3 c1, out Vec3 c2) {
    // Real-Time Collision Detection, Ericson. Clamped algorithm.
    immutable d1 = q1 - p1;
    immutable d2 = q2 - p2;
    immutable r  = p1 - p2;
    immutable a  = d1.dot(d1);
    immutable e  = d2.dot(d2);
    immutable f  = d2.dot(r);

    float s, t;
    if (a <= 1e-12f && e <= 1e-12f) { c1 = p1; c2 = p2; return; }
    if (a <= 1e-12f) {
        s = 0;
        t = f / e;
        if (t < 0) t = 0;
        else if (t > 1) t = 1;
    } else {
        immutable c = d1.dot(r);
        if (e <= 1e-12f) {
            t = 0;
            s = -c / a;
            if (s < 0) s = 0;
            else if (s > 1) s = 1;
        } else {
            immutable b = d1.dot(d2);
            immutable denom = a * e - b * b;
            if (denom != 0.0f) {
                s = (b * f - c * e) / denom;
                if (s < 0) s = 0;
                else if (s > 1) s = 1;
            } else s = 0;
            t = (b * s + f) / e;
            if (t < 0) {
                t = 0;
                s = -c / a;
                if (s < 0) s = 0;
                else if (s > 1) s = 1;
            } else if (t > 1) {
                t = 1;
                s = (b - c) / a;
                if (s < 0) s = 0;
                else if (s > 1) s = 1;
            }
        }
    }
    c1 = p1 + d1 * s;
    c2 = p2 + d2 * t;
}

bool satCapsuleCapsule(Vec3 centerA, Quat orientA, float rA, float hhA,
                       Vec3 centerB, Quat orientB, float rB, float hhB,
                       out ContactManifold manifold) {
    immutable axA = localAxis(orientA, 1);
    immutable axB = localAxis(orientB, 1);
    immutable pA = centerA - axA * hhA;
    immutable qA = centerA + axA * hhA;
    immutable pB = centerB - axB * hhB;
    immutable qB = centerB + axB * hhB;

    Vec3 cA, cB;
    closestPointsSegSeg(pA, qA, pB, qB, cA, cB);
    immutable diff = cB - cA;
    immutable dsq = diff.dot(diff);
    immutable sumR = rA + rB;
    if (dsq >= sumR * sumR) return false;

    immutable dist = sqrt(dsq);
    Vec3 normal;
    if (dist > 1e-6f) normal = diff * (1.0f / dist);
    else normal = Vec3(0, 1, 0);

    immutable depth = sumR - dist;
    immutable worldPos = (cA + cB) * 0.5f;
    manifold.points[0] = ContactPoint(worldPos, normal, depth);
    manifold.count = 1;
    return true;
}

// -----------------------------------------------------------------------------
// Unit tests
// -----------------------------------------------------------------------------

unittest {
    // Two unit cubes axis-aligned, penetrating 0.1 along +X.
    ContactManifold m;
    immutable hit = satBoxBox(
        Vec3(0, 0, 0), Quat.identity, Vec3(0.5f, 0.5f, 0.5f),
        Vec3(0.9f, 0, 0), Quat.identity, Vec3(0.5f, 0.5f, 0.5f),
        m);
    assert(hit);
    assert(m.count == 1);
    assert(m.points[0].depth > 0.09f && m.points[0].depth < 0.11f);
    assert(m.points[0].normal.x > 0.99f);
}

unittest {
    // Two unit cubes far apart — no hit.
    ContactManifold m;
    immutable hit = satBoxBox(
        Vec3(0, 0, 0), Quat.identity, Vec3(0.5f, 0.5f, 0.5f),
        Vec3(5, 0, 0), Quat.identity, Vec3(0.5f, 0.5f, 0.5f),
        m);
    assert(!hit);
}

unittest {
    // Capsule vertical over a flat box: resting contact.
    ContactManifold m;
    immutable hit = satBoxCapsule(
        Vec3(0, 0, 0), Quat.identity, Vec3(5, 0.5f, 5),       // big flat box
        Vec3(0, 1.2f, 0), Quat.identity, 0.5f, 0.5f,          // capsule r=0.5 hh=0.5
        m);
    assert(hit);
    assert(m.count == 1);
    // penetration: capsule bottom at y=0.2, box top at y=0.5 → overlap 0.3
    assert(m.points[0].depth > 0.25f && m.points[0].depth < 0.35f);
}
