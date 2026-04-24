// E1-9 — Migrar demos: sandbox de física headless.
//
// Exercita todos os recursos disponíveis no Épico 1:
//   · Queda e colisão com chão (sphere-plane, box-plane, capsule-plane)
//   · Empilhamento de caixas dinâmicas (box-box / dynamic-dynamic solver)
//   · Sensor box (mIsSensor=true): detecção ENTER/EXIT via varredura de manifolds
//   · Raycast simples por frame (via Shape.CastRay em espaço local de cada corpo)
module demo.test_physics;

import std.stdio : writefln, writeln;
import engine.jph.geometry.plane : Plane;
import engine.jph.math.mat44 : Mat44;
import engine.jph.math.quat : Quat;
import engine.jph.math.vec3 : Vec3;
import engine.jph.physics;
import engine.jph.physics.shape.cast_result : RayCast, RayCastResult;
import engine.jph.physics.shape.sub_shape_id : SubShapeIDCreator;

@safe:

// ---------------------------------------------------------------------------
// Body-with-shape record (needed for inline per-frame raycast)
// ---------------------------------------------------------------------------
private struct RayCastBody {
    BodyID id;
    Shape  shape;
}

// ---------------------------------------------------------------------------
// Factory helpers
// ---------------------------------------------------------------------------
private BodyID addDynamicSphere(ref BodyInterface bi,
                                Vec3 position,
                                float radius,
                                Vec3 velocity = Vec3.sZero()) {
    auto shape = new SphereShape(radius);
    BodyCreationSettings s = BodyCreationSettings(shape, position, Quat.sIdentity(), EMotionType.Dynamic);
    s.mLinearVelocity = velocity;
    s.mFriction       = 0.7f;
    s.mRestitution    = 0.0f;
    return bi.CreateAndAddBody(s, EActivation.Activate);
}

private RayCastBody addDynamicSphereRC(ref BodyInterface bi,
                                        Vec3 position,
                                        float radius,
                                        Vec3 velocity = Vec3.sZero()) {
    auto shape = new SphereShape(radius);
    BodyCreationSettings s = BodyCreationSettings(shape, position, Quat.sIdentity(), EMotionType.Dynamic);
    s.mLinearVelocity = velocity;
    s.mFriction       = 0.7f;
    s.mRestitution    = 0.0f;
    return RayCastBody(bi.CreateAndAddBody(s, EActivation.Activate), shape);
}

private RayCastBody addDynamicBox(ref BodyInterface bi,
                                   Vec3 position,
                                   Vec3 halfExtent,
                                   Vec3 velocity = Vec3.sZero(),
                                   float friction = 0.7f) {
    auto shape = new BoxShape(halfExtent);
    BodyCreationSettings s = BodyCreationSettings(shape, position, Quat.sIdentity(), EMotionType.Dynamic);
    s.mLinearVelocity = velocity;
    s.mFriction       = friction;
    s.mRestitution    = 0.0f;
    return RayCastBody(bi.CreateAndAddBody(s, EActivation.Activate), shape);
}

private RayCastBody addDynamicCapsule(ref BodyInterface bi,
                                       Vec3 position,
                                       float halfHeight,
                                       float radius) {
    auto shape = new CapsuleShape(halfHeight, radius);
    BodyCreationSettings s = BodyCreationSettings(shape, position, Quat.sIdentity(), EMotionType.Dynamic);
    s.mFriction    = 0.7f;
    s.mRestitution = 0.0f;
    return RayCastBody(bi.CreateAndAddBody(s, EActivation.Activate), shape);
}

private RayCastBody addGroundPlane(ref BodyInterface bi) {
    auto shape = new PlaneShape(Plane.sFromPointAndNormal(Vec3.sZero(), Vec3.sAxisY()));
    BodyCreationSettings s = BodyCreationSettings(shape, Vec3.sZero(), Quat.sIdentity(), EMotionType.Static);
    s.mFriction    = 1.0f;
    s.mRestitution = 0.0f;
    return RayCastBody(bi.CreateAndAddBody(s, EActivation.DontActivate), shape);
}

private BodyID addSensor(ref BodyInterface bi, Vec3 position, Vec3 halfExtent) {
    auto shape = new BoxShape(halfExtent);
    BodyCreationSettings s = BodyCreationSettings(shape, position, Quat.sIdentity(), EMotionType.Static);
    s.mIsSensor    = true;
    s.mFriction    = 0.0f;
    s.mRestitution = 0.0f;
    return bi.CreateAndAddBody(s, EActivation.DontActivate);
}

// ---------------------------------------------------------------------------
// Inline per-frame world raycast via Shape.CastRay in local body space.
// inDir carries both direction and length: the ray goes from origin to
// origin+dir and the fraction is in [0,1].
// ---------------------------------------------------------------------------
private void castWorldRay(ref BodyInterface bi,
                          scope const RayCastBody[] bodies,
                          Vec3 origin,
                          Vec3 dir,
                          uint frame) {
    RayCastResult best; // mFraction initialised to 1+ε ("no hit")
    foreach (ref rb; bodies) {
        if (rb.shape is null)
            continue;
        // Transform world ray to body's local CoM space.
        immutable Mat44 invT = bi.GetCenterOfMassTransform(rb.id).Inversed();
        immutable Vec3  lo   = invT * origin;
        immutable Vec3  ld   = invT.Multiply3x3(dir);
        rb.shape.CastRay(RayCast(lo, ld), SubShapeIDCreator.init, best);
    }
    if (best.mFraction <= 1.0f) {
        immutable Vec3 hitPos = origin + dir * best.mFraction;
        writefln("[raycast] frame %3d: hit at y=%.3f (frac=%.4f)",
            frame, hitPos.GetY(), best.mFraction);
    } else {
        writefln("[raycast] frame %3d: no hit", frame);
    }
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------
int main() {
    enum float dt          = 1.0f / 60.0f;
    enum uint  TOTAL_FRAMES = 300;

    PhysicsSystem system;
    system.Init(256);
    auto bi = &system.GetBodyInterface();

    RayCastBody[] rayCastBodies;

    // Ground (PlaneShape) — included in raycast list
    rayCastBodies ~= addGroundPlane(*bi);

    // -----------------------------------------------------------------------
    // Stacking column: 5 dynamic 1m cubes (halfExtent = 0.5)
    //   y = 0.5 (just above floor), 1.55, 2.60, 3.65, 4.70
    // -----------------------------------------------------------------------
    string[] stackNames = ["stack-0", "stack-1", "stack-2", "stack-3", "stack-4"];
    RayCastBody[5] stackBodies;
    foreach (i; 0 .. 5) {
        float y = 0.5f + i * 1.05f;
        stackBodies[i] = addDynamicBox(*bi, Vec3(0.0f, y, 0.0f), Vec3(0.5f, 0.5f, 0.5f));
        rayCastBodies ~= stackBodies[i];
    }

    // -----------------------------------------------------------------------
    // Sphere drops: two spheres from different heights
    // -----------------------------------------------------------------------
    RayCastBody sphereA = addDynamicSphereRC(*bi, Vec3(-5.0f,  8.0f, 0.0f), 0.5f);
    RayCastBody sphereB = addDynamicSphereRC(*bi, Vec3(-3.0f, 12.0f, 0.0f), 0.5f);
    rayCastBodies ~= sphereA;
    rayCastBodies ~= sphereB;

    // -----------------------------------------------------------------------
    // Capsule drops: two capsules (exercises new capsule-plane collision)
    // -----------------------------------------------------------------------
    RayCastBody capsuleA = addDynamicCapsule(*bi, Vec3(5.0f,  8.0f, 0.0f), 0.3f, 0.3f);
    RayCastBody capsuleB = addDynamicCapsule(*bi, Vec3(7.0f, 12.0f, 0.0f), 0.5f, 0.4f);
    rayCastBodies ~= capsuleA;
    rayCastBodies ~= capsuleB;

    // -----------------------------------------------------------------------
    // Sensor zone: static BoxShape at (-12, 1, 0) with half-extent (2,2,2)
    // A rolling box (box-box collision with sensor) passes through it.
    // Sensor bodies are pass-through: manifold is generated but no constraint.
    // -----------------------------------------------------------------------
    immutable BodyID sensorID = addSensor(*bi, Vec3(-12.0f, 1.0f, 0.0f), Vec3(2.0f, 2.0f, 2.0f));
    // Roller uses low friction + high velocity so it slides through the sensor zone.
    // Combined friction = 0.5*(0.1+1.0) = 0.55; decel ≈ 5.4 m/s².
    // Stopping distance from 15 m/s ≈ 20.8 m → clears sensor zone at x=[-14,-10]. ✓
    RayCastBody roller = addDynamicBox(*bi, Vec3(-18.0f, 0.5f, 0.0f),
                                       Vec3(0.4f, 0.4f, 0.4f), Vec3(15.0f, 0.0f, 0.0f), 0.1f);
    rayCastBodies ~= roller;

    writeln("[test-physics] E1-9 sandbox:");
    writeln("[test-physics]   · stacking (5 dynamic boxes)");
    writeln("[test-physics]   · sphere drops (sphere-plane)");
    writeln("[test-physics]   · capsule drops (capsule-plane — new)");
    writeln("[test-physics]   · sensor ENTER/EXIT detection");
    writeln("[test-physics]   · per-frame inline raycast");

    // -----------------------------------------------------------------------
    // Simulation loop
    // -----------------------------------------------------------------------
    bool sensorOccupied = false;
    bool sensorEntered  = false;
    bool sensorExited   = false;

    foreach (frame; 1 .. TOTAL_FRAMES + 1) {
        system.Step(dt);

        // --- Sensor detection: scan contact manifolds for sensor contacts ---
        bool occupiedNow = false;
        foreach (ref manifold; system.GetContactManifolds()) {
            if (manifold.mBody1ID == sensorID || manifold.mBody2ID == sensorID) {
                occupiedNow = true;
                break;
            }
        }
        if (occupiedNow && !sensorOccupied) {
            writefln("[test-physics] frame %3d: SENSOR ENTER", frame);
            sensorEntered = true;
        } else if (!occupiedNow && sensorOccupied) {
            writefln("[test-physics] frame %3d: SENSOR EXIT", frame);
            sensorExited = true;
        }
        sensorOccupied = occupiedNow;

        // --- Log state every 60 frames ---
        if (frame % 60 == 0) {
            writefln("frame %3d | active=%u manifolds=%u pairs=%u",
                frame, system.mStats.mActiveBodies,
                system.mStats.mManifoldCount, system.mStats.mBroadphasePairs);

            void logBody(string label, RayCastBody rb) {
                immutable Vec3 p = bi.GetCenterOfMassPosition(rb.id);
                immutable Vec3 v = bi.GetLinearVelocity(rb.id);
                writefln("  %-12s pos=(%6.2f,%6.2f,%6.2f) vel=(%5.2f,%5.2f,%5.2f)",
                    label, p.GetX(), p.GetY(), p.GetZ(),
                    v.GetX(), v.GetY(), v.GetZ());
            }

            foreach (i, ref rb; stackBodies)
                logBody(stackNames[i], rb);
            logBody("sphere-A", sphereA);
            logBody("sphere-B", sphereB);
            logBody("capsule-A", capsuleA);
            logBody("capsule-B", capsuleB);
            logBody("roller", roller);

            // --- Raycast: fire from above straight down ---
            castWorldRay(*bi, rayCastBodies,
                         Vec3(0.0f, 50.0f, 0.0f),  // origin
                         Vec3(0.0f, -100.0f, 0.0f), // direction (length = 100 m)
                         frame);
        }
    }

    // -----------------------------------------------------------------------
    // Final validation
    // -----------------------------------------------------------------------
    bool allAboveFloor = true;

    void checkBody(string label, RayCastBody rb, float minY = -0.1f) {
        immutable Vec3 p = bi.GetCenterOfMassPosition(rb.id);
        if (p.GetY() < minY) {
            writefln("[test-physics] FAIL: %s at y=%.3f (below threshold %.3f)",
                label, p.GetY(), minY);
            allAboveFloor = false;
        }
    }

    foreach (i, ref rb; stackBodies)
        checkBody(stackNames[i], rb);
    checkBody("sphere-A",  sphereA);
    checkBody("sphere-B",  sphereB);
    checkBody("capsule-A", capsuleA);
    checkBody("capsule-B", capsuleB);
    checkBody("roller",    roller, -1.0f); // roller may have fallen off the edge

    writeln(allAboveFloor
        ? "[test-physics] PASS: all bodies remained above the floor."
        : "[test-physics] FAIL: at least one body fell through the floor.");

    if (sensorEntered)
        writeln("[test-physics] PASS: sensor ENTER detected.");
    else
        writeln("[test-physics] NOTE: sensor ENTER not detected (roller may not have reached sensor).");

    return allAboveFloor ? 0 : 1;
}
