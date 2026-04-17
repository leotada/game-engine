// Jolt — Core/Array.h equivalent. A drop-in `std::vector<T>`-like container
// backed by `malloc/realloc/free` so the GC never sees the storage. Used for
// every dynamically-sized buffer in the physics layer (constraint lists,
// island arrays, manifold pools, etc.).
//
// Move-only by design. Use `dup()` for an explicit deep copy.
//
// Source: ref/JoltPhysics/Jolt/Core/Array.h.
module engine.jph.core.array;

import core.lifetime : emplace, moveEmplace;
import core.stdc.string : memcpy, memmove;
import engine.jph.core.memory : jphAlloc, jphFree, jphRealloc;
import engine.jph.core.types : uint_;

@safe:

struct Array(T) {
@safe:
    private T* mData = null;
    private size_t mSize = 0;
    private size_t mCapacity = 0;

    @disable this(this);

    this(size_t initialSize) @trusted nothrow @nogc {
        if (initialSize == 0) return;
        reserve(initialSize);
        foreach (i; 0 .. initialSize) {
            emplace(&mData[i]);
        }
        mSize = initialSize;
    }

    ~this() nothrow @nogc {
        clear();
        if (mData !is null) {
            jphFree(cast(void*) mData);
            mData = null;
            mCapacity = 0;
        }
    }

    void reserve(size_t n) nothrow @nogc @trusted {
        if (n <= mCapacity) return;
        // Geometric growth (1.5x) like Jolt's grow strategy.
        size_t newCap = mCapacity == 0 ? 4 : mCapacity;
        while (newCap < n) newCap = newCap + (newCap >> 1) + 1;
        auto raw = jphRealloc(cast(void*) mData, newCap * T.sizeof);
        mData = cast(T*) raw;
        mCapacity = newCap;
    }

    void resize(size_t n) @trusted nothrow @nogc {
        if (n > mCapacity) reserve(n);
        if (n > mSize) {
            foreach (i; mSize .. n) emplace(&mData[i]);
        } else if (n < mSize) {
            destroyRange(n, mSize);
        }
        mSize = n;
    }

    void clear() nothrow @nogc {
        destroyRange(0, mSize);
        mSize = 0;
    }

    void push_back()(auto ref T v) @trusted nothrow @nogc {
        if (mSize == mCapacity) reserve(mSize + 1);
        emplace(&mData[mSize], v);
        ++mSize;
    }

    void emplace_back(A...)(auto ref A args) @trusted nothrow @nogc {
        if (mSize == mCapacity) reserve(mSize + 1);
        emplace(&mData[mSize], args);
        ++mSize;
    }

    void pop_back() @trusted nothrow @nogc {
        assert(mSize > 0);
        --mSize;
        destroyOne(mSize);
    }

    /// Swap-erase at index (matches Jolt's `erase` for unordered semantics).
    void erase(size_t i) nothrow @nogc @trusted {
        assert(i < mSize);
        if (i + 1 != mSize) {
            destroyOne(i);
            emplace(&mData[i], mData[mSize - 1]);
            destroyOne(mSize - 1);
        } else {
            destroyOne(i);
        }
        --mSize;
    }

    bool empty() const nothrow @nogc { return mSize == 0; }
    size_t size() const nothrow @nogc { return mSize; }
    size_t capacity() const nothrow @nogc { return mCapacity; }

    inout(T)* data() inout nothrow @nogc @trusted { return cast(inout(T)*) mData; }

    ref T opIndex(size_t i) return nothrow @nogc @trusted {
        assert(i < mSize);
        return mData[i];
    }

    ref const(T) opIndex(size_t i) const return nothrow @nogc @trusted {
        assert(i < mSize);
        return mData[i];
    }

    ref T front() return nothrow @nogc @trusted { assert(mSize > 0); return mData[0]; }
    ref T back()  return nothrow @nogc @trusted { assert(mSize > 0); return mData[mSize - 1]; }

    /// Live range as a D slice. Lifetime tied to the Array.
    inout(T)[] opSlice() inout nothrow @nogc @trusted {
        return mData[0 .. mSize];
    }

    /// Deep copy.
    Array dup() const nothrow @nogc @trusted {
        Array r;
        r.reserve(mSize);
        foreach (i; 0 .. mSize) emplace(&r.mData[i], mData[i]);
        r.mSize = mSize;
        return r;
    }

    private void destroyOne(size_t i) nothrow @nogc @trusted {
        static if (__traits(hasMember, T, "__xdtor"))
            mData[i].__xdtor();
    }

    private void destroyRange(size_t a, size_t b) nothrow @nogc @trusted {
        static if (__traits(hasMember, T, "__xdtor")) {
            foreach (i; a .. b) mData[i].__xdtor();
        }
    }
}

unittest {
    Array!int a;
    a.push_back(10);
    a.push_back(20);
    a.push_back(30);
    assert(a.size == 3);
    assert(a[1] == 20);
    a.erase(0);                  // swaps 30 in
    assert(a.size == 2 && a[0] == 30);
    a.clear();
    assert(a.empty);
}
