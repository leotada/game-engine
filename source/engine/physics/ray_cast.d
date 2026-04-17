// Jolt-style raycasting.
//
// Mirrors Jolt/Physics/Collision/RayCast.h + NarrowPhaseQuery. MVP supports
// sphere, box, capsule and the static plane shape already present in the
// legacy engine. Cylinders and convex hulls currently short-circuit to
// "no hit" — they'll be added alongside proper narrow-phase support.
module engine.physics.ray_cast;

import core.stdc.math : sqrtf, fabsf;
import engine.math.vec;
import engine.math.quat;
import engine.physics.types;

@safe:

/// Ray with an origin and a *direction-with-length* vector (Jolt RRayCast).
/// `getPointOnRay(f)` returns origin + direction * f where f ∈ [0, 1].
struct RRayCast {
@safe:
    Vec3 origin    = Vec3(0, 0, 0);
    Vec3 direction = Vec3(0, 0, 0);

    Vec3 getPointOnRay(float fraction) const {
        return origin + direction * fraction;
    }
}

enum EBackFaceMode : ubyte {
    IgnoreBackFaces  = 0,
    CollideWithBackFaces = 1,
}

struct RayCastSettings {
@safe:
    EBackFaceMode backFaceMode = EBackFaceMode.IgnoreBackFaces;
    /// When true, the first hit wins; otherwise the closest hit is returned.
    bool treatConvexAsSolid = true;
}

struct RayCastResult {
@safe:
    RigidBodyId bodyId   = INVALID_BODY;
    float       fraction = 1.0f; // 1.0 == no hit
    Vec3        normal   = Vec3(0, 1, 0);

    bool hasHit() const {
        return bodyId != INVALID_BODY;
    }
}

/// Ray vs axis-aligned box (in local space). Returns t ∈ [0, 1] on hit, -1 otherwise.
/// Branchless slab test, robust for zero components in `invDir` via copysign-like guard.
private float rayVsLocalBox(Vec3 localOrigin, Vec3 localDir, Vec3 halfExtents) {
    float tMin = 0.0f;
    float tMax = 1.0f;
    static foreach (axis; 0 .. 3) {{
        immutable float o = axis == 0 ? localOrigin.x : axis == 1 ? localOrigin.y : localOrigin.z;
        immutable float d = axis == 0 ? localDir.x    : axis == 1 ? localDir.y    : localDir.z;
        immutable float h = axis == 0 ? halfExtents.x : axis == 1 ? halfExtents.y : halfExtents.z;
        if (fabsf(d) < 1e-8f) {
            if (o < -h || o > h) return -1.0f;
        } else {
            immutable float invD = 1.0f / d;
            float t1 = (-h - o) * invD;
            float t2 = ( h - o) * invD;
            if (t1 > t2) { immutable tmp = t1; t1 = t2; t2 = tmp; }
            if (t1 > tMin) tMin = t1;
            if (t2 < tMax) tMax = t2;
            if (tMin > tMax) return -1.0f;
        }
    }}
    return tMin;
}

/// Outward normal of the box face hit at `localPoint` on a box of half-extents `h`.
private Vec3 localBoxNormal(Vec3 localPoint, Vec3 h) {
    // Pick the axis where |localPoint/h| is largest.
    immutable ax = fabsf(localPoint.x) / (h.x > 0 ? h.x : 1e-6f);
    immutable ay = fabsf(localPoint.y) / (h.y > 0 ? h.y : 1e-6f);
    immutable az = fabsf(localPoint.z) / (h.z > 0 ? h.z : 1e-6f);
    if (ax >= ay && ax >= az) return Vec3(localPoint.x >= 0 ? 1 : -1, 0, 0);
    if (ay >= az)             return Vec3(0, localPoint.y >= 0 ? 1 : -1, 0);
    return Vec3(0, 0, localPoint.z >= 0 ? 1 : -1);
}

/// Ray vs oriented box. Ray is in world space; box frame is (bodyPos, bodyRot).
bool rayVsBox(RRayCast ray, Vec3 bodyPos, Quat bodyRot, Vec3 halfExtents,
              ref float outFraction, ref Vec3 outNormal) {
    immutable qInv = bodyRot.conjugate;
    immutable localOrigin = qInv.rotate(ray.origin - bodyPos);
    immutable localDir    = qInv.rotate(ray.direction);
    immutable t = rayVsLocalBox(localOrigin, localDir, halfExtents);
    if (t < 0 || t > 1) return false;
    outFraction = t;
    immutable localHit = localOrigin + localDir * t;
    outNormal = bodyRot.rotate(localBoxNormal(localHit, halfExtents));
    return true;
}

/// Ray vs sphere centred at `bodyPos` with radius `r`.
bool rayVsSphere(RRayCast ray, Vec3 bodyPos, float r,
                 ref float outFraction, ref Vec3 outNormal) {
    immutable oc = ray.origin - bodyPos;
    immutable a  = ray.direction.dot(ray.direction);
    if (a < 1e-12f) return false;
    immutable b  = 2.0f * oc.dot(ray.direction);
    immutable c  = oc.dot(oc) - r * r;
    immutable disc = b * b - 4.0f * a * c;
    if (disc < 0) return false;
    immutable s = sqrtf(disc);
    immutable t0 = (-b - s) / (2.0f * a);
    immutable t1 = (-b + s) / (2.0f * a);
    float t = t0 >= 0 ? t0 : t1;
    if (t < 0 || t > 1) return false;
    outFraction = t;
    immutable hit = ray.getPointOnRay(t);
    outNormal = (hit - bodyPos).normalized;
    return true;
}

/// Ray vs oriented capsule (Y-aligned in local space).
bool rayVsCapsule(RRayCast ray, Vec3 bodyPos, Quat bodyRot,
                  float radius, float halfHeight,
                  ref float outFraction, ref Vec3 outNormal) {
    // Transform ray into body-local space then solve as Y-aligned capsule.
    immutable qInv  = bodyRot.conjugate;
    immutable o     = qInv.rotate(ray.origin - bodyPos);
    immutable d     = qInv.rotate(ray.direction);

    // Infinite-cylinder solve in XZ plane.
    immutable a = d.x * d.x + d.z * d.z;
    immutable b = 2.0f * (o.x * d.x + o.z * d.z);
    immutable c = o.x * o.x + o.z * o.z - radius * radius;
    float bestT = 2.0f;
    Vec3  bestLocalN = Vec3(0, 1, 0);

    if (a > 1e-8f) {
        immutable disc = b * b - 4.0f * a * c;
        if (disc >= 0) {
            immutable s = sqrtf(disc);
            immutable t0 = (-b - s) / (2.0f * a);
            immutable t1 = (-b + s) / (2.0f * a);
            foreach (float tc; [t0, t1]) {
                if (tc < 0 || tc > 1) continue;
                immutable hy = o.y + d.y * tc;
                if (hy >= -halfHeight && hy <= halfHeight) {
                    if (tc < bestT) {
                        bestT = tc;
                        immutable hx = o.x + d.x * tc;
                        immutable hz = o.z + d.z * tc;
                        bestLocalN = Vec3(hx, 0, hz).normalized;
                    }
                }
            }
        }
    }

    // End-cap spheres at ±halfHeight.
    foreach (float yCap; [-halfHeight, halfHeight]) {
        immutable oc = o - Vec3(0, yCap, 0);
        immutable aa = d.dot(d);
        if (aa < 1e-12f) continue;
        immutable bb = 2.0f * oc.dot(d);
        immutable cc = oc.dot(oc) - radius * radius;
        immutable disc = bb * bb - 4.0f * aa * cc;
        if (disc < 0) continue;
        immutable s = sqrtf(disc);
        immutable t0 = (-bb - s) / (2.0f * aa);
        immutable t1 = (-bb + s) / (2.0f * aa);
        float tc = t0 >= 0 ? t0 : t1;
        if (tc < 0 || tc > 1 || tc >= bestT) continue;
        bestT = tc;
        immutable hit = o + d * tc;
        bestLocalN = (hit - Vec3(0, yCap, 0)).normalized;
    }

    if (bestT > 1.0f) return false;
    outFraction = bestT;
    outNormal   = bodyRot.rotate(bestLocalN);
    return true;
}

/// Ray vs infinite plane (n · x = d).
bool rayVsPlane(RRayCast ray, Vec3 n, float d,
                ref float outFraction, ref Vec3 outNormal) {
    immutable denom = n.dot(ray.direction);
    if (fabsf(denom) < 1e-8f) return false;
    immutable t = (d - n.dot(ray.origin)) / denom;
    if (t < 0 || t > 1) return false;
    outFraction = t;
    outNormal   = denom < 0 ? n : n * -1.0f;
    return true;
}

/// Dispatches to the per-shape raycast. Returns true on hit with `outFraction`
/// in [0, 1] and `outNormal` in world space.
bool rayVsShape(RRayCast ray, Vec3 bodyPos, Quat bodyRot, Shape s,
                ref float outFraction, ref Vec3 outNormal) {
    final switch (s.kind) {
        case ShapeKind.sphere:
            return rayVsSphere(ray, bodyPos, s.sphere.radius, outFraction, outNormal);
        case ShapeKind.box:
            return rayVsBox(ray, bodyPos, bodyRot, s.box.halfExtents, outFraction, outNormal);
        case ShapeKind.capsule:
            return rayVsCapsule(ray, bodyPos, bodyRot,
                                s.capsule.radius, s.capsule.halfHeight,
                                outFraction, outNormal);
        case ShapeKind.staticPlane:
            return rayVsPlane(ray, s.plane.normal, s.plane.d, outFraction, outNormal);
        case ShapeKind.cylinder:
        case ShapeKind.convexHull:
            return false; // not in MVP
    }
}
