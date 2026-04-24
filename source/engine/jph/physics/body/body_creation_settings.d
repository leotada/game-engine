// Jolt — Physics/Body/BodyCreationSettings.h port (runtime subset).
//
// This first pass keeps the runtime shape path and the mass / inertia
// override knobs needed by the simple rigid-body MVP. ShapeSettings-based
// authoring and serialization can be layered on later without changing the
// public data layout used by the solver.
//
// Note: the current JPH shape port still mixes raw `new` allocation and
// intrusive `Ref` results. Until the shape allocation model is unified,
// BodyCreationSettings intentionally *borrows* the runtime shape pointer
// instead of owning it through `RefConst!Shape`.
module engine.jph.physics.body.body_creation_settings;

import engine.jph.core.types                   : uint64, uint8;
import engine.jph.math.vec3                    : Vec3;
import engine.jph.math.vec4                    : Vec4;
import engine.jph.math.quat                    : Quat;
import engine.jph.physics.body.alloweddofs     : EAllowedDOFs;
import engine.jph.physics.body.massproperties  : MassProperties;
import engine.jph.physics.body.motionquality   : EMotionQuality;
import engine.jph.physics.body.motiontype      : EMotionType;
import engine.jph.physics.collision.object_layer : ObjectLayer;
import engine.jph.physics.shape.shape          : Shape;

@safe:

enum EOverrideMassProperties : uint8 {
    CalculateMassAndInertia = 0,
    CalculateInertia = 1,
    MassAndInertiaProvided = 2,
}

struct BodyCreationSettings {
@safe:
    Vec3 mPosition = Vec3.sZero();
    Quat mRotation = Quat.sIdentity();
    Vec3 mLinearVelocity = Vec3.sZero();
    Vec3 mAngularVelocity = Vec3.sZero();
    uint64 mUserData = 0;

    ObjectLayer mObjectLayer = 0;

    EMotionType mMotionType = EMotionType.Dynamic;
    EAllowedDOFs mAllowedDOFs = EAllowedDOFs.All;
    bool mAllowDynamicOrKinematic = false;
    bool mIsSensor = false;
    bool mCollideKinematicVsNonDynamic = false;
    bool mUseManifoldReduction = true;
    bool mApplyGyroscopicForce = false;
    EMotionQuality mMotionQuality = EMotionQuality.Discrete;
    bool mEnhancedInternalEdgeRemoval = false;
    bool mAllowSleeping = true;
    float mFriction = 0.2f;
    float mRestitution = 0.0f;
    float mLinearDamping = 0.05f;
    float mAngularDamping = 0.05f;
    float mMaxLinearVelocity = 500.0f;
    float mMaxAngularVelocity = 0.25f * 3.141592653589793f * 60.0f;
    float mGravityFactor = 1.0f;
    uint mNumVelocityStepsOverride = 0;
    uint mNumPositionStepsOverride = 0;

    EOverrideMassProperties mOverrideMassProperties = EOverrideMassProperties.CalculateMassAndInertia;
    float mInertiaMultiplier = 1.0f;
    MassProperties mMassPropertiesOverride;

        Shape mShape = null;

        this(Shape inShape,
         Vec3 inPosition = Vec3.sZero(),
         Quat inRotation = Quat.sIdentity(),
         EMotionType inMotionType = EMotionType.Dynamic,
            ObjectLayer inObjectLayer = 0) nothrow @nogc {
        mPosition = inPosition;
        mRotation = inRotation;
        mMotionType = inMotionType;
        mObjectLayer = inObjectLayer;
        mShape = inShape;
    }

    bool HasShape() const nothrow @nogc {
        return mShape !is null;
    }

    void SetShape(Shape inShape) nothrow @nogc {
        mShape = inShape;
    }

    const(Shape) GetShape() const nothrow @nogc {
        return mShape;
    }

    Shape GetShapeMutable() const nothrow @nogc @trusted {
        return cast(Shape) mShape;
    }

    bool HasMassProperties() const nothrow @nogc {
        return mAllowDynamicOrKinematic || mMotionType != EMotionType.Static;
    }

    MassProperties GetMassProperties() const nothrow @nogc {
        const(Shape) shape = GetShape();
        assert(shape !is null, "BodyCreationSettings requires a shape before mass properties can be queried");

        MassProperties massProperties;
        final switch (mOverrideMassProperties) {
        case EOverrideMassProperties.CalculateMassAndInertia:
            massProperties = shape.GetMassProperties();
            applyInertiaMultiplier(massProperties, mInertiaMultiplier);
            break;

        case EOverrideMassProperties.CalculateInertia:
            massProperties = shape.GetMassProperties();
            massProperties.ScaleToMass(mMassPropertiesOverride.mMass);
            applyInertiaMultiplier(massProperties, mInertiaMultiplier);
            break;

        case EOverrideMassProperties.MassAndInertiaProvided:
            massProperties = mMassPropertiesOverride;
            canonicalizeInertia(massProperties);
            break;
        }

        return massProperties;
    }

    private static void applyInertiaMultiplier(ref MassProperties ioMassProperties,
                                               float inMultiplier) pure nothrow @nogc {
        ioMassProperties.mInertia = ioMassProperties.mInertia * inMultiplier;
        canonicalizeInertia(ioMassProperties);
    }

    private static void canonicalizeInertia(ref MassProperties ioMassProperties) pure nothrow @nogc {
        foreach (column; 0 .. 3) {
            immutable current = ioMassProperties.mInertia.GetColumn4(column);
            ioMassProperties.mInertia.SetColumn4(column,
                Vec4(current.GetX(), current.GetY(), current.GetZ(), 0.0f));
        }
        ioMassProperties.mInertia.SetColumn4(3, Vec4(0, 0, 0, 1));
    }
}

unittest {
    import engine.jph.physics.shape.box_shape : BoxShape;

    auto shape = new BoxShape(Vec3(1, 2, 3));
    BodyCreationSettings settings = BodyCreationSettings(shape, Vec3(1, 2, 3));
    assert(settings.HasShape());
    assert(settings.GetShape() is cast(const Shape) shape);
    assert(settings.HasMassProperties());

    immutable mp = settings.GetMassProperties();
    assert(mp.mMass > 0.0f);
    assert(mp.mInertia(3, 3) == 1.0f);
}

unittest {
    import engine.jph.physics.shape.sphere_shape : SphereShape;

    auto shape = new SphereShape(2.0f);
    BodyCreationSettings settings = BodyCreationSettings(shape);
    immutable auto base = settings.GetMassProperties();

    settings.mOverrideMassProperties = EOverrideMassProperties.CalculateInertia;
    settings.mMassPropertiesOverride.mMass = 10.0f;
    immutable auto scaled = settings.GetMassProperties();
    assert(scaled.mMass == 10.0f);
    immutable float expectedScale = 10.0f / base.mMass;
    immutable float expectedInertia = base.mInertia(0, 0) * expectedScale;
    assert(scaled.mInertia(0, 0) > expectedInertia - 1.0e-5f
        && scaled.mInertia(0, 0) < expectedInertia + 1.0e-5f);

    settings.mOverrideMassProperties = EOverrideMassProperties.MassAndInertiaProvided;
    settings.mMassPropertiesOverride.mMass = 7.0f;
    settings.mMassPropertiesOverride.mInertia = MassProperties.init.mInertia;
    settings.mMassPropertiesOverride.mInertia.SetColumn4(3, Vec4(9, 9, 9, 9));
    immutable auto provided = settings.GetMassProperties();
    assert(provided.mMass == 7.0f);
    assert(provided.mInertia(3, 3) == 1.0f);
}

unittest {
    BodyCreationSettings settings;
    settings.mMotionType = EMotionType.Static;
    assert(!settings.HasMassProperties());
    settings.mAllowDynamicOrKinematic = true;
    assert(settings.HasMassProperties());
}