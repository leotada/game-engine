// Ported from meshoptimizer v1.3 (src/simplifier.cpp), Copyright (c) 2016-2026 Arseny Kapoulkine, MIT License.
/// Grid clustering used by `simplifySloppy` and `simplifyPoints`.
module engine.meshopt.simplify.sloppy;

import engine.meshopt.internal.hash : hashBuckets, hashLookup;
import engine.meshopt.internal.vec : Vec3;
import engine.meshopt.scratch : MeshoptScratch;
import engine.meshopt.simplify.quadric : Quadric, Reservoir, quadricAdd, quadricError, quadricFromTriangle, sqrtF;
import engine.meshopt.simplify.topology : asU32;
import engine.meshopt.types : SimplifyVertexFlags;

@safe:

package float interpolate(float y, float x0, float y0, float x1, float y1, float x2, float y2) nothrow @nogc {
    float num = (y1 - y) * (x1 - x2) * (x1 - x0) * (y2 - y0);
    float den = (y2 - y) * (x1 - x2) * (y0 - y1) + (y0 - y) * (x1 - x0) * (y1 - y2);
    return x1 + (den == 0.0f ? 0.0f : num / den);
}

package void computeVertexIds(uint[] vertexIds, const(Vec3)[] positions, scope const(ubyte)[] vertexLock, int gridSize) nothrow @nogc {
    assert(gridSize >= 1 && gridSize <= 1024);
    float cellScale = cast(float)(gridSize - 1);
    foreach (i; 0 .. positions.length) {
        Vec3 v = positions[i];
        int xi = cast(int)(v.x * cellScale + 0.5f);
        int yi = cast(int)(v.y * cellScale + 0.5f);
        int zi = cast(int)(v.z * cellScale + 0.5f);
        if (vertexLock.length && (vertexLock[i] & SimplifyVertexFlags.lock) != 0)
            vertexIds[i] = (1u << 30) | asU32(i);
        else
            vertexIds[i] = (cast(uint) xi << 20) | (cast(uint) yi << 10) | cast(uint) zi;
    }
}

package size_t countTriangles(const(uint)[] vertexIds, scope const(uint)[] indices, size_t indexCount) nothrow @nogc {
    size_t result = 0;
    for (size_t i = 0; i < indexCount; i += 3) {
        uint id0 = vertexIds[indices[i + 0]];
        uint id1 = vertexIds[indices[i + 1]];
        uint id2 = vertexIds[indices[i + 2]];
        if (id0 != id1 && id0 != id2 && id1 != id2)
            result++;
    }
    return result;
}

private struct CellHasher {
    const(uint)[] ids;
    bool direct;

    size_t hash(uint i) const scope nothrow @nogc {
        uint h = direct ? i : ids[i];
        h ^= h >> 13;
        h *= 0x5bd1_e995u;
        h ^= h >> 15;
        return h;
    }

    bool equal(uint lhs, uint rhs) const scope nothrow @nogc {
        if (direct)
            return lhs == rhs;
        return ids[lhs] == ids[rhs];
    }
}

package size_t fillVertexCells(uint[] table, uint[] vertexCells, const(uint)[] vertexIds) nothrow @nogc {
    CellHasher hasher;
    hasher.ids = vertexIds;
    table[] = uint.max;
    size_t result = 0;
    foreach (i; 0 .. vertexIds.length) {
        size_t slot = hashLookup(table, hasher, asU32(i), uint.max);
        if (table[slot] == uint.max) {
            table[slot] = asU32(i);
            vertexCells[i] = asU32(result);
            result++;
        } else {
            vertexCells[i] = vertexCells[table[slot]];
        }
    }
    return result;
}

package size_t countVertexCells(uint[] table, const(uint)[] vertexIds) nothrow @nogc {
    CellHasher hasher;
    hasher.direct = true;
    table[] = uint.max;
    size_t result = 0;
    foreach (i; 0 .. vertexIds.length) {
        uint id = vertexIds[i];
        size_t slot = hashLookup(table, hasher, id, uint.max);
        if (table[slot] == uint.max)
            result++;
        table[slot] = id;
    }
    return result;
}

package void fillCellQuadrics(Quadric[] cellQuadrics, scope const(uint)[] indices, size_t indexCount, const(Vec3)[] positions, const(uint)[] vertexCells) nothrow @nogc {
    for (size_t i = 0; i < indexCount; i += 3) {
        uint i0 = indices[i + 0];
        uint i1 = indices[i + 1];
        uint i2 = indices[i + 2];
        uint c0 = vertexCells[i0];
        uint c1 = vertexCells[i1];
        uint c2 = vertexCells[i2];
        bool single = c0 == c1 && c0 == c2;
        Quadric q;
        quadricFromTriangle(q, positions[i0], positions[i1], positions[i2], single ? 3.0f : 1.0f);
        if (single) {
            quadricAdd(cellQuadrics[c0], q);
        } else {
            quadricAdd(cellQuadrics[c0], q);
            quadricAdd(cellQuadrics[c1], q);
            quadricAdd(cellQuadrics[c2], q);
        }
    }
}

package void fillCellReservoirs(Reservoir[] cellReservoirs, const(Vec3)[] positions, ulong colorAddress, size_t colorStride, bool hasColor, const(uint)[] vertexCells) nothrow @nogc {
    import engine.meshopt.simplify.topology : loadF;
    foreach (i; 0 .. positions.length) {
        uint cell = vertexCells[i];
        Vec3 v = positions[i];
        float cr = 0, cg = 0, cb = 0;
        if (hasColor) {
            cr = loadF(colorAddress, i * colorStride + 0);
            cg = loadF(colorAddress, i * colorStride + 1);
            cb = loadF(colorAddress, i * colorStride + 2);
        }
        cellReservoirs[cell].x += v.x;
        cellReservoirs[cell].y += v.y;
        cellReservoirs[cell].z += v.z;
        cellReservoirs[cell].r += cr;
        cellReservoirs[cell].g += cg;
        cellReservoirs[cell].b += cb;
        cellReservoirs[cell].w += 1.0f;
    }
    foreach (ref Reservoir r; cellReservoirs) {
        float iw = r.w == 0.0f ? 0.0f : 1.0f / r.w;
        r.x *= iw;
        r.y *= iw;
        r.z *= iw;
        r.r *= iw;
        r.g *= iw;
        r.b *= iw;
    }
}

package void fillCellRemapQuadric(uint[] cellRemap, float[] cellErrors, const(uint)[] vertexCells, const(Quadric)[] cellQuadrics, const(Vec3)[] positions) nothrow @nogc {
    cellRemap[] = uint.max;
    foreach (i; 0 .. positions.length) {
        uint cell = vertexCells[i];
        float error = quadricError(cellQuadrics[cell], positions[i]);
        if (cellRemap[cell] == uint.max || cellErrors[cell] > error) {
            cellRemap[cell] = asU32(i);
            cellErrors[cell] = error;
        }
    }
}

package void fillCellRemapPoints(uint[] cellRemap, float[] cellErrors, const(uint)[] vertexCells, const(Reservoir)[] cellReservoirs, const(Vec3)[] positions, ulong colorAddress, size_t colorStride, bool hasColor, float colorWeight) nothrow @nogc {
    import engine.meshopt.simplify.topology : loadF;
    cellRemap[] = uint.max;
    foreach (i; 0 .. positions.length) {
        uint cell = vertexCells[i];
        Vec3 v = positions[i];
        Reservoir r = cellReservoirs[cell];
        float cr = 0, cg = 0, cb = 0;
        if (hasColor) {
            cr = loadF(colorAddress, i * colorStride + 0);
            cg = loadF(colorAddress, i * colorStride + 1);
            cb = loadF(colorAddress, i * colorStride + 2);
        }
        float posError = (v.x - r.x) * (v.x - r.x) + (v.y - r.y) * (v.y - r.y) + (v.z - r.z) * (v.z - r.z);
        float colError = (cr - r.r) * (cr - r.r) + (cg - r.g) * (cg - r.g) + (cb - r.b) * (cb - r.b);
        float error = posError + colorWeight * colError;
        if (cellRemap[cell] == uint.max || cellErrors[cell] > error) {
            cellRemap[cell] = asU32(i);
            cellErrors[cell] = error;
        }
    }
}

private uint loadIndex(ulong address, size_t i) nothrow @nogc @trusted {
    return (cast(uint*) address)[i];
}

private struct TriangleHasher {
    ulong address;

    size_t hash(uint i) const scope nothrow @nogc {
        uint a = loadIndex(address, i * 3 + 0);
        uint b = loadIndex(address, i * 3 + 1);
        uint c = loadIndex(address, i * 3 + 2);
        return (a * 73_856_093u) ^ (b * 19_349_663u) ^ (c * 83_492_791u);
    }

    bool equal(uint lhs, uint rhs) const scope nothrow @nogc {
        return loadIndex(address, lhs * 3 + 0) == loadIndex(address, rhs * 3 + 0)
            && loadIndex(address, lhs * 3 + 1) == loadIndex(address, rhs * 3 + 1)
            && loadIndex(address, lhs * 3 + 2) == loadIndex(address, rhs * 3 + 2);
    }
}

private ulong indexAddress(scope const(uint)[] data) nothrow @nogc @trusted {
    return data.length ? cast(ulong) data.ptr : 0;
}

package size_t filterTriangles(scope uint[] destination, uint[] tritable, scope const(uint)[] indices, size_t indexCount, const(uint)[] vertexCells, const(uint)[] cellRemap) nothrow @nogc {
    TriangleHasher hasher;
    hasher.address = indexAddress(destination);
    tritable[] = uint.max;
    size_t result = 0;
    for (size_t i = 0; i < indexCount; i += 3) {
        uint c0 = vertexCells[indices[i + 0]];
        uint c1 = vertexCells[indices[i + 1]];
        uint c2 = vertexCells[indices[i + 2]];
        if (c0 != c1 && c0 != c2 && c1 != c2) {
            uint a = cellRemap[c0];
            uint b = cellRemap[c1];
            uint c = cellRemap[c2];
            if (b < a && b < c) {
                uint t = a;
                a = b;
                b = c;
                c = t;
            } else if (c < a && c < b) {
                uint t = c;
                c = b;
                b = a;
                a = t;
            }
            destination[result * 3 + 0] = a;
            destination[result * 3 + 1] = b;
            destination[result * 3 + 2] = c;
            size_t slot = hashLookup(tritable, hasher, asU32(result), uint.max);
            if (tritable[slot] == uint.max) {
                tritable[slot] = asU32(result);
                result++;
            }
        }
    }
    return result * 3;
}

package size_t simplifySloppyU32(scope uint[] destination, scope const(uint)[] indices, ulong address, size_t strideFloats, size_t vertexCount, scope const(ubyte)[] vertexLock, size_t targetIndexCount, float targetError, ref float outError, ref MeshoptScratch scratch) nothrow @nogc {
    import engine.meshopt.simplify.quadric : rescalePositions;
    size_t indexCount = indices.length;
    assert(indexCount % 3 == 0);
    assert(strideFloats >= 3 && strideFloats <= 64);
    assert(targetIndexCount <= indexCount);
    assert(targetError >= 0);
    assert(vertexLock.length == 0 || vertexLock.length == vertexCount);
    size_t targetCellCount = targetIndexCount / 6;

    Vec3[] positions = scratch.allocate!Vec3(vertexCount);
    rescalePositions(positions, vertexCount, address, strideFloats, null, null);
    uint[] vertexIds = scratch.allocate!uint(vertexCount);

    enum int interpolationPasses = 5;
    float errFloor = targetError < 1e-3f ? 1e-3f : (targetError < 1.0f ? targetError : 1.0f);
    int minGrid = cast(int)(1.0f / errFloor);
    int maxGrid = 1025;
    size_t minTriangles = 0;
    size_t maxTriangles = indexCount / 3;
    if (minGrid > 1 || vertexLock.length) {
        computeVertexIds(vertexIds, positions, vertexLock, minGrid);
        minTriangles = countTriangles(vertexIds, indices, indexCount);
    }
    int nextGrid = cast(int)(sqrtF(cast(float) targetCellCount) + 0.5f);
    foreach (pass; 0 .. 10 + interpolationPasses) {
        if (minTriangles >= targetIndexCount / 3 || maxGrid - minGrid <= 1)
            break;
        int gridSize = nextGrid;
        gridSize = gridSize <= minGrid ? minGrid + 1 : (gridSize >= maxGrid ? maxGrid - 1 : gridSize);
        computeVertexIds(vertexIds, positions, vertexLock, gridSize);
        size_t triangles = countTriangles(vertexIds, indices, indexCount);
        float tip = interpolate(cast(float)(targetIndexCount / 3), cast(float) minGrid, cast(float) minTriangles, cast(float) gridSize, cast(float) triangles, cast(float) maxGrid, cast(float) maxTriangles);
        if (triangles <= targetIndexCount / 3) {
            minGrid = gridSize;
            minTriangles = triangles;
        } else {
            maxGrid = gridSize;
            maxTriangles = triangles;
        }
        nextGrid = pass < interpolationPasses ? cast(int)(tip + 0.5f) : (minGrid + maxGrid) / 2;
    }
    if (minTriangles == 0) {
        outError = 1.0f;
        return 0;
    }

    size_t tableSize = hashBuckets(vertexCount);
    uint[] table = scratch.allocate!uint(tableSize);
    uint[] vertexCells = scratch.allocate!uint(vertexCount);
    computeVertexIds(vertexIds, positions, vertexLock, minGrid);
    size_t cellCount = fillVertexCells(table, vertexCells, vertexIds);

    Quadric[] cellQuadrics = scratch.allocate!Quadric(cellCount);
    cellQuadrics[] = Quadric.init;
    fillCellQuadrics(cellQuadrics, indices, indexCount, positions, vertexCells);

    uint[] cellRemap = scratch.allocate!uint(cellCount);
    float[] cellErrors = scratch.allocate!float(cellCount);
    fillCellRemapQuadric(cellRemap, cellErrors, vertexCells, cellQuadrics, positions);

    float resultError = 0.0f;
    foreach (i; 0 .. cellCount)
        resultError = resultError < cellErrors[i] ? cellErrors[i] : resultError;

    size_t tritableSize = hashBuckets(minTriangles);
    uint[] tritable = scratch.allocate!uint(tritableSize);
    size_t write = filterTriangles(destination, tritable, indices, indexCount, vertexCells, cellRemap);
    outError = sqrtF(resultError);
    return write;
}
