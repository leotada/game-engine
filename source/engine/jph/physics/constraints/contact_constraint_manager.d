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
        mConstraints.clear();

        foreach (manifold; inManifolds) {
            ContactConstraint constraint;
            constraint.AssignFromManifold(manifold);
            mConstraints.push_back(constraint);
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

    private void solveStaticContactVelocity(ref ContactConstraint inConstraint) nothrow @nogc {
        auto body1 = tryGetBody(inConstraint.mBody1ID);
        auto body2 = tryGetBody(inConstraint.mBody2ID);
        if (body1 is null || body2 is null)
            return;

        ContactConstraint constraint = inConstraint;
        auto dynamicBody = body1;
        auto staticBody = body2;

        if (body1.IsStatic() && body2.IsDynamic()) {
            constraint = inConstraint.Reversed();
            dynamicBody = body2;
            staticBody = body1;
        } else if (!body1.IsDynamic() || !body2.IsStatic()) {
            return;
        }

        auto motion = dynamicBody.GetMotionPropertiesUnchecked();
        if (motion is null || constraint.GetNumContactPoints() == 0)
            return;

        Vec3 averagePointOn1 = Vec3.sZero();
        float maxPenetration = constraint.GetContactPoint(0).mPenetrationDepth;
        foreach (index; 0 .. constraint.GetNumContactPoints()) {
            immutable point = constraint.GetContactPoint(index);
            averagePointOn1 += point.mPointOn1;
            if (point.mPenetrationDepth > maxPenetration)
                maxPenetration = point.mPenetrationDepth;
        }
        averagePointOn1 /= cast(float) constraint.GetNumContactPoints();

        immutable Vec3 normal = constraint.mWorldSpaceNormal;
        immutable Vec3 r = averagePointOn1 - dynamicBody.GetCenterOfMassPosition();
        immutable Vec3 pointVelocity = motion.GetPointVelocityCOM(r);
        immutable float normalVelocity = pointVelocity.Dot(normal);
        if (normalVelocity >= 0.0f && maxPenetration <= 0.0f)
            return;

        immutable float invMass = motion.GetInverseMassUnchecked();
        immutable Vec3 angularNormal = motion.MultiplyWorldSpaceInverseInertiaByVector(
            dynamicBody.GetRotation(),
            r.Cross(normal));
        immutable float effectiveMass = invMass + angularNormal.Cross(r).Dot(normal);
        if (effectiveMass <= 1.0e-6f)
            return;

        immutable float restitution = 0.5f * (dynamicBody.GetRestitution() + staticBody.GetRestitution());
        immutable float oldNormalLambda = inConstraint.mPoints[0].mNormalPart.mTotalLambda;
        float newNormalLambda = oldNormalLambda + (-(1.0f + restitution) * normalVelocity) / effectiveMass;
        if (newNormalLambda < 0.0f)
            newNormalLambda = 0.0f;
        immutable float normalImpulse = newNormalLambda - oldNormalLambda;
        if (normalImpulse <= 0.0f)
            return;

        inConstraint.mPoints[0].mNormalPart.mAxis = inConstraint.mWorldSpaceNormal;
        inConstraint.mPoints[0].mNormalPart.mEffectiveMass = effectiveMass;
        inConstraint.mPoints[0].mNormalPart.mTotalLambda = newNormalLambda;

        immutable Vec3 impulse = normal * normalImpulse;
        motion.AddLinearVelocityStep(impulse * invMass);
        motion.AddAngularVelocityStep(motion.MultiplyWorldSpaceInverseInertiaByVector(
            dynamicBody.GetRotation(),
            r.Cross(impulse)));

        immutable Vec3 newPointVelocity = motion.GetPointVelocityCOM(r);
        immutable Vec3 tangentVelocity = newPointVelocity - normal * newPointVelocity.Dot(normal);
        immutable float tangentSpeedSq = tangentVelocity.LengthSq();
        if (tangentSpeedSq <= 1.0e-8f)
            return;

        immutable float tangentSpeed = tangentVelocity.Length();
        immutable Vec3 tangent = tangentVelocity / tangentSpeed;
        immutable Vec3 angularTangent = motion.MultiplyWorldSpaceInverseInertiaByVector(
            dynamicBody.GetRotation(),
            r.Cross(tangent));
        immutable float tangentEffectiveMass = invMass + angularTangent.Cross(r).Dot(tangent);
        if (tangentEffectiveMass <= 1.0e-6f)
            return;

        immutable float friction = 0.5f * (dynamicBody.GetFriction() + staticBody.GetFriction());
        immutable float oldTangentLambda = inConstraint.mPoints[0].mFrictionParts[0].mTotalLambda;
        float newTangentLambda = oldTangentLambda - newPointVelocity.Dot(tangent) / tangentEffectiveMass;
        immutable float maxFrictionImpulse = friction * inConstraint.mPoints[0].mNormalPart.mTotalLambda;
        if (newTangentLambda > maxFrictionImpulse)
            newTangentLambda = maxFrictionImpulse;
        else if (newTangentLambda < -maxFrictionImpulse)
            newTangentLambda = -maxFrictionImpulse;
        immutable float tangentImpulseMagnitude = newTangentLambda - oldTangentLambda;

        inConstraint.mPoints[0].mFrictionParts[0].mAxis = tangent;
        inConstraint.mPoints[0].mFrictionParts[0].mEffectiveMass = tangentEffectiveMass;
        inConstraint.mPoints[0].mFrictionParts[0].mTotalLambda = newTangentLambda;

        immutable Vec3 tangentImpulse = tangent * tangentImpulseMagnitude;
        motion.AddLinearVelocityStep(tangentImpulse * invMass);
        motion.AddAngularVelocityStep(motion.MultiplyWorldSpaceInverseInertiaByVector(
            dynamicBody.GetRotation(),
            r.Cross(tangentImpulse)));
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