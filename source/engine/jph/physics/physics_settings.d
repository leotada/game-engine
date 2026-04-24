// Minimal step-loop configuration for the simple rigid-body MVP.
module engine.jph.physics.physics_settings;

@safe:

struct PhysicsSettings {
@safe:
    uint mNumVelocityIterations = 8;
    uint mNumPositionIterations = 2;
    float mBaumgarteERP = 0.2f;
    float mPenetrationSlop = 0.01f;
    float mVelocitySleepThreshold = 0.01f;
    float mTimeBeforeSleep = 0.5f;
}

unittest {
    PhysicsSettings settings;
    assert(settings.mNumVelocityIterations == 8);
    assert(settings.mNumPositionIterations == 2);
    assert(settings.mBaumgarteERP == 0.2f);
    assert(settings.mPenetrationSlop == 0.01f);
    assert(settings.mVelocitySleepThreshold == 0.01f);
    assert(settings.mTimeBeforeSleep == 0.5f);
}