// Ported from meshoptimizer v1.3 (src/simplifier.cpp), Copyright (c) 2016-2026 Arseny Kapoulkine, MIT License.
/// Remove small disconnected components (`meshopt_simplifyPrune`).
module engine.meshopt.simplify.prune;

import engine.meshopt.internal.vec : Vec3;
import engine.meshopt.scratch : MeshoptScratch;
import engine.meshopt.simplify.collapse : buildComponents, measureComponents, pruneComponents;
import engine.meshopt.simplify.quadric : rescalePositions;
import engine.meshopt.simplify.topology : buildPositionRemap, samePtr;

@safe:

package size_t simplifyPruneU32(scope uint[] destination, scope const(uint)[] indices, ulong address, size_t strideFloats, size_t vertexCount, float targetError, ref MeshoptScratch scratch) nothrow @nogc {
    size_t indexCount = indices.length;
    assert(indexCount % 3 == 0);
    assert(strideFloats >= 3 && strideFloats <= 64);
    assert(targetError >= 0);
    if (!samePtr(destination, indices))
        destination[0 .. indexCount] = indices[];
    scope uint[] result = destination[0 .. indexCount];

    uint[] remap = scratch.allocate!uint(vertexCount);
    buildPositionRemap(remap, null, address, strideFloats, null, scratch);

    Vec3[] positions = scratch.allocate!Vec3(vertexCount);
    rescalePositions(positions, vertexCount, address, strideFloats, null, null);

    uint[] components = scratch.allocate!uint(vertexCount);
    size_t componentCount = buildComponents(components, indices, indexCount, remap);
    float[] componentErrors = scratch.allocate!float(componentCount * 4);
    measureComponents(componentErrors, componentCount, components, positions);

    float nextError = 0;
    return pruneComponents(result, indexCount, components, componentErrors, targetError * targetError, nextError);
}
