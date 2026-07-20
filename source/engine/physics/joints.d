module engine.physics.joints;

import bindings.box3d;
import engine.math.vec : Vec3;
import engine.physics.convert : toB3Pos, toB3Quat, toB3Vec3, toEngineQuat;
import engine.physics.world : PhysicsWorld;

@safe:

b3JointId createDistanceJoint(ref PhysicsWorld world,
                              b3BodyId bodyA,
                              b3BodyId bodyB,
                              Vec3 worldAnchorA,
                              Vec3 worldAnchorB,
                              float length = -1.0f,
                              bool collideConnected = false) nothrow @nogc @trusted {
    b3DistanceJointDef def = b3DefaultDistanceJointDefD();
    def.base.bodyIdA = bodyA;
    def.base.bodyIdB = bodyB;
    def.base.collideConnected = collideConnected;
    def.base.localFrameA.p = b3Body_GetLocalPointD(bodyA, toB3Pos(worldAnchorA));
    def.base.localFrameB.p = b3Body_GetLocalPointD(bodyB, toB3Pos(worldAnchorB));
    def.base.localFrameA.q = b3Quat(b3Vec3(0.0f, 0.0f, 0.0f), 1.0f);
    def.base.localFrameB.q = b3Quat(b3Vec3(0.0f, 0.0f, 0.0f), 1.0f);

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

/// Revolute (hinge) joint. `axis` is the world-space hinge axis (normalized preferred).
b3JointId createRevoluteJoint(ref PhysicsWorld world,
                              b3BodyId bodyA,
                              b3BodyId bodyB,
                              Vec3 worldAnchor,
                              Vec3 axis,
                              bool collideConnected = false) nothrow @nogc @trusted {
    immutable axisN = normalizeOrY(axis);
    immutable axisQuat = toEngineQuat(b3ComputeQuatBetweenUnitVectorsD(
        b3Vec3(0.0f, 0.0f, 1.0f), toB3Vec3(axisN)));

    b3RevoluteJointDef def = b3DefaultRevoluteJointDefD();
    def.base.bodyIdA = bodyA;
    def.base.bodyIdB = bodyB;
    def.base.collideConnected = collideConnected;
    def.base.localFrameA.p = b3Body_GetLocalPointD(bodyA, toB3Pos(worldAnchor));
    def.base.localFrameB.p = b3Body_GetLocalPointD(bodyB, toB3Pos(worldAnchor));
    def.base.localFrameA.q = toB3Quat(axisQuat);
    def.base.localFrameB.q = toB3Quat(axisQuat);
    return b3CreateRevoluteJointD(world.handle, &def);
}

b3JointId createWeldJoint(ref PhysicsWorld world,
                          b3BodyId bodyA,
                          b3BodyId bodyB,
                          Vec3 worldAnchor,
                          bool collideConnected = false) nothrow @nogc @trusted {
    b3WeldJointDef def = b3DefaultWeldJointDefD();
    def.base.bodyIdA = bodyA;
    def.base.bodyIdB = bodyB;
    def.base.collideConnected = collideConnected;
    def.base.localFrameA.p = b3Body_GetLocalPointD(bodyA, toB3Pos(worldAnchor));
    def.base.localFrameB.p = b3Body_GetLocalPointD(bodyB, toB3Pos(worldAnchor));
    def.base.localFrameA.q = b3Quat(b3Vec3(0.0f, 0.0f, 0.0f), 1.0f);
    def.base.localFrameB.q = b3Quat(b3Vec3(0.0f, 0.0f, 0.0f), 1.0f);
    return b3CreateWeldJointD(world.handle, &def);
}

void destroyJoint(b3JointId jointId, bool wakeAttached = true) nothrow @nogc @trusted {
    b3DestroyJointD(jointId, wakeAttached);
}

private float sqrtLength(float x, float y, float z) nothrow @nogc {
    import core.stdc.math : sqrtf;
    return sqrtf(x * x + y * y + z * z);
}

private Vec3 normalizeOrY(Vec3 v) nothrow @nogc {
    immutable len = sqrtLength(v.x, v.y, v.z);
    if (len <= 1e-6f)
        return Vec3(0.0f, 1.0f, 0.0f);
    return Vec3(v.x / len, v.y / len, v.z / len);
}
