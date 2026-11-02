// Ported from meshoptimizer v1.3 (src/allocator.cpp), Copyright (c) 2016-2026 Arseny Kapoulkine, MIT License.
/// Malloc-backed bump allocator. Blocks are kept after `release` so a steady
/// import stops calling `malloc`. Replaces `meshopt_setAllocator`.
module engine.meshopt.scratch;

import core.stdc.stdlib : free, malloc;
import engine.core.pod : isPod;

@safe:

private struct Block {
    void* ptr;
    size_t capacity;
}

/**
 * Stack-ordered bump allocator for meshopt temporaries.
 *
 * `allocate` does not zero memory. `release` rewinds the bump cursor and
 * keeps the underlying blocks. Copying is disabled because the destructor
 * frees those blocks.
 */
struct MeshoptScratch {
    @disable this(this);

    private Block* blocks;
    private size_t blockCount;
    private size_t blockCap;
    private size_t current;
    private size_t offset;
    private size_t mallocs;

    private size_t* marks;
    private size_t markDepth;
    private size_t markCap;

    /// Number of `malloc` calls since this scratch was created.
    size_t mallocCount() const pure nothrow @nogc {
        return mallocs;
    }

    /// Push the bump cursor. Pass the result to `release`.
    size_t mark() nothrow @nogc @trusted {
        if (markDepth == markCap)
            growMarks();
        marks[markDepth * 2] = current;
        marks[markDepth * 2 + 1] = offset;
        return markDepth++;
    }

    /// Rewind to a cursor returned by `mark`. Does not free blocks.
    void release(size_t token) nothrow @nogc @trusted {
        assert(token <= markDepth);
        if (token == markDepth)
            return;
        current = marks[token * 2];
        offset = marks[token * 2 + 1];
        markDepth = token;
    }

    /// Bump-allocate `n` POD values. The slice is invalidated by a `release`
    /// that rewinds past it, and by the destructor.
    T[] allocate(T)(size_t n) nothrow @nogc @trusted
    if (isPod!T) {
        if (n == 0)
            return null;
        assert(T.sizeof == 0 || n <= size_t.max / T.sizeof);
        size_t align_ = T.alignof < 1 ? 1 : T.alignof;
        void* p = bump(n * T.sizeof, align_);
        return (cast(T*) p)[0 .. n];
    }

    ~this() nothrow @nogc @trusted {
        if (blocks !is null) {
            foreach (i; 0 .. blockCount)
                free(blocks[i].ptr);
            free(blocks);
            blocks = null;
        }
        if (marks !is null) {
            free(marks);
            marks = null;
        }
        blockCount = 0;
        blockCap = 0;
        markDepth = 0;
        markCap = 0;
        current = 0;
        offset = 0;
    }

    private void growMarks() nothrow @nogc @trusted {
        size_t ncap = markCap ? markCap * 2 : 32;
        size_t* nmem = cast(size_t*) malloc(ncap * 2 * size_t.sizeof);
        assert(nmem !is null);
        mallocs++;
        if (marks !is null) {
            foreach (i; 0 .. markCap * 2)
                nmem[i] = marks[i];
            free(marks);
        }
        marks = nmem;
        markCap = ncap;
    }

    private void* bump(size_t bytes, size_t align_) nothrow @nogc @trusted {
        if (bytes == 0)
            return null;
        size_t i = blockCount == 0 ? 0 : current;
        for (; i < blockCount; ++i) {
            size_t off = (i == current) ? offset : 0;
            size_t aligned = (off + (align_ - 1)) & ~(align_ - 1);
            if (aligned <= blocks[i].capacity && bytes <= blocks[i].capacity - aligned) {
                current = i;
                offset = aligned + bytes;
                return cast(void*)(cast(ubyte*) blocks[i].ptr + aligned);
            }
        }

        size_t cap = 64 * 1024;
        if (blockCount) {
            size_t grown = blocks[blockCount - 1].capacity * 2;
            if (grown > cap)
                cap = grown;
        }
        size_t need = bytes + align_;
        if (need > cap)
            cap = need;
        void* p = malloc(cap);
        assert(p !is null);
        mallocs++;

        if (blockCount == blockCap) {
            size_t ncap = blockCap ? blockCap * 2 : 8;
            Block* nb = cast(Block*) malloc(ncap * Block.sizeof);
            assert(nb !is null);
            mallocs++;
            foreach (k; 0 .. blockCount)
                nb[k] = blocks[k];
            if (blocks !is null)
                free(blocks);
            blocks = nb;
            blockCap = ncap;
        }
        blocks[blockCount].ptr = p;
        blocks[blockCount].capacity = cap;
        current = blockCount;
        blockCount++;
        // glibc malloc is aligned to at least 16. Larger alignments pad inside the block.
        size_t aligned = align_ > 16 ? (align_ - 1) & ~(align_ - 1) : 0;
        offset = aligned + bytes;
        return cast(void*)(cast(ubyte*) p + aligned);
    }
}

private const(void)* slicePtr(T)(T[] s) nothrow @nogc @trusted {
    return s.ptr;
}

private MeshoptScratch tlsScratch;

/// Thread-local scratch used when a caller does not pass its own.
ref MeshoptScratch defaultScratch() nothrow @nogc {
    return tlsScratch;
}

@safe nothrow unittest {
    static assert(!__traits(compiles, {
        MeshoptScratch a;
        MeshoptScratch b = a;
    }));

    static struct NotPod { int* p; }
    static assert(!isPod!NotPod);
    static assert(!__traits(compiles, tlsScratch.allocate!NotPod(1)));

    MeshoptScratch s;
    immutable m0 = s.mark();
    int[] a = s.allocate!int(4);
    a[] = 1;
    immutable m1 = s.mark();
    int[] b = s.allocate!int(4);
    b[] = 2;
    const(void)* bptr = slicePtr(b);
    s.release(m1);
    int[] c = s.allocate!int(4);
    assert(slicePtr(c) is bptr);
    s.release(m0);

    immutable afterWarm = s.mallocCount();
    immutable m2 = s.mark();
    int[] d = s.allocate!int(10_000);
    d[] = 3;
    s.release(m2);
    immutable warmed = s.mallocCount();
    foreach (_; 0 .. 8) {
        immutable m = s.mark();
        int[] e = s.allocate!int(10_000);
        e[0] = 1;
        s.release(m);
    }
    assert(s.mallocCount() == warmed);

    import core.memory : GC;
    immutable used = GC.stats().usedSize;
    immutable alloc = GC.stats().allocatedInCurrentThread;
    foreach (_; 0 .. 50) {
        immutable m = s.mark();
        int[] e = s.allocate!int(1024);
        e[0] = 7;
        float[] f = s.allocate!float(128);
        f[0] = 1;
        s.release(m);
    }
    assert(GC.stats().usedSize == used);
    assert(GC.stats().allocatedInCurrentThread == alloc);
    assert(s.mallocCount() == warmed || s.mallocCount() >= afterWarm);
}
