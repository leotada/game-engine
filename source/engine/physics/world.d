// 
module engine.physics.world;

import engine.math.vec;
import engine.math.mat3;
import engine.math.quat;
import engine.physics.types;
import engine.physics.narrowphase;
import engine.physics.solver;
import engine.physics.broadphase;
import engine.physics.integrator;

import std.math : abs;

@safe:

struct PhysicsWorld(size_t MaxBodies = 4096) {
    @disable this(this);

    // --- SoA arrays --------------------------------------------------------
    Vec3[MaxBodies]  position;
    Quat[MaxBodies]  orientation;
    Vec3[MaxBodies]  velocity;
    Vec3[MaxBodies]  angularVel;
    Vec3[MaxBodies]  force;
    Vec3[MaxBodies]  torque;
    float[MaxBodies] invMass;
    Mat3[MaxBodies]  invInertiaLocal;
    Mat3[MaxBodies]  invInertiaWorld;
    Shape[MaxBodies] shape;
    Aabb[MaxBodies]  aabb;
    uint             bodyCount;

    // --- Config ------------------------------------------------------------
    Vec3          gravity = Vec3(0, -9.81f, 0);
    SolverConfig  solver;

    // --- Broadphase ---------------------------------------------------------
    // 32×8×64 cells of 4 m → 128×32×256 m window. Call recenterGrid(pos)
    // every step to keep a moving camera/player near the middle of the
    // window. The first step auto-centers on (0,0,0) for simpler setups.
    SpatialGrid!(32, 8, 64, 65536) grid;
    private bool gridInitialized = false;

    /// Move the grid origin so that `center` sits roughly in the middle.
    void recenterGrid(Vec3 center) {
        grid.origin = Vec3(
            center.x - 32 * grid.cellSize * 0.5f,
            center.y - 8  * grid.cellSize * 0.5f,
            center.z - 64 * grid.cellSize * 0.5f,
        );
        gridInitialized = true;
    }

    // Per-pair manifold buffer (dedup arena, overwritten each frame).
    private ContactManifold[MaxBodies * 2] manifolds;
    private size_t manifoldCount;

    // -----------------------------------------------------------------------
    // Body creation
    // -----------------------------------------------------------------------

    /// Add a dynamic body with `mass > 0`. Returns RigidBodyId (== INVALID_BODY on overflow).
    RigidBodyId addDynamic(Vec3 pos, Shape sh, float mass) {
        if (bodyCount >= MaxBodies || mass <= 0) return INVALID_BODY;
        immutable id = bodyCount++;
        position[id]         = pos;
        orientation[id]      = Quat.identity;
        velocity[id]         = Vec3(0, 0, 0);
        angularVel[id]       = Vec3(0, 0, 0);
        force[id]            = Vec3(0, 0, 0);
        torque[id]           = Vec3(0, 0, 0);
        invMass[id]          = 1.0f / mass;
        shape[id]            = sh;
        invInertiaLocal[id]  = computeInvInertia(sh, mass);
        invInertiaWorld[id]  = invInertiaLocal[id];
        aabb[id]             = computeAabb(pos, orientation[id], sh);
        return id;
    }

    /// Add a static (immovable) body. Mass and inverse inertia are zero.
    RigidBodyId addStatic(Vec3 pos, Shape sh) {
        if (bodyCount >= MaxBodies) return INVALID_BODY;
        immutable id = bodyCount++;
        position[id]         = pos;
        orientation[id]      = Quat.identity;
        velocity[id]         = Vec3(0, 0, 0);
        angularVel[id]       = Vec3(0, 0, 0);
        force[id]            = Vec3(0, 0, 0);
        torque[id]           = Vec3(0, 0, 0);
        invMass[id]          = 0.0f;
        shape[id]            = sh;
        invInertiaLocal[id]  = Mat3.zero();
        invInertiaWorld[id]  = Mat3.zero();
        aabb[id]             = computeAabb(pos, orientation[id], sh);
        return id;
    }

    // -----------------------------------------------------------------------
    // Simulation step
    // -----------------------------------------------------------------------

    /// Advance the world by `dt` seconds.
    void step(float dt) @trusted {
        if (!gridInitialized) recenterGrid(Vec3(0, 0, 0));

        // 1. Integrate velocities (apply gravity + forces).
        integrateVelocities(
            velocity[0 .. bodyCount],
            angularVel[0 .. bodyCount],
            force[0 .. bodyCount],
            torque[0 .. bodyCount],
            invInertiaWorld[0 .. bodyCount],
            invMass[0 .. bodyCount],
            gravity, dt,
        );

        // 2. Refresh AABBs (dynamic bodies only — static shapes never move).
        foreach (i; 0 .. bodyCount) {
            if (invMass[i] > 0.0f)
                aabb[i] = computeAabb(position[i], orientation[i], shape[i]);
        }

        // 3. Broadphase + narrowphase.
        manifoldCount = 0;
        grid.clear();
        foreach (i; 0 .. bodyCount) grid.insert(i, aabb[i]);

        // Pair emission uses grid dedup; fallback to simple AABB check here.
        grid.forEachPair((uint a, uint b) @safe {
            if (invMass[a] == 0.0f && invMass[b] == 0.0f) return; // static-static
            if (!aabb[a].overlaps(aabb[b])) return;
            ContactManifold m;
            if (testPair(a, b, m)) {
                if (manifoldCount < manifolds.length)
                    manifolds[manifoldCount++] = m;
            }
        }, aabb[0 .. bodyCount]);

        // 4. Sequential-impulse solver passes.
        foreach (_; 0 .. solver.iterations) {
            foreach (mi; 0 .. manifoldCount) {
                auto m = &manifolds[mi];
                SolverBody A, B;
                loadBody(m.a, A);
                loadBody(m.b, B);
                solveContact(A, B, *m, solver);
                storeBody(m.a, A);
                storeBody(m.b, B);
            }
        }

        // 5. Integrate positions + orientations.
        integratePositions(
            position[0 .. bodyCount],
            orientation[0 .. bodyCount],
            velocity[0 .. bodyCount],
            angularVel[0 .. bodyCount],
            dt,
        );

        // 6. Refresh world-space inertia for next step (R · I_local · Rᵀ).
        foreach (i; 0 .. bodyCount) {
            if (invMass[i] > 0.0f)
                invInertiaWorld[i] = rotateInertia(invInertiaLocal[i], orientation[i]);
        }
    }

    // -----------------------------------------------------------------------
    // Private helpers
    // -----------------------------------------------------------------------

    private void loadBody(RigidBodyId id, ref SolverBody b) {
        b.position   = position[id];
        b.velocity   = velocity[id];
        b.angularVel = angularVel[id];
        b.invInertia = invInertiaWorld[id];
        b.invMass    = invMass[id];
    }

    private void storeBody(RigidBodyId id, ref const SolverBody b) {
        velocity[id]   = b.velocity;
        angularVel[id] = b.angularVel;
    }

    private bool testPair(uint a, uint b, out ContactManifold m) {
        immutable ka = shape[a].kind;
        immutable kb = shape[b].kind;

        bool hit;
        if (ka == ShapeKind.box && kb == ShapeKind.box) {
            hit = satBoxBox(position[a], orientation[a], shape[a].box.halfExtents,
                            position[b], orientation[b], shape[b].box.halfExtents, m);
        } else if (ka == ShapeKind.box && kb == ShapeKind.capsule) {
            hit = satBoxCapsule(position[a], orientation[a], shape[a].box.halfExtents,
                                position[b], orientation[b],
                                shape[b].capsule.radius, shape[b].capsule.halfHeight, m);
        } else if (ka == ShapeKind.capsule && kb == ShapeKind.box) {
            hit = satBoxCapsule(position[b], orientation[b], shape[b].box.halfExtents,
                                position[a], orientation[a],
                                shape[a].capsule.radius, shape[a].capsule.halfHeight, m);
            if (hit) {
                // Flip normal convention so it points from A to B.
                foreach (pi; 0 .. m.count) m.points[pi].normal = -m.points[pi].normal;
                immutable tmpA = a, tmpB = b;
                m.a = tmpA; m.b = tmpB;
                return true;
            }
        } else {
            hit = satCapsuleCapsule(position[a], orientation[a],
                                    shape[a].capsule.radius, shape[a].capsule.halfHeight,
                                    position[b], orientation[b],
                                    shape[b].capsule.radius, shape[b].capsule.halfHeight, m);
        }
        if (hit) { m.a = a; m.b = b; }
        return hit;
    }
}

// -----------------------------------------------------------------------------
// Helpers (free functions)
// -----------------------------------------------------------------------------

// 
Mat3 computeInvInertia(Shape sh, float mass) @safe {
    if (mass <= 0) return Mat3.zero();
    if (sh.kind == ShapeKind.box) {
        immutable h = sh.box.halfExtents;
        immutable w2 = (2 * h.x) * (2 * h.x);
        immutable ht2 = (2 * h.y) * (2 * h.y);
        immutable d2 = (2 * h.z) * (2 * h.z);
        immutable factor = 1.0f / 12.0f * mass;
        immutable ix = factor * (ht2 + d2);
        immutable iy = factor * (w2  + d2);
        immutable iz = factor * (w2  + ht2);
        return Mat3.diagonal(1.0f / ix, 1.0f / iy, 1.0f / iz);
    } else {
        // Approximate capsule as cylinder for inertia.
        immutable r  = sh.capsule.radius;
        immutable hh = sh.capsule.halfHeight;
        immutable h  = 2 * hh + 2 * r;
        immutable ix = (1.0f / 12.0f) * mass * (3 * r * r + h * h);
        immutable iy = 0.5f * mass * r * r;
        immutable iz = ix;
        return Mat3.diagonal(1.0f / ix, 1.0f / iy, 1.0f / iz);
    }
}

// 
Mat3 rotateInertia(Mat3 localInv, Quat q) @safe {
    immutable m4 = q.toMat4();
    // Extract 3x3 rotation from 4x4 column-major.
    Mat3 R;
    R.m[0] = m4.m[0]; R.m[1] = m4.m[1]; R.m[2] = m4.m[2];
    R.m[3] = m4.m[4]; R.m[4] = m4.m[5]; R.m[5] = m4.m[6];
    R.m[6] = m4.m[8]; R.m[7] = m4.m[9]; R.m[8] = m4.m[10];
    return R * (localInv * R.transposed());
}

// 
Aabb computeAabb(Vec3 center, Quat q, Shape sh) @safe {
    import std.math : abs;
    if (sh.kind == ShapeKind.box) {
        immutable h = sh.box.halfExtents;
        // Rotated axes.
        immutable ax = q.rotate(Vec3(h.x, 0, 0));
        immutable ay = q.rotate(Vec3(0, h.y, 0));
        immutable az = q.rotate(Vec3(0, 0, h.z));
        immutable ex = abs(ax.x) + abs(ay.x) + abs(az.x);
        immutable ey = abs(ax.y) + abs(ay.y) + abs(az.y);
        immutable ez = abs(ax.z) + abs(ay.z) + abs(az.z);
        return Aabb(Vec3(center.x - ex, center.y - ey, center.z - ez),
                    Vec3(center.x + ex, center.y + ey, center.z + ez));
    } else {
        immutable r  = sh.capsule.radius;
        immutable hh = sh.capsule.halfHeight;
        immutable axY = q.rotate(Vec3(0, hh, 0));
        immutable ex = abs(axY.x) + r;
        immutable ey = abs(axY.y) + r;
        immutable ez = abs(axY.z) + r;
        return Aabb(Vec3(center.x - ex, center.y - ey, center.z - ez),
                    Vec3(center.x + ex, center.y + ey, center.z + ez));
    }
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

unittest {
    // Free fall: 1s under gravity → y ≈ -4.905, v ≈ -9.81.
    auto world = new PhysicsWorld!64();
    auto id = world.addDynamic(Vec3(0, 10, 0),
                               Shape.makeBox(Vec3(0.5f, 0.5f, 0.5f)), 1.0f);
    assert(id != INVALID_BODY);

    immutable dt = 1.0f / 60.0f;
    foreach (_; 0 .. 60) world.step(dt);

    immutable y = world.position[id].y;
    immutable vy = world.velocity[id].y;
    assert(y < 10.0f - 4.7f && y > 10.0f - 5.2f);
    assert(vy < -9.5f && vy > -10.2f);
}

unittest {
    // Cube dropped on static ground should come to rest above y ≈ 0.5.
    auto world = new PhysicsWorld!64();
    world.addStatic(Vec3(0, -0.5f, 0), Shape.makeBox(Vec3(10, 0.5f, 10)));
    auto id = world.addDynamic(Vec3(0, 5, 0),
                               Shape.makeBox(Vec3(0.5f, 0.5f, 0.5f)), 1.0f);

    immutable dt = 1.0f / 120.0f;
    foreach (_; 0 .. 600) world.step(dt);

    immutable y = world.position[id].y;
    // Resting height: ground top at 0 + cube half-extent 0.5, small slop.
    assert(y > 0.4f && y < 0.7f);
}
