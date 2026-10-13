/// Hot-reload coordinator: watching, compiling, snapshotting, schema migration, and lifecycle ticking.
module engine.hotreload.reload;

import std.json;
import engine.hotreload.watcher : FileWatcher;
import engine.hotreload.build_runner : BuildRunner, BuildResult, Diagnostic;
import engine.hotreload.loader : ScriptModule;
import engine.script.context : ScriptContext;
import engine.reflect.attrs : Stage;
import engine.reflect.descriptor : ComponentTypeId, TypeRegistry, LifecycleMask, invalidComponentTypeId;
import engine.reflect.serialize : serializeComponent, deserializeComponent;
import engine.core.strings : StringId, StringTable;
import engine.ecs.store : EntityId;
import engine.ecs.scene_world : SceneWorld;
import engine.core.log : info, warn, err;

@safe:

struct EntityScriptSnapshot {
    EntityId entity;
    StringId typeName;
    JSONValue json;
}

struct HotReloadManager {
    FileWatcher watcher;
    BuildRunner runner;
    ScriptModule currentModule;
    size_t instanceCounter = 0;
    string soSourcePath = ".engine/bin/libgame.so";
    bool enabled = true;
    bool buildInFlight = false;
    Diagnostic[] lastDiagnostics;

    bool init(string[] watchDirs, string soPath = ".engine/bin/libgame.so", string dubCommand = "dub build --config=game-module --compiler=dmd") @trusted {
        soSourcePath = soPath;
        runner.command = dubCommand;
        return watcher.init(watchDirs, 0.3f);
    }

    void shutdown(ref SceneWorld world) scope @trusted {
        if (buildInFlight) {
            runner.cancel();
            buildInFlight = false;
        }
        watcher.shutdown();
        if (currentModule.isLoaded()) {
            currentModule.unload(world);
        }
    }

    /// Polls watcher, recompiles on changes, snapshots and migrates component state.
    /// Returns true if a reload was performed.
    bool pollAndReload(
        ref SceneWorld world,
        ref TypeRegistry types,
        ref StringTable strings,
        float dt,
        out Diagnostic[] outDiags
    ) scope @trusted {
        if (!enabled) return false;

        BuildResult res;
        if (buildInFlight) {
            if (!runner.poll(res)) return false;
            buildInFlight = false;
            lastDiagnostics = res.diagnostics;
            outDiags = res.diagnostics;
        } else {
            if (!watcher.poll(dt)) return false;
            info("HotReload: detected script modifications, rebuilding...");
            if (!runner.start()) {
                err("HotReload: failed to start background build");
                return false;
            }
            buildInFlight = true;
            return false;
        }

        if (!res.success) {
            err("HotReload: build failed with exit code %d:\n%s", res.exitCode, res.rawOutput);
            return false;
        }

        info("HotReload: compilation successful, snapshotting script components...");
        auto snapshots = snapshotScriptData(world, types, strings);

        // Unload existing module and unregister old types
        if (currentModule.isLoaded()) {
            currentModule.unload(world);
        }

        // Load new instance
        instanceCounter++;
        if (!currentModule.load(soSourcePath, types, strings, instanceCounter)) {
            err("HotReload: failed to load updated module!");
            return false;
        }

        info("HotReload: restoring script state (%d entity components)...", cast(int) snapshots.length);
        restoreScriptData(world, types, strings, snapshots);

        info("HotReload: completed successfully (instance #%d)", cast(int) instanceCounter);
        return true;
    }

    private EntityScriptSnapshot[] snapshotScriptData(
        ref SceneWorld world,
        ref const TypeRegistry types,
        ref const StringTable strings
    ) scope @trusted {
        EntityScriptSnapshot[] snapshots;
        if (!currentModule.isLoaded() && currentModule.registrar.components.length == 0) return snapshots;

        foreach (ref comp; currentModule.registrar.components) {
            foreach (id; 0 .. world.entityCount() + 1000) {
                auto entityId = cast(EntityId) id;
                if (!world.alive(entityId)) continue;
                if (!world.rawHas(comp.typeId, entityId)) continue;

                auto bytes = world.rawGet(comp.typeId, entityId);
                if (bytes.length == 0) continue;

                auto json = serializeComponent(types, comp.typeId, bytes, strings);
                snapshots ~= EntityScriptSnapshot(entityId, comp.qualifiedName, json);
            }
        }
        return snapshots;
    }

    private void restoreScriptData(
        ref SceneWorld world,
        ref const TypeRegistry types,
        ref StringTable strings,
        const(EntityScriptSnapshot)[] snapshots
    ) scope @trusted {
        foreach (ref const snap; snapshots) {
            if (!world.alive(snap.entity)) continue;
            auto tid = types.find(strings.get(snap.typeName), strings);
            if (tid == invalidComponentTypeId) continue;

            auto desc = types.getType(tid);
            ubyte[] buf = new ubyte[desc.size];
            deserializeComponent(types, tid, snap.json, buf, strings);
            world.rawAdd(tid, snap.entity, buf);
        }
    }

    /// Invokes systems registered in the module matching the specified stage.
    void tickSystems(ref SceneWorld world, Stage stage, float dt) scope @trusted {
        if (!currentModule.isLoaded() && currentModule.registrar.systems.length == 0) return;

        foreach (ref sys; currentModule.registrar.systems) {
            if (sys.stage == stage && sys.callback !is null) {
                try {
                    sys.callback(world, dt);
                } catch (Exception e) {
                    err("HotReload: exception in system: %s", e.msg);
                }
            }
        }
    }

    /// Invokes component lifecycle thunks (e.g. onStart, onUpdate, onDestroy).
    void tickLifecycle(
        ref SceneWorld world,
        uint lifecycleFlag,
        scope ref ScriptContext ctx
    ) scope @trusted {
        if (!currentModule.isLoaded() && currentModule.registrar.components.length == 0) return;

        foreach (ref comp; currentModule.registrar.components) {
            if ((comp.lifecycleMask & lifecycleFlag) == 0) continue;

            // Pick callback
            auto cb = (lifecycleFlag == LifecycleMask.onStart) ? comp.onStart :
                      (lifecycleFlag == LifecycleMask.onUpdate) ? comp.onUpdate :
                      (lifecycleFlag == LifecycleMask.onFixedUpdate) ? comp.onFixedUpdate :
                      (lifecycleFlag == LifecycleMask.onDestroy) ? comp.onDestroy :
                      (lifecycleFlag == LifecycleMask.onValidate) ? comp.onValidate : null;

            if (cb is null) continue;

            auto store = world.getStore(comp.typeId);
            if (store is null || store.count == 0) continue;
            immutable itemSize = store.itemSize;
            foreach (i; 0 .. store.count) {
                auto entityId = store.denseToEntity[i];
                if (!world.alive(entityId)) continue;

                auto ptr = store.denseData.ptr + i * itemSize;
                ctx.entity = entityId;
                ctx.world = &world;
                cb(ptr, ctx);
            }
        }
    }
}

unittest {
    import engine.reflect.attrs : component, export_;
    import engine.script.context : ScriptContext;
    import engine.script.module_entry : ModuleRegistrar;

    @component static struct TestRotator {
        @export_ float speed = 90.0f;
        int updateCount = 0;

        void onStart(ref ScriptContext ctx) {
            speed = 180.0f;
        }

        void onUpdate(ref ScriptContext ctx, float dt) {
            updateCount++;
        }
    }

    SceneWorld world;
    ModuleRegistrar reg;
    reg.types = &world.types;
    reg.strings = &world.strings;
    reg.registerComponent!TestRotator();

    assert(reg.components.length == 1);
    assert(world.strings.get(reg.components[0].qualifiedName) == "TestRotator");
    assert((reg.components[0].lifecycleMask & LifecycleMask.onStart) != 0);
    assert((reg.components[0].lifecycleMask & LifecycleMask.onUpdate) != 0);

    auto e = world.spawn();
    world.set(e, TestRotator(45.0f, 0));

    HotReloadManager mgr;
    mgr.currentModule.registrar = reg;

    ScriptContext ctx;
    ctx.world = &world;
    ctx.dt = 1.0f / 60.0f;

    // Test onStart
    mgr.tickLifecycle(world, LifecycleMask.onStart, ctx);
    assert(world.get!TestRotator(e).speed == 180.0f);

    // Test onUpdate
    mgr.tickLifecycle(world, LifecycleMask.onUpdate, ctx);
    assert(world.get!TestRotator(e).updateCount == 1);

    // Test snapshot and restore
    auto snaps = mgr.snapshotScriptData(world, world.types, world.strings);
    assert(snaps.length == 1);
    assert(snaps[0].entity == e);

    // Reset component
    world.get!TestRotator(e).speed = 0.0f;
    mgr.restoreScriptData(world, world.types, world.strings, snaps);
    assert(world.get!TestRotator(e).speed == 180.0f);
}
