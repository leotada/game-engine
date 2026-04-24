module engine.jph.physics.constraints.contact_constraint_manager;

import std.math : fabs;
import engine.jph.core.array : Array;
import engine.jph.math.vec3 : Vec3;
import engine.jph.physics.broadphase : BroadPhase;
import engine.jph.physics.body.body : Body;
import engine.jph.physics.body.body_manager : BodyManager;
import engine.jph.physics.body.bodyid : BodyID;
import engine.jph.physics.collision.collide_shape : ContactManifold;
import engine.jph.physics.constraints.contact_constraint : ContactConstraint;
import engine.jph.physics.constraints.contact_constraint_manager_cache : CachedManifold,
                                                                         ContactConstraintManagerCache;
import engine.jph.physics.physics_settings : PhysicsSettings;

@safe:

struct ContactConstraintManager {
@safe:
    private BodyManager* mBodyManager = null;
    private BroadPhase mBroadPhase;
    private Array!ContactConstraint mConstraints;
    private ContactConstraintManagerCache mCache;
    private float mPreviousStepDeltaTime = 0.0f;

    void Init(scope BodyManager* inBodyManager,
              BroadPhase inBroadPhase = null) @trusted nothrow @nogc {
        mBodyManager = inBodyManager;
        mBroadPhase = inBroadPhase;
        mConstraints.clear();
        mCache.Clear();
    }

    void Solve(const(ContactManifold)[] inManifolds,
               PhysicsSettings inSettings,
               float inDeltaTime) nothrow @nogc {
        if (mBodyManager is null || inManifolds.length == 0) {
            mConstraints.clear();
            mCache.Clear();
            return;
        }

        // Warm-start ratio: scale previous frame's impulses by dt_new/dt_old.
        // Prevents energy injection when dt varies between frames.
        // Ref: Jolt AxisConstraintPart.h:188, PhysicsSystem.cpp:165
        immutable float warmStartRatio = (mPreviousStepDeltaTime > 0.0f && inDeltaTime > 0.0f)
            ? inDeltaTime / mPreviousStepDeltaTime : 0.0f;
        mPreviousStepDeltaTime = inDeltaTime;

        buildConstraints(inManifolds, inSettings, inDeltaTime);
        warmStartConstraints(warmStartRatio);

        foreach (_; 0 .. inSettings.mNumVelocityIterations) {
            foreach (ref constraint; mConstraints[]) {
                auto vb1 = tryGetBody(constraint.mBody1ID);
                auto vb2 = tryGetBody(constraint.mBody2ID);
                if (vb1 !is null && vb2 !is null && vb1.IsDynamic() && vb2.IsDynamic())
                    solveDynamicContactVelocity(constraint);
                else
                    solveStaticContactVelocity(constraint);
            }
        }

        // Position solver: Baumgarte correction for residual penetration.
        // Runs AFTER the velocity solver so corrections don't interfere with
        // the impulse accumulation; uses SetPosition for static-dynamic and
        // proportional split for dynamic-dynamic.
        foreach (_; 0 .. inSettings.mNumPositionIterations) {
            foreach (ref constraint; mConstraints[]) {
                auto pb1 = tryGetBody(constraint.mBody1ID);
                auto pb2 = tryGetBody(constraint.mBody2ID);
                if (pb1 !is null && pb2 !is null && pb1.IsDynamic() && pb2.IsDynamic())
                    solveDynamicContactPosition(constraint, inSettings);
                else
                    solveStaticContactPosition(constraint, inSettings);
            }
        }

        mCache.StoreConstraints(mConstraints[]);
    }

    const(ContactConstraint)[] GetConstraints() const nothrow @nogc {
        return mConstraints[];
    }

    const(CachedManifold)[] GetCachedManifolds() const nothrow @nogc {
        return mCache.GetManifolds();
    }

    /// Returns true if the cache is sorted (i.e. safe for binary search).
    bool IsCacheSorted() const nothrow @nogc { return mCache.mSorted; }

    private void buildConstraints(const(ContactManifold)[] inManifolds,
                                   PhysicsSettings inSettings,
                                   float inDeltaTime) nothrow @nogc {
        // Snapshot previous frame's cache before clearing constraints.
        const(CachedManifold)[] prevCache = mCache.GetManifolds();
        mConstraints.clear();

        foreach (manifold; inManifolds) {
            // Sensor bodies generate manifolds for detection but do not
            // participate in the constraint solver — they are pass-through.
            auto sb1 = tryGetBody(manifold.mBody1ID);
            auto sb2 = tryGetBody(manifold.mBody2ID);
            if ((sb1 !is null && sb1.IsSensor()) || (sb2 !is null && sb2.IsSensor()))
                continue;

            ContactConstraint constraint;
            constraint.AssignFromManifold(manifold);
            // Load warm-start impulses from matching cached contact points.
            loadCachedLambdas(constraint, prevCache);

            // Baumgarte-in-velocity bias: adds a separating velocity proportional
            // to penetration depth so the velocity solver itself corrects sinking.
            // bias = max(0, pen - slop) * ERP / dt  (m/s separating velocity target)
            // This is how Jolt implements position correction — no separate
            // explicit position-correction pass is needed for small penetrations.
            foreach (i; 0 .. constraint.GetNumContactPoints()) {
                immutable float pen = constraint.mPoints[i].mPenetrationDepth;
                immutable float biasVel =
                    (pen > inSettings.mPenetrationSlop)
                    ? (pen - inSettings.mPenetrationSlop) * inSettings.mBaumgarteERP / inDeltaTime
                    : 0.0f;
                constraint.mPoints[i].mNormalPart.mBias = biasVel;
            }

            // Compute two stable friction tangents from the contact normal using
            // the "least axis" trick: pick the world axis most perpendicular to
            // the normal, cross to get tangent1, then cross(n, t1) for tangent2.
            // These tangents are deterministic regardless of body velocity, which
            // keeps mFrictionParts[*].mTotalLambda valid across solver iterations
            // and warm-startable between frames (the root cause of the tower
            // collapsing: old code recomputed tangent from velocity each
            // iteration so the cached lambda was for a different axis).
            {
                immutable Vec3 n = constraint.mWorldSpaceNormal;
                immutable float ax = n.GetX() < 0.0f ? -n.GetX() : n.GetX();
                immutable float ay = n.GetY() < 0.0f ? -n.GetY() : n.GetY();
                immutable float az = n.GetZ() < 0.0f ? -n.GetZ() : n.GetZ();
                // Choose world axis least aligned with n for numerical stability.
                Vec3 helper;
                if (ax <= ay && ax <= az)
                    helper = Vec3(1.0f, 0.0f, 0.0f);
                else if (ay <= az)
                    helper = Vec3(0.0f, 1.0f, 0.0f);
                else
                    helper = Vec3(0.0f, 0.0f, 1.0f);
                immutable Vec3 t1 = n.Cross(helper).Normalized();
                immutable Vec3 t2 = n.Cross(t1);  // already unit-length
                foreach (i; 0 .. constraint.GetNumContactPoints()) {
                    constraint.mPoints[i].mFrictionParts[0].mAxis = t1;
                    constraint.mPoints[i].mFrictionParts[1].mAxis = t2;
                }
            }

            mConstraints.push_back(constraint);
        }
    }

    // Finds the cached manifold for the same body pair and copies the
    // accumulated normal/friction lambdas into the new constraint's points.
    // Matching is by closest mPointOn1 within a 5 cm radius.
    // Cache lookup is O(log N) via binary search (cache is sorted by pair key).
    private static void loadCachedLambdas(ref ContactConstraint inConstraint,
                                          const(CachedManifold)[] inCache) nothrow @nogc {
        // Try canonical order first, then reversed.
        const(CachedManifold)* cached =
            ContactConstraintManagerCache.staticFindIn(
                inCache, inConstraint.mBody1ID, inConstraint.mBody2ID);
        bool reversed = false;
        if (cached is null) {
            cached = ContactConstraintManagerCache.staticFindIn(
                inCache, inConstraint.mBody2ID, inConstraint.mBody1ID);
            reversed = (cached !is null);
        }
        if (cached is null || cached.mNumContactPoints == 0)
            return;

        enum float kMatchDistSq = 0.05f * 0.05f; // 5 cm threshold (squared)
        foreach (i; 0 .. inConstraint.GetNumContactPoints()) {
            immutable Vec3 pt = inConstraint.mPoints[i].mPointOn1;
            uint  bestJ = uint.max;
            float bestD = float.max;
            foreach (j; 0 .. cached.mNumContactPoints) {
                // When reversed, the cached mPointOn1 belongs to body2 of the
                // new constraint, so match against mPointOn2 instead.
                immutable Vec3 cPt = reversed
                    ? cached.mPoints[j].mPointOn2
                    : cached.mPoints[j].mPointOn1;
                immutable float d = (pt - cPt).LengthSq();
                if (d < bestD) { bestD = d; bestJ = j; }
            }
            if (bestJ == uint.max || bestD > kMatchDistSq)
                continue;

            inConstraint.mPoints[i].mNormalPart.mTotalLambda =
                cached.mPoints[bestJ].mNormalLambda;
            // Carry over friction lambdas (axes will be recomputed from the
            // stable normal-derived tangents set in buildConstraints).
            inConstraint.mPoints[i].mFrictionParts[0].mTotalLambda =
                cached.mPoints[bestJ].mFrictionLambda[0];
            inConstraint.mPoints[i].mFrictionParts[1].mTotalLambda =
                cached.mPoints[bestJ].mFrictionLambda[1];
        }
    }

    // Pre-apply the warm-start normal impulse for every contact point whose
    // cached lambda is non-zero.  Scales the accumulated lambda by the
    // dt_new/dt_old ratio before applying so dt variation doesn't inject energy.
    // Ref: Jolt AxisConstraintPart.h:188 WarmStart(), PhysicsSystem.cpp:165
    private void warmStartConstraints(float inWarmStartRatio) nothrow @nogc {
        foreach (ref constraint; mConstraints[]) {
            auto body1 = tryGetBody(constraint.mBody1ID);
            auto body2 = tryGetBody(constraint.mBody2ID);
            if (body1 is null || body2 is null)
                continue;

            Body*  dynamicBody;
            Vec3   applyNormal;
            bool   usePoint1;
            if (body1.IsDynamic() && !body2.IsDynamic()) {
                dynamicBody = body1;
                applyNormal = constraint.mWorldSpaceNormal;
                usePoint1   = true;
            } else if (!body1.IsDynamic() && body2.IsDynamic()) {
                dynamicBody = body2;
                applyNormal = -constraint.mWorldSpaceNormal;
                usePoint1   = false;
            } else if (body1.IsDynamic() && body2.IsDynamic()) {
                // Dynamic-dynamic: warm-start both bodies with opposite half-impulses.
                auto motion1 = body1.GetMotionPropertiesUnchecked();
                auto motion2 = body2.GetMotionPropertiesUnchecked();
                if (motion1 is null || motion2 is null)
                    continue;
                immutable float invM1 = motion1.GetInverseMassUnchecked();
                immutable float invM2 = motion2.GetInverseMassUnchecked();
                foreach (ptIdx; 0 .. constraint.GetNumContactPoints()) {
                    immutable Vec3 r1 = constraint.mPoints[ptIdx].mPointOn1
                                      - body1.GetCenterOfMassPosition();
                    immutable Vec3 r2 = constraint.mPoints[ptIdx].mPointOn2
                                      - body2.GetCenterOfMassPosition();

                    // Normal warm-start.
                    immutable float lambdaN =
                        (constraint.mPoints[ptIdx].mNormalPart.mTotalLambda *= inWarmStartRatio);
                    if (lambdaN > 0.0f) {
                        immutable Vec3 nImp = constraint.mWorldSpaceNormal * lambdaN;
                        motion1.AddLinearVelocityStep( nImp * invM1);
                        motion1.AddAngularVelocityStep(
                            motion1.MultiplyWorldSpaceInverseInertiaByVector(
                                body1.GetRotation(), r1.Cross(nImp)));
                        motion2.AddLinearVelocityStep(-nImp * invM2);
                        motion2.AddAngularVelocityStep(
                            motion2.MultiplyWorldSpaceInverseInertiaByVector(
                                body2.GetRotation(), r2.Cross(-nImp)));
                    }

                    // Friction warm-start along the two stable tangent axes.
                    foreach (fi; 0 .. 2) {
                        immutable float lambdaF =
                            (constraint.mPoints[ptIdx].mFrictionParts[fi].mTotalLambda
                             *= inWarmStartRatio);
                        if (lambdaF == 0.0f) continue;
                        immutable Vec3 fAxis = constraint.mPoints[ptIdx].mFrictionParts[fi].mAxis;
                        immutable Vec3 fImp  = fAxis * lambdaF;
                        motion1.AddLinearVelocityStep( fImp * invM1);
                        motion1.AddAngularVelocityStep(
                            motion1.MultiplyWorldSpaceInverseInertiaByVector(
                                body1.GetRotation(), r1.Cross(fImp)));
                        motion2.AddLinearVelocityStep(-fImp * invM2);
                        motion2.AddAngularVelocityStep(
                            motion2.MultiplyWorldSpaceInverseInertiaByVector(
                                body2.GetRotation(), r2.Cross(-fImp)));
                    }
                }
                continue;
            } else {
                continue;
            }

            auto motion = dynamicBody.GetMotionPropertiesUnchecked();
            if (motion is null)
                continue;

            immutable float invMass = motion.GetInverseMassUnchecked();
            foreach (ptIdx; 0 .. constraint.GetNumContactPoints()) {
                immutable Vec3 ptWorld = usePoint1
                    ? constraint.mPoints[ptIdx].mPointOn1
                    : constraint.mPoints[ptIdx].mPointOn2;
                immutable Vec3 r = ptWorld - dynamicBody.GetCenterOfMassPosition();

                // Normal warm-start.
                immutable float lambdaN =
                    (constraint.mPoints[ptIdx].mNormalPart.mTotalLambda *= inWarmStartRatio);
                if (lambdaN > 0.0f) {
                    immutable Vec3 nImp = applyNormal * lambdaN;
                    motion.AddLinearVelocityStep(nImp * invMass);
                    motion.AddAngularVelocityStep(
                        motion.MultiplyWorldSpaceInverseInertiaByVector(
                            dynamicBody.GetRotation(), r.Cross(nImp)));
                }

                // Friction warm-start along the two stable tangent axes.
                foreach (fi; 0 .. 2) {
                    immutable float lambdaF =
                        (constraint.mPoints[ptIdx].mFrictionParts[fi].mTotalLambda
                         *= inWarmStartRatio);
                    if (lambdaF == 0.0f) continue;
                    // Friction direction is the same regardless of which body is
                    // dynamic (applyNormal is the negated form used for position,
                    // but friction axes are world-space and symmetric).
                    immutable Vec3 fAxis = constraint.mPoints[ptIdx].mFrictionParts[fi].mAxis;
                    immutable Vec3 fImp  = fAxis * lambdaF;
                    motion.AddLinearVelocityStep(fImp * invMass);
                    motion.AddAngularVelocityStep(
                        motion.MultiplyWorldSpaceInverseInertiaByVector(
                            dynamicBody.GetRotation(), r.Cross(fImp)));
                }
            }
        }
    }

    private Body* tryGetBody(BodyID inBodyID) nothrow @nogc {
        return mBodyManager is null ? null : mBodyManager.TryGetBody(inBodyID);
    }

    private void notifyBodyAABBChanged(BodyID inBodyID,
                                       Body* inBody) nothrow @nogc {
        if (mBroadPhase is null || inBody is null || !inBody.IsInBroadPhase())
            return;

        BodyID[1] bodyIDs = [inBodyID];
        mBroadPhase.NotifyBodiesAABBChanged(bodyIDs[]);
    }

    // Sequential-impulse velocity solver — one pass over all contact points.
    // Each point's impulse is applied immediately so subsequent points benefit
    // from the velocity change (Gauss-Seidel ordering).
    private void solveStaticContactVelocity(ref ContactConstraint inConstraint) nothrow @nogc {
        auto body1 = tryGetBody(inConstraint.mBody1ID);
        auto body2 = tryGetBody(inConstraint.mBody2ID);
        if (body1 is null || body2 is null)
            return;

        ContactConstraint constraint = inConstraint;
        auto dynamicBody = body1;
        auto staticBody  = body2;
        bool isReversed  = false;

        if (body1.IsStatic() && body2.IsDynamic()) {
            constraint    = inConstraint.Reversed();
            dynamicBody   = body2;
            staticBody    = body1;
            isReversed    = true;
        } else if (!body1.IsDynamic() || !body2.IsStatic()) {
            return;
        }

        auto motion = dynamicBody.GetMotionPropertiesUnchecked();
        if (motion is null || constraint.GetNumContactPoints() == 0)
            return;

        immutable Vec3  normal     = constraint.mWorldSpaceNormal;
        immutable float invMass    = motion.GetInverseMassUnchecked();
        immutable float restitution =
            0.5f * (dynamicBody.GetRestitution() + staticBody.GetRestitution());
        immutable float friction    =
            0.5f * (dynamicBody.GetFriction()    + staticBody.GetFriction());

        // Solve each contact point independently (sequential impulse).
        foreach (ptIdx; 0 .. constraint.GetNumContactPoints()) {
            immutable Vec3  ptWorld = constraint.mPoints[ptIdx].mPointOn1;
            immutable float ptDepth = constraint.mPoints[ptIdx].mPenetrationDepth;
            immutable Vec3  r       = ptWorld - dynamicBody.GetCenterOfMassPosition();

            // ---------------------------------------------------------------
            // Normal impulse
            // ---------------------------------------------------------------
            immutable Vec3  pointVelocity  = motion.GetPointVelocityCOM(r);
            immutable float normalVelocity = pointVelocity.Dot(normal);

            // Do NOT skip based on velocity direction here: warm-start may have
            // applied a large impulse from the previous frame's impact, giving
            // the body an outward velocity that must be walked back.  The clamp
            // (newLambdaN >= 0) and dLambdaN==0 guard below handle the truly
            // no-contact case with zero overhead.

            immutable Vec3 angN = motion.MultiplyWorldSpaceInverseInertiaByVector(
                dynamicBody.GetRotation(), r.Cross(normal));
            immutable float effMassN = invMass + angN.Cross(r).Dot(normal);
            if (effMassN <= 1.0e-6f)
                continue;

            // Retrieve per-point accumulated lambda (in original constraint index)
            immutable uint origIdx = isReversed
                ? ptIdx   // Reversed() keeps the same index order
                : ptIdx;
            immutable float oldLambdaN =
                inConstraint.mPoints[origIdx].mNormalPart.mTotalLambda;
            // bias = velocity target for penetration correction (Baumgarte-in-velocity).
            // Adds separating velocity proportional to remaining penetration.
            immutable float bias = inConstraint.mPoints[origIdx].mNormalPart.mBias;
            float newLambdaN = oldLambdaN +
                (-(1.0f + restitution) * normalVelocity + bias) / effMassN;
            if (newLambdaN < 0.0f)
                newLambdaN = 0.0f;
            immutable float dLambdaN = newLambdaN - oldLambdaN;
            if (dLambdaN == 0.0f)
                continue;

            inConstraint.mPoints[origIdx].mNormalPart.mAxis         = inConstraint.mWorldSpaceNormal;
            inConstraint.mPoints[origIdx].mNormalPart.mEffectiveMass = effMassN;
            inConstraint.mPoints[origIdx].mNormalPart.mTotalLambda  = newLambdaN;

            immutable Vec3 normalImpulse = normal * dLambdaN;
            motion.AddLinearVelocityStep(normalImpulse * invMass);
            motion.AddAngularVelocityStep(motion.MultiplyWorldSpaceInverseInertiaByVector(
                dynamicBody.GetRotation(), r.Cross(normalImpulse)));

            // ---------------------------------------------------------------
            // Friction impulse — two stable tangent axes, combined Coulomb cone
            // ---------------------------------------------------------------
            // Tangents were computed from the contact normal in buildConstraints
            // (least-axis trick). Using fixed axes keeps mTotalLambda meaningful
            // across iterations and frames; recomputing from velocity (old code)
            // made the cached lambda belong to a different axis each iteration.
            immutable Vec3 velAfterN = motion.GetPointVelocityCOM(r);
            immutable float maxFriction = friction * newLambdaN;

            // Read back old accumulated lambdas for both axes so we can apply
            // the combined Coulomb cone after solving each axis independently.
            float newLambdaT0 = inConstraint.mPoints[origIdx].mFrictionParts[0].mTotalLambda;
            float newLambdaT1 = inConstraint.mPoints[origIdx].mFrictionParts[1].mTotalLambda;

            foreach (fi; 0 .. 2) {
                immutable Vec3  t        = inConstraint.mPoints[origIdx].mFrictionParts[fi].mAxis;
                immutable Vec3  angT     = motion.MultiplyWorldSpaceInverseInertiaByVector(
                    dynamicBody.GetRotation(), r.Cross(t));
                immutable float effMassT = invMass + angT.Cross(r).Dot(t);
                if (effMassT <= 1.0e-6f) continue;

                immutable float oldLT = (fi == 0) ? newLambdaT0 : newLambdaT1;
                float newLT = oldLT - velAfterN.Dot(t) / effMassT;

                if (fi == 0) newLambdaT0 = newLT;
                else         newLambdaT1 = newLT;
            }

            // Combined Coulomb cone: sqrt(λ0² + λ1²) ≤ μ·λn
            {
                import core.stdc.math : sqrtf;
                immutable float mag = sqrtf(newLambdaT0 * newLambdaT0 + newLambdaT1 * newLambdaT1);
                if (mag > maxFriction && mag > 1.0e-8f) {
                    immutable float scale = maxFriction / mag;
                    newLambdaT0 *= scale;
                    newLambdaT1 *= scale;
                }
            }

            foreach (fi; 0 .. 2) {
                immutable Vec3  t    = inConstraint.mPoints[origIdx].mFrictionParts[fi].mAxis;
                immutable Vec3  angT = motion.MultiplyWorldSpaceInverseInertiaByVector(
                    dynamicBody.GetRotation(), r.Cross(t));
                immutable float effMassT = invMass + angT.Cross(r).Dot(t);
                if (effMassT <= 1.0e-6f) continue;

                immutable float oldLT   = inConstraint.mPoints[origIdx].mFrictionParts[fi].mTotalLambda;
                immutable float newLT   = (fi == 0) ? newLambdaT0 : newLambdaT1;
                immutable float dLambdaT = newLT - oldLT;

                inConstraint.mPoints[origIdx].mFrictionParts[fi].mEffectiveMass = effMassT;
                inConstraint.mPoints[origIdx].mFrictionParts[fi].mTotalLambda   = newLT;

                if (dLambdaT == 0.0f) continue;
                immutable Vec3 fImp = t * dLambdaT;
                motion.AddLinearVelocityStep(fImp * invMass);
                motion.AddAngularVelocityStep(motion.MultiplyWorldSpaceInverseInertiaByVector(
                    dynamicBody.GetRotation(), r.Cross(fImp)));
            }
        }
    }

    private void solveStaticContactPosition(ref ContactConstraint inConstraint,
                                            PhysicsSettings inSettings) nothrow @nogc {
        auto body1 = tryGetBody(inConstraint.mBody1ID);
        auto body2 = tryGetBody(inConstraint.mBody2ID);
        if (body1 is null || body2 is null)
            return;

        ContactConstraint constraint = inConstraint;
        auto dynamicBody = body1;

        if (body1.IsStatic() && body2.IsDynamic()) {
            constraint = inConstraint.Reversed();
            dynamicBody = body2;
        } else if (!body1.IsDynamic() || !body2.IsStatic()) {
            return;
        }

        float maxPenetration = 0.0f;
        foreach (index; 0 .. constraint.GetNumContactPoints()) {
            immutable penetration = constraint.GetContactPoint(index).mPenetrationDepth;
            if (penetration > maxPenetration)
                maxPenetration = penetration;
        }

        immutable float correction = (maxPenetration - inSettings.mPenetrationSlop) * inSettings.mBaumgarteERP;
        if (correction <= 0.0f)
            return;

        dynamicBody.SetPosition(dynamicBody.GetPosition() + constraint.mWorldSpaceNormal * correction);
        notifyBodyAABBChanged(dynamicBody.GetID(), dynamicBody);

        // Subtract the applied push-out from each contact point's stored
        // penetration depth so subsequent position iterations (and other
        // constraints in the same iteration that touch this body) see the
        // updated state instead of re-applying the same correction with
        // stale manifold data — the classic PGS over-correction bug.
        foreach (index; 0 .. inConstraint.GetNumContactPoints()) {
            inConstraint.mPoints[index].mPenetrationDepth -= correction;
        }

        auto motion = dynamicBody.GetMotionPropertiesUnchecked();
        if (motion !is null && fabs(motion.GetLinearVelocity().Dot(constraint.mWorldSpaceNormal)) < inSettings.mVelocitySleepThreshold) {
            motion.ApplyLinearVelocityStep(
                motion.GetLinearVelocity()
                - constraint.mWorldSpaceNormal * motion.GetLinearVelocity().Dot(constraint.mWorldSpaceNormal));
        }
    }

    // Sequential-impulse velocity solver for dynamic-dynamic pairs.
    // Both bodies move; effective mass includes both inverse masses and
    // both rotational inertias. Normal direction is body1's outward normal.
    private void solveDynamicContactVelocity(ref ContactConstraint inConstraint) nothrow @nogc {
        auto body1 = tryGetBody(inConstraint.mBody1ID);
        auto body2 = tryGetBody(inConstraint.mBody2ID);
        if (body1 is null || body2 is null || !body1.IsDynamic() || !body2.IsDynamic())
            return;

        auto motion1 = body1.GetMotionPropertiesUnchecked();
        auto motion2 = body2.GetMotionPropertiesUnchecked();
        if (motion1 is null || motion2 is null || inConstraint.GetNumContactPoints() == 0)
            return;

        immutable Vec3  normal      = inConstraint.mWorldSpaceNormal;
        immutable float invMass1    = motion1.GetInverseMassUnchecked();
        immutable float invMass2    = motion2.GetInverseMassUnchecked();
        immutable float restitution =
            0.5f * (body1.GetRestitution() + body2.GetRestitution());
        immutable float friction    =
            0.5f * (body1.GetFriction()    + body2.GetFriction());

        foreach (ptIdx; 0 .. inConstraint.GetNumContactPoints()) {
            immutable Vec3  pt1     = inConstraint.mPoints[ptIdx].mPointOn1;
            immutable Vec3  pt2     = inConstraint.mPoints[ptIdx].mPointOn2;
            immutable float ptDepth = inConstraint.mPoints[ptIdx].mPenetrationDepth;

            immutable Vec3 r1 = pt1 - body1.GetCenterOfMassPosition();
            immutable Vec3 r2 = pt2 - body2.GetCenterOfMassPosition();

            // Relative velocity at the contact point: v1 - v2
            immutable Vec3  vel1    = motion1.GetPointVelocityCOM(r1);
            immutable Vec3  vel2    = motion2.GetPointVelocityCOM(r2);
            immutable float normalVel = (vel1 - vel2).Dot(normal);

            // No velocity-based skip: warm-start overshoot must be corrected.
            // See static solver comment above for the full rationale.

            // Effective mass for normal direction
            immutable Vec3  angN1 = motion1.MultiplyWorldSpaceInverseInertiaByVector(
                body1.GetRotation(), r1.Cross(normal));
            immutable Vec3  angN2 = motion2.MultiplyWorldSpaceInverseInertiaByVector(
                body2.GetRotation(), r2.Cross(normal));
            immutable float effMassN =
                invMass1 + invMass2 + angN1.Cross(r1).Dot(normal) + angN2.Cross(r2).Dot(normal);
            if (effMassN <= 1.0e-6f)
                continue;

            immutable float oldLambdaN =
                inConstraint.mPoints[ptIdx].mNormalPart.mTotalLambda;
            // bias = velocity target for penetration correction (Baumgarte-in-velocity).
            immutable float bias = inConstraint.mPoints[ptIdx].mNormalPart.mBias;
            float newLambdaN = oldLambdaN +
                (-(1.0f + restitution) * normalVel + bias) / effMassN;
            if (newLambdaN < 0.0f)
                newLambdaN = 0.0f;
            immutable float dLambdaN = newLambdaN - oldLambdaN;
            if (dLambdaN == 0.0f)
                continue;

            inConstraint.mPoints[ptIdx].mNormalPart.mAxis          = normal;
            inConstraint.mPoints[ptIdx].mNormalPart.mEffectiveMass  = effMassN;
            inConstraint.mPoints[ptIdx].mNormalPart.mTotalLambda    = newLambdaN;

            immutable Vec3 nImpulse = normal * dLambdaN;
            motion1.AddLinearVelocityStep( nImpulse * invMass1);
            motion1.AddAngularVelocityStep(
                motion1.MultiplyWorldSpaceInverseInertiaByVector(
                    body1.GetRotation(), r1.Cross(nImpulse)));
            motion2.AddLinearVelocityStep(-nImpulse * invMass2);
            motion2.AddAngularVelocityStep(
                motion2.MultiplyWorldSpaceInverseInertiaByVector(
                    body2.GetRotation(), r2.Cross(-nImpulse)));

            // Friction — two stable tangent axes + combined Coulomb cone.
            // Axes were set in buildConstraints from the contact normal.
            immutable Vec3 vel1After   = motion1.GetPointVelocityCOM(r1);
            immutable Vec3 vel2After   = motion2.GetPointVelocityCOM(r2);
            immutable Vec3 relVelAfter = vel1After - vel2After;
            immutable float maxFriction = friction * newLambdaN;

            float newLambdaT0 = inConstraint.mPoints[ptIdx].mFrictionParts[0].mTotalLambda;
            float newLambdaT1 = inConstraint.mPoints[ptIdx].mFrictionParts[1].mTotalLambda;

            foreach (fi; 0 .. 2) {
                immutable Vec3 t = inConstraint.mPoints[ptIdx].mFrictionParts[fi].mAxis;
                immutable Vec3 angT1 = motion1.MultiplyWorldSpaceInverseInertiaByVector(
                    body1.GetRotation(), r1.Cross(t));
                immutable Vec3 angT2 = motion2.MultiplyWorldSpaceInverseInertiaByVector(
                    body2.GetRotation(), r2.Cross(t));
                immutable float effMassT =
                    invMass1 + invMass2 + angT1.Cross(r1).Dot(t) + angT2.Cross(r2).Dot(t);
                if (effMassT <= 1.0e-6f) continue;

                immutable float oldLT = (fi == 0) ? newLambdaT0 : newLambdaT1;
                float newLT = oldLT - relVelAfter.Dot(t) / effMassT;
                if (fi == 0) newLambdaT0 = newLT;
                else         newLambdaT1 = newLT;
            }

            // Combined Coulomb cone clamped to μ·λn
            {
                import core.stdc.math : sqrtf;
                immutable float mag = sqrtf(newLambdaT0 * newLambdaT0 + newLambdaT1 * newLambdaT1);
                if (mag > maxFriction && mag > 1.0e-8f) {
                    immutable float scale = maxFriction / mag;
                    newLambdaT0 *= scale;
                    newLambdaT1 *= scale;
                }
            }

            foreach (fi; 0 .. 2) {
                immutable Vec3 t = inConstraint.mPoints[ptIdx].mFrictionParts[fi].mAxis;
                immutable Vec3 angT1 = motion1.MultiplyWorldSpaceInverseInertiaByVector(
                    body1.GetRotation(), r1.Cross(t));
                immutable Vec3 angT2 = motion2.MultiplyWorldSpaceInverseInertiaByVector(
                    body2.GetRotation(), r2.Cross(t));
                immutable float effMassT =
                    invMass1 + invMass2 + angT1.Cross(r1).Dot(t) + angT2.Cross(r2).Dot(t);
                if (effMassT <= 1.0e-6f) continue;

                immutable float oldLT    = inConstraint.mPoints[ptIdx].mFrictionParts[fi].mTotalLambda;
                immutable float newLT    = (fi == 0) ? newLambdaT0 : newLambdaT1;
                immutable float dLambdaT = newLT - oldLT;

                inConstraint.mPoints[ptIdx].mFrictionParts[fi].mEffectiveMass = effMassT;
                inConstraint.mPoints[ptIdx].mFrictionParts[fi].mTotalLambda   = newLT;

                if (dLambdaT == 0.0f) continue;
                immutable Vec3 fImp = t * dLambdaT;
                motion1.AddLinearVelocityStep( fImp * invMass1);
                motion1.AddAngularVelocityStep(
                    motion1.MultiplyWorldSpaceInverseInertiaByVector(
                        body1.GetRotation(), r1.Cross(fImp)));
                motion2.AddLinearVelocityStep(-fImp * invMass2);
                motion2.AddAngularVelocityStep(
                    motion2.MultiplyWorldSpaceInverseInertiaByVector(
                        body2.GetRotation(), r2.Cross(-fImp)));
            }
        }
    }

    // Baumgarte position correction for dynamic-dynamic pairs.
    // The penetration is split proportional to each body's inverse mass so
    // heavier objects move less than lighter ones.
    private void solveDynamicContactPosition(ref ContactConstraint inConstraint,
                                             PhysicsSettings inSettings) nothrow @nogc {
        auto body1 = tryGetBody(inConstraint.mBody1ID);
        auto body2 = tryGetBody(inConstraint.mBody2ID);
        if (body1 is null || body2 is null || !body1.IsDynamic() || !body2.IsDynamic())
            return;

        auto motion1 = body1.GetMotionPropertiesUnchecked();
        auto motion2 = body2.GetMotionPropertiesUnchecked();
        if (motion1 is null || motion2 is null)
            return;

        float maxPenetration = 0.0f;
        foreach (index; 0 .. inConstraint.GetNumContactPoints()) {
            immutable float p = inConstraint.GetContactPoint(index).mPenetrationDepth;
            if (p > maxPenetration)
                maxPenetration = p;
        }

        immutable float correction =
            (maxPenetration - inSettings.mPenetrationSlop) * inSettings.mBaumgarteERP;
        if (correction <= 0.0f)
            return;

        immutable float invM1 = motion1.GetInverseMassUnchecked();
        immutable float invM2 = motion2.GetInverseMassUnchecked();
        immutable float totalInvM = invM1 + invM2;
        if (totalInvM <= 1.0e-6f)
            return;

        // Push body1 in +normal direction, body2 in -normal direction.
        immutable float ratio1 = invM1 / totalInvM;
        immutable float ratio2 = invM2 / totalInvM;
        body1.SetPosition(
            body1.GetPosition() + inConstraint.mWorldSpaceNormal * (correction * ratio1));
        notifyBodyAABBChanged(body1.GetID(), body1);
        body2.SetPosition(
            body2.GetPosition() - inConstraint.mWorldSpaceNormal * (correction * ratio2));
        notifyBodyAABBChanged(body2.GetID(), body2);

        // Decrement stored penetration depth so subsequent iterations see the
        // already-applied correction instead of compounding.
        foreach (index; 0 .. inConstraint.GetNumContactPoints()) {
            inConstraint.mPoints[index].mPenetrationDepth -= correction;
        }
    }
}