/// World — compile-time ECS registry using variadic templates.
/// Entities + components + query iteration with zero runtime overhead.
module engine.ecs.world;

import engine.ecs.store;
import engine.core.pod : isPod;
import engine.core.strings : StringTable;
import std.meta : allSatisfy;

@safe:

private template isValidComponent(T) {
    enum isValidComponent = is(T == struct) && isPod!T;
}

struct World(Components...) if (Components.length > 0 && allSatisfy!(isValidComponent, Components)) {
    private EntityId _nextId = 0;
    private bool[] _alive;

    /// Interned strings for engine-owned identifiers (material names, dialog keys, …).
    StringTable strings;

    // One ComponentStore per component type, generated at compile time.
    private alias Stores = StoresOf!Components;
    private Stores _stores;

    EntityId spawn() nothrow @trusted {
        immutable id = _nextId++;
        if (id >= _alive.length)
            _alive.length = id + 1;
        _alive[id] = true;
        return id;
    }

    void destroy(EntityId id) nothrow @nogc @trusted {
        if (id >= _alive.length || !_alive[id]) return;
        _alive[id] = false;
        static foreach (i, C; Components)
            _stores[i].remove(id);
    }

    bool alive(EntityId id) const nothrow @nogc @trusted {
        return id < _alive.length && _alive[id];
    }

    void set(C)(EntityId id, C component) nothrow @trusted {
        enum idx = indexOf!(C, Components);
        static assert(idx != -1, "Component type not registered in World");
        auto store = &_stores[idx];
        if (store.has(id))
            store.get(id) = component;
        else
            store.add(id, component);
    }

    ref C get(C)(EntityId id) nothrow @nogc @trusted {
        enum idx = indexOf!(C, Components);
        static assert(idx != -1, "Component type not registered in World");
        return _stores[idx].get(id);
    }

    C* getPtr(C)(EntityId id) nothrow @nogc @trusted {
        enum idx = indexOf!(C, Components);
        static assert(idx != -1, "Component type not registered in World");
        return _stores[idx].getPointer(id);
    }

    bool has(C)(EntityId id) nothrow @nogc @trusted {
        enum idx = indexOf!(C, Components);
        static assert(idx != -1, "Component type not registered in World");
        return _stores[idx].has(id);
    }

    ref ComponentStore!C store(C)() nothrow @nogc @trusted {
        enum idx = indexOf!(C, Components);
        static assert(idx != -1, "Component type not registered in World");
        return _stores[idx];
    }

    /// Query entities that have ALL specified component types.
    /// Returns a Voldemort range yielding EntityId values.
    auto query(QueryComponents...)() nothrow @nogc @trusted {
        // Validate all queried types at compile time.
        static foreach (QC; QueryComponents) {
            static assert(indexOf!(QC, Components) != -1,
                QC.stringof ~ " is not registered in this World");
        }

        struct Range {
            Stores* stores;
            const(EntityId)[] entities;
            size_t idx;

            bool empty() const nothrow @nogc { return idx >= entities.length; }

            EntityId front() nothrow @nogc @trusted {
                return entities[idx];
            }

            void popFront() nothrow @nogc {
                idx++;
                advance();
            }

            private void advance() nothrow @nogc @trusted {
                while (idx < entities.length) {
                    if (hasRemaining(entities[idx]))
                        return;
                    idx++;
                }
            }

            private bool hasRemaining(EntityId e) nothrow @nogc @trusted {
                static foreach (i, QC; QueryComponents) {{
                    static if (i > 0) {
                        enum cIdx = indexOf!(QC, Components);
                        if (!(*stores)[cIdx].has(e))
                            return false;
                    }
                }}
                return true;
            }
        }

        enum leaderIdx = indexOf!(QueryComponents[0], Components);
        Range r;
        r.stores = &_stores;
        r.entities = _stores[leaderIdx].entities();
        r.idx = 0;
        r.advance();
        return r;
    }

    size_t entityCount() const nothrow @nogc @trusted {
        size_t count = 0;
        foreach (a; _alive)
            if (a) count++;
        return count;
    }
}

// ---------------------------------------------------------------------------
// Compile-time helpers
// ---------------------------------------------------------------------------
private template StoresOf(Components...) {
    import std.meta : AliasSeq;
    alias StoresOf = toTuple!(staticMap!(ComponentStore, Components));
}

private template staticMap(alias F, T...) {
    import std.meta : AliasSeq;
    static if (T.length == 0)
        alias staticMap = AliasSeq!();
    else
        alias staticMap = AliasSeq!(F!(T[0]), staticMap!(F, T[1 .. $]));
}

private template toTuple(T...) {
    import std.typecons : Tuple;
    alias toTuple = Tuple!T;
}

private template indexOf(T, List...) {
    enum indexOf = indexOfImpl!(0, T, List);
}

private template indexOfImpl(size_t i, T, List...) {
    static if (i >= List.length)
        enum indexOfImpl = -1;
    else static if (is(T == List[i]))
        enum indexOfImpl = cast(int) i;
    else
        enum indexOfImpl = indexOfImpl!(i + 1, T, List);
}
