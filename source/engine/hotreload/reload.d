/// Hot-reload coordinator: watching, compiling, snapshotting, schema migration, and lifecycle ticking.
module engine.hotreload.reload;

import std.json;
import engine.hotreload.watcher : FileWatcher;
import engine.hotreload.build_runner : BuildRunner, BuildResult, Diagnostic;
import engine.hotreload.loader : ScriptModule;
import engine.script.context : ScriptContext;
import engine.script.module_entry : ScriptComponentDescriptor;
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
    uint generation; /// Of `entity` when the snapshot was taken: its id may be recycled before the state is restored.
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

    private EntityScriptSnapshot[] pendingRestore; /// State saved by a reload whose new module failed to load.
    private bool playing = false;                  /// Between the onStart and onDestroy dispatches.
    private uint[][] startedGen;                   /// Per component, by entity id: generation that got onStart.
    private EntityId[] dispatchIds;                /// Reused by `dispatch` (no allocation once grown).

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
        // With no module loaded (the previous reload failed), the state saved back then is still the latest.
        if (!currentModule.isLoaded() && snapshots.length == 0)
            snapshots = pendingRestore;
        pendingRestore = snapshots;

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
        pendingRestore = null;
        remapStarted(world, snapshots);

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
            // Walk the component's dense store: exactly the live entities that
            // own it, regardless of how sparse recycled entity IDs have become.
            auto store = world.getStore(comp.typeId);
            if (store is null) continue;
            foreach (i; 0 .. store.count) {
                immutable entityId = store.denseToEntity[i];
                if (!world.alive(entityId)) continue;

                auto bytes = world.rawGet(comp.typeId, entityId);
                if (bytes.length == 0) continue;

                auto json = serializeComponent(types, comp.typeId, bytes, strings);
                snapshots ~= EntityScriptSnapshot(entityId, world.generation(entityId), comp.qualifiedName, json);
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
            if (!world.alive(snap.entity, snap.generation)) continue;
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

        auto components = currentModule.registrar.components;
        if (lifecycleFlag == LifecycleMask.onStart) {
            playing = true;
            startedGen = null;
        }
        // Components that appeared during play get onStart before their first other callback.
        if (playing && lifecycleFlag != LifecycleMask.onDestroy) {
            if (startedGen.length < components.length)
                startedGen.length = components.length;
            foreach (ci; 0 .. components.length)
                dispatch(world, cast(uint) ci, LifecycleMask.onStart, ctx, true);
        }
        if (lifecycleFlag != LifecycleMask.onStart) {
            foreach (ci; 0 .. components.length)
                dispatch(world, cast(uint) ci, lifecycleFlag, ctx, false);
        }
        if (lifecycleFlag == LifecycleMask.onDestroy) {
            playing = false;
            startedGen = null;
        }
    }

    /// Calls one method of one component type on every entity that owned it when the pass began. Callbacks may spawn,
    /// destroy and add or remove components.
    private void dispatch(
        ref SceneWorld world,
        uint compIndex,
        uint flag,
        scope ref ScriptContext ctx,
        bool onlyNew
    ) scope @trusted {
        auto comp = &currentModule.registrar.components[compIndex];
        auto cb = callbackFor(*comp, flag);
        auto store = world.getStore(comp.typeId);
        if (store is null || store.count == 0) return;
        if (cb is null) return;

        immutable n = store.count;
        if (dispatchIds.length < n)
            dispatchIds.length = n;
        dispatchIds[0 .. n] = store.denseToEntity[0 .. n];

        foreach (i; 0 .. n) {
            immutable entityId = dispatchIds[i];
            // Stores can be replaced while callbacks run.
            store = world.getStore(comp.typeId);
            if (store is null) return;
            if (!world.alive(entityId) || !store.has(entityId)) continue;
            immutable gen = world.generation(entityId);
            if (onlyNew) {
                if (startedGen[compIndex].length <= entityId)
                    startedGen[compIndex].length = entityId + 1;
                if (startedGen[compIndex][entityId] == gen) continue;
                startedGen[compIndex][entityId] = gen;
            }

            auto bytes = store.get(entityId);
            ctx.entity = entityId;
            ctx.world = &world;
            ctx.deferSelfDestroy = true;
            ctx.selfDestroyRequested = false;
            cb(bytes.ptr, ctx);
            ctx.deferSelfDestroy = false;

            if (ctx.selfDestroyRequested) {
                ctx.selfDestroyRequested = false;
                if (world.alive(entityId, gen))
                    world.destroy(entityId);
                continue;
            }
            // The callback may have grown or compacted the store: the method kept writing to the old location, which
            // is still readable (`bytes` keeps it alive). Move what it wrote to where the component lives now.
            if (world.alive(entityId, gen)) {
                store = world.getStore(comp.typeId);
                if (store !is null && store.has(entityId)) {
                    auto now = store.get(entityId);
                    if (now.ptr !is bytes.ptr && now.length == bytes.length)
                        now[] = bytes[];
                }
            }
        }
    }

    private static auto callbackFor(ref const ScriptComponentDescriptor comp, uint flag) nothrow @nogc {
        switch (flag) {
            case LifecycleMask.onStart:       return comp.onStart;
            case LifecycleMask.onUpdate:      return comp.onUpdate;
            case LifecycleMask.onFixedUpdate: return comp.onFixedUpdate;
            case LifecycleMask.onLateUpdate:  return comp.onLateUpdate;
            case LifecycleMask.onDestroy:     return comp.onDestroy;
            case LifecycleMask.onValidate:    return comp.onValidate;
            default:                          return null;
        }
    }

    /// After a reload during play, components restored from the old module were already started.
    private void remapStarted(ref SceneWorld world, const(EntityScriptSnapshot)[] snapshots) scope @trusted {
        if (!playing) return;
        auto components = currentModule.registrar.components;
        startedGen = new uint[][](components.length);
        foreach (ci, ref comp; components) {
            foreach (ref const s; snapshots) {
                if (s.typeName != comp.qualifiedName || !world.alive(s.entity, s.generation)) continue;
                if (startedGen[ci].length <= s.entity)
                    startedGen[ci].length = s.entity + 1;
                startedGen[ci][s.entity] = world.generation(s.entity);
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

    // Regression: a script component on an entity whose ID is far above
    // `entityCount() + 1000` (many spawned then destroyed) must be captured.
    EntityId[] filler;
    foreach (_; 0 .. 1500) filler ~= world.spawn();
    auto late = world.spawn();
    world.set(late, TestRotator(7.0f, 0));
    foreach (f; filler) world.destroy(f);
    assert(late > world.entityCount() + 1000);
    auto snaps2 = mgr.snapshotScriptData(world, world.types, world.strings);
    assert(snaps2.length == 2);
    bool foundLate;
    foreach (ref s; snaps2) if (s.entity == late) foundLate = true;
    assert(foundLate);
}

version (unittest) {
    // Module-level structs: attributes are not inferred, as in a real game module.
    private struct ScrPlain {
        int started, updated, fixedUpdated, late, destroyed;
        void onStart(scope ref ScriptContext ctx) { started++; }
        void onUpdate(scope ref ScriptContext ctx, float dt) { updated++; }
        void onFixedUpdate(float dt) { fixedUpdated++; }
        void onLateUpdate(ref ScriptContext ctx) { late++; }
        void onDestroy() { destroyed++; }
    }
    private struct ScrThrows {
        int n;
        void onUpdate(ref ScriptContext ctx) { n++; throw new Exception("boom"); }
    }
    private struct ScrSuicide {
        int n;
        void onUpdate(ref ScriptContext ctx) { ctx.destroy(ctx.entity); n = 1000; }
    }
    private struct ScrSpawner {
        int tag = 5, done;
        void onUpdate(ref ScriptContext ctx) {
            if (tag != 5) return;
            foreach (_; 0 .. 400) ctx.world.set(ctx.spawn(), ScrSpawner(1, 0));
            done = 99;
        }
    }
    import scrSystem = engine.reflect.attrs;
    private __gshared string scrOrder;
    @(scrSystem.system(Stage.update, 10)) private void scrLast(ref SceneWorld, float) @trusted { scrOrder ~= "c"; }
    @(scrSystem.system(Stage.update, -1)) private void scrFirst(ref SceneWorld, float) @trusted { scrOrder ~= "a"; }
    @(scrSystem.system(Stage.update, 0)) private void scrMid(ref SceneWorld, float) @trusted { scrOrder ~= "b"; }
}

@("scripts: methods need no attributes, every lifecycle method runs, late spawns get onStart")
@system unittest {
    import engine.script.module_entry : ModuleRegistrar;
    SceneWorld w;
    HotReloadManager m;
    ModuleRegistrar reg;
    reg.types = &w.types;
    reg.strings = &w.strings;
    reg.registerComponent!ScrPlain();
    reg.registerComponent!ScrThrows();
    reg.registerSystem!scrLast();
    reg.registerSystem!scrFirst();
    reg.registerSystem!scrMid();
    m.currentModule.registrar = reg;
    ScriptContext ctx;

    auto e = w.spawn();
    w.set(e, ScrPlain());
    w.set(e, ScrThrows());
    m.tickLifecycle(w, LifecycleMask.onStart, ctx);
    auto late = w.spawn();
    w.set(late, ScrPlain());
    foreach (flag; [LifecycleMask.onFixedUpdate, LifecycleMask.onUpdate, LifecycleMask.onLateUpdate, LifecycleMask.onDestroy])
        m.tickLifecycle(w, flag, ctx);
    assert(w.get!ScrPlain(e) == ScrPlain(1, 1, 1, 1, 1));
    assert(w.get!ScrPlain(late) == ScrPlain(1, 1, 1, 1, 1));
    assert(w.get!ScrThrows(e).n == 1);

    scrOrder = null;
    m.tickSystems(w, Stage.update, 0.1f);
    assert(scrOrder == "abc");
}

@("scripts: self-destroy and store growth inside a callback do not corrupt other components")
@system unittest {
    import engine.script.module_entry : ModuleRegistrar;
    SceneWorld w;
    HotReloadManager m;
    ModuleRegistrar reg;
    reg.types = &w.types;
    reg.strings = &w.strings;
    reg.registerComponent!ScrSuicide();
    reg.registerComponent!ScrSpawner();
    m.currentModule.registrar = reg;
    ScriptContext ctx;

    auto a = w.spawn();
    auto b = w.spawn();
    auto s = w.spawn();
    w.set(a, ScrSuicide());
    w.set(s, ScrSpawner());
    w.set(b, ScrSuicide(-7));
    immutable genA = w.generation(a), genB = w.generation(b);
    m.tickLifecycle(w, LifecycleMask.onUpdate, ctx);
    assert(!w.alive(a, genA) && !w.alive(b, genB)); // the spawner recycled their ids
    assert(w.get!ScrSpawner(s).done == 99);
    assert(w.entityCount() == 401);
}
