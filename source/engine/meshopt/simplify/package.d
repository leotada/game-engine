// Ported from meshoptimizer v1.3 (src/simplifier.cpp), Copyright (c) 2016-2026 Arseny Kapoulkine, MIT License.
/// Edge-collapse simplification. Attribute, lock, and experimental option paths
/// share this loop; `simplifySloppy`, `simplifyPrune`, and `simplifyPoints` are separate.
module engine.meshopt.simplify;

import engine.meshopt.internal.vec : Vec3;
import engine.meshopt.scratch : MeshoptScratch, defaultScratch;
import engine.meshopt.simplify.collapse : Collapse, boundEdgeCollapses, buildComponents, measureComponents,
    orderEdgeCollapses, performEdgeCollapses, pickEdgeCollapses, pruneComponents, rankEdgeCollapses,
    remapEdgeLoops, remapIndexBuffer, solveAttributes, solvePositions, updateQuadrics;
import engine.meshopt.simplify.quadric : Quadric, QuadricGrad, fillAttributeQuadrics, fillEdgeQuadrics,
    fillFaceQuadrics, fillFoldQuadrics, fillVertexQuadrics, finalizeVertices, maxAttributes, rescaleAttributes,
    rescalePositions, sqrtF;
import engine.meshopt.simplify.points : simplifyPointsU32, simplifyScale;
import engine.meshopt.simplify.prune : simplifyPruneU32;
import engine.meshopt.simplify.sloppy : simplifySloppyU32;
import engine.meshopt.simplify.topology : EdgeAdjacency, VertexKind, asU32, buildPositionRemap, buildSparseRemap,
    classifyVertices, prepareEdgeAdjacency, samePtr, updateEdgeAdjacency;
import engine.meshopt.types : FloatStream, SimplifyOptions;

public import engine.meshopt.simplify.points : simplifyScale;

@safe:

/// Development-only. Not part of `SimplifyOptions`. Enables `simplifyWithUpdate`.
package enum uint simplifyInternalSolve = 1u << 29;
/// Development-only. Packs vertex kind into the high bits of each index.
package enum uint simplifyInternalDebug = 1u << 30;

/**
 * Edge-collapse simplification (`meshopt_simplify`).
 *
 * The result indexes the original vertex buffer. `destination` must hold at
 * least `indices.length` entries. When `resultError.length >= 1`, it receives
 * the linear error (relative to the mesh extent, or absolute with `errorAbsolute`).
 *
 * `lockBorder`, `sparse`, and `errorAbsolute` are stable. `prune`, `regularize`,
 * `regularizeLight`, `permissive`, `preserveFolds`, and `errorClamped` are
 * experimental, matching upstream.
 */
size_t simplify(I)(scope I[] destination, scope const(I)[] indices, FloatStream positions, size_t targetIndexCount, float targetError, SimplifyOptions options = SimplifyOptions.none, scope float[] resultError = null, ref MeshoptScratch scratch = defaultScratch()) nothrow @nogc
if (is(I == uint) || is(I == ushort)) {
    return simplifyDispatch!I(destination, indices, positions, FloatStream.init, null, null, targetIndexCount, targetError, cast(uint) options, resultError, scratch);
}

/**
 * `meshopt_simplifyWithAttributes`. `attributeWeights.length` is the attribute
 * count (at most 32). An empty `vertexLock` means unlocked. Experimental options
 * match `simplify`.
 */
size_t simplifyWithAttributes(I)(scope I[] destination, scope const(I)[] indices, FloatStream positions, FloatStream attributes, scope const(float)[] attributeWeights, scope const(ubyte)[] vertexLock, size_t targetIndexCount, float targetError, SimplifyOptions options = SimplifyOptions.none, scope float[] resultError = null, ref MeshoptScratch scratch = defaultScratch()) nothrow @nogc
if (is(I == uint) || is(I == ushort)) {
    return simplifyDispatch!I(destination, indices, positions, attributes, attributeWeights, vertexLock, targetIndexCount, targetError, cast(uint) options, resultError, scratch);
}

/**
 * `meshopt_simplifyWithUpdate`. Updates `indices`, and writes optimal positions
 * and weighted attributes back through the stream addresses. Experimental, as upstream.
 */
size_t simplifyWithUpdate(I)(scope I[] indices, FloatStream positions, FloatStream attributes, scope const(float)[] attributeWeights, scope const(ubyte)[] vertexLock, size_t targetIndexCount, float targetError, SimplifyOptions options = SimplifyOptions.none, scope float[] resultError = null, ref MeshoptScratch scratch = defaultScratch()) nothrow @nogc
if (is(I == uint) || is(I == ushort)) {
    return simplifyDispatch!I(indices, indices, positions, attributes, attributeWeights, vertexLock, targetIndexCount, targetError, cast(uint) options | simplifyInternalSolve, resultError, scratch);
}

private size_t simplifyDispatch(I)(scope I[] destination, scope const(I)[] indices, FloatStream positions, FloatStream attributes, scope const(float)[] attributeWeights, scope const(ubyte)[] vertexLock, size_t targetIndexCount, float targetError, uint options, scope float[] resultError, ref MeshoptScratch scratch) nothrow @nogc
if (is(I == uint) || is(I == ushort)) {
    assert(destination.length >= indices.length);
    assert((options & simplifyInternalSolve) == 0 || samePtr(destination, indices));
    immutable mark = scratch.mark();
    scope(exit) scratch.release(mark);
    float error = 0;
    size_t n;
    static if (is(I == uint)) {
        n = simplifyEdge(destination, indices, positions, attributes, attributeWeights, vertexLock, targetIndexCount, targetError, options, error, scratch);
    } else {
        uint[] wide = scratch.allocate!uint(indices.length);
        foreach (i, v; indices)
            wide[i] = v;
        n = simplifyEdge(wide, wide, positions, attributes, attributeWeights, vertexLock, targetIndexCount, targetError, options, error, scratch);
        foreach (i; 0 .. indices.length)
            destination[i] = cast(I) wide[i];
    }
    if (resultError.length)
        resultError[0] = error;
    return n;
}

package size_t simplifyEdge(scope uint[] destination, scope const(uint)[] indices, FloatStream positions, FloatStream attributes, scope const(float)[] attributeWeights, scope const(ubyte)[] vertexLock, size_t targetIndexCount, float targetError, uint options, ref float outResultError, ref MeshoptScratch scratch) nothrow @nogc {
    size_t indexCount = indices.length;
    assert(indexCount % 3 == 0);
    assert(positions.strideFloats >= 3 && positions.strideFloats <= 64);
    assert(targetIndexCount <= indexCount);
    assert(targetError >= 0);
    assert(attributeWeights.length <= maxAttributes);
    assert(vertexLock.length == 0 || vertexLock.length == positions.count);
    if (attributeWeights.length) {
        assert(attributes.strideFloats >= attributeWeights.length && attributes.strideFloats <= 64);
        foreach (w; attributeWeights)
            assert(w >= 0);
    }
    if (!samePtr(destination, indices))
        destination[0 .. indexCount] = indices[];
    scope uint[] result = destination[0 .. indexCount];

    size_t vertexCount = positions.count;
    uint[] sparseRemap;
    if ((options & SimplifyOptions.sparse) != 0) {
        sparseRemap = buildSparseRemap(result, vertexCount, scratch);
        vertexCount = sparseRemap.length;
    }

    EdgeAdjacency adjacency;
    prepareEdgeAdjacency(adjacency, indexCount, vertexCount, scratch);
    updateEdgeAdjacency(adjacency, result, indexCount, vertexCount, null);

    uint[] remap = scratch.allocate!uint(vertexCount);
    uint[] wedge = scratch.allocate!uint(vertexCount);
    buildPositionRemap(remap, wedge, positions.address, positions.strideFloats, sparseRemap, scratch);

    ubyte[] vertexKind = scratch.allocate!ubyte(vertexCount);
    uint[] loop = scratch.allocate!uint(vertexCount);
    uint[] loopback = scratch.allocate!uint(vertexCount);
    classifyVertices(vertexKind, loop, loopback, adjacency, remap, wedge, vertexLock, sparseRemap, options);

    Vec3[] vertexPositions = scratch.allocate!Vec3(vertexCount);
    float[] vertexOffset = scratch.allocate!float(3);
    float vertexScale = rescalePositions(vertexPositions, vertexCount, positions.address, positions.strideFloats, sparseRemap, vertexOffset);

    uint[maxAttributes] attributeRemap;
    size_t attributeCount = 0;
    foreach (i, w; attributeWeights) {
        if (w > 0)
            attributeRemap[attributeCount++] = asU32(i);
    }
    float[] vertexAttributes;
    if (attributeCount) {
        vertexAttributes = scratch.allocate!float(vertexCount * attributeCount);
        rescaleAttributes(vertexAttributes, attributes.address, attributes.strideFloats, attributeWeights, attributeCount, attributeRemap[], sparseRemap, vertexCount);
    }

    Quadric[] vertexQuadrics = scratch.allocate!Quadric(vertexCount);
    vertexQuadrics[] = Quadric.init;

    Quadric[] attributeQuadrics;
    QuadricGrad[] attributeGradients;
    QuadricGrad[] volumeGradients;
    if (attributeCount) {
        attributeQuadrics = scratch.allocate!Quadric(vertexCount);
        attributeQuadrics[] = Quadric.init;
        attributeGradients = scratch.allocate!QuadricGrad(vertexCount * attributeCount);
        attributeGradients[] = QuadricGrad.init;
        if ((options & simplifyInternalSolve) != 0) {
            volumeGradients = scratch.allocate!QuadricGrad(vertexCount);
            volumeGradients[] = QuadricGrad.init;
        }
    }

    fillFaceQuadrics(vertexQuadrics, volumeGradients, result, indexCount, vertexPositions, remap);
    fillVertexQuadrics(vertexQuadrics, vertexPositions, remap, vertexLock, sparseRemap, options);
    fillEdgeQuadrics(vertexQuadrics, result, indexCount, vertexPositions, remap, vertexKind, loop, loopback);
    if ((options & SimplifyOptions.preserveFolds) != 0)
        fillFoldQuadrics(vertexQuadrics, adjacency, vertexPositions, remap, wedge);
    if (attributeCount)
        fillAttributeQuadrics(attributeQuadrics, attributeGradients, result, indexCount, vertexPositions, vertexAttributes, attributeCount);

    uint[] components;
    float[] componentErrors;
    size_t componentCount = 0;
    float componentNext = 0;
    if ((options & SimplifyOptions.prune) != 0) {
        components = scratch.allocate!uint(vertexCount);
        componentCount = buildComponents(components, result, indexCount, remap);
        componentErrors = scratch.allocate!float(componentCount * 4);
        measureComponents(componentErrors, componentCount, components, vertexPositions);
        componentNext = float.max;
        foreach (i; 0 .. componentCount)
            componentNext = componentNext > componentErrors[i] ? componentErrors[i] : componentNext;
    }

    size_t collapseCapacity = boundEdgeCollapses(adjacency, vertexCount, indexCount, vertexKind);
    Collapse[] edgeCollapses = scratch.allocate!Collapse(collapseCapacity);
    uint[] collapseOrder = scratch.allocate!uint(collapseCapacity);
    uint[] collapseRemap = scratch.allocate!uint(vertexCount);
    ubyte[] collapseLocked = scratch.allocate!ubyte(vertexCount);
    uint[] sortBits = scratch.allocate!uint(collapseCapacity);

    size_t resultCount = indexCount;
    float resultError = 0;
    float vertexError = 0;
    float errorScale = (options & SimplifyOptions.errorAbsolute) != 0 ? vertexScale : 1.0f;
    float errorLimit = (targetError * targetError) / (errorScale * errorScale);
    bool clamped = (options & SimplifyOptions.errorClamped) != 0;

    while (resultCount > targetIndexCount) {
        updateEdgeAdjacency(adjacency, result, resultCount, vertexCount, remap);
        size_t edgeCollapseCount = pickEdgeCollapses(edgeCollapses, collapseCapacity, result, resultCount, remap, vertexKind, loop, loopback);
        assert(edgeCollapseCount <= collapseCapacity);
        if (edgeCollapseCount == 0)
            break;
        rankEdgeCollapses(edgeCollapses, edgeCollapseCount, vertexPositions, vertexAttributes, vertexQuadrics, attributeQuadrics, attributeGradients, attributeCount, remap, wedge, vertexKind, loop, loopback, clamped);
        orderEdgeCollapses(collapseOrder, edgeCollapses, edgeCollapseCount, sortBits);
        size_t triangleCollapseGoal = (resultCount - targetIndexCount) / 3;
        foreach (i; 0 .. vertexCount)
            collapseRemap[i] = asU32(i);
        collapseLocked[] = 0;
        size_t collapses = performEdgeCollapses(collapseRemap, collapseLocked, edgeCollapses, edgeCollapseCount, collapseOrder, remap, wedge, vertexKind, loop, loopback, vertexPositions, adjacency, triangleCollapseGoal, errorLimit, resultError);
        if (collapses == 0)
            break;
        updateQuadrics(collapseRemap, vertexCount, vertexQuadrics, volumeGradients, attributeQuadrics, attributeGradients, attributeCount, vertexPositions, remap, vertexError);
        vertexError = attributeCount == 0 ? resultError : vertexError;
        remapEdgeLoops(loop, collapseRemap);
        remapEdgeLoops(loopback, collapseRemap);
        resultCount = remapIndexBuffer(result, resultCount, collapseRemap, remap);
        if ((options & SimplifyOptions.prune) != 0 && resultCount > targetIndexCount && componentNext <= vertexError)
            resultCount = pruneComponents(result, resultCount, components, componentErrors, vertexError, componentNext);
    }

    bool componentNextStale = true;
    while ((options & SimplifyOptions.prune) != 0 && resultCount > targetIndexCount && componentNext <= errorLimit) {
        float componentCutoff = componentNext * 1.5f < errorLimit ? componentNext * 1.5f : errorLimit;
        float componentMax = 0;
        foreach (i; 0 .. componentCount) {
            if (componentErrors[i] > componentMax && componentErrors[i] <= componentCutoff)
                componentMax = componentErrors[i];
        }
        size_t newCount = pruneComponents(result, resultCount, components, componentErrors, componentCutoff, componentNext);
        if (newCount == resultCount && !componentNextStale)
            break;
        componentNextStale = false;
        resultCount = newCount;
        resultError = resultError < componentMax ? componentMax : resultError;
        vertexError = vertexError < componentMax ? componentMax : vertexError;
    }

    if ((options & simplifyInternalSolve) != 0) {
        ubyte[] vertexUpdate = collapseLocked;
        vertexUpdate[] = 0;
        foreach (i; 0 .. resultCount) {
            uint v = result[i];
            vertexUpdate[remap[v]] = 1;
            vertexUpdate[v] = 1;
        }
        updateEdgeAdjacency(adjacency, result, resultCount, vertexCount, remap);
        solvePositions(vertexPositions, vertexQuadrics, volumeGradients, attributeQuadrics, attributeGradients, attributeCount, remap, wedge, adjacency, vertexKind, vertexUpdate);
        if (attributeCount)
            solveAttributes(vertexPositions, vertexAttributes, attributeQuadrics, attributeGradients, attributeCount, remap, wedge, vertexKind, vertexUpdate);
        finalizeVertices(positions.address, positions.strideFloats, attributes.address, attributes.strideFloats, attributeWeights, attributeCount, vertexCount, vertexPositions, vertexAttributes, sparseRemap, attributeRemap[], vertexScale, vertexOffset, vertexKind, vertexUpdate, vertexLock);
    }

    if ((options & simplifyInternalDebug) != 0 && sparseRemap.length == 0) {
        assert(VertexKind.count <= 8 && vertexCount < (1u << 28));
        for (size_t i = 0; i < resultCount; i += 3) {
            uint a = result[i + 0], b = result[i + 1], c = result[i + 2];
            result[i + 0] |= (cast(uint) vertexKind[a] << 28) | (cast(uint)(loop[a] == b || loopback[b] == a) << 31);
            result[i + 1] |= (cast(uint) vertexKind[b] << 28) | (cast(uint)(loop[b] == c || loopback[c] == b) << 31);
            result[i + 2] |= (cast(uint) vertexKind[c] << 28) | (cast(uint)(loop[c] == a || loopback[a] == c) << 31);
        }
    }

    if (sparseRemap.length) {
        foreach (i; 0 .. resultCount)
            result[i] = sparseRemap[result[i]];
    }

    outResultError = sqrtF(resultError) * errorScale;
    return resultCount;
}

/**
 * Grid clustering (`meshopt_simplifySloppy`). Does not preserve topology.
 * An empty `vertexLock` leaves every vertex free. `targetError` is relative, in [0, 1].
 */
size_t simplifySloppy(I)(scope I[] destination, scope const(I)[] indices, FloatStream positions, scope const(ubyte)[] vertexLock, size_t targetIndexCount, float targetError, scope float[] resultError = null, ref MeshoptScratch scratch = defaultScratch()) nothrow @nogc
if (is(I == uint) || is(I == ushort)) {
    assert(destination.length >= indices.length);
    immutable mark = scratch.mark();
    scope(exit) scratch.release(mark);
    float error = 0;
    size_t n;
    static if (is(I == uint)) {
        n = simplifySloppyU32(destination, indices, positions.address, positions.strideFloats, positions.count, vertexLock, targetIndexCount, targetError, error, scratch);
    } else {
        uint[] wideSrc = scratch.allocate!uint(indices.length);
        uint[] wideDst = scratch.allocate!uint(indices.length);
        foreach (i, v; indices)
            wideSrc[i] = v;
        n = simplifySloppyU32(wideDst, wideSrc, positions.address, positions.strideFloats, positions.count, vertexLock, targetIndexCount, targetError, error, scratch);
        foreach (i; 0 .. n)
            destination[i] = cast(I) wideDst[i];
    }
    if (resultError.length)
        resultError[0] = error;
    return n;
}

/// Remove components whose radius is below `targetError` (`meshopt_simplifyPrune`).
size_t simplifyPrune(I)(scope I[] destination, scope const(I)[] indices, FloatStream positions, float targetError, ref MeshoptScratch scratch = defaultScratch()) nothrow @nogc
if (is(I == uint) || is(I == ushort)) {
    assert(destination.length >= indices.length);
    immutable mark = scratch.mark();
    scope(exit) scratch.release(mark);
    static if (is(I == uint)) {
        return simplifyPruneU32(destination, indices, positions.address, positions.strideFloats, positions.count, targetError, scratch);
    } else {
        uint[] wide = scratch.allocate!uint(indices.length);
        foreach (i, v; indices)
            wide[i] = v;
        size_t n = simplifyPruneU32(wide, wide, positions.address, positions.strideFloats, positions.count, targetError, scratch);
        foreach (i; 0 .. indices.length)
            destination[i] = cast(I) wide[i];
        return n;
    }
}

/**
 * Point-cloud decimation (`meshopt_simplifyPoints`).
 * Empty `colors` ignores color. `colorWeight` is the color-vs-position priority (1 is a safe default).
 */
size_t simplifyPoints(I)(scope I[] destination, FloatStream positions, FloatStream colors, float colorWeight, size_t targetVertexCount, ref MeshoptScratch scratch = defaultScratch()) nothrow @nogc
if (is(I == uint) || is(I == ushort)) {
    if (targetVertexCount == 0)
        return 0;
    assert(destination.length >= targetVertexCount);
    immutable mark = scratch.mark();
    scope(exit) scratch.release(mark);
    bool hasColor = colors.count != 0;
    static if (is(I == uint)) {
        return simplifyPointsU32(destination, positions.address, positions.strideFloats, positions.count, colors.address, colors.strideFloats, hasColor, colorWeight, targetVertexCount, scratch);
    } else {
        uint[] wide = scratch.allocate!uint(targetVertexCount);
        size_t n = simplifyPointsU32(wide, positions.address, positions.strideFloats, positions.count, colors.address, colors.strideFloats, hasColor, colorWeight, targetVertexCount, scratch);
        foreach (i; 0 .. n)
            destination[i] = cast(I) wide[i];
        return n;
    }
}

private FloatStream stream3(scope const(float)[] packed, size_t count) nothrow @nogc @trusted {
    FloatStream s;
    s.strideFloats = 3;
    s.count = count;
    if (count && packed.length)
        s.address = cast(ulong) packed.ptr;
    return s;
}

@("simplify.debug") nothrow @nogc unittest {
    uint[12] ib = [0, 2, 1, 1, 2, 3, 3, 2, 4, 2, 5, 4];
    float[18] vb = [0, 4, 0, 0, 1, 0, 2, 2, 0, 0, 0, 0, 1, 0, 0, 4, 0, 0];
    float err;
    size_t n = simplifyEdge(ib[], ib[], stream3(vb[], 6), FloatStream.init, null, null, 3, 1e-2f, simplifyInternalDebug, err, defaultScratch());
    assert(n == 3);
    assert(err < 1e-4f);
    assert(ib[0] == (0 | (9u << 28)));
    assert(ib[1] == (5 | (9u << 28)));
    assert(ib[2] == (3 | (9u << 28)));
}

@("simplify.basic") nothrow @nogc unittest {
    uint[12] ib = [0, 2, 1, 1, 2, 3, 3, 2, 4, 2, 5, 4];
    float[18] vb = [0, 4, 0, 0, 1, 0, 2, 2, 0, 0, 0, 0, 1, 0, 0, 4, 0, 0];
    uint[3] expected = [0, 5, 3];
    float[1] error;
    assert(simplify(ib[], ib[], stream3(vb[], 6), 3, 1e-2f, SimplifyOptions.none, error[]) == 3);
    assert(error[0] < 1e-4f);
    assert(ib[0 .. 3] == expected[]);
}

@("simplify.stuck") nothrow @nogc unittest {
    float[12] vb1 = [0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1];
    uint[12] ib1 = [0, 1, 2, 0, 2, 3, 0, 3, 1, 2, 1, 3];
    assert(simplify(ib1[], ib1[], stream3(vb1[], 4), 6, 1e-3f) == 12);

    float[15] vb2 = [0, 0, 0, 1, 0, 0, 2, 0, 0, 0.5f, 1, 0, 1.5f, 1, 0];
    uint[9] ib2 = [0, 1, 3, 3, 1, 4, 1, 2, 4];
    uint[9] ib3 = [0, 1, 3, 1, 3, 4, 1, 2, 4];
    assert(simplify(ib2[], ib2[], stream3(vb2[], 5), 6, 1e-3f) == 6);
    assert(simplify(ib3[], ib3[], stream3(vb2[], 5), 6, 1e-3f) == 9);

    float[12] vb4 = [0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 1, 0];
    uint[6] ib4 = [0, 1, 3, 0, 3, 2];
    assert(simplify(ib4[], ib4[], stream3(vb4[], 4), 3, 1e-3f) == 6);

    float[15] vb5 = [0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 1, 0, 1, 1, 0];
    uint[6] ib5 = [0, 1, 4, 0, 3, 2];
    assert(simplify(ib5[], ib5[], stream3(vb5[], 5), 3, 1e-3f) == 6);
}
