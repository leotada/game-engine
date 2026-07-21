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
enum int assetSchemaVersion = 1;

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

/// One material slot on disk (strings OK here; intern at scene/runtime load).
struct AssetMaterialSlot {
    float[4] baseColor = [1, 1, 1, 1];
    float metallic = 0;
    float roughness = 1;
    string albedo; /// texture path; empty = none
    uint flags = 0;
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

/// Optional collision data.
struct AssetCollision {
    bool hasTriangleMesh;
    AssetTriangleMesh triangleMesh;
    bool hasConvexHull;
    AssetConvexHull convexHull;
}

/// Parsed `*.asset.json` (game-engine.asset v1).
struct AssetFile {
    AssetKind kind = AssetKind.model;
    AssetMeta meta;
    AssetRender render;
    AssetMaterialSlot[] materials;
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
        "format", "version", "kind", "meta", "render", "materials", "collision"
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

/// Version migration chain stub. Currently only v1 is accepted.
AssetFile migrateAsset(AssetFile asset, int fromVersion) {
    enforce(fromVersion == assetSchemaVersion,
        "unsupported asset version " ~ fromVersion.to!string
            ~ " (only " ~ assetSchemaVersion.to!string ~ " implemented; migrate_vN stub)");
    return asset;
}

/// Golden + unknown-field checks (also invoked from `dub run --config=test-asset`).
void runAssetFileGoldenTests() {
    // Minified golden with render + hull points (stable key order).
    enum golden =
        `{"format":"game-engine.asset","version":1,"kind":"model",`
        ~ `"meta":{"name":"crate"},`
        ~ `"render":{"source":"assets/models/pbr_cube.gltf","primitive":null},`
        ~ `"materials":[{"baseColor":[1,1,1,1],"metallic":0,"roughness":0.5,`
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
    assert(a.materials[0].roughness == 0.5f);
    assert(a.materials[0].albedo == "assets/models/pbr_cube_albedo.bmp");
    assert(a.collision.hasTriangleMesh);
    assert(a.collision.triangleMesh.source == "render");
    assert(a.collisionMeshPath() == "assets/models/pbr_cube.gltf");
    assert(a.collision.hasConvexHull);
    assert(a.collision.convexHull.maxVertexCount == 64);
    assert(a.hullPoints().length == 8);
    assert(a.hullPoints()[0] == cast(float[3])[-0.5f, -0.5f, -0.5f]);
    assert(a.hullPoints()[7] == cast(float[3])[-0.5f, 0.5f, 0.5f]);

    immutable written = assetToMinifiedJson(a);
    assert(written == golden, "minified write must match golden exactly");

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

    // Primitive asset round-trip.
    enum primGolden =
        `{"format":"game-engine.asset","version":1,"kind":"primitive",`
        ~ `"meta":{"name":"box1"},`
        ~ `"render":{"source":null,"primitive":{"kind":"box","dims":[1,2,3]}},`
        ~ `"materials":[{"baseColor":[1,0,0,1],"metallic":0,"roughness":1,`
        ~ `"albedo":"","flags":0}],`
        ~ `"collision":{"triangleMesh":{"source":"render"}}}`;
    auto p = parseAssetJson(primGolden);
    assert(p.kind == AssetKind.primitive);
    assert(p.render.hasPrimitive);
    assert(p.render.primitive.kind == "box");
    assert(p.render.primitive.dims == [1f, 2f, 3f]);
    assert(!p.collision.hasConvexHull);
    assert(assetToMinifiedJson(p) == primGolden);
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
    requireOnlyKeys(v, ["baseColor", "metallic", "roughness", "albedo", "flags"], "materials[]");
    enforce("baseColor" in v, "materials[] missing 'baseColor'");
    enforce("metallic" in v, "materials[] missing 'metallic'");
    enforce("roughness" in v, "materials[] missing 'roughness'");
    enforce("albedo" in v, "materials[] missing 'albedo'");
    enforce("flags" in v, "materials[] missing 'flags'");

    AssetMaterialSlot m;
    m.baseColor = jsonFloat4(v["baseColor"], "materials[].baseColor");
    m.metallic = jsonFloat(v["metallic"], "materials[].metallic");
    m.roughness = jsonFloat(v["roughness"], "materials[].roughness");
    enforce(v["albedo"].type == JSONType.string, "materials[].albedo must be string");
    m.albedo = v["albedo"].str;
    m.flags = cast(uint) jsonInt(v["flags"], "materials[].flags");
    return m;
}

private AssetCollision parseCollision(ref JSONValue v) {
    enforce(v.type == JSONType.object, "'collision' must be object");
    requireOnlyKeys(v, ["triangleMesh", "convexHull"], "collision");

    AssetCollision c;
    if ("triangleMesh" in v) {
        c.hasTriangleMesh = true;
        c.triangleMesh = parseTriangleMesh(v["triangleMesh"]);
    }
    if ("convexHull" in v) {
        c.hasConvexHull = true;
        c.convexHull = parseConvexHull(v["convexHull"]);
    }
    return c;
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
    app.put(`],"collision":`);
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

private void writeMaterial(ref Appender!string app, const ref AssetMaterialSlot m) {
    app.put(`{"baseColor":[`);
    writeFloat(app, m.baseColor[0]);
    app.put(',');
    writeFloat(app, m.baseColor[1]);
    app.put(',');
    writeFloat(app, m.baseColor[2]);
    app.put(',');
    writeFloat(app, m.baseColor[3]);
    app.put(`],"metallic":`);
    writeFloat(app, m.metallic);
    app.put(`,"roughness":`);
    writeFloat(app, m.roughness);
    app.put(`,"albedo":`);
    writeJsonString(app, m.albedo);
    app.put(`,"flags":`);
    app.formattedWrite("%d", m.flags);
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
