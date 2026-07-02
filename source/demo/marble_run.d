// Marble Run — Box3D gameplay prototype.
module demo.marble_run;

import std.format : format;
import std.math : PI, cos, sin, sqrt;

import bindings.box3d : b3BodyId;
import bindings.wgpu : WGPUPresentMode;
import engine.app : App;
import engine.ecs.store : EntityId;
import engine.gpu.text : FpsCounter, TextRenderer;
import engine.graphics.mesh : Mesh;
import engine.graphics.types : Color4;
import engine.math.mat : Mat4;
import engine.math.quat : Quat;
import engine.math.vec : Vec3;
import engine.physics;
import engine.platform.input : Key;
import engine.scene.camera : Camera;
import engine.scene.scene3d : Scene3D;

@safe:

private enum SCREEN_W = 1280;
private enum SCREEN_H = 720;
private enum PHYS_STEP = 1.0f / 60.0f;
private enum MAX_SUBSTEPS = 5;

private enum float MARBLE_RADIUS = 0.4f;
private enum float MARBLE_FORCE = 8.0f;
private enum float JUMP_IMPULSE = 1.2f;
private enum float JUMP_COOLDOWN = 0.8f;

private enum EntityId MARBLE_ENTITY = 1;
private enum EntityId WIN_ENTITY = 2;
private enum EntityId KILL_ENTITY = 3;

private immutable Vec3 SPAWN = Vec3(0.0f, 1.0f, 0.0f);

private Mat4 modelMatrix(Vec3 center, Quat rotation, Vec3 scale) {
    return Mat4.translation(center.x, center.y, center.z) *
        rotation.toMat4() *
        Mat4.scaling(scale.x, scale.y, scale.z);
}

private Mat4 bodyModelMatrix(b3BodyId body, Vec3 scale) {
    immutable transform = readBodyTransform(body);
    return modelMatrix(transform.position, transform.rotation, scale);
}

private struct StaticPiece {
    Vec3 center;
    Vec3 halfExtent;
    Quat rotation;
    Color4 color;
}

private struct Course {
    StaticPiece[] pieces;
}

private void addStaticBox(ref PhysicsWorld physics,
                          ref Course course,
                          Vec3 center,
                          Vec3 halfExtent,
                          Quat rotation,
                          Color4 color,
                          float friction = 0.6f) {
    createStaticBox(physics, center, halfExtent, rotation, noPhysicsEntity, friction);
    course.pieces ~= StaticPiece(center, halfExtent, rotation, color);
}

private void buildCourse(ref PhysicsWorld physics, ref Course course) {
    immutable Color4 ground = Color4(0.45f, 0.47f, 0.50f, 1.0f);
    immutable Color4 ramp = Color4(0.30f, 0.55f, 0.80f, 1.0f);
    immutable Color4 obstacle = Color4(0.90f, 0.45f, 0.15f, 1.0f);
    immutable Color4 winPad = Color4(0.20f, 0.85f, 0.30f, 1.0f);

    addStaticBox(physics, course, Vec3(0.0f, -0.5f, 0.0f), Vec3(4.0f, 0.5f, 3.0f), Quat.init, ground);

    immutable float rampTilt = -15.0f * cast(float) PI / 180.0f;
    immutable Quat rampRot = Quat.fromAxisAngle(Vec3(0.0f, 0.0f, 1.0f), rampTilt);
    addStaticBox(physics, course, Vec3(9.0f, -1.4f, 0.0f), Vec3(5.0f, 0.25f, 3.0f), rampRot, ramp);

    addStaticBox(physics, course, Vec3(17.5f, -3.1f, 0.0f), Vec3(3.5f, 0.5f, 3.0f), Quat.init, ground);
    addStaticBox(physics, course, Vec3(17.5f, -1.6f, 1.6f), Vec3(0.4f, 1.0f, 0.4f), Quat.init, obstacle);
    addStaticBox(physics, course, Vec3(17.5f, -1.6f, -1.6f), Vec3(0.4f, 1.0f, 0.4f), Quat.init, obstacle);

    addStaticBox(physics, course, Vec3(26.0f, -4.0f, 0.0f), Vec3(5.0f, 0.25f, 3.0f), rampRot, ramp);
    addStaticBox(physics, course, Vec3(34.5f, -5.7f, 0.0f), Vec3(3.5f, 0.5f, 3.0f), Quat.init, ground);
    addStaticBox(physics, course, Vec3(34.5f, -4.7f, 0.0f), Vec3(0.4f, 0.5f, 1.5f), Quat.init, obstacle);

    addStaticBox(physics, course, Vec3(43.0f, -6.6f, 0.0f), Vec3(5.0f, 0.25f, 3.0f), rampRot, ramp);

    immutable Vec3 finishCenter = Vec3(51.5f, -8.3f, 0.0f);
    addStaticBox(physics, course, finishCenter, Vec3(3.5f, 0.5f, 3.0f), Quat.init, winPad);

    createSensorBox(physics, Vec3(finishCenter.x, finishCenter.y + 1.5f, finishCenter.z),
        Vec3(3.0f, 1.0f, 2.5f), WIN_ENTITY);
    createSensorBox(physics, Vec3(25.0f, -30.0f, 0.0f), Vec3(120.0f, 1.0f, 60.0f), KILL_ENTITY);
}

private b3BodyId createMarble(ref PhysicsWorld physics) {
    immutable marble = createDynamicSphere(physics, SPAWN, MARBLE_RADIUS, 1.0f, MARBLE_ENTITY, 0.5f);
    setLinearDamping(marble, 0.2f);
    setAngularDamping(marble, 0.05f);
    return marble;
}

private void respawn(b3BodyId marble) {
    writeBodyTransform(marble, SPAWN, Quat.init);
    setLinearVelocity(marble, Vec3(0.0f, 0.0f, 0.0f));
    setAngularVelocity(marble, Vec3(0.0f, 0.0f, 0.0f));
}

private struct SensorState {
    bool hitKill;
    bool hitWin;
}

private void onSensorEnter(PhysicsSensorEvent event, void* context) nothrow @nogc @trusted {
    auto state = cast(SensorState*) context;
    if (state is null || event.visitorEntity != MARBLE_ENTITY)
        return;
    if (event.sensorEntity == KILL_ENTITY)
        state.hitKill = true;
    else if (event.sensorEntity == WIN_ENTITY)
        state.hitWin = true;
}

private enum GameState { playing, won }

int main() {
    auto app = App.create("Marble Run", SCREEN_W, SCREEN_H, WGPUPresentMode.fifo);

    auto scene = Scene3D.create(app.gpu);
    scope(exit) scene.destroy();
    auto cubeMesh = Mesh.cube(app.gpu);
    scope(exit) cubeMesh.destroy();
    auto sphereMesh = Mesh.sphere(app.gpu);
    scope(exit) sphereMesh.destroy();
    auto text = TextRenderer.create(app.gpu, SCREEN_W, SCREEN_H);
    scope(exit) text.destroy();
    auto fps = FpsCounter.create();

    auto physics = PhysicsWorld(Vec3(0.0f, -9.81f, 0.0f));
    Course course;
    buildCourse(physics, course);
    immutable b3BodyId marble = createMarble(physics);

    SensorState sensors;
    ContactListener listener;
    listener.onSensorEnter = &onSensorEnter;
    listener.context = &sensors;

    auto camera = Camera.create(0.9f, SCREEN_W, SCREEN_H, 0.1f, 300.0f);

    float camYaw = 0.0f;
    float camPitch = 0.45f;
    float camDistance = 9.0f;
    enum float CAM_ROT_SPEED = 1.8f;
    enum float CAM_PITCH_SPEED = 0.9f;
    enum float CAM_ZOOM_SPEED = 6.0f;
    enum float CAM_PITCH_MIN = 0.05f;
    enum float CAM_PITCH_MAX = 1.4f;
    enum float CAM_DIST_MIN = 4.0f;
    enum float CAM_DIST_MAX = 25.0f;
    enum float CAM_MOUSE_SENS = 0.004f;

    GameState state = GameState.playing;
    float jumpTimer = 0.0f;
    float winFlash = 0.0f;
    float accumulator = 0.0f;

    while (app.running()) {
        app.pollEvents();
        immutable rawDt = fps.tick();
        immutable float dt = rawDt > 0.1f ? 0.1f : rawDt;

        if (app.input.keyPressed(Key.escape))
            break;

        if (app.input.keyDown(Key.left)) camYaw -= CAM_ROT_SPEED * dt;
        if (app.input.keyDown(Key.right)) camYaw += CAM_ROT_SPEED * dt;
        if (app.input.keyDown(Key.up)) camPitch += CAM_PITCH_SPEED * dt;
        if (app.input.keyDown(Key.down)) camPitch -= CAM_PITCH_SPEED * dt;
        if (app.input.keyDown(Key.q)) camDistance -= CAM_ZOOM_SPEED * dt;
        if (app.input.keyDown(Key.e)) camDistance += CAM_ZOOM_SPEED * dt;
        camYaw += app.input.mdx() * CAM_MOUSE_SENS;
        camPitch -= app.input.mdy() * CAM_MOUSE_SENS;
        if (camPitch < CAM_PITCH_MIN) camPitch = CAM_PITCH_MIN;
        if (camPitch > CAM_PITCH_MAX) camPitch = CAM_PITCH_MAX;
        if (camDistance < CAM_DIST_MIN) camDistance = CAM_DIST_MIN;
        if (camDistance > CAM_DIST_MAX) camDistance = CAM_DIST_MAX;

        if (app.input.keyPressed(Key.r)) {
            respawn(marble);
            state = GameState.playing;
            sensors.hitKill = false;
            sensors.hitWin = false;
            winFlash = 0.0f;
        }

        if (state == GameState.playing) {
            immutable float fx = cos(camYaw);
            immutable float fz = sin(camYaw);
            immutable float rx = fz;
            immutable float rz = -fx;

            float dx = 0.0f;
            float dz = 0.0f;
            if (app.input.keyDown(Key.w)) { dx += fx; dz += fz; }
            if (app.input.keyDown(Key.s)) { dx -= fx; dz -= fz; }
            if (app.input.keyDown(Key.d)) { dx -= rx; dz -= rz; }
            if (app.input.keyDown(Key.a)) { dx += rx; dz += rz; }

            immutable float lenSq = dx * dx + dz * dz;
            if (lenSq > 0.0001f) {
                immutable inv = 1.0f / cast(float) sqrt(cast(double) lenSq);
                applyForceToCenter(marble, Vec3(dx * inv * MARBLE_FORCE, 0.0f, dz * inv * MARBLE_FORCE));
            }

            jumpTimer -= dt;
            if (jumpTimer < 0.0f) jumpTimer = 0.0f;
            if (app.input.keyPressed(Key.space) && jumpTimer <= 0.0f) {
                applyLinearImpulseToCenter(marble, Vec3(0.0f, JUMP_IMPULSE, 0.0f));
                jumpTimer = JUMP_COOLDOWN;
            }
        }

        accumulator += dt;
        if (accumulator > PHYS_STEP * MAX_SUBSTEPS)
            accumulator = PHYS_STEP * MAX_SUBSTEPS;
        uint subSteps = 0;
        sensors.hitKill = false;
        sensors.hitWin = false;
        while (accumulator >= PHYS_STEP && subSteps < MAX_SUBSTEPS) {
            physics.step(PHYS_STEP, 4);
            drainPhysicsEvents(physics, listener);
            accumulator -= PHYS_STEP;
            ++subSteps;
        }

        immutable Vec3 marblePos = getPosition(marble);
        if (marblePos.y < -25.0f)
            sensors.hitKill = true;

        if (sensors.hitKill && state == GameState.playing)
            respawn(marble);
        if (sensors.hitWin && state == GameState.playing) {
            state = GameState.won;
            winFlash = 0.0f;
        }
        if (state == GameState.won)
            winFlash += dt;

        immutable float cp = cos(camPitch);
        immutable Vec3 eye = Vec3(
            marblePos.x - cos(camYaw) * cp * camDistance,
            marblePos.y + sin(camPitch) * camDistance + 0.5f,
            marblePos.z - sin(camYaw) * cp * camDistance,
        );
        camera.lookAt(eye, Vec3(marblePos.x, marblePos.y + 0.3f, marblePos.z));

        auto frame = app.beginFrame(Color4(0.06f, 0.08f, 0.12f, 1.0f));
        if (!frame.valid)
            continue;

        scene.begin(camera);

        foreach (ref piece; course.pieces) {
            immutable scale = piece.halfExtent * 2.0f;
            scene.drawMatrix(cubeMesh, modelMatrix(piece.center, piece.rotation, scale), piece.color);
        }

        scene.drawMatrix(sphereMesh,
            bodyModelMatrix(marble, Vec3(MARBLE_RADIUS * 2.0f, MARBLE_RADIUS * 2.0f, MARBLE_RADIUS * 2.0f)),
            Color4(0.95f, 0.85f, 0.20f, 1.0f));

        scene.end(frame);

        text.beginFrame();
        text.drawText(frame, fps.text(), 10, 10, 2);
        text.drawText(frame, "Marble Run - reach the green pad", SCREEN_W / 2 - 220, 10, 2);
        text.drawText(frame, "WASD: roll  Space: hop  Arrows/Mouse: camera  Q/E: zoom  R: reset  Esc: quit",
                      10, SCREEN_H - 28, 2);

        immutable Vec3 v = getLinearVelocity(marble);
        immutable float speed = cast(float) sqrt(cast(double)(v.x * v.x + v.y * v.y + v.z * v.z));
        text.drawText(frame, format("pos=(%.1f, %.1f, %.1f)  speed=%.1f m/s",
                      marblePos.x, marblePos.y, marblePos.z, speed),
                      10, 36, 2);

        if (state == GameState.won) {
            immutable bool blink = (cast(int)(winFlash * 4) & 1) == 0;
            if (blink)
                text.drawText(frame, "YOU WIN!", SCREEN_W / 2 - 80, SCREEN_H / 2 - 40, 4);
            text.drawText(frame, "Press R to play again", SCREEN_W / 2 - 170, SCREEN_H / 2 + 30, 2);
        }

        app.endFrame(frame);
    }

    return 0;
}
