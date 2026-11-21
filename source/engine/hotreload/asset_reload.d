/**
 * HR-1 — asset hot-reload coordinator.
 *
 * One `FileWatcher` over the project's asset roots feeds every changed path
 * to the system that owns it:
 *
 * | change | action |
 * |:---|:---|
 * | `*.asset.json`, `.gltf`, `.glb`, `.bin`, images, `.meta` | `SceneRenderer.reloadChangedFiles` swaps every model built from that file |
 * | image registered with `watchTexture` | re-decoded into a new `Texture`, swapped into the registered slot, `onSwapped` rebuilds dependents |
 * | `.wgsl` registered with `watchSurfaceShader` | `Scene3DTextured.reloadSurfaceShader` (transactional) |
 * | `*.prefab.json` | `reloadPrefabInstances` rebuilds live instances, keeping overrides |
 * | `*.scene.json` | `onSceneChanged(path)` — the editor/player decides whether to reopen |
 * | `*.tune.json` registered in `TunableRegistry` | `TunableRegistry.loadFile` |
 *
 * Every swap is transactional: a file that fails to load or parse leaves the
 * previous resource in use and logs the error. Stock engine shaders keep
 * their own `ShaderHotReloader`.
 *
 * Ownership: loaders stay in `engine.assets` / `engine.graphics`; replaced
 * GPU resources are destroyed by the owner right after the swap, between
 * frames (`poll` must run outside `render`). Dev-time only: `poll`
 * allocates, so keep it out of `--assert-no-gc` runs.
 */
module engine.hotreload.asset_reload;

import std.path : baseName, buildNormalizedPath, extension;
import std.string : endsWith, toLower;
import engine.core.log : err, info, warn;
import engine.ecs.scene_world : SceneWorld;
import engine.editor.scene_renderer : SceneRenderer;
import engine.gpu.context : GpuContext;
import engine.graphics.texture : Texture, TextureDesc;
import engine.hotreload.tunables : TunableRegistry, isTunablePath;
import engine.hotreload.watcher : FileWatcher, WatchBackend;
import engine.project.asset_db : AssetDatabase;
import engine.project.asset_ref : AssetGuid;
import engine.scene.prefab : loadPrefabFile, reloadPrefabInstances;
import engine.scene.scene3d_textured : Scene3DTextured;
import engine.scene.scene_file : SceneFile;

@safe:

/// What a changed file is, judged by its name.
enum AssetChangeKind : ubyte {
    other,
    /// `*.asset.json`, glTF/GLB, `.bin` buffers, `.meta` sidecars.
    model,
    texture,
    shader,
    prefab,
    scene,
    tunable,
}

/// Classify `path` by suffix (case-insensitive extension).
AssetChangeKind classifyAssetPath(scope const(char)[] path) {
    if (path.endsWith(".prefab.json")) return AssetChangeKind.prefab;
    if (path.endsWith(".scene.json")) return AssetChangeKind.scene;
    if (isTunablePath(path)) return AssetChangeKind.tunable;
    if (path.endsWith(".asset.json")) return AssetChangeKind.model;
    switch (extension(path).toLower) {
        case ".gltf", ".glb", ".bin", ".meta":
            return AssetChangeKind.model;
        case ".png", ".jpg", ".jpeg", ".bmp", ".tga", ".qoi", ".webp", ".svg":
            return AssetChangeKind.texture;
        case ".wgsl":
            return AssetChangeKind.shader;
        default:
            return AssetChangeKind.other;
    }
}

/// What to reload into. Null members are skipped.
struct HotReloadTargets {
    GpuContext* gpu;
    SceneRenderer* renderer;
    SceneWorld* world;
    /// GUID lookup for prefabs; falls back to the `.meta` sidecar when null.
    const(AssetDatabase)* assetDb;
    TunableRegistry* tunables;
    /// Owner of surface shaders registered with `watchSurfaceShader`
    /// (defaults to `&renderer.scene` when null).
    Scene3DTextured* surfaceScene;
}

/// Counters for the last applied batch.
struct AssetReloadStats {
    uint files;
    uint models;
    uint textures;
    uint shaders;
    uint prefabInstances;
    uint scenes;
    uint tunableFiles;
    uint failures;

    uint total() const nothrow @nogc {
        return models + textures + shaders + prefabInstances + scenes + tunableFiles;
    }
}

struct AssetHotReloader {
    FileWatcher watcher;
    bool enabled = true;

    /// Called for a changed `*.scene.json`; the owner decides whether to reopen it.
    void delegate(string path) @safe onSceneChanged;
    /// Called with every settled batch, after the built-in handlers.
    void delegate(const(string)[] paths) @safe onFilesChanged;

    /// Counters of the most recent batch.
    AssetReloadStats lastStats;
    /// Batches applied since `init`.
    uint batchCount;

    private static struct TextureWatch {
        string path;
        Texture* target;
        TextureDesc desc;
        void delegate(ref Texture) @safe onSwapped;
    }

    private static struct SurfaceShaderWatch {
        string path;
        uint id;
    }

    private TextureWatch[] _textures;
    private SurfaceShaderWatch[] _surfaceShaders;
    private SceneFile[string] _prefabCache;

    /**
     * Watch `roots` (usually `["assets"]`) and snapshot every `*.prefab.json`
     * below them, so a later edit can be diffed against what instances were
     * spawned from.
     */
    bool init(string[] roots, float debounceSeconds = 0.2f,
              WatchBackend backend = WatchBackend.automatic) @trusted {
        import std.file : dirEntries, exists, isDir, SpanMode;
        foreach (root; roots) {
            if (!exists(root) || !isDir(root)) continue;
            try {
                foreach (entry; dirEntries(root, "*.prefab.json", SpanMode.depth))
                    if (!entry.isDir) trackPrefab(entry.name);
            } catch (Exception e) {
                warn("AssetHotReloader: prefab scan failed in ", root, ": ", e.msg);
            }
        }
        if (!watcher.init(roots, debounceSeconds, backend)) {
            warn("AssetHotReloader: no watchable asset root");
            return false;
        }
        info("AssetHotReloader: watching assets (", watcher.backend == WatchBackend.inotify
             ? "inotify" : "polling", ", ", _prefabCache.length, " prefabs cached)");
        return true;
    }

    void shutdown() {
        watcher.shutdown();
        _textures = null;
        _surfaceShaders = null;
        _prefabCache.clear();
    }

    /// Snapshot a prefab definition now (instances spawned later diff against it).
    bool trackPrefab(string path) @trusted {
        try {
            _prefabCache[buildNormalizedPath(path)] = loadPrefabFile(path);
            return true;
        } catch (Exception e) {
            warn("AssetHotReloader: cannot read prefab ", path, ": ", e.msg);
            return false;
        }
    }

    /// Number of prefab definitions currently cached.
    size_t cachedPrefabCount() const nothrow @nogc { return _prefabCache.length; }

    /**
     * Re-decode `path` into `*target` whenever it changes. `target` must
     * outlive the reloader (or be removed with `unwatchTexture`). `onSwapped`
     * runs after the swap so owners can rebuild bind groups/materials that
     * captured the old view.
     */
    void watchTexture(string path, Texture* target, TextureDesc desc = TextureDesc.init,
                      void delegate(ref Texture) @safe onSwapped = null) {
        _textures ~= TextureWatch(buildNormalizedPath(path), target, desc, onSwapped);
    }

    /// Stop updating `target`.
    void unwatchTexture(const(Texture)* target) @trusted {
        import std.algorithm.mutation : remove;
        _textures = _textures.remove!(w => w.target is target);
    }

    /// Reload custom surface shader `id` (from `createSurfaceShader`) from `path`.
    void watchSurfaceShader(string path, uint id) {
        _surfaceShaders ~= SurfaceShaderWatch(buildNormalizedPath(path), id);
    }

    /**
     * Per-frame: collect watcher events and, once a batch settles, apply it.
     * Returns the number of resources/instances reloaded (0 most frames).
     */
    uint poll(float dt, ref HotReloadTargets targets) {
        if (!enabled || !watcher.active) return 0;
        if (!watcher.poll(dt)) return 0;
        return applyChanges(watcher.changedPaths, targets);
    }

    /// Apply one batch of changed paths (also usable without the watcher).
    uint applyChanges(scope const(string)[] paths, ref HotReloadTargets t) @trusted {
        AssetReloadStats stats;
        stats.files = cast(uint) paths.length;
        if (paths.length == 0) return 0;

        string[] normalized;
        bool anyModelInput;
        foreach (p; paths) {
            immutable n = buildNormalizedPath(p);
            normalized ~= n;
            immutable kind = classifyAssetPath(n);
            if (kind == AssetChangeKind.model || kind == AssetChangeKind.texture)
                anyModelInput = true;
        }

        // Models (and the images/buffers they are built from).
        if (anyModelInput && t.renderer !is null && t.gpu !is null && t.renderer.valid) {
            if (!t.renderer.tracksDependencies) t.renderer.enableDependencyTracking();
            stats.models += t.renderer.reloadChangedFiles(*t.gpu, normalized);
        }

        foreach (n; normalized) {
            final switch (classifyAssetPath(n)) {
                case AssetChangeKind.texture:
                    reloadTextures(n, t, stats);
                    break;
                case AssetChangeKind.shader:
                    reloadSurfaceShaders(n, t, stats);
                    break;
                case AssetChangeKind.prefab:
                    reloadPrefab(n, t, stats);
                    break;
                case AssetChangeKind.scene:
                    if (onSceneChanged !is null) {
                        onSceneChanged(n);
                        stats.scenes++;
                    }
                    break;
                case AssetChangeKind.tunable:
                    if (t.tunables !is null && t.tunables.watches(n)) {
                        if (t.tunables.loadFile(n)) stats.tunableFiles++;
                        else stats.failures++;
                    }
                    break;
                case AssetChangeKind.model:
                case AssetChangeKind.other:
                    break;
            }
        }

        if (onFilesChanged !is null) onFilesChanged(normalized);
        lastStats = stats;
        batchCount++;
        immutable total = stats.total;
        if (total || stats.failures)
            info("AssetHotReloader: ", paths.length, " file(s) changed -> ", stats.models, " model(s), ",
                 stats.textures, " texture(s), ", stats.shaders, " shader(s), ", stats.prefabInstances,
                 " prefab instance(s), ", stats.tunableFiles, " tunable file(s), ", stats.failures, " failure(s)");
        return total;
    }

    private void reloadTextures(string path, ref HotReloadTargets t, ref AssetReloadStats stats) @trusted {
        foreach (ref w; _textures) {
            if (w.path != path || w.target is null) continue;
            if (t.gpu is null) {
                warn("AssetHotReloader: texture ", path, " changed but no GpuContext was given");
                return;
            }
            import std.file : exists;
            if (!exists(path)) continue; // deleted: keep the last good texture
            auto fresh = Texture.fromImageFile(*t.gpu, path, w.desc);
            if (!fresh.valid) {
                err("AssetHotReloader: failed to decode ", path, "; keeping the previous texture");
                stats.failures++;
                continue;
            }
            import core.lifetime : move;
            w.target.destroy();
            move(fresh, *w.target);
            if (w.onSwapped !is null) w.onSwapped(*w.target);
            stats.textures++;
            info("AssetHotReloader: reloaded texture ", path);
        }
    }

    private void reloadSurfaceShaders(string path, ref HotReloadTargets t, ref AssetReloadStats stats) @trusted {
        foreach (ref w; _surfaceShaders) {
            if (w.path != path) continue;
            Scene3DTextured* scene = t.surfaceScene;
            if (scene is null && t.renderer !is null && t.renderer.valid) scene = &t.renderer.scene;
            if (scene is null) return;
            import std.file : readText;
            string source;
            try {
                source = readText(path);
            } catch (Exception e) {
                err("AssetHotReloader: cannot read ", path, ": ", e.msg);
                stats.failures++;
                continue;
            }
            if (scene.reloadSurfaceShader(w.id, source)) {
                stats.shaders++;
                info("AssetHotReloader: reloaded surface shader ", path);
            } else {
                err("AssetHotReloader: surface shader ", path, " failed to compile; keeping the previous one");
                stats.failures++;
            }
        }
    }

    private void reloadPrefab(string path, ref HotReloadTargets t, ref AssetReloadStats stats) @trusted {
        import std.file : exists;
        if (!exists(path)) {
            _prefabCache.remove(path);
            return;
        }
        SceneFile fresh;
        try {
            fresh = loadPrefabFile(path);
        } catch (Exception e) {
            err("AssetHotReloader: prefab ", path, " is invalid (", e.msg, "); instances unchanged");
            stats.failures++;
            return;
        }
        auto old = path in _prefabCache;
        if (old !is null && t.world !is null) {
            immutable guid = guidForAsset(path, t.assetDb);
            if (guid.isNull) {
                warn("AssetHotReloader: prefab ", path, " has no GUID (.meta); instances not updated");
            } else {
                stats.prefabInstances += reloadPrefabInstances(*t.world, guid, *old, fresh);
            }
        }
        _prefabCache[path] = fresh;
    }
}

/// GUID of `path` from `db`, else from its `.meta` sidecar (null when unknown).
AssetGuid guidForAsset(string path, const(AssetDatabase)* db) @trusted {
    if (db !is null) {
        auto g = db.getGuid(path);
        if (!g.isNull) return g;
    }
    import std.file : exists, readText;
    import std.json : JSONType, parseJSON;
    immutable meta = path ~ ".meta";
    if (!exists(meta)) return AssetGuid.init;
    try {
        auto root = parseJSON(readText(meta));
        if (root.type == JSONType.object && "guid" in root && root["guid"].type == JSONType.string)
            return AssetGuid.fromString(root["guid"].str);
    } catch (Exception) {}
    return AssetGuid.init;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

@("assetReload.classify") unittest {
    assert(classifyAssetPath("assets/a/car.prefab.json") == AssetChangeKind.prefab);
    assert(classifyAssetPath("assets/scenes/x.scene.json") == AssetChangeKind.scene);
    assert(classifyAssetPath("assets/data/car.tune.json") == AssetChangeKind.tunable);
    assert(classifyAssetPath("assets/models/crate.asset.json") == AssetChangeKind.model);
    assert(classifyAssetPath("assets/models/rock.GLB") == AssetChangeKind.model);
    assert(classifyAssetPath("assets/models/rock.gltf.meta") == AssetChangeKind.model);
    assert(classifyAssetPath("assets/tex/road.PNG") == AssetChangeKind.texture);
    assert(classifyAssetPath("assets/shaders/x.wgsl") == AssetChangeKind.shader);
    assert(classifyAssetPath("assets/readme.md") == AssetChangeKind.other);
}

version (unittest) private string assetReloadTestDir() @trusted {
    import std.file : exists, mkdirRecurse, rmdirRecurse;
    immutable dir = "build/test_asset_reload";
    if (exists(dir)) rmdirRecurse(dir);
    mkdirRecurse(dir);
    return dir;
}

@("assetReload.prefabTunableSceneDispatch") @trusted unittest {
    import std.file : rmdirRecurse, write;
    import engine.ecs.store : EntityId;
    import engine.editor.scene_load : collectSubtreeEntities;
    import engine.math.vec : Vec3;
    import engine.scene.graph : Transform;
    import engine.scene.prefab : PrefabInstance, instantiatePrefab, savePrefabFile;
    import engine.scene.scene_file : SceneEntityData;

    immutable dir = assetReloadTestDir();
    scope (exit) rmdirRecurse(dir);

    // Prefab v1 on disk with a GUID sidecar.
    immutable guid = AssetGuid.generate();
    immutable pfPath = dir ~ "/crate.prefab.json";
    SceneFile v1;
    v1.meta.name = "Crate";
    SceneEntityData root;
    root.id = 1;
    SceneEntityData lid;
    lid.id = 2;
    lid.parent = 1;
    lid.transform.pos = [0, 1, 0];
    v1.entities = [root, lid];
    savePrefabFile(pfPath, v1);
    write(pfPath ~ ".meta", `{"guid":"` ~ guid.toString() ~ `","importer":"prefab"}`);
    immutable tunePath = dir ~ "/crate.tune.json";
    write(tunePath, `{"crate": {"mass": 10}}`);

    SceneWorld world;
    TunableRegistry tunables;
    assert(tunables.addFile(tunePath));

    AssetHotReloader hr;
    assert(hr.init([dir], 0.1f, WatchBackend.polling));
    assert(hr.cachedPrefabCount == 1);
    string sceneSeen;
    hr.onSceneChanged = (string p) { sceneSeen = p; };

    auto inst = instantiatePrefab(world, v1, world.strings, guid, Vec3(5, 0, 0));
    assert(inst != EntityId.max);

    // Edit the prefab, the tunables and a scene, then apply the batch.
    SceneFile v2 = v1;
    v2.entities = v1.entities.dup;
    v2.entities[1].transform.pos = [0, 4, 0];
    savePrefabFile(pfPath, v2);
    write(tunePath, `{"crate": {"mass": 25}}`);
    immutable scenePath = dir ~ "/level.scene.json";
    write(scenePath, "{}");

    HotReloadTargets t;
    t.world = &world;
    t.tunables = &tunables;
    immutable n = hr.applyChanges([pfPath, tunePath, scenePath], t);
    assert(n == 3);
    assert(hr.lastStats.prefabInstances == 1 && hr.lastStats.tunableFiles == 1 && hr.lastStats.scenes == 1);
    assert(sceneSeen == scenePath);
    assert(tunables.getFloat("crate.mass") == 25);

    EntityId newRoot = EntityId.max;
    foreach (e; world.query!PrefabInstance()) newRoot = e;
    assert(newRoot != EntityId.max);
    auto sub = collectSubtreeEntities(world, newRoot);
    assert(sub.length == 2 && world.get!Transform(sub[1]).position == Vec3(0, 4, 0));

    // A broken prefab edit keeps the live instance and the cached definition.
    write(pfPath, "{ not json");
    assert(hr.applyChanges([pfPath], t) == 0);
    assert(hr.lastStats.failures == 1);
    assert(world.alive(newRoot));
    hr.shutdown();
}

@("assetReload.watcherEndToEndWithin500ms") @trusted unittest {
    import core.time : seconds;
    import std.datetime.systime : Clock;
    import std.file : rmdirRecurse, setTimes, write;

    immutable dir = assetReloadTestDir();
    scope (exit) rmdirRecurse(dir);
    immutable tunePath = dir ~ "/speed.tune.json";
    write(tunePath, `{"player": {"speed": 4}}`);

    TunableRegistry tunables;
    assert(tunables.addFile(tunePath));
    AssetHotReloader hr;
    assert(hr.init([dir], 0.2f));
    hr.watcher.pollInterval = 0.05f;
    HotReloadTargets t;
    t.tunables = &tunables;
    assert(hr.poll(0.016f, t) == 0);

    write(tunePath, `{"player": {"speed": 9}}`);
    immutable future = Clock.currTime() + 5.seconds; // coarse-mtime filesystems
    setTimes(tunePath, future, future);

    // Simulated 60 Hz frames: the edit must land within 0.5 s of game time.
    float elapsed = 0;
    bool applied;
    while (elapsed < 0.5f && !applied) {
        elapsed += 1.0f / 60.0f;
        applied = hr.poll(1.0f / 60.0f, t) > 0;
    }
    assert(applied, "tunable edit not applied within 0.5 s");
    assert(tunables.getFloat("player.speed") == 9);
    hr.shutdown();
}
