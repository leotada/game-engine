// Jolt-style BodyInterface — the caller-facing API for creating, destroying,
// and manipulating bodies. Delegates to the underlying PhysicsWorld.
//
// The legacy engine does not destroy or recycle body slots, so `removeBody`
// and `destroyBody` are no-ops: they simply mark the body as sleeping with
// invMass = ∞ equivalent behaviour. A future ECS-based body pool will
// replace this with real destruction semantics.
module engine.physics.body_interface;

import engine.math.vec;
import engine.math.quat;
import engine.physics.types;
import engine.physics.body_id;
import engine.physics.motion_type;
import engine.physics.body_creation_settings;
import engine.physics.world : PhysicsWorld;

@safe:

struct BodyInterface(uint MaxBodies, uint MaxManifolds) {
@safe:
    private PhysicsWorld!(MaxBodies, MaxManifolds)* world;

    this(return scope PhysicsWorld!(MaxBodies, MaxManifolds)* w) pure nothrow @nogc
    in (w !is null)
    {
        world = w;
    }

    /// Create a body and add it to the simulation in a single call.
    /// Returns BodyID.invalid on capacity exhaustion.
    BodyID createAndAddBody(BodyCreationSettings cs, EActivation activation)  {
        if (world.bodyCount >= MaxBodies) return BodyID.invalid;
        RigidBodyId id;
        final switch (cs.motionType) {
            case EMotionType.Static:
            case EMotionType.Kinematic:
                id = world.addStatic(cs.position, cs.rotation, cs.shape);
                break;
            case EMotionType.Dynamic:
                id = world.addDynamic(cs.position, cs.rotation, cs.shape, cs.mass);
                break;
        }
        world.material[id]   = cs.toMaterial();
        world.linearVel[id]  = cs.linearVelocity;
        world.angularVel[id] = cs.angularVelocity;
        if (cs.motionType == EMotionType.Dynamic) {
            final switch (activation) {
                case EActivation.Activate:
                    world.sleeping[id] = false;
                    world.sleepTimer[id] = 0;
                    break;
                case EActivation.DontActivate:
                    if (cs.allowSleeping) {
                        world.sleeping[id]   = true;
                        world.sleepTimer[id] = 2.0f; // TIME_TO_SLEEP
                    }
                    break;
            }
        }
        return BodyID.fromIndex(id);
    }

    /// Remove-then-destroy is a legacy no-op (see module doc).
    void removeBody(BodyID id)  {
        if (id.isInvalid) return;
        immutable legacy = id.toLegacy;
        if (legacy < world.bodyCount) {
            world.sleeping[legacy] = true;
            world.linearVel[legacy] = Vec3(0, 0, 0);
            world.angularVel[legacy] = Vec3(0, 0, 0);
        }
    }

    /// @see removeBody
    void destroyBody(BodyID id) { /* no-op in MVP */ }

    // -------- queries / setters --------------------------------------------

    bool isActive(BodyID id) const  {
        if (id.isInvalid) return false;
        immutable legacy = id.toLegacy;
        return legacy < world.bodyCount && !world.sleeping[legacy];
    }

    Vec3 getPosition(BodyID id) const  {
        return id.isInvalid ? Vec3(0, 0, 0) : world.position[id.toLegacy];
    }
    Quat getRotation(BodyID id) const  {
        return id.isInvalid ? Quat.identity : world.orientation[id.toLegacy];
    }
    Vec3 getLinearVelocity(BodyID id) const  {
        return id.isInvalid ? Vec3(0, 0, 0) : world.linearVel[id.toLegacy];
    }
    Vec3 getAngularVelocity(BodyID id) const  {
        return id.isInvalid ? Vec3(0, 0, 0) : world.angularVel[id.toLegacy];
    }

    /// Equivalent to Jolt's BodyInterface::GetCenterOfMassPosition. Our shapes
    /// assume the COM is at the body position, so this is just getPosition.
    Vec3 getCenterOfMassPosition(BodyID id) const  {
        return getPosition(id);
    }

    void setLinearVelocity(BodyID id, Vec3 v)  {
        if (id.isInvalid) return;
        immutable legacy = id.toLegacy;
        if (legacy >= world.bodyCount) return;
        world.linearVel[legacy] = v;
        world.sleeping[legacy]  = false;
        world.sleepTimer[legacy] = 0;
    }
    void setAngularVelocity(BodyID id, Vec3 w)  {
        if (id.isInvalid) return;
        immutable legacy = id.toLegacy;
        if (legacy >= world.bodyCount) return;
        world.angularVel[legacy] = w;
        world.sleeping[legacy]   = false;
        world.sleepTimer[legacy] = 0;
    }
    void addForce(BodyID id, Vec3 f)  {
        if (id.isInvalid) return;
        immutable legacy = id.toLegacy;
        if (legacy >= world.bodyCount || world.invMass[legacy] == 0) return;
        world.force[legacy] = world.force[legacy] + f;
        world.sleeping[legacy]   = false;
        world.sleepTimer[legacy] = 0;
    }

    void activate(BodyID id)  {
        if (id.isInvalid) return;
        immutable legacy = id.toLegacy;
        if (legacy >= world.bodyCount || world.invMass[legacy] == 0) return;
        world.sleeping[legacy]   = false;
        world.sleepTimer[legacy] = 0;
    }
}
