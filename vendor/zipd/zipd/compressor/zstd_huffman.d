/**
 * ZSTD Huffman literal decoding (RFC 8878 §4.2).
 *
 * Reads a Huffman tree description (FSE-compressed or direct 4-bit
 * weights), builds a single-level decoding table (max 11 bits) and
 * decodes 1-stream or 4-stream literal sections.
 */
module zipd.compressor.zstd_huffman;

import core.bitop : bsr;

import zipd.compressor.errors : Result, ErrorKind, ErrorInfo, noError,
    success, failure;
import zipd.compressor.zstd_bitstream : ZstdBackBitReader;
import zipd.compressor.zstd_fse : FseNorm, FseDecodeTable,
    readFseTableDescription, buildFseDecodeTable, fseDecodeInterleaved;

@safe:
nothrow:
@nogc:

/// Longest Huffman code ZSTD allows.
enum uint maxHuffmanBits = 11;
enum uint huffmanTableSize = 1u << maxHuffmanBits;

/// Single-level decoding table indexed by the next `maxBits` stream bits.
struct HuffmanTable
{
    uint maxBits;
    ubyte[huffmanTableSize] symbol;
    ubyte[huffmanTableSize] numBits;
}

private ErrorInfo corrupt(string m) pure nothrow @nogc
{
    return ErrorInfo(ErrorKind.corruptInput, m);
}

/// Build `t` from the explicit weights `weights[0 .. n]`; the final
/// symbol's weight is inferred from the Kraft sum (RFC 8878 §4.2.1.1).
ErrorInfo buildHuffmanTable(ref HuffmanTable t, scope const(ubyte)[] weights)
    pure nothrow @nogc
{
    const n = weights.length;
    if (n == 0 || n > 255)
        return corrupt("invalid Huffman weight count");
    uint total = 0;
    foreach (w; weights)
    {
        if (w > maxHuffmanBits)
            return corrupt("Huffman weight too large");
        if (w > 0)
            total += 1u << (w - 1);
    }
    if (total == 0)
        return corrupt("empty Huffman tree");
    const maxBits = cast(uint) bsr(total) + 1;
    if (maxBits > maxHuffmanBits)
        return corrupt("Huffman code too long");
    const rest = (1u << maxBits) - total;
    if ((rest & (rest - 1)) != 0)
        return corrupt("Huffman weights are not a complete tree");
    const lastWeight = cast(uint) bsr(rest) + 1;

    ubyte[256] all;
    all[0 .. n] = weights[];
    all[n] = cast(ubyte) lastWeight;
    const count = n + 1;

    t.maxBits = maxBits;
    uint pos = 0;
    foreach (w; 1 .. maxBits + 1)
    {
        const len = 1u << (w - 1);
        const nb = maxBits + 1 - w;
        foreach (s; 0 .. count)
        {
            if (all[s] != w)
                continue;
            if (pos + len > (1u << maxBits))
                return corrupt("Huffman table overflow");
            t.symbol[pos .. pos + len] = cast(ubyte) s;
            t.numBits[pos .. pos + len] = cast(ubyte) nb;
            pos += len;
        }
    }
    if (pos != (1u << maxBits))
        return corrupt("Huffman table underfilled");
    return noError;
}

/// Parse a Huffman tree description at the start of `src` and build
/// `t`. Returns the bytes consumed.
Result!size_t readHuffmanTreeDescription(scope const(ubyte)[] src,
    ref HuffmanTable t) pure nothrow @nogc
{
    if (src.length == 0)
        return failure!size_t(ErrorKind.corruptInput,
            "missing Huffman tree description");
    const hb = src[0];
    ubyte[256] weights;
    size_t n;
    size_t used;

    if (hb < 128)
    {
        if (hb == 0 || src.length < 1 + cast(size_t) hb)
            return failure!size_t(ErrorKind.corruptInput,
                "truncated Huffman tree description");
        const comp = src[1 .. 1 + hb];
        FseNorm norm;
        auto d = readFseTableDescription(comp, 6, 256, norm);
        if (!d.ok)
            return failure!size_t(d.error.kind, d.error.message);
        FseDecodeTable ft;
        auto b = buildFseDecodeTable(ft, norm.counts[], norm.symbolCount,
            norm.accuracyLog);
        if (!b.ok)
            return failure!size_t(b.kind, b.message);
        auto w = fseDecodeInterleaved(comp[d.value .. $], ft, weights[0 .. 255]);
        if (!w.ok)
            return failure!size_t(w.error.kind, w.error.message);
        n = w.value;
        used = 1 + cast(size_t) hb;
    }
    else
    {
        n = cast(size_t) hb - 127;
        const bytes = (n + 1) / 2;
        if (src.length < 1 + bytes)
            return failure!size_t(ErrorKind.corruptInput,
                "truncated Huffman tree description");
        foreach (i; 0 .. n)
        {
            const b = src[1 + i / 2];
            weights[i] = (i & 1) == 0 ? cast(ubyte)(b >> 4) : cast(ubyte)(b & 0xF);
        }
        used = 1 + bytes;
    }
    auto e = buildHuffmanTable(t, weights[0 .. n]);
    if (!e.ok)
        return failure!size_t(e.kind, e.message);
    return success(used);
}

/// Decode exactly `dst.length` symbols from one backward bitstream.
ErrorInfo huffDecodeStream(scope const(ubyte)[] stream,
    ref const HuffmanTable t, scope ubyte[] dst) pure nothrow @nogc
{
    auto rr = ZstdBackBitReader.create(stream);
    if (!rr.ok)
        return corrupt("invalid backward bitstream");
    auto r = rr.value;
    const mb = t.maxBits;
    foreach (ref d; dst)
    {
        const idx = r.peekBits(mb);
        d = t.symbol[idx];
        if (!r.skipBits(t.numBits[idx]))
            return corrupt("Huffman stream overrun");
    }
    if (!r.isFinished())
        return corrupt("Huffman stream has unconsumed bits");
    return noError;
}

/// Decode a 4-stream payload (6-byte jump table + streams) into `dst`.
ErrorInfo huffDecode4Streams(scope const(ubyte)[] payload,
    ref const HuffmanTable t, scope ubyte[] dst) pure nothrow @nogc
{
    if (payload.length < 6 + 4)
        return corrupt("truncated 4-stream Huffman payload");
    const s1 = cast(size_t) payload[0] | (cast(size_t) payload[1] << 8);
    const s2 = cast(size_t) payload[2] | (cast(size_t) payload[3] << 8);
    const s3 = cast(size_t) payload[4] | (cast(size_t) payload[5] << 8);
    const body_ = payload[6 .. $];
    if (s1 + s2 + s3 >= body_.length)
        return corrupt("bad Huffman jump table");
    const seg = (dst.length + 3) / 4;
    if (3 * seg > dst.length)
        return corrupt("literals too short for 4 streams");

    auto e = huffDecodeStream(body_[0 .. s1], t, dst[0 .. seg]);
    if (!e.ok) return e;
    e = huffDecodeStream(body_[s1 .. s1 + s2], t, dst[seg .. 2 * seg]);
    if (!e.ok) return e;
    e = huffDecodeStream(body_[s1 + s2 .. s1 + s2 + s3], t,
        dst[2 * seg .. 3 * seg]);
    if (!e.ok) return e;
    return huffDecodeStream(body_[s1 + s2 + s3 .. $], t, dst[3 * seg .. $]);
}



