// 
module engine.physics.types;

import engine.math.vec;

@safe:

alias RigidBodyId = uint;
enum RigidBodyId INVALID_BODY = RigidBodyId.max;

enum ShapeKind : ubyte { box, capsule }

struct BoxShape {
    Vec3 halfExtents = Vec3(0.5f, 0.5f, 0.5f);
}

// 
struct CapsuleShape {
    float radius     = 0.5f;
    float halfHeight = 0.5f;
}

// 
struct Shape {
    ShapeKind kind = ShapeKind.box;
    union {
        BoxShape     box;
        CapsuleShape capsule;
    }

    static Shape makeBox(Vec3 halfExtents) {
        Shape s;
        s.kind = ShapeKind.box;
        s.box  = BoxShape(halfExtents);
        return s;
    }

    static Shape makeCapsule(float radius, float halfHeight) {
        Shape s;
        s.kind = ShapeKind.capsule;
        s.capsule = CapsuleShape(radius, halfHeight);
        return s;
    }
}

struct ContactPoint {
    Vec3  worldPos;
    Vec3  normal;     // from body A to body B
    float depth = 0;  // positive penetration
}

// 
struct ContactManifold {
    RigidBodyId     a = INVALID_BODY;
    RigidBodyId     b = INVALID_BODY;
    ContactPoint[4] points;
    ubyte           count = 0;
}

// 
struct Aabb {
    Vec3 min;
    Vec3 max;

    bool overlaps(Aabb o) const {
        return !(max.x < o.min.x || min.x > o.max.x ||
                 max.y < o.min.y || min.y > o.max.y ||
                 max.z < o.min.z || min.z > o.max.z);
    }

    static Aabb expand(Aabb a, float m) {
        return Aabb(
            Vec3(a.min.x - m, a.min.y - m, a.min.z - m),
            Vec3(a.max.x + m, a.max.y + m, a.max.z + m),
        );
    }
}
