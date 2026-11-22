/**
 * LSB-first bit reader over a byte slice.
 *
 * DEFLATE (RFC 1951) packs bits little-endian per byte: the first bit
 * of a code occupies the lowest bit of the first byte. `BitReader`
 * exposes that as a stream-of-bits API on top of a borrowed
 * `const(ubyte)[]`.
 *
 * The reader is purely `@safe` and `@nogc`, holds no references past
 * its lifetime, and never reads past the end of its slice (it returns
 * `false` instead).
 */
module zipd.compressor.bitreader;

@safe:
nothrow:
@nogc:

/// LSB-first bit reader. Lifetime: the underlying slice must outlive
/// the reader. Borrowing is enforced by `scope`.
struct BitReader
{
    private const(ubyte)[] src;
    private size_t   pos;     /// byte index of the next byte to consume
    private uint     bitBuf;  /// pending bits (low order = next bit out)
    private uint     bitCount;/// number of valid bits in `bitBuf`

    /// Construct over `data`. Borrows; the caller owns the slice.
    this(return scope const(ubyte)[] data) pure nothrow @nogc @safe return scope
    {
        this.src = data;
    }

    /// Bytes consumed from the original slice, including any byte
    /// whose bits are partially in the bit buffer.
    size_t bytesConsumed() const pure nothrow @nogc @safe scope
    {
        return pos;
    }

    /// Number of bits currently buffered (0..31).
    uint bufferedBits() const pure nothrow @nogc @safe scope { return bitCount; }

    /// Discard pending bits up to the next byte boundary.
    void alignToByte() pure nothrow @nogc @safe scope
    {
        const drop = bitCount & 7;
        bitBuf >>= drop;
        bitCount -= drop;
        // Whole-byte leftovers in the buffer become inaccessible after
        // alignment is followed by direct byte reads, so push them back
        // into pos accounting.
        while (bitCount >= 8)
        {
            // Roll back: a buffered byte is one we already consumed.
            // Aligning means stored-block byte reads start *after* it,
            // so we keep pos as-is and just drop those buffered bits.
            bitBuf >>= 8;
            bitCount -= 8;
            // Note: we don't actually need to rewind src; the only
            // legitimate caller (stored block) flushes via this path
            // and re-reads from `pos`. To preserve correctness we
            // rewind `pos` for any whole bytes still buffered.
            pos -= 1;
        }
    }

    /// Read `nBits` (1..24) low-order bits LSB-first. Returns false on
    /// end-of-stream; on success writes the value to `value`.
    bool readBits(uint nBits, out uint value) pure nothrow @nogc @safe scope
    {
        assert(nBits >= 1 && nBits <= 24);
        while (bitCount < nBits)
        {
            if (pos >= src.length)
                return false;
            bitBuf |= (cast(uint) src[pos]) << bitCount;
            pos += 1;
            bitCount += 8;
        }
        value = bitBuf & ((1u << nBits) - 1u);
        bitBuf >>= nBits;
        bitCount -= nBits;
        return true;
    }

    /// Convenience: read `nBits` and return the value, or `uint.max`
    /// if the stream is exhausted.
    uint readBitsOr(uint nBits, uint orElse) pure nothrow @nogc @safe scope
    {
        uint v;
        return readBits(nBits, v) ? v : orElse;
    }

    /// After `alignToByte`, copy `n` raw bytes into `dst[0 .. n]`.
    /// Returns false if the source has fewer than `n` bytes left.
    bool readBytes(scope ubyte[] dst) pure nothrow @nogc @safe scope
    {
        assert(bitCount == 0,
            "readBytes requires the reader to be byte-aligned");
        if (pos + dst.length > src.length)
            return false;
        dst[] = src[pos .. pos + dst.length];
        pos += dst.length;
        return true;
    }

    /// Skip `n` bytes after `alignToByte`.
    bool skipBytes(size_t n) pure nothrow @nogc @safe scope
    {
        assert(bitCount == 0, "skipBytes requires byte alignment");
        if (pos + n > src.length)
            return false;
        pos += n;
        return true;
    }

    /// True iff at least `n` bytes remain after the bit buffer.
    bool hasBytes(size_t n) const pure nothrow @nogc @safe scope
    {
        return pos + n <= src.length;
    }
}



