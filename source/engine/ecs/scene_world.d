/// SceneWorld — Dynamic ECS registry supporting runtime type registration.
/// Exposes the exact same API as `World!(...)` while allowing type-erased reflection,
/// runtime script components, and Inspector introspection.
module engine.ecs.scene_world;

import engine.core.pod : isPod;
import engine.core.strings : StringTable, StringId;
import engine.ecs.store : EntityHandle, EntityId;
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

    /// Pre-grow the dense and sparse arrays so that `extraItems` more components, whose entity ids are all
    /// below `entityCapacity`, can be added without reallocating.
    void reserve(size_t extraItems, size_t entityCapacity) nothrow @trusted {
        if (entityCapacity > sparse.length)
            sparse.length = entityCapacity;
        immutable need = count + extraItems;
        if (need > denseToEntity.length)
            denseToEntity.length = need;
        if (need * itemSize > denseData.length)
            denseData.length = need * itemSize;
    }

    /// Insert many components at once. `bytes` holds `ids.length` consecutive items of `itemSize` bytes (item `i`
    /// belongs to `ids[i]`). Equivalent to calling `add` for each pair in order, but grows the arrays once and
    /// copies the dense data in a single pass over the new elements. An id already present is overwritten in place;
    /// an id repeated inside the batch keeps its last value.
    void addBatch(scope const(uint)[] ids, scope const(ubyte)[] bytes) nothrow @trusted {
        assert(bytes.length == ids.length * itemSize, "addBatch: bytes must hold ids.length items");
        if (ids.length == 0 || itemSize == 0)
            return;
        uint maxId = 0;
        foreach (id; ids)
            if (id > maxId)
                maxId = id;
        reserve(ids.length, cast(size_t) maxId + 1);

        immutable isz = itemSize;
        foreach (i, id; ids) {
            immutable src = i * isz;
            uint denseIdx;
            if (has(id)) {
                denseIdx = sparse[id];
            } else {
                denseIdx = count++;
                sparse[id] = denseIdx;
                denseToEntity[denseIdx] = id;
            }
            denseData[denseIdx * isz .. (denseIdx + 1) * isz] = bytes[src .. src + isz];
        }
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

    size_t sparseLength() const pure nothrow @nogc {
        return sparse.length;
    }
}

/// Dynamic ECS World supporting both statically-typed calls and runtime dynamic reflection.
struct SceneWorld {
    private EntityId _nextId = 0;
    private bool[] _alive;
    private uint[] _generation;
    private EntityId[] _freeIds;
    private size_t _freeCount = 0;

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

    /// Spawn `outIds.length` entities at once, writing their ids into `outIds`. The ids and their order are exactly
    /// those `outIds.length` successive `spawn()` calls would return (free list first, then fresh ids), but the
    /// bookkeeping arrays grow once.
    void spawnBatch(scope EntityId[] outIds) nothrow @trusted {
        immutable n = outIds.length;
        if (n == 0)
            return;
        size_t k = 0;
        while (k < n && _freeCount > 0) {
            immutable id = _freeIds[--_freeCount];
            _alive[id] = true;
            outIds[k++] = id;
        }
        immutable fresh = n - k;
        if (fresh > 0) {
            immutable last = cast(size_t) _nextId + fresh;     // one past the last new id
            if (last > _alive.length) {
                _alive.length = last;
                _generation.length = last;
                _freeIds.length = last;
            }
            foreach (_; 0 .. fresh) {
                immutable id = _nextId++;
                _alive[id] = true;
                if (_generation[id] == 0)
                    _generation[id] = 1;
                outIds[k++] = id;
            }
        }
    }

    /// Allocating convenience over `spawnBatch(EntityId[])`.
    EntityId[] spawnBatch(size_t n) nothrow @trusted {
        auto ids = new EntityId[n];
        spawnBatch(ids);
        return ids;
    }

    void destroy(EntityId id) nothrow @nogc @trusted {
        if (id >= _alive.length || !_alive[id]) return;
        _alive[id] = false;
        _generation[id]++;
        if (_generation[id] == 0)
            _generation[id] = 1;
        foreach (s; _stores) {
            if (s !is null)
                s.remove(id);
        }
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

    size_t entityCount() const nothrow @nogc @trusted {
        size_t n = 0;
        foreach (a; _alive) if (a) n++;
        return n;
    }

    void clearEntities() nothrow @nogc @trusted {
        foreach (i; 0 .. _alive.length) {
            if (_alive[i]) {
                _alive[i] = false;
                _generation[i]++;
                if (_generation[i] == 0)
                    _generation[i] = 1;
                foreach (s; _stores) {
                    if (s !is null)
                        s.remove(cast(EntityId) i);
                }
            }
        }
        _nextId = 0;
        _freeCount = 0;
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

    /// Batched `rawAdd`: `bytes` holds `ids.length` consecutive component items of the type's size. Ids that are not
    /// alive are skipped (as `rawAdd` does); the rest are inserted through `RawComponentStore.addBatch`.
    void rawAddBatch(ComponentTypeId tid, scope const(EntityId)[] ids, scope const(ubyte)[] bytes) nothrow @trusted {
        auto s = getOrCreateStore(tid);
        if (s is null || ids.length == 0)
            return;
        assert(bytes.length == ids.length * s.itemSize, "rawAddBatch: bytes must hold ids.length items");
        bool allAlive = true;
        foreach (id; ids)
            if (!alive(id)) {
                allAlive = false;
                break;
            }
        if (allAlive) {
            s.addBatch(ids, bytes);
            return;
        }
        foreach (i, id; ids)
            if (alive(id))
                s.add(id, bytes[i * s.itemSize .. (i + 1) * s.itemSize]);
    }

    /// Typed batched add: component `comps[i]` goes to `ids[i]`.
    void setBatch(C)(scope const(EntityId)[] ids, scope const(C)[] comps) @trusted {
        assert(ids.length == comps.length);
        immutable tid = ensureRegistered!C();
        auto p = cast(const(ubyte)*) comps.ptr;
        rawAddBatch(tid, ids, p[0 .. comps.length * C.sizeof]);
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
        // The next module may define this component with another layout.
        types.markStale(tid);
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
        } else if (types.getType(tid).size != C.sizeof) {
            throw new Exception("component type name collision: '" ~ name
                ~ "' is already registered with a different size");
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
        assert(slice.length == C.sizeof, "Component type name collision");
        return *cast(C*) slice.ptr;
    }

    C* getPtr(C)(EntityId id) nothrow @nogc @trusted {
        immutable name = __traits(identifier, C);
        immutable tid = types.find(name, strings);
        if (tid == invalidComponentTypeId || tid >= _stores.length || _stores[tid] is null)
            return null;
        auto slice = _stores[tid].get(id);
        if (slice is null) return null;
        assert(slice.length == C.sizeof, "Component type name collision");
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

@("sceneWorld.recyclingAndGenerations") @safe unittest {
    static struct Tag { uint v = 1; }

    SceneWorld world;
    auto e0 = world.spawn();
    auto h0 = world.handle(e0);
    assert(h0.generation == 1 && world.aliveHandle(h0));
    world.set(e0, Tag(7));

    world.destroy(e0);
    assert(!world.aliveHandle(h0));
    assert(world.generation(e0) == 2);

    auto e0b = world.spawn();
    assert(e0b == e0);
    assert(!world.aliveHandle(h0));
    assert(world.handle(e0b).generation == 2);

    world.clearEntities();
    foreach (_; 0 .. 100) {
        EntityId[24] batch;
        foreach (i; 0 .. 24) {
            batch[i] = world.spawn();
            world.set(batch[i], Tag(cast(uint) i));
        }
        foreach (i; 0 .. 24) {
            world.destroy(batch[i]);
        }
    }
    assert(world.capacity() == 24);
    immutable tid = world.ensureRegistered!Tag();
    assert(world.getStore(tid).sparseLength() == 24);
}

@("sceneWorld.spawnBatchMatchesSequentialSpawn") @safe unittest {
    SceneWorld a, b;
    // Fresh ids
    auto ids = a.spawnBatch(5);
    assert(ids == [0u, 1, 2, 3, 4]);
    foreach (i; 0 .. 5)
        assert(b.spawn() == ids[i]);
    assert(a.entityCount == 5 && a.generation(3) == 1);
    // Recycled ids come first (LIFO), then fresh ones: same as sequential spawns
    a.destroy(1); a.destroy(3);
    b.destroy(1); b.destroy(3);
    auto more = a.spawnBatch(4);
    foreach (i; 0 .. 4)
        assert(b.spawn() == more[i]);
    assert(more == [3u, 1, 5, 6]);
    assert(a.alive(5) && a.alive(6) && a.capacity == b.capacity && a.freeCount == 0);
    assert(a.generation(1) == 2 && !a.aliveHandle(EntityHandle(1, 1)));
    // empty batch and the allocating overload
    EntityId[] none;
    a.spawnBatch(none);
    assert(a.spawnBatch(0).length == 0);
    // clearEntities then batch reuses ids from 0 with bumped generations
    a.clearEntities();
    auto again = a.spawnBatch(3);
    assert(again == [0u, 1, 2] && a.generation(1) == 3);
}

@("sceneWorld.addBatchOrderGrowthRemoval") @safe unittest {
    static struct P { float x = 0, y = 0; uint tag = 0; }
    SceneWorld world;
    immutable tid = world.ensureRegistered!P();
    enum N = 1000;
    auto ids = world.spawnBatch(N);
    P[] comps = new P[N];
    foreach (i; 0 .. N)
        comps[i] = P(i, -cast(float) i, cast(uint) i * 3);
    world.setBatch(ids, comps);
    auto s = world.getStore(tid);
    assert(s.count == N);
    // dense order == batch order, ids and values round-trip
    foreach (i; 0 .. N) {
        assert(s.denseToEntity[i] == ids[i]);
        assert(world.get!P(ids[i]) == comps[i]);
    }
    // batch is equivalent to per-entity set
    SceneWorld ref_;
    auto rids = ref_.spawnBatch(N);
    foreach (i; 0 .. N)
        ref_.set(rids[i], comps[i]);
    auto rs = ref_.getStore(ref_.ensureRegistered!P());
    assert(s.denseData[0 .. N * P.sizeof] == rs.denseData[0 .. N * P.sizeof]);

    // removal after a batch keeps the sparse set consistent (swap-and-pop)
    world.destroy(ids[0]);
    world.destroy(ids[500]);
    assert(s.count == N - 2 && !world.has!P(ids[0]) && !world.has!P(ids[500]));
    assert(world.get!P(ids[999]).x == 999 && world.get!P(ids[1]).x == 1);
    foreach (i; 0 .. s.count)
        assert(s.has(s.denseToEntity[i]) && s.sparse[s.denseToEntity[i]] == i);

    // a second batch on top: growth, overwrite of an existing id, and a repeated id (last wins)
    auto extra = world.spawnBatch(3);
    P[] more = [P(1, 1, 1), P(2, 2, 2), P(3, 3, 3)];
    world.setBatch([extra[0], extra[1], ids[1], extra[0]], [more[0], more[1], more[2], P(9, 9, 9)]);
    assert(s.count == N - 2 + 2);
    assert(world.get!P(extra[0]).x == 9 && world.get!P(ids[1]).x == 3);

    // batch ids beyond the current sparse length grow it once
    SceneWorld w2;
    immutable t2 = w2.ensureRegistered!P();
    auto big = w2.spawnBatch(4096);
    w2.setBatch(big[4000 .. 4096], new P[96]);
    assert(w2.getStore(t2).count == 96 && w2.getStore(t2).sparseLength >= 4096);
    // dead ids in a batch are skipped
    w2.destroy(big[4001]);
    w2.setBatch(big[4000 .. 4003], [P(1, 0, 0), P(2, 0, 0), P(3, 0, 0)]);
    assert(!w2.has!P(big[4001]) && w2.get!P(big[4002]).x == 3);
}

@("sceneWorld.unregisterType: a re-registered component uses its new layout")
@safe unittest {
    static struct A { @component static struct Health { int hp = 100; } }
    static struct B { @component static struct Health { int hp = 100; int shield = 7; } }
    SceneWorld w;
    auto e = w.spawn();
    w.set(e, A.Health(42));
    bool threw;
    try w.set(e, B.Health(1, 2));
    catch (Exception) threw = true;
    assert(threw && w.get!(A.Health)(e).hp == 42);

    w.unregisterType(w.ensureRegistered!(A.Health)());
    assert(!w.has!(A.Health)(e));
    w.set(e, B.Health(1, 2));
    assert(w.get!(B.Health)(e) == B.Health(1, 2));
    assert(w.getStore(w.ensureRegistered!(B.Health)()).itemSize == B.Health.sizeof);
}
