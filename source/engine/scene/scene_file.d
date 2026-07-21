/// `game-engine.scene` v1 — minified JSON reader/writer for level scenes.
///
/// Disk format holds entities (transforms as quat `[x,y,z,w]`), light/physics
/// components, a shared `strings` table, and scene settings (gravity / IBL).
/// Geometry lives in `*.asset.json`; the scene only stores string-table refs.
/// GC is allowed (assets/scene layer).
module engine.scene.scene_file;

import std.algorithm : canFind;
import std.array : appender, Appender;
import std.conv : to;
import std.exception : enforce;
import std.file : exists, readText, write;
import std.format : formattedWrite;
import std.json;
import std.math : isNaN;
import std.string : strip;

@safe:

enum string sceneFormatId = "game-engine.scene";
enum int sceneSchemaVersion = 1;

/// Parent / name sentinel in the file: `0` means none (entity ids are 1-based).
enum uint sceneNoParent = 0;
enum int sceneNoString = -1;

/// Light / shadow budgets — must stay in sync with `engine.scene.light`.
enum uint SCENE_MAX_DIR_LIGHTS = 1;
enum uint SCENE_MAX_POINT_LIGHTS = 8;
enum uint SCENE_MAX_SPOT_LIGHTS = 4;
enum uint SCENE_MAX_DIR_SHADOW_CASTERS = 1;
enum uint SCENE_MAX_POINT_SHADOW_CASTERS = 4;
enum uint SCENE_MAX_SPOT_SHADOW_CASTERS = 2;

// ---------------------------------------------------------------------------
// Data model
// ---------------------------------------------------------------------------

struct SceneMeta {
    string name;
    string units = "meters";
}

struct SceneSettingsData {
    float[3] gravity = [0, -9.81f, 0];
    string iblPreset = "procedural_default";
}

struct SceneTransformData {
    float[3] pos = [0, 0, 0];
    float[4] rot = [0, 0, 0, 1]; /// Quaternion `[x,y,z,w]`
    float[3] scale = [1, 1, 1];
}

struct SceneVisualData {
    bool hasAsset;
    int asset = sceneNoString; /// Index into `SceneFile.strings`
    bool hasKind;
    string kind; /// `"cube"` / `"sphere"` / `"plane"` / `"mesh"`
    bool hasHalfExtents;
    float[3] halfExtents = [0.5f, 0.5f, 0.5f];
}

struct SceneMaterialData {
    float[4] baseColor = [1, 1, 1, 1];
    float metallic = 0;
    float roughness = 0.5f;
    uint flags = 0;
}

struct ScenePhysicsData {
    bool enabled = true;
    string motion = "static"; /// static | dynamic | kinematic
    string shape = "primitive"; /// primitive | convexHull | triangleMesh
    float friction = 0.5f;
    float restitution = 0;
    float mass = 1;
    float linearDamping = 0;
    float angularDamping = 0;
    uint maxHullVertices = 64;
}

struct SceneLightData {
    string type = "directional"; /// directional | point | spot
    float[3] color = [1, 1, 1];
    float intensity = 1;
    float range = 10;
    float innerConeDeg = 15;
    float outerConeDeg = 25;
    bool castShadows = false;
}

struct SceneEntityData {
    uint id;
    bool hasName;
    int name = sceneNoString; /// Index into `strings`
    uint parent = sceneNoParent;
    SceneTransformData transform;
    bool hasVisual;
    SceneVisualData visual;
    bool hasMaterial;
    SceneMaterialData material;
    bool hasPhysics;
    ScenePhysicsData physics;
    bool hasLight;
    SceneLightData light;
}

/// Parsed `*.scene.json` (game-engine.scene v1).
struct SceneFile {
    SceneMeta meta;
    string[] strings;
    SceneSettingsData settings;
    SceneEntityData[] entities;
}

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------

enum SceneValidationCode : uint {
    ok = 0,
    tooManyDirLights = 1,
    tooManyPointLights = 2,
    tooManySpotLights = 3,
    meshDynamicForbidden = 4,
    missingAsset = 5,
    badStringIndex = 6,
    shadowBudgetExceeded = 7,
    duplicateEntityId = 8,
}

struct SceneValidationIssue {
    SceneValidationCode code;
    string message;
    uint entityId;
}

struct SceneValidationResult {
    SceneValidationIssue[] errors;
    SceneValidationIssue[] warnings;

    bool ok() const pure nothrow @nogc {
        return errors.length == 0;
    }
}

/// Validate light UBO limits, mesh+dynamic, string indices, missing assets,
/// and shadow-caster budget (budget overflow → warning).
SceneValidationResult validateScene(const ref SceneFile scene, bool checkAssetFiles = true) {
    SceneValidationResult result;
    uint dir, point, spot;
    uint dirSh, pointSh, spotSh;
    bool[uint] seenIds;

    foreach (ref e; scene.entities) {
        if (e.id in seenIds) {
            result.errors ~= SceneValidationIssue(
                SceneValidationCode.duplicateEntityId,
                "duplicate entity id " ~ e.id.to!string,
                e.id);
        }
        seenIds[e.id] = true;

        if (e.hasName)
            checkStringIndex(scene, e.name, e.id, "name", result);
        if (e.parent != sceneNoParent) {
            // Parent must exist (checked after loop would be ideal; soft-check index).
        }

        if (e.hasVisual) {
            if (e.visual.hasAsset)
                checkStringIndex(scene, e.visual.asset, e.id, "visual.asset", result);
            if (e.visual.hasAsset && checkAssetFiles && e.visual.asset >= 0
                    && e.visual.asset < cast(int) scene.strings.length) {
                immutable path = scene.strings[e.visual.asset];
                if (path.length && !exists(path)) {
                    result.errors ~= SceneValidationIssue(
                        SceneValidationCode.missingAsset,
                        "missing asset '" ~ path ~ "'",
                        e.id);
                }
            }
        }

        if (e.hasPhysics) {
            immutable meshDyn = e.physics.shape == "triangleMesh"
                && e.physics.motion == "dynamic";
            if (meshDyn) {
                result.errors ~= SceneValidationIssue(
                    SceneValidationCode.meshDynamicForbidden,
                    "triangleMesh + dynamic is forbidden",
                    e.id);
            }
        }

        if (e.hasLight) {
            immutable t = e.light.type;
            if (t == "directional") {
                dir++;
                if (e.light.castShadows)
                    dirSh++;
            } else if (t == "point") {
                point++;
                if (e.light.castShadows)
                    pointSh++;
            } else if (t == "spot") {
                spot++;
                if (e.light.castShadows)
                    spotSh++;
            }
        }
    }

    if (dir > SCENE_MAX_DIR_LIGHTS) {
        result.errors ~= SceneValidationIssue(
            SceneValidationCode.tooManyDirLights,
            "directional lights " ~ dir.to!string ~ " exceed MAX_DIR_LIGHTS="
                ~ SCENE_MAX_DIR_LIGHTS.to!string,
            0);
    }
    if (point > SCENE_MAX_POINT_LIGHTS) {
        result.errors ~= SceneValidationIssue(
            SceneValidationCode.tooManyPointLights,
            "point lights " ~ point.to!string ~ " exceed MAX_POINT_LIGHTS="
                ~ SCENE_MAX_POINT_LIGHTS.to!string,
            0);
    }
    if (spot > SCENE_MAX_SPOT_LIGHTS) {
        result.errors ~= SceneValidationIssue(
            SceneValidationCode.tooManySpotLights,
            "spot lights " ~ spot.to!string ~ " exceed MAX_SPOT_LIGHTS="
                ~ SCENE_MAX_SPOT_LIGHTS.to!string,
            0);
    }

    if (dirSh > SCENE_MAX_DIR_SHADOW_CASTERS || pointSh > SCENE_MAX_POINT_SHADOW_CASTERS
            || spotSh > SCENE_MAX_SPOT_SHADOW_CASTERS) {
        result.warnings ~= SceneValidationIssue(
            SceneValidationCode.shadowBudgetExceeded,
            "shadow casters exceed budget (dir=" ~ dirSh.to!string
                ~ "/" ~ SCENE_MAX_DIR_SHADOW_CASTERS.to!string
                ~ " point=" ~ pointSh.to!string
                ~ "/" ~ SCENE_MAX_POINT_SHADOW_CASTERS.to!string
                ~ " spot=" ~ spotSh.to!string
                ~ "/" ~ SCENE_MAX_SPOT_SHADOW_CASTERS.to!string ~ ")",
            0);
    }

    return result;
}

/// Clamp excess `castShadows` flags so the scene fits the shadow budget.
/// Returns the number of lights that had shadows disabled.
uint clampShadowBudget(ref SceneFile scene) {
    uint dirSh, pointSh, spotSh;
    uint clamped;
    foreach (ref e; scene.entities) {
        if (!e.hasLight || !e.light.castShadows)
            continue;
        immutable t = e.light.type;
        if (t == "directional") {
            if (dirSh >= SCENE_MAX_DIR_SHADOW_CASTERS) {
                e.light.castShadows = false;
                clamped++;
            } else
                dirSh++;
        } else if (t == "point") {
            if (pointSh >= SCENE_MAX_POINT_SHADOW_CASTERS) {
                e.light.castShadows = false;
                clamped++;
            } else
                pointSh++;
        } else if (t == "spot") {
            if (spotSh >= SCENE_MAX_SPOT_SHADOW_CASTERS) {
                e.light.castShadows = false;
                clamped++;
            } else
                spotSh++;
        }
    }
    return clamped;
}

private void checkStringIndex(
    const ref SceneFile scene,
    int idx,
    uint entityId,
    string field,
    ref SceneValidationResult result
) {
    if (idx < 0 || idx >= cast(int) scene.strings.length) {
        result.errors ~= SceneValidationIssue(
            SceneValidationCode.badStringIndex,
            field ~ " string index " ~ idx.to!string ~ " out of range",
            entityId);
    }
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Read and parse a `*.scene.json` from disk.
SceneFile loadSceneFile(string path) {
    return parseSceneJson(readText(path));
}

/// Parse scene JSON text (minified or spaced).
SceneFile parseSceneJson(string text) {
    auto root = parseJSON(text.strip());
    enforce(root.type == JSONType.object, "scene root must be a JSON object");
    requireOnlyKeys(root, [
        "format", "version", "meta", "strings", "settings", "entities"
    ], "scene root");

    enforce("format" in root, "scene missing 'format'");
    enforce(root["format"].type == JSONType.string, "scene 'format' must be string");
    enforce(root["format"].str == sceneFormatId,
        "unsupported scene format '" ~ root["format"].str ~ "' (expected " ~ sceneFormatId ~ ")");

    enforce("version" in root, "scene missing 'version'");
    immutable ver = jsonInt(root["version"], "version");
    enforce(ver >= 1, "scene version must be >= 1");

    SceneFile scene;
    scene = parseSceneBody(root);
    return migrateScene(scene, ver);
}

/// Write minified JSON with stable key order to disk.
void saveSceneFile(string path, const ref SceneFile scene) {
    write(path, sceneToMinifiedJson(scene));
}

/// Serialize to minified JSON; key order is deterministic.
string sceneToMinifiedJson(const SceneFile scene) {
    auto app = appender!string();
    writeScene(app, scene);
    return app.data;
}

/// Version migration chain stub. Currently only v1 is accepted.
SceneFile migrateScene(SceneFile scene, int fromVersion) {
    enforce(fromVersion == sceneSchemaVersion,
        "unsupported scene version " ~ fromVersion.to!string
            ~ " (only " ~ sceneSchemaVersion.to!string ~ " implemented; migrate_vN stub)");
    return scene;
}

/// Alias kept for plan wording (`migrate_vN`).
alias migrate_vN = migrateScene;

/// Golden + validation checks (also invoked from `dub run --config=test-scene`).
void runSceneFileGoldenTests() {
    enum golden =
        `{"format":"game-engine.scene","version":1,`
        ~ `"meta":{"name":"arena_01","units":"meters"},`
        ~ `"strings":["Sun","assets/models/crate.asset.json","Lamp"],`
        ~ `"settings":{"gravity":[0,-9.81,0],"iblPreset":"procedural_default"},`
        ~ `"entities":[`
        ~ `{"id":1,"name":0,"parent":0,`
        ~ `"transform":{"pos":[0,1,0],"rot":[0,0,0,1],"scale":[1,1,1]},`
        ~ `"visual":{"asset":1},`
        ~ `"physics":{"enabled":true,"motion":"static","shape":"triangleMesh",`
        ~ `"friction":0.5,"restitution":0.1,"mass":1,"linearDamping":0,`
        ~ `"angularDamping":0,"maxHullVertices":64}},`
        ~ `{"id":2,"name":2,"parent":0,`
        ~ `"transform":{"pos":[0,5,0],"rot":[0,0,0,1],"scale":[1,1,1]},`
        ~ `"light":{"type":"point","color":[1,0.9,0.8],"intensity":40,`
        ~ `"range":12,"innerConeDeg":15,"outerConeDeg":25,"castShadows":true}}`
        ~ `]}`;

    auto a = parseSceneJson(golden);
    assert(a.meta.name == "arena_01");
    assert(a.meta.units == "meters");
    assert(a.strings.length == 3);
    assert(a.strings[1] == "assets/models/crate.asset.json");
    assert(a.settings.gravity[1] == -9.81f);
    assert(a.settings.iblPreset == "procedural_default");
    assert(a.entities.length == 2);

    assert(a.entities[0].id == 1);
    assert(a.entities[0].hasName && a.entities[0].name == 0);
    assert(a.entities[0].hasVisual && a.entities[0].visual.hasAsset);
    assert(a.entities[0].visual.asset == 1);
    assert(a.entities[0].hasPhysics);
    assert(a.entities[0].physics.shape == "triangleMesh");
    assert(a.entities[0].transform.rot == cast(float[4])[0f, 0f, 0f, 1f]);

    assert(a.entities[1].id == 2);
    assert(a.entities[1].hasLight);
    assert(a.entities[1].light.type == "point");
    assert(a.entities[1].light.castShadows);
    assert(a.entities[1].light.intensity == 40f);

    immutable written = sceneToMinifiedJson(a);
    assert(written == golden, "minified write must match golden exactly");
    assert(sceneToMinifiedJson(parseSceneJson(written)) == golden);

    // Quat `[x,y,z,w]` survives parse → write → parse (value equality).
    {
        auto qScene = a;
        qScene.entities[1].transform.rot = [0.0f, 0.5f, 0.0f, 0.8660254f];
        auto q2 = parseSceneJson(sceneToMinifiedJson(qScene));
        assert(q2.entities[1].transform.rot[1] == 0.5f);
        assert(q2.entities[1].transform.rot[3] > 0.86f && q2.entities[1].transform.rot[3] < 0.87f);
    }

    // Unknown field → error.
    bool threw;
    try {
        parseSceneJson(`{"format":"game-engine.scene","version":1,`
            ~ `"meta":{"name":"x","units":"meters"},"strings":[],`
            ~ `"settings":{"gravity":[0,-9.81,0],"iblPreset":"procedural_default"},`
            ~ `"entities":[],"extra":1}`);
    } catch (Exception) {
        threw = true;
    }
    assert(threw, "unknown root field must error");

    // Validation: mesh+dynamic
    {
        auto bad = a;
        bad.entities[0].physics.motion = "dynamic";
        auto v = validateScene(bad, false);
        assert(!v.ok);
        assert(v.errors.canFind!(i => i.code == SceneValidationCode.meshDynamicForbidden));
    }

    // Validation: light UBO overflow
    {
        SceneFile over;
        over.meta.name = "x";
        over.settings = SceneSettingsData.init;
        foreach (i; 0 .. SCENE_MAX_POINT_LIGHTS + 1) {
            SceneEntityData e;
            e.id = cast(uint)(i + 1);
            e.hasLight = true;
            e.light.type = "point";
            over.entities ~= e;
        }
        auto v = validateScene(over, false);
        assert(!v.ok);
        assert(v.errors.canFind!(i => i.code == SceneValidationCode.tooManyPointLights));
    }

    // Shadow budget → warning + clamp
    {
        SceneFile sh;
        sh.meta.name = "x";
        foreach (i; 0 .. SCENE_MAX_POINT_SHADOW_CASTERS + 2) {
            SceneEntityData e;
            e.id = cast(uint)(i + 1);
            e.hasLight = true;
            e.light.type = "point";
            e.light.castShadows = true;
            sh.entities ~= e;
        }
        auto v = validateScene(sh, false);
        assert(v.ok);
        assert(v.warnings.canFind!(i => i.code == SceneValidationCode.shadowBudgetExceeded));
        immutable n = clampShadowBudget(sh);
        assert(n == 2);
        uint still;
        foreach (ref e; sh.entities)
            if (e.hasLight && e.light.castShadows)
                still++;
        assert(still == SCENE_MAX_POINT_SHADOW_CASTERS);
    }

    // Missing asset
    {
        SceneFile miss;
        miss.meta.name = "x";
        miss.strings = ["no/such/asset.asset.json"];
        SceneEntityData e;
        e.id = 1;
        e.hasVisual = true;
        e.visual.hasAsset = true;
        e.visual.asset = 0;
        miss.entities ~= e;
        auto v = validateScene(miss, true);
        assert(!v.ok);
        assert(v.errors.canFind!(i => i.code == SceneValidationCode.missingAsset));
    }
}

@safe unittest {
    runSceneFileGoldenTests();
}

// ---------------------------------------------------------------------------
// Parse
// ---------------------------------------------------------------------------

private SceneFile parseSceneBody(ref JSONValue root) {
    SceneFile s;

    enforce("meta" in root, "scene missing 'meta'");
    s.meta = parseMeta(root["meta"]);

    enforce("strings" in root, "scene missing 'strings'");
    s.strings = parseStrings(root["strings"]);

    enforce("settings" in root, "scene missing 'settings'");
    s.settings = parseSettings(root["settings"]);

    enforce("entities" in root, "scene missing 'entities'");
    s.entities = parseEntities(root["entities"]);

    return s;
}

private SceneMeta parseMeta(ref JSONValue v) {
    enforce(v.type == JSONType.object, "'meta' must be object");
    requireOnlyKeys(v, ["name", "units"], "meta");
    enforce("name" in v && v["name"].type == JSONType.string, "meta.name must be string");
    enforce("units" in v && v["units"].type == JSONType.string, "meta.units must be string");
    return SceneMeta(v["name"].str, v["units"].str);
}

private string[] parseStrings(ref JSONValue v) {
    enforce(v.type == JSONType.array, "'strings' must be array");
    string[] out_;
    foreach (ref s; jsonArray(v)) {
        enforce(s.type == JSONType.string, "strings[] must be string");
        out_ ~= s.str;
    }
    return out_;
}

private SceneSettingsData parseSettings(ref JSONValue v) {
    enforce(v.type == JSONType.object, "'settings' must be object");
    requireOnlyKeys(v, ["gravity", "iblPreset"], "settings");
    enforce("gravity" in v, "settings missing 'gravity'");
    enforce("iblPreset" in v && v["iblPreset"].type == JSONType.string,
        "settings.iblPreset must be string");
    SceneSettingsData s;
    s.gravity = jsonFloat3(v["gravity"], "settings.gravity");
    s.iblPreset = v["iblPreset"].str;
    return s;
}

private SceneEntityData[] parseEntities(ref JSONValue v) {
    enforce(v.type == JSONType.array, "'entities' must be array");
    SceneEntityData[] out_;
    foreach (ref e; jsonArray(v))
        out_ ~= parseEntity(e);
    return out_;
}

private SceneEntityData parseEntity(ref JSONValue v) {
    enforce(v.type == JSONType.object, "entities[] must be object");
    requireOnlyKeys(v, [
        "id", "name", "parent", "transform", "visual", "material", "physics", "light"
    ], "entities[]");

    enforce("id" in v, "entities[] missing 'id'");
    enforce("parent" in v, "entities[] missing 'parent'");
    enforce("transform" in v, "entities[] missing 'transform'");

    SceneEntityData e;
    e.id = cast(uint) jsonInt(v["id"], "entities[].id");
    e.parent = cast(uint) jsonInt(v["parent"], "entities[].parent");
    e.transform = parseTransform(v["transform"]);

    if ("name" in v) {
        e.hasName = true;
        e.name = jsonInt(v["name"], "entities[].name");
    }
    if ("visual" in v) {
        e.hasVisual = true;
        e.visual = parseVisual(v["visual"]);
    }
    if ("material" in v) {
        e.hasMaterial = true;
        e.material = parseMaterial(v["material"]);
    }
    if ("physics" in v) {
        e.hasPhysics = true;
        e.physics = parsePhysics(v["physics"]);
    }
    if ("light" in v) {
        e.hasLight = true;
        e.light = parseLight(v["light"]);
    }
    return e;
}

private SceneTransformData parseTransform(ref JSONValue v) {
    enforce(v.type == JSONType.object, "transform must be object");
    requireOnlyKeys(v, ["pos", "rot", "scale"], "transform");
    enforce("pos" in v && "rot" in v && "scale" in v, "transform missing pos/rot/scale");
    SceneTransformData t;
    t.pos = jsonFloat3(v["pos"], "transform.pos");
    t.rot = jsonFloat4(v["rot"], "transform.rot");
    t.scale = jsonFloat3(v["scale"], "transform.scale");
    return t;
}

private SceneVisualData parseVisual(ref JSONValue v) {
    enforce(v.type == JSONType.object, "visual must be object");
    requireOnlyKeys(v, ["asset", "kind", "halfExtents"], "visual");
    SceneVisualData vis;
    if ("asset" in v) {
        vis.hasAsset = true;
        vis.asset = jsonInt(v["asset"], "visual.asset");
    }
    if ("kind" in v) {
        enforce(v["kind"].type == JSONType.string, "visual.kind must be string");
        vis.hasKind = true;
        vis.kind = v["kind"].str;
    }
    if ("halfExtents" in v) {
        vis.hasHalfExtents = true;
        vis.halfExtents = jsonFloat3(v["halfExtents"], "visual.halfExtents");
    }
    enforce(vis.hasAsset || vis.hasKind, "visual requires 'asset' and/or 'kind'");
    return vis;
}

private SceneMaterialData parseMaterial(ref JSONValue v) {
    enforce(v.type == JSONType.object, "material must be object");
    requireOnlyKeys(v, ["baseColor", "metallic", "roughness", "flags"], "material");
    SceneMaterialData m;
    m.baseColor = jsonFloat4(v["baseColor"], "material.baseColor");
    m.metallic = jsonFloat(v["metallic"], "material.metallic");
    m.roughness = jsonFloat(v["roughness"], "material.roughness");
    m.flags = cast(uint) jsonInt(v["flags"], "material.flags");
    return m;
}

private ScenePhysicsData parsePhysics(ref JSONValue v) {
    enforce(v.type == JSONType.object, "physics must be object");
    requireOnlyKeys(v, [
        "enabled", "motion", "shape", "friction", "restitution",
        "mass", "linearDamping", "angularDamping", "maxHullVertices"
    ], "physics");
    ScenePhysicsData p;
    enforce("enabled" in v, "physics missing 'enabled'");
    p.enabled = jsonBool(v["enabled"], "physics.enabled");
    enforce("motion" in v && v["motion"].type == JSONType.string, "physics.motion must be string");
    p.motion = v["motion"].str;
    enforce("shape" in v && v["shape"].type == JSONType.string, "physics.shape must be string");
    p.shape = v["shape"].str;
    p.friction = jsonFloat(v["friction"], "physics.friction");
    p.restitution = jsonFloat(v["restitution"], "physics.restitution");
    p.mass = jsonFloat(v["mass"], "physics.mass");
    p.linearDamping = jsonFloat(v["linearDamping"], "physics.linearDamping");
    p.angularDamping = jsonFloat(v["angularDamping"], "physics.angularDamping");
    p.maxHullVertices = cast(uint) jsonInt(v["maxHullVertices"], "physics.maxHullVertices");
    return p;
}

private SceneLightData parseLight(ref JSONValue v) {
    enforce(v.type == JSONType.object, "light must be object");
    requireOnlyKeys(v, [
        "type", "color", "intensity", "range", "innerConeDeg", "outerConeDeg", "castShadows"
    ], "light");
    SceneLightData l;
    enforce("type" in v && v["type"].type == JSONType.string, "light.type must be string");
    l.type = v["type"].str;
    l.color = jsonFloat3(v["color"], "light.color");
    l.intensity = jsonFloat(v["intensity"], "light.intensity");
    l.range = jsonFloat(v["range"], "light.range");
    l.innerConeDeg = jsonFloat(v["innerConeDeg"], "light.innerConeDeg");
    l.outerConeDeg = jsonFloat(v["outerConeDeg"], "light.outerConeDeg");
    l.castShadows = jsonBool(v["castShadows"], "light.castShadows");
    return l;
}

// ---------------------------------------------------------------------------
// Write (minified, stable key order)
// ---------------------------------------------------------------------------

private void writeScene(ref Appender!string app, const ref SceneFile s) {
    app.put(`{"format":"`);
    app.put(sceneFormatId);
    app.put(`","version":`);
    app.formattedWrite("%d", sceneSchemaVersion);
    app.put(`,"meta":{"name":`);
    writeJsonString(app, s.meta.name);
    app.put(`,"units":`);
    writeJsonString(app, s.meta.units);
    app.put(`},"strings":[`);
    foreach (i, ref str; s.strings) {
        if (i)
            app.put(',');
        writeJsonString(app, str);
    }
    app.put(`],"settings":{"gravity":[`);
    writeFloat(app, s.settings.gravity[0]);
    app.put(',');
    writeFloat(app, s.settings.gravity[1]);
    app.put(',');
    writeFloat(app, s.settings.gravity[2]);
    app.put(`],"iblPreset":`);
    writeJsonString(app, s.settings.iblPreset);
    app.put(`},"entities":[`);
    foreach (i, ref e; s.entities) {
        if (i)
            app.put(',');
        writeEntity(app, e);
    }
    app.put(`]}`);
}

private void writeEntity(ref Appender!string app, const ref SceneEntityData e) {
    app.put(`{"id":`);
    app.formattedWrite("%d", e.id);
    if (e.hasName) {
        app.put(`,"name":`);
        app.formattedWrite("%d", e.name);
    }
    app.put(`,"parent":`);
    app.formattedWrite("%d", e.parent);
    app.put(`,"transform":{"pos":[`);
    writeFloat(app, e.transform.pos[0]);
    app.put(',');
    writeFloat(app, e.transform.pos[1]);
    app.put(',');
    writeFloat(app, e.transform.pos[2]);
    app.put(`],"rot":[`);
    writeFloat(app, e.transform.rot[0]);
    app.put(',');
    writeFloat(app, e.transform.rot[1]);
    app.put(',');
    writeFloat(app, e.transform.rot[2]);
    app.put(',');
    writeFloat(app, e.transform.rot[3]);
    app.put(`],"scale":[`);
    writeFloat(app, e.transform.scale[0]);
    app.put(',');
    writeFloat(app, e.transform.scale[1]);
    app.put(',');
    writeFloat(app, e.transform.scale[2]);
    app.put(`]}`);
    if (e.hasVisual) {
        app.put(`,"visual":`);
        writeVisual(app, e.visual);
    }
    if (e.hasMaterial) {
        app.put(`,"material":{"baseColor":[`);
        writeFloat(app, e.material.baseColor[0]);
        app.put(',');
        writeFloat(app, e.material.baseColor[1]);
        app.put(',');
        writeFloat(app, e.material.baseColor[2]);
        app.put(',');
        writeFloat(app, e.material.baseColor[3]);
        app.put(`],"metallic":`);
        writeFloat(app, e.material.metallic);
        app.put(`,"roughness":`);
        writeFloat(app, e.material.roughness);
        app.put(`,"flags":`);
        app.formattedWrite("%d", e.material.flags);
        app.put('}');
    }
    if (e.hasPhysics) {
        app.put(`,"physics":{"enabled":`);
        app.put(e.physics.enabled ? "true" : "false");
        app.put(`,"motion":`);
        writeJsonString(app, e.physics.motion);
        app.put(`,"shape":`);
        writeJsonString(app, e.physics.shape);
        app.put(`,"friction":`);
        writeFloat(app, e.physics.friction);
        app.put(`,"restitution":`);
        writeFloat(app, e.physics.restitution);
        app.put(`,"mass":`);
        writeFloat(app, e.physics.mass);
        app.put(`,"linearDamping":`);
        writeFloat(app, e.physics.linearDamping);
        app.put(`,"angularDamping":`);
        writeFloat(app, e.physics.angularDamping);
        app.put(`,"maxHullVertices":`);
        app.formattedWrite("%d", e.physics.maxHullVertices);
        app.put('}');
    }
    if (e.hasLight) {
        app.put(`,"light":{"type":`);
        writeJsonString(app, e.light.type);
        app.put(`,"color":[`);
        writeFloat(app, e.light.color[0]);
        app.put(',');
        writeFloat(app, e.light.color[1]);
        app.put(',');
        writeFloat(app, e.light.color[2]);
        app.put(`],"intensity":`);
        writeFloat(app, e.light.intensity);
        app.put(`,"range":`);
        writeFloat(app, e.light.range);
        app.put(`,"innerConeDeg":`);
        writeFloat(app, e.light.innerConeDeg);
        app.put(`,"outerConeDeg":`);
        writeFloat(app, e.light.outerConeDeg);
        app.put(`,"castShadows":`);
        app.put(e.light.castShadows ? "true" : "false");
        app.put('}');
    }
    app.put('}');
}

private void writeVisual(ref Appender!string app, const ref SceneVisualData vis) {
    app.put('{');
    bool first = true;
    if (vis.hasAsset) {
        first = false;
        app.put(`"asset":`);
        app.formattedWrite("%d", vis.asset);
    }
    if (vis.hasKind) {
        if (!first)
            app.put(',');
        first = false;
        app.put(`"kind":`);
        writeJsonString(app, vis.kind);
    }
    if (vis.hasHalfExtents) {
        if (!first)
            app.put(',');
        app.put(`"halfExtents":[`);
        writeFloat(app, vis.halfExtents[0]);
        app.put(',');
        writeFloat(app, vis.halfExtents[1]);
        app.put(',');
        writeFloat(app, vis.halfExtents[2]);
        app.put(']');
    }
    app.put('}');
}

private void writeJsonString(ref Appender!string app, string s) {
    app.put('"');
    foreach (dchar ch; s) {
        switch (ch) {
        case '"':
            app.put(`\"`);
            break;
        case '\\':
            app.put(`\\`);
            break;
        case '\b':
            app.put(`\b`);
            break;
        case '\f':
            app.put(`\f`);
            break;
        case '\n':
            app.put(`\n`);
            break;
        case '\r':
            app.put(`\r`);
            break;
        case '\t':
            app.put(`\t`);
            break;
        default:
            if (ch < 0x20)
                app.formattedWrite("\\u%04x", cast(uint) ch);
            else
                app.put(ch);
        }
    }
    app.put('"');
}

/// Compact float: integer form when exact, else `%g`.
private void writeFloat(ref Appender!string app, float f) {
    enforce(!isNaN(f), "cannot serialize NaN in scene JSON");
    immutable asInt = cast(int) f;
    if (f == asInt && f >= -2_147_483_648f && f <= 2_147_483_647f) {
        app.formattedWrite("%d", asInt);
    } else {
        app.formattedWrite("%g", f);
    }
}

// ---------------------------------------------------------------------------
// JSON helpers
// ---------------------------------------------------------------------------

private void requireOnlyKeys(ref JSONValue obj, const(string)[] allowed, string ctx) {
    enforce(obj.type == JSONType.object, ctx ~ " must be object");
    foreach (k; jsonObjectKeys(obj)) {
        enforce(allowed.canFind(k), "unknown field '" ~ k ~ "' in " ~ ctx);
    }
}

private string[] jsonObjectKeys(ref JSONValue obj) @trusted {
    string[] keys;
    foreach (k; obj.object.byKey)
        keys ~= k;
    return keys;
}

private JSONValue[] jsonArray(ref JSONValue v) @trusted {
    return v.array;
}

private int jsonInt(ref JSONValue v, string ctx) {
    if (v.type == JSONType.integer)
        return cast(int) v.integer;
    if (v.type == JSONType.uinteger)
        return cast(int) v.uinteger;
    if (v.type == JSONType.float_) {
        immutable f = v.floating;
        enforce(f == cast(int) f, ctx ~ " must be an integer");
        return cast(int) f;
    }
    enforce(false, ctx ~ " must be an integer");
    return 0;
}

private bool jsonBool(ref JSONValue v, string ctx) {
    enforce(v.type == JSONType.true_ || v.type == JSONType.false_, ctx ~ " must be boolean");
    return v.type == JSONType.true_;
}

private float jsonFloat(ref JSONValue v, string ctx) {
    if (v.type == JSONType.float_)
        return cast(float) v.floating;
    if (v.type == JSONType.integer)
        return cast(float) v.integer;
    if (v.type == JSONType.uinteger)
        return cast(float) v.uinteger;
    enforce(false, ctx ~ " must be a number");
    return 0;
}

private float[3] jsonFloat3(ref JSONValue v, string ctx) {
    auto arr = jsonArray(v);
    enforce(v.type == JSONType.array && arr.length == 3, ctx ~ " must be [x,y,z]");
    float[3] out_;
    out_[0] = jsonFloat(arr[0], ctx);
    out_[1] = jsonFloat(arr[1], ctx);
    out_[2] = jsonFloat(arr[2], ctx);
    return out_;
}

private float[4] jsonFloat4(ref JSONValue v, string ctx) {
    auto arr = jsonArray(v);
    enforce(v.type == JSONType.array && arr.length == 4, ctx ~ " must be [x,y,z,w] or [r,g,b,a]");
    float[4] out_;
    out_[0] = jsonFloat(arr[0], ctx);
    out_[1] = jsonFloat(arr[1], ctx);
    out_[2] = jsonFloat(arr[2], ctx);
    out_[3] = jsonFloat(arr[3], ctx);
    return out_;
}
