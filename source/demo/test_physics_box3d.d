module demo.test_physics_box3d;

import std.math : fabs;
import std.stdio : writefln, writeln;

import bindings.box3d;
import engine.ecs.store : EntityId;
import engine.math.vec : Vec3;
import engine.physics;

@safe:

private struct EventState {
    EntityId sensorEntity;
    EntityId rollerEntity;
    bool sensorEntered;
    bool sensorExited;
    bool printedEnter;
    bool printedExit;
}

private void onSensorEnter(PhysicsSensorEvent event, void* context) nothrow @nogc @trusted {
    auto state = cast(EventState*) context;
    if (state !is null &&
        event.sensorEntity == state.sensorEntity &&
        event.visitorEntity == state.rollerEntity)
        state.sensorEntered = true;
}

private void onSensorExit(PhysicsSensorEvent event, void* context) nothrow @nogc @trusted {
    auto state = cast(EventState*) context;
    if (state !is null &&
        event.sensorEntity == state.sensorEntity &&
        event.visitorEntity == state.rollerEntity)
        state.sensorExited = true;
}

int main() {
    enum float dt = 1.0f / 60.0f;
    enum int totalFrames = 240;

    auto world = PhysicsWorld(Vec3(0.0f, -9.81f, 0.0f));

    immutable EntityId groundEntity = 1;
    immutable EntityId sphereEntity = 2;
    immutable EntityId sensorEntity = 3;
    immutable EntityId rollerEntity = 4;

    b3BodyId ground = createGroundSlab(world, 0.0f, Vec3(40.0f, 0.0f, 40.0f), 0.5f, groundEntity);
    b3BodyId sphere = createDynamicSphere(world, Vec3(-4.0f, 8.0f, 0.0f), 0.5f, 1.0f, sphereEntity);
    b3BodyId sensor = createSensorBox(world, Vec3(-10.0f, 1.0f, 0.0f), Vec3(2.0f, 2.0f, 2.0f), sensorEntity);
    b3BodyId roller = createDynamicBox(world, Vec3(-16.0f, 0.5f, 0.0f), Vec3(0.4f, 0.4f, 0.4f), 1.0f, rollerEntity, 0.0f);
    setLinearVelocity(roller, Vec3(12.0f, 0.0f, 0.0f));

    b3BodyId[5] stack;
    foreach (i; 0 .. stack.length) {
        immutable y = 0.5f + cast(float) i * 1.05f;
        stack[i] = createDynamicBox(world, Vec3(0.0f, y, 0.0f), Vec3(0.5f, 0.5f, 0.5f), 1.0f, cast(EntityId)(10 + i));
    }

    EventState events;
    events.sensorEntity = sensorEntity;
    events.rollerEntity = rollerEntity;
    ContactListener listener;
    listener.onSensorEnter = &onSensorEnter;
    listener.onSensorExit = &onSensorExit;
    listener.context = &events;

    bool rayHitGround = false;
    float lastRayFraction = 1.0f;

    writeln("[test-physics-box3d] headless smoke test");

    foreach (frame; 1 .. totalFrames + 1) {
        world.step(dt, 4);
        drainPhysicsEvents(world, listener);

        auto ray = castRayClosest(world, Vec3(0.0f, 20.0f, 0.0f), Vec3(0.0f, -1.0f, 0.0f), 40.0f);
        if (ray.hit) {
            rayHitGround = true;
            lastRayFraction = ray.fraction;
        }

        if (events.sensorEntered && !events.printedEnter) {
            writefln("[test-physics-box3d] frame %3d: SENSOR ENTER", frame);
            events.printedEnter = true;
        }

        if (events.sensorExited && !events.printedExit) {
            writefln("[test-physics-box3d] frame %3d: SENSOR EXIT", frame);
            events.printedExit = true;
        }

        if (frame % 30 == 0) {
            immutable sp = getPosition(sphere);
            immutable rp = getPosition(roller);
            immutable top = getPosition(stack[$ - 1]);
            writefln("frame %3d | sphere.y=%6.3f stackTop.y=%6.3f roller.x=%6.3f ray.frac=%5.3f",
                frame, sp.y, top.y, rp.x, lastRayFraction);
        }
    }

    bool pass = true;

    immutable spherePos = getPosition(sphere);
    if (fabs(spherePos.y - 0.5f) > 0.35f) {
        writefln("[test-physics-box3d] FAIL: sphere rested at y=%.3f", spherePos.y);
        pass = false;
    }

    foreach (i, body; stack) {
        immutable p = getPosition(body);
        if (p.y < 0.35f || p.y > 8.0f || fabs(p.x) > 2.0f || fabs(p.z) > 2.0f) {
            writefln("[test-physics-box3d] FAIL: stack-%u unstable at pos=(%.3f, %.3f, %.3f)",
                i, p.x, p.y, p.z);
            pass = false;
        }
    }

    if (!events.sensorEntered || !events.sensorExited) {
        writefln("[test-physics-box3d] FAIL: sensor events enter=%s exit=%s",
            events.sensorEntered, events.sensorExited);
        pass = false;
    }

    if (!rayHitGround || lastRayFraction >= 1.0f) {
        writefln("[test-physics-box3d] FAIL: raycast hit=%s fraction=%.3f", rayHitGround, lastRayFraction);
        pass = false;
    }

    if (getBodyEntity(sphere) != sphereEntity || getBodyEntity(sensor) != sensorEntity) {
        writeln("[test-physics-box3d] FAIL: body userData entity mapping mismatch");
        pass = false;
    }

    if (pass) {
        writeln("[test-physics-box3d] PASS");
        return 0;
    }

    writeln("[test-physics-box3d] FAIL");
    return 1;
}
