// PhysicsWorld — orchestrates the Bullet-inspired pipeline.
//
// Frame sequence (matches Bullet btDiscreteDynamicsWorld::internalSingleStepSimulation):
//
//   1. predictUnconstraintMotion — apply damping + gravity/force → v, ω
//   2. update Dbvt leaves for moved bodies (fast path: contains check)
//   3. findPairs via Dbvt.findPairs (and dynamic-vs-plane fast-path, since
//      planes are NOT in the Dbvt)
//   4. refresh persistent manifolds + run narrowphase, merge into pool
//   5. compute islands (union-find on contact graph)
//   6. setup + warm-start per manifold, run numIterations solver sweeps
//   7. integrateTransforms: x += (v + pseudo) · dt, q.integrate(ω, dt)
//   8. sleeping: deactivate islands whose energy < thresholds for > 2 s
//   9. ageAndEvict manifolds
module engine.physics.world;

import core.stdc.math : sqrtf;
import engine.math.vec;
import engine.math.quat;
import engine.physics.types;
import engine.physics.dbvt;
import engine.physics.narrowphase;
import engine.physics.manifold_pool;
import engine.physics.islands;
import engine.physics.inertia;
import engine.physics.integrator;
import engine.physics.solver;

@safe:

/// Sleeping thresholds — Bullet btRigidBody defaults.
enum float LINEAR_SLEEP_THRESHOLD  = 0.8f;
enum float ANGULAR_SLEEP_THRESHOLD = 1.0f;
enum float TIME_TO_SLEEP           = 2.0f;

struct PhysicsWorld(uint MaxBodies = 4096, uint MaxManifolds = 8192) {
@safe:
    // SoA body storage.
    Vec3[MaxBodies]  position;
    Quat[MaxBodies]  orientation;
    Vec3[MaxBodies]  linearVel;
    Vec3[MaxBodies]  angularVel;
    Vec3[MaxBodies]  force;
    float[MaxBodies] invMass        = 0;
    Vec3[MaxBodies]  invInertiaDiag;      // body-local
    Shape[MaxBodies] shape;
    Material[MaxBodies] material;
    int[MaxBodies]   dbvtLeaf       = -1;
    float[MaxBodies] sleepTimer     = 0;
    bool[MaxBodies]  sleeping       = false;
    // Plane bodies — special-cased (never inserted into Dbvt).
    bool[MaxBodies]  isPlane        = false;

    uint bodyCount = 0;

    Vec3            gravity         = Vec3(0, -9.81f, 0);
    SolverConfig    solverCfg;
    Dbvt!(MaxBodies * 2)  dbvt;
    ManifoldPool!(MaxManifolds) pool;
    IslandSolver!(MaxBodies)    islands;

    PhysicsStats stats;

    // ------------- lifecycle --------------------------------------------

    void init_()  {
        dbvt.clear();
        pool.init_();
    }

    /// Compatibility no-op (legacy API) — Dbvt has no fixed window.
    void recenterGrid(Vec3)  { /* nothing */ }

    // ------------- body creation ----------------------------------------

    RigidBodyId addStatic(Vec3 pos, Shape s)  {
        return addStatic(pos, Quat.identity, s);
    }
    RigidBodyId addStatic(Vec3 pos, Quat rot, Shape s)  {
        assert(bodyCount < MaxBodies, "PhysicsWorld capacity exhausted");
        immutable id = bodyCount++;
        position[id]    = pos;
        orientation[id] = rot;
        linearVel[id]   = Vec3(0, 0, 0);
        angularVel[id]  = Vec3(0, 0, 0);
        force[id]       = Vec3(0, 0, 0);
        invMass[id]     = 0;
        invInertiaDiag[id] = Vec3(0, 0, 0);
        shape[id]       = s;
        material[id]    = Material.init;
        sleeping[id]    = true;   // static always asleep
        sleepTimer[id]  = TIME_TO_SLEEP;

        if (s.kind == ShapeKind.staticPlane) {
            isPlane[id]  = true;
            dbvtLeaf[id] = -1;
        } else {
            isPlane[id]  = false;
            immutable a = computeAabb(id);
            dbvtLeaf[id] = dbvt.insertLeaf(id, a);
        }
        return id;
    }

    RigidBodyId addDynamic(Vec3 pos, Shape s, float mass)  {
        return addDynamic(pos, Quat.identity, s, mass);
    }
    RigidBodyId addDynamic(Vec3 pos, Quat rot, Shape s, float mass)  {
        assert(bodyCount < MaxBodies, "PhysicsWorld capacity exhausted");
        assert(mass > 0);
        immutable id = bodyCount++;
        position[id]    = pos;
        orientation[id] = rot;
        linearVel[id]   = Vec3(0, 0, 0);
        angularVel[id]  = Vec3(0, 0, 0);
        force[id]       = Vec3(0, 0, 0);
        invMass[id]     = 1.0f / mass;
        invInertiaDiag[id] = bodyInverseInertiaDiagonal(s, mass);
        shape[id]       = s;
        material[id]    = Material.init;
        sleeping[id]    = false;
        sleepTimer[id]  = 0;
        isPlane[id]     = false;

        immutable a = computeAabb(id);
        dbvtLeaf[id] = dbvt.insertLeaf(id, a);
        return id;
    }

    // ------------- shape AABB -------------------------------------------

    Aabb computeAabb(RigidBodyId id) const  {
        immutable p = position[id];
        immutable q = orientation[id];
        final switch (shape[id].kind) {
            case ShapeKind.sphere: {
                immutable r = shape[id].sphere.radius;
                return Aabb(p - Vec3(r, r, r), p + Vec3(r, r, r));
            }
            case ShapeKind.box: {
                immutable h = shape[id].box.halfExtents;
                // World-space extent = |R| · h where |R| is elementwise abs.
                immutable ax = absVec(q.rotate(Vec3(h.x, 0, 0)));
                immutable ay = absVec(q.rotate(Vec3(0, h.y, 0)));
                immutable az = absVec(q.rotate(Vec3(0, 0, h.z)));
                immutable ext = ax + ay + az;
                return Aabb(p - ext, p + ext);
            }
            case ShapeKind.capsule: {
                immutable r  = shape[id].capsule.radius;
                immutable hh = shape[id].capsule.halfHeight;
                immutable axisY = q.rotate(Vec3(0, hh, 0));
                immutable a = p - absVec(axisY) - Vec3(r, r, r);
                immutable b = p + absVec(axisY) + Vec3(r, r, r);
                return Aabb(a, b);
            }
            case ShapeKind.cylinder: {
                immutable h = shape[id].cylinder.halfExtents;
                immutable ax = absVec(q.rotate(Vec3(h.x, 0, 0)));
                immutable ay = absVec(q.rotate(Vec3(0, h.y, 0)));
                immutable az = absVec(q.rotate(Vec3(0, 0, h.z)));
                immutable ext = ax + ay + az;
                return Aabb(p - ext, p + ext);
            }
            case ShapeKind.staticPlane: {
                return Aabb(Vec3(-1e9, -1e9, -1e9), Vec3(1e9, 1e9, 1e9));
            }
            case ShapeKind.convexHull:
                return Aabb(p - Vec3(1, 1, 1), p + Vec3(1, 1, 1)); // placeholder
        }
    }

    // ------------- frame step -------------------------------------------

    void step(float dt)  {
        if (dt <= 0) return;

        // 1. Predict velocities (damping + gravity/force).
        foreach (i; 0 .. bodyCount) {
            if (invMass[i] == 0 || sleeping[i]) continue;
            linearVel[i]  = applyLinearDamping(linearVel[i], material[i].linearDamping, dt);
            angularVel[i] = applyAngularDamping(angularVel[i], material[i].angularDamping, dt);
            linearVel[i]  = integrateLinearVelocity(linearVel[i], force[i], invMass[i], gravity, dt);
            force[i]      = Vec3(0, 0, 0);
        }

        // 2. Update Dbvt for moved bodies. Sleeping bodies do not move,
        //    so skipping them avoids churning the tree every frame.
        foreach (i; 0 .. bodyCount) {
            if (invMass[i] == 0 || isPlane[i] || sleeping[i]) continue;
            if (dbvtLeaf[i] < 0) continue;
            immutable a = computeAabb(i);
            immutable v = linearVel[i] * dt;
            immutable newIdx = dbvt.updateLeafReassign(dbvtLeaf[i], a, v);
            dbvtLeaf[i] = newIdx;
            // Note: after reassign, other bodies' leaf indices are unchanged
            // because Dbvt internal reuse via free list may rewrite a slot,
            // but the leaf's own stored leafBodyId points to THIS body. If
            // another body's stored leaf index happens to equal `newIdx`
            // that would be a bug — but allocNode reuses freed slots only,
            // and we always update-then-return the fresh index.
        }

        // 3. Broadphase pairs (Dbvt) + plane fast-path.
        stats = PhysicsStats.init;
        stats.bodyCount = bodyCount;
        stats.dbvtNodes = dbvt.nodeCount;
        uint pairs = 0;
        dbvt.findPairs((uint a, uint b)  {
            pairs++;
            processPair(a, b);
        });
        // Plane fast-path: every non-plane body against every plane.
        foreach (plId; 0 .. bodyCount) {
            if (!isPlane[plId]) continue;
            foreach (bId; 0 .. bodyCount) {
                if (bId == plId || isPlane[bId]) continue;
                pairs++;
                immutable a = bId < plId ? cast(uint) bId : cast(uint) plId;
                immutable b = bId < plId ? cast(uint) plId : cast(uint) bId;
                processPair(a, b);
            }
        }
        stats.broadphasePairs = pairs;

        // 4. Islands (union-find over active manifolds).
        //    Also: wake any sleeping body that shares a manifold with an
        //    awake dynamic body (collision wake-up). Sleeping ↔ sleeping
        //    and sleeping ↔ static contacts do NOT wake.
        islands.init_(bodyCount);
        uint manifoldCount = 0;
        foreach (ref m; pool.manifolds) {
            if (m.count == 0 || m.framesSinceUse >= 255) continue;
            manifoldCount++;
            immutable dynA = invMass[m.a] > 0;
            immutable dynB = invMass[m.b] > 0;
            if (dynA && dynB) {
                islands.union_(cast(int) m.a, cast(int) m.b);
                // Collision wake-up: if exactly one side is awake, wake the other.
                if (sleeping[m.a] && !sleeping[m.b]) { sleeping[m.a] = false; sleepTimer[m.a] = 0; }
                else if (sleeping[m.b] && !sleeping[m.a]) { sleeping[m.b] = false; sleepTimer[m.b] = 0; }
            }
        }
        stats.manifoldCount = manifoldCount;

        // 5. Solver — build SolverBody view, setup + warm-start, iterate.
        //    Sleeping dynamic bodies are exposed as invMass=0 so the solver
        //    cannot perturb their velocities. This is what actually lets
        //    them stay at rest — otherwise residual constraint impulses
        //    would push ke above the sleep threshold every frame.
        SolverBody[MaxBodies] sb;
        foreach (i; 0 .. bodyCount) {
            if (sleeping[i]) {
                sb[i].linearVel      = Vec3(0, 0, 0);
                sb[i].angularVel     = Vec3(0, 0, 0);
                sb[i].invMass        = 0;
                sb[i].invInertiaDiag = Vec3(0, 0, 0);
            } else {
                sb[i].linearVel      = linearVel[i];
                sb[i].angularVel     = angularVel[i];
                sb[i].invMass        = invMass[i];
                sb[i].invInertiaDiag = invInertiaDiag[i];
            }
            sb[i].pseudoLinVel   = Vec3(0, 0, 0);
            sb[i].pseudoAngVel   = Vec3(0, 0, 0);
            sb[i].orientation    = orientation[i];
        }
        foreach (ref m; pool.manifolds) {
            if (m.count == 0 || m.framesSinceUse >= 255) continue;
            immutable rest = material[m.a].restitution > material[m.b].restitution
                ? material[m.a].restitution : material[m.b].restitution;
            setupAndWarmStart(solverCfg, m, sb[0 .. bodyCount], rest);
        }
        foreach (iter; 0 .. solverCfg.numIterations) {
            foreach (ref m; pool.manifolds) {
                if (m.count == 0 || m.framesSinceUse >= 255) continue;
                immutable fA = material[m.a].friction;
                immutable fB = material[m.b].friction;
                immutable fr = sqrtf(fA * fB);
                iterate(solverCfg, m, sb[0 .. bodyCount], fr, dt);
            }
        }

        // 6. Writeback + integrate transforms. Sleeping bodies keep their
        //    stored (zero) velocity and are not integrated.
        foreach (i; 0 .. bodyCount) {
            if (invMass[i] == 0 || sleeping[i]) continue;
            linearVel[i]  = sb[i].linearVel;
            angularVel[i] = sb[i].angularVel;
            position[i]    = position[i] + (linearVel[i] + sb[i].pseudoLinVel) * dt;
            orientation[i] = orientation[i].integrate(angularVel[i] + sb[i].pseudoAngVel, dt);
        }

        // 7. Sleeping / deactivation.
        foreach (i; 0 .. bodyCount) {
            if (invMass[i] == 0 || sleeping[i]) continue;
            immutable ke = linearVel[i].lengthSquared
                         + angularVel[i].lengthSquared;
            if (ke < LINEAR_SLEEP_THRESHOLD * LINEAR_SLEEP_THRESHOLD
                  + ANGULAR_SLEEP_THRESHOLD * ANGULAR_SLEEP_THRESHOLD) {
                sleepTimer[i] += dt;
                if (sleepTimer[i] > TIME_TO_SLEEP) {
                    sleeping[i]    = true;
                    linearVel[i]   = Vec3(0, 0, 0);   // zero residual drift
                    angularVel[i]  = Vec3(0, 0, 0);
                }
            } else {
                sleepTimer[i] = 0;
            }
        }
        uint active = 0, asleep = 0;
        foreach (i; 0 .. bodyCount) {
            if (invMass[i] == 0) continue;
            if (sleeping[i]) asleep++; else active++;
        }
        stats.activeBodies   = active;
        stats.sleepingBodies = asleep;

        // 8. Manifold aging.
        pool.ageAndEvict(4);
    }

    // ------------- narrowphase dispatch ---------------------------------

    private void processPair(uint a, uint b) @trusted  {
        if (isPlane[a] && isPlane[b]) return;         // plane-plane = skip
        if (invMass[a] == 0 && invMass[b] == 0 && !isPlane[a] && !isPlane[b]) return; // two statics
        // Both dynamic bodies asleep → no impulses possible, skip narrowphase.
        // Wake-up from collision only happens when an awake body touches
        // the sleeping one, which is handled here because at least one side
        // will then have sleeping==false.
        if (invMass[a] > 0 && invMass[b] > 0 && sleeping[a] && sleeping[b]) return;
        // Normalize so plane (if any) is B.
        if (isPlane[a]) { immutable t = a; a = b; b = t; }
        // Sleeping pairs: allow if at least one body can wake.

        NarrowResult nr;
        bool hit = false;
        final switch (shape[a].kind) {
            case ShapeKind.sphere:
                final switch (shape[b].kind) {
                    case ShapeKind.sphere:
                        hit = sphereSphere(position[a], shape[a].sphere.radius,
                                            position[b], shape[b].sphere.radius, nr);
                        break;
                    case ShapeKind.box:
                        hit = sphereBox(position[a], shape[a].sphere.radius,
                                         position[b], orientation[b], shape[b].box.halfExtents, nr);
                        break;
                    case ShapeKind.staticPlane:
                        hit = spherePlane(position[a], shape[a].sphere.radius,
                                           shape[b].plane.normal, shape[b].plane.d, nr);
                        break;
                    case ShapeKind.capsule:
                    case ShapeKind.cylinder:
                    case ShapeKind.convexHull:
                        // Fallback: treat other as its bounding box.
                        immutable heB = approxBoxHalfExtents(b);
                        hit = sphereBox(position[a], shape[a].sphere.radius,
                                         position[b], orientation[b], heB, nr);
                        break;
                }
                break;
            case ShapeKind.box:
            case ShapeKind.capsule:
            case ShapeKind.cylinder:
            case ShapeKind.convexHull: {
                immutable heA = (shape[a].kind == ShapeKind.box)
                    ? shape[a].box.halfExtents
                    : approxBoxHalfExtents(a);
                final switch (shape[b].kind) {
                    case ShapeKind.sphere: {
                        hit = sphereBox(position[b], shape[b].sphere.radius,
                                         position[a], orientation[a], heA, nr);
                        // Flip A↔B: sphereBox returned normal from sphere→box (b→a); we want a→b.
                        if (hit) flipNormal(nr);
                        break;
                    }
                    case ShapeKind.box:
                    case ShapeKind.capsule:
                    case ShapeKind.cylinder:
                    case ShapeKind.convexHull: {
                        immutable heB = (shape[b].kind == ShapeKind.box)
                            ? shape[b].box.halfExtents
                            : approxBoxHalfExtents(b);
                        hit = boxBox(position[a], orientation[a], heA,
                                      position[b], orientation[b], heB, nr);
                        break;
                    }
                    case ShapeKind.staticPlane: {
                        hit = boxPlane(position[a], orientation[a], heA,
                                        shape[b].plane.normal, shape[b].plane.d, nr);
                        break;
                    }
                }
                break;
            }
            case ShapeKind.staticPlane:
                return;  // plane never acts as A after normalization
        }
        if (!hit || nr.count == 0) return;

        // Refresh existing manifold first (drop stale points).
        auto m = pool.getOrCreate(a, b);
        if (m is null) return;  // pool saturated — drop this pair this frame
        if (m.count > 0) ManifoldPool!(MaxManifolds).refresh(*m, position[a], orientation[a],
                                                              position[b], orientation[b]);
        mergeContacts(*m, nr.points[0 .. nr.count]);

        // Wake bodies on contact.
        if (invMass[a] > 0 && sleeping[a]) { sleeping[a] = false; sleepTimer[a] = 0; }
        if (invMass[b] > 0 && sleeping[b]) { sleeping[b] = false; sleepTimer[b] = 0; }
    }

    private Vec3 approxBoxHalfExtents(uint id) const  {
        final switch (shape[id].kind) {
            case ShapeKind.sphere: {
                immutable r = shape[id].sphere.radius;
                return Vec3(r, r, r);
            }
            case ShapeKind.box:      return shape[id].box.halfExtents;
            case ShapeKind.capsule: {
                immutable r  = shape[id].capsule.radius;
                immutable hh = shape[id].capsule.halfHeight;
                return Vec3(r, hh + r, r);
            }
            case ShapeKind.cylinder: return shape[id].cylinder.halfExtents;
            case ShapeKind.staticPlane: return Vec3(0, 0, 0);
            case ShapeKind.convexHull:  return Vec3(1, 1, 1);
        }
    }

    private static void flipNormal(ref NarrowResult nr)  {
        foreach (i; 0 .. nr.count) {
            nr.points[i].normal = -nr.points[i].normal;
            immutable tw = nr.points[i].worldPosA;
            nr.points[i].worldPosA = nr.points[i].worldPosB;
            nr.points[i].worldPosB = tw;
            immutable tl = nr.points[i].localA;
            nr.points[i].localA = nr.points[i].localB;
            nr.points[i].localB = tl;
        }
    }
}

private Vec3 absVec(Vec3 v) @safe pure  {
    import std.math : fabs;
    return Vec3(fabs(v.x), fabs(v.y), fabs(v.z));
}

// ===========================================================================
// Unit tests — validate the Bullet-inspired pipeline end-to-end.
//
// These are the authoritative regression tests for the physics rewrite. They
// run under `dub test` (library config, which includes this module).
// ===========================================================================

version (unittest) {
    import std.math : abs, sqrt;
    import std.stdio : writeln, writefln;

    // Alias a conservative capacity for tests — big enough for stacks but
    // small enough to keep stack frames reasonable.
    private alias TestWorld = PhysicsWorld!(256, 1024);

    // Run a fixed-step simulation for `frames` iterations at 60 Hz.
    private void stepFor(TestWorld* w, uint frames) @safe {
        enum float dt = 1.0f / 60.0f;
        foreach (_; 0 .. frames) w.step(dt);
    }
}

/// Single box free-falls onto a static ground box and comes to rest on top
/// of it within 3 seconds. Catches: solver sign, manifold reuse, integrator.
@safe unittest {
    auto w = new TestWorld;
    w.init_();
    w.gravity = Vec3(0, -20, 0);

    w.addStatic(Vec3(0, -0.5f, 0), Shape.makeBox(Vec3(10, 0.5f, 10)));
    immutable cube = w.addDynamic(Vec3(0, 5, 0), Shape.makeBox(Vec3(0.5f, 0.5f, 0.5f)), 1.0f);

    stepFor(w, 180);

    immutable y = w.position[cube].y;
    assert(y > 0.3f && y < 0.8f, "cube did not rest on ground: y=" ~ y.stringof);
    assert(abs(w.linearVel[cube].y) < 0.5f, "cube still moving vertically");
    assert(w.stats.manifoldCount >= 1, "manifold lost while cube is on ground");
}

/// A single box on a static-plane body also rests. Exercises the plane
/// fast-path (planes are NOT in the Dbvt).
@safe unittest {
    auto w = new TestWorld;
    w.init_();
    w.gravity = Vec3(0, -20, 0);

    // Plane with normal +Y at y=0: n·x + d = 0 ⇒ d = 0.
    w.addStatic(Vec3(0, 0, 0), Shape.makePlane(Vec3(0, 1, 0), 0));
    immutable cube = w.addDynamic(Vec3(0, 5, 0), Shape.makeBox(Vec3(0.5f, 0.5f, 0.5f)), 1.0f);

    stepFor(w, 180);

    immutable y = w.position[cube].y;
    assert(y > 0.3f && y < 0.8f, "cube did not rest on plane");
    assert(abs(w.linearVel[cube].y) < 0.5f);
}

/// Stack of three cubes on a ground box. Verifies that persistent manifolds
/// warm-start correctly (a stack needs converged impulses to avoid jitter).
@safe unittest {
    auto w = new TestWorld;
    w.init_();
    w.gravity = Vec3(0, -20, 0);

    w.addStatic(Vec3(0, -0.5f, 0), Shape.makeBox(Vec3(10, 0.5f, 10)));
    immutable c0 = w.addDynamic(Vec3(0, 0.55f, 0), Shape.makeBox(Vec3(0.5f, 0.5f, 0.5f)), 1.0f);
    immutable c1 = w.addDynamic(Vec3(0, 1.60f, 0), Shape.makeBox(Vec3(0.5f, 0.5f, 0.5f)), 1.0f);
    immutable c2 = w.addDynamic(Vec3(0, 2.65f, 0), Shape.makeBox(Vec3(0.5f, 0.5f, 0.5f)), 1.0f);

    stepFor(w, 300);  // 5 seconds

    // Each cube should stay roughly at its target y (1-box tall step = 1 m).
    // Allow 15 cm tolerance for penetration depth under 10-iter SI solver.
    assert(w.position[c0].y > 0.35f && w.position[c0].y < 0.70f,
        "stack cube 0 out of range");
    assert(w.position[c1].y > 1.35f && w.position[c1].y < 1.70f,
        "stack cube 1 out of range");
    assert(w.position[c2].y > 2.35f && w.position[c2].y < 2.70f,
        "stack cube 2 out of range");

    // And they should all be essentially at rest.
    foreach (id; [c0, c1, c2]) {
        assert(w.linearVel[id].lengthSquared < 4.0f,
            "stacked cube still moving");
    }
}

/// Box dropped off-centre onto the ground tumbles but does not tunnel through.
/// Guards against manifold drop-outs mid-collision and angular impulse bugs.
@safe unittest {
    auto w = new TestWorld;
    w.init_();
    w.gravity = Vec3(0, -20, 0);

    w.addStatic(Vec3(0, -0.5f, 0), Shape.makeBox(Vec3(10, 0.5f, 10)));
    // Small cube, tilted 0.3 rad around Z, dropped with some horizontal vel.
    immutable q = Quat.fromAxisAngle(Vec3(0, 0, 1), 0.3f);
    immutable cube = w.addDynamic(Vec3(0, 4, 0), q,
        Shape.makeBox(Vec3(0.5f, 0.5f, 0.5f)), 1.0f);
    w.linearVel[cube] = Vec3(1.0f, 0, 0);

    stepFor(w, 300);

    immutable y = w.position[cube].y;
    // Must not be below ground (y < 0) and not launched upward.
    assert(y > 0.0f,  "tilted cube tunneled through ground");
    assert(y < 2.0f,  "tilted cube launched upward");
}

/// Many dynamic cubes raining into a ground box — the benchmark scenario
/// compressed. Verifies: (a) the manifold pool doesn't overflow even with
/// lots of pairs; (b) nothing explodes to infinity; (c) bodies do not end up
/// below the ground plane.
@safe unittest {
    auto w = new TestWorld;
    w.init_();
    w.gravity = Vec3(0, -20, 0);

    w.addStatic(Vec3(0, -0.5f, 0), Shape.makeBox(Vec3(20, 0.5f, 20)));

    enum uint N = 64;
    uint[N] ids;
    foreach (i; 0 .. N) {
        // Scatter in a 8x8 grid at varying heights.
        immutable xi = cast(float)(i % 8) - 3.5f;
        immutable zi = cast(float)(i / 8) - 3.5f;
        immutable yi = 2.0f + (i % 4) * 1.2f;
        ids[i] = w.addDynamic(Vec3(xi * 1.3f, yi, zi * 1.3f),
            Shape.makeBox(Vec3(0.5f, 0.5f, 0.5f)), 1.0f);
    }

    // 10 seconds of simulation — should complete without assertion failures
    // (manifold pool exhaustion) or NaNs.
    stepFor(w, 600);

    foreach (i; 0 .. N) {
        immutable p = w.position[ids[i]];
        assert(p.y > -1.0f, "cube fell through ground");
        assert(p.y <  50.0f, "cube launched to the sky");
        assert(p.x > -50.0f && p.x < 50.0f, "cube flew sideways");
        assert(p.z > -50.0f && p.z < 50.0f, "cube flew sideways");
        // No NaN propagation.
        assert(p.x == p.x && p.y == p.y && p.z == p.z, "NaN position");
    }
}

/// Sphere-on-plane with restitution produces bounces, but energy monotonically
/// decreases (restitution < 1). Guards restitution sign.
@safe unittest {
    auto w = new TestWorld;
    w.init_();
    w.gravity = Vec3(0, -10, 0);

    auto plane = w.addStatic(Vec3(0, 0, 0), Shape.makePlane(Vec3(0, 1, 0), 0));
    w.material[plane].restitution = 0.5f;

    immutable ball = w.addDynamic(Vec3(0, 5, 0), Shape.makeSphere(0.5f), 1.0f);
    w.material[ball].restitution = 0.5f;

    float maxY = w.position[ball].y;
    float prevPeak = maxY;
    int peaks = 0;
    float lastVy = 0;
    enum float dt = 1.0f / 60.0f;

    foreach (_; 0 .. 600) {  // 10 s
        immutable vy = w.linearVel[ball].y;
        // Detect a peak (vy crosses from + to -).
        if (lastVy > 0 && vy <= 0 && w.position[ball].y > 0.6f) {
            peaks++;
            immutable peakY = w.position[ball].y;
            assert(peakY <= prevPeak + 0.01f,
                "bounce height increased — energy gain");
            prevPeak = peakY;
        }
        lastVy = vy;
        w.step(dt);
    }

    assert(peaks >= 1, "sphere never bounced");
    assert(w.position[ball].y > 0.4f, "sphere fell through plane");
}

/// ManifoldPool: the same (a,b) returns the same manifold across frames
/// (hash-key stability, not the truncation bug we had).
@safe unittest {
    auto w = new TestWorld;
    w.init_();
    w.gravity = Vec3(0, -20, 0);

    w.addStatic(Vec3(0, -0.5f, 0), Shape.makeBox(Vec3(10, 0.5f, 10)));
    w.addDynamic(Vec3(0, 2, 0), Shape.makeBox(Vec3(0.5f, 0.5f, 0.5f)), 1.0f);

    // Drop long enough to establish contact and hold it.
    stepFor(w, 120);

    // After settling we should have EXACTLY one live manifold for 90+ frames
    // (proves warm-start & hash lookup are working; otherwise each frame
    // would allocate a fresh slot).
    assert(w.stats.manifoldCount == 1,
        "expected 1 manifold, got " ~ w.stats.manifoldCount.stringof);
    assert(w.pool.count <= 4,
        "ManifoldPool leaked slots: count=" ~ w.pool.count.stringof);
}

