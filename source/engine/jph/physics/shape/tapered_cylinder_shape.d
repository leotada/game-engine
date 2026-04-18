// Jolt — Physics/Collision/Shape/TaperedCylinderShape.{h,cpp} port.
//
// A Y-axis cylinder with different top and bottom radii. The COM is shifted
// along Y because the shape is not symmetric around the origin in general,
// so `mTop`/`mBottom` are stored relative to the COM (not the geometric
// centre).
//
// Source: ref/JoltPhysics/Jolt/Physics/Collision/Shape/TaperedCylinderShape.{h,cpp}
module engine.jph.physics.shape.tapered_cylinder_shape;

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
import engine.jph.physics.shape.scale_helpers    : IsUniformScaleXZ,
                                                   MakeUniformScaleXZ,
                                                   MakeNonZeroScale;
import engine.jph.physics.shape.convex_shape     : ConvexShape, ConvexShapeSettings,
                                                   Support, SupportBuffer, ESupportMode;
import engine.jph.physics.shape.cylinder_shape   : CylinderShape, CylinderShapeSettings;

@safe:

private enum float JPH_PI = 3.14159265358979323846f;
private enum float cDefaultConvexRadius = 0.05f;

private float fmin(float a, float b) pure nothrow @nogc { return a < b ? a : b; }
private float fmax(float a, float b) pure nothrow @nogc { return a > b ? a : b; }
private float sq(float v)            pure nothrow @nogc { return v * v; }

final class TaperedCylinderShapeSettings : ConvexShapeSettings {
    float mHalfHeight   = 0.0f;
    float mTopRadius    = 0.0f;
    float mBottomRadius = 0.0f;
    float mConvexRadius = 0.0f;

    this() nothrow {}

    this(float inHalfHeight, float inTopRadius, float inBottomRadius,
         float inConvexRadius = cDefaultConvexRadius,
         const PhysicsMaterial inMaterial = null) @trusted nothrow {
        super(inMaterial);
        mHalfHeight   = inHalfHeight;
        mTopRadius    = inTopRadius;
        mBottomRadius = inBottomRadius;
        mConvexRadius = inConvexRadius;
    }

    /// If top == bottom, falls back to a regular cylinder.
    override ShapeResult Create() const @trusted {
        auto self = cast(TaperedCylinderShapeSettings) this;
        if (self.mCachedResult.IsValid || self.mCachedResult.HasError)
            return self.mCachedResult;

        if (mTopRadius == mBottomRadius) {
            auto cyl = new CylinderShapeSettings(mHalfHeight, mTopRadius, mConvexRadius, mMaterial);
            self.mCachedResult = cyl.Create();
            return self.mCachedResult;
        }

        auto shape = new TaperedCylinderShape(this);
        if (shape.mInitError.length > 0)
            self.mCachedResult = ShapeResult.sError(shape.mInitError);
        else
            self.mCachedResult = ShapeResult.sOk(Ref!Shape(shape));
        return self.mCachedResult;
    }
}

final class TaperedCylinderShape : ConvexShape {
    private float mTop          = 0.0f;
    private float mBottom       = 0.0f;
    private float mTopRadius    = 0.0f;
    private float mBottomRadius = 0.0f;
    private float mConvexRadius = 0.0f;
    package string mInitError;

    this() @trusted nothrow {
        super(EShapeSubType.TaperedCylinder);
    }

    this(const TaperedCylinderShapeSettings inSettings) @trusted nothrow {
        super(EShapeSubType.TaperedCylinder, inSettings);
        mTopRadius    = inSettings.mTopRadius;
        mBottomRadius = inSettings.mBottomRadius;
        mConvexRadius = fmin(inSettings.mConvexRadius,
                              fmin(inSettings.mTopRadius, inSettings.mBottomRadius));

        if (mTopRadius < 0.0f)         { mInitError = "Invalid top radius";    return; }
        if (mBottomRadius < 0.0f)      { mInitError = "Invalid bottom radius"; return; }
        if (mConvexRadius < 0.0f)      { mInitError = "Invalid convex radius"; return; }
        if (inSettings.mHalfHeight <= 0.0f) { mInitError = "Invalid height";   return; }

        // COM along Y: integrate(x*area(x), 0..h)/volume.
        immutable float h   = 2.0f * inSettings.mHalfHeight;
        immutable float tr  = mTopRadius,    tr2 = sq(tr);
        immutable float br  = mBottomRadius, br2 = sq(br);
        immutable float com = h * (3 * tr2 + 2 * br * tr + br2) / (4.0f * (tr2 + br * tr + br2));
        mTop    = h - com;
        mBottom = -com;
    }

    float GetTopRadius()    const nothrow @nogc { return mTopRadius; }
    float GetBottomRadius() const nothrow @nogc { return mBottomRadius; }
    float GetConvexRadius() const nothrow @nogc { return mConvexRadius; }
    float GetHalfHeight()   const nothrow @nogc { return 0.5f * (mTop - mBottom); }

    // ----- Shape overrides ---------------------------------------------------

    override Vec3 GetCenterOfMass() const nothrow @nogc {
        return Vec3(0, -0.5f * (mTop + mBottom), 0);
    }

    override AABox GetLocalBounds() const nothrow @nogc {
        immutable mr = fmax(mTopRadius, mBottomRadius);
        return AABox.sFromTwoPoints(Vec3(-mr, mBottom, -mr), Vec3(mr, mTop, mr));
    }

    override float GetInnerRadius() const nothrow @nogc {
        return fmin(mTopRadius, mBottomRadius);
    }

    override float GetVolume() const nothrow @nogc {
        return (JPH_PI / 3.0f) * (mTop - mBottom)
             * (sq(mTopRadius) + mTopRadius * mBottomRadius + sq(mBottomRadius));
    }

    override MassProperties GetMassProperties() const nothrow @nogc {
        MassProperties p;
        immutable float density = mDensity;
        p.mMass = GetVolume() * density;

        immutable float t  = mTop,  t2 = sq(t),  t3 = t * t2;
        immutable float b  = mBottom, b2 = sq(b), b3 = b * b2;
        immutable float br = mBottomRadius, br2 = sq(br), br3 = br * br2, br4 = sq(br2);
        immutable float tr = mTopRadius,    tr2 = sq(tr), tr3 = tr * tr2, tr4 = sq(tr2);

        immutable float iy = (JPH_PI / 10.0f) * density * (t - b)
                           * (br4 + tr * br3 + tr2 * br2 + tr3 * br + tr4);
        immutable float ix_delta = (JPH_PI / 30.0f) * density
            * ((t3 + 2 * b * t2 + 3 * b2 * t - 6 * b3) * br2
             + (3 * t3 + b * t2 - b2 * t - 3 * b3) * tr * br
             + (6 * t3 - 3 * b * t2 - 2 * b2 * t - b3) * tr2);
        immutable float ix = ix_delta + iy / 2.0f;
        p.mInertia = Mat44.sScale(Vec3(ix, iy, ix));
        return p;
    }

    override Vec3 GetSurfaceNormal(const SubShapeID inSubShapeID,
                                   Vec3 inLocalSurfacePosition) const nothrow @nogc {
        assert(inSubShapeID.IsEmpty(), "Invalid subshape ID");
        enum float cEpsilon = 1.0e-5f;
        immutable y = inLocalSurfacePosition.GetY();
        if (y > mTop - cEpsilon)    return Vec3(0, 1, 0);
        if (y < mBottom + cEpsilon) return Vec3(0, -1, 0);
        immutable Vec3 normalXZ = (Vec3(1, 0, 1) * inLocalSurfacePosition).NormalizedOr(Vec3.sAxisX());
        immutable float tanA = (mBottomRadius - mTopRadius) / (mTop - mBottom);
        return Vec3(normalXZ.GetX(), tanA, normalXZ.GetZ()).Normalized();
    }

    override bool IsValidScale(Vec3 inScale) const nothrow @nogc {
        return super.IsValidScale(inScale) && IsUniformScaleXZ(inScale.Abs());
    }

    override Vec3 MakeScaleValid(Vec3 inScale) const nothrow @nogc {
        immutable s = MakeNonZeroScale(inScale);
        return s.GetSign() * MakeUniformScaleXZ(s.Abs());
    }

    override ShapeStats GetStats() const nothrow @nogc {
        return ShapeStats(__traits(classInstanceSize, TaperedCylinderShape), 0);
    }

    // ----- ConvexShape overrides --------------------------------------------

    override const(Support) GetSupportFunction(ESupportMode inMode,
                                               ref SupportBuffer inBuffer,
                                               Vec3 inScale) const nothrow @nogc {
        assert(IsValidScale(inScale));
        float top, bottom, topR, botR, cvxR;
        getScaled(inScale, top, bottom, topR, botR, cvxR);

        final switch (inMode) {
        case ESupportMode.IncludeConvexRadius:
        case ESupportMode.Default:
            return makeSupport(inBuffer, top, bottom, topR, botR, 0.0f);
        case ESupportMode.ExcludeConvexRadius:
            return makeSupport(inBuffer, top - cvxR, bottom + cvxR,
                               topR - cvxR, botR - cvxR, cvxR);
        }
    }

    private void getScaled(Vec3 inScale,
                           ref float outTop, ref float outBottom,
                           ref float outTopR, ref float outBottomR,
                           ref float outConvexR) const nothrow @nogc {
        immutable abs   = inScale.Abs();
        immutable sxz   = abs.GetX();
        immutable sy    = inScale.GetY();
        outTop      = sy * mTop;
        outBottom   = sy * mBottom;
        outTopR     = sxz * mTopRadius;
        outBottomR  = sxz * mBottomRadius;
        outConvexR  = fmin(abs.GetY(), sxz) * mConvexRadius;
        if (outBottom > outTop) {
            // Negative Y scale flipped the cylinder.
            immutable t = outTop;     outTop     = outBottom;     outBottom    = t;
            immutable r = outTopR;    outTopR    = outBottomR;    outBottomR   = r;
        }
    }
}

// ---------------------------------------------------------------------------
// Support
// ---------------------------------------------------------------------------

private final class TaperedCylinderSupport : Support {
    private float mTop, mBottom, mTopR, mBotR, mConvexR;

    this(float top, float bottom, float topR, float botR, float cvxR) @trusted nothrow @nogc {
        mTop = top; mBottom = bottom; mTopR = topR; mBotR = botR; mConvexR = cvxR;
    }

    override Vec3 GetSupport(Vec3 inDirection) const nothrow @nogc {
        immutable float x = inDirection.GetX();
        immutable float y = inDirection.GetY();
        immutable float z = inDirection.GetZ();
        import std.math : sqrt;
        immutable float o = sqrt(x * x + z * z);
        if (o > 0.0f) {
            immutable Vec3 topS = Vec3((mTopR * x) / o, mTop,    (mTopR * z) / o);
            immutable Vec3 botS = Vec3((mBotR * x) / o, mBottom, (mBotR * z) / o);
            return inDirection.Dot(topS) > inDirection.Dot(botS) ? topS : botS;
        }
        return y > 0.0f ? Vec3(0, mTop, 0) : Vec3(0, mBottom, 0);
    }

    override float GetConvexRadius() const nothrow @nogc { return mConvexR; }
}

private const(Support) makeSupport(ref SupportBuffer inBuffer,
                                   float top, float bottom, float topR, float botR, float cvxR)
        @trusted nothrow @nogc {
    import core.lifetime : emplace;
    static assert(__traits(classInstanceSize, TaperedCylinderSupport) <= SupportBuffer.sizeof);
    return emplace!TaperedCylinderSupport(
        inBuffer.mData[0 .. __traits(classInstanceSize, TaperedCylinderSupport)],
        top, bottom, topR, botR, cvxR);
}

// ---------------------------------------------------------------------------
// unittests
// ---------------------------------------------------------------------------

unittest {
    auto s = new TaperedCylinderShapeSettings(1.0f, 0.5f, 1.0f);
    auto r = s.Create();
    assert(r.IsValid());
    auto sh = cast(TaperedCylinderShape) r.Get().GetPtr();
    assert(sh !is null);
    assert(sh.GetTopRadius() == 0.5f);
    assert(sh.GetBottomRadius() == 1.0f);
    assert(sh.GetSubType() == EShapeSubType.TaperedCylinder);
}

unittest {
    // Equal radii falls back to a regular cylinder.
    auto s = new TaperedCylinderShapeSettings(2.0f, 1.0f, 1.0f);
    auto r = s.Create();
    assert(r.IsValid());
    assert(r.Get().GetPtr().GetSubType() == EShapeSubType.Cylinder);
}

unittest {
    auto bad = new TaperedCylinderShapeSettings(0.0f, 1.0f, 0.5f);
    assert(bad.Create().HasError());
}
