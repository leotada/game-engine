module system.particle;

import system;
import component.particle;
import entity.manager;
import entity;
import math.vector;


immutable float GRAVITYACCELERATION = -9.8;
immutable float PHYSICS_SCALE = 8;


class ParticleSystem : ISystem
{
    // Aggregates forces acting on the particle
    void calcLoads(ref Particle particle) @safe
    {
        // Reset forces
        particle._forces.x = 0;
        particle._forces.y = 0;

        // Aggregate forces
        foreach (force; particle.forces)
        {
            particle._forces += force;
        }
        particle.forces = [];

        // Apply gravity force
        if (particle.gravity)
            particle._forces.y -= particle.mass * GRAVITYACCELERATION * PHYSICS_SCALE;
    }

    // Integrates one time step
    void updateBodyEuler(double dt, ref Particle particle)
    {
        Vector a;
        Vector dv;
        Vector ds;

        // Integrate equation of motion
        a = particle._forces / particle.mass;

        dv = a * dt;
        particle.velocity += dv;

        ds = particle.velocity * dt;
        particle.position += ds;

        // Misc. calculations
        particle.speed = particle.velocity.magnitude();
    }

    void run(ref EntityManager entityManager, double frameTime)
    {
        debug {
            import std.stdio : writeln;
            writeln(entityManager.get(1).componentDict);
        }

        foreach (ref Entity entity; entityManager.getByComponent!Particle())
        {
            Particle particle = entity.getComponent!Particle();
            calcLoads(particle);
            updateBodyEuler(frameTime, particle);
            entity.position = particle.position;
        }
        
    }

}
