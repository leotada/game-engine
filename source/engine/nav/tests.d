/// Unit and integration tests for `engine.nav` (multi-tile bake, TileCache dynamic obstacles,
/// `.navmesh` round-trip, 50-agent `@nogc` NavCrowd simulation, and ECS `stepNavAgents`).
module engine.nav.tests;

version (unittest):

import core.memory : GC;
import engine.ecs.world : World;
import engine.math.vec : Vec3;
import engine.nav;

@safe:

private void buildFloorMesh(out Vec3[] verts, out int[] indices, float halfSize = 48.0f) {
    // 2 triangles covering [-halfSize, +halfSize] in X and Z at y = 0
    verts = [
        Vec3(-halfSize, 0.0f, -halfSize),
        Vec3(-halfSize, 0.0f,  halfSize),
        Vec3( halfSize, 0.0f,  halfSize),
        Vec3( halfSize, 0.0f, -halfSize),
    ];
    indices = [0, 1, 2, 0, 2, 3];
}

private void stepCrowdNoGc(ref NavCrowd crowd, float dt, int steps) nothrow @nogc {
    foreach (_; 0 .. steps) {
        crowd.update(dt);
    }
}

@safe unittest {
    // 1. Multi-tile NavMesh + TileCache bake
    Vec3[] verts;
    int[] indices;
    buildFloorMesh(verts, indices, 48.0f);

    auto cfg = NavBakeConfig.defaults();
    cfg.cellSize = 0.4f;
    cfg.cellHeight = 0.2f;
    cfg.tileSize = 32; // 32 * 0.4 = 12.8m per tile -> ~8x8 = 64 tiles
    cfg.maxTiles = 256;
    cfg.maxPolysPerTile = 1024;
    cfg.maxObstacles = 64;

    immutable float tileWorld = cfg.tileSize * cfg.cellSize;
    immutable origin = Vec3(-48.0f, -5.0f, -48.0f);

    auto mesh = NavMesh.createTiled(origin, tileWorld, tileWorld, cfg.maxTiles, cfg.maxPolysPerTile);
    assert(mesh.isValid());
    auto tc = NavTileCache.create(mesh, origin, tileWorld, tileWorld, cfg);
    assert(tc.isValid());

    immutable built = bakeNavMesh(mesh, tc, verts, indices, cfg);
    assert(built > 1, "Expected multi-tile bake to build >1 tile");

    // 2. Pathfinding across multiple tiles
    auto query = NavQuery.create(mesh, 2048);
    assert(query.isValid());
    auto filter = NavQueryFilter.defaults();
    immutable ext = Vec3(2.0f, 4.0f, 2.0f);

    NavPolyRef startPoly = 0, endPoly = 0;
    Vec3 startPt, endPt;
    assert(query.findNearestPoly(Vec3(-32.0f, 0.0f, 0.0f), ext, filter, startPoly, startPt));
    assert(query.findNearestPoly(Vec3( 32.0f, 0.0f, 0.0f), ext, filter, endPoly, endPt));

    NavPolyRef[128] polys;
    immutable polyCount = query.findPath(startPoly, endPoly, startPt, endPt, filter, polys);
    assert(polyCount > 1, "Expected multi-poly path across tiles");

    NavStraightPathPoint[64] straight;
    immutable spCount = query.findStraightPath(startPt, endPt, polys[0 .. polyCount], straight);
    assert(spCount >= 2);

    // Clear raycast before obstacles
    NavRaycastHit hitBefore;
    assert(query.raycast(startPoly, startPt, endPt, filter, hitBefore));
    assert(!hitBefore.hit, "Expected unobstructed raycast before adding obstacles");

    // 3. Dynamic TileCache obstacles (cylinder + OBB) block & reroute, then clear on removal
    NavObstacleRef cylRef = 0, obbRef = 0;
    assert(tc.addCylinderObstacle(Vec3(0.0f, 0.0f, 0.0f), 4.0f, 3.0f, cylRef));
    assert(tc.addOrientedBoxObstacle(Vec3(0.0f, 1.0f, 6.0f), Vec3(2.5f, 2.0f, 2.5f), 0.45f, obbRef));
    assert(tc.flushUpdates(mesh));

    // Re-query start poly (tile at origin may have rebuilt, start at -32 is intact, check raycast)
    NavRaycastHit hitBlocked;
    assert(query.raycast(startPoly, startPt, endPt, filter, hitBlocked));
    assert(hitBlocked.hit && hitBlocked.t < 1.0f, "Expected raycast to hit dynamic obstacle");

    // Straight path must still succeed by routing around the obstacle
    immutable blockedPolyCount = query.findPath(startPoly, endPoly, startPt, endPt, filter, polys);
    assert(blockedPolyCount > 0);
    immutable blockedSpCount = query.findStraightPath(startPt, endPt, polys[0 .. blockedPolyCount], straight);
    assert(blockedSpCount >= 3, "Expected detour waypoint around dynamic obstacle");

    // Remove obstacles and verify unobstructed raycast returns
    assert(tc.removeObstacle(cylRef));
    assert(tc.removeObstacle(obbRef));
    assert(tc.flushUpdates(mesh));

    NavRaycastHit hitAfter;
    assert(query.raycast(startPoly, startPt, endPt, filter, hitAfter));
    assert(!hitAfter.hit, "Expected unobstructed raycast after removing obstacles");

    // 4. Binary .navmesh round-trip
    ubyte[] serialized;
    assert(saveNavMeshToBytes(mesh, serialized));
    assert(serialized.length > 0);

    auto loadedMesh = loadNavMeshFromBytes(serialized);
    assert(loadedMesh.isValid());
    auto loadedQuery = NavQuery.create(loadedMesh, 2048);
    assert(loadedQuery.isValid());

    NavPolyRef lStart = 0, lEnd = 0;
    Vec3 lStartPt, lEndPt;
    assert(loadedQuery.findNearestPoly(Vec3(-32.0f, 0.0f, 0.0f), ext, filter, lStart, lStartPt));
    assert(loadedQuery.findNearestPoly(Vec3( 32.0f, 0.0f, 0.0f), ext, filter, lEnd, lEndPt));
    immutable lPolyCount = loadedQuery.findPath(lStart, lEnd, lStartPt, lEndPt, filter, polys);
    assert(lPolyCount > 1);
}

@safe unittest {
    // 5. 50-agent NavCrowd simulation with zero GC allocations in the update loop
    Vec3[] verts;
    int[] indices;
    buildFloorMesh(verts, indices, 48.0f);

    auto cfg = NavBakeConfig.defaults();
    cfg.cellSize = 0.4f;
    cfg.tileSize = 32;
    cfg.maxTiles = 256;
    cfg.maxPolysPerTile = 1024;

    immutable float tileWorld = cfg.tileSize * cfg.cellSize;
    immutable origin = Vec3(-48.0f, -5.0f, -48.0f);
    auto mesh = NavMesh.createTiled(origin, tileWorld, tileWorld, cfg.maxTiles, cfg.maxPolysPerTile);
    assert(bakeNavMesh(mesh, verts, indices, cfg) > 0);

    auto query = NavQuery.create(mesh, 2048);
    auto crowd = NavCrowd.create(64, 0.5f, mesh);
    assert(crowd.isValid());

    auto filter = NavQueryFilter.defaults();
    immutable ext = Vec3(2.0f, 4.0f, 2.0f);
    NavPolyRef targetPoly = 0;
    Vec3 targetPos;
    assert(query.findNearestPoly(Vec3(20.0f, 0.0f, 20.0f), ext, filter, targetPoly, targetPos));

    auto params = NavCrowdAgentParams.defaults();
    int[50] agentIds;
    foreach (i; 0 .. 50) {
        immutable float row = cast(float) (i / 10);
        immutable float col = cast(float) (i % 10);
        immutable spawn = Vec3(-20.0f + col * 2.0f, 0.0f, -20.0f + row * 2.0f);
        agentIds[i] = crowd.addAgent(spawn, params);
        assert(agentIds[i] >= 0);
        assert(crowd.requestMoveTarget(agentIds[i], targetPoly, targetPos));
    }

    // Warm up 1 tick, then measure GC allocations over 30 frames
    stepCrowdNoGc(crowd, 1.0f / 60.0f, 1);
    immutable size_t allocBefore = () @trusted { return GC.stats().allocatedInCurrentThread; }();
    stepCrowdNoGc(crowd, 1.0f / 60.0f, 30);
    immutable size_t allocAfter = () @trusted { return GC.stats().allocatedInCurrentThread; }();
    assert(allocAfter == allocBefore, "NavCrowd.update must allocate zero GC memory");

    Vec3 pos, vel;
    NavAgentState st;
    assert(crowd.getAgentState(agentIds[0], pos, vel, st));
    assert(st == NavAgentState.walking);
    assert(pos.x > -20.0f && pos.z > -20.0f, "Expected agent to move toward (20, 0, 20)");
}

private struct TestPos {
    float x = 0, y = 0, z = 0;
}

@safe unittest {
    // 6. ECS World + stepNavAgents integration
    Vec3[] verts;
    int[] indices;
    buildFloorMesh(verts, indices, 32.0f);

    auto cfg = NavBakeConfig.defaults();
    cfg.cellSize = 0.4f;
    cfg.tileSize = 32;
    immutable float tileWorld = cfg.tileSize * cfg.cellSize;
    immutable origin = Vec3(-32.0f, -5.0f, -32.0f);
    auto mesh = NavMesh.createTiled(origin, tileWorld, tileWorld, cfg.maxTiles, cfg.maxPolysPerTile);
    assert(bakeNavMesh(mesh, verts, indices, cfg) > 0);

    auto query = NavQuery.create(mesh, 1024);
    auto crowd = NavCrowd.create(16, 0.5f, mesh);

    World!(TestPos, NavAgent, NavMoveRequest) world;
    auto e = world.spawn();
    world.set(e, TestPos(-10.0f, 0.0f, 0.0f));
    world.set(e, NavAgent.init);
    NavMoveRequest req;
    req.target = Vec3(10.0f, 0.0f, 0.0f);
    req.pending = true;
    world.set(e, req);

    foreach (_; 0 .. 20) {
        stepNavAgents!(typeof(world), TestPos)(world, crowd, query, 1.0f / 60.0f);
    }

    auto pos = world.get!TestPos(e);
    auto agent = world.get!NavAgent(e);
    assert(agent.crowdIndex >= 0);
    assert(pos.x > -10.0f, "Expected ECS NavAgent to advance toward target");
}

// --- Off-mesh links -------------------------------------------------------------------------

/// Two 8 x 8 m platforms at y = 0 separated by a 4 m gap along X (no geometry in between).
private void buildGapPlatforms(out Vec3[] verts, out int[] indices) {
    verts = [
        Vec3(-10.0f, 0.0f, -4.0f), Vec3(-10.0f, 0.0f, 4.0f), Vec3(-2.0f, 0.0f, 4.0f), Vec3(-2.0f, 0.0f, -4.0f),
        Vec3(  2.0f, 0.0f, -4.0f), Vec3(  2.0f, 0.0f, 4.0f), Vec3(10.0f, 0.0f, 4.0f), Vec3(10.0f, 0.0f, -4.0f),
    ];
    indices = [0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7];
}

/// Path from the left platform to the right one; true when the path reaches the right platform.
private bool pathCrossesGap(ref NavMesh mesh, out bool usedOffMesh) {
    usedOffMesh = false;
    auto query = NavQuery.create(mesh, 1024);
    auto filter = NavQueryFilter.defaults();
    immutable ext = Vec3(1.0f, 2.0f, 1.0f);
    NavPolyRef startPoly = 0, endPoly = 0;
    Vec3 startPt, endPt;
    if (!query.findNearestPoly(Vec3(-6.0f, 0.0f, 0.0f), ext, filter, startPoly, startPt)) return false;
    if (!query.findNearestPoly(Vec3(6.0f, 0.0f, 0.0f), ext, filter, endPoly, endPt)) return false;

    NavPolyRef[64] polys;
    immutable n = query.findPath(startPoly, endPoly, startPt, endPt, filter, polys);
    if (n <= 0 || polys[n - 1] != endPoly) return false;

    NavStraightPathPoint[16] straight;
    immutable sp = query.findStraightPath(startPt, endPt, polys[0 .. n], straight);
    foreach (i; 0 .. sp)
        if ((straight[i].flags & NavStraightPathFlags.offMeshConnection) != 0) usedOffMesh = true;
    return true;
}

@safe unittest {
    Vec3[] verts;
    int[] indices;
    buildGapPlatforms(verts, indices);

    auto cfg = NavBakeConfig.defaults();
    cfg.cellSize = 0.3f;
    cfg.cellHeight = 0.2f;
    cfg.tileSize = 50; // 15 m tiles: columns [-15, 0] and [0, 15], so the link crosses a tile border
    cfg.maxTiles = 64;
    cfg.maxPolysPerTile = 512;
    immutable float tileWorld = cfg.tileSize * cfg.cellSize;
    immutable origin = Vec3(-15.0f, -5.0f, -10.0f);

    NavOffMeshConnection link;
    link.start = Vec3(-3.0f, 0.0f, 0.0f);
    link.end = Vec3(3.0f, 0.0f, 0.0f);
    link.radius = 1.0f;
    link.bidirectional = true;
    link.userId = 42;
    const links = [link];

    bool used;

    // Without the link the platforms are disconnected.
    auto plain = NavMesh.createTiled(origin, tileWorld, tileWorld, cfg.maxTiles, cfg.maxPolysPerTile);
    assert(bakeNavMesh(plain, verts, indices, cfg) > 0);
    assert(!pathCrossesGap(plain, used), "gap must block the path without an off-mesh link");

    // With the link (direct bake) the path crosses and reports the off-mesh segment.
    auto linked = NavMesh.createTiled(origin, tileWorld, tileWorld, cfg.maxTiles, cfg.maxPolysPerTile);
    assert(bakeNavMesh(linked, verts, indices, cfg, null, links) > 0);
    assert(pathCrossesGap(linked, used), "off-mesh link must connect the platforms");
    assert(used, "straight path must flag the off-mesh connection");

    // The link is stored in the tile data, so `.navmesh` save/load keeps it.
    ubyte[] bytes;
    assert(saveNavMeshToBytes(linked, bytes));
    auto reloaded = loadNavMeshFromBytes(bytes);
    assert(reloaded.isValid());
    assert(pathCrossesGap(reloaded, used) && used, "off-mesh link must survive .navmesh round trip");

    // With a TileCache the link also survives obstacle-driven tile rebuilds.
    auto tcMesh = NavMesh.createTiled(origin, tileWorld, tileWorld, cfg.maxTiles, cfg.maxPolysPerTile);
    auto tc = NavTileCache.create(tcMesh, origin, tileWorld, tileWorld, cfg);
    assert(tc.isValid());
    assert(bakeNavMesh(tcMesh, tc, verts, indices, cfg, null, links) > 0);
    assert(pathCrossesGap(tcMesh, used) && used);
    NavObstacleRef obs = 0;
    assert(tc.addCylinderObstacle(Vec3(-8.0f, 0.0f, 3.0f), 0.5f, 2.0f, obs));
    assert(tc.flushUpdates(tcMesh));
    assert(pathCrossesGap(tcMesh, used) && used, "off-mesh link must survive a TileCache rebuild");
}
