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
struct SceneLoadResult {
    /// File entity id → live `EntityId`.
    EntityId[uint] fileIdToEntity;
    SceneValidationResult validation;
    /// How many `castShadows` flags were cleared to fit the shadow budget.
    uint shadowsClamped;
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

/// Replace `world` contents with entities from `scene`.
/// Applies `settings` into `lightSettings` (IBL preset).
SceneLoadResult loadSceneIntoWorld(
    ref EditorWorld world,
    ref SceneFile scene,
    ref SceneLightSettings lightSettings,
    SceneLoadOptions opts = SceneLoadOptions.init
) {
    SceneLoadResult result;
    result.validation = validateScene(scene, opts.checkAssetFiles);
    if (opts.clampShadows)
        result.shadowsClamped = clampShadowBudget(scene);

    if (opts.validate && !result.validation.ok) {
        string msg = "scene validation failed:";
        foreach (ref e; result.validation.errors)
            msg ~= " [" ~ e.message ~ "]";
        enforce(false, msg);
    }

    world = EditorWorld.init;

    lightSettings = SceneLightSettings.init;
    lightSettings.iblPreset = iblPresetFromString(scene.settings.iblPreset);

    // First pass: spawn entities + components (parents deferred).
    foreach (ref e; scene.entities) {
        auto id = world.spawn();
        result.fileIdToEntity[e.id] = id;

        Transform t;
        t.position = Vec3(e.transform.pos[0], e.transform.pos[1], e.transform.pos[2]);
        t.rotation = Quat(
            e.transform.rot[0], e.transform.rot[1],
            e.transform.rot[2], e.transform.rot[3]);
        t.scale = Vec3(e.transform.scale[0], e.transform.scale[1], e.transform.scale[2]);
        world.set(id, t);

        if (e.hasName && e.name >= 0 && e.name < cast(int) scene.strings.length) {
            auto sid = world.strings.intern(scene.strings[e.name]);
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

/// Load from a parsed file; returns gravity from settings.
float[3] loadSceneGravity(const ref SceneFile scene) pure nothrow @nogc {
    return scene.settings.gravity;
}

// ---------------------------------------------------------------------------
// Save (world → SceneFile)
// ---------------------------------------------------------------------------

/// Capture the editor world into a `SceneFile` (dense 1-based entity ids).
SceneFile worldToSceneFile(
    ref EditorWorld world,
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

private MaterialOverride materialFromData(const ref SceneMaterialData d) {
    MaterialOverride m;
    m.baseColor = d.baseColor;
    m.metallic = d.metallic;
    m.roughness = d.roughness;
    m.flags = d.flags;
    m.active = 1;
    return m;
}

private SceneMaterialData materialToData(MaterialOverride m) {
    SceneMaterialData d;
    d.baseColor = m.baseColor;
    d.metallic = m.metallic;
    d.roughness = m.roughness;
    d.flags = m.flags;
    return d;
}

private PhysicsBody physicsFromData(const ref ScenePhysicsData d, StringId assetSid) {
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

private ScenePhysicsData physicsToData(PhysicsBody p) {
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

private Light lightFromData(const ref SceneLightData d) {
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

private SceneLightData lightToData(Light l) {
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
    // Simple insertion sort (N is small in editor scenes).
    foreach (i; 1 .. ids.length) {
        immutable key = ids[i];
        sizediff_t j = cast(sizediff_t) i - 1;
        while (j >= 0 && ids[j] > key) {
            ids[j + 1] = ids[j];
            j--;
        }
        ids[j + 1] = key;
    }
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
