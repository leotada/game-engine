#include "recast_shim.h"

#include "Recast.h"
#include "DetourNavMesh.h"
#include "DetourNavMeshBuilder.h"
#include "DetourNavMeshQuery.h"
#include "DetourTileCache.h"
#include "DetourTileCacheBuilder.h"
#include "DetourCrowd.h"
#include "DetourCommon.h"
#include "fastlz.h"

#include <cstdlib>
#include <cstring>
#include <cmath>

namespace {

static const uint8_t WALKABLE_AREA = RC_WALKABLE_AREA;
static const uint16_t POLYFLAGS_WALK = 0x01;
static const uint32_t NAVMESH_MAGIC = 0x4E41564Du; // 'NAVM'
static const uint32_t NAVMESH_VERSION = 1u;

struct FastLZCompressor final : public dtTileCacheCompressor {
    int maxCompressedSize(const int bufferSize) override {
        return static_cast<int>(bufferSize * 1.05f) + 64;
    }

    dtStatus compress(const unsigned char* buffer, const int bufferSize,
                      unsigned char* compressed, const int /*maxCompressedSize*/,
                      int* compressedSize) override {
        *compressedSize = fastlz_compress(buffer, bufferSize, compressed);
        return DT_SUCCESS;
    }

    dtStatus decompress(const unsigned char* compressed, const int compressedSize,
                        unsigned char* buffer, const int maxBufferSize,
                        int* bufferSize) override {
        *bufferSize = fastlz_decompress(compressed, compressedSize, buffer, maxBufferSize);
        return *bufferSize < 0 ? DT_FAILURE : DT_SUCCESS;
    }
};

struct LinearAllocator final : public dtTileCacheAlloc {
    unsigned char* buffer = nullptr;
    size_t capacity = 0;
    size_t top = 0;
    size_t high = 0;

    explicit LinearAllocator(size_t cap) { resize(cap); }
    ~LinearAllocator() override { dtFree(buffer); }

    void resize(size_t cap) {
        if (buffer) dtFree(buffer);
        buffer = static_cast<unsigned char*>(dtAlloc(cap, DT_ALLOC_PERM));
        capacity = buffer ? cap : 0;
        top = 0;
        high = 0;
    }

    void reset() override {
        high = dtMax(high, top);
        top = 0;
    }

    void* alloc(const size_t size) override {
        if (!buffer || top + size > capacity)
            return nullptr;
        unsigned char* mem = &buffer[top];
        top += size;
        return mem;
    }

    void free(void* /*ptr*/) override {}
};

struct DefaultMeshProcess final : public dtTileCacheMeshProcess {
    void process(dtNavMeshCreateParams* params, unsigned char* polyAreas, unsigned short* polyFlags) override {
        for (int i = 0; i < params->polyCount; ++i) {
            if (polyAreas[i] == DT_TILECACHE_WALKABLE_AREA)
                polyAreas[i] = 0;
            polyFlags[i] = POLYFLAGS_WALK;
        }
    }
};

struct TileCacheMeshData {
    static const int MAX_LAYERS = 32;
    struct TileCacheData {
        unsigned char* data = nullptr;
        int dataSize = 0;
    };
    TileCacheData tiles[MAX_LAYERS];
    int tileCount = 0;
};

static void toDtFilter(const NavQueryFilterC* src, dtQueryFilter& dst) {
    if (!src) {
        dst.setIncludeFlags(0xFFFF);
        dst.setExcludeFlags(0);
        return;
    }
    dst.setIncludeFlags(src->includeFlags);
    dst.setExcludeFlags(src->excludeFlags);
    for (int i = 0; i < 64; ++i) {
        dst.setAreaCost(i, src->areaCosts[i]);
    }
}

static bool filterTrianglesForTile(const float* verts3, const int* tris3, int triCount,
                                   const uint8_t* triAreasOrNull,
                                   const float* bmin, const float* bmax,
                                   float walkableSlopeDeg,
                                   rcContext& ctx, rcHeightfield& hf) {
    const int batchSize = 512;
    unsigned char areas[batchSize];
    for (int i = 0; i < triCount; i += batchSize) {
        const int n = dtMin(batchSize, triCount - i);
        if (triAreasOrNull) {
            for (int j = 0; j < n; ++j)
                areas[j] = triAreasOrNull[i + j];
        } else {
            memset(areas, 0, static_cast<size_t>(n));
            rcMarkWalkableTriangles(&ctx, walkableSlopeDeg, verts3, 0,
                                    tris3 + i * 3, n, areas);
        }
        if (!rcRasterizeTriangles(&ctx, verts3, 0, tris3 + i * 3, areas, n, hf, 1))
            return false;
    }
    return true;
}

} // namespace

struct NavMeshHandle {
    dtNavMesh* nav = nullptr;
};

struct NavTileCacheHandle {
    dtTileCache* tc = nullptr;
    LinearAllocator* alloc = nullptr;
    FastLZCompressor* comp = nullptr;
    DefaultMeshProcess* proc = nullptr;
};

struct NavQueryHandle {
    dtNavMeshQuery* query = nullptr;
};

struct NavCrowdHandle {
    dtCrowd* crowd = nullptr;
};

extern "C" {

NavBakeConfig navDefaultBakeConfig(void) {
    NavBakeConfig cfg{};
    cfg.cellSize = 0.3f;
    cfg.cellHeight = 0.2f;
    cfg.agentHeight = 1.8f;
    cfg.agentRadius = 0.35f;
    cfg.agentMaxClimb = 0.45f;
    cfg.agentMaxSlopeDeg = 45.0f;
    cfg.tileSize = 64;
    cfg.regionMinSize = 8;
    cfg.regionMergeSize = 20;
    cfg.edgeMaxLen = 12.0f;
    cfg.edgeMaxError = 1.3f;
    cfg.vertsPerPoly = 6;
    cfg.detailSampleDist = 6.0f;
    cfg.detailSampleMaxError = 1.0f;
    cfg.maxTiles = 1024;
    cfg.maxPolysPerTile = 2048;
    cfg.maxLayersPerTile = 16;
    cfg.maxObstacles = 256;
    return cfg;
}

NavQueryFilterC navDefaultQueryFilter(void) {
    NavQueryFilterC f{};
    f.includeFlags = 0xFFFF;
    f.excludeFlags = 0;
    for (int i = 0; i < 64; ++i) f.areaCosts[i] = 1.0f;
    return f;
}

NavCrowdAgentParamsC navDefaultCrowdAgentParams(void) {
    NavCrowdAgentParamsC p{};
    p.radius = 0.35f;
    p.height = 1.8f;
    p.maxAcceleration = 12.0f;
    p.maxSpeed = 5.5f;
    p.collisionQueryRange = 0.35f * 12.0f;
    p.pathOptimizationRange = 0.35f * 30.0f;
    p.separationWeight = 2.0f;
    p.updateFlags = DT_CROWD_ANTICIPATE_TURNS | DT_CROWD_OPTIMIZE_VIS | DT_CROWD_OBSTACLE_AVOIDANCE | DT_CROWD_SEPARATION;
    p.obstacleAvoidanceType = 3;
    p.queryFilterType = 0;
    return p;
}

NavMeshHandle* navCreateTiledMesh(float originX, float originY, float originZ,
                                  float tileWidth, float tileHeight,
                                  int maxTiles, int maxPolysPerTile) {
    dtNavMesh* nav = dtAllocNavMesh();
    if (!nav) return nullptr;

    dtNavMeshParams params{};
    params.orig[0] = originX;
    params.orig[1] = originY;
    params.orig[2] = originZ;
    params.tileWidth = tileWidth;
    params.tileHeight = tileHeight;
    params.maxTiles = maxTiles > 0 ? maxTiles : 1024;
    params.maxPolys = maxPolysPerTile > 0 ? maxPolysPerTile : 2048;

    if (dtStatusFailed(nav->init(&params))) {
        dtFreeNavMesh(nav);
        return nullptr;
    }

    auto* h = static_cast<NavMeshHandle*>(std::calloc(1, sizeof(NavMeshHandle)));
    if (!h) {
        dtFreeNavMesh(nav);
        return nullptr;
    }
    h->nav = nav;
    return h;
}

void navDestroyMesh(NavMeshHandle* mesh) {
    if (!mesh) return;
    if (mesh->nav) dtFreeNavMesh(mesh->nav);
    std::free(mesh);
}

NavTileCacheHandle* navCreateTileCache(NavMeshHandle* /*mesh*/,
                                       float originX, float originY, float originZ,
                                       float tileWidth, float tileHeight,
                                       const NavBakeConfig* cfg) {
    if (!cfg) return nullptr;
    dtTileCache* tc = dtAllocTileCache();
    if (!tc) return nullptr;

    auto* alloc = new LinearAllocator(64 * 1024);
    auto* comp = new FastLZCompressor();
    auto* proc = new DefaultMeshProcess();

    dtTileCacheParams tcParams{};
    tcParams.orig[0] = originX;
    tcParams.orig[1] = originY;
    tcParams.orig[2] = originZ;
    tcParams.cs = cfg->cellSize;
    tcParams.ch = cfg->cellHeight;
    tcParams.width = cfg->tileSize;
    tcParams.height = cfg->tileSize;
    tcParams.walkableHeight = cfg->agentHeight;
    tcParams.walkableRadius = cfg->agentRadius;
    tcParams.walkableClimb = cfg->agentMaxClimb;
    tcParams.maxSimplificationError = cfg->edgeMaxError;
    tcParams.maxTiles = (cfg->maxTiles > 0 ? cfg->maxTiles : 1024) * (cfg->maxLayersPerTile > 0 ? cfg->maxLayersPerTile : 4);
    tcParams.maxObstacles = cfg->maxObstacles > 0 ? cfg->maxObstacles : 256;

    if (dtStatusFailed(tc->init(&tcParams, alloc, comp, proc))) {
        dtFreeTileCache(tc);
        delete alloc;
        delete comp;
        delete proc;
        return nullptr;
    }

    auto* h = static_cast<NavTileCacheHandle*>(std::calloc(1, sizeof(NavTileCacheHandle)));
    if (!h) {
        dtFreeTileCache(tc);
        delete alloc;
        delete comp;
        delete proc;
        return nullptr;
    }
    h->tc = tc;
    h->alloc = alloc;
    h->comp = comp;
    h->proc = proc;
    return h;
}

void navDestroyTileCache(NavTileCacheHandle* tc) {
    if (!tc) return;
    if (tc->tc) dtFreeTileCache(tc->tc);
    delete tc->alloc;
    delete tc->comp;
    delete tc->proc;
    std::free(tc);
}

static int bakeTileWithTileCache(NavMeshHandle* mesh, NavTileCacheHandle* tc,
                                 int tx, int ty,
                                 const float* tileBmin, const float* tileBmax,
                                 const float* verts3, int vertCount,
                                 const int* tris3, int triCount,
                                 const uint8_t* triAreasOrNull,
                                 const NavBakeConfig& cfg) {
    rcContext ctx;
    const float borderSize = static_cast<float>(static_cast<int>(ceilf(cfg.agentRadius / cfg.cellSize)) + 3);
    const float borderWorld = borderSize * cfg.cellSize;

    rcConfig rcfg{};
    rcfg.cs = cfg.cellSize;
    rcfg.ch = cfg.cellHeight;
    rcfg.walkableSlopeAngle = cfg.agentMaxSlopeDeg;
    rcfg.walkableHeight = static_cast<int>(ceilf(cfg.agentHeight / cfg.cellHeight));
    rcfg.walkableClimb = static_cast<int>(floorf(cfg.agentMaxClimb / cfg.cellHeight));
    rcfg.walkableRadius = static_cast<int>(ceilf(cfg.agentRadius / cfg.cellSize));
    rcfg.maxEdgeLen = static_cast<int>(cfg.edgeMaxLen / cfg.cellSize);
    rcfg.maxSimplificationError = cfg.edgeMaxError;
    rcfg.minRegionArea = cfg.regionMinSize * cfg.regionMinSize;
    rcfg.mergeRegionArea = cfg.regionMergeSize * cfg.regionMergeSize;
    rcfg.maxVertsPerPoly = cfg.vertsPerPoly;
    rcfg.tileSize = cfg.tileSize;
    rcfg.borderSize = static_cast<int>(borderSize);
    rcfg.width = cfg.tileSize + rcfg.borderSize * 2;
    rcfg.height = cfg.tileSize + rcfg.borderSize * 2;
    rcfg.detailSampleDist = cfg.detailSampleDist < 0.9f ? 0 : cfg.cellSize * cfg.detailSampleDist;
    rcfg.detailSampleMaxError = cfg.cellHeight * cfg.detailSampleMaxError;

    rcVcopy(rcfg.bmin, tileBmin);
    rcVcopy(rcfg.bmax, tileBmax);
    rcfg.bmin[0] -= borderWorld;
    rcfg.bmin[2] -= borderWorld;
    rcfg.bmax[0] += borderWorld;
    rcfg.bmax[2] += borderWorld;

    rcHeightfield* solid = rcAllocHeightfield();
    if (!solid || !rcCreateHeightfield(&ctx, *solid, rcfg.width, rcfg.height, rcfg.bmin, rcfg.bmax, rcfg.cs, rcfg.ch)) {
        rcFreeHeightField(solid);
        return 0;
    }

    if (!filterTrianglesForTile(verts3, tris3, triCount, triAreasOrNull, rcfg.bmin, rcfg.bmax,
                                rcfg.walkableSlopeAngle, ctx, *solid)) {
        rcFreeHeightField(solid);
        return 0;
    }
    (void)vertCount;

    rcFilterLowHangingWalkableObstacles(&ctx, rcfg.walkableClimb, *solid);
    rcFilterLedgeSpans(&ctx, rcfg.walkableHeight, rcfg.walkableClimb, *solid);
    rcFilterWalkableLowHeightSpans(&ctx, rcfg.walkableHeight, *solid);

    rcCompactHeightfield* chf = rcAllocCompactHeightfield();
    if (!chf || !rcBuildCompactHeightfield(&ctx, rcfg.walkableHeight, rcfg.walkableClimb, *solid, *chf)) {
        rcFreeHeightField(solid);
        rcFreeCompactHeightfield(chf);
        return 0;
    }
    rcFreeHeightField(solid);

    if (!rcErodeWalkableArea(&ctx, rcfg.walkableRadius, *chf)) {
        rcFreeCompactHeightfield(chf);
        return 0;
    }

    rcHeightfieldLayerSet* lset = rcAllocHeightfieldLayerSet();
    if (!lset || !rcBuildHeightfieldLayers(&ctx, *chf, rcfg.borderSize, rcfg.walkableHeight, *lset)) {
        rcFreeCompactHeightfield(chf);
        rcFreeHeightfieldLayerSet(lset);
        return 0;
    }
    rcFreeCompactHeightfield(chf);

    int added = 0;
    for (int i = 0; i < lset->nlayers && i < TileCacheMeshData::MAX_LAYERS; ++i) {
        const rcHeightfieldLayer* layer = &lset->layers[i];
        dtTileCacheLayerHeader header{};
        header.magic = DT_TILECACHE_MAGIC;
        header.version = DT_TILECACHE_VERSION;
        header.tx = tx;
        header.ty = ty;
        header.tlayer = i;
        dtVcopy(header.bmin, layer->bmin);
        dtVcopy(header.bmax, layer->bmax);
        header.width = static_cast<unsigned char>(layer->width);
        header.height = static_cast<unsigned char>(layer->height);
        header.minx = static_cast<unsigned char>(layer->minx);
        header.maxx = static_cast<unsigned char>(layer->maxx);
        header.miny = static_cast<unsigned char>(layer->miny);
        header.maxy = static_cast<unsigned char>(layer->maxy);
        header.hmin = static_cast<unsigned short>(layer->hmin);
        header.hmax = static_cast<unsigned short>(layer->hmax);

        unsigned char* tileData = nullptr;
        int tileDataSize = 0;
        if (dtStatusSucceed(dtBuildTileCacheLayer(tc->comp, &header, layer->heights, layer->areas, layer->cons,
                                                  &tileData, &tileDataSize))) {
            dtCompressedTileRef tcRef = 0;
            if (dtStatusSucceed(tc->tc->addTile(tileData, tileDataSize, DT_COMPRESSEDTILE_FREE_DATA, &tcRef))) {
                tc->tc->buildNavMeshTile(tcRef, mesh->nav);
                added++;
            } else {
                dtFree(tileData);
            }
        }
    }

    rcFreeHeightfieldLayerSet(lset);
    return added;
}

static int bakeTileDirect(NavMeshHandle* mesh,
                          int tx, int ty,
                          const float* tileBmin, const float* tileBmax,
                          const float* verts3, int /*vertCount*/,
                          const int* tris3, int triCount,
                          const uint8_t* triAreasOrNull,
                          const NavBakeConfig& cfg) {
    rcContext ctx;
    const float borderSize = static_cast<float>(static_cast<int>(ceilf(cfg.agentRadius / cfg.cellSize)) + 3);
    const float borderWorld = borderSize * cfg.cellSize;

    rcConfig rcfg{};
    rcfg.cs = cfg.cellSize;
    rcfg.ch = cfg.cellHeight;
    rcfg.walkableSlopeAngle = cfg.agentMaxSlopeDeg;
    rcfg.walkableHeight = static_cast<int>(ceilf(cfg.agentHeight / cfg.cellHeight));
    rcfg.walkableClimb = static_cast<int>(floorf(cfg.agentMaxClimb / cfg.cellHeight));
    rcfg.walkableRadius = static_cast<int>(ceilf(cfg.agentRadius / cfg.cellSize));
    rcfg.maxEdgeLen = static_cast<int>(cfg.edgeMaxLen / cfg.cellSize);
    rcfg.maxSimplificationError = cfg.edgeMaxError;
    rcfg.minRegionArea = cfg.regionMinSize * cfg.regionMinSize;
    rcfg.mergeRegionArea = cfg.regionMergeSize * cfg.regionMergeSize;
    rcfg.maxVertsPerPoly = cfg.vertsPerPoly;
    rcfg.tileSize = cfg.tileSize;
    rcfg.borderSize = static_cast<int>(borderSize);
    rcfg.width = cfg.tileSize + rcfg.borderSize * 2;
    rcfg.height = cfg.tileSize + rcfg.borderSize * 2;
    rcfg.detailSampleDist = cfg.detailSampleDist < 0.9f ? 0 : cfg.cellSize * cfg.detailSampleDist;
    rcfg.detailSampleMaxError = cfg.cellHeight * cfg.detailSampleMaxError;

    rcVcopy(rcfg.bmin, tileBmin);
    rcVcopy(rcfg.bmax, tileBmax);
    rcfg.bmin[0] -= borderWorld;
    rcfg.bmin[2] -= borderWorld;
    rcfg.bmax[0] += borderWorld;
    rcfg.bmax[2] += borderWorld;

    rcHeightfield* solid = rcAllocHeightfield();
    if (!solid || !rcCreateHeightfield(&ctx, *solid, rcfg.width, rcfg.height, rcfg.bmin, rcfg.bmax, rcfg.cs, rcfg.ch)) {
        rcFreeHeightField(solid);
        return 0;
    }

    if (!filterTrianglesForTile(verts3, tris3, triCount, triAreasOrNull, rcfg.bmin, rcfg.bmax,
                                rcfg.walkableSlopeAngle, ctx, *solid)) {
        rcFreeHeightField(solid);
        return 0;
    }

    rcFilterLowHangingWalkableObstacles(&ctx, rcfg.walkableClimb, *solid);
    rcFilterLedgeSpans(&ctx, rcfg.walkableHeight, rcfg.walkableClimb, *solid);
    rcFilterWalkableLowHeightSpans(&ctx, rcfg.walkableHeight, *solid);

    rcCompactHeightfield* chf = rcAllocCompactHeightfield();
    if (!chf || !rcBuildCompactHeightfield(&ctx, rcfg.walkableHeight, rcfg.walkableClimb, *solid, *chf)) {
        rcFreeHeightField(solid);
        rcFreeCompactHeightfield(chf);
        return 0;
    }
    rcFreeHeightField(solid);

    if (!rcErodeWalkableArea(&ctx, rcfg.walkableRadius, *chf)) {
        rcFreeCompactHeightfield(chf);
        return 0;
    }
    if (!rcBuildDistanceField(&ctx, *chf) || !rcBuildRegions(&ctx, *chf, rcfg.borderSize, rcfg.minRegionArea, rcfg.mergeRegionArea)) {
        rcFreeCompactHeightfield(chf);
        return 0;
    }

    rcContourSet* cset = rcAllocContourSet();
    if (!cset || !rcBuildContours(&ctx, *chf, rcfg.maxSimplificationError, rcfg.maxEdgeLen, *cset)) {
        rcFreeCompactHeightfield(chf);
        rcFreeContourSet(cset);
        return 0;
    }

    rcPolyMesh* pmesh = rcAllocPolyMesh();
    if (!pmesh || !rcBuildPolyMesh(&ctx, *cset, rcfg.maxVertsPerPoly, *pmesh)) {
        rcFreeCompactHeightfield(chf);
        rcFreeContourSet(cset);
        rcFreePolyMesh(pmesh);
        return 0;
    }

    rcPolyMeshDetail* dmesh = rcAllocPolyMeshDetail();
    if (!dmesh || !rcBuildPolyMeshDetail(&ctx, *pmesh, *chf, rcfg.detailSampleDist, rcfg.detailSampleMaxError, *dmesh)) {
        rcFreeCompactHeightfield(chf);
        rcFreeContourSet(cset);
        rcFreePolyMesh(pmesh);
        rcFreePolyMeshDetail(dmesh);
        return 0;
    }

    rcFreeCompactHeightfield(chf);
    rcFreeContourSet(cset);

    for (int i = 0; i < pmesh->npolys; ++i) {
        if (pmesh->areas[i] == RC_WALKABLE_AREA)
            pmesh->areas[i] = 0;
        pmesh->flags[i] = POLYFLAGS_WALK;
    }

    dtNavMeshCreateParams params{};
    params.verts = pmesh->verts;
    params.vertCount = pmesh->nverts;
    params.polys = pmesh->polys;
    params.polyAreas = pmesh->areas;
    params.polyFlags = pmesh->flags;
    params.polyCount = pmesh->npolys;
    params.nvp = pmesh->nvp;
    params.detailMeshes = dmesh->meshes;
    params.detailVerts = dmesh->verts;
    params.detailVertsCount = dmesh->nverts;
    params.detailTris = dmesh->tris;
    params.detailTriCount = dmesh->ntris;
    params.walkableHeight = cfg.agentHeight;
    params.walkableRadius = cfg.agentRadius;
    params.walkableClimb = cfg.agentMaxClimb;
    params.tileX = tx;
    params.tileY = ty;
    params.tileLayer = 0;
    rcVcopy(params.bmin, pmesh->bmin);
    rcVcopy(params.bmax, pmesh->bmax);
    params.cs = rcfg.cs;
    params.ch = rcfg.ch;
    params.buildBvTree = true;

    unsigned char* navData = nullptr;
    int navDataSize = 0;
    int result = 0;
    if (dtCreateNavMeshData(&params, &navData, &navDataSize)) {
        mesh->nav->removeTile(mesh->nav->getTileRefAt(tx, ty, 0), nullptr, nullptr);
        if (dtStatusSucceed(mesh->nav->addTile(navData, navDataSize, DT_TILE_FREE_DATA, 0, nullptr))) {
            result = 1;
        } else {
            dtFree(navData);
        }
    }

    rcFreePolyMesh(pmesh);
    rcFreePolyMeshDetail(dmesh);
    return result;
}

int navBakeGeometry(NavMeshHandle* mesh,
                    NavTileCacheHandle* tc,
                    const float* verts3,
                    int vertCount,
                    const int* tris3,
                    int triCount,
                    const uint8_t* triAreasOrNull,
                    const NavBakeConfig* cfg) {
    if (!mesh || !mesh->nav || !verts3 || !tris3 || vertCount <= 0 || triCount <= 0 || !cfg)
        return 0;

    float bmin[3] = { verts3[0], verts3[1], verts3[2] };
    float bmax[3] = { verts3[0], verts3[1], verts3[2] };
    for (int i = 1; i < vertCount; ++i) {
        const float* v = &verts3[i * 3];
        if (v[0] < bmin[0]) bmin[0] = v[0];
        if (v[1] < bmin[1]) bmin[1] = v[1];
        if (v[2] < bmin[2]) bmin[2] = v[2];
        if (v[0] > bmax[0]) bmax[0] = v[0];
        if (v[1] > bmax[1]) bmax[1] = v[1];
        if (v[2] > bmax[2]) bmax[2] = v[2];
    }

    const dtNavMeshParams* np = mesh->nav->getParams();
    const float tw = np->tileWidth;
    const float th = np->tileHeight;
    if (tw <= 0.0f || th <= 0.0f) return 0;

    const int tx0 = static_cast<int>(floorf((bmin[0] - np->orig[0]) / tw));
    const int ty0 = static_cast<int>(floorf((bmin[2] - np->orig[2]) / th));
    const int tx1 = static_cast<int>(floorf((bmax[0] - np->orig[0]) / tw));
    const int ty1 = static_cast<int>(floorf((bmax[2] - np->orig[2]) / th));

    int totalBuilt = 0;
    for (int ty = ty0; ty <= ty1; ++ty) {
        for (int tx = tx0; tx <= tx1; ++tx) {
            float tbmin[3] = { np->orig[0] + tx * tw, bmin[1] - 1.0f, np->orig[2] + ty * th };
            float tbmax[3] = { np->orig[0] + (tx + 1) * tw, bmax[1] + 1.0f, np->orig[2] + (ty + 1) * th };
            if (tc && tc->tc) {
                totalBuilt += bakeTileWithTileCache(mesh, tc, tx, ty, tbmin, tbmax,
                                                    verts3, vertCount, tris3, triCount, triAreasOrNull, *cfg);
            } else {
                totalBuilt += bakeTileDirect(mesh, tx, ty, tbmin, tbmax,
                                             verts3, vertCount, tris3, triCount, triAreasOrNull, *cfg);
            }
        }
    }
    return totalBuilt;
}

NavStatus navAddCylinderObstacle(NavTileCacheHandle* tc, const float* pos3,
                                 float radius, float height, NavObstacleRef* outRef) {
    if (!tc || !tc->tc || !pos3 || !outRef) return DT_FAILURE;
    dtObstacleRef r = 0;
    dtStatus st = tc->tc->addObstacle(pos3, radius, height, &r);
    *outRef = static_cast<NavObstacleRef>(r);
    return st;
}

NavStatus navAddBoxObstacle(NavTileCacheHandle* tc, const float* min3,
                            const float* max3, NavObstacleRef* outRef) {
    if (!tc || !tc->tc || !min3 || !max3 || !outRef) return DT_FAILURE;
    dtObstacleRef r = 0;
    dtStatus st = tc->tc->addBoxObstacle(min3, max3, &r);
    *outRef = static_cast<NavObstacleRef>(r);
    return st;
}

NavStatus navAddOrientedBoxObstacle(NavTileCacheHandle* tc, const float* center3,
                                    const float* halfExtents3, float yRadians,
                                    NavObstacleRef* outRef) {
    if (!tc || !tc->tc || !center3 || !halfExtents3 || !outRef) return DT_FAILURE;
    dtObstacleRef r = 0;
    dtStatus st = tc->tc->addBoxObstacle(center3, halfExtents3, yRadians, &r);
    *outRef = static_cast<NavObstacleRef>(r);
    return st;
}

NavStatus navRemoveObstacle(NavTileCacheHandle* tc, NavObstacleRef ref) {
    if (!tc || !tc->tc) return DT_FAILURE;
    return tc->tc->removeObstacle(static_cast<dtObstacleRef>(ref));
}

NavStatus navTileCacheUpdate(NavTileCacheHandle* tc, NavMeshHandle* mesh, bool* outUpToDate) {
    if (!tc || !tc->tc || !mesh || !mesh->nav) return DT_FAILURE;
    bool upToDate = false;
    dtStatus st = tc->tc->update(0.0f, mesh->nav, &upToDate);
    if (outUpToDate) *outUpToDate = upToDate;
    return st;
}

bool navSaveMeshToBuffer(const NavMeshHandle* mesh, uint8_t** outData, int* outSize) {
    if (!mesh || !mesh->nav || !outData || !outSize) return false;
    const dtNavMesh* nav = mesh->nav;

    int tileCount = 0;
    size_t totalBytes = sizeof(uint32_t) * 2 + sizeof(dtNavMeshParams) + sizeof(int32_t);
    for (int i = 0; i < nav->getMaxTiles(); ++i) {
        const dtMeshTile* tile = nav->getTile(i);
        if (!tile || !tile->header || !tile->dataSize) continue;
        tileCount++;
        totalBytes += sizeof(uint64_t) + sizeof(int32_t) + static_cast<size_t>(tile->dataSize);
    }

    auto* buf = static_cast<uint8_t*>(std::malloc(totalBytes));
    if (!buf) return false;

    size_t off = 0;
    auto writeBytes = [&](const void* src, size_t n) {
        std::memcpy(buf + off, src, n);
        off += n;
    };

    writeBytes(&NAVMESH_MAGIC, sizeof(uint32_t));
    writeBytes(&NAVMESH_VERSION, sizeof(uint32_t));
    writeBytes(nav->getParams(), sizeof(dtNavMeshParams));
    writeBytes(&tileCount, sizeof(int32_t));

    for (int i = 0; i < nav->getMaxTiles(); ++i) {
        const dtMeshTile* tile = nav->getTile(i);
        if (!tile || !tile->header || !tile->dataSize) continue;
        uint64_t ref = static_cast<uint64_t>(nav->getTileRef(tile));
        int32_t sz = tile->dataSize;
        writeBytes(&ref, sizeof(uint64_t));
        writeBytes(&sz, sizeof(int32_t));
        writeBytes(tile->data, static_cast<size_t>(sz));
    }

    *outData = buf;
    *outSize = static_cast<int>(off);
    return true;
}

void navFreeBuffer(void* ptr) {
    std::free(ptr);
}

NavMeshHandle* navLoadMeshFromBuffer(const uint8_t* data, int size) {
    if (!data || size < static_cast<int>(sizeof(uint32_t) * 2 + sizeof(dtNavMeshParams) + sizeof(int32_t)))
        return nullptr;

    size_t off = 0;
    auto readBytes = [&](void* dst, size_t n) -> bool {
        if (off + n > static_cast<size_t>(size)) return false;
        std::memcpy(dst, data + off, n);
        off += n;
        return true;
    };

    uint32_t magic = 0, ver = 0;
    dtNavMeshParams params{};
    int32_t tileCount = 0;
    if (!readBytes(&magic, sizeof(magic)) || !readBytes(&ver, sizeof(ver))) return nullptr;
    if (magic != NAVMESH_MAGIC || ver != NAVMESH_VERSION) return nullptr;
    if (!readBytes(&params, sizeof(params)) || !readBytes(&tileCount, sizeof(tileCount))) return nullptr;

    dtNavMesh* nav = dtAllocNavMesh();
    if (!nav || dtStatusFailed(nav->init(&params))) {
        dtFreeNavMesh(nav);
        return nullptr;
    }

    for (int32_t i = 0; i < tileCount; ++i) {
        uint64_t tileRef = 0;
        int32_t tileSize = 0;
        if (!readBytes(&tileRef, sizeof(tileRef)) || !readBytes(&tileSize, sizeof(tileSize)) || tileSize <= 0) {
            dtFreeNavMesh(nav);
            return nullptr;
        }
        auto* tileData = static_cast<unsigned char*>(dtAlloc(static_cast<size_t>(tileSize), DT_ALLOC_PERM));
        if (!tileData || !readBytes(tileData, static_cast<size_t>(tileSize))) {
            dtFree(tileData);
            dtFreeNavMesh(nav);
            return nullptr;
        }
        if (dtStatusFailed(nav->addTile(tileData, tileSize, DT_TILE_FREE_DATA,
                                        static_cast<dtTileRef>(tileRef), nullptr))) {
            dtFree(tileData);
            dtFreeNavMesh(nav);
            return nullptr;
        }
    }

    auto* h = static_cast<NavMeshHandle*>(std::calloc(1, sizeof(NavMeshHandle)));
    if (!h) {
        dtFreeNavMesh(nav);
        return nullptr;
    }
    h->nav = nav;
    return h;
}

int navExtractDebugTriangles(const NavMeshHandle* mesh, float* outVerts9,
                             uint8_t* outAreas, int maxTris) {
    if (!mesh || !mesh->nav || !outVerts9 || maxTris <= 0) return 0;
    const dtNavMesh* nav = mesh->nav;
    int triOut = 0;

    for (int ti = 0; ti < nav->getMaxTiles() && triOut < maxTris; ++ti) {
        const dtMeshTile* tile = nav->getTile(ti);
        if (!tile || !tile->header) continue;
        for (int pi = 0; pi < tile->header->polyCount && triOut < maxTris; ++pi) {
            const dtPoly* poly = &tile->polys[pi];
            if (poly->getType() == DT_POLYTYPE_OFFMESH_CONNECTION) continue;
            const dtPolyDetail* pd = &tile->detailMeshes[pi];
            for (int j = 0; j < pd->triCount && triOut < maxTris; ++j) {
                const unsigned char* t = &tile->detailTris[(pd->triBase + j) * 4];
                float* dst = outVerts9 + triOut * 9;
                for (int k = 0; k < 3; ++k) {
                    const float* v = (t[k] < poly->vertCount)
                        ? &tile->verts[poly->verts[t[k]] * 3]
                        : &tile->detailVerts[(pd->vertBase + t[k] - poly->vertCount) * 3];
                    dst[k * 3 + 0] = v[0];
                    dst[k * 3 + 1] = v[1];
                    dst[k * 3 + 2] = v[2];
                }
                if (outAreas) outAreas[triOut] = poly->getArea();
                triOut++;
            }
        }
    }
    return triOut;
}

NavQueryHandle* navCreateQuery(const NavMeshHandle* mesh, int maxNodes) {
    if (!mesh || !mesh->nav) return nullptr;
    dtNavMeshQuery* q = dtAllocNavMeshQuery();
    if (!q || dtStatusFailed(q->init(mesh->nav, maxNodes > 0 ? maxNodes : 2048))) {
        dtFreeNavMeshQuery(q);
        return nullptr;
    }
    auto* h = static_cast<NavQueryHandle*>(std::calloc(1, sizeof(NavQueryHandle)));
    if (!h) {
        dtFreeNavMeshQuery(q);
        return nullptr;
    }
    h->query = q;
    return h;
}

void navDestroyQuery(NavQueryHandle* query) {
    if (!query) return;
    if (query->query) dtFreeNavMeshQuery(query->query);
    std::free(query);
}

NavStatus navFindNearestPoly(NavQueryHandle* query,
                             const float* center3,
                             const float* halfExtents3,
                             const NavQueryFilterC* filter,
                             NavPolyRef* outRef,
                             float* outNearest3) {
    if (!query || !query->query || !center3 || !halfExtents3 || !outRef) return DT_FAILURE;
    dtQueryFilter f;
    toDtFilter(filter, f);
    dtPolyRef r = 0;
    float pt[3]{};
    dtStatus st = query->query->findNearestPoly(center3, halfExtents3, &f, &r, pt);
    *outRef = static_cast<NavPolyRef>(r);
    if (outNearest3) dtVcopy(outNearest3, pt);
    return st;
}

NavStatus navFindPath(NavQueryHandle* query,
                      NavPolyRef startRef,
                      NavPolyRef endRef,
                      const float* startPos3,
                      const float* endPos3,
                      const NavQueryFilterC* filter,
                      NavPolyRef* outPolys,
                      int maxPolys,
                      int* outPolyCount) {
    if (!query || !query->query || !startPos3 || !endPos3 || !outPolys || !outPolyCount)
        return DT_FAILURE;
    dtQueryFilter f;
    toDtFilter(filter, f);
    int count = 0;
    dtStatus st = query->query->findPath(static_cast<dtPolyRef>(startRef),
                                         static_cast<dtPolyRef>(endRef),
                                         startPos3, endPos3, &f,
                                         reinterpret_cast<dtPolyRef*>(outPolys),
                                         &count, maxPolys);
    *outPolyCount = count;
    return st;
}

NavStatus navFindStraightPath(NavQueryHandle* query,
                              const float* startPos3,
                              const float* endPos3,
                              const NavPolyRef* polys,
                              int polyCount,
                              float* outPoints3,
                              uint8_t* outFlags,
                              NavPolyRef* outRefs,
                              int maxPoints,
                              int* outPointCount) {
    if (!query || !query->query || !startPos3 || !endPos3 || !polys || !outPoints3 || !outPointCount)
        return DT_FAILURE;
    int count = 0;
    dtStatus st = query->query->findStraightPath(startPos3, endPos3,
                                                 reinterpret_cast<const dtPolyRef*>(polys), polyCount,
                                                 outPoints3, outFlags,
                                                 reinterpret_cast<dtPolyRef*>(outRefs),
                                                 &count, maxPoints, 0);
    *outPointCount = count;
    return st;
}

NavStatus navRaycast(NavQueryHandle* query,
                     NavPolyRef startRef,
                     const float* startPos3,
                     const float* endPos3,
                     const NavQueryFilterC* filter,
                     float* outT,
                     float* outNormal3,
                     bool* outHit) {
    if (!query || !query->query || !startPos3 || !endPos3) return DT_FAILURE;
    dtQueryFilter f;
    toDtFilter(filter, f);
    float t = 0.0f;
    float norm[3]{};
    dtStatus st = query->query->raycast(static_cast<dtPolyRef>(startRef), startPos3, endPos3, &f,
                                        &t, norm, nullptr, nullptr, 0);
    if (outT) *outT = t;
    if (outNormal3) dtVcopy(outNormal3, norm);
    if (outHit) *outHit = (t < 1.0f);
    return st;
}

NavCrowdHandle* navCreateCrowd(int maxAgents, float maxAgentRadius, NavMeshHandle* mesh) {
    if (!mesh || !mesh->nav) return nullptr;
    dtCrowd* c = dtAllocCrowd();
    if (!c || !c->init(maxAgents > 0 ? maxAgents : 64, maxAgentRadius, mesh->nav)) {
        dtFreeCrowd(c);
        return nullptr;
    }
    dtObstacleAvoidanceParams params{};
    std::memcpy(&params, c->getObstacleAvoidanceParams(0), sizeof(dtObstacleAvoidanceParams));
    params.velBias = 0.5f;
    params.adaptiveDivs = 5;
    params.adaptiveRings = 2;
    params.adaptiveDepth = 2;
    c->setObstacleAvoidanceParams(3, &params);

    auto* h = static_cast<NavCrowdHandle*>(std::calloc(1, sizeof(NavCrowdHandle)));
    if (!h) {
        dtFreeCrowd(c);
        return nullptr;
    }
    h->crowd = c;
    return h;
}

void navDestroyCrowd(NavCrowdHandle* crowd) {
    if (!crowd) return;
    if (crowd->crowd) dtFreeCrowd(crowd->crowd);
    std::free(crowd);
}

int navCrowdAddAgent(NavCrowdHandle* crowd, const float* pos3, const NavCrowdAgentParamsC* params) {
    if (!crowd || !crowd->crowd || !pos3 || !params) return -1;
    dtCrowdAgentParams ap{};
    ap.radius = params->radius;
    ap.height = params->height;
    ap.maxAcceleration = params->maxAcceleration;
    ap.maxSpeed = params->maxSpeed;
    ap.collisionQueryRange = params->collisionQueryRange;
    ap.pathOptimizationRange = params->pathOptimizationRange;
    ap.separationWeight = params->separationWeight;
    ap.updateFlags = params->updateFlags;
    ap.obstacleAvoidanceType = params->obstacleAvoidanceType;
    ap.queryFilterType = params->queryFilterType;
    return crowd->crowd->addAgent(pos3, &ap);
}

void navCrowdRemoveAgent(NavCrowdHandle* crowd, int idx) {
    if (!crowd || !crowd->crowd || idx < 0) return;
    crowd->crowd->removeAgent(idx);
}

bool navCrowdRequestMoveTarget(NavCrowdHandle* crowd, int idx, NavPolyRef targetRef, const float* targetPos3) {
    if (!crowd || !crowd->crowd || idx < 0 || !targetPos3) return false;
    return crowd->crowd->requestMoveTarget(idx, static_cast<dtPolyRef>(targetRef), targetPos3);
}

bool navCrowdRequestMoveVelocity(NavCrowdHandle* crowd, int idx, const float* vel3) {
    if (!crowd || !crowd->crowd || idx < 0 || !vel3) return false;
    return crowd->crowd->requestMoveVelocity(idx, vel3);
}

bool navCrowdResetMoveTarget(NavCrowdHandle* crowd, int idx) {
    if (!crowd || !crowd->crowd || idx < 0) return false;
    return crowd->crowd->resetMoveTarget(idx);
}

void navCrowdUpdate(NavCrowdHandle* crowd, float dt) {
    if (!crowd || !crowd->crowd || dt <= 0.0f) return;
    crowd->crowd->update(dt, nullptr);
}

bool navCrowdGetAgentState(const NavCrowdHandle* crowd, int idx,
                           float* outPos3, float* outVel3, uint8_t* outState) {
    if (!crowd || !crowd->crowd || idx < 0) return false;
    const dtCrowdAgent* ag = crowd->crowd->getAgent(idx);
    if (!ag || !ag->active) return false;
    if (outPos3) dtVcopy(outPos3, ag->npos);
    if (outVel3) dtVcopy(outVel3, ag->vel);
    if (outState) *outState = ag->state;
    return true;
}

} // extern "C"
