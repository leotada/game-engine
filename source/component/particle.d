module component.particle;

import math.vector;

/// Particle physics component — POD struct, no virtual dispatch.
struct Particle
{
    float mass = 1.0;
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

    void reset()
    {
        mass = 1.0;
        velocity = Vector(0, 0, 0);
        speed = 0.0;
        _forces = Vector(0, 0, 0);
        forces[0] = Vector(0, 0, 0);
        forces[1] = Vector(0, 0, 0);
        forces[2] = Vector(0, 0, 0);
        gravity = false;
    }
}
