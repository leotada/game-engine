// Jolt — Core/TempAllocator.h equivalent. A LIFO bump allocator carved out of
// a single up-front `malloc`. Used by the physics solver and broadphase to
// hand out scratch memory inside a frame without per-allocation overhead.
//
// Allocations must be freed in reverse order, exactly like Jolt; the
// implementation asserts this.
//
// Source: ref/JoltPhysics/Jolt/Core/TempAllocator.h.
module engine.jph.core.tempallocator;

import engine.jph.core.memory : jphAlignedAlloc, jphAlignedFree;
import engine.jph.core.types  : uint_;

@safe:

/// Alignment matches Jolt's `JPH_RVECTOR_ALIGNMENT` (Vec3/Vec4 are 16-byte).
enum size_t cTempAllocatorAlignment = 16;

abstract class TempAllocator {
    void* Allocate(uint_ size) @nogc nothrow @safe;
    void  Free(void* address, uint_ size) @nogc nothrow @safe;
}

/// Default impl backed by one large aligned `malloc`.
final class TempAllocatorImpl : TempAllocator {
    private ubyte* mBase = null;
    private size_t mSize = 0;
    private size_t mTop  = 0;

    this(size_t size) @trusted @nogc nothrow {
        mSize = size;
        mBase = cast(ubyte*) jphAlignedAlloc(size, cTempAllocatorAlignment);
    }

    ~this() @trusted @nogc nothrow {
        assert(mTop == 0, "TempAllocator destroyed with outstanding allocations");
        jphAlignedFree(cast(void*) mBase);
    }

    override void* Allocate(uint_ size) @trusted @nogc nothrow {
        if (size == 0) return null;
        immutable rounded = alignUp(size, cTempAllocatorAlignment);
        immutable newTop  = mTop + rounded;
        assert(newTop <= mSize, "TempAllocator: out of memory");
        auto p = cast(void*)(mBase + mTop);
        mTop = newTop;
        return p;
    }

    override void Free(void* address, uint_ size) @trusted @nogc nothrow {
        if (address is null) {
            assert(size == 0);
            return;
        }
        immutable rounded = alignUp(size, cTempAllocatorAlignment);
        mTop -= rounded;
        assert(cast(ubyte*)(mBase + mTop) is cast(ubyte*) address,
               "TempAllocator: free out of order");
    }

    bool   IsEmpty() const @safe @nogc nothrow { return mTop == 0; }
    size_t GetSize()  const @safe @nogc nothrow { return mSize; }
    size_t GetUsage() const @safe @nogc nothrow { return mTop; }
    bool   CanAllocate(uint_ size) const @safe @nogc nothrow {
        return mTop + alignUp(size, cTempAllocatorAlignment) <= mSize;
    }
}

/// `Allocate`/`Free` no-ops fall back to the heap (matches Jolt's
/// `TempAllocatorMalloc` for testing scenarios). Each block is freed
/// independently and order doesn't matter.
final class TempAllocatorMalloc : TempAllocator {
    override void* Allocate(uint_ size) @trusted @nogc nothrow {
        return jphAlignedAlloc(size, cTempAllocatorAlignment);
    }

    override void Free(void* address, uint_ size) @trusted @nogc nothrow {
        jphAlignedFree(address);
    }
}

private size_t alignUp(size_t v, size_t align_) pure nothrow @nogc @safe {
    return (v + align_ - 1) & ~(align_ - 1);
}
