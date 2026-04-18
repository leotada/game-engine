// Jolt — Physics/Collision/Shape/ConvexShape.{h,cpp} port (Phase 4 essentials).
//
// `ConvexShape` is the abstract base of every primitive convex collider
// (Sphere, Box, Capsule, Cylinder, …). It adds the Jolt support-mapping
// machinery (`Support` / `SupportBuffer` / `ESupportMode`) that the GJK
// narrowphase depends on, plus a uniform-density material slot.
//
// Construction is *not* `@nogc` because it pre-fills the default material
// (which may allocate on its very first call). Once constructed all hot-path
// queries (`GetMaterial`, `GetSupportFunction`) are `@nogc nothrow`.
//
// Source: ref/JoltPhysics/Jolt/Physics/Collision/Shape/ConvexShape.{h,cpp}
module engine.jph.physics.shape.convex_shape;

import engine.jph.core.reference          : RefConst;
import engine.jph.math.vec3               : Vec3;
import engine.jph.physics.shape.shape     : Shape, ShapeSettings, EShapeType,
                                             EShapeSubType;
import engine.jph.physics.shape.physics_material : PhysicsMaterial;
import engine.jph.physics.shape.sub_shape_id : SubShapeID, SubShapeIDCreator;
import engine.jph.physics.shape.cast_result   : RayCast, RayCastResult;
import engine.jph.geometry.gjk             : GJKClosestPoint;

@safe:

/// How the GetSupport function should behave (mirrors Jolt's enum).
enum ESupportMode : ubyte {
    ExcludeConvexRadius = 0,
    IncludeConvexRadius = 1,
    Default             = 2,
}

/// In-place buffer for `Support` objects, sized to fit the largest concrete
/// support implementation. Matches Jolt's 4160-byte aligned blob.
align(16) struct SupportBuffer {
@safe:
    ubyte[4160] mData = void;
}

/// Polymorphic GJK support function. Concrete shapes return a pointer to an
/// instance constructed in-place inside a `SupportBuffer`. The instance has
/// the lifetime of that buffer — its destructor is *not* run by the engine.
abstract class Support {
@safe:
    /// Local-space support point for the given direction (relative to COM).
    abstract Vec3  GetSupport(Vec3 inDirection) const nothrow @nogc;

    /// Convex radius bolted onto the underlying hull (or 0 when `inMode`
    /// included it in `GetSupport`).
    abstract float GetConvexRadius() const nothrow @nogc;
}

/// Authoring-time settings for any `ConvexShape` subclass.
abstract class ConvexShapeSettings : ShapeSettings {
    RefConst!PhysicsMaterial mMaterial;
    float mDensity = 1000.0f;

    this() nothrow {}

    this(const PhysicsMaterial inMaterial) @trusted nothrow {
        if (inMaterial !is null)
            mMaterial = RefConst!PhysicsMaterial(cast(PhysicsMaterial) inMaterial);
    }

    final void SetDensity(float inDensity) nothrow @nogc { mDensity = inDensity; }
}

/// Abstract base class for all primitive convex shapes.
abstract class ConvexShape : Shape {
    protected RefConst!PhysicsMaterial mMaterial;
    protected float mDensity = 1000.0f;

    /// Construct with a possibly-null material. Defers to `sDefault()` so
    /// subsequent `GetMaterial()` calls are guaranteed non-null and `@nogc`.
    this(EShapeSubType inSubType, const PhysicsMaterial inMaterial = null)
            @trusted nothrow {
        super(EShapeType.Convex, inSubType);
        if (inMaterial !is null)
            mMaterial = RefConst!PhysicsMaterial(cast(PhysicsMaterial) inMaterial);
        else
            mMaterial = RefConst!PhysicsMaterial(PhysicsMaterial.sDefault());
    }

    /// Construct from settings — copies material + density.
    this(EShapeSubType inSubType, const ConvexShapeSettings inSettings)
            @trusted nothrow {
        super(EShapeType.Convex, inSubType);
        if (!inSettings.mMaterial.isNull)
            mMaterial = RefConst!PhysicsMaterial(cast(PhysicsMaterial) inSettings.mMaterial.GetPtr());
        else
            mMaterial = RefConst!PhysicsMaterial(PhysicsMaterial.sDefault());
        mDensity = inSettings.mDensity;
    }

    // ----- Shape overrides ---------------------------------------------------

    override final uint GetSubShapeIDBitsRecursive() const nothrow @nogc { return 0; }

    /// Material lookup via SubShapeID (must be empty for a convex shape).
    override const(PhysicsMaterial) GetMaterial(const SubShapeID inSubShapeID)
            const nothrow @nogc {
        assert(inSubShapeID.IsEmpty(), "Invalid subshape ID");
        return GetMaterial();
    }

    // ----- material / density ------------------------------------------------

    final const(PhysicsMaterial) GetMaterial() const nothrow @nogc @trusted {
        // mMaterial is guaranteed non-null after construction.
        return (cast() mMaterial).GetPtr();
    }

    final void SetMaterial(const PhysicsMaterial inMaterial) @trusted nothrow {
        if (inMaterial !is null)
            mMaterial = RefConst!PhysicsMaterial(cast(PhysicsMaterial) inMaterial);
        else
            mMaterial = RefConst!PhysicsMaterial(PhysicsMaterial.sDefault());
    }

    final float GetDensity() const nothrow @nogc { return mDensity; }
    final void  SetDensity(float v) nothrow @nogc { mDensity = v; }

    // ----- support function (implemented by concrete shape) ------------------

    abstract const(Support) GetSupportFunction(ESupportMode inMode,
                                               ref SupportBuffer inBuffer,
                                               Vec3 inScale) const nothrow @nogc;

    // ----- ray cast ----------------------------------------------------------

    /// GJK-based fallback ray cast. Concrete shapes with cheaper analytic
    /// formulas (Sphere, Box, Capsule, Cylinder, Triangle) override this.
    override bool CastRay(const RayCast inRay,
                          const SubShapeIDCreator inSubShapeIDCreator,
                          ref RayCastResult ioHit) const nothrow @nogc {
        SupportBuffer buffer;
        const(Support) support = GetSupportFunction(
            ESupportMode.IncludeConvexRadius, buffer, Vec3.sOne());
        GJKClosestPoint gjk;
        enum float cDefaultCollisionTolerance = 1.0e-4f;
        if (gjk.CastRay(inRay.mOrigin, inRay.mDirection,
                        cDefaultCollisionTolerance, support, ioHit.mFraction)) {
            ioHit.mSubShapeID2 = inSubShapeIDCreator.GetID();
            return true;
        }
        return false;
    }
}
