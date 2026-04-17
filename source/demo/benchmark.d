// Forest Stress Test — flyover of a dense procedural forest with async chunk
// streaming and continuous rigid-body rain. Measures frametime stats via
// FrameTimer (1% low, stddev) and GC pause times via core.memory.GC.profileStats.
module demo.benchmark;

import core.memory : GC;
import core.time : Duration, MonoTime;
import std.parallelism : taskPool, task, Task;
import std.random : Mt19937, uniform;
import std.stdio : writeln, writef, writefln, stdout;
import std.math : sin, cos, sqrt;

import engine;
import bindings.wgpu;

// Duration → milliseconds as double (Duration.total!"msecs" truncates to long).
private double toMs(Duration d) pure nothrow @safe { return d.total!"hnsecs" / 10_000.0; }

private enum SCREEN_W = 1280;
private enum SCREEN_H = 720;

// Forest layout
private enum CHUNK_SIZE      = 16.0f;    // metres per chunk edge
private enum TREES_PER_CHUNK = 25;
private enum STREAM_RADIUS   = 4;        // chunks visible around camera
private enum RENDER_RADIUS   = 3;        // chunks actually rendered (smaller → perf)

// Physics
// Caps below are sized so every tree the camera flies past during the 30 s
// benchmark has a matching static collider — otherwise rain cubes visibly
// tunnel through uncollidered trees. See cap-derivation note on each cap.
private enum PHYS_MAX_BODIES = 4096;     // total pool size
private enum RAIN_MAX_BODIES = 150;      // cap on dynamic cubes
// Trunk/crown caps must cover every tree the camera will fly past, otherwise
// rain cubes tunnel through trees with no colliders. Flyover of 30 s × 30 m/s
// ÷ 16 m/chunk ≈ 56 chunks × 25 trees = 1400 trunks + 1400 crowns, comfortably
// under PHYS_MAX_BODIES after ground + rain (3151 < 4096).
private enum TRUNK_BODY_CAP  = 1500;     // cap on static trunk colliders
private enum CROWN_BODY_CAP  = 1500;     // cap on static crown colliders
private enum RAIN_SPAWN_RATE = 2;        // cubes per frame while under cap
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
    phys.init_();
    phys.gravity = Vec3(0, -20.0f, 0);
    // Static ground at y = -0.5, spanning the whole flyover path.
    phys.addStatic(Vec3(0, -0.5f, 0), Shape.makeBox(Vec3(GROUND_HALF, 0.5f, GROUND_HALF)));

    uint rainCount   = 0;  // number of dynamic rain cubes
    uint trunkCount  = 0;  // number of static trunk colliders
    uint crownCount  = 0;  // number of static crown colliders

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

    // Fixed-timestep accumulator. The render loop runs as fast as the GPU
    // allows (mailbox present mode → uncapped, often 200+ FPS with dt ≈ 3 ms),
    // but physics must advance in deterministic 1/60 s steps. Without this,
    // rain cubes fall imperceptibly slowly on a fast machine — the user
    // sees them "parked in the air" while the CPU spins at 100%.
    // Cap substeps at 5 so a hitch can't cause catch-up explosions.
    enum float PHYS_STEP = 1.0f / 60.0f;
    enum uint  MAX_SUBSTEPS = 5;
    float physAccum = 0.0f;

    // -- Per-second profile accumulators (diagnostic) -----------------------
    double profAccum   = 0.0;
    double physMsAcc   = 0.0;
    double beginMsAcc  = 0.0;
    double sceneMsAcc  = 0.0;
    double endMsAcc    = 0.0;
    uint   profFrames  = 0;

    // -----------------------------------------------------------------------
    // Main loop
    // -----------------------------------------------------------------------
    auto tLoopStart = MonoTime.currTime;
    while (app.running()) {
        app.pollEvents();
        if (app.input.keyPressed(Key.escape)) app.close();

        timer.tick();
        immutable dt = cast(float) timer.dtSeconds();
        immutable frameDt = dt > 0.1f ? 0.1f : dt; // clamp huge first frame
        immutable wallMs = toMs(MonoTime.currTime - tLoopStart);
        writefln("[f] t=%.1fms frame=%d dt=%.3f bodies=%d rain=%d",
                 wallMs, framesRun, frameDt, phys.bodyCount, rainCount);
        stdout.flush();

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

        // -------- Register static trunk/crown colliders for fresh chunks --
        foreach (k, ref chunk; forest.loaded) {
            if (chunk.collidersAdded) continue;
            foreach (i; 0 .. chunk.trunkPos.length) {
                if (trunkCount < TRUNK_BODY_CAP && phys.bodyCount < PHYS_MAX_BODIES) {
                    immutable halfExt = Vec3(chunk.trunkScale[i].x * 0.5f,
                                             chunk.trunkScale[i].y * 0.5f,
                                             chunk.trunkScale[i].z * 0.5f);
                    phys.addStatic(chunk.trunkPos[i], Shape.makeBox(halfExt));
                    ++trunkCount;
                }
                if (crownCount < CROWN_BODY_CAP && phys.bodyCount < PHYS_MAX_BODIES) {
                    // Approximate the bushy crown as a fat box — rain cubes
                    // bounce off the canopy rather than slipping past the
                    // thin trunk below.
                    immutable crownHalf = Vec3(chunk.crownScale[i].x * 0.5f,
                                               chunk.crownScale[i].y * 0.5f,
                                               chunk.crownScale[i].z * 0.5f);
                    phys.addStatic(chunk.crownPos[i], Shape.makeBox(crownHalf));
                    ++crownCount;
                }
            }
            chunk.collidersAdded = true;
        }

        // Keep the broadphase grid window centered on the camera so bodies
        // are never clamped out of range (which would silently drop pairs).
        phys.recenterGrid(Vec3(camX, 16.0f, camZ + 40.0f));

        // -------- Rain: spawn new rigid-body cubes above the tree canopy --
        foreach (_; 0 .. RAIN_SPAWN_RATE) {
            if (rainCount >= RAIN_MAX_BODIES) break;
            if (phys.bodyCount >= PHYS_MAX_BODIES) break;
            immutable rx = camX + uniform(-35.0f, 35.0f, rng);
            immutable rz = camZ + uniform(-5.0f, 60.0f, rng);
            immutable ry = 25.0f + uniform(0.0f, 15.0f, rng);
            immutable id = phys.addDynamic(Vec3(rx, ry, rz),
                            Shape.makeBox(Vec3(0.5f, 0.5f, 0.5f)), 1.0f);
            if (id != INVALID_BODY) ++rainCount;
        }

        // -------- Physics tick --------------------------------------------
        // Fixed-step accumulator: spend real time into buckets of PHYS_STEP
        // and run one world.step per bucket (up to MAX_SUBSTEPS per frame).
        physAccum += frameDt;
        if (physAccum > PHYS_STEP * MAX_SUBSTEPS)
            physAccum = PHYS_STEP * MAX_SUBSTEPS;  // drop extra, never catch-up explode
        uint physSteps = 0;
        auto tP0 = MonoTime.currTime;
        while (physAccum >= PHYS_STEP && physSteps < MAX_SUBSTEPS) {
            phys.step(PHYS_STEP);
            physAccum -= PHYS_STEP;
            ++physSteps;
        }
        auto tP1 = MonoTime.currTime;

        // -------- Render ---------------------------------------------------
        auto tB0 = MonoTime.currTime;
        auto frame = app.beginFrame(Color(0.45f, 0.65f, 0.90f, 1.0f));
        auto tB1 = MonoTime.currTime;
        if (frame.valid) {
            auto tS0 = MonoTime.currTime;
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
                if (phys.invMass[i] == 0.0f) continue; // static (ground/trunks/crowns)
                immutable p = phys.position[i];
                // Only render bodies roughly within the visible cone.
                if (p.z < camZ - 30 || p.z > camZ + 120) continue;
                scene.draw(cubeMesh, p, Vec3(1.0f, 1.0f, 1.0f), cubeColor);
            }

            scene.end(frame);
            auto tS1 = MonoTime.currTime;

            // -------- Overlay stats ---------------------------------------
            overlay.beginFrame(frameDt);
            labelRefreshAccum += frameDt;
            if (labelRefreshAccum > 0.25f) labelRefreshAccum = 0;

            overlay.section("live");
            overlay.label("rigid_bodies_awake", phys.stats.activeBodies);

            overlay.section("frame");
            overlay.label("fps", cast(uint)(1000.0 / (timer.avgMs() > 0 ? timer.avgMs() : 16.0)));
            overlay.label("frame_avg_ms", timer.avgMs());
            overlay.label("frame_stddev_ms", timer.stdDevMs());
            overlay.label("one_percent_low_ms", timer.onePercentLowMs());

            overlay.section("gc");
            immutable gs = GC.profileStats;
            immutable totalPauseMs = toMs(gs.totalPauseTime);
            immutable maxPauseMs   = toMs(gs.maxPauseTime);
            overlay.label("gc_total_pause_ms", totalPauseMs);
            overlay.label("gc_max_pause_ms", maxPauseMs);
            overlay.label("gc_collections", gs.numCollections);

            overlay.section("world");
            overlay.label("chunks_loaded",  forest.loadedCount());
            overlay.label("chunks_pending", forest.pendingCount());
            overlay.label("trunk_colliders", trunkCount);
            overlay.label("crown_colliders", crownCount);

            overlay.section("physics");
            overlay.label("bodies_total",    phys.bodyCount);
            overlay.label("bodies_active",   phys.stats.activeBodies);
            overlay.label("bodies_sleeping", phys.stats.sleepingBodies);
            overlay.label("manifolds",       phys.stats.manifoldCount);
            overlay.label("broadphase_pairs", phys.stats.broadphasePairs);
            overlay.label("rain_cubes",       rainCount);

            text.beginFrame();
            overlay.render(text, frame, 8, 8, 2, 22);

            auto tE0 = MonoTime.currTime;
            app.endFrame(frame);
            auto tE1 = MonoTime.currTime;

            physMsAcc  += toMs(tP1 - tP0);
            beginMsAcc += toMs(tB1 - tB0);
            sceneMsAcc += toMs(tS1 - tS0);
            endMsAcc   += toMs(tE1 - tE0);
            profFrames++;
            profAccum  += frameDt;
            if (profAccum >= 1.0) {
                writefln("[prof] frames=%d phys=%.1fms begin=%.1fms scene=%.1fms end=%.1fms bodies=%d rain=%d manifolds=%d active=%d sleeping=%d",
                         profFrames,
                         physMsAcc / profFrames,
                         beginMsAcc / profFrames,
                         sceneMsAcc / profFrames,
                         endMsAcc / profFrames,
                         phys.bodyCount,
                         rainCount,
                         phys.stats.manifoldCount,
                         phys.stats.activeBodies,
                         phys.stats.sleepingBodies);
                stdout.flush();
                profAccum = 0.0;
                physMsAcc = 0.0; beginMsAcc = 0.0; sceneMsAcc = 0.0; endMsAcc = 0.0;
                profFrames = 0;
            }
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
    writefln(" GC total pause    : %.3f ms", toMs(gs.totalPauseTime));
    writefln(" GC max pause      : %.3f ms", toMs(gs.maxPauseTime));
    writefln(" GC note: D's DRuntime GC is stop-the-world mark-sweep (not");
    writefln("          incremental). Pauses reflect worst-case blocking of");
    writefln("          the main rendering thread while background tasks");
    writefln("          produced allocation pressure.");
    writeln("-----------------------------------------------------------------");
}
