module engine.physics.joints;

import bindings.box3d;
import bindings.box3d.ids : b3IdEquals;
import core.math : sqrt;
import core.stdc.math : fabsf;
import core.stdc.stdlib : free, realloc;
import engine.core.pod : isPod;
import engine.ecs.store : EntityId;
import engine.math.quat : Quat;
import engine.math.vec : Vec3;
import engine.physics.body : getBodyEntity, noPhysicsEntity;
import engine.physics.convert : toB3Pos, toB3Quat, toB3Vec3, toEngineQuat, toEngineVec3;
import engine.physics.world : PhysicsWorld;

@safe:

/// Configuration for a revolute (hinge) joint.
struct RevoluteJointConfig {
    bool enableLimit = false;
    float lowerAngle = 0.0f;
    float upperAngle = 0.0f;
    bool enableSpring = false;
    float hertz = 0.0f;
    float dampingRatio = 0.0f;
    float targetAngle = 0.0f;
    bool enableMotor = false;
    float motorSpeed = 0.0f;
    float maxMotorTorque = 0.0f;
    bool collideConnected = false;
}

/// Configuration for a weld joint (rigid or compliant spring-damper).
struct WeldJointConfig {
    float linearHertz = 0.0f;
    float linearDampingRatio = 1.0f;
    float angularHertz = 0.0f;
    float angularDampingRatio = 1.0f;
    bool collideConnected = false;
}

/// Configuration for a spherical (ball-socket / ragdoll cone-twist) joint.
/// Cone axis is aligned with local frame Z; twist rotates around local frame Z.
struct SphericalJointConfig {
    bool enableConeLimit = false;
    float coneAngle = 0.5f;
    bool enableTwistLimit = false;
    float lowerTwistAngle = -0.25f;
    float upperTwistAngle = 0.25f;
    bool enableSpring = false;
    float hertz = 0.0f;
    float dampingRatio = 0.0f;
    Quat targetRotation = Quat.init;
    bool enableMotor = false;
    Vec3 motorVelocity = Vec3(0.0f, 0.0f, 0.0f);
    float maxMotorTorque = 0.0f;
    bool collideConnected = false;
}

/// Configuration for a wheel joint (chassis suspension along X, steering around X, wheel spin around Z).
struct WheelJointConfig {
    bool enableSuspensionSpring = true;
    float suspensionHertz = 8.0f;
    float suspensionDampingRatio = 0.7f;
    bool enableSuspensionLimit = false;
    float lowerSuspensionLimit = -0.25f;
    float upperSuspensionLimit = 0.25f;
    bool enableSpinMotor = false;
    float spinSpeed = 0.0f;
    float maxSpinTorque = 0.0f;
    bool enableSteering = false;
    float steeringHertz = 12.0f;
    float steeringDampingRatio = 1.0f;
    float targetSteeringAngle = 0.0f;
    float maxSteeringTorque = 0.0f;
    bool enableSteeringLimit = false;
    float lowerSteeringLimit = -0.6f;
    float upperSteeringLimit = 0.6f;
    bool collideConnected = false;
}

/// Configuration for a prismatic (slider along local frame X) joint.
struct PrismaticJointConfig {
    bool enableLimit = false;
    float lowerTranslation = 0.0f;
    float upperTranslation = 0.0f;
    bool enableSpring = false;
    float hertz = 0.0f;
    float dampingRatio = 0.0f;
    float targetTranslation = 0.0f;
    bool enableMotor = false;
    float motorSpeed = 0.0f;
    float maxMotorForce = 0.0f;
    bool collideConnected = false;
}

/// Event emitted when a tracked breakable joint exceeds its force or torque threshold.
struct BreakableJointEvent {
    b3JointId jointId;
    b3BodyId bodyA;
    b3BodyId bodyB;
    EntityId entityA = noPhysicsEntity;
    EntityId entityB = noPhysicsEntity;
    ulong userTag = 0;
    Vec3 force;
    Vec3 torque;
    float forceMag = 0.0f;
    float torqueMag = 0.0f;
}

alias JointBrokenCallback = void function(BreakableJointEvent event, void* context) nothrow @nogc @safe;

static assert(isPod!RevoluteJointConfig);
static assert(isPod!WeldJointConfig);
static assert(isPod!SphericalJointConfig);
static assert(isPod!WheelJointConfig);
static assert(isPod!PrismaticJointConfig);
static assert(isPod!BreakableJointEvent);

b3JointId createDistanceJoint(ref PhysicsWorld world,
                              b3BodyId bodyA,
                              b3BodyId bodyB,
                              Vec3 worldAnchorA,
                              Vec3 worldAnchorB,
                              float length = -1.0f,
                              bool collideConnected = false) nothrow @nogc @trusted {
    b3DistanceJointDef def = b3DefaultDistanceJointDefD();
    initJointBase(def.base, bodyA, bodyB, worldAnchorA, worldAnchorB,
        b3Quat(b3Vec3(0.0f, 0.0f, 0.0f), 1.0f), collideConnected);

    if (length < 0.0f) {
        immutable dx = worldAnchorB.x - worldAnchorA.x;
        immutable dy = worldAnchorB.y - worldAnchorA.y;
        immutable dz = worldAnchorB.z - worldAnchorA.z;
        length = sqrtLength(dx, dy, dz);
    }
    def.length = length;
    def.minLength = length;
    def.maxLength = length;
    return b3CreateDistanceJointD(world.handle, &def);
}

/// Revolute (hinge) joint. `axis` is the world-space hinge axis.
b3JointId createRevoluteJoint(ref PhysicsWorld world,
                              b3BodyId bodyA,
                              b3BodyId bodyB,
                              Vec3 worldAnchor,
                              Vec3 axis,
                              bool collideConnected = false) nothrow @nogc @trusted {
    RevoluteJointConfig cfg;
    cfg.collideConnected = collideConnected;
    return createRevoluteJoint(world, bodyA, bodyB, worldAnchor, axis, cfg);
}

/// Revolute (hinge) joint with explicit limits, spring, and motor settings.
b3JointId createRevoluteJoint(ref PhysicsWorld world,
                              b3BodyId bodyA,
                              b3BodyId bodyB,
                              Vec3 worldAnchor,
                              Vec3 axis,
                              const RevoluteJointConfig cfg) nothrow @nogc @trusted {
    immutable worldQ = alignZToAxis(axis);
    b3RevoluteJointDef def = b3DefaultRevoluteJointDefD();
    initJointBase(def.base, bodyA, bodyB, worldAnchor, worldAnchor, worldQ, cfg.collideConnected);
    def.enableLimit = cfg.enableLimit;
    def.lowerAngle = cfg.lowerAngle;
    def.upperAngle = cfg.upperAngle;
    def.enableSpring = cfg.enableSpring;
    def.hertz = cfg.hertz;
    def.dampingRatio = cfg.dampingRatio;
    def.targetAngle = cfg.targetAngle;
    def.enableMotor = cfg.enableMotor;
    def.motorSpeed = cfg.motorSpeed;
    def.maxMotorTorque = cfg.maxMotorTorque;
    return b3CreateRevoluteJointD(world.handle, &def);
}

b3JointId createWeldJoint(ref PhysicsWorld world,
                          b3BodyId bodyA,
                          b3BodyId bodyB,
                          Vec3 worldAnchor,
                          bool collideConnected = false) nothrow @nogc @trusted {
    WeldJointConfig cfg;
    cfg.collideConnected = collideConnected;
    return createWeldJoint(world, bodyA, bodyB, worldAnchor, cfg);
}

/// Weld joint with optional linear/angular spring stiffness and damping.
b3JointId createWeldJoint(ref PhysicsWorld world,
                          b3BodyId bodyA,
                          b3BodyId bodyB,
                          Vec3 worldAnchor,
                          const WeldJointConfig cfg) nothrow @nogc @trusted {
    b3WeldJointDef def = b3DefaultWeldJointDefD();
    initJointBase(def.base, bodyA, bodyB, worldAnchor, worldAnchor,
        b3Quat(b3Vec3(0.0f, 0.0f, 0.0f), 1.0f), cfg.collideConnected);
    def.linearHertz = cfg.linearHertz;
    def.linearDampingRatio = cfg.linearDampingRatio;
    def.angularHertz = cfg.angularHertz;
    def.angularDampingRatio = cfg.angularDampingRatio;
    return b3CreateWeldJointD(world.handle, &def);
}

/// Spherical (ball-socket / ragdoll cone-twist) joint anchored at `worldAnchor`.
/// `coneAxis` defines the world-space reference cone/twist Z axis at creation time.
b3JointId createSphericalJoint(ref PhysicsWorld world,
                               b3BodyId bodyA,
                               b3BodyId bodyB,
                               Vec3 worldAnchor,
                               Vec3 coneAxis = Vec3(0.0f, -1.0f, 0.0f),
                               const SphericalJointConfig cfg = SphericalJointConfig.init) nothrow @nogc @trusted {
    immutable worldQ = alignZToAxis(coneAxis);
    b3SphericalJointDef def = b3DefaultSphericalJointDefD();
    initJointBase(def.base, bodyA, bodyB, worldAnchor, worldAnchor, worldQ, cfg.collideConnected);
    def.enableConeLimit = cfg.enableConeLimit;
    def.coneAngle = cfg.coneAngle;
    def.enableTwistLimit = cfg.enableTwistLimit;
    def.lowerTwistAngle = cfg.lowerTwistAngle;
    def.upperTwistAngle = cfg.upperTwistAngle;
    def.enableSpring = cfg.enableSpring;
    def.hertz = cfg.hertz;
    def.dampingRatio = cfg.dampingRatio;
    def.targetRotation = toB3Quat(cfg.targetRotation);
    def.enableMotor = cfg.enableMotor;
    def.motorVelocity = toB3Vec3(cfg.motorVelocity);
    def.maxMotorTorque = cfg.maxMotorTorque;
    return b3CreateSphericalJointD(world.handle, &def);
}

/// Wheel joint attaching `wheelBody` to `chassisBody` at `worldAnchor`.
/// Suspension travel and steering axis align with `suspensionAxis` (local X),
/// and wheel rotation aligns with `spinAxis` (local Z).
b3JointId createWheelJoint(ref PhysicsWorld world,
                           b3BodyId chassisBody,
                           b3BodyId wheelBody,
                           Vec3 worldAnchor,
                           Vec3 suspensionAxis = Vec3(0.0f, 1.0f, 0.0f),
                           Vec3 spinAxis = Vec3(1.0f, 0.0f, 0.0f),
                           const WheelJointConfig cfg = WheelJointConfig.init) nothrow @nogc @trusted {
    immutable worldQ = toB3Quat(basisFromXZ(suspensionAxis, spinAxis));
    b3WheelJointDef def = b3DefaultWheelJointDefD();
    initJointBase(def.base, chassisBody, wheelBody, worldAnchor, worldAnchor, worldQ, cfg.collideConnected);
    def.enableSuspensionSpring = cfg.enableSuspensionSpring;
    def.suspensionHertz = cfg.suspensionHertz;
    def.suspensionDampingRatio = cfg.suspensionDampingRatio;
    def.enableSuspensionLimit = cfg.enableSuspensionLimit;
    def.lowerSuspensionLimit = cfg.lowerSuspensionLimit;
    def.upperSuspensionLimit = cfg.upperSuspensionLimit;
    def.enableSpinMotor = cfg.enableSpinMotor;
    def.spinSpeed = cfg.spinSpeed;
    def.maxSpinTorque = cfg.maxSpinTorque;
    def.enableSteering = cfg.enableSteering;
    def.steeringHertz = cfg.steeringHertz;
    def.steeringDampingRatio = cfg.steeringDampingRatio;
    def.targetSteeringAngle = cfg.targetSteeringAngle;
    def.maxSteeringTorque = cfg.maxSteeringTorque;
    def.enableSteeringLimit = cfg.enableSteeringLimit;
    def.lowerSteeringLimit = cfg.lowerSteeringLimit;
    def.upperSteeringLimit = cfg.upperSteeringLimit;
    return b3CreateWheelJointD(world.handle, &def);
}

/// Prismatic (slider) joint allowing translation along world-space `slideAxis`.
b3JointId createPrismaticJoint(ref PhysicsWorld world,
                               b3BodyId bodyA,
                               b3BodyId bodyB,
                               Vec3 worldAnchor,
                               Vec3 slideAxis,
                               const PrismaticJointConfig cfg = PrismaticJointConfig.init) nothrow @nogc @trusted {
    immutable perpHint = fabsf(slideAxis.y) < 0.9f ? Vec3(0.0f, 1.0f, 0.0f) : Vec3(1.0f, 0.0f, 0.0f);
    immutable worldQ = toB3Quat(basisFromXZ(slideAxis, perpHint));
    b3PrismaticJointDef def = b3DefaultPrismaticJointDefD();
    initJointBase(def.base, bodyA, bodyB, worldAnchor, worldAnchor, worldQ, cfg.collideConnected);
    def.enableLimit = cfg.enableLimit;
    def.lowerTranslation = cfg.lowerTranslation;
    def.upperTranslation = cfg.upperTranslation;
    def.enableSpring = cfg.enableSpring;
    def.hertz = cfg.hertz;
    def.dampingRatio = cfg.dampingRatio;
    def.targetTranslation = cfg.targetTranslation;
    def.enableMotor = cfg.enableMotor;
    def.motorSpeed = cfg.motorSpeed;
    def.maxMotorForce = cfg.maxMotorForce;
    return b3CreatePrismaticJointD(world.handle, &def);
}

/// Filter joint disabling contact generation between `bodyA` and `bodyB`.
b3JointId createFilterJoint(ref PhysicsWorld world, b3BodyId bodyA, b3BodyId bodyB) nothrow @nogc @trusted {
    b3FilterJointDef def = b3DefaultFilterJointDefD();
    def.base.bodyIdA = bodyA;
    def.base.bodyIdB = bodyB;
    return b3CreateFilterJointD(world.handle, &def);
}

void destroyJoint(b3JointId jointId, bool wakeAttached = true) nothrow @nogc @trusted {
    if (b3Joint_IsValidD(jointId))
        b3DestroyJointD(jointId, wakeAttached);
}

bool isJointValid(b3JointId jointId) nothrow @nogc @trusted {
    return b3Joint_IsValidD(jointId);
}

Vec3 getJointConstraintForce(b3JointId jointId) nothrow @nogc @trusted {
    if (!b3Joint_IsValidD(jointId))
        return Vec3(0.0f, 0.0f, 0.0f);
    return toEngineVec3(b3Joint_GetConstraintForceD(jointId));
}

Vec3 getJointConstraintTorque(b3JointId jointId) nothrow @nogc @trusted {
    if (!b3Joint_IsValidD(jointId))
        return Vec3(0.0f, 0.0f, 0.0f);
    return toEngineVec3(b3Joint_GetConstraintTorqueD(jointId));
}

void setJointForceThreshold(b3JointId jointId, float threshold) nothrow @nogc @trusted {
    if (b3Joint_IsValidD(jointId))
        b3Joint_SetForceThresholdD(jointId, threshold);
}

void setJointTorqueThreshold(b3JointId jointId, float threshold) nothrow @nogc @trusted {
    if (b3Joint_IsValidD(jointId))
        b3Joint_SetTorqueThresholdD(jointId, threshold);
}

void setRevoluteJointMotor(b3JointId jointId, float motorSpeed, float maxMotorTorque) nothrow @nogc @trusted {
    if (!b3Joint_IsValidD(jointId))
        return;
    b3RevoluteJoint_EnableMotorD(jointId, true);
    b3RevoluteJoint_SetMotorSpeedD(jointId, motorSpeed);
    b3RevoluteJoint_SetMaxMotorTorqueD(jointId, maxMotorTorque);
}

float getRevoluteJointAngle(b3JointId jointId) nothrow @nogc @trusted {
    if (!b3Joint_IsValidD(jointId))
        return 0.0f;
    return b3RevoluteJoint_GetAngleD(jointId);
}

void setWheelJointSpinMotor(b3JointId jointId, float spinSpeed, float maxSpinTorque) nothrow @nogc @trusted {
    if (!b3Joint_IsValidD(jointId))
        return;
    b3WheelJoint_EnableSpinMotorD(jointId, true);
    b3WheelJoint_SetSpinMotorSpeedD(jointId, spinSpeed);
    b3WheelJoint_SetMaxSpinTorqueD(jointId, maxSpinTorque);
}

void setWheelJointSteeringAngle(b3JointId jointId, float angleRadians) nothrow @nogc @trusted {
    if (b3Joint_IsValidD(jointId))
        b3WheelJoint_SetTargetSteeringAngleD(jointId, angleRadians);
}

/// Zero-GC tracker for joints that automatically break when reaction force or torque
/// exceeds configured thresholds. Call `update(world, ...)` once per physics step.
struct BreakableJointTracker {
    @disable this(this);

    private struct Entry {
        b3JointId jointId;
        b3BodyId bodyA;
        b3BodyId bodyB;
        EntityId entityA = noPhysicsEntity;
        EntityId entityB = noPhysicsEntity;
        float breakForce = float.max;
        float breakTorque = float.max;
        ulong userTag = 0;
    }

    private Entry* _entries;
    private size_t _count;
    private size_t _cap;

    ~this() nothrow @nogc @trusted {
        clear();
    }

    size_t count() const pure nothrow @nogc {
        return _count;
    }

    void clear() nothrow @nogc @trusted {
        if (_entries !is null) {
            free(_entries);
            _entries = null;
        }
        _count = 0;
        _cap = 0;
    }

    /// Register `jointId` to break when constraint force >= `breakForce` or torque >= `breakTorque`.
    bool registerJoint(b3JointId jointId,
                       float breakForce,
                       float breakTorque = float.max,
                       ulong userTag = 0) nothrow @nogc @trusted {
        if (!b3Joint_IsValidD(jointId))
            return false;

        b3Joint_SetForceThresholdD(jointId, breakForce);
        b3Joint_SetTorqueThresholdD(jointId, breakTorque);

        immutable idx = findIndex(jointId);
        if (idx >= 0) {
            _entries[idx].breakForce = breakForce;
            _entries[idx].breakTorque = breakTorque;
            _entries[idx].userTag = userTag;
            return true;
        }

        if (_count == _cap) {
            immutable nextCap = _cap == 0 ? 16 : _cap * 2;
            auto nextBuf = cast(Entry*) realloc(_entries, nextCap * Entry.sizeof);
            if (nextBuf is null)
                return false;
            _entries = nextBuf;
            _cap = nextCap;
        }

        Entry e;
        e.jointId = jointId;
        e.bodyA = b3Joint_GetBodyAD(jointId);
        e.bodyB = b3Joint_GetBodyBD(jointId);
        e.entityA = getBodyEntity(e.bodyA);
        e.entityB = getBodyEntity(e.bodyB);
        e.breakForce = breakForce;
        e.breakTorque = breakTorque;
        e.userTag = userTag;
        _entries[_count++] = e;
        return true;
    }

    bool unregisterJoint(b3JointId jointId) nothrow @nogc @trusted {
        immutable idx = findIndex(jointId);
        if (idx < 0)
            return false;
        removeAt(cast(size_t) idx);
        return true;
    }

    /// Inspect joint events and current constraint reactions, destroy broken joints,
    /// and invoke `onBroken` for each broken joint. Returns number of joints broken.
    int update(ref PhysicsWorld world,
               JointBrokenCallback onBroken = null,
               scope void* context = null) nothrow @nogc @trusted {
        if (_count == 0 || !world.valid())
            return 0;

        int brokenCount = 0;
        b3JointEvents events = b3World_GetJointEventsD(world.handle);

        size_t i = 0;
        while (i < _count) {
            Entry e = _entries[i];
            if (!b3Joint_IsValidD(e.jointId)) {
                removeAt(i);
                continue;
            }

            immutable f = getJointConstraintForce(e.jointId);
            immutable t = getJointConstraintTorque(e.jointId);
            immutable fMag = sqrtLength(f.x, f.y, f.z);
            immutable tMag = sqrtLength(t.x, t.y, t.z);

            bool shouldBreak = fMag >= e.breakForce || tMag >= e.breakTorque;
            if (!shouldBreak) {
                foreach (ei; 0 .. events.count) {
                    if (b3IdEquals(events.jointEvents[ei].jointId, e.jointId)) {
                        shouldBreak = true;
                        break;
                    }
                }
            }

            if (shouldBreak) {
                BreakableJointEvent ev;
                ev.jointId = e.jointId;
                ev.bodyA = e.bodyA;
                ev.bodyB = e.bodyB;
                ev.entityA = e.entityA;
                ev.entityB = e.entityB;
                ev.userTag = e.userTag;
                ev.force = f;
                ev.torque = t;
                ev.forceMag = fMag;
                ev.torqueMag = tMag;

                b3DestroyJointD(e.jointId, true);
                removeAt(i);
                brokenCount += 1;

                if (onBroken !is null)
                    onBroken(ev, context);
                continue;
            }

            i += 1;
        }

        return brokenCount;
    }

private:
    ptrdiff_t findIndex(b3JointId jointId) const nothrow @nogc @trusted {
        foreach (i; 0 .. _count) {
            if (b3IdEquals(_entries[i].jointId, jointId))
                return cast(ptrdiff_t) i;
        }
        return -1;
    }

    void removeAt(size_t idx) nothrow @nogc @trusted {
        if (idx + 1 < _count)
            _entries[idx] = _entries[_count - 1];
        _count -= 1;
    }
}

// --- Private helpers ---

private void initJointBase(ref b3JointDef base,
                           b3BodyId bodyA,
                           b3BodyId bodyB,
                           Vec3 worldAnchorA,
                           Vec3 worldAnchorB,
                           b3Quat worldQ,
                           bool collideConnected) nothrow @nogc @trusted {
    base.bodyIdA = bodyA;
    base.bodyIdB = bodyB;
    base.collideConnected = collideConnected;
    base.localFrameA.p = b3Body_GetLocalPointD(bodyA, toB3Pos(worldAnchorA));
    base.localFrameB.p = b3Body_GetLocalPointD(bodyB, toB3Pos(worldAnchorB));
    base.localFrameA.q = worldQuatToLocal(bodyA, worldQ);
    base.localFrameB.q = worldQuatToLocal(bodyB, worldQ);
}

private b3Quat alignZToAxis(Vec3 axis) nothrow @nogc @trusted {
    immutable axisN = normalizeOrDefault(axis, Vec3(0.0f, 1.0f, 0.0f));
    return b3ComputeQuatBetweenUnitVectorsD(b3Vec3(0.0f, 0.0f, 1.0f), toB3Vec3(axisN));
}

private b3Quat worldQuatToLocal(const b3BodyId bodyId, const b3Quat worldQ) nothrow @nogc @trusted {
    immutable br = b3Body_GetRotationD(bodyId);
    // conjugate(br) * worldQ
    immutable ax = -br.v.x, ay = -br.v.y, az = -br.v.z, aw = br.s;
    immutable bx = worldQ.v.x, by = worldQ.v.y, bz = worldQ.v.z, bw = worldQ.s;
    immutable qx = aw * bx + ax * bw + ay * bz - az * by;
    immutable qy = aw * by - ax * bz + ay * bw + az * bx;
    immutable qz = aw * bz + ax * by - ay * bx + az * bw;
    immutable qw = aw * bw - ax * bx - ay * by - az * bz;
    return normalizeB3Quat(qx, qy, qz, qw);
}

private b3Quat normalizeB3Quat(float x, float y, float z, float w) pure nothrow @nogc {
    immutable len = sqrt(x * x + y * y + z * z + w * w);
    if (len <= 1e-20f)
        return b3Quat(b3Vec3(0.0f, 0.0f, 0.0f), 1.0f);
    immutable inv = 1.0f / len;
    return b3Quat(b3Vec3(x * inv, y * inv, z * inv), w * inv);
}

private Quat basisFromXZ(Vec3 xAxis, Vec3 zAxis) pure nothrow @nogc {
    immutable z = normalizeOrDefault(zAxis, Vec3(0.0f, 0.0f, 1.0f));
    Vec3 xRaw = xAxis - z * xAxis.dot(z);
    if (xRaw.lengthSquared() <= 1e-8f) {
        immutable fallback = fabsf(z.x) < 0.9f ? Vec3(1.0f, 0.0f, 0.0f) : Vec3(0.0f, 1.0f, 0.0f);
        xRaw = fallback - z * fallback.dot(z);
    }
    immutable x = normalizeOrDefault(xRaw, Vec3(1.0f, 0.0f, 0.0f));
    immutable y = z.cross(x);

    immutable m00 = x.x, m01 = y.x, m02 = z.x;
    immutable m10 = x.y, m11 = y.y, m12 = z.y;
    immutable m20 = x.z, m21 = y.z, m22 = z.z;

    immutable trace = m00 + m11 + m22;
    float qx, qy, qz, qw;
    if (trace > 0.0f) {
        immutable s = sqrt(trace + 1.0f) * 2.0f;
        qx = (m21 - m12) / s;
        qy = (m02 - m20) / s;
        qz = (m10 - m01) / s;
        qw = 0.25f * s;
    } else if (m00 > m11 && m00 > m22) {
        immutable s = sqrt(1.0f + m00 - m11 - m22) * 2.0f;
        qx = 0.25f * s;
        qy = (m01 + m10) / s;
        qz = (m02 + m20) / s;
        qw = (m21 - m12) / s;
    } else if (m11 > m22) {
        immutable s = sqrt(1.0f + m11 - m00 - m22) * 2.0f;
        qx = (m01 + m10) / s;
        qy = 0.25f * s;
        qz = (m12 + m21) / s;
        qw = (m02 - m20) / s;
    } else {
        immutable s = sqrt(1.0f + m22 - m00 - m11) * 2.0f;
        qx = (m02 + m20) / s;
        qy = (m12 + m21) / s;
        qz = 0.25f * s;
        qw = (m10 - m01) / s;
    }
    immutable len = sqrt(qx * qx + qy * qy + qz * qz + qw * qw);
    if (len <= 1e-20f)
        return Quat.init;
    immutable inv = 1.0f / len;
    return Quat(qx * inv, qy * inv, qz * inv, qw * inv);
}

private float sqrtLength(float x, float y, float z) pure nothrow @nogc {
    return sqrt(x * x + y * y + z * z);
}

private Vec3 normalizeOrDefault(Vec3 v, Vec3 fallback) pure nothrow @nogc {
    immutable len = sqrtLength(v.x, v.y, v.z);
    if (len <= 1e-6f)
        return fallback;
    return Vec3(v.x / len, v.y / len, v.z / len);
}

@safe nothrow @nogc unittest {
    static assert(isPod!RevoluteJointConfig);
    static assert(isPod!WeldJointConfig);
    static assert(isPod!SphericalJointConfig);
    static assert(isPod!WheelJointConfig);
    static assert(isPod!PrismaticJointConfig);
    static assert(isPod!BreakableJointEvent);

    immutable q = basisFromXZ(Vec3(0.0f, 1.0f, 0.0f), Vec3(1.0f, 0.0f, 0.0f));
    immutable rx = q.rotate(Vec3(1.0f, 0.0f, 0.0f));
    immutable rz = q.rotate(Vec3(0.0f, 0.0f, 1.0f));
    assert(fabsf(rx.x) < 1e-5f && fabsf(rx.y - 1.0f) < 1e-5f && fabsf(rx.z) < 1e-5f);
    assert(fabsf(rz.x - 1.0f) < 1e-5f && fabsf(rz.y) < 1e-5f && fabsf(rz.z) < 1e-5f);
}
