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
import engine.editor.scene_load : loadSceneIntoWorld;
import engine.editor.selection : noSelection;
import engine.graphics.types : Color4;
import engine.math.vec : Vec3;
import engine.platform.input : Key;
import engine.scene.camera : Camera;
import engine.scene.scene_file : SceneFile, loadSceneFile;
import engine.scene.streamer : WorldStreamer;
import engine.editor.scene_renderer : SceneRenderer;
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
        }
    }

    info("Player: launching scene %s (headless=%s)", scenePath, headless ? "true" : "false");

    SceneWorld world = SceneWorld.init;
    world.ensureRegistered!Camera3D();
    SceneLightSettings lightSettings;
    WorldStreamer streamer;
    bool streamingEnabled = false;

    if (exists(scenePath)) {
        try {
            auto sf = loadSceneFile(scenePath);
            loadSceneIntoWorld(world, sf, lightSettings);
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
    PhysicsSimSession sim;
    sim.beginSimulate(world, physics, makeAssetResolver(world));

    if (headless && !renderHeadless) {
        scope (exit) {
            if (streamingEnabled)
                streamer.stopWorker();
        }
        info("Player: running %u headless frames...", headlessFrames);
        size_t gcBefore = 0;
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
            size_t gcAfter = GC.stats().allocatedInCurrentThread;
            size_t delta = gcAfter - gcBefore;
            writefln("GC allocations over %u frames in Standalone Player: %u bytes", headlessFrames, delta);
            assert(delta == 0, "GC allocations detected in standalone player frame loop!");
        }

        sim.stopSimulate(world);
        info("Player: headless test completed successfully!");
        return;
    }

    App app = App.create("Game Player", 1280, 720);
    SceneRenderer renderer = SceneRenderer.create(app.gpu);
    renderer.syncAssets(app.gpu, world); // import every model before the first frame

    scope (exit) {
        if (streamingEnabled)
            streamer.stopWorker();
        renderer.destroy();
        sim.stopSimulate(world);
    }

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

        sim.tick(world, physics, 1.0f / 60.0f);

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
        size_t gcBefore = 0;
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
