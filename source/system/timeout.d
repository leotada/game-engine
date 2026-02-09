module system.timeout;

import system;
import component.timeout;
import entity.manager;
import entity;

class TimeoutSystem : ISystem
{
    void run(ref EntityManager entityManager, double frameTime)
    {
        foreach (ref Entity entity; entityManager.getByComponent!Timeout())
        {
            if (entity is null)
                continue;

            Timeout timeout = entity.getComponent!Timeout();
            if (timeout is null || timeout.expired)
                continue;

            timeout.elapsed += frameTime;
            if (timeout.elapsed >= timeout.duration)
            {
                timeout.expired = true;
                entity.active = false;
            }
        }
    }
}
