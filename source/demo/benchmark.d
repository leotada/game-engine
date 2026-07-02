// Box3D visual 12-second benchmark.
//
// Scene: 1 static floor and a grid of dynamic unit cubes.
// Measures physics throughput and GC behaviour
// under sustained load.
module demo.benchmark;

import core.memory : GC;
import core.time : Duration;
import std.format : format;
import std.math : cos, sin;
import std.random : Mt19937, uniform;
import std.stdio : writefln;

import engine.app : App;
import bindings.wgpu : WGPUPresentMode;
import engine.gpu.text : FpsCounter, TextRenderer;
import engine.graphics.mesh : Mesh;
import engine.graphics.types : Color4;
import engine.math.mat : Mat4;
import engine.math.vec : Vec3;
import engine.platform.input : Key;
import engine.physics;
import engine.scene.camera : Camera;
import engine.scene.scene3d : Scene3D;
import bindings.box3d : b3BodyId;

@safe:

private enum SCREEN_W = 1280;
private enum SCREEN_H = 720;
private enum BENCHMARK_SECONDS = 12.0f;
private enum PHYS_STEP = 1.0f / 60.0f;
private enum MAX_SUBSTEPS = 4;

private enum CUBE_COLS   = 10;   // X axis
private enum CUBE_ROWS   = 10;   // Z axis
private enum CUBE_LAYERS = 8;    // Y axis
private enum NUM_CUBES   = CUBE_COLS * CUBE_ROWS * CUBE_LAYERS;

private double toMs(Duration d) pure nothrow @safe { return d.total!"hnsecs" / 10_000.0; }

private Mat4 toRenderMat4(PhysicsTransform transform) {
    Mat4 result = transform.rotation.toMat4();
    result.m[12] = transform.position.x;
    result.m[13] = transform.position.y;
    result.m[14] = transform.position.z;
    return result;
}

int main() {
    auto app = App.create(format("Box3D Cube Benchmark %d cubes", NUM_CUBES), SCREEN_W, SCREEN_H,
                          WGPUPresentMode.immediate);

    auto scene = Scene3D.create(app.gpu);
    scope(exit) scene.destroy();
    auto cubeMesh = Mesh.cube(app.gpu);
    scope(exit) cubeMesh.destroy();
    auto text = TextRenderer.create(app.gpu, SCREEN_W, SCREEN_H);
    scope(exit) text.destroy();
    auto fps = FpsCounter.create();

    auto physics = PhysicsWorld(Vec3(0.0f, -9.81f, 0.0f));

    // -----------------------------------------------------------------------
    // Static floor: 40m × 1m × 40m centred at (0, -0.5, 0)
    // -----------------------------------------------------------------------
    createStaticBox(physics, Vec3(0.0f, -0.5f, 0.0f), Vec3(20.0f, 0.5f, 20.0f), noPhysicsEntity, 1.0f);

    // -----------------------------------------------------------------------
    // Small per-cube jitter avoids perfectly aligned stacks (which produce
    // degenerate contact patterns and hide broadphase pair counts).
    // -----------------------------------------------------------------------
    auto rng = Mt19937(0xF00Du);
    b3BodyId[NUM_CUBES] cubeIDs;
    {
        uint idx = 0;
        foreach (layer; 0 .. CUBE_LAYERS) {
            foreach (row; 0 .. CUBE_ROWS) {
                foreach (col; 0 .. CUBE_COLS) {
                    // 1.3 m horizontal spacing on a 1 m cube (convexRadius=0.05) =>
                    // outer-shell gap = 1.3 - 2*0.55 = 0.20 m > combinedConvexRadius (0.10 m).
                    // This prevents GJK from generating lateral speculative contacts between
                    // side-by-side cubes.
                    immutable float x = (col - (CUBE_COLS  - 1) * 0.5f) * 1.3f + uniform(-0.02f, 0.02f, rng);
                    immutable float z = (row - (CUBE_ROWS  - 1) * 0.5f) * 1.3f + uniform(-0.02f, 0.02f, rng);
                    immutable float y = 1.5f + layer * 1.2f + uniform(-0.01f, 0.01f, rng);
                    cubeIDs[idx++] = createDynamicBox(physics, Vec3(x, y, z), Vec3(0.5f, 0.5f, 0.5f), 1.0f, noPhysicsEntity, 0.7f);
                }
            }
        }
    }

    auto camera = Camera.create(0.9f, SCREEN_W, SCREEN_H, 0.1f, 300.0f);

    float elapsed     = 0.0f;
    float accumulator = 0.0f;
    uint  frames      = 0;
    float minAvgY = float.max;
    uint  maxBelowFloor = 0;

    GC.profileStats(); // prime GC stats tracking

    writefln("[benchmark] Box3D cubes=%d static=1", NUM_CUBES);

    // Periodic FPS reporting so we see throughput trend, not just final avg.
    float reportElapsed = 0.0f;
    uint  reportFrames  = 0;
    enum  REPORT_INTERVAL = 2.0f; // seconds

    while (elapsed < BENCHMARK_SECONDS) {
        app.pollEvents();
        // Deliberately ignore SDL_EVENT_QUIT / window-close during the
        // timed run — only ESC or the timer can stop the benchmark.
        immutable rawDt = fps.tick();
        immutable float dt = rawDt > 0.1f ? 0.1f : rawDt;
        elapsed += dt;
        ++frames;

        if (app.input.keyPressed(Key.escape))
            break;

        // Physics substep accumulator
        accumulator += dt;
        if (accumulator > PHYS_STEP * MAX_SUBSTEPS)
            accumulator = PHYS_STEP * MAX_SUBSTEPS;

        uint subSteps = 0;
        while (accumulator >= PHYS_STEP && subSteps < MAX_SUBSTEPS) {
            physics.step(PHYS_STEP, 4);
            accumulator -= PHYS_STEP;
            ++subSteps;
            // Keep SDL/Wayland responsive during heavy physics steps so the
            // compositor does not send SDL_EVENT_WINDOW_CLOSE_REQUESTED.
            app.pollEvents();
        }

        // Periodic FPS / position stability report.
        ++reportFrames;
        reportElapsed += dt;
        if (reportElapsed >= REPORT_INTERVAL) {
            // Compute avg Y and count below-floor to diagnose explosion.
            float sumY = 0.0f;
            uint  belowFloor = 0;
            uint  aboveLayer = 0; // > 2m (in the air)
            foreach (id; cubeIDs) {
                immutable float y = getPosition(id).y;
                sumY += y;
                if (y < 0.0f) ++belowFloor;
                if (y > 2.0f) ++aboveLayer;
            }
            immutable avgY = sumY / NUM_CUBES;
            if (avgY < minAvgY)
                minAvgY = avgY;
            if (belowFloor > maxBelowFloor)
                maxBelowFloor = belowFloor;
            writefln("[benchmark] t=%.1fs fps=%.1f dynamic=%d avgY=%.2f inAir=%d belowFloor=%d",
                elapsed,
                cast(float) reportFrames / reportElapsed,
                NUM_CUBES,
                avgY,
                aboveLayer,
                belowFloor);
            // Flush via C runtime so a SIGINT/SIGTERM doesn't lose the report.
            () @trusted {
                import core.stdc.stdio : fflush, stdout;
                fflush(stdout);
            }();
            reportElapsed = 0.0f;
            reportFrames  = 0;
        }

        // Orbit camera (radius 30m, height 20m, looking at y=5)
        immutable float camAngle = elapsed * 0.22f;
        immutable Vec3 eye = Vec3(cos(camAngle) * 30.0f, 20.0f, sin(camAngle) * 30.0f);
        camera.lookAt(eye, Vec3(0.0f, 5.0f, 0.0f));

        auto frame = app.beginFrame(Color4(0.05f, 0.08f, 0.11f, 1.0f));
        if (!frame.valid)
            continue;

        scene.begin(camera);

        // Floor (static: draw with position + scale directly)
        scene.draw(cubeMesh,
            Vec3(0.0f, -0.5f, 0.0f),
            Vec3(40.0f, 1.0f, 40.0f),
            Color4(0.25f, 0.30f, 0.22f, 1.0f));

        // Dynamic cubes — follow physics world transform
        foreach (id; cubeIDs) {
            immutable transform = readBodyTransform(id);
            scene.drawMatrix(cubeMesh, toRenderMat4(transform), Color4(0.7f, 0.6f, 0.4f, 1.0f));
        }

        scene.end(frame);

        text.beginFrame();
        text.drawText(frame, format("Benchmark t=%.1fs / %.1fs", elapsed, BENCHMARK_SECONDS), 16, 16, 2);
        text.drawText(frame, fps.text(), 16, 40, 2);
        text.drawText(frame, format("Static=1  Dynamic=%d  Active=%d",
            NUM_CUBES, NUM_CUBES), 16, 64, 2);
        text.drawText(frame, format("Min avg Y=%.2f  Peak below floor=%d",
            minAvgY, maxBelowFloor), 16, 88, 2);

        immutable gs = GC.profileStats;
        text.drawText(frame, format("GC: %d col | total: %.1f ms | max: %.1f ms",
            gs.numCollections, toMs(gs.totalPauseTime), toMs(gs.maxPauseTime)), 16, 112, 2);

        app.endFrame(frame);
    }

    immutable float avgFps = elapsed > 0.0f ? cast(float) frames / elapsed : 0.0f;
    immutable gs = GC.profileStats;
    writefln("[benchmark] done frames=%d elapsed=%.2fs avg_fps=%.1f min_avg_y=%.2f peak_below_floor=%d",
        frames, elapsed, avgFps, minAvgY, maxBelowFloor);
    writefln("[benchmark] gc collections=%d total_pause=%.1fms max_pause=%.1fms",
        gs.numCollections, toMs(gs.totalPauseTime), toMs(gs.maxPauseTime));
    return 0;
}
