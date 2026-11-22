/**
 * ZSTD frame encoder.
 *
 * Emits a single RFC 8878 frame with a declared content size and an
 * XXH64 content checksum. Blocks (<= 128 KiB) are encoded as RLE, raw, or
 * compressed (Huffman literals + FSE-coded sequences, with predefined,
 * RLE or per-block FSE tables). Repeat-mode tables and treeless literals
 * are not emitted; every compressed block is self-contained.
 */
module zipd.compressor.zstd_enc;

import core.bitop : bsr;
import std.math : log2;

import zipd.compressor.scratch : allocScratch, freeScratch;
import zipd.compressor.errors : Result, ErrorKind, success, failure;
import zipd.compressor.xxhash : xxh64Low32;
import zipd.compressor.zstd_bitstream : ZstdBackBitWriter;
import zipd.compressor.zstd_fse_enc;
import zipd.compressor.zstd_frame;
import zipd.compressor.zstd_huffman_enc;
import zipd.compressor.zstd_lz;
import zipd.compressor.zstd_sequences;
import zipd.compressor.zstd_tables;

@safe:
nothrow:
@nogc:

/// Largest window the encoder advertises (1 MiB).
enum uint zstdMaxEncoderWindowLog = 20;

/// Worst-case output size for `inputLen` bytes.
size_t zstdEncodeBound(size_t inputLen) pure nothrow @nogc
{
    const blocks = inputLen / zstdBlockMaxSize + 1;
    return 16 + blocks * zstdBlockHeaderSize + inputLen + zstdChecksumSize;
}

// ------------------------------------------------------------------ //
// Literals section

private size_t litSizeHeader(uint type, size_t n, scope ubyte[] o)
    pure nothrow @nogc
{
    if (n < 32)
    {
        o[0] = cast(ubyte)(type | (n << 3));
        return 1;
    }
    if (n < 4096)
    {
        o[0] = cast(ubyte)(type | (1 << 2) | ((n & 15) << 4));
        o[1] = cast(ubyte)(n >> 4);
        return 2;
    }
    o[0] = cast(ubyte)(type | (3 << 2) | ((n & 15) << 4));
    o[1] = cast(ubyte)((n >> 4) & 0xFF);
    o[2] = cast(ubyte)(n >> 12);
    return 3;
}

/// Try a Huffman-compressed literals section. Returns its size, or 0 if
/// it does not fit or is not representable.
private size_t tryHuffmanLiterals(scope const(ubyte)[] lits, scope ubyte[] o,
    scope ubyte[] tmp) pure nothrow @nogc
{
    const n = lits.length;
    uint[256] hist;
    foreach (b; lits)
        hist[b]++;
    HuffmanEncTable t;
    if (!buildHuffmanEncTable(t, hist[]))
        return 0;

    ubyte[300] tree;
    auto tr = writeHuffmanTreeDescription(t, tree[]);
    if (!tr.ok)
        return 0;

    const four = n >= 256;
    size_t streamBytes = 0;
    size_t[3] sz;
    if (!four)
    {
        auto e = huffEncodeStream(t, lits, tmp);
        if (!e.ok)
            return 0;
        streamBytes = e.value;
    }
    else
    {
        const seg = (n + 3) / 4;
        size_t off = 0;
        foreach (k; 0 .. 4)
        {
            const lo = k * seg;
            const hi = k == 3 ? n : (k + 1) * seg;
            auto e = huffEncodeStream(t, lits[lo .. hi], tmp[off .. $]);
            if (!e.ok)
                return 0;
            if (k < 3)
            {
                if (e.value > 0xFFFF)
                    return 0;
                sz[k] = e.value;
            }
            off += e.value;
        }
        streamBytes = off;
    }

    const comp = tr.value + (four ? 6 : 0) + streamBytes;
    uint fmt, nbits;
    size_t hdr;
    if (!four)
    {
        fmt = 0; nbits = 10; hdr = 3;
    }
    else if (n <= 1023 && comp <= 1023)
    {
        fmt = 1; nbits = 10; hdr = 3;
    }
    else if (n <= 16383 && comp <= 16383)
    {
        fmt = 2; nbits = 14; hdr = 4;
    }
    else
    {
        fmt = 3; nbits = 18; hdr = 5;
    }
    if (n >= (1UL << nbits) || comp >= (1UL << nbits))
        return 0;
    if (o.length < hdr + comp)
        return 0;

    const ulong v = 2 | (fmt << 2) | (cast(ulong) n << 4)
        | (cast(ulong) comp << (4 + nbits));
    foreach (i; 0 .. hdr)
        o[i] = cast(ubyte)((v >> (8 * i)) & 0xFF);
    size_t p = hdr;
    o[p .. p + tr.value] = tree[0 .. tr.value];
    p += tr.value;
    if (four)
    {
        foreach (k; 0 .. 3)
        {
            o[p++] = cast(ubyte)(sz[k] & 0xFF);
            o[p++] = cast(ubyte)(sz[k] >> 8);
        }
    }
    o[p .. p + streamBytes] = tmp[0 .. streamBytes];
    return p + streamBytes;
}

private size_t encodeLiterals(scope const(ubyte)[] lits, scope ubyte[] o,
    scope ubyte[] tmp) pure nothrow @nogc
{
    const n = lits.length;
    if (n >= 2)
    {
        bool uniform = true;
        foreach (b; lits)
            if (b != lits[0])
            {
                uniform = false;
                break;
            }
        if (uniform)
        {
            const h = litSizeHeader(1, n, o);
            o[h] = lits[0];
            return h + 1;
        }
    }
    ubyte[4] probe;
    const rawHdr = litSizeHeader(0, n, probe[]);
    if (n >= 32)
    {
        const hs = tryHuffmanLiterals(lits, o, tmp);
        if (hs != 0 && hs < rawHdr + n)
            return hs;
    }
    const h = litSizeHeader(0, n, o);
    o[h .. h + n] = lits[];
    return h + n;
}

// ------------------------------------------------------------------ //
// Sequences section

private enum uint modePredefined = 0;
private enum uint modeRle = 1;
private enum uint modeFse = 2;

private struct TableChoice
{
    uint mode;
    ubyte rleSymbol;
    ubyte[300] header;
    size_t headerLen;
}

private double fastLog2(uint v) pure nothrow @nogc
{
    static immutable double[256] table = [
        0.000000, 1.000000, 1.584963, 2.000000, 2.321928, 2.584963, 2.807355, 3.000000,
        3.169925, 3.321928, 3.459432, 3.584963, 3.700440, 3.807355, 3.906891, 4.000000,
        4.087463, 4.169925, 4.247928, 4.321928, 4.392317, 4.459432, 4.523562, 4.584963,
        4.643856, 4.700440, 4.754888, 4.807355, 4.857981, 4.906891, 4.954196, 5.000000,
        5.044394, 5.087463, 5.129283, 5.169925, 5.209453, 5.247928, 5.285402, 5.321928,
        5.357552, 5.392317, 5.426265, 5.459432, 5.491853, 5.523562, 5.554589, 5.584963,
        5.614710, 5.643856, 5.672425, 5.700440, 5.727920, 5.754888, 5.781360, 5.807355,
        5.832890, 5.857981, 5.882643, 5.906891, 5.930737, 5.954196, 5.977280, 6.000000,
        6.022368, 6.044394, 6.066089, 6.087463, 6.108524, 6.129283, 6.149747, 6.169925,
        6.189825, 6.209453, 6.228819, 6.247928, 6.266787, 6.285402, 6.303781, 6.321928,
        6.339850, 6.357552, 6.375039, 6.392317, 6.409391, 6.426265, 6.442943, 6.459432,
        6.475733, 6.491853, 6.507795, 6.523562, 6.539159, 6.554589, 6.569856, 6.584963,
        6.599913, 6.614710, 6.629357, 6.643856, 6.658211, 6.672425, 6.686501, 6.700440,
        6.714246, 6.727920, 6.741467, 6.754888, 6.768184, 6.781360, 6.794416, 6.807355,
        6.820179, 6.832890, 6.845490, 6.857981, 6.870365, 6.882643, 6.894818, 6.906891,
        6.918863, 6.930737, 6.942515, 6.954196, 6.965784, 6.977280, 6.988685, 7.000000,
        7.011227, 7.022368, 7.033423, 7.044394, 7.055282, 7.066089, 7.076816, 7.087463,
        7.098032, 7.108524, 7.118941, 7.129283, 7.139551, 7.149747, 7.159871, 7.169925,
        7.179909, 7.189825, 7.199672, 7.209453, 7.219169, 7.228819, 7.238405, 7.247928,
        7.257388, 7.266787, 7.276124, 7.285402, 7.294621, 7.303781, 7.312883, 7.321928,
        7.330917, 7.339850, 7.348728, 7.357552, 7.366322, 7.375039, 7.383704, 7.392317,
        7.400879, 7.409391, 7.417853, 7.426265, 7.434628, 7.442943, 7.451211, 7.459432,
        7.467606, 7.475733, 7.483816, 7.491853, 7.499846, 7.507795, 7.515700, 7.523562,
        7.531381, 7.539159, 7.546894, 7.554589, 7.562242, 7.569856, 7.577429, 7.584963,
        7.592457, 7.599913, 7.607330, 7.614710, 7.622052, 7.629357, 7.636625, 7.643856,
        7.651052, 7.658211, 7.665336, 7.672425, 7.679480, 7.686501, 7.693487, 7.700440,
        7.707359, 7.714246, 7.721099, 7.727920, 7.734710, 7.741467, 7.748193, 7.754888,
        7.761551, 7.768184, 7.774787, 7.781360, 7.787903, 7.794416, 7.800900, 7.807355,
        7.813781, 7.820179, 7.826548, 7.832890, 7.839204, 7.845490, 7.851749, 7.857981,
        7.864186, 7.870365, 7.876517, 7.882643, 7.888743, 7.894818, 7.900867, 7.906891,
        7.912889, 7.918863, 7.924813, 7.930737, 7.936638, 7.942515, 7.948367, 7.954196,
        7.960002, 7.965784, 7.971544, 7.977280, 7.982994, 7.988685, 7.994353, 8.000000
    ];
    if (v >= 1 && v <= 256)
        return table[v - 1];
    import std.math : log2;
    return log2(cast(double)(v < 1 ? 1 : v));
}

private bool chooseTable(scope const(uint)[] hist, uint symCount, size_t nSeq,
    uint maxLog, scope const(short)[] defNorm, uint defLog,
    ref FseCTable ct, ref TableChoice tc) pure nothrow @nogc
{
    uint distinct = 0, maxSym = 0, only = 0;
    foreach (s; 0 .. symCount)
        if (hist[s] != 0)
        {
            distinct++;
            maxSym = s;
            only = s;
        }
    if (distinct == 0)
        return false;
    if (distinct == 1)
    {
        tc.mode = modeRle;
        tc.rleSymbol = cast(ubyte) only;
        tc.headerLen = 0;
        makeRleCTable(ct);
        return true;
    }

    enum double inf = 1e300;
    double predCost = 0;
    foreach (s; 0 .. symCount)
    {
        if (hist[s] == 0)
            continue;
        if (s >= defNorm.length || defNorm[s] == 0)
        {
            predCost = inf;
            break;
        }
        const nv = defNorm[s] < 1 ? 1 : defNorm[s];
        predCost += hist[s] * (cast(double) defLog - fastLog2(cast(uint) nv));
    }

    double dynCost = inf;
    short[256] norm;
    const tl = optimalTableLog(maxLog, nSeq, maxSym);
    size_t hlen = 0;
    if (normalizeCounts(hist, maxSym + 1, nSeq, tl, norm[]).ok)
    {
        auto hw = writeFseTableDescription(norm[], maxSym + 1, tl, tc.header[]);
        if (hw.ok)
        {
            hlen = hw.value;
            dynCost = cast(double) hlen * 8;
            foreach (s; 0 .. maxSym + 1)
                if (hist[s] != 0)
                    dynCost += hist[s] * (cast(double) tl - fastLog2(cast(uint) (norm[s] < 1 ? 1 : norm[s])));
        }
    }

    if (predCost >= inf && dynCost >= inf)
        return false;
    if (predCost <= dynCost)
    {
        tc.mode = modePredefined;
        tc.headerLen = 0;
        return buildFseCTable(ct, defNorm, cast(uint) defNorm.length, defLog).ok;
    }
    tc.mode = modeFse;
    tc.headerLen = hlen;
    return buildFseCTable(ct, norm[], maxSym + 1, tl).ok;
}

private struct EncWorkspace
{
    ZstdSeq[] seqs;
    ubyte[] lits;
    ubyte[] llc, ofc, mlc;
    ubyte[] blk;
    ubyte[] tmp;

    /// Returns false when out of memory.
    bool allocate() nothrow @nogc
    {
        const maxSeq = zstdBlockMaxSize / 3 + 2;
        const blkLen = 2 * zstdBlockMaxSize + 4096;
        if (seqs.length < maxSeq)
        {
            freeScratch(seqs);
            seqs = allocScratch!ZstdSeq(maxSeq);
        }
        if (lits.length < zstdBlockMaxSize + 8)
        {
            freeScratch(lits);
            lits = allocScratch!ubyte(zstdBlockMaxSize + 8);
        }
        if (llc.length < maxSeq)
        {
            freeScratch(llc);
            llc = allocScratch!ubyte(maxSeq);
        }
        if (ofc.length < maxSeq)
        {
            freeScratch(ofc);
            ofc = allocScratch!ubyte(maxSeq);
        }
        if (mlc.length < maxSeq)
        {
            freeScratch(mlc);
            mlc = allocScratch!ubyte(maxSeq);
        }
        if (blk.length < blkLen)
        {
            freeScratch(blk);
            blk = allocScratch!ubyte(blkLen);
        }
        if (tmp.length < blkLen)
        {
            freeScratch(tmp);
            tmp = allocScratch!ubyte(blkLen);
        }
        return seqs.length != 0 && lits.length != 0 && llc.length != 0
            && ofc.length != 0 && mlc.length != 0 && blk.length != 0
            && tmp.length != 0;
    }

    void release() nothrow @nogc
    {
        freeScratch(seqs);
        freeScratch(lits);
        freeScratch(llc);
        freeScratch(ofc);
        freeScratch(mlc);
        freeScratch(blk);
        freeScratch(tmp);
    }
}

/// Reusable per-worker ZSTD encoding scratch buffers.
struct ZstdEncContext
{
    private EncWorkspace ws;
    private uint[] headBuf;
    private uint[] chainBuf;

    @disable this(this);

    ~this() nothrow @nogc
    {
        ws.release();
        freeScratch(headBuf);
        freeScratch(chainBuf);
    }
}

/// Write the sequences section. Returns bytes written or 0 on failure.
private size_t encodeSequences(ref EncWorkspace ws, size_t n, scope ubyte[] o)
    pure nothrow @nogc
{
    size_t pos = 0;
    if (o.length < 8)
        return 0;
    if (n == 0)
    {
        o[0] = 0;
        return 1;
    }
    if (n < 128)
        o[pos++] = cast(ubyte) n;
    else if (n < 0x7F00)
    {
        o[pos++] = cast(ubyte)((n >> 8) + 128);
        o[pos++] = cast(ubyte)(n & 0xFF);
    }
    else
    {
        o[pos++] = 255;
        o[pos++] = cast(ubyte)((n - 0x7F00) & 0xFF);
        o[pos++] = cast(ubyte)((n - 0x7F00) >> 8);
    }

    uint[llSymbolCount] llH;
    uint[ofSymbolCount] ofH;
    uint[mlSymbolCount] mlH;
    foreach (i; 0 .. n)
    {
        const s = ws.seqs[i];
        ws.llc[i] = cast(ubyte) llCode(s.litLength);
        ws.mlc[i] = cast(ubyte) mlCode(s.matchLength);
        ws.ofc[i] = cast(ubyte) ofCode(s.offsetValue);
        llH[ws.llc[i]]++;
        mlH[ws.mlc[i]]++;
        ofH[ws.ofc[i]]++;
    }

    FseCTable llT, ofT, mlT;
    TableChoice llC, ofC, mlC;
    if (!chooseTable(llH[], llSymbolCount, n, maxLlAccuracyLog,
            llDefaultNorm[], predefinedLlAccuracyLog, llT, llC)
        || !chooseTable(ofH[], ofSymbolCount, n, maxOfAccuracyLog,
            ofDefaultNorm[], predefinedOfAccuracyLog, ofT, ofC)
        || !chooseTable(mlH[], mlSymbolCount, n, maxMlAccuracyLog,
            mlDefaultNorm[], predefinedMlAccuracyLog, mlT, mlC))
        return 0;

    o[pos++] = cast(ubyte)((llC.mode << 6) | (ofC.mode << 4) | (mlC.mode << 2));
    void writeTableChoice(scope const ref TableChoice tc) pure nothrow @nogc @safe
    {
        if (tc.mode == modeRle)
            o[pos++] = tc.rleSymbol;
        else if (tc.mode == modeFse)
        {
            o[pos .. pos + tc.headerLen] = tc.header[0 .. tc.headerLen];
            pos += tc.headerLen;
        }
    }
    if (pos + llC.headerLen + ofC.headerLen + mlC.headerLen + 3 > o.length)
        return 0;
    writeTableChoice(llC);
    writeTableChoice(ofC);
    writeTableChoice(mlC);

    auto w = ZstdBackBitWriter(o[pos .. $]);
    uint stLL, stOF, stML;
    const last = n - 1;
    if (!mlT.rle) stML = fseInitState(mlT, ws.mlc[last]);
    if (!ofT.rle) stOF = fseInitState(ofT, ws.ofc[last]);
    if (!llT.rle) stLL = fseInitState(llT, ws.llc[last]);

    void extras(size_t i) pure nothrow @nogc @safe
    {
        const s = ws.seqs[i];
        const lc = ws.llc[i];
        const mc = ws.mlc[i];
        const oc = ws.ofc[i];
        w.writeBits(s.litLength - llBase[lc], llExtraBits[lc]);
        w.writeBits(s.matchLength - mlBase[mc], mlExtraBits[mc]);
        w.writeBits(s.offsetValue - (1u << oc), oc);
    }
    extras(last);
    size_t i = last;
    while (i > 0)
    {
        i--;
        if (!ofT.rle) fseEncodeSymbol(w, ofT, stOF, ws.ofc[i]);
        if (!mlT.rle) fseEncodeSymbol(w, mlT, stML, ws.mlc[i]);
        if (!llT.rle) fseEncodeSymbol(w, llT, stLL, ws.llc[i]);
        extras(i);
    }
    if (!mlT.rle) fseFlushState(w, mlT, stML);
    if (!ofT.rle) fseFlushState(w, ofT, stOF);
    if (!llT.rle) fseFlushState(w, llT, stLL);
    auto f = w.finish();
    if (!f.ok)
        return 0;
    return pos + f.value;
}

/// Encode block `[start, end)` as a compressed block body. Returns the
/// body size, or 0 if it could not be produced.
private size_t compressBlock(ref EncWorkspace ws, scope ref ZstdMatcher m,
    size_t start, size_t end, ref uint[3] rep) pure nothrow @nogc
{
    auto pr = m.parseBlock(start, end, rep, ws.seqs, ws.lits);
    const ls = encodeLiterals(ws.lits[0 .. pr.nLit], ws.blk, ws.tmp);
    if (ls == 0)
        return 0;
    const ss = encodeSequences(ws, pr.nSeq, ws.blk[ls .. $]);
    if (ss == 0)
        return 0;
    return ls + ss;
}

// ------------------------------------------------------------------ //
// Frame

/// Encode `input` as one ZSTD frame into `output`.
///
/// `level` (1..9) controls match-search effort; `storeOnly` forces raw
/// blocks. Returns bytes written.
Result!size_t zstdEncodeFrame(scope const(ubyte)[] input,
    scope ubyte[] output, uint level = 6, bool storeOnly = false) @safe
{
    ZstdEncContext ctx;
    return zstdEncodeFrameWithContext(ctx, input, output, level, storeOnly);
}

/// Encode `input` as one ZSTD frame into `output`, reusing scratch buffers in `ctx`.
Result!size_t zstdEncodeFrameWithContext(ref ZstdEncContext ctx,
    scope const(ubyte)[] input, scope ubyte[] output, uint level = 6,
    bool storeOnly = false) @safe
{
    if (output.length < zstdEncodeBound(input.length))
        return failure!size_t(ErrorKind.internal,
            "zstd encode buffer too small");
    if (input.length >= 0xFFFF_0000UL)
        return failure!size_t(ErrorKind.unsupported,
            "input too large for a single zstd frame");

    uint windowLog = 10;
    if (input.length > 1)
        windowLog = cast(uint) bsr(input.length - 1) + 1;
    if (windowLog < 10)
        windowLog = 10;
    if (windowLog > zstdMaxEncoderWindowLog)
        windowLog = zstdMaxEncoderWindowLog;

    ZstdFrameHeader h;
    h.windowSize = 1UL << windowLog;
    h.hasContentSize = true;
    h.contentSize = input.length;
    h.hasChecksum = true;
    auto hr = writeZstdFrameHeader(output, h);
    if (!hr.ok)
        return hr;
    size_t out_ = hr.value;

    scope ZstdMatcher matcher;
    uint[3] rep = initialRep;
    if (!storeOnly && input.length >= 16)
    {
        if (!ctx.ws.allocate())
            return failure!size_t(ErrorKind.internal,
                "zstd encoder out of memory");
        matcher.initWithBuffers(input, windowLog, level,
            ctx.headBuf, ctx.chainBuf);
        if (matcher.allocFailed)
            return failure!size_t(ErrorKind.internal,
                "zstd encoder out of memory");
    }

    size_t pos = 0;
    do
    {
        const rest = input.length - pos;
        const len = rest > zstdBlockMaxSize ? zstdBlockMaxSize : rest;
        const chunk = input[pos .. pos + len];
        const last = pos + len == input.length;

        bool uniform = len > 3 && !storeOnly;
        if (uniform)
            foreach (b; chunk)
                if (b != chunk[0])
                {
                    uniform = false;
                    break;
                }

        ZstdBlockHeader bh;
        bh.lastBlock = last;
        bh.blockSize = cast(uint) len;
        bool done = false;
        if (uniform)
        {
            bh.type = ZstdBlockType.rle;
            writeZstdBlockHeader(output[out_ .. $], bh);
            out_ += zstdBlockHeaderSize;
            output[out_++] = chunk[0];
            done = true;
        }
        else if (!storeOnly && input.length >= 16 && len >= 16)
        {
            const snapshot = rep;
            const cs = compressBlock(ctx.ws, matcher, pos, pos + len, rep);
            if (cs != 0 && cs < len)
            {
                bh.type = ZstdBlockType.compressed;
                bh.blockSize = cast(uint) cs;
                writeZstdBlockHeader(output[out_ .. $], bh);
                out_ += zstdBlockHeaderSize;
                output[out_ .. out_ + cs] = ctx.ws.blk[0 .. cs];
                out_ += cs;
                done = true;
            }
            else
                rep = snapshot;
        }
        if (!done)
        {
            bh.type = ZstdBlockType.raw;
            writeZstdBlockHeader(output[out_ .. $], bh);
            out_ += zstdBlockHeaderSize;
            output[out_ .. out_ + len] = chunk[];
            out_ += len;
        }
        pos += len;
    }
    while (pos < input.length);

    auto ck = writeZstdChecksum(output[out_ .. $], xxh64Low32(input));
    if (!ck.ok)
        return ck;
    return success(out_ + ck.value);
}




