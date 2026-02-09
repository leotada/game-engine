module pool.object_pool;

import pool.poolable;

/**
 * Generic object pool to reduce GC allocations.
 * 
 * Usage:
 *   auto pool = new ObjectPool!Entity();
 *   pool.reserve(100);  // Pre-allocate 100 entities
 *   
 *   auto e = pool.acquire();  // Get from pool or create new
 *   // ... use entity ...
 *   pool.release(e);  // Return to pool for reuse
 */
class ObjectPool(T) if (is(T == class))
{
    private T[] available;
    private size_t _totalAllocated = 0;

    /// Acquire an object from the pool, or create a new one if empty
    T acquire()
    {
        if (available.length > 0)
        {
            T obj = available[$ - 1];
            available = available[0 .. $ - 1];
            return obj;
        }

        // Pool empty, allocate new object
        _totalAllocated++;
        return new T();
    }

    /// Release an object back to the pool for reuse
    void release(T obj)
    {
        if (obj is null)
            return;

        // If object implements IPoolable, reset it
        static if (is(T : IPoolable))
        {
            obj.reset();
        }

        available ~= obj;
    }

    /// Pre-allocate objects into the pool
    void reserve(size_t count)
    {
        foreach (_; 0 .. count)
        {
            T obj = new T();
            _totalAllocated++;
            available ~= obj;
        }
    }

    /// Number of objects currently available in pool
    @property size_t availableCount() const
    {
        return available.length;
    }

    /// Total objects allocated by this pool
    @property size_t totalAllocated() const
    {
        return _totalAllocated;
    }

    /// Clear the pool (objects become eligible for GC)
    void clear()
    {
        available.length = 0;
    }
}

// Unit tests
unittest
{
    static class TestObj : IPoolable
    {
        int value = 42;
        bool wasReset = false;

        void reset()
        {
            value = 0;
            wasReset = true;
        }
    }

    auto pool = new ObjectPool!TestObj();

    // Test acquire creates new object
    auto obj1 = pool.acquire();
    assert(obj1 !is null);
    assert(pool.totalAllocated == 1);
    assert(pool.availableCount == 0);

    // Test release returns to pool
    obj1.value = 100;
    pool.release(obj1);
    assert(pool.availableCount == 1);
    assert(obj1.wasReset); // reset() was called
    assert(obj1.value == 0); // value was reset

    // Test acquire reuses pooled object
    auto obj2 = pool.acquire();
    assert(obj2 is obj1); // Same object reused
    assert(pool.totalAllocated == 1); // No new allocation

    // Test reserve
    pool.reserve(5);
    assert(pool.availableCount == 5);
    assert(pool.totalAllocated == 6);
}
