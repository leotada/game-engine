/// High-level camera controllers: orbit, fly, first-person.
/// Each controller mutates a `Camera` based on keyboard/mouse input.
/// Gameplay-layer code — allowed to use the GC, but none is needed here.
module engine.scene.controllers;

import std.math : sin, cos, PI, PI_2;

import engine.math.vec : Vec3;
import engine.platform.input : InputState, Key;
import engine.scene.camera : Camera;

@safe:

private enum float EPS = 0.001f;

/// Clamp a value between lo and hi.
private float clamp(float v, float lo, float hi) pure nothrow @nogc {
    return v < lo ? lo : (v > hi ? hi : v);
}

// ---------------------------------------------------------------------------
// OrbitCamera — rotates around a target point. Ideal for RTS / showcase views.
// ---------------------------------------------------------------------------
struct OrbitCamera {
    Vec3 target = Vec3(0, 0, 0);
    float distance = 10;
    float minDistance = 2;
    float maxDistance = 60;
    float yaw   = 0;       // rotation around +Y axis (radians)
    float pitch = 0.5f;    // elevation above horizon (radians), clamped to (-π/2, π/2)
    float rotateSpeed = 1.8f;   // radians per second via arrow keys
    float zoomSpeed = 8.0f;     // units per second via W/S
    float mouseSensitivity = 0.004f;

    static OrbitCamera create(Vec3 target, float distance, float yaw = 0, float pitch = 0.5f) {
        OrbitCamera c;
        c.target   = target;
        c.distance = distance;
        c.yaw      = yaw;
        c.pitch    = pitch;
        return c;
    }

    /// Drive the orbit from input + dt; write the result back into `camera`.
    /// Left/Right arrows rotate yaw, Up/Down tilt pitch, W/S zoom in/out.
    /// Right-mouse-drag also rotates (mouseDX → yaw, mouseDY → pitch).
    void update(ref const InputState input, float dt, ref Camera camera) {
        if (input.keyDown(Key.left))  yaw   -= rotateSpeed * dt;
        if (input.keyDown(Key.right)) yaw   += rotateSpeed * dt;
        if (input.keyDown(Key.up))    pitch += rotateSpeed * 0.5f * dt;
        if (input.keyDown(Key.down))  pitch -= rotateSpeed * 0.5f * dt;

        if (input.keyDown(Key.w)) distance -= zoomSpeed * dt;
        if (input.keyDown(Key.s)) distance += zoomSpeed * dt;

        yaw   += input.mdx() * mouseSensitivity;
        pitch -= input.mdy() * mouseSensitivity;

        pitch    = clamp(pitch, -cast(float) PI_2 + EPS, cast(float) PI_2 - EPS);
        distance = clamp(distance, minDistance, maxDistance);

        immutable cp = cos(pitch);
        immutable eye = target + Vec3(
            cos(yaw) * cp * distance,
            sin(pitch) * distance,
            sin(yaw) * cp * distance,
        );
        camera.lookAt(eye, target);
    }
}

// ---------------------------------------------------------------------------
// FlyCamera — free 6-DOF camera. WASD moves horizontally, Space/Ctrl vertically.
// Mouse delta rotates (FPS-style) — suitable for editor / debug flythrough.
// ---------------------------------------------------------------------------
struct FlyCamera {
    Vec3  position = Vec3(0, 5, 10);
    float yaw   = -cast(float) PI_2; // facing -Z by default
    float pitch = 0;
    float moveSpeed = 6.0f;
    float sprintMultiplier = 3.0f;
    float mouseSensitivity = 0.003f;

    static FlyCamera create(Vec3 start, float yaw = -cast(float) PI_2, float pitch = 0) {
        FlyCamera c;
        c.position = start;
        c.yaw      = yaw;
        c.pitch    = pitch;
        return c;
    }

    Vec3 forward() const pure nothrow @nogc {
        return Vec3(cos(pitch) * cos(yaw), sin(pitch), cos(pitch) * sin(yaw));
    }

    Vec3 right() const pure nothrow @nogc {
        // Right = cross(forward, worldUp) normalized; worldUp = (0,1,0).
        immutable f = forward();
        immutable len = cast(float) (f.z * f.z + f.x * f.x);
        if (len < EPS) return Vec3(1, 0, 0);
        immutable invL = 1.0f / cast(float)(cos(pitch));
        return Vec3(f.z * invL, 0, -f.x * invL);
    }

    void update(ref const InputState input, float dt, ref Camera camera) {
        yaw   += input.mdx() * mouseSensitivity;
        pitch -= input.mdy() * mouseSensitivity;
        pitch  = clamp(pitch, -cast(float) PI_2 + EPS, cast(float) PI_2 - EPS);

        immutable speed = moveSpeed * dt;
        immutable f = forward();
        immutable r = right();

        Vec3 move = Vec3(0, 0, 0);
        if (input.keyDown(Key.w)) move = move + f;
        if (input.keyDown(Key.s)) move = move - f;
        if (input.keyDown(Key.d)) move = move + r;
        if (input.keyDown(Key.a)) move = move - r;
        if (input.keyDown(Key.space)) move.y += 1;

        if (move.lengthSquared() > EPS)
            position = position + move.normalized() * speed;

        camera.lookAt(position, position + forward());
    }
}

// ---------------------------------------------------------------------------
// FirstPersonCamera — yaw/pitch camera locked to a moving character position.
// The caller owns movement; this controller only handles look direction.
// ---------------------------------------------------------------------------
struct FirstPersonCamera {
    float yaw   = 0;
    float pitch = 0;
    float mouseSensitivity = 0.003f;

    static FirstPersonCamera create(float yaw = 0, float pitch = 0) {
        FirstPersonCamera c;
        c.yaw   = yaw;
        c.pitch = pitch;
        return c;
    }

    Vec3 forward() const pure nothrow @nogc {
        return Vec3(cos(pitch) * cos(yaw), sin(pitch), cos(pitch) * sin(yaw));
    }

    /// Update look direction and point `camera` from `eyePosition` forward.
    void update(ref const InputState input, Vec3 eyePosition, ref Camera camera) {
        yaw   += input.mdx() * mouseSensitivity;
        pitch -= input.mdy() * mouseSensitivity;
        pitch  = clamp(pitch, -cast(float) PI_2 + EPS, cast(float) PI_2 - EPS);
        camera.lookAt(eyePosition, eyePosition + forward());
    }
}
