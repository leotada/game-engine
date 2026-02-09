module component;

import pool.poolable;

class Component : IPoolable
{
    bool active = true;
    bool owned = false;

    /// Reset component state for reuse (override in subclasses)
    void reset()
    {
        active = true;
        owned = false;
    }
}
