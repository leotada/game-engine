module engine.jph.physics.constraints.contact_constraint_part;

import engine.jph.math.vec3 : Vec3;

@safe:

struct ContactConstraintPart {
@safe:
    Vec3 mAxis = Vec3.sZero();
    float mEffectiveMass = 0.0f;
    float mTotalLambda = 0.0f;
    float mBias = 0.0f;

    void Reset(Vec3 inAxis = Vec3.sZero(),
               float inBias = 0.0f) nothrow @nogc {
        mAxis = inAxis;
        mEffectiveMass = 0.0f;
        mTotalLambda = 0.0f;
        mBias = inBias;
    }
}

unittest {
    ContactConstraintPart part;
    part.mEffectiveMass = 2.0f;
    part.mTotalLambda = 3.0f;
    part.Reset(Vec3.sAxisY(), 0.25f);
    assert(part.mAxis == Vec3.sAxisY());
    assert(part.mEffectiveMass == 0.0f);
    assert(part.mTotalLambda == 0.0f);
    assert(part.mBias == 0.25f);
}