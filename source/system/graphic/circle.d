module system.graphic.circle;

import system;
import component.graphic.circle;
import entity.manager;
import entity;
import raylib;


class CircleSystem : ISystem
{
    void draw(ref Circle circle)
    {
        DrawCircle(cast(int) circle.position.x, cast(int) circle.position.y, circle.radius, circle.color);
    }

    void run(ref EntityManager entityManager, double frameTime)
    {
        foreach (ref Entity entity; entityManager.getByComponent!Circle())
        {
            Circle circle = entity.getComponent!Circle();
            draw(circle);
        }
    }
}


