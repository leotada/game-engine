module system.graphic.circle;

import system;
import component.graphic.circle;
import component.manager;
import raylib;


class CircleSystem : ISystem
{
    void draw(ref Circle circle)
    {
        DrawCircle(cast(int) circle.position.x, cast(int) circle.position.y, circle.radius, circle.color);
    }

    void run(ref ComponentManager componentManager, double frameTime)
    {
        foreach (ref p; componentManager.Get!Circle())
        {
            draw(p);
        }
    }
}


