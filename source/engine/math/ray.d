/// Screen-space picking helpers — unproject pixels to world-space rays.
module engine.math.ray;

import engine.math.vec : Vec3, Vec4;
import engine.math.mat : Mat4;
import std.math : sqrt;

@safe:

/// Infinite ray in world space.
struct Ray {
    Vec3 origin;
    Vec3 direction; /// Unit direction.
}

/// Build a world-space ray from a screen pixel through the camera frustum.
///
/// Screen origin is top-left (SDL / typical window coords). `viewProj` is the
/// combined view × projection matrix (column-major). Uses WebGPU NDC Z in [0,1].
Ray screenToWorldRay(float mx, float my, float width, float height, Mat4 viewProj) {
    immutable ndcX = (mx / width) * 2.0f - 1.0f;
    immutable ndcY = 1.0f - (my / height) * 2.0f; // flip Y (screen down → NDC up)

    immutable inv = viewProj.inverse();
    auto nearH = inv * Vec4(ndcX, ndcY, 0.0f, 1.0f);
    auto farH  = inv * Vec4(ndcX, ndcY, 1.0f, 1.0f);

    if (nearH.w != 0) {
        immutable iw = 1.0f / nearH.w;
        nearH = Vec4(nearH.x * iw, nearH.y * iw, nearH.z * iw, 1.0f);
    }
    if (farH.w != 0) {
        immutable iw = 1.0f / farH.w;
        farH = Vec4(farH.x * iw, farH.y * iw, farH.z * iw, 1.0f);
    }

    immutable origin = Vec3(nearH.x, nearH.y, nearH.z);
    immutable dx = farH.x - origin.x;
    immutable dy = farH.y - origin.y;
    immutable dz = farH.z - origin.z;
    immutable lenSq = dx * dx + dy * dy + dz * dz;
    Vec3 dir;
    if (lenSq > 0) {
        immutable invLen = 1.0f / sqrt(lenSq);
        dir = Vec3(dx * invLen, dy * invLen, dz * invLen);
    }
    return Ray(origin, dir);
}
