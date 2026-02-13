module system.collision;

import component.particle;
import component.position;
import component.circle;
import math.vector;
import std.math.algebraic : sqrt;

// ── Tuning constants ────────────────────────────────────────────────────────
/// How aggressively particles are pushed apart on overlap.
/// 1.0 = exact correction, >1.0 = overcorrect to avoid lingering overlap.
immutable float SEPARATION_FACTOR = 1f;

/// How many collision resolution passes to run per frame.
/// More iterations = less overlap, but more CPU cost.
immutable int COLLISION_ITERATIONS = 1;

/// Elastic collision response between two particles (2D).
/// Uses conservation of momentum and kinetic energy.
private void resolveCollision(
    Particle* a, Position* posA, float radiusA,
    Particle* b, Position* posB, float radiusB)
{
    // Vector from A to B
    Vector delta = Vector(posB.x - posA.x, posB.y - posA.y, 0);
    float dist = delta.magnitude();

    float minDist = radiusA + radiusB;
    if (dist < 0.001f)
        dist = 0.001f;

    // ── Separation: push particles apart so they don't overlap ──────────
    float overlap = minDist - dist;
    Vector normal = delta / dist;
    float totalMass = a.mass + b.mass;

    // Weighted separation based on mass, amplified by SEPARATION_FACTOR
    float correctedOverlap = overlap * SEPARATION_FACTOR;
    float moveA = correctedOverlap * (b.mass / totalMass);
    float moveB = correctedOverlap * (a.mass / totalMass);

    posA.x -= normal.x * moveA;
    posA.y -= normal.y * moveA;
    posB.x += normal.x * moveB;
    posB.y += normal.y * moveB;

    // ── Velocity response: elastic collision ────────────────────────────
    Vector relVel = Vector(
        a.velocity.x - b.velocity.x,
        a.velocity.y - b.velocity.y,
        0
    );

    float velAlongNormal = relVel.dot(normal);

    // Only resolve if particles are approaching each other
    if (velAlongNormal > 0)
        return;

    // Restitution coefficient (1.0 = perfectly elastic, 0.5 = some energy loss)
    float restitution = 0.85f;

    // Impulse scalar
    float j = -(1.0f + restitution) * velAlongNormal;
    j /= (1.0f / a.mass) + (1.0f / b.mass);

    // Apply impulse
    Vector impulse = normal * j;
    a.velocity.x += impulse.x / a.mass;
    a.velocity.y += impulse.y / a.mass;
    b.velocity.x -= impulse.x / b.mass;
    b.velocity.y -= impulse.y / b.mass;
}

/// Particle collision system — detects and resolves collisions between
/// all particle pairs that have Position, Particle and Circle components.
///
/// Uses a spatial grid to avoid O(n²) full pair checks. The grid cell size
/// is based on the maximum particle radius so that only neighbouring cells
/// need to be checked.
ulong collisionSystem(Registry)(ref Registry reg, double dt)
{
    ulong totalCollisions = 0;

    foreach (iter; 0 .. COLLISION_ITERATIONS)
    {
        totalCollisions += collisionPass(reg);
    }

    return totalCollisions;
}

/// Single pass of collision detection and resolution.
private ulong collisionPass(Registry)(ref Registry reg)
{
    // ── Collect entity data into a local buffer for grid insertion ───────
    const(uint)[] entityIds = reg.store!Position.entities;
    size_t count = entityIds.length;

    if (count < 2)
        return 0;

    // Use a simple uniform grid for broad-phase
    enum float CELL_SIZE = 30.0f; // slightly larger than MAX_RADIUS * 2

    // For each entity, we store its position and index for fast access.
    struct EntityRef
    {
        uint id;
        float x, y, radius;
    }

    // Build a local array of entity refs that have all 3 components
    EntityRef[] refs;
    refs.reserve(count);

    foreach (eid; entityIds)
    {
        auto pos = reg.store!Position.getPointer(eid);
        auto circ = reg.store!Circle.getPointer(eid);
        auto part = reg.store!Particle.getPointer(eid);

        if (pos is null || circ is null || part is null)
            continue;

        refs ~= EntityRef(eid, pos.x, pos.y, circ.radius);
    }

    if (refs.length < 2)
        return 0;

    // ── Spatial hash grid broad-phase ───────────────────────────────────
    uint[][int] grid;

    int cellKey(float x, float y)
    {
        int cx = cast(int)(x / CELL_SIZE);
        int cy = cast(int)(y / CELL_SIZE);
        return cy * 10_000 + cx;
    }

    foreach (i, ref r; refs)
    {
        int key = cellKey(r.x, r.y);
        grid[key] ~= cast(uint) i;
    }

    // ── Narrow-phase: check pairs in same and neighbouring cells ────────
    ulong collisionCount = 0;

    // Offsets for 9 neighbouring cells (including self)
    static immutable int[2][9] offsets = [
        [0, 0], [1, 0], [-1, 0],
        [0, 1], [0, -1], [1, 1],
        [-1, -1], [1, -1], [-1, 1]
    ];

    foreach (key, ref cellEntities; grid)
    {
        int cy = key / 10_000;
        int cx = key % 10_000;

        foreach (ref offset; offsets)
        {
            int nkey = (cy + offset[1]) * 10_000 + (cx + offset[0]);
            auto neighborPtr = nkey in grid;
            if (neighborPtr is null)
                continue;

            foreach (idxA; cellEntities)
            {
                foreach (idxB; *neighborPtr)
                {
                    if (idxA >= idxB)
                        continue; // avoid duplicate pairs and self

                    auto rA = &refs[idxA];
                    auto rB = &refs[idxB];

                    // Quick distance check (squared to avoid sqrt)
                    float dx = rA.x - rB.x;
                    float dy = rA.y - rB.y;
                    float distSq = dx * dx + dy * dy;
                    float minDist = rA.radius + rB.radius;

                    if (distSq < minDist * minDist)
                    {
                        auto partA = reg.store!Particle.getPointer(rA.id);
                        auto posA = reg.store!Position.getPointer(rA.id);
                        auto partB = reg.store!Particle.getPointer(rB.id);
                        auto posB = reg.store!Position.getPointer(rB.id);

                        if (partA !is null && posA !is null &&
                            partB !is null && posB !is null)
                        {
                            resolveCollision(
                                partA, posA, rA.radius,
                                partB, posB, rB.radius
                            );
                            collisionCount++;
                        }
                    }
                }
            }
        }
    }

    return collisionCount;
}
