// Jolt-style PhysicsSystem — top-level entry point mirroring
// Jolt/Physics/PhysicsSystem.h.
//
// PhysicsSystem is a thin alias over the existing PhysicsWorld template so
// the underlying algorithm (Bullet-inspired SI solver + DBVT broadphase)
// stays the same. Callers get a Jolt-idiomatic surface:
//
//     auto system = new PhysicsSystem!();
//     system.init();
//     auto bi = system.getBodyInterface();
//     auto bid = bi.createAndAddBody(settings, EActivation.Activate);
//     system.update(1.0f / 60.0f);
//     auto npq = system.getNarrowPhaseQuery();
//     RayCastResult hit;
//     npq.castRay(RRayCast(origin, direction), hit);
//
// The legacy `addStatic` / `addDynamic` / `step` API on the underlying
// PhysicsWorld is still reachable via `.world` for the compat facade.
module engine.physics.system;

import engine.math.vec;
import engine.physics.world : PhysicsWorld;
import engine.physics.types : PhysicsStats;
import engine.physics.solver : SolverConfig;
import engine.physics.body_interface : BodyInterface;
import engine.physics.narrow_phase_query : NarrowPhaseQuery;

@safe:

/// Jolt-style façade. `MaxBodies` / `MaxManifolds` match the legacy template
/// parameters so gameplay code can size the engine up-front.
struct PhysicsSystem(uint MaxBodies = 4096, uint MaxManifolds = 8192) {
@safe:
    PhysicsWorld!(MaxBodies, MaxManifolds) world;

    /// Must be called before any body creation. Mirrors Jolt::PhysicsSystem::Init.
    void init_()  { world.init_(); }

    /// Advance the simulation by `dt`. `collisionSteps` is accepted for
    /// Jolt API parity; the MVP runs a single step regardless.
    void update(float dt, int collisionSteps = 1)  {
        if (collisionSteps <= 0) collisionSteps = 1;
        immutable sub = dt / collisionSteps;
        foreach (_; 0 .. collisionSteps) world.step(sub);
    }

    BodyInterface!(MaxBodies, MaxManifolds) getBodyInterface() return  {
        return BodyInterface!(MaxBodies, MaxManifolds)(&world);
    }

    NarrowPhaseQuery!(MaxBodies, MaxManifolds) getNarrowPhaseQuery() return  {
        return NarrowPhaseQuery!(MaxBodies, MaxManifolds)(&world);
    }

    ref Vec3 gravity() return  { return world.gravity; }
    ref SolverConfig solverConfig() return  { return world.solverCfg; }
    ref PhysicsStats stats() return  { return world.stats; }

    uint bodyCount() const  { return world.bodyCount; }

    /// Mirrors Jolt::PhysicsSystem::OptimizeBroadPhase. The legacy DBVT is
    /// incrementally balanced, so this is currently a no-op retained for
    /// API parity.
    void optimizeBroadPhase() { /* no-op */ }
}
