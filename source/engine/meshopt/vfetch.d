// Ported from meshoptimizer v1.3 (src/vfetchoptimizer.cpp), Copyright (c) 2016-2026 Arseny Kapoulkine, MIT License.
/// Reorder vertices into the order they are first fetched by the index buffer.
module engine.meshopt.vfetch;

import engine.meshopt.scratch : MeshoptScratch, defaultScratch;

@safe:

private enum bool isIndex(I) = is(I == uint) || is(I == ushort);

/// Remap old vertices to first-use order. Unreferenced vertices stay `uint.max`.
size_t optimizeVertexFetchRemap(I)(scope uint[] destination, scope const(I)[] indices, size_t vertexCount)
if (isIndex!I) {
    assert(destination.length >= vertexCount);
    destination[0 .. vertexCount] = uint.max;
    uint nextVertex = 0;
    foreach (index; indices) {
        uint id = index;
        assert(id < vertexCount);
        if (destination[id] == uint.max)
            destination[id] = nextVertex++;
    }
    assert(nextVertex <= vertexCount);
    return nextVertex;
}

/// Compact `vertices` into first-use order and rewrite `indices` in place.
size_t optimizeVertexFetch(I)(scope ubyte[] destination, scope I[] indices, scope const(ubyte)[] vertices, size_t vertexCount, size_t vertexSize, ref MeshoptScratch scratch = defaultScratch())
if (isIndex!I) {
    assert(vertexSize > 0 && vertexSize <= 256);
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
    uint[] remap = scratch.allocate!uint(vertexCount);
    remap[] = uint.max;
    uint nextVertex = 0;
    foreach (ref slot; indices) {
        uint index = slot;
        assert(index < vertexCount);
        if (remap[index] == uint.max) {
            copyBlock(dst + cast(ulong) nextVertex * vertexSize, src + cast(ulong) index * vertexSize, vertexSize);
            remap[index] = nextVertex++;
        }
        slot = cast(I) remap[index];
    }
    assert(nextVertex <= vertexCount);
    return nextVertex;
}

/// Typed `optimizeVertexFetch`. `V.sizeof` is the vertex size.
size_t optimizeVertexFetch(V, I)(scope V[] destination, scope I[] indices, scope const(V)[] vertices, ref MeshoptScratch scratch = defaultScratch())
if (isIndex!I && !is(V == ubyte) && V.sizeof > 0 && V.sizeof <= 256) {
    assert(destination.length >= vertices.length);
    return optimizeVertexFetch(typedBytes(destination), indices, typedBytes(vertices), vertices.length, V.sizeof, scratch);
}

private ulong addrOf(scope const(ubyte)[] data) nothrow @nogc @trusted {
    return data.length ? cast(ulong) data.ptr : 0;
}

private void copyBlock(ulong dst, ulong src, size_t n) nothrow @nogc @trusted {
    if (n == 0)
        return;
    import core.stdc.string : memcpy;
    memcpy(cast(void*) dst, cast(const(void)*) src, n);
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

@("optimizeVertexFetch.basic") unittest {
    ubyte[12] vb = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0];
    uint[3] ib = [2, 0, 1];
    ubyte[12] dst;
    size_t n = optimizeVertexFetch(dst[], ib[], vb[], 3, 4);
    assert(n == 3);
    assert(ib[] == [0, 1, 2]);
    assert(dst[0 .. 4] == vb[8 .. 12]);
    assert(dst[4 .. 8] == vb[0 .. 4]);
    assert(dst[8 .. 12] == vb[4 .. 8]);

    uint[3] remap;
    uint[3] src = [2, 0, 1];
    assert(optimizeVertexFetchRemap(remap[], src[], 3) == 3);
    assert(remap[] == [1, 2, 0]);
}
