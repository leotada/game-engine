// Benchmark repro: mimic the forest scenario (static boxes on ground + rain
// of dynamic cubes) without any rendering, so we can see whether physics
// actually advances or spins forever.
module demo.test_physics;

import std.stdio : writefln;
import std.random : Mt19937, uniform;
import std.datetime.stopwatch : StopWatch, AutoStart;
import engine.math.vec;
import engine.physics;

int main() {
    auto w = new PhysicsWorld!4096();
    w.init_();
    w.gravity = Vec3(0, -20.0f, 0);

    // Ground
    w.addStatic(Vec3(0, -0.5f, 0), Shape.makeBox(Vec3(512, 0.5f, 512)));

    // A few static trunks + crowns on a small grid, like a mini forest.
    auto rng = Mt19937(0xBEEF);
    foreach (i; 0 .. 64) {
        immutable x = uniform(-20.0f, 20.0f, rng);
        immutable z = uniform(-20.0f, 20.0f, rng);
        immutable h = uniform(3.0f, 6.0f, rng);
        w.addStatic(Vec3(x, h * 0.5f, z), Shape.makeBox(Vec3(0.3f, h * 0.5f, 0.3f)));
        w.addStatic(Vec3(x, h + 1.5f, z), Shape.makeBox(Vec3(1.5f, 1.5f, 1.5f)));
    }

    writefln("bodies after statics = %d", w.bodyCount);

    enum dt = 1.0f / 60.0f;
    auto sw = StopWatch(AutoStart.yes);
    foreach (frame; 0 .. 600) {
        // Spawn 8 cubes per frame until 200 dynamics.
        foreach (_; 0 .. 8) {
            if (w.bodyCount >= 400) break;
            immutable x = uniform(-25.0f, 25.0f, rng);
            immutable z = uniform(-25.0f, 25.0f, rng);
            immutable y = 25.0f + uniform(0.0f, 10.0f, rng);
            w.addDynamic(Vec3(x, y, z), Shape.makeBox(Vec3(0.5f, 0.5f, 0.5f)), 1.0f);
        }

        immutable tStart = sw.peek.total!"usecs";
        w.step(dt);
        immutable tEnd = sw.peek.total!"usecs";

        if (frame % 60 == 0) {
            // Find a dynamic body's position to check if stuff is falling.
            Vec3 samplePos = Vec3.init;
            float minY = 1e9f;
            uint dyn = 0;
            foreach (i; 0 .. w.bodyCount) {
                if (w.invMass[i] == 0) continue;
                dyn++;
                if (w.position[i].y < minY) { minY = w.position[i].y; samplePos = w.position[i]; }
            }
            writefln("frame %3d | step=%6d us | bodies=%4d | dyn=%3d | lowest=(%.2f,%.2f,%.2f) | manifolds=%d pairs=%d",
                frame, tEnd - tStart, w.bodyCount, dyn,
                samplePos.x, samplePos.y, samplePos.z,
                w.stats.manifoldCount, w.stats.broadphasePairs);
        }
    }
    return 0;
}
