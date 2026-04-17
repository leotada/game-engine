// Minimal headless smoke test: drop a box onto a static ground box and
// verify it comes to rest above the ground within a few seconds.
//
// This is a quick command-line repro of the physics pipeline. The full
// regression suite lives as @safe unittests inside engine.physics.world —
// run them with `dub test`.
module demo.test_physics;

import std.stdio : writefln;
import engine.math.vec;
import engine.physics;

int main() {
    auto world = new PhysicsWorld!(64, 128);
    world.init_();
    world.gravity = Vec3(0, -20.0f, 0);

    world.addStatic(Vec3(0, -0.5f, 0), Shape.makeBox(Vec3(10, 0.5f, 10)));
    immutable cube = world.addDynamic(Vec3(0, 5.0f, 0), Shape.makeBox(Vec3(0.5f, 0.5f, 0.5f)), 1.0f);

    enum dt = 1.0f / 60.0f;
    foreach (f; 0 .. 180) world.step(dt);

    immutable y = world.position[cube].y;
    if (y < 0.3f || y > 0.8f) {
        writefln("FAIL: cube final y = %f (expected ~0.5)", y);
        return 1;
    }
    writefln("PASS: cube rested at y = %f", y);
    return 0;
}
