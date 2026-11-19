/**
 * `MaterialPool` — generational storage for `Material`s addressed by POD
 * `MaterialHandle`s.
 *
 * ECS components and `ModelInstance` overrides cannot hold `Material*`
 * (raw pointers in engine storage). They hold a `MaterialHandle` instead and
 * resolve it once per draw with `get` (two array reads, `nothrow @nogc`).
 * A removed material bumps its slot generation, so stale handles resolve to
 * `null` instead of a recycled material.
 */
module engine.graphics.material_pool;

import core.lifetime : move;

import engine.core.handle : Handle;
import engine.core.log : warn;
import engine.core.pod : Pod;
import engine.graphics.material : Material;

@safe:

/// POD reference to a `Material` stored in a `MaterialPool`.
alias MaterialHandle = Handle!Material;

/// Fixed-capacity pool; slot addresses never move, so `get` pointers stay
/// valid until `remove`.
struct MaterialPool {
    private Material[] slots;          // slot 0 is the null handle
    private Pod!uint[] generations;
    private Pod!bool[] alive;
    private Pod!uint[] freeList;
    private uint nextFresh = 1;

    @disable this(this);

    static MaterialPool create(uint capacity = 1024) {
        MaterialPool p;
        p.slots = new Material[capacity + 1];
        p.generations = new uint[capacity + 1];
        p.alive = new bool[capacity + 1];
        return p;
    }

    /// Number of live materials.
    size_t length() const nothrow @nogc {
        return (nextFresh - 1) - freeList.length;
    }

    /// Take ownership of `material` (moved out). Returns a null handle when full.
    MaterialHandle add(ref Material material) {
        uint idx;
        if (freeList.length) {
            idx = freeList[$ - 1];
            freeList = freeList[0 .. $ - 1];
        } else if (nextFresh < slots.length) {
            idx = nextFresh++;
        } else {
            warn("MaterialPool full (capacity ", slots.length - 1, ")");
            return MaterialHandle.init;
        }
        move(material, slots[idx]);
        alive[idx] = true;
        return MaterialHandle(idx, generations[idx]);
    }

    /// Live material behind `h`, or null for null/stale handles.
    Material* get(MaterialHandle h) return nothrow @nogc @trusted {
        if (!valid(h)) return null;
        return &slots[h.index];
    }

    /// True when `h` addresses a live material.
    bool valid(MaterialHandle h) const nothrow @nogc {
        return h.index != 0 && h.index < slots.length && alive[h.index] && generations[h.index] == h.generation;
    }

    /// Destroy the GPU material and invalidate every handle to it.
    bool remove(MaterialHandle h) {
        if (!valid(h)) return false;
        slots[h.index].destroy();
        slots[h.index] = Material.init;
        alive[h.index] = false;
        generations[h.index]++;
        freeList ~= h.index;
        return true;
    }

    /// Destroy every live material.
    void destroy() nothrow @nogc {
        foreach (i; 1 .. nextFresh) {
            if (alive.length > i && alive[i]) {
                slots[i].destroy();
                alive[i] = false;
            }
        }
    }
}

@("materialPool.handles") @safe unittest {
    auto pool = MaterialPool.create(2);
    Material a, b, c;
    a.surfaceShader = 11;
    b.surfaceShader = 22;
    c.surfaceShader = 33;
    auto ha = pool.add(a);
    auto hb = pool.add(b);
    assert(!ha.isNull && !hb.isNull && ha != hb);
    assert(pool.add(c).isNull); // full
    assert(pool.length == 2);
    assert(pool.get(ha).surfaceShader == 11);
    assert(pool.get(hb).surfaceShader == 22);
    assert(pool.get(MaterialHandle.init) is null);

    assert(pool.remove(ha));
    assert(pool.get(ha) is null);        // stale
    assert(!pool.remove(ha));
    auto hc = pool.add(c);               // reuses the slot with a new generation
    assert(hc.index == ha.index && hc.generation != ha.generation);
    assert(pool.get(ha) is null && pool.get(hc).surfaceShader == 33);
    pool.destroy();
}
