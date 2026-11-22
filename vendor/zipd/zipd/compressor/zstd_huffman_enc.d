/**
 * ZSTD Huffman literal encoder (RFC 8878 §4.2).
 *
 * Builds a length-limited (11-bit) canonical code, serializes the tree
 * description (direct nibbles or FSE-compressed weights, whichever is
 * smaller) and encodes backward bitstreams.
 */
module zipd.compressor.zstd_huffman_enc;

import zipd.compressor.errors : Result, ErrorKind, success, failure;
import zipd.compressor.zstd_bitstream : ZstdBackBitWriter;
import zipd.compressor.zstd_fse_enc;
import zipd.compressor.zstd_huffman : maxHuffmanBits;

@safe:
nothrow:
@nogc:

/// Encoding side of a Huffman table.
struct HuffmanEncTable
{
    ubyte[256]  len;
    ushort[256] code;
    ubyte[256]  weight;
    uint maxBits;
    /// Highest symbol present; its weight is implicit in the description.
    uint lastSymbol;
}

/// Plain Huffman code lengths for `cnt`. Returns the longest length, or
/// 0 if fewer than two symbols are present.
private uint computeLengths(scope const(uint)[] cnt, ref ubyte[256] len)
    pure nothrow @nogc
{
    uint[512] w;
    ushort[512] parent;
    bool[512] dead;
    ubyte[256] sym;
    uint total = 0;
    len[] = 0;
    foreach (s; 0 .. 256)
        if (cnt[s] != 0)
        {
            w[total] = cnt[s];
            sym[total] = cast(ubyte) s;
            total++;
        }
    const present = total;
    if (present < 2)
        return 0;

    uint alive = present;
    while (alive > 1)
    {
        uint a = uint.max, b = uint.max;
        foreach (i; 0 .. total)
        {
            if (dead[i])
                continue;
            if (a == uint.max || w[i] < w[a])
            {
                b = a;
                a = i;
            }
            else if (b == uint.max || w[i] < w[b])
                b = i;
        }
        w[total] = w[a] + w[b];
        parent[a] = cast(ushort) total;
        parent[b] = cast(ushort) total;
        dead[a] = true;
        dead[b] = true;
        total++;
        alive--;
    }
    const root = total - 1;
    uint maxLen = 0;
    foreach (i; 0 .. present)
    {
        uint d = 0;
        uint n = i;
        while (n != root)
        {
            n = parent[n];
            d++;
        }
        len[sym[i]] = cast(ubyte) d;
        if (d > maxLen)
            maxLen = d;
    }
    return maxLen;
}

/// Build the encoding table from a 256-entry histogram. Returns false if
/// fewer than two symbols are present.
bool buildHuffmanEncTable(ref HuffmanEncTable t, scope const(uint)[] hist)
    pure nothrow @nogc
{
    uint[256] cnt;
    cnt[] = hist[0 .. 256];
    uint maxLen;
    while (true)
    {
        maxLen = computeLengths(cnt[], t.len);
        if (maxLen == 0)
            return false;
        if (maxLen <= maxHuffmanBits)
            break;
        // Flatten the distribution until the code fits in 11 bits.
        foreach (ref c; cnt)
            if (c != 0)
                c = (c + 1) >> 1;
    }
    t.maxBits = maxLen;
    t.lastSymbol = 0;
    foreach (s; 0 .. 256)
    {
        t.weight[s] = t.len[s] == 0 ? 0 : cast(ubyte)(maxLen + 1 - t.len[s]);
        if (t.len[s] != 0)
            t.lastSymbol = s;
    }
    // Canonical assignment, mirroring the decoder's table layout:
    // weight ascending, then symbol ascending.
    uint pos = 0;
    foreach (w; 1 .. maxLen + 1)
        foreach (s; 0 .. 256)
            if (t.weight[s] == w)
            {
                t.code[s] = cast(ushort)(pos >> (maxLen - t.len[s]));
                pos += 1u << (w - 1);
            }
    return true;
}

/// Serialize the tree description. Returns bytes written.
Result!size_t writeHuffmanTreeDescription(ref const HuffmanEncTable t,
    scope ubyte[] dst) pure nothrow @nogc
{
    const n = t.lastSymbol; // explicit weights are weight[0 .. n]
    size_t directSize = n <= 128 ? 1 + (n + 1) / 2 : size_t.max;

    // Try FSE-compressed weights.
    ubyte[256] fseBuf;
    size_t fseSize = size_t.max;
    if (n >= 2)
    {
        uint[16] hist;
        uint maxW = 0;
        foreach (i; 0 .. n)
        {
            hist[t.weight[i]]++;
            if (t.weight[i] > maxW)
                maxW = t.weight[i];
        }
        uint distinct = 0;
        foreach (c; hist)
            if (c != 0)
                distinct++;
        if (distinct > 1)
        {
            const tl = optimalTableLog(6, n, maxW);
            short[16] norm;
            FseCTable ct;
            if (normalizeCounts(hist[], maxW + 1, n, tl, norm[]).ok
                && buildFseCTable(ct, norm[], maxW + 1, tl).ok)
            {
                auto h = writeFseTableDescription(norm[], maxW + 1, tl, fseBuf[]);
                if (h.ok)
                {
                    ubyte[256] stream;
                    auto s = fseEncodeInterleaved(t.weight[0 .. n], ct, stream[]);
                    if (s.ok && h.value + s.value < 128
                        && h.value + s.value + h.value < fseBuf.length)
                    {
                        // Append the stream after the table description.
                        fseBuf[h.value .. h.value + s.value] = stream[0 .. s.value];
                        fseSize = 1 + h.value + s.value;
                    }
                }
            }
        }
    }

    if (fseSize < directSize)
    {
        if (dst.length < fseSize)
            return failure!size_t(ErrorKind.internal, "tree buffer too small");
        dst[0] = cast(ubyte)(fseSize - 1);
        dst[1 .. fseSize] = fseBuf[0 .. fseSize - 1];
        return success(fseSize);
    }
    if (directSize == size_t.max)
        return failure!size_t(ErrorKind.internal,
            "Huffman tree not representable");
    if (dst.length < directSize)
        return failure!size_t(ErrorKind.internal, "tree buffer too small");
    dst[0] = cast(ubyte)(127 + n);
    foreach (i; 0 .. (n + 1) / 2)
    {
        const hi = t.weight[2 * i];
        const lo = 2 * i + 1 < n ? t.weight[2 * i + 1] : 0;
        dst[1 + i] = cast(ubyte)((hi << 4) | lo);
    }
    return success(directSize);
}

/// Encode `src` as one backward bitstream.
Result!size_t huffEncodeStream(ref const HuffmanEncTable t,
    scope const(ubyte)[] src, scope ubyte[] dst) pure nothrow @nogc
{
    auto w = ZstdBackBitWriter(dst);
    foreach_reverse (b; src)
        w.writeBits(t.code[b], t.len[b]);
    return w.finish();
}


