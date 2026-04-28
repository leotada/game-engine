// Marble Run — physics prototype.
//
// A WASD-controlled sphere is pushed by force across a fixed obstacle course
// of ramps and pillars. A "kill zone" sensor below the course teleports the
// marble back to the start; a "win zone" sensor on the final platform
// triggers a victory message. Validates: force input → physics, static
// collisions, sensor (trigger) detection, simple state machine (reset/win).
module demo.marble_run;

import std.format : format;
import std.math : cos, sin, PI;

import engine.app : App;
import bindings.wgpu : WGPUPresentMode;
import engine.gpu.text : FpsCounter, TextRenderer;
import engine.graphics.mesh : Mesh;
import engine.graphics.types : Color4;
import engine.math.mat : Mat4;
import engine.math.vec : RenderVec3 = Vec3;
import engine.platform.input : Key;
import engine.scene.camera : Camera;
import engine.scene.scene3d : Scene3D;

import engine.jph.math.mat44 : Mat44;
import engine.jph.math.quat  : Quat;
import engine.jph.math.vec3  : PhysVec3 = Vec3;
import engine.jph.physics.body.body_creation_settings : BodyCreationSettings;
import engine.jph.physics.body.body_interface         : BodyInterface;
import engine.jph.physics.body.bodyid                 : BodyID;
import engine.jph.physics.body.motiontype             : EMotionType;
import engine.jph.physics.eactivation                 : EActivation;
import engine.jph.physics.physics_system              : PhysicsSystem;
import engine.jph.physics.shape.box_shape             : BoxShape;
import engine.jph.physics.shape.sphere_shape          : SphereShape;

@safe:

private enum SCREEN_W   = 1280;
private enum SCREEN_H   = 720;
private enum PHYS_STEP  = 1.0f / 60.0f;
private enum MAX_SUBSTEPS = 5;

private enum float MARBLE_RADIUS = 0.4f;
private enum float MARBLE_FORCE  = 4500.0f;     // tuned for default density sphere
private enum float JUMP_IMPULSE  = 2200.0f;     // small upward force for Space
private enum float JUMP_COOLDOWN = 0.8f;

private enum PhysVec3 SPAWN = PhysVec3(0.0f, 1.0f, 0.0f);

// ---------------------------------------------------------------------------
// Math helpers (mirrors benchmark.d)
// ---------------------------------------------------------------------------
private RenderVec3 toRenderVec3(PhysVec3 v) pure nothrow @nogc {
    return RenderVec3(v.GetX(), v.GetY(), v.GetZ());
}

private Mat4 toRenderMat4(Mat44 m) pure nothrow @nogc {
    Mat4 result;
    foreach (col; 0 .. 4)
        foreach (row; 0 .. 4)
            result.m[col * 4 + row] = m(cast(uint) row, cast(uint) col);
    return result;
}

// ---------------------------------------------------------------------------
// Render description for a static box piece (cached once at build).
// ---------------------------------------------------------------------------
private struct StaticPiece {
    PhysVec3 center;        // world-space center (also the body position)
    PhysVec3 halfExtent;    // box half-extent
    Quat     rotation;      // world-space rotation
    Color4   color;
}

// ---------------------------------------------------------------------------
// Course layout — built once into PhysicsSystem and a render-side array.
// ---------------------------------------------------------------------------
private struct Course {
    StaticPiece[] pieces;   // for rendering
    BodyID winZone;
    BodyID killZone;
}

private void addStaticBox(ref BodyInterface bi,
                          ref Course course,
                          PhysVec3 center,
                          PhysVec3 halfExtent,
                          Quat rotation,
                          Color4 color,
                          float friction = 0.6f) {
    auto shape = new BoxShape(halfExtent);
    BodyCreationSettings s = BodyCreationSettings(shape, center, rotation, EMotionType.Static);
    s.mFriction    = friction;
    s.mRestitution = 0.0f;
    bi.CreateAndAddBody(s, EActivation.DontActivate);
    course.pieces ~= StaticPiece(center, halfExtent, rotation, color);
}

private BodyID addSensorBox(ref BodyInterface bi,
                            PhysVec3 center,
                            PhysVec3 halfExtent) {
    auto shape = new BoxShape(halfExtent);
    BodyCreationSettings s = BodyCreationSettings(shape, center, Quat.sIdentity(), EMotionType.Static);
    s.mIsSensor    = true;
    s.mFriction    = 0.0f;
    s.mRestitution = 0.0f;
    return bi.CreateAndAddBody(s, EActivation.DontActivate);
}

private Course buildCourse(ref BodyInterface bi) {
    Course course;

    immutable Color4 GROUND   = Color4(0.45f, 0.47f, 0.50f, 1.0f);
    immutable Color4 RAMP     = Color4(0.30f, 0.55f, 0.80f, 1.0f);
    immutable Color4 OBSTACLE = Color4(0.90f, 0.45f, 0.15f, 1.0f);
    immutable Color4 WIN_PAD  = Color4(0.20f, 0.85f, 0.30f, 1.0f);

    // Start platform (top surface at y=0)
    addStaticBox(bi, course,
        PhysVec3(0.0f, -0.5f, 0.0f),
        PhysVec3(4.0f, 0.5f, 3.0f),
        Quat.sIdentity(),
        GROUND);

    // Ramp 1 — descends from start platform toward +X. Tilt -15° around Z.
    immutable float RAMP_TILT = -15.0f * cast(float) PI / 180.0f;
    immutable Quat rampRot = Quat.sRotation(PhysVec3.sAxisZ(), RAMP_TILT);
    addStaticBox(bi, course,
        PhysVec3(9.0f, -1.4f, 0.0f),
        PhysVec3(5.0f, 0.25f, 3.0f),
        rampRot,
        RAMP);

    // Mid platform
    addStaticBox(bi, course,
        PhysVec3(17.5f, -3.1f, 0.0f),
        PhysVec3(3.5f, 0.5f, 3.0f),
        Quat.sIdentity(),
        GROUND);

    // Two pillars on mid platform forcing navigation around them
    addStaticBox(bi, course,
        PhysVec3(17.5f, -1.6f, 1.6f),
        PhysVec3(0.4f, 1.0f, 0.4f),
        Quat.sIdentity(),
        OBSTACLE);
    addStaticBox(bi, course,
        PhysVec3(17.5f, -1.6f, -1.6f),
        PhysVec3(0.4f, 1.0f, 0.4f),
        Quat.sIdentity(),
        OBSTACLE);

    // Ramp 2 — second descent
    addStaticBox(bi, course,
        PhysVec3(26.0f, -4.0f, 0.0f),
        PhysVec3(5.0f, 0.25f, 3.0f),
        rampRot,
        RAMP);

    // Lower platform with a single centered obstacle
    addStaticBox(bi, course,
        PhysVec3(34.5f, -5.7f, 0.0f),
        PhysVec3(3.5f, 0.5f, 3.0f),
        Quat.sIdentity(),
        GROUND);
    addStaticBox(bi, course,
        PhysVec3(34.5f, -4.7f, 0.0f),
        PhysVec3(0.4f, 0.5f, 1.5f),
        Quat.sIdentity(),
        OBSTACLE);

    // Ramp 3 — final descent
    addStaticBox(bi, course,
        PhysVec3(43.0f, -6.6f, 0.0f),
        PhysVec3(5.0f, 0.25f, 3.0f),
        rampRot,
        RAMP);

    // Finish platform (green)
    immutable PhysVec3 finishCenter = PhysVec3(51.5f, -8.3f, 0.0f);
    addStaticBox(bi, course,
        finishCenter,
        PhysVec3(3.5f, 0.5f, 3.0f),
        Quat.sIdentity(),
        WIN_PAD);

    // Win-zone sensor — sits on top of the finish platform
    course.winZone = addSensorBox(bi,
        PhysVec3(finishCenter.GetX(), finishCenter.GetY() + 1.5f, finishCenter.GetZ()),
        PhysVec3(3.0f, 1.0f, 2.5f));

    // Kill-zone sensor — large flat slab well below the entire course
    course.killZone = addSensorBox(bi,
        PhysVec3(25.0f, -30.0f, 0.0f),
        PhysVec3(120.0f, 1.0f, 60.0f));

    return course;
}

// ---------------------------------------------------------------------------
// Marble creation
// ---------------------------------------------------------------------------
private BodyID createMarble(ref BodyInterface bi) {
    // The marble uses native Sphere-vs-Box collision!
    auto shape = new SphereShape(MARBLE_RADIUS);
    BodyCreationSettings s = BodyCreationSettings(shape, SPAWN, Quat.sIdentity(), EMotionType.Dynamic);
    // NOTE: EMotionQuality.LinearCast is declared in this JPH port but not
    // wired into the solver yet, so it would silently behave like Discrete.
    // The marble's terminal speed in this course stays well within the
    // Discrete tolerance (no thin walls), so leaving it Discrete is fine.
    s.mFriction      = 0.5f;
    s.mRestitution   = 0.15f;
    s.mLinearDamping  = 0.2f;
    s.mAngularDamping = 0.05f;
    return bi.CreateAndAddBody(s, EActivation.Activate);
}

private void respawn(ref BodyInterface bi, BodyID marble) {
    bi.SetPositionAndRotation(marble, SPAWN, Quat.sIdentity(), EActivation.Activate);
    bi.SetLinearVelocity(marble,  PhysVec3.sZero());
    bi.SetAngularVelocity(marble, PhysVec3.sZero());
}

// ---------------------------------------------------------------------------
// Game state
// ---------------------------------------------------------------------------
private enum GameState { playing, won }

int main() {
    auto app = App.create("Marble Run", SCREEN_W, SCREEN_H);

    auto scene = Scene3D.create(app.gpu);
    scope(exit) scene.destroy();
    auto cubeMesh = Mesh.cube(app.gpu);
    scope(exit) cubeMesh.destroy();
    
    auto sphereMesh = Mesh.sphere(app.gpu);
    scope(exit) sphereMesh.destroy();

    auto text = TextRenderer.create(app.gpu, SCREEN_W, SCREEN_H);
    scope(exit) text.destroy();
    auto fps = FpsCounter.create();

    PhysicsSystem physics;
    physics.Init(64);
    auto bi = &physics.GetBodyInterface();

    auto course = buildCourse(*bi);
    immutable BodyID marble = createMarble(*bi);

    auto camera = Camera.create(0.9f, SCREEN_W, SCREEN_H, 0.1f, 300.0f);

    // Manual orbit-style camera: yaw/pitch/distance follow the marble.
    // We don't use OrbitCamera.update() because it binds W/S to zoom and would
    // collide with the marble's WASD controls.
    float camYaw      = 0.0f;            // facing along +X (toward course end)
    float camPitch    = 0.45f;           // ~26° downward
    float camDistance = 9.0f;
    enum  float CAM_ROT_SPEED = 1.8f;
    enum  float CAM_PITCH_SPEED = 0.9f;
    enum  float CAM_ZOOM_SPEED  = 6.0f;
    enum  float CAM_PITCH_MIN = 0.05f;
    enum  float CAM_PITCH_MAX = 1.4f;
    enum  float CAM_DIST_MIN  = 4.0f;
    enum  float CAM_DIST_MAX  = 25.0f;
    enum  float CAM_MOUSE_SENS = 0.004f;

    GameState state  = GameState.playing;
    float jumpTimer  = 0.0f;
    float winFlash   = 0.0f;
    float accumulator = 0.0f;

    while (app.running()) {
        app.pollEvents();
        immutable rawDt = fps.tick();
        immutable float dt = rawDt > 0.1f ? 0.1f : rawDt;

        if (app.input.keyPressed(Key.escape))
            break;

        // ---- Camera control (arrows + right-mouse + Q/E zoom) -------------
        if (app.input.keyDown(Key.left))  camYaw   -= CAM_ROT_SPEED * dt;
        if (app.input.keyDown(Key.right)) camYaw   += CAM_ROT_SPEED * dt;
        if (app.input.keyDown(Key.up))    camPitch += CAM_PITCH_SPEED * dt;
        if (app.input.keyDown(Key.down))  camPitch -= CAM_PITCH_SPEED * dt;
        if (app.input.keyDown(Key.q))     camDistance -= CAM_ZOOM_SPEED * dt;
        if (app.input.keyDown(Key.e))     camDistance += CAM_ZOOM_SPEED * dt;
        camYaw   += app.input.mdx() * CAM_MOUSE_SENS;
        camPitch -= app.input.mdy() * CAM_MOUSE_SENS;
        if (camPitch < CAM_PITCH_MIN) camPitch = CAM_PITCH_MIN;
        if (camPitch > CAM_PITCH_MAX) camPitch = CAM_PITCH_MAX;
        if (camDistance < CAM_DIST_MIN) camDistance = CAM_DIST_MIN;
        if (camDistance > CAM_DIST_MAX) camDistance = CAM_DIST_MAX;

        // ---- Reset on R (works in any state) ------------------------------
        if (app.input.keyPressed(Key.r)) {
            respawn(*bi, marble);
            state = GameState.playing;
            winFlash = 0.0f;
        }

        // ---- Apply input force to marble (camera-relative) ----------------
        if (state == GameState.playing) {
            // Horizontal forward = direction the camera looks (XZ-projected).
            immutable float fx = cos(camYaw);
            immutable float fz = sin(camYaw);
            // Right = forward rotated -90° around Y.
            immutable float rx =  fz;
            immutable float rz = -fx;

            float dx = 0, dz = 0;
            if (app.input.keyDown(Key.w)) { dx += fx; dz += fz; }
            if (app.input.keyDown(Key.s)) { dx -= fx; dz -= fz; }
            if (app.input.keyDown(Key.d)) { dx -= rx; dz -= rz; }
            if (app.input.keyDown(Key.a)) { dx += rx; dz += rz; }

            immutable float lenSq = dx * dx + dz * dz;
            if (lenSq > 0.0001f) {
                import std.math : sqrt;
                immutable float inv = 1.0f / cast(float) sqrt(cast(double) lenSq);
                immutable PhysVec3 force = PhysVec3(dx * inv * MARBLE_FORCE, 0.0f,
                                                    dz * inv * MARBLE_FORCE);
                bi.AddForce(marble, force, EActivation.Activate);
            }

            jumpTimer -= dt;
            if (jumpTimer < 0.0f) jumpTimer = 0.0f;
            if (app.input.keyPressed(Key.space) && jumpTimer <= 0.0f) {
                bi.AddForce(marble, PhysVec3(0.0f, JUMP_IMPULSE, 0.0f), EActivation.Activate);
                jumpTimer = JUMP_COOLDOWN;
            }
        }

        // ---- Fixed-timestep physics ---------------------------------------
        accumulator += dt;
        if (accumulator > PHYS_STEP * MAX_SUBSTEPS)
            accumulator = PHYS_STEP * MAX_SUBSTEPS;
        uint subSteps = 0;
        while (accumulator >= PHYS_STEP && subSteps < MAX_SUBSTEPS) {
            physics.Step(PHYS_STEP);
            accumulator -= PHYS_STEP;
            ++subSteps;
        }

        // ---- Sensor detection ---------------------------------------------
        bool hitKill = false;
        bool hitWin  = false;
        foreach (ref manifold; physics.GetContactManifolds()) {
            immutable bool touchesMarble =
                manifold.mBody1ID == marble || manifold.mBody2ID == marble;
            if (!touchesMarble) continue;
            immutable BodyID other = (manifold.mBody1ID == marble)
                ? manifold.mBody2ID : manifold.mBody1ID;
            if (other == course.killZone) hitKill = true;
            else if (other == course.winZone) hitWin = true;
        }
        // Defensive: if the marble somehow ends up far below the kill zone
        // without a manifold (e.g., teleported by a previous frame), respawn.
        immutable PhysVec3 marblePos = bi.GetCenterOfMassPosition(marble);
        if (marblePos.GetY() < -25.0f) hitKill = true;

        if (hitKill && state == GameState.playing) {
            respawn(*bi, marble);
        }
        if (hitWin && state == GameState.playing) {
            state = GameState.won;
            winFlash = 0.0f;
        }
        if (state == GameState.won) winFlash += dt;

        // ---- Camera follow -------------------------------------------------
        immutable float cp = cos(camPitch);
        immutable RenderVec3 marbleRender = toRenderVec3(marblePos);
        immutable RenderVec3 eye = RenderVec3(
            marbleRender.x - cos(camYaw) * cp * camDistance,
            marbleRender.y + sin(camPitch) * camDistance + 0.5f,
            marbleRender.z - sin(camYaw) * cp * camDistance,
        );
        camera.lookAt(eye, RenderVec3(marbleRender.x, marbleRender.y + 0.3f, marbleRender.z));

        // ---- Render --------------------------------------------------------
        auto frame = app.beginFrame(Color4(0.06f, 0.08f, 0.12f, 1.0f));
        if (!frame.valid) continue;

        scene.begin(camera);

        // Static course pieces — use cached transforms.
        // For axis-aligned pieces the simple draw(pos,scale,color) is enough,
        // but rotated ramps need the full matrix path.
        foreach (ref p; course.pieces) {
            // Build a model matrix from (translation, rotation, full extent).
            // BoxShape uses half-extents; the cube mesh is unit-extent, so the
            // visual scale equals 2 × half-extent.
            immutable Mat4 t = Mat4.translation(p.center.GetX(), p.center.GetY(), p.center.GetZ());
            immutable Mat4 s = Mat4.scaling(p.halfExtent.GetX() * 2.0f,
                                            p.halfExtent.GetY() * 2.0f,
                                            p.halfExtent.GetZ() * 2.0f);
            // Convert quaternion to Mat44 then to render Mat4.
            immutable Mat44 r44 = Mat44.sRotation(p.rotation);
            immutable Mat4  r   = toRenderMat4(r44);
            scene.drawMatrix(cubeMesh, t * r * s, p.color);
        }

        // Marble — drawn with physics world transform so orientation 
        // matches the physical sphere rolling down the track.
        immutable Mat44 marbleXform = bi.GetWorldTransform(marble);
        immutable Mat4  marbleModel = toRenderMat4(marbleXform)
            * Mat4.scaling(MARBLE_RADIUS * 2.0f, MARBLE_RADIUS * 2.0f, MARBLE_RADIUS * 2.0f);
        scene.drawMatrix(sphereMesh, marbleModel, Color4(0.95f, 0.85f, 0.20f, 1.0f));

        scene.end(frame);

        // ---- HUD -----------------------------------------------------------
        text.beginFrame();
        text.drawText(frame, fps.text(), 10, 10, 2);
        text.drawText(frame, "Marble Run — reach the green pad", SCREEN_W / 2 - 220, 10, 2);
        text.drawText(frame, "WASD: roll  Space: hop  Arrows/Mouse: camera  Q/E: zoom  R: reset  Esc: quit",
                      10, SCREEN_H - 28, 2);

        immutable PhysVec3 v = bi.GetLinearVelocity(marble);
        immutable float speed = cast(float) (() {
            immutable double sx = v.GetX(), sy = v.GetY(), sz = v.GetZ();
            import std.math : sqrt;
            return sqrt(sx * sx + sy * sy + sz * sz);
        }());
        text.drawText(frame, format("pos=(%.1f, %.1f, %.1f)  speed=%.1f m/s",
                      marblePos.GetX(), marblePos.GetY(), marblePos.GetZ(), speed),
                      10, 36, 2);

        if (state == GameState.won) {
            // Blink the message slightly so it reads as celebratory.
            immutable bool blink = (cast(int)(winFlash * 4) & 1) == 0;
            if (blink)
                text.drawText(frame, "YOU WIN!", SCREEN_W / 2 - 80, SCREEN_H / 2 - 40, 4);
            text.drawText(frame, "Press R to play again",
                          SCREEN_W / 2 - 170, SCREEN_H / 2 + 30, 2);
        }

        app.endFrame(frame);
    }
    return 0;
}
