// Jolt — Physics/Collision/Shape/SphereShape.{h,cpp} port.
//
// A sphere is implemented as a *point with convex radius*: the support
// function returns either the origin (when the convex radius is exposed
// separately) or the radius-scaled direction (when the radius is folded
// into the support). Scale must be uniform — `IsValidScale`/`MakeScaleValid`
// override the base defaults to enforce this.
//
// Source: ref/JoltPhysics/Jolt/Physics/Collision/Shape/SphereShape.{h,cpp}
module engine.jph.physics.shape.sphere_shape;

import engine.jph.core.reference          : Ref, RefConst;
import engine.jph.math.vec3               : Vec3;
import engine.jph.math.mat44              : Mat44;
import engine.jph.geometry.aabox          : AABox;
import engine.jph.geometry.ray_sphere     : RaySphere;
import engine.jph.physics.body.massproperties : MassProperties;
import engine.jph.physics.shape.shape         : Shape, ShapeResult, ShapeStats,
                                                 EShapeSubType;
import engine.jph.physics.shape.physics_material : PhysicsMaterial;
import engine.jph.physics.shape.sub_shape_id    : SubShapeID, SubShapeIDCreator;
import engine.jph.physics.shape.cast_result     : RayCast, RayCastResult;
import engine.jph.physics.shape.scale_helpers   : IsUniformScale, MakeUniformScale;
import engine.jph.physics.shape.convex_shape    : ConvexShape, ConvexShapeSettings,
                                                  Support, SupportBuffer, ESupportMode;

@safe:

private enum float JPH_PI = 3.14159265358979323846f;

private float cubed(float v) pure nothrow @nogc { return v * v * v; }

/// Authoring-time settings for a sphere.
final class SphereShapeSettings : ConvexShapeSettings {
    float mRadius = 0.0f;

    this() nothrow {}

    this(float inRadius, const PhysicsMaterial inMaterial = null) @trusted nothrow {
        super(inMaterial);
        mRadius = inRadius;
    }

    override ShapeResult Create() const @trusted {
        auto self = cast(SphereShapeSettings) this;
        if (self.mCachedResult.IsValid || self.mCachedResult.HasError)
            return self.mCachedResult;

        if (mRadius <= 0.0f) {
            self.mCachedResult = ShapeResult.sError("Invalid radius");
            return self.mCachedResult;
        }

        auto shape = new SphereShape(this);
        self.mCachedResult = ShapeResult.sOk(Ref!Shape(shape));
        return self.mCachedResult;
    }
}

/// A sphere centred around the origin.
final class SphereShape : ConvexShape {
    private float mRadius = 0.0f;

    /// Default constructor for deserialisation (no radius set yet).
    this() @trusted nothrow {
        super(EShapeSubType.Sphere);
    }

    /// Construct from settings (radius must be > 0).
    this(const SphereShapeSettings inSettings) @trusted nothrow {
        super(EShapeSubType.Sphere, inSettings);
        mRadius = inSettings.mRadius;
    }

    /// Convenience constructor.
    this(float inRadius, const PhysicsMaterial inMaterial = null) @trusted nothrow {
        super(EShapeSubType.Sphere, inMaterial);
        assert(inRadius > 0.0f, "Sphere radius must be > 0");
        mRadius = inRadius;
    }

    float GetRadius() const nothrow @nogc { return mRadius; }

    /// Sphere is uniform, so any scale axis can supply the scaling factor.
    private float getScaledRadius(Vec3 inScale) const nothrow @nogc {
        assert(IsValidScale(inScale));
        return inScale.Abs().GetX() * mRadius;
    }

    // ----- Shape overrides ---------------------------------------------------

    override AABox GetLocalBounds() const nothrow @nogc {
        immutable he = Vec3.sReplicate(mRadius);
        return AABox.sFromTwoPoints(-he, he);
    }

    override AABox GetWorldSpaceBounds(Mat44 inCenterOfMassTransform, Vec3 inScale)
            const nothrow @nogc {
        immutable r = getScaledRadius(inScale);
        immutable he = Vec3.sReplicate(r);
        auto bounds = AABox.sFromTwoPoints(-he, he);
        bounds.Translate(inCenterOfMassTransform.GetTranslation());
        return bounds;
    }

    override float GetInnerRadius() const nothrow @nogc { return mRadius; }

    override MassProperties GetMassProperties() const nothrow @nogc {
        MassProperties p;
        immutable r2 = mRadius * mRadius;
        p.mMass    = (4.0f / 3.0f * JPH_PI) * mRadius * r2 * mDensity;
        immutable inertia = (2.0f / 5.0f) * p.mMass * r2;
        p.mInertia = Mat44.sScale(inertia);
        return p;
    }

    override Vec3 GetSurfaceNormal(const SubShapeID inSubShapeID,
                                   Vec3 inLocalSurfacePosition) const nothrow @nogc {
        assert(inSubShapeID.IsEmpty(), "Invalid subshape ID");
        immutable len = inLocalSurfacePosition.Length();
        return len != 0.0f
            ? inLocalSurfacePosition * (1.0f / len)
            : Vec3.sAxisY();
    }

    override float GetVolume() const nothrow @nogc {
        return (4.0f / 3.0f) * JPH_PI * cubed(mRadius);
    }

    override bool CastRay(const RayCast inRay,
                          const SubShapeIDCreator inSubShapeIDCreator,
                          ref RayCastResult ioHit) const nothrow @nogc {
        immutable f = RaySphere(inRay.mOrigin, inRay.mDirection, Vec3.sZero(), mRadius);
        if (f < ioHit.mFraction) {
            ioHit.mFraction = f;
            ioHit.mSubShapeID2 = inSubShapeIDCreator.GetID();
            return true;
        }
        return false;
    }

    /// Sphere only accepts uniform scale.
    override bool IsValidScale(Vec3 inScale) const nothrow @nogc {
        // Reuse base's "non-zero" check then add uniformity.
        return super.IsValidScale(inScale) && IsUniformScale(inScale.Abs());
    }

    override Vec3 MakeScaleValid(Vec3 inScale) const nothrow @nogc {
        return MakeUniformScale(super.MakeScaleValid(inScale));
    }

    override ShapeStats GetStats() const nothrow @nogc {
        return ShapeStats(__traits(classInstanceSize, SphereShape), 0);
    }

    // ----- ConvexShape overrides --------------------------------------------

    override const(Support) GetSupportFunction(ESupportMode inMode,
                                               ref SupportBuffer inBuffer,
                                               Vec3 inScale) const nothrow @nogc {
        return getSupportImpl(inMode, inBuffer, getScaledRadius(inScale));
    }
}

// ---------------------------------------------------------------------------
// Support implementations.
// ---------------------------------------------------------------------------

/// Sphere support that exposes the radius separately (faster GJK iterations
/// because the underlying point support trivially returns the origin).
private final class SphereNoConvex : Support {
    private float mRadius;

    this(float inRadius) @trusted nothrow @nogc {
        mRadius = inRadius;
    }

    override Vec3  GetSupport(Vec3 inDirection) const nothrow @nogc { return Vec3.sZero(); }
    override float GetConvexRadius() const nothrow @nogc { return mRadius; }
}

/// Sphere support that folds the radius into the support point itself.
private final class SphereWithConvex : Support {
    private float mRadius;

    this(float inRadius) @trusted nothrow @nogc {
        mRadius = inRadius;
    }

    override Vec3 GetSupport(Vec3 inDirection) const nothrow @nogc {
        immutable len = inDirection.Length();
        return len > 0.0f ? inDirection * (mRadius / len) : Vec3.sZero();
    }

    override float GetConvexRadius() const nothrow @nogc { return 0.0f; }
}

/// Placement-construct one of the support implementations into `inBuffer`.
/// Mirrors Jolt's `new (&inBuffer) SphereXXX(...)`.
private const(Support) getSupportImpl(ESupportMode inMode,
                                      ref SupportBuffer inBuffer,
                                      float inScaledRadius) @trusted nothrow @nogc {
    import core.lifetime : emplace;

    static assert(__traits(classInstanceSize, SphereNoConvex)   <= SupportBuffer.sizeof,
                  "SphereNoConvex too large for SupportBuffer");
    static assert(__traits(classInstanceSize, SphereWithConvex) <= SupportBuffer.sizeof,
                  "SphereWithConvex too large for SupportBuffer");

    final switch (inMode) {
    case ESupportMode.IncludeConvexRadius:
        return emplace!SphereWithConvex(inBuffer.mData[0 .. __traits(classInstanceSize, SphereWithConvex)],
                                         inScaledRadius);
    case ESupportMode.ExcludeConvexRadius:
    case ESupportMode.Default:
        return emplace!SphereNoConvex(inBuffer.mData[0 .. __traits(classInstanceSize, SphereNoConvex)],
                                       inScaledRadius);
    }
}

// ---------------------------------------------------------------------------
// unittests
// ---------------------------------------------------------------------------

unittest {
    auto s = new SphereShape(2.0f);
    assert(s.GetRadius() == 2.0f);
    assert(s.GetType()    == EShapeType.Convex);
    assert(s.GetSubType() == EShapeSubType.Sphere);
    assert(s.GetInnerRadius() == 2.0f);

    auto bounds = s.GetLocalBounds();
    assert(bounds.GetExtent().GetX() == 2.0f);
}

unittest {
    auto settings = new SphereShapeSettings(1.5f);
    auto r = settings.Create();
    assert(r.IsValid());
    assert((cast(SphereShape) r.Get().GetPtr()).GetRadius() == 1.5f);
}

unittest {
    auto settings = new SphereShapeSettings(-1.0f);
    auto r = settings.Create();
    assert(r.HasError());
    assert(r.GetError() == "Invalid radius");
}

unittest {
    // Mass properties of a unit sphere with density 1 → m = 4/3 * π
    auto s = new SphereShape(1.0f);
    s.SetDensity(1.0f);
    auto p = s.GetMassProperties();
    import std.math : isClose;
    assert(isClose(p.mMass, 4.0f / 3.0f * 3.14159265358979323846f));
}

import engine.jph.physics.shape.shape : EShapeType;
