module ecs.store;

/**
 * Compile-time generated component store using Sparse Set pattern.
 *
 * - dense[]: contiguous array of T (cache-friendly iteration)
 * - denseToEntity[]: maps dense index → entity ID
 * - sparse[]: maps entity ID → dense index (O(1) random access)
 *
 * No hash maps, no GC allocations on the hot path.
 * All type resolution happens at compile time via templates.
 */
struct ComponentStore(T)
{
    private T[] dense;
    private uint[] denseToEntity;
    private uint[] sparse;
    private enum uint INVALID = uint.max;

    /// Add a component for the given entity
    void add(uint entityId, T component)
    {
        ensureSparse(entityId);

        if (sparse[entityId] != INVALID)
        {
            // Already exists — overwrite
            dense[sparse[entityId]] = component;
            return;
        }

        uint denseIdx = cast(uint) dense.length;
        dense ~= component;
        denseToEntity ~= entityId;
        sparse[entityId] = denseIdx;
    }

    /// Remove a component using swap-and-pop (O(1))
    void remove(uint entityId)
    {
        if (entityId >= sparse.length || sparse[entityId] == INVALID)
            return;

        uint denseIdx = sparse[entityId];
        uint lastIdx = cast(uint)(dense.length - 1);

        if (denseIdx != lastIdx)
        {
            // Swap with last element
            dense[denseIdx] = dense[lastIdx];
            uint movedEntity = denseToEntity[lastIdx];
            denseToEntity[denseIdx] = movedEntity;
            sparse[movedEntity] = denseIdx;
        }

        // Pop last
        dense = dense[0 .. $ - 1];
        denseToEntity = denseToEntity[0 .. $ - 1];
        sparse[entityId] = INVALID;
    }

    /// O(1) pointer access — returns null if entity doesn't have this component
    T* getPointer(uint entityId)
    {
        if (entityId >= sparse.length || sparse[entityId] == INVALID)
            return null;
        return &dense[sparse[entityId]];
    }

    /// Check if entity has this component
    bool has(uint entityId) const
    {
        return entityId < sparse.length && sparse[entityId] != INVALID;
    }

    /// Number of active components
    @property size_t length() const
    {
        return dense.length;
    }

    /// Access the dense array for iteration
    @property inout(T)[] components() inout
    {
        return dense;
    }

    /// Access entity IDs corresponding to dense array
    @property const(uint)[] entities() const
    {
        return denseToEntity;
    }

    /// Pre-allocate sparse array capacity
    void reserve(uint maxEntityId)
    {
        ensureSparse(maxEntityId);
    }

    /// Clear all data
    void clear()
    {
        dense.length = 0;
        denseToEntity.length = 0;
        sparse[] = INVALID;
    }

    /// Ensure sparse array is large enough for the given entity ID
    private void ensureSparse(uint entityId)
    {
        if (entityId >= sparse.length)
        {
            size_t oldLen = sparse.length;
            size_t newLen = (entityId + 1) * 2; // Grow by 2x to amortize
            sparse.length = newLen;
            sparse[oldLen .. newLen] = INVALID;
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Unit Tests
// ─────────────────────────────────────────────────────────────────────────────
unittest
{
    struct TestComp
    {
        int value;
    }

    ComponentStore!TestComp store;

    // Add
    store.add(0, TestComp(10));
    store.add(5, TestComp(50));
    store.add(3, TestComp(30));

    assert(store.length == 3);
    assert(store.has(0));
    assert(store.has(5));
    assert(store.has(3));
    assert(!store.has(1));

    // getPointer
    auto p = store.getPointer(5);
    assert(p !is null);
    assert(p.value == 50);

    // Modify via pointer
    p.value = 99;
    assert(store.getPointer(5).value == 99);

    // Remove with swap-and-pop
    store.remove(0);
    assert(!store.has(0));
    assert(store.length == 2);
    assert(store.has(5)); // still there
    assert(store.has(3)); // still there

    // getPointer on removed
    assert(store.getPointer(0) is null);

    // Remove last remaining
    store.remove(5);
    store.remove(3);
    assert(store.length == 0);
}
