/// RAII wrapper for external C resources (SDL/WGPU handles).
/// Provides deterministic cleanup via struct destructors.
module engine.core.resource;

@safe:

/// Wraps a C pointer with automatic release on scope exit.
/// T is the pointer type, releaseFn is the cleanup function.
struct Handle(T, alias releaseFn) {
    private T _ptr;

    @disable this(this); // No copies — move only.

    this(T ptr) @trusted {
        _ptr = ptr;
    }

    ~this() @trusted {
        if (_ptr !is null) {
            releaseFn(_ptr);
            _ptr = null;
        }
    }

    T ptr() nothrow @nogc @trusted const {
        return cast(T) _ptr;
    }

    bool valid() nothrow @nogc const {
        return _ptr !is null;
    }

    /// Take ownership — caller must release.
    T take() @trusted {
        auto p = _ptr;
        _ptr = null;
        return p;
    }
}
