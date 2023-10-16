module system.graphic.circle;

import system;
import component.graphic.circle;
import entity.manager;
import entity;
import math.vector;

import raylib;


class CircleSystem : ISystem
{
    void draw(Vector basePosition, ref Circle circle)
    {
        DrawCircle(
            cast(int) (basePosition.x + circle.position.x),
            cast(int) (basePosition.y + circle.position.y),
            circle.radius,
            circle.color
        );
    }

    void run(ref EntityManager entityManager, double frameTime)
    {
        foreach (ref Entity entity; entityManager.getByComponent!Circle())
        {
            Circle circle = entity.getComponent!Circle();
            draw(entity.position, circle);
        }
    }
}


