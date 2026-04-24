module engine.jph.physics.constraints.contact_constraint;

import engine.jph.math.vec3 : Vec3;
import engine.jph.physics.body.bodyid : BodyID;
import engine.jph.physics.collision.collide_shape : ContactManifold,
                                                    cMaxContactPoints;
import engine.jph.physics.constraints.contact_constraint_part : ContactConstraintPart;

@safe:

struct ContactConstraintPoint {
@safe:
    Vec3 mPointOn1 = Vec3.sZero();
    Vec3 mPointOn2 = Vec3.sZero();
    float mPenetrationDepth = 0.0f;
    ContactConstraintPart mNormalPart;
    ContactConstraintPart[2] mFrictionParts;
}

struct ContactConstraint {
@safe:
    BodyID mBody1ID;
    BodyID mBody2ID;
    Vec3 mWorldSpaceNormal = Vec3.sZero();
    ContactConstraintPoint[cMaxContactPoints] mPoints;
    uint mNumContactPoints = 0;

    void AssignFromManifold(ref const(ContactManifold) inManifold) nothrow @nogc {
        mBody1ID = inManifold.mBody1ID;
        mBody2ID = inManifold.mBody2ID;
        mWorldSpaceNormal = inManifold.mWorldSpaceNormal;
        mNumContactPoints = inManifold.GetNumContactPoints();

        foreach (index; 0 .. cMaxContactPoints) {
            mPoints[index] = ContactConstraintPoint.init;
            if (index >= mNumContactPoints)
                continue;

            immutable point = inManifold.GetContactPoint(index);
            mPoints[index].mPointOn1 = point.mPointOn1;
            mPoints[index].mPointOn2 = point.mPointOn2;
            mPoints[index].mPenetrationDepth = point.mPenetrationDepth;
            mPoints[index].mNormalPart.Reset(mWorldSpaceNormal);
        }
    }

    bool IsEmpty() const nothrow @nogc {
        return mNumContactPoints == 0;
    }

    uint GetNumContactPoints() const nothrow @nogc {
        return mNumContactPoints;
    }

    ref const(ContactConstraintPoint) GetContactPoint(uint inIndex) const return nothrow @nogc {
        assert(inIndex < mNumContactPoints);
        return mPoints[inIndex];
    }

    ContactConstraint Reversed() const nothrow @nogc {
        ContactConstraint reversed = this;
        reversed.mBody1ID = mBody2ID;
        reversed.mBody2ID = mBody1ID;
        reversed.mWorldSpaceNormal = -mWorldSpaceNormal;

        foreach (index; 0 .. mNumContactPoints) {
            reversed.mPoints[index].mPointOn1 = mPoints[index].mPointOn2;
            reversed.mPoints[index].mPointOn2 = mPoints[index].mPointOn1;
            reversed.mPoints[index].mNormalPart.Reset(reversed.mWorldSpaceNormal);
        }

        return reversed;
    }
}

unittest {
    import engine.jph.physics.collision.collide_shape : ContactManifold,
                                                        InitializeContactManifold;
    import engine.jph.math.vec3 : Vec3;

    ContactManifold manifold;
    InitializeContactManifold(manifold, BodyID(1, 1), BodyID(2, 1), Vec3.sAxisY());
    assert(manifold.AddContactPoint(Vec3(1, 2, 3), Vec3(1, 0, 3), 2.0f));

    ContactConstraint constraint;
    constraint.AssignFromManifold(manifold);
    assert(constraint.GetNumContactPoints() == 1);
    assert(constraint.GetContactPoint(0).mPointOn1 == Vec3(1, 2, 3));

    immutable reversed = constraint.Reversed();
    assert(reversed.mBody1ID == BodyID(2, 1));
    assert(reversed.mWorldSpaceNormal == -Vec3.sAxisY());
    assert(reversed.GetContactPoint(0).mPointOn1 == Vec3(1, 0, 3));
}