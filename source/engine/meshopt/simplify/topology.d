// Ported from meshoptimizer v1.3 (src/simplifier.cpp), Copyright (c) 2016-2026 Arseny Kapoulkine, MIT License.
/// Edge adjacency, position welding, and vertex-kind classification.
module engine.meshopt.simplify.topology;

import engine.meshopt.internal.bits : bitsFloat, floatBits;
import engine.meshopt.internal.hash : hashBuckets, hashLookup;
import engine.meshopt.scratch : MeshoptScratch;
import engine.meshopt.types : SimplifyOptions, SimplifyVertexFlags;

@safe:

package enum VertexKind : ubyte {
    manifold = 0,
    border = 1,
    seam = 2,
    complex = 3,
    fringe = 4,
    locked = 5,
    count = 6,
}

/// Collapsing kind A into kind B is allowed when the entry is 1.
package immutable ubyte[6][6] kCanCollapse = [
    [1, 1, 1, 1, 1, 1],
    [0, 1, 0, 0, 1, 1],
    [0, 0, 1, 0, 0, 1],
    [0, 0, 0, 1, 1, 1],
    [0, 0, 0, 0, 1, 0],
    [0, 0, 0, 0, 0, 0],
];

/// Manifold and seam edges are emitted twice; the second copy is skipped.
package immutable ubyte[6][6] kHasOpposite = [
    [1, 1, 1, 1, 1, 1],
    [1, 0, 1, 0, 0, 0],
    [1, 1, 1, 0, 0, 1],
    [1, 0, 0, 0, 0, 0],
    [1, 0, 0, 0, 0, 0],
    [1, 0, 1, 0, 0, 0],
];

package struct Edge {
    uint next = 0;
    uint prev = 0;
}

package struct EdgeAdjacency {
    uint[] offsets;
    Edge[] data;
}

package uint asU32(size_t v) pure nothrow @nogc {
    return cast(uint) v;
}

package float loadF(ulong address, size_t floatIndex) nothrow @nogc @trusted {
    ubyte* p = cast(ubyte*)(address + floatIndex * 4);
    uint u = p[0] | (cast(uint) p[1] << 8) | (cast(uint) p[2] << 16) | (cast(uint) p[3] << 24);
    return bitsFloat(u);
}

package uint loadBits(ulong address, size_t floatIndex) nothrow @nogc @trusted {
    ubyte* p = cast(ubyte*)(address + floatIndex * 4);
    return p[0] | (cast(uint) p[1] << 8) | (cast(uint) p[2] << 16) | (cast(uint) p[3] << 24);
}

package void storeF(ulong address, size_t floatIndex, float v) nothrow @nogc @trusted {
    uint u = floatBits(v);
    ubyte* p = cast(ubyte*)(address + floatIndex * 4);
    p[0] = cast(ubyte) u;
    p[1] = cast(ubyte)(u >> 8);
    p[2] = cast(ubyte)(u >> 16);
    p[3] = cast(ubyte)(u >> 24);
}

package bool samePtr(T)(const(T)[] a, const(T)[] b) nothrow @nogc @trusted {
    return a.ptr is b.ptr;
}

package void prepareEdgeAdjacency(ref EdgeAdjacency adjacency, size_t indexCount, size_t vertexCount, ref MeshoptScratch scratch) nothrow @nogc {
    adjacency.offsets = scratch.allocate!uint(vertexCount + 1);
    adjacency.data = scratch.allocate!Edge(indexCount);
}

package void updateEdgeAdjacency(ref EdgeAdjacency adjacency, scope const(uint)[] indices, size_t indexCount, size_t vertexCount, const(uint)[] remap) nothrow @nogc {
    size_t faceCount = indexCount / 3;
    uint[] offsets = adjacency.offsets[1 .. vertexCount + 1];
    Edge[] data = adjacency.data;

    offsets[] = 0;

    foreach (i; 0 .. indexCount) {
        uint v = remap.length ? remap[indices[i]] : indices[i];
        assert(v < vertexCount);
        offsets[v]++;
    }

    uint offset = 0;
    foreach (i; 0 .. vertexCount) {
        uint count = offsets[i];
        offsets[i] = offset;
        offset += count;
    }
    assert(offset == indexCount);

    foreach (i; 0 .. faceCount) {
        uint a = indices[i * 3 + 0];
        uint b = indices[i * 3 + 1];
        uint c = indices[i * 3 + 2];
        if (remap.length) {
            a = remap[a];
            b = remap[b];
            c = remap[c];
        }

        data[offsets[a]].next = b;
        data[offsets[a]].prev = c;
        offsets[a]++;

        data[offsets[b]].next = c;
        data[offsets[b]].prev = a;
        offsets[b]++;

        data[offsets[c]].next = a;
        data[offsets[c]].prev = b;
        offsets[c]++;
    }

    adjacency.offsets[0] = 0;
    assert(adjacency.offsets[vertexCount] == indexCount);
}

private struct PositionHasher {
    ulong address;
    size_t strideFloats;
    const(uint)[] sparse;

    size_t hash(uint index) const scope nothrow @nogc {
        uint ri = sparse.length ? sparse[index] : index;
        uint x = loadBits(address, ri * strideFloats + 0);
        uint y = loadBits(address, ri * strideFloats + 1);
        uint z = loadBits(address, ri * strideFloats + 2);
        if (x == 0x8000_0000)
            x = 0;
        if (y == 0x8000_0000)
            y = 0;
        if (z == 0x8000_0000)
            z = 0;
        x ^= x >> 17;
        y ^= y >> 17;
        z ^= z >> 17;
        return (x * 73_856_093u) ^ (y * 19_349_663u) ^ (z * 83_492_791u);
    }

    bool equal(uint lhs, uint rhs) const scope nothrow @nogc {
        uint li = sparse.length ? sparse[lhs] : lhs;
        uint ri = sparse.length ? sparse[rhs] : rhs;
        return loadF(address, li * strideFloats + 0) == loadF(address, ri * strideFloats + 0)
            && loadF(address, li * strideFloats + 1) == loadF(address, ri * strideFloats + 1)
            && loadF(address, li * strideFloats + 2) == loadF(address, ri * strideFloats + 2);
    }
}

private struct RemapHasher {
    uint[] remap;

    size_t hash(uint id) const scope pure nothrow @nogc {
        return id * 0x5bd1_e995u;
    }

    bool equal(uint lhs, uint rhs) const scope pure nothrow @nogc {
        return remap[lhs] == rhs;
    }
}

/// Forward position remap, and a cyclic wedge list when `wedge` is non-empty.
package void buildPositionRemap(uint[] remap, uint[] wedge, ulong address, size_t strideFloats, const(uint)[] sparse, ref MeshoptScratch scratch) nothrow @nogc {
    size_t vertexCount = remap.length;
    PositionHasher hasher;
    hasher.address = address;
    hasher.strideFloats = strideFloats;
    hasher.sparse = sparse;

    size_t tableSize = hashBuckets(vertexCount);
    size_t mark = scratch.mark();
    uint[] table = scratch.allocate!uint(tableSize);
    table[] = uint.max;

    foreach (i; 0 .. vertexCount) {
        uint index = asU32(i);
        size_t slot = hashLookup(table, hasher, index, uint.max);
        if (table[slot] == uint.max)
            table[slot] = index;
        remap[index] = table[slot];
    }
    scratch.release(mark);

    if (wedge.length == 0)
        return;

    foreach (i; 0 .. vertexCount)
        wedge[i] = asU32(i);

    foreach (i; 0 .. vertexCount) {
        if (remap[i] != i) {
            uint r = remap[i];
            wedge[i] = wedge[r];
            wedge[r] = asU32(i);
        }
    }
}

/// Compact indices to the vertices they reference. Returns dense-to-sparse ids.
package uint[] buildSparseRemap(scope uint[] indices, size_t vertexCount, ref MeshoptScratch scratch) nothrow @nogc {
    ubyte[] filter = scratch.allocate!ubyte((vertexCount + 7) / 8);
    if (filter.length)
        filter[] = 0;

    foreach (i; 0 .. indices.length) {
        uint index = indices[i];
        assert(index < vertexCount);
        filter[index / 8] = 0;
    }

    size_t unique = 0;
    foreach (i; 0 .. indices.length) {
        uint index = indices[i];
        uint bit = 1u << (index % 8);
        if ((filter[index / 8] & bit) == 0)
            unique++;
        filter[index / 8] |= cast(ubyte) bit;
    }

    uint[] remap = scratch.allocate!uint(unique);
    size_t offset = 0;

    size_t revSize = hashBuckets(unique);
    size_t mark = scratch.mark();
    uint[] revremap = scratch.allocate!uint(revSize);
    revremap[] = uint.max;
    RemapHasher hasher;
    hasher.remap = remap;

    foreach (i; 0 .. indices.length) {
        uint index = indices[i];
        size_t slot = hashLookup(revremap, hasher, index, uint.max);
        if (revremap[slot] == uint.max) {
            remap[offset] = index;
            revremap[slot] = asU32(offset);
            offset++;
        }
        indices[i] = revremap[slot];
    }
    scratch.release(mark);

    assert(offset == unique);
    return remap;
}

package bool hasEdge(const(EdgeAdjacency) adjacency, uint a, uint b) nothrow @nogc {
    uint count = adjacency.offsets[a + 1] - adjacency.offsets[a];
    const(Edge)[] edges = adjacency.data[adjacency.offsets[a] .. adjacency.offsets[a] + count];
    foreach (i; 0 .. count) {
        if (edges[i].next == b)
            return true;
    }
    return false;
}

package bool hasEdgeWedge(const(EdgeAdjacency) adjacency, uint a, uint b, const(uint)[] remap, const(uint)[] wedge) nothrow @nogc {
    uint v = a;
    do {
        uint count = adjacency.offsets[v + 1] - adjacency.offsets[v];
        const(Edge)[] edges = adjacency.data[adjacency.offsets[v] .. adjacency.offsets[v] + count];
        foreach (i; 0 .. count) {
            if (remap[edges[i].next] == remap[b])
                return true;
        }
        v = wedge[v];
    }
    while (v != a);
    return false;
}

package uint oppositeVertex(const(EdgeAdjacency) adjacency, uint a, uint b, const(uint)[] remap, const(uint)[] wedge) nothrow @nogc {
    uint v = a;
    uint r = uint.max;
    do {
        uint count = adjacency.offsets[v + 1] - adjacency.offsets[v];
        const(Edge)[] edges = adjacency.data[adjacency.offsets[v] .. adjacency.offsets[v] + count];
        foreach (i; 0 .. count) {
            if (remap[edges[i].next] == remap[b])
                r = (r == uint.max) ? edges[i].prev : a;
        }
        v = wedge[v];
    }
    while (v != a);
    return r == a ? uint.max : r;
}

package void classifyVertices(ubyte[] result, uint[] loop, uint[] loopback, const(EdgeAdjacency) adjacency, const(uint)[] remap, const(uint)[] wedge, scope const(ubyte)[] vertexLock, const(uint)[] sparse, uint options) nothrow @nogc {
    size_t vertexCount = result.length;
    loop[] = uint.max;
    loopback[] = uint.max;

    // Open-edge ids live in the loop arrays until classification finishes.
    uint[] openinc = loopback;
    uint[] openout = loop;

    foreach (i; 0 .. vertexCount) {
        uint vertex = asU32(i);
        uint count = adjacency.offsets[vertex + 1] - adjacency.offsets[vertex];
        const(Edge)[] edges = adjacency.data[adjacency.offsets[vertex] .. adjacency.offsets[vertex] + count];
        foreach (j; 0 .. count) {
            uint target = edges[j].next;
            if (target == vertex) {
                openinc[vertex] = vertex;
                openout[vertex] = vertex;
            } else if (!hasEdge(adjacency, target, vertex)) {
                openinc[target] = (openinc[target] == uint.max) ? vertex : target;
                openout[vertex] = (openout[vertex] == uint.max) ? target : vertex;
            }
        }
    }

    foreach (i; 0 .. vertexCount) {
        if (remap[i] == i) {
            if (wedge[i] == i) {
                uint openi = openinc[i];
                uint openo = openout[i];
                if (openi == uint.max && openo == uint.max)
                    result[i] = VertexKind.manifold;
                else if (openi != uint.max && openo != uint.max && remap[openi] == remap[openo] && openi != i)
                    result[i] = VertexKind.seam;
                else if (openi != i && openo != i)
                    result[i] = VertexKind.border;
                else
                    result[i] = VertexKind.locked;
            } else if (wedge[wedge[i]] == i) {
                uint w = wedge[i];
                uint openiv = openinc[i], openov = openout[i];
                uint openiw = openinc[w], openow = openout[w];
                if (openiv != uint.max && openiv != i && openov != uint.max && openov != i &&
                    openiw != uint.max && openiw != w && openow != uint.max && openow != w &&
                    remap[openiv] == remap[openow] && remap[openov] == remap[openiw] && remap[openiv] != remap[openov])
                    result[i] = VertexKind.seam;
                else
                    result[i] = VertexKind.locked;
            } else {
                result[i] = VertexKind.locked;
            }
        } else {
            assert(remap[i] < i);
            result[i] = result[remap[i]];
        }
    }

    if ((options & SimplifyOptions.permissive) != 0) {
        foreach (i; 0 .. vertexCount) {
            if (result[i] == VertexKind.seam || result[i] == VertexKind.locked) {
                if (remap[i] != i) {
                    result[i] = result[remap[i]];
                    continue;
                }
                bool protect = false;
                uint v = asU32(i);
                do {
                    uint rv = sparse.length ? sparse[v] : v;
                    protect |= vertexLock.length != 0 && (vertexLock[rv] & SimplifyVertexFlags.protect) != 0;
                    v = wedge[v];
                }
                while (v != i);

                bool border = false;
                v = asU32(i);
                do {
                    size_t count = adjacency.offsets[v + 1] - adjacency.offsets[v];
                    const(Edge)[] edges = adjacency.data[adjacency.offsets[v] .. adjacency.offsets[v] + count];
                    foreach (j; 0 .. count)
                        border |= !hasEdgeWedge(adjacency, edges[j].next, v, remap, wedge);
                    v = wedge[v];
                }
                while (v != i);

                result[i] = protect ? result[i] : cast(ubyte)(border ? VertexKind.fringe : VertexKind.complex);
            }
        }
    }

    if (vertexLock.length) {
        foreach (i; 0 .. vertexCount) {
            uint ri = sparse.length ? sparse[i] : asU32(i);
            if ((vertexLock[ri] & SimplifyVertexFlags.lock) != 0)
                result[remap[i]] = VertexKind.locked;
        }
        foreach (i; 0 .. vertexCount) {
            if (result[remap[i]] == VertexKind.locked)
                result[i] = VertexKind.locked;
        }
    }

    if ((options & SimplifyOptions.lockBorder) != 0) {
        foreach (i; 0 .. vertexCount) {
            if (result[i] == VertexKind.border || result[i] == VertexKind.fringe)
                result[i] = VertexKind.locked;
        }
    }
}
