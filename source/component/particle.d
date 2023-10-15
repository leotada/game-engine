module component.particle;

import component;
import math.vector;


class Particle : Component
{
    float fMass = 1.0;
    Vector vPosition;
    Vector vVelocity;
    float fSpeed = 0.0;
    Vector vForces;
    Vector[] forces;
    float fRadius = 5;
    bool gravity;

    void addForce(Vector force)
    {
        this.forces ~= force;
    }
}