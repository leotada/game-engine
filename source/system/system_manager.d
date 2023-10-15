module system.system_manager;

import system;
import component.manager;
import raylib;


class SystemManager
{
    private ISystem[] systems;
    private ComponentManager componentManager;

    this(ComponentManager componentManager)
    {
        this.componentManager = componentManager;
    }

    void add(T)(T system)
    {
        systems ~= system;
    }

    void run()
    {
        foreach (system; systems)
        {
            system.run(componentManager, GetFrameTime());
        }
    }
}