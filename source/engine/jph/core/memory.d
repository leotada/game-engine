// Jolt — Core/Memory.h equivalent: allocation primitives that bypass the GC.
//
// Jolt funnels every allocation through `JPH::Allocate`/`JPH::Free` and
// `JPH::AlignedAllocate`/`JPH::AlignedFree`. We expose the same surface as
// `jphAlloc`/`jphFree`/`jphAlignedAlloc`/`jphAlignedFree`, plus the helpers
// `jphNew!T` and `jphDelete!T` that mirror Jolt's use of `new` / `delete` on
// `RefTarget`-derived classes. All of them go through the C runtime allocator
// so the GC never sees the memory and `@nogc nothrow` propagates cleanly
// through the engine frame loop.
//
// Source: ref/JoltPhysics/Jolt/Core/Memory.{h,cpp}.
module engine.jph.core.memory;

import core.stdc.stdlib : malloc, free, realloc;
import core.stdc.string : memset, memcpy;
import core.lifetime : emplace;

@safe:

// ---------------------------------------------------------------------------
// Plain heap allocation
// ---------------------------------------------------------------------------

void* jphAlloc(size_t bytes) @trusted @nogc nothrow {
    if (bytes == 0) return null;
    auto p = malloc(bytes);
    assert(p !is null, "jphAlloc: out of memory");
    return p;
}

void jphFree(void* p) @trusted @nogc nothrow {
    if (p is null) return;
    free(p);
}

void* jphRealloc(void* p, size_t bytes) @trusted @nogc nothrow {
    auto np = realloc(p, bytes);
    assert(bytes == 0 || np !is null, "jphRealloc: out of memory");
    return np;
}

// ---------------------------------------------------------------------------
// Aligned heap allocation (used by Vec3/Vec4/Mat44 buffers and TempAllocator
// when JPH_RVECTOR_ALIGNMENT > the platform default of 16).
// ---------------------------------------------------------------------------

/// Allocates `bytes` bytes aligned to `alignment` (must be power of two).
/// Stores the original `malloc` pointer just before the returned address so
/// `jphAlignedFree` can recover it. Mirrors Jolt's `AlignedAllocate`.
void* jphAlignedAlloc(size_t bytes, size_t alignment) @trusted @nogc nothrow {
    if (bytes == 0) return null;
    assert((alignment & (alignment - 1)) == 0, "alignment must be power of two");
    immutable extra = alignment - 1 + (void*).sizeof;
    auto raw = cast(ubyte*) malloc(bytes + extra);
    assert(raw !is null, "jphAlignedAlloc: out of memory");
    immutable addr = cast(size_t) raw + (void*).sizeof;
    immutable aligned = (addr + alignment - 1) & ~(alignment - 1);
    auto user = cast(ubyte*) aligned;
    *(cast(void**)(user - (void*).sizeof)) = raw;
    return user;
}

void jphAlignedFree(void* p) @trusted @nogc nothrow {
    if (p is null) return;
    auto raw = *(cast(void**)(cast(ubyte*) p - (void*).sizeof));
    free(raw);
}

// ---------------------------------------------------------------------------
// Class new/delete mirroring Jolt's `new`/`delete` for RefTarget-derived
// classes. Uses `core.lifetime.emplace` to construct in place over a malloc'd
// block. `jphDelete` invokes the compiler-generated combined destructor
// (`__xdtor`, which walks the inheritance chain) and frees the block.
// ---------------------------------------------------------------------------

T jphNew(T, A...)(auto ref A args) @trusted @nogc nothrow if (is(T == class)) {
    enum size = __traits(classInstanceSize, T);
    auto raw = malloc(size);
    assert(raw !is null, "jphNew: out of memory");
    auto chunk = (cast(ubyte*) raw)[0 .. size];
    return emplace!T(chunk, args);
}

void jphDelete(T)(T obj) @system @nogc nothrow if (is(T == class)) {
    if (obj is null) return;
    static if (__traits(hasMember, T, "__xdtor"))
        obj.__xdtor();
    free(cast(void*) obj);
}

/// Same as `jphNew` but for POD struct instances on the heap.
T* jphNewStruct(T, A...)(auto ref A args) @trusted @nogc nothrow if (is(T == struct)) {
    auto raw = malloc(T.sizeof);
    assert(raw !is null, "jphNewStruct: out of memory");
    auto chunk = (cast(ubyte*) raw)[0 .. T.sizeof];
    return emplace!T(chunk, args);
}

void jphDeleteStruct(T)(T* p) @system @nogc nothrow if (is(T == struct)) {
    if (p is null) return;
    static if (__traits(hasMember, T, "__xdtor"))
        p.__xdtor();
    free(cast(void*) p);
}
