/**
 * Per-frame bump-pointer arena for transient allocations.
 *
 * `FrameArena` provides fast, zero-overhead allocation for data that dies
 * at the end of the current frame (debug strings, AI scratch arrays,
 * HUD labels, particle temporaries, etc.).  The engine calls `reset()`
 * once per frame in `endFrame()`, which simply rewinds the cursor.
 *
 * All memory comes from a single pre-allocated `ubyte[]` buffer.  The GC
 * sees it as one root, not thousands of small allocations.
 *
 * Only `isPod` types may be allocated — no class refs or slices that
 * would create hidden GC roots.
 *
 * See docs/gc-safe-architecture-plan.md §2.4.
 */
module engine.core.arena;

import engine.core.pod : isPod;

@safe:

struct FrameArena
{
    private ubyte[] buffer;
    private size_t  cursor;

    /// Create an arena with the given capacity in bytes.
    this(size_t capacity) @trusted
    {
        buffer = new ubyte[](capacity);
        cursor = 0;
    }

    /**
     * Allocate `n` elements of type `T` from the arena.
     * Returns a zero-initialised slice.  Returns `null` if the arena is
     * exhausted (caller should fall back to GC or report an error).
     */
    T[] alloc(T)(size_t n) @trusted if (isPod!T)
    {
        import core.stdc.string : memset;

        immutable bytes = T.sizeof * n;
        // Align to T.alignof.
        immutable mask  = T.alignof - 1;
        immutable aligned = (cursor + mask) & ~mask;

        if (aligned + bytes > buffer.length)
            return null;

        auto ptr = cast(T*)(buffer.ptr + aligned);
        memset(ptr, 0, bytes);
        cursor = aligned + bytes;
        return ptr[0 .. n];
    }

    /**
     * Format a string into the arena.  Returns a `char[]` slice into arena
     * memory (valid until `reset()`).  Returns `null` on overflow.
     */
    char[] fmt(Args...)(string pattern, Args args) @trusted
    {
        import std.format : sformat;

        immutable mask    = char.alignof - 1;
        immutable aligned = (cursor + mask) & ~mask;
        immutable avail   = buffer.length > aligned ? buffer.length - aligned : 0;

        if (avail == 0) return null;

        auto dest = cast(char[])(buffer[aligned .. aligned + avail]);
        char[] result;
        try
            result = sformat(dest, pattern, args);
        catch (Exception)
            return null;  // pattern overflows available space

        cursor = aligned + result.length;
        return result;
    }

    /// Rewind the arena.  Call once per frame in `endFrame()`.
    void reset() @nogc nothrow @safe
    {
        cursor = 0;
    }

    /// How many bytes are currently in use.
    size_t used() const @nogc nothrow pure @safe { return cursor; }

    /// Total capacity in bytes.
    size_t capacity() const @nogc nothrow pure @safe { return buffer.length; }
}

///
@safe unittest
{
    auto arena = FrameArena(4096);

    auto ints = arena.alloc!int(10);
    assert(ints !is null);
    assert(ints.length == 10);
    assert(ints[0] == 0);

    auto label = arena.fmt("fps=%d", 60);
    assert(label !is null);
    assert(label == "fps=60");

    assert(arena.used > 0);
    arena.reset();
    assert(arena.used == 0);
}
