# Navigation Guide (`engine.nav`)

This guide covers 3D navigation in the engine via `engine.nav`, backed by vendored C++ `recastnavigation` (`v1.6.0`, `DT_POLYREF64`) behind a flat `extern "C"` shim and `@safe nothrow @nogc` `Pod!T` D wrappers.

For design rationale and the future pure-D port roadmap, see [plan-navigation-recast.md](plan-navigation-recast.md).

---

## 1. Architecture Overview

| Module | Purpose |
|---|---|
| `engine.nav.types` | POD configs and enums (`NavBakeConfig`, `NavOffMeshConnection`, `NavQueryFilter`, `NavCrowdAgentParams`, `NavObstacleShape`, `NavAgentState`, `NavPolyRef`) |
| `engine.nav.mesh` | RAII wrappers: `NavMesh`, `NavTileCache`, `NavQuery`, `NavCrowd` |
| `engine.nav.bake` | `bakeNavMesh` (tiled Recast/Detour + TileCache + off-mesh links), binary `.navmesh` persistence (`saveNavMeshToBytes`, `loadNavMeshFromBytes`, `saveNavMeshFile`, `loadNavMeshFile`) and the cache-aware variants (`saveNavMeshToBytes(mesh, tc, out)`, `saveNavMeshFile(mesh, tc, path)`, `loadNavMeshAndCacheFromBytes`) |
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
- `bakeNavMesh` returns the number of tiles (direct path) or TileCache layers (TileCache path) that were built; `0` means nothing walkable was produced or the input was invalid.
- The bake covers every tile touched by the bounds of the input geometry and **replaces** those tiles. Always bake the full geometry of an area in one call: baking two halves separately leaves the tiles on their shared border with only the second half's triangles.

### `NavBakeConfig` reference

| Field | Default (D) | Meaning |
|:---|:---|:---|
| `cellSize` | `0.30` | Voxel size in X/Z (m). Smaller = more precise edges, slower bake, more memory. |
| `cellHeight` | `0.20` | Voxel size in Y (m). Must resolve `agentMaxClimb` (`agentMaxClimb / cellHeight` steps). |
| `agentHeight` | `2.0` | Minimum ceiling clearance (m). |
| `agentRadius` | `0.5` | Walkable area is eroded by this radius (m); agents keep this distance from walls. |
| `agentMaxClimb` | `0.9` | Highest ledge/step an agent can walk up (m). |
| `agentMaxSlopeDeg` | `45` | Steepest walkable slope (degrees). Ignored for triangles with explicit `triAreas`. |
| `tileSize` | `48` | Tile width in cells. Tile world size = `tileSize * cellSize`; pass that to `NavMesh.createTiled` / `NavTileCache.create`. |
| `regionMinSize` | `8` | Regions smaller than `regionMinSize²` cells are removed (kills tiny islands). |
| `regionMergeSize` | `20` | Regions smaller than `regionMergeSize²` cells are merged into neighbours. |
| `edgeMaxLen` | `12.0` | Longest contour edge (m) before it is split. |
| `edgeMaxError` | `1.3` | Contour simplification tolerance (cells). |
| `vertsPerPoly` | `6` | Max vertices per navmesh polygon (3..6). |
| `detailSampleDist` | `6.0` | Height-detail sampling distance (× `cellSize`); below `0.9` disables the detail mesh. |
| `detailSampleMaxError` | `1.0` | Height-detail tolerance (× `cellHeight`). |
| `maxTiles` | `1024` | Capacity of the `NavMesh` (and, times `maxLayersPerTile`, of the `NavTileCache`). Must cover the whole tile grid. |
| `maxPolysPerTile` | `4096` | Polygon capacity per tile. |
| `maxLayersPerTile` | `32` | TileCache layers per tile (stacked floors, bridges). |
| `maxObstacles` | `512` | Dynamic obstacle capacity of the `NavTileCache`. |
| `threads` | `1` | Bake worker threads: `1` serial, `0` one per hardware thread, `N` explicit. See below. |

### Multithreaded bake

Set `cfg.threads` to bake tiles on several threads: `1` (default) is serial, `0` uses one thread per
hardware thread (`std::thread::hardware_concurrency`), any other value is an explicit count (capped at
the number of tiles).

```d
auto cfg = NavBakeConfig.defaults();
cfg.threads = 0; // all cores
bakeNavMesh(navMesh, tileCache, verts, indices, cfg);
saveNavMeshFile(navMesh, tileCache, "assets/nav/city.navmesh");
```

**How it works.** The bake has two phases inside `navBakeGeometryEx` (`source/bindings/recast/recast_shim.cpp`):

1. **Build (parallel).** Workers take tile indices from an atomic counter. For each tile they run the
   whole Recast pipeline with their own `rcContext` and scratch buffers: rasterization, filtering,
   compact heightfield, erosion, then either regions → contours → poly mesh → detail mesh →
   `dtCreateNavMeshData` (direct path) or heightfield layers → `dtBuildTileCacheLayer` compression
   (TileCache path). The input geometry, `triAreas` and off-mesh links are only read.
2. **Commit (serial).** The built tiles are inserted in row-major tile order: `removeTile` /
   `addTile` on the `NavMesh`, or `dtTileCache::addTile` + `buildNavMeshTile` on the TileCache path
   (that step uses the cache's shared allocator, so it is not parallel).

Because the commit order does not depend on the thread count, the baked `.navmesh` is
**byte-identical** for every `threads` value. `engine/nav/tests.d` checks this on both paths.

**Measured gain** (120 m × 120 m hilly test terrain, ~170 tiles, 16 hardware threads, release-built shim):

| Path | `threads = 1` | `threads = 8` | `threads = 0` |
|:---|---:|---:|---:|
| Direct | 149 ms | 23 ms | 18 ms |
| TileCache | 125 ms | 22 ms | — |

**Rules and limits.**

- Thread safety covers the tiles of **one** bake call. Do not bake into the same `NavMesh` /
  `NavTileCache` from two threads at once, and do not query or step a `NavCrowd` on a mesh while it
  is being baked.
- Peak memory grows by the built tile data held until the commit phase (the same data then lives in the mesh).
- Every tile tests every input triangle against its bounds before rasterizing. With millions of
  triangles and thousands of tiles that `tiles × triangles` term grows; threads divide it, but
  removing it needs a per-tile spatial index in the shim (not implemented yet).
- `NavBakeConfig` gained the trailing `threads` field in the C header, so the D bindings and
  `librecast_shim.a` should match: rebuild the shim with `tools/build_sdl3_deps.sh` after pulling. A
  stale library does not know the field and silently bakes serially.

### Restoring dynamic obstacles from a saved `.navmesh`

A mesh-only `.navmesh` has no `NavTileCache`, so dynamic obstacles would need a full re-bake (minutes on a big map). Save the cache next to the mesh and restore both:

```d
saveNavMeshFile(navMesh, tileCache, "assets/nav/city.navmesh");        // mesh + cache section (format v2)

NavMesh mesh;
NavTileCache cache;
ubyte[] bytes = cast(ubyte[]) read("assets/nav/city.navmesh");
if (loadNavMeshAndCacheFromBytes(bytes, mesh, cache)) {
    // cache.isValid() is false when the file was saved mesh-only
    NavObstacleRef ref_;
    cache.addCylinderObstacle(pos, 1.0f, 2.0f, ref_);
    cache.flushUpdates(mesh);              // rebuilds only the affected tiles from the stored layers
}
```

The section stores the cache parameters, the compressed tile layers and the off-mesh links; plain `loadNavMeshFromBytes` / `loadNavMeshFile` still read these files (they ignore the section), and old v1 files load as before. Obstacles themselves are not stored: add them again after loading.

### Off-mesh links (jumps, ladders, drops)

Pass `NavOffMeshConnection[]` as the last argument of `bakeNavMesh` (after the optional per-triangle `triAreas`) to connect surfaces that are not adjacent in the geometry:

```d
NavOffMeshConnection jump;
jump.start = Vec3(-3, 0, 0);   // must be within `radius` of walkable ground (after agent-radius erosion)
jump.end   = Vec3( 3, 0, 0);
jump.radius = 1.0f;
jump.bidirectional = true;
jump.userId = 42;              // your own link id
bakeNavMesh(navMesh, tileCache, verts, indices, cfg, null, [jump]);
```

- `findPath` routes through the link, and `findStraightPath` marks the crossing with `NavStraightPathFlags.offMeshConnection`; a crowd agent that follows it reports `NavAgentState.offMesh` so the game can play its jump or ladder animation.
- The links are stored in the tile data: they survive `saveNavMeshToBytes` / `loadNavMeshFromBytes`, and with a `NavTileCache` they also survive obstacle-driven tile rebuilds (the cache keeps the set).
- `area` and `flags` feed `NavQueryFilter` (flags 0 = the default walk flag), so a filter can price or forbid a link kind.
- Covered by unit tests with a link crossing a tile border. An earlier test layout with the link end 0.2 m inside a tile border did not connect; this was not root-caused, so keep endpoints well inside the baked tile when you can.
- The shim (`source/bindings/recast/recast_shim.cpp`, new `navBakeGeometryEx`) is compiled into `libs/<target>/librecast_shim.a`; rebuild it with `tools/build_sdl3_deps.sh` after pulling this change.

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
