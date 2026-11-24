/**
 * `PodBuffer!T` — malloc-backed growable array of POD values.
 *
 * Use it for engine-owned buffers that are filled every frame (instance
 * lists, visibility scratch). Growth doubles capacity with `realloc`, so after
 * a warm-up frame the steady state performs no allocation at all, and since
 * the memory is not GC-owned it is never scanned or collected. Everything is
 * `nothrow @nogc`.
 *
 * Move-only: copy is disabled; call `release()` (or let the owner's
 * `destroy()` do it) to free the memory.
 */
module engine.core.podbuf;

import engine.core.pod : isPod;

@safe:

struct PodBuffer(T) {
    static assert(isPod!T, "PodBuffer!" ~ T.stringof ~ " requires a POD element type");

    private T* ptr_;
    private size_t length_;
    private size_t capacity_;

    @disable this(this);

    /// Live elements.
    inout(T)[] opSlice() inout return nothrow @nogc @trusted {
        return ptr_ is null ? null : ptr_[0 .. length_];
    }

    /// Elements `[a .. b)` of the live range.
    inout(T)[] opSlice(size_t a, size_t b) inout return nothrow @nogc {
        return this[][a .. b];
    }

    ref inout(T) opIndex(size_t i) inout return nothrow @nogc {
        return this[][i];
    }

    size_t length() const nothrow @nogc { return length_; }
    size_t capacity() const nothrow @nogc { return capacity_; }
    size_t opDollar() const nothrow @nogc { return length_; }

    /// Drop all elements, keep capacity.
    void clear() nothrow @nogc { length_ = 0; }

    /// Ensure room for `n` elements without changing `length`.
    void reserve(size_t n) nothrow @nogc @trusted {
        if (n <= capacity_) return;
        import core.stdc.stdlib : realloc;
        size_t cap = capacity_ == 0 ? 16 : capacity_;
        while (cap < n) cap *= 2;
        auto p = cast(T*) realloc(ptr_, cap * T.sizeof);
        if (p is null) {
            import core.stdc.stdlib : abort;
            abort();
        }
        ptr_ = p;
        capacity_ = cap;
    }

    /// Set the length, growing capacity when needed. New elements are `T.init`.
    void resize(size_t n) nothrow @nogc {
        reserve(n);
        immutable old = length_;
        length_ = n;
        if (n > old)
            this[][old .. n] = T.init;
    }

    /// Append one element (amortized O(1), allocation only on growth).
    ref T put()(auto ref const T value) return nothrow @nogc {
        if (length_ == capacity_) {
            // `value` may be an element of this buffer, which growing moves.
            T copy = value;
            reserve(length_ + 1);
            length_++;
            this[][length_ - 1] = copy;
        } else {
            length_++;
            this[][length_ - 1] = value;
        }
        return this[][length_ - 1];
    }

    /// Free the memory.
    void release() nothrow @nogc @trusted {
        import core.stdc.stdlib : free;
        free(ptr_);
        ptr_ = null;
        length_ = 0;
        capacity_ = 0;
    }
}

@("podbuf.basic") nothrow @nogc unittest {
    struct P { float x; uint y; }
    PodBuffer!P buf;
    assert(buf.length == 0 && buf[].length == 0);
    foreach (i; 0 .. 100)
        buf.put(P(i, i * 2));
    assert(buf.length == 100 && buf.capacity >= 100);
    assert(buf[42].y == 84);
    immutable cap = buf.capacity;
    buf.clear();
    assert(buf.length == 0 && buf.capacity == cap);
    buf.put(P(1, 2));
    assert(buf.capacity == cap); // no regrow after clear
    buf.resize(4);
    assert(buf[3].y == 0);
    assert(buf[1 .. 3].length == 2);
    buf.release();
    assert(buf.capacity == 0);
}

@("podbuf: put of an own element while growing") nothrow @nogc unittest {
    PodBuffer!int buf;
    buf.put(7);
    while (buf.length < buf.capacity)
        buf.put(1);
    foreach (_; 0 .. 5000) // enough growth for realloc to move the block
        buf.put(buf[0]);
    assert(buf[buf.length - 1] == 7);
    buf.release();
}
