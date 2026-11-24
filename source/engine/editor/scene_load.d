/// Spawn / capture `EditorWorld` from `SceneFile` (ED-7).
///
/// Resolves string-table refs into interned `StringId`s, maps file entity ids
/// (1-based, `parent:0` = none) onto live `EntityId`s, and applies light /
/// physics / visual / material components.
///
/// Lives in `engine.editor` (not `engine.scene`) because it targets
/// `EditorWorld` and editor light settings — the disk format stays in
/// `engine.scene.scene_file` for potential runtime loaders.
module engine.editor.scene_load;

import std.exception : enforce;

import engine.core.strings : StringId, StringTable;
import engine.ecs.store : EntityId;
import engine.editor.components :
    EditorWorld, MaterialOverride, Name, Parent, PhysicsBody, PhysicsMotion,
    PhysicsShapeKind, Visual, VisualKind, defaultHalfExtents, noParent,
    validatePhysicsBody, PhysicsValidation;
import engine.editor.light_panel : IblPreset, SceneLightSettings;
import engine.math.quat : Quat;
import engine.math.vec : Vec3;
import engine.scene.graph : Transform;
import engine.scene.light : Light, LightType;
import engine.scene.scene_file :
    SceneEntityData, SceneFile, SceneLightData, SceneMaterialData, SceneMeta,
    ScenePhysicsData, SceneValidationResult, SceneVisualData,
    clampShadowBudget, sceneNoParent, sceneToMinifiedJson, validateScene;

@safe:

/// Result of loading a scene into a world.
/// A `customComponents` entry whose type the target world does not register.
/// The entity still loads; the component is skipped.
struct UnresolvedComponent {
    EntityId entity;
    string typeName;
}

struct SceneLoadResult {
    /// File entity id → live `EntityId`.
    EntityId[uint] fileIdToEntity;
    /// All live entities spawned during this load, in file order.
    EntityId[] spawnedEntities;
    SceneValidationResult validation;
    /// How many `castShadows` flags were cleared to fit the shadow budget.
    uint shadowsClamped;
    /// Custom components skipped because their type is not registered.
    UnresolvedComponent[] unresolvedComponents;
}

/// Options for `loadSceneIntoWorld` / `worldToSceneFile`.
struct SceneLoadOptions {
    /// When true, `validateScene` must pass (errors throw).
    bool validate = true;
    /// When true, missing `*.asset.json` files are errors.
    bool checkAssetFiles = true;
    /// When true, excess shadow casters are clamped (and warned via validation).
    bool clampShadows = true;
    string defaultMetaName = "untitled";
    string defaultUnits = "meters";
}

// ---------------------------------------------------------------------------
// Load
// ---------------------------------------------------------------------------

/// Add entities from `scene` into `world` without clearing existing entities.
/// Remaps file-local `id` and `parent` indices to newly spawned live `EntityId`s,
/// and applies `rootOffset` to root entities (`e.parent == sceneNoParent`).
SceneLoadResult loadSceneAdditive(W)(
    ref W world,
    ref SceneFile scene,
    Vec3 rootOffset = Vec3(0, 0, 0),
    SceneLoadOptions opts = SceneLoadOptions.init
) {
    SceneLoadResult result;
    if (opts.validate || opts.clampShadows) {
        result.validation = validateScene(scene, opts.checkAssetFiles);
    }
    if (opts.clampShadows)
        result.shadowsClamped = clampShadowBudget(scene);

    if (opts.validate && !result.validation.ok) {
        string msg = "scene validation failed:";
        foreach (ref e; result.validation.errors)
            msg ~= " [" ~ e.message ~ "]";
        enforce(false, msg);
    }

    // All or nothing: a failure midway must not leave half of the scene in the world.
    scope (failure) {
        foreach (id; result.spawnedEntities)
            world.destroy(id);
    }

    // First pass: spawn entities + components (parents deferred). Worlds with a batch API (SceneWorld) get the
    // entities spawned at once and the Transform / Name columns inserted in one pass each.
    enum batched = __traits(hasMember, W, "spawnBatch") && __traits(hasMember, W, "setBatch");
    static if (batched) {
        result.spawnedEntities = world.spawnBatch(scene.entities.length);
        // Recycled ids come back in reverse. Ascending ids keep file order through a save (sorted by id) and through
        // `collectSubtreeEntities`.
        sortEntityIds(result.spawnedEntities);
        auto transforms = new Transform[scene.entities.length];
        EntityId[] nameIds;
        Name[] names;
    }
    // Ids are assigned up front: components may reference entities that come later in the file.
    foreach (idx, ref e; scene.entities) {
        static if (!batched)
            result.spawnedEntities ~= world.spawn();
        result.fileIdToEntity[e.id] = result.spawnedEntities[idx];
    }
    uint toLive(uint fileId) @safe {
        auto p = fileId in result.fileIdToEntity;
        return p is null ? EntityId.max : *p;
    }

    foreach (idx, ref e; scene.entities) {
        auto id = result.spawnedEntities[idx];

        Transform t;
        t.position = Vec3(e.transform.pos[0], e.transform.pos[1], e.transform.pos[2]);
        if (e.parent == sceneNoParent)
            t.position = t.position + rootOffset;
        t.rotation = Quat(
            e.transform.rot[0], e.transform.rot[1],
            e.transform.rot[2], e.transform.rot[3]);
        t.scale = Vec3(e.transform.scale[0], e.transform.scale[1], e.transform.scale[2]);
        static if (batched)
            transforms[idx] = t;
        else
            world.set(id, t);

        if (e.hasName && e.name >= 0 && e.name < cast(int) scene.strings.length) {
            auto sid = world.strings.intern(scene.strings[e.name]);
            static if (batched) {
                nameIds ~= id;
                names ~= Name(sid);
            } else
                world.set(id, Name(sid));
        }

        StringId assetSid = StringId.init;
        if (e.hasVisual && e.visual.hasAsset
                && e.visual.asset >= 0 && e.visual.asset < cast(int) scene.strings.length) {
            assetSid = world.strings.intern(scene.strings[e.visual.asset]);
        }

        if (e.hasVisual) {
            world.set(id, visualFromData(e.visual, assetSid));
        }

        if (e.hasMaterial) {
            world.set(id, materialFromData(e.material));
        }

        if (e.hasPhysics) {
            auto pb = physicsFromData(e.physics, assetSid);
            enforce(validatePhysicsBody(pb) == PhysicsValidation.ok,
                "entity " ~ toStringy(e.id) ~ ": mesh+dynamic forbidden");
            world.set(id, pb);
        }

        if (e.hasLight) {
            world.set(id, lightFromData(e.light));
        }

        static if (__traits(hasMember, W, "types") && __traits(hasMember, W, "rawAdd")) {
            import engine.reflect.serialize : deserializeComponent;
            import engine.reflect.descriptor : invalidComponentTypeId;
            foreach (ref comp; e.customComponents) {
                auto tid = world.types.find(comp.typeName, world.strings);
                if (tid == invalidComponentTypeId && comp.typeName == "PrefabInstance") {
                    // Engine component: the world registers it on first use, so a freshly started player lacks it.
                    import engine.scene.prefab : PrefabInstance;
                    tid = world.ensureRegistered!PrefabInstance();
                }
                if (tid != invalidComponentTypeId) {
                    auto defs = world.types.getDefaults(tid);
                    world.rawAdd(tid, id, defs);
                    auto slice = world.rawGet(tid, id);
                    deserializeComponent(world.types, tid, comp.data, slice, world.strings, &toLive);
                } else {
                    result.unresolvedComponents ~= UnresolvedComponent(id, comp.typeName);
                }
            }
        } else {
            // No runtime type registry on this world: every custom component is unresolved.
            foreach (ref comp; e.customComponents)
                result.unresolvedComponents ~= UnresolvedComponent(id, comp.typeName);
        }
    }

    static if (batched) {
        world.setBatch(result.spawnedEntities, transforms);
        world.setBatch(nameIds, names);
    }

    // Second pass: parent links (file id 0 = none).
    foreach (ref e; scene.entities) {
        if (e.parent == sceneNoParent)
            continue;
        enforce(e.parent in result.fileIdToEntity,
            "entity " ~ toStringy(e.id) ~ " parent id " ~ toStringy(e.parent) ~ " missing");
        auto id = result.fileIdToEntity[e.id];
        auto parentId = result.fileIdToEntity[e.parent];
        world.set(id, Parent(parentId));
    }

    return result;
}

/// Replace `world` contents with entities from `scene`.
/// Applies `settings` into `lightSettings` (IBL preset).
SceneLoadResult loadSceneIntoWorld(W)(
    ref W world,
    ref SceneFile scene,
    ref SceneLightSettings lightSettings,
    SceneLoadOptions opts = SceneLoadOptions.init
) {
    auto validation = validateScene(scene, opts.checkAssetFiles);
    uint clamped = 0;
    if (opts.clampShadows)
        clamped = clampShadowBudget(scene);

    if (opts.validate && !validation.ok) {
        string msg = "scene validation failed:";
        foreach (ref e; validation.errors)
            msg ~= " [" ~ e.message ~ "]";
        enforce(false, msg);
    }

    static if (__traits(hasMember, W, "clearEntities")) {
        world.clearEntities();
    } else {
        world = W.init;
    }

    lightSettings = SceneLightSettings.init;
    lightSettings.iblPreset = iblPresetFromString(scene.settings.iblPreset);
    if (scene.settings.hasFog) {
        immutable f = scene.settings.fog;
        lightSettings.fog.enabled = f.enabled;
        lightSettings.fog.color = Vec3(f.color[0], f.color[1], f.color[2]);
        lightSettings.fog.density = f.density;
        lightSettings.fog.heightBase = f.heightBase;
        lightSettings.fog.heightFalloff = f.heightFalloff;
        lightSettings.fog.startDistance = f.startDistance;
        lightSettings.fog.maxOpacity = f.maxOpacity;
    }

    SceneLoadOptions innerOpts = opts;
    innerOpts.validate = false;
    innerOpts.clampShadows = false;
    auto result = loadSceneAdditive(world, scene, Vec3(0, 0, 0), innerOpts);
    result.validation = validation;
    result.shadowsClamped = clamped;
    return result;
}

/// Load from a parsed file; returns gravity from settings.
float[3] loadSceneGravity(const ref SceneFile scene) pure nothrow @nogc {
    return scene.settings.gravity;
}

// ---------------------------------------------------------------------------
// Save (world → SceneFile)
// ---------------------------------------------------------------------------

/// Capture the editor world into a `SceneFile` (dense 1-based entity ids).
SceneFile worldToSceneFile(W)(
    ref W world,
    const ref SceneLightSettings lightSettings,
    float[3] gravity = [0, -9.81f, 0],
    SceneMeta meta = SceneMeta.init,
    SceneLoadOptions opts = SceneLoadOptions.init
) {
    SceneFile scene;
    scene.meta = meta;
    if (scene.meta.name.length == 0)
        scene.meta.name = opts.defaultMetaName;
    if (scene.meta.units.length == 0)
        scene.meta.units = opts.defaultUnits;
    scene.settings.gravity = gravity;
    scene.settings.iblPreset = iblPresetToString(lightSettings.iblPreset);
    if (lightSettings.fog.enabled) {
        immutable f = lightSettings.fog;
        scene.settings.hasFog = true;
        scene.settings.fog.enabled = true;
        scene.settings.fog.color = [f.color.x, f.color.y, f.color.z];
        scene.settings.fog.density = f.density;
        scene.settings.fog.heightBase = f.heightBase;
        scene.settings.fog.heightFalloff = f.heightFalloff;
        scene.settings.fog.startDistance = f.startDistance;
        scene.settings.fog.maxOpacity = f.maxOpacity;
    }

    // Collect alive entities sorted by EntityId for stable output.
    EntityId[] ids;
    foreach (id; world.query!(Transform)()) {
        if (world.alive(id))
            ids ~= id;
    }
    // Also entities that might lack Transform but have Light (shouldn't happen).
    foreach (id; world.query!(Light)()) {
        if (!world.alive(id))
            continue;
        bool found;
        foreach (x; ids)
            if (x == id) {
                found = true;
                break;
            }
        if (!found)
            ids ~= id;
    }
    sortEntityIds(ids);

    uint[EntityId] entityToFileId;
    foreach (i, id; ids)
        entityToFileId[id] = cast(uint)(i + 1);
    // `@entityRef` values are saved as file ids (0 = none, or not part of this file).
    uint toFile(uint live) @safe {
        auto p = live in entityToFileId;
        return p is null ? 0 : *p;
    }

    // Build strings table via temporary interning order (first-seen).
    foreach (id; ids) {
        SceneEntityData e;
        e.id = entityToFileId[id];

        if (world.has!Name(id)) {
            auto n = world.get!Name(id);
            if (!n.id.isNull) {
                e.hasName = true;
                e.name = internSceneString(scene, world.strings.get(n.id));
            }
        }

        if (world.has!Parent(id)) {
            immutable p = world.get!Parent(id).entity;
            if (p != noParent && p in entityToFileId)
                e.parent = entityToFileId[p];
            else
                e.parent = sceneNoParent;
        } else {
            e.parent = sceneNoParent;
        }

        if (world.has!Transform(id)) {
            immutable t = world.get!Transform(id);
            e.transform.pos = [t.position.x, t.position.y, t.position.z];
            e.transform.rot = [t.rotation.x, t.rotation.y, t.rotation.z, t.rotation.w];
            e.transform.scale = [t.scale.x, t.scale.y, t.scale.z];
        }

        StringId assetSid = StringId.init;
        if (world.has!Visual(id)) {
            immutable vis = world.get!Visual(id);
            e.hasVisual = true;
            e.visual = visualToData(scene, world.strings, vis);
            assetSid = vis.assetPath;
        }

        if (world.has!MaterialOverride(id)) {
            immutable mat = world.get!MaterialOverride(id);
            if (mat.active) {
                e.hasMaterial = true;
                e.material = materialToData(mat);
            }
        }

        if (world.has!PhysicsBody(id)) {
            immutable pb = world.get!PhysicsBody(id);
            e.hasPhysics = true;
            e.physics = physicsToData(pb);
            if (assetSid.isNull && !pb.assetPath.isNull)
                assetSid = pb.assetPath;
            // Ensure visual.asset is set when physics references an asset.
            if (!assetSid.isNull && e.hasVisual && !e.visual.hasAsset) {
                e.visual.hasAsset = true;
                e.visual.asset = internSceneString(scene, world.strings.get(assetSid));
            }
        }

        if (world.has!Light(id)) {
            e.hasLight = true;
            e.light = lightToData(world.get!Light(id));
        }

        static if (__traits(hasMember, W, "types") && __traits(hasMember, W, "getComponentTypes")) {
            import engine.reflect.serialize : serializeComponent;
            import engine.reflect.descriptor : ComponentTypeId;
            import engine.scene.scene_file : SceneComponentData;
            ComponentTypeId[] ctypes;
            world.getComponentTypes(id, ctypes);
            foreach (tid; ctypes) {
                auto tdesc = world.types.getType(tid);
                string qname = world.strings.get(tdesc.qualifiedName).idup;
                if (qname == "Transform" || qname == "Name" || qname == "Parent" ||
                    qname == "Visual" || qname == "MaterialOverride" || qname == "PhysicsBody" || qname == "Light")
                    continue;

                auto bytes = (cast() world).rawGet(tid, id);
                if (bytes !is null) {
                    auto cjson = serializeComponent(world.types, tid, bytes, world.strings, &toFile);
                    e.customComponents ~= SceneComponentData(qname, cjson);
                }
            }
        }

        scene.entities ~= e;
    }

    return scene;
}

/// Collect `root` and all of its transitive descendants (walking `Parent` links).
/// Returns `[root, ...]` in breadth-first order, or empty if `root` is not alive.
EntityId[] collectSubtreeEntities(W)(ref W world, EntityId root) {
    if (!world.alive(root))
        return null;

    EntityId[] result = [root];
    bool[EntityId] seen;
    seen[root] = true;

    size_t cursor = 0;
    while (cursor < result.length) {
        immutable parentId = result[cursor++];
        EntityId[] children;
        foreach (cid; world.query!(Parent)()) {
            if (!world.alive(cid) || cid in seen)
                continue;
            if (world.get!Parent(cid).entity == parentId) {
                children ~= cid;
            }
        }
        sortEntityIds(children);
        foreach (cid; children) {
            seen[cid] = true;
            result ~= cid;
        }
    }
    return result;
}

/// Capture only the subtree rooted at `root` into a `SceneFile` with dense 1-based IDs.
/// `root` is mapped to ID `1` with `parent = sceneNoParent`, and `rootSpawnOffset` is
/// subtracted from `root`'s position so the exported prefab stays in prefab-local space.
SceneFile subtreeToSceneFile(W)(
    ref W world,
    EntityId root,
    Vec3 rootSpawnOffset = Vec3(0, 0, 0),
    SceneMeta meta = SceneMeta.init,
    SceneLoadOptions opts = SceneLoadOptions.init
) {
    SceneFile scene;
    scene.meta = meta;
    if (scene.meta.name.length == 0)
        scene.meta.name = opts.defaultMetaName;
    if (scene.meta.units.length == 0)
        scene.meta.units = opts.defaultUnits;

    auto ids = collectSubtreeEntities(world, root);
    if (ids.length == 0)
        return scene;

    uint[EntityId] entityToFileId;
    foreach (i, id; ids)
        entityToFileId[id] = cast(uint)(i + 1);
    // `@entityRef` values are saved as file ids (0 = none, or not part of this file).
    uint toFile(uint live) @safe {
        auto p = live in entityToFileId;
        return p is null ? 0 : *p;
    }

    foreach (i, id; ids) {
        SceneEntityData e;
        e.id = entityToFileId[id];

        if (world.has!Name(id)) {
            auto n = world.get!Name(id);
            if (!n.id.isNull) {
                e.hasName = true;
                e.name = internSceneString(scene, world.strings.get(n.id));
            }
        }

        if (i == 0) {
            e.parent = sceneNoParent;
        } else if (world.has!Parent(id)) {
            immutable p = world.get!Parent(id).entity;
            e.parent = (p != noParent && p in entityToFileId) ? entityToFileId[p] : sceneNoParent;
        } else {
            e.parent = sceneNoParent;
        }

        if (world.has!Transform(id)) {
            auto t = world.get!Transform(id);
            if (i == 0)
                t.position = t.position - rootSpawnOffset;
            e.transform.pos = [t.position.x, t.position.y, t.position.z];
            e.transform.rot = [t.rotation.x, t.rotation.y, t.rotation.z, t.rotation.w];
            e.transform.scale = [t.scale.x, t.scale.y, t.scale.z];
        }

        StringId assetSid = StringId.init;
        if (world.has!Visual(id)) {
            immutable vis = world.get!Visual(id);
            e.hasVisual = true;
            e.visual = visualToData(scene, world.strings, vis);
            assetSid = vis.assetPath;
        }

        if (world.has!MaterialOverride(id)) {
            immutable mat = world.get!MaterialOverride(id);
            if (mat.active) {
                e.hasMaterial = true;
                e.material = materialToData(mat);
            }
        }

        if (world.has!PhysicsBody(id)) {
            immutable pb = world.get!PhysicsBody(id);
            e.hasPhysics = true;
            e.physics = physicsToData(pb);
            if (assetSid.isNull && !pb.assetPath.isNull)
                assetSid = pb.assetPath;
            if (!assetSid.isNull && e.hasVisual && !e.visual.hasAsset) {
                e.visual.hasAsset = true;
                e.visual.asset = internSceneString(scene, world.strings.get(assetSid));
            }
        }

        if (world.has!Light(id)) {
            e.hasLight = true;
            e.light = lightToData(world.get!Light(id));
        }

        static if (__traits(hasMember, W, "types") && __traits(hasMember, W, "getComponentTypes")) {
            import engine.reflect.serialize : serializeComponent;
            import engine.reflect.descriptor : ComponentTypeId;
            import engine.scene.scene_file : SceneComponentData;
            ComponentTypeId[] ctypes;
            world.getComponentTypes(id, ctypes);
            foreach (tid; ctypes) {
                auto tdesc = world.types.getType(tid);
                string qname = world.strings.get(tdesc.qualifiedName).idup;
                if (qname == "Transform" || qname == "Name" || qname == "Parent" ||
                    qname == "Visual" || qname == "MaterialOverride" || qname == "PhysicsBody" ||
                    qname == "Light" || qname == "PrefabInstance")
                    continue;

                auto bytes = (cast() world).rawGet(tid, id);
                if (bytes !is null) {
                    auto cjson = serializeComponent(world.types, tid, bytes, world.strings, &toFile);
                    e.customComponents ~= SceneComponentData(qname, cjson);
                }
            }
        }

        scene.entities ~= e;
    }

    return scene;
}

// ---------------------------------------------------------------------------
// IBL preset string ↔ enum
// ---------------------------------------------------------------------------

string iblPresetToString(IblPreset p) pure nothrow {
    final switch (p) {
        case IblPreset.defaultSky: return "procedural_default";
        case IblPreset.studio:     return "studio";
        case IblPreset.outdoor:    return "outdoor";
        case IblPreset.dusk:       return "dusk";
        case IblPreset.night:      return "night";
    }
}

IblPreset iblPresetFromString(string s) pure nothrow {
    if (s == "studio")
        return IblPreset.studio;
    if (s == "outdoor")
        return IblPreset.outdoor;
    if (s == "dusk")
        return IblPreset.dusk;
    if (s == "night")
        return IblPreset.night;
    // "procedural_default", "defaultSky", unknown → default
    return IblPreset.defaultSky;
}

// ---------------------------------------------------------------------------
// Component converters
// ---------------------------------------------------------------------------

private Visual visualFromData(const ref SceneVisualData d, StringId assetSid) {
    Visual v;
    if (d.hasHalfExtents)
        v.localHalfExtents = Vec3(d.halfExtents[0], d.halfExtents[1], d.halfExtents[2]);

    if (d.hasAsset) {
        v.kind = VisualKind.mesh;
        v.assetPath = assetSid;
        if (!d.hasHalfExtents)
            v.localHalfExtents = defaultHalfExtents(VisualKind.mesh);
        return v;
    }

    if (d.hasKind) {
        v.kind = visualKindFromString(d.kind);
        if (!d.hasHalfExtents)
            v.localHalfExtents = defaultHalfExtents(v.kind);
    }
    return v;
}

private SceneVisualData visualToData(ref SceneFile scene, ref StringTable strings, Visual vis) {
    SceneVisualData d;
    if (!vis.assetPath.isNull) {
        d.hasAsset = true;
        d.asset = internSceneString(scene, strings.get(vis.assetPath));
    }
    d.hasKind = true;
    d.kind = visualKindToString(vis.kind);
    d.hasHalfExtents = true;
    d.halfExtents = [
        vis.localHalfExtents.x, vis.localHalfExtents.y, vis.localHalfExtents.z
    ];
    return d;
}

private VisualKind visualKindFromString(string s) pure nothrow {
    if (s == "sphere")
        return VisualKind.sphere;
    if (s == "plane")
        return VisualKind.plane;
    if (s == "mesh")
        return VisualKind.mesh;
    if (s == "none")
        return VisualKind.none;
    return VisualKind.cube;
}

private string visualKindToString(VisualKind k) pure nothrow {
    final switch (k) {
        case VisualKind.none:   return "none";
        case VisualKind.cube:   return "cube";
        case VisualKind.sphere: return "sphere";
        case VisualKind.plane:  return "plane";
        case VisualKind.mesh:   return "mesh";
    }
}

package(engine) MaterialOverride materialFromData(const ref SceneMaterialData d) {
    MaterialOverride m;
    m.baseColor = d.baseColor;
    m.baseWeight = d.baseWeight;
    m.baseMetalness = d.baseMetalness;
    m.baseDiffuseRoughness = d.baseDiffuseRoughness;
    m.specularWeight = d.specularWeight;
    m.specularRoughness = d.specularRoughness;
    m.specularColor = d.specularColor;
    m.specularIor = d.specularIor;
    m.specularAnisotropy = d.specularAnisotropy;
    m.coatWeight = d.coatWeight;
    m.coatColor = d.coatColor;
    m.coatRoughness = d.coatRoughness;
    m.coatIor = d.coatIor;
    m.coatDarkening = d.coatDarkening;
    m.fuzzWeight = d.fuzzWeight;
    m.fuzzColor = d.fuzzColor;
    m.fuzzRoughness = d.fuzzRoughness;
    m.thinFilmWeight = d.thinFilmWeight;
    m.thinFilmThickness = d.thinFilmThickness;
    m.thinFilmIor = d.thinFilmIor;
    m.emissionColor = d.emissionColor;
    m.emissionLuminance = d.emissionLuminance;
    m.geometryOpacity = d.geometryOpacity;
    m.flags = d.flags;
    m.active = 1;
    return m;
}

package(engine) SceneMaterialData materialToData(MaterialOverride m) {
    SceneMaterialData d;
    d.baseColor = m.baseColor;
    d.baseWeight = m.baseWeight;
    d.baseMetalness = m.baseMetalness;
    d.baseDiffuseRoughness = m.baseDiffuseRoughness;
    d.specularWeight = m.specularWeight;
    d.specularRoughness = m.specularRoughness;
    d.specularColor = m.specularColor;
    d.specularIor = m.specularIor;
    d.specularAnisotropy = m.specularAnisotropy;
    d.coatWeight = m.coatWeight;
    d.coatColor = m.coatColor;
    d.coatRoughness = m.coatRoughness;
    d.coatIor = m.coatIor;
    d.coatDarkening = m.coatDarkening;
    d.fuzzWeight = m.fuzzWeight;
    d.fuzzColor = m.fuzzColor;
    d.fuzzRoughness = m.fuzzRoughness;
    d.thinFilmWeight = m.thinFilmWeight;
    d.thinFilmThickness = m.thinFilmThickness;
    d.thinFilmIor = m.thinFilmIor;
    d.emissionColor = m.emissionColor;
    d.emissionLuminance = m.emissionLuminance;
    d.geometryOpacity = m.geometryOpacity;
    d.flags = m.flags;
    return d;
}

package(engine) PhysicsBody physicsFromData(const ref ScenePhysicsData d, StringId assetSid) {
    PhysicsBody p;
    p.enabled = d.enabled ? 1 : 0;
    p.motion = motionFromString(d.motion);
    p.shape = shapeFromString(d.shape);
    p.friction = d.friction;
    p.restitution = d.restitution;
    p.mass = d.mass;
    p.linearDamping = d.linearDamping;
    p.angularDamping = d.angularDamping;
    p.maxHullVertices = d.maxHullVertices;
    p.assetPath = assetSid;
    return p;
}

package(engine) ScenePhysicsData physicsToData(PhysicsBody p) {
    ScenePhysicsData d;
    d.enabled = p.enabled != 0;
    d.motion = motionToString(p.motion);
    d.shape = shapeToString(p.shape);
    d.friction = p.friction;
    d.restitution = p.restitution;
    d.mass = p.mass;
    d.linearDamping = p.linearDamping;
    d.angularDamping = p.angularDamping;
    d.maxHullVertices = p.maxHullVertices;
    return d;
}

private uint motionFromString(string s) pure nothrow {
    if (s == "dynamic")
        return PhysicsMotion.dynamic_;
    if (s == "kinematic")
        return PhysicsMotion.kinematic;
    return PhysicsMotion.static_;
}

private string motionToString(uint m) pure nothrow {
    if (m == PhysicsMotion.dynamic_)
        return "dynamic";
    if (m == PhysicsMotion.kinematic)
        return "kinematic";
    return "static";
}

private uint shapeFromString(string s) pure nothrow {
    if (s == "convexHull")
        return PhysicsShapeKind.convexHull;
    if (s == "triangleMesh")
        return PhysicsShapeKind.triangleMesh;
    return PhysicsShapeKind.primitive;
}

private string shapeToString(uint s) pure nothrow {
    if (s == PhysicsShapeKind.convexHull)
        return "convexHull";
    if (s == PhysicsShapeKind.triangleMesh)
        return "triangleMesh";
    return "primitive";
}

package(engine) Light lightFromData(const ref SceneLightData d) {
    Light l;
    l.type = lightTypeFromString(d.type);
    l.color = d.color;
    l.intensity = d.intensity;
    l.range = d.range;
    l.innerConeDeg = d.innerConeDeg;
    l.outerConeDeg = d.outerConeDeg;
    l.castShadows = d.castShadows ? 1 : 0;
    return l;
}

package(engine) SceneLightData lightToData(Light l) {
    SceneLightData d;
    d.type = lightTypeToString(l.type);
    d.color = l.color;
    d.intensity = l.intensity;
    d.range = l.range;
    d.innerConeDeg = l.innerConeDeg;
    d.outerConeDeg = l.outerConeDeg;
    d.castShadows = l.castShadows != 0;
    return d;
}

private LightType lightTypeFromString(string s) pure nothrow {
    if (s == "point")
        return LightType.point;
    if (s == "spot")
        return LightType.spot;
    return LightType.directional;
}

private string lightTypeToString(LightType t) pure nothrow {
    final switch (t) {
        case LightType.directional: return "directional";
        case LightType.point:       return "point";
        case LightType.spot:        return "spot";
    }
}

/// Append string to scene table if new; return index.
private int internSceneString(ref SceneFile scene, const(char)[] s) {
    foreach (i, ref existing; scene.strings) {
        if (existing == s)
            return cast(int) i;
    }
    scene.strings ~= s.idup;
    return cast(int)(scene.strings.length - 1);
}

private void sortEntityIds(ref EntityId[] ids) {
    import std.algorithm.sorting : isSorted, sort;
    if (!isSorted(ids))
        sort(ids);
}

private string toStringy(uint v) {
    import std.conv : to;
    return v.to!string;
}

// ---------------------------------------------------------------------------
// Round-trip unittest (EditorWorld)
// ---------------------------------------------------------------------------

@safe unittest {
    import engine.scene.light :
        MAX_DIR_LIGHTS, MAX_DIR_SHADOW_CASTERS, MAX_POINT_LIGHTS,
        MAX_POINT_SHADOW_CASTERS, MAX_SPOT_LIGHTS, MAX_SPOT_SHADOW_CASTERS;
    import engine.scene.scene_file :
        SCENE_MAX_DIR_LIGHTS, SCENE_MAX_DIR_SHADOW_CASTERS, SCENE_MAX_POINT_LIGHTS,
        SCENE_MAX_POINT_SHADOW_CASTERS, SCENE_MAX_SPOT_LIGHTS, SCENE_MAX_SPOT_SHADOW_CASTERS;

    static assert(SCENE_MAX_DIR_LIGHTS == MAX_DIR_LIGHTS);
    static assert(SCENE_MAX_POINT_LIGHTS == MAX_POINT_LIGHTS);
    static assert(SCENE_MAX_SPOT_LIGHTS == MAX_SPOT_LIGHTS);
    static assert(SCENE_MAX_DIR_SHADOW_CASTERS == MAX_DIR_SHADOW_CASTERS);
    static assert(SCENE_MAX_POINT_SHADOW_CASTERS == MAX_POINT_SHADOW_CASTERS);
    static assert(SCENE_MAX_SPOT_SHADOW_CASTERS == MAX_SPOT_SHADOW_CASTERS);
}

@safe unittest {
    import engine.scene.scene_file : parseSceneJson, sceneToMinifiedJson;

    EditorWorld world;
    SceneLightSettings lights;
    lights.iblPreset = IblPreset.studio;

    // Crate mesh + physics
    {
        auto id = world.spawn();
        Transform t;
        t.position = Vec3(0, 1, 0);
        t.rotation = Quat(0, 0.5f, 0, 0.8660254f);
        world.set(id, t);
        world.set(id, Name(world.strings.intern("Crate")));
        Visual vis;
        vis.kind = VisualKind.mesh;
        vis.assetPath = world.strings.intern("assets/models/crate.asset.json");
        world.set(id, vis);
        PhysicsBody pb;
        pb.enabled = 1;
        pb.motion = PhysicsMotion.static_;
        pb.shape = PhysicsShapeKind.triangleMesh;
        pb.friction = 0.5f;
        pb.restitution = 0.1f;
        pb.assetPath = vis.assetPath;
        world.set(id, pb);
    }
    // Point light with shadows
    {
        auto id = world.spawn();
        Transform t;
        t.position = Vec3(0, 5, 0);
        world.set(id, t);
        world.set(id, Name(world.strings.intern("Lamp")));
        Light light;
        light.type = LightType.point;
        light.color = [1, 0.9f, 0.8f];
        light.intensity = 40;
        light.range = 12;
        light.castShadows = 1;
        world.set(id, light);
    }

    auto scene = worldToSceneFile(world, lights, [0, -9.81f, 0], SceneMeta("arena_01", "meters"));
    assert(scene.entities.length == 2);
    assert(scene.settings.iblPreset == "studio");

    // Find mesh entity
    SceneEntityData meshE, lightE;
    foreach (ref e; scene.entities) {
        if (e.hasVisual)
            meshE = e;
        if (e.hasLight)
            lightE = e;
    }
    assert(meshE.hasVisual && meshE.visual.hasAsset);
    assert(scene.strings[meshE.visual.asset] == "assets/models/crate.asset.json");
    assert(meshE.hasPhysics && meshE.physics.shape == "triangleMesh");
    assert(meshE.transform.rot[1] == 0.5f);
    assert(lightE.hasLight && lightE.light.castShadows);
    assert(lightE.light.type == "point");

    // Round-trip through JSON
    auto scene2 = parseSceneJson(sceneToMinifiedJson(scene));
    EditorWorld world2;
    SceneLightSettings lights2;
    auto opts = SceneLoadOptions.init;
    opts.checkAssetFiles = true; // crate.asset.json exists in repo
    auto loaded = loadSceneIntoWorld(world2, scene2, lights2, opts);
    assert(loaded.validation.ok);
    assert(lights2.iblPreset == IblPreset.studio);
    assert(world2.entityCount == 2);

    // Verify quat + light + asset path restored
    bool foundMesh, foundLight;
    foreach (id; world2.query!(Transform)()) {
        if (world2.has!Visual(id)) {
            foundMesh = true;
            immutable vis = world2.get!Visual(id);
            assert(vis.kind == VisualKind.mesh);
            assert(world2.strings.get(vis.assetPath) == "assets/models/crate.asset.json");
            immutable t = world2.get!Transform(id);
            assert(t.rotation.y == 0.5f);
            assert(world2.has!PhysicsBody(id));
            assert(world2.get!PhysicsBody(id).shape == PhysicsShapeKind.triangleMesh);
            assert(world2.strings.get(world2.get!PhysicsBody(id).assetPath)
                == "assets/models/crate.asset.json");
        }
        if (world2.has!Light(id)) {
            foundLight = true;
            immutable light = world2.get!Light(id);
            assert(light.type == LightType.point);
            assert(light.castShadows != 0);
            assert(light.intensity == 40f);
        }
    }
    assert(foundMesh && foundLight);
}

@safe unittest {
    import engine.ecs.scene_world : SceneWorld;

    static struct Rotator {
        float speed = 90.0f;
        Vec3 axis = Vec3(0, 1, 0);
    }

    SceneWorld world;
    auto e1 = world.spawn();
    world.set(e1, Transform(Vec3(1, 2, 3), Vec3(1, 1, 1), Quat.identity()));
    world.set(e1, Rotator(120.0f, Vec3(1, 0, 0)));

    SceneLightSettings lights;
    auto scene = worldToSceneFile(world, lights);
    assert(scene.entities.length == 1);
    assert(scene.entities[0].customComponents.length == 1);
    assert(scene.entities[0].customComponents[0].typeName == "Rotator");

    // Round-trip into new SceneWorld
    SceneWorld world2;
    world2.ensureRegistered!Rotator();
    SceneLightSettings lights2;
    auto res = loadSceneIntoWorld(world2, scene, lights2);
    assert(world2.entityCount == 1);
    assert(world2.has!Transform(0));
    assert(world2.has!Rotator(0));
    assert(world2.get!Rotator(0).speed == 120.0f);
    assert(world2.get!Rotator(0).axis == Vec3(1, 0, 0));
}

@safe unittest {
    import engine.ecs.scene_world : SceneWorld;
    import engine.editor.components : Camera3D;

    SceneWorld world;
    world.ensureRegistered!Camera3D();
    auto e1 = world.spawn();
    world.set(e1, Transform(Vec3(0, 1.6f, 8), Vec3(1, 1, 1), Quat.identity()));
    Camera3D cam;
    cam.current = 1;
    cam.fovYDeg = 55;
    cam.nearPlane = 0.25f;
    cam.farPlane = 400;
    world.set(e1, cam);

    SceneLightSettings lights;
    auto scene = worldToSceneFile(world, lights);
    assert(scene.entities.length == 1);
    assert(scene.entities[0].customComponents.length == 1);
    assert(scene.entities[0].customComponents[0].typeName == "Camera3D");

    SceneWorld world2;
    world2.ensureRegistered!Camera3D();
    SceneLightSettings lights2;
    cast(void) loadSceneIntoWorld(world2, scene, lights2);
    assert(world2.has!Camera3D(0));
    assert(world2.get!Camera3D(0).current == 1);
    assert(world2.get!Camera3D(0).fovYDeg == 55);
    assert(world2.get!Camera3D(0).nearPlane == 0.25f);
    assert(world2.get!Camera3D(0).farPlane == 400);
}

@("sceneLoad.waterSurface") @safe unittest {
    // WaterSurface survives save -> JSON -> load (enum, float and uint fields).
    import engine.ecs.scene_world : SceneWorld;
    import engine.scene.scene_file : parseSceneJson, sceneToMinifiedJson;
    import engine.water.component : WaterSurface;
    import engine.water.water_body : WaterFeature, WaterStyle;

    SceneWorld world;
    world.ensureRegistered!WaterSurface();
    auto e1 = world.spawn();
    world.set(e1, Transform(Vec3(3, 0.5f, -2), Vec3(1, 1, 1), Quat.identity()));
    WaterSurface ws;
    ws.style = WaterStyle.river;
    ws.halfExtent = 22;
    ws.waveScale = 0.6f;
    ws.causticsScale = 0;
    ws.gridResolution = 128;
    ws.features = WaterFeature.all & ~WaterFeature.ssr;
    world.set(e1, ws);

    SceneLightSettings lights;
    auto json = sceneToMinifiedJson(worldToSceneFile(world, lights));
    auto scene = parseSceneJson(json);

    SceneWorld world2;
    world2.ensureRegistered!WaterSurface();
    SceneLightSettings lights2;
    cast(void) loadSceneIntoWorld(world2, scene, lights2);
    assert(world2.has!WaterSurface(0));
    assert(world2.get!WaterSurface(0) == ws);
}

@("sceneLoad.unresolvedComponents") unittest {
    // "viatura.prop" is not registered in SceneWorld: the entity loads, the component is reported.
    enum json = `{"format":"game-engine.scene","version":1,"meta":{"name":"t","units":"meters"},` ~
        `"strings":["prop"],"settings":{"gravity":[0,-9.81,0],"iblPreset":"procedural_default"},` ~
        `"entities":[{"id":1,"name":0,"parent":0,` ~
        `"transform":{"pos":[1,2,3],"rot":[0,0,0,1],"scale":[1,1,1]},` ~
        `"components":{"viatura.prop":{"kind":"crate"}}}]}`;
    import engine.scene.scene_file : parseSceneJson;
    auto scene = parseSceneJson(json);
    EditorWorld world;
    SceneLightSettings lights;
    auto res = loadSceneIntoWorld(world, scene, lights);
    assert(res.validation.ok);
    assert(world.entityCount == 1);
    assert(res.unresolvedComponents.length == 1);
    assert(res.unresolvedComponents[0].typeName == "viatura.prop");
    assert(res.unresolvedComponents[0].entity == res.fileIdToEntity[1]);
}

@("sceneLoad.additiveAndSubtree") @safe unittest {
    import engine.ecs.scene_world : SceneWorld;

    SceneWorld world;

    SceneFile s1;
    s1.meta.name = "chunk_a";
    SceneEntityData e1;
    e1.id = 1;
    e1.hasName = true;
    e1.name = 0;
    s1.strings = ["RootA"];
    e1.transform.pos = [1, 0, 0];
    s1.entities ~= e1;

    auto r1 = loadSceneAdditive(world, s1, Vec3(10, 0, 0));
    assert(r1.spawnedEntities.length == 1);
    assert(world.entityCount() == 1);
    immutable rootA = r1.fileIdToEntity[1];
    assert(world.get!Transform(rootA).position == Vec3(11, 0, 0));

    SceneFile s2;
    s2.meta.name = "chunk_b";
    s2.strings = ["RootB", "ChildB"];
    SceneEntityData b1;
    b1.id = 1;
    b1.hasName = true;
    b1.name = 0;
    b1.transform.pos = [0, 2, 0];
    SceneEntityData b2;
    b2.id = 2;
    b2.parent = 1;
    b2.hasName = true;
    b2.name = 1;
    b2.transform.pos = [0, 1, 0];
    s2.entities ~= b1;
    s2.entities ~= b2;

    auto r2 = loadSceneAdditive(world, s2, Vec3(100, 0, 0));
    assert(r2.spawnedEntities.length == 2);
    assert(world.entityCount() == 3);
    immutable rootB = r2.fileIdToEntity[1];
    immutable childB = r2.fileIdToEntity[2];
    assert(world.get!Transform(rootB).position == Vec3(100, 2, 0));
    assert(world.get!Transform(childB).position == Vec3(0, 1, 0));
    assert(world.get!Parent(childB).entity == rootB);
    assert(world.alive(rootA));

    // Subtree export must contain only RootB + ChildB, excluding RootA.
    auto sub = subtreeToSceneFile(world, rootB, Vec3(100, 0, 0));
    assert(sub.entities.length == 2);
    assert(sub.entities[0].id == 1 && sub.entities[0].parent == sceneNoParent);
    assert(sub.entities[0].transform.pos == [0.0f, 2.0f, 0.0f]);
    assert(sub.entities[1].id == 2 && sub.entities[1].parent == 1);
}

@("scene load: entity refs are file-local, failures leave no entities, PrefabInstance survives a fresh world")
unittest {
    import engine.ecs.scene_world : SceneWorld;
    import engine.project.asset_ref : AssetGuid;
    import engine.reflect.attrs : component, entityRef;
    import engine.scene.prefab : PrefabInstance;
    import std.exception : assertThrown;

    @component static struct Follow { @entityRef uint target = uint.max; @entityRef uint other = uint.max; }

    SceneWorld w;
    SceneLightSettings ls;
    auto hole = w.spawn();
    auto a = w.spawn();
    auto b = w.spawn();
    w.destroy(hole);
    foreach (id; [a, b]) w.set(id, Transform.init);
    w.set(a, Follow(b, uint.max)); // forward reference
    w.set(b, Follow(a, hole));     // `hole` is dead
    auto guid = AssetGuid.generate();
    w.set(b, PrefabInstance(guid, 1, Vec3(1, 2, 3)));

    auto file = worldToSceneFile(w, ls);
    SceneWorld w2;
    w2.ensureRegistered!Follow();
    auto shift = w2.spawn(); // live ids differ from the first world's
    auto res = loadSceneAdditive(w2, file);
    auto a2 = res.spawnedEntities[0], b2 = res.spawnedEntities[1];
    assert(w2.get!Follow(a2) == Follow(b2, uint.max));
    assert(w2.get!Follow(b2) == Follow(a2, uint.max));
    assert(w2.get!PrefabInstance(b2).prefabGuid == guid);
    assert(w2.get!PrefabInstance(b2).spawnOffset == Vec3(1, 2, 3));

    // A missing parent fails the load and leaves the world as it was.
    file.entities[1].parent = 77;
    assertThrown(loadSceneAdditive(w2, file));
    assert(w2.entityCount() == 3);

    // Recycled ids still follow file order.
    w2.destroy(a2);
    w2.destroy(b2);
    file.entities[1].parent = sceneNoParent;
    auto again = loadSceneAdditive(w2, file);
    assert(again.spawnedEntities[0] < again.spawnedEntities[1]);
}
