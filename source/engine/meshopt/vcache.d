// Ported from meshoptimizer v1.3 (src/vcacheoptimizer.cpp), Copyright (c) 2016-2026 Arseny Kapoulkine, MIT License.
/// Vertex-cache optimization: score table, strip scores, and Tipsify FIFO.
module engine.meshopt.vcache;

import engine.meshopt.scratch : MeshoptScratch, defaultScratch;
import engine.meshopt.types : FloatStream;

@safe:

private enum bool isIndex(I) = is(I == uint) || is(I == ushort);
private enum cacheSizeMax = 16;
private enum valenceMax = 8;

private struct VertexScoreTable {
    float[1 + cacheSizeMax] cache;
    float[1 + valenceMax] live;
}

// Tuned for a GPU cache profile similar to NVIDIA and AMD.
private immutable VertexScoreTable kVertexScoreTable = VertexScoreTable(
    [0, 0.779f, 0.791f, 0.789f, 0.981f, 0.843f, 0.726f, 0.847f, 0.882f, 0.867f, 0.799f, 0.642f, 0.613f, 0.600f, 0.568f, 0.372f, 0.234f],
    [0, 0.995f, 0.713f, 0.450f, 0.404f, 0.059f, 0.005f, 0.147f, 0.006f],
);

// Tuned to minimize the encoded index buffer size.
private immutable VertexScoreTable kVertexScoreTableStrip = VertexScoreTable(
    [0, 1.000f, 1.000f, 1.000f, 0.453f, 0.561f, 0.490f, 0.459f, 0.179f, 0.526f, 0.000f, 0.227f, 0.184f, 0.490f, 0.112f, 0.050f, 0.131f],
    [0, 0.956f, 0.786f, 0.577f, 0.558f, 0.618f, 0.549f, 0.499f, 0.489f],
);

private struct TriangleAdjacency {
    uint[] counts;
    uint[] offsets;
    uint[] data;
}

private void buildTriangleAdjacency(ref TriangleAdjacency adjacency, const(uint)[] indices, size_t vertexCount, ref MeshoptScratch scratch) {
    size_t indexCount = indices.length;
    size_t faceCount = indexCount / 3;
    adjacency.counts = scratch.allocate!uint(vertexCount);
    adjacency.offsets = scratch.allocate!uint(vertexCount);
    adjacency.data = scratch.allocate!uint(indexCount);
    adjacency.counts[] = 0;
    foreach (index; indices) {
        assert(index < vertexCount);
        adjacency.counts[index]++;
    }
    uint offset = 0;
    foreach (i; 0 .. vertexCount) {
        adjacency.offsets[i] = offset;
        offset += adjacency.counts[i];
    }
    assert(offset == indexCount);
    foreach (i; 0 .. faceCount) {
        uint a = indices[i * 3 + 0], b = indices[i * 3 + 1], c = indices[i * 3 + 2];
        adjacency.data[adjacency.offsets[a]++] = cast(uint) i;
        adjacency.data[adjacency.offsets[b]++] = cast(uint) i;
        adjacency.data[adjacency.offsets[c]++] = cast(uint) i;
    }
    foreach (i; 0 .. vertexCount) {
        assert(adjacency.offsets[i] >= adjacency.counts[i]);
        adjacency.offsets[i] -= adjacency.counts[i];
    }
}

private uint getNextVertexDeadEnd(const(uint)[] deadEnd, ref uint deadEndTop, ref uint inputCursor, const(uint)[] liveTriangles, size_t vertexCount) {
    while (deadEndTop) {
        uint vertex = deadEnd[--deadEndTop];
        if (liveTriangles[vertex] > 0)
            return vertex;
    }
    while (inputCursor < vertexCount) {
        if (liveTriangles[inputCursor] > 0)
            return inputCursor;
        inputCursor++;
    }
    return uint.max;
}

private uint getNextVertexNeighbor(const(uint)[] nextCandidates, const(uint)[] liveTriangles, const(uint)[] cacheTimestamps, uint timestamp, uint cacheSize) {
    uint bestCandidate = uint.max;
    int bestPriority = -1;
    foreach (vertex; nextCandidates) {
        if (liveTriangles[vertex] > 0) {
            int priority = 0;
            if (2 * liveTriangles[vertex] + timestamp - cacheTimestamps[vertex] <= cacheSize)
                priority = cast(int)(timestamp - cacheTimestamps[vertex]);
            if (priority > bestPriority) {
                bestCandidate = vertex;
                bestPriority = priority;
            }
        }
    }
    return bestCandidate;
}

private float vertexScore(const(VertexScoreTable) table, int cachePosition, uint liveTriangles) {
    assert(cachePosition >= -1 && cachePosition < cacheSizeMax);
    uint clamped = liveTriangles < valenceMax ? liveTriangles : valenceMax;
    return table.cache[1 + cachePosition] + table.live[clamped];
}

private uint getNextTriangleDeadEnd(ref uint inputCursor, const(ubyte)[] emitted, size_t faceCount) {
    while (inputCursor < faceCount) {
        if (!emitted[inputCursor])
            return inputCursor;
        inputCursor++;
    }
    return uint.max;
}

private void optimizeTable(I)(scope I[] destination, scope const(I)[] indices, size_t vertexCount, const(VertexScoreTable) table, ref MeshoptScratch scratch) {
    assert(indices.length % 3 == 0);
    assert(destination.length >= indices.length);
    if (indices.length == 0 || vertexCount == 0)
        return;
    immutable m = scratch.mark();
    scope (exit)
        scratch.release(m);
    const(I)[] src = indices;
    if (samePtr(destination, indices)) {
        I[] copy = scratch.allocate!I(indices.length);
        copy[] = indices[];
        src = copy;
    }
    uint[] idx = scratch.allocate!uint(src.length);
    foreach (i, v; src)
        idx[i] = v;

    enum uint cacheSize = 16;
    size_t faceCount = idx.length / 3;
    TriangleAdjacency adjacency;
    buildTriangleAdjacency(adjacency, idx, vertexCount, scratch);
    uint[] liveTriangles = adjacency.counts;
    ubyte[] emitted = scratch.allocate!ubyte(faceCount);
    emitted[] = 0;
    float[] vertexScores = scratch.allocate!float(vertexCount);
    foreach (i; 0 .. vertexCount)
        vertexScores[i] = vertexScore(table, -1, liveTriangles[i]);
    float[] triangleScores = scratch.allocate!float(faceCount);
    foreach (i; 0 .. faceCount) {
        uint a = idx[i * 3 + 0], b = idx[i * 3 + 1], c = idx[i * 3 + 2];
        triangleScores[i] = vertexScores[a] + vertexScores[b] + vertexScores[c];
    }

    uint[2 * (cacheSizeMax + 4)] holder;
    size_t cacheAt = 0;
    size_t cacheNewAt = cacheSizeMax + 4;
    size_t cacheCount = 0;
    uint currentTriangle = 0;
    uint inputCursor = 1;
    uint outputTriangle = 0;

    while (currentTriangle != uint.max) {
        assert(outputTriangle < faceCount);
        uint a = idx[currentTriangle * 3 + 0];
        uint b = idx[currentTriangle * 3 + 1];
        uint c = idx[currentTriangle * 3 + 2];
        destination[outputTriangle * 3 + 0] = cast(I) a;
        destination[outputTriangle * 3 + 1] = cast(I) b;
        destination[outputTriangle * 3 + 2] = cast(I) c;
        outputTriangle++;
        emitted[currentTriangle] = 1;
        triangleScores[currentTriangle] = 0;

        size_t cacheWrite = 0;
        holder[cacheNewAt + cacheWrite++] = a;
        holder[cacheNewAt + cacheWrite++] = b;
        holder[cacheNewAt + cacheWrite++] = c;
        foreach (i; 0 .. cacheCount) {
            uint index = holder[cacheAt + i];
            holder[cacheNewAt + cacheWrite] = index;
            cacheWrite += (index != a && index != b && index != c) ? 1 : 0;
        }
        size_t tmp = cacheAt;
        cacheAt = cacheNewAt;
        cacheNewAt = tmp;
        cacheCount = cacheWrite > cacheSize ? cacheSize : cacheWrite;

        foreach (k; 0 .. 3) {
            uint index = idx[currentTriangle * 3 + k];
            uint[] neighbors = adjacency.data[adjacency.offsets[index] .. adjacency.offsets[index] + adjacency.counts[index]];
            size_t neighborsSize = adjacency.counts[index];
            foreach (i; 0 .. neighborsSize) {
                uint tri = neighbors[i];
                if (tri == currentTriangle) {
                    neighbors[i] = neighbors[neighborsSize - 1];
                    adjacency.counts[index]--;
                    break;
                }
            }
        }

        uint bestTriangle = uint.max;
        float bestScore = 0;
        foreach (i; 0 .. cacheWrite) {
            uint index = holder[cacheAt + i];
            if (adjacency.counts[index] == 0)
                continue;
            int cachePosition = i >= cacheSize ? -1 : cast(int) i;
            float score = vertexScore(table, cachePosition, liveTriangles[index]);
            float scoreDiff = score - vertexScores[index];
            vertexScores[index] = score;
            const(uint)[] nb = adjacency.data[adjacency.offsets[index] .. adjacency.offsets[index] + adjacency.counts[index]];
            foreach (tri; nb) {
                assert(!emitted[tri]);
                float triScore = triangleScores[tri] + scoreDiff;
                assert(triScore > 0);
                bestTriangle = bestScore < triScore ? tri : bestTriangle;
                bestScore = bestScore < triScore ? triScore : bestScore;
                triangleScores[tri] = triScore;
            }
        }
        currentTriangle = bestTriangle;
        if (currentTriangle == uint.max)
            currentTriangle = getNextTriangleDeadEnd(inputCursor, emitted, faceCount);
    }
    assert(inputCursor == faceCount);
    assert(outputTriangle == faceCount);
}

/// Forsyth-style vertex cache reorder. `destination` may alias `indices`.
void optimizeVertexCache(I)(scope I[] destination, scope const(I)[] indices, size_t vertexCount, ref MeshoptScratch scratch = defaultScratch())
if (isIndex!I) {
    optimizeTable(destination, indices, vertexCount, kVertexScoreTable, scratch);
}

/// Same search as `optimizeVertexCache`, scored to shrink a later index encoding.
void optimizeVertexCacheStrip(I)(scope I[] destination, scope const(I)[] indices, size_t vertexCount, ref MeshoptScratch scratch = defaultScratch())
if (isIndex!I) {
    optimizeTable(destination, indices, vertexCount, kVertexScoreTableStrip, scratch);
}

/// Tipsify FIFO reorder. `cacheSize >= 3`.
void optimizeVertexCacheFifo(I)(scope I[] destination, scope const(I)[] indices, size_t vertexCount, uint cacheSize, ref MeshoptScratch scratch = defaultScratch())
if (isIndex!I) {
    assert(indices.length % 3 == 0);
    assert(cacheSize >= 3);
    assert(destination.length >= indices.length);
    if (indices.length == 0 || vertexCount == 0)
        return;
    immutable m = scratch.mark();
    scope (exit)
        scratch.release(m);
    const(I)[] src = indices;
    if (samePtr(destination, indices)) {
        I[] copy = scratch.allocate!I(indices.length);
        copy[] = indices[];
        src = copy;
    }
    uint[] idx = scratch.allocate!uint(src.length);
    foreach (i, v; src)
        idx[i] = v;

    size_t faceCount = idx.length / 3;
    TriangleAdjacency adjacency;
    buildTriangleAdjacency(adjacency, idx, vertexCount, scratch);
    uint[] liveTriangles = scratch.allocate!uint(vertexCount);
    liveTriangles[] = adjacency.counts[];
    uint[] cacheTimestamps = scratch.allocate!uint(vertexCount);
    cacheTimestamps[] = 0;
    uint[] deadEnd = scratch.allocate!uint(idx.length);
    uint deadEndTop = 0;
    ubyte[] emitted = scratch.allocate!ubyte(faceCount);
    emitted[] = 0;
    uint currentVertex = 0;
    uint timestamp = cacheSize + 1;
    uint inputCursor = 1;
    uint outputTriangle = 0;

    while (currentVertex != uint.max) {
        size_t nextBegin = deadEndTop;
        const(uint)[] neighbors = adjacency.data[adjacency.offsets[currentVertex] .. adjacency.offsets[currentVertex] + adjacency.counts[currentVertex]];
        foreach (triangle; neighbors) {
            if (!emitted[triangle]) {
                uint a = idx[triangle * 3 + 0], b = idx[triangle * 3 + 1], c = idx[triangle * 3 + 2];
                destination[outputTriangle * 3 + 0] = cast(I) a;
                destination[outputTriangle * 3 + 1] = cast(I) b;
                destination[outputTriangle * 3 + 2] = cast(I) c;
                outputTriangle++;
                deadEnd[deadEndTop + 0] = a;
                deadEnd[deadEndTop + 1] = b;
                deadEnd[deadEndTop + 2] = c;
                deadEndTop += 3;
                liveTriangles[a]--;
                liveTriangles[b]--;
                liveTriangles[c]--;
                if (timestamp - cacheTimestamps[a] > cacheSize)
                    cacheTimestamps[a] = timestamp++;
                if (timestamp - cacheTimestamps[b] > cacheSize)
                    cacheTimestamps[b] = timestamp++;
                if (timestamp - cacheTimestamps[c] > cacheSize)
                    cacheTimestamps[c] = timestamp++;
                emitted[triangle] = 1;
            }
        }
        currentVertex = getNextVertexNeighbor(deadEnd[nextBegin .. deadEndTop], liveTriangles, cacheTimestamps, timestamp, cacheSize);
        if (currentVertex == uint.max)
            currentVertex = getNextVertexDeadEnd(deadEnd, deadEndTop, inputCursor, liveTriangles, vertexCount);
    }
    assert(outputTriangle == faceCount);
}

private bool samePtr(I)(scope const(I)[] a, scope const(I)[] b) nothrow @nogc @trusted {
    return a.length > 0 && a.ptr is b.ptr;
}

@("emptyMesh") unittest {
    uint[0] empty;
    optimizeVertexCache(empty[], empty[], 0);
    optimizeVertexCacheStrip(empty[], empty[], 0);
    optimizeVertexCacheFifo(empty[], empty[], 0, 16);
}

@("m2.golden") @trusted unittest {
    import engine.meshopt.analyze;
    import engine.meshopt.internal.bits : bitsFloat;
    import engine.meshopt.overdraw;
    import engine.meshopt.quantize : goldenParamsHash;
    import engine.meshopt.stripify;
    import engine.meshopt.types : FloatStream;
    import engine.meshopt.vfetch;
    import std.file : dirEntries, read, SpanMode;
    import std.path : baseName, stripExtension;

    string[] names = [
        "optimizeVertexCache", "optimizeVertexCacheStrip", "optimizeVertexCacheFifo",
        "optimizeOverdraw", "optimizeVertexFetch", "optimizeVertexFetchRemap",
        "analyzeVertexCache", "analyzeVertexFetch", "analyzeOverdraw", "analyzeCoverage",
        "stripify",
    ];
    foreach (name; names) {
        int files;
        foreach (entry; dirEntries("tests/meshopt/golden/" ~ name, SpanMode.shallow)) {
            string path = entry.name;
            if (path.length < 4 || path[$ - 4 .. $] != ".bin")
                continue;
            checkM2(name, path, cast(ubyte[]) read(path), goldenParamsHash(name ~ "/" ~ stripExtension(baseName(path))));
            files++;
        }
        assert(files > 0, name);
    }
}

private void checkM2(string name, string path, const(ubyte)[] file, uint hash) {
    import engine.meshopt.analyze;
    import engine.meshopt.internal.bits : bitsFloat, floatBits;
    import engine.meshopt.overdraw;
    import engine.meshopt.stripify;
    import engine.meshopt.types : FloatStream;
    import engine.meshopt.vfetch;

    assert(file.length >= 52 && file[0 .. 8] == cast(const(ubyte)[]) "MOPTGLD1", path);
    assert(loadU32at(file, 44) == hash, path);
    G2 g;
    g.b = file[52 .. $];
    if (name == "optimizeVertexCache" || name == "optimizeVertexCacheStrip") {
        uint vc = g.u32(), ic = g.u32();
        uint[] indices = g.u32s(ic);
        uint[] expect = g.u32s(ic);
        uint[] dst = new uint[ic];
        if (name == "optimizeVertexCache")
            optimizeVertexCache(dst, indices, vc);
        else
            optimizeVertexCacheStrip(dst, indices, vc);
        assert(dst == expect, path);
    } else if (name == "optimizeVertexCacheFifo") {
        uint vc = g.u32(), ic = g.u32(), cache = g.u32();
        uint[] indices = g.u32s(ic);
        uint[] expect = g.u32s(ic);
        uint[] dst = new uint[ic];
        optimizeVertexCacheFifo(dst, indices, vc, cache);
        assert(dst == expect, path);
    } else if (name == "optimizeOverdraw") {
        uint vc = g.u32(), ic = g.u32(), stride = g.u32();
        float threshold = bitsFloat(g.u32());
        uint[] indices = g.u32s(ic);
        float[] pos = g.f32s(vc * stride);
        uint[] expect = g.u32s(ic);
        uint[] dst = new uint[ic];
        optimizeOverdraw(dst, indices, floatStream(pos, stride, vc), threshold);
        assert(dst == expect, path);
    } else if (name == "optimizeVertexFetch") {
        uint vc = g.u32(), size = g.u32(), ic = g.u32(), unique = g.u32();
        uint[] indices = g.u32s(ic);
        ubyte[] src = g.bytes(vc * size);
        uint[] expectI = g.u32s(ic);
        ubyte[] expectV = g.bytes(unique * size);
        ubyte[] dst = new ubyte[vc * size];
        uint[] idx = indices.dup;
        size_t n = optimizeVertexFetch(dst, idx, src, vc, size);
        assert(n == unique && idx == expectI && dst[0 .. n * size] == expectV, path);
    } else if (name == "optimizeVertexFetchRemap") {
        uint vc = g.u32(), ic = g.u32(), unique = g.u32();
        uint[] indices = g.u32s(ic);
        uint[] expect = g.u32s(vc);
        uint[] dst = new uint[vc];
        assert(optimizeVertexFetchRemap(dst, indices, vc) == unique, path);
        assert(dst == expect, path);
    } else if (name == "analyzeVertexCache") {
        uint vc = g.u32(), ic = g.u32(), cache = g.u32(), warp = g.u32(), prim = g.u32();
        uint[] indices = g.u32s(ic);
        auto s = analyzeVertexCache(indices, vc, cache, warp, prim);
        assert(s.verticesTransformed == g.u32() && s.warpsExecuted == g.u32(), path);
        assert(floatBits(s.acmr) == g.u32() && floatBits(s.atvr) == g.u32(), path);
    } else if (name == "analyzeVertexFetch") {
        uint vc = g.u32(), ic = g.u32(), size = g.u32();
        uint[] indices = g.u32s(ic);
        auto s = analyzeVertexFetch(indices, vc, size);
        assert(s.bytesFetched == g.u32() && floatBits(s.overfetch) == g.u32(), path);
    } else if (name == "analyzeOverdraw") {
        uint vc = g.u32(), ic = g.u32(), stride = g.u32();
        uint[] indices = g.u32s(ic);
        float[] pos = g.f32s(vc * stride);
        auto s = analyzeOverdraw(indices, floatStream(pos, stride, vc));
        assert(s.pixelsCovered == g.u32() && s.pixelsShaded == g.u32(), path);
        assert(floatBits(s.overdraw) == g.u32(), path);
    } else if (name == "analyzeCoverage") {
        uint vc = g.u32(), ic = g.u32(), stride = g.u32();
        uint[] indices = g.u32s(ic);
        float[] pos = g.f32s(vc * stride);
        auto s = analyzeCoverage(indices, floatStream(pos, stride, vc));
        foreach (k; 0 .. 3)
            assert(floatBits(s.coverage[k]) == g.u32(), path);
        assert(floatBits(s.extent) == g.u32(), path);
    } else if (name == "stripify") {
        uint vc = g.u32(), ic = g.u32(), restart = g.u32(), sn = g.u32(), tn = g.u32();
        uint[] indices = g.u32s(ic);
        uint[] expectS = g.u32s(sn);
        uint[] expectT = g.u32s(tn);
        uint[] strip = new uint[stripifyBound(ic)];
        size_t n = stripify(strip, indices, vc, restart);
        assert(n == sn && strip[0 .. n] == expectS, path);
        uint[] tris = new uint[unstripifyBound(n == 0 ? 0 : n)];
        size_t t = n == 0 ? 0 : unstripify(tris, strip[0 .. n], restart);
        assert(t == tn && tris[0 .. t] == expectT, path);
    } else {
        assert(0, name);
    }
    assert(g.at == g.b.length, path);
}

private FloatStream floatStream(return scope const(float)[] data, size_t stride, size_t count) @trusted {
    FloatStream s;
    s.strideFloats = stride;
    s.count = count;
    if (count)
        s.address = cast(ulong) data.ptr;
    return s;
}

private struct G2 {
    const(ubyte)[] b;
    size_t at;
    uint u32() {
        uint v = b[at] | (cast(uint) b[at + 1] << 8) | (cast(uint) b[at + 2] << 16) | (cast(uint) b[at + 3] << 24);
        at += 4;
        return v;
    }

    uint[] u32s(size_t n) {
        uint[] r = new uint[n];
        foreach (i; 0 .. n)
            r[i] = u32();
        return r;
    }

    ubyte[] bytes(size_t n) {
        ubyte[] r = b[at .. at + n].dup;
        at += n;
        return r;
    }

    float[] f32s(size_t n) {
        import engine.meshopt.internal.bits : bitsFloat;
        float[] r = new float[n];
        foreach (i; 0 .. n)
            r[i] = bitsFloat(u32());
        return r;
    }
}

private uint loadU32at(const(ubyte)[] file, size_t at) {
    return file[at] | (cast(uint) file[at + 1] << 8) | (cast(uint) file[at + 2] << 16) | (cast(uint) file[at + 3] << 24);
}

@("optimizeVertexCache.triangle") unittest {
    uint[3] ib = [0, 1, 2];
    uint[3] out_;
    optimizeVertexCache(out_[], ib[], 3);
    assert(out_[] == ib[]);
    ushort[3] ib16 = [0, 1, 2];
    ushort[3] out16;
    optimizeVertexCache(out16[], ib16[], 3);
    assert(out16[] == ib16[]);
    optimizeVertexCacheFifo(out_[], ib[], 3, 16);
    assert(out_[] == ib[]);
}
