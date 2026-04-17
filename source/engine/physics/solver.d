// 
module engine.physics.solver;

import engine.math.vec;
import engine.math.mat3;
import engine.physics.types;
import std.math : abs, sqrt;

@safe:

struct SolverConfig {
    float restitution   = 0.15f;  // bounciness; 0 = fully inelastic
    float friction      = 0.6f;   // Coulomb coefficient
    float baumgarte     = 0.2f;   // positional correction strength
    float slop          = 0.01f;  // depth ignored for correction
    uint  iterations    = 8;      // sequential-impulse passes
}

// 
struct SolverBody {
    Vec3  position;       // read-only (for contact arms)
    Vec3  velocity;       // read-write
    Vec3  angularVel;     // read-write
    Mat3  invInertia;     // read-only (world-space)
    float invMass;        // read-only (0 = static)
}

private Vec3 crossV(Vec3 a, Vec3 b) {
    return Vec3(
        a.y * b.z - a.z * b.y,
        a.z * b.x - a.x * b.z,
        a.x * b.y - a.y * b.x,
    );
}

// 
void solveContact(ref SolverBody A, ref SolverBody B,
                  ref ContactManifold m, in SolverConfig cfg) {
    if (m.count == 0) return;

    foreach (pi; 0 .. m.count) {
        immutable cp = m.points[pi];
        immutable n  = cp.normal;
        immutable rA = cp.worldPos - A.position;
        immutable rB = cp.worldPos - B.position;

        // Relative velocity at contact.
        immutable vA = A.velocity + crossV(A.angularVel, rA);
        immutable vB = B.velocity + crossV(B.angularVel, rB);
        immutable relVel = vB - vA;
        immutable velAlongN = relVel.dot(n);

        // Effective mass along normal.
        immutable raxn = crossV(rA, n);
        immutable rbxn = crossV(rB, n);
        immutable invMassN = A.invMass + B.invMass
                           + raxn.dot(A.invInertia * raxn)
                           + rbxn.dot(B.invInertia * rbxn);
        if (invMassN <= 1e-12f) continue;

        // Baumgarte positional bias (bias velocity inward).
        immutable penetration = cp.depth - cfg.slop;
        immutable bias = penetration > 0 ? cfg.baumgarte * penetration * 60.0f : 0.0f;
        immutable restVel = velAlongN < 0 ? -cfg.restitution * velAlongN : 0.0f;

        float jN = (-(velAlongN) + bias + restVel) / invMassN;
        if (jN < 0) jN = 0;

        immutable impulseN = n * jN;
        A.velocity    = A.velocity    - impulseN * A.invMass;
        B.velocity    = B.velocity    + impulseN * B.invMass;
        A.angularVel  = A.angularVel  - A.invInertia * crossV(rA, impulseN);
        B.angularVel  = B.angularVel  + B.invInertia * crossV(rB, impulseN);

        // --- Friction: project relative velocity onto tangent plane ---
        immutable vA2 = A.velocity + crossV(A.angularVel, rA);
        immutable vB2 = B.velocity + crossV(B.angularVel, rB);
        immutable relV2 = vB2 - vA2;
        Vec3 tangent = relV2 - n * relV2.dot(n);
        immutable tLen = sqrt(tangent.dot(tangent));
        if (tLen < 1e-6f) continue;
        tangent = tangent * (1.0f / tLen);

        immutable rat = crossV(rA, tangent);
        immutable rbt = crossV(rB, tangent);
        immutable invMassT = A.invMass + B.invMass
                           + rat.dot(A.invInertia * rat)
                           + rbt.dot(B.invInertia * rbt);
        if (invMassT <= 1e-12f) continue;

        float jT = -relV2.dot(tangent) / invMassT;
        immutable maxFric = cfg.friction * jN;
        if (jT > maxFric) jT = maxFric;
        else if (jT < -maxFric) jT = -maxFric;

        immutable impulseT = tangent * jT;
        A.velocity    = A.velocity    - impulseT * A.invMass;
        B.velocity    = B.velocity    + impulseT * B.invMass;
        A.angularVel  = A.angularVel  - A.invInertia * crossV(rA, impulseT);
        B.angularVel  = B.angularVel  + B.invInertia * crossV(rB, impulseT);
    }
}
