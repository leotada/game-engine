// Jolt — Physics/Collision/Shape/TaperedCapsuleShape.{h,cpp} port.
//
// A capsule with different top/bottom sphere radii. The cylindrical band
// becomes a *cone frustum* tangent to both spheres. The COM is shifted so
// the local frame stays balanced. Only uniform scale is permitted.
//
// NOTE: when settings reduce to a sphere with non-zero centre offset, Jolt
// wraps it in a `RotatedTranslatedShape`. That decorator lives in milestone
// 4a.4, so until then we only collapse the sphere fallback when the offset
// is negligible; offset cases return an error.
//
// Source: ref/JoltPhysics/Jolt/Physics/Collision/Shape/TaperedCapsuleShape.{h,cpp}
module engine.jph.physics.shape.tapered_capsule_shape;

import engine.jph.core.reference            : Ref;
import engine.jph.math.vec3                 : Vec3;
import engine.jph.math.mat44                : Mat44;
import engine.jph.geometry.aabox            : AABox;
import engine.jph.physics.body.massproperties : MassProperties;
import engine.jph.physics.shape.shape          : Shape, ShapeResult, ShapeStats,
                                                  EShapeSubType;
import engine.jph.physics.shape.physics_material : PhysicsMaterial;
import engine.jph.physics.shape.sub_shape_id     : SubShapeID, SubShapeIDCreator;
import engine.jph.physics.shape.cast_result      : RayCast, RayCastResult;
import engine.jph.physics.shape.scale_helpers    : IsUniformScale, MakeUniformScale,
                                                   MakeNonZeroScale;
import engine.jph.physics.shape.convex_shape     : ConvexShape, ConvexShapeSettings,
                                                   Support, SupportBuffer, ESupportMode;
import engine.jph.physics.shape.sphere_shape     : SphereShape;

@safe:

private float fmin(float a, float b) pure nothrow @nogc { return a < b ? a : b; }
private float fmax(float a, float b) pure nothrow @nogc { return a > b ? a : b; }
private float fabs(float a)          pure nothrow @nogc { return a < 0.0f ? -a : a; }

final class TaperedCapsuleShapeSettings : ConvexShapeSettings {
    float mHalfHeightOfTaperedCylinder = 0.0f;
    float mTopRadius                   = 0.0f;
    float mBottomRadius                = 0.0f;

    this() nothrow {}

    this(float inHalfHeight, float inTopRadius, float inBottomRadius,
         const PhysicsMaterial inMaterial = null) @trusted nothrow {
        super(inMaterial);
        mHalfHeightOfTaperedCylinder = inHalfHeight;
        mTopRadius                   = inTopRadius;
        mBottomRadius                = inBottomRadius;
    }

    bool IsValid() const nothrow @nogc {
        return mTopRadius > 0.0f && mBottomRadius > 0.0f
            && mHalfHeightOfTaperedCylinder >= 0.0f;
    }

    bool IsSphere() const nothrow @nogc {
        immutable float mx = fmax(mTopRadius, mBottomRadius);
        immutable float mn = fmin(mTopRadius, mBottomRadius);
        return mx >= 2.0f * mHalfHeightOfTaperedCylinder + mn;
    }

    override ShapeResult Create() const @trusted {
        auto self = cast(TaperedCapsuleShapeSettings) this;
        if (self.mCachedResult.IsValid || self.mCachedResult.HasError)
            return self.mCachedResult;

        if (IsValid() && IsSphere()) {
            float radius, center;
            if (mTopRadius > mBottomRadius) {
                radius = mTopRadius;  center =  mHalfHeightOfTaperedCylinder;
            } else {
                radius = mBottomRadius; center = -mHalfHeightOfTaperedCylinder;
            }
            if (fabs(center) > 1.0e-6f) {
                self.mCachedResult = ShapeResult.sError(
                    "TaperedCapsule degenerated to offset sphere; needs RotatedTranslatedShape (milestone 4a.4)");
                return self.mCachedResult;
            }
            auto sphere = new SphereShape(radius, mMaterial);
            self.mCachedResult = ShapeResult.sOk(Ref!Shape(sphere));
            return self.mCachedResult;
        }

        auto shape = new TaperedCapsuleShape(this);
        if (shape.mInitError.length > 0)
            self.mCachedResult = ShapeResult.sError(shape.mInitError);
        else
            self.mCachedResult = ShapeResult.sOk(Ref!Shape(shape));
        return self.mCachedResult;
    }
}

final class TaperedCapsuleShape : ConvexShape {
    private Vec3  mCenterOfMassOffset = Vec3(0, 0, 0);
    private float mTopRadius     = 0.0f;
    private float mBottomRadius  = 0.0f;
    private float mTopCenter     = 0.0f;
    private float mBottomCenter  = 0.0f;
    private float mConvexRadius  = 0.0f;
    private float mSinAlpha      = 0.0f;
    private float mTanAlpha      = 0.0f;
    package string mInitError;

    this() @trusted nothrow {
        super(EShapeSubType.TaperedCapsule);
    }

    this(const TaperedCapsuleShapeSettings inSettings) @trusted nothrow {
        super(EShapeSubType.TaperedCapsule, inSettings);
        mTopRadius    = inSettings.mTopRadius;
        mBottomRadius = inSettings.mBottomRadius;

        if (mTopRadius <= 0.0f)         { mInitError = "Invalid top radius";    return; }
        if (mBottomRadius <= 0.0f)      { mInitError = "Invalid bottom radius"; return; }
        if (inSettings.mHalfHeightOfTaperedCylinder <= 0.0f) {
            mInitError = "Invalid height"; return;
        }
        if (inSettings.IsSphere()) {
            mInitError = "One sphere embedded in other; use sphere shape instead"; return;
        }

        // The COM is taken to lie midway between the two cap centres
        // (an approximation matching reference Jolt).
        mTopCenter     = inSettings.mHalfHeightOfTaperedCylinder + 0.5f * (mBottomRadius - mTopRadius);
        mBottomCenter  = -inSettings.mHalfHeightOfTaperedCylinder + 0.5f * (mBottomRadius - mTopRadius);
        mCenterOfMassOffset = Vec3(0, inSettings.mHalfHeightOfTaperedCylinder - mTopCenter, 0);

        mConvexRadius = fmin(mTopRadius, mBottomRadius);
        assert(mConvexRadius > 0.0f);

        mSinAlpha = (mBottomRadius - mTopRadius) / (mTopCenter - mBottomCenter);
        assert(mSinAlpha >= -1.0f && mSinAlpha <= 1.0f);
        import std.math : asin, tan;
        mTanAlpha = cast(float) tan(asin(cast(double) mSinAlpha));
    }

    float GetTopRadius()    const nothrow @nogc { return mTopRadius; }
    float GetBottomRadius() const nothrow @nogc { return mBottomRadius; }
    float GetHalfHeight()   const nothrow @nogc { return 0.5f * (mTopCenter - mBottomCenter); }

    // ----- Shape overrides ---------------------------------------------------

    override Vec3 GetCenterOfMass() const nothrow @nogc { return mCenterOfMassOffset; }

    override AABox GetLocalBounds() const nothrow @nogc {
        immutable mr = fmax(mTopRadius, mBottomRadius);
        return AABox.sFromTwoPoints(
            Vec3(-mr, mBottomCenter - mBottomRadius, -mr),
            Vec3( mr, mTopCenter    + mTopRadius,    mr));
    }

    override AABox GetWorldSpaceBounds(Mat44 inCenterOfMassTransform, Vec3 inScale)
            const nothrow @nogc {
        assert(IsValidScale(inScale));
        immutable abs   = inScale.Abs();
        immutable sxz   = abs.GetX();
        immutable sy    = inScale.GetY();
        immutable bExt  = Vec3.sReplicate(sxz * mBottomRadius);
        immutable bC    = inCenterOfMassTransform * Vec3(0, sy * mBottomCenter, 0);
        immutable tExt  = Vec3.sReplicate(sxz * mTopRadius);
        immutable tC    = inCenterOfMassTransform * Vec3(0, sy * mTopCenter, 0);
        return AABox.sFromTwoPoints(
            Vec3.sMin(tC - tExt, bC - bExt),
            Vec3.sMax(tC + tExt, bC + bExt));
    }

    override float GetInnerRadius() const nothrow @nogc { return fmin(mTopRadius, mBottomRadius); }

    override float GetVolume() const nothrow @nogc { return GetLocalBounds().GetVolume(); }

    /// Approximate inertia: solid box around the average-radius bounding box.
    override MassProperties GetMassProperties() const nothrow @nogc {
        immutable float ar = 0.5f * (mTopRadius + mBottomRadius);
        immutable AABox box = AABox.sFromTwoPoints(
            Vec3(-ar, mBottomCenter - mBottomRadius, -ar),
            Vec3( ar, mTopCenter    + mTopRadius,    ar));
        immutable Vec3 size = box.GetExtent() * 2.0f;
        MassProperties p;
        p.SetMassAndInertiaOfSolidBox(size, mDensity);
        return p;
    }

    override Vec3 GetSurfaceNormal(const SubShapeID inSubShapeID,
                                   Vec3 inLocalSurfacePosition) const nothrow @nogc {
        assert(inSubShapeID.IsEmpty(), "Invalid subshape ID");
        immutable y = inLocalSurfacePosition.GetY();
        if (y > mTopCenter + mSinAlpha * mTopRadius)
            return (inLocalSurfacePosition - Vec3(0, mTopCenter, 0)).Normalized();
        if (y < mBottomCenter + mSinAlpha * mBottomRadius)
            return (inLocalSurfacePosition - Vec3(0, mBottomCenter, 0)).Normalized();
        Vec3 perp = Vec3(inLocalSurfacePosition.GetX(), 0, inLocalSurfacePosition.GetZ())
            .NormalizedOr(Vec3.sAxisX());
        perp.SetY(mTanAlpha);
        return perp.Normalized();
    }

    override bool IsValidScale(Vec3 inScale) const nothrow @nogc {
        return super.IsValidScale(inScale) && IsUniformScale(inScale.Abs());
    }

    override Vec3 MakeScaleValid(Vec3 inScale) const nothrow @nogc {
        immutable s = MakeNonZeroScale(inScale);
        return s.GetSign() * MakeUniformScale(s.Abs());
    }

    override ShapeStats GetStats() const nothrow @nogc {
        return ShapeStats(__traits(classInstanceSize, TaperedCapsuleShape), 0);
    }

    // ----- ConvexShape overrides --------------------------------------------

    override const(Support) GetSupportFunction(ESupportMode inMode,
                                               ref SupportBuffer inBuffer,
                                               Vec3 inScale) const nothrow @nogc {
        assert(IsValidScale(inScale));
        immutable abs   = inScale.Abs();
        immutable sxz   = abs.GetX();
        immutable sy    = inScale.GetY(); // sign matters
        immutable Vec3  stc = Vec3(0, sy * mTopCenter, 0);
        immutable Vec3  sbc = Vec3(0, sy * mBottomCenter, 0);
        immutable float str = sxz * mTopRadius;
        immutable float sbr = sxz * mBottomRadius;
        immutable float scvx = sxz * mConvexRadius;

        final switch (inMode) {
        case ESupportMode.IncludeConvexRadius:
            return makeSupport(inBuffer, stc, sbc, str, sbr, 0.0f);
        case ESupportMode.ExcludeConvexRadius:
        case ESupportMode.Default:
            // Convex radius = min radius, so one of (str-cvx, sbr-cvx) is zero.
            immutable float tr = str - scvx;
            immutable float br = sbr - scvx;
            return makeSupport(inBuffer, stc, sbc, tr, br, scvx);
        }
    }
}

// ---------------------------------------------------------------------------
// Support
// ---------------------------------------------------------------------------

private final class TaperedCapsuleSupport : Support {
    private Vec3  mTopCenter;
    private Vec3  mBottomCenter;
    private float mTopRadius;
    private float mBottomRadius;
    private float mConvexRadius;

    this(Vec3 tc, Vec3 bc, float tr, float br, float cvx) @trusted nothrow @nogc {
        mTopCenter = tc; mBottomCenter = bc;
        mTopRadius = tr; mBottomRadius = br; mConvexRadius = cvx;
    }

    override Vec3 GetSupport(Vec3 inDirection) const nothrow @nogc {
        immutable float len = inDirection.Length();
        if (len == 0.0f) return mTopCenter + Vec3(0, mTopRadius, 0);
        immutable Vec3 st = mTopCenter    + inDirection * (mTopRadius    / len);
        immutable Vec3 sb = mBottomCenter + inDirection * (mBottomRadius / len);
        return st.Dot(inDirection) > sb.Dot(inDirection) ? st : sb;
    }

    override float GetConvexRadius() const nothrow @nogc { return mConvexRadius; }
}

private const(Support) makeSupport(ref SupportBuffer inBuffer,
                                   Vec3 tc, Vec3 bc, float tr, float br, float cvx)
        @trusted nothrow @nogc {
    import core.lifetime : emplace;
    static assert(__traits(classInstanceSize, TaperedCapsuleSupport) <= SupportBuffer.sizeof);
    return emplace!TaperedCapsuleSupport(
        inBuffer.mData[0 .. __traits(classInstanceSize, TaperedCapsuleSupport)],
        tc, bc, tr, br, cvx);
}

// ---------------------------------------------------------------------------
// unittests
// ---------------------------------------------------------------------------

unittest {
    auto s = new TaperedCapsuleShapeSettings(1.0f, 0.3f, 0.5f);
    assert(s.IsValid());
    assert(!s.IsSphere());
    auto r = s.Create();
    assert(r.IsValid());
    auto sh = cast(TaperedCapsuleShape) r.Get().GetPtr();
    assert(sh !is null);
    assert(sh.GetSubType() == EShapeSubType.TaperedCapsule);
}

unittest {
    // Big sphere swallows small one but no offset → collapses to SphereShape.
    auto s = new TaperedCapsuleShapeSettings(0.0f, 1.0f, 1.0f);
    auto r = s.Create();
    assert(r.IsValid());
    assert(r.Get().GetPtr().GetSubType() == EShapeSubType.Sphere);
}

unittest {
    auto bad = new TaperedCapsuleShapeSettings(1.0f, -0.5f, 0.5f);
    assert(bad.Create().HasError());
}
