/// Import-time mesh optimization. This module may allocate with the GC.
/// Call it while loading or importing an asset, never from the frame loop.
module engine.meshopt.pipeline;

import engine.meshopt.analyze : analyzeOverdraw, analyzeVertexCache, analyzeVertexFetch;
import engine.meshopt.indexgen : generateShadowIndexBuffer, generateVertexRemap, remapIndexBuffer, remapVertexBuffer;
import engine.meshopt.overdraw : optimizeOverdraw;
import engine.meshopt.simplify : simplify, simplifyPoints, simplifyScale, simplifySloppy, simplifyWithAttributes;
import engine.meshopt.types : FloatStream, SimplifyOptions, positionsOf;
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

private ulong floatAddress(scope const(float)[] data) nothrow @nogc @trusted {
    return data.length ? cast(ulong) data.ptr : 0;
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

/// Per-level target for `buildLodChain`. `error` is mesh-relative (simplify's linear error).
struct LodSettings {
    uint maxLods = 5;
    /// Target index-count multiplier for each coarser level.
    float ratio = 0.5f;
    /// Relative error cap passed to the simplifier.
    float maxError = 0.05f;
    /// Weight normals and uvs when the vertex type has them.
    bool attributes = true;
    float normalWeight = 0.5f;
    float uvWeight = 0.25f;
    /// Use `simplifySloppy` when topology blocks a 10% reduction.
    bool sloppyFallback = true;
}

/// One LOD. Indices address the chain's shared vertex buffer.
struct LodLevel(I) {
    I[] indices;
    float error;
}

/// Shared vertices plus LOD0..N index ranges. Built at import time, never per frame.
struct LodChain(V, I) {
    V[] vertices;
    LodLevel!(I)[] levels;
}

/**
 * Build a LOD chain. LOD0 is the input. Each coarser level targets `ratio` of the
 * previous index count and stops at `maxError`. One `optimizeVertexFetch` then
 * reorders the shared vertex buffer for the concatenated index ranges.
 */
LodChain!(V, I) buildLodChain(V, I)(const(V)[] verts, const(I)[] indices, const LodSettings settings = LodSettings.init)
if ((is(I == ushort) || is(I == uint)) && is(typeof(V.init.pos) == float[3]) && V.pos.offsetof == 0 && V.sizeof % 4 == 0 && V.sizeof > 0 && V.sizeof <= 256) {
    assert(indices.length % 3 == 0);
    LodChain!(V, I) chain;
    if (indices.length == 0 || verts.length == 0 || settings.maxLods == 0)
        return chain;

    uint[] current = new uint[indices.length];
    foreach (i, index; indices)
        current[i] = index;

    static if (is(typeof(V.init.normal) == float[3]) && is(typeof(V.init.uv) == float[2]))
        enum hasAttr = true;
    else
        enum hasAttr = false;

    float[] packed;
    float[] weights;
    FloatStream attributes;
    static if (hasAttr) {
        if (settings.attributes) {
            enum attrCount = 5;
            packed = new float[verts.length * attrCount];
            weights = [settings.normalWeight, settings.normalWeight, settings.normalWeight, settings.uvWeight, settings.uvWeight];
            foreach (i, v; verts) {
                packed[i * attrCount + 0] = v.normal[0];
                packed[i * attrCount + 1] = v.normal[1];
                packed[i * attrCount + 2] = v.normal[2];
                packed[i * attrCount + 3] = v.uv[0];
                packed[i * attrCount + 4] = v.uv[1];
            }
            attributes.strideFloats = attrCount;
            attributes.count = verts.length;
            attributes.address = floatAddress(packed);
        }
    }

    FloatStream positions = positionsOf!V(verts);
    uint[][] raw;
    float[] errors;
    raw ~= current.dup;
    errors ~= 0;

    while (raw.length < settings.maxLods) {
        size_t previous = current.length;
        size_t target = cast(size_t)(previous * settings.ratio);
        target -= target % 3;
        if (target >= previous || previous < 6)
            break;
        uint[] dst = new uint[previous];
        float[1] err;
        size_t n;
        static if (hasAttr) {
            if (settings.attributes)
                n = simplifyWithAttributes(dst, current, positions, attributes, weights, null, target, settings.maxError, SimplifyOptions.none, err[]);
            else
                n = simplify(dst, current, positions, target, settings.maxError, SimplifyOptions.none, err[]);
        } else {
            n = simplify(dst, current, positions, target, settings.maxError, SimplifyOptions.none, err[]);
        }
        if (settings.sloppyFallback && n * 10 > previous * 9) {
            float[1] sloppyError;
            uint[] sloppy = new uint[previous];
            size_t sn = simplifySloppy(sloppy, current, positions, null, target, settings.maxError, sloppyError[]);
            if (sn < n && sn > 0) {
                n = sn;
                dst = sloppy;
                err[0] = sloppyError[0];
            }
        }
        if (n == 0 || n >= previous)
            break;
        current = dst[0 .. n].dup;
        raw ~= current;
        errors ~= err[0];
    }

    uint[] concat;
    foreach (level; raw)
        concat ~= level;
    V[] compacted = new V[verts.length];
    size_t fetched = optimizeVertexFetch(mutableBytes(compacted), concat, vertexBytes(verts), verts.length, V.sizeof);
    chain.vertices = compacted[0 .. fetched];
    size_t cursor = 0;
    foreach (i, level; raw) {
        LodLevel!I lod;
        lod.error = errors[i];
        lod.indices = new I[level.length];
        foreach (k; 0 .. level.length)
            lod.indices[k] = cast(I) concat[cursor + k];
        cursor += level.length;
        chain.levels ~= lod;
    }
    return chain;
}

/// Baked collision stand-in. Triangles index the source vertices. Not a render-mesh path.
struct CollisionProxy {
    uint[] triangles;
    float error;
    float[3][] hullPoints;
}

/**
 * Import-time collision proxy. Border-locked `simplify` builds the triangle list;
 * `simplifySloppy` is the fallback when topology will not reach the budget.
 * `simplifyPoints` decimates positions for a convex-hull input.
 */
CollisionProxy buildCollisionProxy(V)(const(V)[] verts, const(uint)[] indices, size_t targetIndexCount, size_t hullVertices)
if (is(typeof(V.init.pos) == float[3]) && V.pos.offsetof == 0 && V.sizeof % 4 == 0) {
    CollisionProxy proxy;
    if (indices.length == 0 || verts.length == 0)
        return proxy;
    FloatStream positions = positionsOf!V(verts);
    uint[] dst = new uint[indices.length];
    float[1] err;
    size_t n = simplify(dst, indices, positions, targetIndexCount, 0.05f, SimplifyOptions.lockBorder, err[]);
    if (n > targetIndexCount && targetIndexCount < indices.length) {
        float[1] sloppyError;
        uint[] sloppy = new uint[indices.length];
        size_t sn = simplifySloppy(sloppy, indices, positions, null, targetIndexCount, 0.05f, sloppyError[]);
        if (sn < n) {
            n = sn;
            dst = sloppy;
            err[0] = sloppyError[0];
        }
    }
    proxy.triangles = dst[0 .. n].dup;
    proxy.error = err[0];
    size_t hull = hullVertices == 0 ? 0 : (hullVertices < verts.length ? hullVertices : verts.length);
    if (hull > 0) {
        uint[] ids = new uint[hull];
        size_t kept = simplifyPoints(ids, positions, FloatStream.init, 1.0f, hull);
        proxy.hullPoints = new float[3][kept];
        foreach (i; 0 .. kept) {
            uint id = ids[i];
            proxy.hullPoints[i] = verts[id].pos;
        }
    }
    return proxy;
}

@("buildLodChain.grid") unittest {
    static struct V {
        float[3] pos;
        float[3] normal;
        float[2] uv;
    }

    enum uint n = 8;
    V[] verts;
    verts.length = (n + 1) * (n + 1);
    foreach (z; 0 .. n + 1) {
        foreach (x; 0 .. n + 1) {
            size_t i = z * (n + 1) + x;
            verts[i].pos = [x, 0, z];
            verts[i].normal = [0, 1, 0];
            verts[i].uv = [cast(float) x / n, cast(float) z / n];
        }
    }
    uint[] idx;
    idx.length = n * n * 6;
    size_t t = 0;
    foreach (z; 0 .. n) {
        foreach (x; 0 .. n) {
            uint a = cast(uint)(z * (n + 1) + x);
            uint b = a + 1;
            uint c = a + n + 1;
            uint d = c + 1;
            idx[t .. t + 6] = [a, c, b, b, c, d];
            t += 6;
        }
    }
    LodSettings settings;
    settings.maxLods = 4;
    settings.ratio = 0.5f;
    settings.maxError = 0.05f;
    auto chain = buildLodChain(verts, idx, settings);
    assert(chain.levels.length >= 2);
    assert(chain.levels[0].indices.length == idx.length);
    assert(chain.levels[0].error == 0);
    assert(chain.levels[1].indices.length < chain.levels[0].indices.length);
    assert(chain.levels[1].indices.length % 3 == 0);
    foreach (level; chain.levels) {
        foreach (i; level.indices)
            assert(i < chain.vertices.length);
    }
    // Measured on this 128-triangle grid: the second level is at most half the indices.
    assert(chain.levels[1].indices.length * 2 <= chain.levels[0].indices.length + 3);

    auto proxy = buildCollisionProxy(chain.vertices, chain.levels[0].indices, idx.length / 4, 8);
    assert(proxy.triangles.length % 3 == 0);
    assert(proxy.triangles.length < idx.length);
    assert(proxy.hullPoints.length > 0 && proxy.hullPoints.length <= 8);
}
