/// Import-time mesh optimization for glTF. Reads the asset `.meta` sidecar.
/// Missing file or missing `settings.meshopt` keeps `MeshOptSettings` defaults (on).
module engine.assets.gltf_optimize;

import std.file : exists, read;
import std.json : JSONType, JSONValue, parseJSON;

import engine.gpu.context : GpuContext;
import engine.graphics.texmesh : TexMesh;
import engine.graphics.types : TexTanVert, TexVert;
import engine.meshopt.pipeline : MeshOptSettings, optimizeMesh;
import engine.meshopt.tangent : generateTangents;
import engine.meshopt.types : FloatStream, TangentOptions, positionsOf;

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

/// Optimize `TexVert` data, or a packed tangent vertex when `tangents` is one entry per vertex.
void finalizeImportedMesh(string assetPath, ref TexVert[] vertices, ref uint[] indices, ref uint[] shadowIndices, ref float[4][] tangents) {
    if (tangents.length == vertices.length && tangents.length > 0) {
        TexTanVert[] packed = packTangents(vertices, tangents);
        auto spec = meshOptImportFor(assetPath);
        if (!spec.enabled) {
            shadowIndices = null;
            return;
        }
        auto opt = optimizeMesh(packed, indices, spec.settings);
        unpackTangents(opt.vertices, opt.indices, opt.shadowIndices, vertices, indices, shadowIndices, tangents);
        return;
    }
    optimizeImportedMesh(assetPath, vertices, indices, shadowIndices);
}

/// Per-corner tangents for a normal map, then the import-time pipeline.
/// No-op when `tangents` is already one entry per vertex.
void generateMissingTangents(string assetPath, ref TexVert[] vertices, ref uint[] indices, ref uint[] shadowIndices, ref float[4][] tangents) {
    if (tangents.length == vertices.length && tangents.length > 0)
        return;
    if (vertices.length == 0 || indices.length == 0)
        return;
    float[4][] corners = new float[4][](indices.length);
    generateTangents(corners, indices, positionsOf!TexVert(vertices), positionsOf!(TexVert, "normal")(vertices), uvStream(vertices), TangentOptions.compatible);
    TexTanVert[] expanded = new TexTanVert[indices.length];
    uint[] expandedIdx = new uint[indices.length];
    foreach (i, id; indices) {
        expanded[i].pos = vertices[id].pos;
        expanded[i].normal = vertices[id].normal;
        expanded[i].uv = vertices[id].uv;
        expanded[i].tangent = corners[i];
        expandedIdx[i] = cast(uint) i;
    }
    auto spec = meshOptImportFor(assetPath);
    if (!spec.enabled) {
        unpackTangents(expanded, expandedIdx, null, vertices, indices, shadowIndices, tangents);
        return;
    }
    auto opt = optimizeMesh(expanded, expandedIdx, spec.settings);
    unpackTangents(opt.vertices, opt.indices, opt.shadowIndices, vertices, indices, shadowIndices, tangents);
}

/// Upload `TexTanVert` when tangents are present, otherwise `TexVert`.
TexMesh uploadOptimizedMesh(ref GpuContext gpu, const(TexVert)[] vertices, const(uint)[] indices, const(uint)[] shadowIndices, const(float[4])[] tangents) {
    if (tangents.length == vertices.length && tangents.length > 0)
        return TexMesh.fromData(gpu, packTangents(vertices, tangents), indices, shadowIndices);
    return TexMesh.fromData(gpu, vertices, indices, shadowIndices);
}

private TexTanVert[] packTangents(const(TexVert)[] vertices, const(float[4])[] tangents) {
    auto packed = new TexTanVert[vertices.length];
    foreach (i, v; vertices) {
        packed[i].pos = v.pos;
        packed[i].normal = v.normal;
        packed[i].uv = v.uv;
        packed[i].tangent = tangents[i];
    }
    return packed;
}

private void unpackTangents(const(TexTanVert)[] packed, const(uint)[] optIndices, const(uint)[] optShadow, ref TexVert[] vertices, ref uint[] indices, ref uint[] shadowIndices, ref float[4][] tangents) {
    vertices.length = packed.length;
    tangents.length = packed.length;
    foreach (i, v; packed) {
        vertices[i].pos = v.pos;
        vertices[i].normal = v.normal;
        vertices[i].uv = v.uv;
        tangents[i] = v.tangent;
    }
    indices = optIndices.dup;
    shadowIndices = optShadow.dup;
}

private FloatStream uvStream(const(TexVert)[] vertices) @trusted {
    FloatStream uvs;
    uvs.strideFloats = TexVert.sizeof / 4;
    uvs.count = vertices.length;
    if (vertices.length)
        uvs.address = cast(ulong)(cast(const(ubyte)*) vertices.ptr + TexVert.uv.offsetof);
    return uvs;
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

@("generateMissingTangents.mirror") unittest {
    TexVert[4] quad = [
        TexVert([0, 0, 0], [0, 1, 0], [1, 0]),
        TexVert([1, 0, 0], [0, 1, 0], [0, 0]),
        TexVert([1, 0, 1], [0, 1, 0], [0, 1]),
        TexVert([0, 0, 1], [0, 1, 0], [1, 1]),
    ];
    TexVert[] verts = quad.dup;
    uint[] indices = [0, 1, 2, 0, 2, 3];
    uint[] shadow;
    float[4][] tangents;
    generateMissingTangents("/tmp/meshopt-no-such-tangent-asset.gltf", verts, indices, shadow, tangents);
    assert(tangents.length == verts.length);
    assert(tangents.length > 0);
    bool negative = false;
    foreach (t; tangents) {
        assert(t[3] == 1.0f || t[3] == -1.0f);
        if (t[3] < 0)
            negative = true;
    }
    assert(negative);
}
