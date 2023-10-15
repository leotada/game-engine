module system.particle;

import system;
import component.particle;
import component.manager;

import math.vector;


immutable float GRAVITYACCELERATION = -9.8;
immutable float PHYSICS_SCALE = 8;


class ParticleSystem : ISystem
{
    // Aggregates forces acting on the particle
    void calcLoads(ref Particle particle) @safe
    {
        // Reset forces
        particle.vForces.x = 0;
        particle.vForces.y = 0;

        // Aggregate forces
        foreach (force; particle.forces)
        {
            particle.vForces += force;
        }
        particle.forces = [];

        // Apply gravity force
        if (particle.gravity)
            particle.vForces.y -= particle.fMass * GRAVITYACCELERATION * PHYSICS_SCALE;
    }

    // Integrates one time step
    void updateBodyEuler(double dt, ref Particle particle)
    {
        Vector a;
        Vector dv;
        Vector ds;

        // Integrate equation of motion
        a = particle.vForces / particle.fMass;

        dv = a * dt;
        particle.vVelocity += dv;

        ds = particle.vVelocity * dt;
        particle.vPosition += ds;

        // Misc. calculations
        particle.fSpeed = particle.vVelocity.magnitude();
    }

    // Draws the particle
/*     void draw(ref Particle particle)
    {
        DrawCircle(cast(int) particle.vPosition.x, cast(int) particle.vPosition.y, particle.fRadius, Colors.BROWN);
    } */

    void run(ref ComponentManager componentManager, double frameTime)
    {
        foreach (ref p; componentManager.Get!Particle())
        {
            calcLoads(p);
            updateBodyEuler(frameTime, p);
        }
    }

}
