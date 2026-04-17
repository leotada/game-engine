// Jolt-style motion type. Mirrors Jolt/Physics/Body/MotionType.h.
//
// The legacy PhysicsWorld distinguishes static vs dynamic by invMass == 0,
// so EMotionType.Kinematic currently behaves like Static (invMass = 0) with
// the caller responsible for velocity updates. Dynamic matches Jolt's
// default for `addDynamic`.
module engine.physics.motion_type;

@safe:

enum EMotionType : ubyte {
    Static    = 0,  // Infinite mass, never moves
    Kinematic = 1,  // Infinite mass, but driven by velocity / setPosition
    Dynamic   = 2,  // Normal rigid body
}

/// Collision filter layer (application-defined). Matches Jolt's ObjectLayer
/// semantics; the MVP does not yet use it for filtering but preserves the
/// field shape so callers can port Jolt code directly.
alias ObjectLayer = ushort;

enum ObjectLayer LAYER_NON_MOVING = 0;
enum ObjectLayer LAYER_MOVING     = 1;

/// Activation policy when adding a body to simulation.
enum EActivation : ubyte {
    Activate     = 0,
    DontActivate = 1,
}
