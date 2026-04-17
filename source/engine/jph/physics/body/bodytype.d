// Jolt — Physics/Body/BodyType.h port.
module engine.jph.physics.body.bodytype;

@safe:

/// Type of body.
enum EBodyType : ubyte {
    RigidBody,  ///< Rigid body composed of a rigid shape.
    SoftBody,   ///< Deformable shape (cloth / mesh).
}

enum uint cBodyTypeCount = 2;
