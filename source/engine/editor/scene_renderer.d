/**
 * `SceneRenderer` — draws an editor/player `SceneWorld` through
 * `Scene3DTextured` (OpenPBR, shadows, culling, automatic LOD).
 *
 * Shared by the visual editor and the standalone player so both show the
 * same image:
 * - `Visual` primitives (cube / sphere / plane) use built-in `TexMesh`es with
 *   a white OpenPBR material; `MaterialOverride.baseColor` /
 *   `geometryOpacity` become the instance tint.
 * - `VisualKind.mesh` entities reference a `*.asset.json`; its glTF/GLB
 *   (`render.source`) is loaded once into a cached `GltfAsset` (all nodes,
 *   primitives and materials; `.meta` `settings.lod` builds LOD chains) and
 *   drawn with `drawModel`. Missing or broken assets fall back to a cube.
 * - `Transform` + `WaterSurface` entities become `WaterRenderer` bodies
 *   once `enableWater` was called (up to `MAX_WATER_BODIES`); the engine
 *   sky, which the water reflects, is drawn while any water exists.
 * - `Light` components are packed with `packLightsFromWorld` and rendered
 *   with shadows. A scene without lights gets a default sun so it is never
 *   black.
 *
 * Frame path: `render` allocates nothing once every referenced asset is
 * loaded. A newly referenced asset path is loaded on first sight (load-time
 * work; GC allowed) and remembered, including failures, so it is never
 * retried every frame.
 */
module engine.editor.scene_renderer;

import engine.assets.asset_file : AssetKind, loadAssetFile;
import engine.core.log;
import engine.editor.components : MaterialOverride, MAX_REFLECTION_PROBES, ReflectionProbe, Visual, VisualKind, worldMatrix;
import engine.editor.light_panel : applyCascadeSettings, SceneLightSettings, packLightsFromWorld;
import engine.gpu.context : GpuContext;
import engine.gpu.renderer : FrameContext;
import engine.gpu.shadow : directionalLightVP;
import engine.graphics.material : Material;
import engine.graphics.model : GltfAsset, GltfLoadOptions, ModelInstance, drawModel, loadGltfAsset;
import engine.graphics.texmesh : TexMesh;
import engine.graphics.texture : Sampler, SamplerDesc, Texture, TextureFilter, TextureWrap;
import engine.graphics.types : Color4;
import engine.math.mat : Mat4;
import engine.math.vec : Vec3;
import engine.scene.camera : Camera;
import engine.scene.graph : Transform;
import engine.scene.light : LightSet;
import engine.scene.scene3d_textured : Scene3DTextured;
import engine.ecs.store : EntityId;
import engine.gpu.renderer : Renderer;
import engine.water.component : WaterSurface, toWaterBody;
import engine.water.gpu_data : MAX_WATER_BODIES;
import engine.water.renderer : WaterRenderer;
import core.time : MonoTime;

@safe:

/// Asset-table state for one interned `*.asset.json` path.
private enum int ASSET_UNKNOWN = 0;
private enum int ASSET_FAILED = -1;

/// True when `set` has no light at all (the renderer then adds a sun).
bool lightSetIsEmpty(ref const LightSet set) pure nothrow @nogc {
    return !set.dirEnabled && set.pointCount == 0 && set.spotCount == 0;
}

/// Default sun for scenes without lights, fitted to the shadow settings.
LightSet defaultSunLight(ref const SceneLightSettings settings) {
    LightSet set;
    set.dirEnabled = true;
    set.dir.direction = Vec3(0.4f, 1.0f, 0.3f).normalized();
    set.dir.color = Vec3(1.0f, 0.97f, 0.92f);
    set.dir.intensity = 2.5f;
    set.dir.castShadows = true;
    set.dir.viewProj = directionalLightVP(set.dir.direction, settings.dirShadowCenter, settings.dirShadowRadius);
    applyCascadeSettings(set.dir, settings);
    set.shadowBias = 0.0004f;
    return set;
}

/// Instance tint from an optional `MaterialOverride` (white when absent).
Color4 overrideTint(bool hasOverride, ref const MaterialOverride m) pure nothrow @nogc {
    if (!hasOverride) return Color4.white;
    return Color4(m.baseColor[0], m.baseColor[1], m.baseColor[2], m.geometryOpacity);
}

/// Renders a `SceneWorld`'s visuals and lights. Move-only; call `destroy()`.
struct SceneRenderer {
    Scene3DTextured scene;
    private Sampler sampler;
    private Texture white;
    private Material defaultMaterial;
    private TexMesh cube, sphere, plane;
    /// Heap slots so the move-only assets never relocate.
    private GltfAsset*[] assets;
    /// `StringId.id` → `assets` index + 1, `ASSET_UNKNOWN` or `ASSET_FAILED`.
    private int[] assetSlot;
    /// Per `assets` index: `*.asset.json` path and, when dependency
    /// tracking is on, every file the slot was built from (normalized).
    private string[] slotPath;
    private string[][] slotDeps;
    private bool trackDeps;
    private ModelInstance defaultInstance;
    private bool ready;
    /// Water: one `WaterRenderer` body per `WaterSurface` entity.
    private WaterRenderer water;
    private bool waterReady;
    private EntityId[MAX_WATER_BODIES] waterEntity;
    private int[MAX_WATER_BODIES] waterId = -1;
    private MonoTime waterStart;

    @disable this(this);

    static SceneRenderer create(ref GpuContext gpu) @trusted {
        SceneRenderer r;
        r.scene = Scene3DTextured.create(gpu);
        SamplerDesc sd;
        sd.filter = TextureFilter.linear;
        sd.wrap = TextureWrap.repeat;
        sd.maxAnisotropy = 8;
        r.sampler = Sampler.create(gpu, sd);
        r.white = Texture.solid(gpu, 255, 255, 255, 255);
        r.defaultMaterial = Material.create(gpu, r.scene.materialLayout(), r.sampler, r.white);
        r.cube = TexMesh.cube(gpu);
        r.sphere = TexMesh.sphere(gpu);
        r.plane = TexMesh.quad(gpu);
        r.ready = true;
        return r;
    }

    bool valid() const nothrow @nogc { return ready; }

    /// Number of `*.asset.json` models loaded so far.
    size_t loadedAssetCount() const nothrow @nogc { return assets.length; }

    /// Unload a cached `GltfAsset` slot by interned path `StringId.id` so streamed chunks
    /// can release GPU memory when unloaded. Returns true if an asset was destroyed.
    bool unloadAsset(uint stringId) @trusted {
        if (stringId >= assetSlot.length)
            return false;
        immutable slot = assetSlot[stringId];
        if (slot <= 0) {
            assetSlot[stringId] = ASSET_UNKNOWN;
            return false;
        }
        immutable idx = cast(size_t)(slot - 1);
        if (idx < assets.length && assets[idx] !is null) {
            assets[idx].destroy();
            assets[idx] = null;
            slotDeps[idx] = null;
        }
        assetSlot[stringId] = ASSET_UNKNOWN;
        return true;
    }

    /**
     * Record, for every loaded model, the files it was built from
     * (`*.asset.json`, glTF/GLB, `.meta`, external buffers and images) so
     * `reloadChangedFiles` can find the models an edit affects. Off by
     * default because it parses each glTF a second time at load; the editor
     * and dev players turn it on together with `AssetHotReloader`.
     */
    void enableDependencyTracking() @trusted {
        if (trackDeps) return;
        trackDeps = true;
        foreach (idx, a; assets)
            if (a !is null) slotDeps[idx] = assetDependencies(slotPath[idx]);
    }

    /// True once `enableDependencyTracking` was called.
    bool tracksDependencies() const nothrow @nogc { return trackDeps; }

    /// Files the loaded model behind `*.asset.json` `assetPath` depends on.
    const(string)[] dependenciesOf(scope const(char)[] assetPath) const {
        foreach (idx, p; slotPath)
            if (p == assetPath && assets[idx] !is null) return slotDeps[idx];
        return null;
    }

    /**
     * HR-1 hot-reload: re-import every loaded model that depends on one of
     * `changedPaths` and swap it in place. The swap is transactional: when
     * the new import fails, the previous GPU asset stays in use and the error
     * is logged. Models that previously failed to load are retried. Returns
     * the number of models swapped. Load-time work (allocates); call between
     * frames, never inside `render`.
     */
    uint reloadChangedFiles(ref GpuContext gpu, scope const(string)[] changedPaths) @trusted {
        import std.path : buildNormalizedPath;
        if (!ready || changedPaths.length == 0) return 0;
        bool[string] changed;
        foreach (p; changedPaths) changed[buildNormalizedPath(p)] = true;

        uint swapped;
        foreach (idx, a; assets) {
            if (a is null) continue;
            bool hit = (buildNormalizedPath(slotPath[idx]) in changed) !is null;
            foreach (d; slotDeps[idx]) if (!hit && (d in changed)) hit = true;
            if (!hit) continue;

            GltfAsset fresh;
            string[] deps;
            if (!importAsset(gpu, slotPath[idx], fresh, deps)) {
                warn("SceneRenderer: hot-reload kept the previous version of ", slotPath[idx]);
                continue;
            }
            import core.lifetime : move;
            assets[idx].destroy();
            move(fresh, *assets[idx]);
            slotDeps[idx] = deps;
            swapped++;
            info("SceneRenderer: hot-reloaded ", slotPath[idx]);
        }
        // Give failed imports another chance: the edit may have fixed them.
        foreach (id, s; assetSlot)
            if (s == ASSET_FAILED) assetSlot[id] = ASSET_UNKNOWN;
        return swapped;
    }

    /**
     * Load every mesh asset referenced by `world` that has not been seen yet.
     * Called by `render`; call it right after loading a scene to keep the
     * first frame from paying for the imports.
     */
    void syncAssets(W)(ref GpuContext gpu, ref W world) {
        if (!ready) return;
        foreach (e; world.query!(Transform, Visual)()) {
            if (!world.alive(e)) continue;
            immutable v = world.get!Visual(e);
            if (v.kind != VisualKind.mesh || v.assetPath.isNull) continue;
            immutable id = v.assetPath.id;
            if (id < assetSlot.length && assetSlot[id] != ASSET_UNKNOWN) continue;
            loadAssetSlot(gpu, id, world.strings.get(v.assetPath));
        }
    }

    /**
     * Draw every visible entity of `world` from `camera` into `frame`, with
     * the world's lights (or a default sun) and shadows. `viewportHeight` is
     * the target height in pixels (LOD selection).
     */
    void render(W)(ref GpuContext gpu, ref W world, ref FrameContext frame, ref const Camera camera,
                   ref const SceneLightSettings lightSettings, float viewportHeight) {
        if (!ready || !frame.valid) return;
        syncAssets(gpu, world);
        if (waterReady) syncWater(world, camera);

        LightSet lights = packLightsFromWorld(world, lightSettings);
        if (lightSetIsEmpty(lights))
            lights = defaultSunLight(lightSettings);
        scene.setIblIntensity(lightSettings.iblIntensity);
        scene.setFog(lightSettings.fog);
        static if (is(typeof(world.query!(Transform, ReflectionProbe)()))) {
            ReflectionProbe[MAX_REFLECTION_PROBES] probes;
            uint probeCount = 0;
            foreach (e; world.query!(Transform, ReflectionProbe)()) {
                if (!world.alive(e)) continue;
                auto pr = world.get!ReflectionProbe(e);
                immutable tr = world.get!Transform(e);
                pr.position = tr.position;
                probes[probeCount++] = pr;
                if (probeCount >= MAX_REFLECTION_PROBES) break;
            }
            scene.setReflectionProbes(probes[0 .. probeCount]);
        }
        if (viewportHeight >= 1) scene.setLodScreenHeight(viewportHeight);

        scene.begin(camera);
        foreach (e; world.query!(Transform, Visual)()) {
            if (!world.alive(e)) continue;
            immutable v = world.get!Visual(e);
            if (v.kind == VisualKind.none) continue;

            immutable bool hasOverride = world.has!MaterialOverride(e);
            MaterialOverride mo;
            if (hasOverride) mo = world.get!MaterialOverride(e);
            immutable tint = overrideTint(hasOverride, mo);
            immutable model = worldMatrix(world, e);

            final switch (v.kind) {
                case VisualKind.none:
                    break;
                case VisualKind.cube:
                    scene.drawMatrix(cube, defaultMaterial, model, tint);
                    break;
                case VisualKind.sphere:
                    scene.drawMatrix(sphere, defaultMaterial, model, tint);
                    break;
                case VisualKind.plane:
                    scene.drawMatrix(plane, defaultMaterial, model, tint);
                    break;
                case VisualKind.mesh:
                    immutable slot = v.assetPath.isNull || v.assetPath.id >= assetSlot.length
                        ? ASSET_UNKNOWN : assetSlot[v.assetPath.id];
                    if (slot > 0)
                        drawModel(scene, *assets[slot - 1], defaultInstance, model, tint);
                    else
                        scene.drawMatrix(cube, defaultMaterial, model, tint);
                    break;
            }
        }
        scene.renderShadows(frame, lights);
        scene.end(frame);
    }

    /**
     * Draw `WaterSurface` entities from now on. Call once, after this
     * renderer and `renderer` reached their final addresses (the water draw
     * hook keeps pointers to both). Allocates GPU resources.
     */
    void enableWater(ref GpuContext gpu, ref Renderer renderer) @trusted {
        if (!ready || waterReady) return;
        water = WaterRenderer.create(gpu, scene);
        water.attach(scene, renderer);
        waterId[] = -1;
        waterStart = MonoTime.currTime;
        waterReady = true;
    }

    /// Adds, updates and removes water bodies to match the world's
    /// `WaterSurface` entities, then uploads the water frame data. Adding a
    /// body allocates GPU resources (first frame it appears only).
    private void syncWater(W)(ref W world, ref const Camera camera) @trusted {
        bool[MAX_WATER_BODIES] seen;
        foreach (e; world.query!(Transform, WaterSurface)()) {
            if (!world.alive(e)) continue;
            immutable ws = world.get!WaterSurface(e);
            immutable tr = world.get!Transform(e);
            immutable wb = toWaterBody(ws, tr);
            int slot = -1;
            foreach (i; 0 .. MAX_WATER_BODIES)
                if (waterId[i] >= 0 && waterEntity[i] == e) { slot = cast(int) i; break; }
            if (slot < 0) {
                foreach (i; 0 .. MAX_WATER_BODIES)
                    if (waterId[i] < 0) { slot = cast(int) i; break; }
                if (slot < 0) continue;   // every body slot is in use
                waterId[slot] = water.addBody(wb);
                if (waterId[slot] < 0) continue;
                waterEntity[slot] = e;
            } else {
                water.setBody(waterId[slot], wb);
                water.setGridResolution(waterId[slot], wb.gridResolution);   // no-op when unchanged
            }
            seen[slot] = true;
        }
        foreach (i; 0 .. MAX_WATER_BODIES) {
            if (waterId[i] < 0 || seen[i]) continue;
            water.removeBody(waterId[i]);
            waterId[i] = -1;
        }
        // The water reflects the engine sky: show it while any water exists.
        scene.setSkyEnabled(water.bodyCount() > 0);
        immutable float t = (MonoTime.currTime - waterStart).total!"usecs" * 1e-6f;
        water.update(camera, t);
    }

    void destroy() @trusted {
        if (!ready) return;
        if (waterReady) {
            water.destroy();
            waterReady = false;
        }
        foreach (a; assets) if (a !is null) a.destroy();
        assets = null;
        assetSlot = null;
        slotPath = null;
        slotDeps = null;
        plane.destroy();
        sphere.destroy();
        cube.destroy();
        defaultMaterial.destroy();
        white.destroy();
        sampler.destroy();
        scene.destroy();
        ready = false;
    }

    private void loadAssetSlot(ref GpuContext gpu, uint id, scope const(char)[] assetPath) @trusted {
        if (id >= assetSlot.length) assetSlot.length = id + 1;
        assetSlot[id] = ASSET_FAILED;
        immutable path = assetPath.idup;
        GltfAsset loaded;
        string[] deps;
        if (!importAsset(gpu, path, loaded, deps)) return;
        import core.lifetime : move;
        auto slot = new GltfAsset;
        move(loaded, *slot);
        assets ~= slot;
        slotPath ~= path;
        slotDeps ~= deps;
        assetSlot[id] = cast(int) assets.length;
        info("SceneRenderer: loaded ", path, " (", assets[$ - 1].subMeshes.length, " sub-meshes, ",
             assets[$ - 1].nodes.length, " nodes)");
    }

    /// Import `*.asset.json` `path` into `result`; false (logged) on failure.
    private bool importAsset(ref GpuContext gpu, string path, out GltfAsset result,
                             out string[] deps) @trusted {
        try {
            auto file = loadAssetFile(path);
            immutable source = file.renderGltfPath();
            if (file.kind != AssetKind.model || source.length == 0) {
                warn("SceneRenderer: asset has no glTF render source, drawing a cube: ", path);
                return false;
            }
            GltfLoadOptions opts; // mips on; LODs from the glTF's `.meta` settings.lod
            import core.lifetime : move;
            auto loaded = loadGltfAsset(gpu, source, scene.materialLayout(), sampler, opts);
            move(loaded, result);
            if (trackDeps) deps = assetDependencies(path);
            return true;
        } catch (Exception ex) {
            err("SceneRenderer: failed to load ", path, ": ", ex.msg);
            return false;
        }
    }
}

/**
 * Files a `*.asset.json` model depends on: the asset file, its glTF render
 * source and that glTF's own dependencies (`gltfFileDependencies`), as
 * normalized paths. Load-time only.
 */
string[] assetDependencies(string assetJsonPath) @trusted {
    import std.path : buildNormalizedPath;
    import engine.assets.gltf : gltfFileDependencies;
    string[] deps = [buildNormalizedPath(assetJsonPath)];
    try {
        auto file = loadAssetFile(assetJsonPath);
        immutable source = file.renderGltfPath();
        if (source.length) deps ~= gltfFileDependencies(source);
    } catch (Exception) {}
    return deps;
}

@("sceneRenderer.assetDependencies") unittest {
    import std.algorithm.searching : canFind;
    auto deps = assetDependencies("assets/models/crate.asset.json");
    assert(deps[0] == "assets/models/crate.asset.json");
    assert(deps.canFind("assets/models/pbr_cube.gltf"));
    assert(deps.canFind("assets/models/pbr_cube_albedo.bmp"));
    assert(assetDependencies("build/missing.asset.json") == ["build/missing.asset.json"]);
}

@("sceneRenderer.lightFallback") unittest {
    LightSet empty; // `LightSet.init` enables the directional light; packed sets clear it
    empty.dirEnabled = false;
    assert(lightSetIsEmpty(empty));
    SceneLightSettings settings;
    auto sun = defaultSunLight(settings);
    assert(!lightSetIsEmpty(sun) && sun.dirEnabled && sun.dir.castShadows);
    assert(sun.dir.direction.y > 0.8f);
    LightSet point;
    point.dirEnabled = false;
    point.pointCount = 1;
    assert(!lightSetIsEmpty(point));
}

@("sceneRenderer.tint") nothrow @nogc unittest {
    MaterialOverride m;
    assert(overrideTint(false, m) == Color4.white);
    m.baseColor = [0.2f, 0.4f, 0.6f];
    m.geometryOpacity = 0.5f;
    immutable t = overrideTint(true, m);
    assert(t.r == 0.2f && t.g == 0.4f && t.b == 0.6f && t.a == 0.5f);
}
