/**
 * ZSTD backward bitstreams (RFC 8878 §4.1).
 *
 * The encoder writes bits LSB-first into a byte buffer and terminates the
 * stream with a single `1` sentinel bit (padded with zeros to a byte
 * boundary). The decoder locates the sentinel in the last byte and reads
 * bits starting from the sentinel downward, so the *last* bits written
 * are the *first* bits read.
 */
module zipd.compressor.zstd_bitstream;

import core.bitop : bsr;

import zipd.compressor.errors : Result, ErrorKind, success, failure;

@safe:
nothrow:
@nogc:

/// Backward bit reader over a borrowed slice.
struct ZstdBackBitReader
{
    private const(ubyte)[] src;
    /// Number of data bits still unread; they are bits `0 .. remaining`.
    private size_t remaining;

    /// Locate the sentinel bit. Fails if the last byte is zero or the
    /// slice is empty.
    static Result!ZstdBackBitReader create(return scope const(ubyte)[] slice)
        pure nothrow @nogc
    {
        if (slice.length == 0)
            return failure!ZstdBackBitReader(ErrorKind.corruptInput,
                "empty backward bitstream");
        const last = slice[$ - 1];
        if (last == 0)
            return failure!ZstdBackBitReader(ErrorKind.corruptInput,
                "backward bitstream missing sentinel bit");
        ZstdBackBitReader r;
        r.src = slice;
        r.remaining = (slice.length - 1) * 8 + cast(uint) bsr(cast(uint) last);
        return success(r);
    }

    /// Unread data bits.
    size_t bitsRemaining() const pure nothrow @nogc scope
    {
        return remaining;
    }

    /// True once every data bit has been consumed.
    bool isFinished() const pure nothrow @nogc scope
    {
        return remaining == 0;
    }

    /// Read `nBits` (0..32). Returns false (and consumes nothing) if
    /// fewer bits remain.
    bool readBits(uint nBits, out uint value) pure nothrow @nogc scope
    {
        assert(nBits <= 32);
        value = 0;
        if (nBits == 0)
            return true;
        if (nBits > remaining)
            return false;
        const start = remaining - nBits;
        const firstByte = start >> 3;
        const lastByte = (remaining - 1) >> 3;
        ulong acc = 0;
        foreach (i; firstByte .. lastByte + 1)
            acc |= cast(ulong) src[i] << ((i - firstByte) * 8);
        acc >>= (start & 7);
        value = cast(uint)(acc & ((1UL << nBits) - 1));
        remaining = start;
        return true;
    }

    /// Like `readBits`, but when fewer than `nBits` remain the missing
    /// low-order bits read as zero, the stream is drained, and `false`
    /// is returned (the "overflow" condition of the reference decoder).
    bool readBitsPadded(uint nBits, out uint value) pure nothrow @nogc scope
    {
        assert(nBits <= 32);
        if (nBits <= remaining)
            return readBits(nBits, value);
        const k = cast(uint) remaining;
        uint hi = 0;
        if (k > 0)
            readBits(k, hi);
        value = k == 0 ? 0 : hi << (nBits - k);
        remaining = 0;
        return false;
    }

    /// Peek `nBits` (0..32) without consuming; missing bits read as zero.
    uint peekBits(uint nBits) const pure nothrow @nogc scope
    {
        ZstdBackBitReader copy;
        copy.src = src;
        copy.remaining = remaining;
        uint v;
        copy.readBitsPadded(nBits, v);
        return v;
    }

    /// Discard `nBits`. Returns false (and drains) on overflow.
    bool skipBits(uint nBits) pure nothrow @nogc scope
    {
        if (nBits > remaining)
        {
            remaining = 0;
            return false;
        }
        remaining -= nBits;
        return true;
    }
}

/// Backward bit writer producing a stream for `ZstdBackBitReader`.
struct ZstdBackBitWriter
{
    private ubyte[] buf;
    private size_t pos;
    private ulong bitBuf;
    private uint bitCount;
    private bool overflow;

    this(return scope ubyte[] output) pure nothrow @nogc return scope
    {
        this.buf = output;
    }

    /// Append `nBits` (0..32) low-order bits of `value`. Overflow is
    /// sticky and reported by `finish`.
    void writeBits(uint value, uint nBits) pure nothrow @nogc scope
    {
        assert(nBits <= 32);
        if (nBits == 0)
            return;
        bitBuf |= (cast(ulong) value & ((1UL << nBits) - 1)) << bitCount;
        bitCount += nBits;
        if (bitCount >= 32)
        {
            if (pos + 4 <= buf.length)
            {
                buf[pos]     = cast(ubyte)(bitBuf & 0xFF);
                buf[pos + 1] = cast(ubyte)((bitBuf >> 8) & 0xFF);
                buf[pos + 2] = cast(ubyte)((bitBuf >> 16) & 0xFF);
                buf[pos + 3] = cast(ubyte)((bitBuf >> 24) & 0xFF);
                pos += 4;
                bitBuf >>= 32;
                bitCount -= 32;
            }
            else
            {
                while (bitCount >= 8)
                {
                    if (pos >= buf.length)
                    {
                        overflow = true;
                        bitBuf = 0;
                        bitCount = 0;
                        return;
                    }
                    buf[pos++] = cast(ubyte)(bitBuf & 0xFF);
                    bitBuf >>= 8;
                    bitCount -= 8;
                }
            }
        }
    }

    /// Write the sentinel bit and pad to a byte boundary. Returns the
    /// total stream length in bytes.
    Result!size_t finish() pure nothrow @nogc scope
    {
        writeBits(1, 1);
        while (!overflow && bitCount >= 8)
        {
            if (pos >= buf.length)
            {
                overflow = true;
                bitBuf = 0;
                bitCount = 0;
                break;
            }
            buf[pos++] = cast(ubyte)(bitBuf & 0xFF);
            bitBuf >>= 8;
            bitCount -= 8;
        }
        if (!overflow && bitCount > 0)
        {
            if (pos >= buf.length)
                overflow = true;
            else
            {
                buf[pos++] = cast(ubyte)(bitBuf & 0xFF);
                bitBuf = 0;
                bitCount = 0;
            }
        }
        if (overflow)
            return failure!size_t(ErrorKind.internal,
                "backward bit writer output buffer overflow");
        return success(pos);
    }
}




