// Quick smoke test for the new Jolt-style PhysicsSystem + NarrowPhaseQuery.
// Not wired into dub.json — invoke via:
//   dmd -run source/engine/physics/smoke_raycast.d ...
// (kept as an example file; excluded from normal builds via module naming).
module engine.physics.tests.smoke_raycast;

version (PhysicsRayTest):

import std.stdio;
import std.math : isClose;
import engine.math.vec;
import engine.physics;

int main() {
    auto system = new PhysicsSystem!4096();
    system.init_();
    system.gravity = Vec3(0, -10, 0);

    auto bi = system.getBodyInterface();

    // A big static floor and a dynamic sphere above it.
    BodyCreationSettings floor;
    floor.motionType = EMotionType.Static;
    floor.position   = Vec3(0, -0.5f, 0);
    floor.shape      = Shape.makeBox(Vec3(100, 0.5f, 100));
    const floorId = bi.createAndAddBody(floor, EActivation.DontActivate);

    BodyCreationSettings sphere;
    sphere.motionType = EMotionType.Dynamic;
    sphere.position   = Vec3(0, 5, 0);
    sphere.shape      = Shape.makeSphere(0.5f);
    sphere.mass       = 1.0f;
    const sphereId = bi.createAndAddBody(sphere, EActivation.Activate);

    // Ray from high up pointing straight down should hit the sphere first.
    auto npq = system.getNarrowPhaseQuery();
    RayCastResult hit;
    immutable ray = RRayCast(Vec3(0, 20, 0), Vec3(0, -20, 0));
    assert(npq.castRay(ray, hit), "expected hit");
    assert(hit.bodyId == sphereId.toLegacy, "expected sphere first");
    writefln("raycast fraction=%.3f normal=(%.2f,%.2f,%.2f)",
             hit.fraction, hit.normal.x, hit.normal.y, hit.normal.z);

    // Side ray that misses the sphere must hit the floor box.
    RayCastResult hit2;
    immutable ray2 = RRayCast(Vec3(10, 5, 0), Vec3(0, -10, 0));
    assert(npq.castRay(ray2, hit2), "expected floor hit");
    assert(hit2.bodyId == floorId.toLegacy, "expected floor");
    writefln("floor raycast fraction=%.3f", hit2.fraction);

    writeln("raycast smoke OK");
    return 0;
}
