// Ported from meshoptimizer v1.3 (src/stripifier.cpp), Copyright (c) 2016-2026 Arseny Kapoulkine, MIT License.
/// Triangle strips with optional restart indices, and the inverse unstripify.
module engine.meshopt.stripify;

import engine.meshopt.scratch : MeshoptScratch, defaultScratch;

@safe:

private enum bool isIndex(I) = is(I == uint) || is(I == ushort);

private struct Tri {
    uint a, b, c;
}

private uint triCorner(Tri t, int which) pure nothrow @nogc {
    if (which == 0)
        return t.a;
    if (which == 1)
        return t.b;
    return t.c;
}

private uint findStripFirst(scope const(Tri)[] buffer, scope const(ubyte)[] valence) {
    uint index = 0;
    uint iv = uint.max;
    foreach (i, tri; buffer) {
        ubyte va = valence[tri.a], vb = valence[tri.b], vc = valence[tri.c];
        uint v = (va < vb && va < vc) ? va : (vb < vc ? vb : vc);
        if (v < iv) {
            index = cast(uint) i;
            iv = v;
        }
    }
    return index;
}

private int findStripNext(scope const(Tri)[] buffer, uint e0, uint e1) {
    foreach (i, tri; buffer) {
        uint a = tri.a, b = tri.b, c = tri.c;
        if (e0 == a && e1 == b)
            return (cast(int) i << 2) | 2;
        else if (e0 == b && e1 == c)
            return (cast(int) i << 2) | 0;
        else if (e0 == c && e1 == a)
            return (cast(int) i << 2) | 1;
    }
    return -1;
}

/// Build a triangle strip. `restartIndex == 0` joins strips with degenerate triangles.
size_t stripify(I)(scope I[] destination, scope const(I)[] indices, size_t vertexCount, I restartIndex, ref MeshoptScratch scratch = defaultScratch())
if (isIndex!I) {
    assert(!samePtr(destination, indices));
    assert(indices.length % 3 == 0);
    assert(destination.length >= stripifyBound(indices.length));
    immutable mark = scratch.mark();
    scope (exit)
        scratch.release(mark);

    enum bufferCapacity = 8;
    Tri[bufferCapacity] buffer;
    uint bufferSize = 0;
    size_t indexOffset = 0;
    uint[2] strip;
    uint parity = 0;
    size_t stripSize = 0;

    ubyte[] valence = scratch.allocate!ubyte(vertexCount);
    valence[] = 0;
    foreach (index; indices) {
        uint id = index;
        assert(id < vertexCount);
        valence[id]++;
    }

    int next = -1;
    while (bufferSize > 0 || indexOffset < indices.length) {
        assert(next < 0 || (cast(size_t)(next >> 2) < bufferSize && (next & 3) < 3));
        while (bufferSize < bufferCapacity && indexOffset < indices.length) {
            buffer[bufferSize].a = indices[indexOffset + 0];
            buffer[bufferSize].b = indices[indexOffset + 1];
            buffer[bufferSize].c = indices[indexOffset + 2];
            bufferSize++;
            indexOffset += 3;
        }
        assert(bufferSize > 0);
        if (next >= 0) {
            uint i = cast(uint) next >> 2;
            uint a = buffer[i].a, b = buffer[i].b, c = buffer[i].c;
            uint v = triCorner(buffer[i], next & 3);
            foreach (k; i .. bufferSize - 1)
                buffer[k] = buffer[k + 1];
            bufferSize--;
            valence[a]--;
            valence[b]--;
            valence[c]--;
            int cont = findStripNext(buffer[0 .. bufferSize], parity ? strip[1] : v, parity ? v : strip[1]);
            int swap = cont < 0 ? findStripNext(buffer[0 .. bufferSize], parity ? v : strip[0], parity ? strip[0] : v) : -1;
            if (cont < 0 && swap >= 0) {
                destination[stripSize++] = cast(I) strip[0];
                destination[stripSize++] = cast(I) v;
                strip[1] = v;
                next = swap;
            } else {
                destination[stripSize++] = cast(I) v;
                strip[0] = strip[1];
                strip[1] = v;
                parity ^= 1;
                next = cont;
            }
        } else {
            uint i = findStripFirst(buffer[0 .. bufferSize], valence);
            uint a = buffer[i].a, b = buffer[i].b, c = buffer[i].c;
            foreach (k; i .. bufferSize - 1)
                buffer[k] = buffer[k + 1];
            bufferSize--;
            valence[a]--;
            valence[b]--;
            valence[c]--;
            int ea = findStripNext(buffer[0 .. bufferSize], c, b);
            int eb = findStripNext(buffer[0 .. bufferSize], a, c);
            int ec = findStripNext(buffer[0 .. bufferSize], b, a);
            int mine = int.max;
            mine = (ea >= 0 && mine > ea) ? ea : mine;
            mine = (eb >= 0 && mine > eb) ? eb : mine;
            mine = (ec >= 0 && mine > ec) ? ec : mine;
            if (ea == mine) {
                next = ea;
            } else if (eb == mine) {
                uint t = a;
                a = b;
                b = c;
                c = t;
                next = eb;
            } else if (ec == mine) {
                uint t = c;
                c = b;
                b = a;
                a = t;
                next = ec;
            }
            if (restartIndex) {
                if (stripSize)
                    destination[stripSize++] = restartIndex;
                destination[stripSize++] = cast(I) a;
                destination[stripSize++] = cast(I) b;
                destination[stripSize++] = cast(I) c;
                strip[0] = b;
                strip[1] = c;
                parity = 1;
            } else {
                if (stripSize) {
                    destination[stripSize++] = cast(I) strip[1];
                    destination[stripSize++] = cast(I) a;
                }
                uint e0 = parity ? c : b;
                uint e1 = parity ? b : c;
                destination[stripSize++] = cast(I) a;
                destination[stripSize++] = cast(I) e0;
                destination[stripSize++] = cast(I) e1;
                strip[0] = e0;
                strip[1] = e1;
                parity ^= 1;
            }
        }
    }
    return stripSize;
}

/// Worst-case strip length: 5 indices per triangle.
size_t stripifyBound(size_t indexCount) pure nothrow @nogc {
    assert(indexCount % 3 == 0);
    return (indexCount / 3) * 5;
}

/// Expand a strip back into triangles, dropping degenerates.
size_t unstripify(I)(scope I[] destination, scope const(I)[] indices, I restartIndex)
if (isIndex!I) {
    assert(!samePtr(destination, indices));
    assert(destination.length >= unstripifyBound(indices.length));
    size_t offset = 0;
    size_t start = 0;
    foreach (i; 0 .. indices.length) {
        if (restartIndex && indices[i] == restartIndex) {
            start = i + 1;
        } else if (i - start >= 2) {
            uint a = indices[i - 2], b = indices[i - 1], c = indices[i];
            if ((i - start) & 1) {
                uint t = a;
                a = b;
                b = t;
            }
            if (a != b && a != c && b != c) {
                destination[offset + 0] = cast(I) a;
                destination[offset + 1] = cast(I) b;
                destination[offset + 2] = cast(I) c;
                offset += 3;
            }
        }
    }
    return offset;
}

/// Worst-case triangle index count for a strip of `indexCount` vertices.
size_t unstripifyBound(size_t indexCount) pure nothrow @nogc {
    assert(indexCount == 0 || indexCount >= 3);
    return indexCount == 0 ? 0 : (indexCount - 2) * 3;
}

private bool samePtr(I)(scope const(I)[] a, scope const(I)[] b) nothrow @nogc @trusted {
    return a.length > 0 && a.ptr is b.ptr;
}

@("stripify.bound") unittest {
    assert(stripifyBound(0) == 0);
    assert(stripifyBound(3) == 5);
    assert(unstripifyBound(0) == 0);
    assert(unstripifyBound(3) == 3);
    uint[3] ib = [0, 1, 2];
    uint[5] strip;
    size_t n = stripify(strip[], ib[], 3, 0);
    assert(n == 3);
    assert(strip[0 .. 3] == [0, 1, 2]);
    uint[3] back;
    assert(unstripify(back[], strip[0 .. n], 0) == 3);
    assert(back[] == ib[]);
}
