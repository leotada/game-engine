// Jolt — Physics/Collision/Shape/Shape.{h,cpp} port (Phase 4 essentials).
//
// This is the abstract base of the entire shape hierarchy. It defines:
//   * `EShapeType` / `EShapeSubType` enums (full Jolt set, even sub-types
//     not yet implemented, so values match the C++ source numerically).
//   * `ShapeSettings` — abstract factory base. Every concrete shape ships
//     a derived settings class with a `Create()` method that returns a
//     `ShapeResult` (success → `Ref!Shape`, failure → human-readable error).
//   * `Shape` — the polymorphic base. Holds shape type/subtype and a
//     user-data slot, exposes the virtual interface the rest of the engine
//     depends on (bounds, mass, support, raycast, …). Methods that aren't
//     required by Phase 4/5 are stubbed with sane defaults or `assert(false)`
//     until a later phase fills them in.
//   * `ShapeFilter` — predicate object passed to queries. Default accepts
//     everything; subclass to filter.
//
// We deliberately use *classes* here (with the existing `RefTargetMixin`
// from `engine.jph.core.reference`). The "no classes" rule in `AGENTS.md`
// applies to ECS components in the engine core; the JPH port already opted
// into ref-counted classes for `JobSystem`, `TempAllocator`, etc., and the
// Jolt source models the entire shape system this way.
//
// Source: ref/JoltPhysics/Jolt/Physics/Collision/Shape/Shape.h + .cpp
//         ref/JoltPhysics/Jolt/Physics/Collision/ShapeFilter.h
module engine.jph.physics.shape.shape;

import engine.jph.core.reference : RefTargetMixin, Ref, RefConst;
import engine.jph.core.types     : uint8, uint64;
import engine.jph.math.vec3      : Vec3;
import engine.jph.math.mat44     : Mat44;
import engine.jph.geometry.aabox : AABox;
import engine.jph.physics.body.bodyid          : BodyID;
import engine.jph.physics.body.massproperties  : MassProperties;
import engine.jph.physics.shape.sub_shape_id   : SubShapeID, SubShapeIDCreator;
import engine.jph.physics.shape.physics_material : PhysicsMaterial;
import engine.jph.physics.shape.cast_result    : RayCast, RayCastResult;
import engine.jph.physics.shape.scale_helpers  : MakeNonZeroScale, IsZeroScale;

@safe:

// ---------------------------------------------------------------------------
// Enums (numerical layout matches Jolt's webgpu-style "must match header"
// rule — never reorder).
// ---------------------------------------------------------------------------

enum EShapeType : uint8 {
    Convex      = 0,
    Compound    = 1,
    Decorated   = 2,
    Mesh        = 3,
    HeightField = 4,
    SoftBody    = 5,
    User1       = 6,
    User2       = 7,
    User3       = 8,
    User4       = 9,
    Plane       = 10,
    Empty       = 11,
}

enum EShapeSubType : uint8 {
    // Convex
    Sphere            = 0,
    Box               = 1,
    Triangle          = 2,
    Capsule           = 3,
    TaperedCapsule    = 4,
    Cylinder          = 5,
    ConvexHull        = 6,
    // Compound
    StaticCompound    = 7,
    MutableCompound   = 8,
    // Decorated
    RotatedTranslated = 9,
    Scaled            = 10,
    OffsetCenterOfMass= 11,
    // Other
    Mesh              = 12,
    HeightField       = 13,
    SoftBody          = 14,
    // User defined
    User1             = 15,
    User2             = 16,
    User3             = 17,
    User4             = 18,
    User5             = 19,
    User6             = 20,
    User7             = 21,
    User8             = 22,
    UserConvex1       = 23,
    UserConvex2       = 24,
    UserConvex3       = 25,
    UserConvex4       = 26,
    UserConvex5       = 27,
    UserConvex6       = 28,
    UserConvex7       = 29,
    UserConvex8       = 30,
    // Tail
    Plane             = 31,
    TaperedCylinder   = 32,
    Empty             = 33,
}

enum uint NumSubShapeTypes = 34;

// ---------------------------------------------------------------------------
// Result type for ShapeSettings.Create()
// ---------------------------------------------------------------------------

/// Lightweight Result for shape creation. Carries either a `Ref!Shape` or
/// an error message. We avoid `std.typecons.Nullable` so this stays
/// `@nogc nothrow`-friendly.
struct ShapeResult {
@safe:
    Ref!Shape mShape;
    string    mError;     // empty on success
    bool      mIsValid = false;

    /// Construct a successful result holding `inShape`.
    static ShapeResult sOk(Ref!Shape inShape) nothrow @nogc {
        ShapeResult r;
        r.mShape   = inShape;
        r.mIsValid = true;
        return r;
    }

    /// Construct an error result. The string is borrowed (typically a
    /// compile-time literal).
    static ShapeResult sError(string inError) nothrow @nogc {
        ShapeResult r;
        r.mError   = inError;
        r.mIsValid = false;
        return r;
    }

    bool IsValid()    const nothrow @nogc { return mIsValid; }
    bool HasError()   const nothrow @nogc { return !mIsValid; }
    string GetError() const nothrow @nogc { return mError; }
    Ref!Shape Get()        nothrow @nogc { return mShape; }
}

// ---------------------------------------------------------------------------
// ShapeSettings — abstract factory base
// ---------------------------------------------------------------------------

/// Authoring-time configuration for a shape. Subclasses (BoxShapeSettings,
/// SphereShapeSettings, …) carry the parameters and override `Create()` to
/// build the cooked `Shape` object. Caches the result so repeated `Create()`
/// calls return the same shape.
abstract class ShapeSettings {
    mixin RefTargetMixin!ShapeSettings;

    /// Application-defined user data, copied into the produced Shape.
    uint64 mUserData = 0;

    /// Cached result of the most recent `Create()`.
    protected ShapeResult mCachedResult;

    /// Build (or return cached) shape according to this settings.
    abstract ShapeResult Create() const;

    /// Drop the cached shape so the next `Create()` rebuilds.
    void ClearCachedResult() nothrow @nogc {
        mCachedResult = ShapeResult.init;
    }
}

// ---------------------------------------------------------------------------
// ShapeFilter — predicate object for queries
// ---------------------------------------------------------------------------

/// Default shape filter. Override `ShouldCollide` to skip specific shapes
/// during traversal. The default returns `true` for everything.
class ShapeFilter {
    /// BodyID being queried (set by the engine before each top-level call).
    BodyID mBodyID2;

    /// Single-shape variant (raycast / point-in-shape).
    bool ShouldCollide(const Shape shape2, ref const SubShapeID subShapeID2)
            const nothrow @nogc {
        return true;
    }

    /// Pair variant (shape-vs-shape collision dispatch).
    bool ShouldCollide(const Shape shape1, ref const SubShapeID subShapeID1,
                       const Shape shape2, ref const SubShapeID subShapeID2)
            const nothrow @nogc {
        return true;
    }

    /// Process-wide accept-everything singleton.
    static ShapeFilter sDefault() @trusted nothrow {
        if (gFilterDefault is null) gFilterDefault = new ShapeFilter();
        return gFilterDefault;
    }
}

private __gshared ShapeFilter gFilterDefault;

// ---------------------------------------------------------------------------
// Stats — for logging / introspection
// ---------------------------------------------------------------------------

struct ShapeStats {
@safe:
    size_t mSizeBytes;
    uint   mNumTriangles;
}

// ---------------------------------------------------------------------------
// Shape — abstract polymorphic base
// ---------------------------------------------------------------------------

/// Base class for every collision volume in the engine. All concrete shapes
/// derive from this (directly or via `ConvexShape`/`DecoratedShape`/
/// `CompoundShape`).
abstract class Shape {
    mixin RefTargetMixin!Shape;

    protected EShapeType    mShapeType;
    protected EShapeSubType mShapeSubType;
    protected uint64        mUserData;

    /// Construct with type tags and zero user data.
    this(EShapeType inType, EShapeSubType inSubType) nothrow @nogc {
        mShapeType    = inType;
        mShapeSubType = inSubType;
        mUserData     = 0;
    }

    // ----- type / user data --------------------------------------------------

    final EShapeType    GetType()    const nothrow @nogc { return mShapeType; }
    final EShapeSubType GetSubType() const nothrow @nogc { return mShapeSubType; }
    final uint64        GetUserData() const nothrow @nogc { return mUserData; }
    final void          SetUserData(uint64 v)  nothrow @nogc { mUserData = v; }

    // ----- general queries (defaults; some abstract) -------------------------

    /// Shapes that can only back static bodies (e.g. PlaneShape) override
    /// this to return true.
    bool MustBeStatic() const nothrow @nogc { return false; }

    /// Centre-of-mass offset relative to the local origin. Defaults to zero;
    /// shapes whose COM is shifted (TaperedCapsule, OffsetCOM) override.
    Vec3 GetCenterOfMass() const nothrow @nogc { return Vec3.sZero(); }

    /// Local-space AABB containing the entire shape (incl. convex radius),
    /// centred around the centre of mass.
    abstract AABox GetLocalBounds() const nothrow @nogc;

    /// Number of `SubShapeID` bits needed to address every leaf inside this
    /// shape. Convex shapes return 0; compound shapes return enough bits to
    /// index their immediate children plus the maximum recursion below.
    abstract uint GetSubShapeIDBitsRecursive() const nothrow @nogc;

    /// World-space AABB. The default scales the local box and transforms it
    /// by `inCenterOfMassTransform`. Shapes with cheaper exact bounds
    /// override.
    AABox GetWorldSpaceBounds(Mat44 inCenterOfMassTransform, Vec3 inScale)
            const nothrow @nogc {
        return GetLocalBounds().Scaled(inScale).Transformed(inCenterOfMassTransform);
    }

    /// Radius of the largest sphere fitting inside the shape. Used for
    /// CCD / sub-step sizing.
    abstract float GetInnerRadius() const nothrow @nogc;

    /// Mass + inertia tensor at `mDensity = 1` units. Caller scales as
    /// needed via `MassProperties.ScaleToMass`.
    abstract MassProperties GetMassProperties() const nothrow @nogc;

    /// Walk a SubShapeID path until reaching a leaf shape. Default returns
    /// `this` and leaves `outRemainder` equal to `inSubShapeID` — correct
    /// for shapes with no sub-shapes.
    const(Shape) GetLeafShape(const SubShapeID inSubShapeID,
                              out SubShapeID outRemainder) const nothrow @nogc {
        outRemainder = inSubShapeID;
        return this;
    }

    /// Material assigned to a particular sub-shape. Default returns the
    /// shape's own material if it exposes one; concrete shapes that hold a
    /// material (ConvexShape, PlaneShape) override.
    abstract const(PhysicsMaterial) GetMaterial(const SubShapeID inSubShapeID)
            const nothrow @nogc;

    /// Outward normal at a point on the surface (in local space, relative to
    /// COM). For sub-shape-bearing shapes the path picks the leaf.
    abstract Vec3 GetSurfaceNormal(const SubShapeID inSubShapeID,
                                   Vec3 inLocalSurfacePosition) const nothrow @nogc;

    /// User-data of the leaf identified by `inSubShapeID`. Shapes without
    /// sub-shapes simply return their own user data.
    uint64 GetSubShapeUserData(const SubShapeID inSubShapeID) const nothrow @nogc {
        return mUserData;
    }

    /// Volume in m³ at scale 1.
    abstract float GetVolume() const nothrow @nogc;

    // ----- raycast / point query --------------------------------------------

    /// Single-hit raycast against this shape (relative to COM). Returns true
    /// if `ioHit.mFraction` was tightened. Concrete shapes override.
    abstract bool CastRay(const RayCast inRay,
                          const SubShapeIDCreator inSubShapeIDCreator,
                          ref RayCastResult ioHit) const nothrow @nogc;

    // ----- scale validation --------------------------------------------------

    /// Default implementation: any non-zero scale is valid. Shapes with
    /// stricter requirements (Sphere → uniform, Cylinder → uniform XZ)
    /// override.
    bool IsValidScale(Vec3 inScale) const nothrow @nogc {
        return !IsZeroScale(inScale);
    }

    /// Adjust an invalid scale to the closest valid one. Default just
    /// clamps |components| to `cMinScale`.
    Vec3 MakeScaleValid(Vec3 inScale) const nothrow @nogc {
        return MakeNonZeroScale(inScale);
    }

    // ----- introspection -----------------------------------------------------

    /// Memory + triangle count of this shape. Concrete shapes override with
    /// real numbers; the default returns the class instance size.
    ShapeStats GetStats() const nothrow @nogc {
        return ShapeStats(__traits(classInstanceSize, typeof(this)), 0);
    }
}
