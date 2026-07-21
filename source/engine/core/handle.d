/**
 * Typed handle for engine-owned resources.
 *
 * A `Handle!T` is a lightweight 8-byte POD value that replaces class/pointer
 * references when crossing the gameplay→engine boundary.  It stores an index
 * into a pool plus a generation counter for use-after-free detection.
 *
 * Handles contain no GC-traced pointers, so they can live freely inside
 * engine storage (ECS components, mesh data, etc.) without increasing
 * mark cost.
 *
 * See docs/gc-safe-architecture-plan.md §2.2.
 */
module engine.core.handle;

import engine.core.pod : isPod;

@safe:

/**
 * Lightweight, generational handle to a resource of logical type `T`.
 *
 * `T` is a phantom type — it is never stored or instantiated; it only
 * exists to prevent accidentally mixing handles of different domains
 * (e.g. `Handle!NpcDef` vs `Handle!InventoryNode`).
 */
struct Handle(T)
{
    uint index      = 0;
    uint generation = 0;

    bool isNull() const @nogc nothrow pure @safe { return index == 0; }

    /// Two handles are equal iff both index and generation match.
    bool opEquals()(const Handle!T rhs) const @nogc nothrow pure @safe
    {
        return index == rhs.index && generation == rhs.generation;
    }

    size_t toHash() const @nogc nothrow pure @safe
    {
        // FNV-style mix of the two uint fields.
        size_t h = index;
        h ^= generation * 0x9e3779b9;
        return h;
    }
}

/// Handles are always POD — safe for engine storage.
@safe pure nothrow @nogc unittest
{
    struct Npc {}
    struct Item {}

    static assert(isPod!(Handle!Npc));
    static assert(isPod!(Handle!Item));

    auto a = Handle!Npc(1, 0);
    auto b = Handle!Npc(1, 0);
    auto c = Handle!Npc(2, 0);
    assert(a == b);
    assert(a != c);
    assert(a.isNull == false);
    assert(Handle!Npc.init.isNull == true);
}
