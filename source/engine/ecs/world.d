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
    private uint[] _generation;
    private EntityId[] _freeIds;
    private size_t _freeCount = 0;

    /// Interned strings for engine-owned identifiers (material names, dialog keys, …).
    StringTable strings;

    // One ComponentStore per component type, generated at compile time.
    private alias Stores = StoresOf!Components;
    private Stores _stores;

    EntityId spawn() nothrow @trusted {
        if (_freeCount > 0) {
            immutable id = _freeIds[--_freeCount];
            _alive[id] = true;
            return id;
        }
        immutable id = _nextId++;
        if (id >= _alive.length) {
            _alive.length = id + 1;
            _generation.length = id + 1;
            _freeIds.length = id + 1;
        }
        _alive[id] = true;
        if (_generation[id] == 0)
            _generation[id] = 1;
        return id;
    }

    void destroy(EntityId id) nothrow @nogc @trusted {
        if (id >= _alive.length || !_alive[id]) return;
        _alive[id] = false;
        _generation[id]++;
        if (_generation[id] == 0)
            _generation[id] = 1;
        static foreach (i, C; Components)
            _stores[i].remove(id);
        _freeIds[_freeCount++] = id;
    }

    bool alive(EntityId id) const nothrow @nogc @trusted {
        return id < _alive.length && _alive[id];
    }

    uint generation(EntityId id) const nothrow @nogc @trusted {
        return id < _generation.length ? _generation[id] : 0;
    }

    bool alive(EntityId id, uint expectedGen) const nothrow @nogc @trusted {
        return id < _alive.length && _alive[id] && expectedGen != 0 && _generation[id] == expectedGen;
    }

    EntityHandle handle(EntityId id) const nothrow @nogc @trusted {
        return alive(id) ? EntityHandle(id, _generation[id]) : EntityHandle.init;
    }

    bool aliveHandle(EntityHandle h) const nothrow @nogc @trusted {
        return !h.isNull() && alive(h.id, h.generation);
    }

    size_t capacity() const nothrow @nogc @trusted { return _alive.length; }

    size_t freeCount() const nothrow @nogc @trusted { return _freeCount; }

    void clearEntities() nothrow @nogc @trusted {
        foreach (i; 0 .. _alive.length) {
            if (_alive[i]) {
                _alive[i] = false;
                _generation[i]++;
                if (_generation[i] == 0)
                    _generation[i] = 1;
                static foreach (ci, C; Components)
                    _stores[ci].remove(cast(EntityId) i);
            }
        }
        _nextId = 0;
        _freeCount = 0;
    }

    /// Add or replace a component. Ignored when `id` is not alive: its id would leak the component into the next
    /// entity that reuses it.
    void set(C)(EntityId id, C component) nothrow @trusted {
        enum idx = indexOf!(C, Components);
        static assert(idx != -1, "Component type not registered in World");
        if (!alive(id)) return;
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

@("world.recyclingAndGenerations") @safe unittest {
    static struct Pos { float x = 0, y = 0, z = 0; }

    World!Pos w;
    auto e0 = w.spawn();
    auto h0 = w.handle(e0);
    assert(e0 == 0 && h0.generation == 1);
    assert(w.aliveHandle(h0));
    w.set(e0, Pos(1, 2, 3));

    w.destroy(e0);
    assert(!w.alive(e0));
    assert(!w.aliveHandle(h0));
    assert(w.generation(e0) == 2);
    assert(w.freeCount() == 1);

    auto e0b = w.spawn();
    assert(e0b == e0, "free-list should recycle destroyed EntityId");
    assert(w.alive(e0b));
    assert(!w.aliveHandle(h0), "stale handle must be rejected after recycle");
    auto h0b = w.handle(e0b);
    assert(h0b.generation == 2);
    assert(w.aliveHandle(h0b));

    // 100 wave cycles of 32 entities must keep capacity and sparseLength bounded at 32.
    w.clearEntities();
    assert(w.entityCount() == 0);
    foreach (_; 0 .. 100) {
        EntityId[32] batch;
        foreach (i; 0 .. 32) {
            batch[i] = w.spawn();
            w.set(batch[i], Pos(i, 0, 0));
        }
        foreach (i; 0 .. 32) {
            w.destroy(batch[i]);
        }
    }
    assert(w.capacity() == 32);
    assert(w.store!Pos().sparseLength() == 32);
}

@("world.set on a dead entity is ignored") @safe unittest {
    static struct A { int x; }
    World!A w;
    auto e = w.spawn();
    w.destroy(e);
    w.set(e, A(7));
    assert(w.spawn() == e && !w.has!A(e));
}
