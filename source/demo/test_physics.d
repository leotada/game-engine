// Minimal headless smoke test: drop a box onto a static ground box and
// verify it comes to rest above the ground within a few seconds.
module demo.test_physics;

import std.stdio : writefln, writeln;
import engine.math.vec;
import engine.physics;

int main() {
    auto world = new PhysicsWorld!(64, 128);
    world.init_();
    world.gravity = Vec3(0, -20.0f, 0);

    // Ground: 20 m × 1 m × 20 m box centred at y = -0.5 so its top is at y = 0.
    immutable ground = world.addStatic(Vec3(0, -0.5f, 0), Shape.makeBox(Vec3(10, 0.5f, 10)));
    writefln("ground id=%d", ground);

    // Dropped cube: 1 m³ box at y = 5, mass 1 kg.
    immutable cube = world.addDynamic(Vec3(0, 5.0f, 0), Shape.makeBox(Vec3(0.5f, 0.5f, 0.5f)), 1.0f);
    writefln("cube id=%d invMass=%f", cube, world.invMass[cube]);

    enum dt = 1.0f / 60.0f;
    writefln("step  y         vy        manifolds pairs");
    foreach (f; 0 .. 180) {
        world.step(dt);
        if (f % 10 == 0 || f < 5) {
            writefln("%4d  %+8.4f  %+8.4f  %9d %5d",
                f, world.position[cube].y, world.linearVel[cube].y,
                world.stats.manifoldCount, world.stats.broadphasePairs);
        }
    }

    immutable finalY = world.position[cube].y;
    if (finalY < 0.3f || finalY > 0.8f) {
        writefln("FAIL: cube final y = %f (expected ~0.5)", finalY);
        return 1;
    }
    writefln("PASS: cube rested at y = %f", finalY);
    return 0;
}
