/// View frustum for culling, extracted from a view-projection matrix.
module engine.math.frustum;

import engine.math.bounds : Aabb, BoundingSphere;
import engine.math.mat : Mat4;
import engine.math.vec : Vec3, Vec4;

@safe:

/**
 * Six inward-facing planes (`dot(n, p) + d >= 0` is inside), extracted with
 * Gribb–Hartmann from a column-major view-projection matrix for WebGPU clip
 * space (`z ∈ [0, 1]`): the near plane is row 2 alone and the far plane is
 * row 3 − row 2. Works for perspective and orthographic (light) matrices.
 */
struct Frustum {
    enum Plane : uint { left, right, bottom, top, near, far }

    /// xyz = unit normal pointing into the frustum, w = distance term.
    Vec4[6] planes;
    /// World-space box around the 8 frustum corners (for broad-phase grids).
    Aabb bounds;

pure nothrow @nogc:

    static Frustum fromViewProj(Mat4 vp) {
        Vec4 row(uint i) {
            return Vec4(vp.m[i], vp.m[4 + i], vp.m[8 + i], vp.m[12 + i]);
        }
        immutable r0 = row(0), r1 = row(1), r2 = row(2), r3 = row(3);
        Frustum f;
        f.planes[Plane.left]   = r3 + r0;
        f.planes[Plane.right]  = r3 - r0;
        f.planes[Plane.bottom] = r3 + r1;
        f.planes[Plane.top]    = r3 - r1;
        f.planes[Plane.near]   = r2;
        f.planes[Plane.far]    = r3 - r2;
        foreach (ref p; f.planes) {
            import core.math : sqrt;
            immutable len = sqrt(p.x * p.x + p.y * p.y + p.z * p.z);
            if (len > 0) p = p * (1.0f / len);
        }
        // Corner box: unproject the 8 NDC corners.
        immutable inv = vp.inverse();
        foreach (ix; 0 .. 2) foreach (iy; 0 .. 2) foreach (iz; 0 .. 2) {
            immutable c = inv * Vec4(ix ? 1.0f : -1.0f, iy ? 1.0f : -1.0f, iz ? 1.0f : 0.0f, 1.0f);
            if (c.w != 0)
                f.bounds.extend(Vec3(c.x / c.w, c.y / c.w, c.z / c.w));
        }
        return f;
    }

    /// Signed distance of `p` to plane `i` (positive = inside).
    float distance(uint i, Vec3 p) const {
        return planes[i].x * p.x + planes[i].y * p.y + planes[i].z * p.z + planes[i].w;
    }

    bool containsPoint(Vec3 p) const {
        foreach (i; 0 .. 6)
            if (distance(i, p) < 0) return false;
        return true;
    }

    /// Conservative: true unless the sphere is fully outside one plane.
    bool intersectsSphere(Vec3 center, float radius) const {
        foreach (i; 0 .. 6)
            if (distance(i, center) < -radius) return false;
        return true;
    }

    bool intersectsSphere(BoundingSphere s) const { return intersectsSphere(s.center, s.radius); }

    /// Conservative p-vertex test: true unless the box is fully outside one plane.
    bool intersectsAabb(Aabb b) const {
        if (b.empty) return false;
        foreach (i; 0 .. 6) {
            immutable p = Vec3(planes[i].x >= 0 ? b.max.x : b.min.x,
                               planes[i].y >= 0 ? b.max.y : b.min.y,
                               planes[i].z >= 0 ? b.max.z : b.min.z);
            if (distance(i, p) < 0) return false;
        }
        return true;
    }
}

@("frustum.perspective") unittest {
    import engine.scene.camera : Camera;
    auto cam = Camera.create(1.0f, 1.0f, 0.5f, 100.0f);
    cam.lookAt(Vec3(0, 0, 0), Vec3(0, 0, -1)); // looking down -Z
    auto f = Frustum.fromViewProj(cam.viewProjection());

    assert(f.containsPoint(Vec3(0, 0, -10)));            // straight ahead
    assert(!f.containsPoint(Vec3(0, 0, 10)));            // behind
    assert(!f.containsPoint(Vec3(0, 0, -0.1f)));         // before near
    assert(!f.containsPoint(Vec3(0, 0, -150)));          // beyond far
    assert(!f.containsPoint(Vec3(-20, 0, -10)));         // left
    assert(!f.containsPoint(Vec3(20, 0, -10)));          // right
    assert(!f.containsPoint(Vec3(0, 20, -10)));          // up
    assert(!f.containsPoint(Vec3(0, -20, -10)));         // down
    assert(f.containsPoint(Vec3(4, 4, -10)));            // tan(0.5)*10 ≈ 5.46

    // Near plane sits at distance 0.5 along -Z.
    assert(f.distance(Frustum.Plane.near, Vec3(0, 0, -0.5f)) > -1e-3f
        && f.distance(Frustum.Plane.near, Vec3(0, 0, -0.5f)) < 1e-3f);

    // Spheres: straddling the left plane is kept, fully outside is culled.
    assert(f.intersectsSphere(Vec3(-6, 0, -10), 1.0f));
    assert(!f.intersectsSphere(Vec3(-20, 0, -10), 1.0f));
    assert(f.intersectsSphere(Vec3(0, 0, 3), 4.0f));     // behind but overlapping the apex
    assert(!f.intersectsSphere(Vec3(0, 0, 10), 2.0f));

    // Boxes.
    assert(f.intersectsAabb(Aabb(Vec3(-1, -1, -11), Vec3(1, 1, -9))));
    assert(f.intersectsAabb(Aabb(Vec3(-100, -1, -11), Vec3(-5, 1, -9)))); // straddles left
    assert(!f.intersectsAabb(Aabb(Vec3(-100, -1, -11), Vec3(-50, 1, -9))));
    assert(!f.intersectsAabb(Aabb(Vec3(-1, -1, 5), Vec3(1, 1, 9))));
    assert(!f.intersectsAabb(Aabb.init));

    // Corner box spans the far plane footprint.
    assert(f.bounds.min.z < -99.0f && f.bounds.max.z > -0.6f);
    assert(f.bounds.max.x > 54.0f && f.bounds.min.x < -54.0f);
}

@("frustum.orthographic") unittest {
    // Light-style ortho: x,y ∈ [-10, 10], depth 1..50 looking down -Y.
    Mat4 proj;
    proj.m[] = 0;
    proj.m[0] = 0.1f;
    proj.m[5] = 0.1f;
    proj.m[10] = -1.0f / 49.0f;
    proj.m[14] = -1.0f / 49.0f;
    proj.m[15] = 1;
    auto view = Mat4.lookAt(Vec3(0, 30, 0), Vec3(0, 0, 0), Vec3(0, 0, -1));
    auto f = Frustum.fromViewProj(proj * view);
    assert(f.containsPoint(Vec3(0, 0, 0)));
    assert(f.containsPoint(Vec3(9, 0, 9)));
    assert(!f.containsPoint(Vec3(11, 0, 0)));
    assert(!f.containsPoint(Vec3(0, 31, 0)));   // above the light (before near)
    assert(!f.containsPoint(Vec3(0, -30, 0)));  // beyond far
}
