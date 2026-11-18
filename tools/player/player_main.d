/// Standalone game player entrypoint without editor overhead.
module tools.player.player_main;

import core.memory : GC;
import std.file : exists;
import std.stdio : writeln, writefln;

import engine.app : App;
import engine.ecs.scene_world : SceneWorld;
import engine.ecs.store : EntityId;
import engine.physics.world : PhysicsWorld;
import engine.editor.components : Camera3D, MaterialOverride, Visual, VisualKind, worldMatrix;
import engine.editor.demo_level : findCurrentCamera, sceneCameraToGpu;
import engine.editor.light_panel : SceneLightSettings;
import engine.editor.physics_sim : PhysicsSimSession;
import engine.editor.scene_load : loadSceneIntoWorld;
import engine.editor.selection : noSelection;
import engine.graphics.mesh : Mesh;
import engine.graphics.types : Color4;
import engine.math.vec : Vec3;
import engine.platform.input : Key;
import engine.scene.camera : Camera;
import engine.scene.graph : Transform;
import engine.scene.scene_file : SceneFile, loadSceneFile;
import engine.scene.scene3d : Scene3D;
import engine.core.log : info, warn, err;

version (Symgc_cards) {
    /// Default runtime options when built with Symgc configurations: activate steadygc concurrent collector.
    extern (C) __gshared string[] rt_options = ["gcopt=gc:sdcq"];
}

@safe:

private void drawWorldMeshes(ref SceneWorld world, ref Scene3D scene,
                             ref Mesh cubeMesh, ref Mesh sphereMesh, ref Mesh planeMesh) {
    foreach (EntityId e; world.query!(Transform, Visual)()) {
        if (!world.alive(e))
            continue;
        immutable v = world.get!Visual(e);
        if (v.kind == VisualKind.none)
            continue;

        Color4 col = Color4(0.75f, 0.75f, 0.80f, 1.0f);
        if (world.has!MaterialOverride(e)) {
            immutable m = world.get!MaterialOverride(e);
            col = Color4(m.baseColor[0], m.baseColor[1], m.baseColor[2], m.geometryOpacity);
        }

        immutable model = worldMatrix(world, e);
        if (v.kind == VisualKind.sphere)
            scene.drawMatrix(sphereMesh, model, col);
        else if (v.kind == VisualKind.plane)
            scene.drawMatrix(planeMesh, model, col);
        else
            scene.drawMatrix(cubeMesh, model, col);
    }
}

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
    world.ensureRegistered!Camera3D();
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

        sim.stopSimulate(world);
        info("Player: headless test completed successfully!");
        return;
    }

    App app = App.create("Game Player", 1280, 720);
    Scene3D scene = Scene3D.create(app.gpu);
    Mesh cubeMesh = Mesh.cube(app.gpu);
    Mesh sphereMesh = Mesh.sphere(app.gpu);
    Mesh planeMesh = Mesh.plane(app.gpu);

    scope (exit) {
        planeMesh.destroy();
        sphereMesh.destroy();
        cubeMesh.destroy();
        scene.destroy();
        sim.stopSimulate(world);
    }

    app.run((float dt) {
        app.pollEvents();
        app.handleResize();
        if (app.input.keyPressed(Key.escape)) {
            app.close();
            return;
        }

        sim.tick(world, physics, 1.0f / 60.0f);

        auto frame = app.beginFrame(Color4(0.08f, 0.09f, 0.12f, 1.0f));
        if (!frame.valid) {
            return;
        }

        immutable uint winW = app.window.width > 0 ? app.window.width : 1280;
        immutable uint winH = app.window.height > 0 ? app.window.height : 720;
        frame.setViewport(0.0f, 0.0f, cast(float) winW, cast(float) winH, winW, winH);

        immutable EntityId camEntity = findCurrentCamera(world);
        Camera viewCam;
        if (camEntity != noSelection) {
            viewCam = sceneCameraToGpu(world, camEntity, cast(float) winW, cast(float) winH);
        } else {
            immutable float aspect = cast(float) winW / cast(float) winH;
            viewCam = Camera.create(0.9f, aspect, 0.1f, 1000.0f);
            viewCam.lookAt(Vec3(0.0f, 4.0f, 9.0f), Vec3(0.0f, 0.5f, 0.0f));
        }

        scene.begin(viewCam);
        drawWorldMeshes(world, scene, cubeMesh, sphereMesh, planeMesh);
        scene.end(frame);

        app.pumpEvents();
        app.resolvePost(frame);
        if (!frame.valid) {
            if (frame.acquireNeedsRecover()) {
                app.recoverSurface();
            }
            return;
        }

        app.endFrame(frame);
    });

    info("Player: exited cleanly.");
}
