// Jolt — Core/Reference.h equivalent. Intrusive reference counting that lets
// us mirror Jolt's `Ref<Shape>`, `RefConst<PhysicsMaterial>` patterns without
// the GC.
//
// `RefTargetMixin` is mixed into a class body; it adds an atomic refcount and
// `AddRef`/`Release`/`GetRefCount` methods. `Release()` deletes via
// `jphDelete!T(this)` once the count reaches zero, mirroring
// `delete static_cast<T *>(this)` in the C++ source.
//
// `Ref(T)` is a smart-pointer struct: copy-construction increments the count,
// destruction decrements it. Move via `move(ref)` is supported.
//
// Source: ref/JoltPhysics/Jolt/Core/Reference.h.
module engine.jph.core.reference;

import engine.jph.core.atomics;
import engine.jph.core.memory : jphDelete;

@safe:

/// Mark used by `SetEmbedded()` so an instance allocated on the stack or
/// inside another object is never deleted by `Release`. Same magic value as
/// Jolt's `cEmbedded`.
enum uint cEmbedded = 0x0ebedded;

/// Mix into a class body to make it a Jolt-style `RefTarget<T>`. T is the
/// concrete derived class (CRTP) so the templated `Release()` calls the right
/// destructor via `jphDelete!T(cast(T) this)`.
mixin template RefTargetMixin(T) {
    import engine.jph.core.atomics : atomicLoad, atomicFetchAdd, atomicFetchSub,
                                     atomicFence, MemoryOrder;
    import engine.jph.core.memory : jphDelete;
    import engine.jph.core.reference : cEmbedded;

    private shared uint mRefCount = 0;

    /// Get the current reference count.
    final uint GetRefCount() const @trusted nothrow @nogc {
        return atomicLoad!(MemoryOrder.raw)(mRefCount);
    }

    /// Mark this instance as embedded — Release() then never deletes it.
    final void SetEmbedded() const @trusted nothrow @nogc {
        atomicFetchAdd!(MemoryOrder.raw)(*cast(shared(uint)*) &mRefCount, cEmbedded);
    }

    /// Increment the reference count (relaxed memory order).
    final void AddRef() const @trusted nothrow @nogc {
        atomicFetchAdd!(MemoryOrder.raw)(*cast(shared(uint)*) &mRefCount, 1);
    }

    /// Decrement the reference count and delete the object on transition 1→0.
    final void Release() const @trusted nothrow @nogc {
        immutable old = atomicFetchSub!(MemoryOrder.rel)(*cast(shared(uint)*) &mRefCount, 1);
        assert(old != 0 && old != cEmbedded, "Too many calls to Release");
        if (old == 1) {
            atomicFence!(MemoryOrder.acq);
            // The const cast mirrors Jolt's `delete static_cast<const T*>(this)`.
            jphDelete!T(cast(T) cast(void*) this);
        }
    }
}

/// Smart pointer mirroring Jolt's `Ref<T>`. Copy-constructible, move-aware,
/// and `@nogc nothrow @safe` because every refcount op is.
struct Ref(T) if (is(T == class)) {
@safe:
    private T mPtr = null;

    this(T ptr) nothrow @nogc {
        mPtr = ptr;
        addRef();
    }

    this(this) nothrow @nogc {
        addRef();
    }

    ~this() nothrow @nogc {
        release();
    }

    void opAssign(T rhs) nothrow @nogc {
        if (mPtr is rhs) return;
        release();
        mPtr = rhs;
        addRef();
    }

    void opAssign(Ref!T rhs) nothrow @nogc {
        if (mPtr is rhs.mPtr) return;
        release();
        mPtr = rhs.mPtr;
        addRef();
    }

    /// Implicit conversion to the underlying pointer.
    T GetPtr() inout nothrow @nogc @trusted { return cast(T) mPtr; }
    alias GetPtr this;

    bool isNull() const nothrow @nogc { return mPtr is null; }

    private void addRef() nothrow @nogc {
        if (mPtr !is null) mPtr.AddRef();
    }

    private void release() nothrow @nogc @trusted {
        if (mPtr !is null) {
            mPtr.Release();
            mPtr = null;
        }
    }
}

/// `RefConst(T)` mirrors Jolt's `RefConst<T>` — same as `Ref` but the held
/// pointer is `const`. We model it as a separate struct rather than `const(Ref!T)`
/// because D doesn't allow mutating refcounts through `const`.
struct RefConst(T) if (is(T == class)) {
@safe:
    private T mPtr = null;

    this(const(T) ptr) nothrow @nogc @trusted {
        mPtr = cast(T) ptr;
        addRef();
    }

    this(Ref!T r) nothrow @nogc {
        mPtr = r.mPtr;
        addRef();
    }

    this(this) nothrow @nogc {
        addRef();
    }

    ~this() nothrow @nogc {
        release();
    }

    void opAssign(const(T) rhs) nothrow @nogc @trusted {
        if (mPtr is rhs) return;
        release();
        mPtr = cast(T) rhs;
        addRef();
    }

    const(T) GetPtr() const nothrow @nogc { return mPtr; }
    alias GetPtr this;

    bool isNull() const nothrow @nogc { return mPtr is null; }

    private void addRef() nothrow @nogc {
        if (mPtr !is null) mPtr.AddRef();
    }

    private void release() nothrow @nogc @trusted {
        if (mPtr !is null) {
            mPtr.Release();
            mPtr = null;
        }
    }
}
