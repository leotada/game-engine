/// Import-time mesh optimization. This module may allocate with the GC.
/// Call it while loading or importing an asset, never from the frame loop.
module engine.meshopt.pipeline;

import engine.meshopt.analyze : analyzeOverdraw, analyzeVertexCache, analyzeVertexFetch;
import engine.meshopt.indexgen : generateShadowIndexBuffer, generateVertexRemap, remapIndexBuffer, remapVertexBuffer;
import engine.meshopt.overdraw : optimizeOverdraw;
import engine.meshopt.types : FloatStream, positionsOf;
import engine.meshopt.vcache : optimizeVertexCache;
import engine.meshopt.vfetch : optimizeVertexFetch;

@safe:

/// Switches for one import-time optimization pass.
struct MeshOptSettings {
    bool reindex = true;
    bool vertexCache = true;
    /// `0` skips `optimizeOverdraw`. The upstream default is 1.05.
    float overdrawThreshold = 1.05f;
    bool vertexFetch = true;
    /// Position-only index buffer for the shadow pass. Empty when off.
    bool shadowIndices = true;
}

/// ACMR, ATVR, overfetch, and overdraw for one index buffer.
struct MeshStats {
    uint vertexCount;
    uint indexCount;
    float acmr;
    float atvr;
    float overfetch;
    float overdraw;
}

/// Optimized copy of a mesh. `shadowIndices` indexes `vertices` and is empty when disabled.
struct OptimizedMesh(V, I) {
    V[] vertices;
    I[] indices;
    I[] shadowIndices;
    MeshStats before;
    MeshStats after;
}

/**
 * Reindex, optimize for the vertex cache and overdraw, compact the vertex
 * buffer, and build a position-only shadow index buffer.
 *
 * `V.pos` is a `float[3]` at offset 0. `I` is `ushort` or `uint`.
 * The result is a new set of arrays; `verts` and `indices` are not modified.
 */
OptimizedMesh!(V, I) optimizeMesh(V, I)(const(V)[] verts, const(I)[] indices, const MeshOptSettings settings = MeshOptSettings.init)
if ((is(I == ushort) || is(I == uint)) && is(typeof(V.init.pos) == float[3]) && V.pos.offsetof == 0 && V.sizeof % 4 == 0 && V.sizeof > 0 && V.sizeof <= 256) {
    assert(indices.length % 3 == 0);
    OptimizedMesh!(V, I) result;
    result.before = measure!(V, I)(verts, indices);

    V[] v = verts.dup;
    I[] idx = indices.dup;

    // An empty index slice is the unindexed case inside generateVertexRemap.
    if (settings.reindex && idx.length > 0 && v.length > 0) {
        uint[] remap = new uint[v.length];
        size_t unique = generateVertexRemap(remap, idx, vertexBytes(v), V.sizeof);
        static if (is(I == ushort))
            assert(unique <= 65536, "ushort remap does not fit; optimize with uint indices");
        V[] remapped = new V[v.length];
        remapVertexBuffer(mutableBytes(remapped), vertexBytes(v), v.length, V.sizeof, remap);
        I[] remappedIdx = new I[idx.length];
        remapIndexBuffer(remappedIdx, idx, remap);
        v = remapped[0 .. unique];
        idx = remappedIdx;
    }

    if (settings.vertexCache && idx.length > 0 && v.length > 0)
        optimizeVertexCache(idx, idx, v.length);

    if (settings.overdrawThreshold > 0 && idx.length > 0 && v.length > 0)
        optimizeOverdraw(idx, idx, positionsOf!V(v), settings.overdrawThreshold);

    if (settings.vertexFetch && idx.length > 0 && v.length > 0) {
        V[] compacted = new V[v.length];
        size_t fetched = optimizeVertexFetch(mutableBytes(compacted), idx, vertexBytes(v), v.length, V.sizeof);
        v = compacted[0 .. fetched];
    }

    if (settings.shadowIndices && idx.length > 0 && v.length > 0) {
        result.shadowIndices = new I[idx.length];
        generateShadowIndexBuffer(result.shadowIndices, idx, vertexBytes(v), v.length, float[3].sizeof, V.sizeof);
    }

    result.vertices = v;
    result.indices = idx;
    result.after = measure!(V, I)(v, idx);
    return result;
}

/// Every index is representable as `ushort` (`<= 65535`).
bool indicesFitU16(I)(scope const(I)[] indices) pure nothrow @nogc
if (is(I == ushort) || is(I == uint)) {
    foreach (i; indices) {
        if (i > 65535)
            return false;
    }
    return true;
}

private MeshStats measure(V, I)(const(V)[] verts, const(I)[] indices)
if ((is(I == ushort) || is(I == uint)) && is(typeof(V.init.pos) == float[3])) {
    MeshStats s;
    s.vertexCount = cast(uint) verts.length;
    s.indexCount = cast(uint) indices.length;
    s.acmr = 0;
    s.atvr = 0;
    s.overfetch = 0;
    s.overdraw = 0;
    if (indices.length == 0 || verts.length == 0)
        return s;
    auto cache = analyzeVertexCache(indices, verts.length);
    s.acmr = cache.acmr;
    s.atvr = cache.atvr;
    s.overfetch = analyzeVertexFetch(indices, verts.length, V.sizeof).overfetch;
    // The rasterizer takes `uint` indices. Copy the ushort buffer.
    static if (is(I == uint)) {
        s.overdraw = analyzeOverdraw(indices, positionsOf!V(verts)).overdraw;
    } else {
        uint[] wide = new uint[indices.length];
        foreach (i, index; indices)
            wide[i] = index;
        s.overdraw = analyzeOverdraw(wide, positionsOf!V(verts)).overdraw;
    }
    return s;
}

private const(ubyte)[] vertexBytes(V)(const(V)[] verts) nothrow @trusted {
    if (verts.length == 0)
        return null;
    return (cast(const(ubyte)*) verts.ptr)[0 .. verts.length * V.sizeof];
}

private ubyte[] mutableBytes(V)(V[] verts) nothrow @trusted {
    if (verts.length == 0)
        return null;
    return (cast(ubyte*) verts.ptr)[0 .. verts.length * V.sizeof];
}

@("optimizeMesh.weld") unittest {
    static struct V {
        float[3] pos;
        float[3] nrm;
    }

    V[] verts = [
        V([0, 0, 0], [0, 1, 0]),
        V([1, 0, 0], [0, 1, 0]),
        V([0, 0, 1], [0, 1, 0]),
        V([0, 0, 0], [0, 1, 0]),
    ];
    uint[] idx = [0, 1, 2, 3, 1, 2];
    auto opt = optimizeMesh(verts, idx);
    assert(opt.vertices.length == 3);
    assert(opt.indices.length == 6);
    assert(opt.shadowIndices.length == 6);
    assert(opt.before.vertexCount == 4);
    assert(opt.after.vertexCount == 3);
    assert(opt.after.indexCount == 6);
    foreach (i; opt.indices)
        assert(i < opt.vertices.length);
    foreach (i; opt.shadowIndices)
        assert(i < opt.vertices.length);

    ushort[] idx16 = [0, 1, 2, 3, 1, 2];
    auto opt16 = optimizeMesh(verts, idx16);
    assert(opt16.vertices.length == 3);
    assert(opt16.indices.length == 6);
}

@("optimizeMesh.disabled") unittest {
    static struct V {
        float[3] pos;
    }

    V[] verts = [V([0, 0, 0]), V([1, 0, 0]), V([0, 1, 0])];
    uint[] idx = [0, 1, 2];
    MeshOptSettings off;
    off.reindex = false;
    off.vertexCache = false;
    off.overdrawThreshold = 0;
    off.vertexFetch = false;
    off.shadowIndices = false;
    auto opt = optimizeMesh(verts, idx, off);
    assert(opt.vertices.length == 3);
    assert(opt.indices == idx);
    assert(opt.shadowIndices.length == 0);
    assert(opt.vertices[0].pos == [0, 0, 0]);
    assert(opt.vertices[1].pos == [1, 0, 0]);
    assert(opt.vertices[2].pos == [0, 1, 0]);
}

@("indicesFitU16") unittest {
    assert(indicesFitU16([0u, 65535u]));
    assert(!indicesFitU16([65536u]));
    ushort[] narrow = [0, 1, 2];
    assert(indicesFitU16(narrow));
}
