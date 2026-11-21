/// RAII `@safe nothrow @nogc` wrappers for Detour NavMesh, TileCache, NavMeshQuery, and Crowd.
module engine.nav.mesh;

import engine.math.vec : Vec3;
import engine.nav.types;
import recast = bindings.recast;

@safe:

/// Tiled Detour navigation mesh (move-only RAII).
struct NavMesh {
    package recast.NavMeshHandle* handle = null;

    @disable this(this);

    ~this() nothrow @nogc {
        destroy();
    }

    static NavMesh createTiled(Vec3 origin, float tileWidth, float tileHeight,
                               int maxTiles = 1024, int maxPolysPerTile = 4096) @trusted nothrow @nogc {
        NavMesh m;
        m.handle = recast.navCreateTiledMesh(origin.x, origin.y, origin.z,
                                             tileWidth, tileHeight, maxTiles, maxPolysPerTile);
        return m;
    }

    bool isValid() const nothrow @nogc {
        return handle !is null;
    }

    void destroy() @trusted nothrow @nogc {
        if (handle !is null) {
            recast.navDestroyMesh(handle);
            handle = null;
        }
    }
}

/// Dynamic obstacle cache for `NavMesh` (cylinder, AABB, and OBB obstacles).
struct NavTileCache {
    package recast.NavTileCacheHandle* handle = null;

    @disable this(this);

    ~this() nothrow @nogc {
        destroy();
    }

    static NavTileCache create(ref NavMesh mesh, Vec3 origin, float tileWidth, float tileHeight,
                               const ref NavBakeConfig cfg) @trusted nothrow @nogc {
        NavTileCache tc;
        if (!mesh.isValid()) return tc;
        auto cCfg = cfg.toC();
        tc.handle = recast.navCreateTileCache(mesh.handle, origin.x, origin.y, origin.z,
                                              tileWidth, tileHeight, &cCfg);
        return tc;
    }

    bool isValid() const nothrow @nogc {
        return handle !is null;
    }

    void destroy() @trusted nothrow @nogc {
        if (handle !is null) {
            recast.navDestroyTileCache(handle);
            handle = null;
        }
    }

    bool addCylinderObstacle(Vec3 bottomCenter, float radius, float height,
                             out NavObstacleRef outRef) @trusted nothrow @nogc {
        if (handle is null) return false;
        float[3] pos = [bottomCenter.x, bottomCenter.y, bottomCenter.z];
        immutable st = recast.navAddCylinderObstacle(handle, pos.ptr, radius, height, &outRef);
        return (st & recast.NAV_STATUS_SUCCEDED) != 0;
    }

    bool addBoxObstacle(Vec3 minPt, Vec3 maxPt, out NavObstacleRef outRef) @trusted nothrow @nogc {
        if (handle is null) return false;
        float[3] mn = [minPt.x, minPt.y, minPt.z];
        float[3] mx = [maxPt.x, maxPt.y, maxPt.z];
        immutable st = recast.navAddBoxObstacle(handle, mn.ptr, mx.ptr, &outRef);
        return (st & recast.NAV_STATUS_SUCCEDED) != 0;
    }

    bool addOrientedBoxObstacle(Vec3 center, Vec3 halfExtents, float yRadians,
                                out NavObstacleRef outRef) @trusted nothrow @nogc {
        if (handle is null) return false;
        float[3] c = [center.x, center.y, center.z];
        float[3] h = [halfExtents.x, halfExtents.y, halfExtents.z];
        immutable st = recast.navAddOrientedBoxObstacle(handle, c.ptr, h.ptr, yRadians, &outRef);
        return (st & recast.NAV_STATUS_SUCCEDED) != 0;
    }

    bool removeObstacle(NavObstacleRef obsRef) @trusted nothrow @nogc {
        if (handle is null || obsRef == 0) return false;
        immutable st = recast.navRemoveObstacle(handle, obsRef);
        return (st & recast.NAV_STATUS_SUCCEDED) != 0;
    }

    /// Process pending obstacle additions/removals and rebuild affected tiles.
    bool update(ref NavMesh mesh, out bool upToDate) @trusted nothrow @nogc {
        upToDate = true;
        if (handle is null || !mesh.isValid()) return false;
        bool u = false;
        immutable st = recast.navTileCacheUpdate(handle, mesh.handle, &u);
        upToDate = u;
        return (st & recast.NAV_STATUS_SUCCEDED) != 0;
    }

    /// Pump `update()` until all queued obstacle changes are applied (useful at load/test time).
    bool flushUpdates(ref NavMesh mesh, int maxSteps = 64) nothrow @nogc {
        bool upToDate = false;
        foreach (_; 0 .. maxSteps) {
            if (!update(mesh, upToDate)) return false;
            if (upToDate) return true;
        }
        return upToDate;
    }
}

/// Pathfinding and spatial query context for a `NavMesh` (move-only RAII).
struct NavQuery {
    package recast.NavQueryHandle* handle = null;

    @disable this(this);

    ~this() nothrow @nogc {
        destroy();
    }

    static NavQuery create(ref const NavMesh mesh, int maxNodes = 2048) @trusted nothrow @nogc {
        NavQuery q;
        if (!mesh.isValid()) return q;
        q.handle = recast.navCreateQuery(mesh.handle, maxNodes);
        return q;
    }

    bool isValid() const nothrow @nogc {
        return handle !is null;
    }

    void destroy() @trusted nothrow @nogc {
        if (handle !is null) {
            recast.navDestroyQuery(handle);
            handle = null;
        }
    }

    bool findNearestPoly(Vec3 center, Vec3 halfExtents, const ref NavQueryFilter filter,
                         out NavPolyRef outRef, out Vec3 outNearest) @trusted nothrow @nogc {
        if (handle is null) return false;
        float[3] c = [center.x, center.y, center.z];
        float[3] h = [halfExtents.x, halfExtents.y, halfExtents.z];
        float[3] n = 0;
        auto cf = filter.toC();
        immutable st = recast.navFindNearestPoly(handle, c.ptr, h.ptr, &cf, &outRef, n.ptr);
        outNearest = Vec3(n[0], n[1], n[2]);
        return (st & recast.NAV_STATUS_SUCCEDED) != 0 && outRef != 0;
    }

    int findPath(NavPolyRef startRef, NavPolyRef endRef, Vec3 startPos, Vec3 endPos,
                 const ref NavQueryFilter filter, scope NavPolyRef[] outPolys) @trusted nothrow @nogc {
        if (handle is null || outPolys.length == 0) return 0;
        float[3] sp = [startPos.x, startPos.y, startPos.z];
        float[3] ep = [endPos.x, endPos.y, endPos.z];
        auto cf = filter.toC();
        int count = 0;
        immutable st = recast.navFindPath(handle, startRef, endRef, sp.ptr, ep.ptr, &cf,
                                          outPolys.ptr, cast(int) outPolys.length, &count);
        if ((st & recast.NAV_STATUS_SUCCEDED) == 0) return 0;
        return count;
    }

    int findStraightPath(Vec3 startPos, Vec3 endPos, scope const(NavPolyRef)[] polys,
                         scope NavStraightPathPoint[] outPoints) @trusted nothrow @nogc {
        if (handle is null || polys.length == 0 || outPoints.length == 0) return 0;
        enum int STACK_MAX = 256;
        immutable int cap = cast(int) outPoints.length < STACK_MAX ? cast(int) outPoints.length : STACK_MAX;
        float[STACK_MAX * 3] pts = void;
        ubyte[STACK_MAX] flags = void;
        NavPolyRef[STACK_MAX] refs = void;
        float[3] sp = [startPos.x, startPos.y, startPos.z];
        float[3] ep = [endPos.x, endPos.y, endPos.z];
        int count = 0;
        immutable st = recast.navFindStraightPath(handle, sp.ptr, ep.ptr, polys.ptr, cast(int) polys.length,
                                                  pts.ptr, flags.ptr, refs.ptr, cap, &count);
        if ((st & recast.NAV_STATUS_SUCCEDED) == 0) return 0;
        foreach (i; 0 .. count) {
            outPoints[i].position = Vec3(pts[i * 3 + 0], pts[i * 3 + 1], pts[i * 3 + 2]);
            outPoints[i].polyRef = refs[i];
            outPoints[i].flags = flags[i];
        }
        return count;
    }

    bool raycast(NavPolyRef startRef, Vec3 startPos, Vec3 endPos,
                 const ref NavQueryFilter filter, out NavRaycastHit outHit) @trusted nothrow @nogc {
        if (handle is null || startRef == 0) return false;
        float[3] sp = [startPos.x, startPos.y, startPos.z];
        float[3] ep = [endPos.x, endPos.y, endPos.z];
        float[3] n = 0;
        auto cf = filter.toC();
        float t = 1.0f;
        bool hit = false;
        immutable st = recast.navRaycast(handle, startRef, sp.ptr, ep.ptr, &cf, &t, n.ptr, &hit);
        outHit.t = t;
        outHit.normal = Vec3(n[0], n[1], n[2]);
        outHit.hit = hit;
        return (st & recast.NAV_STATUS_SUCCEDED) != 0;
    }
}

/// Multi-agent local-avoidance crowd manager (move-only RAII).
struct NavCrowd {
    package recast.NavCrowdHandle* handle = null;

    @disable this(this);

    ~this() nothrow @nogc {
        destroy();
    }

    static NavCrowd create(int maxAgents, float maxAgentRadius, ref NavMesh mesh) @trusted nothrow @nogc {
        NavCrowd c;
        if (!mesh.isValid() || maxAgents <= 0) return c;
        c.handle = recast.navCreateCrowd(maxAgents, maxAgentRadius, mesh.handle);
        return c;
    }

    bool isValid() const nothrow @nogc {
        return handle !is null;
    }

    void destroy() @trusted nothrow @nogc {
        if (handle !is null) {
            recast.navDestroyCrowd(handle);
            handle = null;
        }
    }

    int addAgent(Vec3 pos, const ref NavCrowdAgentParams params) @trusted nothrow @nogc {
        if (handle is null) return -1;
        float[3] p = [pos.x, pos.y, pos.z];
        auto cp = params.toC();
        return recast.navCrowdAddAgent(handle, p.ptr, &cp);
    }

    void removeAgent(int idx) @trusted nothrow @nogc {
        if (handle !is null && idx >= 0) {
            recast.navCrowdRemoveAgent(handle, idx);
        }
    }

    bool requestMoveTarget(int idx, NavPolyRef targetRef, Vec3 targetPos) @trusted nothrow @nogc {
        if (handle is null || idx < 0 || targetRef == 0) return false;
        float[3] p = [targetPos.x, targetPos.y, targetPos.z];
        return recast.navCrowdRequestMoveTarget(handle, idx, targetRef, p.ptr);
    }

    bool requestMoveVelocity(int idx, Vec3 vel) @trusted nothrow @nogc {
        if (handle is null || idx < 0) return false;
        float[3] v = [vel.x, vel.y, vel.z];
        return recast.navCrowdRequestMoveVelocity(handle, idx, v.ptr);
    }

    bool resetMoveTarget(int idx) @trusted nothrow @nogc {
        if (handle is null || idx < 0) return false;
        return recast.navCrowdResetMoveTarget(handle, idx);
    }

    void update(float dt) @trusted nothrow @nogc {
        if (handle !is null && dt > 0.0f) {
            recast.navCrowdUpdate(handle, dt);
        }
    }

    bool getAgentState(int idx, out Vec3 outPos, out Vec3 outVel,
                       out NavAgentState outState) const @trusted nothrow @nogc {
        if (handle is null || idx < 0) return false;
        float[3] p = 0;
        float[3] v = 0;
        ubyte s = 0;
        if (!recast.navCrowdGetAgentState(handle, idx, p.ptr, v.ptr, &s)) return false;
        outPos = Vec3(p[0], p[1], p[2]);
        outVel = Vec3(v[0], v[1], v[2]);
        outState = s <= NavAgentState.offMesh ? cast(NavAgentState) s : NavAgentState.invalid;
        return true;
    }
}
