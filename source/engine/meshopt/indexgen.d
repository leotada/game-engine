// Ported from meshoptimizer v1.3 (src/indexgenerator.cpp), Copyright (c) 2016-2026 Arseny Kapoulkine, MIT License.
/// Vertex remap, reindex, shadow indices, adjacency, tessellation, and provoking vertices.
module engine.meshopt.indexgen;

import engine.meshopt.internal.bits : bitsFloat;
import engine.meshopt.internal.hash : hashBuckets, hashLookup;
import engine.meshopt.scratch : MeshoptScratch, defaultScratch;
import engine.meshopt.types : FloatStream, VertexStream;

@safe:

private enum bool isIndex(I) = is(I == uint) || is(I == ushort);

/// Positions match is enough. `generateVertexRemapCustom` uses this when no extra predicate is given.
bool meshoptPositionsEqual(uint, uint) pure nothrow @nogc {
    return true;
}

private uint loadU32(ulong address) nothrow @nogc @trusted {
    ubyte* p = cast(ubyte*) address;
    return p[0] | (cast(uint) p[1] << 8) | (cast(uint) p[2] << 16) | (cast(uint) p[3] << 24);
}

private float loadFloat(ulong address, size_t floatIndex) nothrow @nogc {
    return bitsFloat(loadU32(address + floatIndex * 4));
}

private uint hashUpdate(uint h, ulong address, size_t len) nothrow @nogc @trusted {
    enum uint m = 0x5bd1e995;
    enum int r = 24;
    ubyte* key = cast(ubyte*) address;
    while (len >= 4) {
        uint k = key[0] | (cast(uint) key[1] << 8) | (cast(uint) key[2] << 16) | (cast(uint) key[3] << 24);
        k *= m;
        k ^= k >> r;
        k *= m;
        h *= m;
        h ^= k;
        key += 4;
        len -= 4;
    }
    if (len > 0) {
        uint tail = key[0] | (cast(uint) key[len / 2] << 8) | (cast(uint) key[len - 1] << 16);
        h ^= tail;
        h *= m;
        h ^= h >> r;
    }
    return h;
}

private bool bytesEqual(ulong a, ulong b, size_t n) nothrow @nogc @trusted {
    if (n == 0)
        return true;
    import core.stdc.string : memcmp;
    return memcmp(cast(const(void)*) a, cast(const(void)*) b, n) == 0;
}

private void copyBlock(ulong dst, ulong src, size_t n) nothrow @nogc @trusted {
    if (n == 0)
        return;
    import core.stdc.string : memcpy;
    memcpy(cast(void*) dst, cast(const(void)*) src, n);
}

private ulong addrOf(scope const(ubyte)[] data) nothrow @nogc @trusted {
    return data.length ? cast(ulong) data.ptr : 0;
}

private struct VertexHasher {
    ulong address;
    size_t vertexSize;
    size_t vertexStride;

    size_t hash(uint index) const nothrow @nogc {
        return hashUpdate(0, address + cast(ulong) index * vertexStride, vertexSize);
    }

    bool equal(uint lhs, uint rhs) const nothrow @nogc {
        return bytesEqual(address + cast(ulong) lhs * vertexStride, address + cast(ulong) rhs * vertexStride, vertexSize);
    }
}

private struct VertexStreamHasher {
    VertexStream[16] streams;
    size_t streamCount;

    size_t hash(uint index) const nothrow @nogc {
        uint h = 0;
        foreach (i; 0 .. streamCount) {
            VertexStream s = streams[i];
            h = hashUpdate(h, s.address + cast(ulong) index * s.stride, s.size);
        }
        return h;
    }

    bool equal(uint lhs, uint rhs) const nothrow @nogc {
        foreach (i; 0 .. streamCount) {
            VertexStream s = streams[i];
            if (!bytesEqual(s.address + cast(ulong) lhs * s.stride, s.address + cast(ulong) rhs * s.stride, s.size))
                return false;
        }
        return true;
    }
}

private struct VertexCustomHasher(alias pred) {
    ulong address;
    size_t strideFloats;

    size_t hash(uint index) const nothrow @nogc {
        uint x = loadU32(address + (cast(ulong) index * strideFloats + 0) * 4);
        uint y = loadU32(address + (cast(ulong) index * strideFloats + 1) * 4);
        uint z = loadU32(address + (cast(ulong) index * strideFloats + 2) * 4);
        // replace negative zero with zero
        x = (x == 0x8000_0000) ? 0 : x;
        y = (y == 0x8000_0000) ? 0 : y;
        z = (z == 0x8000_0000) ? 0 : z;
        // scramble bits so integer coordinates have entropy in the low bits
        x ^= x >> 17;
        y ^= y >> 17;
        z ^= z >> 17;
        // Optimized Spatial Hashing for Collision Detection of Deformable Objects
        return (x * 73856093u) ^ (y * 19349663u) ^ (z * 83492791u);
    }

    bool equal(uint lhs, uint rhs) const nothrow @nogc {
        float lx = loadFloat(address, cast(ulong) lhs * strideFloats + 0);
        float ly = loadFloat(address, cast(ulong) lhs * strideFloats + 1);
        float lz = loadFloat(address, cast(ulong) lhs * strideFloats + 2);
        float rx = loadFloat(address, cast(ulong) rhs * strideFloats + 0);
        float ry = loadFloat(address, cast(ulong) rhs * strideFloats + 1);
        float rz = loadFloat(address, cast(ulong) rhs * strideFloats + 2);
        if (lx != rx || ly != ry || lz != rz)
            return false;
        return pred(lhs, rhs);
    }
}

private struct TriangleKey {
    uint a;
    uint b;
    uint c;

    bool opEquals(const TriangleKey rhs) const pure nothrow @nogc {
        return a == rhs.a && b == rhs.b && c == rhs.c;
    }
}

private struct TriangleKeyHasher {
    size_t hash(TriangleKey k) const pure nothrow @nogc {
        return (k.a * 73856093u) ^ (k.b * 19349663u) ^ (k.c * 83492791u);
    }

    bool equal(TriangleKey lhs, TriangleKey rhs) const pure nothrow @nogc {
        return lhs == rhs;
    }
}

private struct EdgeHasher {
    ulong remapAddress;

    uint at(uint index) const nothrow @nogc {
        return loadU32(remapAddress + cast(ulong) index * 4);
    }

    size_t hash(ulong edge) const nothrow @nogc {
        uint e0 = cast(uint)(edge >> 32);
        uint e1 = cast(uint) edge;
        uint h1 = at(e0);
        uint h2 = at(e1);
        enum uint m = 0x5bd1e995;
        // MurmurHash64B finalizer
        h1 ^= h2 >> 18;
        h1 *= m;
        h2 ^= h1 >> 22;
        h2 *= m;
        h1 ^= h2 >> 17;
        h1 *= m;
        h2 ^= h1 >> 19;
        h2 *= m;
        return h2;
    }

    bool equal(ulong lhs, ulong rhs) const nothrow @nogc {
        uint l0 = cast(uint)(lhs >> 32);
        uint l1 = cast(uint) lhs;
        uint r0 = cast(uint)(rhs >> 32);
        uint r1 = cast(uint) rhs;
        return at(l0) == at(r0) && at(l1) == at(r1);
    }
}

private uint indexAt(I)(const(I)[] indices, size_t i) {
    return indices[i];
}

private size_t generateRemap(I, Hash)(scope uint[] remap, scope const(I)[] indices, scope ref Hash hasher, ref MeshoptScratch scratch) {
    size_t vertexCount = remap.length;
    remap[] = uint.max;
    size_t tableSize = hashBuckets(vertexCount);
    uint[] table = scratch.allocate!uint(tableSize);
    table[] = uint.max;
    uint nextVertex = 0;
    size_t indexCount = indices.length == 0 ? vertexCount : indices.length;
    foreach (i; 0 .. indexCount) {
        uint index = indices.length == 0 ? cast(uint) i : indexAt(indices, i);
        assert(index < vertexCount);
        if (remap[index] != uint.max)
            continue;
        size_t slot = hashLookup(table, hasher, index, uint.max);
        if (table[slot] == uint.max) {
            table[slot] = index;
            remap[index] = nextVertex++;
        } else {
            assert(remap[table[slot]] != uint.max);
            remap[index] = remap[table[slot]];
        }
    }
    assert(nextVertex <= vertexCount);
    return nextVertex;
}

private void representativeRemap(Hash)(scope uint[] remap, scope ref Hash hasher, ref MeshoptScratch scratch) {
    size_t vertexCount = remap.length;
    size_t tableSize = hashBuckets(vertexCount);
    uint[] table = scratch.allocate!uint(tableSize);
    table[] = uint.max;
    foreach (i; 0 .. vertexCount) {
        uint index = cast(uint) i;
        size_t slot = hashLookup(table, hasher, index, uint.max);
        if (table[slot] == uint.max)
            table[slot] = index;
        remap[index] = table[slot];
    }
}

private void remapVertices(size_t Block)(ulong destination, ulong vertices, size_t vertexCount, size_t vertexSize, scope const(uint)[] remap) {
    size_t blockSize = Block == 0 ? vertexSize : Block;
    assert(blockSize == vertexSize);
    foreach (i; 0 .. vertexCount) {
        uint r = remap[i];
        if (r != uint.max) {
            assert(r < vertexCount);
            copyBlock(destination + cast(ulong) r * blockSize, vertices + cast(ulong) i * blockSize, blockSize);
        }
    }
}

private void generateShadow(I, Hash)(scope I[] destination, scope const(I)[] indices, size_t vertexCount, scope ref Hash hasher, ref MeshoptScratch scratch) {
    uint[] remap = scratch.allocate!uint(vertexCount);
    remap[] = uint.max;
    size_t tableSize = hashBuckets(vertexCount);
    uint[] table = scratch.allocate!uint(tableSize);
    table[] = uint.max;
    foreach (i; 0 .. indices.length) {
        uint index = indexAt(indices, i);
        assert(index < vertexCount);
        if (remap[index] == uint.max) {
            size_t slot = hashLookup(table, hasher, index, uint.max);
            if (table[slot] == uint.max)
                table[slot] = index;
            remap[index] = table[slot];
        }
        destination[i] = cast(I) remap[index];
    }
}

private size_t filterTriangles(I)(scope I[] destination, scope const(I)[] indices, scope const(uint)[] remap, size_t vertexCount, ref MeshoptScratch scratch) {
    TriangleKeyHasher hasher;
    TriangleKey empty = TriangleKey(uint.max, uint.max, uint.max);
    size_t faceCount = indices.length / 3;
    size_t tableSize = hashBuckets(faceCount);
    TriangleKey[] table = scratch.allocate!TriangleKey(tableSize);
    foreach (ref slot; table)
        slot = empty;
    size_t write = 0;
    foreach (i; 0 .. faceCount) {
        uint a = indexAt(indices, i * 3 + 0);
        uint b = indexAt(indices, i * 3 + 1);
        uint c = indexAt(indices, i * 3 + 2);
        assert(a < vertexCount && b < vertexCount && c < vertexCount);
        uint ra = remap[a], rb = remap[b], rc = remap[c];
        if (ra == rb || ra == rc || rb == rc)
            continue;
        // canonicalize, preserving winding
        if (rb < ra && rb < rc) {
            uint t = ra;
            ra = rb;
            rb = rc;
            rc = t;
        } else if (rc < ra && rc < rb) {
            uint t = rc;
            rc = rb;
            rb = ra;
            ra = t;
        }
        TriangleKey key = TriangleKey(ra, rb, rc);
        size_t slot = hashLookup(table, hasher, key, empty);
        if (table[slot].a != uint.max)
            continue;
        table[slot] = key;
        destination[write + 0] = cast(I) a;
        destination[write + 1] = cast(I) b;
        destination[write + 2] = cast(I) c;
        write += 3;
    }
    return write;
}

private void checkStreams(scope const(VertexStream)[] streams) {
    assert(streams.length > 0 && streams.length <= 16);
    foreach (s; streams) {
        assert(s.size > 0 && s.size <= 256);
        assert(s.size <= s.stride);
    }
}

private VertexStreamHasher streamHasher(scope const(VertexStream)[] streams) {
    VertexStreamHasher hasher;
    hasher.streamCount = streams.length;
    foreach (i, s; streams)
        hasher.streams[i] = s;
    return hasher;
}

private void checkFloatStride(size_t strideFloats) {
    size_t stride = strideFloats * 4;
    assert(stride >= 12 && stride <= 256);
}

private size_t bufferBytes(size_t vertexCount, size_t vertexSize, size_t vertexStride) {
    if (vertexCount == 0)
        return 0;
    return (vertexCount - 1) * vertexStride + vertexSize;
}

/**
 * Binary-equivalent vertex remap. `remap.length` is the vertex count.
 * An empty `indices` slice is the unindexed case (`index_count == vertex_count`).
 * Returns the number of unique vertices.
 */
size_t generateVertexRemap(I)(scope uint[] remap, scope const(I)[] indices, scope const(ubyte)[] vertices, size_t vertexSize, ref MeshoptScratch scratch = defaultScratch())
if (isIndex!I) {
    size_t vertexCount = remap.length;
    assert(vertexSize > 0 && vertexSize <= 256);
    // Empty indices select the unindexed case: index count is the vertex count.
    assert(vertices.length >= bufferBytes(vertexCount, vertexSize, vertexSize));
    immutable m = scratch.mark();
    scope (exit)
        scratch.release(m);
    VertexHasher hasher;
    hasher.address = addrOf(vertices);
    hasher.vertexSize = vertexSize;
    hasher.vertexStride = vertexSize;
    return generateRemap(remap, indices, hasher, scratch);
}

/// Typed vertices. `vertex_size` is `V.sizeof` and the buffer is tightly packed.
size_t generateVertexRemap(V, I)(scope uint[] remap, scope const(I)[] indices, scope const(V)[] vertices, ref MeshoptScratch scratch = defaultScratch())
if (isIndex!I && !is(V == ubyte) && V.sizeof > 0 && V.sizeof <= 256) {
    assert(vertices.length == remap.length);
    return generateVertexRemap(remap, indices, typedBytes(vertices), V.sizeof, scratch);
}

/// Same as `generateVertexRemap`, comparing every stream.
size_t generateVertexRemapMulti(I)(scope uint[] remap, scope const(I)[] indices, scope const(VertexStream)[] streams, ref MeshoptScratch scratch = defaultScratch())
if (isIndex!I) {
    checkStreams(streams);
    immutable m = scratch.mark();
    scope (exit)
        scratch.release(m);
    VertexStreamHasher hasher = streamHasher(streams);
    return generateRemap(remap, indices, hasher, scratch);
}

/**
 * Position remap plus a compile-time equality predicate.
 * `pred(lhs, rhs)` is consulted only after the positions match.
 * The default predicate accepts every pair, matching a null C callback.
 */
size_t generateVertexRemapCustom(alias pred = meshoptPositionsEqual, I)(scope uint[] remap, scope const(I)[] indices, FloatStream positions, ref MeshoptScratch scratch = defaultScratch())
if (isIndex!I && is(typeof(pred(uint.init, uint.init)) : bool)) {
    checkFloatStride(positions.strideFloats);
    assert(positions.count == remap.length);
    immutable m = scratch.mark();
    scope (exit)
        scratch.release(m);
    VertexCustomHasher!pred hasher;
    hasher.address = positions.address;
    hasher.strideFloats = positions.strideFloats;
    return generateRemap(remap, indices, hasher, scratch);
}

/// Reorder `vertices` into `destination` with a remap from `generateVertexRemap`.
void remapVertexBuffer(scope ubyte[] destination, scope const(ubyte)[] vertices, size_t vertexCount, size_t vertexSize, scope const(uint)[] remap, ref MeshoptScratch scratch = defaultScratch()) {
    assert(vertexSize > 0 && vertexSize <= 256);
    assert(remap.length >= vertexCount);
    assert(destination.length >= vertexCount * vertexSize);
    assert(vertices.length >= vertexCount * vertexSize);
    immutable m = scratch.mark();
    scope (exit)
        scratch.release(m);
    ulong src = addrOf(vertices);
    ulong dst = addrOf(destination);
    if (vertexCount > 0 && src == dst) {
        ubyte[] copy = scratch.allocate!ubyte(vertexCount * vertexSize);
        copyBlock(addrOf(copy), src, vertexCount * vertexSize);
        src = addrOf(copy);
    }
    switch (vertexSize) {
    case 4:
        remapVertices!4(dst, src, vertexCount, vertexSize, remap);
        break;
    case 8:
        remapVertices!8(dst, src, vertexCount, vertexSize, remap);
        break;
    case 12:
        remapVertices!12(dst, src, vertexCount, vertexSize, remap);
        break;
    case 16:
        remapVertices!16(dst, src, vertexCount, vertexSize, remap);
        break;
    default:
        remapVertices!0(dst, src, vertexCount, vertexSize, remap);
        break;
    }
}

/// Typed `remapVertexBuffer`.
void remapVertexBuffer(V)(scope V[] destination, scope const(V)[] vertices, scope const(uint)[] remap, ref MeshoptScratch scratch = defaultScratch())
if (!is(V == ubyte) && V.sizeof > 0 && V.sizeof <= 256) {
    remapVertexBuffer(typedBytes(destination), typedBytes(vertices), vertices.length, V.sizeof, remap, scratch);
}

/// Apply `remap` to indices. An empty `indices` slice is the unindexed case.
void remapIndexBuffer(I)(scope I[] destination, scope const(I)[] indices, scope const(uint)[] remap, ref MeshoptScratch scratch = defaultScratch())
if (isIndex!I) {
    size_t indexCount = indices.length == 0 ? destination.length : indices.length;
    assert(destination.length >= indexCount);
    immutable m = scratch.mark();
    scope (exit)
        scratch.release(m);
    foreach (i; 0 .. indexCount) {
        uint index = indices.length == 0 ? cast(uint) i : indexAt(indices, i);
        assert(index < remap.length);
        assert(remap[index] != uint.max);
        destination[i] = cast(I) remap[index];
    }
}

/// Drop degenerate and duplicate triangles. `vertexStride >= vertexSize` (not required to be a multiple of 4).
size_t filterIndexBuffer(I)(scope I[] destination, scope const(I)[] indices, scope const(ubyte)[] vertices, size_t vertexCount, size_t vertexSize, size_t vertexStride, ref MeshoptScratch scratch = defaultScratch())
if (isIndex!I) {
    assert(indices.length % 3 == 0);
    assert(destination.length >= indices.length);
    assert(vertexSize > 0 && vertexSize <= 256);
    assert(vertexSize <= vertexStride);
    assert(vertices.length >= bufferBytes(vertexCount, vertexSize, vertexStride));
    immutable m = scratch.mark();
    scope (exit)
        scratch.release(m);
    VertexHasher hasher;
    hasher.address = addrOf(vertices);
    hasher.vertexSize = vertexSize;
    hasher.vertexStride = vertexStride;
    uint[] remap = scratch.allocate!uint(vertexCount);
    generateRemap(remap, indices, hasher, scratch);
    return filterTriangles(destination, indices, remap, vertexCount, scratch);
}

/// `filterIndexBuffer` across several streams.
size_t filterIndexBufferMulti(I)(scope I[] destination, scope const(I)[] indices, size_t vertexCount, scope const(VertexStream)[] streams, ref MeshoptScratch scratch = defaultScratch())
if (isIndex!I) {
    assert(indices.length % 3 == 0);
    assert(destination.length >= indices.length);
    checkStreams(streams);
    immutable m = scratch.mark();
    scope (exit)
        scratch.release(m);
    VertexStreamHasher hasher = streamHasher(streams);
    uint[] remap = scratch.allocate!uint(vertexCount);
    generateRemap(remap, indices, hasher, scratch);
    return filterTriangles(destination, indices, remap, vertexCount, scratch);
}

/// Index buffer that welds vertices identical in the given byte range. `vertexStride >= vertexSize`.
void generateShadowIndexBuffer(I)(scope I[] destination, scope const(I)[] indices, scope const(ubyte)[] vertices, size_t vertexCount, size_t vertexSize, size_t vertexStride, ref MeshoptScratch scratch = defaultScratch())
if (isIndex!I) {
    assert(indices.length % 3 == 0);
    assert(destination.length >= indices.length);
    assert(vertexSize > 0 && vertexSize <= 256);
    assert(vertexSize <= vertexStride);
    assert(vertices.length >= bufferBytes(vertexCount, vertexSize, vertexStride));
    immutable m = scratch.mark();
    scope (exit)
        scratch.release(m);
    VertexHasher hasher;
    hasher.address = addrOf(vertices);
    hasher.vertexSize = vertexSize;
    hasher.vertexStride = vertexStride;
    generateShadow(destination, indices, vertexCount, hasher, scratch);
}

/// `generateShadowIndexBuffer` across several streams.
void generateShadowIndexBufferMulti(I)(scope I[] destination, scope const(I)[] indices, size_t vertexCount, scope const(VertexStream)[] streams, ref MeshoptScratch scratch = defaultScratch())
if (isIndex!I) {
    assert(indices.length % 3 == 0);
    assert(destination.length >= indices.length);
    checkStreams(streams);
    immutable m = scratch.mark();
    scope (exit)
        scratch.release(m);
    VertexStreamHasher hasher = streamHasher(streams);
    generateShadow(destination, indices, vertexCount, hasher, scratch);
}

/// For each vertex, the first vertex with an equal position (`-0 == +0`). Not a dense remap.
void generatePositionRemap(scope uint[] destination, FloatStream positions, ref MeshoptScratch scratch = defaultScratch()) {
    checkFloatStride(positions.strideFloats);
    assert(destination.length >= positions.count);
    immutable m = scratch.mark();
    scope (exit)
        scratch.release(m);
    VertexCustomHasher!meshoptPositionsEqual hasher;
    hasher.address = positions.address;
    hasher.strideFloats = positions.strideFloats;
    representativeRemap(destination[0 .. positions.count], hasher, scratch);
}

/// 6 indices per input triangle: vertex, opposite vertex, repeated. Border edges repeat the source vertex.
void generateAdjacencyIndexBuffer(I)(scope I[] destination, scope const(I)[] indices, FloatStream positions, ref MeshoptScratch scratch = defaultScratch())
if (isIndex!I) {
    assert(indices.length % 3 == 0);
    assert(destination.length >= indices.length * 2);
    checkFloatStride(positions.strideFloats);
    size_t vertexCount = positions.count;
    immutable m = scratch.mark();
    scope (exit)
        scratch.release(m);
    static immutable int[4] next = [1, 2, 0, 1];
    uint[] remap = scratch.allocate!uint(vertexCount);
    buildPositionRemap(remap, positions, scratch);
    EdgeHasher edgeHasher;
    edgeHasher.remapAddress = addrOf(typedBytes(remap));
    size_t edgeTableSize = hashBuckets(indices.length);
    ulong[] edgeTable = scratch.allocate!ulong(edgeTableSize);
    uint[] edgeVertex = scratch.allocate!uint(edgeTableSize);
    edgeTable[] = ulong.max;
    edgeVertex[] = uint.max;
    for (size_t i = 0; i < indices.length; i += 3) {
        foreach (e; 0 .. 3) {
            uint i0 = indexAt(indices, i + e);
            uint i1 = indexAt(indices, i + next[e]);
            uint i2 = indexAt(indices, i + next[e + 1]);
            assert(i0 < vertexCount && i1 < vertexCount && i2 < vertexCount);
            ulong edge = (cast(ulong) i0 << 32) | i1;
            size_t slot = hashLookup(edgeTable, edgeHasher, edge, ulong.max);
            if (edgeTable[slot] == ulong.max) {
                edgeTable[slot] = edge;
                edgeVertex[slot] = i2;
            }
        }
    }
    for (size_t i = 0; i < indices.length; i += 3) {
        uint[6] patch;
        foreach (e; 0 .. 3) {
            uint i0 = indexAt(indices, i + e);
            uint i1 = indexAt(indices, i + next[e]);
            assert(i0 < vertexCount && i1 < vertexCount);
            ulong edge = (cast(ulong) i1 << 32) | i0;
            size_t slot = hashLookup(edgeTable, edgeHasher, edge, ulong.max);
            patch[e * 2 + 0] = i0;
            patch[e * 2 + 1] = edgeTable[slot] == ulong.max ? i0 : edgeVertex[slot];
        }
        foreach (k; 0 .. 6)
            destination[i * 2 + k] = cast(I) patch[k];
    }
}

/// 12 indices per input triangle (corners, opposite edges, dominant vertices).
void generateTessellationIndexBuffer(I)(scope I[] destination, scope const(I)[] indices, FloatStream positions, ref MeshoptScratch scratch = defaultScratch())
if (isIndex!I) {
    assert(indices.length % 3 == 0);
    assert(destination.length >= indices.length * 4);
    checkFloatStride(positions.strideFloats);
    size_t vertexCount = positions.count;
    immutable m = scratch.mark();
    scope (exit)
        scratch.release(m);
    static immutable int[3] next = [1, 2, 0];
    uint[] remap = scratch.allocate!uint(vertexCount);
    buildPositionRemap(remap, positions, scratch);
    EdgeHasher edgeHasher;
    edgeHasher.remapAddress = addrOf(typedBytes(remap));
    size_t edgeTableSize = hashBuckets(indices.length);
    ulong[] edgeTable = scratch.allocate!ulong(edgeTableSize);
    edgeTable[] = ulong.max;
    for (size_t i = 0; i < indices.length; i += 3) {
        foreach (e; 0 .. 3) {
            uint i0 = indexAt(indices, i + e);
            uint i1 = indexAt(indices, i + next[e]);
            assert(i0 < vertexCount && i1 < vertexCount);
            ulong edge = (cast(ulong) i0 << 32) | i1;
            size_t slot = hashLookup(edgeTable, edgeHasher, edge, ulong.max);
            if (edgeTable[slot] == ulong.max)
                edgeTable[slot] = edge;
        }
    }
    for (size_t i = 0; i < indices.length; i += 3) {
        uint[12] patch;
        foreach (e; 0 .. 3) {
            uint i0 = indexAt(indices, i + e);
            uint i1 = indexAt(indices, i + next[e]);
            assert(i0 < vertexCount && i1 < vertexCount);
            ulong edge = (cast(ulong) i1 << 32) | i0;
            size_t slot = hashLookup(edgeTable, edgeHasher, edge, ulong.max);
            ulong oppe = edgeTable[slot];
            oppe = (oppe == ulong.max) ? edge : oppe;
            patch[e] = i0;
            patch[3 + e * 2 + 0] = cast(uint) oppe;
            patch[3 + e * 2 + 1] = cast(uint)(oppe >> 32);
            patch[9 + e] = remap[i0];
        }
        foreach (k; 0 .. 12)
            destination[i * 4 + k] = cast(I) patch[k];
    }
}

/**
 * One unique provoking vertex per triangle.
 * `reorder` receives the source vertex for each new index.
 * Returns the number of vertices written to `reorder` (`<= vertexCount + triangleCount`).
 */
size_t generateProvokingIndexBuffer(I)(scope I[] destination, scope uint[] reorder, scope const(I)[] indices, size_t vertexCount, ref MeshoptScratch scratch = defaultScratch())
if (isIndex!I) {
    assert(indices.length % 3 == 0);
    assert(destination.length >= indices.length);
    size_t bound = vertexCount + indices.length / 3;
    assert(reorder.length >= bound);
    assert(bound == 0 || cast(I)(bound - 1) == bound - 1);
    immutable m = scratch.mark();
    scope (exit)
        scratch.release(m);
    uint[] remap = scratch.allocate!uint(vertexCount);
    remap[] = uint.max;
    ubyte[] valence = scratch.allocate!ubyte(vertexCount);
    valence[] = 0;
    foreach (i; 0 .. indices.length) {
        uint index = indexAt(indices, i);
        assert(index < vertexCount);
        valence[index]++;
    }
    uint reorderOffset = 0;
    for (size_t i = 0; i < indices.length; i += 3) {
        uint a = indexAt(indices, i + 0);
        uint b = indexAt(indices, i + 1);
        uint c = indexAt(indices, i + 2);
        assert(a < vertexCount && b < vertexCount && c < vertexCount);
        uint va = remap[a] == uint.max ? valence[a] : uint.max;
        uint vb = remap[b] == uint.max ? valence[b] : uint.max;
        uint vc = remap[c] == uint.max ? valence[c] : uint.max;
        if (vb != uint.max && vb <= va && vb <= vc) {
            uint t = a;
            a = b;
            b = c;
            c = t;
        } else if (vc != uint.max && vc <= va && vc <= vb) {
            uint t = c;
            c = b;
            b = a;
            a = t;
        }
        uint newidx = reorderOffset;
        if (remap[a] == uint.max)
            remap[a] = newidx;
        reorder[reorderOffset++] = a;
        destination[i + 0] = cast(I) newidx;
        destination[i + 1] = cast(I) b;
        destination[i + 2] = cast(I) c;
        valence[a]--;
        valence[b]--;
        valence[c]--;
    }
    uint step = 1;
    for (size_t i = 1; i < indices.length;) {
        uint index = destination[i];
        if (remap[index] == uint.max) {
            uint newidx = reorderOffset;
            remap[index] = newidx;
            reorder[reorderOffset++] = index;
        }
        destination[i] = cast(I) remap[index];
        i += step;
        step ^= 3;
    }
    assert(reorderOffset <= vertexCount + indices.length / 3);
    return reorderOffset;
}

private void buildPositionRemap(scope uint[] remap, FloatStream positions, ref MeshoptScratch scratch) {
    VertexHasher hasher;
    hasher.address = positions.address;
    hasher.vertexSize = 12;
    hasher.vertexStride = positions.strideFloats * 4;
    representativeRemap(remap, hasher, scratch);
}

private ubyte[] typedBytes(V)(return scope V[] data) nothrow @nogc @trusted {
    if (data.length == 0)
        return null;
    return (cast(ubyte*) data.ptr)[0 .. data.length * V.sizeof];
}

private const(ubyte)[] typedBytes(V)(return scope const(V)[] data) nothrow @nogc @trusted {
    if (data.length == 0)
        return null;
    return (cast(const(ubyte)*) data.ptr)[0 .. data.length * V.sizeof];
}

@("remapCustom") unittest {
    static bool yes(uint, uint) {
        return true;
    }

    static bool no(uint, uint) {
        return false;
    }

    float[18] vb = [
        0, 0, 0,
        1, 0, 0,
        0, 1, 0,
        0, 0, 1,
        1, 0, 0,
        0, -0.0f, 1,
    ];
    uint[6] remap;
    FloatStream pos = floatStream(vb[], 3, 6);
    size_t res = generateVertexRemapCustom(remap[], (uint[]).init, pos);
    assert(res == 4);
    foreach (i; 0 .. 4)
        assert(remap[i] == i);
    assert(remap[4] == 1);
    assert(remap[5] == 3);

    res = generateVertexRemapCustom!yes(remap[], (uint[]).init, pos);
    assert(res == 4);
    foreach (i; 0 .. 4)
        assert(remap[i] == i);
    assert(remap[4] == 1);
    assert(remap[5] == 3);

    res = generateVertexRemapCustom!no(remap[], (uint[]).init, pos);
    assert(res == 6);
    foreach (i; 0 .. 6)
        assert(remap[i] == i);
}

@("filterTriangles") unittest {
    uint[15] vb = [
        1, 0, 10,
        2, 0, 20,
        3, 0, 30,
        1, 1, 10,
        1, 1, 99,
    ];
    uint[15] ib = [
        0, 1, 2,
        3, 1, 2,
        4, 1, 2,
        2, 1, 0,
        0, 4, 1,
    ];
    uint[15] sib;
    const(ubyte)[] raw = typedBytes(vb[]);
    size_t slen = filterIndexBuffer(sib[], ib[], raw, 5, 4, 12);
    uint[] expectedS = [0, 1, 2, 2, 1, 0];
    assert(slen == expectedS.length);
    assert(sib[0 .. slen] == expectedS);

    VertexStream[2] streams;
    streams[0] = VertexStream(addrOf(raw), 4, 12);
    streams[1] = VertexStream(addrOf(raw) + 8, 4, 12);
    uint[15] mib;
    size_t mlen = filterIndexBufferMulti(mib[], ib[], 5, streams[]);
    uint[] expectedM = [0, 1, 2, 4, 1, 2, 2, 1, 0, 0, 4, 1];
    assert(mlen == expectedM.length);
    assert(mib[0 .. mlen] == expectedM);
}

@("adjacency") unittest {
    float[18] vb = [0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 1, 0, 1, 0, 0, 0, 1, 0];
    uint[6] ib = [0, 1, 2, 5, 4, 3];
    uint[12] adjib;
    generateAdjacencyIndexBuffer(adjib[], ib[], floatStream(vb[], 3, 6));
    uint[12] expected = [
        0, 0,
        1, 3,
        2, 2,
        5, 0,
        4, 4,
        3, 3,
    ];
    assert(adjib[] == expected[]);
}

@("tessellation") unittest {
    float[18] vb = [0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 1, 0, 1, 0, 0, 0, 1, 0];
    uint[6] ib = [0, 1, 2, 5, 4, 3];
    uint[24] tessib;
    generateTessellationIndexBuffer(tessib[], ib[], floatStream(vb[], 3, 6));
    uint[24] expected = [
        0, 1, 2,
        0, 1,
        4, 5,
        2, 0,
        0, 1, 2,
        5, 4, 3,
        2, 1,
        4, 3,
        3, 5,
        2, 1, 3,
    ];
    assert(tessib[] == expected[]);
}

@("provoking") unittest {
    uint[15] ib = [
        0, 1, 3,
        3, 1, 4,
        1, 2, 4,
        4, 2, 5,
        0, 2, 4,
    ];
    uint[15] pib;
    uint[11] pre;
    size_t res = generateProvokingIndexBuffer(pib[], pre[], ib[], 6);
    uint[15] expectedIb = [
        0, 5, 1,
        1, 4, 0,
        2, 4, 1,
        3, 4, 2,
        4, 5, 2,
    ];
    uint[6] expectedRe = [3, 1, 2, 5, 4, 0];
    assert(res == 6);
    assert(pib[] == expectedIb[]);
    assert(pre[0 .. res] == expectedRe[]);
}

@("generateVertexRemap.basic") unittest {
    ubyte[12] verts = [1, 2, 3, 4, 1, 2, 3, 4, 5, 6, 7, 8];
    uint[3] idx = [0, 1, 2];
    uint[3] remap;
    size_t n = generateVertexRemap(remap[], idx[], verts[], 4);
    assert(n == 2);
    assert(remap[0] == 0 && remap[1] == 0 && remap[2] == 1);

    uint[3] remapU;
    size_t nu = generateVertexRemap(remapU[], (uint[]).init, verts[], 4);
    assert(nu == 2);
    assert(remapU[] == remap[]);

    ushort[3] idx16 = [0, 1, 2];
    uint[3] remap16;
    size_t n16 = generateVertexRemap(remap16[], idx16[], verts[], 4);
    assert(n16 == n && remap16[] == remap[]);

    ubyte[12] dst;
    remapVertexBuffer(dst[], verts[], 3, 4, remap[]);
    assert(dst[0 .. 4] == verts[0 .. 4]);
    assert(dst[4 .. 8] == verts[8 .. 12]);

    uint[3] ib;
    remapIndexBuffer(ib[], idx[], remap[]);
    assert(ib[] == [0, 0, 1]);

    // in-place vertex remap
    ubyte[12] inplace = verts;
    remapVertexBuffer(inplace[], inplace[], 3, 4, remap[]);
    assert(inplace[0 .. 8] == dst[0 .. 8]);
}

private FloatStream floatStream(return scope const(float)[] data, size_t strideFloats, size_t count) nothrow @nogc @trusted {
    FloatStream s;
    s.strideFloats = strideFloats;
    s.count = count;
    if (count)
        s.address = cast(ulong) data.ptr;
    return s;
}

// Golden payloads (little-endian), after the 52-byte MOPTGLD1 header.
// The params hash is FNV-1a of "<function>/<stem>".
// generateVertexRemap: vc, indexCount (0 = unindexed), vertexSize, unique, indices?, vertices, remap
// remapVertexBuffer: vc, vertexSize, remap, src, dst
// remapIndexBuffer: indexCount (0 = unindexed), vc, remap, indices?, output
// generateVertexRemapCustom: vc, indexCount, strideFloats, pred (0 accept / 1 reject), unique, indices, floats, remap
// filterIndexBuffer: vc, indexCount, size, stride, outCount, indices, vertex bytes, output
// generateShadowIndexBuffer: vc, indexCount, size, stride, indices, vertex bytes, output
// filter/shadow multi: vc, indexCount, streamCount, [outCount if filter], indices, per-stream size/stride/bytes, output
// generatePositionRemap: vc, strideFloats, floats, remap
// adjacency/tessellation: vc, indexCount, strideFloats, indices, floats, output
// generateProvokingIndexBuffer: vc, indexCount, reorderCount, indices, output indices, reorder

@("m1.golden") @trusted unittest {
    import std.file : dirEntries, read, SpanMode;

    string root = "tests/meshopt/golden/";
    string[] names = [
        "generateVertexRemap", "generateVertexRemapMulti", "generateVertexRemapCustom",
        "remapVertexBuffer", "remapIndexBuffer",
        "filterIndexBuffer", "filterIndexBufferMulti",
        "generateShadowIndexBuffer", "generateShadowIndexBufferMulti",
        "generatePositionRemap", "generateAdjacencyIndexBuffer",
        "generateTessellationIndexBuffer", "generateProvokingIndexBuffer",
    ];
    foreach (name; names) {
        int files;
        foreach (entry; dirEntries(root ~ name, SpanMode.shallow)) {
            if (entry.name.length < 4 || entry.name[$ - 4 .. $] != ".bin")
                continue;
            checkM1Golden(name, entry.name, cast(ubyte[]) read(entry.name));
            files++;
        }
        assert(files > 0, name);
    }
}

private void checkM1Golden(string name, string path, const(ubyte)[] file) @trusted {
    import engine.meshopt.quantize : goldenParamsHash;
    import engine.meshopt.types : FloatStream, VertexStream;
    import std.path : baseName, stripExtension;

    assert(file.length >= 52, path);
    assert(file[0 .. 8] == cast(const(ubyte)[]) "MOPTGLD1", path);
    assert(loadU32(file, 8) == 1030, path);
    char[32] gotName;
    gotName[] = cast(char[]) file[12 .. 44];
    char[32] expectName;
    expectName[] = 0;
    expectName[0 .. name.length] = name[];
    assert(gotName == expectName, path);
    string stem = stripExtension(baseName(path));
    assert(loadU32(file, 44) == goldenParamsHash(name ~ "/" ~ stem), path);
    uint nbytes = loadU32(file, 48);
    assert(file.length == 52 + nbytes, path);

    G g;
    g.b = file[52 .. $];

    if (name == "generateVertexRemap") {
        uint vc = g.u32(), ic = g.u32(), size = g.u32(), unique = g.u32();
        uint[] indices = ic ? g.u32s(ic) : null;
        ubyte[] raw = g.bytes(vc * size);
        uint[] expect = g.u32s(vc);
        uint[] remap = new uint[vc];
        size_t n = generateVertexRemap(remap, indices, raw, size);
        assert(n == unique, path);
        expectU(path, remap, expect);
        if (fitsU16(indices)) {
            ushort[] i16 = toU16(indices);
            remap[] = 0;
            size_t n16 = generateVertexRemap(remap, i16, raw, size);
            assert(n16 == unique && remap == expect, path);
        }
    } else if (name == "remapVertexBuffer") {
        uint vc = g.u32(), size = g.u32();
        uint[] remap = g.u32s(vc);
        ubyte[] src = g.bytes(vc * size);
        ubyte[] expect = g.bytes(vc * size);
        ubyte[] dst = new ubyte[vc * size];
        remapVertexBuffer(dst, src, vc, size, remap);
        assert(dst == expect, path);
    } else if (name == "remapIndexBuffer") {
        uint ic = g.u32(), vc = g.u32();
        uint[] remap = g.u32s(vc);
        uint[] indices = ic ? g.u32s(ic) : null;
        uint outN = ic ? ic : vc;
        uint[] expect = g.u32s(outN);
        uint[] dst = new uint[outN];
        remapIndexBuffer(dst, indices, remap);
        expectU(path, dst, expect);
    } else if (name == "generateVertexRemapMulti") {
        uint vc = g.u32(), ic = g.u32(), nstreams = g.u32(), unique = g.u32();
        uint[] indices = ic ? g.u32s(ic) : null;
        VertexStream[] ss = new VertexStream[nstreams];
        ubyte[][] blobs = new ubyte[][nstreams];
        foreach (s; 0 .. nstreams) {
            uint sz = g.u32(), stride = g.u32();
            blobs[s] = g.bytes(bufferBytes(vc, sz, stride));
            ss[s] = VertexStream(addrOf(blobs[s]), sz, stride);
        }
        uint[] expect = g.u32s(vc);
        uint[] remap = new uint[vc];
        size_t n = generateVertexRemapMulti(remap, indices, ss);
        assert(n == unique, path);
        expectU(path, remap, expect);
    } else if (name == "generateVertexRemapCustom") {
        uint vc = g.u32(), ic = g.u32(), strideFloats = g.u32(), pred = g.u32(), unique = g.u32();
        uint[] indices = g.u32s(ic);
        float[] pos = g.f32s(vc * strideFloats);
        uint[] expect = g.u32s(vc);
        uint[] remap = new uint[vc];
        FloatStream fs = floatStream(pos, strideFloats, vc);
        size_t n = pred == 0
            ? generateVertexRemapCustom(remap, indices, fs)
            : generateVertexRemapCustom!goldenReject(remap, indices, fs);
        assert(n == unique, path);
        expectU(path, remap, expect);
    } else if (name == "filterIndexBuffer" || name == "generateShadowIndexBuffer") {
        uint vc = g.u32(), ic = g.u32(), size = g.u32(), stride = g.u32();
        uint outCount = name == "filterIndexBuffer" ? g.u32() : ic;
        uint[] indices = g.u32s(ic);
        ubyte[] raw = g.bytes(bufferBytes(vc, size, stride));
        uint[] expect = g.u32s(outCount);
        uint[] dst = new uint[ic];
        size_t n = ic;
        if (name == "filterIndexBuffer")
            n = filterIndexBuffer(dst, indices, raw, vc, size, stride);
        else
            generateShadowIndexBuffer(dst, indices, raw, vc, size, stride);
        assert(n == outCount, path);
        expectU(path, dst[0 .. n], expect);
        if (fitsU16(indices)) {
            ushort[] i16 = toU16(indices);
            ushort[] d16 = new ushort[ic];
            size_t n16 = ic;
            if (name == "filterIndexBuffer")
                n16 = filterIndexBuffer(d16, i16, raw, vc, size, stride);
            else
                generateShadowIndexBuffer(d16, i16, raw, vc, size, stride);
            assert(n16 == n, path);
            foreach (i; 0 .. n)
                assert(d16[i] == expect[i], path);
        }
    } else if (name == "filterIndexBufferMulti" || name == "generateShadowIndexBufferMulti") {
        uint vc = g.u32(), ic = g.u32(), streams = g.u32();
        uint outCount = name == "filterIndexBufferMulti" ? g.u32() : ic;
        uint[] indices = g.u32s(ic);
        VertexStream[] ss = new VertexStream[streams];
        ubyte[][] blobs = new ubyte[][streams];
        foreach (s; 0 .. streams) {
            uint sz = g.u32(), stride = g.u32();
            blobs[s] = g.bytes(bufferBytes(vc, sz, stride));
            ss[s] = VertexStream(addrOf(blobs[s]), sz, stride);
        }
        uint[] expect = g.u32s(outCount);
        uint[] dst = new uint[ic];
        size_t n = ic;
        if (name == "filterIndexBufferMulti")
            n = filterIndexBufferMulti(dst, indices, vc, ss);
        else
            generateShadowIndexBufferMulti(dst, indices, vc, ss);
        assert(n == outCount, path);
        expectU(path, dst[0 .. n], expect);
    } else if (name == "generatePositionRemap") {
        uint vc = g.u32(), strideFloats = g.u32();
        float[] pos = g.f32s(vc * strideFloats);
        uint[] expect = g.u32s(vc);
        uint[] dst = new uint[vc];
        generatePositionRemap(dst, floatStream(pos, strideFloats, vc));
        expectU(path, dst, expect);
    } else if (name == "generateAdjacencyIndexBuffer" || name == "generateTessellationIndexBuffer") {
        uint vc = g.u32(), ic = g.u32(), strideFloats = g.u32();
        uint[] indices = g.u32s(ic);
        float[] pos = g.f32s(vc * strideFloats);
        uint outN = name == "generateAdjacencyIndexBuffer" ? ic * 2 : ic * 4;
        uint[] expect = g.u32s(outN);
        uint[] dst = new uint[outN];
        FloatStream fs = floatStream(pos, strideFloats, vc);
        if (name == "generateAdjacencyIndexBuffer")
            generateAdjacencyIndexBuffer(dst, indices, fs);
        else
            generateTessellationIndexBuffer(dst, indices, fs);
        expectU(path, dst, expect);
    } else if (name == "generateProvokingIndexBuffer") {
        uint vc = g.u32(), ic = g.u32(), rn = g.u32();
        uint[] indices = g.u32s(ic);
        uint[] expectI = g.u32s(ic);
        uint[] expectR = g.u32s(rn);
        uint[] dst = new uint[ic];
        uint[] reorder = new uint[vc + ic / 3];
        size_t n = generateProvokingIndexBuffer(dst, reorder, indices, vc);
        assert(n == rn, path);
        expectU(path, dst, expectI);
        expectU(path, reorder[0 .. n], expectR);
    } else {
        assert(0, name);
    }
    g.done();
}

private bool goldenReject(uint, uint) pure nothrow @nogc {
    return false;
}

private bool fitsU16(const(uint)[] indices) {
    foreach (v; indices) {
        if (v > ushort.max)
            return false;
    }
    return true;
}

private ushort[] toU16(const(uint)[] indices) {
    ushort[] o = new ushort[indices.length];
    foreach (i, v; indices)
        o[i] = cast(ushort) v;
    return o;
}

private void expectU(string path, const(uint)[] got, const(uint)[] expect) {
    assert(got.length == expect.length, path);
    foreach (i; 0 .. got.length)
        assert(got[i] == expect[i], path);
}

private struct G {
    const(ubyte)[] b;
    size_t at;

    uint u32() {
        assert(at + 4 <= b.length);
        uint v = b[at] | (cast(uint) b[at + 1] << 8) | (cast(uint) b[at + 2] << 16) | (cast(uint) b[at + 3] << 24);
        at += 4;
        return v;
    }

    uint[] u32s(size_t n) {
        uint[] r = new uint[n];
        foreach (i; 0 .. n)
            r[i] = u32();
        return r;
    }

    ubyte[] bytes(size_t n) {
        assert(at + n <= b.length);
        ubyte[] r = b[at .. at + n].dup;
        at += n;
        return r;
    }

    float[] f32s(size_t n) {
        import engine.meshopt.internal.bits : bitsFloat;
        float[] r = new float[n];
        foreach (i; 0 .. n)
            r[i] = bitsFloat(u32());
        return r;
    }

    void done() {
        assert(at == b.length);
    }
}

private uint loadU32(const(ubyte)[] file, size_t at) {
    return file[at] | (cast(uint) file[at + 1] << 8) | (cast(uint) file[at + 2] << 16) | (cast(uint) file[at + 3] << 24);
}
