/// Standalone game player entrypoint without editor overhead.
module tools.player.player_main;

import core.memory : GC;
import std.file : exists;
import std.stdio : writeln, writefln;

import engine.app : App;
import engine.ecs.scene_world : SceneWorld;
import engine.ecs.store : EntityId;
import engine.physics.world : PhysicsWorld;
import engine.editor.components : Camera3D;
import engine.editor.demo_level : findCurrentCamera, sceneCameraToGpu;
import engine.editor.light_panel : SceneLightSettings;
import engine.editor.physics_panel : makeAssetResolver;
import engine.editor.physics_sim : PhysicsSimSession;
import engine.editor.scene_load : loadSceneGravity, loadSceneIntoWorld;
import engine.editor.selection : noSelection;
import engine.graphics.types : Color4;
import engine.math.vec : Vec3;
import engine.platform.input : Key;
import engine.scene.camera : Camera;
import engine.scene.prefab : PrefabInstance;
import engine.scene.scene_file : SceneFile, loadSceneFile, validateScene;
import engine.scene.streamer : WorldStreamer;
import engine.editor.scene_renderer : SceneRenderer;
import engine.water.component : WaterSurface;
import engine.hotreload.asset_reload : AssetHotReloader, HotReloadTargets, batchContains;
import engine.hotreload.tunables : TunableRegistry;
import engine.core.log : info, warn, err;

version (Symgc_cards) {
    /// Default runtime options when built with Symgc configurations: activate steadygc concurrent collector.
    extern (C) __gshared string[] rt_options = ["gcopt=gc:sdcq"];
}

@safe:

void main(string[] args) {
    string scenePath = "assets/scenes/arena_01.scene.json";
    bool headless = false;
    uint headlessFrames = 0;
    bool assertNoGc = false;
    bool renderHeadless = false;
    /// `--hot-reload`: live asset / prefab / scene / `*.tune.json` reload
    /// (dev builds; ignored by `--headless-frames` runs).
    bool hotReloadEnabled = false;

    foreach (arg; args[1 .. $]) {
        if (arg.length > 8 && arg[0 .. 8] == "--scene=") {
            scenePath = arg[8 .. $];
        } else if (arg.length > 18 && arg[0 .. 18] == "--headless-frames=") {
            import std.conv : to;
            headless = true;
            headlessFrames = arg[18 .. $].to!uint();
        } else if (arg == "--assert-no-gc") {
            assertNoGc = true;
        } else if (arg == "--render") {
            renderHeadless = true;
        } else if (arg == "--hot-reload") {
            hotReloadEnabled = true;
        }
    }
    if (headless) hotReloadEnabled = false;

    info("Player: launching scene %s (headless=%s)", scenePath, headless ? "true" : "false");

    SceneWorld world = SceneWorld.init;
    world.ensureRegistered!Camera3D();
    world.ensureRegistered!WaterSurface();
    world.ensureRegistered!PrefabInstance();
    SceneLightSettings lightSettings;
    WorldStreamer streamer;
    bool streamingEnabled = false;
    float[3] gravity = [0, -9.81f, 0];

    if (exists(scenePath)) {
        try {
            auto sf = loadSceneFile(scenePath);
            loadSceneIntoWorld(world, sf, lightSettings);
            gravity = loadSceneGravity(sf);
            if (sf.hasChunkManifest && sf.chunkManifest.chunks.length > 0) {
                streamer.initFromManifest(sf.chunkManifest);
                streamer.startWorker();
                streamingEnabled = true;
            }
            info("Player: loaded scene %s (%d entities)", scenePath, cast(int) world.entityCount());
        } catch (Exception e) {
            err("Player: failed to load scene %s: %s", scenePath, e.msg);
        }
    }

    auto physics = PhysicsWorld.createDefault();
    physics.setGravity(Vec3(gravity[0], gravity[1], gravity[2]));
    PhysicsSimSession sim;
    sim.beginSimulate(world, physics, makeAssetResolver(world));

    if (headless && !renderHeadless) {
        scope (exit) {
            if (streamingEnabled)
                streamer.stopWorker();
        }
        info("Player: running %u headless frames...", headlessFrames);
        ulong gcBefore = 0;
        if (assertNoGc) {
            GC.collect();
            gcBefore = GC.stats().allocatedInCurrentThread;
        }

        foreach (f; 0 .. headlessFrames) {
            if (streamingEnabled)
                streamer.update(world, Vec3(0, 0, 0), 2.0f);
            sim.tick(world, physics, 1.0f / 60.0f);
        }

        if (assertNoGc) {
            immutable ulong gcAfter = GC.stats().allocatedInCurrentThread;
            immutable ulong delta = gcAfter - gcBefore;
            writefln("GC allocations over %u frames in Standalone Player: %u bytes", headlessFrames, delta);
            assert(delta == 0, "GC allocations detected in standalone player frame loop!");
        }

        sim.stopSimulate(world);
        info("Player: headless test completed successfully!");
        return;
    }

    App app = App.create("Game Player", 1280, 720);
    SceneRenderer renderer = SceneRenderer.create(app.gpu);
    renderer.enableWater(app.gpu, app.renderer);
    renderer.syncAssets(app.gpu, world); // import every model before the first frame

    AssetHotReloader hotReload;
    TunableRegistry tunables;
    if (hotReloadEnabled) {
        tunables.addFilesUnder("assets");
        renderer.enableDependencyTracking();
        if (!hotReload.init(["assets"]))
            hotReloadEnabled = false;
    }

    scope (exit) {
        if (streamingEnabled)
            streamer.stopWorker();
        hotReload.shutdown();
        renderer.destroy();
        sim.stopSimulate(world);
    }

    /// Apply settled asset edits; restart the simulation when the scene file changed.
    void pollHotReload(float dt) @trusted {
        HotReloadTargets t;
        t.gpu = &app.gpu;
        t.renderer = &renderer;
        t.world = &world;
        t.tunables = &tunables;
        immutable before = hotReload.batchCount;
        hotReload.poll(dt, t);
        if (hotReload.batchCount == before) return;
        if (!batchContains(hotReload.watcher.changedPaths, scenePath)) return;
        if (streamingEnabled) {
            warn("Player: root scene changed; reload of streamed worlds needs a restart");
            return;
        }
        bool stopped;
        try {
            auto sf = loadSceneFile(scenePath);
            // Checked before the running scene is touched.
            auto check = validateScene(sf);
            if (!check.ok) {
                err("Player: scene reload failed (keeping the running scene): ", check.errors[0].message);
                return;
            }
            sim.stopSimulate(world);
            stopped = true;
            loadSceneIntoWorld(world, sf, lightSettings);
            immutable g = loadSceneGravity(sf);
            physics.setGravity(Vec3(g[0], g[1], g[2]));
            sim.beginSimulate(world, physics, makeAssetResolver(world));
            renderer.syncAssets(app.gpu, world);
            info("Player: hot-reloaded scene ", scenePath);
        } catch (Exception e) {
            if (stopped)
                err("Player: scene reload failed (the world is now empty; fix the file to reload it): ", e.msg);
            else
                err("Player: scene reload failed (keeping the running scene): ", e.msg);
        }
    }

    // Physics runs at a fixed 60 Hz whatever the display rate; long stalls are dropped instead of caught up.
    enum float STEP = 1.0f / 60.0f;
    enum int MAX_STEPS = 5;
    float accumulator = 0;

    void frameFn(float dt) {
        app.pollEvents();
        app.handleResize();
        if (app.input.keyPressed(Key.escape)) {
            app.close();
            return;
        }

        immutable uint winW = app.window.width > 0 ? app.window.width : 1280;
        immutable uint winH = app.window.height > 0 ? app.window.height : 720;

        immutable EntityId camEntity = findCurrentCamera(world);
        Camera viewCam;
        if (camEntity != noSelection) {
            viewCam = sceneCameraToGpu(world, camEntity, cast(float) winW, cast(float) winH);
        } else {
            immutable float aspect = cast(float) winW / cast(float) winH;
            viewCam = Camera.create(0.9f, aspect, 0.1f, 1000.0f);
            viewCam.lookAt(Vec3(0.0f, 4.0f, 9.0f), Vec3(0.0f, 0.5f, 0.0f));
        }

        if (streamingEnabled)
            streamer.update(world, viewCam.position, 2.0f);
        if (hotReloadEnabled)
            pollHotReload(dt);

        accumulator += dt;
        int steps;
        while (accumulator >= STEP * 0.999f && steps < MAX_STEPS) {
            sim.tick(world, physics, STEP);
            accumulator -= STEP;
            steps++;
        }
        if (steps == MAX_STEPS || accumulator < 0)
            accumulator = 0;

        auto frame = app.beginFrame(Color4(0.08f, 0.09f, 0.12f, 1.0f));
        if (!frame.valid) {
            return;
        }

        frame.setViewport(0.0f, 0.0f, cast(float) winW, cast(float) winH, winW, winH);

        renderer.render(app.gpu, world, frame, viewCam, lightSettings, cast(float) winH);

        app.pumpEvents();
        app.resolvePost(frame);
        if (!frame.valid) {
            if (frame.acquireNeedsRecover()) {
                app.recoverSurface();
            }
            return;
        }

        app.endFrame(frame);
    }

    if (renderHeadless) {
        // `--headless-frames=N --render`: render N real frames (window + GPU)
        // after a short warm-up, then report GC growth and exit.
        enum WARMUP = 5;
        foreach (_; 0 .. WARMUP) frameFn(1.0f / 60.0f);
        ulong gcBefore = 0;
        if (assertNoGc) {
            GC.collect();
            gcBefore = GC.stats().allocatedInCurrentThread;
        }
        foreach (f; 0 .. headlessFrames) frameFn(1.0f / 60.0f);
        if (assertNoGc) {
            immutable delta = GC.stats().allocatedInCurrentThread - gcBefore;
            writefln("GC allocations over %u rendered frames in Standalone Player: %u bytes (%u models loaded)",
                     headlessFrames, delta, renderer.loadedAssetCount());
            assert(delta == 0, "GC allocations detected in standalone player render loop!");
        }
        info("Player: rendered headless test completed successfully!");
        return;
    }

    app.run(&frameFn);

    info("Player: exited cleanly.");
}
