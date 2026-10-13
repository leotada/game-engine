/// Editor Play Mode session, state transitions, scene snapshot restore, and simulation loop.
module editor.play_mode;

import engine.ecs.scene_world : SceneWorld;
import engine.physics.world : PhysicsWorld;
import engine.core.strings : StringTable;
import engine.editor.light_panel : SceneLightSettings;
import engine.editor.physics_sim : PhysicsSimSession;
import engine.editor.scene_load : worldToSceneFile, loadSceneIntoWorld;
import engine.scene.scene_file : SceneFile;
import engine.script.context : ScriptContext;
import engine.reflect.attrs : Stage;
import engine.reflect.descriptor : LifecycleMask;
import engine.hotreload.reload : HotReloadManager;
import engine.platform.input : InputState;
import engine.core.log : info, warn;

@safe:

enum PlayState : ubyte {
    editing = 0,
    playing = 1,
    paused  = 2,
}

struct PlayMode {
    PlayState state = PlayState.editing;
    SceneFile snapshot;
    SceneLightSettings lightSnapshot;
    PhysicsSimSession physicsSim;
    ScriptContext scriptCtx;
    double playTime = 0.0;
    bool hasSnapshot = false;

    bool isPlaying() const nothrow @nogc { return state == PlayState.playing; }
    bool isPaused() const nothrow @nogc { return state == PlayState.paused; }
    bool isEditing() const nothrow @nogc { return state == PlayState.editing; }

    void start(
        ref SceneWorld world,
        ref PhysicsWorld physics,
        ref StringTable strings,
        ref SceneLightSettings lightSettings,
        ref HotReloadManager hotReload
    ) @trusted {
        if (state != PlayState.editing) return;

        info("PlayMode: starting simulation...");
        try {
            snapshot = worldToSceneFile(world, lightSettings);
            lightSnapshot = lightSettings;
            hasSnapshot = true;
        } catch (Exception e) {
            warn("PlayMode: failed to capture scene snapshot: %s", e.msg);
            hasSnapshot = false;
        }

        playTime = 0.0;
        state = PlayState.playing;

        // Start physics
        physicsSim.beginSimulate(world, physics, null);

        // Dispatch onStart to script components
        scriptCtx.world = &world;
        scriptCtx.dt = 0.0f;
        scriptCtx.totalTime = 0.0;
        hotReload.tickLifecycle(world, LifecycleMask.onStart, scriptCtx);
    }

    void pause() nothrow @nogc {
        if (state == PlayState.playing) {
            state = PlayState.paused;
            info("PlayMode: paused");
        }
    }

    void resume() nothrow @nogc {
        if (state == PlayState.paused) {
            state = PlayState.playing;
            info("PlayMode: resumed");
        }
    }

    void toggle(
        ref SceneWorld world,
        ref PhysicsWorld physics,
        ref StringTable strings,
        ref SceneLightSettings lightSettings,
        ref HotReloadManager hotReload
    ) {
        if (state == PlayState.editing) {
            start(world, physics, strings, lightSettings, hotReload);
        } else {
            stop(world, physics, strings, lightSettings, hotReload);
        }
    }

    void step(
        ref SceneWorld world,
        ref PhysicsWorld physics,
        in InputState input,
        float dt,
        ref HotReloadManager hotReload
    ) {
        if (state != PlayState.paused) return;
        tickFrame(world, physics, input, dt, hotReload);
    }

    void stop(
        ref SceneWorld world,
        ref PhysicsWorld physics,
        ref StringTable strings,
        ref SceneLightSettings lightSettings,
        ref HotReloadManager hotReload
    ) @trusted {
        if (state == PlayState.editing) return;

        info("PlayMode: stopping simulation and restoring snapshot...");

        // Dispatch onDestroy to script components
        scriptCtx.world = &world;
        hotReload.tickLifecycle(world, LifecycleMask.onDestroy, scriptCtx);

        // Stop physics simulation without saving transforms
        physicsSim.stopSimulate(world);

        // Restore entire scene snapshot
        if (hasSnapshot) {
            world.clearEntities();
            try {
                loadSceneIntoWorld(world, snapshot, lightSettings);
                lightSettings = lightSnapshot;
            } catch (Exception e) {
                warn("PlayMode: failed to restore scene snapshot: %s", e.msg);
            }
            hasSnapshot = false;
        }

        state = PlayState.editing;
        playTime = 0.0;
        info("PlayMode: returned to edit mode");
    }

    void update(
        ref SceneWorld world,
        ref PhysicsWorld physics,
        in InputState input,
        float dt,
        ref HotReloadManager hotReload
    ) {
        if (state != PlayState.playing) return;
        tickFrame(world, physics, input, dt, hotReload);
    }

    private void tickFrame(
        ref SceneWorld world,
        ref PhysicsWorld physics,
        in InputState input,
        float dt,
        ref HotReloadManager hotReload
    ) @trusted {
        playTime += dt;
        scriptCtx.world = &world;
        scriptCtx.input = &input;
        scriptCtx.dt = dt;
        scriptCtx.totalTime = playTime;

        // PreUpdate
        hotReload.tickSystems(world, Stage.preUpdate, dt);

        // Physics step & FixedUpdate
        physicsSim.tick(world, physics, dt);
        hotReload.tickSystems(world, Stage.fixedUpdate, dt);
        hotReload.tickLifecycle(world, LifecycleMask.onFixedUpdate, scriptCtx);

        // Update
        hotReload.tickSystems(world, Stage.update, dt);
        hotReload.tickLifecycle(world, LifecycleMask.onUpdate, scriptCtx);

        // LateUpdate
        hotReload.tickSystems(world, Stage.lateUpdate, dt);
        hotReload.tickLifecycle(world, LifecycleMask.onLateUpdate, scriptCtx);
    }
}
