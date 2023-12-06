module system.particle;

import system;
import component.particle;
import entity.manager;
import entity;
import math.vector;

import std.random;

immutable float GRAVITYACCELERATION = -9.8;
immutable float PHYSICS_SCALE = 8;


class ParticleSystem : ISystem
{
    // Aggregates forces acting on the particle
    void calcLoads(scope ref Particle particle)
    {
        // Reset forces
        particle._forces.x = 0;
        particle._forces.y = 0;

        // Aggregate forces
        foreach (ref force; particle.forces)
        {
            particle._forces += force;
            force = Vector(0, 0, 0);
        }

        // Apply gravity force
        if (particle.gravity)
            particle._forces.y -= particle.mass * GRAVITYACCELERATION * PHYSICS_SCALE;
    }

    // Integrates one time step
    void updateBodyEuler(double dt, scope ref Particle particle)
    {
        scope Vector a;
        scope Vector dv;
        scope Vector ds;

        // Integrate equation of motion
        a = particle._forces / particle.mass;

        dv = a * dt;
        particle.velocity += dv;

        ds = particle.velocity * dt;
        particle.position += ds;

        // Misc. calculations
        particle.speed = particle.velocity.magnitude();
    }

    void run(scope ref EntityManager entityManager, double frameTime)
    {
        scope auto rnd = Random();

        foreach (scope ref Entity entity; entityManager.getByComponent!Particle())
        {
            scope Particle particle = entity.getComponent!Particle();
            //
            scope auto i = uniform(-100, 100, rnd);
            particle.addForce(Vector(40, 0, 0), 0);
            particle.addForce(Vector(i, i, 0), 1);
            //
            calcLoads(particle);
            updateBodyEuler(frameTime, particle);
            entity.position = particle.position; // TODO refactor
        }

    }

}
