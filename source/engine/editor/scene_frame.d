/**
 * `framePose` — camera pose that frames a world-space box.
 *
 * The editor uses it after a scene is opened, so the loaded content is on
 * screen instead of wherever the fly camera last was. The camera looks at the
 * box centre from above and in front (+Z), at a distance where the box's
 * bounding sphere fits the vertical field of view.
 *
 * Pure math, no GPU or world access, so it is unit-tested directly.
 */
module engine.editor.scene_frame;

import std.math : sqrt, tan;

import engine.math.vec : Vec3;

@safe:

/// Camera pose in the editor's fly-camera convention (`FlyCamera.forward`).
struct FramePose {
    Vec3 position;
    float yaw;
    float pitch;
    /// Far clip distance that keeps the whole box inside the frustum.
    float far;
}

/// Pose that frames the axis-aligned box `[boxMin, boxMax]` with vertical
/// field of view `fovY` (radians). A degenerate box still gets a usable pose.
FramePose framePose(Vec3 boxMin, Vec3 boxMax, float fovY) pure nothrow @nogc {
    immutable float cx = (boxMin.x + boxMax.x) * 0.5f;
    immutable float cy = (boxMin.y + boxMax.y) * 0.5f;
    immutable float cz = (boxMin.z + boxMax.z) * 0.5f;
    immutable float hx = (boxMax.x - boxMin.x) * 0.5f;
    immutable float hy = (boxMax.y - boxMin.y) * 0.5f;
    immutable float hz = (boxMax.z - boxMin.z) * 0.5f;

    float radius = sqrt(hx * hx + hy * hy + hz * hz);
    if (radius < 1.0f) radius = 1.0f;

    // Fit the bounding sphere vertically, with a 10% margin.
    immutable float halfFov = fovY * 0.5f;
    immutable float distance = radius / tan(halfFov) * 1.1f;

    // Direction from the centre back to the camera: 0.5 up per 1.0 forward,
    // normalized. Its yaw is -PI/2 (looking along -Z), its pitch -atan(0.5).
    enum float dirY = 0.4472136f;   // 0.5 / sqrt(1.25)
    enum float dirZ = 0.8944272f;   // 1.0 / sqrt(1.25)
    enum float pitch = -0.4636476f; // -atan(0.5)
    enum float yaw = -1.5707964f;   // -PI/2

    FramePose pose;
    pose.position = Vec3(cx, cy + dirY * distance, cz + dirZ * distance);
    pose.yaw = yaw;
    pose.pitch = pitch;
    pose.far = (distance + radius) * 2.0f;
    if (pose.far < 1000.0f) pose.far = 1000.0f;
    return pose;
}

@("sceneFrame.looksAtCentre") unittest {
    import std.math : cos, sin, abs;

    immutable p = framePose(Vec3(-150, 0, -150), Vec3(150, 3, 150), 0.9f);
    // FlyCamera.forward convention: (cos p cos y, sin p, cos p sin y).
    immutable float fx = cos(p.pitch) * cos(p.yaw);
    immutable float fy = sin(p.pitch);
    immutable float fz = cos(p.pitch) * sin(p.yaw);

    // Direction from the camera to the box centre (0, 1.5, 0), normalized.
    immutable float dx = 0.0f - p.position.x;
    immutable float dy = 1.5f - p.position.y;
    immutable float dz = 0.0f - p.position.z;
    immutable float len = sqrt(dx * dx + dy * dy + dz * dz);
    immutable float dot = (fx * dx + fy * dy + fz * dz) / len;
    assert(abs(dot - 1.0f) < 1e-4f);
    assert(p.position.y > 0 && p.position.z > 0);
}

@("sceneFrame.farCoversBox") unittest {
    immutable lo = Vec3(-150, 0, -150);
    immutable hi = Vec3(150, 3, 150);
    immutable p = framePose(lo, hi, 0.9f);
    assert(p.far >= 1000.0f);
    // Every corner of the box is closer to the camera than the far plane.
    foreach (x; [lo.x, hi.x]) foreach (y; [lo.y, hi.y]) foreach (z; [lo.z, hi.z]) {
        immutable float dx = x - p.position.x;
        immutable float dy = y - p.position.y;
        immutable float dz = z - p.position.z;
        assert(sqrt(dx * dx + dy * dy + dz * dz) < p.far);
    }
}

@("sceneFrame.degenerate") unittest {
    // A single point still yields a finite pose a few units away.
    immutable p = framePose(Vec3(2, 2, 2), Vec3(2, 2, 2), 0.9f);
    assert(p.position.y > 2.0f && p.position.z > 2.0f);
    assert(p.far >= 1000.0f);
}
