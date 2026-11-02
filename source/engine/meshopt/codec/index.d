// Ported from meshoptimizer v1.3 (src/indexcodec.cpp), Copyright (c) 2016-2026 Arseny Kapoulkine, MIT License.
/// Index buffer and index sequence codecs (v0 and v1).
/// Version is an argument of the encoders. There is no process-global setter.
module engine.meshopt.codec.index;

@safe:

private enum ubyte kIndexHeader = 0xe0;
private enum ubyte kSequenceHeader = 0xd0;
private enum int kDecodeIndexVersion = 1;

private static immutable ubyte[16] kCodeAuxEncodingTable = [
    0x00, 0x76, 0x87, 0x56, 0x67, 0x78, 0xa9, 0x86, 0x65, 0x89, 0x68, 0x98, 0x01, 0x69,
    0, 0
];

private static immutable int[6] kRotations = [0, 1, 2, 0, 1];

private int rotateTriangle(uint, uint b, uint c, uint next) pure nothrow @nogc {
    return (b == next) ? 1 : (c == next ? 2 : 0);
}

private int getEdgeFifo(ref uint[2][16] fifo, uint a, uint b, uint c, size_t offset) pure nothrow @nogc {
    foreach (i; 0 .. 16) {
        size_t index = (offset - 1 - i) & 15;
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

private void pushEdgeFifo(ref uint[2][16] fifo, uint a, uint b, ref size_t offset) pure nothrow @nogc {
    fifo[offset][0] = a;
    fifo[offset][1] = b;
    offset = (offset + 1) & 15;
}

private int getVertexFifo(ref uint[16] fifo, uint v, size_t offset) pure nothrow @nogc {
    foreach (i; 0 .. 16) {
        size_t index = (offset - 1 - i) & 15;
        if (fifo[index] == v)
            return i;
    }
    return -1;
}

private void pushVertexFifo(ref uint[16] fifo, uint v, ref size_t offset, int cond = 1) pure nothrow @nogc {
    fifo[offset] = v;
    offset = (offset + cond) & 15;
}

/// Encode a 32-bit value as a 7-bit group varint. `offset` has room for 5 bytes.
private size_t encodeVByte(ubyte[] data, size_t offset, uint v) pure nothrow @nogc {
    do {
        assert(offset < data.length);
        data[offset++] = cast(ubyte)((v & 127) | (v > 127 ? 128 : 0));
        v >>= 7;
    } while (v);
    return offset;
}

/// Decode one varint. Caller guarantees at least 5 readable bytes at `offset`.
private uint decodeVByte(const(ubyte)[] data, ref size_t offset) pure nothrow @nogc {
    assert(offset < data.length);
    ubyte lead = data[offset++];
    if (lead < 128)
        return lead;
    uint result = lead & 127;
    uint shift = 7;
    foreach (_; 0 .. 4) {
        assert(offset < data.length);
        ubyte group = data[offset++];
        result |= (group & 127u) << shift;
        shift += 7;
        if (group < 128)
            break;
    }
    return result;
}

private void encodeIndex(ubyte[] data, ref size_t offset, uint index, uint last) pure nothrow @nogc {
    uint d = index - last;
    uint v = (d << 1) ^ (cast(uint)(cast(int) d >> 31));
    offset = encodeVByte(data, offset, v);
}

private uint decodeIndex(const(ubyte)[] data, ref size_t offset, uint last) pure nothrow @nogc {
    uint v = decodeVByte(data, offset);
    uint d = (v >> 1) ^ cast(uint)(-cast(int)(v & 1));
    return last + d;
}

private int getCodeAuxIndex(ubyte v) pure nothrow @nogc {
    foreach (i; 0 .. 16)
        if (kCodeAuxEncodingTable[i] == v)
            return cast(int) i;
    return -1;
}

private uint loadIndex(I)(const(I)[] indices, size_t i) pure nothrow @nogc {
    return indices[i];
}

/// `c == next ? (next++, 0) : 15` — D rejects a comma expression used as a value.
private int consumeNext(ref uint next, uint index) pure nothrow @nogc {
    if (index == next) {
        next++;
        return 0;
    }
    return 15;
}

/**
 * Encode a triangle list. `version_` is 0 or 1 (default 1).
 * Returns the encoded size, or 0 when `dst` is too small.
 */
size_t encodeIndexBuffer(I)(ubyte[] dst, const(I)[] indices, int version_ = 1) pure nothrow @nogc
if (is(I == uint) || is(I == ushort)) {
    assert(indices.length % 3 == 0);
    assert(version_ >= 0 && version_ <= kDecodeIndexVersion);
    immutable size_t indexCount = indices.length;
    if (dst.length < 1 + indexCount / 3 + 16)
        return 0;

    dst[0] = cast(ubyte)(kIndexHeader | version_);

    uint[2][16] edgefifo;
    uint[16] vertexfifo;
    edgefifo[] = [uint.max, uint.max];
    vertexfifo[] = uint.max;

    size_t edgefifooffset = 0;
    size_t vertexfifooffset = 0;
    uint next = 0;
    uint last = 0;

    size_t code = 1;
    size_t data = code + indexCount / 3;
    immutable size_t dataSafeEnd = dst.length - 16;
    immutable int fecmax = version_ >= 1 ? 13 : 15;

    foreach (i; 0 .. indexCount / 3) {
        if (data > dataSafeEnd)
            return 0;
        uint i0 = loadIndex(indices, i * 3 + 0);
        uint i1 = loadIndex(indices, i * 3 + 1);
        uint i2 = loadIndex(indices, i * 3 + 2);

        int fer = getEdgeFifo(edgefifo, i0, i1, i2, edgefifooffset);
        if (fer >= 0 && (fer >> 2) < 15) {
            immutable int rot = fer & 3;
            uint a = loadIndex(indices, i * 3 + kRotations[rot]);
            uint b = loadIndex(indices, i * 3 + kRotations[rot + 1]);
            uint c = loadIndex(indices, i * 3 + kRotations[rot + 2]);

            int fe = fer >> 2;
            int fc = getVertexFifo(vertexfifo, c, vertexfifooffset);
            int fec = (fc >= 1 && fc < fecmax) ? fc : consumeNext(next, c);

            if (fec == 15 && version_ >= 1) {
                if (c + 1 == last)
                    fec = 13, last = c;
                if (c == last + 1)
                    fec = 14, last = c;
            }

            dst[code++] = cast(ubyte)((fe << 4) | fec);
            if (fec == 15)
                encodeIndex(dst, data, c, last), last = c;
            if (fec == 0 || fec >= fecmax)
                pushVertexFifo(vertexfifo, c, vertexfifooffset);
            pushEdgeFifo(edgefifo, c, b, edgefifooffset);
            pushEdgeFifo(edgefifo, a, c, edgefifooffset);
        } else {
            int rotation = rotateTriangle(i0, i1, i2, next);
            uint a = loadIndex(indices, i * 3 + kRotations[rotation]);
            uint b = loadIndex(indices, i * 3 + kRotations[rotation + 1]);
            uint c = loadIndex(indices, i * 3 + kRotations[rotation + 2]);

            bool reset = false;
            if (a == 0 && b == 1 && c == 2 && next > 0 && version_ >= 1) {
                reset = true;
                next = 0;
                vertexfifo[] = uint.max;
            }

            int fb = getVertexFifo(vertexfifo, b, vertexfifooffset);
            int fc = getVertexFifo(vertexfifo, c, vertexfifooffset);
            int fea = consumeNext(next, a);
            int feb = (fb >= 0 && fb < 14) ? fb + 1 : consumeNext(next, b);
            int fec = (fc >= 0 && fc < 14) ? fc + 1 : consumeNext(next, c);

            ubyte codeaux = cast(ubyte)((feb << 4) | fec);
            int codeauxindex = getCodeAuxIndex(codeaux);

            if (fea == 0 && codeauxindex >= 0 && codeauxindex < 14 && !reset) {
                dst[code++] = cast(ubyte)((15 << 4) | codeauxindex);
            } else {
                dst[code++] = cast(ubyte)((15 << 4) | 14 | fea);
                assert(data < dst.length);
                dst[data++] = codeaux;
            }

            if (fea == 15)
                encodeIndex(dst, data, a, last), last = a;
            if (feb == 15)
                encodeIndex(dst, data, b, last), last = b;
            if (fec == 15)
                encodeIndex(dst, data, c, last), last = c;

            if (fea == 0 || fea == 15)
                pushVertexFifo(vertexfifo, a, vertexfifooffset);
            if (feb == 0 || feb == 15)
                pushVertexFifo(vertexfifo, b, vertexfifooffset);
            if (fec == 0 || fec == 15)
                pushVertexFifo(vertexfifo, c, vertexfifooffset);

            pushEdgeFifo(edgefifo, b, a, edgefifooffset);
            pushEdgeFifo(edgefifo, c, b, edgefifooffset);
            pushEdgeFifo(edgefifo, a, c, edgefifooffset);
        }
    }

    if (data > dataSafeEnd)
        return 0;
    foreach (t; 0 .. 16)
        dst[data++] = kCodeAuxEncodingTable[t];
    assert(data <= dst.length);
    return data;
}

/// Worst-case size of `encodeIndexBuffer` for `indexCount` indices over `vertexCount` vertices.
size_t encodeIndexBufferBound(size_t indexCount, size_t vertexCount) pure nothrow @nogc {
    assert(indexCount % 3 == 0);
    uint vertexBits = 1;
    while (vertexBits < 32 && vertexCount > (size_t(1) << vertexBits))
        vertexBits++;
    uint vertexGroups = (vertexBits + 1 + 6) / 7;
    return 1 + (indexCount / 3) * (2 + 3 * vertexGroups) + 16;
}

/**
 * Header version of an index buffer or sequence, or -1 when the header is not ours.
 */
int decodeIndexVersion(const(ubyte)[] buffer) pure nothrow @nogc {
    if (buffer.length < 1)
        return -1;
    ubyte header = buffer[0];
    if ((header & 0xf0) != kIndexHeader && (header & 0xf0) != kSequenceHeader)
        return -1;
    int version_ = header & 0x0f;
    if (version_ > kDecodeIndexVersion)
        return -1;
    return version_;
}

/**
 * Decode a triangle list produced by `encodeIndexBuffer`.
 * Returns 0 on success, -1 for a bad header, -2 when the buffer is truncated,
 * and -3 when the payload size does not match.
 */
int decodeIndexBuffer(I)(I[] destination, const(ubyte)[] buffer) pure nothrow @nogc @trusted
if (is(I == uint) || is(I == ushort)) {
    // Invariants: writes exactly destination.length indices; reads stay inside buffer
    // because every variable-length read is guarded by `data > dataSafeEnd` (16 bytes remain).
    immutable size_t indexCount = destination.length;
    assert(indexCount % 3 == 0);
    if (buffer.length < 1 + indexCount / 3 + 16)
        return -2;
    if ((buffer[0] & 0xf0) != kIndexHeader)
        return -1;
    int version_ = buffer[0] & 0x0f;
    if (version_ > kDecodeIndexVersion)
        return -1;

    uint[2][16] edgefifo;
    uint[16] vertexfifo;
    edgefifo[] = [uint.max, uint.max];
    vertexfifo[] = uint.max;

    size_t edgefifooffset = 0;
    size_t vertexfifooffset = 0;
    uint next = 0;
    uint last = 0;
    immutable int fecmax = version_ >= 1 ? 13 : 15;

    size_t code = 1;
    immutable size_t codeEnd = code + indexCount / 3;
    size_t data = codeEnd;
    immutable size_t dataSafeEnd = buffer.length - 16;
    I* outp = destination.ptr;

    while (code < codeEnd) {
        ubyte codetri = buffer[code++];
        if (codetri < 0xf0) {
            int fe = codetri >> 4;
            uint a = edgefifo[(edgefifooffset - 1 - fe) & 15][0];
            uint b = edgefifo[(edgefifooffset - 1 - fe) & 15][1];
            uint c = 0;
            int fec = codetri & 15;

            if (fec < fecmax) {
                uint cf = vertexfifo[(vertexfifooffset - 1 - fec) & 15];
                c = (fec == 0) ? next : cf;
                int fec0 = fec == 0;
                next += fec0;
                pushVertexFifo(vertexfifo, c, vertexfifooffset, fec0);
            } else {
                if (data > dataSafeEnd)
                    return -2;
                last = c = (fec != 15) ? last + (fec * 2 - 27) : decodeIndex(buffer, data, last);
                pushVertexFifo(vertexfifo, c, vertexfifooffset);
            }

            pushEdgeFifo(edgefifo, c, b, edgefifooffset);
            pushEdgeFifo(edgefifo, a, c, edgefifooffset);
            outp[0] = cast(I) a;
            outp[1] = cast(I) b;
            outp[2] = cast(I) c;
            outp += 3;
        } else if (codetri < 0xfe) {
            ubyte codeaux = buffer[dataSafeEnd + (codetri & 15)];
            int feb = codeaux >> 4;
            int fec = codeaux & 15;
            uint a = next++;
            uint bf = vertexfifo[(vertexfifooffset - feb) & 15];
            uint b = (feb == 0) ? next : bf;
            int feb0 = feb == 0;
            next += feb0;
            uint cf = vertexfifo[(vertexfifooffset - fec) & 15];
            uint c = (fec == 0) ? next : cf;
            int fec0 = fec == 0;
            next += fec0;

            outp[0] = cast(I) a;
            outp[1] = cast(I) b;
            outp[2] = cast(I) c;
            outp += 3;

            pushVertexFifo(vertexfifo, a, vertexfifooffset);
            pushVertexFifo(vertexfifo, b, vertexfifooffset, feb0);
            pushVertexFifo(vertexfifo, c, vertexfifooffset, fec0);
            pushEdgeFifo(edgefifo, b, a, edgefifooffset);
            pushEdgeFifo(edgefifo, c, b, edgefifooffset);
            pushEdgeFifo(edgefifo, a, c, edgefifooffset);
        } else {
            if (data > dataSafeEnd)
                return -2;
            ubyte codeaux = buffer[data++];
            int fea = codetri == 0xfe ? 0 : 15;
            int feb = codeaux >> 4;
            int fec = codeaux & 15;
            if (codeaux == 0)
                next = 0;

            uint a = (fea == 0) ? next++ : 0;
            uint b = (feb == 0) ? next++ : vertexfifo[(vertexfifooffset - feb) & 15];
            uint c = (fec == 0) ? next++ : vertexfifo[(vertexfifooffset - fec) & 15];

            if (fea == 15)
                last = a = decodeIndex(buffer, data, last);
            if (feb == 15)
                last = b = decodeIndex(buffer, data, last);
            if (fec == 15)
                last = c = decodeIndex(buffer, data, last);

            outp[0] = cast(I) a;
            outp[1] = cast(I) b;
            outp[2] = cast(I) c;
            outp += 3;

            pushVertexFifo(vertexfifo, a, vertexfifooffset);
            pushVertexFifo(vertexfifo, b, vertexfifooffset, (feb == 0) | (feb == 15));
            pushVertexFifo(vertexfifo, c, vertexfifooffset, (fec == 0) | (fec == 15));
            pushEdgeFifo(edgefifo, b, a, edgefifooffset);
            pushEdgeFifo(edgefifo, c, b, edgefifooffset);
            pushEdgeFifo(edgefifo, a, c, edgefifooffset);
        }
    }

    if (data != dataSafeEnd)
        return -3;
    return 0;
}

/// Encode an arbitrary index sequence. `version_` is 0 or 1 (default 1).
size_t encodeIndexSequence(I)(ubyte[] dst, const(I)[] indices, int version_ = 1) pure nothrow @nogc
if (is(I == uint) || is(I == ushort)) {
    assert(version_ >= 0 && version_ <= kDecodeIndexVersion);
    if (dst.length < 1 + indices.length + 4)
        return 0;
    dst[0] = cast(ubyte)(kSequenceHeader | version_);

    uint[2] last = 0;
    uint current = 0;
    size_t data = 1;
    immutable size_t dataSafeEnd = dst.length - 4;

    foreach (i; 0 .. indices.length) {
        if (data >= dataSafeEnd)
            return 0;
        uint index = indices[i];
        int cd = cast(int)(index - last[current]);
        int ad = cd < 0 ? -cd : cd;
        current ^= cast(uint)(ad >= 30);
        uint d = index - last[current];
        uint v = (d << 1) ^ (cast(uint)(cast(int) d >> 31));
        data = encodeVByte(dst, data, (v << 1) | current);
        last[current] = index;
    }
    if (data > dataSafeEnd)
        return 0;
    foreach (_; 0 .. 4)
        dst[data++] = 0;
    return data;
}

/// Worst-case size of `encodeIndexSequence`.
size_t encodeIndexSequenceBound(size_t indexCount, size_t vertexCount) pure nothrow @nogc {
    uint vertexBits = 1;
    while (vertexBits < 32 && vertexCount > (size_t(1) << vertexBits))
        vertexBits++;
    uint vertexGroups = (vertexBits + 1 + 1 + 6) / 7;
    return 1 + indexCount * vertexGroups + 4;
}

/// Decode an index sequence. Same error codes as `decodeIndexBuffer`.
int decodeIndexSequence(I)(I[] destination, const(ubyte)[] buffer) pure nothrow @nogc
if (is(I == uint) || is(I == ushort)) {
    immutable size_t indexCount = destination.length;
    if (buffer.length < 1 + indexCount + 4)
        return -2;
    if ((buffer[0] & 0xf0) != kSequenceHeader)
        return -1;
    int version_ = buffer[0] & 0x0f;
    if (version_ > kDecodeIndexVersion)
        return -1;

    size_t data = 1;
    immutable size_t dataSafeEnd = buffer.length - 4;
    uint[2] last = 0;

    foreach (i; 0 .. indexCount) {
        if (data >= dataSafeEnd)
            return -2;
        uint v = decodeVByte(buffer, data);
        uint current = v & 1;
        v >>= 1;
        uint d = (v >> 1) ^ cast(uint)(-cast(int)(v & 1));
        uint index = last[current] + d;
        last[current] = index;
        destination[i] = cast(I) index;
    }
    if (data != dataSafeEnd)
        return -3;
    return 0;
}

@safe nothrow unittest {
    uint[6] idx = [0, 1, 2, 2, 1, 3];
    ubyte[] enc = new ubyte[encodeIndexBufferBound(idx.length, 4)];
    foreach (ver; 0 .. 2) {
        size_t n = encodeIndexBuffer(enc, idx[], ver);
        assert(n > 0 && n <= enc.length);
        assert(decodeIndexVersion(enc[0 .. n]) == ver);
        uint[6] out_;
        assert(decodeIndexBuffer(out_[], enc[0 .. n]) == 0);
        assert(out_[] == idx[]);
    }
    ushort[6] sidx = [0, 1, 2, 2, 1, 3];
    size_t ns = encodeIndexBuffer(enc, sidx[], 1);
    ushort[6] sout;
    assert(decodeIndexBuffer(sout[], enc[0 .. ns]) == 0);
    assert(sout[] == sidx[]);

    assert(decodeIndexBuffer(idx[], cast(ubyte[])[]) == -2);
    ubyte[1] bad = [0x00];
    assert(decodeIndexVersion(bad[]) == -1);
    assert(decodeIndexBuffer(idx[], bad[]) == -2 || decodeIndexBuffer(idx[], bad[]) == -1);

    uint[8] seq = [0, 1, 2, 5, 5, 4, 100, 100];
    ubyte[] senc = new ubyte[encodeIndexSequenceBound(seq.length, 101)];
    foreach (ver; 0 .. 2) {
        size_t n = encodeIndexSequence(senc, seq[], ver);
        assert(n > 0);
        assert(decodeIndexVersion(senc[0 .. n]) == ver);
        uint[8] out_;
        assert(decodeIndexSequence(out_[], senc[0 .. n]) == 0);
        assert(out_[] == seq[]);
    }

    // A restart (0,1,2) after the stream has moved on, v1 only.
    uint[12] restart = [0, 1, 2, 2, 1, 3, 0, 1, 2, 2, 1, 4];
    ubyte[] renc = new ubyte[encodeIndexBufferBound(restart.length, 5)];
    size_t rn = encodeIndexBuffer(renc, restart[], 1);
    uint[12] rout;
    assert(decodeIndexBuffer(rout[], renc[0 .. rn]) == 0);
    assert(rout[] == restart[]);

    // The codec may rotate a triangle; winding is preserved, vertex order is not.
    // Bytes below are the C++ v1.3 encoding of this strip (encodeIndexVersion 1).
    uint[12] strip = [0, 1, 2, 1, 2, 3, 2, 3, 4, 3, 4, 5];
    ubyte[24] stripCpp = [
        0xe1, 0xf0, 0xfe, 0xfe, 0xfe, 0x21, 0x21, 0x21, 0x00, 0x76, 0x87, 0x56,
        0x67, 0x78, 0xa9, 0x86, 0x65, 0x89, 0x68, 0x98, 0x01, 0x69, 0x00, 0x00
    ];
    ubyte[] stenc = new ubyte[encodeIndexBufferBound(strip.length, 6)];
    size_t sn = encodeIndexBuffer(stenc, strip[], 1);
    assert(sn == stripCpp.length);
    assert(stenc[0 .. sn] == stripCpp[]);
    uint[12] sout2;
    assert(decodeIndexBuffer(sout2[], stenc[0 .. sn]) == 0);
    assert(sout2 == [0u, 1, 2, 3, 1, 2, 4, 2, 3, 5, 3, 4]);
}
