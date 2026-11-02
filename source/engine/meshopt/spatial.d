// Ported from meshoptimizer v1.3 (src/spatialorder.cpp), Copyright (c) 2016-2026 Arseny Kapoulkine, MIT License.
/// Morton and axis spatial order for vertices, triangles, and point clusters.
module engine.meshopt.spatial;

import engine.meshopt.internal.sort : radixSort10;
import engine.meshopt.scratch : MeshoptScratch, defaultScratch;
import engine.meshopt.types : FloatStream;

@safe:

private enum bool isIndex(I) = is(I == uint) || is(I == ushort);

private float[3] load3(FloatStream positions, size_t i) pure nothrow @nogc {
    return positions.get3(i);
}

/// Insert two zero bits after each of the low 20 bits. Giesen, 2009.
private ulong part1By2(ulong x) pure nothrow @nogc {
    x &= 0x000f_ffffUL;
    x = (x ^ (x << 32)) & 0x000f_0000_0000_ffffUL;
    x = (x ^ (x << 16)) & 0x000f_0000_ff00_00ffUL;
    x = (x ^ (x << 8)) & 0x000f_00f0_0f00_f00fUL;
    x = (x ^ (x << 4)) & 0x00c3_0c30_c30c_30c3UL;
    x = (x ^ (x << 2)) & 0x0249_2492_4924_9249UL;
    return x;
}

private void computeOrder(ulong[] result, FloatStream positions, bool morton) pure nothrow @nogc {
    size_t vertexCount = positions.count;
    assert(result.length >= vertexCount);
    float[3] minv = float.max;
    float[3] maxv = -float.max;

    foreach (i; 0 .. vertexCount) {
        float[3] v = load3(positions, i);
        foreach (j; 0 .. 3) {
            float vj = v[j];
            minv[j] = minv[j] > vj ? vj : minv[j];
            maxv[j] = maxv[j] < vj ? vj : maxv[j];
        }
    }

    float extent = 0;
    extent = (maxv[0] - minv[0]) < extent ? extent : (maxv[0] - minv[0]);
    extent = (maxv[1] - minv[1]) < extent ? extent : (maxv[1] - minv[1]);
    extent = (maxv[2] - minv[2]) < extent ? extent : (maxv[2] - minv[2]);

    // Rescale each axis to 16 bits to get 48-bit Morton codes.
    float scale = extent == 0 ? 0 : 65535.0f / extent;

    foreach (i; 0 .. vertexCount) {
        float[3] v = load3(positions, i);
        int x = cast(int)((v[0] - minv[0]) * scale + 0.5f);
        int y = cast(int)((v[1] - minv[1]) * scale + 0.5f);
        int z = cast(int)((v[2] - minv[2]) * scale + 0.5f);
        if (morton)
            result[i] = part1By2(cast(ulong) x) | (part1By2(cast(ulong) y) << 1) | (part1By2(cast(ulong) z) << 2);
        else
            result[i] = (cast(ulong) x << 0) | (cast(ulong) y << 20) | (cast(ulong) z << 40);
    }
}

private void computeHistogram(ref uint[2][256] hist, const(ushort)[] data) pure nothrow @nogc {
    size_t count = data.length;
    foreach (i; 0 .. 256) {
        hist[i][0] = 0;
        hist[i][1] = 0;
    }
    foreach (i; 0 .. count) {
        uint id = data[i];
        hist[(id >> 0) & 255][0]++;
        hist[(id >> 8) & 255][1]++;
    }
    uint sum0 = 0, sum1 = 0;
    foreach (i; 0 .. 256) {
        uint h0 = hist[i][0], h1 = hist[i][1];
        hist[i][0] = sum0;
        hist[i][1] = sum1;
        sum0 += h0;
        sum1 += h1;
    }
    assert(sum0 == count && sum1 == count);
}

private void radixPass(uint[] destination, const(uint)[] source, const(ushort)[] keys, ref uint[2][256] hist, int pass) pure nothrow @nogc {
    size_t count = source.length;
    assert(destination.length >= count);
    int bitoff = pass * 8;
    foreach (i; 0 .. count) {
        uint id = (keys[source[i]] >> bitoff) & 255;
        destination[hist[id][pass]++] = source[i];
    }
}

private void partitionPoints(uint[] target, const(uint)[] order, const(ubyte)[] sides, size_t split) pure nothrow @nogc {
    size_t count = order.length;
    assert(target.length >= count);
    size_t l = 0;
    size_t r = split;
    foreach (i; 0 .. count) {
        ubyte side = sides[order[i]];
        target[side ? r : l] = order[i];
        l += 1;
        l -= side;
        r += side;
    }
    assert(l == split && r == count);
}

private void splitPoints(uint[] destination, uint[] orderx, uint[] ordery, uint[] orderz, const(ulong)[] keys, size_t count, uint[] temp, ubyte[] sides, size_t clusterSize) pure nothrow @nogc {
    assert(orderx.length >= count && ordery.length >= count && orderz.length >= count);
    assert(destination.length >= count);
    if (count <= clusterSize) {
        destination[0 .. count] = orderx[0 .. count];
        return;
    }

    int bestk = -1;
    uint bestdim = 0;
    enum uint mask = (1u << 20) - 1;
    foreach (k; 0 .. 3) {
        uint[] axis = k == 0 ? orderx : (k == 1 ? ordery : orderz);
        uint dim = (cast(uint)(keys[axis[count - 1]] >> (k * 20)) & mask)
            - (cast(uint)(keys[axis[0]] >> (k * 20)) & mask);
        if (dim >= bestdim) {
            bestk = cast(int) k;
            bestdim = dim;
        }
    }
    assert(bestk >= 0);

    // Left split is aligned to the cluster size.
    size_t split = ((count / 2) + clusterSize - 1) / clusterSize * clusterSize;
    assert(split > 0 && split < count);

    uint[] bestAxis = bestk == 0 ? orderx : (bestk == 1 ? ordery : orderz);
    foreach (i; 0 .. split)
        sides[bestAxis[i]] = 0;
    foreach (i; split .. count)
        sides[bestAxis[i]] = 1;

    foreach (k; 0 .. 3) {
        if (k == bestk)
            continue;
        uint[] axis = k == 0 ? orderx : (k == 1 ? ordery : orderz);
        temp[0 .. count] = axis[0 .. count];
        partitionPoints(axis[0 .. count], temp[0 .. count], sides, split);
    }

    splitPoints(destination[0 .. split], orderx[0 .. split], ordery[0 .. split], orderz[0 .. split], keys, split, temp, sides, clusterSize);
    splitPoints(destination[split .. count], orderx[split .. count], ordery[split .. count], orderz[split .. count], keys, count - split, temp, sides, clusterSize);
}

/**
 * Remap that gathers points into Morton order.
 * `destination[old] = new`. `destination.length >= positions.count`.
 */
void spatialSortRemap(scope uint[] destination, FloatStream positions, ref MeshoptScratch scratch = defaultScratch()) nothrow @nogc
in (positions.strideFloats >= 3 && positions.strideFloats <= 64)
in (destination.length >= positions.count)
do {
    size_t vertexCount = positions.count;
    if (vertexCount == 0)
        return;
    immutable m = scratch.mark();
    scope (exit)
        scratch.release(m);

    ulong[] keys = scratch.allocate!ulong(vertexCount);
    computeOrder(keys, positions, true);

    uint[] scratchOrder = scratch.allocate!uint(vertexCount);
    ushort[] keyk = scratch.allocate!ushort(vertexCount);
    foreach (i; 0 .. vertexCount)
        destination[i] = cast(uint) i;

    // Five 10-bit passes leave the sorted order in `scratchOrder`.
    foreach (k; 0 .. 5) {
        foreach (i; 0 .. vertexCount)
            keyk[i] = cast(ushort)((keys[i] >> (k * 10)) & 1023);
        if ((k & 1) == 0)
            radixSort10(scratchOrder, destination[0 .. vertexCount], keyk);
        else
            radixSort10(destination[0 .. vertexCount], scratchOrder, keyk);
    }

    // Remap is old=>new, so reverse the sorted order.
    foreach (i; 0 .. vertexCount)
        destination[scratchOrder[i]] = cast(uint) i;
}

/**
 * Reorder triangles by the Morton code of their centroids.
 * `destination` may alias `indices`.
 */
void spatialSortTriangles(I)(scope I[] destination, scope const(I)[] indices, FloatStream positions, ref MeshoptScratch scratch = defaultScratch()) nothrow @nogc
if (isIndex!I)
in (indices.length % 3 == 0)
in (destination.length >= indices.length)
in (positions.strideFloats >= 3 && positions.strideFloats <= 64)
do {
    size_t faceCount = indices.length / 3;
    immutable m = scratch.mark();
    scope (exit)
        scratch.release(m);

    uint[] idx = scratch.allocate!uint(indices.length);
    foreach (i, v; indices) {
        assert(v < positions.count);
        idx[i] = v;
    }

    float[] centroids = scratch.allocate!float(faceCount * 3);
    foreach (i; 0 .. faceCount) {
        uint a = idx[i * 3 + 0], b = idx[i * 3 + 1], c = idx[i * 3 + 2];
        float[3] va = load3(positions, a);
        float[3] vb = load3(positions, b);
        float[3] vc = load3(positions, c);
        centroids[i * 3 + 0] = (va[0] + vb[0] + vc[0]) / 3.0f;
        centroids[i * 3 + 1] = (va[1] + vb[1] + vc[1]) / 3.0f;
        centroids[i * 3 + 2] = (va[2] + vb[2] + vc[2]) / 3.0f;
    }

    FloatStream cents;
    cents.strideFloats = 3;
    cents.count = faceCount;
    if (faceCount)
        cents.address = floatAddr(centroids);
    uint[] remap = scratch.allocate!uint(faceCount);
    spatialSortRemap(remap, cents, scratch);

    foreach (i; 0 .. faceCount) {
        uint a = idx[i * 3 + 0], b = idx[i * 3 + 1], c = idx[i * 3 + 2];
        uint r = remap[i];
        destination[r * 3 + 0] = cast(I) a;
        destination[r * 3 + 1] = cast(I) b;
        destination[r * 3 + 2] = cast(I) c;
    }
}

/**
 * Order points so each chunk of `clusterSize` (except the last) is spatially compact.
 * `destination` receives the source point index for each output slot.
 */
void spatialClusterPoints(scope uint[] destination, FloatStream positions, size_t clusterSize, ref MeshoptScratch scratch = defaultScratch()) nothrow @nogc
in (positions.strideFloats >= 3 && positions.strideFloats <= 64)
in (clusterSize > 0)
in (destination.length >= positions.count)
do {
    size_t vertexCount = positions.count;
    if (vertexCount == 0)
        return;
    immutable m = scratch.mark();
    scope (exit)
        scratch.release(m);

    ulong[] keys = scratch.allocate!ulong(vertexCount);
    computeOrder(keys, positions, false);

    uint[] order = scratch.allocate!uint(vertexCount * 3);
    uint[] temp = scratch.allocate!uint(vertexCount);
    ubyte[] sides = scratch.allocate!ubyte(vertexCount);
    ushort[] keyk = scratch.allocate!ushort(vertexCount);

    foreach (k; 0 .. 3) {
        foreach (i; 0 .. vertexCount)
            keyk[i] = cast(ushort)(keys[i] >> (k * 20));
        uint[2][256] hist;
        computeHistogram(hist, keyk);
        uint[] axis = order[k * vertexCount .. (k + 1) * vertexCount];
        foreach (i; 0 .. vertexCount)
            axis[i] = cast(uint) i;
        radixPass(temp, axis, keyk, hist, 0);
        radixPass(axis, temp, keyk, hist, 1);
    }

    splitPoints(destination, order[0 .. vertexCount], order[vertexCount .. vertexCount * 2], order[vertexCount * 2 .. vertexCount * 3], keys, vertexCount, temp, sides, clusterSize);
}

private ulong floatAddr(scope float[] data) nothrow @nogc @trusted {
    return data.length ? cast(ulong) data.ptr : 0;
}

@safe nothrow @nogc unittest {
    assert(part1By2(0) == 0);
    assert(part1By2(1) == 1);
    assert(part1By2(2) == 8);

    float[12] pos = [0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 1, 1];
    FloatStream fs;
    fs.strideFloats = 3;
    fs.count = 4;
    fs.address = floatAddr(pos);
    uint[4] remap;
    spatialSortRemap(remap[], fs);
    bool[4] seen;
    foreach (v; remap[]) {
        assert(v < 4);
        assert(!seen[v]);
        seen[v] = true;
    }

    uint[6] idx = [0, 1, 2, 1, 2, 3];
    uint[6] sorted;
    spatialSortTriangles(sorted[], idx[], fs);
    assert(sorted[0] + sorted[1] + sorted[2] + sorted[3] + sorted[4] + sorted[5]
        == idx[0] + idx[1] + idx[2] + idx[3] + idx[4] + idx[5]);

    uint[4] clusters;
    spatialClusterPoints(clusters[], fs, 2);
    bool[4] seenC;
    foreach (v; clusters[]) {
        assert(v < 4);
        assert(!seenC[v]);
        seenC[v] = true;
    }

    uint[0] empty;
    FloatStream none;
    none.strideFloats = 3;
    spatialSortRemap(empty[], none);
    spatialSortTriangles(empty[], empty[], none);
    spatialClusterPoints(empty[], none, 1);
}
