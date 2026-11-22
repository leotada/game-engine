/// High-level camera controllers: orbit, fly, first-person.
/// Each controller mutates a `Camera` based on keyboard, mouse, and gamepad input.
/// Gameplay-layer code — allowed to use the GC, but none is needed here.
module engine.scene.controllers;

import std.math : sin, cos, PI, PI_2;

import engine.math.vec : Vec2, Vec3;
import engine.platform.gamepad : PadButton;
import engine.platform.input : InputState, Key, MouseButton;
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
    float padRotateSpeed = 2.2f; // radians per second via right stick
    float padZoomSpeed = 10.0f;  // units per second via LT (out) / RT (in)
    uint  padSlot = 0;
    bool  useGamepad = true;
    /// Pitch limits (radians). Raise `minPitch` above 0 to keep the camera
    /// over the ground or a water surface.
    float minPitch = -cast(float) PI_2 + EPS;
    float maxPitch = cast(float) PI_2 - EPS;
    /// Units per mouse-wheel notch (0 = wheel ignored).
    float wheelZoomSpeed = 0.0f;
    /// When true the mouse only rotates while the left or right button is held
    /// (windowed demos); when false every mouse delta rotates (captured mouse).
    bool  dragToRotate = false;

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
    /// Right-mouse-drag and gamepad right stick also rotate; LT/RT zoom out/in.
    void update(ref const InputState input, float dt, ref Camera camera) {
        if (input.keyDown(Key.left))  yaw   -= rotateSpeed * dt;
        if (input.keyDown(Key.right)) yaw   += rotateSpeed * dt;
        if (input.keyDown(Key.up))    pitch += rotateSpeed * 0.5f * dt;
        if (input.keyDown(Key.down))  pitch -= rotateSpeed * 0.5f * dt;

        if (input.keyDown(Key.w)) distance -= zoomSpeed * dt;
        if (input.keyDown(Key.s)) distance += zoomSpeed * dt;

        if (!dragToRotate || input.mouseDown(MouseButton.left) || input.mouseDown(MouseButton.right)) {
            yaw   += input.mdx() * mouseSensitivity;
            pitch -= input.mdy() * mouseSensitivity;
        }
        distance -= input.wheelY() * wheelZoomSpeed;

        if (useGamepad && input.padConnected(padSlot)) {
            immutable Vec2 rs = input.padRightStick(padSlot);
            yaw      += rs.x * padRotateSpeed * dt;
            pitch    -= rs.y * padRotateSpeed * 0.6f * dt;
            distance += (input.padLeftTrigger(padSlot) - input.padRightTrigger(padSlot)) * padZoomSpeed * dt;
        }

        pitch    = clamp(pitch, minPitch, maxPitch);
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
    float mouseSensitivity = 0.008f;
    float padLookSpeed = 2.2f;
    uint  padSlot = 0;
    bool  useGamepad = true;

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
        // cross((fx,fy,fz),(0,1,0)) = (-fz, 0, fx); |cross| = |cos(pitch)|.
        immutable f = forward();
        immutable len = cast(float) (f.z * f.z + f.x * f.x);
        if (len < EPS) return Vec3(1, 0, 0);
        immutable invL = 1.0f / cast(float)(cos(pitch));
        return Vec3(-f.z * invL, 0, f.x * invL);
    }

    void update(ref const InputState input, float dt, ref Camera camera) {
        yaw   += input.mdx() * mouseSensitivity;
        pitch -= input.mdy() * mouseSensitivity;

        immutable bool padActive = useGamepad && input.padConnected(padSlot);
        if (padActive) {
            immutable Vec2 rs = input.padRightStick(padSlot);
            yaw   += rs.x * padLookSpeed * dt;
            pitch -= rs.y * padLookSpeed * dt;
        }
        pitch = clamp(pitch, -cast(float) PI_2 + EPS, cast(float) PI_2 - EPS);

        immutable bool padSprint = padActive &&
            (input.padDown(PadButton.leftStick, padSlot) || input.padDown(PadButton.a, padSlot));
        immutable float mul = (input.keyDown(Key.lshift) || padSprint) ? sprintMultiplier : 1.0f;
        immutable speed = moveSpeed * mul * dt;
        immutable f = forward();
        immutable r = right();

        Vec3 move = Vec3(0, 0, 0);
        if (input.keyDown(Key.w)) move = move + f;
        if (input.keyDown(Key.s)) move = move - f;
        if (input.keyDown(Key.d)) move = move + r;
        if (input.keyDown(Key.a)) move = move - r;
        if (input.keyDown(Key.space)) move.y += 1;
        if (input.keyDown(Key.lctrl)) move.y -= 1;

        if (padActive) {
            immutable Vec2 ls = input.padLeftStick(padSlot);
            move = move + r * ls.x - f * ls.y;
            if (input.padDown(PadButton.rb, padSlot)) move.y += 1.0f;
            if (input.padDown(PadButton.lb, padSlot)) move.y -= 1.0f;
        }

        immutable float moveLenSq = move.lengthSquared();
        if (moveLenSq > 1.0f) {
            move = move.normalized();
        }
        if (moveLenSq > EPS * EPS) {
            position = position + move * speed;
        }

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
    float padSensitivity = 2.2f;
    uint  padSlot = 0;
    bool  useGamepad = true;

    static FirstPersonCamera create(float yaw = 0, float pitch = 0) {
        FirstPersonCamera c;
        c.yaw   = yaw;
        c.pitch = pitch;
        return c;
    }

    Vec3 forward() const pure nothrow @nogc {
        return Vec3(cos(pitch) * cos(yaw), sin(pitch), cos(pitch) * sin(yaw));
    }

    /// Update look direction from mouse delta and point `camera` from `eyePosition` forward.
    void update(ref const InputState input, Vec3 eyePosition, ref Camera camera) {
        update(input, 0.0f, eyePosition, camera);
    }

    /// Update look direction from mouse delta and gamepad right stick, scaled by `dt`.
    void update(ref const InputState input, float dt, Vec3 eyePosition, ref Camera camera) {
        yaw   += input.mdx() * mouseSensitivity;
        pitch -= input.mdy() * mouseSensitivity;
        if (useGamepad && dt > 0.0f && input.padConnected(padSlot)) {
            immutable Vec2 rs = input.padRightStick(padSlot);
            yaw   += rs.x * padSensitivity * dt;
            pitch -= rs.y * padSensitivity * dt;
        }
        pitch  = clamp(pitch, -cast(float) PI_2 + EPS, cast(float) PI_2 - EPS);
        camera.lookAt(eyePosition, eyePosition + forward());
    }
}

@safe unittest {
    import bindings.sdl3;

    InputState input;
    input.gamepads.pads[0].connected = true;
    input.gamepads.pads[0].id = 1;

    SDL_Event ev = SDL_Event.init;
    ev.type = SDL_EVENT_GAMEPAD_AXIS_MOTION;
    ev.gaxis.which = 1;
    ev.gaxis.axis = SDL_GamepadAxis.SDL_GAMEPAD_AXIS_RIGHTX;
    ev.gaxis.value = 32767;
    input.processEvent(ev);

    Camera cam;
    auto orbit = OrbitCamera.create(Vec3(0, 0, 0), 10.0f);
    immutable float yaw0 = orbit.yaw;
    orbit.update(input, 0.5f, cam);
    assert(orbit.yaw > yaw0);

    auto fp = FirstPersonCamera.create();
    immutable float fpYaw0 = fp.yaw;
    fp.update(input, 0.5f, Vec3(0, 1.8f, 0), cam);
    assert(fp.yaw > fpYaw0);

    ev.gaxis.axis = SDL_GamepadAxis.SDL_GAMEPAD_AXIS_LEFTY;
    ev.gaxis.value = -32768; // push left stick forward
    input.processEvent(ev);
    auto fly = FlyCamera.create(Vec3(0, 5, 10));
    immutable float z0 = fly.position.z;
    fly.update(input, 0.5f, cam);
    assert(fly.position.z < z0);
}
