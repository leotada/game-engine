// Jolt — Physics/Collision/Shape/PlaneShape.{h,cpp} port.
//
// An *infinite* plane that can only back static bodies. Negative half-space
// is solid. The local bounding box is artificially clipped to ±halfExtent so
// the broad phase doesn't need to handle infinity; queries outside that
// box return no hit (and queries near its border may be inconsistent).
//
// Source: ref/JoltPhysics/Jolt/Physics/Collision/Shape/PlaneShape.{h,cpp}
module engine.jph.physics.shape.plane_shape;

import engine.jph.core.reference            : Ref, RefConst;
import engine.jph.math.vec3                 : Vec3;
import engine.jph.math.mat44                : Mat44;
import engine.jph.geometry.aabox            : AABox;
import engine.jph.geometry.plane            : Plane;
import engine.jph.physics.body.massproperties : MassProperties;
import engine.jph.physics.shape.shape          : Shape, ShapeSettings, ShapeResult,
                                                  ShapeStats, EShapeType, EShapeSubType;
import engine.jph.physics.shape.physics_material : PhysicsMaterial;
import engine.jph.physics.shape.sub_shape_id     : SubShapeID, SubShapeIDCreator;
import engine.jph.physics.shape.cast_result      : RayCast, RayCastResult;

@safe:

enum float cDefaultPlaneHalfExtent = 1000.0f;

private void getOrthogonalBasis(Vec3 inN, out Vec3 outP1, out Vec3 outP2) nothrow @nogc {
    outP1 = inN.Cross(Vec3(0, 1, 0)).NormalizedOr(Vec3.sAxisX());
    outP2 = outP1.Cross(inN).Normalized();
    outP1 = inN.Cross(outP2);
}

final class PlaneShapeSettings : ShapeSettings {
    Plane mPlane;
    RefConst!PhysicsMaterial mMaterial;
    float mHalfExtent = cDefaultPlaneHalfExtent;

    this() nothrow {}

    this(Plane inPlane, const PhysicsMaterial inMaterial = null,
         float inHalfExtent = cDefaultPlaneHalfExtent) @trusted nothrow {
        mPlane = inPlane;
        if (inMaterial !is null)
            mMaterial = RefConst!PhysicsMaterial(cast(PhysicsMaterial) inMaterial);
        mHalfExtent = inHalfExtent;
    }

    override ShapeResult Create() const @trusted {
        auto self = cast(PlaneShapeSettings) this;
        if (self.mCachedResult.IsValid || self.mCachedResult.HasError)
            return self.mCachedResult;
        if (!mPlane.GetNormal().IsNormalized()) {
            self.mCachedResult = ShapeResult.sError("Plane normal needs to be normalized!");
            return self.mCachedResult;
        }
        auto shape = new PlaneShape(this);
        self.mCachedResult = ShapeResult.sOk(Ref!Shape(shape));
        return self.mCachedResult;
    }
}

final class PlaneShape : Shape {
    private Plane mPlane;
    private RefConst!PhysicsMaterial mMaterial;
    private float mHalfExtent = cDefaultPlaneHalfExtent;
    private AABox mLocalBounds;

    this() @trusted nothrow {
        super(EShapeType.Plane, EShapeSubType.Plane);
        mMaterial = RefConst!PhysicsMaterial(PhysicsMaterial.sDefault());
    }

    this(Plane inPlane, const PhysicsMaterial inMaterial = null,
         float inHalfExtent = cDefaultPlaneHalfExtent) @trusted nothrow {
        super(EShapeType.Plane, EShapeSubType.Plane);
        mPlane = inPlane;
        if (inMaterial !is null)
            mMaterial = RefConst!PhysicsMaterial(cast(PhysicsMaterial) inMaterial);
        else
            mMaterial = RefConst!PhysicsMaterial(PhysicsMaterial.sDefault());
        mHalfExtent = inHalfExtent;
        calculateLocalBounds();
    }

    this(const PlaneShapeSettings inSettings) @trusted nothrow {
        super(EShapeType.Plane, EShapeSubType.Plane);
        mPlane = inSettings.mPlane;
        if (!inSettings.mMaterial.isNull)
            mMaterial = RefConst!PhysicsMaterial(cast(PhysicsMaterial) inSettings.mMaterial.GetPtr());
        else
            mMaterial = RefConst!PhysicsMaterial(PhysicsMaterial.sDefault());
        mHalfExtent = inSettings.mHalfExtent;
        calculateLocalBounds();
    }

    Plane GetPlane()      const nothrow @nogc { return mPlane; }
    float GetHalfExtent() const nothrow @nogc { return mHalfExtent; }

    private void getVertices(out Vec3[4] outV) const nothrow @nogc {
        immutable Vec3 normal = mPlane.GetNormal();
        Vec3 p1, p2;
        getOrthogonalBasis(normal, p1, p2);
        p1 = p1 * mHalfExtent;
        p2 = p2 * mHalfExtent;
        immutable Vec3 point = -normal * mPlane.GetConstant();
        outV[0] = point + p1 + p2;
        outV[1] = point + p1 - p2;
        outV[2] = point - p1 - p2;
        outV[3] = point - p1 + p2;
    }

    private void calculateLocalBounds() @trusted nothrow @nogc {
        Vec3[4] verts;
        getVertices(verts);
        mLocalBounds = AABox.sFromTwoPoints(verts[0], verts[0]);
        immutable Vec3 normal = mPlane.GetNormal();
        foreach (v; verts) {
            mLocalBounds.Encapsulate(v);
            mLocalBounds.Encapsulate(v - normal * mHalfExtent);
        }
    }

    // ----- Shape overrides ---------------------------------------------------

    override bool MustBeStatic()                    const nothrow @nogc { return true; }
    override AABox GetLocalBounds()                 const nothrow @nogc { return mLocalBounds; }
    override uint  GetSubShapeIDBitsRecursive()     const nothrow @nogc { return 0; }
    override float GetInnerRadius()                 const nothrow @nogc { return 0.0f; }
    override float GetVolume()                      const nothrow @nogc { return 0.0f; }

    override MassProperties GetMassProperties() const nothrow @nogc { return MassProperties(); }

    override const(PhysicsMaterial) GetMaterial(const SubShapeID inSubShapeID)
            const nothrow @nogc @trusted {
        assert(inSubShapeID.IsEmpty(), "Invalid subshape ID");
        return getMaterial();
    }

    private const(PhysicsMaterial) getMaterial() const nothrow @nogc @trusted {
        return (cast() mMaterial).GetPtr();
    }

    override Vec3 GetSurfaceNormal(const SubShapeID inSubShapeID,
                                   Vec3 inLocalSurfacePosition) const nothrow @nogc {
        cast(void) inLocalSurfacePosition;
        assert(inSubShapeID.IsEmpty(), "Invalid subshape ID");
        return mPlane.GetNormal();
    }

    override bool CastRay(const RayCast inRay,
                          const SubShapeIDCreator inSubShapeIDCreator,
                          ref RayCastResult ioHit) const nothrow @nogc {
        // Inside the solid (negative) half-space → instant hit at fraction 0.
        immutable float distance = mPlane.SignedDistance(inRay.mOrigin);
        if (distance <= 0.0f) {
            ioHit.mFraction = 0.0f;
            ioHit.mSubShapeID2 = inSubShapeIDCreator.GetID();
            return true;
        }
        immutable float dot = inRay.mDirection.Dot(mPlane.GetNormal());
        if (dot == 0.0f) return false;
        immutable float fraction = -distance / dot;
        if (fraction >= 0.0f && fraction < ioHit.mFraction) {
            ioHit.mFraction = fraction;
            ioHit.mSubShapeID2 = inSubShapeIDCreator.GetID();
            return true;
        }
        return false;
    }

    override ShapeStats GetStats() const nothrow @nogc {
        return ShapeStats(__traits(classInstanceSize, PlaneShape), 0);
    }
}

unittest {
    auto plane = Plane.sFromPointAndNormal(Vec3.sZero(), Vec3(0, 1, 0));
    auto p = new PlaneShape(plane);
    assert(p.MustBeStatic());
    assert(p.GetSubType() == EShapeSubType.Plane);
    assert(p.GetVolume() == 0.0f);
    immutable b = p.GetLocalBounds();
    // Plane lies in y=0; local bounds extend ±halfExtent in X/Z and 0..-half in Y.
    assert(b.mMax.GetX() > 0.0f);
}

unittest {
    auto plane = Plane.sFromPointAndNormal(Vec3.sZero(), Vec3(0, 1, 0));
    auto p = new PlaneShape(plane);

    // Ray pointing down from above hits the plane (direction encodes max distance).
    RayCastResult hit;
    assert(p.CastRay(RayCast(Vec3(0, 5, 0), Vec3(0, -10, 0)), SubShapeIDCreator.init, hit));
    import std.math : isClose;
    assert(isClose(hit.mFraction, 0.5f));

    // Ray starting in solid half-space hits at fraction 0.
    RayCastResult hit2;
    assert(p.CastRay(RayCast(Vec3(0, -1, 0), Vec3(0, 1, 0)), SubShapeIDCreator.init, hit2));
    assert(hit2.mFraction == 0.0f);
}

unittest {
    // Unnormalised normal → error.
    auto plane = Plane(Vec3(0, 2, 0), 0.0f);
    auto s = new PlaneShapeSettings(plane);
    assert(s.Create().HasError());
}
