module system.timeout;

import component.timeout;

/// Timeout system — template function, zero virtual dispatch.
/// Marks entities as expired when their timeout elapses.
/// Returns array of expired entity IDs for cleanup.
uint[] timeoutSystem(Registry)(ref Registry reg, double frameTime)
{
    uint[] expired;

    foreach (entityId; reg.entitiesWith!(Timeout))
    {
        auto timeout = reg.store!Timeout.getPointer(entityId);

        if (timeout is null || timeout.expired)
            continue;

        timeout.elapsed += frameTime;
        if (timeout.elapsed >= timeout.duration)
        {
            timeout.expired = true;
            expired ~= entityId;
        }
    }

    return expired;
}
