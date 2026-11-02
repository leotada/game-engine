// Ported from meshoptimizer v1.3 (src/meshletcodec.cpp), Copyright (c) 2016-2026 Arseny Kapoulkine, MIT License.
/// Meshlet vertex-reference and triangle encoder/decoder. Scalar path.
/// Defined outputs match the upstream SIMD decoder; this module does not
/// write the SIMD tail padding past the requested counts.
module engine.meshopt.codec.meshlet;

import engine.meshopt.internal.bits : unzigzag, zigzag;

@safe:

private enum size_t kMeshletMaxVertices = 256;
private enum size_t kMeshletMaxTriangles = 256;

/// Worst-case encoded size for a meshlet with the given limits.
size_t encodeMeshletBound(size_t maxVertices, size_t maxTriangles) pure nothrow @nogc
in (maxVertices <= kMeshletMaxVertices)
in (maxTriangles <= kMeshletMaxTriangles)
do {
    size_t codesSize = (maxTriangles + 1) / 2;
    size_t extraSize = maxTriangles * 3;
    size_t ctrlSize = (maxVertices + 3) / 4;
    size_t dataSize = (maxVertices + 3) / 4 * 16;
    size_t gapSize = (codesSize + ctrlSize < 16) ? 16 - (codesSize + ctrlSize) : 0;
    return codesSize + extraSize + ctrlSize + dataSize + gapSize;
}

private int rotateTriangle(uint a, uint b, uint c) pure nothrow @nogc {
    return (a > b && a > c) ? 1 : (b > c ? 2 : 0);
}

private int getEdgeFifo8(ref const(uint[2][8]) fifo, uint a, uint b, uint c, size_t offset) pure nothrow @nogc {
    foreach (i; 0 .. 8) {
        size_t index = (offset - 1 - i) & 7;
        uint e0 = fifo[index][0];
        uint e1 = fifo[index][1];
        if (e0 == a && e1 == b)
            return (i << 2) | 0;
        if (e0 == b && e1 == c)
            return (i << 2) | 1;
        if (e0 == c && e1 == a)
            return (i << 2) | 2;
    }
    return -1;
}

private void pushEdgeFifo8(ref uint[2][8] fifo, uint a, uint b, ref size_t offset) pure nothrow @nogc {
    fifo[offset][0] = a;
    fifo[offset][1] = b;
    offset = (offset + 1) & 7;
}

private size_t encodeTriangles(ubyte[] codes, ubyte[] extra, const(ubyte)[] triangles, size_t triangleCount) pure nothrow @nogc {
    uint[2][8] edgefifo;
    foreach (ref slot; edgefifo) {
        slot[0] = uint.max;
        slot[1] = uint.max;
    }
    size_t edgefifooffset = 0;
    uint next = 0;
    size_t codesSize = (triangleCount + 1) / 2;
    codes[0 .. codesSize] = 0;
    static immutable int[5] rotations = [0, 1, 2, 0, 1];
    size_t extraCount = 0;

    foreach (i; 0 .. triangleCount) {
        uint t0 = triangles[i * 3 + 0];
        uint t1 = triangles[i * 3 + 1];
        uint t2 = triangles[i * 3 + 2];
        int fer = getEdgeFifo8(edgefifo, t0, t1, t2, edgefifooffset);
        if (fer >= 0 && (fer >> 2) < 6) {
            int base = fer & 3;
            uint a = triangles[i * 3 + rotations[base + 0]];
            uint b = triangles[i * 3 + rotations[base + 1]];
            uint c = triangles[i * 3 + rotations[base + 2]];
            int fec = 1;
            if (c == next) {
                next++;
                fec = 0;
            }
            uint code = cast(uint)(fer >> 2) * 2 + fec;
            codes[i / 2] |= cast(ubyte)(code << ((i & 1) * 4));
            if (fec)
                extra[extraCount++] = cast(ubyte) c;
            pushEdgeFifo8(edgefifo, c, b, edgefifooffset);
            pushEdgeFifo8(edgefifo, a, c, edgefifooffset);
        } else {
            int rotation = rotateTriangle(t0, t1, t2);
            uint a = triangles[i * 3 + rotations[rotation + 0]];
            uint b = triangles[i * 3 + rotations[rotation + 1]];
            uint c = triangles[i * 3 + rotations[rotation + 2]];
            int fea = 1, feb = 1, fec = 1;
            if (a == next && b == next + 1 && c == next + 2) {
                next++;
                fea = 0;
            }
            if (b == next && c == next + 1) {
                next++;
                feb = 0;
            }
            if (c == next) {
                next++;
                fec = 0;
            }
            uint code = cast(uint)(12 + (fea + feb + fec));
            codes[i / 2] |= cast(ubyte)(code << ((i & 1) * 4));
            if (fea)
                extra[extraCount++] = cast(ubyte) a;
            if (feb)
                extra[extraCount++] = cast(ubyte) b;
            if (fec)
                extra[extraCount++] = cast(ubyte) c;
            pushEdgeFifo8(edgefifo, c, b, edgefifooffset);
            pushEdgeFifo8(edgefifo, a, c, edgefifooffset);
        }
    }
    return extraCount;
}

private size_t encodeVertices(ubyte[] ctrl, ubyte[] data, const(uint)[] vertices) pure nothrow @nogc {
    size_t vertexCount = vertices.length;
    size_t ctrlSize = (vertexCount + 3) / 4;
    ctrl[0 .. ctrlSize] = 0;
    size_t dataCount = 0;
    uint last = uint.max;
    for (size_t i = 0; i < vertexCount; i += 4) {
        uint[4] gv = 0;
        foreach (k; 0 .. 4) {
            if (i + k >= vertexCount)
                break;
            uint d = vertices[i + k] - last - 1;
            gv[k] = zigzag(d);
            last = vertices[i + k];
        }
        bool use4 = (gv[0] | gv[1] | gv[2] | gv[3]) > 0xff_ffff
            || (gv[0] > 0xffff && gv[1] > 0xffff && gv[2] > 0xffff && gv[3] > 0xffff);
        foreach (k; 0 .. 4) {
            uint v = gv[k];
            int code = use4 ? 3 : (v == 0 ? 0 : (v < 256 ? 1 : (v < 65536 ? 2 : 3)));
            if (code > 0)
                data[dataCount++] = cast(ubyte)(v & 0xff);
            if (code > 1)
                data[dataCount++] = cast(ubyte)((v >> 8) & 0xff);
            if (code > 2)
                data[dataCount++] = cast(ubyte)((v >> 16) & 0xff);
            if (use4)
                data[dataCount++] = cast(ubyte)((v >> 24) & 0xff);
            ctrl[i / 4] |= cast(ubyte)(((code & 1) << k) | ((code >> 1) << (k + 4)));
        }
    }
    return dataCount;
}

/**
 * Encode one meshlet. Returns the byte count, or 0 when `buffer` is too small.
 * `triangles.length == triangleCount * 3` local indices. `vertices` are the
 * meshlet's global vertex ids.
 */
size_t encodeMeshlet(scope ubyte[] buffer, scope const(uint)[] vertices, scope const(ubyte)[] triangles) pure nothrow @nogc
in (vertices.length <= kMeshletMaxVertices)
in (triangles.length % 3 == 0)
in (triangles.length / 3 <= kMeshletMaxTriangles)
do {
    size_t vertexCount = vertices.length;
    size_t triangleCount = triangles.length / 3;
    ubyte[kMeshletMaxTriangles / 2] codes;
    ubyte[kMeshletMaxTriangles * 3] extra;
    size_t codesSize = (triangleCount + 1) / 2;
    size_t extraSize = encodeTriangles(codes[], extra[], triangles, triangleCount);

    ubyte[kMeshletMaxVertices / 4] ctrl;
    ubyte[kMeshletMaxVertices * 4] data;
    size_t ctrlSize = (vertexCount + 3) / 4;
    size_t dataSize = encodeVertices(ctrl[], data[], vertices);

    size_t gapSize = (codesSize + ctrlSize < 16) ? 16 - (codesSize + ctrlSize) : 0;
    size_t result = codesSize + extraSize + ctrlSize + dataSize + gapSize;
    if (result > buffer.length)
        return 0;

    size_t at = 0;
    buffer[at .. at + dataSize] = data[0 .. dataSize];
    at += dataSize;
    buffer[at .. at + extraSize] = extra[0 .. extraSize];
    at += extraSize;
    buffer[at .. at + gapSize] = 0;
    at += gapSize;
    buffer[at .. at + ctrlSize] = ctrl[0 .. ctrlSize];
    at += ctrlSize;
    buffer[at .. at + codesSize] = codes[0 .. codesSize];
    return result;
}

private bool takeExtra(ref size_t pos, ref uint next, const(ubyte)[] buffer, ref uint var, int ec) pure nothrow @nogc {
    if (ec) {
        if (pos >= buffer.length)
            return false;
        var = buffer[pos];
        pos++;
    } else {
        var = next;
        next++;
    }
    return true;
}

private int decodePayload(scope ubyte[] vertices, size_t vertexCount, size_t vertexSize, scope ubyte[] triangles, size_t triangleCount, size_t triangleSize, scope const(ubyte)[] buffer) pure nothrow @nogc {
    size_t codesSize = (triangleCount + 1) / 2;
    size_t ctrlSize = (vertexCount + 3) / 4;
    size_t gapSize = (codesSize + ctrlSize < 16) ? 16 - (codesSize + ctrlSize) : 0;
    if (buffer.length < codesSize + ctrlSize + gapSize)
        return -2;

    size_t bound = buffer.length - codesSize - ctrlSize - gapSize;
    const(ubyte)[] ctrl = buffer[bound + gapSize .. bound + gapSize + ctrlSize];
    const(ubyte)[] codes = buffer[buffer.length - codesSize .. $];
    size_t pos = 0;

    uint last = uint.max;
    for (size_t i = 0; i < vertexCount; i += 4) {
        if (pos > bound)
            return -2;
        ubyte code4 = ctrl[i / 4];
        foreach (k; 0 .. 4) {
            int code = ((code4 >> k) & 1) | ((code4 >> (k + 3)) & 2);
            int length = code4 == 0xff ? 4 : code;
            if (pos + cast(size_t) length > buffer.length)
                return -2;
            uint v = 0;
            if (length > 0)
                v |= buffer[pos];
            if (length > 1)
                v |= cast(uint) buffer[pos + 1] << 8;
            if (length > 2)
                v |= cast(uint) buffer[pos + 2] << 16;
            if (length > 3)
                v |= cast(uint) buffer[pos + 3] << 24;
            uint d = unzigzag(v);
            uint r = last + d + 1;
            if (i + k < vertexCount)
                storeVertex(vertices, i + k, vertexSize, r);
            pos += length;
            last = r;
        }
    }

    uint next = 0;
    uint[3] fifo = 0;
    foreach (i; 0 .. triangleCount) {
        if (pos > bound)
            return -2;
        uint code = (codes[i / 2] >> ((i & 1) * 4)) & 0xF;
        uint tri;
        if (code < 12) {
            uint edge = fifo[code / 4];
            edge >>= (code << 3) & 16;
            uint c;
            if (!takeExtra(pos, next, buffer, c, code & 1))
                return -2;
            tri = ((edge & 0xff) << 16) | (edge & 0xff00) | c | (c << 24);
        } else {
            int fea = code > 12;
            int feb = code > 13;
            int fec = code > 14;
            uint a, b, c;
            if (!takeExtra(pos, next, buffer, a, fea))
                return -2;
            if (!takeExtra(pos, next, buffer, b, feb))
                return -2;
            if (!takeExtra(pos, next, buffer, c, fec))
                return -2;
            tri = c | (a << 8) | (b << 16) | (c << 24);
        }
        storeTriangle(triangles, i, triangleSize, tri);
        fifo[2] = fifo[1];
        fifo[1] = fifo[0];
        fifo[0] = tri;
    }
    return pos == bound ? 0 : -3;
}

private void storeVertex(ubyte[] dst, size_t index, size_t vertexSize, uint v) pure nothrow @nogc {
    if (vertexSize == 4) {
        size_t o = index * 4;
        dst[o + 0] = cast(ubyte) v;
        dst[o + 1] = cast(ubyte)(v >> 8);
        dst[o + 2] = cast(ubyte)(v >> 16);
        dst[o + 3] = cast(ubyte)(v >> 24);
    } else {
        ushort s = cast(ushort) v;
        size_t o = index * 2;
        dst[o + 0] = cast(ubyte) s;
        dst[o + 1] = cast(ubyte)(s >> 8);
    }
}

private void storeTriangle(ubyte[] dst, size_t index, size_t triangleSize, uint fifo) pure nothrow @nogc {
    if (triangleSize == 4) {
        uint packed = fifo >> 8;
        size_t o = index * 4;
        dst[o + 0] = cast(ubyte) packed;
        dst[o + 1] = cast(ubyte)(packed >> 8);
        dst[o + 2] = cast(ubyte)(packed >> 16);
        dst[o + 3] = cast(ubyte)(packed >> 24);
    } else {
        size_t o = index * 3;
        dst[o + 0] = cast(ubyte)(fifo >> 8);
        dst[o + 1] = cast(ubyte)(fifo >> 16);
        dst[o + 2] = cast(ubyte)(fifo >> 24);
    }
}

/**
 * Decode a meshlet. `vertexSize` is 2 or 4, `triangleSize` is 3 or 4.
 * Returns 0 on success, -2 when the buffer is truncated, -3 when bytes remain.
 */
int decodeMeshlet(scope ubyte[] vertices, size_t vertexCount, size_t vertexSize, scope ubyte[] triangles, size_t triangleCount, size_t triangleSize, scope const(ubyte)[] buffer) pure nothrow @nogc
in (vertexCount <= kMeshletMaxVertices)
in (triangleCount <= kMeshletMaxTriangles)
in (vertexSize == 2 || vertexSize == 4)
in (triangleSize == 3 || triangleSize == 4)
in (vertices.length >= vertexCount * vertexSize)
in (triangles.length >= triangleCount * triangleSize)
do {
    return decodePayload(vertices, vertexCount, vertexSize, triangles, triangleCount, triangleSize, buffer);
}

/**
 * Decode into 32-bit vertex ids and packed 24-bit triangles (`a | b<<8 | c<<16`).
 * Returns the same codes as `decodeMeshlet`.
 */
int decodeMeshletRaw(scope uint[] vertices, size_t vertexCount, scope uint[] triangles, size_t triangleCount, scope const(ubyte)[] buffer) nothrow @nogc
in (vertexCount <= kMeshletMaxVertices)
in (triangleCount <= kMeshletMaxTriangles)
in (vertices.length >= vertexCount)
in (triangles.length >= triangleCount)
do {
    ubyte[] vbytes = uintBytes(vertices);
    ubyte[] tbytes = uintBytes(triangles);
    return decodePayload(vbytes, vertexCount, 4, tbytes, triangleCount, 4, buffer);
}

private ubyte[] uintBytes(return scope uint[] data) nothrow @nogc @trusted {
    if (data.length == 0)
        return null;
    return (cast(ubyte*) data.ptr)[0 .. data.length * 4];
}

@("meshlet.codec") unittest {
    ubyte[15] triangles = [
        0, 1, 2,
        2, 1, 3,
        3, 5, 4,
        2, 0, 6,
        6, 6, 6,
    ];
    uint[7] vertices = [5, 12, 140, 0, 12389, 123456789, 7];
    size_t bound = encodeMeshletBound(7, 5);
    ubyte[256] enc;
    size_t size = encodeMeshlet(enc[], vertices[], triangles[]);
    assert(size > 0 && size <= bound);
    assert(encodeMeshlet(enc[0 .. size - 1], vertices[], triangles[]) == 0);

    ubyte[7 * 4] rv;
    ubyte[5 * 4] rt;
    assert(decodeMeshlet(rv[], 7, 4, rt[], 5, 4, enc[0 .. size]) == 0);
    foreach (j; 0 .. 7)
        assert(loadU32(rv[], j * 4) == vertices[j]);

    ubyte[5 * 3] rtb;
    assert(decodeMeshlet(rv[], 7, 4, rtb[], 5, 3, enc[0 .. size]) == 0);
    foreach (j; 0 .. 5) {
        uint tri = rtb[j * 3] | (cast(uint) rtb[j * 3 + 1] << 8) | (cast(uint) rtb[j * 3 + 2] << 16);
        uint a = triangles[j * 3], b = triangles[j * 3 + 1], c = triangles[j * 3 + 2];
        uint abc = a | (b << 8) | (c << 16);
        uint bca = b | (c << 8) | (a << 16);
        uint cab = c | (a << 8) | (b << 16);
        assert(tri == abc || tri == bca || tri == cab);
    }

    ushort[8] rvs;
    ubyte[] rvsb = ushortBytes(rvs[]);
    assert(decodeMeshlet(rvsb, 7, 2, rtb[], 5, 3, enc[0 .. size]) == 0);
    foreach (j; 0 .. 7)
        assert(rvs[j] == cast(ushort) vertices[j] || vertices[j] > ushort.max);

    foreach (i; 1 .. size) {
        assert(decodeMeshlet(rv[], 7, 4, rt[], 5, 4, enc[0 .. i]) < 0);
        assert(decodeMeshlet(rv[], 7, 4, rt[], 5, 4, enc[i .. size]) < 0);
    }

    uint[8] rvr;
    uint[8] rtr;
    assert(decodeMeshlet(rv[], 7, 4, rt[], 5, 4, enc[0 .. size]) == 0);
    assert(decodeMeshletRaw(rvr[], 7, rtr[], 5, enc[0 .. size]) == 0);
    assert(rvr[0 .. 7] == vertices[]);
    foreach (j; 0 .. 5)
        assert(rtr[j] == loadU32(rt[], j * 4));

    ubyte[46] encoded = [
        0x0a, 0x0c, 0xfe, 0x19, 0x01, 0xc8, 0x60, 0x00, 0x00, 0x5e, 0x39, 0xb7, 0x0e, 0x1d, 0x9a, 0xb7,
        0x0e, 0x00, 0x00, 0x00, 0x00, 0x04, 0x03, 0x05, 0x02, 0x00, 0x06, 0x06, 0x06, 0x06, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x87, 0xff, 0x2c, 0xff, 0x0f,
    ];
    ubyte[15] basicTri = [
        0, 1, 2,
        2, 1, 3,
        4, 3, 5,
        2, 0, 6,
        6, 6, 6,
    ];
    ubyte[16] basicOut;
    assert(decodeMeshlet(rv[], 7, 4, basicOut[], 5, 3, encoded[]) == 0);
    assert(basicOut[0 .. 15] == basicTri[]);
    foreach (j; 0 .. 7)
        assert(loadU32(rv[], j * 4) == vertices[j]);

    // Round-trip of the published basic buffer must reproduce those bytes when
    // the local indices are already in the encoded order.
    size_t again = encodeMeshlet(enc[], vertices[], basicTri[]);
    assert(again == encoded.length);
    assert(enc[0 .. again] == encoded[]);
}

private uint loadU32(const(ubyte)[] b, size_t at) pure nothrow @nogc {
    return b[at] | (cast(uint) b[at + 1] << 8) | (cast(uint) b[at + 2] << 16) | (cast(uint) b[at + 3] << 24);
}

private ubyte[] ushortBytes(return scope ushort[] data) nothrow @nogc @trusted {
    return (cast(ubyte*) data.ptr)[0 .. data.length * 2];
}
