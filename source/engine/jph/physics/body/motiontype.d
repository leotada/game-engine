// Jolt — Physics/Body/MotionType.h port.
module engine.jph.physics.body.motiontype;

@safe:

/// Motion type of a physics body.
enum EMotionType : ubyte {
    Static,     ///< Non movable.
    Kinematic,  ///< Movable using velocities only, ignores forces.
    Dynamic,    ///< Responds to forces as a normal physics object.
}
