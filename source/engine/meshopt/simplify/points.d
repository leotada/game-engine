// Ported from meshoptimizer v1.3 (src/simplifier.cpp), Copyright (c) 2016-2026 Arseny Kapoulkine, MIT License.
/// Point-cloud decimation (`meshopt_simplifyPoints`) and `simplifyScale`.
module engine.meshopt.simplify.points;

import engine.meshopt.internal.hash : hashBuckets;
import engine.meshopt.internal.vec : Vec3;
import engine.meshopt.scratch : MeshoptScratch;
import engine.meshopt.simplify.quadric : Reservoir, rescalePositions, sqrtF;
import engine.meshopt.simplify.sloppy : computeVertexIds, countVertexCells, fillCellRemapPoints, fillCellReservoirs, fillVertexCells, interpolate;
import engine.meshopt.types : FloatStream;

@safe:

package size_t simplifyPointsU32(scope uint[] destination, ulong address, size_t strideFloats, size_t vertexCount, ulong colorAddress, size_t colorStride, bool hasColor, float colorWeight, size_t targetVertexCount, ref MeshoptScratch scratch) nothrow @nogc {
    assert(strideFloats >= 3 && strideFloats <= 64);
    assert(!hasColor || (colorStride >= 3 && colorStride <= 64));
    assert(targetVertexCount <= vertexCount);
    if (targetVertexCount == 0)
        return 0;

    Vec3[] positions = scratch.allocate!Vec3(vertexCount);
    rescalePositions(positions, vertexCount, address, strideFloats, null, null);
    uint[] vertexIds = scratch.allocate!uint(vertexCount);
    size_t tableSize = hashBuckets(vertexCount);
    uint[] table = scratch.allocate!uint(tableSize);

    enum int interpolationPasses = 5;
    int minGrid = 0;
    int maxGrid = 1025;
    size_t minVertices = 0;
    size_t maxVertices = vertexCount;
    int nextGrid = cast(int)(sqrtF(cast(float) targetVertexCount) + 0.5f);

    foreach (pass; 0 .. 10 + interpolationPasses) {
        assert(minVertices < targetVertexCount);
        assert(maxGrid - minGrid > 1);
        int gridSize = nextGrid;
        gridSize = gridSize <= minGrid ? minGrid + 1 : (gridSize >= maxGrid ? maxGrid - 1 : gridSize);
        computeVertexIds(vertexIds, positions, null, gridSize);
        size_t vertices = countVertexCells(table, vertexIds);
        float tip = interpolate(cast(float) targetVertexCount, cast(float) minGrid, cast(float) minVertices, cast(float) gridSize, cast(float) vertices, cast(float) maxGrid, cast(float) maxVertices);
        if (vertices <= targetVertexCount) {
            minGrid = gridSize;
            minVertices = vertices;
        } else {
            maxGrid = gridSize;
            maxVertices = vertices;
        }
        if (vertices == targetVertexCount || maxGrid - minGrid <= 1)
            break;
        nextGrid = pass < interpolationPasses ? cast(int)(tip + 0.5f) : (minGrid + maxGrid) / 2;
    }
    if (minVertices == 0)
        return 0;

    uint[] vertexCells = scratch.allocate!uint(vertexCount);
    computeVertexIds(vertexIds, positions, null, minGrid);
    size_t cellCount = fillVertexCells(table, vertexCells, vertexIds);

    Reservoir[] cellReservoirs = scratch.allocate!Reservoir(cellCount);
    cellReservoirs[] = Reservoir.init;
    fillCellReservoirs(cellReservoirs, positions, colorAddress, colorStride, hasColor, vertexCells);

    uint[] cellRemap = scratch.allocate!uint(cellCount);
    float[] cellErrors = scratch.allocate!float(cellCount);
    float colorWeightScaled = colorWeight * (minGrid == 1 ? 1.0f : 1.0f / (minGrid - 1));
    fillCellRemapPoints(cellRemap, cellErrors, vertexCells, cellReservoirs, positions, colorAddress, colorStride, hasColor, colorWeightScaled * colorWeightScaled);

    assert(cellCount <= targetVertexCount);
    destination[0 .. cellCount] = cellRemap[];
    return cellCount;
}

/// Absolute scale of the position extent. Divide a world-space error by this
/// before passing it as a relative `targetError`.
float simplifyScale(FloatStream positions) nothrow @nogc {
    assert(positions.strideFloats >= 3 && positions.strideFloats <= 64);
    return rescalePositions(null, positions.count, positions.address, positions.strideFloats, null, null);
}
