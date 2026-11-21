/// Public navigation types, configs, and POD structures for `engine.nav`.
module engine.nav.types;

import engine.core.pod : isPod;
import engine.math.vec : Vec3;
import bindings.recast : NavBakeConfigC = NavBakeConfig,
    NavQueryFilterC, NavCrowdAgentParamsC,
    NAV_STATUS_SUCCEDED, NAV_STATUS_FAILED, NAV_STATUS_INPROGRESS;

@safe:

alias NavPolyRef = ulong;
alias NavObstacleRef = uint;
alias NavStatus = uint;

enum NavStatusCode : uint {
    succeeded = NAV_STATUS_SUCCEDED,
    failed = NAV_STATUS_FAILED,
    inProgress = NAV_STATUS_INPROGRESS,
}

enum NavObstacleShape : ubyte {
    cylinder = 0,
    aabb = 1,
    obb = 2,
}

enum NavAgentState : ubyte {
    invalid = 0,
    walking = 1,
    offMesh = 2,
}

enum NavStraightPathFlags : ubyte {
    start = 1,
    end = 2,
    offMeshConnection = 4,
}

/// Tiled Recast/Detour navigation mesh bake parameters.
struct NavBakeConfig {
    float cellSize = 0.30f;
    float cellHeight = 0.20f;
    float agentHeight = 2.0f;
    float agentRadius = 0.5f;
    float agentMaxClimb = 0.9f;
    float agentMaxSlopeDeg = 45.0f;
    int tileSize = 48;
    int regionMinSize = 8;
    int regionMergeSize = 20;
    float edgeMaxLen = 12.0f;
    float edgeMaxError = 1.3f;
    int vertsPerPoly = 6;
    float detailSampleDist = 6.0f;
    float detailSampleMaxError = 1.0f;
    int maxTiles = 1024;
    int maxPolysPerTile = 4096;
    int maxLayersPerTile = 32;
    int maxObstacles = 512;

    static NavBakeConfig defaults() nothrow @nogc {
        return NavBakeConfig.init;
    }

    NavBakeConfigC toC() const nothrow @nogc {
        NavBakeConfigC c;
        c.cellSize = cellSize;
        c.cellHeight = cellHeight;
        c.agentHeight = agentHeight;
        c.agentRadius = agentRadius;
        c.agentMaxClimb = agentMaxClimb;
        c.agentMaxSlopeDeg = agentMaxSlopeDeg;
        c.tileSize = tileSize;
        c.regionMinSize = regionMinSize;
        c.regionMergeSize = regionMergeSize;
        c.edgeMaxLen = edgeMaxLen;
        c.edgeMaxError = edgeMaxError;
        c.vertsPerPoly = vertsPerPoly;
        c.detailSampleDist = detailSampleDist;
        c.detailSampleMaxError = detailSampleMaxError;
        c.maxTiles = maxTiles;
        c.maxPolysPerTile = maxPolysPerTile;
        c.maxLayersPerTile = maxLayersPerTile;
        c.maxObstacles = maxObstacles;
        return c;
    }
}

/// Polygon area costs and inclusion/exclusion flags for queries.
struct NavQueryFilter {
    ushort includeFlags = 0xffff;
    ushort excludeFlags = 0;
    float[64] areaCosts = 1.0f;

    static NavQueryFilter defaults() nothrow @nogc {
        NavQueryFilter f;
        f.areaCosts[] = 1.0f;
        return f;
    }

    NavQueryFilterC toC() const nothrow @nogc {
        NavQueryFilterC c;
        c.includeFlags = includeFlags;
        c.excludeFlags = excludeFlags;
        c.areaCosts = areaCosts;
        return c;
    }
}

/// Crowd steering and local avoidance parameters per agent.
struct NavCrowdAgentParams {
    float radius = 0.5f;
    float height = 2.0f;
    float maxAcceleration = 8.0f;
    float maxSpeed = 3.5f;
    float collisionQueryRange = 6.0f;
    float pathOptimizationRange = 15.0f;
    float separationWeight = 2.0f;
    ubyte updateFlags = 0x1f;
    ubyte obstacleAvoidanceType = 3;
    ubyte queryFilterType = 0;

    static NavCrowdAgentParams defaults() nothrow @nogc {
        return NavCrowdAgentParams.init;
    }

    NavCrowdAgentParamsC toC() const nothrow @nogc {
        NavCrowdAgentParamsC c;
        c.radius = radius;
        c.height = height;
        c.maxAcceleration = maxAcceleration;
        c.maxSpeed = maxSpeed;
        c.collisionQueryRange = collisionQueryRange;
        c.pathOptimizationRange = pathOptimizationRange;
        c.separationWeight = separationWeight;
        c.updateFlags = updateFlags;
        c.obstacleAvoidanceType = obstacleAvoidanceType;
        c.queryFilterType = queryFilterType;
        return c;
    }
}

struct NavStraightPathPoint {
    Vec3 position;
    NavPolyRef polyRef = 0;
    ubyte flags = 0;
}

struct NavRaycastHit {
    float t = 1.0f;
    Vec3 normal;
    bool hit = false;
}

static assert(isPod!NavBakeConfig);
static assert(isPod!NavQueryFilter);
static assert(isPod!NavCrowdAgentParams);
static assert(isPod!NavStraightPathPoint);
static assert(isPod!NavRaycastHit);
