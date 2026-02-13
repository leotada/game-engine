module system.particle;

import component.particle;
import component.position;
import math.vector;
import std.random;

immutable float GRAVITYACCELERATION = -9.8;
immutable float PHYSICS_SCALE = 8;

/// Aggregates forces acting on the particle
private void calcLoads(ref Particle particle)
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

/// Integrates one time step using Euler method
private void updateBodyEuler(double dt, ref Particle particle, ref Position pos)
{
    // Integrate equation of motion
    Vector a = particle._forces / particle.mass;

    Vector dv = a * dt;
    particle.velocity += dv;

    Vector ds = particle.velocity * dt;
    pos.x += ds.x;
    pos.y += ds.y;
    pos.z += ds.z;

    // Misc. calculations
    particle.speed = particle.velocity.magnitude();
}

/// Particle physics system — template function, zero virtual dispatch.
void particleSystem(Registry)(ref Registry reg, double frameTime)
{
    auto rng = Random(unpredictableSeed);

    foreach (entityId; reg.entitiesWith!(Particle, Position))
    {
        auto particle = reg.store!Particle.getPointer(entityId);
        auto pos = reg.store!Position.getPointer(entityId);

        if (particle is null || pos is null)
            continue;

        auto i = uniform(-100, 100, rng);
        particle.addForce(Vector(40, 0, 0), 0);
        particle.addForce(Vector(i, i, 0), 1);

        calcLoads(*particle);
        updateBodyEuler(frameTime, *particle, *pos);
    }
}
