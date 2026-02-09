module entity.manager;

import entity;
import pool;
import component;

/**
 * EntityManager with O(1) add/remove operations using sparse set pattern.
 * 
 * Architecture:
 * - entities[]: Dense array of active entities (no gaps)
 * - entityIndices[]: Maps entity.id -> position in entities[]
 * - Removal: Swap-and-pop (O(1) instead of O(n) filtering)
 */
class EntityManager
{
    private Entity[] entities; // Dense packed array
    private size_t[uint] entityIndices; // entity.id -> index in entities[]
    private uint nextId = 0;
    private ObjectPool!Entity entityPool;

    // Component index: typeinfo -> set of entity indices
    private size_t[][TypeInfo] componentIndex;

    this()
    {
        entityPool = new ObjectPool!Entity();
        entities.reserve(10_000); // Pre-allocate for performance
    }

    /// Create a new entity from the pool
    Entity createEntity()
    {
        auto e = entityPool.acquire();
        e.id = nextId++;
        return e;
    }

    /// Add an entity to the manager - O(1)
    void add(Entity entity)
    {
        size_t idx = entities.length;
        entities ~= entity;
        entityIndices[entity.id] = idx;

        // Update component indices
        foreach (TypeInfo key; entity.getComponentTypes())
        {
            if (key in componentIndex)
                componentIndex[key] ~= idx;
            else
                componentIndex[key] = [idx];
        }
    }

    /// Remove entity - O(1) using swap-and-pop
    void remove(ref Entity entity)
    {
        if (entity.id !in entityIndices)
            return;

        size_t idx = entityIndices[entity.id];
        size_t lastIdx = entities.length - 1;

        // Remove from component indices
        foreach (TypeInfo key; entity.getComponentTypes())
        {
            if (key in componentIndex)
            {
                removeFromComponentIndex(key, idx);
            }
        }

        // Swap with last element if not already last
        if (idx != lastIdx)
        {
            Entity lastEntity = entities[lastIdx];
            entities[idx] = lastEntity;
            entityIndices[lastEntity.id] = idx;

            // Update component indices for swapped entity
            foreach (TypeInfo key; lastEntity.getComponentTypes())
            {
                if (key in componentIndex)
                {
                    updateComponentIndex(key, lastIdx, idx);
                }
            }
        }

        // Pop the last element
        entities = entities[0 .. $ - 1];
        entityIndices.remove(entity.id);

        // Return to pool
        entityPool.release(entity);
    }

    // Remove an index from a component's entity list - O(n) but on small arrays
    private void removeFromComponentIndex(TypeInfo key, size_t idx)
    {
        auto arr = componentIndex[key];
        for (size_t i = 0; i < arr.length; i++)
        {
            if (arr[i] == idx)
            {
                // Swap with last and pop
                arr[i] = arr[$ - 1];
                componentIndex[key] = arr[0 .. $ - 1];
                return;
            }
        }
    }

    // Update component index when an entity is swapped
    private void updateComponentIndex(TypeInfo key, size_t oldIdx, size_t newIdx)
    {
        auto arr = componentIndex[key];
        for (size_t i = 0; i < arr.length; i++)
        {
            if (arr[i] == oldIdx)
            {
                arr[i] = newIdx;
                return;
            }
        }
    }

    Entity get(uint id)
    {
        if (id in entityIndices)
            return entities[entityIndices[id]];
        return null;
    }

    Entity[] getAll()
    {
        return entities;
    }

    /// Get entities by component - returns indices, then lookup
    Entity[] getByComponent(T)()
    {
        TypeInfo key = T.classinfo;
        if (key !in componentIndex)
            return [];

        Entity[] result;
        result.reserve(componentIndex[key].length);
        foreach (idx; componentIndex[key])
        {
            if (idx < entities.length)
                result ~= entities[idx];
        }
        return result;
    }

    /// Get active entity count
    @property size_t count() const
    {
        return entities.length;
    }

    /// Get pool statistics
    @property size_t poolAvailable() const
    {
        return entityPool.availableCount;
    }

    @property size_t poolTotalAllocated() const
    {
        return entityPool.totalAllocated;
    }
}

unittest
{
    import component.particle;

    auto em = new EntityManager();
    auto e1 = em.createEntity();
    auto e2 = em.createEntity();

    e1.addComponent!Particle(new Particle());
    e2.addComponent!Particle(new Particle());

    em.add(e1);
    em.add(e2);

    assert(em.count == 2);
    assert(em.getByComponent!Particle().length == 2);

    // Test removal
    em.remove(e1);
    assert(em.count == 1);
    assert(em.get(e1.id) is null);
    assert(em.get(e2.id) !is null);
}
