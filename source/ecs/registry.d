module ecs.registry;

import ecs.store;
import std.meta : staticIndexOf;

/**
 * Compile-time ECS Registry using variadic templates.
 *
 * Usage:
 *   alias World = Registry!(Position, Particle, Circle, Timeout);
 *   World world;
 *
 *   auto e = world.create();
 *   world.store!Position.add(e, Position(100, 200));
 *   world.store!Particle.add(e, Particle(...));
 *
 *   foreach (id; world.entitiesWith!(Position, Particle)) {
 *       auto pos = world.store!Position.getPointer(id);
 *       auto p   = world.store!Particle.getPointer(id);
 *   }
 *
 * All store lookups and query resolution happen at compile time.
 * Zero virtual dispatch, zero hash lookups.
 */
struct Registry(Components...)
{
    // ─── Compile-time store generation ────────────────────────────────────
    // One ComponentStore per component type, stored as a tuple of fields.
    private template Stores(Cs...)
    {
        static if (Cs.length == 0)
        {
            alias Stores = imported!"std.meta".AliasSeq!();
        }
        else
        {
            alias Stores = imported!"std.meta".AliasSeq!(ComponentStore!(Cs[0]),
                Stores!(Cs[1 .. $]));
        }
    }

    Stores!Components _stores;

    private uint _nextId = 0;
    private bool[] _alive;

    // ─── Entity lifecycle ─────────────────────────────────────────────────

    uint create()
    {
        uint id = _nextId++;
        if (id >= _alive.length)
        {
            size_t newLen = (id + 1) * 2;
            size_t oldLen = _alive.length;
            _alive.length = newLen;
            _alive[oldLen .. newLen] = false;
        }
        _alive[id] = true;
        return id;
    }

    void destroy(uint id)
    {
        if (id >= _alive.length || !_alive[id])
            return;

        _alive[id] = false;

        // Remove from all stores at compile time
        static foreach (idx; 0 .. Components.length)
        {
            _stores[idx].remove(id);
        }
    }

    bool alive(uint id) const
    {
        return id < _alive.length && _alive[id];
    }

    // ─── Store access (compile-time dispatch) ─────────────────────────────

    /// Get a reference to the ComponentStore for type C.
    /// Resolved entirely at compile time via staticIndexOf.
    ref auto store(C)()
    {
        enum idx = staticIndexOf!(C, Components);
        static assert(idx >= 0, "Component " ~ C.stringof ~ " not in Registry");
        return _stores[idx];
    }

    // ─── Query ────────────────────────────────────────────────────────────

    auto entitiesWith(Query...)()
    {
        return EntitiesWithRange!(typeof(this), Query)(&this);
    }
}

/// Input range that iterates over entities having all queried components.
struct EntitiesWithRange(RegistryType, Query...)
{
    RegistryType* reg;
    const(uint)[] _entityIds;
    size_t _idx;

    this(RegistryType* registry)
    {
        reg = registry;
        _entityIds = registry.store!(Query[0]).entities;
        _idx = 0;
        advance();
    }

    @property bool empty() const
    {
        return _idx >= _entityIds.length;
    }

    @property uint front() const
    {
        return _entityIds[_idx];
    }

    void popFront()
    {
        _idx++;
        advance();
    }

    private void advance()
    {
        while (_idx < _entityIds.length)
        {
            uint id = _entityIds[_idx];

            if (!reg.alive(id))
            {
                _idx++;
                continue;
            }

            bool hasAll = true;
            static foreach (i, C; Query)
            {
                static if (i > 0)
                {
                    if (!reg.store!C.has(id))
                        hasAll = false;
                }
            }

            if (hasAll)
                return;

            _idx++;
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Unit Tests
// ─────────────────────────────────────────────────────────────────────────────
unittest
{
    struct Pos
    {
        float x, y;
    }

    struct Vel
    {
        float dx, dy;
    }

    struct Health
    {
        int hp;
    }

    alias World = Registry!(Pos, Vel, Health);
    World world;

    auto e0 = world.create();
    auto e1 = world.create();
    auto e2 = world.create();

    assert(e0 == 0);
    assert(e1 == 1);
    assert(e2 == 2);

    world.store!Pos.add(e0, Pos(1, 2));
    world.store!Vel.add(e0, Vel(10, 20));

    world.store!Pos.add(e1, Pos(3, 4));

    world.store!Pos.add(e2, Pos(5, 6));
    world.store!Vel.add(e2, Vel(30, 40));
    world.store!Health.add(e2, Health(100));

    auto p = world.store!Pos.getPointer(e0);
    assert(p !is null);
    assert(p.x == 1 && p.y == 2);

    uint[] matched;
    foreach (id; world.entitiesWith!(Pos, Vel))
    {
        matched ~= id;
    }
    assert(matched.length == 2);

    world.destroy(e0);
    assert(!world.alive(e0));
    assert(world.store!Pos.getPointer(e0) is null);

    uint[] matched2;
    foreach (id; world.entitiesWith!(Pos, Vel))
    {
        matched2 ~= id;
    }
    assert(matched2.length == 1);
    assert(matched2[0] == 2);
}
