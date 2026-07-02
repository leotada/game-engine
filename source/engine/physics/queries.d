module engine.physics.queries;

import bindings.box3d;
import bindings.box3d.constants : b3DefaultMaskBits;
import core.stdc.math : sqrtf;
import engine.math.vec : Vec3;
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

b3QueryFilter defaultPhysicsQueryFilter() nothrow @nogc @trusted {
    b3QueryFilter filter = b3DefaultQueryFilterD();
    filter.maskBits = b3DefaultMaskBits;
    return filter;
}
