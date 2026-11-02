// Ported from meshoptimizer v1.3 (src/overdrawoptimizer.cpp), Copyright (c) 2016-2026 Arseny Kapoulkine, MIT License.
/// View-independent overdraw reorder. Clusters come from a vertex-cache-optimized mesh.
module engine.meshopt.overdraw;

import engine.meshopt.quantize : quantizeUnorm;
import engine.meshopt.scratch : MeshoptScratch, defaultScratch;
import engine.meshopt.types : FloatStream;

@safe:

private enum bool isIndex(I) = is(I == uint) || is(I == ushort);

private float sqrtF(float x) nothrow @nogc @trusted {
    import core.stdc.math : sqrtf;
    alias F = float function(float) nothrow @nogc @trusted;
    return (cast(F) &sqrtf)(x);
}

private float fabsF(float x) nothrow @nogc @trusted {
    import core.stdc.math : fabsf;
    alias F = float function(float) nothrow @nogc @trusted;
    return (cast(F) &fabsf)(x);
}

private float loadFloat(ulong address, size_t floatIndex) nothrow @nogc @trusted {
    import engine.meshopt.internal.bits : bitsFloat;
    ubyte* p = cast(ubyte*)(address + floatIndex * 4);
    uint u = p[0] | (cast(uint) p[1] << 8) | (cast(uint) p[2] << 16) | (cast(uint) p[3] << 24);
    return bitsFloat(u);
}

private void calculateSortData(float[] sortData, const(uint)[] indices, ulong positions, size_t vertexCount, size_t strideFloats, const(uint)[] clusters) {
    float[3] meshCentroid = 0;
    foreach (i; 0 .. vertexCount) {
        meshCentroid[0] += loadFloat(positions, i * strideFloats + 0);
        meshCentroid[1] += loadFloat(positions, i * strideFloats + 1);
        meshCentroid[2] += loadFloat(positions, i * strideFloats + 2);
    }
    meshCentroid[0] /= cast(float) vertexCount;
    meshCentroid[1] /= cast(float) vertexCount;
    meshCentroid[2] /= cast(float) vertexCount;

    foreach (cluster; 0 .. clusters.length) {
        size_t clusterBegin = clusters[cluster] * 3;
        size_t clusterEnd = (cluster + 1 < clusters.length) ? clusters[cluster + 1] * 3 : indices.length;
        assert(clusterBegin < clusterEnd);
        float clusterArea = 0;
        float[3] clusterCentroid = 0;
        float[3] clusterNormal = 0;
        for (size_t i = clusterBegin; i < clusterEnd; i += 3) {
            size_t i0 = indices[i + 0], i1 = indices[i + 1], i2 = indices[i + 2];
            float p0x = loadFloat(positions, i0 * strideFloats + 0);
            float p0y = loadFloat(positions, i0 * strideFloats + 1);
            float p0z = loadFloat(positions, i0 * strideFloats + 2);
            float p1x = loadFloat(positions, i1 * strideFloats + 0);
            float p1y = loadFloat(positions, i1 * strideFloats + 1);
            float p1z = loadFloat(positions, i1 * strideFloats + 2);
            float p2x = loadFloat(positions, i2 * strideFloats + 0);
            float p2y = loadFloat(positions, i2 * strideFloats + 1);
            float p2z = loadFloat(positions, i2 * strideFloats + 2);
            float p10x = p1x - p0x, p10y = p1y - p0y, p10z = p1z - p0z;
            float p20x = p2x - p0x, p20y = p2y - p0y, p20z = p2z - p0z;
            float normalx = p10y * p20z - p10z * p20y;
            float normaly = p10z * p20x - p10x * p20z;
            float normalz = p10x * p20y - p10y * p20x;
            float area = sqrtF(normalx * normalx + normaly * normaly + normalz * normalz);
            float w = area / 3;
            clusterCentroid[0] += (p0x + p1x + p2x) * w;
            clusterCentroid[1] += (p0y + p1y + p2y) * w;
            clusterCentroid[2] += (p0z + p1z + p2z) * w;
            clusterNormal[0] += normalx;
            clusterNormal[1] += normaly;
            clusterNormal[2] += normalz;
            clusterArea += area;
        }
        float invClusterArea = clusterArea == 0 ? 0 : 1 / clusterArea;
        clusterCentroid[0] *= invClusterArea;
        clusterCentroid[1] *= invClusterArea;
        clusterCentroid[2] *= invClusterArea;
        float clusterNormalLength = sqrtF(clusterNormal[0] * clusterNormal[0] + clusterNormal[1] * clusterNormal[1] + clusterNormal[2] * clusterNormal[2]);
        float invLen = clusterNormalLength == 0 ? 0 : 1 / clusterNormalLength;
        clusterNormal[0] *= invLen;
        clusterNormal[1] *= invLen;
        clusterNormal[2] *= invLen;
        float cvx = clusterCentroid[0] - meshCentroid[0];
        float cvy = clusterCentroid[1] - meshCentroid[1];
        float cvz = clusterCentroid[2] - meshCentroid[2];
        sortData[cluster] = cvx * clusterNormal[0] + cvy * clusterNormal[1] + cvz * clusterNormal[2];
    }
}

private void calculateSortOrderRadix(uint[] sortOrder, const(float)[] sortData, ushort[] sortKeys) {
    float sortDataMax = 1e-3f;
    foreach (d; sortData) {
        float dpa = fabsF(d);
        sortDataMax = (sortDataMax < dpa) ? dpa : sortDataMax;
    }
    enum int sortBits = 11;
    foreach (i, d; sortData) {
        float sortKey = 0.5f - 0.5f * (d / sortDataMax);
        sortKeys[i] = cast(ushort)(quantizeUnorm(sortKey, sortBits) & ((1 << sortBits) - 1));
    }
    uint[1 << sortBits] histogram;
    histogram[] = 0;
    foreach (key; sortKeys)
        histogram[key]++;
    size_t histogramSum = 0;
    foreach (i, ref bin; histogram) {
        size_t count = bin;
        bin = cast(uint) histogramSum;
        histogramSum += count;
    }
    assert(histogramSum == sortData.length);
    foreach (i, key; sortKeys)
        sortOrder[histogram[key]++] = cast(uint) i;
}

private uint updateCache(uint a, uint b, uint c, uint cacheSize, uint[] cacheTimestamps, ref uint timestamp) {
    uint misses = 0;
    if (timestamp - cacheTimestamps[a] > cacheSize) {
        cacheTimestamps[a] = timestamp++;
        misses++;
    }
    if (timestamp - cacheTimestamps[b] > cacheSize) {
        cacheTimestamps[b] = timestamp++;
        misses++;
    }
    if (timestamp - cacheTimestamps[c] > cacheSize) {
        cacheTimestamps[c] = timestamp++;
        misses++;
    }
    return misses;
}

private size_t generateHardBoundaries(uint[] destination, const(uint)[] indices, size_t vertexCount, uint cacheSize, uint[] cacheTimestamps) {
    cacheTimestamps[] = 0;
    uint timestamp = cacheSize + 1;
    size_t faceCount = indices.length / 3;
    size_t result = 0;
    foreach (i; 0 .. faceCount) {
        uint m = updateCache(indices[i * 3 + 0], indices[i * 3 + 1], indices[i * 3 + 2], cacheSize, cacheTimestamps, timestamp);
        if (i == 0 || m == 3)
            destination[result++] = cast(uint) i;
    }
    assert(result <= faceCount);
    return result;
}

private size_t generateSoftBoundaries(uint[] destination, const(uint)[] indices, size_t vertexCount, const(uint)[] clusters, uint cacheSize, float threshold, uint[] cacheTimestamps) {
    cacheTimestamps[] = 0;
    uint timestamp = 0;
    size_t result = 0;
    size_t faceCount = indices.length / 3;
    foreach (it; 0 .. clusters.length) {
        size_t start = clusters[it];
        size_t end = (it + 1 < clusters.length) ? clusters[it + 1] : faceCount;
        assert(start < end);
        timestamp += cacheSize + 1;
        uint clusterMisses = 0;
        foreach (i; start .. end) {
            uint m = updateCache(indices[i * 3 + 0], indices[i * 3 + 1], indices[i * 3 + 2], cacheSize, cacheTimestamps, timestamp);
            clusterMisses += m;
        }
        float clusterThreshold = threshold * (cast(float) clusterMisses / cast(float)(end - start));
        destination[result++] = cast(uint) start;
        timestamp += cacheSize + 1;
        uint runningMisses = 0;
        uint runningFaces = 0;
        foreach (i; start .. end) {
            uint m = updateCache(indices[i * 3 + 0], indices[i * 3 + 1], indices[i * 3 + 2], cacheSize, cacheTimestamps, timestamp);
            runningMisses += m;
            runningFaces += 1;
            if (cast(float) runningMisses / cast(float) runningFaces <= clusterThreshold) {
                destination[result++] = cast(uint)(i + 1);
                timestamp += cacheSize + 1;
                runningMisses = 0;
                runningFaces = 0;
            }
        }
        if (destination[result - 1] != start)
            result--;
    }
    assert(result >= clusters.length);
    assert(result <= faceCount);
    return result;
}

/**
 * Reorder triangles to reduce overdraw. `indices` should already be vertex-cache optimized.
 * `threshold` is 1.05 upstream when omitted by the caller; pass it explicitly.
 */
void optimizeOverdraw(I)(scope I[] destination, scope const(I)[] indices, ulong positions, size_t vertexCount, size_t strideFloats, float threshold, ref MeshoptScratch scratch = defaultScratch())
if (isIndex!I) {
    assert(indices.length % 3 == 0);
    assert(destination.length >= indices.length);
    size_t stride = strideFloats * 4;
    assert(stride >= 12 && stride <= 256);
    if (indices.length == 0 || vertexCount == 0)
        return;
    immutable mark = scratch.mark();
    scope (exit)
        scratch.release(mark);
    const(I)[] srcI = indices;
    if (samePtr(destination, indices)) {
        I[] copy = scratch.allocate!I(indices.length);
        copy[] = indices[];
        srcI = copy;
    }
    uint[] idx = scratch.allocate!uint(srcI.length);
    foreach (i, v; srcI)
        idx[i] = v;

    enum uint cacheSize = 16;
    uint[] cacheTimestamps = scratch.allocate!uint(vertexCount);
    uint[] hardClusters = scratch.allocate!uint(idx.length / 3);
    size_t hardCount = generateHardBoundaries(hardClusters, idx, vertexCount, cacheSize, cacheTimestamps);
    uint[] softClusters = scratch.allocate!uint(idx.length / 3 + 1);
    size_t softCount = generateSoftBoundaries(softClusters, idx, vertexCount, hardClusters[0 .. hardCount], cacheSize, threshold, cacheTimestamps);
    uint[] clusters = softClusters[0 .. softCount];
    float[] sortData = scratch.allocate!float(softCount);
    calculateSortData(sortData, idx, positions, vertexCount, strideFloats, clusters);
    ushort[] sortKeys = scratch.allocate!ushort(softCount);
    uint[] sortOrder = scratch.allocate!uint(softCount);
    calculateSortOrderRadix(sortOrder, sortData, sortKeys);

    size_t offset = 0;
    foreach (it; 0 .. softCount) {
        uint cluster = sortOrder[it];
        assert(cluster < softCount);
        size_t begin = clusters[cluster] * 3;
        size_t end = (cluster + 1 < softCount) ? clusters[cluster + 1] * 3 : idx.length;
        assert(begin < end);
        foreach (k; begin .. end)
            destination[offset++] = cast(I) idx[k];
    }
    assert(offset == idx.length);
}

/// `FloatStream` overload. The default threshold is the usual upstream call (1.05).
void optimizeOverdraw(I)(scope I[] destination, scope const(I)[] indices, FloatStream positions, float threshold = 1.05f, ref MeshoptScratch scratch = defaultScratch())
if (isIndex!I) {
    optimizeOverdraw(destination, indices, positions.address, positions.count, positions.strideFloats, threshold, scratch);
}

private bool samePtr(I)(scope const(I)[] a, scope const(I)[] b) nothrow @nogc @trusted {
    return a.length > 0 && a.ptr is b.ptr;
}

@("emptyMesh") unittest {
    uint[0] empty;
    FloatStream fs;
    fs.strideFloats = 3;
    optimizeOverdraw(empty[], empty[], fs, 1.0f);
}
