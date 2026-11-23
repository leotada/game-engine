/// D bindings for the `recast_shim` C API (`librecast_shim.a`).
/// Types come from `recast_import.c` (ImportC), and functions are declared
/// `extern(C) nothrow @nogc` so `engine.nav` can call them directly from `@nogc` paths.
module bindings.recast;

public import recast_import : NavPolyRef,
    NavObstacleRef,
    NavStatus,
    NavMeshHandle,
    NavTileCacheHandle,
    NavQueryHandle,
    NavCrowdHandle,
    NavBakeConfig,
    NavOffMeshConnectionC,
    NavQueryFilterC,
    NavCrowdAgentParamsC;

enum uint NAV_STATUS_SUCCEDED   = 1u << 30;
enum uint NAV_STATUS_FAILED     = 1u << 31;
enum uint NAV_STATUS_INPROGRESS = 1u << 29;

extern(C) nothrow @nogc:

NavBakeConfig navDefaultBakeConfig();
NavQueryFilterC navDefaultQueryFilter();
NavCrowdAgentParamsC navDefaultCrowdAgentParams();

NavMeshHandle* navCreateTiledMesh(float originX, float originY, float originZ,
                                  float tileWidth, float tileHeight,
                                  int maxTiles, int maxPolysPerTile);
void navDestroyMesh(NavMeshHandle* mesh);

NavTileCacheHandle* navCreateTileCache(NavMeshHandle* mesh,
                                       float originX, float originY, float originZ,
                                       float tileWidth, float tileHeight,
                                       const(NavBakeConfig)* cfg);
void navDestroyTileCache(NavTileCacheHandle* tc);

int navBakeGeometry(NavMeshHandle* mesh,
                    NavTileCacheHandle* tc,
                    const(float)* verts3,
                    int vertCount,
                    const(int)* tris3,
                    int triCount,
                    const(ubyte)* triAreasOrNull,
                    const(NavBakeConfig)* cfg);

int navBakeGeometryEx(NavMeshHandle* mesh,
                      NavTileCacheHandle* tc,
                      const(float)* verts3,
                      int vertCount,
                      const(int)* tris3,
                      int triCount,
                      const(ubyte)* triAreasOrNull,
                      const(NavBakeConfig)* cfg,
                      const(NavOffMeshConnectionC)* offMeshCons,
                      int offMeshConCount);

NavStatus navAddCylinderObstacle(NavTileCacheHandle* tc, const(float)* pos3,
                                 float radius, float height, NavObstacleRef* outRef);
NavStatus navAddBoxObstacle(NavTileCacheHandle* tc, const(float)* min3,
                            const(float)* max3, NavObstacleRef* outRef);
NavStatus navAddOrientedBoxObstacle(NavTileCacheHandle* tc, const(float)* center3,
                                    const(float)* halfExtents3, float yRadians,
                                    NavObstacleRef* outRef);
NavStatus navRemoveObstacle(NavTileCacheHandle* tc, NavObstacleRef obsRef);
NavStatus navTileCacheUpdate(NavTileCacheHandle* tc, NavMeshHandle* mesh, bool* outUpToDate);

bool navSaveMeshToBuffer(const(NavMeshHandle)* mesh, ubyte** outData, int* outSize);
void navFreeBuffer(void* ptr);
NavMeshHandle* navLoadMeshFromBuffer(const(ubyte)* data, int size);

int navExtractDebugTriangles(const(NavMeshHandle)* mesh, float* outVerts9,
                             ubyte* outAreas, int maxTris);

NavQueryHandle* navCreateQuery(const(NavMeshHandle)* mesh, int maxNodes);
void navDestroyQuery(NavQueryHandle* query);

NavStatus navFindNearestPoly(NavQueryHandle* query,
                             const(float)* center3,
                             const(float)* halfExtents3,
                             const(NavQueryFilterC)* filter,
                             NavPolyRef* outRef,
                             float* outNearest3);

NavStatus navFindPath(NavQueryHandle* query,
                      NavPolyRef startRef,
                      NavPolyRef endRef,
                      const(float)* startPos3,
                      const(float)* endPos3,
                      const(NavQueryFilterC)* filter,
                      NavPolyRef* outPolys,
                      int maxPolys,
                      int* outPolyCount);

NavStatus navFindStraightPath(NavQueryHandle* query,
                              const(float)* startPos3,
                              const(float)* endPos3,
                              const(NavPolyRef)* polys,
                              int polyCount,
                              float* outPoints3,
                              ubyte* outFlags,
                              NavPolyRef* outRefs,
                              int maxPoints,
                              int* outPointCount);

NavStatus navRaycast(NavQueryHandle* query,
                     NavPolyRef startRef,
                     const(float)* startPos3,
                     const(float)* endPos3,
                     const(NavQueryFilterC)* filter,
                     float* outT,
                     float* outNormal3,
                     bool* outHit);

NavCrowdHandle* navCreateCrowd(int maxAgents, float maxAgentRadius, NavMeshHandle* mesh);
void navDestroyCrowd(NavCrowdHandle* crowd);

int navCrowdAddAgent(NavCrowdHandle* crowd, const(float)* pos3, const(NavCrowdAgentParamsC)* params);
void navCrowdRemoveAgent(NavCrowdHandle* crowd, int idx);
bool navCrowdRequestMoveTarget(NavCrowdHandle* crowd, int idx, NavPolyRef targetRef, const(float)* targetPos3);
bool navCrowdRequestMoveVelocity(NavCrowdHandle* crowd, int idx, const(float)* vel3);
bool navCrowdResetMoveTarget(NavCrowdHandle* crowd, int idx);
void navCrowdUpdate(NavCrowdHandle* crowd, float dt);
bool navCrowdGetAgentState(const(NavCrowdHandle)* crowd, int idx,
                           float* outPos3, float* outVel3, ubyte* outState);
