// Jolt — Physics/Collision/Shape/CapsuleShape.{h,cpp} port.
//
// A capsule is a Y-aligned line segment (length `2*mHalfHeightOfCylinder`)
// with the cylinder *radius* exposed as a true convex radius. Setting
// `mHalfHeightOfCylinder == 0` collapses the capsule into a sphere — Jolt
// keeps the type stable and we mirror that.
//
// Source: ref/JoltPhysics/Jolt/Physics/Collision/Shape/CapsuleShape.{h,cpp}
module engine.jph.physics.shape.capsule_shape;

import engine.jph.core.reference          : Ref;
import engine.jph.math.vec3               : Vec3;
import engine.jph.math.mat44              : Mat44;
import engine.jph.geometry.aabox          : AABox;
import engine.jph.geometry.ray_capsule    : RayCapsule;
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

private float sq(float v) pure nothrow @nogc { return v * v; }

/// Authoring-time settings for a capsule.
final class CapsuleShapeSettings : ConvexShapeSettings {
    float mRadius                = 0.0f;
    float mHalfHeightOfCylinder  = 0.0f;

    this() nothrow {}

    this(float inHalfHeightOfCylinder, float inRadius,
         const PhysicsMaterial inMaterial = null) @trusted nothrow {
        super(inMaterial);
        mRadius               = inRadius;
        mHalfHeightOfCylinder = inHalfHeightOfCylinder;
    }

    bool IsValid()  const nothrow @nogc { return mRadius > 0.0f && mHalfHeightOfCylinder >= 0.0f; }
    bool IsSphere() const nothrow @nogc { return mHalfHeightOfCylinder == 0.0f; }

    override ShapeResult Create() const @trusted {
        auto self = cast(CapsuleShapeSettings) this;
        if (self.mCachedResult.IsValid || self.mCachedResult.HasError)
            return self.mCachedResult;

        if (mRadius <= 0.0f) {
            self.mCachedResult = ShapeResult.sError("Invalid radius");
            return self.mCachedResult;
        }
        if (mHalfHeightOfCylinder < 0.0f) {
            self.mCachedResult = ShapeResult.sError("Invalid half height");
            return self.mCachedResult;
        }

        auto shape = new CapsuleShape(this);
        self.mCachedResult = ShapeResult.sOk(Ref!Shape(shape));
        return self.mCachedResult;
    }
}

/// A capsule centred around the origin, axis along Y.
final class CapsuleShape : ConvexShape {
    private float mRadius                = 0.0f;
    private float mHalfHeightOfCylinder  = 0.0f;

    this() @trusted nothrow {
        super(EShapeSubType.Capsule);
    }

    this(const CapsuleShapeSettings inSettings) @trusted nothrow {
        super(EShapeSubType.Capsule, inSettings);
        mRadius               = inSettings.mRadius;
        mHalfHeightOfCylinder = inSettings.mHalfHeightOfCylinder;
    }

    this(float inHalfHeightOfCylinder, float inRadius,
         const PhysicsMaterial inMaterial = null) @trusted nothrow {
        super(EShapeSubType.Capsule, inMaterial);
        assert(inHalfHeightOfCylinder >= 0.0f);
        assert(inRadius > 0.0f);
        mRadius               = inRadius;
        mHalfHeightOfCylinder = inHalfHeightOfCylinder;
    }

    float GetRadius()              const nothrow @nogc { return mRadius; }
    float GetHalfHeightOfCylinder() const nothrow @nogc { return mHalfHeightOfCylinder; }

    // ----- Shape overrides ---------------------------------------------------

    override AABox GetLocalBounds() const nothrow @nogc {
        immutable e = Vec3.sReplicate(mRadius) + Vec3(0, mHalfHeightOfCylinder, 0);
        return AABox.sFromTwoPoints(-e, e);
    }

    override AABox GetWorldSpaceBounds(Mat44 inCenterOfMassTransform, Vec3 inScale)
            const nothrow @nogc {
        assert(IsValidScale(inScale));
        immutable s        = inScale.Abs().GetX();
        immutable extent   = Vec3.sReplicate(s * mRadius);
        immutable height   = Vec3(0, s * mHalfHeightOfCylinder, 0);
        immutable p1       = inCenterOfMassTransform * (-height);
        immutable p2       = inCenterOfMassTransform * height;
        return AABox.sFromTwoPoints(Vec3.sMin(p1, p2) - extent,
                                     Vec3.sMax(p1, p2) + extent);
    }

    override float GetInnerRadius() const nothrow @nogc { return mRadius; }

    override MassProperties GetMassProperties() const nothrow @nogc {
        // Reference: https://www.gamedev.net/resources/_/technical/math-and-physics/capsule-inertia-tensor-r3856
        // (eq 14 corrected: H^2/4 not H^2/2 for Ixx/Izz).
        MassProperties p;
        immutable r2     = sq(mRadius);
        immutable h      = 2.0f * mHalfHeightOfCylinder;
        immutable cylM   = JPH_PI * h * r2 * mDensity;
        immutable hemiM  = (2.0f * JPH_PI / 3.0f) * r2 * mRadius * mDensity;

        immutable h2     = sq(h);
        float iy = r2 * cylM * 0.5f;
        float ixz = iy * 0.5f + cylM * h2 / 12.0f;

        immutable t = hemiM * 4.0f * r2 / 5.0f;
        iy  += t;
        ixz += t + hemiM * (0.5f * h2 + (3.0f / 4.0f) * h * mRadius);

        p.mMass    = cylM + hemiM * 2.0f;
        p.mInertia = Mat44.sScale(Vec3(ixz, iy, ixz));
        return p;
    }

    override Vec3 GetSurfaceNormal(const SubShapeID inSubShapeID,
                                   Vec3 inLocalSurfacePosition) const nothrow @nogc {
        assert(inSubShapeID.IsEmpty(), "Invalid subshape ID");
        immutable y = inLocalSurfacePosition.GetY();
        if (y > mHalfHeightOfCylinder)
            return (inLocalSurfacePosition - Vec3(0, mHalfHeightOfCylinder, 0)).Normalized();
        if (y < -mHalfHeightOfCylinder)
            return (inLocalSurfacePosition - Vec3(0, -mHalfHeightOfCylinder, 0)).Normalized();
        return Vec3(inLocalSurfacePosition.GetX(), 0, inLocalSurfacePosition.GetZ())
            .NormalizedOr(Vec3.sAxisX());
    }

    override float GetVolume() const nothrow @nogc {
        immutable r2 = sq(mRadius);
        return 4.0f / 3.0f * JPH_PI * r2 * mRadius
             + 2.0f * JPH_PI * mHalfHeightOfCylinder * r2;
    }

    override bool CastRay(const RayCast inRay,
                          const SubShapeIDCreator inSubShapeIDCreator,
                          ref RayCastResult ioHit) const nothrow @nogc {
        immutable f = RayCapsule(inRay.mOrigin, inRay.mDirection, mHalfHeightOfCylinder, mRadius);
        if (f < ioHit.mFraction) {
            ioHit.mFraction = f;
            ioHit.mSubShapeID2 = inSubShapeIDCreator.GetID();
            return true;
        }
        return false;
    }

    /// Capsule only accepts uniform scale (otherwise it's an ellipsoid).
    override bool IsValidScale(Vec3 inScale) const nothrow @nogc {
        return super.IsValidScale(inScale) && IsUniformScale(inScale.Abs());
    }

    override Vec3 MakeScaleValid(Vec3 inScale) const nothrow @nogc {
        return MakeUniformScale(super.MakeScaleValid(inScale));
    }

    override ShapeStats GetStats() const nothrow @nogc {
        return ShapeStats(__traits(classInstanceSize, CapsuleShape), 0);
    }

    // ----- ConvexShape overrides --------------------------------------------

    override const(Support) GetSupportFunction(ESupportMode inMode,
                                               ref SupportBuffer inBuffer,
                                               Vec3 inScale) const nothrow @nogc {
        assert(IsValidScale(inScale));
        immutable s          = inScale.Abs().GetX();
        immutable scaledHHC  = Vec3(0, s * mHalfHeightOfCylinder, 0);
        immutable scaledRad  = s * mRadius;

        final switch (inMode) {
        case ESupportMode.IncludeConvexRadius:
            return makeWithConvex(inBuffer, scaledHHC, scaledRad);
        case ESupportMode.ExcludeConvexRadius:
        case ESupportMode.Default:
            return makeNoConvex(inBuffer, scaledHHC, scaledRad);
        }
    }
}

// ---------------------------------------------------------------------------
// Support implementations
// ---------------------------------------------------------------------------

/// Cylinder-segment-only support: returns ±half-height. The cylinder radius
/// is exposed via `GetConvexRadius` so GJK adds it back.
private final class CapsuleNoConvex : Support {
    private Vec3  mHalfHeightOfCylinder;
    private float mConvexRadius;

    this(Vec3 inHHC, float inConvexRadius) @trusted nothrow @nogc {
        mHalfHeightOfCylinder = inHHC;
        mConvexRadius          = inConvexRadius;
    }

    override Vec3 GetSupport(Vec3 inDirection) const nothrow @nogc {
        return inDirection.GetY() > 0.0f ? mHalfHeightOfCylinder : -mHalfHeightOfCylinder;
    }

    override float GetConvexRadius() const nothrow @nogc { return mConvexRadius; }
}

/// Full capsule support: radius folded into the support point.
private final class CapsuleWithConvex : Support {
    private Vec3  mHalfHeightOfCylinder;
    private float mRadius;

    this(Vec3 inHHC, float inRadius) @trusted nothrow @nogc {
        mHalfHeightOfCylinder = inHHC;
        mRadius                = inRadius;
    }

    override Vec3 GetSupport(Vec3 inDirection) const nothrow @nogc {
        immutable len = inDirection.Length();
        immutable rad = len > 0.0f ? inDirection * (mRadius / len) : Vec3.sZero();
        return inDirection.GetY() > 0.0f
            ? rad + mHalfHeightOfCylinder
            : rad - mHalfHeightOfCylinder;
    }

    override float GetConvexRadius() const nothrow @nogc { return 0.0f; }
}

private const(Support) makeNoConvex(ref SupportBuffer inBuffer, Vec3 inHHC, float inRad)
        @trusted nothrow @nogc {
    import core.lifetime : emplace;
    static assert(__traits(classInstanceSize, CapsuleNoConvex) <= SupportBuffer.sizeof);
    return emplace!CapsuleNoConvex(inBuffer.mData[0 .. __traits(classInstanceSize, CapsuleNoConvex)],
                                    inHHC, inRad);
}

private const(Support) makeWithConvex(ref SupportBuffer inBuffer, Vec3 inHHC, float inRad)
        @trusted nothrow @nogc {
    import core.lifetime : emplace;
    static assert(__traits(classInstanceSize, CapsuleWithConvex) <= SupportBuffer.sizeof);
    return emplace!CapsuleWithConvex(inBuffer.mData[0 .. __traits(classInstanceSize, CapsuleWithConvex)],
                                      inHHC, inRad);
}

// ---------------------------------------------------------------------------
// unittests
// ---------------------------------------------------------------------------

unittest {
    auto c = new CapsuleShape(2.0f, 0.5f);
    assert(c.GetRadius() == 0.5f);
    assert(c.GetHalfHeightOfCylinder() == 2.0f);
    assert(c.GetSubType() == EShapeSubType.Capsule);
    assert(c.GetInnerRadius() == 0.5f);

    immutable b = c.GetLocalBounds();
    assert(b.GetExtent() == Vec3(0.5f, 2.5f, 0.5f));
}

unittest {
    auto s = new CapsuleShapeSettings(1.0f, 0.5f);
    assert(s.IsValid());
    assert(!s.IsSphere());
    auto r = s.Create();
    assert(r.IsValid());
}

unittest {
    auto bad = new CapsuleShapeSettings(1.0f, -1.0f);
    assert(bad.Create().HasError());
}
