// Ported from meshoptimizer v1.3 (src/simplifier.cpp), Copyright (c) 2016-2026 Arseny Kapoulkine, MIT License.
/// Edge-collapse candidate selection, ranking, and index remapping.
module engine.meshopt.simplify.collapse;

import engine.meshopt.internal.sort : sortEdgeCollapses;
import engine.meshopt.internal.vec : Vec3;
import engine.meshopt.simplify.quadric : Quadric, QuadricGrad, fabsF, quadricError, quadricErrorAttr, sqrtF;
import engine.meshopt.simplify.topology : Edge, EdgeAdjacency, VertexKind, asU32, kCanCollapse, kHasOpposite;

@safe:

package struct Collapse {
    uint v0;
    uint v1;
    union {
        uint bidi;
        float error;
        uint errorui;
    }
}

package bool hasTriangleFlip(const(Vec3) a, const(Vec3) b, const(Vec3) c, const(Vec3) d) nothrow @nogc {
    Vec3 eb = Vec3(b.x - a.x, b.y - a.y, b.z - a.z);
    Vec3 ec = Vec3(c.x - a.x, c.y - a.y, c.z - a.z);
    Vec3 ed = Vec3(d.x - a.x, d.y - a.y, d.z - a.z);
    Vec3 nbc = Vec3(eb.y * ec.z - eb.z * ec.y, eb.z * ec.x - eb.x * ec.z, eb.x * ec.y - eb.y * ec.x);
    Vec3 nbd = Vec3(eb.y * ed.z - eb.z * ed.y, eb.z * ed.x - eb.x * ed.z, eb.x * ed.y - eb.y * ed.x);
    float ndp = nbc.x * nbd.x + nbc.y * nbd.y + nbc.z * nbd.z;
    float abc = nbc.x * nbc.x + nbc.y * nbc.y + nbc.z * nbc.z;
    float abd = nbd.x * nbd.x + nbd.y * nbd.y + nbd.z * nbd.z;
    return ndp <= 0.25f * sqrtF(abc * abd);
}

package bool hasTriangleFlips(const(EdgeAdjacency) adjacency, const(Vec3)[] positions, const(uint)[] collapseRemap, uint i0, uint i1) nothrow @nogc {
    assert(collapseRemap[i0] == i0);
    assert(collapseRemap[i1] == i1);
    Vec3 v0 = positions[i0];
    Vec3 v1 = positions[i1];
    size_t count = adjacency.offsets[i0 + 1] - adjacency.offsets[i0];
    const(Edge)[] edges = adjacency.data[adjacency.offsets[i0] .. adjacency.offsets[i0] + count];
    foreach (i; 0 .. count) {
        uint a = collapseRemap[edges[i].next];
        uint b = collapseRemap[edges[i].prev];
        if (a == i1 || b == i1 || a == b)
            continue;
        if (hasTriangleFlip(positions[a], positions[b], v0, v1))
            return true;
    }
    return false;
}

package bool hasTriangleFlipsAt(const(EdgeAdjacency) adjacency, const(Vec3)[] positions, uint i0, const(Vec3) v1) nothrow @nogc {
    Vec3 v0 = positions[i0];
    size_t count = adjacency.offsets[i0 + 1] - adjacency.offsets[i0];
    const(Edge)[] edges = adjacency.data[adjacency.offsets[i0] .. adjacency.offsets[i0] + count];
    foreach (i; 0 .. count) {
        uint a = edges[i].next;
        uint b = edges[i].prev;
        if (hasTriangleFlip(positions[a], positions[b], v0, v1))
            return true;
    }
    return false;
}

package float getNeighborhoodRadius(const(EdgeAdjacency) adjacency, const(Vec3)[] positions, uint i0) nothrow @nogc {
    Vec3 v0 = positions[i0];
    size_t count = adjacency.offsets[i0 + 1] - adjacency.offsets[i0];
    const(Edge)[] edges = adjacency.data[adjacency.offsets[i0] .. adjacency.offsets[i0] + count];
    float result = 0.0f;
    foreach (i; 0 .. count) {
        uint a = edges[i].next;
        uint b = edges[i].prev;
        Vec3 va = positions[a];
        Vec3 vb = positions[b];
        float da = (va.x - v0.x) * (va.x - v0.x) + (va.y - v0.y) * (va.y - v0.y) + (va.z - v0.z) * (va.z - v0.z);
        float db = (vb.x - v0.x) * (vb.x - v0.x) + (vb.y - v0.y) * (vb.y - v0.y) + (vb.z - v0.z) * (vb.z - v0.z);
        result = result < da ? da : result;
        result = result < db ? db : result;
    }
    return sqrtF(result);
}

package uint getComplexTarget(uint v, uint target, const(uint)[] remap, const(uint)[] loop, const(uint)[] loopback) nothrow @nogc {
    uint r = remap[target];
    if (loop[v] != uint.max && remap[loop[v]] == r)
        return loop[v];
    else if (loopback[v] != uint.max && remap[loopback[v]] == r)
        return loopback[v];
    else
        return target;
}

package size_t boundEdgeCollapses(const(EdgeAdjacency) adjacency, size_t vertexCount, size_t indexCount, const(ubyte)[] vertexKind) nothrow @nogc {
    size_t dualCount = 0;
    foreach (i; 0 .. vertexCount) {
        ubyte k = vertexKind[i];
        uint e = adjacency.offsets[i + 1] - adjacency.offsets[i];
        dualCount += (k == VertexKind.manifold || k == VertexKind.seam) ? e : 0;
    }
    assert(dualCount <= indexCount);
    return (indexCount - dualCount / 2) + 3;
}

package size_t pickEdgeCollapses(Collapse[] collapses, size_t collapseCapacity, scope const(uint)[] indices, size_t indexCount, const(uint)[] remap, const(ubyte)[] vertexKind, const(uint)[] loop, const(uint)[] loopback) nothrow @nogc {
    size_t collapseCount = 0;
    static immutable int[3] next = [1, 2, 0];
    for (size_t i = 0; i < indexCount; i += 3) {
        if (collapseCount + 3 > collapseCapacity)
            break;
        foreach (e; 0 .. 3) {
            uint i0 = indices[i + e];
            uint i1 = indices[i + next[e]];
            if (remap[i0] == remap[i1])
                continue;
            ubyte k0 = vertexKind[i0];
            ubyte k1 = vertexKind[i1];
            if ((kCanCollapse[k0][k1] | kCanCollapse[k1][k0]) == 0)
                continue;
            if (kHasOpposite[k0][k1] && remap[i1] > remap[i0])
                continue;
            if ((k0 == VertexKind.border || k0 == VertexKind.seam) && k1 != VertexKind.manifold && loop[i0] != i1)
                continue;
            if ((k1 == VertexKind.border || k1 == VertexKind.seam) && k0 != VertexKind.manifold && loopback[i1] != i0)
                continue;
            Collapse c;
            if ((kCanCollapse[k0][k1] & kCanCollapse[k1][k0]) != 0) {
                c.v0 = i0;
                c.v1 = i1;
                c.bidi = 1;
            } else {
                c.v0 = kCanCollapse[k0][k1] ? i0 : i1;
                c.v1 = kCanCollapse[k0][k1] ? i1 : i0;
                c.bidi = 0;
            }
            collapses[collapseCount++] = c;
        }
    }
    return collapseCount;
}

package void rankEdgeCollapses(Collapse[] collapses, size_t collapseCount, const(Vec3)[] positions, const(float)[] attributes, const(Quadric)[] vertexQuadrics, const(Quadric)[] attributeQuadrics, const(QuadricGrad)[] attributeGradients, size_t attributeCount, const(uint)[] remap, const(uint)[] wedge, const(ubyte)[] vertexKind, const(uint)[] loop, const(uint)[] loopback, bool clamped) nothrow @nogc {
    foreach (i; 0 .. collapseCount) {
        uint i0 = collapses[i].v0;
        uint i1 = collapses[i].v1;
        bool bidi = collapses[i].bidi != 0;
        float ei = quadricError(vertexQuadrics[remap[i0]], positions[i1]);
        float ej = bidi ? quadricError(vertexQuadrics[remap[i1]], positions[i0]) : float.max;
        if (attributeCount) {
            ei += quadricErrorAttr(attributeQuadrics[i0], attributeGradients[i0 * attributeCount .. i0 * attributeCount + attributeCount], attributeCount, positions[i1], attributes[i1 * attributeCount .. i1 * attributeCount + attributeCount], clamped);
            ej += bidi ? quadricErrorAttr(attributeQuadrics[i1], attributeGradients[i1 * attributeCount .. i1 * attributeCount + attributeCount], attributeCount, positions[i0], attributes[i0 * attributeCount .. i0 * attributeCount + attributeCount], clamped) : 0;
            if (vertexKind[i0] == VertexKind.seam) {
                uint s0 = wedge[i0];
                uint s1 = loop[i0] == i1 ? loopback[s0] : loop[s0];
                assert(wedge[s0] == i0);
                assert(s1 != uint.max && remap[s1] == remap[i1]);
                s1 = (s1 != uint.max) ? s1 : wedge[i1];
                ei += quadricErrorAttr(attributeQuadrics[s0], attributeGradients[s0 * attributeCount .. s0 * attributeCount + attributeCount], attributeCount, positions[s1], attributes[s1 * attributeCount .. s1 * attributeCount + attributeCount], clamped);
                ej += bidi ? quadricErrorAttr(attributeQuadrics[s1], attributeGradients[s1 * attributeCount .. s1 * attributeCount + attributeCount], attributeCount, positions[s0], attributes[s0 * attributeCount .. s0 * attributeCount + attributeCount], clamped) : 0;
            } else {
                if (vertexKind[i0] == VertexKind.complex || vertexKind[i0] == VertexKind.fringe) {
                    for (uint v = wedge[i0]; v != i0; v = wedge[v]) {
                        uint t = getComplexTarget(v, i1, remap, loop, loopback);
                        ei += quadricErrorAttr(attributeQuadrics[v], attributeGradients[v * attributeCount .. v * attributeCount + attributeCount], attributeCount, positions[t], attributes[t * attributeCount .. t * attributeCount + attributeCount], clamped);
                    }
                }
                if ((vertexKind[i1] == VertexKind.complex || vertexKind[i1] == VertexKind.fringe) && bidi) {
                    for (uint v = wedge[i1]; v != i1; v = wedge[v]) {
                        uint t = getComplexTarget(v, i0, remap, loop, loopback);
                        ej += quadricErrorAttr(attributeQuadrics[v], attributeGradients[v * attributeCount .. v * attributeCount + attributeCount], attributeCount, positions[t], attributes[t * attributeCount .. t * attributeCount + attributeCount], clamped);
                    }
                }
            }
        }
        bool rev = bidi && (ej < ei);
        collapses[i].v0 = rev ? i1 : i0;
        collapses[i].v1 = rev ? i0 : i1;
        collapses[i].error = ej < ei ? ej : ei;
    }
}

package void orderEdgeCollapses(uint[] sortOrder, const(Collapse)[] collapses, size_t collapseCount, uint[] errorBits) nothrow @nogc {
    foreach (i; 0 .. collapseCount)
        errorBits[i] = collapses[i].errorui;
    sortEdgeCollapses(sortOrder[0 .. collapseCount], errorBits[0 .. collapseCount]);
}

package size_t performEdgeCollapses(uint[] collapseRemap, ubyte[] collapseLocked, const(Collapse)[] collapses, size_t collapseCount, const(uint)[] collapseOrder, const(uint)[] remap, const(uint)[] wedge, const(ubyte)[] vertexKind, const(uint)[] loop, const(uint)[] loopback, const(Vec3)[] positions, const(EdgeAdjacency) adjacency, size_t triangleCollapseGoal, float errorLimit, ref float resultError) nothrow @nogc {
    size_t edgeCollapses = 0;
    size_t triangleCollapses = 0;
    size_t edgeCollapseGoal = triangleCollapseGoal / 2;
    foreach (i; 0 .. collapseCount) {
        Collapse c = collapses[collapseOrder[i]];
        if (c.error > errorLimit)
            break;
        if (triangleCollapses >= triangleCollapseGoal)
            break;
        float errorGoal = edgeCollapseGoal < collapseCount ? 1.5f * collapses[collapseOrder[edgeCollapseGoal]].error : float.max;
        if (c.error > errorGoal && c.error > resultError && triangleCollapses > triangleCollapseGoal / 6)
            break;
        uint i0 = c.v0;
        uint i1 = c.v1;
        uint r0 = remap[i0];
        uint r1 = remap[i1];
        ubyte kind = vertexKind[i0];
        if ((collapseLocked[r0] | collapseLocked[r1]) != 0)
            continue;
        if (hasTriangleFlips(adjacency, positions, collapseRemap, r0, r1)) {
            edgeCollapseGoal++;
            continue;
        }
        assert(collapseRemap[r0] == r0);
        assert(collapseRemap[r1] == r1);
        if (kind == VertexKind.complex || kind == VertexKind.fringe) {
            collapseRemap[i0] = i1;
            for (uint v = wedge[i0]; v != i0; v = wedge[v])
                collapseRemap[v] = getComplexTarget(v, i1, remap, loop, loopback);
        } else if (kind == VertexKind.seam) {
            uint s0 = wedge[i0];
            uint s1 = loop[i0] == i1 ? loopback[s0] : loop[s0];
            assert(wedge[s0] == i0);
            assert(s1 != uint.max && remap[s1] == r1);
            assert(kind != vertexKind[i1] || s1 == wedge[i1]);
            assert(loop[i0] == i1 || loopback[i0] == i1);
            assert(loop[s0] == s1 || loopback[s0] == s1);
            s1 = (s1 != uint.max) ? s1 : wedge[i1];
            collapseRemap[i0] = i1;
            collapseRemap[s0] = s1;
        } else {
            assert(wedge[i0] == i0);
            collapseRemap[i0] = i1;
        }
        collapseLocked[r0] = 1;
        collapseLocked[r1] = 1;
        triangleCollapses += (kind == VertexKind.border) ? 1 : 2;
        edgeCollapses++;
        resultError = resultError < c.error ? c.error : resultError;
    }
    return edgeCollapses;
}

package void updateQuadrics(const(uint)[] collapseRemap, size_t vertexCount, Quadric[] vertexQuadrics, QuadricGrad[] volumeGradients, Quadric[] attributeQuadrics, QuadricGrad[] attributeGradients, size_t attributeCount, const(Vec3)[] positions, const(uint)[] remap, ref float vertexError) nothrow @nogc {
    import engine.meshopt.simplify.quadric : quadricAdd, quadricAddGrad, quadricAddGrads;
    foreach (i; 0 .. vertexCount) {
        if (collapseRemap[i] == i)
            continue;
        uint i0 = asU32(i);
        uint i1 = collapseRemap[i];
        uint r0 = remap[i0];
        uint r1 = remap[i1];
        if (i0 == r0) {
            quadricAdd(vertexQuadrics[r1], vertexQuadrics[r0]);
            if (volumeGradients.length)
                quadricAddGrad(volumeGradients[r1], volumeGradients[r0]);
        }
        if (attributeCount) {
            quadricAdd(attributeQuadrics[i1], attributeQuadrics[i0]);
            quadricAddGrads(attributeGradients[i1 * attributeCount .. i1 * attributeCount + attributeCount], attributeGradients[i0 * attributeCount .. i0 * attributeCount + attributeCount], attributeCount);
            if (i0 == r0) {
                float derr = quadricError(vertexQuadrics[r0], positions[r1]);
                vertexError = vertexError < derr ? derr : vertexError;
            }
        }
    }
}

package size_t remapIndexBuffer(scope uint[] indices, size_t indexCount, const(uint)[] collapseRemap, const(uint)[] remap) nothrow @nogc {
    size_t write = 0;
    for (size_t i = 0; i < indexCount; i += 3) {
        uint v0 = collapseRemap[indices[i + 0]];
        uint v1 = collapseRemap[indices[i + 1]];
        uint v2 = collapseRemap[indices[i + 2]];
        assert(collapseRemap[v0] == v0);
        assert(collapseRemap[v1] == v1);
        assert(collapseRemap[v2] == v2);
        uint r0 = remap[v0];
        uint r1 = remap[v1];
        uint r2 = remap[v2];
        if (r0 != r1 && r0 != r2 && r1 != r2) {
            indices[write + 0] = v0;
            indices[write + 1] = v1;
            indices[write + 2] = v2;
            write += 3;
        }
    }
    return write;
}

package void remapEdgeLoops(uint[] loop, const(uint)[] collapseRemap) nothrow @nogc {
    foreach (i; 0 .. loop.length) {
        if (loop[i] != uint.max) {
            uint l = loop[i];
            uint r = collapseRemap[l];
            if (i == r)
                loop[i] = (loop[l] != uint.max) ? collapseRemap[loop[l]] : uint.max;
            else
                loop[i] = r;
        }
    }
}

package uint follow(uint[] parents, uint index) nothrow @nogc {
    while (index != parents[index]) {
        uint parent = parents[index];
        parents[index] = parents[parent];
        index = parent;
    }
    return index;
}

package size_t buildComponents(uint[] components, scope const(uint)[] indices, size_t indexCount, const(uint)[] remap) nothrow @nogc {
    static immutable int[4] next = [1, 2, 0, 1];
    foreach (i; 0 .. components.length)
        components[i] = asU32(i);
    for (size_t i = 0; i < indexCount; i += 3) {
        foreach (e; 0 .. 3) {
            uint i0 = indices[i + e];
            uint i1 = indices[i + next[e]];
            uint r0 = follow(components, remap[i0]);
            uint r1 = follow(components, remap[i1]);
            if (r0 != r1)
                components[r0 < r1 ? r1 : r0] = r0 < r1 ? r0 : r1;
        }
    }
    foreach (i; 0 .. components.length) {
        if (remap[i] == i)
            components[i] = follow(components, asU32(i));
    }
    uint nextComponent = 0;
    foreach (i; 0 .. components.length) {
        if (remap[i] == i) {
            uint root = components[i];
            assert(root <= i);
            components[i] = (root == i) ? nextComponent++ : components[root];
        } else {
            assert(remap[i] < i);
            components[i] = components[remap[i]];
        }
    }
    return nextComponent;
}

package void measureComponents(float[] componentErrors, size_t componentCount, const(uint)[] components, const(Vec3)[] positions) nothrow @nogc {
    componentErrors[0 .. componentCount * 4] = 0;
    foreach (i; 0 .. positions.length) {
        uint c = components[i];
        assert(c < componentCount);
        Vec3 v = positions[i];
        componentErrors[c * 4 + 0] += v.x;
        componentErrors[c * 4 + 1] += v.y;
        componentErrors[c * 4 + 2] += v.z;
        componentErrors[c * 4 + 3] += 1;
    }
    foreach (i; 0 .. componentCount) {
        float w = componentErrors[i * 4 + 3];
        float iw = w == 0.0f ? 0.0f : 1.0f / w;
        componentErrors[i * 4 + 0] *= iw;
        componentErrors[i * 4 + 1] *= iw;
        componentErrors[i * 4 + 2] *= iw;
        componentErrors[i * 4 + 3] = 0;
    }
    foreach (i; 0 .. positions.length) {
        uint c = components[i];
        float dx = positions[i].x - componentErrors[c * 4 + 0];
        float dy = positions[i].y - componentErrors[c * 4 + 1];
        float dz = positions[i].z - componentErrors[c * 4 + 2];
        float r = dx * dx + dy * dy + dz * dz;
        componentErrors[c * 4 + 3] = componentErrors[c * 4 + 3] < r ? r : componentErrors[c * 4 + 3];
    }
    foreach (i; 0 .. componentCount)
        componentErrors[i] = componentErrors[i * 4 + 3];
}

package size_t pruneComponents(scope uint[] indices, size_t indexCount, const(uint)[] components, const(float)[] componentErrors, float errorCutoff, ref float nextError) nothrow @nogc {
    size_t write = 0;
    float minError = float.max;
    for (size_t i = 0; i < indexCount; i += 3) {
        uint v0 = indices[i + 0], v1 = indices[i + 1], v2 = indices[i + 2];
        uint c = components[v0];
        assert(c == components[v1] && c == components[v2]);
        if (componentErrors[c] > errorCutoff) {
            minError = minError > componentErrors[c] ? componentErrors[c] : minError;
            indices[write + 0] = v0;
            indices[write + 1] = v1;
            indices[write + 2] = v2;
            write += 3;
        }
    }
    nextError = minError;
    return write;
}

package void solvePositions(Vec3[] positions, const(Quadric)[] vertexQuadrics, const(QuadricGrad)[] volumeGradients, const(Quadric)[] attributeQuadrics, const(QuadricGrad)[] attributeGradients, size_t attributeCount, const(uint)[] remap, const(uint)[] wedge, const(EdgeAdjacency) adjacency, const(ubyte)[] vertexKind, const(ubyte)[] vertexUpdate) nothrow @nogc {
    import engine.meshopt.simplify.quadric : quadricAdd, quadricFromPoint, quadricReduceAttributes, quadricSolve;
    foreach (i; 0 .. positions.length) {
        if (!vertexUpdate[i])
            continue;
        if (vertexKind[i] != VertexKind.manifold && vertexKind[i] != VertexKind.complex)
            continue;
        if (remap[i] != i) {
            positions[i] = positions[remap[i]];
            continue;
        }
        Vec3 vp = positions[i];
        Quadric q = vertexQuadrics[i];
        QuadricGrad gv;
        Quadric r;
        quadricFromPoint(r, vp.x, vp.y, vp.z, q.w * 1e-4f);
        quadricAdd(q, r);
        if (attributeCount) {
            uint v = asU32(i);
            do {
                quadricReduceAttributes(q, attributeQuadrics[v], attributeGradients[v * attributeCount .. v * attributeCount + attributeCount], attributeCount);
                v = wedge[v];
            }
            while (v != i);
            if (volumeGradients.length)
                gv = volumeGradients[i];
        }
        Vec3 p;
        if (!quadricSolve(p, q, gv))
            continue;
        float nr = getNeighborhoodRadius(adjacency, positions, asU32(i));
        float dp = (p.x - vp.x) * (p.x - vp.x) + (p.y - vp.y) * (p.y - vp.y) + (p.z - vp.z) * (p.z - vp.z);
        if (dp > nr * nr)
            continue;
        if (hasTriangleFlipsAt(adjacency, positions, asU32(i), p))
            continue;
        if (quadricError(vertexQuadrics[i], p) > quadricError(vertexQuadrics[i], vp) * 1.5f + 1e-6f)
            continue;
        positions[i] = p;
    }
}

package void solveAttributes(Vec3[] positions, float[] attributes, const(Quadric)[] attributeQuadrics, const(QuadricGrad)[] attributeGradients, size_t attributeCount, const(uint)[] remap, const(uint)[] wedge, const(ubyte)[] vertexKind, const(ubyte)[] vertexUpdate) nothrow @nogc {
    foreach (i; 0 .. positions.length) {
        if (!vertexUpdate[i])
            continue;
        if (remap[i] != i)
            continue;
        foreach (k; 0 .. attributeCount) {
            uint sharedWedge = uint.max;
            if (vertexKind[i] == VertexKind.complex || vertexKind[i] == VertexKind.fringe) {
                sharedWedge = asU32(i);
                for (uint v = wedge[i]; v != i; v = wedge[v]) {
                    if (attributes[v * attributeCount + k] != attributes[i * attributeCount + k])
                        sharedWedge = uint.max;
                    else if (sharedWedge != uint.max && attributeQuadrics[v].w > attributeQuadrics[sharedWedge].w)
                        sharedWedge = v;
                }
            }
            uint v = asU32(i);
            do {
                uint r = (sharedWedge == uint.max) ? v : sharedWedge;
                Vec3 p = positions[i];
                Quadric a = attributeQuadrics[r];
                QuadricGrad g = attributeGradients[r * attributeCount + k];
                float iw = a.w == 0 ? 0.0f : 1.0f / a.w;
                float av = (g.gx * p.x + g.gy * p.y + g.gz * p.z + g.gw) * iw;
                attributes[v * attributeCount + k] = av;
                v = wedge[v];
            }
            while (v != i);
        }
    }
}
