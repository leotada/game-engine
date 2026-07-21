/**
 * Compile-time POD enforcement for engine storage.
 *
 * Any type that lives in engine-owned, GC-untraced storage (ECS components,
 * mesh buffers, particle pools, terrain chunks, etc.) must pass `isPod`.
 * Use `Pod!T` in container declarations to get a clear compile error when
 * a type violates the rule.
 *
 * See docs/gc-safe-architecture-plan.md §2.1.
 */
module engine.core.pod;

import std.traits : hasIndirections;

@safe:

/// `true` when `T` contains no GC-traced indirections (no class refs,
/// slices, strings, delegates, or pointers to GC memory).
enum isPod(T) = !hasIndirections!T;

/**
 * Identity alias that fails compilation with an explanatory message if
 * `T` is not POD.  Use in any container that lives in engine memory:
 *
 * ---
 * struct ParticlePool(T) { Pod!T[] data; }
 * ---
 */
template Pod(T)
{
    static assert(isPod!T,
        "Type `" ~ T.stringof ~ "` contains GC-traced indirections "
        ~ "(class, string, slice, delegate, or pointer to GC memory). "
        ~ "Engine storage must be POD. Replace references with "
        ~ "EntityId / Handle!T, and strings with StringId or fixed buffers.");
    alias Pod = T;
}

///
@safe pure nothrow @nogc unittest
{
    struct Good { float x; int y; }
    static assert(isPod!Good);
    static assert(is(Pod!Good == Good));

    struct Bad { string s; }
    static assert(!isPod!Bad);
    // Pod!Bad would fail to compile with a descriptive message.
}
