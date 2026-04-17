// Forest Stress Test — flyover of a dense procedural forest with async chunk
// streaming and continuous rigid-body rain. Measures frametime stats via
// FrameTimer (1% low, stddev) and GC pause times via core.memory.GC.profileStats.
module demo.benchmark;

import core.memory : GC;
import core.time : Duration;
import std.parallelism : taskPool, task, Task;
import std.random : Mt19937, uniform;
import std.stdio : writeln, writefln;
import std.math : sin, cos, sqrt;

import engine;
import bindings.wgpu;

private enum SCREEN_W = 1280;
private enum SCREEN_H = 720;

// Forest layout
private enum CHUNK_SIZE      = 16.0f;    // metres per chunk edge
private enum TREES_PER_CHUNK = 25;
private enum STREAM_RADIUS   = 4;        // chunks visible around camera
private enum RENDER_RADIUS   = 3;        // chunks actually rendered (smaller → perf)

// Physics
private enum PHYS_MAX_BODIES = 4096;     // total (ground + trunks + rain)
private enum RAIN_MAX_BODIES = 1024;     // cap on dynamic cubes
private enum TRUNK_BODY_CAP  = 2048;     // cap on static trunk colliders
private enum RAIN_SPAWN_RATE = 10;       // cubes per frame while under cap
private enum GROUND_HALF     = 512.0f;

// Camera
private enum CAM_SPEED       = 30.0f;    // m/s, constant forward motion
private enum CAM_HEIGHT      = 18.0f;
private enum CAM_WARMUP      = 10.0f;    // seconds to hold still so physics is visible

// Chunk coordinate key (XZ grid).
private struct ChunkKey { int x, z; }

// Data produced by a streaming task.
private struct ChunkData {
    int cx, cz;
    Vec3[] trunkPos;
    Vec3[] trunkScale;
    Vec3[] crownPos;
    Vec3[] crownScale;
    bool collidersAdded;
}

// Generate one chunk of forest. Intentionally allocates (arrays, LCG state)
// to exercise GC pressure when run across many threads.
private ChunkData generateChunk(int cx, int cz) {
    ChunkData c;
    c.cx = cx;
    c.cz = cz;
    c.trunkPos   = new Vec3[TREES_PER_CHUNK];
    c.trunkScale = new Vec3[TREES_PER_CHUNK];
    c.crownPos   = new Vec3[TREES_PER_CHUNK];
    c.crownScale = new Vec3[TREES_PER_CHUNK];

    // Deterministic seed per chunk so flyovers look consistent.
    immutable uint seed = cast(uint)(cx * 73856093 ^ cz * 19349663 ^ 0xBEEF);
    auto rng = Mt19937(seed);

    immutable ox = cx * CHUNK_SIZE;
    immutable oz = cz * CHUNK_SIZE;

    foreach (i; 0 .. TREES_PER_CHUNK) {
        immutable fx = uniform(0.0f, CHUNK_SIZE, rng);
        immutable fz = uniform(0.0f, CHUNK_SIZE, rng);
        immutable trunkH = uniform(3.0f, 7.0f, rng);
        immutable trunkR = uniform(0.25f, 0.5f, rng);
        immutable crownR = uniform(1.5f, 3.0f, rng);
        immutable px = ox + fx;
        immutable pz = oz + fz;

        c.trunkPos[i]   = Vec3(px, trunkH * 0.5f, pz);
        c.trunkScale[i] = Vec3(trunkR, trunkH, trunkR);
        c.crownPos[i]   = Vec3(px, trunkH + crownR * 0.5f, pz);
        c.crownScale[i] = Vec3(crownR, crownR, crownR);
    }
    return c;
}

// Forest world — renderable chunks + their async tasks.
private struct ForestWorld {
    ChunkData[ChunkKey] loaded;
    Task!(generateChunk, int, int)*[ChunkKey] pending;

    // Request the given chunk asynchronously if not already loaded/pending.
    void request(int cx, int cz) {
        auto k = ChunkKey(cx, cz);
        if (k in loaded) return;
        if (k in pending) return;
        auto t = task!generateChunk(cx, cz);
        taskPool.put(t);
        pending[k] = t;
    }

    // Harvest any completed chunks into `loaded`.
    void pumpReady() {
        ChunkKey[] done;
        foreach (k, t; pending) {
            if (t.done) {
                loaded[k] = t.yieldForce;
                done ~= k;
            }
        }
        foreach (k; done) pending.remove(k);
    }

    // Drop chunks outside the streaming radius around (cx, cz).
    void evictFar(int cx, int cz) {
        ChunkKey[] drop;
        foreach (k, _; loaded) {
            immutable dx = k.x - cx;
            immutable dz = k.z - cz;
            if (dx * dx + dz * dz > STREAM_RADIUS * STREAM_RADIUS * 4) drop ~= k;
        }
        foreach (k; drop) loaded.remove(k);
    }

    size_t loadedCount() const { return loaded.length; }
    size_t pendingCount() const { return pending.length; }
}

void main() {
    auto app = App.create("Forest Stress Test", SCREEN_W, SCREEN_H, WGPUPresentMode.mailbox);
    scope(exit) app.destroy();

    info("Forest Stress Test starting...");
    GC.profileStats(); // prime GC stats tracking.

    // -----------------------------------------------------------------------
    // Scene + physics + tooling
    // -----------------------------------------------------------------------
    auto scene   = Scene3D.create(app.gpu);
    scope(exit) scene.destroy();
    auto cubeMesh   = Mesh.cube(app.gpu);
    scope(exit) cubeMesh.destroy();

    auto text = TextRenderer.create(() @trusted { return app.gpu.getDevice(); }(),
                                    () @trusted { return app.gpu.getQueue(); }(),
                                    app.gpu.getFormat(), SCREEN_W, SCREEN_H);
    scope(exit) text.destroy();

    auto overlay = DebugOverlay();
    auto timer   = FrameTimer.create();

    auto phys = new PhysicsWorld!PHYS_MAX_BODIES();
    phys.gravity = Vec3(0, -20.0f, 0);
    // Static ground at y = -0.5, spanning the whole flyover path.
    phys.addStatic(Vec3(0, -0.5f, 0), Shape.makeBox(Vec3(GROUND_HALF, 0.5f, GROUND_HALF)));

    uint rainCount   = 0;  // number of dynamic rain cubes
    uint trunkCount  = 0;  // number of static trunk colliders

    // Camera.
    auto camera = Camera.create(0.9f, SCREEN_W, SCREEN_H, 0.1f, 400.0f);
    float camX = 0, camZ = 0;

    auto forest = ForestWorld();

    immutable trunkColor = Color4(0.35f, 0.22f, 0.12f, 1.0f);
    immutable crownColor = Color4(0.18f, 0.55f, 0.22f, 1.0f);
    immutable cubeColor  = Color4(0.85f, 0.85f, 0.92f, 1.0f);
    immutable groundColor= Color4(0.25f, 0.32f, 0.20f, 1.0f);

    // Rain state: per-body Y rotation just for visual variety (we use physics position).
    auto rng = Mt19937(0xC001D00D);

    size_t framesRun = 0;
    double totalDt   = 0;
    float labelRefreshAccum = 0;

    // -----------------------------------------------------------------------
    // Main loop
    // -----------------------------------------------------------------------
    while (app.running()) {
        app.pollEvents();
        if (app.input.keyPressed(Key.escape)) app.close();

        timer.tick();
        immutable dt = cast(float) timer.dtSeconds();
        immutable frameDt = dt > 0.1f ? 0.1f : dt; // clamp huge first frame

        // -------- Camera: hold still for CAM_WARMUP s, then fly forward ---
        if (totalDt >= CAM_WARMUP) camZ += CAM_SPEED * frameDt;
        immutable eye    = Vec3(camX, CAM_HEIGHT, camZ - 25.0f);
        immutable target = Vec3(camX, CAM_HEIGHT - 5, camZ + 25.0f);
        camera.lookAt(eye, target);

        // -------- Streaming: request/evict chunks based on camera ----------
        immutable int ccx = cast(int)(camX / CHUNK_SIZE);
        immutable int ccz = cast(int)(camZ / CHUNK_SIZE);
        foreach (dx; -STREAM_RADIUS .. STREAM_RADIUS + 1)
            foreach (dz; -STREAM_RADIUS .. STREAM_RADIUS + 1)
                forest.request(ccx + dx, ccz + dz);
        forest.pumpReady();
        forest.evictFar(ccx, ccz);

        // -------- Register static trunk colliders for freshly loaded chunks
        foreach (k, ref chunk; forest.loaded) {
            if (chunk.collidersAdded) continue;
            if (trunkCount >= TRUNK_BODY_CAP) break;
            foreach (i; 0 .. chunk.trunkPos.length) {
                if (trunkCount >= TRUNK_BODY_CAP) break;
                immutable halfExt = Vec3(chunk.trunkScale[i].x * 0.5f,
                                         chunk.trunkScale[i].y * 0.5f,
                                         chunk.trunkScale[i].z * 0.5f);
                phys.addStatic(chunk.trunkPos[i], Shape.makeBox(halfExt));
                ++trunkCount;
            }
            chunk.collidersAdded = true;
        }

        // -------- Rain: spawn new rigid-body cubes -------------------------
        foreach (_; 0 .. RAIN_SPAWN_RATE) {
            if (rainCount >= RAIN_MAX_BODIES) break;
            if (phys.bodyCount >= PHYS_MAX_BODIES) break;
            immutable rx = camX + uniform(-40.0f, 40.0f, rng);
            immutable rz = camZ + uniform(-10.0f, 60.0f, rng);
            immutable ry = 40.0f + uniform(0.0f, 20.0f, rng);
            immutable id = phys.addDynamic(Vec3(rx, ry, rz),
                            Shape.makeBox(Vec3(0.4f, 0.4f, 0.4f)), 1.0f);
            if (id != INVALID_BODY) ++rainCount;
        }

        // -------- Physics tick --------------------------------------------
        phys.step(frameDt);

        // -------- Render ---------------------------------------------------
        auto frame = app.beginFrame(Color(0.45f, 0.65f, 0.90f, 1.0f));
        if (frame.valid) {
            scene.begin(camera);

            // Ground plate rendered as a huge flat cube.
            scene.draw(cubeMesh, Vec3(camX, -0.5f, camZ),
                       Vec3(GROUND_HALF * 2, 1.0f, GROUND_HALF * 2),
                       groundColor);

            // Trees from loaded chunks — only render those near the camera.
            foreach (k, ref chunk; forest.loaded) {
                immutable dcx = k.x - ccx;
                immutable dcz = k.z - ccz;
                if (dcx * dcx + dcz * dcz > RENDER_RADIUS * RENDER_RADIUS) continue;
                foreach (i; 0 .. chunk.trunkPos.length) {
                    scene.draw(cubeMesh, chunk.trunkPos[i], chunk.trunkScale[i], trunkColor);
                    scene.draw(cubeMesh, chunk.crownPos[i], chunk.crownScale[i], crownColor);
                }
            }

            // Rigid-body cubes. Render only dynamic (non-static) bodies.
            foreach (i; 0 .. phys.bodyCount) {
                if (phys.invMass[i] == 0.0f) continue; // static (ground/trunks)
                immutable p = phys.position[i];
                // Only render bodies ahead of the camera (visible cone).
                if (p.z < camZ - 30 || p.z > camZ + 120) continue;
                scene.draw(cubeMesh, p, Vec3(0.8f, 0.8f, 0.8f), cubeColor);
            }

            scene.end(frame);

            // -------- Overlay stats ---------------------------------------
            overlay.beginFrame(frameDt);
            labelRefreshAccum += frameDt;
            if (labelRefreshAccum > 0.25f) labelRefreshAccum = 0;

            overlay.label("frame_avg_ms", timer.avgMs());
            overlay.label("frame_stddev_ms", timer.stdDevMs());
            overlay.label("one_percent_low_ms", timer.onePercentLowMs());

            immutable gs = GC.profileStats;
            immutable totalPauseMs = gs.totalPauseTime.total!"usecs" / 1000.0;
            immutable maxPauseUs   = gs.maxPauseTime.total!"usecs";
            overlay.label("gc_total_pause_ms", totalPauseMs);
            overlay.label("gc_max_pause_us", maxPauseUs);
            overlay.label("gc_collections", gs.numCollections);

            overlay.label("chunks_loaded",  forest.loadedCount());
            overlay.label("chunks_pending", forest.pendingCount());
            overlay.label("bodies_active",  phys.bodyCount);
            overlay.label("rain_cubes",     rainCount);
            overlay.label("trunk_colliders", trunkCount);

            overlay.render(text, frame, 8, 8, 2, 22);

            app.endFrame(frame);
        }

        ++framesRun;
        totalDt += frameDt;

        // Run for 30 seconds of simulated time then exit gracefully.
        if (totalDt > 30.0) app.close();
    }

    // -----------------------------------------------------------------------
    // Final summary
    // -----------------------------------------------------------------------
    immutable gs = GC.profileStats;
    writeln("-----------------------------------------------------------------");
    writeln(" Forest Stress Test — summary");
    writeln("-----------------------------------------------------------------");
    writefln(" Frames rendered   : %d", framesRun);
    writefln(" Simulated seconds : %.2f", totalDt);
    writefln(" Frametime avg     : %.3f ms", timer.avgMs());
    writefln(" Frametime stddev  : %.3f ms", timer.stdDevMs());
    writefln(" Frametime 1%% low : %.3f ms", timer.onePercentLowMs());
    writefln(" Average FPS       : %.1f", timer.avgFps());
    writefln(" GC collections    : %d", gs.numCollections);
    writefln(" GC total pause    : %.3f ms",
             gs.totalPauseTime.total!"usecs" / 1000.0);
    writefln(" GC max pause      : %d us", gs.maxPauseTime.total!"usecs");
    writefln(" GC note: D's DRuntime GC is stop-the-world mark-sweep (not");
    writefln("          incremental). Pauses reflect worst-case blocking of");
    writefln("          the main rendering thread while background tasks");
    writefln("          produced allocation pressure.");
    writeln("-----------------------------------------------------------------");
}
