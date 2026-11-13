/// `game-engine.asset` v1 — minified JSON reader/writer for model/primitive assets.
///
/// Disk format holds render source paths, material slots, collision mesh source,
/// and optional baked convex-hull points. Geometry bytes stay in glTF/BMP; this
/// file only references them. GC is allowed (assets layer).
///
/// Load path (CPU): `loadAssetFile` / `parseAssetJson` → `AssetFile`.
/// GPU/physics later: `renderGltfPath` → `loadGltfMesh` / `loadGltfPbr`;
/// `hullPoints` → `create*Hull`; material fields map 1:1 to `MaterialParams`
/// (`baseColor` → `baseColorFactor`, plus metallic/roughness/flags) with
/// `albedo` as a texture path for the caller to upload.
module engine.assets.asset_file;

import std.algorithm : canFind;
import std.array : appender, Appender;
import std.conv : to;
import std.exception : enforce;
import std.file : readText, write;
import std.format : formattedWrite;
import std.json;
import std.math : isNaN;
import std.string : strip;

@safe:

enum string assetFormatId = "game-engine.asset";
enum int assetSchemaVersion = 2;

/// Top-level asset kind.
enum AssetKind : string {
    model = "model",
    primitive = "primitive",
}

/// Meta block.
struct AssetMeta {
    string name;
}

/// Generated primitive when `kind == primitive` (no glTF).
struct AssetPrimitiveDesc {
    string kind; /// e.g. "box", "sphere", "capsule", "cylinder"
    float[] dims;
}

/// Render block: glTF path and/or primitive generator.
struct AssetRender {
    string source; /// glTF path; empty means JSON `null`
    bool hasPrimitive;
    AssetPrimitiveDesc primitive;
}

/// One material slot on disk (OpenPBR Surface v1.1; strings OK here, interned at load).
struct AssetMaterialSlot {
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
    string   albedo; /// texture path; empty = none
    uint     flags = 0;
}

/// Triangle-mesh collision source.
struct AssetTriangleMesh {
    string source; /// `"render"` or path to a dedicated mesh/glTF
}

/// Baked convex hull in object space.
struct AssetConvexHull {
    uint maxVertexCount = 64;
    float[3][] points;
}

/// One LOD in the shared index buffer. Absent `lods` means a single level.
struct AssetLod {
    uint indexOffset;
    uint indexCount;
    float error;
}

/// Generated collision stand-in. Does not replace `triangleMesh.source`.
struct AssetGeneratedCollision {
    bool present;
    float error;
    uint[] triangles;
    float[3][] hull;
}

/// Optional collision data.
struct AssetCollision {
    bool hasTriangleMesh;
    AssetTriangleMesh triangleMesh;
    bool hasConvexHull;
    AssetConvexHull convexHull;
    AssetGeneratedCollision generated;
}

/// Parsed `*.asset.json` (game-engine.asset v1).
struct AssetFile {
    AssetKind kind = AssetKind.model;
    AssetMeta meta;
    AssetRender render;
    AssetMaterialSlot[] materials;
    /// Empty means one LOD covering the render mesh.
    AssetLod[] lods;
    AssetCollision collision;

    /// glTF path for `loadGltfMesh` / `loadGltfPbr`, or empty.
    string renderGltfPath() const pure nothrow @nogc {
        return render.source;
    }

    /// Collision mesh path: render glTF when source is `"render"`, else override.
    string collisionMeshPath() const pure nothrow {
        if (!collision.hasTriangleMesh)
            return null;
        if (collision.triangleMesh.source == "render")
            return render.source;
        return collision.triangleMesh.source;
    }

    /// Baked hull points, or empty slice if not baked.
    const(float[3])[] hullPoints() const pure nothrow @nogc {
        if (!collision.hasConvexHull)
            return null;
        return collision.convexHull.points;
    }
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Read and parse a `*.asset.json` from disk.
AssetFile loadAssetFile(string path) {
    return parseAssetJson(readText(path));
}

/// Parse asset JSON text (minified or spaced).
AssetFile parseAssetJson(string text) {
    auto root = parseJSON(text.strip());
    enforce(root.type == JSONType.object, "asset root must be a JSON object");
    requireOnlyKeys(root, [
        "format", "version", "kind", "meta", "render", "materials", "lods", "collision"
    ], "asset root");

    enforce("format" in root, "asset missing 'format'");
    enforce(root["format"].type == JSONType.string, "asset 'format' must be string");
    enforce(root["format"].str == assetFormatId,
        "unsupported asset format '" ~ root["format"].str ~ "' (expected " ~ assetFormatId ~ ")");

    enforce("version" in root, "asset missing 'version'");
    immutable ver = jsonInt(root["version"], "version");
    enforce(ver >= 1, "asset version must be >= 1");

    AssetFile asset;
    asset = parseAssetBody(root);
    return migrateAsset(asset, ver);
}

/// Write minified JSON with stable key order to disk.
void saveAssetFile(string path, const ref AssetFile asset) {
    write(path, assetToMinifiedJson(asset));
}

/// Serialize to minified JSON; key order is deterministic.
string assetToMinifiedJson(const ref AssetFile asset) {
    auto app = appender!string();
    writeAsset(app, asset);
    return app.data;
}

/// v1 assets have no `lods` and no generated collision payload. They load as one LOD.
AssetFile migrateAsset(AssetFile asset, int fromVersion) {
    enforce(fromVersion >= 1 && fromVersion <= assetSchemaVersion,
        "unsupported asset version " ~ fromVersion.to!string
            ~ " (supported 1.." ~ assetSchemaVersion.to!string ~ ")");
    return asset;
}

/// Golden + unknown-field checks (also invoked from `dub run --config=test-asset`).
void runAssetFileGoldenTests() {
    // Minified golden with render + hull points (stable key order).
    enum golden =
        `{"format":"game-engine.asset","version":2,"kind":"model",`
        ~ `"meta":{"name":"crate"},`
        ~ `"render":{"source":"assets/models/pbr_cube.gltf","primitive":null},`
        ~ `"materials":[{"baseColor":[1,1,1],"baseMetalness":0,"specularRoughness":0.5,`
        ~ `"albedo":"assets/models/pbr_cube_albedo.bmp","flags":0}],`
        ~ `"collision":{"triangleMesh":{"source":"render"},`
        ~ `"convexHull":{"maxVertexCount":64,"points":[`
        ~ `[-0.5,-0.5,-0.5],[0.5,-0.5,-0.5],[0.5,0.5,-0.5],[-0.5,0.5,-0.5],`
        ~ `[-0.5,-0.5,0.5],[0.5,-0.5,0.5],[0.5,0.5,0.5],[-0.5,0.5,0.5]]}}}`;

    auto a = parseAssetJson(golden);
    assert(a.kind == AssetKind.model);
    assert(a.meta.name == "crate");
    assert(a.render.source == "assets/models/pbr_cube.gltf");
    assert(!a.render.hasPrimitive);
    assert(a.materials.length == 1);
    assert(a.materials[0].specularRoughness == 0.5f);
    assert(a.materials[0].albedo == "assets/models/pbr_cube_albedo.bmp");
    assert(a.collision.hasTriangleMesh);
    assert(a.collision.triangleMesh.source == "render");
    assert(a.collisionMeshPath() == "assets/models/pbr_cube.gltf");
    assert(a.collision.hasConvexHull);
    assert(a.collision.convexHull.maxVertexCount == 64);
    assert(a.hullPoints().length == 8);
    assert(a.hullPoints()[0] == cast(float[3])[-0.5f, -0.5f, -0.5f]);
    assert(a.hullPoints()[7] == cast(float[3])[-0.5f, 0.5f, 0.5f]);

    assert(a.lods.length == 0);
    assert(!a.collision.generated.present);
    immutable written = assetToMinifiedJson(a);
    assert(written == golden, "minified write must match golden exactly");

    enum v1 = `{"format":"game-engine.asset","version":1,"kind":"model","meta":{"name":"crate"},"render":{"source":"assets/models/pbr_cube.gltf","primitive":null},"materials":[],"collision":{"triangleMesh":{"source":"render"}}}`;
    auto migrated = parseAssetJson(v1);
    assert(migrated.lods.length == 0);
    assert(migrated.collision.triangleMesh.source == "render");
    assert(!migrated.collision.generated.present);

    auto b = parseAssetJson(written);
    assert(assetToMinifiedJson(b) == golden);

    // Unknown field → error.
    bool threw;
    try {
        parseAssetJson(`{"format":"game-engine.asset","version":1,"kind":"model",`
            ~ `"meta":{"name":"x"},"render":{"source":null,"primitive":null},`
            ~ `"materials":[],"collision":{},"extra":1}`);
    } catch (Exception) {
        threw = true;
    }
    assert(threw, "unknown root field must error");

    // Primitive asset round-trip with OpenPBR slabs.
    enum primGolden =
        `{"format":"game-engine.asset","version":2,"kind":"primitive",`
        ~ `"meta":{"name":"box1"},`
        ~ `"render":{"source":null,"primitive":{"kind":"box","dims":[1,2,3]}},`
        ~ `"materials":[{"baseColor":[1,0,0],"baseMetalness":0,"specularRoughness":1,`
        ~ `"albedo":"","flags":0,"specularIor":1.6,"coatWeight":0.8,"fuzzWeight":0.4}],`
        ~ `"collision":{"triangleMesh":{"source":"render"}}}`;
    auto p = parseAssetJson(primGolden);
    assert(p.kind == AssetKind.primitive);
    assert(p.render.hasPrimitive);
    assert(p.render.primitive.kind == "box");
    assert(p.render.primitive.dims == [1f, 2f, 3f]);
    assert(!p.collision.hasConvexHull);
    assert(p.materials[0].coatWeight == 0.8f);
    assert(p.materials[0].fuzzWeight == 0.4f);
    assert(p.materials[0].specularIor == 1.6f);
    assert(assetToMinifiedJson(p) == primGolden);

    enum lodGolden =
        `{"format":"game-engine.asset","version":2,"kind":"model","meta":{"name":"lod"},`
        ~ `"render":{"source":"m.gltf","primitive":null},"materials":[],"lods":[{"indexOffset":0,"indexCount":12,"error":0},{"indexOffset":12,"indexCount":6,"error":0.02}],`
        ~ `"collision":{"triangleMesh":{"source":"render"},"generated":{"error":0.05,"triangles":[0,1,2],"hull":[[0,0,0],[1,0,0]]}}}`;
    auto lod = parseAssetJson(lodGolden);
    assert(lod.lods.length == 2);
    assert(lod.lods[1].indexCount == 6);
    assert(lod.collision.triangleMesh.source == "render");
    assert(lod.collision.generated.present);
    assert(lod.collision.generated.triangles == [0u, 1, 2]);
    assert(lod.collision.generated.hull.length == 2);
    assert(assetToMinifiedJson(lod) == lodGolden);
}

@safe unittest {
    runAssetFileGoldenTests();
}

// ---------------------------------------------------------------------------
// Parse
// ---------------------------------------------------------------------------

private AssetFile parseAssetBody(ref JSONValue root) {
    AssetFile a;

    enforce("kind" in root, "asset missing 'kind'");
    enforce(root["kind"].type == JSONType.string, "asset 'kind' must be string");
    immutable kindStr = root["kind"].str;
    if (kindStr == AssetKind.model) {
        a.kind = AssetKind.model;
    } else if (kindStr == AssetKind.primitive) {
        a.kind = AssetKind.primitive;
    } else {
        enforce(false, "unknown asset kind '" ~ kindStr ~ "'");
    }

    enforce("meta" in root, "asset missing 'meta'");
    a.meta = parseMeta(root["meta"]);

    enforce("render" in root, "asset missing 'render'");
    a.render = parseRender(root["render"]);

    enforce("materials" in root, "asset missing 'materials'");
    a.materials = parseMaterials(root["materials"]);

    if ("lods" in root)
        a.lods = parseLods(root["lods"]);

    enforce("collision" in root, "asset missing 'collision'");
    a.collision = parseCollision(root["collision"]);

    return a;
}

private AssetMeta parseMeta(ref JSONValue v) {
    enforce(v.type == JSONType.object, "'meta' must be object");
    requireOnlyKeys(v, ["name"], "meta");
    enforce("name" in v, "meta missing 'name'");
    enforce(v["name"].type == JSONType.string, "meta.name must be string");
    return AssetMeta(v["name"].str);
}

private AssetRender parseRender(ref JSONValue v) {
    enforce(v.type == JSONType.object, "'render' must be object");
    requireOnlyKeys(v, ["source", "primitive"], "render");
    enforce("source" in v, "render missing 'source'");
    enforce("primitive" in v, "render missing 'primitive'");

    AssetRender r;
    if (v["source"].type == JSONType.null_) {
        r.source = null;
    } else {
        enforce(v["source"].type == JSONType.string, "render.source must be string or null");
        r.source = v["source"].str;
    }

    if (v["primitive"].type == JSONType.null_) {
        r.hasPrimitive = false;
    } else {
        r.hasPrimitive = true;
        r.primitive = parsePrimitive(v["primitive"]);
    }
    return r;
}

private AssetPrimitiveDesc parsePrimitive(ref JSONValue v) {
    enforce(v.type == JSONType.object, "render.primitive must be object or null");
    requireOnlyKeys(v, ["kind", "dims"], "render.primitive");
    enforce("kind" in v && v["kind"].type == JSONType.string, "primitive.kind must be string");
    enforce("dims" in v && v["dims"].type == JSONType.array, "primitive.dims must be array");

    AssetPrimitiveDesc p;
    p.kind = v["kind"].str;
    foreach (ref d; jsonArray(v["dims"])) {
        p.dims ~= jsonFloat(d, "primitive.dims[]");
    }
    return p;
}

private AssetMaterialSlot[] parseMaterials(ref JSONValue v) {
    enforce(v.type == JSONType.array, "'materials' must be array");
    AssetMaterialSlot[] mats;
    auto arr = jsonArray(v);
    mats.reserve(arr.length);
    foreach (ref m; arr) {
        mats ~= parseMaterialSlot(m);
    }
    return mats;
}

private AssetMaterialSlot parseMaterialSlot(ref JSONValue v) {
    enforce(v.type == JSONType.object, "materials[] entry must be object");
    requireOnlyKeys(v, [
        "baseColor", "baseWeight", "baseMetalness", "baseDiffuseRoughness",
        "specularWeight", "specularRoughness", "specularColor", "specularIor",
        "specularAnisotropy", "coatWeight", "coatColor", "coatRoughness",
        "coatIor", "coatDarkening", "fuzzWeight", "fuzzColor", "fuzzRoughness",
        "thinFilmWeight", "thinFilmThickness", "thinFilmIor",
        "emissionColor", "emissionLuminance", "geometryOpacity",
        "albedo", "flags"
    ], "materials[]");
    enforce("baseColor" in v, "materials[] missing 'baseColor'");
    enforce("baseMetalness" in v, "materials[] missing 'baseMetalness'");
    enforce("specularRoughness" in v, "materials[] missing 'specularRoughness'");
    enforce("albedo" in v, "materials[] missing 'albedo'");
    enforce("flags" in v, "materials[] missing 'flags'");

    AssetMaterialSlot m;
    m.baseColor = jsonFloat3(v["baseColor"], "materials[].baseColor");
    m.baseMetalness = jsonFloat(v["baseMetalness"], "materials[].baseMetalness");
    m.specularRoughness = jsonFloat(v["specularRoughness"], "materials[].specularRoughness");
    enforce(v["albedo"].type == JSONType.string, "materials[].albedo must be string");
    m.albedo = v["albedo"].str;
    m.flags = cast(uint) jsonInt(v["flags"], "materials[].flags");
    if ("baseWeight" in v) m.baseWeight = jsonFloat(v["baseWeight"], "materials[].baseWeight");
    if ("baseDiffuseRoughness" in v) m.baseDiffuseRoughness = jsonFloat(v["baseDiffuseRoughness"], "materials[].baseDiffuseRoughness");
    if ("specularWeight" in v) m.specularWeight = jsonFloat(v["specularWeight"], "materials[].specularWeight");
    if ("specularColor" in v) m.specularColor = jsonFloat3(v["specularColor"], "materials[].specularColor");
    if ("specularIor" in v) m.specularIor = jsonFloat(v["specularIor"], "materials[].specularIor");
    if ("specularAnisotropy" in v) m.specularAnisotropy = jsonFloat(v["specularAnisotropy"], "materials[].specularAnisotropy");
    if ("coatWeight" in v) m.coatWeight = jsonFloat(v["coatWeight"], "materials[].coatWeight");
    if ("coatColor" in v) m.coatColor = jsonFloat3(v["coatColor"], "materials[].coatColor");
    if ("coatRoughness" in v) m.coatRoughness = jsonFloat(v["coatRoughness"], "materials[].coatRoughness");
    if ("coatIor" in v) m.coatIor = jsonFloat(v["coatIor"], "materials[].coatIor");
    if ("coatDarkening" in v) m.coatDarkening = jsonFloat(v["coatDarkening"], "materials[].coatDarkening");
    if ("fuzzWeight" in v) m.fuzzWeight = jsonFloat(v["fuzzWeight"], "materials[].fuzzWeight");
    if ("fuzzColor" in v) m.fuzzColor = jsonFloat3(v["fuzzColor"], "materials[].fuzzColor");
    if ("fuzzRoughness" in v) m.fuzzRoughness = jsonFloat(v["fuzzRoughness"], "materials[].fuzzRoughness");
    if ("thinFilmWeight" in v) m.thinFilmWeight = jsonFloat(v["thinFilmWeight"], "materials[].thinFilmWeight");
    if ("thinFilmThickness" in v) m.thinFilmThickness = jsonFloat(v["thinFilmThickness"], "materials[].thinFilmThickness");
    if ("thinFilmIor" in v) m.thinFilmIor = jsonFloat(v["thinFilmIor"], "materials[].thinFilmIor");
    if ("emissionColor" in v) m.emissionColor = jsonFloat3(v["emissionColor"], "materials[].emissionColor");
    if ("emissionLuminance" in v) m.emissionLuminance = jsonFloat(v["emissionLuminance"], "materials[].emissionLuminance");
    if ("geometryOpacity" in v) m.geometryOpacity = jsonFloat(v["geometryOpacity"], "materials[].geometryOpacity");
    return m;
}

private AssetLod[] parseLods(ref JSONValue v) {
    enforce(v.type == JSONType.array, "lods must be array");
    AssetLod[] lods;
    foreach (ref item; jsonArray(v)) {
        enforce(item.type == JSONType.object, "lods[] must be object");
        requireOnlyKeys(item, ["indexOffset", "indexCount", "error"], "lods[]");
        AssetLod lod;
        lod.indexOffset = cast(uint) jsonInt(item["indexOffset"], "lods.indexOffset");
        lod.indexCount = cast(uint) jsonInt(item["indexCount"], "lods.indexCount");
        lod.error = jsonFloat(item["error"], "lods.error");
        lods ~= lod;
    }
    return lods;
}

private AssetCollision parseCollision(ref JSONValue v) {
    enforce(v.type == JSONType.object, "'collision' must be object");
    requireOnlyKeys(v, ["triangleMesh", "convexHull", "generated"], "collision");

    AssetCollision c;
    if ("triangleMesh" in v) {
        c.hasTriangleMesh = true;
        c.triangleMesh = parseTriangleMesh(v["triangleMesh"]);
    }
    if ("convexHull" in v) {
        c.hasConvexHull = true;
        c.convexHull = parseConvexHull(v["convexHull"]);
    }
    if ("generated" in v)
        c.generated = parseGenerated(v["generated"]);
    return c;
}

private AssetGeneratedCollision parseGenerated(ref JSONValue v) {
    enforce(v.type == JSONType.object, "collision.generated must be object");
    requireOnlyKeys(v, ["error", "triangles", "hull"], "collision.generated");
    AssetGeneratedCollision g;
    g.present = true;
    g.error = jsonFloat(v["error"], "collision.generated.error");
    enforce(v["triangles"].type == JSONType.array, "collision.generated.triangles must be array");
    foreach (ref t; jsonArray(v["triangles"]))
        g.triangles ~= cast(uint) jsonInt(t, "collision.generated.triangles[]");
    enforce(v["hull"].type == JSONType.array, "collision.generated.hull must be array");
    foreach (ref pt; jsonArray(v["hull"]))
        g.hull ~= jsonFloat3(pt, "collision.generated.hull[]");
    return g;
}

private AssetTriangleMesh parseTriangleMesh(ref JSONValue v) {
    enforce(v.type == JSONType.object, "collision.triangleMesh must be object");
    requireOnlyKeys(v, ["source"], "collision.triangleMesh");
    enforce("source" in v && v["source"].type == JSONType.string,
        "collision.triangleMesh.source must be string");
    return AssetTriangleMesh(v["source"].str);
}

private AssetConvexHull parseConvexHull(ref JSONValue v) {
    enforce(v.type == JSONType.object, "collision.convexHull must be object");
    requireOnlyKeys(v, ["maxVertexCount", "points"], "collision.convexHull");
    enforce("maxVertexCount" in v, "convexHull missing 'maxVertexCount'");
    enforce("points" in v && v["points"].type == JSONType.array, "convexHull.points must be array");

    AssetConvexHull h;
    h.maxVertexCount = cast(uint) jsonInt(v["maxVertexCount"], "convexHull.maxVertexCount");
    foreach (ref pt; jsonArray(v["points"])) {
        h.points ~= jsonFloat3(pt, "convexHull.points[]");
    }
    return h;
}

// ---------------------------------------------------------------------------
// Write (minified, stable key order)
// ---------------------------------------------------------------------------

private void writeAsset(ref Appender!string app, const ref AssetFile a) {
    app.put(`{"format":"`);
    app.put(assetFormatId);
    app.put(`","version":`);
    app.formattedWrite("%d", assetSchemaVersion);
    app.put(`,"kind":"`);
    app.put(cast(string) a.kind);
    app.put(`","meta":{"name":`);
    writeJsonString(app, a.meta.name);
    app.put(`},"render":`);
    writeRender(app, a.render);
    app.put(`,"materials":[`);
    foreach (i, ref m; a.materials) {
        if (i)
            app.put(',');
        writeMaterial(app, m);
    }
    app.put(`]`);
    if (a.lods.length) {
        app.put(`,"lods":[`);
        foreach (i, ref lod; a.lods) {
            if (i)
                app.put(',');
            app.put(`{"indexOffset":`);
            app.formattedWrite("%d", lod.indexOffset);
            app.put(`,"indexCount":`);
            app.formattedWrite("%d", lod.indexCount);
            app.put(`,"error":`);
            writeFloat(app, lod.error);
            app.put('}');
        }
        app.put(']');
    }
    app.put(`,"collision":`);
    writeCollision(app, a.collision);
    app.put('}');
}

private void writeRender(ref Appender!string app, const ref AssetRender r) {
    app.put(`{"source":`);
    if (r.source.length == 0)
        app.put("null");
    else
        writeJsonString(app, r.source);
    app.put(`,"primitive":`);
    if (!r.hasPrimitive)
        app.put("null");
    else {
        app.put(`{"kind":`);
        writeJsonString(app, r.primitive.kind);
        app.put(`,"dims":[`);
        foreach (i, d; r.primitive.dims) {
            if (i)
                app.put(',');
            writeFloat(app, d);
        }
        app.put(`]}`);
    }
    app.put('}');
}

private void writeFloat3(ref Appender!string app, const float[3] v) {
    app.put('[');
    writeFloat(app, v[0]);
    app.put(',');
    writeFloat(app, v[1]);
    app.put(',');
    writeFloat(app, v[2]);
    app.put(']');
}

private void writeMaterial(ref Appender!string app, const ref AssetMaterialSlot m) {
    app.put(`{"baseColor":`);
    writeFloat3(app, m.baseColor);
    app.put(`,"baseMetalness":`);
    writeFloat(app, m.baseMetalness);
    app.put(`,"specularRoughness":`);
    writeFloat(app, m.specularRoughness);
    app.put(`,"albedo":`);
    writeJsonString(app, m.albedo);
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
    if (m.thinFilmIor != 1.4f) { app.put(`,"thinFilmIor":`); writeFloat(app, m.thinFilmIor); }
    if (m.emissionColor != [1.0f, 1.0f, 1.0f]) { app.put(`,"emissionColor":`); writeFloat3(app, m.emissionColor); }
    if (m.emissionLuminance != 0.0f) { app.put(`,"emissionLuminance":`); writeFloat(app, m.emissionLuminance); }
    if (m.geometryOpacity != 1.0f) { app.put(`,"geometryOpacity":`); writeFloat(app, m.geometryOpacity); }
    app.put('}');
}

private void writeCollision(ref Appender!string app, const ref AssetCollision c) {
    app.put('{');
    bool first = true;
    if (c.hasTriangleMesh) {
        first = false;
        app.put(`"triangleMesh":{"source":`);
        writeJsonString(app, c.triangleMesh.source);
        app.put('}');
    }
    if (c.hasConvexHull) {
        if (!first)
            app.put(',');
        app.put(`"convexHull":{"maxVertexCount":`);
        app.formattedWrite("%d", c.convexHull.maxVertexCount);
        app.put(`,"points":[`);
        foreach (i, ref p; c.convexHull.points) {
            if (i)
                app.put(',');
            app.put('[');
            writeFloat(app, p[0]);
            app.put(',');
            writeFloat(app, p[1]);
            app.put(',');
            writeFloat(app, p[2]);
            app.put(']');
        }
        app.put(`]}`);
        first = false;
    }
    if (c.generated.present) {
        if (!first)
            app.put(',');
        app.put(`"generated":{"error":`);
        writeFloat(app, c.generated.error);
        app.put(`,"triangles":[`);
        foreach (i, t; c.generated.triangles) {
            if (i)
                app.put(',');
            app.formattedWrite("%d", t);
        }
        app.put(`],"hull":[`);
        foreach (i, ref p; c.generated.hull) {
            if (i)
                app.put(',');
            app.put('[');
            writeFloat(app, p[0]);
            app.put(',');
            writeFloat(app, p[1]);
            app.put(',');
            writeFloat(app, p[2]);
            app.put(']');
        }
        app.put(`]}`);
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
    enforce(!isNaN(f), "cannot serialize NaN in asset JSON");
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

/// Minimal `@trusted` wrappers — `JSONValue.object` / `.array` are `@system` in Phobos.
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
    // JSON may encode whole numbers as float.
    if (v.type == JSONType.float_) {
        immutable f = v.floating;
        enforce(f == cast(int) f, ctx ~ " must be an integer");
        return cast(int) f;
    }
    enforce(false, ctx ~ " must be an integer");
    return 0;
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
    enforce(v.type == JSONType.array && arr.length == 4, ctx ~ " must be [r,g,b,a]");
    float[4] out_;
    out_[0] = jsonFloat(arr[0], ctx);
    out_[1] = jsonFloat(arr[1], ctx);
    out_[2] = jsonFloat(arr[2], ctx);
    out_[3] = jsonFloat(arr[3], ctx);
    return out_;
}
