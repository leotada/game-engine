// Jolt — Core/StaticArray.h equivalent. A bounded-capacity, value-type array
// living entirely inside the struct (no heap). Used heavily in the physics
// solver for per-body work queues and per-contact buffers.
//
// Source: ref/JoltPhysics/Jolt/Core/StaticArray.h.
module engine.jph.core.staticarray;

import core.lifetime : emplace;
import engine.jph.core.types : uint_;

@safe:

struct StaticArray(T, uint_ N) {
@safe:
    alias value_type = T;
    alias size_type  = uint_;
    enum uint_ Capacity = N;

    private T[N] mElements;
    private uint_ mSize = 0;

    @disable this(this);  // copy via dup() if needed

    /// Construct from a small initialiser list (matches Jolt's `StaticArray{...}`).
    this(T[] init) nothrow @nogc {
        assert(init.length <= N, "initializer too large");
        foreach (ref v; init)
            mElements[mSize++] = v;
    }

    void clear() nothrow @nogc { mSize = 0; }

    bool empty() const nothrow @nogc { return mSize == 0; }
    size_type size() const nothrow @nogc { return mSize; }
    static size_type capacity() nothrow @nogc { return N; }

    void push_back()(auto ref T v) nothrow @nogc {
        assert(mSize < N, "StaticArray full");
        mElements[mSize++] = v;
    }

    void emplace_back(A...)(auto ref A args) nothrow @nogc {
        assert(mSize < N, "StaticArray full");
        emplace(&mElements[mSize++], args);
    }

    void pop_back() nothrow @nogc {
        assert(mSize > 0, "StaticArray empty");
        --mSize;
    }

    void resize(size_type n) nothrow @nogc {
        assert(n <= N, "resize exceeds capacity");
        mSize = n;
    }

    ref T opIndex(size_type i) return nothrow @nogc {
        assert(i < mSize, "out of range");
        return mElements[i];
    }

    ref const(T) opIndex(size_type i) const return nothrow @nogc {
        assert(i < mSize, "out of range");
        return mElements[i];
    }

    ref T front() return nothrow @nogc { assert(mSize > 0); return mElements[0]; }
    ref T back()  return nothrow @nogc { assert(mSize > 0); return mElements[mSize - 1]; }

    /// Range-friendly slice over the live elements.
    inout(T)[] data() inout return nothrow @nogc { return mElements[0 .. mSize]; }

    /// Copy contents into a new StaticArray.
    StaticArray dup() const nothrow @nogc {
        StaticArray r;
        foreach (i; 0 .. mSize) r.mElements[i] = mElements[i];
        r.mSize = mSize;
        return r;
    }

    /// Erase the element at `i` by swapping with the last (Jolt's `erase`).
    void erase(size_type i) nothrow @nogc {
        assert(i < mSize, "erase out of range");
        if (i + 1 != mSize)
            mElements[i] = mElements[mSize - 1];
        --mSize;
    }
}

unittest {
    StaticArray!(int, 4) a;
    a.push_back(1);
    a.push_back(2);
    a.push_back(3);
    assert(a.size == 3);
    assert(a[0] == 1 && a[2] == 3);
    a.erase(0);                  // swaps last in
    assert(a.size == 2 && a[0] == 3);
    a.clear();
    assert(a.empty);
}
