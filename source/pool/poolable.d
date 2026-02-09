module pool.poolable;

/**
 * Interface for objects that can be pooled.
 * Implementing classes will have reset() called when released back to pool.
 */
interface IPoolable
{
    /// Reset object state for reuse
    void reset();
}
