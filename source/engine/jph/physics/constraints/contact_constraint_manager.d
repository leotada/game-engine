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

    void Init(scope BodyManager* inBodyManager,
              BroadPhase inBroadPhase = null) @trusted nothrow @nogc {
        mBodyManager = inBodyManager;
        mBroadPhase = inBroadPhase;
        mConstraints.clear();
        mCache.Clear();
    }

    void Solve(const(ContactManifold)[] inManifolds,
               PhysicsSettings inSettings) nothrow @nogc {
        if (mBodyManager is null || inManifolds.length == 0) {
            mConstraints.clear();
            mCache.Clear();
            return;
        }

        buildConstraints(inManifolds);
        warmStartConstraints();

        foreach (_; 0 .. inSettings.mNumVelocityIterations) {
            foreach (ref constraint; mConstraints[])
                solveStaticContactVelocity(constraint);
        }

        foreach (_; 0 .. inSettings.mNumPositionIterations) {
            foreach (ref constraint; mConstraints[])
                solveStaticContactPosition(constraint, inSettings);
        }

        mCache.StoreConstraints(mConstraints[]);
    }

    const(ContactConstraint)[] GetConstraints() const nothrow @nogc {
        return mConstraints[];
    }

    const(CachedManifold)[] GetCachedManifolds() const nothrow @nogc {
        return mCache.GetManifolds();
    }

    private void buildConstraints(const(ContactManifold)[] inManifolds) nothrow @nogc {
        // Snapshot previous frame's cache before clearing constraints.
        const(CachedManifold)[] prevCache = mCache.GetManifolds();
        mConstraints.clear();

        foreach (manifold; inManifolds) {
            ContactConstraint constraint;
            constraint.AssignFromManifold(manifold);
            // Phase 2.2: load impulses from matching cached contact points.
            loadCachedLambdas(constraint, prevCache);
            mConstraints.push_back(constraint);
        }
    }

    // Finds the cached manifold for the same body pair and copies the
    // accumulated normal/friction lambdas into the new constraint's points.
    // Matching is by closest mPointOn1 within a 5 cm radius.
    private static void loadCachedLambdas(ref ContactConstraint inConstraint,
                                          const(CachedManifold)[] inCache) nothrow @nogc {
        const(CachedManifold)* cached = null;
        bool reversed = false;
        foreach (ref cm; inCache) {
            if (cm.mBody1ID == inConstraint.mBody1ID &&
                cm.mBody2ID == inConstraint.mBody2ID) {
                cached = &cm;
                break;
            }
            if (cm.mBody1ID == inConstraint.mBody2ID &&
                cm.mBody2ID == inConstraint.mBody1ID) {
                cached   = &cm;
                reversed = true;
                break;
            }
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
        }
    }

    // Phase 2.3: pre-apply the warm-start normal impulse for every contact
    // point whose cached lambda is non-zero.  This seeds the velocity so the
    // iterative solver needs far fewer iterations to converge.
    private void warmStartConstraints() nothrow @nogc {
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
            } else {
                continue;
            }

            auto motion = dynamicBody.GetMotionPropertiesUnchecked();
            if (motion is null)
                continue;

            immutable float invMass = motion.GetInverseMassUnchecked();
            foreach (ptIdx; 0 .. constraint.GetNumContactPoints()) {
                immutable float lambdaN =
                    constraint.mPoints[ptIdx].mNormalPart.mTotalLambda;
                if (lambdaN <= 0.0f)
                    continue;

                // Apply the full cached impulse as a velocity seed and keep
                // mTotalLambda at the cached value so the solver knows what
                // was already applied and can REDUCE it if the warm-start
                // overshot (e.g. on the frame after a large impact).
                // The solver's negative-delta path handles any overshoot.

                immutable Vec3 ptWorld = usePoint1
                    ? constraint.mPoints[ptIdx].mPointOn1
                    : constraint.mPoints[ptIdx].mPointOn2;
                immutable Vec3 r = ptWorld - dynamicBody.GetCenterOfMassPosition();
                immutable Vec3 impulse = applyNormal * lambdaN;
                motion.AddLinearVelocityStep(impulse * invMass);
                motion.AddAngularVelocityStep(
                    motion.MultiplyWorldSpaceInverseInertiaByVector(
                        dynamicBody.GetRotation(), r.Cross(impulse)));
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

            // Skip point if separating and not penetrating
            if (normalVelocity >= 0.0f && ptDepth <= 0.0f)
                continue;

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
            float newLambdaN = oldLambdaN +
                (-(1.0f + restitution) * normalVelocity) / effMassN;
            if (newLambdaN < 0.0f)
                newLambdaN = 0.0f;
            immutable float dLambdaN = newLambdaN - oldLambdaN;
            // Allow negative delta so the solver can walk back a warm-start
            // overshoot (e.g. the frame after a large impact).
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
            // Friction impulse (Coulomb cone clamped to normal lambda)
            // ---------------------------------------------------------------
            immutable Vec3  velAfterN   = motion.GetPointVelocityCOM(r);
            immutable Vec3  tangentVel  = velAfterN - normal * velAfterN.Dot(normal);
            if (tangentVel.LengthSq() <= 1.0e-8f)
                continue;

            immutable float tangentSpeed = tangentVel.Length();
            immutable Vec3  tangent      = tangentVel / tangentSpeed;
            immutable Vec3  angT = motion.MultiplyWorldSpaceInverseInertiaByVector(
                dynamicBody.GetRotation(), r.Cross(tangent));
            immutable float effMassT = invMass + angT.Cross(r).Dot(tangent);
            if (effMassT <= 1.0e-6f)
                continue;

            immutable float oldLambdaT =
                inConstraint.mPoints[origIdx].mFrictionParts[0].mTotalLambda;
            float newLambdaT = oldLambdaT - velAfterN.Dot(tangent) / effMassT;
            immutable float maxFriction = friction * newLambdaN;
            if      (newLambdaT >  maxFriction) newLambdaT =  maxFriction;
            else if (newLambdaT < -maxFriction) newLambdaT = -maxFriction;
            immutable float dLambdaT = newLambdaT - oldLambdaT;

            inConstraint.mPoints[origIdx].mFrictionParts[0].mAxis         = tangent;
            inConstraint.mPoints[origIdx].mFrictionParts[0].mEffectiveMass = effMassT;
            inConstraint.mPoints[origIdx].mFrictionParts[0].mTotalLambda  = newLambdaT;

            immutable Vec3 frictionImpulse = tangent * dLambdaT;
            motion.AddLinearVelocityStep(frictionImpulse * invMass);
            motion.AddAngularVelocityStep(motion.MultiplyWorldSpaceInverseInertiaByVector(
                dynamicBody.GetRotation(), r.Cross(frictionImpulse)));
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

        auto motion = dynamicBody.GetMotionPropertiesUnchecked();
        if (motion !is null && fabs(motion.GetLinearVelocity().Dot(constraint.mWorldSpaceNormal)) < inSettings.mVelocitySleepThreshold) {
            motion.ApplyLinearVelocityStep(
                motion.GetLinearVelocity()
                - constraint.mWorldSpaceNormal * motion.GetLinearVelocity().Dot(constraint.mWorldSpaceNormal));
        }
    }
}