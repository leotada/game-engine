module engine.jph.physics.constraints.contact_constraint_manager_cache;

import engine.jph.core.array : Array;
import engine.jph.math.vec3 : Vec3;
import engine.jph.physics.body.bodyid : BodyID;
import engine.jph.physics.collision.collide_shape : cMaxContactPoints;
import engine.jph.physics.constraints.contact_constraint : ContactConstraint;

@safe:

struct CachedContactPoint {
@safe:
    Vec3 mPointOn1 = Vec3.sZero();
    Vec3 mPointOn2 = Vec3.sZero();
    float mNormalLambda = 0.0f;
    float[2] mFrictionLambda = [0.0f, 0.0f];
}

struct CachedManifold {
@safe:
    BodyID mBody1ID;
    BodyID mBody2ID;
    Vec3 mWorldSpaceNormal = Vec3.sZero();
    CachedContactPoint[cMaxContactPoints] mPoints;
    uint mNumContactPoints = 0;

    void AssignFromConstraint(ref const(ContactConstraint) inConstraint) nothrow @nogc {
        mBody1ID = inConstraint.mBody1ID;
        mBody2ID = inConstraint.mBody2ID;
        mWorldSpaceNormal = inConstraint.mWorldSpaceNormal;
        mNumContactPoints = inConstraint.GetNumContactPoints();

        foreach (index; 0 .. cMaxContactPoints) {
            mPoints[index] = CachedContactPoint.init;
            if (index >= mNumContactPoints)
                continue;

            immutable point = inConstraint.GetContactPoint(index);
            mPoints[index].mPointOn1 = point.mPointOn1;
            mPoints[index].mPointOn2 = point.mPointOn2;
            mPoints[index].mNormalLambda = point.mNormalPart.mTotalLambda;
            mPoints[index].mFrictionLambda[0] = point.mFrictionParts[0].mTotalLambda;
            mPoints[index].mFrictionLambda[1] = point.mFrictionParts[1].mTotalLambda;
        }
    }
}

struct ContactConstraintManagerCache {
@safe:
    Array!CachedManifold mManifolds;

    void Clear() nothrow @nogc {
        mManifolds.clear();
    }

    void StoreConstraints(const(ContactConstraint)[] inConstraints) nothrow @nogc {
        mManifolds.clear();

        foreach (constraint; inConstraints) {
            CachedManifold manifold;
            manifold.AssignFromConstraint(constraint);
            mManifolds.push_back(manifold);
        }
    }

    const(CachedManifold)[] GetManifolds() const nothrow @nogc {
        return mManifolds[];
    }
}

unittest {
    import engine.jph.math.vec3 : Vec3;
    import engine.jph.physics.constraints.contact_constraint : ContactConstraint;

    ContactConstraint constraint;
    constraint.mBody1ID = BodyID(1, 1);
    constraint.mBody2ID = BodyID(2, 1);
    constraint.mWorldSpaceNormal = Vec3.sAxisY();
    constraint.mNumContactPoints = 1;
    constraint.mPoints[0].mPointOn1 = Vec3(0, 1, 0);
    constraint.mPoints[0].mPointOn2 = Vec3(0, 0, 0);
    constraint.mPoints[0].mNormalPart.mTotalLambda = 1.5f;

    CachedManifold manifold;
    manifold.AssignFromConstraint(constraint);
    assert(manifold.mNumContactPoints == 1);
    assert(manifold.mPoints[0].mNormalLambda == 1.5f);

    ContactConstraintManagerCache cache;
    cache.StoreConstraints([constraint]);
    assert(cache.GetManifolds().length == 1);
    assert(cache.GetManifolds()[0].mPoints[0].mNormalLambda == 1.5f);
}