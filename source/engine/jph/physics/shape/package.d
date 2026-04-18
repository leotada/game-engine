// Re-export of engine.jph.physics.shape submodules.
//
// Concrete shape implementations land in subsequent commits within Phase 4.
// For now this exports the base infrastructure (Shape, ShapeSettings,
// SubShapeID, PhysicsMaterial, ShapeFilter, RayCast/RayCastResult,
// scale helpers).
module engine.jph.physics.shape;

public import engine.jph.physics.shape.cast_result;
public import engine.jph.physics.shape.physics_material;
public import engine.jph.physics.shape.scale_helpers;
public import engine.jph.physics.shape.shape;
public import engine.jph.physics.shape.sub_shape_id;
