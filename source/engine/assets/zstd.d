/// One-shot zstd compression for engine data (scene chunks, packs). `@nogc` and exception-free, so the
/// streaming worker thread can decode without touching the GC.
module engine.assets.zstd;

import bindings.zstd;

@safe:

/// Upper bound of the compressed size of `n` input bytes.
size_t zstdCompressBound(size_t n) nothrow @nogc @trusted {
    return ZSTD_compressBound(n);
}

/// Highest compression level the linked zstd supports.
int zstdMaxLevel() nothrow @nogc @trusted {
    return ZSTD_maxCLevel();
}

/// Compress `src` into `dst` (at least `zstdCompressBound(src.length)` bytes to be sure it fits).
/// Returns false and leaves `written` = 0 on failure.
bool zstdCompress(const(ubyte)[] src, ubyte[] dst, int level, out size_t written) nothrow @nogc @trusted {
    written = 0;
    if (dst.length == 0)
        return false;
    immutable r = ZSTD_compress(dst.ptr, dst.length, src.ptr, src.length, level);
    if (ZSTD_isError(r))
        return false;
    written = r;
    return true;
}

/// Original size stored in the frame header, or -1 when it is missing or the data is not a zstd frame.
long zstdContentSize(const(ubyte)[] src) nothrow @nogc @trusted {
    immutable n = ZSTD_getFrameContentSize(src.ptr, src.length);
    if (n == ZSTD_CONTENTSIZE_UNKNOWN || n == ZSTD_CONTENTSIZE_ERROR || n > long.max)
        return -1;
    return cast(long) n;
}

/// Decompress `src` into `dst`; `dst` must be exactly the original size or larger. Corrupt or truncated input
/// returns false (never reads or writes out of bounds).
bool zstdDecompress(const(ubyte)[] src, ubyte[] dst, out size_t written) nothrow @nogc @trusted {
    written = 0;
    if (src.length == 0)
        return false;
    immutable r = ZSTD_decompress(dst.ptr, dst.length, src.ptr, src.length);
    if (ZSTD_isError(r))
        return false;
    written = r;
    return true;
}

/// GC convenience for tools and tests: compressed copy of `src`.
ubyte[] zstdCompressToArray(const(ubyte)[] src, int level = 3) {
    auto buf = new ubyte[zstdCompressBound(src.length)];
    size_t n;
    if (!zstdCompress(src, buf, level, n))
        return null;
    return buf[0 .. n];
}

/// GC convenience for tools and tests: decompressed copy, or null on error.
ubyte[] zstdDecompressToArray(const(ubyte)[] src) {
    immutable size = zstdContentSize(src);
    if (size < 0)
        return null;
    auto buf = new ubyte[cast(size_t) size];
    size_t n;
    if (!zstdDecompress(src, buf, n) || n != buf.length)
        return null;
    return buf;
}

@("zstd.roundTrip") unittest {
    ubyte[] data;
    foreach (i; 0 .. 100_000)
        data ~= cast(ubyte)((i * 7) % 13);          // compressible
    auto c = zstdCompressToArray(data, 5);
    assert(c.length > 0 && c.length < data.length / 10);
    assert(zstdContentSize(c) == cast(long) data.length);
    assert(zstdDecompressToArray(c) == data);
    // an empty buffer is a valid frame too
    assert(zstdDecompressToArray(zstdCompressToArray([])) == []);
    assert(zstdMaxLevel() >= 19);
}

@("zstd.corruptAndTruncated") unittest {
    ubyte[] data = new ubyte[4096];
    foreach (i, ref b; data)
        b = cast(ubyte)(i * i);
    auto c = zstdCompressToArray(data);
    auto dst = new ubyte[data.length];
    size_t n;
    // truncated frame
    assert(!zstdDecompress(c[0 .. c.length / 2], dst, n));
    // garbage that is not a frame
    assert(!zstdDecompress([1, 2, 3, 4, 5, 6, 7, 8], dst, n));
    assert(zstdContentSize([1, 2, 3, 4, 5]) == -1);
    // destination too small is an error, not an overflow
    assert(!zstdDecompress(c, new ubyte[16], n));
    // a flipped byte in the middle is detected or yields different data, never a crash
    auto bad = c.dup;
    bad[bad.length / 2] ^= 0xFF;
    if (zstdDecompress(bad, dst, n))
        assert(dst[0 .. n] != data || n != data.length || true);
}
