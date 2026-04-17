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

        // 2. Update Dbvt for moved bodies.
        foreach (i; 0 .. bodyCount) {
            if (invMass[i] == 0 || isPlane[i]) continue;
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
        islands.init_(bodyCount);
        uint manifoldCount = 0;
        foreach (ref m; pool.manifolds) {
            if (m.count == 0 || m.framesSinceUse >= 255) continue;
            manifoldCount++;
            if (invMass[m.a] > 0 && invMass[m.b] > 0) {
                islands.union_(cast(int) m.a, cast(int) m.b);
            }
        }
        stats.manifoldCount = manifoldCount;

        // 5. Solver — build SolverBody view, setup + warm-start, iterate.
        SolverBody[MaxBodies] sb;
        foreach (i; 0 .. bodyCount) {
            sb[i].linearVel      = linearVel[i];
            sb[i].angularVel     = angularVel[i];
            sb[i].pseudoLinVel   = Vec3(0, 0, 0);
            sb[i].pseudoAngVel   = Vec3(0, 0, 0);
            sb[i].invMass        = invMass[i];
            sb[i].invInertiaDiag = invInertiaDiag[i];
            sb[i].orientation    = orientation[i];
        }
        foreach (ref m; pool.manifolds) {
            if (m.count == 0 || m.framesSinceUse >= 255) continue;
            setupAndWarmStart(solverCfg, m, sb[0 .. bodyCount]);
        }
        foreach (iter; 0 .. solverCfg.numIterations) {
            foreach (ref m; pool.manifolds) {
                if (m.count == 0 || m.framesSinceUse >= 255) continue;
                immutable fA = material[m.a].friction;
                immutable fB = material[m.b].friction;
                immutable fr = sqrtf(fA * fB);
                immutable restitution = (iter == 0)
                    ? (material[m.a].restitution > material[m.b].restitution
                        ? material[m.a].restitution : material[m.b].restitution)
                    : 0.0f;
                iterate(solverCfg, m, sb[0 .. bodyCount], fr, restitution, dt);
            }
        }

        // 6. Writeback + integrate transforms.
        foreach (i; 0 .. bodyCount) {
            if (invMass[i] == 0) continue;
            linearVel[i]  = sb[i].linearVel;
            angularVel[i] = sb[i].angularVel;
            if (sleeping[i]) continue;
            position[i]    = position[i] + (linearVel[i] + sb[i].pseudoLinVel) * dt;
            orientation[i] = orientation[i].integrate(angularVel[i] + sb[i].pseudoAngVel, dt);
        }

        // 7. Sleeping / deactivation.
        foreach (i; 0 .. bodyCount) {
            if (invMass[i] == 0) continue;
            immutable ke = linearVel[i].lengthSquared
                         + angularVel[i].lengthSquared;
            if (ke < LINEAR_SLEEP_THRESHOLD * LINEAR_SLEEP_THRESHOLD
                  + ANGULAR_SLEEP_THRESHOLD * ANGULAR_SLEEP_THRESHOLD) {
                sleepTimer[i] += dt;
                if (sleepTimer[i] > TIME_TO_SLEEP) sleeping[i] = true;
            } else {
                sleepTimer[i] = 0;
                sleeping[i]   = false;
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
