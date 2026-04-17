// Jolt-style BodyID — opaque handle around the legacy RigidBodyId.
//
// Jolt stores an index + 8-bit generation in a single uint to detect
// use-after-destroy. Our legacy engine does not yet recycle slots, so
// generation stays at 0 but the layout matches Jolt/Physics/Body/BodyID.h
// so callers can migrate without changes.
module engine.physics.body_id;

import engine.physics.types : RigidBodyId, INVALID_BODY;

@safe:

enum uint BODY_INDEX_BITS = 23;
enum uint BODY_INDEX_MASK = (1u << BODY_INDEX_BITS) - 1u;
enum uint BODY_GENERATION_MASK = 0xFFu << BODY_INDEX_BITS;

struct BodyID {
@safe:
    uint raw = uint.max;

    this(uint index, ubyte generation = 0) {
        raw = (cast(uint) generation << BODY_INDEX_BITS) | (index & BODY_INDEX_MASK);
    }

    /// Construct from the legacy SoA index used by PhysicsWorld.
    static BodyID fromIndex(RigidBodyId idx) {
        BodyID b;
        b.raw = idx & BODY_INDEX_MASK;
        return b;
    }

    uint index() const { return raw & BODY_INDEX_MASK; }
    ubyte generation() const {
        return cast(ubyte) ((raw & BODY_GENERATION_MASK) >> BODY_INDEX_BITS);
    }

    bool isInvalid() const { return raw == uint.max; }

    /// Legacy interop — yields the index PhysicsWorld expects.
    RigidBodyId toLegacy() const {
        return isInvalid ? INVALID_BODY : cast(RigidBodyId) index;
    }

    static BodyID invalid() { BodyID b; return b; }
}
