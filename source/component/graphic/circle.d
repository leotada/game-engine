module component.graphic.circle;

import component;
import math.vector;
import raylib : Colors;

class Circle : Component
{
    Vector position;
    float radius = 5;
    Colors color = Colors.GRAY;
}