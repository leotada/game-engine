/// Import-time mesh optimization for glTF. Reads the asset `.meta` sidecar.
/// Missing file or missing `settings.meshopt` keeps `MeshOptSettings` defaults (on).
module engine.assets.gltf_optimize;

import std.file : exists, read;
import std.json : JSONType, JSONValue, parseJSON;

import engine.meshopt.pipeline : MeshOptSettings, optimizeMesh;

@safe:

/// Whether to run `optimizeMesh`, plus the pass switches from `.meta`.
struct MeshOptImport {
    bool enabled = true;
    MeshOptSettings settings;
}

/// `assetPath` is the glTF (or other asset), not the `.meta` path.
MeshOptImport meshOptImportFor(string assetPath) @trusted {
    MeshOptImport result;
    string metaPath = assetPath ~ ".meta";
    if (!exists(metaPath))
        return result;
    try {
        auto root = parseJSON(cast(string) read(metaPath));
        if (root.type != JSONType.object || "settings" !in root)
            return result;
        auto settings = root["settings"];
        if (settings.type != JSONType.object || "meshopt" !in settings)
            return result;
        auto meshopt = settings["meshopt"];
        if (meshopt.type != JSONType.object)
            return result;
        result.enabled = jsonBool(meshopt, "enabled", true);
        result.settings.reindex = jsonBool(meshopt, "reindex", true);
        result.settings.vertexCache = jsonBool(meshopt, "vertexCache", true);
        result.settings.vertexFetch = jsonBool(meshopt, "vertexFetch", true);
        result.settings.shadowIndices = jsonBool(meshopt, "shadowIndices", true);
        if ("overdrawThreshold" in meshopt) {
            auto t = meshopt["overdrawThreshold"];
            if (t.type == JSONType.float_)
                result.settings.overdrawThreshold = cast(float) t.floating;
            else if (t.type == JSONType.integer)
                result.settings.overdrawThreshold = cast(float) t.integer;
        }
    } catch (Exception) {
        return MeshOptImport.init;
    }
    return result;
}

/// Run `optimizeMesh` when the sidecar asks for it. `shadowIndices` is cleared when the pass is off.
void optimizeImportedMesh(V)(string assetPath, ref V[] vertices, ref uint[] indices, ref uint[] shadowIndices)
if (is(typeof(V.init.pos) == float[3]) && V.pos.offsetof == 0 && V.sizeof % 4 == 0 && V.sizeof <= 256) {
    auto spec = meshOptImportFor(assetPath);
    if (!spec.enabled) {
        shadowIndices = null;
        return;
    }
    auto opt = optimizeMesh(vertices, indices, spec.settings);
    vertices = opt.vertices;
    indices = opt.indices;
    shadowIndices = opt.shadowIndices;
}

private bool jsonBool(ref JSONValue obj, string key, bool fallback) {
    if (key !in obj)
        return fallback;
    auto v = obj[key];
    if (v.type == JSONType.true_)
        return true;
    if (v.type == JSONType.false_)
        return false;
    return fallback;
}

@("meshOptImportFor.defaults") @trusted unittest {
    import std.file : mkdirRecurse, rmdirRecurse, write;
    import std.path : buildPath;

    string dir = "/tmp/meshopt-meta-m3";
    mkdirRecurse(dir);
    scope (exit)
        rmdirRecurse(dir);
    string path = buildPath(dir, "a.gltf");
    auto missing = meshOptImportFor(path);
    assert(missing.enabled);
    assert(missing.settings.reindex);
    assert(missing.settings.shadowIndices);
    assert(missing.settings.overdrawThreshold == 1.05f);

    write(path ~ ".meta", `{"guid":"x","importer":"gltf","settings":{"meshopt":{"enabled":false,"overdrawThreshold":0}}}`);
    auto off = meshOptImportFor(path);
    assert(!off.enabled);
    assert(off.settings.overdrawThreshold == 0);

    write(path ~ ".meta", `{"settings":{}}`);
    auto bare = meshOptImportFor(path);
    assert(bare.enabled);
    assert(bare.settings.vertexFetch);
}
