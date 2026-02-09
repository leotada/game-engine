module component.graphic.circle;

import component;
import raylib : Colors;

class Circle : Component
{
    float radius = 5;
    Colors color = Colors.GRAY;

    override void reset()
    {
        super.reset();
        radius = 5;
        color = Colors.GRAY;
    }
}
