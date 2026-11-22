/**
 * Malloc-backed scratch buffers for the `@nogc` zstd codec.
 *
 * Local addition to the vendored zipd sources: the upstream codec allocates
 * its working memory with the GC, which the engine forbids on the streaming
 * thread. Memory is released explicitly (`freeScratch`) or by the owning
 * struct's destructor.
 */
module zipd.compressor.scratch;

import core.stdc.stdlib : malloc, free;

@safe:
nothrow:
@nogc:

/// Allocate `n` uninitialised elements, or return `null` when out of memory.
/// `T` must not contain GC pointers.
T[] allocScratch(T)(size_t n) @trusted
    if (__traits(isPOD, T))
{
    if (n == 0)
        return null;
    if (n > size_t.max / T.sizeof)
        return null;
    auto p = cast(T*) malloc(n * T.sizeof);
    if (p is null)
        return null;
    return p[0 .. n];
}

/// Release a buffer from `allocScratch` and reset the slice.
void freeScratch(T)(ref T[] buf) @trusted
{
    if (buf.ptr !is null)
        free(buf.ptr);
    buf = null;
}
