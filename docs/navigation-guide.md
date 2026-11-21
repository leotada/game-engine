# Navigation Guide (`engine.nav`)

This guide covers 3D navigation in the engine via `engine.nav`, backed by vendored C++ `recastnavigation` (`v1.6.0`, `DT_POLYREF64`) behind a flat `extern "C"` shim and `@safe nothrow @nogc` `Pod!T` D wrappers.

For design rationale and the future pure-D port roadmap, see [plan-navigation-recast.md](plan-navigation-recast.md).

---

## 1. Architecture Overview

| Module | Purpose |
|---|---|
| `engine.nav.types` | POD configs and enums (`NavBakeConfig`, `NavQueryFilter`, `NavCrowdAgentParams`, `NavObstacleShape`, `NavAgentState`, `NavPolyRef`) |
| `engine.nav.mesh` | RAII wrappers: `NavMesh`, `NavTileCache`, `NavQuery`, `NavCrowd` |
| `engine.nav.bake` | `bakeNavMesh` (tiled Recast/Detour + TileCache), binary `.navmesh` persistence (`saveNavMeshToBytes`, `loadNavMeshFromBytes`, `saveNavMeshFile`, `loadNavMeshFile`) |
| `engine.nav.ecs` | POD `@component` structs (`NavMeshSurface`, `NavAgent`, `NavMoveRequest`, `NavObstacle`, `NavOffMeshLink`, `NavModifierVolume`) and `stepNavAgents` |
| `engine.nav.debugdraw` | `drawNavMesh` (renders walkable NavMesh polygons as semi-transparent filled triangles + wireframe edges via `GizmoRenderer`) |

Re-exported from `import engine.nav;`.

---

## 2. Baking & Persisting a Tiled NavMesh

Pass triangle soup (`Vec3[]` vertices + `uint[]` indices) and a `NavBakeConfig` to `bakeNavMesh`. When a `NavTileCache` is passed, `bakeNavMesh` builds compressed tile layers so runtime dynamic obstacles can re-bake individual tiles on the fly.

```d
import engine.nav;

NavBakeConfig cfg = NavBakeConfig.defaults();
cfg.cellSize = 0.30f;
cfg.cellHeight = 0.20f;
cfg.agentRadius = 0.5f;
cfg.agentHeight = 2.0f;
cfg.agentMaxClimb = 0.9f;
cfg.agentMaxSlopeDeg = 45.0f;
cfg.tileSize = 48;

NavMesh navMesh;
NavTileCache tileCache;
scope(exit) {
    tileCache.destroy();
    navMesh.destroy();
}

immutable int builtTiles = bakeNavMesh(navMesh, tileCache, verts, indices, cfg);

// Save & reload binary .navmesh assets (registered in AssetDatabase as "navmesh"):
saveNavMeshFile(navMesh, "assets/nav/city_sector.navmesh");
NavMesh loaded = loadNavMeshFile("assets/nav/city_sector.navmesh");
```

- Use the 5-argument overload `bakeNavMesh(navMesh, verts, indices, cfg)` when you only need a static `NavMesh` without `NavTileCache`.

---

## 3. Pathfinding Queries (`NavQuery`)

`NavQuery` provides `@nogc` polygon lookups, A* corridor searches, string-pulled straight paths, and navmesh raycasts:

```d
auto query = NavQuery.create(navMesh, maxNodes: 2048);
scope(exit) query.destroy();

auto filter = NavQueryFilter.defaults();
immutable extents = Vec3(2.0f, 4.0f, 2.0f);

NavPolyRef startPoly, endPoly;
Vec3 startPt, endPt;
if (query.findNearestPoly(fromPos, extents, filter, startPoly, startPt) &&
    query.findNearestPoly(toPos, extents, filter, endPoly, endPt)) {
    NavPolyRef[256] polys = void;
    immutable int polyCount = query.findPath(startPoly, endPoly, startPt, endPt, filter, polys);

    Vec3[128] waypoints = void;
    ubyte[128] flags = void;
    NavPolyRef[128] wpPolys = void;
    immutable int wpCount = query.findStraightPath(startPt, endPt, polys[0 .. polyCount],
                                                   waypoints, flags, wpPolys);
}
```

- `query.raycast(startPoly, startPt, endPt, filter, t, hitNormal)` tests line-of-sight along walkable polygons without full A*.

---

## 4. Dynamic Obstacles (`NavTileCache`)

`NavTileCache` supports runtime addition and removal of cylinder, AABB, and oriented-box (OBB) obstacles without re-baking the whole level:

```d
NavObstacleRef barrelRef = 0;
tileCache.addCylinderObstacle(Vec3(4.0f, 0.0f, 2.0f), radius: 0.6f, height: 2.0f, barrelRef);

NavObstacleRef crateRef = 0;
tileCache.addOrientedBoxObstacle(Vec3(8.0f, 1.0f, 0.0f), Vec3(1.5f, 1.0f, 0.8f),
                                 yRadians: 0.5f, crateRef);

// Flush deferred tile rebuilds (call in update loop or flushUpdates):
tileCache.flushUpdates(navMesh);

// Remove later:
tileCache.removeObstacle(barrelRef);
tileCache.flushUpdates(navMesh);
```

- `tileCache.update(navMesh, upToDate)` performs incremental single-step tile updates if you want to budget obstacle rebuilds per frame.

---

## 5. Crowd Simulation & Local Avoidance (`NavCrowd`)

`NavCrowd` runs Detour's RVO/velocity-obstacle steering for multiple agents simultaneously in `@nogc`:

```d
auto crowd = NavCrowd.create(maxAgents: 64, maxAgentRadius: 0.6f, navMesh);
scope(exit) crowd.destroy();

NavCrowdAgentParams params;
params.radius = 0.5f;
params.height = 2.0f;
params.maxSpeed = 4.5f;
params.maxAcceleration = 10.0f;

immutable int idx = crowd.addAgent(spawnPos, params);
crowd.requestMoveTarget(idx, targetPoly, targetPos);

// Each fixed step / frame:
crowd.update(dt);

Vec3 pos, vel;
NavAgentState state;
if (crowd.getAgentState(idx, pos, vel, state)) {
    // apply pos / vel to entity
}
```

---

## 6. ECS Integration & Debug Draw

`engine.nav.ecs` provides POD `@component` structs (`NavMeshSurface`, `NavAgent`, `NavMoveRequest`, `NavObstacle`, `NavOffMeshLink`, `NavModifierVolume`) and a `@nogc` system helper `stepNavAgents`:

```d
// World must include PositionT (with float x, y, z), NavAgent, and NavMoveRequest:
stepNavAgents!(GameWorld, Position)(world, crowd, query, dt);
```

To visualize walkable NavMesh polygons in the editor or debug builds, pass your `GizmoRenderer` to `drawNavMesh`:

```d
drawNavMesh(gizmos, navMesh, fillAlpha: 0.35f, yOffset: 0.03f);
```

This draws semi-transparent filled cyan triangles (`GizmoRenderer.triangle`) plus wireframe polygon edges.
