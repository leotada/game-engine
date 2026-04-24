module demo.test_physics;

import std.stdio : writefln, writeln;
import engine.jph.geometry.plane : Plane;
import engine.jph.math.quat : Quat;
import engine.jph.math.vec3 : Vec3;
import engine.jph.physics;

@safe:

private struct TrackedBody {
    string label;
    BodyID id;
}

private BodyID addDynamicSphere(ref BodyInterface inBodyInterface,
                                Vec3 inPosition,
                                float inRadius,
                                Vec3 inLinearVelocity = Vec3.sZero()) {
    BodyCreationSettings settings = BodyCreationSettings(
        new SphereShape(inRadius),
        inPosition,
        Quat.sIdentity(),
        EMotionType.Dynamic);
    settings.mLinearVelocity = inLinearVelocity;
    settings.mFriction = 0.9f;
    settings.mRestitution = 0.0f;
    return inBodyInterface.CreateAndAddBody(settings, EActivation.Activate);
}

private BodyID addDynamicBox(ref BodyInterface inBodyInterface,
                             Vec3 inPosition,
                             Vec3 inHalfExtent,
                             Vec3 inLinearVelocity = Vec3.sZero()) {
    BodyCreationSettings settings = BodyCreationSettings(
        new BoxShape(inHalfExtent),
        inPosition,
        Quat.sIdentity(),
        EMotionType.Dynamic);
    settings.mLinearVelocity = inLinearVelocity;
    settings.mFriction = 0.8f;
    settings.mRestitution = 0.0f;
    return inBodyInterface.CreateAndAddBody(settings, EActivation.Activate);
}

private void addGroundPlane(ref BodyInterface inBodyInterface) {
    BodyCreationSettings settings = BodyCreationSettings(
        new PlaneShape(Plane.sFromPointAndNormal(Vec3.sZero(), Vec3.sAxisY())),
        Vec3.sZero(),
        Quat.sIdentity(),
        EMotionType.Static);
    settings.mFriction = 1.0f;
    settings.mRestitution = 0.0f;
    inBodyInterface.CreateAndAddBody(settings, EActivation.DontActivate);
}

private void logFrame(ref PhysicsSystem inSystem,
                      ref BodyInterface inBodyInterface,
                      scope const(TrackedBody)[] inTrackedBodies,
                      uint inFrame) {
    writefln("frame %3d | active=%u | manifolds=%u | pairs=%u",
        inFrame,
        inSystem.mStats.mActiveBodies,
        inSystem.mStats.mManifoldCount,
        inSystem.mStats.mBroadphasePairs);

    foreach (tracked; inTrackedBodies) {
        immutable position = inBodyInterface.GetCenterOfMassPosition(tracked.id);
        immutable velocity = inBodyInterface.GetLinearVelocity(tracked.id);
        writefln("  %-12s pos=(%7.3f,%7.3f,%7.3f) vel=(%7.3f,%7.3f,%7.3f)",
            tracked.label,
            position.GetX(), position.GetY(), position.GetZ(),
            velocity.GetX(), velocity.GetY(), velocity.GetZ());
    }
}

int main() {
    enum float dt = 1.0f / 60.0f;
    PhysicsSystem system;
    system.Init(64);

    auto bodyInterface = &system.GetBodyInterface();
    addGroundPlane(*bodyInterface);

    TrackedBody[] trackedBodies;
    trackedBodies ~= TrackedBody("sphere-left", addDynamicSphere(*bodyInterface, Vec3(-6.0f, 4.0f, 0.0f), 0.5f));
    trackedBodies ~= TrackedBody("box-center", addDynamicBox(*bodyInterface, Vec3(-2.0f, 5.0f, 0.0f), Vec3(0.5f, 0.5f, 0.5f)));
    trackedBodies ~= TrackedBody("box-slide", addDynamicBox(*bodyInterface, Vec3(2.0f, 2.5f, 0.0f), Vec3(0.5f, 0.5f, 0.5f), Vec3(3.0f, 0.0f, 0.0f)));
    trackedBodies ~= TrackedBody("sphere-slide", addDynamicSphere(*bodyInterface, Vec3(6.0f, 3.5f, 0.0f), 0.5f, Vec3(-2.0f, 0.0f, 0.0f)));

    writeln("[test-physics] headless rigid-body sandbox");
    writeln("[test-physics] supported contacts today: sphere-plane and box-plane");
    logFrame(system, *bodyInterface, trackedBodies, 0);

    foreach (frame; 1 .. 181) {
        system.Step(dt);
        if (frame % 30 == 0)
            logFrame(system, *bodyInterface, trackedBodies, cast(uint) frame);
    }

    bool allBodiesAboveGround = true;
    foreach (tracked; trackedBodies) {
        immutable position = bodyInterface.GetCenterOfMassPosition(tracked.id);
        if (position.GetY() < 0.45f)
            allBodiesAboveGround = false;
    }

    writeln(allBodiesAboveGround
        ? "[test-physics] final state: bodies remained supported by the plane."
        : "[test-physics] final state: at least one body fell through the plane.");
    writeln("[test-physics] legacy forest-style scenario remains in source/demo/_legacy/test_physics.d.txt.");
    return allBodiesAboveGround ? 0 : 1;
}
