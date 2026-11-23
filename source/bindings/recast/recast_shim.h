#ifndef GAME_ENGINE_RECAST_SHIM_H
#define GAME_ENGINE_RECAST_SHIM_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef uint64_t NavPolyRef;
typedef uint32_t NavObstacleRef;
typedef uint32_t NavStatus;

typedef struct NavMeshHandle NavMeshHandle;
typedef struct NavTileCacheHandle NavTileCacheHandle;
typedef struct NavQueryHandle NavQueryHandle;
typedef struct NavCrowdHandle NavCrowdHandle;

typedef struct NavBakeConfig {
    float cellSize;
    float cellHeight;
    float agentHeight;
    float agentRadius;
    float agentMaxClimb;
    float agentMaxSlopeDeg;
    int tileSize;
    int regionMinSize;
    int regionMergeSize;
    float edgeMaxLen;
    float edgeMaxError;
    int vertsPerPoly;
    float detailSampleDist;
    float detailSampleMaxError;
    int maxTiles;
    int maxPolysPerTile;
    int maxLayersPerTile;
    int maxObstacles;
    /// Bake worker threads: 1 = serial, 0 = one per hardware thread. Output is identical either way.
    int threads;
} NavBakeConfig;

/// Off-mesh link (jump, ladder, teleport). `start`/`end` are world positions that must lie within
/// `radius` of the walkable surface; `flags` 0 means the default walk flag.
typedef struct NavOffMeshConnectionC {
    float start[3];
    float end[3];
    float radius;
    uint8_t bidirectional;
    uint8_t area;
    uint16_t flags;
    uint32_t userId;
} NavOffMeshConnectionC;

typedef struct NavQueryFilterC {
    uint16_t includeFlags;
    uint16_t excludeFlags;
    float areaCosts[64];
} NavQueryFilterC;

typedef struct NavCrowdAgentParamsC {
    float radius;
    float height;
    float maxAcceleration;
    float maxSpeed;
    float collisionQueryRange;
    float pathOptimizationRange;
    float separationWeight;
    uint8_t updateFlags;
    uint8_t obstacleAvoidanceType;
    uint8_t queryFilterType;
} NavCrowdAgentParamsC;

NavBakeConfig navDefaultBakeConfig(void);
NavQueryFilterC navDefaultQueryFilter(void);
NavCrowdAgentParamsC navDefaultCrowdAgentParams(void);

// --- NavMesh & TileCache ---
NavMeshHandle* navCreateTiledMesh(float originX, float originY, float originZ,
                                  float tileWidth, float tileHeight,
                                  int maxTiles, int maxPolysPerTile);
void navDestroyMesh(NavMeshHandle* mesh);

NavTileCacheHandle* navCreateTileCache(NavMeshHandle* mesh,
                                       float originX, float originY, float originZ,
                                       float tileWidth, float tileHeight,
                                       const NavBakeConfig* cfg);
void navDestroyTileCache(NavTileCacheHandle* tc);

/// Bake all tiles overlapping the input geometry into `mesh` (and `tc` if non-null).
/// Returns number of tiles built (<= 0 on error).
int navBakeGeometry(NavMeshHandle* mesh,
                    NavTileCacheHandle* tc,
                    const float* verts3,
                    int vertCount,
                    const int* tris3,
                    int triCount,
                    const uint8_t* triAreasOrNull,
                    const NavBakeConfig* cfg);

/// Like `navBakeGeometry`, plus off-mesh connections baked into every tile that contains their
/// start (they are stored in the tile data, so `.navmesh` save/load keeps them). With a TileCache
/// the connections are also kept in the cache and survive obstacle-driven tile rebuilds.
int navBakeGeometryEx(NavMeshHandle* mesh,
                      NavTileCacheHandle* tc,
                      const float* verts3,
                      int vertCount,
                      const int* tris3,
                      int triCount,
                      const uint8_t* triAreasOrNull,
                      const NavBakeConfig* cfg,
                      const NavOffMeshConnectionC* offMeshCons,
                      int offMeshConCount);

/// Dynamic obstacles via TileCache (requires `tc != NULL`).
NavStatus navAddCylinderObstacle(NavTileCacheHandle* tc, const float* pos3,
                                 float radius, float height, NavObstacleRef* outRef);
NavStatus navAddBoxObstacle(NavTileCacheHandle* tc, const float* min3,
                            const float* max3, NavObstacleRef* outRef);
NavStatus navAddOrientedBoxObstacle(NavTileCacheHandle* tc, const float* center3,
                                    const float* halfExtents3, float yRadians,
                                    NavObstacleRef* outRef);
NavStatus navRemoveObstacle(NavTileCacheHandle* tc, NavObstacleRef ref);
NavStatus navTileCacheUpdate(NavTileCacheHandle* tc, NavMeshHandle* mesh, bool* outUpToDate);

/// Binary `.navmesh` serialization (saves all tiles in `mesh`; `navFreeBuffer` frees `outData`).
bool navSaveMeshToBuffer(const NavMeshHandle* mesh, uint8_t** outData, int* outSize);
void navFreeBuffer(void* ptr);
NavMeshHandle* navLoadMeshFromBuffer(const uint8_t* data, int size);

/// Like `navSaveMeshToBuffer`, plus the TileCache (compressed layers, params, off-mesh links) as a
/// trailing section (format version 2). With `tc == NULL` it is identical to `navSaveMeshToBuffer`.
bool navSaveMeshAndTileCacheToBuffer(const NavMeshHandle* mesh, const NavTileCacheHandle* tc,
                                     uint8_t** outData, int* outSize);

/// Load a `.navmesh` and, when the buffer holds a TileCache section, rebuild the cache into `*outTc`
/// (NULL otherwise). Dynamic obstacles are not persisted: add them again after loading.
NavMeshHandle* navLoadMeshAndTileCacheFromBuffer(const uint8_t* data, int size, NavTileCacheHandle** outTc);

/// Extract walkable triangles from `mesh` for debug rendering (`outVerts9` has 9 floats/tri).
int navExtractDebugTriangles(const NavMeshHandle* mesh, float* outVerts9,
                             uint8_t* outAreas, int maxTris);

// --- Queries ---
NavQueryHandle* navCreateQuery(const NavMeshHandle* mesh, int maxNodes);
void navDestroyQuery(NavQueryHandle* query);

NavStatus navFindNearestPoly(NavQueryHandle* query,
                             const float* center3,
                             const float* halfExtents3,
                             const NavQueryFilterC* filter,
                             NavPolyRef* outRef,
                             float* outNearest3);

NavStatus navFindPath(NavQueryHandle* query,
                      NavPolyRef startRef,
                      NavPolyRef endRef,
                      const float* startPos3,
                      const float* endPos3,
                      const NavQueryFilterC* filter,
                      NavPolyRef* outPolys,
                      int maxPolys,
                      int* outPolyCount);

NavStatus navFindStraightPath(NavQueryHandle* query,
                              const float* startPos3,
                              const float* endPos3,
                              const NavPolyRef* polys,
                              int polyCount,
                              float* outPoints3,
                              uint8_t* outFlags,
                              NavPolyRef* outRefs,
                              int maxPoints,
                              int* outPointCount);

NavStatus navRaycast(NavQueryHandle* query,
                     NavPolyRef startRef,
                     const float* startPos3,
                     const float* endPos3,
                     const NavQueryFilterC* filter,
                     float* outT,
                     float* outNormal3,
                     bool* outHit);

// --- Crowd ---
NavCrowdHandle* navCreateCrowd(int maxAgents, float maxAgentRadius, NavMeshHandle* mesh);
void navDestroyCrowd(NavCrowdHandle* crowd);

int navCrowdAddAgent(NavCrowdHandle* crowd, const float* pos3, const NavCrowdAgentParamsC* params);
void navCrowdRemoveAgent(NavCrowdHandle* crowd, int idx);
bool navCrowdRequestMoveTarget(NavCrowdHandle* crowd, int idx, NavPolyRef targetRef, const float* targetPos3);
bool navCrowdRequestMoveVelocity(NavCrowdHandle* crowd, int idx, const float* vel3);
bool navCrowdResetMoveTarget(NavCrowdHandle* crowd, int idx);
void navCrowdUpdate(NavCrowdHandle* crowd, float dt);
bool navCrowdGetAgentState(const NavCrowdHandle* crowd, int idx,
                           float* outPos3, float* outVel3, uint8_t* outState);

#ifdef __cplusplus
}
#endif

#endif // GAME_ENGINE_RECAST_SHIM_H
