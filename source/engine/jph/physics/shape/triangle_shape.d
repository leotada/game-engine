// Jolt — Physics/Collision/Shape/TriangleShape.{h,cpp} port.
//
// A single triangle as a convex shape. The triangle is infinitely thin for
// raycasting/face purposes; the convex radius is only used for shape-vs-shape
// (GJK) collision and is the only contributor to the local bounds expansion.
//
// Source: ref/JoltPhysics/Jolt/Physics/Collision/Shape/TriangleShape.{h,cpp}
module engine.jph.physics.shape.triangle_shape;

import engine.jph.core.reference            : Ref;
import engine.jph.math.vec3                 : Vec3;
import engine.jph.math.mat44                : Mat44;
import engine.jph.geometry.aabox            : AABox;
import engine.jph.geometry.ray_triangle     : RayTriangle;
import engine.jph.geometry.convexsupport    : TriangleConvexSupport;
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

@safe:

final class TriangleShapeSettings : ConvexShapeSettings {
    Vec3  mV1;
    Vec3  mV2;
    Vec3  mV3;
    float mConvexRadius = 0.0f;

    this() nothrow {}

    this(Vec3 inV1, Vec3 inV2, Vec3 inV3,
         float inConvexRadius = 0.0f,
         const PhysicsMaterial inMaterial = null) @trusted nothrow {
        super(inMaterial);
        mV1 = inV1; mV2 = inV2; mV3 = inV3;
        mConvexRadius = inConvexRadius;
    }

    override ShapeResult Create() const @trusted {
        auto self = cast(TriangleShapeSettings) this;
        if (self.mCachedResult.IsValid || self.mCachedResult.HasError)
            return self.mCachedResult;
        if (mConvexRadius < 0.0f) {
            self.mCachedResult = ShapeResult.sError("Invalid convex radius");
            return self.mCachedResult;
        }
        auto shape = new TriangleShape(this);
        self.mCachedResult = ShapeResult.sOk(Ref!Shape(shape));
        return self.mCachedResult;
    }
}

final class TriangleShape : ConvexShape {
    private Vec3  mV1;
    private Vec3  mV2;
    private Vec3  mV3;
    private float mConvexRadius = 0.0f;

    this() @trusted nothrow {
        super(EShapeSubType.Triangle);
    }

    this(const TriangleShapeSettings inSettings) @trusted nothrow {
        super(EShapeSubType.Triangle, inSettings);
        mV1 = inSettings.mV1; mV2 = inSettings.mV2; mV3 = inSettings.mV3;
        mConvexRadius = inSettings.mConvexRadius;
    }

    this(Vec3 inV1, Vec3 inV2, Vec3 inV3,
         float inConvexRadius = 0.0f,
         const PhysicsMaterial inMaterial = null) @trusted nothrow {
        super(EShapeSubType.Triangle, inMaterial);
        assert(inConvexRadius >= 0.0f);
        mV1 = inV1; mV2 = inV2; mV3 = inV3;
        mConvexRadius = inConvexRadius;
    }

    Vec3  GetVertex1() const nothrow @nogc { return mV1; }
    Vec3  GetVertex2() const nothrow @nogc { return mV2; }
    Vec3  GetVertex3() const nothrow @nogc { return mV3; }
    float GetConvexRadius() const nothrow @nogc { return mConvexRadius; }

    // ----- Shape overrides ---------------------------------------------------

    override AABox GetLocalBounds() const nothrow @nogc {
        AABox b = AABox.sFromTwoPoints(mV1, mV1);
        b.Encapsulate(mV2);
        b.Encapsulate(mV3);
        b.ExpandBy(Vec3.sReplicate(mConvexRadius));
        return b;
    }

    override AABox GetWorldSpaceBounds(Mat44 inCenterOfMassTransform, Vec3 inScale)
            const nothrow @nogc {
        assert(IsValidScale(inScale));
        immutable v1 = inCenterOfMassTransform * (inScale * mV1);
        immutable v2 = inCenterOfMassTransform * (inScale * mV2);
        immutable v3 = inCenterOfMassTransform * (inScale * mV3);
        AABox b = AABox.sFromTwoPoints(v1, v1);
        b.Encapsulate(v2);
        b.Encapsulate(v3);
        b.ExpandBy(inScale * mConvexRadius);
        return b;
    }

    override float GetInnerRadius() const nothrow @nogc { return mConvexRadius; }

    /// Triangles have zero volume, so default mass properties are returned.
    /// Callers that want a dynamic triangle must override mass externally.
    override MassProperties GetMassProperties() const nothrow @nogc {
        return MassProperties();
    }

    override Vec3 GetSurfaceNormal(const SubShapeID inSubShapeID,
                                   Vec3 inLocalSurfacePosition) const nothrow @nogc {
        cast(void) inLocalSurfacePosition;
        assert(inSubShapeID.IsEmpty(), "Invalid subshape ID");
        immutable c = (mV2 - mV1).Cross(mV3 - mV1);
        immutable len = c.Length();
        return len != 0.0f ? c / len : Vec3(0, 1, 0);
    }

    override float GetVolume() const nothrow @nogc { return 0.0f; }

    override bool CastRay(const RayCast inRay,
                          const SubShapeIDCreator inSubShapeIDCreator,
                          ref RayCastResult ioHit) const nothrow @nogc {
        immutable f = RayTriangle(inRay.mOrigin, inRay.mDirection, mV1, mV2, mV3);
        if (f < ioHit.mFraction) {
            ioHit.mFraction = f;
            ioHit.mSubShapeID2 = inSubShapeIDCreator.GetID();
            return true;
        }
        return false;
    }

    override bool IsValidScale(Vec3 inScale) const nothrow @nogc {
        return super.IsValidScale(inScale)
            && (mConvexRadius == 0.0f || IsUniformScale(inScale.Abs()));
    }

    override Vec3 MakeScaleValid(Vec3 inScale) const nothrow @nogc {
        immutable s = MakeNonZeroScale(inScale);
        if (mConvexRadius == 0.0f) return s;
        return s.GetSign() * MakeUniformScale(s.Abs());
    }

    override ShapeStats GetStats() const nothrow @nogc {
        return ShapeStats(__traits(classInstanceSize, TriangleShape), 1);
    }

    // ----- ConvexShape overrides --------------------------------------------

    override const(Support) GetSupportFunction(ESupportMode inMode,
                                               ref SupportBuffer inBuffer,
                                               Vec3 inScale) const nothrow @nogc {
        immutable v1 = inScale * mV1;
        immutable v2 = inScale * mV2;
        immutable v3 = inScale * mV3;
        final switch (inMode) {
        case ESupportMode.IncludeConvexRadius:
        case ESupportMode.Default:
            if (mConvexRadius > 0.0f)
                return makeWithConvex(inBuffer, v1, v2, v3, mConvexRadius);
            return makeNoConvex(inBuffer, v1, v2, v3);
        case ESupportMode.ExcludeConvexRadius:
            return makeNoConvex(inBuffer, v1, v2, v3);
        }
    }
}

// ---------------------------------------------------------------------------
// Support
// ---------------------------------------------------------------------------

private final class TriangleNoConvex : Support {
    private TriangleConvexSupport mTri;

    this(Vec3 v1, Vec3 v2, Vec3 v3) @trusted nothrow @nogc {
        mTri = TriangleConvexSupport(v1, v2, v3);
    }

    override Vec3 GetSupport(Vec3 inDirection) const nothrow @nogc {
        return mTri.GetSupport(inDirection);
    }

    override float GetConvexRadius() const nothrow @nogc { return 0.0f; }
}

private final class TriangleWithConvex : Support {
    private float mConvexRadius;
    private TriangleConvexSupport mTri;

    this(Vec3 v1, Vec3 v2, Vec3 v3, float cr) @trusted nothrow @nogc {
        mConvexRadius = cr;
        mTri = TriangleConvexSupport(v1, v2, v3);
    }

    override Vec3 GetSupport(Vec3 inDirection) const nothrow @nogc {
        Vec3 s = mTri.GetSupport(inDirection);
        immutable len = inDirection.Length();
        if (len > 0.0f) s = s + inDirection * (mConvexRadius / len);
        return s;
    }

    override float GetConvexRadius() const nothrow @nogc { return mConvexRadius; }
}

private const(Support) makeNoConvex(ref SupportBuffer inBuffer, Vec3 v1, Vec3 v2, Vec3 v3)
        @trusted nothrow @nogc {
    import core.lifetime : emplace;
    static assert(__traits(classInstanceSize, TriangleNoConvex) <= SupportBuffer.sizeof);
    return emplace!TriangleNoConvex(inBuffer.mData[0 .. __traits(classInstanceSize, TriangleNoConvex)],
                                     v1, v2, v3);
}

private const(Support) makeWithConvex(ref SupportBuffer inBuffer,
                                      Vec3 v1, Vec3 v2, Vec3 v3, float cr)
        @trusted nothrow @nogc {
    import core.lifetime : emplace;
    static assert(__traits(classInstanceSize, TriangleWithConvex) <= SupportBuffer.sizeof);
    return emplace!TriangleWithConvex(inBuffer.mData[0 .. __traits(classInstanceSize, TriangleWithConvex)],
                                       v1, v2, v3, cr);
}

// ---------------------------------------------------------------------------
// unittests
// ---------------------------------------------------------------------------

unittest {
    auto t = new TriangleShape(Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0));
    assert(t.GetSubType() == EShapeSubType.Triangle);
    assert(t.GetVolume() == 0.0f);
    immutable n = t.GetSurfaceNormal(SubShapeID.init, Vec3.sZero());
    assert(n == Vec3(0, 0, 1));
}

unittest {
    auto s = new TriangleShapeSettings(Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0));
    assert(s.Create().IsValid());

    auto bad = new TriangleShapeSettings(Vec3(0,0,0), Vec3(1,0,0), Vec3(0,1,0), -1.0f);
    assert(bad.Create().HasError());
}
