module component.circle;

import raylib : Colors;

/// Circle rendering component — POD struct.
struct Circle
{
    float radius = 5;
    Colors color = Colors.GRAY;

    void reset()
    {
        radius = 5;
        color = Colors.GRAY;
    }
}
