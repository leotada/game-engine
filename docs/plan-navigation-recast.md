# Port Plan: Recast Navigation → Pure D (`engine.nav.*`)

> **Status:** pending · Priority: medium · See [roadmap.md](roadmap.md)
>
> **Upstream:** <https://github.com/recastnavigation/recastnavigation> — version 1.6.0+,
> pinned at commit **`9f4ce64`** (2026-02-27). License: **zlib**.
>
> **Reference checkout:** `ref/recastnavigation/` (same convention as `ref/JoltPhysics/`).

## 1. Objective

Rewrite Recast Navigation in **pure D**, with no C/C++ code linked into the engine, as a first-class engine
subsystem under `engine.nav`. The port covers:

| Upstream library  | What it does                                                                    | D package               |
| :---------------- | :------------------------------------------------------------------------------ | :---------------------- |
| `Recast`          | Voxelizes triangle soup and builds a polygon navigation mesh from it            | `engine.nav.recast`     |
| `Detour`          | Tiled runtime navmesh plus queries: pathfinding, raycasts, nearest poly, …      | `engine.nav.detour`     |
| `DetourCrowd`     | Agent steering, path corridors, local obstacle avoidance                        | `engine.nav.crowd`      |
| `DetourTileCache` | Compressed tile layers that rebuild quickly under temporary obstacles           | `engine.nav.tilecache`  |
| `DebugUtils`      | Debug drawing of every build stage, plus dumps                                  | `engine.nav.debugdraw`  |

On top of the port, the plan adds the engine-specific layers that upstream does not have:

- an **ECS gameplay API** (`NavAgent`, `NavObstacle`, `NavOffMeshLink` components and systems),
- a **`.navmesh` asset** registered in the `AssetDatabase`,
- an **editor Navigation panel** (bake settings, background bake, visualization, test tools),
- a **demo** and a quickstart guide.

The finished system should be good enough to ship a commercial game with crowds of 100+ agents, runtime
obstacles, and tiled worlds. That matches the engine's goal of Bevy-level quality.

### 1.1 Why a pure-D port (and how it avoids the Jolt outcome)

The native Jolt port was **cancelled** ([jph-port-plan.md](jph-port-plan.md)) because it was about 4× slower
than Box3D. Recast is a much better candidate for a native port:

- **It is scalar, single-threaded, integer-heavy code.** Recast builds run on integer voxel grids after
  rasterization, and Detour queries are pointer and array walks with simple float math. There is no SIMD solver
  to compete against, so LDC with `-O3` should land close to Clang.
- **It is small.** The library code is about **15k LOC** of C++ (Catch2, the demo, and Contrib excluded).
  Jolt is over 100k.
- **It is stable.** Upstream sees few changes and the algorithms are well understood, so the risk of falling
  behind is low.
- **It benefits from engine integration.** POD storage, `Handle!T`, `FrameArena`, gizmo debug draw, ECS
  components, and the asset database are all hard to get through a C++ binding.

The plan still **adds a performance gate early** (Phase N2-G) so the Jolt mistake is not repeated. If the gate
fails, we stop and reconsider before porting the remaining 80% of the code.

## 2. Upstream Inventory

Library LOC measured at the pinned commit. Headers and sources are counted together.

| Upstream file(s)                                   |   LOC | Target D module                                  | Phase |
| :------------------------------------------------- | ----: | :----------------------------------------------- | :---- |
| `Recast.h` / `Recast.cpp`                          | 1913 | `nav/recast/config.d`, `heightfield.d`, `compact.d` | N2–N3 |
| `RecastAlloc.h/.cpp`, `RecastAssert.h/.cpp`        |  520 | `nav/core/alloc.d`, `nav/core/assert_.d`         | N1    |
| `RecastRasterization.cpp`                          |  562 | `nav/recast/rasterize.d`                         | N2    |
| `RecastFilter.cpp`                                 |  201 | `nav/recast/filter.d`                            | N2    |
| `RecastArea.cpp`                                   |  717 | `nav/recast/area.d`                              | N3    |
| `RecastRegion.cpp`                                 | 1820 | `nav/recast/region.d`                            | N4    |
| `RecastContour.cpp`                                | 1095 | `nav/recast/contour.d`                           | N5    |
| `RecastMesh.cpp`                                   | 1541 | `nav/recast/polymesh.d`                          | N6    |
| `RecastMeshDetail.cpp`                             | 1476 | `nav/recast/polymesh_detail.d`                   | N6    |
| `RecastLayers.cpp`                                 |  656 | `nav/recast/layers.d`                            | N10   |
| `DetourCommon.h/.cpp`, `DetourMath.h`              |  988 | `nav/core/geom.d`                                | N1    |
| `DetourStatus.h`, `DetourAlloc`, `DetourAssert`    |  267 | `nav/core/status.d` (+ shared alloc/assert)      | N1    |
| `DetourNavMesh.h/.cpp`                             | 2378 | `nav/detour/navmesh.d`, `tile.d`                 | N7    |
| `DetourNavMeshBuilder.h/.cpp`                      |  951 | `nav/detour/builder.d`                           | N7    |
| `DetourNode.h/.cpp`                                |  368 | `nav/detour/node.d`                              | N8    |
| `DetourNavMeshQuery.h/.cpp`                        | 4286 | `nav/detour/query.d`, `query_sliced.d`, `filter.d` | N8–N9 |
| `DetourTileCache.h/.cpp`                           | 1081 | `nav/tilecache/tilecache.d`                      | N10   |
| `DetourTileCacheBuilder.h/.cpp`                    | 2391 | `nav/tilecache/builder.d`                        | N10   |
| `DetourPathCorridor.h/.cpp`                        |  748 | `nav/crowd/corridor.d`                           | N11   |
| `DetourLocalBoundary.h/.cpp`                       |  203 | `nav/crowd/boundary.d`                           | N11   |
| `DetourObstacleAvoidance.h/.cpp`                   |  778 | `nav/crowd/avoidance.d`                          | N11   |
| `DetourProximityGrid.h/.cpp`                       |  268 | `nav/crowd/proximity.d`                          | N11   |
| `DetourPathQueue.h/.cpp`                           |  279 | `nav/crowd/path_queue.d`                         | N11   |
| `DetourCrowd.h/.cpp`                               | 1909 | `nav/crowd/crowd.d`                              | N11   |
| `DebugDraw`, `RecastDebugDraw`, `DetourDebugDraw`  | 2853 | `nav/debugdraw/*.d`                              | N12   |
| `RecastDump.h/.cpp`                                |  493 | `nav/debugdraw/dump.d`                           | N12   |
| `RecastDemo/Source/PartitionedMesh.cpp`            | ~250 | `nav/input/chunky_mesh.d`                        | N13   |
| `RecastDemo/Contrib/fastlz` (MIT)                  | ~550 | `nav/tilecache/fastlz.d`                         | N10   |

**Tests to port** (upstream uses Catch2, which becomes D `unittest` blocks):
`Tests_Recast.cpp` (692), `Tests_RecastRasterization.cpp` (613), `Tests_RecastFilter.cpp` (338),
`Tests_Alloc.cpp` (260, only the parts that still apply), `Tests_DetourPathCorridor.cpp` (118),
`Tests_Detour.cpp` (32).

**Test meshes:** `RecastDemo/Bin/Meshes/{dungeon,nav_test,undulating}.obj`. Copy them to `tests/nav/meshes/`
(they ship under the same zlib terms).

**Out of scope:** the `RecastDemo` ImGui application itself (`Sample_*`, `Tool_*`, `main.cpp`, ImGui, ImPlot),
the CMake build, Catch2, and `Bench_rcVector.cpp`. The demo's *tool behaviour* is re-implemented in the editor
(Phase N14), not ported line by line.

## 3. Global Port Conventions

These conventions apply to every phase. They follow [AGENTS.md](../AGENTS.md).

### 3.1 Process

- **One phase per commit** (or a small series per sub-phase). Each phase must finish with
  `dub test --config=library` passing, all dub configurations building, and `dub run --config=lint` clean.
- **DMD for development.** LDC2 release builds are used only for the performance gates and benchmarks.
- **Port faithfully first, optimize second.** Keep upstream function names (camelCase without the `rc`/`dt`
  prefix) and the order of operations, so each D function can be diffed against its C++ original. Restructure
  only where D safety or the GC rules require it (see §3.3).
- **Every ported file carries the zlib notice** plus a line saying it was altered (zlib clause 2):

  ```d
  // Ported from Recast Navigation (https://github.com/recastnavigation/recastnavigation),
  // commit 9f4ce64, file Recast/Source/RecastRegion.cpp.
  // Copyright (c) 2009-2010 Mikko Mononen memon@inside.org — zlib license (see LICENSES/recastnavigation.txt).
  // ALTERED: rewritten in D for engine.nav; this is not the original software.
  ```

  Also add `LICENSES/recastnavigation.txt` and an acknowledgment line in `README.md`.

### 3.2 Safety

- **`@safe:` at the top of every module.** No exceptions.
- **Slices instead of pointer arithmetic.** `const float* v` with `v[i*3+0]` becomes `const(float)[] verts`
  with the same indexing. Bounds checks stay on in debug builds.
- **`@trusted` only for the minimum.** Typical cases are the tile-blob reinterpretation (§3.4), `malloc`/`free`
  in `nav/core/alloc.d`, and measured hotspots that index through `.ptr`. Each `@trusted` block gets a comment
  explaining why it is sound.
- **DIP1000.** Query functions take `scope` output slices (`scope PolyRef[] path`) and return the number of
  elements written. They never return a slice into caller-owned stack memory.
- **`nothrow @nogc` on the whole runtime path.** That covers all of Detour, Crowd, and TileCache update. Recast
  build functions are also `nothrow @nogc` and allocate through `NavAllocator`, so baking can run on a worker
  thread without touching the GC.

### 3.3 Data layout (GC rules)

The most important structural change: upstream relies heavily on raw pointers between structures. Under the
engine's `Pod!T` rule (`!hasIndirections!T`), **engine storage cannot contain pointers**. The port replaces
them with **32-bit indices or offsets**:

| Upstream pointer                                   | D replacement                                                                          |
| :------------------------------------------------- | :------------------------------------------------------------------------------------- |
| `rcSpan* next` (heightfield span linked list)      | `uint next` index into a `SpanPool` (`0` = null). Also shrinks spans from 16 to 12 bytes |
| `rcSpanPool* next` + per-pool `rcSpan items[]`     | One growable `Pod!Span[]` arena per heightfield                                          |
| `rcHeightfield::spans` (`rcSpan**`)                | `Pod!uint[] columns` (head index per column)                                            |
| `dtMeshTile::{verts,polys,links,…}` pointers       | Offsets into the tile data blob; accessor methods return slices (§3.4)                 |
| `dtMeshTile* next` (tile free list, hash chain)    | `uint next` tile index                                                                  |
| `dtNode` pool hash `first`/`next`                  | Already index-based upstream, kept as is                                                |
| `dtPathCorridor::m_path` (heap array per agent)    | Slice of one shared `Pod!PolyRef[]` pool owned by `Crowd` (fixed capacity per agent)   |
| `dtCrowdAgent` corners / neighbours arrays         | Fixed-size static arrays (they already are upstream, kept as is)                       |
| `dtTileCache` compressed tile `data` pointers      | Offsets into a compressed-layer arena plus a `Handle!CompressedTile`                    |

Rules:

- Every container uses `Pod!T[]`. The lint (`tools/lint.d`) must pass on `source/engine/nav/`.
- Large buffers come from `NavAllocator` (default: `malloc`, so the GC never sees them; the
  `--DRT-gcopt` path is irrelevant here). Small long-lived arrays may use `new Pod!T[]` (allocated `NO_SCAN`).
- **Build scratch** (the equivalent of upstream `rcTempVector` / `rcScopedDelete`) uses a `NavScratch` bump
  allocator that is reset per tile build. This mirrors `dtTileCacheAlloc`'s `LinearAllocator` in the demo.
- **Query scratch** (node pool, open list, result buffers) is pre-allocated in `NavMeshQuery.init(maxNodes)`,
  exactly as upstream does. Nothing allocates per query.

### 3.4 Tile data blob (Detour)

Upstream `dtCreateNavMeshData` produces one contiguous `unsigned char*` blob:
`header | verts | polys | links | detailMeshes | detailVerts | detailTris | bvTree | offMeshCons`.
`dtNavMesh::addTile` then *patches raw pointers into it*. The D port keeps **the same blob layout**, so the
binary format stays compatible with upstream (useful for differential tests and tooling). It does **not** store
pointers. Instead:

```d
struct MeshTile {
    uint     salt;
    uint     linksFreeList;
    uint     dataOffset;   // into NavMesh.tileArena
    uint     dataSize;
    uint     next;         // free list / spatial hash chain (tile index, 0 = none)
    uint     flags;
    // Cached section offsets computed once in addTile (validated, see below)
    uint     vertsOff, polysOff, linksOff, detailMeshesOff, detailVertsOff,
             detailTrisOff, bvTreeOff, offMeshConsOff;
}

// Accessors on NavMesh: bounds-checked views into the blob.
const(MeshHeader)* header(in MeshTile t) const;   // @trusted cast, size-checked
const(Poly)[]       polys(in MeshTile t) const;
Link[]              links(ref MeshTile t);
```

- `addTile` **validates** magic, version, all section counts, and that the sum of section sizes equals
  `dataSize` *before* any reinterpretation. This makes loading `.navmesh` files from disk safe: a corrupted or
  hostile file returns `NavStatus.invalidParam` instead of reading out of bounds.
- Endian swapping (`dtNavMeshHeaderSwapEndian`, `dtNavMeshDataSwapEndian`) is ported as is.
- All `Poly`, `Link`, `BVNode`, `OffMeshConnection`, `PolyDetail` structs are POD with `static assert` on
  `.sizeof` and field offsets to match the C++ layout.

### 3.5 Virtual interfaces → compile-time dispatch

The engine forbids virtual dispatch in engine code. Upstream has five virtual interfaces:

| Upstream                        | D replacement                                                                                                    |
| :------------------------------ | :--------------------------------------------------------------------------------------------------------------- |
| `rcContext` (log, timers)       | `struct BuildContext` with an optional `void function(LogCategory, scope const(char)[]) nothrow @nogc` hook and timers backed by `MonoTime`. Logs go to `engine.core.log` by default |
| `dtQueryFilter` (virtual opt-in)| `struct QueryFilter` (include/exclude flags, `float[64] areaCost`), which is the upstream default non-virtual path. Query methods are **templated** on `Filter` with duck-typed `passFilter` / `getCost` (`isQueryFilter!F` constraint) |
| `dtPolyQuery`                   | Template callback parameter: `queryPolygons(F, CB)(…, ref CB cb)` where `cb(tileIdx, polys, refs)`               |
| `dtTileCacheCompressor`         | Template parameter `C` with `maxCompressedSize` / `compress` / `decompress` (`isTileCompressor!C`). Built-ins: `FastLzCompressor`, `NullCompressor` |
| `dtTileCacheMeshProcess`        | Template parameter or `void function(ref TileCacheParams, ubyte[] areas, ushort[] flags) nothrow @nogc`          |
| `dtTileCacheAlloc`              | `NavScratch` bump allocator (§3.3)                                                                              |

`NavMeshQuery!(Filter = QueryFilter)` and `TileCache!(Compressor = FastLzCompressor)` default their template
parameters, so the common case reads like ordinary non-template code.

### 3.6 Types and naming

| Upstream                                      | D                                                                     |
| :-------------------------------------------- | :-------------------------------------------------------------------- |
| `dtPolyRef` / `dtTileRef` (32-bit default)    | `PolyRef` / `TileRef` = **`ulong`** (upstream `DT_POLYREF64` layout: 32 salt / 22 tile / 10 poly bits). `version(NavPolyRef32)` restores the 32-bit layout |
| `dtStatus` (`unsigned int` bitfield)          | `struct NavStatus { uint bits; bool failed(); bool succeeded(); bool inProgress(); … }` with the same bit values |
| `rcConfig`                                    | `struct RecastConfig` (same fields, plus engine-friendly `fromAgent(AgentSettings, cellSize)`) |
| `float*` 3-vectors (internal)                 | `float[3]` / slices of `float`. Kept internally so the code stays diffable and hot loops stay flat |
| 3-vectors at the public API                   | `engine.math.Vec3`. Conversions are zero-cost: `Vec3` is three tightly packed floats, `static assert`ed |
| `rcMin` / `rcMax` / `rcSqr` / `rcClamp`       | `nav/core/geom.d` helpers (`pragma(inline, true)`)                    |
| `rcVector`, `rcTempVector`                    | `NavArray!T` (RAII, `@disable this(this)`, `Pod!T`) / `NavScratch`    |
| `rcNew` / `rcDelete` / `dtAlloc` / `dtFree`   | `NavAllocator` (struct with `alloc`/`free` function pointers, defaulting to `malloc`) |
| `rcAssert` / `dtAssert`                       | `navAssert` → `assert` in debug, optional custom hook (matches upstream #250) |

Upstream constants (`RC_WALKABLE_AREA`, `DT_VERTS_PER_POLYGON = 6`, `RC_SPAN_HEIGHT_BITS`, `DT_MAX_AREAS = 64`,
…) become `enum` values in the corresponding modules, keeping their numeric values.

### 3.7 Floating-point determinism

The differential tests (§4) only work if D and C++ do the same float operations in the same order:

- Do not reorder arithmetic during the faithful port. Keep `a*b + c` exactly as written.
- Build the C++ oracle with `-ffp-contract=off -fno-fast-math` and LDC with default flags (no `--ffast-math`;
  `--fp-contract=off` in the oracle comparison config) so FMA contraction cannot differ.
- Use `core.math.sqrt` / `std.math` functions with the same semantics as `sqrtf`, `floorf`, `ceilf`, `fabsf`.
  Watch `floor` on negative values and integer conversions (`(int)floorf(x)` vs `cast(int)`): they must
  truncate identically.
- Expected outcome: **bit-exact** results for every integer stage (spans, compact heightfield, distance field,
  regions, contours, poly mesh). **Epsilon comparison (≤ 1e-5 relative)** for the detail mesh and for float
  query outputs.

## 4. Verification Strategy: the `navref` Oracle

A pure-D port can only be trusted if it is compared stage by stage against the original. Linking C++ into the
engine is not acceptable, so the plan uses **golden files**:

1. **`tools/navref/`** holds a small C++17 command-line tool, *outside* the dub build. It is compiled with CMake
   against `ref/recastnavigation/`. It never ships, never links into the engine, and is only needed to
   regenerate goldens.
2. `navref` reads `mesh.obj` plus `config.json` and dumps a **versioned binary snapshot** of each stage into
   `tests/nav/golden/<mesh>/<config>/`:
   - `heightfield.bin` (every span: column, smin, smax, area), after each filter step,
   - `compact.bin` (spans, connections, areas, distance field, region IDs),
   - `contours.bin`, `polymesh.bin`, `polymesh_detail.bin`,
   - `navmesh_tile_<x>_<y>.bin` (the raw `dtCreateNavMeshData` blob, compared byte by byte),
   - `queries.bin`: a fixed, seeded list of about 2,000 query cases (findNearestPoly, findPath,
     findStraightPath, raycast, moveAlongSurface, findDistanceToWall, findPolysAroundCircle, getPolyHeight)
     and their results,
   - `crowd_trace.bin`: positions and velocities of 32 agents over 600 fixed-dt steps.
3. The D test suite (`tests/nav/*.d`, run by `dub test --config=library`) builds the same input and
   **diffs each stage against the golden data**. When a stage differs, the test prints the first diverging
   span, region, or vertex, which usually points straight at the faulty function.
4. Matrix: three meshes × configs {watershed, monotone, layers} × {solo, tiled 32/64} × agent sizes
   {small, default, large}. Golden data is about 5–15 MB, stored with Git LFS or regenerated in CI.

Additional verification:

- **Port all upstream Catch2 tests** as D `unittest` blocks in the module they test.
- **Fuzzing:** feed random/corrupted `.navmesh` blobs to `NavMesh.addTile` and `loadNavMesh` (no crash, no
  out-of-bounds read); feed random triangle soup to the Recast pipeline (no assert, no hang).
- **Property tests:** paths returned by `findPath` are connected via valid links; `findStraightPath` corners
  lie on the corridor portals; `moveAlongSurface` stays inside the visited polygons.
- **`--assert-no-gc`:** the demo's crowd update and pathfinding run for 600 headless frames without a GC
  allocation.

## 5. Target Module Layout

```
source/engine/nav/
├── package.d               # public import of the gameplay-facing API
├── core/
│   ├── alloc.d             # NavAllocator, NavArray!T, NavScratch
│   ├── assert_.d           # navAssert + custom hook
│   ├── status.d            # NavStatus
│   ├── geom.d              # DetourCommon + Recast inline math (vcross, triArea2D, distancePtSeg, …)
│   └── context.d           # BuildContext (log + timers)
├── recast/
│   ├── package.d
│   ├── config.d            # RecastConfig, calcBounds, calcGridSize, area constants
│   ├── heightfield.d       # Heightfield, SpanPool, addSpan
│   ├── rasterize.d         # rasterizeTriangle(s), markWalkable/clearUnwalkable
│   ├── filter.d            # low-hanging, ledge, low-height filters
│   ├── compact.d           # CompactHeightfield, buildCompactHeightfield
│   ├── area.d              # erode, median filter, markBox/Convex/Cylinder, offsetPoly
│   ├── region.d            # distance field, watershed, monotone, layer regions
│   ├── contour.d           # ContourSet, buildContours
│   ├── polymesh.d          # PolyMesh, buildPolyMesh, merge, copy
│   ├── polymesh_detail.d   # PolyMeshDetail, buildPolyMeshDetail, merge
│   └── layers.d            # HeightfieldLayerSet (for TileCache)
├── detour/
│   ├── package.d
│   ├── types.d             # PolyRef, Poly, Link, BVNode, OffMeshConnection, MeshHeader (C layout)
│   ├── builder.d           # NavMeshCreateParams, createNavMeshData (+ BV-tree build)
│   ├── navmesh.d           # NavMesh: tiles, salts, linking, off-mesh, serialization
│   ├── node.d              # NodePool, NodeQueue
│   ├── filter.d            # QueryFilter + isQueryFilter
│   ├── query.d             # NavMeshQuery: point/poly/path/raycast/wall queries
│   └── query_sliced.d      # sliced (time-budgeted) pathfinding
├── tilecache/
│   ├── package.d
│   ├── fastlz.d            # FastLZ level-1 in D (MIT)
│   ├── builder.d           # TileCacheLayer, regions, contours, polymesh (DetourTileCacheBuilder)
│   └── tilecache.d         # TileCache!(Compressor): obstacles (cylinder/AABB/OBB), timesliced update
├── crowd/
│   ├── package.d
│   ├── proximity.d         # ProximityGrid
│   ├── boundary.d          # LocalBoundary
│   ├── avoidance.d         # ObstacleAvoidanceQuery + debug data
│   ├── corridor.d          # PathCorridor (index-backed path storage)
│   ├── path_queue.d        # PathQueue
│   └── crowd.d             # Crowd, CrowdAgent, CrowdAgentParams
├── input/
│   ├── geometry.d          # NavInputGeometry: gathers scene triangles + convex volumes + links
│   └── chunky_mesh.d       # ChunkyTriMesh (RecastDemo PartitionedMesh) for tiled builds
├── bake/
│   ├── settings.d          # NavBakeSettings (@component-serializable), AgentSettings
│   ├── solo.d              # single-tile build pipeline
│   ├── tiled.d             # multi-tile build (parallel tiles)
│   └── tilecache_bake.d    # layer build for TileCache
├── asset/
│   └── navmesh_file.d      # .navmesh read/write (header + tiles + tilecache layers)
├── debugdraw/
│   ├── draw.d              # NavDebugDraw interface struct → GizmoRenderer adapter
│   ├── recast_draw.d       # heightfield / compact / regions / contours / polymesh visualizers
│   ├── detour_draw.d       # navmesh, BV-tree, portals, node pool, tile cache visualizers
│   └── dump.d              # OBJ dump of contours / poly meshes (RecastDump)
└── ecs/
    ├── components.d        # NavAgent, NavObstacle, NavOffMeshLink, NavModifierVolume, NavMeshSurface
    ├── systems.d           # navAgentSyncSystem, navCrowdSystem, navObstacleSystem
    └── nav_world.d         # NavWorld: owns NavMesh + Query + Crowd + TileCache; gameplay API
```

## 6. Phases

Status legend: ⬜ pending · ⏳ in progress · ✅ done. Estimates are D LOC including tests.

| #     | Phase                                                         | Est. LOC | Status     |
| :---- | :------------------------------------------------------------ | -------: | :--------- |
| N0    | Reference checkout, `navref` oracle, golden pipeline          |     ~900 | ⬜ Pending |
| N1    | `nav.core`: alloc, status, geom, context, assert              |   ~1,300 | ⬜ Pending |
| N2    | Recast heightfield: config, rasterization, filters            |   ~1,400 | ⬜ Pending |
| N2-G  | **Performance gate #1** (rasterization + filters vs C++)      |     ~150 | ⬜ Pending |
| N3    | Compact heightfield + area marking/erosion                    |   ~1,100 | ⬜ Pending |
| N4    | Distance field + regions (watershed / monotone / layer)       |   ~1,900 | ⬜ Pending |
| N5    | Contours                                                      |   ~1,100 | ⬜ Pending |
| N6    | Poly mesh + detail mesh                                       |   ~3,000 | ⬜ Pending |
| N6-G  | **Performance gate #2** (full solo build vs C++)              |      ~50 | ⬜ Pending |
| N7    | Detour: tile data builder + `NavMesh`                         |   ~2,400 | ⬜ Pending |
| N8    | Detour: node pool + core `NavMeshQuery`                       |   ~3,200 | ⬜ Pending |
| N9    | Detour: sliced pathfinding + remaining queries                |   ~1,200 | ⬜ Pending |
| N9-G  | **Performance gate #3** (query throughput vs C++)             |      ~80 | ⬜ Pending |
| N10   | TileCache: layers, FastLZ, builder, obstacles                 |   ~3,600 | ⬜ Pending |
| N11   | DetourCrowd: corridor, boundary, avoidance, grid, queue, crowd|   ~3,700 | ⬜ Pending |
| N12   | Debug draw + dump (gizmo adapter)                             |   ~2,600 | ⬜ Pending |
| N13   | Engine integration: input geometry, bake, asset, ECS API      |   ~2,500 | ⬜ Pending |
| N14   | Editor: Navigation panel, bake, tools                         |   ~2,000 | ⬜ Pending |
| N15   | Demo, docs, roadmap                                           |   ~1,000 | ⬜ Pending |
| N16   | Hardening: fuzzing, parallel bake, LDC tuning                 |     ~800 | ⬜ Pending |

**Total:** about 33k LOC of D including tests, demo, and editor. Of that, about 17k is a direct port.

Dependency graph:

```
N0 → N1 → N2 → N2-G → N3 → N4 → N5 → N6 → N6-G → N7 → N8 → N9 → N9-G ─┬→ N10 ─┐
                                                                       ├→ N11 ─┼→ N13 → N14 → N15 → N16
                                                                       └→ N12 ─┘
```

N10, N11, and N12 are independent of each other and can be done in any order (or in parallel) once Detour is
complete. N12 is useful early, so drawing helpers for each Recast stage may be added alongside N2–N6.

---

### Phase N0 — Reference checkout and `navref` oracle ⬜

- [ ] Clone upstream into `ref/recastnavigation/` pinned at `9f4ce64`. Record the commit in
      `ref/recastnavigation.COMMIT`. Add a `ref/` entry to the README next to JoltPhysics/bullet3.
- [ ] `tools/navref/CMakeLists.txt` + `navref.cpp` (about 600 LOC): OBJ loader (reuse upstream
      `InputGeom`/`MeshLoaderObj` logic), JSON config, stage dumps, the seeded query list, and the crowd trace.
      Build with `-O2 -ffp-contract=off`.
- [ ] Define the snapshot format in `tests/nav/golden/FORMAT.md`: little-endian, a `NAVG` magic, a version,
      and one section per stage.
- [ ] `tests/nav/golden_reader.d`: a D reader for the snapshot format, `@safe`, used by every later phase.
- [ ] `scripts/nav-regen-golden.sh`: rebuilds `navref` and regenerates every golden case.
- [ ] Copy the three test OBJ meshes into `tests/nav/meshes/`, with the license notice.
- [ ] `LICENSES/recastnavigation.txt`.

**Exit criteria:** `navref` produces the full golden matrix; the D reader parses every file in a `unittest`.

### Phase N1 — `nav.core` ⬜

- [ ] `alloc.d`: `NavAllocator` (malloc/free hooks, alignment, statistics in debug); `NavArray!T` (RAII,
      `@disable this(this)`, `reserve`/`resize`/`push`/`opIndex`/`opSlice`, `Pod!T` constraint);
      `NavScratch` (bump allocator with `mark()`/`release(mark)` and per-build `reset()`).
- [ ] `status.d`: `NavStatus` with `success`, `failure`, `inProgress` plus the detail bits (`wrongMagic`,
      `wrongVersion`, `outOfMemory`, `invalidParam`, `bufferTooSmall`, `outOfNodes`, `partialResult`,
      `alreadyOccupied`). The bit values match `DetourStatus.h`.
- [ ] `geom.d`: every `dtV*` / `rcV*` helper, `triArea2D`, `closestPtPointTriangle`, `closestHeightPointTriangle`,
      `intersectSegmentPoly2D`, `intersectSegSeg2D`, `pointInPolygon`, `distancePtPolyEdgesSqr`,
      `distancePtSegSqr2D`, `calcPolyCenter`, `overlapQuantBounds`, `overlapBounds`, `overlapPolyPoly2D`,
      `randomPointInConvexPoly`, `nextPow2`, `ilog2`, `align4`, `oppositeTile`, `swapEndian` helpers.
- [ ] `context.d`: `BuildContext` with log categories, a log ring buffer (fixed 256 entries × 128 chars, POD),
      and named timers (`TimerLabel` enum, same as `rcTimerLabel`), plus a summary printer.
- [ ] `assert_.d`: `navAssert(cond, msg)` and `setNavAssertHandler`.
- [ ] Unittests: port the applicable parts of `Tests_Recast.cpp` (math helpers) and `Tests_Alloc.cpp`
      (vector semantics, now tested against `NavArray`).

**Exit criteria:** every helper is covered by a unittest, and `geom.d` matches C++ results on 10k random inputs
(add a `navref geom` mode for this).

### Phase N2 — Recast heightfield ⬜

- [ ] `config.d`: `RecastConfig`, `calcBounds`, `calcGridSize`, the `RC_*` constants (`RC_SPAN_HEIGHT_BITS = 13`,
      `RC_SPAN_MAX_HEIGHT`, `RC_SPANS_PER_POOL`, `RC_NULL_AREA`, `RC_WALKABLE_AREA`, …).
- [ ] `heightfield.d`: `Span { uint smin:13, smax:13, area:6; uint next; }` (bitfields via
      `std.bitmanip.bitfields` or manual masking, then `static assert(Span.sizeof == 8)`); `SpanPool` as a
      `NavArray!Span` with a free list; `Heightfield { width, height, bmin, bmax, cs, ch, columns, pool }`;
      `createHeightfield`; `addSpan` (with merge, matching upstream `addSpan` exactly).
- [ ] `rasterize.d`: `dividePoly`, `rasterizeTri`, `rasterizeTriangle`, `rasterizeTriangles` (int indices,
      ushort indices, and flat-vertex overloads), `markWalkableTriangles`, `clearUnwalkableTriangles`.
      Includes the tile-border fix (#476).
- [ ] `filter.d`: `filterLowHangingWalkableObstacles`, `filterLedgeSpans`, `filterWalkableLowHeightSpans`.
- [ ] Port `Tests_RecastRasterization.cpp` and `Tests_RecastFilter.cpp`.
- [ ] Golden diff: the heightfield after rasterization and after each filter, for every matrix case.

**Exit criteria:** bit-exact heightfields on the whole matrix.

### Phase N2-G — Performance gate #1 ⬜

- [ ] `tools/navbench/` (dub config `nav-bench`): times rasterize + filters on `dungeon.obj` and
      `undulating.obj` at cs = 0.3 / 0.1, running 50 iterations and reporting the median.
- [ ] `navref bench` runs the same workload in C++ (Clang `-O3`).
- [ ] **Gate:** LDC `-O3 -mcpu=native` ≤ **1.25×** the C++ median. DMD `-O -release -inline` is recorded for
      information only.
- [ ] If the gate fails: profile with `perf` and apply local fixes (`.ptr` indexing in `@trusted` inner loops,
      `pragma(inline)`, avoiding bounds checks in the span merge loop). If it still fails after that, **stop and
      write a decision note in this document** before continuing.

### Phase N3 — Compact heightfield and areas ⬜

- [ ] `compact.d`: `CompactCell`, `CompactSpan { ushort y; ushort reg; uint con:24, h:8; }`,
      `CompactHeightfield`, `getHeightFieldSpanCount`, `buildCompactHeightfield` (including neighbour
      connections), `setCon` / `getCon` / `getDirOffsetX/Y` / `getDirForOffset`.
- [ ] `area.d`: `erodeWalkableArea`, `medianFilterWalkableArea`, `markBoxArea`, `markConvexPolyArea`,
      `markCylinderArea`, `offsetPoly`.
- [ ] Golden diff: spans, connections, and areas after erosion and after each marker.

### Phase N4 — Regions ⬜

The riskiest file in the Recast port (1820 LOC of stateful flood fills).

- [ ] `buildDistanceField` (+ `calculateDistanceField`, `boxBlur`).
- [ ] Watershed: `buildRegions` with `expandRegions`, `floodRegion`, `sortCellsByLevel`, `paintRectRegion`,
      `mergeAndFilterRegions` (+ `Region` struct, `addUniqueFloorRegion`, connection walking).
- [ ] Monotone: `buildRegionsMonotone`.
- [ ] Layers: `buildLayerRegions` + `mergeAndFilterLayerRegions`.
- [ ] Replace upstream `rcTempVector<int>` stacks with `NavScratch`-backed `NavArray!int`. Iteration order must
      stay **identical**, because region IDs depend on it.
- [ ] Golden diff: the distance field, then region IDs per span, for all three partition types.

### Phase N5 — Contours ⬜

- [ ] `contour.d`: `Contour`, `ContourSet`, `buildContours` with `getCornerHeight`, `walkContour`,
      `simplifyContour`, `removeDegenerateSegments`, `mergeContours`, hole merging (`ContourHole`,
      `ContourRegion`, `mergeRegionHoles`, `findLeftMostVertex`, diagonal tests), and the
      `RC_CONTOUR_TESS_WALL_EDGES` / `AREA_EDGES` flags.
- [ ] Golden diff: raw and simplified contour vertices.

### Phase N6 — Poly mesh and detail mesh ⬜

- [ ] `polymesh.d`: `PolyMesh`, `buildPolyMesh` (`triangulate`, `diagonal`, `inCone`, `addVertex` with the
      bucket hash, `buildMeshAdjacency`, `getPolyMergeValue`, `mergePolys`, `canRemoveVertex`, `removeVertex`),
      `mergePolyMeshes`, `copyPolyMesh`.
- [ ] `polymesh_detail.d`: `PolyMeshDetail`, `buildPolyMeshDetail` (`getHeightData`, `seedArrayWithPolyCenter`,
      `buildPolyDetail`, `delaunayHull`, `completeFacet`, `triangulateHull`, `polyMinExtent`, jitter
      functions, `getTriFlags`), `mergePolyMeshDetails`.
- [ ] Golden diff: `PolyMesh` bit-exact; `PolyMeshDetail` vertices within epsilon, triangles exact.
- [ ] `bake/solo.d`: an early version of the full single-tile pipeline (`buildSoloNavMeshData(input, settings)`),
      used by the gate below.

### Phase N6-G — Performance gate #2 ⬜

- [ ] Full solo build (all stages through the detail mesh) on the three meshes, for each partition type.
- [ ] **Gate:** LDC ≤ **1.3×** C++. Publish the per-stage breakdown from `BuildContext` timers in
      `docs/navigation-benchmark.md`.

### Phase N7 — Detour tile data and `NavMesh` ⬜

- [ ] `types.d`: `Poly` (`firstLink`, `verts[6]`, `neis[6]`, `flags`, `vertCount`, `areaAndtype`), `PolyDetail`,
      `Link`, `BVNode`, `OffMeshConnection`, `MeshHeader`, `NavMeshParams`, `PolyTypes`, the `DT_*` constants,
      and `static assert` checks on sizes and offsets.
- [ ] `builder.d`: `NavMeshCreateParams`, `createNavMeshData` (vertex/poly packing, portal edge classification,
      `createBVTree` with `subdivide` and `calcExtends`, off-mesh connection classification, detail mesh
      packing), `navMeshHeaderSwapEndian`, `navMeshDataSwapEndian`.
- [ ] `navmesh.d`: `NavMesh.init(params)` / `init(data)`, tile LUT (spatial hash), `addTile` (with validation,
      §3.4), `removeTile`, `connectIntLinks`, `connectExtLinks`, `connectExtOffMeshLinks`,
      `baseOffMeshLinks`, `unconnectLinks`, `findConnectingPolys`, `closestPointOnPolyInTile`,
      `findNearestPolyInTile`, `queryPolygonsInTile`, `getTileAt`, `getTilesAt`, `getNeighbourTilesAt`,
      `getTileRefAt`, `getTileByRef`, `getPolyRefBase`, `encodePolyId`, `decodePolyId`,
      `getTileAndPolyByRef(Unsafe)`, `isValidPolyRef`, `getOffMeshConnectionPolyEndPoints`,
      `setPolyFlags` / `getPolyFlags`, `setPolyArea` / `getPolyArea`, `storeTileState` / `restoreTileState`,
      `getPolyHeight`.
- [ ] Golden diff: tile blobs byte for byte; link tables after adding every tile of a tiled build.
- [ ] Round trip: build → add → remove → re-add keeps salts and links consistent.

### Phase N8 — Node pool and core `NavMeshQuery` ⬜

- [ ] `node.d`: `Node { float[3] pos; float cost, total; uint pidx:24, state:2, flags:3; PolyRef id; }`,
      `NodePool` (hash with `first`/`next` index arrays, `DT_MAX_STATES_PER_NODE`), `NodeQueue` (binary heap).
- [ ] `filter.d`: `QueryFilter`, `isQueryFilter!F`.
- [ ] `query.d`: `init(nav, maxNodes)`; `findNearestPoly` (both overloads, including `isOverPoly`, #448);
      `queryPolygons` (batch callback, #175); `closestPointOnPoly`; `closestPointOnPolyBoundary`;
      `getPolyHeight`; `findPath` (A*, `outOfNodes` handling, #222); `findStraightPath` (funnel algorithm
      with `appendVertex`, `appendPortals`, area/all-crossings options); `moveAlongSurface`; `raycast`
      (both the legacy and the `RaycastHit` versions, with path cost and `DT_RAYCAST_USE_COSTS`);
      `findDistanceToWall`; `getPortalPoints`; `getEdgeMidPoint`; `isValidPolyRef`; `isInClosedList`;
      `getAttachedNavMesh`.
- [ ] Query results go into caller-provided `scope` slices; the functions return `NavStatus` plus a count.
- [ ] Golden diff: the full seeded query list. Paths and refs exact, positions within epsilon.

### Phase N9 — Sliced pathfinding and remaining queries ⬜

- [ ] `query_sliced.d`: `initSlicedFindPath`, `updateSlicedFindPath(maxIter)`, `finalizeSlicedFindPath`,
      `finalizeSlicedFindPathPartial`, including `DT_FINDPATH_ANY_ANGLE` (raycast shortcuts).
- [ ] `findPolysAroundCircle`, `findPolysAroundShape`, `findLocalNeighbourhood`, `findRandomPoint`,
      `findRandomPointAroundCircle` (RNG as `float function() nothrow @nogc` or a template functor; defaults to
      an engine xorshift), `getPathFromDijkstraSearch` (#211), `getPolyWallSegments`.
- [ ] Golden diff: extend the query list. For random-point queries, use a deterministic RNG shared by `navref`.

### Phase N9-G — Performance gate #3 ⬜

- [ ] 100k `findPath` + `findStraightPath` pairs, 100k `raycast`, and 100k `findNearestPoly` on the tiled
      dungeon.
- [ ] **Gate:** LDC ≤ **1.2×** C++ throughput. This is the runtime hot path, so it gets the strictest bound.

### Phase N10 — TileCache ⬜

- [ ] `recast/layers.d`: `HeightfieldLayer`, `HeightfieldLayerSet`, `buildHeightfieldLayers` (from
      `RecastLayers.cpp`).
- [ ] `tilecache/fastlz.d`: FastLZ level 1 compress/decompress in pure D (MIT, about 550 LOC), byte-compatible
      with the C version (golden test on random buffers). `NullCompressor` for debugging.
- [ ] `tilecache/builder.d`: `TileCacheLayerHeader`, `TileCacheLayer`, `TileCacheContourSet`,
      `TileCachePolyMesh`, `buildTileCacheLayer`, `decompressTileCacheLayer`, `markCylinderArea`,
      `markBoxArea` (AABB + OBB), `buildTileCacheRegions`, `buildTileCacheContours`, `buildTileCachePolyMesh`,
      `tileCacheHeaderSwapEndian`. Includes the `removeVertex` overrun fix (#601).
- [ ] `tilecache/tilecache.d`: `TileCache!(Compressor)`: `init`, `addTile`, `removeTile`, `addObstacle`
      (cylinder), `addBoxObstacle` (AABB and OBB, #215/#278), `removeObstacle`, `queryTiles`, `update(dt, nav,
      &upToDate)` with time slicing (#203), `buildNavMeshTilesAt`, `buildNavMeshTile`, `getObstacleBounds`,
      `encodeTileId` / `decodeTileId` / obstacle refs. Obstacles are stored in `Pod!Obstacle[]` with salts;
      requests go into fixed `MAX_REQUESTS` / `MAX_UPDATE` ring buffers, as upstream.
- [ ] `bake/tilecache_bake.d`: layer rasterization per tile (the `Sample_TempObstacles` pipeline, reworked as
      engine code).
- [ ] Golden diff: compressed layers byte-exact (FastLZ determinism); rebuilt tile blobs after a scripted
      add/remove obstacle sequence.
- [ ] `--assert-no-gc` test: 600 frames of obstacles moving and `update()` running.

### Phase N11 — DetourCrowd ⬜

- [ ] `proximity.d`: `ProximityGrid` (pool + hash buckets, already index-based upstream).
- [ ] `boundary.d`: `LocalBoundary` (fixed segment and poly arrays).
- [ ] `avoidance.d`: `ObstacleAvoidanceParams`, `ObstacleAvoidanceQuery` (circle and segment obstacles,
      `sampleVelocityGrid`, `sampleVelocityAdaptive`, `processSample`), `ObstacleAvoidanceDebugData`
      (pre-allocated, optional).
- [ ] `corridor.d`: `PathCorridor` backed by a slice of the crowd's shared path pool (§3.3): `reset`,
      `findCorners`, `optimizePathVisibility`, `optimizePathTopology`, `moveOverOffmeshConnection`, `fixPathStart`,
      `trimInvalidPath`, `isValid`, `movePosition`, `moveTargetPosition`, `setCorridor`, plus the free functions
      `mergeCorridorStartMoved`, `mergeCorridorEndMoved`, `mergeCorridorStartShortcut`. Port
      `Tests_DetourPathCorridor.cpp`.
- [ ] `path_queue.d`: `PathQueue` (fixed request slots, sliced queries with an iteration budget per update).
- [ ] `crowd.d`: `CrowdAgentParams`, `CrowdAgent`, `CrowdAgentAnimation`, `Crowd`: `init(maxAgents, maxRadius,
      nav)`, `addAgent`, `removeAgent`, `updateAgentParameters`, `requestMoveTarget`, `requestMoveVelocity`,
      `resetMoveTarget`, `update(dt, debug)` (with every upstream step: check path validity, update move
      requests, update topology optimization, neighbours, find corners, trigger off-mesh, steering, velocity
      planning, integrate, handle collisions, move along the corridor, off-mesh animation), the
      `getFilter` / `getEditableFilter` table (`DT_CROWD_MAX_QUERY_FILTER_TYPE`), and the agent-index fix
      (#450).
- [ ] Golden diff: the crowd trace (32 agents × 600 steps, positions within epsilon, corridor refs exact).
- [ ] Benchmark: 1,000 agents on the tiled dungeon, `Crowd.update` ≤ 1.2× C++, `--assert-no-gc`.

### Phase N12 — Debug draw ⬜

- [ ] `draw.d`: `NavDebugDraw` struct (begin/vertex/end with primitive `points`/`lines`/`tris`/`quads`, depth
      mask, texture toggle). The `GizmoRenderer` adapter maps lines directly. For triangles, add a
      `trianglelist` pipeline to `engine.devtools.gizmos` (alpha-blended, depth-tested, `@nogc` vertex buffer),
      because walkable-surface and region views need filled polygons.
- [ ] `recast_draw.d`: `debugDrawTriMeshSlope`, heightfield solid/walkable, compact heightfield
      (solid/distance/regions), heightfield layers, region connections, raw/simplified contours, poly mesh,
      poly mesh detail.
- [ ] `detour_draw.d`: navmesh (with flags `offMeshConns`, `closedList`, `colorTiles`), nav mesh BV-tree,
      portals, node pool, nav mesh polys with a given flag, single poly highlight, tile cache layer areas,
      regions, contours, poly mesh, crowd agents (corridor, corners, avoidance samples, local boundary).
- [ ] `dump.d`: `dumpPolyMeshToObj`, `dumpPolyMeshDetailToObj`, `dumpContourSet`, `readContourSet`, and a
      `dumpCompactHeightfield` equivalent, all through `std.stdio` (used by tools only, not the frame path).
- [ ] Color helpers (`duRGBA`, `duIntToCol`, `duDarkenCol`, `duLerpCol`, `duTransCol`, `duCalcBoxColors`)
      mapped to the engine's `Color4`.

### Phase N13 — Engine integration ⬜

**Input geometry** (`nav/input/geometry.d`):

- [ ] `NavInputGeometry`: a POD vertex/index soup plus per-triangle area IDs, built from a `SceneWorld`.
      Sources: static entities with a `Visual` mesh (glTF `TexMesh` / generated primitives, using world
      transforms) and static `PhysicsBody` colliders (box/sphere/capsule/cylinder triangulated, mesh/hull
      colliders as is). The include/exclude rule uses a `NavMeshSurface` layer mask.
- [ ] `ChunkyTriMesh` (port of the demo's `PartitionedMesh`): an AABB tree over triangles, used to rasterize
      only the triangles overlapping each tile.
- [ ] Convex volumes from `NavModifierVolume` components (area type + height range), applied with
      `markConvexPolyArea`.
- [ ] Off-mesh connections from `NavOffMeshLink` components (start/end entity or local points, radius,
      bidirectional, area, flags, user ID = `EntityId`).

**Bake pipeline** (`nav/bake/`):

- [ ] `NavBakeSettings`: agent height/radius/max climb/max slope, cell size/height, region min/merge size,
      edge max len/error, verts per poly, detail sample dist/error, partition type, tile size, build mode
      (`solo` / `tiled` / `tileCache`). Reflected with `@component`/`@export_` so the inspector and scene files
      work automatically.
- [ ] `bakeNavMesh(ref const NavInputGeometry, in NavBakeSettings, ref BuildContext) → NavMeshData`. Solo,
      tiled, and tile cache variants.
- [ ] **Parallel tiled bake:** tiles are independent, so they are distributed over `std.parallelism` worker
      threads (or the future job system from [plan-parallel-ecs.md](plan-parallel-ecs.md)), each with its own
      `NavScratch` and `BuildContext`. Workers call `gcExcludeCurrentThread()` (from `engine/core/gc.d`)
      because the bake never touches the GC. Results are added to the `NavMesh` on the main thread.
- [ ] **Runtime rebake of single tiles** (for destructible or editable levels): `rebuildTile(tx, ty)`, issued
      from gameplay code and executed on a worker thread; the swap happens at frame start.

**Asset** (`nav/asset/navmesh_file.d`):

- [ ] Binary `.navmesh` file: `NAVM` magic, version, `NavMeshParams`, bake settings hash, input geometry hash,
      N tile blobs (Detour layout), optional tile cache section (compressed layers + params). It is a sidecar
      of the scene (`levels/foo.scene.json` → `levels/foo.navmesh`) with a `.meta` GUID in `AssetDatabase`.
      The scene's `NavMeshSurface` references it by GUID.
- [ ] Loading validates every tile (§3.4) and refuses version mismatches with a clear `warn()`.
- [ ] Stale detection: if the input geometry hash no longer matches, the editor shows "NavMesh out of date".

**ECS components and systems** (`nav/ecs/`): all components are POD (`@component`), with no slices or strings:

```d
@component struct NavMeshSurface {    // one per scene (or per agent type)
    AssetGuid   navMesh;              // baked .navmesh asset
    uint        includeLayers = uint.max;
    ubyte       agentTypeIndex;
}

@component struct NavAgent {
    float   radius = 0.6f, height = 2.0f;
    float   maxSpeed = 3.5f, maxAcceleration = 8.0f;
    float   separationWeight = 2.0f, collisionQueryRange = 12.0f, pathOptimizationRange = 30.0f;
    ubyte   avoidanceQuality = 3;     // index into ObstacleAvoidanceParams presets
    ubyte   queryFilterType;          // crowd filter slot
    ushort  updateFlags = NavAgentFlags.all;
    // runtime state (written by navCrowdSystem, read by gameplay)
    int     crowdIndex = -1;
    Vec3    desiredVelocity, velocity;
    NavAgentState state;              // invalid, walking, offMesh, arrived, noPath
}

@component struct NavMoveRequest { Vec3 target; bool velocityMode; Vec3 velocity; }  // add/replace to issue a move
@component struct NavObstacle { NavObstacleShape shape; Vec3 halfExtents; float radius, height; ObstacleRef tcRef; }
@component struct NavOffMeshLink { EntityId endEntity; Vec3 startLocal, endLocal; float radius; bool bidirectional; ubyte area; ushort flags; }
@component struct NavModifierVolume { Vec3 halfExtents; ubyte area; }
```

- [ ] `navAgentSyncSystem`: creates and removes crowd agents for new or destroyed `NavAgent` entities, and
      pushes parameter changes (`updateAgentParameters`).
- [ ] `navMoveRequestSystem`: consumes `NavMoveRequest` (finding the nearest poly to the target, then
      `requestMoveTarget` / `requestMoveVelocity`).
- [ ] `navCrowdSystem(dt)`: `Crowd.update`, then writes positions back to `Transform` (optionally only XZ while
      physics or animation drives Y), and fills the runtime state on `NavAgent`.
- [ ] `navObstacleSystem`: syncs `NavObstacle` transforms into the tile cache (add/remove/move when the entity
      moves more than a threshold), then calls `TileCache.update` with a time budget per frame.
- [ ] Every system is `nothrow @nogc` and allocation-free in steady state.

**Gameplay API** (`nav/ecs/nav_world.d`): a `NavWorld` struct owned by `App` / scene, for direct queries.

```d
struct NavWorld {
    NavStatus load(AssetGuid navMesh);
    bool      findPath(Vec3 from, Vec3 to, ref FrameArena arena, out Vec3[] corners,
                       in QueryFilter filter = QueryFilter.init);  // corners live until frame end
    bool      raycast(Vec3 from, Vec3 to, out NavRayHit hit);
    bool      nearestPoint(Vec3 p, Vec3 extents, out Vec3 onMesh, out PolyRef poly);
    bool      randomPointAround(Vec3 center, float radius, out Vec3 p);
    float     distanceToWall(Vec3 p, float maxRadius, out Vec3 hitPos, out Vec3 hitNormal);
    void      setAreaCost(NavArea area, float cost);           // areas named via StringId registry
    ref NavMeshQuery!QueryFilter query() return;               // escape hatch to the full Detour API
}
```

- [ ] Area registry: up to 64 areas named through `StringId` (`"walkable"`, `"water"`, `"door"`, `"jump"`,
      …), each with a default cost and flags, stored in the project settings.
- [ ] Physics coupling (optional, documented): agents can drive a Box3D kinematic character controller instead
      of writing the transform directly. The crowd provides the desired velocity, and physics resolves the
      final position, which is then fed back with `Crowd` agent position correction.

### Phase N14 — Editor ⬜

Follows [plan-editor-ux.md](plan-editor-ux.md) conventions (dock panel, undo stack, inspector reflection).

- [ ] **Navigation panel** (`editor/panels/navigation.d`): agent types list, `NavBakeSettings` inspector,
      "Bake" / "Clear" buttons, build mode and partition selection, a progress bar, and per-stage timings from
      `BuildContext`. Bakes run in the background with a cancel button; the editor stays responsive.
- [ ] **Scene View overlay:** toggles for each debug draw mode (input triangles by slope, voxels, regions,
      contours, poly mesh, detail mesh, navmesh, BV-tree, portals, tiles, obstacles, agents).
- [ ] **Tools** (re-implementing RecastDemo tools inside the editor):
  - *Path tester* (from `Tool_NavMeshTester`): click start and end, choose the mode (findPath + straight,
    sliced, raycast, distance to wall, polys around circle/shape, local neighbourhood, random points), and see
    the result and the explored node pool.
  - *Convex volume tool*: draw a `NavModifierVolume` polygon on the ground and set its area. Creates an entity
    with undo.
  - *Off-mesh link tool*: click two points and create a `NavOffMeshLink` entity.
  - *Prune tool* (`Tool_NavMeshPrune`): flood-fill from a seed and disable unreachable polygons.
  - *Crowd tool* in Play mode: spawn agents, set targets, and visualize corridors, corners, avoidance
    samples, and the proximity grid.
- [ ] Scene files: serialize the new components (scene_file v2) and the `.navmesh` GUID reference. The "NavMesh
      out of date" banner uses the input geometry hash.
- [ ] Player export (`build_export.d`): include `.navmesh` assets in exported builds.

### Phase N15 — Demo, docs, and roadmap ⬜

- [ ] `source/demo/navigation.d` + dub config `navigation`: a procedurally assembled level (ramps, stairs,
      platforms, a gap bridged by an off-mesh link), with 200 crowd agents that follow a player-controlled
      target, doors as `NavObstacle` toggled with a key, and a debug overlay toggle. It must run with
      `--headless-frames=600 --assert-no-gc`.
- [ ] `docs/navigation-quickstart.md`: baking, components, `NavWorld` queries, areas and costs, obstacles,
      off-mesh links, performance tips (tile size, `maxNodes`, path queue budget).
- [ ] `docs/navigation-benchmark.md`: results from the three gates plus crowd and bake timings (DMD and LDC).
- [ ] `roadmap.md`: add the navigation row and update the "Already Delivered" list on completion.
- [ ] `AGENTS.md`: add `nav/` to the directory structure and the build commands.

### Phase N16 — Hardening ⬜

- [ ] Fuzz harness (`tests/nav/fuzz.d`, dub config `nav-fuzz`): random tile blobs, truncated `.navmesh` files,
      degenerate triangle soup (zero area, NaN/Inf vertices, huge coordinates). Requirement: no crash, no
      out-of-bounds read, no infinite loop.
- [ ] Large-world test: 64×64 tiles, 64-bit `PolyRef`, tiles streamed in and out while queries run.
- [ ] LDC profile-guided pass on the three hot spots measured in the gates. Optional `core.simd` for
      rasterization clipping and BV-tree traversal, only if it is measurably faster.
- [ ] Track upstream: a script that lists upstream commits after `9f4ce64` touching ported files, so fixes can
      be cherry-picked by hand.

## 7. Risks and Mitigations

| Risk                                                                   | Mitigation                                                                                            |
| :--------------------------------------------------------------------- | :---------------------------------------------------------------------------------------------------- |
| Subtle divergence in region/contour code (order-dependent flood fills) | Stage-by-stage golden diffs (§4) that report the first diverging element; faithful port before any refactor |
| Float differences between D and C++ (FMA, `floor`, int conversion)     | §3.7 rules; integer stages must be bit-exact; epsilon only where unavoidable                         |
| Performance shortfall (the Jolt outcome)                               | Three hard gates (N2-G, N6-G, N9-G) with a written stop/continue decision                             |
| DMD debug builds too slow for editor bakes                             | Bakes run on worker threads; optionally compile `engine.nav` with `-O` in a dub sub-configuration     |
| Pointer → index rewrite introduces bugs                                | Done once, in N2 (spans) and N7 (tiles), each covered by goldens before moving on                     |
| Unsafe tile blob reinterpretation                                      | Single `@trusted` accessor module, full validation in `addTile`, fuzzing in N16                       |
| DIP1000 friction with slices into tile data                            | Accessors return `return scope` slices tied to `NavMesh`; queries write into caller `scope` buffers   |
| Template bloat from `Filter` / `Compressor` parameters                 | Defaults instantiate once; custom filters are rare; measure binary size in N15                        |
| Upstream fixes after the pinned commit                                 | Tracking script (N16); the faithful port keeps cherry-picking practical                               |
| License compliance (zlib)                                              | Header in every ported file marking it as altered, plus `LICENSES/recastnavigation.txt` and README acknowledgment |

## 8. Definition of Done

- All N0–N16 phases ✅; `dub test --config=library` covers every ported module, with golden diffs passing on
  the full matrix.
- All three performance gates pass with LDC; DMD numbers are documented.
- `dub run --config=navigation -- --headless-frames=600 --assert-no-gc` passes.
- The editor can bake, visualize, test, and save a navmesh for any scene, and the exported player loads it.
- `dub run --config=lint` is clean on `source/engine/nav/`; no `@system` code; every `@trusted` block has a
  justification comment.
- The quickstart and benchmark docs are published and the roadmap is updated.
