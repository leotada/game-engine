// Ported from meshoptimizer v1.3 (src/vertexcodec.cpp), Copyright (c) 2016-2026 Arseny Kapoulkine, MIT License.
/// SSSE3 vertex decode. `version(LDC)` only. DMD keeps the scalar path in `vertex.d`.
/// AVX-512 VBMI is not dispatched: this host has no AVX-512, and upstream enables that
/// kernel only when the compiler target has it. NEON is not compiled on x86_64.
module engine.meshopt.codec.vertex_simd;

@safe:

version (LDC):

import core.simd : byte16, int4, long2, short8;
import ldc.attributes : target;
import ldc.gccbuiltins_x86;
import ldc.simd : equalMask, loadUnaligned, shufflevector, storeUnaligned;

private enum size_t kByteGroupSize = 16;
private enum size_t kByteGroupDecodeLimit = 24;
private enum size_t kVertexBlockMaxSize = 256;
private enum size_t kVertexBlockSizeBytes = 8192;
private enum size_t kTailMinSizeV0 = 32;
private enum size_t kTailMinSizeV1 = 24;
private enum ubyte kVertexHeader = 0xa0;
private enum int kDecodeVertexVersion = 1;

private size_t blockSizeOf(size_t vertexSize) pure nothrow @nogc {
    size_t result = (kVertexBlockSizeBytes / vertexSize) & ~(kByteGroupSize - 1);
    return result < kVertexBlockMaxSize ? result : kVertexBlockMaxSize;
}

align(16) private static immutable ubyte[16][4][9] kConfig = [
    [[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1],
     [128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128],
     [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
     [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]],
    [[3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3],
     [0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3],
     [4, 0, 64, 0, 4, 0, 64, 0, 4, 0, 64, 0, 4, 0, 64, 0],
     [16, 0, 0, 1, 16, 0, 0, 1, 16, 0, 0, 1, 16, 0, 0, 1]],
    [[15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15],
     [0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7],
     [16, 0, 16, 0, 16, 0, 16, 0, 16, 0, 16, 0, 16, 0, 16, 0],
     [0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1]],
    [[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
     [128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128],
     [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
     [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]],
    [[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1],
     [128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128],
     [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
     [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]],
    [[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1],
     [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1],
     [0, 1, 64, 0, 16, 0, 4, 0, 0, 1, 64, 0, 16, 0, 4, 0],
     [128, 0, 32, 0, 8, 0, 2, 0, 128, 0, 32, 0, 8, 0, 2, 0]],
    [[3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3],
     [0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3],
     [4, 0, 64, 0, 4, 0, 64, 0, 4, 0, 64, 0, 4, 0, 64, 0],
     [16, 0, 0, 1, 16, 0, 0, 1, 16, 0, 0, 1, 16, 0, 0, 1]],
    [[15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15],
     [0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7],
     [16, 0, 16, 0, 16, 0, 16, 0, 16, 0, 16, 0, 16, 0, 16, 0],
     [0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1]],
    [[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
     [128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128],
     [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
     [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]],
];

private ubyte[8][256] buildShuffle() pure nothrow @nogc {
    ubyte[8][256] shuf;
    foreach (mask; 0 .. 256) {
        ubyte count = 0;
        foreach (i; 0 .. 8) {
            int bit = (mask >> i) & 1;
            shuf[mask][i] = cast(ubyte)(bit ? count : 0x80);
            count += cast(ubyte) bit;
        }
    }
    return shuf;
}

align(16) private static immutable ubyte[8][256] kShuffle = buildShuffle();

private bool simdOn;

shared static this() @trusted {
    import core.cpuid : hasPopcnt, ssse3;
    simdOn = ssse3 && hasPopcnt;
}

/// True when the SSSE3+POPCNT decoder may run.
bool vertexSimdReady() nothrow @nogc {
    return simdOn;
}

private byte16 loadLow8(const(ubyte)* p) nothrow @nogc @trusted {
    long v;
    import core.stdc.string : memcpy;
    memcpy(&v, p, 8);
    long2 L = 0;
    L.array[0] = v;
    return cast(byte16) L;
}

private byte16 load16(const(ubyte)* p) nothrow @nogc @trusted {
    return loadUnaligned!byte16(cast(const(byte)*) p);
}

private void store16(ubyte* p, byte16 v) nothrow @nogc @trusted {
    storeUnaligned!byte16(v, cast(byte*) p);
}

private byte16 cfg(int hbits, int row) nothrow @nogc @trusted {
    return loadUnaligned!byte16(cast(const(byte)*) &kConfig[hbits][row][0]);
}

private byte16 unpacklo64(byte16 a, byte16 b) pure nothrow @nogc {
    return cast(byte16) shufflevector!(long2, 0, 2)(cast(long2) a, cast(long2) b);
}

private byte16 unpacklo8(byte16 a, byte16 b) pure nothrow @nogc {
    return shufflevector!(byte16, 0, 16, 1, 17, 2, 18, 3, 19, 4, 20, 5, 21, 6, 22, 7, 23)(a, b);
}

private byte16 unpackhi8(byte16 a, byte16 b) pure nothrow @nogc {
    return shufflevector!(byte16, 8, 24, 9, 25, 10, 26, 11, 27, 12, 28, 13, 29, 14, 30, 15, 31)(a, b);
}

private byte16 unpacklo16(byte16 a, byte16 b) pure nothrow @nogc {
    return cast(byte16) shufflevector!(short8, 0, 8, 1, 9, 2, 10, 3, 11)(cast(short8) a, cast(short8) b);
}

private byte16 unpackhi16(byte16 a, byte16 b) pure nothrow @nogc {
    return cast(byte16) shufflevector!(short8, 4, 12, 5, 13, 6, 14, 7, 15)(cast(short8) a, cast(short8) b);
}

/// Invariants: `data` has the bytes this group will read (caller checked 24, or 96 for the fast path).
/// `buffer` has 16 writable bytes. Returns how many source bytes were consumed.
@target("ssse3,popcnt")
private size_t decodeBytesGroupSimd(const(ubyte)* data, ubyte* buffer, int hbits) nothrow @nogc @trusted {
    enum int[9] hbtn = [4, 1, 2, 3, 4, 0, 1, 2, 3];
    int n = hbtn[hbits];
    size_t skip = (2u << n) & 15;
    byte16 selb = loadLow8(data);
    byte16 rest = load16(data + skip);
    byte16 selw = __builtin_ia32_pshufb128(selb, cfg(hbits, 1));
    short8 sel0 = __builtin_ia32_pmulhuw128(cast(short8) selw, cast(short8) cfg(hbits, 2));
    short8 sel1 = __builtin_ia32_pmulhuw128(cast(short8) selw, cast(short8) cfg(hbits, 3));
    byte16 seli = cast(byte16) sel0 | cast(byte16) __builtin_ia32_psllwi128(sel1, 8);
    byte16 sent = cfg(hbits, 0);
    byte16 sel = seli & sent;
    byte16 mask = equalMask!byte16(sel, sent);
    int mask16 = __builtin_ia32_pmovmskb128(mask);
    ubyte mask0 = cast(ubyte)(mask16 & 255);
    ubyte mask1 = cast(ubyte)(mask16 >> 8);
    byte16 sm0 = loadLow8(&kShuffle[mask0][0]);
    byte16 sm1 = loadLow8(&kShuffle[mask1][0]);
    long2 npops = __builtin_ia32_psadbw128(mask, byte16(0));
    byte16 npb = __builtin_ia32_pshufb128(cast(byte16) npops, byte16(0));
    byte16 sm1r = sm1 - npb;
    byte16 shuf = unpacklo64(sm0, sm1r);
    byte16 result = __builtin_ia32_pshufb128(rest, shuf) | ((~mask) & sel);
    store16(buffer, result);
    import core.bitop : popcnt;
    return skip + popcnt(cast(uint) mask16);
}

@target("ssse3,popcnt")
private bool decodeBytesSimd(ref size_t data, const(ubyte)[] src, ubyte[] buffer, int hshift) nothrow @nogc @trusted {
    size_t headerSize = (buffer.length / kByteGroupSize + 3) / 4;
    if (data > src.length || src.length - data < headerSize)
        return false;
    size_t header = data;
    data += headerSize;
    size_t i = 0;
    for (; i + kByteGroupSize * 4 <= buffer.length && data <= src.length && src.length - data >= kByteGroupDecodeLimit * 4; i += kByteGroupSize * 4) {
        ubyte headerByte = src[header + (i / kByteGroupSize) / 4];
        if (hshift != 5 && headerByte == 0) {
            buffer[i .. i + kByteGroupSize * 4] = 0;
            continue;
        }
        if (hshift != 4 && headerByte == 255) {
            buffer[i .. i + kByteGroupSize * 4] = src[data .. data + kByteGroupSize * 4];
            data += kByteGroupSize * 4;
            continue;
        }
        data += decodeBytesGroupSimd(src.ptr + data, buffer.ptr + i + kByteGroupSize * 0, hshift + ((headerByte >> 0) & 3));
        data += decodeBytesGroupSimd(src.ptr + data, buffer.ptr + i + kByteGroupSize * 1, hshift + ((headerByte >> 2) & 3));
        data += decodeBytesGroupSimd(src.ptr + data, buffer.ptr + i + kByteGroupSize * 2, hshift + ((headerByte >> 4) & 3));
        data += decodeBytesGroupSimd(src.ptr + data, buffer.ptr + i + kByteGroupSize * 3, hshift + ((headerByte >> 6) & 3));
    }
    for (; i < buffer.length; i += kByteGroupSize) {
        if (data > src.length || src.length - data < kByteGroupDecodeLimit)
            return false;
        size_t headerOffset = i / kByteGroupSize;
        ubyte headerByte = src[header + headerOffset / 4];
        int bitsk = (headerByte >> ((headerOffset % 4) * 2)) & 3;
        data += decodeBytesGroupSimd(src.ptr + data, buffer.ptr + i, hshift + bitsk);
    }
    return true;
}

private void transpose8(ref byte16 x0, ref byte16 x1, ref byte16 x2, ref byte16 x3) pure nothrow @nogc {
    byte16 t0 = unpacklo8(x0, x1);
    byte16 t1 = unpackhi8(x0, x1);
    byte16 t2 = unpacklo8(x2, x3);
    byte16 t3 = unpackhi8(x2, x3);
    x0 = unpacklo16(t0, t2);
    x1 = unpackhi16(t0, t2);
    x2 = unpacklo16(t1, t3);
    x3 = unpackhi16(t1, t3);
}

private byte16 unzigzag8(byte16 v) pure nothrow @nogc {
    byte16 one = 1;
    byte16 m127 = 127;
    byte16 xl = byte16(0) - (v & one);
    byte16 xr = cast(byte16) __builtin_ia32_psrlwi128(cast(short8) v, 1);
    return xl ^ (xr & m127);
}

private byte16 unzigzag16(byte16 v) pure nothrow @nogc {
    short8 s = cast(short8) v;
    short8 one = 1;
    short8 xl = short8(0) - (s & one);
    short8 xr = __builtin_ia32_psrlwi128(s, 1);
    return cast(byte16)(xl ^ xr);
}

private byte16 rotate32(byte16 v, int r) pure nothrow @nogc {
    if (r == 0)
        return v;
    int4 i = cast(int4) v;
    int4 o = __builtin_ia32_pslldi128(i, r) | __builtin_ia32_psrldi128(i, 32 - r);
    return cast(byte16) o;
}

private byte16 splatDword(byte16 r, int lane) pure nothrow @nogc {
    int4 i = cast(int4) r;
    static if (false) {}
    int4 s;
    if (lane == 0)
        s = i;
    else if (lane == 1)
        s = shufflevector!(int4, 1, 0, 0, 0)(i, i);
    else if (lane == 2)
        s = shufflevector!(int4, 2, 0, 0, 0)(i, i);
    else
        s = shufflevector!(int4, 3, 0, 0, 0)(i, i);
    return cast(byte16) s;
}

private void fixd(int channel)(ref byte16 t, ref byte16 pi) pure nothrow @nogc {
    static if (channel == 0)
        t = pi = pi + t;
    else static if (channel == 1)
        t = pi = cast(byte16)(cast(short8) pi + cast(short8) t);
    else
        t = pi = pi ^ t;
}

private void store32(ubyte* p, byte16 v) nothrow @nogc @trusted {
    int x = (cast(int4) v).array[0];
    import core.stdc.string : memcpy;
    memcpy(p, &x, 4);
}

private byte16 load32(const(ubyte)* p) nothrow @nogc @trusted {
    int x;
    import core.stdc.string : memcpy;
    memcpy(&x, p, 4);
    int4 i = 0;
    i.array[0] = x;
    return cast(byte16) i;
}

/// Invariants: `buffer` has 4 planes of `aligned` bytes. `transposed` has room for `aligned * vertexSize` bytes.
@target("ssse3,popcnt")
private void decodeDeltas4(int channel)(const(ubyte)* buffer, ubyte* transposed, size_t aligned, size_t vertexSize, const(ubyte)* lastVertex, int rot) nothrow @nogc @trusted {
    byte16 pi = load32(lastVertex);
    ubyte* savep = transposed;
    for (size_t j = 0; j < aligned; j += 16) {
        byte16 r0 = load16(buffer + j);
        byte16 r1 = load16(buffer + j + aligned);
        byte16 r2 = load16(buffer + j + aligned * 2);
        byte16 r3 = load16(buffer + j + aligned * 3);
        transpose8(r0, r1, r2, r3);
        static if (channel == 0) {
            r0 = unzigzag8(r0);
            r1 = unzigzag8(r1);
            r2 = unzigzag8(r2);
            r3 = unzigzag8(r3);
        } else static if (channel == 1) {
            r0 = unzigzag16(r0);
            r1 = unzigzag16(r1);
            r2 = unzigzag16(r2);
            r3 = unzigzag16(r3);
        } else {
            r0 = rotate32(r0, rot);
            r1 = rotate32(r1, rot);
            r2 = rotate32(r2, rot);
            r3 = rotate32(r3, rot);
        }
        byte16[4] rs = [r0, r1, r2, r3];
        foreach (r; rs) {
            byte16 t0 = splatDword(r, 0);
            byte16 t1 = splatDword(r, 1);
            byte16 t2 = splatDword(r, 2);
            byte16 t3 = splatDword(r, 3);
            fixd!channel(t0, pi);
            fixd!channel(t1, pi);
            fixd!channel(t2, pi);
            fixd!channel(t3, pi);
            store32(savep, t0);
            savep += vertexSize;
            store32(savep, t1);
            savep += vertexSize;
            store32(savep, t2);
            savep += vertexSize;
            store32(savep, t3);
            savep += vertexSize;
        }
    }
}

@target("ssse3,popcnt")
private int decodeVertexBlockSimd(ref size_t data, const(ubyte)[] src, ubyte[] vertexData, size_t vertexCount, size_t vertexSize, ubyte[] lastVertex, const(ubyte)[] channels, int version_) nothrow @nogc @trusted {
    ubyte[kVertexBlockMaxSize * 4] buffer;
    ubyte[kVertexBlockSizeBytes] transposed;
    size_t aligned = (vertexCount + kByteGroupSize - 1) & ~(kByteGroupSize - 1);
    size_t controlSize = version_ == 0 ? 0 : vertexSize / 4;
    if (data > src.length || src.length - data < controlSize)
        return -2;
    size_t control = data;
    data += controlSize;
    for (size_t k = 0; k < vertexSize; k += 4) {
        ubyte ctrlByte = version_ == 0 ? 0 : src[control + k / 4];
        foreach (j; 0 .. 4) {
            int ctrl = (ctrlByte >> (j * 2)) & 3;
            size_t plane = j * aligned;
            if (ctrl == 3) {
                if (data > src.length || src.length - data < aligned)
                    return -2;
                buffer[plane .. plane + aligned] = src[data .. data + aligned];
                data += vertexCount;
            } else if (ctrl == 2) {
                buffer[plane .. plane + aligned] = 0;
            } else {
                int hshift = version_ == 0 ? 0 : 4 + ctrl;
                if (!decodeBytesSimd(data, src, buffer[plane .. plane + aligned], hshift))
                    return -2;
            }
        }
        int channel = version_ == 0 ? 0 : channels[k / 4];
        int which = channel & 3;
        if (which == 0)
            decodeDeltas4!0(buffer.ptr, transposed.ptr + k, aligned, vertexSize, lastVertex.ptr + k, 0);
        else if (which == 1)
            decodeDeltas4!1(buffer.ptr, transposed.ptr + k, aligned, vertexSize, lastVertex.ptr + k, 0);
        else if (which == 2)
            decodeDeltas4!2(buffer.ptr, transposed.ptr + k, aligned, vertexSize, lastVertex.ptr + k, (32 - (channel >> 4)) & 31);
        else
            return -2;
    }
    vertexData[0 .. vertexCount * vertexSize] = transposed[0 .. vertexCount * vertexSize];
    size_t lastAt = vertexSize * (vertexCount - 1);
    lastVertex[0 .. vertexSize] = transposed[lastAt .. lastAt + vertexSize];
    return 0;
}

/**
 * SSSE3 decode. Same error codes as `decodeVertexBuffer`.
 * Invariants: `destination.length >= vertexCount * vertexSize`. Does not read past `buffer.length`.
 */
@target("ssse3,popcnt")
pragma(inline, false)
int decodeVertexBufferSimd(scope ubyte[] destination, size_t vertexCount, size_t vertexSize, scope const(ubyte)[] buffer) nothrow @nogc @trusted {
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
    const(ubyte)[] channels = version_ == 0 ? null : buffer[tail + vertexSize .. tail + tailSize];
    size_t block = blockSizeOf(vertexSize);
    size_t data = 1;
    size_t vertexOffset = 0;
    while (vertexOffset < vertexCount) {
        size_t n = vertexOffset + block < vertexCount ? block : vertexCount - vertexOffset;
        int rc = decodeVertexBlockSimd(data, buffer, destination[vertexOffset * vertexSize .. $], n, vertexSize, lastVertex[], channels, version_);
        if (rc != 0)
            return rc;
        vertexOffset += n;
    }
    if (buffer.length - data != tailPad)
        return -3;
    return 0;
}
