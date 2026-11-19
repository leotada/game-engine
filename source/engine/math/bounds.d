/// Bounding volumes: axis-aligned boxes and spheres, plus their transforms.
module engine.math.bounds;

import engine.math.mat : Mat4;
import engine.math.vec : Vec3;

pure nothrow @nogc @safe:

/// Axis-aligned bounding box. `Aabb.init` is the empty box (min = +inf, max = -inf),
/// so `merge` / `extend` grow it from nothing.
struct Aabb {
pure nothrow @nogc:
    Vec3 min = Vec3(float.infinity, float.infinity, float.infinity);
    Vec3 max = Vec3(-float.infinity, -float.infinity, -float.infinity);

    /// True when no point was ever added.
    bool empty() const { return min.x > max.x || min.y > max.y || min.z > max.z; }

    Vec3 center() const {
        return Vec3((min.x + max.x) * 0.5f, (min.y + max.y) * 0.5f, (min.z + max.z) * 0.5f);
    }

    /// Full extents (max - min).
    Vec3 extents() const {
        return Vec3(max.x - min.x, max.y - min.y, max.z - min.z);
    }

    /// Half extents ((max - min) / 2).
    Vec3 halfExtents() const {
        return Vec3((max.x - min.x) * 0.5f, (max.y - min.y) * 0.5f, (max.z - min.z) * 0.5f);
    }

    /// Grow to include `p`.
    void extend(Vec3 p) {
        if (p.x < min.x) min.x = p.x;
        if (p.y < min.y) min.y = p.y;
        if (p.z < min.z) min.z = p.z;
        if (p.x > max.x) max.x = p.x;
        if (p.y > max.y) max.y = p.y;
        if (p.z > max.z) max.z = p.z;
    }

    /// Union of two boxes.
    Aabb merge(Aabb b) const {
        Aabb r = this;
        if (b.empty) return r;
        r.extend(b.min);
        r.extend(b.max);
        return r;
    }

    bool contains(Vec3 p) const {
        return p.x >= min.x && p.x <= max.x
            && p.y >= min.y && p.y <= max.y
            && p.z >= min.z && p.z <= max.z;
    }

    bool intersects(Aabb b) const {
        return min.x <= b.max.x && max.x >= b.min.x
            && min.y <= b.max.y && max.y >= b.min.y
            && min.z <= b.max.z && max.z >= b.min.z;
    }

    /// Box around a set of `float[3]` positions (vertex `pos` fields).
    static Aabb fromPositions(V)(scope const(V)[] verts) if (is(typeof(V.init.pos) == float[3])) {
        Aabb b;
        foreach (ref v; verts)
            b.extend(Vec3(v.pos[0], v.pos[1], v.pos[2]));
        return b;
    }

    /// World box of this local box under an affine `m` (Arvo's method).
    Aabb transformed(Mat4 m) const {
        if (empty) return Aabb.init;
        float[3] mn = [m.m[12], m.m[13], m.m[14]];
        float[3] mx = mn;
        immutable float[3] lo = [min.x, min.y, min.z];
        immutable float[3] hi = [max.x, max.y, max.z];
        foreach (row; 0 .. 3) {
            foreach (col; 0 .. 3) {
                immutable a = m.m[col * 4 + row] * lo[col];
                immutable b = m.m[col * 4 + row] * hi[col];
                if (a < b) {
                    mn[row] += a;
                    mx[row] += b;
                } else {
                    mn[row] += b;
                    mx[row] += a;
                }
            }
        }
        return Aabb(Vec3(mn[0], mn[1], mn[2]), Vec3(mx[0], mx[1], mx[2]));
    }
}

/// Bounding sphere.
struct BoundingSphere {
pure nothrow @nogc:
    Vec3 center = Vec3(0, 0, 0);
    float radius = 0;

    /// Sphere enclosing `box` (center + half diagonal).
    static BoundingSphere fromAabb(Aabb box) {
        if (box.empty) return BoundingSphere.init;
        return BoundingSphere(box.center, box.halfExtents.length);
    }

    /// Sphere under an affine `m`; the radius scales by the largest axis scale.
    BoundingSphere transformed(Mat4 m) const {
        immutable c = Vec3(
            m.m[0] * center.x + m.m[4] * center.y + m.m[8] * center.z + m.m[12],
            m.m[1] * center.x + m.m[5] * center.y + m.m[9] * center.z + m.m[13],
            m.m[2] * center.x + m.m[6] * center.y + m.m[10] * center.z + m.m[14]);
        return BoundingSphere(c, radius * maxAxisScale(m));
    }
}

/// Largest column length of the upper 3×3 (uniform bound on the scale).
float maxAxisScale(Mat4 m) {
    import core.math : sqrt;
    float best = 0;
    foreach (col; 0 .. 3) {
        immutable x = m.m[col * 4], y = m.m[col * 4 + 1], z = m.m[col * 4 + 2];
        immutable l2 = x * x + y * y + z * z;
        if (l2 > best) best = l2;
    }
    return sqrt(best);
}

@("bounds.aabb") unittest {
    Aabb b;
    assert(b.empty);
    b.extend(Vec3(1, 2, 3));
    b.extend(Vec3(-1, 0, 5));
    assert(!b.empty);
    assert(b.min == Vec3(-1, 0, 3) && b.max == Vec3(1, 2, 5));
    assert(b.center == Vec3(0, 1, 4));
    assert(b.halfExtents == Vec3(1, 1, 1));
    assert(b.contains(Vec3(0, 1, 4)) && !b.contains(Vec3(2, 1, 4)));
    assert(b.merge(Aabb.init) == b);
    assert(Aabb.init.merge(b) == b);
    assert(b.intersects(Aabb(Vec3(0.5f, 1, 4.5f), Vec3(3, 3, 9))));
    assert(!b.intersects(Aabb(Vec3(2, 2, 2), Vec3(3, 3, 3))));
}

@("bounds.aabbTransformed") unittest {
    import std.math : PI;
    auto unit = Aabb(Vec3(-1, -1, -1), Vec3(1, 1, 1));
    auto t = unit.transformed(Mat4.translation(10, 0, 0) * Mat4.scaling(2, 3, 4));
    assert(t.min == Vec3(8, -3, -4) && t.max == Vec3(12, 3, 4));
    // 45° around Y grows the X/Z extent to sqrt(2).
    auto r = unit.transformed(Mat4.rotationY(PI / 4));
    assert(r.max.x > 1.41f && r.max.x < 1.42f && r.max.y > 0.99f && r.max.y < 1.01f);
    assert(Aabb.init.transformed(Mat4.identity()).empty);
}

@("bounds.sphere") unittest {
    auto s = BoundingSphere.fromAabb(Aabb(Vec3(-1, -1, -1), Vec3(1, 1, 1)));
    assert(s.center == Vec3(0, 0, 0) && s.radius > 1.73f && s.radius < 1.74f);
    auto w = BoundingSphere(Vec3(1, 0, 0), 1).transformed(Mat4.translation(0, 5, 0) * Mat4.scaling(1, 3, 1));
    assert(w.center == Vec3(1, 5, 0) && w.radius == 3);
    assert(maxAxisScale(Mat4.scaling(2, 7, 3)) == 7);
}
