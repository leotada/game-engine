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
import std.math : floor, isNaN;
import std.string : strip;

@safe:

enum string sceneFormatId = "game-engine.scene";
enum int sceneSchemaVersion = 1;
enum int sceneSchemaVersionV2 = 2;

/// Parent / name sentinel in the file: `0` means none (entity ids are 1-based).
enum uint sceneNoParent = 0;
enum int sceneNoString = -1;

/// Light / shadow budgets — must stay in sync with `engine.scene.light`.
enum uint SCENE_MAX_DIR_LIGHTS = 1;
enum uint SCENE_MAX_POINT_LIGHTS = 32;
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
    /// Optional `settings.fog` object (written only when `hasFog`).
    bool hasFog = false;
    SceneFogData fog;
}

/// Atmospheric fog stored in `settings.fog` (see `engine.scene.atmosphere.FogSettings`).
struct SceneFogData {
    bool enabled = true;
    float[3] color = [0.62f, 0.72f, 0.84f];
    float density = 0.002f;
    float heightBase = 0;
    float heightFalloff = 0.02f;
    float startDistance = 0;
    float maxOpacity = 1;
}

struct SceneTransformData {
    float[3] pos = [0, 0, 0];
    float[4] rot = [0, 0, 0, 1]; /// Quaternion `[x,y,z,w]`
    float[3] scale = [1, 1, 1];
}

struct SceneVisualData {
    bool hasAsset;
    int asset = sceneNoString; /// Index into `SceneFile.strings`
    bool hasAssetGuid;
    string assetGuid; /// Optional v2 32-char hex AssetGuid
    bool hasKind;
    string kind; /// `"cube"` / `"sphere"` / `"plane"` / `"mesh"`
    bool hasHalfExtents;
    float[3] halfExtents = [0.5f, 0.5f, 0.5f];
}

struct SceneMaterialData {
    float[3] baseColor = [1.0f, 1.0f, 1.0f];
    float    baseWeight = 1.0f;
    float    baseMetalness = 0.0f;
    float    baseDiffuseRoughness = 0.0f;
    float    specularWeight = 1.0f;
    float    specularRoughness = 0.5f;
    float[3] specularColor = [1.0f, 1.0f, 1.0f];
    float    specularIor = 1.5f;
    float    specularAnisotropy = 0.0f;
    float    coatWeight = 0.0f;
    float[3] coatColor = [1.0f, 1.0f, 1.0f];
    float    coatRoughness = 0.1f;
    float    coatIor = 1.6f;
    float    coatDarkening = 1.0f;
    float    fuzzWeight = 0.0f;
    float[3] fuzzColor = [1.0f, 1.0f, 1.0f];
    float    fuzzRoughness = 0.5f;
    float    thinFilmWeight = 0.0f;
    float    thinFilmThickness = 500.0f;
    float    thinFilmIor = 1.4f;
    float[3] emissionColor = [1.0f, 1.0f, 1.0f];
    float    emissionLuminance = 0.0f;
    float    geometryOpacity = 1.0f;
    float    anisotropyRotation = 0.0f;
    float    thinFilmThicknessMin = 300.0f;
    float[3] transmissionColor = [1.0f, 1.0f, 1.0f];
    float    transmissionWeight = 0.0f;
    float    transmissionDepth = 0.0f;
    float    transmissionDispersion = 0.0f;
    float    transmissionThickness = 0.0f;
    uint     flags = 0;
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

struct SceneComponentData {
    string typeName;
    JSONValue data;
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
    /// Arbitrary / script components for SceneWorld and v2 scene files.
    SceneComponentData[] customComponents;
}

/// Spatial AABB bounds for a v2 scene or streamed chunk cell.
struct SceneCellBounds {
    float[3] min = [0, 0, 0];
    float[3] max = [0, 0, 0];
}

/// Persistent asset reference in a v2 scene (`AssetGuid` + `strings[]` path index).
struct SceneAssetLink {
    string guid;
    int path = sceneNoString;
    string kind = "model"; /// `"model"` | `"texture"` | `"navmesh"` | `"prefab"`
}

/// Descriptor for one streamed world chunk in `ChunkManifest`.
struct SceneChunkDescriptor {
    int coordX = 0;
    int coordZ = 0;
    SceneCellBounds bounds;
    string scenePath;
    string navmeshPath;
}

/// World streaming manifest embedded in v2 root scenes.
struct ChunkManifest {
    float cellSize = 256.0f;
    float loadRadius = 512.0f;
    float unloadRadius = 640.0f;
    SceneChunkDescriptor[] chunks;
}

/// Parsed `*.scene.json` (game-engine.scene v1 / v2).
struct SceneFile {
    int schemaVersion = sceneSchemaVersion;
    SceneMeta meta;
    string[] strings;
    SceneSettingsData settings;
    SceneEntityData[] entities;
    /// Optional v2 fields:
    bool hasCellBounds = false;
    SceneCellBounds cellBounds;
    SceneAssetLink[] assetLinks;
    bool hasChunkManifest = false;
    ChunkManifest chunkManifest;
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

    immutable bool perChunkLights = scene.schemaVersion >= sceneSchemaVersionV2
        || scene.hasChunkManifest || scene.hasCellBounds;
    if (perChunkLights) {
        immutable float cellSize = (scene.hasChunkManifest && scene.chunkManifest.cellSize > 0.0f)
            ? scene.chunkManifest.cellSize : 256.0f;
        uint[ulong] pointPerCell;
        uint[ulong] spotPerCell;
        foreach (ref e; scene.entities) {
            if (!e.hasLight) continue;
            immutable int cx = cast(int) floor(e.transform.pos[0] / cellSize);
            immutable int cz = cast(int) floor(e.transform.pos[2] / cellSize);
            immutable ulong cellKey = (cast(ulong) cast(uint) cx << 32) | cast(ulong) cast(uint) cz;
            if (e.light.type == "point") {
                pointPerCell[cellKey] = (cellKey in pointPerCell ? pointPerCell[cellKey] : 0) + 1;
            } else if (e.light.type == "spot") {
                spotPerCell[cellKey] = (cellKey in spotPerCell ? spotPerCell[cellKey] : 0) + 1;
            }
        }
        foreach (k, cnt; pointPerCell) {
            if (cnt > SCENE_MAX_POINT_LIGHTS) {
                result.errors ~= SceneValidationIssue(
                    SceneValidationCode.tooManyPointLights,
                    "chunk point lights " ~ cnt.to!string ~ " exceed MAX_POINT_LIGHTS="
                        ~ SCENE_MAX_POINT_LIGHTS.to!string,
                    0);
                break;
            }
        }
        foreach (k, cnt; spotPerCell) {
            if (cnt > SCENE_MAX_SPOT_LIGHTS) {
                result.errors ~= SceneValidationIssue(
                    SceneValidationCode.tooManySpotLights,
                    "chunk spot lights " ~ cnt.to!string ~ " exceed MAX_SPOT_LIGHTS="
                        ~ SCENE_MAX_SPOT_LIGHTS.to!string,
                    0);
                break;
            }
        }
    } else {
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
        "format", "version", "meta", "strings", "settings", "entities",
        "cellBounds", "assetLinks", "chunks"
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
    scene.schemaVersion = ver;
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

/// Version migration chain: accepts v1 and v2 scenes.
SceneFile migrateScene(SceneFile scene, int fromVersion) {
    enforce(fromVersion >= sceneSchemaVersion && fromVersion <= sceneSchemaVersionV2,
        "unsupported scene version " ~ fromVersion.to!string
            ~ " (supported " ~ sceneSchemaVersion.to!string ~ ".."
            ~ sceneSchemaVersionV2.to!string ~ ")");
    scene.schemaVersion = fromVersion;
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

    // OpenPBR material round-trip
    {
        SceneFile opbr;
        opbr.meta.name = "opbr_test";
        SceneEntityData e;
        e.id = 1;
        e.hasMaterial = true;
        e.material.baseColor = [0.2f, 0.4f, 0.8f];
        e.material.baseMetalness = 0.75f;
        e.material.specularRoughness = 0.25f;
        e.material.specularIor = 1.7f;
        e.material.coatWeight = 0.9f;
        e.material.coatRoughness = 0.05f;
        e.material.fuzzWeight = 0.6f;
        e.material.thinFilmWeight = 0.5f;
        e.material.thinFilmThicknessMin = 150.0f;
        e.material.anisotropyRotation = 0.25f;
        e.material.transmissionWeight = 0.85f;
        e.material.transmissionColor = [0.3f, 0.9f, 0.75f];
        e.material.transmissionDepth = 2.0f;
        e.material.transmissionDispersion = 0.5f;
        e.material.transmissionThickness = 0.8f;
        opbr.entities ~= e;
        immutable json = sceneToMinifiedJson(opbr);
        auto parsed = parseSceneJson(json);
        assert(parsed.entities.length == 1 && parsed.entities[0].hasMaterial);
        assert(parsed.entities[0].material.specularIor == 1.7f);
        assert(parsed.entities[0].material.coatWeight == 0.9f);
        assert(parsed.entities[0].material.fuzzWeight == 0.6f);
        assert(parsed.entities[0].material.thinFilmWeight == 0.5f);
        assert(parsed.entities[0].material.thinFilmThicknessMin == 150.0f);
        assert(parsed.entities[0].material.anisotropyRotation == 0.25f);
        assert(parsed.entities[0].material.transmissionWeight == 0.85f);
        assert(parsed.entities[0].material.transmissionColor[1] == 0.9f);
        assert(parsed.entities[0].material.transmissionDepth == 2.0f);
        assert(parsed.entities[0].material.transmissionDispersion == 0.5f);
        assert(parsed.entities[0].material.transmissionThickness == 0.8f);
        assert(sceneToMinifiedJson(parsed) == json);
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

    if ("cellBounds" in root) {
        s.hasCellBounds = true;
        s.cellBounds = parseCellBounds(root["cellBounds"]);
    }
    if ("assetLinks" in root) {
        s.assetLinks = parseAssetLinks(root["assetLinks"]);
    }
    if ("chunks" in root) {
        s.hasChunkManifest = true;
        s.chunkManifest = parseChunkManifest(root["chunks"]);
    }

    return s;
}

private SceneCellBounds parseCellBounds(ref JSONValue v) {
    enforce(v.type == JSONType.object, "cellBounds must be object");
    requireOnlyKeys(v, ["min", "max"], "cellBounds");
    enforce("min" in v && "max" in v, "cellBounds missing min/max");
    SceneCellBounds b;
    b.min = jsonFloat3(v["min"], "cellBounds.min");
    b.max = jsonFloat3(v["max"], "cellBounds.max");
    return b;
}

private SceneAssetLink[] parseAssetLinks(ref JSONValue v) {
    enforce(v.type == JSONType.array, "assetLinks must be array");
    SceneAssetLink[] out_;
    foreach (ref item; jsonArray(v)) {
        enforce(item.type == JSONType.object, "assetLinks[] must be object");
        requireOnlyKeys(item, ["guid", "path", "kind"], "assetLinks[]");
        enforce("guid" in item && item["guid"].type == JSONType.string, "assetLinks[].guid must be string");
        SceneAssetLink link;
        link.guid = item["guid"].str;
        if ("path" in item)
            link.path = jsonInt(item["path"], "assetLinks[].path");
        if ("kind" in item) {
            enforce(item["kind"].type == JSONType.string, "assetLinks[].kind must be string");
            link.kind = item["kind"].str;
        }
        out_ ~= link;
    }
    return out_;
}

private ChunkManifest parseChunkManifest(ref JSONValue v) {
    enforce(v.type == JSONType.object, "chunks must be object");
    requireOnlyKeys(v, ["cellSize", "loadRadius", "unloadRadius", "items"], "chunks");
    ChunkManifest m;
    if ("cellSize" in v) m.cellSize = jsonFloat(v["cellSize"], "chunks.cellSize");
    if ("loadRadius" in v) m.loadRadius = jsonFloat(v["loadRadius"], "chunks.loadRadius");
    if ("unloadRadius" in v) m.unloadRadius = jsonFloat(v["unloadRadius"], "chunks.unloadRadius");
    if ("items" in v) {
        enforce(v["items"].type == JSONType.array, "chunks.items must be array");
        foreach (ref item; jsonArray(v["items"])) {
            enforce(item.type == JSONType.object, "chunks.items[] must be object");
            requireOnlyKeys(item, ["coord", "bounds", "scenePath", "navmeshPath"], "chunks.items[]");
            SceneChunkDescriptor d;
            if ("coord" in item) {
                auto arr = jsonArray(item["coord"]);
                enforce(item["coord"].type == JSONType.array && arr.length == 2,
                    "chunks.items[].coord must be [x,z]");
                d.coordX = jsonInt(arr[0], "chunks.items[].coord[0]");
                d.coordZ = jsonInt(arr[1], "chunks.items[].coord[1]");
            }
            if ("bounds" in item) {
                d.bounds = parseCellBounds(item["bounds"]);
            }
            if ("scenePath" in item) {
                enforce(item["scenePath"].type == JSONType.string, "chunks.items[].scenePath must be string");
                d.scenePath = item["scenePath"].str;
            }
            if ("navmeshPath" in item) {
                enforce(item["navmeshPath"].type == JSONType.string, "chunks.items[].navmeshPath must be string");
                d.navmeshPath = item["navmeshPath"].str;
            }
            m.chunks ~= d;
        }
    }
    return m;
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
    requireOnlyKeys(v, ["gravity", "iblPreset", "fog"], "settings");
    enforce("gravity" in v, "settings missing 'gravity'");
    enforce("iblPreset" in v && v["iblPreset"].type == JSONType.string,
        "settings.iblPreset must be string");
    SceneSettingsData s;
    s.gravity = jsonFloat3(v["gravity"], "settings.gravity");
    s.iblPreset = v["iblPreset"].str;
    if (auto f = "fog" in v) {
        enforce(f.type == JSONType.object, "settings.fog must be object");
        requireOnlyKeys(*f, ["enabled", "color", "density", "heightBase", "heightFalloff",
            "startDistance", "maxOpacity"], "settings.fog");
        s.hasFog = true;
        if (auto e = "enabled" in *f) {
            enforce(e.type == JSONType.true_ || e.type == JSONType.false_, "settings.fog.enabled must be bool");
            s.fog.enabled = e.type == JSONType.true_;
        }
        if (auto c = "color" in *f) s.fog.color = jsonFloat3(*c, "settings.fog.color");
        float num(string key, float def) {
            if (auto n = key in *f) return jsonFloat(*n, "settings.fog." ~ key);
            return def;
        }
        s.fog.density = num("density", s.fog.density);
        s.fog.heightBase = num("heightBase", s.fog.heightBase);
        s.fog.heightFalloff = num("heightFalloff", s.fog.heightFalloff);
        s.fog.startDistance = num("startDistance", s.fog.startDistance);
        s.fog.maxOpacity = num("maxOpacity", s.fog.maxOpacity);
    }
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
        "id", "name", "parent", "transform", "visual", "material", "physics", "light", "components"
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
    if ("components" in v) {
        auto cVal = v["components"];
        if (cVal.type == JSONType.object) {
            foreach (typeName, compVal; jsonObject(cVal)) {
                e.customComponents ~= SceneComponentData(typeName, compVal);
            }
        }
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
    requireOnlyKeys(v, ["asset", "assetGuid", "kind", "halfExtents"], "visual");
    SceneVisualData vis;
    if ("asset" in v) {
        vis.hasAsset = true;
        vis.asset = jsonInt(v["asset"], "visual.asset");
    }
    if ("assetGuid" in v) {
        enforce(v["assetGuid"].type == JSONType.string, "visual.assetGuid must be string");
        vis.hasAssetGuid = true;
        vis.assetGuid = v["assetGuid"].str;
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
    enforce(vis.hasAsset || vis.hasAssetGuid || vis.hasKind,
        "visual requires 'asset', 'assetGuid', and/or 'kind'");
    return vis;
}

private SceneMaterialData parseMaterial(ref JSONValue v) {
    enforce(v.type == JSONType.object, "material must be object");
    requireOnlyKeys(v, [
        "baseColor", "baseWeight", "baseMetalness", "baseDiffuseRoughness",
        "specularWeight", "specularRoughness", "specularColor", "specularIor",
        "specularAnisotropy", "anisotropyRotation", "coatWeight", "coatColor", "coatRoughness",
        "coatIor", "coatDarkening", "fuzzWeight", "fuzzColor", "fuzzRoughness",
        "thinFilmWeight", "thinFilmThickness", "thinFilmThicknessMin", "thinFilmIor",
        "transmissionColor", "transmissionWeight", "transmissionDepth",
        "transmissionDispersion", "transmissionThickness",
        "emissionColor", "emissionLuminance", "geometryOpacity",
        "flags"
    ], "material");
    SceneMaterialData m;
    m.baseColor = jsonFloat3(v["baseColor"], "material.baseColor");
    m.baseMetalness = jsonFloat(v["baseMetalness"], "material.baseMetalness");
    m.specularRoughness = jsonFloat(v["specularRoughness"], "material.specularRoughness");
    m.flags = cast(uint) jsonInt(v["flags"], "material.flags");
    if ("baseWeight" in v) m.baseWeight = jsonFloat(v["baseWeight"], "material.baseWeight");
    if ("baseDiffuseRoughness" in v) m.baseDiffuseRoughness = jsonFloat(v["baseDiffuseRoughness"], "material.baseDiffuseRoughness");
    if ("specularWeight" in v) m.specularWeight = jsonFloat(v["specularWeight"], "material.specularWeight");
    if ("specularColor" in v) m.specularColor = jsonFloat3(v["specularColor"], "material.specularColor");
    if ("specularIor" in v) m.specularIor = jsonFloat(v["specularIor"], "material.specularIor");
    if ("specularAnisotropy" in v) m.specularAnisotropy = jsonFloat(v["specularAnisotropy"], "material.specularAnisotropy");
    if ("coatWeight" in v) m.coatWeight = jsonFloat(v["coatWeight"], "material.coatWeight");
    if ("coatColor" in v) m.coatColor = jsonFloat3(v["coatColor"], "material.coatColor");
    if ("coatRoughness" in v) m.coatRoughness = jsonFloat(v["coatRoughness"], "material.coatRoughness");
    if ("coatIor" in v) m.coatIor = jsonFloat(v["coatIor"], "material.coatIor");
    if ("coatDarkening" in v) m.coatDarkening = jsonFloat(v["coatDarkening"], "material.coatDarkening");
    if ("fuzzWeight" in v) m.fuzzWeight = jsonFloat(v["fuzzWeight"], "material.fuzzWeight");
    if ("fuzzColor" in v) m.fuzzColor = jsonFloat3(v["fuzzColor"], "material.fuzzColor");
    if ("fuzzRoughness" in v) m.fuzzRoughness = jsonFloat(v["fuzzRoughness"], "material.fuzzRoughness");
    if ("thinFilmWeight" in v) m.thinFilmWeight = jsonFloat(v["thinFilmWeight"], "material.thinFilmWeight");
    if ("thinFilmThickness" in v) m.thinFilmThickness = jsonFloat(v["thinFilmThickness"], "material.thinFilmThickness");
    if ("thinFilmThicknessMin" in v) m.thinFilmThicknessMin = jsonFloat(v["thinFilmThicknessMin"], "material.thinFilmThicknessMin");
    if ("thinFilmIor" in v) m.thinFilmIor = jsonFloat(v["thinFilmIor"], "material.thinFilmIor");
    if ("anisotropyRotation" in v) m.anisotropyRotation = jsonFloat(v["anisotropyRotation"], "material.anisotropyRotation");
    if ("transmissionColor" in v) m.transmissionColor = jsonFloat3(v["transmissionColor"], "material.transmissionColor");
    if ("transmissionWeight" in v) m.transmissionWeight = jsonFloat(v["transmissionWeight"], "material.transmissionWeight");
    if ("transmissionDepth" in v) m.transmissionDepth = jsonFloat(v["transmissionDepth"], "material.transmissionDepth");
    if ("transmissionDispersion" in v) m.transmissionDispersion = jsonFloat(v["transmissionDispersion"], "material.transmissionDispersion");
    if ("transmissionThickness" in v) m.transmissionThickness = jsonFloat(v["transmissionThickness"], "material.transmissionThickness");
    if ("emissionColor" in v) m.emissionColor = jsonFloat3(v["emissionColor"], "material.emissionColor");
    if ("emissionLuminance" in v) m.emissionLuminance = jsonFloat(v["emissionLuminance"], "material.emissionLuminance");
    if ("geometryOpacity" in v) m.geometryOpacity = jsonFloat(v["geometryOpacity"], "material.geometryOpacity");
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

private bool isV2Scene(const ref SceneFile s) pure nothrow @nogc {
    if (s.schemaVersion >= sceneSchemaVersionV2 || s.hasCellBounds ||
        s.assetLinks.length > 0 || s.hasChunkManifest) {
        return true;
    }
    foreach (ref e; s.entities) {
        if (e.hasVisual && e.visual.hasAssetGuid)
            return true;
    }
    return false;
}

private void writeScene(ref Appender!string app, const ref SceneFile s) {
    immutable int outVersion = isV2Scene(s) ? sceneSchemaVersionV2 : sceneSchemaVersion;
    app.put(`{"format":"`);
    app.put(sceneFormatId);
    app.put(`","version":`);
    app.formattedWrite("%d", outVersion);
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
    if (s.settings.hasFog) {
        immutable f = s.settings.fog;
        app.put(f.enabled ? `,"fog":{"enabled":true,"color":[` : `,"fog":{"enabled":false,"color":[`);
        writeFloat(app, f.color[0]); app.put(',');
        writeFloat(app, f.color[1]); app.put(',');
        writeFloat(app, f.color[2]);
        app.put(`],"density":`); writeFloat(app, f.density);
        app.put(`,"heightBase":`); writeFloat(app, f.heightBase);
        app.put(`,"heightFalloff":`); writeFloat(app, f.heightFalloff);
        app.put(`,"startDistance":`); writeFloat(app, f.startDistance);
        app.put(`,"maxOpacity":`); writeFloat(app, f.maxOpacity);
        app.put('}');
    }
    app.put(`},"entities":[`);
    foreach (i, ref e; s.entities) {
        if (i)
            app.put(',');
        writeEntity(app, e);
    }
    app.put(']');
    if (s.hasCellBounds) {
        app.put(`,"cellBounds":{"min":`);
        writeFloat3(app, s.cellBounds.min);
        app.put(`,"max":`);
        writeFloat3(app, s.cellBounds.max);
        app.put('}');
    }
    if (s.assetLinks.length > 0) {
        app.put(`,"assetLinks":[`);
        foreach (i, ref link; s.assetLinks) {
            if (i) app.put(',');
            app.put(`{"guid":`);
            writeJsonString(app, link.guid);
            app.put(`,"path":`);
            app.formattedWrite("%d", link.path);
            app.put(`,"kind":`);
            writeJsonString(app, link.kind);
            app.put('}');
        }
        app.put(']');
    }
    if (s.hasChunkManifest) {
        app.put(`,"chunks":{"cellSize":`);
        writeFloat(app, s.chunkManifest.cellSize);
        app.put(`,"loadRadius":`);
        writeFloat(app, s.chunkManifest.loadRadius);
        app.put(`,"unloadRadius":`);
        writeFloat(app, s.chunkManifest.unloadRadius);
        app.put(`,"items":[`);
        foreach (i, ref ch; s.chunkManifest.chunks) {
            if (i) app.put(',');
            app.put(`{"coord":[`);
            app.formattedWrite("%d,%d", ch.coordX, ch.coordZ);
            app.put(`],"bounds":{"min":`);
            writeFloat3(app, ch.bounds.min);
            app.put(`,"max":`);
            writeFloat3(app, ch.bounds.max);
            app.put(`},"scenePath":`);
            writeJsonString(app, ch.scenePath);
            if (ch.navmeshPath.length > 0) {
                app.put(`,"navmeshPath":`);
                writeJsonString(app, ch.navmeshPath);
            }
            app.put('}');
        }
        app.put(`]}`);
    }
    app.put('}');
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
        auto m = e.material;
        app.put(`,"material":{"baseColor":`);
        writeFloat3(app, m.baseColor);
        app.put(`,"baseMetalness":`);
        writeFloat(app, m.baseMetalness);
        app.put(`,"specularRoughness":`);
        writeFloat(app, m.specularRoughness);
        app.put(`,"flags":`);
        app.formattedWrite("%d", m.flags);
        if (m.baseWeight != 1.0f) { app.put(`,"baseWeight":`); writeFloat(app, m.baseWeight); }
        if (m.baseDiffuseRoughness != 0.0f) { app.put(`,"baseDiffuseRoughness":`); writeFloat(app, m.baseDiffuseRoughness); }
        if (m.specularWeight != 1.0f) { app.put(`,"specularWeight":`); writeFloat(app, m.specularWeight); }
        if (m.specularColor != [1.0f, 1.0f, 1.0f]) { app.put(`,"specularColor":`); writeFloat3(app, m.specularColor); }
        if (m.specularIor != 1.5f) { app.put(`,"specularIor":`); writeFloat(app, m.specularIor); }
        if (m.specularAnisotropy != 0.0f) { app.put(`,"specularAnisotropy":`); writeFloat(app, m.specularAnisotropy); }
        if (m.coatWeight != 0.0f) { app.put(`,"coatWeight":`); writeFloat(app, m.coatWeight); }
        if (m.coatColor != [1.0f, 1.0f, 1.0f]) { app.put(`,"coatColor":`); writeFloat3(app, m.coatColor); }
        if (m.coatRoughness != 0.1f) { app.put(`,"coatRoughness":`); writeFloat(app, m.coatRoughness); }
        if (m.coatIor != 1.6f) { app.put(`,"coatIor":`); writeFloat(app, m.coatIor); }
        if (m.coatDarkening != 1.0f) { app.put(`,"coatDarkening":`); writeFloat(app, m.coatDarkening); }
        if (m.fuzzWeight != 0.0f) { app.put(`,"fuzzWeight":`); writeFloat(app, m.fuzzWeight); }
        if (m.fuzzColor != [1.0f, 1.0f, 1.0f]) { app.put(`,"fuzzColor":`); writeFloat3(app, m.fuzzColor); }
        if (m.fuzzRoughness != 0.5f) { app.put(`,"fuzzRoughness":`); writeFloat(app, m.fuzzRoughness); }
        if (m.thinFilmWeight != 0.0f) { app.put(`,"thinFilmWeight":`); writeFloat(app, m.thinFilmWeight); }
        if (m.thinFilmThickness != 500.0f) { app.put(`,"thinFilmThickness":`); writeFloat(app, m.thinFilmThickness); }
        if (m.thinFilmThicknessMin != 300.0f) { app.put(`,"thinFilmThicknessMin":`); writeFloat(app, m.thinFilmThicknessMin); }
        if (m.thinFilmIor != 1.4f) { app.put(`,"thinFilmIor":`); writeFloat(app, m.thinFilmIor); }
        if (m.anisotropyRotation != 0.0f) { app.put(`,"anisotropyRotation":`); writeFloat(app, m.anisotropyRotation); }
        if (m.transmissionColor != [1.0f, 1.0f, 1.0f]) { app.put(`,"transmissionColor":`); writeFloat3(app, m.transmissionColor); }
        if (m.transmissionWeight != 0.0f) { app.put(`,"transmissionWeight":`); writeFloat(app, m.transmissionWeight); }
        if (m.transmissionDepth != 0.0f) { app.put(`,"transmissionDepth":`); writeFloat(app, m.transmissionDepth); }
        if (m.transmissionDispersion != 0.0f) { app.put(`,"transmissionDispersion":`); writeFloat(app, m.transmissionDispersion); }
        if (m.transmissionThickness != 0.0f) { app.put(`,"transmissionThickness":`); writeFloat(app, m.transmissionThickness); }
        if (m.emissionColor != [1.0f, 1.0f, 1.0f]) { app.put(`,"emissionColor":`); writeFloat3(app, m.emissionColor); }
        if (m.emissionLuminance != 0.0f) { app.put(`,"emissionLuminance":`); writeFloat(app, m.emissionLuminance); }
        if (m.geometryOpacity != 1.0f) { app.put(`,"geometryOpacity":`); writeFloat(app, m.geometryOpacity); }
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
    if (e.customComponents.length > 0) {
        app.put(`,"components":{`);
        foreach (i, ref const comp; e.customComponents) {
            if (i > 0) app.put(',');
            writeJsonString(app, comp.typeName);
            app.put(':');
            app.put(comp.data.toJSON());
        }
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
    if (vis.hasAssetGuid) {
        if (!first)
            app.put(',');
        first = false;
        app.put(`"assetGuid":`);
        writeJsonString(app, vis.assetGuid);
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
private void writeFloat3(ref Appender!string app, const float[3] v) {
    app.put('[');
    writeFloat(app, v[0]);
    app.put(',');
    writeFloat(app, v[1]);
    app.put(',');
    writeFloat(app, v[2]);
    app.put(']');
}

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

private JSONValue[string] jsonObject(ref JSONValue v) @trusted {
    return v.object;
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

@("sceneFile.fogRoundTrip") unittest {
    enum json = `{"format":"game-engine.scene","version":1,"meta":{"name":"f","units":"meters"},`
        ~ `"strings":[],"settings":{"gravity":[0,-9.81,0],"iblPreset":"procedural_default",`
        ~ `"fog":{"enabled":true,"color":[0.5,0.6,0.7],"density":0.004,"heightBase":10,`
        ~ `"heightFalloff":0.03,"startDistance":20,"maxOpacity":0.9}},"entities":[]}`;
    auto a = parseSceneJson(json);
    assert(a.settings.hasFog && a.settings.fog.enabled);
    assert(a.settings.fog.density == 0.004f && a.settings.fog.heightBase == 10);
    assert(sceneToMinifiedJson(a) == json);
    // Scenes without fog keep the old settings object byte-for-byte.
    auto b = parseSceneJson(`{"format":"game-engine.scene","version":1,"meta":{"name":"f","units":"meters"},`
        ~ `"strings":[],"settings":{"gravity":[0,-9.81,0],"iblPreset":"procedural_default"},"entities":[]}`);
    assert(!b.settings.hasFog);
}

@("sceneFile.v2ManifestAndPerChunkLights") unittest {
    SceneFile v2;
    v2.schemaVersion = sceneSchemaVersionV2;
    v2.meta = SceneMeta("open_world", "meters");
    v2.strings = ["assets/models/rock.asset.json"];
    v2.hasCellBounds = true;
    v2.cellBounds = SceneCellBounds([-1536, -64, -1536], [1536, 512, 1536]);
    v2.assetLinks ~= SceneAssetLink("0123456789abcdef0123456789abcdef", 0, "model");
    v2.hasChunkManifest = true;
    v2.chunkManifest.cellSize = 256.0f;
    v2.chunkManifest.loadRadius = 512.0f;
    v2.chunkManifest.unloadRadius = 640.0f;
    v2.chunkManifest.chunks ~= SceneChunkDescriptor(
        0, 0, SceneCellBounds([0, -10, 0], [256, 200, 256]),
        "assets/scenes/chunk_0_0.scene.json", "assets/nav/chunk_0_0.navmesh");

    SceneEntityData rock;
    rock.id = 1;
    rock.hasVisual = true;
    rock.visual.hasAsset = true;
    rock.visual.asset = 0;
    rock.visual.hasAssetGuid = true;
    rock.visual.assetGuid = "0123456789abcdef0123456789abcdef";
    v2.entities ~= rock;

    // 40 point lights split across 2 chunk cells (20 in cell 0, 20 in cell 1) must pass v2 validation.
    foreach (i; 0 .. 40) {
        SceneEntityData l;
        l.id = cast(uint)(i + 2);
        l.transform.pos = [i < 20 ? 10.0f : 300.0f, 3.0f, 10.0f];
        l.hasLight = true;
        l.light.type = "point";
        v2.entities ~= l;
    }
    auto valOk = validateScene(v2, false);
    assert(valOk.ok, "20 point lights per chunk cell must pass v2 validation");

    // 33 point lights in one cell must fail v2 validation.
    SceneFile overChunk = v2;
    foreach (i; 0 .. 14) {
        SceneEntityData l;
        l.id = cast(uint)(100 + i);
        l.transform.pos = [10.0f, 3.0f, 10.0f];
        l.hasLight = true;
        l.light.type = "point";
        overChunk.entities ~= l;
    }
    auto valBad = validateScene(overChunk, false);
    assert(!valBad.ok);
    assert(valBad.errors.canFind!(x => x.code == SceneValidationCode.tooManyPointLights));

    // Round-trip v2 JSON
    immutable json = sceneToMinifiedJson(v2);
    auto parsed = parseSceneJson(json);
    assert(parsed.schemaVersion == 2);
    assert(parsed.hasCellBounds);
    assert(parsed.assetLinks.length == 1 && parsed.assetLinks[0].guid == "0123456789abcdef0123456789abcdef");
    assert(parsed.hasChunkManifest && parsed.chunkManifest.chunks.length == 1);
    assert(parsed.chunkManifest.chunks[0].navmeshPath == "assets/nav/chunk_0_0.navmesh");
    assert(parsed.entities[0].visual.hasAssetGuid);
    assert(sceneToMinifiedJson(parsed) == json);
}
