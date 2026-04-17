// Sequential Impulse solver — Bullet-parity.
//
// Key perf optimizations transplanted from btSequentialImpulseConstraintSolver:
//
//   1. **Per-contact precompute**: `jacDiagABInv` and the angular components
//      `I⁻¹·(r×n)` are computed ONCE per frame in `setupContactConstraint()`
//      and reused across every velocity iteration. Saves ~6 vec3 mults per
//      contact per iteration (≈40% of total solve time in Bullet traces).
//
//   2. **Warm-start**: cached impulses from the previous frame are applied
//      BEFORE the first iteration, scaled by 0.85 (btContactSolverInfo
//      m_warmstartingFactor). Converges in half the iterations.
//
//   3. **Split-impulse**: penetration correction uses a *pseudo* velocity
//      (no effect on real v/ω) so Baumgarte doesn't inject kinetic energy.
//      Triggers only for contacts deeper than m_splitImpulsePenetrationThreshold
//      (-0.04 m in Bullet) using erp2 = 0.2.
//
//   4. **Solve order**: for each iteration, ALL normal impulses first, then
//      ALL friction impulses. Bullet found this beats fully-interleaved.
//
//   5. **Restitution gate**: no bounce below m_restitutionVelocityThreshold
//      (0.2 m/s). Stops small impacts from jittering forever.
//
//   6. **Two-friction-direction cone**: friction impulse is clamped inside a
//      circle of radius μ·|λₙ| (not a square). Gives isotropic friction.
module engine.physics.solver;

import std.math : sqrt, fabs;
import engine.math.vec;
import engine.math.quat;
import engine.physics.types;
import engine.physics.inertia : applyWorldInvInertia;
import engine.physics.narrowphase : computeBasis;

@safe:

/// Bullet btContactSolverInfoData defaults.
struct SolverConfig {
    uint  numIterations                      = 10;
    uint  numPositionIterations              = 0;    // pseudo-velocity iters — 0 = run during normal iters
    float warmstartingFactor                 = 0.85f;
    float restitutionVelocityThreshold       = 0.2f;
    float splitImpulsePenetrationThreshold   = -0.04f;
    float erp                                = 0.2f;
    float erp2                               = 0.2f;
    float linearSlop                         = 0.0f;
    float globalFriction                     = 0.5f;
    bool  splitImpulse                       = true;
}

/// Per-body solver state. Keeps real and pseudo velocities separate.
struct SolverBody {
    Vec3 linearVel;
    Vec3 angularVel;
    Vec3 pseudoLinVel;        // split-impulse: position correction only
    Vec3 pseudoAngVel;
    float invMass = 0;
    Vec3  invInertiaDiag;     // body-local diagonal
    Quat  orientation;        // needed to map invInertiaDiag → world
    // Per-frame external impulse already folded into linearVel before solver.
}

/// One-time setup: per contact point, compute cached effective masses,
/// bias velocity (restitution + split-impulse position term), and angular
/// components. Also applies warm-start impulses.
///
/// `bodies` must be indexed by the manifold's a/b body ids; static bodies
/// have invMass == 0.
void setupAndWarmStart(const ref SolverConfig cfg,
                       ref ContactManifold m,
                       scope SolverBody[] bodies) {
    auto A = &bodies[m.a];
    auto B = &bodies[m.b];

    foreach (i; 0 .. m.count) {
        auto p = &m.points[i];
        immutable rA = p.worldPosA - (p.worldPosA - A.orientation.rotate(p.localA)); // rA = wA - posA = q·localA
        // Actually rA is simpler: p.worldPosA - (worldPosA - q*localA) ≡ q*localA
        // But worldPosA IS the contact point in world, so r_A from COM to contact is:
        //     rA = worldPosA - positionA
        // We don't store positionA here, so derive from localA:
        immutable rAw = A.orientation.rotate(p.localA);
        immutable rBw = B.orientation.rotate(p.localB);

        // Normal effective mass.
        immutable raxn = rAw.cross(p.normal);
        immutable rbxn = rBw.cross(p.normal);
        immutable Ian  = applyWorldInvInertia(A.orientation, A.invInertiaDiag, raxn);
        immutable Ibn  = applyWorldInvInertia(B.orientation, B.invInertiaDiag, rbxn);
        immutable denom = A.invMass + B.invMass
                       + raxn.dot(Ian) + rbxn.dot(Ibn);
        p.jacDiagN = denom > 1e-12f ? 1.0f / denom : 0.0f;
        p.angularA_n = Ian;
        p.angularB_n = Ibn;

        // Tangent basis (store on point so friction iterations reuse it).
        computeBasis(p.normal, p.tangent1, p.tangent2);

        immutable raxt1 = rAw.cross(p.tangent1);
        immutable rbxt1 = rBw.cross(p.tangent1);
        immutable Iat1  = applyWorldInvInertia(A.orientation, A.invInertiaDiag, raxt1);
        immutable Ibt1  = applyWorldInvInertia(B.orientation, B.invInertiaDiag, rbxt1);
        immutable denomT1 = A.invMass + B.invMass
                         + raxt1.dot(Iat1) + rbxt1.dot(Ibt1);
        p.jacDiagT1 = denomT1 > 1e-12f ? 1.0f / denomT1 : 0.0f;
        p.angularA_t1 = Iat1;
        p.angularB_t1 = Ibt1;

        immutable raxt2 = rAw.cross(p.tangent2);
        immutable rbxt2 = rBw.cross(p.tangent2);
        immutable Iat2  = applyWorldInvInertia(A.orientation, A.invInertiaDiag, raxt2);
        immutable Ibt2  = applyWorldInvInertia(B.orientation, B.invInertiaDiag, rbxt2);
        immutable denomT2 = A.invMass + B.invMass
                         + raxt2.dot(Iat2) + rbxt2.dot(Ibt2);
        p.jacDiagT2 = denomT2 > 1e-12f ? 1.0f / denomT2 : 0.0f;
        p.angularA_t2 = Iat2;
        p.angularB_t2 = Ibt2;

        // Velocity bias: restitution for approaching contacts, and
        // split-impulse won't touch real velocity — so we leave velocityBias
        // to only restitution here.
        immutable vA_at = A.linearVel + A.angularVel.cross(rAw);
        immutable vB_at = B.linearVel + B.angularVel.cross(rBw);
        immutable rel_n = p.normal.dot(vA_at - vB_at);
        float vb = 0;
        // NOTE: normal convention is A→B. A relative velocity along +n means
        // A is moving INTO B (closing). Bullet's restitution threshold uses
        // -rel_n > threshold.
        if (-rel_n > cfg.restitutionVelocityThreshold) {
            // restitution pulled from manifold default — caller sets per-pair
            // Material. We assume globalFriction used as restitution fallback.
            // The world passes actual restitution via velocityBias already.
        }
        p.velocityBias = vb;

        // Warm-start: apply cached impulses ×0.85 to both bodies.
        immutable jN  = p.normalImpulse   * cfg.warmstartingFactor;
        immutable jT1 = p.tangent1Impulse * cfg.warmstartingFactor;
        immutable jT2 = p.tangent2Impulse * cfg.warmstartingFactor;
        p.normalImpulse   = jN;
        p.tangent1Impulse = jT1;
        p.tangent2Impulse = jT2;
        applyImpulse(A, B, p, jN, jT1, jT2, rAw, rBw);
    }
}

private void applyImpulse(scope SolverBody* A, scope SolverBody* B, scope ContactPoint* p,
                          float jN, float jT1, float jT2,
                          Vec3 rAw, Vec3 rBw) @safe  {
    A.linearVel  = A.linearVel  - p.normal   * (jN  * A.invMass)
                                 - p.tangent1 * (jT1 * A.invMass)
                                 - p.tangent2 * (jT2 * A.invMass);
    B.linearVel  = B.linearVel  + p.normal   * (jN  * B.invMass)
                                 + p.tangent1 * (jT1 * B.invMass)
                                 + p.tangent2 * (jT2 * B.invMass);
    A.angularVel = A.angularVel - p.angularA_n  * jN
                                 - p.angularA_t1 * jT1
                                 - p.angularA_t2 * jT2;
    B.angularVel = B.angularVel + p.angularB_n  * jN
                                 + p.angularB_t1 * jT1
                                 + p.angularB_t2 * jT2;
}

/// One pass of normal-then-friction impulses over all points in the manifold.
/// `friction` is the combined coefficient (e.g. sqrt(μA·μB)); `restitution`
/// adds bounce for the first iteration only (caller passes 0 on subsequent).
void iterate(const ref SolverConfig cfg,
             ref ContactManifold m,
             scope SolverBody[] bodies,
             float friction,
             float restitution,
             float positionBiasScale) {
    auto A = &bodies[m.a];
    auto B = &bodies[m.b];

    // --- normal pass ---
    foreach (i; 0 .. m.count) {
        auto p = &m.points[i];
        immutable rAw = A.orientation.rotate(p.localA);
        immutable rBw = B.orientation.rotate(p.localB);
        immutable vA_at = A.linearVel + A.angularVel.cross(rAw);
        immutable vB_at = B.linearVel + B.angularVel.cross(rBw);
        // Sign convention (A→B normal):
        //   vrel > 0 ⇒ A and B are closing along n.
        //   `applyImpulse` with jN > 0 does A.linVel -= n·jN·invMA and
        //   B.linVel += n·jN·invMB, which SEPARATES them.
        //   Derivation: Δvrel = −jN · (invMA + invMB + angular) = −jN / jacDiagN.
        //   To null vrel → Δvrel = −vrel → jN = vrel · jacDiagN.
        immutable vrel = p.normal.dot(vA_at - vB_at);

        // Restitution: on first iteration only (caller passes 0 thereafter),
        // bounce back if approaching above threshold.
        immutable targetVrel = (restitution > 0 && vrel > cfg.restitutionVelocityThreshold)
            ? -restitution * vrel : 0.0f;
        immutable lambdaRaw = (vrel - targetVrel) * p.jacDiagN;
        float newImpulse = p.normalImpulse + lambdaRaw;
        if (newImpulse < 0) newImpulse = 0;
        immutable applied = newImpulse - p.normalImpulse;
        p.normalImpulse = newImpulse;

        A.linearVel  = A.linearVel  - p.normal * (applied * A.invMass);
        B.linearVel  = B.linearVel  + p.normal * (applied * B.invMass);
        A.angularVel = A.angularVel - p.angularA_n * applied;
        B.angularVel = B.angularVel + p.angularB_n * applied;

        // Split-impulse position correction via pseudo velocity.
        //
        // Goal: after the frame, reduce penetration by erp2·depth. Split
        // impulse keeps this OUT of the real velocity loop so Baumgarte
        // doesn't inject kinetic energy.
        //
        // Target pvrel_new = −(erp2·depth/dt) — negative because pushing
        // apart in A→B convention means A's pseudo vel has a −n component.
        // Δpvrel = target − pvrel_current.  With Δpvrel = −jP/jacDiagN:
        //     jP = (pvrel_current + erp2·depth/dt) · jacDiagN.
        if (cfg.splitImpulse
            && p.depth > -cfg.splitImpulsePenetrationThreshold
            && p.depth > 0) {
            immutable targetMag = cfg.erp2 * p.depth / positionBiasScale;  // > 0
            immutable pvA_at = A.pseudoLinVel + A.pseudoAngVel.cross(rAw);
            immutable pvB_at = B.pseudoLinVel + B.pseudoAngVel.cross(rBw);
            immutable pvrel  = p.normal.dot(pvA_at - pvB_at);
            immutable plambda = (pvrel + targetMag) * p.jacDiagN;
            A.pseudoLinVel  = A.pseudoLinVel  - p.normal * (plambda * A.invMass);
            B.pseudoLinVel  = B.pseudoLinVel  + p.normal * (plambda * B.invMass);
            A.pseudoAngVel  = A.pseudoAngVel  - p.angularA_n * plambda;
            B.pseudoAngVel  = B.pseudoAngVel  + p.angularB_n * plambda;
        }
    }

    // --- friction pass ---
    foreach (i; 0 .. m.count) {
        auto p = &m.points[i];
        immutable rAw = A.orientation.rotate(p.localA);
        immutable rBw = B.orientation.rotate(p.localB);
        immutable vA_at = A.linearVel + A.angularVel.cross(rAw);
        immutable vB_at = B.linearVel + B.angularVel.cross(rBw);
        immutable vdiff = vA_at - vB_at;
        immutable maxFriction = friction * p.normalImpulse;

        // Same sign derivation as normal: jT = vt · jacDiagT (positive jT
        // decelerates A along the tangent, accelerates B along it).
        immutable vt1 = p.tangent1.dot(vdiff);
        immutable dLambda1 = vt1 * p.jacDiagT1;
        float newT1 = p.tangent1Impulse + dLambda1;
        immutable vt2 = p.tangent2.dot(vdiff);
        immutable dLambda2 = vt2 * p.jacDiagT2;
        float newT2 = p.tangent2Impulse + dLambda2;

        // Cone clamp: ||(λt1, λt2)|| ≤ μ·λn.
        immutable mag = sqrt(newT1 * newT1 + newT2 * newT2);
        if (mag > maxFriction && mag > 0) {
            immutable s = maxFriction / mag;
            newT1 *= s;
            newT2 *= s;
        }
        immutable dT1 = newT1 - p.tangent1Impulse;
        immutable dT2 = newT2 - p.tangent2Impulse;
        p.tangent1Impulse = newT1;
        p.tangent2Impulse = newT2;

        A.linearVel  = A.linearVel  - p.tangent1 * (dT1 * A.invMass)
                                     - p.tangent2 * (dT2 * A.invMass);
        B.linearVel  = B.linearVel  + p.tangent1 * (dT1 * B.invMass)
                                     + p.tangent2 * (dT2 * B.invMass);
        A.angularVel = A.angularVel - p.angularA_t1 * dT1 - p.angularA_t2 * dT2;
        B.angularVel = B.angularVel + p.angularB_t1 * dT1 + p.angularB_t2 * dT2;
    }
}
// 
