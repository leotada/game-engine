// Ported from meshoptimizer v1.3 (src/clusterizer.cpp, src/meshletutils.cpp), Copyright (c) 2016-2026 Arseny Kapoulkine, MIT License.
/// Meshlet construction, cluster bounds, and a CPU cone/sphere reject helper.
module engine.meshopt.cluster;

import engine.meshopt.internal.sort : radixSortFloat;
import engine.meshopt.quantize : quantizeSnorm;
import engine.meshopt.scratch : MeshoptScratch, defaultScratch;
import engine.meshopt.types : Bounds, FloatStream, Meshlet;

@safe:

private enum bool isIndex(I) = is(I == uint) || is(I == ushort);

private enum size_t kMeshletMaxVertices = 256;
private enum size_t kMeshletMaxTriangles = 512;
private enum size_t kMeshletMaxSeeds = 256;
private enum size_t kMeshletAddSeeds = 4;
private enum int kMeshletMaxTreeDepth = 50;

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

private float load1(ulong address, size_t floatIndex) nothrow @nogc @trusted {
    const(float)* p = cast(const(float)*) address;
    return p[floatIndex];
}

private Bounds boundsZero() pure nothrow @nogc {
    Bounds b;
    b.center[] = 0;
    b.radius = 0;
    b.coneApex[] = 0;
    b.coneAxis[] = 0;
    b.coneCutoff = 0;
    b.coneAxisS8[] = 0;
    b.coneCutoffS8 = 0;
    return b;
}

private enum float[3][7] kBoundAxes = [
    [1, 0, 0],
    [0, 1, 0],
    [0, 0, 1],
    [0.57735026f, 0.57735026f, 0.57735026f],
    [-0.57735026f, 0.57735026f, 0.57735026f],
    [0.57735026f, -0.57735026f, 0.57735026f],
    [0.57735026f, 0.57735026f, -0.57735026f],
];

private void computeBoundingSphere(alias pointAt, alias radiusAt)(ref float[4] result, size_t count, size_t axisCount) nothrow @nogc {
    assert(count > 0);
    assert(axisCount <= kBoundAxes.length);
    uint[7] pmin, pmax;
    float[7] tmin, tmax;
    foreach (axis; 0 .. axisCount) {
        pmin[axis] = 0;
        pmax[axis] = 0;
        tmin[axis] = float.max;
        tmax[axis] = -float.max;
    }
    foreach (i; 0 .. count) {
        uint v = cast(uint) i;
        float[3] p = pointAt(v);
        float r = radiusAt(v);
        foreach (axis; 0 .. axisCount) {
            float[3] ax = kBoundAxes[axis];
            float tp = ax[0] * p[0] + ax[1] * p[1] + ax[2] * p[2];
            float tpmin = tp - r;
            float tpmax = tp + r;
            pmin[axis] = (tpmin < tmin[axis]) ? v : pmin[axis];
            pmax[axis] = (tpmax > tmax[axis]) ? v : pmax[axis];
            tmin[axis] = (tpmin < tmin[axis]) ? tpmin : tmin[axis];
            tmax[axis] = (tpmax > tmax[axis]) ? tpmax : tmax[axis];
        }
    }

    size_t paxis = 0;
    float paxisdr = 0;
    foreach (axis; 0 .. axisCount) {
        float[3] p1 = pointAt(pmin[axis]);
        float[3] p2 = pointAt(pmax[axis]);
        float r1 = radiusAt(pmin[axis]);
        float r2 = radiusAt(pmax[axis]);
        float dx = p2[0] - p1[0], dy = p2[1] - p1[1], dz = p2[2] - p1[2];
        float dr = sqrtF(dx * dx + dy * dy + dz * dz) + r1 + r2;
        if (dr > paxisdr) {
            paxisdr = dr;
            paxis = axis;
        }
    }

    float[3] p1 = pointAt(pmin[paxis]);
    float[3] p2 = pointAt(pmax[paxis]);
    float r1 = radiusAt(pmin[paxis]);
    float r2 = radiusAt(pmax[paxis]);
    float dx = p2[0] - p1[0], dy = p2[1] - p1[1], dz = p2[2] - p1[2];
    float paxisd = sqrtF(dx * dx + dy * dy + dz * dz);
    float paxisk = paxisd > 0 ? (paxisd + r2 - r1) / (2 * paxisd) : 0;
    float[3] center = [p1[0] + dx * paxisk, p1[1] + dy * paxisk, p1[2] + dz * paxisk];
    float radius = paxisdr / 2;

    foreach (i; 0 .. count) {
        uint v = cast(uint) i;
        float[3] p = pointAt(v);
        float r = radiusAt(v);
        float ex = p[0] - center[0], ey = p[1] - center[1], ez = p[2] - center[2];
        float d2 = ex * ex + ey * ey + ez * ez;
        float d = sqrtF(d2);
        if (d + r > radius) {
            float k = d > 0 ? (d + r - radius) / (2 * d) : 0;
            center[0] += k * ex;
            center[1] += k * ey;
            center[2] += k * ez;
            radius = (radius + d + r) / 2;
        }
    }
    result[0] = center[0];
    result[1] = center[1];
    result[2] = center[2];
    result[3] = radius;
}

private Bounds finishClusterBounds(scope const(uint)[] indices, FloatStream positions, scope const(uint)[] corners) nothrow @nogc {
    float[4][kMeshletMaxTriangles] normals;
    size_t triangles = 0;
    for (size_t i = 0; i < indices.length; i += 3) {
        uint a = indices[i + 0], b = indices[i + 1], c = indices[i + 2];
        float[3] p0 = positions.get3(a);
        float[3] p1 = positions.get3(b);
        float[3] p2 = positions.get3(c);
        float p10x = p1[0] - p0[0], p10y = p1[1] - p0[1], p10z = p1[2] - p0[2];
        float p20x = p2[0] - p0[0], p20y = p2[1] - p0[1], p20z = p2[2] - p0[2];
        float normalx = p10y * p20z - p10z * p20y;
        float normaly = p10z * p20x - p10x * p20z;
        float normalz = p10x * p20y - p10y * p20x;
        float area = sqrtF(normalx * normalx + normaly * normaly + normalz * normalz);
        if (area == 0)
            continue;
        normalx /= area;
        normaly /= area;
        normalz /= area;
        normals[triangles][0] = normalx;
        normals[triangles][1] = normaly;
        normals[triangles][2] = normalz;
        normals[triangles][3] = -(normalx * p0[0] + normaly * p0[1] + normalz * p0[2]);
        triangles++;
    }

    Bounds bounds = boundsZero();
    if (triangles == 0)
        return bounds;

    float[3] pointAt(size_t i) {
        return positions.get3(corners[i]);
    }

    float radiusAt(size_t) {
        return 0;
    }

    float[4] psphere = 0;
    computeBoundingSphere!(pointAt, radiusAt)(psphere, corners.length, 7);
    float[3] center = [psphere[0], psphere[1], psphere[2]];

    float[3] npoint(size_t i) {
        return [normals[i][0], normals[i][1], normals[i][2]];
    }

    float[4] nsphere = 0;
    computeBoundingSphere!(npoint, radiusAt)(nsphere, triangles, 3);
    float[3] axis = [nsphere[0], nsphere[1], nsphere[2]];
    float axisLength = sqrtF(axis[0] * axis[0] + axis[1] * axis[1] + axis[2] * axis[2]);
    float invAxis = axisLength == 0 ? 0 : 1.0f / axisLength;
    axis[0] *= invAxis;
    axis[1] *= invAxis;
    axis[2] *= invAxis;

    float mindp = 1;
    foreach (i; 0 .. triangles) {
        float dp = normals[i][0] * axis[0] + normals[i][1] * axis[1] + normals[i][2] * axis[2];
        mindp = dp < mindp ? dp : mindp;
    }

    bounds.center[] = center[];
    bounds.radius = psphere[3];
    if (mindp <= 0.1f) {
        bounds.coneCutoff = 1;
        bounds.coneCutoffS8 = 127;
        return bounds;
    }

    float maxt = 0;
    foreach (i; 0 .. triangles) {
        float dc = center[0] * normals[i][0] + center[1] * normals[i][1] + center[2] * normals[i][2] + normals[i][3];
        float dn = axis[0] * normals[i][0] + axis[1] * normals[i][1] + axis[2] * normals[i][2];
        assert(dn > 0);
        float t = dc / dn;
        maxt = t > maxt ? t : maxt;
    }

    bounds.coneApex[0] = center[0] - axis[0] * maxt;
    bounds.coneApex[1] = center[1] - axis[1] * maxt;
    bounds.coneApex[2] = center[2] - axis[2] * maxt;
    bounds.coneAxis[] = axis[];
    bounds.coneCutoff = sqrtF(1 - mindp * mindp);
    bounds.coneAxisS8[0] = cast(byte) quantizeSnorm(bounds.coneAxis[0], 8);
    bounds.coneAxisS8[1] = cast(byte) quantizeSnorm(bounds.coneAxis[1], 8);
    bounds.coneAxisS8[2] = cast(byte) quantizeSnorm(bounds.coneAxis[2], 8);
    float e0 = fabsF(bounds.coneAxisS8[0] / 127.0f - bounds.coneAxis[0]);
    float e1 = fabsF(bounds.coneAxisS8[1] / 127.0f - bounds.coneAxis[1]);
    float e2 = fabsF(bounds.coneAxisS8[2] / 127.0f - bounds.coneAxis[2]);
    int coneCutoffS8 = cast(int)(127 * (bounds.coneCutoff + e0 + e1 + e2) + 1);
    bounds.coneCutoffS8 = coneCutoffS8 > 127 ? 127 : cast(byte) coneCutoffS8;
    return bounds;
}

/**
 * Sphere and normal cone for an index cluster.
 * `indices.length / 3 <= 512`. At most 256 unique vertices are meaningful;
 * the routine still accepts any index that fits the triangle cap.
 */
Bounds computeClusterBounds(I)(scope const(I)[] indices, FloatStream positions) nothrow @nogc
if (isIndex!I)
in (indices.length % 3 == 0)
in (indices.length / 3 <= kMeshletMaxTriangles)
in (positions.strideFloats >= 3 && positions.strideFloats <= 64)
do {
    if (indices.length == 0)
        return boundsZero();
    uint[512] cache = uint.max;
    uint[kMeshletMaxTriangles * 3 + 1] corners;
    size_t cornerCount = 0;
    foreach (index; indices) {
        uint v = index;
        assert(v < positions.count);
        uint slot = v & 511;
        corners[cornerCount] = v;
        cornerCount += cache[slot] != v;
        cache[slot] = v;
    }
    static if (is(I == uint)) {
        return finishClusterBounds(indices, positions, corners[0 .. cornerCount]);
    } else {
        uint[kMeshletMaxTriangles * 3] local;
        foreach (i, v; indices)
            local[i] = v;
        return finishClusterBounds(local[0 .. indices.length], positions, corners[0 .. cornerCount]);
    }
}

/// Bounds of one meshlet. `triangleCount` is `meshletTriangles.length / 3`.
Bounds computeMeshletBounds(scope const(uint)[] meshletVertices, scope const(ubyte)[] meshletTriangles, FloatStream positions) nothrow @nogc
in (meshletTriangles.length % 3 == 0)
in (meshletTriangles.length / 3 <= kMeshletMaxTriangles)
in (positions.strideFloats >= 3 && positions.strideFloats <= 64)
do {
    size_t triangleCount = meshletTriangles.length / 3;
    if (triangleCount == 0)
        return boundsZero();
    uint[kMeshletMaxTriangles * 3] indices;
    size_t cornerCount = 0;
    foreach (i, t; meshletTriangles) {
        uint index = meshletVertices[t];
        assert(index < positions.count);
        indices[i] = index;
        cornerCount = t >= cornerCount ? t + 1 : cornerCount;
    }
    return finishClusterBounds(indices[0 .. triangleCount * 3], positions, meshletVertices[0 .. cornerCount]);
}

/**
 * Bounding sphere of points, or of spheres when `radiiAddress` is set.
 * Radii are strided floats. A zero address means radius 0.
 * Other `Bounds` fields are zero.
 */
Bounds computeSphereBounds(FloatStream positions, ulong radiiAddress = 0, size_t radiiStrideFloats = 0) nothrow @nogc
in (positions.strideFloats >= 3 && positions.strideFloats <= 64)
in (radiiAddress == 0 || (radiiStrideFloats >= 1 && radiiStrideFloats <= 64))
do {
    Bounds bounds = boundsZero();
    if (positions.count == 0)
        return bounds;

    float[3] pointAt(size_t i) {
        return positions.get3(i);
    }

    float radiusAt(size_t i) {
        if (radiiAddress == 0)
            return 0;
        return load1(radiiAddress, i * radiiStrideFloats);
    }

    float[4] psphere = 0;
    computeBoundingSphere!(pointAt, radiusAt)(psphere, positions.count, 7);
    bounds.center[0] = psphere[0];
    bounds.center[1] = psphere[1];
    bounds.center[2] = psphere[2];
    bounds.radius = psphere[3];
    return bounds;
}

/**
 * Orthographic backface reject: `dot(view, coneAxis) >= coneCutoff`.
 * Not called from the frame loop.
 */
bool clusterBackfaceOrtho(Bounds bounds, float vx, float vy, float vz) pure nothrow @nogc {
    float d = bounds.coneAxis[0] * vx + bounds.coneAxis[1] * vy + bounds.coneAxis[2] * vz;
    return d >= bounds.coneCutoff;
}

/**
 * Perspective backface reject using the bounding sphere (no cone apex).
 * Not called from the frame loop.
 */
bool clusterBackfacePerspective(Bounds bounds, float cx, float cy, float cz) nothrow @nogc {
    float dx = bounds.center[0] - cx;
    float dy = bounds.center[1] - cy;
    float dz = bounds.center[2] - cz;
    float dist = sqrtF(dx * dx + dy * dy + dz * dz);
    float d = dx * bounds.coneAxis[0] + dy * bounds.coneAxis[1] + dz * bounds.coneAxis[2];
    return d >= bounds.coneCutoff * dist + bounds.radius;
}

/// True when the sphere lies entirely outside an inward-facing plane.
bool clusterOutsidePlane(Bounds bounds, float nx, float ny, float nz, float pw) pure nothrow @nogc {
    float dist = nx * bounds.center[0] + ny * bounds.center[1] + nz * bounds.center[2] + pw;
    return dist < -bounds.radius;
}

// --- meshlet construction ---------------------------------------------------

private struct TriangleAdjacency2 {
    uint[] counts;
    uint[] offsets;
    uint[] data;
}

private struct Cone {
    float px = 0;
    float py = 0;
    float pz = 0;
    float nx = 0;
    float ny = 0;
    float nz = 0;
}

static assert(Cone.sizeof == 24);

private struct KDNode {
    float split = 0;
    uint index;
    uint axis;
    uint children;
}

private struct BVHBox {
    float[3] lo;
    float[3] hi;
}

private struct BVHBoxT {
    float[4] lo;
    float[4] hi;
}

private void buildTriangleAdjacency(ref TriangleAdjacency2 adjacency, const(uint)[] indices, size_t vertexCount, ref MeshoptScratch scratch) nothrow @nogc {
    size_t faceCount = indices.length / 3;
    adjacency.counts = scratch.allocate!uint(vertexCount);
    adjacency.offsets = scratch.allocate!uint(vertexCount);
    adjacency.data = scratch.allocate!uint(indices.length);
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
    assert(offset == indices.length);
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

private void buildTriangleAdjacencySparse(ref TriangleAdjacency2 adjacency, const(uint)[] indices, size_t vertexCount, ref MeshoptScratch scratch) nothrow @nogc {
    size_t faceCount = indices.length / 3;
    enum uint sparseSeen = 1u << 31;
    assert(indices.length < sparseSeen);
    adjacency.counts = scratch.allocate!uint(vertexCount);
    adjacency.offsets = scratch.allocate!uint(vertexCount);
    adjacency.data = scratch.allocate!uint(indices.length);
    foreach (index; indices)
        assert(index < vertexCount);
    foreach (index; indices)
        adjacency.counts[index] = 0;
    foreach (index; indices)
        adjacency.counts[index]++;
    uint offset = 0;
    foreach (v; indices) {
        if ((adjacency.counts[v] & sparseSeen) == 0) {
            adjacency.offsets[v] = offset;
            offset += adjacency.counts[v];
            adjacency.counts[v] |= sparseSeen;
        }
    }
    assert(offset == indices.length);
    foreach (i; 0 .. faceCount) {
        uint a = indices[i * 3 + 0], b = indices[i * 3 + 1], c = indices[i * 3 + 2];
        adjacency.data[adjacency.offsets[a]++] = cast(uint) i;
        adjacency.data[adjacency.offsets[b]++] = cast(uint) i;
        adjacency.data[adjacency.offsets[c]++] = cast(uint) i;
    }
    foreach (v; indices) {
        if (adjacency.counts[v] & sparseSeen) {
            adjacency.counts[v] &= ~sparseSeen;
            assert(adjacency.offsets[v] >= adjacency.counts[v]);
            adjacency.offsets[v] -= adjacency.counts[v];
        }
    }
}

private void clearUsed(short[] used, const(uint)[] indices) pure nothrow @nogc {
    if (used.length <= indices.length)
        used[] = -1;
    else {
        foreach (v; indices) {
            assert(v < used.length);
            used[v] = -1;
        }
    }
}

private float getMeshletScore(float distance, float spread, float coneWeight, float expectedRadius) pure nothrow @nogc {
    float cone = 1 - spread * coneWeight;
    float coneClamped = cone < 1e-3f ? 1e-3f : cone;
    return (1 + distance / expectedRadius * (1 - coneWeight)) * coneClamped;
}

private Cone getMeshletCone(Cone acc, uint triangleCount) nothrow @nogc {
    Cone result = acc;
    float centerScale = triangleCount == 0 ? 0 : 1.0f / cast(float) triangleCount;
    result.px *= centerScale;
    result.py *= centerScale;
    result.pz *= centerScale;
    float axisLength = result.nx * result.nx + result.ny * result.ny + result.nz * result.nz;
    float axisScale = axisLength == 0 ? 0 : 1.0f / sqrtF(axisLength);
    result.nx *= axisScale;
    result.ny *= axisScale;
    result.nz *= axisScale;
    return result;
}

private float computeTriangleCones(Cone[] triangles, const(uint)[] indices, FloatStream positions) nothrow @nogc {
    size_t faceCount = indices.length / 3;
    float meshArea = 0;
    foreach (i; 0 .. faceCount) {
        uint a = indices[i * 3 + 0], b = indices[i * 3 + 1], c = indices[i * 3 + 2];
        float[3] p0 = positions.get3(a);
        float[3] p1 = positions.get3(b);
        float[3] p2 = positions.get3(c);
        float p10x = p1[0] - p0[0], p10y = p1[1] - p0[1], p10z = p1[2] - p0[2];
        float p20x = p2[0] - p0[0], p20y = p2[1] - p0[1], p20z = p2[2] - p0[2];
        float normalx = p10y * p20z - p10z * p20y;
        float normaly = p10z * p20x - p10x * p20z;
        float normalz = p10x * p20y - p10y * p20x;
        float area = sqrtF(normalx * normalx + normaly * normaly + normalz * normalz);
        float invarea = area == 0 ? 0 : 1.0f / area;
        triangles[i].px = (p0[0] + p1[0] + p2[0]) / 3.0f;
        triangles[i].py = (p0[1] + p1[1] + p2[1]) / 3.0f;
        triangles[i].pz = (p0[2] + p1[2] + p2[2]) / 3.0f;
        triangles[i].nx = normalx * invarea;
        triangles[i].ny = normaly * invarea;
        triangles[i].nz = normalz * invarea;
        meshArea += area;
    }
    return meshArea;
}

private bool appendMeshlet(ref Meshlet meshlet, uint a, uint b, uint c, scope short[] used, scope Meshlet[] meshlets, scope uint[] meshletVertices, scope ubyte[] meshletTriangles, size_t meshletOffset, size_t maxVertices, size_t maxTriangles, bool split) pure nothrow @nogc {
    int usedExtra = (used[a] < 0) + (used[b] < 0) + (used[c] < 0);
    bool result = false;
    if (meshlet.vertexCount + usedExtra > maxVertices || meshlet.triangleCount >= maxTriangles || split) {
        meshlets[meshletOffset] = meshlet;
        foreach (j; 0 .. meshlet.vertexCount)
            used[meshletVertices[meshlet.vertexOffset + j]] = -1;
        meshlet.vertexOffset += meshlet.vertexCount;
        meshlet.triangleOffset += meshlet.triangleCount * 3;
        meshlet.vertexCount = 0;
        meshlet.triangleCount = 0;
        result = true;
    }
    if (used[a] < 0) {
        used[a] = cast(short) meshlet.vertexCount;
        meshletVertices[meshlet.vertexOffset + meshlet.vertexCount] = a;
        meshlet.vertexCount++;
    }
    if (used[b] < 0) {
        used[b] = cast(short) meshlet.vertexCount;
        meshletVertices[meshlet.vertexOffset + meshlet.vertexCount] = b;
        meshlet.vertexCount++;
    }
    if (used[c] < 0) {
        used[c] = cast(short) meshlet.vertexCount;
        meshletVertices[meshlet.vertexOffset + meshlet.vertexCount] = c;
        meshlet.vertexCount++;
    }
    size_t to = meshlet.triangleOffset + meshlet.triangleCount * 3;
    meshletTriangles[to + 0] = cast(ubyte) used[a];
    meshletTriangles[to + 1] = cast(ubyte) used[b];
    meshletTriangles[to + 2] = cast(ubyte) used[c];
    meshlet.triangleCount++;
    return result;
}

private uint getNeighborTriangle(ref const(Meshlet) meshlet, Cone meshletCone, scope const(uint)[] meshletVertices, scope const(uint)[] indices, ref const(TriangleAdjacency2) adjacency, scope const(Cone)[] triangles, scope const(uint)[] liveTriangles, scope const(short)[] used, float expectedRadius, float coneWeight) nothrow @nogc {
    uint bestTriangle = uint.max;
    int bestPriority = 5;
    float bestScore = float.max;
    foreach (i; 0 .. meshlet.vertexCount) {
        uint index = meshletVertices[meshlet.vertexOffset + i];
        size_t base = adjacency.offsets[index];
        size_t neighborsSize = adjacency.counts[index];
        foreach (j; 0 .. neighborsSize) {
            uint triangle = adjacency.data[base + j];
            uint a = indices[triangle * 3 + 0], b = indices[triangle * 3 + 1], c = indices[triangle * 3 + 2];
            int extra = (used[a] < 0) + (used[b] < 0) + (used[c] < 0);
            assert(extra <= 2);
            int priority = -1;
            if (extra == 0)
                priority = 0;
            else if (liveTriangles[a] == 1 || liveTriangles[b] == 1 || liveTriangles[c] == 1)
                priority = 1;
            else if ((liveTriangles[a] == 2) + (liveTriangles[b] == 2) + (liveTriangles[c] == 2) >= 2)
                priority = 1 + extra;
            else
                priority = 2 + extra;
            if (priority > bestPriority)
                continue;
            Cone triCone = triangles[triangle];
            float dx = triCone.px - meshletCone.px, dy = triCone.py - meshletCone.py, dz = triCone.pz - meshletCone.pz;
            float distance = sqrtF(dx * dx + dy * dy + dz * dz);
            float spread = triCone.nx * meshletCone.nx + triCone.ny * meshletCone.ny + triCone.nz * meshletCone.nz;
            float score = getMeshletScore(distance, spread, coneWeight, expectedRadius);
            if (priority < bestPriority || score < bestScore) {
                bestTriangle = triangle;
                bestPriority = priority;
                bestScore = score;
            }
        }
    }
    return bestTriangle;
}

private size_t appendSeedTriangles(scope uint[] seeds, ref const(Meshlet) meshlet, scope const(uint)[] meshletVertices, scope const(uint)[] indices, ref const(TriangleAdjacency2) adjacency, scope const(Cone)[] triangles, scope const(uint)[] liveTriangles, float cornerx, float cornery, float cornerz) nothrow @nogc {
    uint[kMeshletAddSeeds] bestSeeds = uint.max;
    uint[kMeshletAddSeeds] bestLive = uint.max;
    float[kMeshletAddSeeds] bestScore = float.max;
    foreach (i; 0 .. meshlet.vertexCount) {
        uint index = meshletVertices[meshlet.vertexOffset + i];
        uint bestNeighbor = uint.max;
        uint bestNeighborLive = uint.max;
        size_t base = adjacency.offsets[index];
        size_t neighborsSize = adjacency.counts[index];
        foreach (j; 0 .. neighborsSize) {
            uint triangle = adjacency.data[base + j];
            uint a = indices[triangle * 3 + 0], b = indices[triangle * 3 + 1], c = indices[triangle * 3 + 2];
            uint live = liveTriangles[a] + liveTriangles[b] + liveTriangles[c];
            if (live < bestNeighborLive) {
                bestNeighbor = triangle;
                bestNeighborLive = live;
            }
        }
        if (bestNeighbor == uint.max)
            continue;
        float dx = triangles[bestNeighbor].px - cornerx;
        float dy = triangles[bestNeighbor].py - cornery;
        float dz = triangles[bestNeighbor].pz - cornerz;
        float bestNeighborScore = sqrtF(dx * dx + dy * dy + dz * dz);
        foreach (j; 0 .. kMeshletAddSeeds) {
            if (bestNeighborLive < bestLive[j] || (bestNeighborLive == bestLive[j] && bestNeighborScore <= bestScore[j])) {
                bestSeeds[j] = bestNeighbor;
                bestLive[j] = bestNeighborLive;
                bestScore[j] = bestNeighborScore;
                break;
            }
        }
    }
    size_t seedCount = 0;
    foreach (i; 0 .. kMeshletAddSeeds)
        if (bestSeeds[i] != uint.max)
            seeds[seedCount++] = bestSeeds[i];
    return seedCount;
}

private size_t pruneSeedTriangles(scope uint[] seeds, size_t seedCount, scope const(ubyte)[] emitted) pure nothrow @nogc {
    size_t result = 0;
    foreach (i; 0 .. seedCount) {
        uint index = seeds[i];
        seeds[result] = index;
        result += emitted[index] == 0;
    }
    return result;
}

private uint selectSeedTriangle(scope const(uint)[] seeds, scope const(uint)[] indices, scope const(Cone)[] triangles, scope const(uint)[] liveTriangles, float cornerx, float cornery, float cornerz) nothrow @nogc {
    uint bestSeed = uint.max;
    uint bestLive = uint.max;
    float bestScore = float.max;
    foreach (index; seeds) {
        uint a = indices[index * 3 + 0], b = indices[index * 3 + 1], c = indices[index * 3 + 2];
        uint live = liveTriangles[a] + liveTriangles[b] + liveTriangles[c];
        float dx = triangles[index].px - cornerx, dy = triangles[index].py - cornery, dz = triangles[index].pz - cornerz;
        float score = sqrtF(dx * dx + dy * dy + dz * dz);
        if (live < bestLive || (live == bestLive && score < bestScore)) {
            bestSeed = index;
            bestLive = live;
            bestScore = score;
        }
    }
    return bestSeed;
}

private float coneCoord(const(Cone)[] points, size_t index, int axis) pure nothrow @nogc {
    Cone c = points[index];
    return axis == 0 ? c.px : (axis == 1 ? c.py : c.pz);
}

private size_t kdtreePartition(uint[] indices, const(Cone)[] points, int axis, float pivot) pure nothrow @nogc {
    size_t count = indices.length;
    size_t m = 0;
    foreach (i; 0 .. count) {
        float v = coneCoord(points, indices[i], axis);
        uint t = indices[m];
        indices[m] = indices[i];
        indices[i] = t;
        m += v < pivot;
    }
    return m;
}

private size_t kdtreeBuildLeaf(size_t offset, KDNode[] nodes, uint[] indices) pure nothrow @nogc {
    size_t count = indices.length;
    nodes[offset].index = indices[0];
    nodes[offset].axis = 3;
    nodes[offset].children = cast(uint) count;
    nodes[offset].split = 0;
    foreach (i; 1 .. count) {
        nodes[offset + i].index = indices[i];
        nodes[offset + i].axis = 3;
        nodes[offset + i].children = uint.max >> 2;
        nodes[offset + i].split = 0;
    }
    return offset + count;
}

private size_t kdtreeBuild(size_t offset, KDNode[] nodes, const(Cone)[] points, uint[] indices, size_t leafSize, int depth) nothrow @nogc {
    size_t count = indices.length;
    assert(count > 0);
    assert(offset < nodes.length);
    if (count <= leafSize)
        return kdtreeBuildLeaf(offset, nodes, indices);
    float[3] mean = 0;
    float[3] vars = 0;
    float runc = 1;
    float runs = 1;
    foreach (i; 0 .. count) {
        float[3] point;
        point[0] = coneCoord(points, indices[i], 0);
        point[1] = coneCoord(points, indices[i], 1);
        point[2] = coneCoord(points, indices[i], 2);
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
    size_t middle = kdtreePartition(indices, points, axis, split);
    if (middle <= leafSize / 2 || middle >= count - leafSize / 2 || depth >= kMeshletMaxTreeDepth)
        return kdtreeBuildLeaf(offset, nodes, indices);
    nodes[offset].split = split;
    nodes[offset].axis = cast(uint) axis;
    size_t nextOffset = kdtreeBuild(offset + 1, nodes, points, indices[0 .. middle], leafSize, depth + 1);
    assert(nextOffset - offset > 1);
    nodes[offset].children = cast(uint)(nextOffset - offset - 1);
    return kdtreeBuild(nextOffset, nodes, points, indices[middle .. count], leafSize, depth + 1);
}

private void kdtreeNearest(KDNode[] nodes, uint root, const(Cone)[] triangles, const(ubyte)[] emitted, float px, float py, float pz, ref uint result, ref float limit) nothrow @nogc {
    KDNode node = nodes[root];
    if (node.children == 0)
        return;
    if (node.axis == 3) {
        bool inactive = true;
        foreach (i; 0 .. node.children) {
            uint index = nodes[root + i].index;
            if (emitted[index])
                continue;
            inactive = false;
            float dx = coneCoord(triangles, index, 0) - px;
            float dy = coneCoord(triangles, index, 1) - py;
            float dz = coneCoord(triangles, index, 2) - pz;
            float distance = sqrtF(dx * dx + dy * dy + dz * dz);
            if (distance < limit) {
                result = index;
                limit = distance;
            }
        }
        if (inactive)
            nodes[root].children = 0;
    } else {
        float coord = node.axis == 0 ? px : (node.axis == 1 ? py : pz);
        float delta = coord - node.split;
        uint first = delta <= 0 ? 0 : node.children;
        uint second = first ^ node.children;
        if ((nodes[root + 1 + first].children | nodes[root + 1 + second].children) == 0)
            nodes[root].children = 0;
        kdtreeNearest(nodes, root + 1 + first, triangles, emitted, px, py, pz, result, limit);
        if (fabsF(delta) <= limit)
            kdtreeNearest(nodes, root + 1 + second, triangles, emitted, px, py, pz, result, limit);
    }
}

private float boxMerge(ref BVHBoxT box, ref const(BVHBox) other) pure nothrow @nogc {
    foreach (k; 0 .. 3) {
        box.lo[k] = other.lo[k] < box.lo[k] ? other.lo[k] : box.lo[k];
        box.hi[k] = other.hi[k] > box.hi[k] ? other.hi[k] : box.hi[k];
    }
    float sx = box.hi[0] - box.lo[0];
    float sy = box.hi[1] - box.lo[1];
    float sz = box.hi[2] - box.lo[2];
    return sx * sy + sy * sz + sz * sx;
}

private void bvhPrepare(BVHBox[] boxes, float[] centroids, const(uint)[] indices, FloatStream positions) nothrow @nogc {
    size_t faceCount = indices.length / 3;
    foreach (i; 0 .. faceCount) {
        uint a = indices[i * 3 + 0], b = indices[i * 3 + 1], c = indices[i * 3 + 2];
        float[3] va = positions.get3(a);
        float[3] vb = positions.get3(b);
        float[3] vc = positions.get3(c);
        foreach (k; 0 .. 3) {
            float lo = va[k] < vb[k] ? va[k] : vb[k];
            lo = vc[k] < lo ? vc[k] : lo;
            float hi = va[k] > vb[k] ? va[k] : vb[k];
            hi = vc[k] > hi ? vc[k] : hi;
            boxes[i].lo[k] = lo;
            boxes[i].hi[k] = hi;
            centroids[i + faceCount * k] = (lo + hi) / 2;
        }
    }
}

private size_t bvhCountVertices(const(uint)[] order, short[] used, const(uint)[] indices, uint[] sink) pure nothrow @nogc {
    size_t count = order.length;
    size_t usedVertices = 0;
    foreach (i; 0 .. count) {
        uint index = order[i];
        uint a = indices[index * 3 + 0], b = indices[index * 3 + 1], c = indices[index * 3 + 2];
        usedVertices += (used[a] < 0) + (used[b] < 0) + (used[c] < 0);
        used[a] = used[b] = used[c] = 1;
        if (sink.length)
            sink[i] = cast(uint) usedVertices;
    }
    foreach (index; order) {
        uint a = indices[index * 3 + 0], b = indices[index * 3 + 1], c = indices[index * 3 + 2];
        used[a] = used[b] = used[c] = -1;
    }
    return usedVertices;
}

private void bvhPackLeaf(ubyte[] boundary) pure nothrow @nogc {
    assert(boundary.length > 0);
    boundary[0] = 1;
    boundary[1 .. $] = 0;
}

private void bvhPackTail(ubyte[] boundary, const(uint)[] order, short[] used, const(uint)[] indices, size_t maxVertices, size_t maxTriangles) pure nothrow @nogc {
    size_t count = order.length;
    size_t i = 0;
    while (i < count) {
        size_t chunk = i + maxTriangles <= count ? maxTriangles : count - i;
        if (bvhCountVertices(order[i .. i + chunk], used, indices, null) <= maxVertices) {
            bvhPackLeaf(boundary[i .. i + chunk]);
            i += chunk;
            continue;
        }
        assert(chunk > maxVertices / 3);
        size_t leaf = maxVertices / 3;
        bvhPackLeaf(boundary[i .. i + leaf]);
        i += leaf;
    }
}

private bool bvhDivisible(size_t count, size_t min, size_t max) pure nothrow @nogc {
    return min * 2 <= max ? count >= min : count % min <= (count / min) * (max - min);
}

private void bvhComputeArea(float[] areas, const(BVHBox)[] boxes, const(uint)[] order) pure nothrow @nogc {
    size_t count = order.length;
    BVHBoxT accuml;
    accuml.lo[0] = float.max;
    accuml.lo[1] = float.max;
    accuml.lo[2] = float.max;
    accuml.lo[3] = 0;
    accuml.hi[0] = -float.max;
    accuml.hi[1] = -float.max;
    accuml.hi[2] = -float.max;
    accuml.hi[3] = 0;
    BVHBoxT accumr = accuml;
    foreach (i; 0 .. count) {
        float larea = boxMerge(accuml, boxes[order[i]]);
        float rarea = boxMerge(accumr, boxes[order[count - 1 - i]]);
        areas[i] = larea;
        areas[i + count] = rarea;
    }
}

private size_t bvhPivot(const(float)[] areas, const(uint)[] vertices, size_t count, size_t step, size_t min, size_t max, float fill, size_t maxfill, out float outCost) pure nothrow @nogc {
    bool aligned = count >= min * 2 && bvhDivisible(count, min, max);
    size_t end = aligned ? count - min : count - 1;
    float rmaxfill = 1.0f / cast(float) cast(int) maxfill;
    size_t bestsplit = 0;
    float bestcost = float.max;
    for (size_t i = min - 1; i < end; i += step) {
        size_t lsplit = i + 1;
        size_t rsplit = count - (i + 1);
        if (!bvhDivisible(lsplit, min, max))
            continue;
        if (aligned && !bvhDivisible(rsplit, min, max))
            continue;
        float larea = areas[i];
        float rarea = areas[(count - 1 - (i + 1)) + count];
        float cost = larea * cast(float) cast(int) lsplit + rarea * cast(float) cast(int) rsplit;
        if (cost > bestcost)
            continue;
        size_t lfill = vertices.length ? vertices[i] : lsplit;
        size_t rfill = vertices.length ? vertices[i] : rsplit;
        int lrest = cast(int)(cast(float) cast(int)(lfill + maxfill - 1) * rmaxfill) * cast(int) maxfill - cast(int) lfill;
        int rrest = cast(int)(cast(float) cast(int)(rfill + maxfill - 1) * rmaxfill) * cast(int) maxfill - cast(int) rfill;
        cost += fill * (cast(float) lrest * larea + cast(float) rrest * rarea);
        if (cost < bestcost) {
            bestcost = cost;
            bestsplit = i + 1;
        }
    }
    outCost = bestcost;
    return bestsplit;
}

private void bvhPartition(uint[] target, const(uint)[] order, const(ubyte)[] sides, size_t split) pure nothrow @nogc {
    size_t count = order.length;
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

private void bvhSplit(const(BVHBox)[] boxes, uint[] orderx, uint[] ordery, uint[] orderz, ubyte[] boundary, int depth, float[] areas, uint[] vertScratch, ubyte[] sides, uint[] temp, short[] used, const(uint)[] indices, size_t maxVertices, size_t minTriangles, size_t maxTriangles, float fillWeight) nothrow @nogc {
    size_t count = boundary.length;
    assert(orderx.length >= count && ordery.length >= count && orderz.length >= count);
    if (count <= maxTriangles && bvhCountVertices(orderx[0 .. count], used, indices, null) <= maxVertices)
        return bvhPackLeaf(boundary);

    size_t step = minTriangles == maxTriangles && count > maxTriangles ? maxTriangles : 1;
    size_t mint = count <= maxTriangles && maxVertices / 3 < minTriangles ? maxVertices / 3 : minTriangles;
    size_t maxfill = count <= maxTriangles ? maxVertices : maxTriangles;
    int bestk = -1;
    size_t bestsplit = 0;
    float bestcost = float.max;
    foreach (k; 0 .. 3) {
        uint[] axis = k == 0 ? orderx : (k == 1 ? ordery : orderz);
        bvhComputeArea(areas[0 .. count * 2], boxes, axis[0 .. count]);
        uint[] vertices;
        if (count <= maxTriangles) {
            bvhCountVertices(axis[0 .. count], used, indices, vertScratch[0 .. count]);
            vertices = vertScratch[0 .. count];
        }
        float axiscost;
        size_t axissplit = bvhPivot(areas, vertices, count, step, mint, maxTriangles, fillWeight, maxfill, axiscost);
        if (axissplit && axiscost < bestcost) {
            bestk = cast(int) k;
            bestcost = axiscost;
            bestsplit = axissplit;
        }
    }
    if (bestk < 0 || depth >= kMeshletMaxTreeDepth)
        return bvhPackTail(boundary, orderx[0 .. count], used, indices, maxVertices, maxTriangles);

    uint[] bestAxis = bestk == 0 ? orderx : (bestk == 1 ? ordery : orderz);
    foreach (i; 0 .. bestsplit)
        sides[bestAxis[i]] = 0;
    foreach (i; bestsplit .. count)
        sides[bestAxis[i]] = 1;
    foreach (k; 0 .. 3) {
        if (k == bestk)
            continue;
        uint[] axis = k == 0 ? orderx : (k == 1 ? ordery : orderz);
        temp[0 .. count] = axis[0 .. count];
        bvhPartition(axis[0 .. count], temp[0 .. count], sides, bestsplit);
    }
    bvhSplit(boxes, orderx[0 .. bestsplit], ordery[0 .. bestsplit], orderz[0 .. bestsplit], boundary[0 .. bestsplit], depth + 1, areas, vertScratch, sides, temp, used, indices, maxVertices, minTriangles, maxTriangles, fillWeight);
    bvhSplit(boxes, orderx[bestsplit .. count], ordery[bestsplit .. count], orderz[bestsplit .. count], boundary[bestsplit .. count], depth + 1, areas, vertScratch, sides, temp, used, indices, maxVertices, minTriangles, maxTriangles, fillWeight);
}

private uint[] copyIndices(I)(scope const(I)[] indices, ref MeshoptScratch scratch) {
    uint[] idx = scratch.allocate!uint(indices.length);
    foreach (i, v; indices)
        idx[i] = v;
    return idx;
}

/// Worst-case meshlet count for `indexCount` indices.
size_t buildMeshletsBound(size_t indexCount, size_t maxVertices, size_t maxTriangles) pure nothrow @nogc
in (indexCount % 3 == 0)
in (maxVertices >= 3 && maxVertices <= kMeshletMaxVertices)
in (maxTriangles >= 1 && maxTriangles <= kMeshletMaxTriangles)
do {
    size_t maxVerticesConservative = maxVertices - 2;
    size_t limitVertices = (indexCount + maxVerticesConservative - 1) / maxVerticesConservative;
    size_t limitTriangles = (indexCount / 3 + maxTriangles - 1) / maxTriangles;
    return limitVertices > limitTriangles ? limitVertices : limitTriangles;
}

/**
 * Greedy meshlets with a flexible triangle range.
 * The output bound is `buildMeshletsBound(indices.length, maxVertices, minTriangles)`.
 */
size_t buildMeshletsFlex(I)(scope Meshlet[] meshlets, scope uint[] meshletVertices, scope ubyte[] meshletTriangles, scope const(I)[] indices, FloatStream positions, size_t maxVertices, size_t minTriangles, size_t maxTriangles, float coneWeight, float splitFactor, ref MeshoptScratch scratch = defaultScratch()) nothrow @nogc
if (isIndex!I)
in (indices.length % 3 == 0)
in (positions.strideFloats >= 3 && positions.strideFloats <= 64)
in (maxVertices >= 3 && maxVertices <= kMeshletMaxVertices)
in (minTriangles >= 1 && minTriangles <= maxTriangles && maxTriangles <= kMeshletMaxTriangles)
in (coneWeight >= 0 && coneWeight <= 1)
in (splitFactor >= 0)
do {
    if (indices.length == 0)
        return 0;
    size_t bound = buildMeshletsBound(indices.length, maxVertices, minTriangles);

    immutable mark = scratch.mark();
    scope (exit)
        scratch.release(mark);
    uint[] idx = copyIndices(indices, scratch);
    size_t vertexCount = positions.count;
    size_t faceCount = idx.length / 3;

    TriangleAdjacency2 adjacency;
    if (vertexCount > idx.length && idx.length < (1u << 31))
        buildTriangleAdjacencySparse(adjacency, idx, vertexCount, scratch);
    else
        buildTriangleAdjacency(adjacency, idx, vertexCount, scratch);
    uint[] liveTriangles = adjacency.counts;

    ubyte[] emitted = scratch.allocate!ubyte(faceCount);
    emitted[] = 0;
    Cone[] triangles = scratch.allocate!Cone(faceCount);
    float meshArea = computeTriangleCones(triangles, idx, positions);
    float triangleAreaAvg = faceCount == 0 ? 0 : meshArea / cast(float) faceCount * 0.5f;
    float expectedRadius = sqrtF(triangleAreaAvg * cast(float) maxTriangles) * 0.5f;

    uint[] kdindices = scratch.allocate!uint(faceCount);
    foreach (i; 0 .. faceCount)
        kdindices[i] = cast(uint) i;
    KDNode[] nodes = scratch.allocate!KDNode(faceCount * 2);
    kdtreeBuild(0, nodes, triangles, kdindices, 8, 0);

    float cornerx = float.max, cornery = float.max, cornerz = float.max;
    foreach (tri; triangles) {
        cornerx = cornerx > tri.px ? tri.px : cornerx;
        cornery = cornery > tri.py ? tri.py : cornery;
        cornerz = cornerz > tri.pz ? tri.pz : cornerz;
    }

    short[] used = scratch.allocate!short(vertexCount);
    clearUsed(used, idx);

    uint initialSeed = uint.max;
    float initialScore = float.max;
    foreach (i, tri; triangles) {
        float dx = tri.px - cornerx, dy = tri.py - cornery, dz = tri.pz - cornerz;
        float score = sqrtF(dx * dx + dy * dy + dz * dz);
        if (initialSeed == uint.max || score < initialScore) {
            initialSeed = cast(uint) i;
            initialScore = score;
        }
    }

    uint[kMeshletMaxSeeds] seeds;
    size_t seedCount = 0;
    Meshlet meshlet;
    size_t meshletOffset = 0;
    Cone meshletConeAcc;
    meshletConeAcc.px = meshletConeAcc.py = meshletConeAcc.pz = 0;
    meshletConeAcc.nx = meshletConeAcc.ny = meshletConeAcc.nz = 0;

    while (true) {
        Cone meshletCone = getMeshletCone(meshletConeAcc, meshlet.triangleCount);
        uint bestTriangle = uint.max;
        if (meshletOffset == 0 && meshlet.triangleCount == 0)
            bestTriangle = initialSeed;
        else
            bestTriangle = getNeighborTriangle(meshlet, meshletCone, meshletVertices, idx, adjacency, triangles, liveTriangles, used, expectedRadius, coneWeight);

        bool split = false;
        if (bestTriangle == uint.max) {
            uint index = uint.max;
            float distance = float.max;
            kdtreeNearest(nodes, 0, triangles, emitted, meshletCone.px, meshletCone.py, meshletCone.pz, index, distance);
            bestTriangle = index;
            split = meshlet.triangleCount >= minTriangles && splitFactor > 0 && distance > expectedRadius * splitFactor;
        }
        if (bestTriangle == uint.max)
            break;

        int bestExtra = (used[idx[bestTriangle * 3 + 0]] < 0) + (used[idx[bestTriangle * 3 + 1]] < 0) + (used[idx[bestTriangle * 3 + 2]] < 0);
        if (split || meshlet.vertexCount + bestExtra > maxVertices || meshlet.triangleCount >= maxTriangles) {
            seedCount = pruneSeedTriangles(seeds[], seedCount, emitted);
            seedCount = (seedCount + kMeshletAddSeeds <= kMeshletMaxSeeds) ? seedCount : kMeshletMaxSeeds - kMeshletAddSeeds;
            seedCount += appendSeedTriangles(seeds[seedCount .. $], meshlet, meshletVertices, idx, adjacency, triangles, liveTriangles, cornerx, cornery, cornerz);
            uint bestSeed = selectSeedTriangle(seeds[0 .. seedCount], idx, triangles, liveTriangles, cornerx, cornery, cornerz);
            bestTriangle = bestSeed != uint.max ? bestSeed : bestTriangle;
        }

        uint a = idx[bestTriangle * 3 + 0], b = idx[bestTriangle * 3 + 1], c = idx[bestTriangle * 3 + 2];
        if (appendMeshlet(meshlet, a, b, c, used, meshlets, meshletVertices, meshletTriangles, meshletOffset, maxVertices, maxTriangles, split)) {
            meshletOffset++;
            meshletConeAcc.px = meshletConeAcc.py = meshletConeAcc.pz = 0;
            meshletConeAcc.nx = meshletConeAcc.ny = meshletConeAcc.nz = 0;
        }

        foreach (k; 0 .. 3) {
            uint index = idx[bestTriangle * 3 + k];
            size_t base = adjacency.offsets[index];
            size_t neighborsSize = adjacency.counts[index];
            foreach (i; 0 .. neighborsSize) {
                uint tri = adjacency.data[base + i];
                if (tri == bestTriangle) {
                    adjacency.data[base + i] = adjacency.data[base + neighborsSize - 1];
                    adjacency.counts[index]--;
                    break;
                }
            }
        }

        meshletConeAcc.px += triangles[bestTriangle].px;
        meshletConeAcc.py += triangles[bestTriangle].py;
        meshletConeAcc.pz += triangles[bestTriangle].pz;
        meshletConeAcc.nx += triangles[bestTriangle].nx;
        meshletConeAcc.ny += triangles[bestTriangle].ny;
        meshletConeAcc.nz += triangles[bestTriangle].nz;
        assert(!emitted[bestTriangle]);
        emitted[bestTriangle] = 1;
    }

    if (meshlet.triangleCount)
        meshlets[meshletOffset++] = meshlet;
    assert(meshletOffset <= bound);
    return meshletOffset;
}

/// Greedy meshlets. `minTriangles == maxTriangles` and `splitFactor == 0`.
size_t buildMeshlets(I)(scope Meshlet[] meshlets, scope uint[] meshletVertices, scope ubyte[] meshletTriangles, scope const(I)[] indices, FloatStream positions, size_t maxVertices, size_t maxTriangles, float coneWeight, ref MeshoptScratch scratch = defaultScratch()) nothrow @nogc
if (isIndex!I)
in (maxVertices >= 3 && maxVertices <= kMeshletMaxVertices)
in (maxTriangles >= 1 && maxTriangles <= kMeshletMaxTriangles)
do {
    return buildMeshletsFlex(meshlets, meshletVertices, meshletTriangles, indices, positions, maxVertices, maxTriangles, maxTriangles, coneWeight, 0, scratch);
}

/// Scan meshlets in index order, without spatial scoring.
size_t buildMeshletsScan(I)(scope Meshlet[] meshlets, scope uint[] meshletVertices, scope ubyte[] meshletTriangles, scope const(I)[] indices, size_t vertexCount, size_t maxVertices, size_t maxTriangles, ref MeshoptScratch scratch = defaultScratch()) nothrow @nogc
if (isIndex!I)
in (indices.length % 3 == 0)
in (maxVertices >= 3 && maxVertices <= kMeshletMaxVertices)
in (maxTriangles >= 1 && maxTriangles <= kMeshletMaxTriangles)
do {
    if (indices.length == 0)
        return 0;
    size_t bound = buildMeshletsBound(indices.length, maxVertices, maxTriangles);
    immutable mark = scratch.mark();
    scope (exit)
        scratch.release(mark);
    uint[] idx = copyIndices(indices, scratch);
    short[] used = scratch.allocate!short(vertexCount);
    clearUsed(used, idx);
    Meshlet meshlet;
    size_t meshletOffset = 0;
    for (size_t i = 0; i < idx.length; i += 3) {
        uint a = idx[i + 0], b = idx[i + 1], c = idx[i + 2];
        assert(a < vertexCount && b < vertexCount && c < vertexCount);
        meshletOffset += appendMeshlet(meshlet, a, b, c, used, meshlets, meshletVertices, meshletTriangles, meshletOffset, maxVertices, maxTriangles, false);
    }
    if (meshlet.triangleCount)
        meshlets[meshletOffset++] = meshlet;
    assert(meshletOffset <= bound);
    return meshletOffset;
}

/**
 * SAH meshlets for ray-tracing leaves.
 * The output bound uses `minTriangles`, same as `buildMeshletsFlex`.
 */
size_t buildMeshletsSpatial(I)(scope Meshlet[] meshlets, scope uint[] meshletVertices, scope ubyte[] meshletTriangles, scope const(I)[] indices, FloatStream positions, size_t maxVertices, size_t minTriangles, size_t maxTriangles, float fillWeight, ref MeshoptScratch scratch = defaultScratch()) nothrow @nogc
if (isIndex!I)
in (indices.length % 3 == 0)
in (positions.strideFloats >= 3 && positions.strideFloats <= 64)
in (maxVertices >= 3 && maxVertices <= kMeshletMaxVertices)
in (minTriangles >= 1 && minTriangles <= maxTriangles && maxTriangles <= kMeshletMaxTriangles)
in (fillWeight >= 0)
do {
    if (indices.length == 0)
        return 0;
    size_t bound = buildMeshletsBound(indices.length, maxVertices, minTriangles);

    immutable mark = scratch.mark();
    scope (exit)
        scratch.release(mark);
    uint[] idx = copyIndices(indices, scratch);
    size_t faceCount = idx.length / 3;
    size_t vertexCount = positions.count;

    float[] centroids = scratch.allocate!float(faceCount * 3);
    BVHBox[] boxes = scratch.allocate!BVHBox(faceCount);
    bvhPrepare(boxes, centroids, idx, positions);

    uint[] axes = scratch.allocate!uint(faceCount * 3);
    uint[] temp = scratch.allocate!uint(faceCount);
    foreach (k; 0 .. 3) {
        uint[] order = axes[k * faceCount .. (k + 1) * faceCount];
        radixSortFloat(order, temp, centroids[k * faceCount .. (k + 1) * faceCount]);
    }

    short[] used = scratch.allocate!short(vertexCount);
    clearUsed(used, idx);
    ubyte[] boundary = scratch.allocate!ubyte(faceCount);
    float[] areas = scratch.allocate!float(faceCount * 2);
    uint[] vertScratch = scratch.allocate!uint(faceCount);
    ubyte[] sides = scratch.allocate!ubyte(faceCount);
    bvhSplit(boxes, axes[0 .. faceCount], axes[faceCount .. faceCount * 2], axes[faceCount * 2 .. faceCount * 3], boundary, 0, areas, vertScratch, sides, temp, used, idx, maxVertices, minTriangles, maxTriangles, fillWeight);

    size_t meshletCount = 0;
    foreach (b; boundary) {
        assert(b <= 1);
        meshletCount += b;
    }

    Meshlet meshlet;
    size_t meshletOffset = 0;
    size_t meshletPending = meshletCount;
    foreach (i; 0 .. faceCount) {
        assert(boundary[i] <= 1);
        bool split = i > 0 && boundary[i] == 1;
        if (split && meshletCount > bound && meshletOffset + meshletPending >= bound)
            split = false;
        uint index = axes[i];
        assert(index < faceCount);
        uint a = idx[index * 3 + 0], b = idx[index * 3 + 1], c = idx[index * 3 + 2];
        meshletOffset += appendMeshlet(meshlet, a, b, c, used, meshlets, meshletVertices, meshletTriangles, meshletOffset, maxVertices, maxTriangles, split);
        meshletPending -= boundary[i];
    }
    if (meshlet.triangleCount)
        meshlets[meshletOffset++] = meshlet;
    assert(meshletOffset <= bound);
    return meshletOffset;
}

@("cluster.upstream") unittest {
    FloatStream none;
    none.strideFloats = 3;
    uint[0] emptyIdx;
    Bounds bounds0 = computeClusterBounds(emptyIdx[], none);
    assert(bounds0.center == [0, 0, 0] && bounds0.radius == 0);

    float[9] vbd = 0;
    FloatStream deg;
    deg.strideFloats = 3;
    deg.count = 3;
    deg.address = addrOf(vbd);
    uint[3] ibd = [0, 0, 0];
    uint[3] ib1 = [0, 1, 2];
    Bounds boundsd = computeClusterBounds(ibd[], deg);
    Bounds bounds1 = computeClusterBounds(ib1[], deg);
    assert(boundsd.radius == 0 && bounds1.radius == 0);

    float[9] vb1 = [1, 0, 0, 0, 1, 0, 0, 0, 1];
    FloatStream opp;
    opp.strideFloats = 3;
    opp.count = 3;
    opp.address = addrOf(vb1);
    uint[6] ib2 = [0, 1, 2, 0, 2, 1];
    Bounds bounds2 = computeClusterBounds(ib2[], opp);
    assert(bounds2.coneApex == [0, 0, 0]);
    assert(bounds2.coneAxis == [0, 0, 0]);
    assert(bounds2.coneCutoff == 1);
    assert(bounds2.coneAxisS8 == [0, 0, 0]);
    assert(bounds2.coneCutoffS8 == 127);
    assert(bounds2.center[0] - bounds2.radius <= 0 && bounds2.center[0] + bounds2.radius >= 1);
    assert(bounds2.center[1] - bounds2.radius <= 0 && bounds2.center[1] + bounds2.radius >= 1);
    assert(bounds2.center[2] - bounds2.radius <= 0 && bounds2.center[2] + bounds2.radius >= 1);

    float[16] vbr = [0, 0, 0, 0, 0, 1, 0, 1, 0, 0, 1, 2, 1, 0, 1, 3];
    FloatStream sph;
    sph.strideFloats = 4;
    sph.count = 4;
    sph.address = addrOf(vbr);
    Bounds bounds = computeSphereBounds(sph);
    assert(absDiff(bounds.center[0], 0.5f) < 1e-2f);
    assert(absDiff(bounds.center[1], 0.5f) < 1e-2f);
    assert(absDiff(bounds.center[2], 0.5f) < 1e-2f);
    assert(bounds.radius < 0.87f);
    Bounds boundsr = computeSphereBounds(sph, sph.address + 3 * 4, 4);
    assert(absDiff(boundsr.center[0], 1) < 1e-2f);
    assert(absDiff(boundsr.center[1], 0) < 1e-2f);
    assert(absDiff(boundsr.center[2], 1) < 1e-2f);
    assert(absDiff(boundsr.radius, 3) < 1e-2f);

    float[12] v4 = 0;
    FloatStream p4;
    p4.strideFloats = 3;
    p4.count = 4;
    p4.address = addrOf(v4);
    Meshlet[1] ml;
    uint[4] mv;
    ubyte[8] mt;
    assert(buildMeshlets(ml[], mv[], mt[], emptyIdx[], p4, 64, 64, 0) == 0);

    uint[6] dense = [0, 2, 1, 1, 2, 3];
    assert(buildMeshlets(ml[], mv[], mt[], dense[], p4, 64, 64, 0) == 1);
    assert(ml[0].triangleCount == 2 && ml[0].vertexCount == 4);
    assert(mv[mt[0]] == 0 && mv[mt[1]] == 2 && mv[mt[2]] == 1);
    assert(mv[mt[3]] == 1 && mv[mt[4]] == 2 && mv[mt[5]] == 3);

    float[48] v16 = 0;
    FloatStream p16;
    p16.strideFloats = 3;
    p16.count = 16;
    p16.address = addrOf(v16);
    uint[6] sparse = [0, 7, 15, 15, 7, 3];
    assert(buildMeshlets(ml[], mv[], mt[], sparse[], p16, 64, 64, 0) == 1);
    assert(ml[0].vertexCount == 4);
    assert(mv[mt[0]] == 0 && mv[mt[1]] == 7 && mv[mt[2]] == 15);

    ushort[6] sparse16 = [0, 7, 15, 15, 7, 3];
    assert(buildMeshlets(ml[], mv[], mt[], sparse16[], p16, 64, 64, 0) == 1);
    assert(mv[mt[0]] == 0 && mv[mt[2]] == 15);

    assert(buildMeshletsBound(24, 16, 4) == 2);
    float[24] tet = [
        0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1,
        10, 0, 0, 11, 0, 0, 10, 1, 0, 10, 0, 1,
    ];
    uint[24] teti = [
        0, 1, 2, 0, 2, 3, 0, 3, 1, 1, 3, 2,
        4, 5, 6, 4, 6, 7, 4, 7, 5, 5, 7, 6,
    ];
    FloatStream tp;
    tp.strideFloats = 3;
    tp.count = 8;
    tp.address = addrOf(tet);
    Meshlet[2] ml2;
    uint[32] mv2;
    ubyte[48] mt2;
    assert(buildMeshlets(ml2[], mv2[], mt2[], teti[], tp, 16, 8, 0) == 1);
    assert(ml2[0].triangleCount == 8 && ml2[0].vertexCount == 8);
    assert(buildMeshlets(ml2[], mv2[], mt2[], teti[], tp, 16, 4, 0) == 2);
    assert(buildMeshletsFlex(ml2[], mv2[], mt2[], teti[], tp, 16, 4, 8, 0, 0) == 1);
    assert(buildMeshletsFlex(ml2[], mv2[], mt2[], teti[], tp, 16, 4, 8, 0, 10) == 1);
    assert(buildMeshletsFlex(ml2[], mv2[], mt2[], teti[], tp, 16, 4, 8, 0, 1) == 2);
    assert(ml2[0].triangleCount == 4 && ml2[1].triangleCount == 4);

    assert(buildMeshletsSpatial(ml2[], mv2[], mt2[], teti[], tp, 16, 8, 8, 0) == 1);
    assert(buildMeshletsSpatial(ml2[], mv2[], mt2[], teti[], tp, 16, 4, 4, 0) == 2);
    assert(buildMeshletsSpatial(ml2[], mv2[], mt2[], teti[], tp, 4, 4, 8, 0) == 2);

    // 16x16 grid, one meshlet at the implementation limits.
    float[16 * 16 * 3] grid;
    uint[15 * 15 * 6] gridIdx;
    foreach (y; 0 .. 16) {
        foreach (x; 0 .. 16) {
            grid[(y * 16 + x) * 3 + 0] = cast(float) x;
            grid[(y * 16 + x) * 3 + 1] = cast(float) y;
            grid[(y * 16 + x) * 3 + 2] = 0;
        }
    }
    foreach (y; 0 .. 15) {
        foreach (x; 0 .. 15) {
            size_t t = (y * 15 + x) * 6;
            gridIdx[t + 0] = (y + 0) * 16 + (x + 0);
            gridIdx[t + 1] = (y + 0) * 16 + (x + 1);
            gridIdx[t + 2] = (y + 1) * 16 + (x + 0);
            gridIdx[t + 3] = (y + 1) * 16 + (x + 0);
            gridIdx[t + 4] = (y + 0) * 16 + (x + 1);
            gridIdx[t + 5] = (y + 1) * 16 + (x + 1);
        }
    }
    FloatStream gp;
    gp.strideFloats = 3;
    gp.count = 256;
    gp.address = addrOf(grid);
    Meshlet[1] mlg;
    uint[256] mvg;
    ubyte[15 * 15 * 6 + 3] mtg;
    size_t mc = buildMeshlets(mlg[], mvg[], mtg[], gridIdx[], gp, 256, 512, 0);
    assert(mc == 1);
    assert(mlg[0].triangleCount == 450 && mlg[0].vertexCount == 256);
    import engine.meshopt.meshlet : optimizeMeshlet;
    optimizeMeshlet(mvg[0 .. mlg[0].vertexCount], mtg[0 .. mlg[0].triangleCount * 3]);
    int vmax = -1;
    foreach (b; mtg[0 .. 450 * 3]) {
        assert(b <= vmax + 1);
        vmax = vmax < b ? b : vmax;
    }

    enum nDeep = 400;
    float[(nDeep + 1) * 3] deepPos;
    uint[nDeep * 3] deepIdx;
    deepPos[0] = deepPos[1] = deepPos[2] = 0;
    foreach (i; 0 .. nDeep) {
        float p = powF(1.2f, cast(float) i);
        deepPos[(i + 1) * 3 + 0] = p;
        deepPos[(i + 1) * 3 + 1] = p;
        deepPos[(i + 1) * 3 + 2] = p;
        deepIdx[i * 3 + 0] = 0;
        deepIdx[i * 3 + 1] = cast(uint)(i + 1);
        deepIdx[i * 3 + 2] = cast(uint)(i + 1);
    }
    FloatStream dp;
    dp.strideFloats = 3;
    dp.count = nDeep + 1;
    dp.address = addrOf(deepPos);
    size_t deepBound = buildMeshletsBound(nDeep * 3, 4, 4);
    Meshlet[] deepMl = new Meshlet[deepBound];
    uint[] deepMv = new uint[nDeep * 3];
    ubyte[] deepMt = new ubyte[nDeep * 3];
    assert(buildMeshletsSpatial(deepMl, deepMv, deepMt, deepIdx[], dp, 4, 4, 4, 0) == nDeep);

    // Reduced clusterfuzz: fixed seeds, degenerate topology, no crash.
    foreach (seed; 1 .. 17) {
        uint rng = seed * 0x9E3779B9;
        float[100 * 4] vb;
        foreach (i; 0 .. 100) {
            vb[i * 4 + 0] = cast(float)(xorshift(rng) % 10);
            vb[i * 4 + 1] = cast(float)(xorshift(rng) % 10);
            vb[i * 4 + 2] = cast(float)(xorshift(rng) % 10);
            vb[i * 4 + 3] = cast(float)(xorshift(rng) % 10);
        }
        uint[99] ib;
        foreach (i; 0 .. 99)
            ib[i] = xorshift(rng) % 100;
        size_t indices = 96;
        FloatStream fp;
        fp.strideFloats = 4;
        fp.count = 100;
        fp.address = addrOf(vb);
        size_t mb = buildMeshletsBound(indices, 4, 4);
        Meshlet[] fml = new Meshlet[mb];
        uint[] fmv = new uint[indices];
        ubyte[] fmt = new ubyte[indices];
        size_t got = buildMeshlets(fml, fmv, fmt, ib[0 .. indices], fp, 4, 4, 0);
        assert(got <= mb);
        buildMeshletsScan(fml, fmv, fmt, ib[0 .. indices], 100, 4, 4);
        buildMeshletsFlex(fml, fmv, fmt, ib[0 .. indices], fp, 16, 8, 32, 0, 2);
        buildMeshletsSpatial(fml, fmv, fmt, ib[0 .. indices], fp, 8, 4, 32, 0);
        import engine.meshopt.partition : partitionClusters;
        uint[] part = new uint[indices / 3];
        uint[] counts = new uint[indices / 3];
        counts[] = 3;
        partitionClusters(part, ib[0 .. indices], counts, fp, 12);
    }
}

private float absDiff(float a, float b) pure nothrow @nogc {
    float d = a - b;
    return d < 0 ? -d : d;
}

private ubyte[] bytesOf(uint[] data) @trusted {
    if (data.length == 0)
        return null;
    return (cast(ubyte*) data.ptr)[0 .. data.length * 4];
}

private ulong addrOf(T)(T[] data) nothrow @nogc @trusted {
    return data.length ? cast(ulong) data.ptr : 0;
}

private float powF(float x, float y) nothrow @nogc @trusted {
    import core.stdc.math : powf;
    alias F = float function(float, float) nothrow @nogc @trusted;
    return (cast(F) &powf)(x, y);
}

private uint xorshift(ref uint x) pure nothrow @nogc {
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    return x;
}

private void putU32(ref ubyte[] o, uint v) {
    o ~= cast(ubyte) v;
    o ~= cast(ubyte)(v >> 8);
    o ~= cast(ubyte)(v >> 16);
    o ~= cast(ubyte)(v >> 24);
}

private void putF32(ref ubyte[] o, float v) {
    import engine.meshopt.internal.bits : floatBits;
    putU32(o, floatBits(v));
}

private void putBoundsBytes(ref ubyte[] o, Bounds b) {
    foreach (x; b.center)
        putF32(o, x);
    putF32(o, b.radius);
    foreach (x; b.coneApex)
        putF32(o, x);
    foreach (x; b.coneAxis)
        putF32(o, x);
    putF32(o, b.coneCutoff);
    foreach (x; b.coneAxisS8)
        o ~= cast(ubyte) x;
    o ~= cast(ubyte) b.coneCutoffS8;
}

private void putRec(ref ubyte[] o, string key, const(ubyte)[] payload) {
    putU32(o, cast(uint) key.length);
    foreach (char c; key)
        o ~= cast(ubyte) c;
    putU32(o, cast(uint) payload.length);
    o ~= payload;
}

private FloatStream streamOf(const(float)[] pos, size_t strideFloats) @trusted {
    FloatStream fs;
    fs.strideFloats = strideFloats;
    fs.count = strideFloats ? pos.length / strideFloats : 0;
    if (fs.count)
        fs.address = cast(ulong) pos.ptr;
    return fs;
}

private void putMeshlets(ref ubyte[] payload, Meshlet[] meshlets, uint[] verts, ubyte[] tris, size_t count) {
    putU32(payload, cast(uint) count);
    foreach (i; 0 .. count) {
        putU32(payload, meshlets[i].vertexOffset);
        putU32(payload, meshlets[i].triangleOffset);
        putU32(payload, meshlets[i].vertexCount);
        putU32(payload, meshlets[i].triangleCount);
    }
    size_t usedV = 0;
    size_t usedT = 0;
    if (count) {
        Meshlet last = meshlets[count - 1];
        usedV = last.vertexOffset + last.vertexCount;
        usedT = last.triangleOffset + last.triangleCount * 3;
    }
    putU32(payload, cast(uint) usedV);
    foreach (v; verts[0 .. usedV])
        putU32(payload, v);
    putU32(payload, cast(uint) usedT);
    payload ~= tris[0 .. usedT];
}

/**
 * Canonical bytes for one mesh. The oracle driver emits the same layout
 * from the C++ reference. `strideFloats` is 3 or 4.
 */
ubyte[] m9GoldenPayload(string name, const(float)[] pos, const(uint)[] idx, size_t strideFloats) {
    import engine.meshopt.codec.meshlet : decodeMeshlet, decodeMeshletRaw, encodeMeshlet, encodeMeshletBound;
    import engine.meshopt.internal.bits : floatBits;
    import engine.meshopt.meshlet : extractMeshletIndices, optimizeMeshletLevel;
    import engine.meshopt.partition : partitionClusters;
    import engine.meshopt.spatial : spatialClusterPoints, spatialSortRemap, spatialSortTriangles;
    import std.format : format;

    ubyte[] o;
    FloatStream fs = streamOf(pos, strideFloats);
    string pfx = name ~ "/";

    void boundRec(size_t maxV, size_t maxT) {
        ubyte[] payload;
        putU32(payload, cast(uint) buildMeshletsBound(idx.length, maxV, maxT));
        putRec(o, format("%sbound/%s/%s", pfx, maxV, maxT), payload);
    }

    boundRec(64, 64);
    boundRec(256, 512);
    boundRec(3, 1);

    void buildRec(string kind, size_t count, Meshlet[] mls, uint[] mv, ubyte[] mt) {
        ubyte[] payload;
        putMeshlets(payload, mls, mv, mt, count);
        putRec(o, pfx ~ kind, payload);
    }

    void runBuild(size_t maxV, size_t maxT, float cone) {
        size_t b = buildMeshletsBound(idx.length, maxV, maxT);
        Meshlet[] mls = new Meshlet[b];
        uint[] mv = new uint[idx.length];
        ubyte[] mt = new ubyte[idx.length];
        size_t n = buildMeshlets(mls, mv, mt, idx, fs, maxV, maxT, cone);
        buildRec(format("meshlets/%s/%s/%08x", maxV, maxT, floatBits(cone)), n, mls, mv, mt);
    }

    void runScan(size_t maxV, size_t maxT) {
        size_t b = buildMeshletsBound(idx.length, maxV, maxT);
        Meshlet[] mls = new Meshlet[b];
        uint[] mv = new uint[idx.length];
        ubyte[] mt = new ubyte[idx.length];
        size_t n = buildMeshletsScan(mls, mv, mt, idx, fs.count, maxV, maxT);
        buildRec(format("scan/%s/%s", maxV, maxT), n, mls, mv, mt);
    }

    void runFlex(size_t maxV, size_t minT, size_t maxT, float cone, float split) {
        size_t b = buildMeshletsBound(idx.length, maxV, minT);
        Meshlet[] mls = new Meshlet[b];
        uint[] mv = new uint[idx.length];
        ubyte[] mt = new ubyte[idx.length];
        size_t n = buildMeshletsFlex(mls, mv, mt, idx, fs, maxV, minT, maxT, cone, split);
        buildRec(format("flex/%s/%s/%s/%08x/%08x", maxV, minT, maxT, floatBits(cone), floatBits(split)), n, mls, mv, mt);
    }

    void runSpatial(size_t maxV, size_t minT, size_t maxT, float fill) {
        size_t b = buildMeshletsBound(idx.length, maxV, minT);
        Meshlet[] mls = new Meshlet[b];
        uint[] mv = new uint[idx.length];
        ubyte[] mt = new ubyte[idx.length];
        size_t n = buildMeshletsSpatial(mls, mv, mt, idx, fs, maxV, minT, maxT, fill);
        buildRec(format("spatial/%s/%s/%s/%08x", maxV, minT, maxT, floatBits(fill)), n, mls, mv, mt);
    }

    if (idx.length == 0) {
        runScan(64, 64);
    } else {
        runBuild(64, 64, 0);
        runBuild(32, 96, 0.5f);
        runScan(64, 64);
        runScan(16, 32);
        runFlex(64, 16, 64, 0, 0);
        runFlex(48, 8, 64, 0.25f, 1.5f);
        runSpatial(64, 16, 64, 0);
        runSpatial(32, 8, 32, 0.5f);
    }

    if (idx.length / 3 <= 512) {
        ubyte[] payload;
        putBoundsBytes(payload, computeClusterBounds(idx, fs));
        putRec(o, pfx ~ "clusterBounds", payload);
    }
    {
        ubyte[] payload;
        putBoundsBytes(payload, computeSphereBounds(fs));
        putRec(o, pfx ~ "sphere", payload);
        float[] radii = new float[fs.count];
        radii[] = 0.25f;
        ulong rad = 0;
        if (radii.length)
            rad = addrOf(radii);
        ubyte[] payloadR;
        putBoundsBytes(payloadR, computeSphereBounds(fs, rad, 1));
        putRec(o, pfx ~ "sphereR", payloadR);
    }

    if (idx.length) {
        size_t b = buildMeshletsBound(idx.length, 64, 64);
        Meshlet[] mls = new Meshlet[b];
        uint[] mv = new uint[idx.length];
        ubyte[] mt = new ubyte[idx.length];
        size_t n = buildMeshlets(mls, mv, mt, idx, fs, 64, 64, 0);
        foreach (i; 0 .. n) {
            Meshlet m = mls[i];
            ubyte[] payload;
            putBoundsBytes(payload, computeMeshletBounds(mv[m.vertexOffset .. m.vertexOffset + m.vertexCount], mt[m.triangleOffset .. m.triangleOffset + m.triangleCount * 3], fs));
            putRec(o, format("%smeshletBounds/%s", pfx, i), payload);

            uint[] ov = mv[m.vertexOffset .. m.vertexOffset + m.vertexCount].dup;
            ubyte[] ot = mt[m.triangleOffset .. m.triangleOffset + m.triangleCount * 3].dup;
            optimizeMeshletLevel(ov, ot, 0);
            ubyte[] payload0;
            foreach (v; ov)
                putU32(payload0, v);
            payload0 ~= ot;
            putRec(o, format("%sopt/0/%s", pfx, i), payload0);

            uint[] ov3 = mv[m.vertexOffset .. m.vertexOffset + m.vertexCount].dup;
            ubyte[] ot3 = mt[m.triangleOffset .. m.triangleOffset + m.triangleCount * 3].dup;
            optimizeMeshletLevel(ov3, ot3, 3);
            ubyte[] payload3;
            foreach (v; ov3)
                putU32(payload3, v);
            payload3 ~= ot3;
            putRec(o, format("%sopt/3/%s", pfx, i), payload3);

            uint[] expanded = new uint[m.triangleCount * 3];
            foreach (t; 0 .. m.triangleCount * 3)
                expanded[t] = mv[m.vertexOffset + mt[m.triangleOffset + t]];
            uint[] ev = new uint[256];
            ubyte[] et = new ubyte[expanded.length];
            size_t unique = extractMeshletIndices(ev, et, expanded);
            ubyte[] payloadE;
            putU32(payloadE, cast(uint) unique);
            foreach (v; ev[0 .. unique])
                putU32(payloadE, v);
            payloadE ~= et[0 .. expanded.length];
            putRec(o, format("%sextract/%s", pfx, i), payloadE);

            if (m.vertexCount <= 256 && m.triangleCount <= 256) {
                ubyte[] enc = new ubyte[encodeMeshletBound(m.vertexCount, m.triangleCount)];
                // Local indices are the meshlet triangle bytes; vertices are global ids.
                size_t esz = encodeMeshlet(enc, mv[m.vertexOffset .. m.vertexOffset + m.vertexCount], mt[m.triangleOffset .. m.triangleOffset + m.triangleCount * 3]);
                ubyte[] payloadN;
                putU32(payloadN, cast(uint) esz);
                payloadN ~= enc[0 .. esz];
                uint[] dv = new uint[m.vertexCount];
                ubyte[] dt = new ubyte[m.triangleCount * 3];
                int rc = decodeMeshlet(bytesOf(dv), m.vertexCount, 4, dt, m.triangleCount, 3, enc[0 .. esz]);
                putU32(payloadN, cast(uint) rc);
                foreach (v; dv)
                    putU32(payloadN, v);
                payloadN ~= dt;
                uint[] rawT = new uint[m.triangleCount];
                int rcr = decodeMeshletRaw(dv, m.vertexCount, rawT, m.triangleCount, enc[0 .. esz]);
                putU32(payloadN, cast(uint) rcr);
                foreach (v; rawT)
                    putU32(payloadN, v);
                putRec(o, format("%sencode/%s", pfx, i), payloadN);
            }
        }

        size_t faces = idx.length / 3;
        uint[] counts = new uint[faces];
        counts[] = 3;
        uint[] part = new uint[faces];
        FloatStream noPos;
        noPos.count = fs.count;
        size_t np = partitionClusters(part, idx, counts, noPos, 4);
        ubyte[] payloadP;
        putU32(payloadP, cast(uint) np);
        foreach (v; part)
            putU32(payloadP, v);
        putRec(o, pfx ~ "partition/4/0", payloadP);

        part[] = 0;
        size_t wp = partitionClusters(part, idx, counts, fs, 4);
        ubyte[] payloadW;
        putU32(payloadW, cast(uint) wp);
        foreach (v; part)
            putU32(payloadW, v);
        putRec(o, pfx ~ "partition/4/1", payloadW);
    }

    {
        uint[] remap = new uint[fs.count];
        spatialSortRemap(remap, fs);
        ubyte[] payload;
        foreach (v; remap)
            putU32(payload, v);
        putRec(o, pfx ~ "remap", payload);
    }
    {
        uint[] tris = new uint[idx.length];
        spatialSortTriangles(tris, idx, fs);
        ubyte[] payload;
        foreach (v; tris)
            putU32(payload, v);
        putRec(o, pfx ~ "sortTri", payload);
    }
    foreach (clusterSize; [8, 32]) {
        if (clusterSize == 0)
            continue;
        uint[] dest = new uint[fs.count];
        spatialClusterPoints(dest, fs, clusterSize);
        ubyte[] payload;
        foreach (v; dest)
            putU32(payload, v);
        putRec(o, format("%spoints/%s", pfx, clusterSize), payload);
    }
    return o;
}

struct M9Mesh {
    string name;
    float[] pos;
    uint[] idx;
    size_t strideFloats;
}

/// Corpus used by the M9 golden file.
M9Mesh[] m9Corpus() {
    import engine.meshopt.corpus : ProcMesh, makeGrid, makeSeam, makeSoup, makeSphere, makeTorus;
    import std.conv : to;
    import std.file : readText;
    import std.string : split, splitLines, strip;

    M9Mesh[] meshes;
    void one(string meshName, ProcMesh m) {
        meshes ~= M9Mesh(meshName, m.positions, m.indices, 3);
    }

    one("grid2x3", makeGrid(2, 3));
    one("sphere8x4", makeSphere(8, 4));
    one("torus8x4", makeTorus(8, 4, 2, 0.4f));
    one("seam", makeSeam());
    one("soup", makeSoup());
    one("grid16", makeGrid(16, 16));

    float[] stridePos = [
        0, 0, 0, 9,
        1, 0, 0, 9,
        0, 1, 0, 9,
        1, 1, 1, 9,
    ];
    uint[] strideIdx = [0, 1, 2, 1, 2, 3];
    meshes ~= M9Mesh("stride4", stridePos, strideIdx, 4);

    float[] negPos = [0, 0, 0, 0, -0.0f, 0, 1, 0, 0];
    uint[] negIdx = [0, 1, 2];
    meshes ~= M9Mesh("negzero", negPos, negIdx, 3);

    float[] piratePos;
    uint[] pirateIdx;
    foreach (raw; readText("assets/models/meshopt/pirate.obj").splitLines) {
        string line = raw.strip;
        if (line.length < 3 || line[0] == '#')
            continue;
        if (line.length >= 2 && line[0] == 'v' && line[1] == ' ') {
            auto parts = line.split;
            piratePos ~= to!float(parts[1]);
            piratePos ~= to!float(parts[2]);
            piratePos ~= to!float(parts[3]);
        } else if (line.length >= 2 && line[0] == 'f' && line[1] == ' ') {
            auto parts = line.split;
            uint[] face;
            foreach (k; 1 .. parts.length) {
                auto slash = parts[k].split("/");
                int id = to!int(slash[0]);
                size_t nverts = piratePos.length / 3;
                uint u = id < 0 ? cast(uint)(nverts + id) : cast(uint)(id - 1);
                face ~= u;
            }
            if (face.length >= 3) {
                foreach (k; 1 .. face.length - 1) {
                    pirateIdx ~= face[0];
                    pirateIdx ~= face[k];
                    pirateIdx ~= face[k + 1];
                }
            }
        }
    }
    meshes ~= M9Mesh("pirate", piratePos, pirateIdx, 3);
    return meshes;
}

@("m9.golden") @trusted unittest {
    import engine.meshopt.quantize : goldenParamsHash;
    import std.file : read;

    ubyte[] file = cast(ubyte[]) read("tests/meshopt/golden/m9/corpus.bin");
    assert(file.length >= 48, "m9 golden too small");
    assert(file[0 .. 8] == cast(const(ubyte)[]) "MOPTGLD1");
    assert((file[8] | (cast(uint) file[9] << 8) | (cast(uint) file[10] << 16) | (cast(uint) file[11] << 24)) == 1030);
    char[32] expect;
    expect[] = 0;
    expect[0 .. 8] = "m9corpus";
    assert(cast(const(char)[]) file[12 .. 44] == expect[]);
    uint hash = file[44] | (cast(uint) file[45] << 8) | (cast(uint) file[46] << 16) | (cast(uint) file[47] << 24);
    assert(hash == goldenParamsHash("m9corpus"));
    ubyte[] got;
    foreach (mesh; m9Corpus())
        got ~= m9GoldenPayload(mesh.name, mesh.pos, mesh.idx, mesh.strideFloats);
    assert(got == file[48 .. $], "m9 golden mismatch");
}
