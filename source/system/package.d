module system;

import entity.manager;

interface ISystem
{
    void run(ref EntityManager entityManager, double frameTime);
}

