/**
 * FSE (tANS) encoder support for ZSTD (RFC 8878 §4.1).
 *
 * Count normalization, table-description writer, compression tables and
 * the per-symbol encode step. The matching decoder lives in `zstd_fse`.
 */
module zipd.compressor.zstd_fse_enc;

import core.bitop : bsr;

import zipd.compressor.errors : Result, ErrorKind, ErrorInfo, noError,
    success, failure;
import zipd.compressor.zstd_bitstream : ZstdBackBitWriter;
import zipd.compressor.zstd_fse : maxFseTableSize, maxFseAccuracyLog;

@safe:
nothrow:
@nogc:

/// Per-symbol transform constants.
struct FseSymbolTT
{
    int deltaNbBits;
    int deltaFindState;
}

/// Compression table. `rle` tables carry no bits at all.
struct FseCTable
{
    uint tableLog;
    bool rle;
    ushort[maxFseTableSize] stateTable;
    FseSymbolTT[256] symbolTT;
}

/// Pick an accuracy log for `srcSize` symbols over an alphabet whose
/// largest symbol is `maxSymbol` (mirrors the reference heuristic).
uint optimalTableLog(uint maxLog, size_t srcSize, uint maxSymbol)
    pure nothrow @nogc
{
    const minBitsSrc = (srcSize > 0 ? cast(uint) bsr(srcSize) : 0) + 1;
    const minBitsSym = (maxSymbol > 0 ? cast(uint) bsr(maxSymbol) : 0) + 2;
    const minBits = minBitsSrc < minBitsSym ? minBitsSrc : minBitsSym;
    const lg = srcSize > 1 ? cast(uint) bsr(srcSize - 1) : 0;
    const maxBitsSrc = lg > 2 ? lg - 2 : 0;
    uint tl = maxLog;
    if (maxBitsSrc < tl)
        tl = maxBitsSrc;
    if (minBits > tl)
        tl = minBits;
    if (tl < 5)
        tl = 5;
    if (tl > maxLog)
        tl = maxLog;
    return tl;
}

/// Normalize `counts[0 .. symbolCount]` (total `total`) so the result
/// sums to `1 << tableLog`, giving every present symbol at least 1.
ErrorInfo normalizeCounts(scope const(uint)[] counts, uint symbolCount,
    size_t total, uint tableLog, scope short[] norm) pure nothrow @nogc
{
    const size = 1u << tableLog;
    uint present = 0;
    foreach (s; 0 .. symbolCount)
        if (counts[s] != 0)
            present++;
    if (present > size || total == 0)
        return ErrorInfo(ErrorKind.internal, "FSE alphabet exceeds table");

    uint sum = 0;
    foreach (s; 0 .. symbolCount)
    {
        if (counts[s] == 0)
        {
            norm[s] = 0;
            continue;
        }
        uint v = cast(uint)((cast(ulong) counts[s] * size) / total);
        if (v < 1)
            v = 1;
        norm[s] = cast(short) v;
        sum += v;
    }
    while (sum > size)
    {
        uint best = uint.max;
        short bv = 1;
        foreach (s; 0 .. symbolCount)
            if (norm[s] > bv)
            {
                bv = norm[s];
                best = s;
            }
        if (best == uint.max)
            return ErrorInfo(ErrorKind.internal, "FSE normalization failed");
        norm[best]--;
        sum--;
    }
    if (sum < size)
    {
        uint best = 0;
        short bv = 0;
        foreach (s; 0 .. symbolCount)
            if (norm[s] > bv)
            {
                bv = norm[s];
                best = s;
            }
        norm[best] += cast(short)(size - sum);
    }
    return noError;
}

/// Serialize a table description for `norm[0 .. symbolCount]` (the last
/// symbol must be non-zero). Returns bytes written.
Result!size_t writeFseTableDescription(scope const(short)[] norm,
    uint symbolCount, uint tableLog, scope ubyte[] dst) pure nothrow @nogc
{
    ulong acc = 0;
    uint nbits = 0;
    size_t pos = 0;
    bool overflow = false;

    void put(uint value, uint n) pure nothrow @nogc @safe
    {
        acc |= cast(ulong) value << nbits;
        nbits += n;
        while (nbits >= 8)
        {
            if (pos >= dst.length)
            {
                overflow = true;
                return;
            }
            dst[pos++] = cast(ubyte)(acc & 0xFF);
            acc >>= 8;
            nbits -= 8;
        }
    }

    put(tableLog - 5, 4);
    int remaining = (1 << tableLog) + 1;
    int threshold = 1 << tableLog;
    uint nb = tableLog + 1;
    uint sym = 0;
    bool prevZero = false;

    while (remaining > 1)
    {
        if (prevZero)
        {
            uint start = sym;
            while (sym < symbolCount && norm[sym] == 0)
                sym++;
            uint n0 = sym - start;
            while (n0 >= 3)
            {
                put(3, 2);
                n0 -= 3;
            }
            put(n0, 2);
            prevZero = false;
            if (sym >= symbolCount)
                break;
        }
        if (sym >= symbolCount)
            return failure!size_t(ErrorKind.internal, "bad FSE counts");
        int count = norm[sym++];
        const maxv = (2 * threshold - 1) - remaining;
        remaining -= count < 0 ? -count : count;
        count++;
        if (count >= threshold)
            count += maxv;
        put(cast(uint) count, count < maxv ? nb - 1 : nb);
        prevZero = count == 1;
        if (remaining < 1)
            return failure!size_t(ErrorKind.internal, "bad FSE counts");
        while (remaining < threshold)
        {
            nb--;
            threshold >>= 1;
        }
    }
    if (nbits > 0)
    {
        if (pos >= dst.length)
            overflow = true;
        else
            dst[pos++] = cast(ubyte)(acc & 0xFF);
    }
    if (overflow)
        return failure!size_t(ErrorKind.internal,
            "FSE description buffer too small");
    return success(pos);
}

/// Build the compression table for normalized counts.
ErrorInfo buildFseCTable(ref FseCTable ct, scope const(short)[] norm,
    uint symbolCount, uint tableLog) pure nothrow @nogc
{
    if (tableLog == 0 || tableLog > maxFseAccuracyLog || symbolCount > 256)
        return ErrorInfo(ErrorKind.internal, "bad FSE table parameters");
    const size = 1u << tableLog;
    const mask = size - 1;
    const step = (size >> 1) + (size >> 3) + 3;
    ct.tableLog = tableLog;
    ct.rle = false;

    ubyte[maxFseTableSize] tableSymbol;
    uint[258] cumul;
    int high = cast(int) size - 1;
    cumul[0] = 0;
    foreach (u; 1 .. symbolCount + 1)
    {
        if (norm[u - 1] == -1)
        {
            cumul[u] = cumul[u - 1] + 1;
            tableSymbol[high--] = cast(ubyte)(u - 1);
        }
        else
            cumul[u] = cumul[u - 1] + norm[u - 1];
    }
    uint position = 0;
    foreach (s; 0 .. symbolCount)
    {
        if (norm[s] <= 0)
            continue;
        foreach (i; 0 .. cast(uint) norm[s])
        {
            tableSymbol[position] = cast(ubyte) s;
            position = (position + step) & mask;
            while (cast(int) position > high)
                position = (position + step) & mask;
        }
    }
    if (position != 0)
        return ErrorInfo(ErrorKind.internal, "FSE counts do not fill table");

    foreach (u; 0 .. size)
    {
        const s = tableSymbol[u];
        ct.stateTable[cumul[s]++] = cast(ushort)(size + u);
    }

    int total = 0;
    foreach (s; 0 .. symbolCount)
    {
        const n = norm[s];
        if (n == 0)
        {
            ct.symbolTT[s].deltaNbBits = cast(int)(((tableLog + 1) << 16) - size);
        }
        else if (n == -1 || n == 1)
        {
            ct.symbolTT[s].deltaNbBits = cast(int)((tableLog << 16) - size);
            ct.symbolTT[s].deltaFindState = total - 1;
            total++;
        }
        else
        {
            const maxBitsOut = tableLog - cast(uint) bsr(cast(uint)(n - 1));
            const minStatePlus = cast(uint) n << maxBitsOut;
            ct.symbolTT[s].deltaNbBits = cast(int)((maxBitsOut << 16) - minStatePlus);
            ct.symbolTT[s].deltaFindState = total - n;
            total += n;
        }
    }
    return noError;
}

/// RLE pseudo-table (no state, no bits).
void makeRleCTable(ref FseCTable ct) pure nothrow @nogc
{
    ct.tableLog = 0;
    ct.rle = true;
}

/// Initialise `state` for the first symbol encoded (no bits emitted).
uint fseInitState(ref const FseCTable ct, uint symbol) pure nothrow @nogc
{
    const tt = ct.symbolTT[symbol];
    const nb = cast(uint)(tt.deltaNbBits + (1 << 15)) >> 16;
    const st = (nb << 16) - cast(uint) tt.deltaNbBits;
    return ct.stateTable[cast(int)(st >> nb) + tt.deltaFindState];
}

/// Encode `symbol`, emitting the bits that identify the previous state.
void fseEncodeSymbol(ref ZstdBackBitWriter w, ref const FseCTable ct,
    ref uint state, uint symbol) pure nothrow @nogc
{
    const tt = ct.symbolTT[symbol];
    const nb = (state + cast(uint) tt.deltaNbBits) >> 16;
    w.writeBits(state, nb);
    state = ct.stateTable[cast(int)(state >> nb) + tt.deltaFindState];
}

/// Write the final state (`tableLog` bits).
void fseFlushState(ref ZstdBackBitWriter w, ref const FseCTable ct,
    uint state) pure nothrow @nogc
{
    w.writeBits(state, ct.tableLog);
}

/// Encode `symbols` as the interleaved two-state stream used for Huffman
/// weights. Needs at least two symbols. Returns bytes written.
Result!size_t fseEncodeInterleaved(scope const(ubyte)[] symbols,
    ref const FseCTable ct, scope ubyte[] dst) pure nothrow @nogc
{
    const m = symbols.length;
    if (m < 2)
        return failure!size_t(ErrorKind.internal, "too few weights for FSE");
    auto w = ZstdBackBitWriter(dst);
    uint st1, st2;
    // Even indices belong to state 1, odd indices to state 2.
    if ((m - 1) % 2 == 0)
    {
        st1 = fseInitState(ct, symbols[m - 1]);
        st2 = fseInitState(ct, symbols[m - 2]);
    }
    else
    {
        st2 = fseInitState(ct, symbols[m - 1]);
        st1 = fseInitState(ct, symbols[m - 2]);
    }
    if (m >= 3)
    {
        size_t k = m - 2;
        while (k > 0)
        {
            k--;
            if (k % 2 == 0)
                fseEncodeSymbol(w, ct, st1, symbols[k]);
            else
                fseEncodeSymbol(w, ct, st2, symbols[k]);
        }
    }
    fseFlushState(w, ct, st2);
    fseFlushState(w, ct, st1);
    return w.finish();
}



