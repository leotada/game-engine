/// Standalone game player entrypoint without editor overhead.
module tools.player.player_main;

import core.memory : GC;
import std.file : exists;
import std.stdio : writeln, writefln;

import engine.app : App;
import engine.ecs.scene_world : SceneWorld;
import engine.physics.world : PhysicsWorld;
import engine.editor.physics_sim : PhysicsSimSession;
import engine.editor.light_panel : SceneLightSettings;
import engine.editor.scene_load : loadSceneIntoWorld;
import engine.scene.scene_file : SceneFile, loadSceneFile;
import engine.platform.input : Key, InputState;
import engine.graphics.types : Color4;
import engine.core.log : info, warn, err;

/// Default runtime options: activate steadygc concurrent collector when linked
extern (C) __gshared string[] rt_options = ["gcopt=gc:sdcq"];

@safe:

void main(string[] args) {
    string scenePath = "assets/scenes/arena_01.scene.json";
    bool headless = false;
    uint headlessFrames = 0;
    bool assertNoGc = false;

    foreach (arg; args[1 .. $]) {
        if (arg.length > 8 && arg[0 .. 8] == "--scene=") {
            scenePath = arg[8 .. $];
        } else if (arg.length > 18 && arg[0 .. 18] == "--headless-frames=") {
            import std.conv : to;
            headless = true;
            headlessFrames = arg[18 .. $].to!uint();
        } else if (arg == "--assert-no-gc") {
            assertNoGc = true;
        }
    }

    info("Player: launching scene %s (headless=%s)", scenePath, headless ? "true" : "false");

    SceneWorld world = SceneWorld.init;
    SceneLightSettings lightSettings;

    if (exists(scenePath)) {
        try {
            auto sf = loadSceneFile(scenePath);
            loadSceneIntoWorld(world, sf, lightSettings);
            info("Player: loaded scene %s (%d entities)", scenePath, cast(int) world.entityCount());
        } catch (Exception e) {
            err("Player: failed to load scene %s: %s", scenePath, e.msg);
        }
    }

    auto physics = PhysicsWorld.createDefault();
    PhysicsSimSession sim;
    sim.beginSimulate(world, physics, null);

    if (headless) {
        info("Player: running %u headless frames...", headlessFrames);
        size_t gcBefore = 0;
        if (assertNoGc) {
            GC.collect();
            gcBefore = GC.stats().allocatedInCurrentThread;
        }

        foreach (f; 0 .. headlessFrames) {
            sim.tick(world, physics, 1.0f / 60.0f);
        }

        if (assertNoGc) {
            size_t gcAfter = GC.stats().allocatedInCurrentThread;
            size_t delta = gcAfter - gcBefore;
            writefln("GC allocations over %u frames in Standalone Player: %u bytes", headlessFrames, delta);
            assert(delta == 0, "GC allocations detected in standalone player frame loop!");
        }

        info("Player: headless test completed successfully!");
        return;
    }

    App app = App.create("Game Player", 1280, 720);
    while (app.running) {
        app.pollEvents();
        if (app.input.keyPressed(Key.escape)) {
            break;
        }

        sim.tick(world, physics, 1.0f / 60.0f);

        auto frame = app.beginFrame(Color4(0.1f, 0.1f, 0.12f, 1.0f));
        if (frame.valid) {
            app.endFrame(frame);
        }
    }

    sim.stopSimulate(world);
    info("Player: exited cleanly.");
}
