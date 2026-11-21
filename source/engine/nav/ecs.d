/// POD ECS components and `NavWorld` helper for `engine.nav`.
module engine.nav.ecs;

import engine.core.pod : isPod;
import engine.ecs.store : EntityId;
import engine.ecs.world : World;
import engine.math.vec : Vec3;
import engine.reflect.attrs : component, export_;
import engine.nav.types;
import engine.nav.mesh : NavCrowd, NavQuery, NavTileCache;

@safe:

/// Attached to a terrain/level root entity describing baked NavMesh parameters.
@component struct NavMeshSurface {
    @export_ float cellSize = 0.30f;
    @export_ float cellHeight = 0.20f;
    @export_ float agentHeight = 2.0f;
    @export_ float agentRadius = 0.5f;
    @export_ float agentMaxClimb = 0.9f;
    @export_ float agentMaxSlopeDeg = 45.0f;
    @export_ int tileSize = 48;
    @export_ bool dynamicObstacles = true;
}

/// Attached to an autonomous navigating entity managed by `NavCrowd`.
@component struct NavAgent {
    @export_ float radius = 0.5f;
    @export_ float height = 2.0f;
    @export_ float maxSpeed = 3.5f;
    @export_ float maxAcceleration = 8.0f;
    @export_ float stoppingDistance = 0.35f;
    int crowdIndex = -1;
    NavAgentState state = NavAgentState.invalid;
    Vec3 velocity = Vec3(0, 0, 0);
}

/// Pending or active destination request for a `NavAgent`.
@component struct NavMoveRequest {
    @export_ Vec3 target = Vec3(0, 0, 0);
    NavPolyRef targetPoly = 0;
    bool pending = false;
    bool arrived = false;
}

/// Dynamic obstacle registered with `NavTileCache`.
@component struct NavObstacle {
    @export_ NavObstacleShape shape = NavObstacleShape.cylinder;
    @export_ Vec3 halfExtents = Vec3(0.5f, 1.0f, 0.5f);
    @export_ float radius = 0.5f;
    @export_ float height = 2.0f;
    @export_ float yawRadians = 0.0f;
    NavObstacleRef obstacleRef = 0;
    bool registered = false;
}

/// Bidirectional or one-way off-mesh traversal link (jumps, ladders, ledges).
@component struct NavOffMeshLink {
    @export_ Vec3 startOffset = Vec3(0, 0, 0);
    @export_ Vec3 endOffset = Vec3(0, 0, 2);
    @export_ float radius = 0.6f;
    @export_ bool bidirectional = true;
    @export_ ubyte areaId = 0;
    @export_ ushort flags = 1;
}

/// Spatial area/cost modifier volume for baking or runtime filtering.
@component struct NavModifierVolume {
    @export_ Vec3 halfExtents = Vec3(2, 2, 2);
    @export_ ubyte areaId = 0;
}

static assert(isPod!NavMeshSurface);
static assert(isPod!NavAgent);
static assert(isPod!NavMoveRequest);
static assert(isPod!NavObstacle);
static assert(isPod!NavOffMeshLink);
static assert(isPod!NavModifierVolume);

/// Step `NavCrowd` and sync `NavMoveRequest` / `NavAgent` components inside any `World`
/// containing `Position`, `NavAgent`, and `NavMoveRequest`.
void stepNavAgents(W, PositionT)(ref W world, ref NavCrowd crowd, ref NavQuery query, float dt) nothrow @nogc {
    if (!crowd.isValid() || !query.isValid()) return;
    auto filter = NavQueryFilter.defaults();
    immutable searchExtents = Vec3(2.0f, 4.0f, 2.0f);

    // 1. Register new agents and submit pending move requests.
    foreach (e; world.query!(PositionT, NavAgent)()) {
        auto pos = world.getPtr!PositionT(e);
        auto agent = world.getPtr!NavAgent(e);
        if (agent.crowdIndex < 0) {
            NavCrowdAgentParams p;
            p.radius = agent.radius;
            p.height = agent.height;
            p.maxSpeed = agent.maxSpeed;
            p.maxAcceleration = agent.maxAcceleration;
            agent.crowdIndex = crowd.addAgent(Vec3(pos.x, pos.y, pos.z), p);
        }
        if (agent.crowdIndex >= 0 && world.has!NavMoveRequest(e)) {
            auto req = world.getPtr!NavMoveRequest(e);
            if (req.pending) {
                NavPolyRef poly = 0;
                Vec3 nearest;
                if (query.findNearestPoly(req.target, searchExtents, filter, poly, nearest)) {
                    req.targetPoly = poly;
                    req.arrived = false;
                    crowd.requestMoveTarget(agent.crowdIndex, poly, nearest);
                }
                req.pending = false;
            }
        }
    }

    // 2. Advance Detour crowd simulation.
    crowd.update(dt);

    // 3. Copy positions/velocities back into ECS components.
    foreach (e; world.query!(PositionT, NavAgent)()) {
        auto pos = world.getPtr!PositionT(e);
        auto agent = world.getPtr!NavAgent(e);
        if (agent.crowdIndex < 0) continue;
        Vec3 cPos, cVel;
        NavAgentState cState;
        if (crowd.getAgentState(agent.crowdIndex, cPos, cVel, cState)) {
            pos.x = cPos.x;
            pos.y = cPos.y;
            pos.z = cPos.z;
            agent.velocity = cVel;
            agent.state = cState;
            if (world.has!NavMoveRequest(e)) {
                auto req = world.getPtr!NavMoveRequest(e);
                immutable dx = req.target.x - cPos.x;
                immutable dy = req.target.y - cPos.y;
                immutable dz = req.target.z - cPos.z;
                immutable distSq = dx * dx + dy * dy + dz * dz;
                req.arrived = distSq <= (agent.stoppingDistance * agent.stoppingDistance);
            }
        }
    }
}
