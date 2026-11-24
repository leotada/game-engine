/// Sparse-set component store — O(1) add/remove/lookup, cache-friendly iteration.
/// Enhanced from the original ECS with @safe support and SoA storage.
module engine.ecs.store;

import engine.core.pod : isPod, Pod;

@safe:

alias EntityId = uint;

/// Generational entity handle pairing a dense `EntityId` slot with its generation counter.
struct EntityHandle {
    EntityId id = EntityId.max;
    uint generation = 0;

    bool isNull() const pure nothrow @nogc {
        return id == EntityId.max || generation == 0;
    }
}
static assert(isPod!EntityHandle);

struct ComponentStore(T) if (is(T == struct)) {
    static assert(isPod!T, "Component " ~ T.stringof ~ " must not contain GC pointers — see docs/gc-safe-architecture-plan.md");

    private Pod!T[] dense;
    private EntityId[] denseToEntity;
    private uint[] sparse;
    private size_t _length;

    void reserve(size_t entityCapacity) nothrow @trusted {
        if (sparse.length < entityCapacity)
            sparse.length = entityCapacity;
    }

    /// Insert `component` for `id`, overwriting the one it already has.
    void add(EntityId id, T component) nothrow @trusted {
        if (has(id)) {
            dense[sparse[id]] = component;
            return;
        }
        if (id >= sparse.length)
            sparse.length = id + 1;

        sparse[id] = cast(uint) _length;

        if (_length >= dense.length) {
            dense.length = _length + 1;
            denseToEntity.length = _length + 1;
        }

        dense[_length] = component;
        denseToEntity[_length] = id;
        _length++;
    }

    /// Insert `comps[i]` for `ids[i]` in one pass (arrays grow once). An id already present is overwritten.
    void addBatch(scope const(EntityId)[] ids, scope const(T)[] comps) nothrow @trusted {
        assert(ids.length == comps.length);
        if (ids.length == 0) return;
        EntityId maxId = 0;
        foreach (id; ids)
            if (id > maxId) maxId = id;
        if (maxId >= sparse.length)
            sparse.length = cast(size_t) maxId + 1;
        immutable need = _length + ids.length;
        if (need > dense.length) {
            dense.length = need;
            denseToEntity.length = need;
        }
        foreach (i, id; ids) {
            if (has(id)) {
                dense[sparse[id]] = comps[i];
            } else {
                sparse[id] = cast(uint) _length;
                dense[_length] = comps[i];
                denseToEntity[_length] = id;
                _length++;
            }
        }
    }

    void remove(EntityId id) nothrow @nogc @trusted {
        if (!has(id)) return;

        immutable denseIdx = sparse[id];
        immutable lastIdx  = _length - 1;

        if (denseIdx != lastIdx) {
            dense[denseIdx]         = dense[lastIdx];
            denseToEntity[denseIdx] = denseToEntity[lastIdx];
            sparse[denseToEntity[denseIdx]] = cast(uint) denseIdx;
        }

        _length--;
    }

    bool has(EntityId id) const nothrow @nogc @trusted {
        if (id >= sparse.length) return false;
        immutable idx = sparse[id];
        return idx < _length && denseToEntity[idx] == id;
    }

    ref T get(EntityId id) nothrow @nogc @trusted {
        return dense[sparse[id]];
    }

    T* getPointer(EntityId id) nothrow @nogc @trusted {
        if (!has(id)) return null;
        return &dense[sparse[id]];
    }

    size_t length() const nothrow @nogc { return _length; }

    size_t sparseLength() const pure nothrow @nogc { return sparse.length; }

    void clear() nothrow @nogc { _length = 0; }

    /// Direct access to dense component array for cache-friendly iteration.
    T[] components() nothrow @nogc @trusted {
        return dense[0 .. _length];
    }

    /// Entity IDs matching the dense array order.
    const(EntityId)[] entities() const nothrow @nogc @trusted {
        return denseToEntity[0 .. _length];
    }
}

@("componentStore.addBatch") @safe unittest {
    static struct V { float a = 0; uint b = 0; }
    ComponentStore!V st;
    st.addBatch([5u, 2, 9], [V(5, 1), V(2, 2), V(9, 3)]);
    assert(st.length == 3 && st.entities == [5u, 2, 9]);
    assert(st.get(2).a == 2 && st.get(9).b == 3);
    st.addBatch([2u, 100], [V(20, 0), V(100, 0)]);      // overwrite + grow the sparse array
    assert(st.length == 4 && st.get(2).a == 20 && st.has(100) && st.sparseLength >= 101);
    st.remove(5);
    assert(!st.has(5) && st.length == 3 && st.get(100).a == 100);
}

@("componentStore.add overwrites an existing entry") @safe unittest {
    static struct V { int x; }
    ComponentStore!V st;
    st.add(3, V(1));
    st.add(3, V(2));
    assert(st.length == 1 && st.get(3).x == 2);
    st.remove(3);
    assert(!st.has(3) && st.length == 0);
}
