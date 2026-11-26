/// Import-time mesh optimization for glTF. Reads the asset `.meta` sidecar.
/// Missing file or missing `settings.meshopt` keeps `MeshOptSettings` defaults (on).
module engine.assets.gltf_optimize;

import std.file : exists, read;
import std.json : JSONType, JSONValue, parseJSON;

import engine.gpu.context : GpuContext;
import engine.graphics.texmesh : TexMesh;
import engine.graphics.types : TexTanVert, TexVert;
import engine.meshopt.pipeline : LodChain, LodLevel, LodSettings, MeshOptSettings, buildLodChain, optimizeMesh;
import engine.meshopt.simplify.points : simplifyScale;
import engine.meshopt.tangent : generateTangents;
import engine.meshopt.types : FloatStream, TangentOptions, positionsOf;

@safe:

/// Whether to run `optimizeMesh`, plus the pass switches from `.meta`.
struct MeshOptImport {
    bool enabled = true;
    MeshOptSettings settings;
}

/// Load-time LOD chain request from `.meta` `settings.lod`.
struct LodImport {
    bool enabled = false;
    LodSettings settings;
}

/**
 * Parse `settings.lod` of a `.meta` document:
 * `{"settings":{"lod":{"enabled":true,"maxLods":4,"ratio":0.5,"maxError":0.05}}}`.
 * Missing keys keep `LodSettings` defaults; a missing block means disabled.
 */
LodImport parseLodImport(JSONValue root) @trusted {
    LodImport result;
    if (root.type != JSONType.object || "settings" !in root) return result;
    auto settings = root["settings"];
    if (settings.type != JSONType.object || "lod" !in settings) return result;
    auto lod = settings["lod"];
    if (lod.type != JSONType.object) return result;
    result.enabled = jsonBool(lod, "enabled", false);
    float num(string key, float def) {
        if (key !in lod) return def;
        auto v = lod[key];
        if (v.type == JSONType.float_) return cast(float) v.floating;
        if (v.type == JSONType.integer) return cast(float) v.integer;
        if (v.type == JSONType.uinteger) return cast(float) v.uinteger;
        return def;
    }
    immutable maxLods = num("maxLods", result.settings.maxLods);
    result.settings.maxLods = maxLods < 1 ? 1 : (maxLods > 8 ? 8 : cast(uint) maxLods);
    result.settings.ratio = num("ratio", result.settings.ratio);
    result.settings.maxError = num("maxError", result.settings.maxError);
    return result;
}

/// Import-time vertex of meshes with vertex colors; split again before upload.
private struct ColorVert {
    float[3] pos;
    float[3] normal;
    float[2] uv;
    ubyte[4] color;
}

private struct ColorTanVert {
    float[3] pos;
    float[3] normal;
    float[2] uv;
    float[4] tangent;
    ubyte[4] color;
}

private V[] packColors(V)(const(TexVert)[] vertices, const(float[4])[] tangents, const(ubyte[4])[] colors) {
    auto packed = new V[vertices.length];
    foreach (i, ref p; packed) {
        p.pos = vertices[i].pos;
        p.normal = vertices[i].normal;
        p.uv = vertices[i].uv;
        static if (is(V == ColorTanVert)) p.tangent = tangents[i];
        p.color = colors[i];
    }
    return packed;
}

private void unpackColors(V)(const(V)[] packed, ref TexVert[] vertices, ref float[4][] tangents, ref ubyte[4][] colors) {
    vertices = new TexVert[packed.length];
    colors = new ubyte[4][packed.length];
    static if (is(V == ColorTanVert)) tangents = new float[4][packed.length];
    foreach (i, ref p; packed) {
        vertices[i] = TexVert(p.pos, p.normal, p.uv);
        colors[i] = p.color;
        static if (is(V == ColorTanVert)) tangents[i] = p.tangent;
    }
}

private void optimizeColored(V)(string assetPath, V[] packed, ref TexVert[] vertices, ref uint[] indices,
                                ref uint[] shadowIndices, ref float[4][] tangents, ref ubyte[4][] colors) {
    optimizeImportedMesh(assetPath, packed, indices, shadowIndices);
    unpackColors(packed, vertices, tangents, colors);
}

/// `finalizeImportedMesh` keeping one color per vertex.
void finalizeImportedMesh(string assetPath, ref TexVert[] vertices, ref uint[] indices, ref uint[] shadowIndices,
                          ref float[4][] tangents, ref ubyte[4][] colors) {
    if (colors.length == 0 || colors.length != vertices.length) {
        colors = null;
        finalizeImportedMesh(assetPath, vertices, indices, shadowIndices, tangents);
    } else if (tangents.length == vertices.length) {
        optimizeColored(assetPath, packColors!ColorTanVert(vertices, tangents, colors), vertices, indices,
                        shadowIndices, tangents, colors);
    } else {
        optimizeColored(assetPath, packColors!ColorVert(vertices, null, colors), vertices, indices,
                        shadowIndices, tangents, colors);
    }
}

/// `generateMissingTangents` keeping one color per vertex.
void generateMissingTangents(string assetPath, ref TexVert[] vertices, ref uint[] indices, ref uint[] shadowIndices,
                             ref float[4][] tangents, ref ubyte[4][] colors) {
    if (colors.length == 0 || colors.length != vertices.length) {
        colors = null;
        generateMissingTangents(assetPath, vertices, indices, shadowIndices, tangents);
        return;
    }
    if (tangents.length == vertices.length || indices.length == 0) return;
    auto corners = new float[4][](indices.length);
    generateTangents(corners, indices, positionsOf!TexVert(vertices), positionsOf!(TexVert, "normal")(vertices),
                     uvStream(vertices), TangentOptions.compatible);
    auto expanded = new ColorTanVert[indices.length];
    auto expandedIdx = new uint[indices.length];
    foreach (i, id; indices) {
        expanded[i] = ColorTanVert(vertices[id].pos, vertices[id].normal, vertices[id].uv, corners[i], colors[id]);
        expandedIdx[i] = cast(uint) i;
    }
    indices = expandedIdx;
    optimizeColored(assetPath, expanded, vertices, indices, shadowIndices, tangents, colors);
}

/// `.meta` `settings.lod` of `assetPath` (disabled when absent or unreadable).
LodImport lodImportFor(string assetPath) @trusted {
    string metaPath = assetPath ~ ".meta";
    if (!exists(metaPath))
        return LodImport.init;
    try {
        return parseLodImport(parseJSON(cast(string) read(metaPath)));
    } catch (Exception) {
        return LodImport.init;
    }
}

/// Upload an imported mesh, building a LOD chain when `.meta` asks for one.
TexMesh uploadImportedMesh(ref GpuContext gpu, string assetPath, const(TexVert)[] vertices,
                           const(uint)[] indices, const(uint)[] shadowIndices, const(float[4])[] tangents,
                           const(ubyte[4])[] colors = null) {
    immutable lod = lodImportFor(assetPath);
    if (lod.enabled)
        return uploadLodMesh(gpu, vertices, indices, shadowIndices, tangents, lod.settings, colors);
    return uploadOptimizedMesh(gpu, vertices, indices, shadowIndices, tangents, colors);
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
TexMesh uploadOptimizedMesh(ref GpuContext gpu, const(TexVert)[] vertices, const(uint)[] indices, const(uint)[] shadowIndices, const(float[4])[] tangents, const(ubyte[4])[] colors = null) {
    auto mesh = uploadPlain(gpu, vertices, indices, shadowIndices, tangents);
    if (colors.length == vertices.length) mesh.setVertexColors(gpu, colors);
    return mesh;
}

private TexMesh uploadPlain(ref GpuContext gpu, const(TexVert)[] vertices, const(uint)[] indices,
                            const(uint)[] shadowIndices, const(float[4])[] tangents) {
    if (tangents.length == vertices.length && tangents.length > 0)
        return TexMesh.fromData(gpu, packTangents(vertices, tangents), indices, shadowIndices);
    return TexMesh.fromData(gpu, vertices, indices, shadowIndices);
}

/**
 * Build a simplified LOD chain at load time and upload it as one `TexMesh`
 * whose index buffer holds LOD0..N back to back (`TexMesh.setLodChain`).
 * The chain reorders the vertex buffer, so the position-welded shadow index
 * buffer is dropped; shadow passes use the next-coarser LOD range instead.
 */
TexMesh uploadLodMesh(ref GpuContext gpu, const(TexVert)[] vertices, const(uint)[] indices,
                      const(uint)[] shadowIndices, const(float[4])[] tangents,
                      LodSettings settings = LodSettings.init, const(ubyte[4])[] colors = null) {
    if (settings.maxLods > 8) settings.maxLods = 8;
    if (indices.length == 0 || vertices.length == 0)
        return uploadOptimizedMesh(gpu, vertices, indices, shadowIndices, tangents, colors);
    if (colors.length == vertices.length) {
        if (tangents.length == vertices.length)
            return uploadColorChain(gpu, buildLodChain(packColors!ColorTanVert(vertices, tangents, colors), indices, settings));
        return uploadColorChain(gpu, buildLodChain(packColors!ColorVert(vertices, null, colors), indices, settings));
    }
    if (tangents.length == vertices.length && tangents.length > 0)
        return uploadChain(gpu, buildLodChain(packTangents(vertices, tangents), indices, settings));
    return uploadChain(gpu, buildLodChain(vertices, indices, settings));
}

/// Concatenate LOD index lists; writes each level's first index, count and error.
uint[] concatLodLevels(scope const(LodLevel!uint)[] levels, scope uint[] first, scope uint[] counts,
                       scope float[] errors) pure {
    assert(first.length >= levels.length && counts.length >= levels.length && errors.length >= levels.length);
    uint[] concat;
    foreach (i, ref level; levels) {
        first[i] = cast(uint) concat.length;
        counts[i] = cast(uint) level.indices.length;
        errors[i] = level.error;
        concat ~= level.indices;
    }
    return concat;
}

private TexMesh uploadChain(V)(ref GpuContext gpu, LodChain!(V, uint) chain) {
    immutable n = chain.levels.length > 8 ? 8 : chain.levels.length;
    uint[8] first, counts;
    float[8] errors;
    auto concat = concatLodLevels(chain.levels[0 .. n], first[], counts[], errors[]);
    // LOD0 is the full mesh: test it alone, not the concatenated chain.
    import engine.graphics.closed_mesh : Closedness, isClosedMesh;
    immutable closed = n > 0 && isClosedMesh(chain.vertices, chain.levels[0].indices) ? Closedness.closed : Closedness.open;
    auto mesh = TexMesh.fromData(gpu, chain.vertices, concat, null, closed);
    mesh.setLodChain(first[0 .. n], counts[0 .. n], errors[0 .. n], simplifyScale(positionsOf!V(chain.vertices)));
    return mesh;
}

private TexMesh uploadColorChain(V)(ref GpuContext gpu, LodChain!(V, uint) chain) {
    TexVert[] vertices;
    float[4][] tangents;
    ubyte[4][] colors;
    unpackColors(chain.vertices, vertices, tangents, colors);
    static if (is(V == ColorTanVert))
        auto mesh = uploadChain(gpu, LodChain!(TexTanVert, uint)(packTangents(vertices, tangents), chain.levels));
    else
        auto mesh = uploadChain(gpu, LodChain!(TexVert, uint)(vertices, chain.levels));
    mesh.setVertexColors(gpu, colors);
    return mesh;
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

@("gltfOptimize.concatLodLevels") @safe unittest {
    LodLevel!uint[3] levels;
    levels[0].indices = [0, 1, 2, 2, 3, 0];
    levels[0].error = 0;
    levels[1].indices = [0, 1, 2];
    levels[1].error = 0.01f;
    levels[2].indices = [];
    levels[2].error = 0.2f;
    uint[3] first, counts;
    float[3] errors;
    auto concat = concatLodLevels(levels[], first[], counts[], errors[]);
    assert(concat == [0, 1, 2, 2, 3, 0, 0, 1, 2]);
    assert(first == [0, 6, 9] && counts == [6, 3, 0]);
    assert(errors[1] == 0.01f && errors[2] == 0.2f);
}

@("gltfOptimize.lodImport") @safe unittest {
    auto none = parseLodImport(parseJSON(`{"guid":"x","settings":{}}`));
    assert(!none.enabled);
    auto on = parseLodImport(parseJSON(`{"settings":{"lod":{"enabled":true,"maxLods":12,"ratio":0.4,"maxError":0.1}}}`));
    assert(on.enabled && on.settings.maxLods == 8);
    assert(on.settings.ratio > 0.39f && on.settings.ratio < 0.41f);
    assert(on.settings.maxError > 0.09f && on.settings.maxError < 0.11f);
    auto defaults = parseLodImport(parseJSON(`{"settings":{"lod":{"enabled":true}}}`));
    assert(defaults.enabled && defaults.settings.maxLods == LodSettings.init.maxLods);
}

@("vertexColors.optimize") unittest {
    // Same position, two colors: the seam must survive the reindex.
    TexVert[] verts = [
        TexVert([0, 0, 0], [0, 1, 0], [0, 0]), TexVert([1, 0, 0], [0, 1, 0], [1, 0]),
        TexVert([0, 0, 1], [0, 1, 0], [0, 1]), TexVert([1, 0, 0], [0, 1, 0], [1, 0]),
        TexVert([1, 0, 1], [0, 1, 0], [1, 1]), TexVert([0, 0, 1], [0, 1, 0], [0, 1]),
    ];
    ubyte[4] red = [255, 0, 0, 255], blue = [0, 0, 255, 128];
    foreach (withTangents; [false, true]) {
        auto v = verts.dup;
        uint[] idx = [0, 2, 1, 3, 5, 4];
        uint[] shadow;
        float[4][] tangents;
        ubyte[4][] colors = [red, red, red, blue, blue, blue];
        finalizeImportedMesh("/nonexistent/a.gltf", v, idx, shadow, tangents, colors);
        if (withTangents) generateMissingTangents("/nonexistent/a.gltf", v, idx, shadow, tangents, colors);
        assert(v.length == 6 && colors.length == 6 && tangents.length == (withTangents ? 6 : 0));
        foreach (t; 0 .. 2) {
            // The triangle touching the origin is the red one.
            bool origin = false;
            foreach (k; 0 .. 3) if (v[idx[t * 3 + k]].pos == [0.0f, 0, 0]) origin = true;
            foreach (k; 0 .. 3) assert(colors[idx[t * 3 + k]] == (origin ? red : blue));
        }
    }
    // Wrong count: colors are dropped.
    auto v = verts.dup;
    uint[] idx = [0, 2, 1];
    uint[] shadow;
    float[4][] tangents;
    ubyte[4][] colors = [red];
    finalizeImportedMesh("/nonexistent/a.gltf", v, idx, shadow, tangents, colors);
    assert(colors.length == 0);
}
