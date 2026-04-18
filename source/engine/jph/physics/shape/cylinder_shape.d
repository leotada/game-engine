// Jolt — Physics/Collision/Shape/CylinderShape.{h,cpp} port.
//
// Y-axis cylinder centered at origin. Convex radius is *carved* off the
// height/radius (chamfering the rim) so increasing it never enlarges the
// outer hull. Only uniform-XZ scale is permitted (otherwise the cross
// section would be elliptical).
//
// Source: ref/JoltPhysics/Jolt/Physics/Collision/Shape/CylinderShape.{h,cpp}
module engine.jph.physics.shape.cylinder_shape;

import engine.jph.core.reference            : Ref;
import engine.jph.math.vec3                 : Vec3;
import engine.jph.math.mat44                : Mat44;
import engine.jph.geometry.aabox            : AABox;
import engine.jph.geometry.ray_cylinder     : RayCylinder;
import engine.jph.physics.body.massproperties : MassProperties;
import engine.jph.physics.shape.shape          : Shape, ShapeResult, ShapeStats,
                                                  EShapeSubType;
import engine.jph.physics.shape.physics_material : PhysicsMaterial;
import engine.jph.physics.shape.sub_shape_id     : SubShapeID, SubShapeIDCreator;
import engine.jph.physics.shape.cast_result      : RayCast, RayCastResult;
import engine.jph.physics.shape.scale_helpers    : IsUniformScaleXZ,
                                                   MakeUniformScaleXZ,
                                                   MakeNonZeroScale,
                                                   ScaleConvexRadius;
import engine.jph.physics.shape.convex_shape     : ConvexShape, ConvexShapeSettings,
                                                   Support, SupportBuffer, ESupportMode;

@safe:

private enum float JPH_PI = 3.14159265358979323846f;
private enum float cDefaultConvexRadius = 0.05f;

private float fmin(float a, float b) pure nothrow @nogc { return a < b ? a : b; }
private float sq(float v)            pure nothrow @nogc { return v * v; }
private float sgn(float v)           pure nothrow @nogc { return v >= 0.0f ? 1.0f : -1.0f; }

/// Authoring-time settings.
final class CylinderShapeSettings : ConvexShapeSettings {
    float mHalfHeight   = 0.0f;
    float mRadius       = 0.0f;
    float mConvexRadius = 0.0f;

    this() nothrow {}

    this(float inHalfHeight, float inRadius,
         float inConvexRadius = cDefaultConvexRadius,
         const PhysicsMaterial inMaterial = null) @trusted nothrow {
        super(inMaterial);
        mHalfHeight   = inHalfHeight;
        mRadius       = inRadius;
        mConvexRadius = inConvexRadius;
    }

    override ShapeResult Create() const @trusted {
        auto self = cast(CylinderShapeSettings) this;
        if (self.mCachedResult.IsValid || self.mCachedResult.HasError)
            return self.mCachedResult;

        if (mHalfHeight < 0.0f)   { self.mCachedResult = ShapeResult.sError("Invalid height");        return self.mCachedResult; }
        if (mRadius < 0.0f)       { self.mCachedResult = ShapeResult.sError("Invalid radius");        return self.mCachedResult; }
        if (mConvexRadius < 0.0f) { self.mCachedResult = ShapeResult.sError("Invalid convex radius"); return self.mCachedResult; }

        auto shape = new CylinderShape(this);
        self.mCachedResult = ShapeResult.sOk(Ref!Shape(shape));
        return self.mCachedResult;
    }
}

/// Y-axis cylinder.
final class CylinderShape : ConvexShape {
    private float mHalfHeight   = 0.0f;
    private float mRadius       = 0.0f;
    private float mConvexRadius = 0.0f;

    this() @trusted nothrow {
        super(EShapeSubType.Cylinder);
    }

    this(const CylinderShapeSettings inSettings) @trusted nothrow {
        super(EShapeSubType.Cylinder, inSettings);
        mHalfHeight   = inSettings.mHalfHeight;
        mRadius       = inSettings.mRadius;
        mConvexRadius = fmin(inSettings.mConvexRadius, fmin(inSettings.mHalfHeight, inSettings.mRadius));
    }

    this(float inHalfHeight, float inRadius,
         float inConvexRadius = cDefaultConvexRadius,
         const PhysicsMaterial inMaterial = null) @trusted nothrow {
        super(EShapeSubType.Cylinder, inMaterial);
        assert(inHalfHeight >= 0.0f);
        assert(inRadius >= 0.0f);
        assert(inConvexRadius >= 0.0f);
        mHalfHeight   = inHalfHeight;
        mRadius       = inRadius;
        mConvexRadius = fmin(inConvexRadius, fmin(inHalfHeight, inRadius));
    }

    float GetHalfHeight()   const nothrow @nogc { return mHalfHeight; }
    float GetRadius()       const nothrow @nogc { return mRadius; }
    float GetConvexRadius() const nothrow @nogc { return mConvexRadius; }

    // ----- Shape overrides ---------------------------------------------------

    override AABox GetLocalBounds() const nothrow @nogc {
        immutable e = Vec3(mRadius, mHalfHeight, mRadius);
        return AABox.sFromTwoPoints(-e, e);
    }

    override float GetInnerRadius() const nothrow @nogc {
        return mHalfHeight < mRadius ? mHalfHeight : mRadius;
    }

    override MassProperties GetMassProperties() const nothrow @nogc {
        MassProperties p;
        immutable r2 = sq(mRadius);
        immutable h  = 2.0f * mHalfHeight;
        p.mMass = JPH_PI * r2 * h * mDensity;

        immutable iy = r2 * p.mMass * 0.5f;
        immutable ix = iy * 0.5f + p.mMass * h * h / 12.0f;
        p.mInertia = Mat44.sScale(Vec3(ix, iy, ix));
        return p;
    }

    override Vec3 GetSurfaceNormal(const SubShapeID inSubShapeID,
                                   Vec3 inLocalSurfacePosition) const nothrow @nogc {
        assert(inSubShapeID.IsEmpty(), "Invalid subshape ID");
        immutable Vec3 xz = Vec3(inLocalSurfacePosition.GetX(), 0, inLocalSurfacePosition.GetZ());
        immutable float xzLen = xz.Length();
        immutable float dCurved = xzLen > mRadius ? xzLen - mRadius : mRadius - xzLen;
        immutable float ay = inLocalSurfacePosition.GetY() < 0 ? -inLocalSurfacePosition.GetY() : inLocalSurfacePosition.GetY();
        immutable float dCap = ay > mHalfHeight ? ay - mHalfHeight : mHalfHeight - ay;
        if (dCurved < dCap)
            return xzLen > 0.0f ? xz / xzLen : Vec3.sAxisX();
        return inLocalSurfacePosition.GetY() > 0.0f ? Vec3(0, 1, 0) : Vec3(0, -1, 0);
    }

    override float GetVolume() const nothrow @nogc {
        return 2.0f * JPH_PI * mHalfHeight * sq(mRadius);
    }

    override bool CastRay(const RayCast inRay,
                          const SubShapeIDCreator inSubShapeIDCreator,
                          ref RayCastResult ioHit) const nothrow @nogc {
        immutable f = RayCylinder(inRay.mOrigin, inRay.mDirection, mHalfHeight, mRadius);
        if (f < ioHit.mFraction) {
            ioHit.mFraction = f;
            ioHit.mSubShapeID2 = inSubShapeIDCreator.GetID();
            return true;
        }
        return false;
    }

    override bool IsValidScale(Vec3 inScale) const nothrow @nogc {
        return super.IsValidScale(inScale) && IsUniformScaleXZ(inScale.Abs());
    }

    override Vec3 MakeScaleValid(Vec3 inScale) const nothrow @nogc {
        immutable s = MakeNonZeroScale(inScale);
        return s.GetSign() * MakeUniformScaleXZ(s.Abs());
    }

    override ShapeStats GetStats() const nothrow @nogc {
        return ShapeStats(__traits(classInstanceSize, CylinderShape), 0);
    }

    // ----- ConvexShape overrides --------------------------------------------

    override const(Support) GetSupportFunction(ESupportMode inMode,
                                               ref SupportBuffer inBuffer,
                                               Vec3 inScale) const nothrow @nogc {
        assert(IsValidScale(inScale));
        immutable abs   = inScale.Abs();
        immutable sxz   = abs.GetX();
        immutable sy    = abs.GetY();
        immutable shh   = sy * mHalfHeight;
        immutable srad  = sxz * mRadius;
        immutable scvx  = ScaleConvexRadius(mConvexRadius, inScale);

        final switch (inMode) {
        case ESupportMode.IncludeConvexRadius:
        case ESupportMode.Default:
            return makeCyl(inBuffer, shh, srad, 0.0f);
        case ESupportMode.ExcludeConvexRadius:
            return makeCyl(inBuffer, shh - scvx, srad - scvx, scvx);
        }
    }
}

// ---------------------------------------------------------------------------
// Support
// ---------------------------------------------------------------------------

private final class CylinderSupport : Support {
    private float mHalfHeight, mRadius, mConvexRadius;

    this(float inHH, float inR, float inCR) @trusted nothrow @nogc {
        mHalfHeight = inHH; mRadius = inR; mConvexRadius = inCR;
    }

    override Vec3 GetSupport(Vec3 inDirection) const nothrow @nogc {
        // Gino van den Bergen, "A Fast and Robust GJK Implementation", p.8.
        immutable float x = inDirection.GetX();
        immutable float y = inDirection.GetY();
        immutable float z = inDirection.GetZ();
        import std.math : sqrt;
        immutable float o = sqrt(x * x + z * z);
        immutable float sy = sgn(y) * mHalfHeight;
        if (o > 0.0f)
            return Vec3((mRadius * x) / o, sy, (mRadius * z) / o);
        return Vec3(0, sy, 0);
    }

    override float GetConvexRadius() const nothrow @nogc { return mConvexRadius; }
}

private const(Support) makeCyl(ref SupportBuffer inBuffer, float hh, float r, float cr)
        @trusted nothrow @nogc {
    import core.lifetime : emplace;
    static assert(__traits(classInstanceSize, CylinderSupport) <= SupportBuffer.sizeof);
    return emplace!CylinderSupport(inBuffer.mData[0 .. __traits(classInstanceSize, CylinderSupport)],
                                    hh, r, cr);
}

// ---------------------------------------------------------------------------
// unittests
// ---------------------------------------------------------------------------

unittest {
    auto c = new CylinderShape(2.0f, 1.0f);
    assert(c.GetHalfHeight() == 2.0f);
    assert(c.GetRadius() == 1.0f);
    assert(c.GetSubType() == EShapeSubType.Cylinder);
    assert(c.GetInnerRadius() == 1.0f);
    immutable b = c.GetLocalBounds();
    assert(b.GetExtent() == Vec3(1, 2, 1));
}

unittest {
    auto s = new CylinderShapeSettings(1.0f, 0.5f);
    auto r = s.Create();
    assert(r.IsValid());
}

unittest {
    auto bad = new CylinderShapeSettings(-1.0f, 1.0f);
    assert(bad.Create().HasError());
}
