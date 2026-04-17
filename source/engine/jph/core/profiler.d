// Jolt — Core/Profiler.h equivalent. The full profiler is omitted; this
// module supplies no-op markers so ports of `JPH_PROFILE_FUNCTION()` and
// `JPH_PROFILE_SCOPE("name")` compile away.
//
// Source: ref/JoltPhysics/Jolt/Core/Profiler.h.
module engine.jph.core.profiler;

@safe:

/// No-op equivalent of `JPH_PROFILE_FUNCTION()`. Inlined to nothing.
pragma(inline, true)
void jphProfileFunction()(string file = __FUNCTION__) pure nothrow @nogc {}

/// No-op equivalent of `JPH_PROFILE_SCOPE("name")`.
pragma(inline, true)
void jphProfileScope()(string name) pure nothrow @nogc {}
