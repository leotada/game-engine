module component.particle;

import core.memory: GC;

import component;
import math.vector;


class Particle : Component
{
    float mass = 1.0;
    Vector position;
    Vector velocity;
    float speed = 0.0;
    Vector _forces;
    Vector[3] forces;
    bool gravity;

    void addForce(Vector force)
    {
        this.forces[0] = force;
    }

    void addForce(Vector force, int index)
    {
        this.forces[index] = force;
    }

    ~this()
    {
        GC.free(&this.forces);
    }
}
