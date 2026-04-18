// Jolt — Physics/Collision/Shape/BoxShape.{h,cpp} port.
//
// Axis-aligned box centred on the origin. Ships with a *convex radius*
// (default `cDefaultConvexRadius = 0.05 m`) which is internally subtracted
// from the half-extent so growing the radius does **not** enlarge the box —
// it only chamfers the corners for cheaper GJK contact stability.
//
// Source: ref/JoltPhysics/Jolt/Physics/Collision/Shape/BoxShape.{h,cpp}
//         ref/JoltPhysics/Jolt/Physics/PhysicsSettings.h (cDefaultConvexRadius)
module engine.jph.physics.shape.box_shape;

import engine.jph.core.reference          : Ref;
import engine.jph.math.vec3               : Vec3;
import engine.jph.geometry.aabox          : AABox;
import engine.jph.geometry.ray_aabox      : RayAABox, RayInvDirection;
import engine.jph.physics.body.massproperties : MassProperties;
import engine.jph.physics.shape.shape         : Shape, ShapeResult, ShapeStats,
                                                 EShapeSubType;
import engine.jph.physics.shape.physics_material : PhysicsMaterial;
import engine.jph.physics.shape.sub_shape_id    : SubShapeID, SubShapeIDCreator;
import engine.jph.physics.shape.cast_result     : RayCast, RayCastResult;
import engine.jph.physics.shape.scale_helpers   : ScaleConvexRadius;
import engine.jph.physics.shape.convex_shape    : ConvexShape, ConvexShapeSettings,
                                                  Support, SupportBuffer, ESupportMode;

@safe:

/// Default convex radius for boxes (5 cm). Mirrors Jolt's
/// `cDefaultConvexRadius` from `PhysicsSettings.h`.
enum float cDefaultConvexRadius = 0.05f;

private float fmin(float a, float b) pure nothrow @nogc { return a < b ? a : b; }
private float fmax(float a, float b) pure nothrow @nogc { return a > b ? a : b; }

/// Authoring-time settings for a box.
final class BoxShapeSettings : ConvexShapeSettings {
    Vec3  mHalfExtent   = Vec3.sZero();
    float mConvexRadius = 0.0f;

    this() nothrow {}

    this(Vec3 inHalfExtent,
         float inConvexRadius = cDefaultConvexRadius,
         const PhysicsMaterial inMaterial = null) @trusted nothrow {
        super(inMaterial);
        mHalfExtent   = inHalfExtent;
        mConvexRadius = inConvexRadius;
    }

    override ShapeResult Create() const @trusted {
        auto self = cast(BoxShapeSettings) this;
        if (self.mCachedResult.IsValid || self.mCachedResult.HasError)
            return self.mCachedResult;

        if (mHalfExtent.ReduceMin() < 0.0f) {
            self.mCachedResult = ShapeResult.sError("Invalid half extent");
            return self.mCachedResult;
        }
        if (mConvexRadius < 0.0f) {
            self.mCachedResult = ShapeResult.sError("Invalid convex radius");
            return self.mCachedResult;
        }

        auto shape = new BoxShape(this);
        self.mCachedResult = ShapeResult.sOk(Ref!Shape(shape));
        return self.mCachedResult;
    }
}

/// A box, centred around the origin.
final class BoxShape : ConvexShape {
    private Vec3  mHalfExtent   = Vec3.sZero();
    private float mConvexRadius = 0.0f;

    this() @trusted nothrow {
        super(EShapeSubType.Box);
    }

    this(const BoxShapeSettings inSettings) @trusted nothrow {
        super(EShapeSubType.Box, inSettings);
        mHalfExtent   = inSettings.mHalfExtent;
        mConvexRadius = fmin(inSettings.mConvexRadius, inSettings.mHalfExtent.ReduceMin());
    }

    this(Vec3 inHalfExtent,
         float inConvexRadius = cDefaultConvexRadius,
         const PhysicsMaterial inMaterial = null) @trusted nothrow {
        super(EShapeSubType.Box, inMaterial);
        assert(inHalfExtent.ReduceMin() >= 0.0f);
        assert(inConvexRadius >= 0.0f);
        mHalfExtent   = inHalfExtent;
        mConvexRadius = fmin(inConvexRadius, inHalfExtent.ReduceMin());
    }

    Vec3  GetHalfExtent()   const nothrow @nogc { return mHalfExtent; }
    float GetConvexRadius() const nothrow @nogc { return mConvexRadius; }

    // ----- Shape overrides ---------------------------------------------------

    override AABox GetLocalBounds() const nothrow @nogc {
        return AABox.sFromTwoPoints(-mHalfExtent, mHalfExtent);
    }

    override float GetInnerRadius() const nothrow @nogc { return mHalfExtent.ReduceMin(); }

    override MassProperties GetMassProperties() const nothrow @nogc {
        MassProperties p;
        p.SetMassAndInertiaOfSolidBox(mHalfExtent * 2.0f, mDensity);
        return p;
    }

    override Vec3 GetSurfaceNormal(const SubShapeID inSubShapeID,
                                   Vec3 inLocalSurfacePosition) const nothrow @nogc {
        assert(inSubShapeID.IsEmpty(), "Invalid subshape ID");

        // Pick the axis on which the point is closest to the matching face.
        immutable diff   = (inLocalSurfacePosition.Abs() - mHalfExtent).Abs();
        immutable index  = diff.GetLowestComponentIndex();

        Vec3 normal = Vec3.sZero();
        normal.SetComponent(cast(uint) index,
                            inLocalSurfacePosition[cast(uint) index] > 0.0f ? 1.0f : -1.0f);
        return normal;
    }

    override float GetVolume() const nothrow @nogc {
        return GetLocalBounds().GetVolume();
    }

    override bool CastRay(const RayCast inRay,
                          const SubShapeIDCreator inSubShapeIDCreator,
                          ref RayCastResult ioHit) const nothrow @nogc {
        auto inv = RayInvDirection(inRay.mDirection);
        immutable f = fmax(RayAABox(inRay.mOrigin, inv, -mHalfExtent, mHalfExtent), 0.0f);
        if (f < ioHit.mFraction) {
            ioHit.mFraction = f;
            ioHit.mSubShapeID2 = inSubShapeIDCreator.GetID();
            return true;
        }
        return false;
    }

    override ShapeStats GetStats() const nothrow @nogc {
        return ShapeStats(__traits(classInstanceSize, BoxShape), 12);
    }

    // ----- ConvexShape overrides --------------------------------------------

    override const(Support) GetSupportFunction(ESupportMode inMode,
                                               ref SupportBuffer inBuffer,
                                               Vec3 inScale) const nothrow @nogc {
        immutable scaledHalf = inScale.Abs() * mHalfExtent;

        final switch (inMode) {
        case ESupportMode.IncludeConvexRadius:
        case ESupportMode.Default:
            return makeBoxSupport(inBuffer,
                                  AABox.sFromTwoPoints(-scaledHalf, scaledHalf),
                                  0.0f);

        case ESupportMode.ExcludeConvexRadius:
            immutable cr  = ScaleConvexRadius(mConvexRadius, inScale);
            immutable cr3 = Vec3.sReplicate(cr);
            immutable reduced = scaledHalf - cr3;
            return makeBoxSupport(inBuffer,
                                  AABox.sFromTwoPoints(-reduced, reduced),
                                  cr);
        }
    }
}

// ---------------------------------------------------------------------------
// Support implementation (placement-constructed in the caller's buffer).
// ---------------------------------------------------------------------------

private final class BoxSupport : Support {
    private AABox mBox;
    private float mConvexRadius;

    this(AABox inBox, float inConvexRadius) @trusted nothrow @nogc {
        mBox          = inBox;
        mConvexRadius = inConvexRadius;
    }

    override Vec3 GetSupport(Vec3 inDirection) const nothrow @nogc {
        return mBox.GetSupport(inDirection);
    }

    override float GetConvexRadius() const nothrow @nogc { return mConvexRadius; }
}

private const(Support) makeBoxSupport(ref SupportBuffer inBuffer,
                                      AABox inBox,
                                      float inConvexRadius) @trusted nothrow @nogc {
    import core.lifetime : emplace;

    static assert(__traits(classInstanceSize, BoxSupport) <= SupportBuffer.sizeof,
                  "BoxSupport too large for SupportBuffer");

    return emplace!BoxSupport(inBuffer.mData[0 .. __traits(classInstanceSize, BoxSupport)],
                              inBox, inConvexRadius);
}

// ---------------------------------------------------------------------------
// unittests
// ---------------------------------------------------------------------------

unittest {
    auto b = new BoxShape(Vec3(1, 2, 3));
    assert(b.GetHalfExtent() == Vec3(1, 2, 3));
    assert(b.GetSubType() == EShapeSubType.Box);
    assert(b.GetInnerRadius() == 1.0f);

    auto bounds = b.GetLocalBounds();
    assert(bounds.GetExtent() == Vec3(1, 2, 3));
}

unittest {
    auto settings = new BoxShapeSettings(Vec3(2, 2, 2), 0.05f);
    auto r = settings.Create();
    assert(r.IsValid());
    assert((cast(BoxShape) r.Get().GetPtr()).GetHalfExtent() == Vec3(2, 2, 2));

    // Cached on second call.
    auto r2 = settings.Create();
    assert(r2.IsValid);
    assert(r2.Get().GetPtr() is r.Get().GetPtr());
}

unittest {
    auto bad = new BoxShapeSettings(Vec3(-1, 1, 1));
    assert(bad.Create().HasError());

    auto badRadius = new BoxShapeSettings(Vec3(1, 1, 1), -1.0f);
    assert(badRadius.Create().HasError());
}

unittest {
    // Mass of a unit cube (size 2x2x2) with density 1 → m = 8
    auto b = new BoxShape(Vec3(1, 1, 1));
    b.SetDensity(1.0f);
    auto p = b.GetMassProperties();
    assert(p.mMass == 8.0f);
}
