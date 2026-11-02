// Ported from meshoptimizer v1.3 (src/partition.cpp), Copyright (c) 2016-2026 Arseny Kapoulkine, MIT License.
/// Agglomerative cluster grouping by shared vertices and spatial proximity.
module engine.meshopt.partition;

import engine.meshopt.internal.sort : GroupOrder, heapPop, heapPush;
import engine.meshopt.scratch : MeshoptScratch, defaultScratch;
import engine.meshopt.types : FloatStream;

@safe:

private enum bool isIndex(I) = is(I == uint) || is(I == ushort);

// Switch to bisection after this many splits so a malformed input cannot recurse forever.
private enum int kMergeDepthCutoff = 40;

private float sqrtF(float x) nothrow @nogc @trusted {
    import core.stdc.math : sqrtf;
    alias F = float function(float) nothrow @nogc @trusted;
    return (cast(F) &sqrtf)(x);
}

private float[3] load3(FloatStream positions, size_t i) pure nothrow @nogc {
    return positions.get3(i);
}

private struct ClusterAdjacency {
    uint[] offsets;
    uint[] clusters;
    uint[] sharedVerts;
}

private struct ClusterGroup {
    int group;
    int next;
    uint size;
    uint vertices;
    float cx = 0;
    float cy = 0;
    float cz = 0;
    float radius = 0;
}

private void filterClusterIndices(uint[] data, uint[] offsets, const(uint)[] clusterIndices, const(uint)[] clusterIndexCounts, ubyte[] used) pure nothrow @nogc {
    size_t clusterCount = clusterIndexCounts.length;
    size_t clusterStart = 0;
    size_t clusterWrite = 0;
    foreach (i; 0 .. clusterCount) {
        offsets[i] = cast(uint) clusterWrite;
        foreach (j; 0 .. clusterIndexCounts[i]) {
            uint v = clusterIndices[clusterStart + j];
            assert(v < used.length);
            data[clusterWrite] = v;
            clusterWrite += 1 - used[v];
            used[v] = 1;
        }
        foreach (j; offsets[i] .. clusterWrite)
            used[data[j]] = 0;
        clusterStart += clusterIndexCounts[i];
    }
    assert(clusterStart == clusterIndices.length);
    assert(clusterWrite <= clusterIndices.length);
    offsets[clusterCount] = cast(uint) clusterWrite;
}

private struct CenterRadius {
    float x = 0;
    float y = 0;
    float z = 0;
    float radius = 0;
}

/// Average every index reference (duplicates included) and return the sphere.
private CenterRadius averageClusterRadius(const(uint)[] indices, FloatStream positions) nothrow @nogc {
    CenterRadius r;
    foreach (v; indices) {
        float[3] p = load3(positions, v);
        r.x += p[0];
        r.y += p[1];
        r.z += p[2];
    }
    if (indices.length) {
        float n = cast(float) indices.length;
        r.x /= n;
        r.y /= n;
        r.z /= n;
    }
    float radiussq = 0;
    foreach (v; indices) {
        float[3] p = load3(positions, v);
        float dx = p[0] - r.x;
        float dy = p[1] - r.y;
        float dz = p[2] - r.z;
        float d2 = dx * dx + dy * dy + dz * dz;
        radiussq = radiussq < d2 ? d2 : radiussq;
    }
    r.radius = sqrtF(radiussq);
    return r;
}

private void buildClusterAdjacency(ref ClusterAdjacency adjacency, const(uint)[] clusterIndices, const(uint)[] clusterOffsets, size_t clusterCount, size_t vertexCount, ref MeshoptScratch scratch) nothrow @nogc {
    uint[] refOffsets = scratch.allocate!uint(vertexCount + 1);
    refOffsets[0 .. vertexCount] = 0;

    foreach (i; 0 .. clusterCount) {
        foreach (j; clusterOffsets[i] .. clusterOffsets[i + 1])
            refOffsets[clusterIndices[j]]++;
    }

    size_t totalAdjacency = 0;
    foreach (i; 0 .. clusterCount) {
        size_t count = 0;
        foreach (j; clusterOffsets[i] .. clusterOffsets[i + 1])
            count += refOffsets[clusterIndices[j]] - 1;
        totalAdjacency += count < clusterCount - 1 ? count : clusterCount - 1;
    }

    adjacency.offsets = scratch.allocate!uint(clusterCount + 1);
    adjacency.clusters = scratch.allocate!uint(totalAdjacency);
    adjacency.sharedVerts = scratch.allocate!uint(totalAdjacency);

    size_t totalRefs = 0;
    foreach (i; 0 .. vertexCount) {
        size_t count = refOffsets[i];
        refOffsets[i] = cast(uint) totalRefs;
        totalRefs += count;
    }

    uint[] refData = scratch.allocate!uint(totalRefs);
    foreach (i; 0 .. clusterCount) {
        foreach (j; clusterOffsets[i] .. clusterOffsets[i + 1])
            refData[refOffsets[clusterIndices[j]]++] = cast(uint) i;
    }

    // refOffsets[i] is now the end of vertex i. Shift it so index 0 is the start.
    foreach_reverse (i; 0 .. vertexCount)
        refOffsets[i + 1] = refOffsets[i];
    refOffsets[0] = 0;

    uint[] slots = scratch.allocate!uint(clusterCount);
    foreach (i; 0 .. clusterCount)
        slots[i] = uint.max;

    adjacency.offsets[0] = 0;
    foreach (i; 0 .. clusterCount) {
        size_t base = adjacency.offsets[i];
        size_t count = 0;
        foreach (j; clusterOffsets[i] .. clusterOffsets[i + 1]) {
            uint v = clusterIndices[j];
            foreach (k; refOffsets[v] .. refOffsets[v + 1]) {
                uint c = refData[k];
                assert(c < clusterCount);
                if (c == i)
                    continue;
                uint slot = slots[c];
                if (slot < count && adjacency.clusters[base + slot] == c)
                    adjacency.sharedVerts[base + slot]++;
                else {
                    slots[c] = cast(uint) count;
                    adjacency.clusters[base + count] = c;
                    adjacency.sharedVerts[base + count] = 1;
                    count++;
                }
            }
        }
        adjacency.offsets[i + 1] = adjacency.offsets[i] + cast(uint) count;
    }
    assert(adjacency.offsets[clusterCount] <= totalAdjacency);
}

private void mergeBounds(ref ClusterGroup target, ref const(ClusterGroup) source) nothrow @nogc {
    float r1 = target.radius;
    float r2 = source.radius;
    float dx = source.cx - target.cx;
    float dy = source.cy - target.cy;
    float dz = source.cz - target.cz;
    float d = sqrtF(dx * dx + dy * dy + dz * dz);

    if (d + r1 < r2) {
        target.cx = source.cx;
        target.cy = source.cy;
        target.cz = source.cz;
        target.radius = source.radius;
        return;
    }
    if (d + r2 > r1) {
        float k = d > 0 ? (d + r2 - r1) / (2 * d) : 0;
        target.cx += dx * k;
        target.cy += dy * k;
        target.cz += dz * k;
        target.radius = (d + r2 + r1) / 2;
    }
}

private float boundsScore(ref const(ClusterGroup) target, ref const(ClusterGroup) source) nothrow @nogc {
    float r1 = target.radius;
    float r2 = source.radius;
    float dx = source.cx - target.cx;
    float dy = source.cy - target.cy;
    float dz = source.cz - target.cz;
    float d = sqrtF(dx * dx + dy * dy + dz * dz);
    float mr = d + r1 < r2 ? r2 : (d + r2 < r1 ? r1 : (d + r2 + r1) / 2);
    return mr > 0 ? r1 / mr : 0;
}

private int pickGroupToMerge(const(ClusterGroup)[] groups, int id, ref const(ClusterAdjacency) adjacency, size_t maxPartitionSize, bool useBounds, uint[] sharedAcc, out uint outShared) nothrow @nogc {
    assert(groups[id].size > 0);
    float groupRsqrt = 1.0f / sqrtF(cast(float) cast(int) groups[id].vertices);

    int bestGroup = -1;
    float bestScore = 0;
    uint bestShared = 0;

    for (int ci = id; ci >= 0; ci = groups[ci].next) {
        foreach (adj; adjacency.offsets[ci] .. adjacency.offsets[ci + 1]) {
            int other = groups[adjacency.clusters[adj]].group;
            if (other >= 0)
                sharedAcc[other] += adjacency.sharedVerts[adj];
        }
    }

    for (int ci = id; ci >= 0; ci = groups[ci].next) {
        foreach (adj; adjacency.offsets[ci] .. adjacency.offsets[ci + 1]) {
            int other = groups[adjacency.clusters[adj]].group;
            if (other < 0 || sharedAcc[other] == 0)
                continue;
            uint sharedCount = sharedAcc[other];
            sharedAcc[other] = 0;
            assert(groups[other].size > 0);
            if (groups[id].size + groups[other].size > maxPartitionSize)
                continue;
            float otherRsqrt = 1.0f / sqrtF(cast(float) cast(int) groups[other].vertices);
            float score = cast(float) cast(int) sharedCount * (groupRsqrt + otherRsqrt);
            if (useBounds)
                score *= 1.0f + 0.4f * boundsScore(groups[id], groups[other]);
            if (score > bestScore) {
                bestGroup = other;
                bestScore = score;
                bestShared = sharedCount;
            }
        }
    }

    outShared = bestShared;
    return bestGroup;
}

private void mergeLeaf(ClusterGroup[] groups, uint[] order, size_t count, size_t targetPartitionSize, size_t maxPartitionSize) nothrow @nogc {
    foreach (i; 0 .. count) {
        uint id = order[i];
        if (groups[id].size == 0 || groups[id].size >= targetPartitionSize)
            continue;
        float bestScore = -1;
        int bestGroup = -1;
        foreach (j; 0 .. count) {
            uint other = order[j];
            if (id == other || groups[other].size == 0)
                continue;
            if (groups[id].size + groups[other].size > maxPartitionSize)
                continue;
            float score = boundsScore(groups[id], groups[other]);
            if (score > bestScore) {
                bestScore = score;
                bestGroup = cast(int) other;
            }
        }
        if (bestGroup != -1) {
            uint tail = cast(uint) bestGroup;
            while (groups[tail].next >= 0)
                tail = cast(uint) groups[tail].next;
            groups[tail].next = cast(int) id;
            groups[bestGroup].size += groups[id].size;
            groups[id].size = 0;
            mergeBounds(groups[bestGroup], groups[id]);
            groups[id].radius = 0;
        }
    }
}

private size_t mergePartition(uint[] order, const(ClusterGroup)[] groups, int axis, float pivot) pure nothrow @nogc {
    size_t count = order.length;
    size_t m = 0;
    foreach (i; 0 .. count) {
        float v = axis == 0 ? groups[order[i]].cx : (axis == 1 ? groups[order[i]].cy : groups[order[i]].cz);
        uint t = order[m];
        order[m] = order[i];
        order[i] = t;
        m += v < pivot;
    }
    return m;
}

private void mergeSpatial(ClusterGroup[] groups, uint[] order, size_t count, size_t targetPartitionSize, size_t maxPartitionSize, size_t leafSize, int depth) nothrow @nogc {
    size_t total = 0;
    foreach (i; 0 .. count)
        total += groups[order[i]].size;
    if (total <= maxPartitionSize || count <= leafSize)
        return mergeLeaf(groups, order[0 .. count], count, targetPartitionSize, maxPartitionSize);

    float[3] mean = 0;
    float[3] vars = 0;
    float runc = 1;
    float runs = 1;
    foreach (i; 0 .. count) {
        float[3] point;
        point[0] = groups[order[i]].cx;
        point[1] = groups[order[i]].cy;
        point[2] = groups[order[i]].cz;
        foreach (k; 0 .. 3) {
            float delta = point[k] - mean[k];
            mean[k] += delta * runs;
            vars[k] += delta * (point[k] - mean[k]);
        }
        runc += 1;
        runs = 1.0f / runc;
    }

    int axis = (vars[0] >= vars[1] && vars[0] >= vars[2]) ? 0 : (vars[1] >= vars[2] ? 1 : 2);
    float split = mean[axis];
    size_t middle = mergePartition(order[0 .. count], groups, axis, split);
    if (middle <= leafSize / 2 || count - middle <= leafSize / 2 || depth >= kMergeDepthCutoff)
        middle = count / 2;

    mergeSpatial(groups, order[0 .. middle], middle, targetPartitionSize, maxPartitionSize, leafSize, depth + 1);
    mergeSpatial(groups, order[middle .. count], count - middle, targetPartitionSize, maxPartitionSize, leafSize, depth + 1);
}

/**
 * Group clusters into partitions of about `targetPartitionSize` clusters
 * (never more than target + target/3).
 *
 * `destination[i]` is the partition id of cluster `i`. The return value is
 * the number of partitions. Pass a zero-address `FloatStream` to ignore positions.
 */
size_t partitionClusters(I)(scope uint[] destination, scope const(I)[] clusterIndices, scope const(uint)[] clusterIndexCounts, FloatStream positions, size_t targetPartitionSize, ref MeshoptScratch scratch = defaultScratch()) nothrow @nogc
if (isIndex!I)
in (positions.address == 0 || (positions.strideFloats >= 3 && positions.strideFloats <= 64))
in (targetPartitionSize > 0)
in (destination.length >= clusterIndexCounts.length)
do {
    size_t clusterCount = clusterIndexCounts.length;
    size_t vertexCount = positions.count;
    size_t maxPartitionSize = targetPartitionSize + targetPartitionSize / 3;
    bool useBounds = positions.address != 0;

    immutable m = scratch.mark();
    scope (exit)
        scratch.release(m);

    ubyte[] used = scratch.allocate!ubyte(vertexCount);
    if (vertexCount)
        used[] = 0;

    uint[] raw = scratch.allocate!uint(clusterIndices.length);
    foreach (i, v; clusterIndices)
        raw[i] = v;
    uint[] indices = scratch.allocate!uint(clusterIndices.length);
    uint[] offsets = scratch.allocate!uint(clusterCount + 1);
    filterClusterIndices(indices, offsets, raw, clusterIndexCounts, used);

    ClusterAdjacency adjacency;
    buildClusterAdjacency(adjacency, indices, offsets, clusterCount, vertexCount, scratch);

    ClusterGroup[] groups = scratch.allocate!ClusterGroup(clusterCount);
    foreach (ref g; groups) {
        g.group = 0;
        g.next = 0;
        g.size = 0;
        g.vertices = 0;
        g.cx = 0;
        g.cy = 0;
        g.cz = 0;
        g.radius = 0;
    }

    GroupOrder[] order = scratch.allocate!GroupOrder(clusterCount);
    size_t pending = 0;
    uint[] sharedAcc = scratch.allocate!uint(clusterCount);
    if (clusterCount)
        sharedAcc[] = 0;

    foreach (i; 0 .. clusterCount) {
        groups[i].group = cast(int) i;
        groups[i].next = -1;
        groups[i].size = 1;
        groups[i].vertices = offsets[i + 1] - offsets[i];
        assert(groups[i].vertices > 0);
        if (useBounds) {
            CenterRadius sphere = averageClusterRadius(indices[offsets[i] .. offsets[i + 1]], positions);
            groups[i].cx = sphere.x;
            groups[i].cy = sphere.y;
            groups[i].cz = sphere.z;
            groups[i].radius = sphere.radius;
        }
        GroupOrder item;
        item.id = cast(uint) i;
        item.order = cast(int) groups[i].vertices;
        heapPush(order, pending++, item);
    }

    while (pending) {
        GroupOrder top = heapPop(order, pending--);
        if (groups[top.id].size == 0)
            continue;
        for (int i = cast(int) top.id; i >= 0; i = groups[i].next) {
            assert(groups[i].group == cast(int) top.id);
            groups[i].group = -1;
        }
        if (groups[top.id].size >= targetPartitionSize)
            continue;

        uint bestShared = 0;
        int bestGroup = pickGroupToMerge(groups, cast(int) top.id, adjacency, maxPartitionSize, useBounds, sharedAcc, bestShared);
        if (bestGroup == -1)
            continue;

        uint tail = top.id;
        while (groups[tail].next >= 0)
            tail = cast(uint) groups[tail].next;
        groups[tail].next = bestGroup;

        groups[top.id].size += groups[bestGroup].size;
        groups[top.id].vertices += groups[bestGroup].vertices;
        groups[top.id].vertices = (groups[top.id].vertices > bestShared) ? groups[top.id].vertices - bestShared : 1;
        groups[bestGroup].size = 0;
        groups[bestGroup].vertices = 0;

        if (useBounds) {
            mergeBounds(groups[top.id], groups[bestGroup]);
            groups[bestGroup].radius = 0;
        }
        for (int i = cast(int) top.id; i >= 0; i = groups[i].next)
            groups[i].group = cast(int) top.id;

        top.order = cast(int) groups[top.id].vertices;
        heapPush(order, pending++, top);
    }

    if (useBounds) {
        uint[] mergeOrder = scratch.allocate!uint(clusterCount);
        size_t mergeOffset = 0;
        foreach (i; 0 .. clusterCount)
            if (groups[i].size)
                mergeOrder[mergeOffset++] = cast(uint) i;
        mergeSpatial(groups, mergeOrder, mergeOffset, targetPartitionSize, maxPartitionSize, 8, 0);
    }

    size_t nextGroup = 0;
    foreach (i; 0 .. clusterCount) {
        if (groups[i].size == 0)
            continue;
        for (int j = cast(int) i; j >= 0; j = groups[j].next)
            destination[j] = cast(uint) nextGroup;
        nextGroup++;
    }
    assert(nextGroup <= clusterCount);
    return nextGroup;
}

@("partition.upstream") unittest {
    uint[24] ci = [
        0, 1, 3, 4, 5, 6,
        1, 2, 3, 6, 7, 8,
        4, 5, 6, 9, 10, 11,
        6, 7, 8, 9, 11, 12,
    ];
    uint[4] cc = [6, 6, 6, 6];
    uint[4] part;
    FloatStream none;
    none.count = 13;
    assert(partitionClusters(part[], ci[], cc[], none, 1) == 4);
    assert(part == [0, 1, 2, 3]);
    assert(partitionClusters(part[], ci[], cc[], none, 2) == 2);
    assert(part == [0, 0, 1, 1]);
    assert(partitionClusters(part[], ci[], cc[], none, 4) == 1);
    assert(part == [0, 0, 0, 0]);

    uint[9] ci2 = [0, 1, 2, 0, 3, 4, 0, 5, 6];
    float[21] vb = [
        0, 0, 0,
        1, 0, 0, 0, 1, 0,
        0, 2, 0, 2, 0, 0,
        -1, 0, 0, 0, -1, 0,
    ];
    uint[3] cc2 = [3, 3, 3];
    uint[3] part2;
    FloatStream none7;
    none7.count = 7;
    assert(partitionClusters(part2[], ci2[], cc2[], none7, 2) == 2);
    assert(part2 == [0, 0, 1]);
    FloatStream pos;
    pos.strideFloats = 3;
    pos.count = 7;
    pos.address = addrOf(vb);
    assert(partitionClusters(part2[], ci2[], cc2[], pos, 2) == 2);
    assert(part2 == [0, 1, 0]);

    uint[9] ci3 = [0, 1, 2, 3, 4, 5, 6, 7, 8];
    float[27] vb3 = [
        0, 0, 0, 1, 0, 0, 0, 1, 0,
        0, 0, 0, 0, 2, 0, 2, 0, 0,
        10, 0, 0, 10, 1, 0, 10, 2, 0,
    ];
    uint[3] cc3 = [3, 3, 3];
    uint[3] part3;
    FloatStream none9;
    none9.count = 9;
    assert(partitionClusters(part3[], ci3[], cc3[], none9, 2) == 3);
    assert(part3 == [0, 1, 2]);
    FloatStream pos3;
    pos3.strideFloats = 3;
    pos3.count = 9;
    pos3.address = addrOf(vb3);
    assert(partitionClusters(part3[], ci3[], cc3[], pos3, 2) == 2);
    assert(part3 == [0, 0, 1]);
}

private ulong addrOf(T)(T[] data) nothrow @nogc @trusted {
    return data.length ? cast(ulong) data.ptr : 0;
}
