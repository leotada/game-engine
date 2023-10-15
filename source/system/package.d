module system;

import component.manager;

interface ISystem
{
    void run(ref ComponentManager componentManager, double frameTime);
}

