// Jolt — Physics/Collision/Shape/EmptyShape.{h,cpp} port.
//
// Volumeless, collisionless placeholder. Useful as a stand-in for a body
// whose final shape will be assigned later, or for kinematic bodies that
// only carry constraints. Always passes scale validation.
//
// Source: ref/JoltPhysics/Jolt/Physics/Collision/Shape/EmptyShape.{h,cpp}
module engine.jph.physics.shape.empty_shape;

import engine.jph.core.reference            : Ref, RefConst;
import engine.jph.math.vec3                 : Vec3;
import engine.jph.math.mat44                : Mat44;
import engine.jph.geometry.aabox            : AABox;
import engine.jph.physics.body.massproperties : MassProperties;
import engine.jph.physics.shape.shape          : Shape, ShapeSettings, ShapeResult,
                                                  ShapeStats, EShapeType, EShapeSubType;
import engine.jph.physics.shape.physics_material : PhysicsMaterial;
import engine.jph.physics.shape.sub_shape_id     : SubShapeID, SubShapeIDCreator;
import engine.jph.physics.shape.cast_result      : RayCast, RayCastResult;

@safe:

final class EmptyShapeSettings : ShapeSettings {
    Vec3 mCenterOfMass = Vec3.sZero();

    this() nothrow {}
    this(Vec3 inCenterOfMass) nothrow @nogc { mCenterOfMass = inCenterOfMass; }

    override ShapeResult Create() const @trusted {
        auto self = cast(EmptyShapeSettings) this;
        if (self.mCachedResult.IsValid || self.mCachedResult.HasError)
            return self.mCachedResult;
        auto shape = new EmptyShape(mCenterOfMass);
        self.mCachedResult = ShapeResult.sOk(Ref!Shape(shape));
        return self.mCachedResult;
    }
}

final class EmptyShape : Shape {
    private Vec3 mCenterOfMass = Vec3.sZero();

    private RefConst!PhysicsMaterial mMaterial;

    this() @trusted nothrow {
        super(EShapeType.Empty, EShapeSubType.Empty);
        mMaterial = RefConst!PhysicsMaterial(PhysicsMaterial.sDefault());
    }

    this(Vec3 inCenterOfMass) @trusted nothrow {
        super(EShapeType.Empty, EShapeSubType.Empty);
        mCenterOfMass = inCenterOfMass;
        mMaterial = RefConst!PhysicsMaterial(PhysicsMaterial.sDefault());
    }

    override Vec3  GetCenterOfMass() const nothrow @nogc { return mCenterOfMass; }
    override AABox GetLocalBounds()  const nothrow @nogc { return AABox.sFromTwoPoints(Vec3.sZero(), Vec3.sZero()); }
    override uint  GetSubShapeIDBitsRecursive() const nothrow @nogc { return 0; }
    override float GetInnerRadius()  const nothrow @nogc { return 0.0f; }
    override float GetVolume()       const nothrow @nogc { return 0.0f; }

    override MassProperties GetMassProperties() const nothrow @nogc { return MassProperties(); }

    override const(PhysicsMaterial) GetMaterial(const SubShapeID inSubShapeID)
            const nothrow @nogc @trusted {
        cast(void) inSubShapeID;
        return (cast() mMaterial).GetPtr();
    }

    override Vec3 GetSurfaceNormal(const SubShapeID inSubShapeID,
                                   Vec3 inLocalSurfacePosition) const nothrow @nogc {
        cast(void) inSubShapeID; cast(void) inLocalSurfacePosition;
        return Vec3.sZero();
    }

    override bool CastRay(const RayCast inRay,
                          const SubShapeIDCreator inSubShapeIDCreator,
                          ref RayCastResult ioHit) const nothrow @nogc {
        cast(void) inRay; cast(void) inSubShapeIDCreator; cast(void) ioHit;
        return false;
    }

    override bool IsValidScale(Vec3 inScale) const nothrow @nogc {
        cast(void) inScale; return true;
    }

    override ShapeStats GetStats() const nothrow @nogc {
        return ShapeStats(__traits(classInstanceSize, EmptyShape), 0);
    }
}

unittest {
    auto e = new EmptyShape();
    assert(e.GetVolume() == 0.0f);
    assert(e.GetSubType() == EShapeSubType.Empty);
    assert(e.GetType() == EShapeType.Empty);
    assert(e.IsValidScale(Vec3(2, 3, 4)));
    RayCastResult hit;
    assert(!e.CastRay(RayCast(Vec3.sZero(), Vec3(1, 0, 0)), SubShapeIDCreator.init, hit));
}

unittest {
    auto s = new EmptyShapeSettings(Vec3(1, 2, 3));
    auto r = s.Create();
    assert(r.IsValid());
    assert(r.Get().GetPtr().GetCenterOfMass() == Vec3(1, 2, 3));
}
