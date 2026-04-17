// Jolt — Core/NonCopyable.h equivalent.
//
// `NonCopyable` in Jolt disables copy-construction and copy-assignment so
// resource-owning types like JobSystem, TempAllocator, Barrier, BodyManager
// cannot be accidentally duplicated. In D the same effect is achieved by
// `@disable this(this);` on a struct or by `mixin NonCopyable;` on a class.
//
// Source: ref/JoltPhysics/Jolt/Core/NonCopyable.h.
module engine.jph.core.noncopyable;

@safe:

/// Mix into a class or struct body to forbid copy / postblit / assignment.
mixin template NonCopyable() {
    @disable this(this);
    @disable void opAssign(typeof(this));
}
