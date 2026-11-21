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
import engine.editor.components : MaterialOverride, Visual, VisualKind, worldMatrix;
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
    private ModelInstance defaultInstance;
    private bool ready;

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
        }
        assetSlot[stringId] = ASSET_UNKNOWN;
        return true;
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

        LightSet lights = packLightsFromWorld(world, lightSettings);
        if (lightSetIsEmpty(lights))
            lights = defaultSunLight(lightSettings);
        scene.setIblIntensity(lightSettings.iblIntensity);
        scene.setFog(lightSettings.fog);
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

    void destroy() @trusted {
        if (!ready) return;
        foreach (a; assets) if (a !is null) a.destroy();
        assets = null;
        assetSlot = null;
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
        try {
            auto file = loadAssetFile(path);
            immutable source = file.renderGltfPath();
            if (file.kind != AssetKind.model || source.length == 0) {
                warn("SceneRenderer: asset has no glTF render source, drawing a cube: ", path);
                return;
            }
            GltfLoadOptions opts; // mips on; LODs from the glTF's `.meta` settings.lod
            import core.lifetime : move;
            auto loaded = loadGltfAsset(gpu, source, scene.materialLayout(), sampler, opts);
            auto slot = new GltfAsset;
            move(loaded, *slot);
            assets ~= slot;
            assetSlot[id] = cast(int) assets.length;
            info("SceneRenderer: loaded ", path, " (", assets[$ - 1].subMeshes.length, " sub-meshes, ",
                 assets[$ - 1].nodes.length, " nodes)");
        } catch (Exception ex) {
            err("SceneRenderer: failed to load ", path, ": ", ex.msg);
        }
    }
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
