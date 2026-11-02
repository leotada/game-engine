// Ported from meshoptimizer v1.3 (src/vertexcodec.cpp), Copyright (c) 2016-2026 Arseny Kapoulkine, MIT License.
/// Vertex codec, scalar path (upstream SIMD_FALLBACK). Versions v0 and v1, levels 0–3.
/// Version is an argument of the encoder. There is no process-global setter.
module engine.meshopt.codec.vertex;

import engine.meshopt.internal.bits : rotl, unzigzag, zigzag;

@safe:

private enum ubyte kVertexHeader = 0xa0;
private enum int kDecodeVertexVersion = 1;
private enum size_t kVertexBlockSizeBytes = 8192;
private enum size_t kVertexBlockMaxSize = 256;
private enum size_t kByteGroupSize = 16;
private enum size_t kByteGroupDecodeLimit = 24;
private enum size_t kTailMinSizeV0 = 32;
private enum size_t kTailMinSizeV1 = 24;
private enum int kEncodeDefaultLevel = 2;

private static immutable int[4] kBitsV0 = [0, 2, 4, 8];
private static immutable int[5] kBitsV1 = [0, 1, 2, 4, 8];

/// Block size is part of the format. Do not change it.
size_t vertexBlockSize(size_t vertexSize) pure nothrow @nogc {
    size_t result = (kVertexBlockSizeBytes / vertexSize) & ~(kByteGroupSize - 1);
    return result < kVertexBlockMaxSize ? result : kVertexBlockMaxSize;
}

private ubyte reverseBits8(ubyte b) pure nothrow @nogc {
    ulong v = b;
    v = (((v * 0x8020_0802UL) & 0x0884_4221_10UL) * 0x0101_0101_01UL) >> 32;
    return cast(ubyte) v;
}

private bool groupZero(const(ubyte)[] buffer, size_t at) pure nothrow @nogc {
    foreach (i; 0 .. kByteGroupSize)
        if (buffer[at + i] != 0)
            return false;
    return true;
}

private size_t encodeBytesGroupMeasure(const(ubyte)[] buffer, size_t at, int bits) pure nothrow @nogc {
    if (bits == 0)
        return groupZero(buffer, at) ? 0 : size_t.max;
    if (bits == 8)
        return kByteGroupSize;
    size_t result = kByteGroupSize * bits / 8;
    ubyte sentinel = cast(ubyte)((1 << bits) - 1);
    foreach (i; 0 .. kByteGroupSize)
        result += buffer[at + i] >= sentinel;
    return result;
}

private size_t encodeBytesGroup(ubyte[] dst, size_t data, const(ubyte)[] buffer, size_t at, int bits) pure nothrow @nogc {
    if (bits == 0)
        return data;
    if (bits == 8) {
        dst[data .. data + kByteGroupSize] = buffer[at .. at + kByteGroupSize];
        return data + kByteGroupSize;
    }
    size_t byteSize = 8 / bits;
    ubyte sentinel = cast(ubyte)((1 << bits) - 1);
    for (size_t i = 0; i < kByteGroupSize; i += byteSize) {
        ubyte byte_ = 0;
        foreach (k; 0 .. byteSize) {
            ubyte enc = buffer[at + i + k] >= sentinel ? sentinel : buffer[at + i + k];
            byte_ = cast(ubyte)(byte_ << bits);
            byte_ = cast(ubyte)(byte_ | enc);
        }
        if (bits == 1)
            byte_ = reverseBits8(byte_);
        dst[data++] = byte_;
    }
    foreach (i; 0 .. kByteGroupSize) {
        ubyte v = buffer[at + i];
        dst[data] = v;
        data += v >= sentinel;
    }
    return data;
}

private bool encodeBytes(ref size_t data, ubyte[] dst, const(ubyte)[] buffer, scope const(int)[] bits) pure nothrow @nogc {
    assert(buffer.length % kByteGroupSize == 0);
    size_t headerSize = (buffer.length / kByteGroupSize + 3) / 4;
    if (dst.length - data < headerSize)
        return false;
    size_t header = data;
    data += headerSize;
    dst[header .. header + headerSize] = 0;
    int lastBits = -1;
    for (size_t i = 0; i < buffer.length; i += kByteGroupSize) {
        if (dst.length - data < kByteGroupDecodeLimit)
            return false;
        int bestBitk = 3;
        size_t bestSize = encodeBytesGroupMeasure(buffer, i, bits[bestBitk]);
        foreach (bitk; 0 .. 3) {
            size_t size = encodeBytesGroupMeasure(buffer, i, bits[bitk]);
            if (size < bestSize || (size == bestSize && bits[bitk] == lastBits && bits[bestBitk] != 8)) {
                bestBitk = bitk;
                bestSize = size;
            }
        }
        size_t headerOffset = i / kByteGroupSize;
        dst[header + headerOffset / 4] |= cast(ubyte)(bestBitk << ((headerOffset % 4) * 2));
        int bestBits = bits[bestBitk];
        size_t next = encodeBytesGroup(dst, data, buffer, i, bestBits);
        assert(data + bestSize == next);
        data = next;
        lastBits = bestBits;
    }
    return true;
}

private void encodeDeltas1(T, bool Xor)(ubyte[] buffer, const(ubyte)[] vertexData, size_t vertexBase,
        size_t vertexCount, size_t vertexSize, const(ubyte)[] lastVertex, size_t k, int rot) pure nothrow @nogc {
    size_t k0 = k & ~(T.sizeof - 1);
    int ks = cast(int)((k & (T.sizeof - 1)) * 8);
    T p = lastVertex[k0];
    static if (T.sizeof > 1) {
        foreach (j; 1 .. T.sizeof)
            p |= cast(T)(cast(T)(lastVertex[k0 + j]) << (j * 8));
    }
    size_t vertex = vertexBase + k0;
    foreach (i; 0 .. vertexCount) {
        T v = vertexData[vertex];
        static if (T.sizeof > 1) {
            foreach (j; 1 .. T.sizeof)
                v |= cast(T)(cast(T)(vertexData[vertex + j]) << (j * 8));
        }
        T d;
        static if (Xor)
            d = cast(T) rotl(cast(uint)(v ^ p), rot);
        else
            d = zigzag(cast(T)(v - p));
        buffer[i] = cast(ubyte)(d >> ks);
        p = v;
        vertex += vertexSize;
    }
}

private void encodeDeltas(ubyte[] buffer, const(ubyte)[] vertexData, size_t vertexBase,
        size_t vertexCount, size_t vertexSize, const(ubyte)[] lastVertex, size_t k, int channel) pure nothrow @nogc {
    final switch (channel & 3) {
    case 0:
        encodeDeltas1!(ubyte, false)(buffer, vertexData, vertexBase, vertexCount, vertexSize, lastVertex, k, 0);
        break;
    case 1:
        encodeDeltas1!(ushort, false)(buffer, vertexData, vertexBase, vertexCount, vertexSize, lastVertex, k, 0);
        break;
    case 2:
        encodeDeltas1!(uint, true)(buffer, vertexData, vertexBase, vertexCount, vertexSize, lastVertex, k, channel >> 4);
        break;
    case 3:
        assert(0);
    }
}

private int estimateBits(ubyte v) pure nothrow @nogc {
    return v <= 15 ? (v <= 3 ? (v == 0 ? 0 : 2) : 4) : 8;
}

private uint loadU32(const(ubyte)[] data, size_t o) pure nothrow @nogc {
    return data[o] | (cast(uint) data[o + 1] << 8) | (cast(uint) data[o + 2] << 16) | (cast(uint) data[o + 3] << 24);
}

private int estimateRotate(const(ubyte)[] vertexData, size_t vertexCount, size_t vertexSize, size_t k, size_t groupSize) pure nothrow @nogc {
    size_t[8] sizes;
    size_t vertex = k;
    uint last = loadU32(vertexData, vertex);
    for (size_t i = 0; i < vertexCount; i += groupSize) {
        uint bitg = 0;
        for (size_t j = 0; j < groupSize && i + j < vertexCount; ++j) {
            uint v = loadU32(vertexData, vertex);
            uint d = v ^ last;
            bitg |= d;
            last = v;
            vertex += vertexSize;
        }
        foreach (rot; 0 .. 8) {
            uint bitr = rotl(bitg, rot);
            sizes[rot] += estimateBits(cast(ubyte) bitr);
            sizes[rot] += estimateBits(cast(ubyte)(bitr >> 8));
            sizes[rot] += estimateBits(cast(ubyte)(bitr >> 16));
            sizes[rot] += estimateBits(cast(ubyte)(bitr >> 24));
        }
    }
    int best = 0;
    foreach (rot; 1 .. 8)
        if (sizes[rot] < sizes[best])
            best = rot;
    return best;
}

private int estimateChannel(const(ubyte)[] vertexData, size_t vertexCount, size_t vertexSize, size_t k,
        size_t vertexBlock, size_t blockSkip, int maxChannel, int xorRot) pure nothrow @nogc {
    ubyte[kVertexBlockMaxSize] block;
    ubyte[256] lastVertex;
    size_t[3] sizes;
    for (size_t i = 0; i < vertexCount; i += vertexBlock * blockSkip) {
        size_t blockSize = i + vertexBlock < vertexCount ? vertexBlock : vertexCount - i;
        size_t blockAligned = (blockSize + kByteGroupSize - 1) & ~(kByteGroupSize - 1);
        size_t src = (i == 0 ? 0 : i - 1) * vertexSize;
        lastVertex[0 .. vertexSize] = vertexData[src .. src + vertexSize];
        if (blockSize < blockAligned)
            block[blockSize .. blockAligned] = 0;
        foreach (channel; 0 .. maxChannel) {
            foreach (j; 0 .. 4) {
                encodeDeltas(block[], vertexData, i * vertexSize, blockSize, vertexSize, lastVertex[], k + j,
                        channel | (xorRot << 4));
                for (size_t ig = 0; ig < blockSize; ig += kByteGroupSize) {
                    size_t size1 = encodeBytesGroupMeasure(block[], ig, 1);
                    size_t size2 = encodeBytesGroupMeasure(block[], ig, 2);
                    size_t size4 = encodeBytesGroupMeasure(block[], ig, 4);
                    size_t size8 = encodeBytesGroupMeasure(block[], ig, 8);
                    size_t best = size1 < size2 ? size1 : size2;
                    best = best < size4 ? best : size4;
                    best = best < size8 ? best : size8;
                    sizes[channel] += best;
                }
            }
        }
    }
    int bestChannel = 0;
    foreach (channel; 1 .. maxChannel)
        if (sizes[channel] < sizes[bestChannel])
            bestChannel = channel;
    return bestChannel == 2 ? bestChannel | (xorRot << 4) : bestChannel;
}

private bool controlZero(const(ubyte)[] buffer, size_t vertexCountAligned) pure nothrow @nogc {
    for (size_t i = 0; i < vertexCountAligned; i += kByteGroupSize)
        if (!groupZero(buffer, i))
            return false;
    return true;
}

private int estimateControl(const(ubyte)[] buffer, size_t vertexCount, size_t vertexCountAligned, int level) pure nothrow @nogc {
    if (controlZero(buffer, vertexCountAligned))
        return 2;
    if (level == 0)
        return 1;
    size_t headerSize = (vertexCountAligned / kByteGroupSize + 3) / 4;
    size_t est0 = headerSize, est1 = headerSize;
    for (size_t i = 0; i < vertexCountAligned; i += kByteGroupSize) {
        size_t size0 = encodeBytesGroupMeasure(buffer, i, 0);
        size_t size1 = encodeBytesGroupMeasure(buffer, i, 1);
        size_t size2 = encodeBytesGroupMeasure(buffer, i, 2);
        size_t size4 = encodeBytesGroupMeasure(buffer, i, 4);
        size_t size8 = encodeBytesGroupMeasure(buffer, i, 8);
        size_t size12 = size1 < size2 ? size1 : size2;
        size_t size124 = size12 < size4 ? size12 : size4;
        est0 += size124 < size0 ? size124 : size0;
        est1 += size124 < size8 ? size124 : size8;
    }
    if (est0 < vertexCount || est1 < vertexCount)
        return est0 < est1 ? 0 : 1;
    return 3;
}

private bool encodeVertexBlock(ref size_t data, ubyte[] dst, const(ubyte)[] vertexData, size_t vertexBase,
        size_t vertexCount, size_t vertexSize, ubyte[] lastVertex, const(ubyte)[] channels, int version_, int level) pure nothrow @nogc {
    assert(vertexCount > 0 && vertexCount <= kVertexBlockMaxSize);
    ubyte[kVertexBlockMaxSize] buffer;
    size_t vertexCountAligned = (vertexCount + kByteGroupSize - 1) & ~(kByteGroupSize - 1);
    buffer[] = 0;
    size_t controlSize = version_ == 0 ? 0 : vertexSize / 4;
    if (dst.length - data < controlSize)
        return false;
    size_t control = data;
    data += controlSize;
    if (controlSize)
        dst[control .. control + controlSize] = 0;

    foreach (k; 0 .. vertexSize) {
        int chan = version_ == 0 ? 0 : channels[k / 4];
        encodeDeltas(buffer[], vertexData, vertexBase, vertexCount, vertexSize, lastVertex, k, chan);
        int ctrl = 0;
        if (version_ != 0) {
            ctrl = estimateControl(buffer[0 .. vertexCountAligned], vertexCount, vertexCountAligned, level);
            dst[control + k / 4] |= cast(ubyte)(ctrl << ((k % 4) * 2));
        }
        if (ctrl == 3) {
            if (dst.length - data < vertexCount)
                return false;
            dst[data .. data + vertexCount] = buffer[0 .. vertexCount];
            data += vertexCount;
        } else if (ctrl != 2) {
            scope const(int)[] bits = version_ == 0 ? kBitsV0[] : kBitsV1[ctrl .. ctrl + 4];
            if (!encodeBytes(data, dst, buffer[0 .. vertexCountAligned], bits))
                return false;
        }
    }
    size_t last = vertexBase + vertexSize * (vertexCount - 1);
    lastVertex[0 .. vertexSize] = vertexData[last .. last + vertexSize];
    return true;
}

/**
 * Encode tightly packed vertices.
 * `level` is 0–3 (higher values up to 9 match level 3). `version_` is -1 (default 1), 0, or 1.
 * Returns the encoded size, or 0 when `dst` is too small.
 */
size_t encodeVertexBufferLevel(ubyte[] dst, const(ubyte)[] vertices, size_t vertexCount, size_t vertexSize,
        int level, int version_) pure nothrow @nogc {
    assert(vertexSize > 0 && vertexSize <= 256);
    assert(vertexSize % 4 == 0);
    assert(level >= 0 && level <= 9);
    assert(version_ < 0 || (version_ >= 0 && version_ <= kDecodeVertexVersion));
    assert(vertexCount == 0 || vertices.length >= vertexCount * vertexSize);
    version_ = version_ < 0 ? 1 : version_;

    if (dst.length < 1)
        return 0;
    size_t data = 0;
    dst[data++] = cast(ubyte)(kVertexHeader | version_);

    ubyte[256] firstVertex;
    ubyte[256] lastVertex;
    firstVertex[] = 0;
    if (vertexCount > 0)
        firstVertex[0 .. vertexSize] = vertices[0 .. vertexSize];
    lastVertex[0 .. vertexSize] = firstVertex[0 .. vertexSize];

    size_t block = vertexBlockSize(vertexSize);
    ubyte[64] channels;
    channels[] = 0;
    if (version_ != 0 && level > 1 && vertexCount > 1) {
        foreach (k; 0 .. vertexSize / 4) {
            int rot = level >= 3 ? estimateRotate(vertices, vertexCount, vertexSize, k * 4, 16) : 0;
            int channel = estimateChannel(vertices, vertexCount, vertexSize, k * 4, block, 3, level >= 3 ? 3 : 2, rot);
            channels[k] = cast(ubyte) channel;
        }
    }

    size_t vertexOffset = 0;
    while (vertexOffset < vertexCount) {
        size_t blockSize = vertexOffset + block < vertexCount ? block : vertexCount - vertexOffset;
        if (!encodeVertexBlock(data, dst, vertices, vertexOffset * vertexSize, blockSize, vertexSize, lastVertex[],
                    channels[], version_, level))
            return 0;
        vertexOffset += blockSize;
    }

    size_t tailSize = vertexSize + (version_ == 0 ? 0 : vertexSize / 4);
    size_t tailMin = version_ == 0 ? kTailMinSizeV0 : kTailMinSizeV1;
    size_t tailPad = tailSize < tailMin ? tailMin : tailSize;
    if (dst.length - data < tailPad)
        return 0;
    if (tailSize < tailPad) {
        dst[data .. data + (tailPad - tailSize)] = 0;
        data += tailPad - tailSize;
    }
    dst[data .. data + vertexSize] = firstVertex[0 .. vertexSize];
    data += vertexSize;
    if (version_ != 0) {
        dst[data .. data + vertexSize / 4] = channels[0 .. vertexSize / 4];
        data += vertexSize / 4;
    }
    return data;
}

/// Encode at level 2, version 1 (upstream defaults). `version_` overrides the on-disk version.
size_t encodeVertexBuffer(ubyte[] dst, const(ubyte)[] vertices, size_t vertexCount, size_t vertexSize,
        int level = kEncodeDefaultLevel, int version_ = -1) pure nothrow @nogc {
    return encodeVertexBufferLevel(dst, vertices, vertexCount, vertexSize, level, version_);
}

/// Worst-case encoded size, covering both on-disk versions.
size_t encodeVertexBufferBound(size_t vertexCount, size_t vertexSize) pure nothrow @nogc {
    assert(vertexSize > 0 && vertexSize <= 256);
    assert(vertexSize % 4 == 0);
    size_t block = vertexBlockSize(vertexSize);
    size_t blockCount = vertexCount == 0 ? 0 : (vertexCount + block - 1) / block;
    size_t controlSize = vertexSize / 4;
    size_t byteHeader = (block / kByteGroupSize + 3) / 4;
    size_t byteData = block;
    size_t tailSize = vertexSize + vertexSize / 4;
    size_t tailMin = kTailMinSizeV0 > kTailMinSizeV1 ? kTailMinSizeV0 : kTailMinSizeV1;
    size_t tailPad = tailSize < tailMin ? tailMin : tailSize;
    return 1 + blockCount * (controlSize + vertexSize * (byteHeader + byteData)) + tailPad;
}

/// Header version, or -1.
int decodeVertexVersion(const(ubyte)[] buffer) pure nothrow @nogc {
    if (buffer.length < 1)
        return -1;
    ubyte header = buffer[0];
    if ((header & 0xf0) != kVertexHeader)
        return -1;
    int version_ = header & 0x0f;
    if (version_ > kDecodeVertexVersion)
        return -1;
    return version_;
}

private size_t decodeBytesGroup(const(ubyte)[] src, size_t data, ubyte[] buffer, size_t at, int bits) pure nothrow @nogc {
    if (bits == 0) {
        buffer[at .. at + kByteGroupSize] = 0;
        return data;
    }
    if (bits == 8) {
        buffer[at .. at + kByteGroupSize] = src[data .. data + kByteGroupSize];
        return data + kByteGroupSize;
    }
    size_t npacked = kByteGroupSize * bits / 8;
    size_t dataVar = data + npacked;
    size_t out_ = at;
    ubyte sentinel = cast(ubyte)((1 << bits) - 1);
    foreach (_; 0 .. npacked) {
        ubyte byte_ = src[data++];
        if (bits == 1)
            byte_ = reverseBits8(byte_);
        foreach (__; 0 .. 8 / bits) {
            ubyte enc = cast(ubyte)(byte_ >> (8 - bits));
            byte_ = cast(ubyte)(byte_ << bits);
            ubyte encv = src[dataVar];
            buffer[out_++] = enc == sentinel ? encv : enc;
            dataVar += enc == sentinel;
        }
    }
    return dataVar;
}

private bool decodeBytes(ref size_t data, const(ubyte)[] src, ubyte[] buffer, scope const(int)[] bits) pure nothrow @nogc {
    assert(buffer.length % kByteGroupSize == 0);
    size_t headerSize = (buffer.length / kByteGroupSize + 3) / 4;
    if (src.length - data < headerSize)
        return false;
    size_t header = data;
    data += headerSize;
    for (size_t i = 0; i < buffer.length; i += kByteGroupSize) {
        if (src.length - data < kByteGroupDecodeLimit)
            return false;
        size_t headerOffset = i / kByteGroupSize;
        int bitsk = (src[header + headerOffset / 4] >> ((headerOffset % 4) * 2)) & 3;
        data = decodeBytesGroup(src, data, buffer, i, bits[bitsk]);
    }
    return true;
}

private void decodeDeltas1(T, bool Xor)(const(ubyte)[] buffer, ubyte[] transposed, size_t vertexCount,
        size_t vertexSize, ubyte[] lastVertex, int rot) pure nothrow @nogc {
    size_t plane = 0;
    size_t lastOff = 0;
    for (size_t k = 0; k < 4; k += T.sizeof) {
        size_t vertexOffset = k;
        T p = lastVertex[lastOff];
        static if (T.sizeof > 1) {
            foreach (j; 1 .. T.sizeof)
                p |= cast(T)(cast(T)(lastVertex[lastOff + j]) << (8 * j));
        }
        foreach (i; 0 .. vertexCount) {
            T v = buffer[plane + i];
            static if (T.sizeof > 1) {
                foreach (j; 1 .. T.sizeof)
                    v |= cast(T)(cast(T)(buffer[plane + i + vertexCount * j]) << (8 * j));
            }
            static if (Xor)
                v = cast(T) rotl(v, rot) ^ p;
            else
                v = cast(T)(unzigzag(v) + p);
            static if (T.sizeof == 1)
                transposed[vertexOffset] = cast(ubyte) v;
            else {
                foreach (j; 0 .. T.sizeof)
                    transposed[vertexOffset + j] = cast(ubyte)(v >> (j * 8));
            }
            p = v;
            vertexOffset += vertexSize;
        }
        plane += vertexCount * T.sizeof;
        lastOff += T.sizeof;
    }
}

private int decodeVertexBlock(ref size_t data, const(ubyte)[] src, ubyte[] vertexData, size_t vertexCount,
        size_t vertexSize, ubyte[] lastVertex, const(ubyte)[] channels, int version_) pure nothrow @nogc {
    ubyte[kVertexBlockMaxSize * 4] buffer;
    ubyte[kVertexBlockSizeBytes] transposed;
    size_t vertexCountAligned = (vertexCount + kByteGroupSize - 1) & ~(kByteGroupSize - 1);
    size_t controlSize = version_ == 0 ? 0 : vertexSize / 4;
    if (src.length - data < controlSize)
        return -2;
    size_t control = data;
    data += controlSize;

    for (size_t k = 0; k < vertexSize; k += 4) {
        ubyte ctrlByte = version_ == 0 ? 0 : src[control + k / 4];
        foreach (j; 0 .. 4) {
            int ctrl = (ctrlByte >> (j * 2)) & 3;
            size_t plane = j * vertexCount;
            if (ctrl == 3) {
                if (src.length - data < vertexCount)
                    return -2;
                buffer[plane .. plane + vertexCount] = src[data .. data + vertexCount];
                data += vertexCount;
            } else if (ctrl == 2) {
                buffer[plane .. plane + vertexCount] = 0;
            } else {
                scope const(int)[] bits = version_ == 0 ? kBitsV0[] : kBitsV1[ctrl .. ctrl + 4];
                // decodeBytes writes vertexCountAligned bytes starting at plane j.
                // Planes overlap when aligned > count; the next plane overwrites that tail.
                ubyte[] dest = buffer[plane .. plane + vertexCountAligned];
                if (!decodeBytes(data, src, dest, bits))
                    return -2;
            }
        }
        int channel = version_ == 0 ? 0 : channels[k / 4];
        ubyte[] target = transposed[k .. $];
        ubyte[] last = lastVertex[k .. k + 4];
        switch (channel & 3) {
        case 0:
            decodeDeltas1!(ubyte, false)(buffer[], target, vertexCount, vertexSize, last, 0);
            break;
        case 1:
            decodeDeltas1!(ushort, false)(buffer[], target, vertexCount, vertexSize, last, 0);
            break;
        case 2:
            decodeDeltas1!(uint, true)(buffer[], target, vertexCount, vertexSize, last, (32 - (channel >> 4)) & 31);
            break;
        default:
            return -2;
        }
    }
    vertexData[0 .. vertexCount * vertexSize] = transposed[0 .. vertexCount * vertexSize];
    size_t lastAt = vertexSize * (vertexCount - 1);
    lastVertex[0 .. vertexSize] = transposed[lastAt .. lastAt + vertexSize];
    return 0;
}

/**
 * Decode vertices written by `encodeVertexBuffer`.
 * Returns 0 on success, -1 for a bad header, -2 when truncated or corrupt,
 * and -3 when the payload size does not match.
 * `destination` must hold `vertexCount * vertexSize` bytes.
 */
int decodeVertexBuffer(scope ubyte[] destination, size_t vertexCount, size_t vertexSize, scope const(ubyte)[] buffer) nothrow @nogc {
    version (LDC) {
        version (MeshoptForceScalar) {
        } else {
            import engine.meshopt.codec.vertex_simd : decodeVertexBufferSimd, vertexSimdReady;
            if (vertexSimdReady())
                return decodeVertexBufferSimd(destination, vertexCount, vertexSize, buffer);
        }
    }
    assert(vertexSize > 0 && vertexSize <= 256);
    assert(vertexSize % 4 == 0);
    assert(destination.length >= vertexCount * vertexSize);
    if (buffer.length < 1)
        return -2;
    ubyte header = buffer[0];
    if ((header & 0xf0) != kVertexHeader)
        return -1;
    int version_ = header & 0x0f;
    if (version_ > kDecodeVertexVersion)
        return -1;

    size_t tailSize = vertexSize + (version_ == 0 ? 0 : vertexSize / 4);
    size_t tailMin = version_ == 0 ? kTailMinSizeV0 : kTailMinSizeV1;
    size_t tailPad = tailSize < tailMin ? tailMin : tailSize;
    if (buffer.length - 1 < tailPad)
        return -2;

    size_t tail = buffer.length - tailSize;
    ubyte[256] lastVertex;
    lastVertex[0 .. vertexSize] = buffer[tail .. tail + vertexSize];
    const(ubyte)[] channels = version_ == 0 ? null : buffer[tail + vertexSize .. tail + vertexSize + vertexSize / 4];

    size_t block = vertexBlockSize(vertexSize);
    size_t data = 1;
    size_t vertexOffset = 0;
    while (vertexOffset < vertexCount) {
        size_t blockSize = vertexOffset + block < vertexCount ? block : vertexCount - vertexOffset;
        int rc = decodeVertexBlock(data, buffer, destination[vertexOffset * vertexSize .. $], blockSize, vertexSize,
                lastVertex[], channels, version_);
        if (rc != 0)
            return rc;
        vertexOffset += blockSize;
    }
    if (buffer.length - data != tailPad)
        return -3;
    return 0;
}

@safe pure nothrow @nogc unittest {
    ubyte b = 0b1000_0000;
    ubyte r = reverseBits8(b);
    ubyte expect = 0b0000_0001;
    // The meshopt permutation is a full 8-bit reverse.
    ubyte rev = b;
    rev = cast(ubyte)(((rev & 0xF0) >> 4) | ((rev & 0x0F) << 4));
    rev = cast(ubyte)(((rev & 0xCC) >> 2) | ((rev & 0x33) << 2));
    rev = cast(ubyte)(((rev & 0xAA) >> 1) | ((rev & 0x55) << 1));
    assert(r == rev);
    assert(reverseBits8(0x01) == reverseBits8(reverseBits8(reverseBits8(0x01))));
    assert(expect == reverseBits8(0x80) || reverseBits8(0x80) == rev);
}

@safe nothrow unittest {
    ubyte[64] raw;
    foreach (i, ref v; raw)
        v = cast(ubyte)(i * 17 + 3);
    ubyte[] enc = new ubyte[encodeVertexBufferBound(16, 4)];
    foreach (ver; 0 .. 2) {
        foreach (level; 0 .. 4) {
            size_t n = encodeVertexBufferLevel(enc, raw[], 16, 4, level, ver);
            assert(n > 0, "encode failed");
            assert(decodeVertexVersion(enc[0 .. n]) == ver);
            ubyte[64] out_;
            int rc = decodeVertexBuffer(out_[], 16, 4, enc[0 .. n]);
            assert(rc == 0);
            assert(out_[] == raw[]);
        }
    }
    // Cross a block boundary (block size is 256 for 4-byte vertices).
    ubyte[] big = new ubyte[300 * 8];
    foreach (i, ref v; big)
        v = cast(ubyte)(i * 13);
    ubyte[] benc = new ubyte[encodeVertexBufferBound(300, 8)];
    size_t bn = encodeVertexBuffer(benc, big[], 300, 8);
    assert(bn > 0);
    ubyte[] bout = new ubyte[300 * 8];
    assert(decodeVertexBuffer(bout, 300, 8, benc[0 .. bn]) == 0);
    assert(bout[] == big[]);

    assert(decodeVertexBuffer(raw[], 16, 4, cast(ubyte[])[]) == -2);
    ubyte[1] bad = [0x11];
    assert(decodeVertexVersion(bad[]) == -1);
}

/// Byte-exact goldens from the scalar C++ oracle (`MESHOPTIMIZER_NO_SIMD`).
/// The SSE2 `decodeFilterOct` in a default clang build uses `rsqrt` and is not bit-exact.
@safe unittest {
    import std.file : read;

    import engine.meshopt.codec.filter;
    import engine.meshopt.codec.index;
    import engine.meshopt.internal.bits : bitsFloat;
    import engine.meshopt.types : EncodeExpMode;

    static uint lu32(const(ubyte)[] f, size_t at) pure nothrow @nogc {
        return f[at] | (cast(uint) f[at + 1] << 8) | (cast(uint) f[at + 2] << 16) | (cast(uint) f[at + 3] << 24);
    }

    void check(string path) @trusted {
        ubyte[] file = cast(ubyte[]) read(path);
        assert(file.length >= 16 && file[0 .. 8] == cast(const(ubyte)[]) "MOPTCDC1", path);
        assert(lu32(file, 8) == 1030, path);
        uint cases = lu32(file, 12);
        size_t at = 16;
        foreach (_; 0 .. cases) {
            uint kind = lu32(file, at);
            at += 4;
            int a = cast(int) lu32(file, at);
            at += 4;
            int b = cast(int) lu32(file, at);
            at += 4;
            uint c = lu32(file, at);
            at += 4;
            uint n = lu32(file, at);
            at += 4;
            uint inLen = lu32(file, at);
            at += 4;
            const(ubyte)[] input = file[at .. at + inLen];
            at += inLen;
            uint encLen = lu32(file, at);
            at += 4;
            const(ubyte)[] encoded = file[at .. at + encLen];
            at += encLen;
            uint decLen = lu32(file, at);
            at += 4;
            const(ubyte)[] decoded = file[at .. at + decLen];
            at += decLen;

            if (kind == 1 || kind == 2) {
                uint[] idx = new uint[n];
                assert(input.length == n * 4);
                foreach (i; 0 .. n)
                    idx[i] = lu32(input, i * 4);
                ubyte[] buf = new ubyte[kind == 1 ? encodeIndexBufferBound(n, uint.max) : encodeIndexSequenceBound(n, uint.max)];
                size_t got = kind == 1 ? encodeIndexBuffer(buf, idx, a) : encodeIndexSequence(buf, idx, a);
                assert(got == encoded.length && buf[0 .. got] == encoded);
                uint[] out_ = new uint[n];
                int rc = kind == 1 ? decodeIndexBuffer(out_[], encoded) : decodeIndexSequence(out_[], encoded);
                assert(rc == 0);
                foreach (i; 0 .. n)
                    assert(out_[i] == lu32(decoded, i * 4));
            } else if (kind == 3) {
                assert(input.length == n * c);
                ubyte[] buf = new ubyte[encodeVertexBufferBound(n, c)];
                size_t got = encodeVertexBufferLevel(buf, input, n, c, b, a);
                assert(got == encoded.length && buf[0 .. got] == encoded);
                ubyte[] out_ = new ubyte[n * c];
                assert(decodeVertexBuffer(out_[], n, c, encoded) == 0);
                assert(out_[] == decoded);
            } else if (kind == 8) {
                uint[] dest = new uint[n];
                assert(decodeIndexBuffer(dest, input) == a);
            } else if (kind == 9) {
                ubyte[] dest = new ubyte[n * c];
                assert(decodeVertexBuffer(dest, n, c, input) == a);
            } else if (kind >= 4 && kind <= 7) {
                float[] fv = new float[input.length / 4];
                foreach (i, ref f; fv)
                    f = bitsFloat(lu32(input, i * 4));
                ubyte[] buf = new ubyte[n * c];
                if (kind == 4)
                    encodeFilterOct(buf, n, c, a, fv);
                else if (kind == 5)
                    encodeFilterQuat(buf, n, c, a, fv);
                else if (kind == 6)
                    encodeFilterExp(buf, n, c, a, fv, cast(EncodeExpMode) b);
                else
                    encodeFilterColor(buf, n, c, a, fv);
                assert(buf == encoded);
                ubyte[] back = encoded.dup;
                if (kind == 4)
                    decodeFilterOct(back, n, c);
                else if (kind == 5)
                    decodeFilterQuat(back, n, c);
                else if (kind == 6)
                    decodeFilterExp(back, n, c);
                else
                    decodeFilterColor(back, n, c);
                assert(back == decoded);
            } else {
                assert(0, "unknown golden kind");
            }
        }
    }

    check("tests/meshopt/golden/codec/index.bin");
    check("tests/meshopt/golden/codec/vertex.bin");
    check("tests/meshopt/golden/codec/filter.bin");
}
