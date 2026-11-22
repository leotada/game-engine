/**
 * Finite State Entropy (tANS) decoding support for ZSTD (RFC 8878 §4.1).
 *
 * Provides the normalized-count header reader, the decoding-table
 * builder, an RLE pseudo-table, and the two-state weight decoder used by
 * Huffman tree descriptions. Encoder-side pieces arrive in Phase 3.
 */
module zipd.compressor.zstd_fse;

import core.bitop : bsr;

import zipd.compressor.bitreader : BitReader;
import zipd.compressor.errors : Result, ErrorKind, ErrorInfo, noError,
    success, failure;
import zipd.compressor.zstd_bitstream : ZstdBackBitReader;

@safe:
nothrow:
@nogc:

/// Largest accuracy log any ZSTD FSE table may use.
enum uint maxFseAccuracyLog = 9;
/// Largest decoding table.
enum uint maxFseTableSize = 1u << maxFseAccuracyLog;

/// One decoding-table cell.
struct FseDecodeEntry
{
    ushort newState;
    ubyte  symbol;
    ubyte  numBits;
}

/// Decoding table. `accuracyLog == 0` is the RLE pseudo-table.
struct FseDecodeTable
{
    uint accuracyLog;
    FseDecodeEntry[maxFseTableSize] entries;
}

/// Normalized symbol counts parsed from a table description. A count of
/// -1 means "probability less than one".
struct FseNorm
{
    short[256] counts;
    uint symbolCount;
    uint accuracyLog;
}

private ErrorInfo corrupt(string m) pure nothrow @nogc
{
    return ErrorInfo(ErrorKind.corruptInput, m);
}

/// Parse an FSE table description from the start of `src`.
///
/// `maxAccuracyLog` and `maxSymbols` bound the table. On success returns
/// the number of bytes the description occupies.
Result!size_t readFseTableDescription(scope const(ubyte)[] src,
    uint maxAccuracyLog, uint maxSymbols, ref FseNorm norm) pure nothrow @nogc
{
    enum msg = "invalid FSE table description";
    auto br = BitReader(src);
    uint v;
    if (!br.readBits(4, v))
        return failure!size_t(ErrorKind.corruptInput, msg);
    const acc = v + 5;
    if (acc > maxAccuracyLog || acc > maxFseAccuracyLog)
        return failure!size_t(ErrorKind.corruptInput,
            "FSE accuracy log too large");

    norm.counts[] = 0;
    norm.accuracyLog = acc;

    int remaining = (1 << acc) + 1;
    int threshold = 1 << acc;
    uint nbBits = acc + 1;
    uint sym = 0;
    bool prevZero = false;

    while (remaining > 1)
    {
        if (prevZero)
        {
            while (true)
            {
                if (!br.readBits(2, v))
                    return failure!size_t(ErrorKind.corruptInput, msg);
                sym += v;
                if (sym > maxSymbols)
                    return failure!size_t(ErrorKind.corruptInput, msg);
                if (v != 3)
                    break;
            }
            prevZero = false;
        }
        const maxv = (2 * threshold - 1) - remaining;
        uint low;
        if (!br.readBits(nbBits - 1, low))
            return failure!size_t(ErrorKind.corruptInput, msg);
        int count;
        if (cast(int) low < maxv)
            count = cast(int) low;
        else
        {
            uint hi;
            if (!br.readBits(1, hi))
                return failure!size_t(ErrorKind.corruptInput, msg);
            int full = cast(int)(low | (hi << (nbBits - 1)));
            count = full >= threshold ? full - maxv : full;
        }
        count--;
        remaining -= count < 0 ? -count : count;
        if (remaining < 1 || sym >= maxSymbols)
            return failure!size_t(ErrorKind.corruptInput, msg);
        norm.counts[sym++] = cast(short) count;
        prevZero = count == 0;
        while (remaining < threshold)
        {
            nbBits--;
            threshold >>= 1;
        }
    }
    norm.symbolCount = sym;
    return success(br.bytesConsumed);
}

/// Build the decoding table for normalized `counts[0 .. symbolCount]`.
ErrorInfo buildFseDecodeTable(ref FseDecodeTable t, scope const(short)[] counts,
    uint symbolCount, uint accuracyLog) pure nothrow @nogc
{
    if (accuracyLog == 0 || accuracyLog > maxFseAccuracyLog
        || symbolCount > 256 || symbolCount > counts.length)
        return corrupt("bad FSE table parameters");
    const size = 1u << accuracyLog;
    t.accuracyLog = accuracyLog;

    ushort[256] next;
    int high = cast(int) size - 1;
    foreach (s; 0 .. symbolCount)
    {
        if (counts[s] == -1)
        {
            t.entries[high].symbol = cast(ubyte) s;
            high--;
            next[s] = 1;
        }
        else
            next[s] = cast(ushort) counts[s];
    }

    const step = (size >> 1) + (size >> 3) + 3;
    const mask = size - 1;
    uint pos = 0;
    foreach (s; 0 .. symbolCount)
    {
        if (counts[s] <= 0)
            continue;
        foreach (i; 0 .. cast(uint) counts[s])
        {
            t.entries[pos].symbol = cast(ubyte) s;
            pos = (pos + step) & mask;
            while (cast(int) pos > high)
                pos = (pos + step) & mask;
        }
    }
    if (pos != 0)
        return corrupt("FSE counts do not fill the table");

    foreach (u; 0 .. size)
    {
        const s = t.entries[u].symbol;
        const ns = next[s]++;
        const nb = accuracyLog - cast(uint) bsr(cast(uint) ns);
        t.entries[u].numBits = cast(ubyte) nb;
        t.entries[u].newState = cast(ushort)((cast(uint) ns << nb) - size);
    }
    return noError;
}

/// Single-symbol (RLE) pseudo-table: zero accuracy bits, never changes.
void makeRleTable(ref FseDecodeTable t, ubyte symbol) pure nothrow @nogc
{
    t.accuracyLog = 0;
    t.entries[0] = FseDecodeEntry(0, symbol, 0);
}

/// Decode a Huffman weight list: two interleaved FSE states sharing
/// `table`, read from the backward bitstream `stream`. Fills `dst` from
/// the start and returns the number of weights decoded.
Result!size_t fseDecodeInterleaved(scope const(ubyte)[] stream,
    ref const FseDecodeTable table, scope ubyte[] dst) pure nothrow @nogc
{
    enum msg = "invalid FSE-compressed weights";
    auto rr = ZstdBackBitReader.create(stream);
    if (!rr.ok)
        return failure!size_t(ErrorKind.corruptInput,
            "invalid backward bitstream");
    auto r = rr.value;

    uint s1, s2;
    if (!r.readBits(table.accuracyLog, s1) || !r.readBits(table.accuracyLog, s2))
        return failure!size_t(ErrorKind.corruptInput, msg);

    size_t n = 0;
    while (true)
    {
        if (n + 2 > dst.length)
            return failure!size_t(ErrorKind.corruptInput, msg);
        const e1 = table.entries[s1];
        dst[n++] = e1.symbol;
        uint b;
        if (!r.readBitsPadded(e1.numBits, b))
        {
            dst[n++] = table.entries[s2].symbol;
            break;
        }
        s1 = e1.newState + b;

        const e2 = table.entries[s2];
        dst[n++] = e2.symbol;
        if (!r.readBitsPadded(e2.numBits, b))
        {
            dst[n++] = table.entries[s1].symbol;
            break;
        }
        s2 = e2.newState + b;
    }
    return success(n);
}


