// Jolt-style BodyCreationSettings — POD bundle forwarded to BodyInterface.
//
// Mirrors the subset of Jolt/Physics/Body/BodyCreationSettings.h that the
// MVP honours. Fields beyond the MVP are present so callers can migrate
// Jolt code, but they're ignored by the current implementation.
module engine.physics.body_creation_settings;

import engine.math.vec;
import engine.math.quat;
import engine.physics.types : Shape, Material;
import engine.physics.motion_type;

@safe:

struct BodyCreationSettings {
@safe:
    Vec3   position        = Vec3(0, 0, 0);
    Quat   rotation        = Quat.identity;
    Vec3   linearVelocity  = Vec3(0, 0, 0);
    Vec3   angularVelocity = Vec3(0, 0, 0);
    Shape  shape;

    EMotionType motionType = EMotionType.Dynamic;
    ObjectLayer objectLayer = LAYER_MOVING;

    /// Only honoured when motionType == Dynamic. Defaults to 1 kg.
    float  mass            = 1.0f;

    /// Replaces Material fields on the body. Defaults match Material.init.
    float  friction        = 0.5f;
    float  restitution     = 0.0f;
    float  linearDamping   = 0.04f;
    float  angularDamping  = 0.1f;

    /// Honoured: true places the body asleep on spawn.
    bool   allowSleeping   = true;

    /// Preserved for forward compatibility; not yet applied.
    float  gravityFactor   = 1.0f;
    float  maxLinearVelocity  = 500.0f;
    float  maxAngularVelocity = 47.12389f; // 7.5π rad/s

    /// Build the Material block that the legacy engine consumes.
    Material toMaterial() const {
        Material m;
        m.friction       = friction;
        m.restitution    = restitution;
        m.linearDamping  = linearDamping;
        m.angularDamping = angularDamping;
        return m;
    }
}
