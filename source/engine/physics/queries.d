module engine.physics.queries;

import bindings.box3d;
import bindings.box3d.constants : b3DefaultMaskBits;
import core.stdc.math : sqrtf;
import engine.ecs.store : EntityId;
import engine.math.vec : Vec3;
import engine.physics.body : getShapeEntity, noPhysicsEntity;
import engine.physics.convert : toB3Pos, toB3Vec3, toEngineVec3;
import engine.physics.world : PhysicsWorld;

@safe:

struct RayCastHit {
    bool hit;
    b3ShapeId shapeId;
    b3BodyId bodyId;
    Vec3 point;
    Vec3 normal;
    float fraction;
}

alias OverlapCallback = bool function(b3ShapeId shapeId, b3BodyId bodyId, EntityId entityId, void* context) nothrow @nogc @safe;

RayCastHit castRayClosest(ref PhysicsWorld world,
                          Vec3 origin,
                          Vec3 direction,
                          float maxDist) nothrow @nogc @trusted {
    return castRayClosest(world, origin, direction, maxDist, defaultPhysicsQueryFilter());
}

RayCastHit castRayClosest(ref PhysicsWorld world,
                          Vec3 origin,
                          Vec3 direction,
                          float maxDist,
                          b3QueryFilter filter) nothrow @nogc @trusted {
    RayCastHit hit;
    if (maxDist <= 0.0f)
        return hit;

    immutable lenSq = direction.x * direction.x + direction.y * direction.y + direction.z * direction.z;
    immutable len = sqrtf(lenSq);
    if (len <= 0.000001f)
        return hit;

    immutable translation = toB3Vec3(direction / len * maxDist);
    b3RayResult result = b3World_CastRayClosestD(world.handle, toB3Pos(origin), translation, filter);
    if (!result.hit)
        return hit;

    hit.hit = true;
    hit.shapeId = result.shapeId;
    hit.bodyId = b3Shape_IsValidD(result.shapeId) ? b3Shape_GetBodyD(result.shapeId) : b3BodyId.init;
    hit.point = toEngineVec3(result.point);
    hit.normal = toEngineVec3(result.normal);
    hit.fraction = result.fraction;
    return hit;
}

/// Overlap all shapes that potentially intersect the AABB `[minCorner, maxCorner]`.
/// Callback return `false` to stop early. Uses `defaultPhysicsQueryFilter` unless overridden.
int overlapAabb(ref PhysicsWorld world,
                Vec3 minCorner,
                Vec3 maxCorner,
                OverlapCallback callback,
                scope void* context = null) nothrow @nogc @trusted {
    return overlapAabb(world, minCorner, maxCorner, callback, context, defaultPhysicsQueryFilter());
}

int overlapAabb(ref PhysicsWorld world,
                Vec3 minCorner,
                Vec3 maxCorner,
                OverlapCallback callback,
                scope void* context,
                b3QueryFilter filter) nothrow @nogc @trusted {
    if (callback is null)
        return 0;

    OverlapCtx ctx;
    ctx.callback = callback;
    ctx.userContext = context;

    b3AABB aabb;
    aabb.lowerBound = toB3Vec3(minCorner);
    aabb.upperBound = toB3Vec3(maxCorner);
    b3World_OverlapAABBD(world.handle, aabb, filter, &overlapResultThunk, &ctx);
    return ctx.count;
}

/// Overlap shapes against a sphere proxy (single point + radius).
int overlapSphere(ref PhysicsWorld world,
                  Vec3 center,
                  float radius,
                  OverlapCallback callback,
                  scope void* context = null) nothrow @nogc @trusted {
    return overlapSphere(world, center, radius, callback, context, defaultPhysicsQueryFilter());
}

int overlapSphere(ref PhysicsWorld world,
                  Vec3 center,
                  float radius,
                  OverlapCallback callback,
                  scope void* context,
                  b3QueryFilter filter) nothrow @nogc @trusted {
    if (callback is null || radius < 0.0f)
        return 0;

    OverlapCtx ctx;
    ctx.callback = callback;
    ctx.userContext = context;

    b3Vec3 point = b3Vec3(0.0f, 0.0f, 0.0f);
    b3ShapeProxy proxy;
    proxy.points = &point;
    proxy.count = 1;
    proxy.radius = radius;

    b3World_OverlapShapeD(world.handle, toB3Pos(center), &proxy, filter, &overlapResultThunk, &ctx);
    return ctx.count;
}

b3QueryFilter defaultPhysicsQueryFilter() nothrow @nogc @trusted {
    b3QueryFilter filter = b3DefaultQueryFilterD();
    filter.maskBits = b3DefaultMaskBits;
    return filter;
}

private struct OverlapCtx {
    OverlapCallback callback;
    void* userContext;
    int count;
}

private extern(C) bool overlapResultThunk(b3ShapeId shapeId, void* context) nothrow @nogc @trusted {
    auto ctx = cast(OverlapCtx*) context;
    if (ctx is null || ctx.callback is null)
        return false;

    b3BodyId bodyId = b3BodyId.init;
    EntityId entityId = noPhysicsEntity;
    if (b3Shape_IsValidD(shapeId)) {
        bodyId = b3Shape_GetBodyD(shapeId);
        entityId = getShapeEntity(shapeId);
    }

    ctx.count += 1;
    return ctx.callback(shapeId, bodyId, entityId, ctx.userContext);
}
