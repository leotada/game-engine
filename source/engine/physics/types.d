// Physics types — Bullet-inspired. Shape is a tagged union of POD data only
// (no GC pointers / indirections). Convex hulls reference a world-owned bank
// via a numeric index so Shape stays trivially copyable and component-safe.
module engine.physics.types;

import engine.math.vec;
import engine.math.quat;

@safe:

alias RigidBodyId = uint;
enum RigidBodyId INVALID_BODY = RigidBodyId.max;

/// Bullet's default btPersistentManifold::gContactBreakingThreshold.
enum float CONTACT_BREAKING_THRESHOLD = 0.02f;
/// btPersistentManifold keeps up to 4 points per pair.
enum uint MANIFOLD_CACHE_SIZE = 4;

enum ShapeKind : ubyte {
    sphere,
    box,
    capsule,
    cylinder,
    staticPlane,
    convexHull,
}

struct SphereShape   { float radius = 0.5f; }
struct BoxShape      { Vec3  halfExtents = Vec3(0.5f, 0.5f, 0.5f); }
struct CapsuleShape  { float radius = 0.5f; float halfHeight = 0.5f; }
struct CylinderShape { Vec3  halfExtents = Vec3(0.5f, 0.5f, 0.5f); } // Y-aligned
struct PlaneShape    { Vec3  normal = Vec3(0, 1, 0); float d = 0; }
struct ConvexHullRef { uint  bankIdx; }

struct Shape {
    ShapeKind kind = ShapeKind.box;
    union {
        SphereShape   sphere;
        BoxShape      box;
        CapsuleShape  capsule;
        CylinderShape cylinder;
        PlaneShape    plane;
        ConvexHullRef hull;
    }

    static Shape makeSphere(float r)                   { Shape s; s.kind = ShapeKind.sphere;      s.sphere   = SphereShape(r);        return s; }
    static Shape makeBox(Vec3 h)                       { Shape s; s.kind = ShapeKind.box;         s.box      = BoxShape(h);           return s; }
    static Shape makeCapsule(float r, float hh)        { Shape s; s.kind = ShapeKind.capsule;     s.capsule  = CapsuleShape(r, hh);   return s; }
    static Shape makeCylinder(Vec3 h)                  { Shape s; s.kind = ShapeKind.cylinder;    s.cylinder = CylinderShape(h);      return s; }
    static Shape makePlane(Vec3 n, float d)            { Shape s; s.kind = ShapeKind.staticPlane; s.plane    = PlaneShape(n, d);      return s; }
    static Shape makeConvexHull(uint bankIdx)          { Shape s; s.kind = ShapeKind.convexHull;  s.hull     = ConvexHullRef(bankIdx); return s; }
}

/// Bullet: friction combined sqrt(a*b); restitution combined with max.
struct Material {
    float friction        = 0.5f;
    float restitution     = 0.0f;
    float linearDamping   = 0.04f;   // Bullet default
    float angularDamping  = 0.1f;    // Bullet default
}

/// A single contact point. Stores both world- and local-space anchors so we
/// can re-project every frame (Bullet btPersistentManifold::refreshContactPoints)
/// and preserves cached impulses for warm-starting.
struct ContactPoint {
    Vec3  worldPosA;         // contact on body A (world)
    Vec3  worldPosB;         // contact on body B (world)
    Vec3  localA;            // same point in body A's local frame
    Vec3  localB;            // same point in body B's local frame
    Vec3  normal;            // A → B (unit)
    float depth            = 0;
    // Warm-started impulses (Bullet m_appliedImpulse, m_appliedImpulseLateral1/2).
    float normalImpulse    = 0;
    float tangent1Impulse  = 0;
    float tangent2Impulse  = 0;
    // Per-point solver cache (Bullet setupContactConstraint). Computed once
    // per frame, reused across every velocity iteration.
    float jacDiagN         = 0;
    float jacDiagT1        = 0;
    float jacDiagT2        = 0;
    Vec3  tangent1, tangent2;
    Vec3  angularA_n,  angularB_n;
    Vec3  angularA_t1, angularB_t1;
    Vec3  angularA_t2, angularB_t2;
    // Velocity bias (restitution + split-impulse position term).
    float velocityBias     = 0;
}

/// Persistent manifold — reused across frames, warm-starts the solver.
struct ContactManifold {
    RigidBodyId a = INVALID_BODY;
    RigidBodyId b = INVALID_BODY;
    ContactPoint[MANIFOLD_CACHE_SIZE] points;
    ubyte count           = 0;
    ubyte framesAlive     = 0;
    ubyte framesSinceUse  = 255;  // 255 = free slot
}

struct Aabb {
    Vec3 min = Vec3(0, 0, 0);
    Vec3 max = Vec3(0, 0, 0);

    bool overlaps(const Aabb o) const {
        return !(max.x < o.min.x || min.x > o.max.x ||
                 max.y < o.min.y || min.y > o.max.y ||
                 max.z < o.min.z || min.z > o.max.z);
    }

    /// Bullet btDbvtVolume::Contain — does `this` fully include `o`?
    bool contains(const Aabb o) const {
        return min.x <= o.min.x && max.x >= o.max.x
            && min.y <= o.min.y && max.y >= o.max.y
            && min.z <= o.min.z && max.z >= o.max.z;
    }

    Aabb merged(const Aabb o) const {
        Aabb r;
        r.min = Vec3(min.x < o.min.x ? min.x : o.min.x,
                     min.y < o.min.y ? min.y : o.min.y,
                     min.z < o.min.z ? min.z : o.min.z);
        r.max = Vec3(max.x > o.max.x ? max.x : o.max.x,
                     max.y > o.max.y ? max.y : o.max.y,
                     max.z > o.max.z ? max.z : o.max.z);
        return r;
    }

    /// Bullet btDbvtVolume::Expand — grow by constant margin on all sides.
    Aabb expanded(float m) const {
        return Aabb(Vec3(min.x - m, min.y - m, min.z - m),
                    Vec3(max.x + m, max.y + m, max.z + m));
    }

    /// Bullet btDbvtVolume::SignedExpand — extend by velocity in its sign
    /// direction only. Keeps the fat AABB tight against backwards motion.
    Aabb signedExpanded(Vec3 v) const {
        Aabb r = this;
        if (v.x > 0) r.max.x += v.x; else r.min.x += v.x;
        if (v.y > 0) r.max.y += v.y; else r.min.y += v.y;
        if (v.z > 0) r.max.z += v.z; else r.min.z += v.z;
        return r;
    }

    float surfaceArea() const {
        immutable dx = max.x - min.x, dy = max.y - min.y, dz = max.z - min.z;
        return 2.0f * (dx * dy + dy * dz + dz * dx);
    }

    Vec3 center() const { return (min + max) * 0.5f; }
}

struct RayHit {
    bool        hit    = false;
    float       t      = 0;
    Vec3        point;
    Vec3        normal;
    RigidBodyId body_  = INVALID_BODY;
}

struct PhysicsStats {
    uint bodyCount;
    uint activeBodies;
    uint sleepingBodies;
    uint islandCount;
    uint manifoldCount;
    uint broadphasePairs;
    uint dbvtNodes;
}
// 
