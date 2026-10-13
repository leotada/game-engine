/// SceneWorld — Dynamic ECS registry supporting runtime type registration.
/// Exposes the exact same API as `World!(...)` while allowing type-erased reflection,
/// runtime script components, and Inspector introspection.
module engine.ecs.scene_world;

import engine.core.pod : isPod;
import engine.core.strings : StringTable, StringId;
import engine.ecs.store : EntityId;
import engine.reflect.attrs;
import engine.reflect.descriptor;

@safe:

/// Type-erased Sparse-Set component store.
struct RawComponentStore {
    ComponentTypeId typeId = invalidComponentTypeId;
    uint itemSize = 0;
    uint itemAlign = 0;
    uint count = 0;

    uint[] denseToEntity;
    uint[] sparse;
    ubyte[] denseData;

    @disable this(this);

    bool has(EntityId id) const nothrow @nogc @trusted {
        if (id >= sparse.length) return false;
        immutable denseIdx = sparse[id];
        return denseIdx < count && denseToEntity[denseIdx] == id;
    }

    ubyte[] get(EntityId id) nothrow @nogc @trusted {
        if (!has(id)) return null;
        immutable denseIdx = sparse[id];
        immutable offset = denseIdx * itemSize;
        return denseData[offset .. offset + itemSize];
    }

    void add(EntityId id, scope const(ubyte)[] bytes) nothrow @trusted {
        if (has(id)) {
            // Already present: overwrite
            immutable denseIdx = sparse[id];
            immutable offset = denseIdx * itemSize;
            denseData[offset .. offset + itemSize] = bytes[0 .. itemSize];
            return;
        }

        if (id >= sparse.length) {
            sparse.length = id + 1;
        }

        immutable denseIdx = count;
        sparse[id] = denseIdx;

        if (denseIdx >= denseToEntity.length) {
            denseToEntity.length = denseIdx + 1;
        }
        denseToEntity[denseIdx] = id;

        immutable offset = denseIdx * itemSize;
        if (offset + itemSize > denseData.length) {
            denseData.length = (denseIdx + 1) * itemSize;
        }
        denseData[offset .. offset + itemSize] = bytes[0 .. itemSize];
        count++;
    }

    void remove(EntityId id) nothrow @nogc @trusted {
        if (!has(id)) return;

        immutable denseIdx = sparse[id];
        immutable lastIdx = count - 1;

        if (denseIdx != lastIdx) {
            // Swap-and-pop with the last element
            immutable lastEntity = denseToEntity[lastIdx];
            denseToEntity[denseIdx] = lastEntity;
            sparse[lastEntity] = denseIdx;

            immutable srcOffset = lastIdx * itemSize;
            immutable dstOffset = denseIdx * itemSize;
            denseData[dstOffset .. dstOffset + itemSize] = denseData[srcOffset .. srcOffset + itemSize];
        }

        count--;
        sparse[id] = uint.max;
    }

    void clear() nothrow @nogc {
        count = 0;
    }
}

/// Dynamic ECS World supporting both statically-typed calls and runtime dynamic reflection.
struct SceneWorld {
    private EntityId _nextId = 0;
    private bool[] _alive;

    StringTable strings;
    TypeRegistry types;

    // Array of stores indexed by ComponentTypeId
    private RawComponentStore*[] _stores;

    @disable this(this);

    ~this() @trusted {
        foreach (s; _stores) {
            if (s !is null) {
                // GC will collect members
            }
        }
    }

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
        foreach (s; _stores) {
            if (s !is null)
                s.remove(id);
        }
    }

    bool alive(EntityId id) const nothrow @nogc @trusted {
        return id < _alive.length && _alive[id];
    }

    size_t entityCount() const nothrow @nogc @trusted {
        size_t n = 0;
        foreach (a; _alive) if (a) n++;
        return n;
    }

    void clearEntities() nothrow @nogc @trusted {
        foreach (i; 0 .. _alive.length) {
            if (_alive[i])
                destroy(cast(EntityId) i);
        }
        _nextId = 0;
    }

    // -----------------------------------------------------------------------
    // Dynamic / Reflection API (Used by Editor, Inspector, and Serializer)
    // -----------------------------------------------------------------------

    RawComponentStore* getStore(ComponentTypeId tid) nothrow @nogc @trusted {
        if (tid >= _stores.length) return null;
        return _stores[tid];
    }

    private RawComponentStore* getOrCreateStore(ComponentTypeId tid) nothrow @trusted {
        if (tid == invalidComponentTypeId) return null;
        if (tid >= _stores.length) {
            _stores.length = tid + 1;
        }
        if (_stores[tid] is null) {
            auto desc = types.getType(tid);
            auto s = new RawComponentStore();
            s.typeId = tid;
            s.itemSize = desc.size;
            s.itemAlign = desc.alignment;
            _stores[tid] = s;
        }
        return _stores[tid];
    }

    bool rawHas(ComponentTypeId tid, EntityId id) const nothrow @nogc @trusted {
        if (tid >= _stores.length || _stores[tid] is null) return false;
        return _stores[tid].has(id);
    }

    ubyte[] rawGet(ComponentTypeId tid, EntityId id) nothrow @nogc @trusted {
        if (tid >= _stores.length || _stores[tid] is null) return null;
        return _stores[tid].get(id);
    }

    void rawAdd(ComponentTypeId tid, EntityId id, scope const(ubyte)[] bytes) nothrow @trusted {
        if (!alive(id)) return;
        auto s = getOrCreateStore(tid);
        if (s !is null)
            s.add(id, bytes);
    }

    void rawRemove(ComponentTypeId tid, EntityId id) nothrow @nogc @trusted {
        if (tid < _stores.length && _stores[tid] !is null)
            _stores[tid].remove(id);
    }

    /// Returns all ComponentTypeIds present on an entity.
    void getComponentTypes(EntityId id, ref ComponentTypeId[] outTypes) const nothrow @trusted {
        outTypes.length = 0;
        if (!alive(id)) return;
        foreach (tid, s; _stores) {
            if (s !is null && s.has(id))
                outTypes ~= cast(ComponentTypeId) tid;
        }
    }

    /// Unregisters and frees component store for a type (used during script hot reload).
    void unregisterType(ComponentTypeId tid) nothrow @trusted {
        if (tid < _stores.length && _stores[tid] !is null) {
            _stores[tid].clear();
            _stores[tid] = null;
        }
    }

    // -----------------------------------------------------------------------
    // Typed API (100% compatible with World!(...))
    // -----------------------------------------------------------------------

    ComponentTypeId ensureRegistered(C)() @trusted {
        static assert(is(C == struct), "Component must be a struct");
        static assert(isPod!C, "Component must be POD");
        immutable name = __traits(identifier, C);
        auto tid = types.find(name, strings);
        if (tid == invalidComponentTypeId) {
            tid = types.register!C(strings);
        }
        return tid;
    }

    void set(C)(EntityId id, C component) @trusted {
        immutable tid = ensureRegistered!C();
        auto p = cast(const(ubyte)*) &component;
        rawAdd(tid, id, p[0 .. C.sizeof]);
    }

    ref C get(C)(EntityId id) nothrow @nogc @trusted {
        immutable name = __traits(identifier, C);
        immutable tid = types.find(name, strings);
        assert(tid != invalidComponentTypeId, "Component type not registered");
        assert(tid < _stores.length && _stores[tid] !is null, "No store for component");
        auto slice = _stores[tid].get(id);
        assert(slice !is null, "Entity does not have component");
        return *cast(C*) slice.ptr;
    }

    C* getPtr(C)(EntityId id) nothrow @nogc @trusted {
        immutable name = __traits(identifier, C);
        immutable tid = types.find(name, strings);
        if (tid == invalidComponentTypeId || tid >= _stores.length || _stores[tid] is null)
            return null;
        auto slice = _stores[tid].get(id);
        if (slice is null) return null;
        return cast(C*) slice.ptr;
    }

    bool has(C)(EntityId id) const nothrow @nogc @trusted {
        immutable name = __traits(identifier, C);
        immutable tid = types.find(name, strings);
        if (tid == invalidComponentTypeId || tid >= _stores.length || _stores[tid] is null)
            return false;
        return _stores[tid].has(id);
    }

    void remove(C)(EntityId id) nothrow @nogc @trusted {
        immutable name = __traits(identifier, C);
        immutable tid = types.find(name, strings);
        if (tid != invalidComponentTypeId)
            rawRemove(tid, id);
    }

    /// Query entities possessing all specified component types.
    auto query(QueryComponents...)() @trusted {
        struct Range {
            const(RawComponentStore)*[QueryComponents.length] stores;
            const(EntityId)[] leaderEntities;
            const(bool)[] alive;
            size_t idx;

            bool empty() const nothrow @nogc { return idx >= leaderEntities.length; }

            EntityId front() nothrow @nogc @trusted {
                return leaderEntities[idx];
            }

            void popFront() nothrow @nogc {
                idx++;
                advance();
            }

            private void advance() nothrow @nogc @trusted {
                while (idx < leaderEntities.length) {
                    immutable e = leaderEntities[idx];
                    if (e < alive.length && alive[e] && hasRemaining(e))
                        return;
                    idx++;
                }
            }

            private bool hasRemaining(EntityId e) nothrow @nogc @trusted {
                static foreach (i; 1 .. QueryComponents.length) {
                    if (stores[i] is null || !stores[i].has(e))
                        return false;
                }
                return true;
            }
        }

        Range r;
        r.alive = _alive;
        r.idx = 0;

        static foreach (i, QC; QueryComponents) {{
            immutable tid = ensureRegistered!QC();
            r.stores[i] = (tid < _stores.length) ? _stores[tid] : null;
        }}

        if (r.stores[0] !is null) {
            r.leaderEntities = r.stores[0].denseToEntity[0 .. r.stores[0].count];
        }

        r.advance();
        return r;
    }
}

@safe unittest {
    static struct Position { float x = 0, y = 0, z = 0; }
    static struct Velocity { float vx = 1, vy = 2, vz = 3; }
    static struct Tag { uint id = 42; }

    SceneWorld world;
    auto e1 = world.spawn();
    auto e2 = world.spawn();
    auto e3 = world.spawn();

    world.set(e1, Position(10, 20, 30));
    world.set(e1, Velocity(1, 0, 0));

    world.set(e2, Position(5, 5, 5));

    world.set(e3, Position(0, 0, 0));
    world.set(e3, Velocity(0, 1, 0));
    world.set(e3, Tag(99));

    assert(world.has!Position(e1));
    assert(world.has!Velocity(e1));
    assert(!world.has!Tag(e1));

    assert(world.get!Position(e1).x == 10);
    assert(world.get!Velocity(e1).vx == 1);

    // Test query over multiple components
    size_t countPosVel = 0;
    foreach (e; world.query!(Position, Velocity)) {
        countPosVel++;
        assert(world.has!Position(e));
        assert(world.has!Velocity(e));
    }
    assert(countPosVel == 2); // e1 and e3

    // Dynamic type-erased listing
    ComponentTypeId[] types;
    world.getComponentTypes(e3, types);
    assert(types.length == 3);

    // Destroy entity
    world.destroy(e1);
    assert(!world.alive(e1));
    assert(!world.has!Position(e1));
}
