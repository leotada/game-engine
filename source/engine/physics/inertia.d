// Closed-form inverse inertia tensors per shape (body-local, diagonal).
// The solver only needs `I_world^{-1} · v`. Keeping the body tensor as a
// diagonal Vec3 and doing q.rotate(diag * q.conjugate.rotate(v)) avoids
// materializing a 3×3 world tensor every frame.
module engine.physics.inertia;

import engine.math.vec;
import engine.math.quat;
import engine.physics.types;

@safe:

Vec3 bodyInverseInertiaDiagonal(const Shape shape, float mass) {
    if (mass <= 0) return Vec3(0, 0, 0);

    final switch (shape.kind) {
        case ShapeKind.sphere: {
            immutable r = shape.sphere.radius;
            immutable I = 0.4f * mass * r * r;
            return Vec3(1.0f / I, 1.0f / I, 1.0f / I);
        }
        case ShapeKind.box: {
            immutable h  = shape.box.halfExtents;
            immutable x2 = 4.0f * h.x * h.x;
            immutable y2 = 4.0f * h.y * h.y;
            immutable z2 = 4.0f * h.z * h.z;
            immutable k  = mass / 12.0f;
            return Vec3(1.0f / (k * (y2 + z2)),
                        1.0f / (k * (x2 + z2)),
                        1.0f / (k * (x2 + y2)));
        }
        case ShapeKind.capsule: {
            immutable r  = shape.capsule.radius;
            immutable hh = shape.capsule.halfHeight;
            immutable Iy = 0.5f * mass * r * r;
            immutable Ix = mass * (0.25f * r * r + (hh * hh) / 3.0f);
            return Vec3(1.0f / Ix, 1.0f / Iy, 1.0f / Ix);
        }
        case ShapeKind.cylinder: {
            immutable h  = shape.cylinder.halfExtents;
            immutable r  = h.x;
            immutable hy = h.y;
            immutable Iy = 0.5f * mass * r * r;
            immutable Ix = mass * (0.25f * r * r + (hy * hy) / 3.0f);
            return Vec3(1.0f / Ix, 1.0f / Iy, 1.0f / Ix);
        }
        case ShapeKind.staticPlane:
        case ShapeKind.convexHull:
            return Vec3(0, 0, 0);
    }
}

/// Apply `I_world^{-1} · v` via the body-local diagonal and the rotation.
Vec3 applyWorldInvInertia(Quat q, Vec3 invIbodyDiag, Vec3 v) {
    immutable vBody = q.conjugate().rotate(v);
    immutable prod  = Vec3(invIbodyDiag.x * vBody.x,
                           invIbodyDiag.y * vBody.y,
                           invIbodyDiag.z * vBody.z);
    return q.rotate(prod);
}
// Closed-form inverse inertia tensors per shape (body-local, diagonal).
// Bullet computes these via btCollisionShape::calculateLocalInertia; we
// inline the analytic forms for each primitive.
