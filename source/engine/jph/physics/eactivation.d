// Jolt — Physics/EActivation.h port.
//
// Used by BodyInterface-style APIs to indicate whether a body should be
// woken when it is added or mutated.
module engine.jph.physics.eactivation;

@safe:

enum EActivation : ubyte {
    Activate = 0,
    DontActivate = 1,
}