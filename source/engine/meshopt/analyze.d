// Ported from meshoptimizer v1.3 (src/indexanalyzer.cpp, src/rasterizer.cpp), Copyright (c) 2016-2026 Arseny Kapoulkine, MIT License.
/// Vertex-cache, vertex-fetch, overdraw, and coverage statistics.
module engine.meshopt.analyze;

import engine.core.pod : isPod;
import engine.meshopt.scratch : MeshoptScratch, defaultScratch;
import engine.meshopt.types : CoverageStatistics, FloatStream, OverdrawStatistics, VertexCacheStatistics, VertexFetchStatistics;

@safe:

private enum bool isIndex(I) = is(I == uint) || is(I == ushort);
private enum viewport = 256;

private struct OverdrawBuffer {
    float[2][viewport][viewport] z;
    uint[2][viewport][viewport] overdraw;
}

static assert(isPod!OverdrawBuffer);

/// FIFO cache simulation. `cacheSize >= 3`. `warpSize == 0` disables warp flushes.
VertexCacheStatistics analyzeVertexCache(I)(scope const(I)[] indices, size_t vertexCount, uint cacheSize = 16, uint warpSize = 0, uint primGroupSize = 0, ref MeshoptScratch scratch = defaultScratch())
if (isIndex!I) {
    assert(indices.length % 3 == 0);
    assert(cacheSize >= 3);
    assert(warpSize == 0 || warpSize >= 3);
    immutable mark = scratch.mark();
    scope (exit)
        scratch.release(mark);
    VertexCacheStatistics result;
    uint warpOffset = 0;
    uint primGroupOffset = 0;
    uint[] timestamps = scratch.allocate!uint(vertexCount);
    timestamps[] = 0;
    uint timestamp = cacheSize + 1;
    for (size_t i = 0; i < indices.length; i += 3) {
        uint a = indices[i + 0], b = indices[i + 1], c = indices[i + 2];
        assert(a < vertexCount && b < vertexCount && c < vertexCount);
        uint ac = (timestamp - timestamps[a]) > cacheSize ? 1 : 0;
        uint bc = (timestamp - timestamps[b]) > cacheSize ? 1 : 0;
        uint cc = (timestamp - timestamps[c]) > cacheSize ? 1 : 0;
        if ((primGroupSize && primGroupOffset == primGroupSize) || (warpSize && warpOffset + ac + bc + cc > warpSize)) {
            result.warpsExecuted += warpOffset > 0 ? 1 : 0;
            warpOffset = 0;
            primGroupOffset = 0;
            timestamp += cacheSize + 1;
        }
        foreach (j; 0 .. 3) {
            uint index = indices[i + j];
            if (timestamp - timestamps[index] > cacheSize) {
                timestamps[index] = timestamp++;
                result.verticesTransformed++;
                warpOffset++;
            }
        }
        primGroupOffset++;
    }
    size_t unique = 0;
    foreach (t; timestamps)
        unique += t > 0 ? 1 : 0;
    result.warpsExecuted += warpOffset > 0 ? 1 : 0;
    result.acmr = indices.length == 0 ? 0 : cast(float) result.verticesTransformed / cast(float)(indices.length / 3);
    result.atvr = unique == 0 ? 0 : cast(float) result.verticesTransformed / cast(float) unique;
    return result;
}

/// Direct-mapped 128 KiB cache model. `vertexSize` is 1..256.
VertexFetchStatistics analyzeVertexFetch(I)(scope const(I)[] indices, size_t vertexCount, size_t vertexSize, ref MeshoptScratch scratch = defaultScratch())
if (isIndex!I) {
    assert(vertexSize > 0 && vertexSize <= 256);
    immutable mark = scratch.mark();
    scope (exit)
        scratch.release(mark);
    VertexFetchStatistics result;
    ubyte[] visited = scratch.allocate!ubyte(vertexCount);
    visited[] = 0;
    enum cacheLine = 64;
    enum cacheBytes = 128 * 1024;
    size_t[cacheBytes / cacheLine] cache;
    cache[] = 0;
    foreach (index; indices) {
        uint id = index;
        assert(id < vertexCount);
        visited[id] = 1;
        size_t startAddress = id * vertexSize;
        size_t endAddress = startAddress + vertexSize;
        size_t startTag = startAddress / cacheLine;
        size_t endTag = (endAddress + cacheLine - 1) / cacheLine;
        assert(startTag < endTag);
        foreach (tag; startTag .. endTag) {
            size_t line = tag % cache.length;
            result.bytesFetched += cache[line] != tag + 1 ? cacheLine : 0;
            cache[line] = tag + 1;
        }
    }
    size_t unique = 0;
    foreach (v; visited)
        unique += v ? 1 : 0;
    result.overfetch = unique == 0 ? 0 : cast(float) result.bytesFetched / cast(float)(unique * vertexSize);
    return result;
}

/// Software-rasterized overdraw over the three orthographic axes.
OverdrawStatistics analyzeOverdraw(I)(scope const(I)[] indices, FloatStream positions, ref MeshoptScratch scratch = defaultScratch())
if (isIndex!I) {
    assert(indices.length % 3 == 0);
    checkStride(positions.strideFloats);
    immutable mark = scratch.mark();
    scope (exit)
        scratch.release(mark);
    OverdrawStatistics result;
    float[] triangles = scratch.allocate!float(indices.length * 3);
    transformTriangles(triangles, indices, positions);
    OverdrawBuffer[] buffer = scratch.allocate!OverdrawBuffer(1);
    foreach (axis; 0 .. 3) {
        zeroBuffer(buffer);
        rasterizeTriangles(buffer[0], triangles, indices.length, axis);
        foreach (y; 0 .. viewport)
            foreach (x; 0 .. viewport)
                foreach (s; 0 .. 2) {
                    uint over = buffer[0].overdraw[y][x][s];
                    result.pixelsCovered += over > 0 ? 1 : 0;
                    result.pixelsShaded += over;
                }
    }
    result.overdraw = result.pixelsCovered ? cast(float) result.pixelsShaded / cast(float) result.pixelsCovered : 0;
    return result;
}

/// Fraction of the 256² viewport covered on each axis, plus the mesh extent.
CoverageStatistics analyzeCoverage(I)(scope const(I)[] indices, FloatStream positions, ref MeshoptScratch scratch = defaultScratch())
if (isIndex!I) {
    assert(indices.length % 3 == 0);
    checkStride(positions.strideFloats);
    immutable mark = scratch.mark();
    scope (exit)
        scratch.release(mark);
    CoverageStatistics result;
    float[] triangles = scratch.allocate!float(indices.length * 3);
    result.extent = transformTriangles(triangles, indices, positions);
    OverdrawBuffer[] buffer = scratch.allocate!OverdrawBuffer(1);
    foreach (axis; 0 .. 3) {
        zeroBuffer(buffer);
        rasterizeTriangles(buffer[0], triangles, indices.length, axis);
        uint covered = 0;
        foreach (y; 0 .. viewport)
            foreach (x; 0 .. viewport)
                covered += (buffer[0].overdraw[y][x][0] | buffer[0].overdraw[y][x][1]) > 0 ? 1 : 0;
        result.coverage[axis] = cast(float) covered / cast(float)(viewport * viewport);
    }
    return result;
}

private void checkStride(size_t strideFloats) {
    size_t stride = strideFloats * 4;
    assert(stride >= 12 && stride <= 256);
}

private float loadFloat(ulong address, size_t floatIndex) nothrow @nogc @trusted {
    import engine.meshopt.internal.bits : bitsFloat;
    ubyte* p = cast(ubyte*)(address + floatIndex * 4);
    uint u = p[0] | (cast(uint) p[1] << 8) | (cast(uint) p[2] << 16) | (cast(uint) p[3] << 24);
    return bitsFloat(u);
}

private void zeroBuffer(OverdrawBuffer[] buffer) nothrow @nogc @trusted {
    import core.stdc.string : memset;
    memset(buffer.ptr, 0, OverdrawBuffer.sizeof);
}

private float transformTriangles(float[] triangles, scope const(uint)[] indices, FloatStream positions) {
    size_t stride = positions.strideFloats;
    float[3] minv = [float.max, float.max, float.max];
    float[3] maxv = [-float.max, -float.max, -float.max];
    foreach (i; 0 .. positions.count) {
        foreach (j; 0 .. 3) {
            float vj = loadFloat(positions.address, i * stride + j);
            minv[j] = minv[j] > vj ? vj : minv[j];
            maxv[j] = maxv[j] < vj ? vj : maxv[j];
        }
    }
    float extent = 0;
    extent = (maxv[0] - minv[0]) < extent ? extent : (maxv[0] - minv[0]);
    extent = (maxv[1] - minv[1]) < extent ? extent : (maxv[1] - minv[1]);
    extent = (maxv[2] - minv[2]) < extent ? extent : (maxv[2] - minv[2]);
    float scale = extent == 0 ? 0 : viewport / extent;
    foreach (i, index; indices) {
        assert(index < positions.count);
        triangles[i * 3 + 0] = (loadFloat(positions.address, index * stride + 0) - minv[0]) * scale;
        triangles[i * 3 + 1] = (loadFloat(positions.address, index * stride + 1) - minv[1]) * scale;
        triangles[i * 3 + 2] = (loadFloat(positions.address, index * stride + 2) - minv[2]) * scale;
    }
    return extent;
}

private float depthGradients(ref float dzdx, ref float dzdy, float x1, float y1, float z1, float x2, float y2, float z2, float x3, float y3, float z3) {
    float det = (x2 - x1) * (y3 - y1) - (y2 - y1) * (x3 - x1);
    float invdet = det == 0 ? 0 : 1 / det;
    dzdx = ((z2 - z1) * (y3 - y1) - (y2 - y1) * (z3 - z1)) * invdet;
    dzdy = ((x2 - x1) * (z3 - z1) - (z2 - z1) * (x3 - x1)) * invdet;
    return det;
}

private void rasterize(ref OverdrawBuffer buffer, float v1x, float v1y, float v1z, float v2x, float v2y, float v2z, float v3x, float v3y, float v3z) {
    float dzx, dzy;
    float det = depthGradients(dzx, dzy, v1x, v1y, v1z, v2x, v2y, v2z, v3x, v3y, v3z);
    int sign = det > 0 ? 1 : 0;
    if (sign) {
        float t = v2x;
        v2x = v3x;
        v3x = t;
        t = v2y;
        v2y = v3y;
        v3y = t;
        v1z = viewport - v1z;
        dzx = -dzx;
        dzy = -dzy;
    }
    int x1 = cast(int)(16.0f * v1x + 0.5f);
    int x2 = cast(int)(16.0f * v2x + 0.5f);
    int x3 = cast(int)(16.0f * v3x + 0.5f);
    int y1 = cast(int)(16.0f * v1y + 0.5f);
    int y2 = cast(int)(16.0f * v2y + 0.5f);
    int y3 = cast(int)(16.0f * v3y + 0.5f);

    int minx = x1 < x2 ? x1 : x2;
    minx = minx < x3 ? minx : x3;
    minx = (minx + 7) >> 4;
    minx = minx < 0 ? 0 : minx;
    int miny = y1 < y2 ? y1 : y2;
    miny = miny < y3 ? miny : y3;
    miny = (miny + 7) >> 4;
    miny = miny < 0 ? 0 : miny;
    int maxx = x1 > x2 ? x1 : x2;
    maxx = maxx > x3 ? maxx : x3;
    maxx = (maxx + 7) >> 4;
    maxx = maxx > viewport ? viewport : maxx;
    int maxy = y1 > y2 ? y1 : y2;
    maxy = maxy > y3 ? maxy : y3;
    maxy = (maxy + 7) >> 4;
    maxy = maxy > viewport ? viewport : maxy;

    int dx12 = x1 - x2, dx23 = x2 - x3, dx31 = x3 - x1;
    int dy12 = y1 - y2, dy23 = y2 - y3, dy31 = y3 - y1;
    int tl1 = dy12 < 0 || (dy12 == 0 && dx12 > 0) ? 1 : 0;
    int tl2 = dy23 < 0 || (dy23 == 0 && dx23 > 0) ? 1 : 0;
    int tl3 = dy31 < 0 || (dy31 == 0 && dx31 > 0) ? 1 : 0;
    int fx = (minx << 4) + 8;
    int fy = (miny << 4) + 8;
    int cy1 = dx12 * (fy - y1) - dy12 * (fx - x1) + tl1 - 1;
    int cy2 = dx23 * (fy - y2) - dy23 * (fx - x2) + tl2 - 1;
    int cy3 = dx31 * (fy - y3) - dy31 * (fx - x3) + tl3 - 1;
    float zy = v1z + (dzx * cast(float)(fx - x1) + dzy * cast(float)(fy - y1)) * (1 / 16.0f);

    foreach (y; miny .. maxy) {
        int cx1 = cy1, cx2 = cy2, cx3 = cy3;
        float zx = zy;
        foreach (x; minx .. maxx) {
            if ((cx1 | cx2 | cx3) >= 0) {
                if (zx >= buffer.z[y][x][sign]) {
                    buffer.z[y][x][sign] = zx;
                    buffer.overdraw[y][x][sign]++;
                }
            }
            cx1 -= cast(int)(cast(uint) dy12 << 4);
            cx2 -= cast(int)(cast(uint) dy23 << 4);
            cx3 -= cast(int)(cast(uint) dy31 << 4);
            zx += dzx;
        }
        cy1 += cast(int)(cast(uint) dx12 << 4);
        cy2 += cast(int)(cast(uint) dx23 << 4);
        cy3 += cast(int)(cast(uint) dx31 << 4);
        zy += dzy;
    }
}

private void rasterizeTriangles(ref OverdrawBuffer buffer, const(float)[] triangles, size_t indexCount, int axis) {
    for (size_t i = 0; i < indexCount; i += 3) {
        const(float)[] vn0 = triangles[3 * (i + 0) .. 3 * (i + 0) + 3];
        const(float)[] vn1 = triangles[3 * (i + 1) .. 3 * (i + 1) + 3];
        const(float)[] vn2 = triangles[3 * (i + 2) .. 3 * (i + 2) + 3];
        if (axis == 0)
            rasterize(buffer, vn0[2], vn0[1], vn0[0], vn1[2], vn1[1], vn1[0], vn2[2], vn2[1], vn2[0]);
        else if (axis == 1)
            rasterize(buffer, vn0[0], vn0[2], vn0[1], vn1[0], vn1[2], vn1[1], vn2[0], vn2[2], vn2[1]);
        else
            rasterize(buffer, vn0[1], vn0[0], vn0[2], vn1[1], vn1[0], vn1[2], vn2[1], vn2[0], vn2[2]);
    }
}

@("analyzeVertexCache.triangle") unittest {
    uint[3] ib = [0, 1, 2];
    VertexCacheStatistics s = analyzeVertexCache(ib[], 3);
    assert(s.verticesTransformed == 3);
    assert(s.acmr == 3);
    assert(s.atvr == 1);
    VertexFetchStatistics f = analyzeVertexFetch(ib[], 3, 12);
    assert(f.bytesFetched == 64);
}
