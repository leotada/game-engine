module component.particle;

import component;
import math.vector;


class Particle : Component
{
    float mass = 1.0;
    Vector position;
    Vector velocity;
    float speed = 0.0;
    Vector _forces;
    Vector[] forces;
    bool gravity;

    void addForce(Vector force)
    {
        this.forces ~= force;
    }
}