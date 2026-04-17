// Jolt-style NarrowPhaseQuery. Mirrors Jolt/Physics/Collision/NarrowPhaseQuery.h
// for the MVP subset: castRay (first / closest hit).
//
// The query walks the broadphase DBVT via an AABB that encloses the ray,
// then runs per-shape raycasts on the candidate bodies. Planes are not in
// the DBVT (same as the legacy engine) and are probed linearly.
module engine.physics.narrow_phase_query;

import engine.math.vec;
import engine.math.quat;
import engine.physics.types;
import engine.physics.ray_cast;
import engine.physics.world : PhysicsWorld;

@safe:

/// Ray-cast accessor for a PhysicsWorld. Construct via `world.narrowPhaseQuery`.
struct NarrowPhaseQuery(uint MaxBodies, uint MaxManifolds) {
@safe:
    private PhysicsWorld!(MaxBodies, MaxManifolds)* world;

    this(return scope PhysicsWorld!(MaxBodies, MaxManifolds)* w) pure nothrow @nogc
    in (w !is null)
    {
        world = w;
    }

    /// Cast `ray` and populate `result` with the closest hit in [0, 1].
    /// Returns true if any body was hit.
    bool castRay(RRayCast ray, ref RayCastResult result,
                 RayCastSettings settings = RayCastSettings.init)  {
        return castRayImpl(ray, result, settings);
    }

    private bool castRayImpl(RRayCast ray, ref RayCastResult result,
                             RayCastSettings settings) @trusted {
        result = RayCastResult.init;
        if (world is null || world.bodyCount == 0) return false;

        // Build an AABB enclosing the ray for DBVT traversal.
        immutable p0 = ray.origin;
        immutable p1 = ray.origin + ray.direction;
        Aabb rayAabb;
        rayAabb.min = Vec3(
            p0.x < p1.x ? p0.x : p1.x,
            p0.y < p1.y ? p0.y : p1.y,
            p0.z < p1.z ? p0.z : p1.z);
        rayAabb.max = Vec3(
            p0.x > p1.x ? p0.x : p1.x,
            p0.y > p1.y ? p0.y : p1.y,
            p0.z > p1.z ? p0.z : p1.z);

        float bestT = 2.0f;
        RigidBodyId bestId = INVALID_BODY;
        Vec3 bestN = Vec3(0, 1, 0);

        // 1. Probe candidates from the DBVT.
        auto w = world;
        w.dbvt.query(rayAabb, (uint bid) @safe {
            if (bid >= w.bodyCount) return;
            float t; Vec3 n;
            if (rayVsShape(ray, w.position[bid], w.orientation[bid], w.shape[bid], t, n)) {
                if (t < bestT) { bestT = t; bestId = bid; bestN = n; }
            }
        });

        // 2. Planes are kept outside the DBVT — walk them linearly.
        foreach (i; 0 .. w.bodyCount) {
            if (!w.isPlane[i]) continue;
            float t; Vec3 n;
            if (rayVsShape(ray, w.position[i], w.orientation[i], w.shape[i], t, n)) {
                if (t < bestT) { bestT = t; bestId = cast(RigidBodyId) i; bestN = n; }
            }
        }

        if (bestId == INVALID_BODY) return false;
        result.bodyId   = bestId;
        result.fraction = bestT;
        result.normal   = bestN;
        return true;
    }
}
