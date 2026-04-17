// Jolt — Physics/Body/MotionQuality.h port.
module engine.jph.physics.body.motionquality;

@safe:

/// Motion quality, or how well a body detects collisions when moving fast.
enum EMotionQuality : ubyte {
    /// Discrete time stepping. Cheap, but the body can tunnel through thin
    /// objects when its velocity is high enough.
    Discrete,
    /// Linear-cast CCD: at each step the shape is swept from start to
    /// destination using the starting rotation. Prevents most tunneling at
    /// the cost of one extra cast per step.
    LinearCast,
}
