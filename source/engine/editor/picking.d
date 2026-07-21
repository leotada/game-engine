/// Editor picking: ray vs world AABB, selection highlight, optional physics ray.
module engine.editor.picking;

import engine.devtools.gizmos : GizmoRenderer;
import engine.editor.components : Visual, worldMatrix;
import engine.editor.selection : Selection;
import engine.ecs.store : EntityId;
import engine.graphics.types : Color4;
import engine.math.mat : Mat4;
import engine.math.ray : Ray;
import engine.math.vec : Vec3;
import engine.scene.graph : Transform;

@safe:

/// Axis-aligned bounding box in world space.
struct Aabb {
    Vec3 min = Vec3(0, 0, 0);
    Vec3 max = Vec3(0, 0, 0);

    Vec3 center() const nothrow @nogc {
        return Vec3(
            (min.x + max.x) * 0.5f,
            (min.y + max.y) * 0.5f,
            (min.z + max.z) * 0.5f,
        );
    }

    /// Full extents (max - min), matching `GizmoRenderer.box`.
    Vec3 extents() const nothrow @nogc {
        return Vec3(max.x - min.x, max.y - min.y, max.z - min.z);
    }
}

/// Result of a scene pick.
struct PickHit {
    bool hit;
    EntityId entity = EntityId.max;
    float t = float.infinity; /// Ray parameter (distance along unit direction).
    Vec3 point;
}

/// Kay–Kajiya slab test. Returns true and writes entry `t` when the ray hits.
bool rayAabb(Ray ray, Aabb box, ref float tHit) nothrow @nogc {
    float tMin = 0;
    float tMax = float.infinity;

    bool slab(float origin, float dir, float bmin, float bmax, ref float tMin, ref float tMax) nothrow @nogc {
        enum eps = 1e-8f;
        if (dir > -eps && dir < eps) {
            // Parallel to slab — miss if outside.
            return origin >= bmin && origin <= bmax;
        }
        immutable inv = 1.0f / dir;
        float t0 = (bmin - origin) * inv;
        float t1 = (bmax - origin) * inv;
        if (t0 > t1) {
            immutable tmp = t0;
            t0 = t1;
            t1 = tmp;
        }
        if (t0 > tMin) tMin = t0;
        if (t1 < tMax) tMax = t1;
        return tMax >= tMin;
    }

    if (!slab(ray.origin.x, ray.direction.x, box.min.x, box.max.x, tMin, tMax))
        return false;
    if (!slab(ray.origin.y, ray.direction.y, box.min.y, box.max.y, tMin, tMax))
        return false;
    if (!slab(ray.origin.z, ray.direction.z, box.min.z, box.max.z, tMin, tMax))
        return false;

    if (tMax < 0) return false;
    tHit = tMin >= 0 ? tMin : tMax;
    return tHit >= 0;
}

/// Transform local half-extents (object space, pre-scale) into a world AABB.
Aabb worldAabbFromLocal(Mat4 world, Vec3 localHalfExtents) nothrow @nogc {
    // 8 corners of the local AABB around origin.
    immutable hx = localHalfExtents.x;
    immutable hy = localHalfExtents.y;
    immutable hz = localHalfExtents.z;

    Vec3 mn = Vec3(float.infinity, float.infinity, float.infinity);
    Vec3 mx = Vec3(-float.infinity, -float.infinity, -float.infinity);

    foreach (ix; 0 .. 2)
    foreach (iy; 0 .. 2)
    foreach (iz; 0 .. 2) {
        immutable lx = ix ? hx : -hx;
        immutable ly = iy ? hy : -hy;
        immutable lz = iz ? hz : -hz;
        // world * (lx,ly,lz,1)
        immutable wx = world.m[0] * lx + world.m[4] * ly + world.m[8]  * lz + world.m[12];
        immutable wy = world.m[1] * lx + world.m[5] * ly + world.m[9]  * lz + world.m[13];
        immutable wz = world.m[2] * lx + world.m[6] * ly + world.m[10] * lz + world.m[14];
        if (wx < mn.x) mn.x = wx;
        if (wy < mn.y) mn.y = wy;
        if (wz < mn.z) mn.z = wz;
        if (wx > mx.x) mx.x = wx;
        if (wy > mx.y) mx.y = wy;
        if (wz > mx.z) mx.z = wz;
    }
    return Aabb(mn, mx);
}

/// World AABB for an entity with `Transform` + optional `Visual`.
Aabb entityWorldAabb(W)(ref W world, EntityId id) {
    import engine.editor.components : defaultHalfExtents;

    Vec3 half = Vec3(0.5f, 0.5f, 0.5f);
    if (world.has!Visual(id)) {
        immutable v = world.get!Visual(id);
        half = v.localHalfExtents;
        if (half.x <= 0 && half.y <= 0 && half.z <= 0)
            half = defaultHalfExtents(v.kind);
    }
    return worldAabbFromLocal(worldMatrix(world, id), half);
}

/// Pick the closest entity whose world AABB intersects `ray` (t in [0, maxDist]).
PickHit pickClosestAabb(W)(ref W world, Ray ray, float maxDist = 1e6f) {
    PickHit best;
    best.t = maxDist;

    foreach (id; world.query!(Transform)()) {
        if (!world.alive(id)) continue;
        // Prefer entities with a Visual; still allow Transform-only (tiny default box).
        immutable box = entityWorldAabb(world, id);
        float t = 0;
        if (!rayAabb(ray, box, t)) continue;
        if (t < 0 || t > best.t) continue;
        best.hit = true;
        best.entity = id;
        best.t = t;
        best.point = Vec3(
            ray.origin.x + ray.direction.x * t,
            ray.origin.y + ray.direction.y * t,
            ray.origin.z + ray.direction.z * t,
        );
    }
    return best;
}

/// Physics-aware pick: prefer a closer `castRayClosest` hit when a
/// `PhysicsWorld*` is supplied; otherwise fall back to AABB picking.
PickHit pickClosestWithPhysics(W)(
    ref W world,
    Ray ray,
    float maxDist,
    void* physicsWorldPtr
) {
    auto hit = pickClosestAabb(world, ray, maxDist);
    if (physicsWorldPtr is null)
        return hit;

    import engine.physics.body : getShapeEntity, noPhysicsEntity;
    import engine.physics.queries : castRayClosest;
    import engine.physics.world : PhysicsWorld;

    auto physics = (() @trusted => cast(PhysicsWorld*) physicsWorldPtr)();
    immutable phy = castRayClosest(*physics, ray.origin, ray.direction, maxDist);
    if (!phy.hit)
        return hit;

    immutable dist = phy.fraction * maxDist;
    if (hit.hit && hit.t <= dist)
        return hit;

    immutable eid = getShapeEntity(phy.shapeId);
    if (eid == noPhysicsEntity || !world.alive(eid))
        return hit;

    PickHit out_;
    out_.hit = true;
    out_.entity = eid;
    out_.t = dist;
    out_.point = phy.point;
    return out_;
}

/// Yellow wire AABB highlight for the selected entity.
void drawSelectionHighlight(W)(ref W world, EntityId id, ref GizmoRenderer gizmos) {
    if (id == EntityId.max || !world.alive(id)) return;
    immutable box = entityWorldAabb(world, id);
    gizmos.box(box.center(), box.extents(), Color4(1.0f, 0.85f, 0.15f, 1.0f));
}

/// Highlight every entity in a multi-selection.
void drawSelectionHighlights(W)(ref W world, ref const Selection sel, ref GizmoRenderer gizmos) {
    foreach (i; 0 .. sel.count)
        drawSelectionHighlight(world, sel.ids[i], gizmos);
}

@safe unittest {
    Aabb box = Aabb(Vec3(-1, -1, -1), Vec3(1, 1, 1));
    Ray ray = Ray(Vec3(0, 0, -5), Vec3(0, 0, 1));
    float t = 0;
    assert(rayAabb(ray, box, t));
    assert(t > 3.9f && t < 4.1f);

    Ray miss = Ray(Vec3(10, 0, -5), Vec3(0, 0, 1));
    assert(!rayAabb(miss, box, t));
}

@safe unittest {
    immutable m = Mat4.translation(2, 0, 0) * Mat4.scaling(2, 2, 2);
    immutable box = worldAabbFromLocal(m, Vec3(0.5f, 0.5f, 0.5f));
    // half 0.5 * scale 2 → full extent 2, center at x=2
    assert(box.min.x > 0.9f && box.min.x < 1.1f);
    assert(box.max.x > 2.9f && box.max.x < 3.1f);
}
