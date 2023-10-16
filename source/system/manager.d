module system.manager;

import system;
import entity.manager;

import raylib;


class SystemManager
{
    private ISystem[] systems;
    private EntityManager entityManager;

    this(ref EntityManager entityManager)
    {
        this.entityManager = entityManager;
    }

    void add(T)(T system)
    {
        systems ~= system;
    }

    void run()
    {
        foreach (ref system; systems)
        {
            system.run(entityManager, GetFrameTime());
        }
    }
}