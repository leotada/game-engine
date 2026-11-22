/**
 * ZSTD frame decoder (RFC 8878).
 *
 * Decodes one or more concatenated frames (skipping skippable frames)
 * into a caller-provided buffer. If the buffer is too small the call
 * fails with `ErrorKind.internal` so the caller can retry with a larger
 * one, mirroring `deflateDecode`.
 */
module zipd.compressor.zstd_dec;

import zipd.compressor.errors : Result, ErrorKind, ErrorInfo, noError,
    success, failure;
import zipd.compressor.scratch : allocScratch, freeScratch;
import zipd.compressor.xxhash : xxh64Low32;
import zipd.compressor.zstd_bitstream : ZstdBackBitReader;
import zipd.compressor.zstd_fse;
import zipd.compressor.zstd_frame;
import zipd.compressor.zstd_huffman;
import zipd.compressor.zstd_sequences : resolveOffset, initialRep;
import zipd.compressor.zstd_tables;

@safe:
nothrow:
@nogc:

/// Outcome of `zstdDecode`.
struct ZstdDecodeResult
{
    /// Input bytes consumed (the whole input on success).
    size_t consumed;
    /// Output bytes produced.
    size_t produced;
    /// Number of data frames decoded (skippable frames excluded).
    ulong  frames;
}

private ErrorInfo corrupt(string m) pure nothrow @nogc
{
    return ErrorInfo(ErrorKind.corruptInput, m);
}

private enum ErrorInfo errSmall = ErrorInfo(ErrorKind.internal,
    "zstd output buffer too small");

/// Per-frame decoder state (reset at every frame boundary).
private struct FrameState
{
    uint[3] rep = initialRep;
    HuffmanTable huff;
    bool hasHuff;
    FseDecodeTable ll, of, ml;
    bool hasLl, hasOf, hasMl;
    ubyte[] lit;
    size_t litLen;

    void reset() pure nothrow @nogc
    {
        rep = initialRep;
        hasHuff = hasLl = hasOf = hasMl = false;
        litLen = 0;
    }
}

/**
 * Decode every frame in `src` into `dst`.
 *
 * `maxWindow` caps the window size a frame may declare.
 */
Result!ZstdDecodeResult zstdDecode(scope const(ubyte)[] src,
    scope ubyte[] dst, ulong maxWindow = zstdDefaultMaxWindow) @safe
{
    if (src.length == 0)
        return failure!ZstdDecodeResult(ErrorKind.corruptInput,
            "empty zstd input");

    FrameState st;
    st.lit = allocScratch!ubyte(zstdBlockMaxSize);
    if (st.lit.length == 0)
        return failure!ZstdDecodeResult(ErrorKind.internal,
            "zstd decoder out of memory");
    scope (exit)
        freeScratch(st.lit);

    ZstdDecodeResult res;
    size_t pos = 0;
    size_t outPos = 0;
    while (pos < src.length)
    {
        const rest = src[pos .. $];
        if (isZstdSkippableMagic(rest))
        {
            auto sk = parseZstdSkippableFrame(rest);
            if (!sk.ok)
                return failure!ZstdDecodeResult(sk.error.kind, sk.error.message);
            pos += sk.value;
            continue;
        }
        if (!isZstdFrameMagic(rest))
            return failure!ZstdDecodeResult(ErrorKind.corruptInput,
                "bad zstd magic number");
        st.reset();
        size_t used;
        auto e = decodeFrame(rest, dst, outPos, st, maxWindow, used);
        if (!e.ok)
            return failure!ZstdDecodeResult(e.kind, e.message);
        pos += used;
        res.frames++;
    }
    res.consumed = pos;
    res.produced = outPos;
    return success(res);
}

private ErrorInfo decodeFrame(scope const(ubyte)[] src, scope ubyte[] dst,
    ref size_t outPos, ref FrameState st, ulong maxWindow,
    out size_t used) @safe
{
    auto hr = parseZstdFrameHeader(src, maxWindow);
    if (!hr.ok)
        return hr.error;
    const hdr = hr.value;
    if (hdr.dictId != 0)
        return ErrorInfo(ErrorKind.unsupported,
            "zstd dictionary frames are not supported");

    const frameStart = outPos;
    size_t pos = hdr.headerSize;
    const blockMax = hdr.windowSize < zstdBlockMaxSize
        ? cast(size_t) hdr.windowSize : zstdBlockMaxSize;

    while (true)
    {
        auto bh = parseZstdBlockHeader(src[pos .. $]);
        if (!bh.ok)
            return bh.error;
        pos += zstdBlockHeaderSize;
        const b = bh.value;
        if (b.blockSize > blockMax)
            return corrupt("zstd block larger than window");

        final switch (b.type)
        {
            case ZstdBlockType.raw:
                if (src.length - pos < b.blockSize)
                    return corrupt("truncated zstd raw block");
                if (dst.length - outPos < b.blockSize)
                    return errSmall;
                dst[outPos .. outPos + b.blockSize] =
                    src[pos .. pos + b.blockSize];
                outPos += b.blockSize;
                pos += b.blockSize;
                break;
            case ZstdBlockType.rle:
                if (src.length - pos < 1)
                    return corrupt("truncated zstd RLE block");
                if (dst.length - outPos < b.blockSize)
                    return errSmall;
                dst[outPos .. outPos + b.blockSize] = src[pos];
                outPos += b.blockSize;
                pos += 1;
                break;
            case ZstdBlockType.compressed:
                if (src.length - pos < b.blockSize)
                    return corrupt("truncated zstd compressed block");
                auto e = decodeCompressedBlock(st,
                    src[pos .. pos + b.blockSize], dst, outPos, frameStart,
                    hdr.windowSize);
                if (!e.ok)
                    return e;
                pos += b.blockSize;
                break;
            case ZstdBlockType.reserved:
                return corrupt("reserved zstd block type");
        }
        if (b.lastBlock)
            break;
    }

    const produced = outPos - frameStart;
    if (hdr.hasContentSize && produced != hdr.contentSize)
        return corrupt("zstd frame content size mismatch");

    if (hdr.hasChecksum)
    {
        auto ck = parseZstdChecksum(src[pos .. $]);
        if (!ck.ok)
            return ck.error;
        if (ck.value != xxh64Low32(dst[frameStart .. outPos]))
            return ErrorInfo(ErrorKind.checksum, "zstd content checksum mismatch");
        pos += zstdChecksumSize;
    }
    used = pos;
    return noError;
}

// ------------------------------------------------------------------ //
// Literals section

private ErrorInfo decodeLiterals(ref FrameState st, scope const(ubyte)[] blk,
    ref size_t pos) pure nothrow @nogc @safe
{
    if (blk.length < 1)
        return corrupt("empty zstd compressed block");
    const b0 = blk[0];
    const type = b0 & 3;
    const fmt = (b0 >> 2) & 3;

    if (type < 2)
    {
        size_t hdr;
        uint size;
        if ((fmt & 1) == 0)
        {
            hdr = 1;
            size = b0 >> 3;
        }
        else if (fmt == 1)
        {
            if (blk.length < 2) return corrupt("truncated literals header");
            hdr = 2;
            size = (b0 >> 4) | (cast(uint) blk[1] << 4);
        }
        else
        {
            if (blk.length < 3) return corrupt("truncated literals header");
            hdr = 3;
            size = (b0 >> 4) | (cast(uint) blk[1] << 4)
                | (cast(uint) blk[2] << 12);
        }
        if (size > zstdBlockMaxSize)
            return corrupt("literals exceed block size");
        if (type == 0)
        {
            if (blk.length - hdr < size)
                return corrupt("truncated raw literals");
            st.lit[0 .. size] = blk[hdr .. hdr + size];
            pos = hdr + size;
        }
        else
        {
            if (blk.length - hdr < 1)
                return corrupt("truncated RLE literals");
            st.lit[0 .. size] = blk[hdr];
            pos = hdr + 1;
        }
        st.litLen = size;
        return noError;
    }

    size_t hdr;
    uint nbits;
    if (fmt <= 1) { hdr = 3; nbits = 10; }
    else if (fmt == 2) { hdr = 4; nbits = 14; }
    else { hdr = 5; nbits = 18; }
    if (blk.length < hdr)
        return corrupt("truncated literals header");
    ulong v = 0;
    foreach (i; 0 .. hdr)
        v |= cast(ulong) blk[i] << (8 * i);
    const mask = (1UL << nbits) - 1;
    const regen = cast(size_t)((v >> 4) & mask);
    const comp = cast(size_t)((v >> (4 + nbits)) & mask);
    if (regen == 0 || regen > zstdBlockMaxSize)
        return corrupt("bad literals regenerated size");
    if (blk.length - hdr < comp)
        return corrupt("truncated compressed literals");
    auto payload = blk[hdr .. hdr + comp];

    if (type == 2)
    {
        auto t = readHuffmanTreeDescription(payload, st.huff);
        if (!t.ok)
            return t.error;
        payload = payload[t.value .. $];
        st.hasHuff = true;
    }
    else if (!st.hasHuff)
        return corrupt("treeless literals without a previous tree");

    ErrorInfo e;
    if (fmt == 0)
        e = huffDecodeStream(payload, st.huff, st.lit[0 .. regen]);
    else
        e = huffDecode4Streams(payload, st.huff, st.lit[0 .. regen]);
    if (!e.ok)
        return e;
    st.litLen = regen;
    pos = hdr + comp;
    return noError;
}

// ------------------------------------------------------------------ //
// Sequences

private ErrorInfo setupTable(ref FseDecodeTable t, ref bool has, uint mode,
    uint maxAcc, uint maxSymbols, scope const(short)[] defNorm, uint defAcc,
    scope const(ubyte)[] s, ref size_t sp) pure nothrow @nogc @safe
{
    switch (mode)
    {
        case 0:
            auto e = buildFseDecodeTable(t, defNorm, cast(uint) defNorm.length,
                defAcc);
            if (!e.ok) return e;
            has = true;
            return noError;
        case 1:
            if (sp >= s.length)
                return corrupt("truncated RLE sequence table");
            const sym = s[sp++];
            if (sym >= maxSymbols)
                return corrupt("RLE sequence symbol out of range");
            makeRleTable(t, sym);
            has = true;
            return noError;
        case 2:
            FseNorm norm;
            auto r = readFseTableDescription(s[sp .. $], maxAcc, maxSymbols, norm);
            if (!r.ok)
                return r.error;
            sp += r.value;
            auto e = buildFseDecodeTable(t, norm.counts[], norm.symbolCount,
                norm.accuracyLog);
            if (!e.ok) return e;
            has = true;
            return noError;
        default:
            if (!has)
                return corrupt("repeat mode without a previous table");
            return noError;
    }
}

private ErrorInfo decodeCompressedBlock(ref FrameState st,
    scope const(ubyte)[] blk, scope ubyte[] dst, ref size_t outPos,
    size_t frameStart, ulong windowSize) @safe
{
    size_t pos = 0;
    auto le = decodeLiterals(st, blk, pos);
    if (!le.ok)
        return le;

    auto s = blk[pos .. $];
    if (s.length == 0)
        return corrupt("missing sequences section");

    // Number_of_Sequences.
    size_t sp = 0;
    uint nSeq;
    if (s[0] == 0)
    {
        nSeq = 0;
        sp = 1;
    }
    else if (s[0] < 128)
    {
        nSeq = s[0];
        sp = 1;
    }
    else if (s[0] < 255)
    {
        if (s.length < 2) return corrupt("truncated sequence count");
        nSeq = ((cast(uint) s[0] - 128) << 8) + s[1];
        sp = 2;
    }
    else
    {
        if (s.length < 3) return corrupt("truncated sequence count");
        nSeq = cast(uint) s[1] + (cast(uint) s[2] << 8) + 0x7F00;
        sp = 3;
    }

    size_t blockOut = 0;
    size_t litPos = 0;

    if (nSeq > 0)
    {
        if (sp >= s.length)
            return corrupt("missing symbol compression modes");
        const modes = s[sp++];
        if ((modes & 3) != 0)
            return corrupt("reserved sequence mode bits set");

        auto e = setupTable(st.ll, st.hasLl, modes >> 6, maxLlAccuracyLog,
            llSymbolCount, llDefaultNorm[], predefinedLlAccuracyLog, s, sp);
        if (!e.ok) return e;
        e = setupTable(st.of, st.hasOf, (modes >> 4) & 3, maxOfAccuracyLog,
            ofSymbolCount, ofDefaultNorm[], predefinedOfAccuracyLog, s, sp);
        if (!e.ok) return e;
        e = setupTable(st.ml, st.hasMl, (modes >> 2) & 3, maxMlAccuracyLog,
            mlSymbolCount, mlDefaultNorm[], predefinedMlAccuracyLog, s, sp);
        if (!e.ok) return e;

        auto rr = ZstdBackBitReader.create(s[sp .. $]);
        if (!rr.ok)
            return corrupt("invalid sequence bitstream");
        auto rd = rr.value;

        uint llS, ofS, mlS;
        if (!rd.readBits(st.ll.accuracyLog, llS)
            || !rd.readBits(st.of.accuracyLog, ofS)
            || !rd.readBits(st.ml.accuracyLog, mlS))
            return corrupt("truncated sequence bitstream");

        foreach (i; 0 .. nSeq)
        {
            const eL = st.ll.entries[llS];
            const eO = st.of.entries[ofS];
            const eM = st.ml.entries[mlS];
            const ofC = eO.symbol;
            const mlC = eM.symbol;
            const llC = eL.symbol;

            uint ofx, mlx, llx;
            if (!rd.readBits(ofC, ofx)
                || !rd.readBits(mlExtraBits[mlC], mlx)
                || !rd.readBits(llExtraBits[llC], llx))
                return corrupt("truncated sequence bitstream");
            const offsetValue = (1u << ofC) + ofx;
            const matchLen = mlBase[mlC] + mlx;
            const litLen = llBase[llC] + llx;

            if (i + 1 < nSeq)
            {
                uint b;
                if (!rd.readBits(eL.numBits, b))
                    return corrupt("truncated sequence bitstream");
                llS = eL.newState + b;
                if (!rd.readBits(eM.numBits, b))
                    return corrupt("truncated sequence bitstream");
                mlS = eM.newState + b;
                if (!rd.readBits(eO.numBits, b))
                    return corrupt("truncated sequence bitstream");
                ofS = eO.newState + b;
            }

            // Resolve the offset against the repeat-offset history.
            uint offset;
            if (!resolveOffset(offsetValue, litLen, st.rep, offset))
                return corrupt("zero repeat offset");

            // Execute the sequence.
            if (litLen > st.litLen - litPos)
                return corrupt("sequence literals exceed literals section");
            blockOut += cast(size_t) litLen + matchLen;
            if (blockOut > zstdBlockMaxSize)
                return corrupt("zstd block exceeds 128 KiB");
            if (offset > outPos - frameStart + litLen || offset > windowSize)
                return corrupt("zstd match offset out of range");
            if (dst.length - outPos < cast(size_t) litLen + matchLen)
                return errSmall;

            dst[outPos .. outPos + litLen] = st.lit[litPos .. litPos + litLen];
            outPos += litLen;
            litPos += litLen;
            foreach (k; 0 .. matchLen)
            {
                dst[outPos] = dst[outPos - offset];
                outPos++;
            }
        }
        if (!rd.isFinished())
            return corrupt("unconsumed bits in sequence bitstream");
    }

    // Remaining literals.
    const rem = st.litLen - litPos;
    blockOut += rem;
    if (blockOut > zstdBlockMaxSize)
        return corrupt("zstd block exceeds 128 KiB");
    if (dst.length - outPos < rem)
        return errSmall;
    dst[outPos .. outPos + rem] = st.lit[litPos .. litPos + rem];
    outPos += rem;
    return noError;
}
