/// Pong 3D — Box3D arcade demo with spark bursts on hits.
/// W/S or Up/Down: move paddle  |  R: reset  |  Esc: quit
module demo.pong3d;

import std.format : format;
import std.math : PI, fabs, sin;
import std.random : Random, uniform, unpredictableSeed;

import bindings.box3d : b3BodyId;
import bindings.wgpu : WGPUPresentMode;
import engine.app : App;
import engine.audio : AudioClip, AudioEngine;
import engine.devtools.gizmos : GizmoRenderer;
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

private enum float TABLE_HALF_X = 9.0f;
private enum float TABLE_HALF_Z = 5.0f;
private enum float TABLE_Y = 0.0f;
private enum float WALL_THICK = 0.25f;
private enum float WALL_HEIGHT = 1.2f;

private enum float PADDLE_HALF_X = 0.25f;
private enum float PADDLE_HALF_Y = 0.45f;
private enum float PADDLE_HALF_Z = 1.1f;
private enum float PADDLE_SPEED = 14.0f;
private enum float AI_SPEED = 10.0f;
private enum float PADDLE_Z_LIMIT = TABLE_HALF_Z - PADDLE_HALF_Z - 0.15f;

private enum float BALL_RADIUS = 0.28f;
private enum float BALL_SPEED = 12.0f;
private enum float BALL_SPEED_MAX = 22.0f;
private enum float BALL_MIN_VX = 7.0f;   // prevents endless Z-wall / vertical stalls
private enum float BALL_MAX_VY = 1.5f;
private enum float HIT_THRESHOLD = 1.5f;

private enum EntityId BALL_ENTITY = 1;
private enum EntityId PLAYER_ENTITY = 2;
private enum EntityId AI_ENTITY = 3;
private enum EntityId GOAL_LEFT_ENTITY = 4;
private enum EntityId GOAL_RIGHT_ENTITY = 5;
private enum EntityId WALL_ENTITY = 6;

private immutable Color4 COL_TABLE = Color4(0.18f, 0.20f, 0.28f, 1.0f);
private immutable Color4 COL_WALL = Color4(0.35f, 0.65f, 1.1f, 1.0f);
private immutable Color4 COL_PLAYER = Color4(0.35f, 1.2f, 1.3f, 1.0f);
private immutable Color4 COL_AI = Color4(1.3f, 0.40f, 0.95f, 1.0f);
private immutable Color4 COL_BALL = Color4(1.4f, 1.3f, 0.95f, 1.0f);
private immutable Color4 COL_SPARK_PADDLE = Color4(1.3f, 0.95f, 0.35f, 1.0f);
private immutable Color4 COL_SPARK_WALL = Color4(0.45f, 0.85f, 1.4f, 1.0f);
private immutable Color4 COL_SPARK_GOAL = Color4(1.4f, 0.45f, 0.85f, 1.0f);

// ---------------------------------------------------------------------------
// Procedural SFX (gameplay — GC ok)
// ---------------------------------------------------------------------------

private enum int SFX_RATE = 48000;

private float[] makeTone(float freqHz, float durationSec, float volume,
                         float attack = 0.005f, float release = 0.04f) {
    immutable n = cast(int)(durationSec * SFX_RATE);
    if (n <= 0)
        return null;
    auto pcm = new float[](n * 2);
    foreach (i; 0 .. n) {
        immutable t = cast(float) i / SFX_RATE;
        float env = 1.0f;
        if (t < attack)
            env = t / attack;
        immutable rem = durationSec - t;
        if (rem < release)
            env *= rem / release;
        immutable s = sin(2.0f * cast(float) PI * freqHz * t) * volume * env;
        pcm[i * 2 + 0] = s;
        pcm[i * 2 + 1] = s;
    }
    return pcm;
}

private float[] concatPcm(float[] a, float[] b) {
    return a ~ b;
}

private struct PongSfx {
    AudioClip paddle;
    AudioClip wall;
    AudioClip goal;

    static PongSfx create() {
        PongSfx s;
        s.paddle = AudioClip.fromInterleavedF32(makeTone(920.0f, 0.07f, 0.35f));
        s.wall = AudioClip.fromInterleavedF32(makeTone(280.0f, 0.055f, 0.28f, 0.002f, 0.035f));
        s.goal = AudioClip.fromInterleavedF32(
            concatPcm(makeTone(523.25f, 0.12f, 0.4f), makeTone(784.0f, 0.18f, 0.38f)));
        return s;
    }

    void destroy() {
        paddle.destroy();
        wall.destroy();
        goal.destroy();
    }
}

private Mat4 modelMatrix(Vec3 center, Quat rotation, Vec3 scale) {
    return Mat4.translation(center.x, center.y, center.z) *
        rotation.toMat4() *
        Mat4.scaling(scale.x, scale.y, scale.z);
}

private Mat4 bodyModelMatrix(b3BodyId body, Vec3 scale) {
    immutable transform = readBodyTransform(body);
    return modelMatrix(transform.position, transform.rotation, scale);
}

// ---------------------------------------------------------------------------
// Arena visuals
// ---------------------------------------------------------------------------

private struct ArenaPiece {
    Vec3 center;
    Vec3 halfExtent;
    Color4 color;
}

private void addStaticVisual(ref PhysicsWorld physics,
                             ref ArenaPiece[] pieces,
                             Vec3 center,
                             Vec3 halfExtent,
                             Color4 color,
                             float friction,
                             float restitution,
                             bool hitEvents,
                             EntityId entityId = WALL_ENTITY) {
    createStaticBox(physics, center, halfExtent, entityId, friction, restitution, hitEvents);
    pieces ~= ArenaPiece(center, halfExtent, color);
}

private void buildArena(ref PhysicsWorld physics, ref ArenaPiece[] pieces) {
    // Floor
    addStaticVisual(physics, pieces,
        Vec3(0.0f, TABLE_Y - 0.15f, 0.0f),
        Vec3(TABLE_HALF_X + 0.5f, 0.15f, TABLE_HALF_Z + 0.5f),
        COL_TABLE, 0.4f, 0.85f, false);

    // Side walls (±Z) — open top so the elevated camera can see the court
    addStaticVisual(physics, pieces,
        Vec3(0.0f, TABLE_Y + WALL_HEIGHT * 0.5f, TABLE_HALF_Z + WALL_THICK),
        Vec3(TABLE_HALF_X + 0.5f, WALL_HEIGHT * 0.5f, WALL_THICK),
        COL_WALL, 0.2f, 0.95f, false);
    addStaticVisual(physics, pieces,
        Vec3(0.0f, TABLE_Y + WALL_HEIGHT * 0.5f, -(TABLE_HALF_Z + WALL_THICK)),
        Vec3(TABLE_HALF_X + 0.5f, WALL_HEIGHT * 0.5f, WALL_THICK),
        COL_WALL, 0.2f, 0.95f, false);

    // Invisible ceiling (physics only) — a visible roof blocked the camera view
    createStaticBox(physics,
        Vec3(0.0f, TABLE_Y + WALL_HEIGHT + 0.15f, 0.0f),
        Vec3(TABLE_HALF_X + 0.5f, 0.1f, TABLE_HALF_Z + 0.5f),
        WALL_ENTITY, 0.1f, 0.9f, false);

    // Goal sensors just past the paddle lines
    createSensorBox(physics,
        Vec3(-(TABLE_HALF_X + 1.2f), TABLE_Y + 0.6f, 0.0f),
        Vec3(0.4f, 0.9f, TABLE_HALF_Z + 0.5f),
        GOAL_LEFT_ENTITY);
    createSensorBox(physics,
        Vec3(TABLE_HALF_X + 1.2f, TABLE_Y + 0.6f, 0.0f),
        Vec3(0.4f, 0.9f, TABLE_HALF_Z + 0.5f),
        GOAL_RIGHT_ENTITY);
}

// ---------------------------------------------------------------------------
// Sparks (gameplay — dynamic allocation OK)
// ---------------------------------------------------------------------------

private struct Spark {
    Vec3 pos;
    Vec3 vel;
    Color4 color;
    float life = 0;
    float maxLife = 1;
    float size = 0.08f;
}

private struct Sparks {
    Spark[] active;
    Random rng;

    this(uint seed) {
        rng = Random(seed);
    }

    void burst(Vec3 origin, Vec3 normal, float speed, Color4 color, int count) {
        immutable n = normal.lengthSquared() > 0.0001f ? normal.normalized() : Vec3(0, 1, 0);
        immutable baseSpeed = 2.0f + speed * 0.35f;
        foreach (_; 0 .. count) {
            immutable spreadX = uniform(-1.0f, 1.0f, rng);
            immutable spreadY = uniform(0.1f, 1.0f, rng);
            immutable spreadZ = uniform(-1.0f, 1.0f, rng);
            immutable dir = (n + Vec3(spreadX, spreadY, spreadZ) * 0.85f).normalized();
            immutable life = uniform(0.25f, 0.7f, rng);
            active ~= Spark(
                origin,
                dir * (baseSpeed * uniform(0.6f, 1.4f, rng)),
                color,
                life,
                life,
                uniform(0.04f, 0.12f, rng),
            );
        }
    }

    void trail(Vec3 origin, Vec3 vel, Color4 color) {
        if (vel.lengthSquared() < 4.0f)
            return;
        immutable back = vel.normalized() * -0.15f;
        active ~= Spark(
            origin + back,
            vel * 0.05f + Vec3(uniform(-0.5f, 0.5f, rng), uniform(0.2f, 1.0f, rng), uniform(-0.5f, 0.5f, rng)),
            color,
            0.18f,
            0.18f,
            0.05f,
        );
    }

    void update(float dt) {
        size_t write = 0;
        foreach (ref s; active) {
            s.life -= dt;
            if (s.life <= 0)
                continue;
            s.vel.y -= 6.0f * dt;
            s.vel = s.vel * (1.0f - 2.2f * dt);
            s.pos = s.pos + s.vel * dt;
            active[write++] = s;
        }
        active.length = write;
    }

    void draw(ref Scene3D scene, ref Mesh cube, ref GizmoRenderer gizmos) {
        foreach (ref s; active) {
            immutable t = s.life / s.maxLife;
            // colored3d ignores alpha — fade via RGB intensity; gizmos keep alpha
            immutable meshColor = Color4(s.color.r * t, s.color.g * t, s.color.b * t, 1.0f);
            immutable lineColor = Color4(s.color.r * t, s.color.g * t, s.color.b * t, t);
            immutable scale = s.size * (0.5f + 0.5f * t);
            scene.draw(cube, s.pos, Vec3(scale, scale, scale), meshColor);
            immutable tip = s.pos + s.vel * 0.04f;
            gizmos.line(s.pos, tip, lineColor);
        }
    }
}

// ---------------------------------------------------------------------------
// Event bridging (@nogc callbacks → game state)
// ---------------------------------------------------------------------------

private struct GameEvents {
    bool scoredLeft;
    bool scoredRight;
    PhysicsHitEvent[48] hits;
    int hitCount;

    void clearFrame() nothrow @nogc {
        scoredLeft = false;
        scoredRight = false;
        hitCount = 0;
    }
}

private void onSensorEnter(PhysicsSensorEvent event, void* context) nothrow @nogc @trusted {
    auto ev = cast(GameEvents*) context;
    if (ev is null || event.visitorEntity != BALL_ENTITY)
        return;
    if (event.sensorEntity == GOAL_LEFT_ENTITY)
        ev.scoredLeft = true;
    else if (event.sensorEntity == GOAL_RIGHT_ENTITY)
        ev.scoredRight = true;
}

private void onContactHit(PhysicsHitEvent event, void* context) nothrow @nogc @trusted {
    auto ev = cast(GameEvents*) context;
    if (ev is null || ev.hitCount >= cast(int) ev.hits.length)
        return;
    if (event.entityA != BALL_ENTITY && event.entityB != BALL_ENTITY)
        return;
    ev.hits[ev.hitCount++] = event;
}

// ---------------------------------------------------------------------------
// Ball / paddle helpers
// ---------------------------------------------------------------------------

private b3BodyId createBall(ref PhysicsWorld physics) {
    return createDynamicSphere(
        physics,
        Vec3(0.0f, TABLE_Y + BALL_RADIUS + 0.05f, 0.0f),
        BALL_RADIUS,
        1.0f,
        BALL_ENTITY,
        0.05f,
        0.98f,
        true,
    );
}

private void serveBall(b3BodyId ball, int towardSign, ref Random rng) {
    immutable z = uniform(-0.45f, 0.45f, rng);
    immutable dir = Vec3(cast(float) towardSign, 0.0f, z).normalized();
    writeBodyTransform(ball, Vec3(0.0f, TABLE_Y + BALL_RADIUS + 0.05f, 0.0f), Quat.init);
    setLinearVelocity(ball, dir * BALL_SPEED);
    setAngularVelocity(ball, Vec3(0, 0, 0));
}

/// Keep the rally playable: always a solid X component, no floor/ceiling loops,
/// and Z bounce can't dominate into an infinite side-wall ping-pong.
private void stabilizeBallVelocity(b3BodyId ball, ref float lastVxSign) {
    auto v = getLinearVelocity(ball);

    if (fabs(v.x) > 0.5f)
        lastVxSign = v.x > 0.0f ? 1.0f : -1.0f;
    if (lastVxSign == 0.0f)
        lastVxSign = 1.0f;

    // Damp vertical bounce (floor/ceiling)
    if (fabs(v.y) > BALL_MAX_VY)
        v.y = v.y > 0.0f ? BALL_MAX_VY : -BALL_MAX_VY;
    v.y *= 0.35f;

    // Escape near-zero X (pure Z / pure Y stalls)
    if (fabs(v.x) < BALL_MIN_VX)
        v.x = lastVxSign * BALL_MIN_VX;

    // Cap |vz| relative to |vx| so wall rallies still advance toward a goal
    immutable maxVz = fabs(v.x) * 1.1f + 1.5f;
    if (fabs(v.z) > maxVz)
        v.z = v.z > 0.0f ? maxVz : -maxVz;

    immutable speed = v.length();
    if (speed > BALL_SPEED_MAX)
        v = v.normalized() * BALL_SPEED_MAX;
    else if (speed < BALL_SPEED * 0.7f && speed > 0.01f)
        v = v.normalized() * (BALL_SPEED * 0.7f);

    // Normalize can shrink vx again — re-assert minimum
    if (fabs(v.x) < BALL_MIN_VX) {
        immutable s = fabs(v.x) > 0.01f ? (v.x > 0.0f ? 1.0f : -1.0f) : lastVxSign;
        v.x = s * BALL_MIN_VX;
        lastVxSign = s;
    }

    setLinearVelocity(ball, v);
}

/// Paddle hits always send the ball toward the opponent with a Z slice from contact.
private void applyPaddleRedirect(b3BodyId ball, b3BodyId paddle, float towardXSign) {
    immutable ballPos = getPosition(ball);
    immutable paddlePos = getPosition(paddle);
    immutable offset = (ballPos.z - paddlePos.z) / PADDLE_HALF_Z; // ~[-1, 1]
    immutable clamped = offset < -1.0f ? -1.0f : (offset > 1.0f ? 1.0f : offset);
    immutable speed = BALL_SPEED + 1.5f;
    setLinearVelocity(ball, Vec3(towardXSign * speed, 0.0f, clamped * speed * 0.75f));
    setAngularVelocity(ball, Vec3(0, 0, 0));
}

private void movePaddle(b3BodyId paddle, float desiredVz, float zLimit) {
    setLinearVelocity(paddle, Vec3(0.0f, 0.0f, desiredVz));
    immutable p = getPosition(paddle);
    if (p.z < -zLimit || p.z > zLimit) {
        immutable clampedZ = p.z < -zLimit ? -zLimit : zLimit;
        writeBodyTransform(paddle, Vec3(p.x, p.y, clampedZ), Quat.init);
        setLinearVelocity(paddle, Vec3(0.0f, 0.0f, 0.0f));
    }
}

private Color4 sparkColorForHit(const PhysicsHitEvent hit) {
    immutable other = hit.entityA == BALL_ENTITY ? hit.entityB : hit.entityA;
    if (other == PLAYER_ENTITY || other == AI_ENTITY)
        return COL_SPARK_PADDLE;
    if (other == GOAL_LEFT_ENTITY || other == GOAL_RIGHT_ENTITY)
        return COL_SPARK_GOAL;
    return COL_SPARK_WALL;
}

private int sparkCountForHit(const PhysicsHitEvent hit) {
    immutable other = hit.entityA == BALL_ENTITY ? hit.entityB : hit.entityA;
    if (other == PLAYER_ENTITY || other == AI_ENTITY)
        return 28;
    return 14;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

int main() {
    auto app = App.create("Pong 3D", SCREEN_W, SCREEN_H, WGPUPresentMode.fifo);

    auto scene = Scene3D.create(app.gpu);
    scope(exit) scene.destroy();
    auto cubeMesh = Mesh.cube(app.gpu);
    scope(exit) cubeMesh.destroy();
    auto sphereMesh = Mesh.sphere(app.gpu);
    scope(exit) sphereMesh.destroy();
    auto text = TextRenderer.create(app.gpu, SCREEN_W, SCREEN_H);
    scope(exit) text.destroy();
    auto fps = FpsCounter.create();
    auto gizmos = GizmoRenderer.create(app.gpu);
    scope(exit) gizmos.destroy();

    auto audio = AudioEngine.create();
    scope(exit) audio.destroy();
    auto sfx = PongSfx.create();
    scope(exit) sfx.destroy();

    auto physics = PhysicsWorld(Vec3(0.0f, 0.0f, 0.0f), false, true, 1);
    physics.setHitEventThreshold(HIT_THRESHOLD);

    ArenaPiece[] pieces;
    buildArena(physics, pieces);

    immutable playerX = -(TABLE_HALF_X - 1.0f);
    immutable aiX = TABLE_HALF_X - 1.0f;
    immutable paddleY = TABLE_Y + PADDLE_HALF_Y + 0.02f;
    immutable paddleHalf = Vec3(PADDLE_HALF_X, PADDLE_HALF_Y, PADDLE_HALF_Z);

    immutable b3BodyId player = createKinematicBox(
        physics, Vec3(playerX, paddleY, 0.0f), paddleHalf, PLAYER_ENTITY, 0.1f, 1.0f, true);
    immutable b3BodyId ai = createKinematicBox(
        physics, Vec3(aiX, paddleY, 0.0f), paddleHalf, AI_ENTITY, 0.1f, 1.0f, true);
    immutable b3BodyId ball = createBall(physics);
    setLinearDamping(ball, 0.0f);
    setAngularDamping(ball, 0.2f);

    GameEvents events;
    ContactListener listener;
    listener.onSensorEnter = &onSensorEnter;
    listener.onContactHit = &onContactHit;
    listener.context = &events;

    auto sparks = Sparks(unpredictableSeed);
    auto camera = Camera.create(0.85f, SCREEN_W, SCREEN_H, 0.1f, 200.0f);
    camera.lookAt(Vec3(0.0f, 12.0f, 14.0f), Vec3(0.0f, 0.3f, 0.0f));

    int scorePlayer = 0;
    int scoreAi = 0;
    int serveSign = 1;
    float lastVxSign = 1.0f;
    float accumulator = 0.0f;
    float trailTimer = 0.0f;
    float goalFlash = 0.0f;

    serveBall(ball, serveSign, sparks.rng);
    lastVxSign = cast(float) serveSign;

    while (app.running()) {
        app.pollEvents();
        immutable rawDt = fps.tick();
        immutable float dt = rawDt > 0.1f ? 0.1f : rawDt;

        if (app.input.keyPressed(Key.escape))
            break;

        if (app.input.keyPressed(Key.r)) {
            scorePlayer = 0;
            scoreAi = 0;
            serveSign = 1;
            serveBall(ball, serveSign, sparks.rng);
            lastVxSign = cast(float) serveSign;
            writeBodyTransform(player, Vec3(playerX, paddleY, 0.0f), Quat.init);
            writeBodyTransform(ai, Vec3(aiX, paddleY, 0.0f), Quat.init);
            sparks.active.length = 0;
            goalFlash = 0.0f;
        }

        // Player paddle
        float playerVz = 0.0f;
        if (app.input.keyDown(Key.w) || app.input.keyDown(Key.up))
            playerVz -= PADDLE_SPEED;
        if (app.input.keyDown(Key.s) || app.input.keyDown(Key.down))
            playerVz += PADDLE_SPEED;
        movePaddle(player, playerVz, PADDLE_Z_LIMIT);

        // Simple AI
        immutable ballPos = getPosition(ball);
        immutable aiPos = getPosition(ai);
        float aiVz = 0.0f;
        immutable dz = ballPos.z - aiPos.z;
        if (fabs(dz) > 0.15f)
            aiVz = (dz > 0 ? 1.0f : -1.0f) * AI_SPEED;
        // Only chase when ball is coming toward AI
        if (getLinearVelocity(ball).x < 0.5f)
            aiVz *= 0.35f;
        movePaddle(ai, aiVz, PADDLE_Z_LIMIT);

        accumulator += dt;
        if (accumulator > PHYS_STEP * MAX_SUBSTEPS)
            accumulator = PHYS_STEP * MAX_SUBSTEPS;

        events.clearFrame();
        uint subSteps = 0;
        while (accumulator >= PHYS_STEP && subSteps < MAX_SUBSTEPS) {
            physics.step(PHYS_STEP, 4);
            drainPhysicsEvents(physics, listener);
            accumulator -= PHYS_STEP;
            ++subSteps;
        }

        // Convert buffered hits → sparks + paddle redirects + SFX
        bool playedPaddle = false;
        bool playedWall = false;
        foreach (i; 0 .. events.hitCount) {
            immutable hit = events.hits[i];
            sparks.burst(hit.point, hit.normal, hit.approachSpeed,
                sparkColorForHit(hit), sparkCountForHit(hit));

            immutable other = hit.entityA == BALL_ENTITY ? hit.entityB : hit.entityA;
            if (other == PLAYER_ENTITY) {
                applyPaddleRedirect(ball, player, 1.0f);
                lastVxSign = 1.0f;
                if (!playedPaddle) {
                    audio.play(sfx.paddle);
                    playedPaddle = true;
                }
            } else if (other == AI_ENTITY) {
                applyPaddleRedirect(ball, ai, -1.0f);
                lastVxSign = -1.0f;
                if (!playedPaddle) {
                    audio.play(sfx.paddle);
                    playedPaddle = true;
                }
            } else if (!playedWall && other != GOAL_LEFT_ENTITY && other != GOAL_RIGHT_ENTITY) {
                audio.play(sfx.wall);
                playedWall = true;
            }
        }

        stabilizeBallVelocity(ball, lastVxSign);

        if (events.scoredLeft || events.scoredRight) {
            if (events.scoredLeft) {
                scoreAi++;
                serveSign = 1;
                sparks.burst(getPosition(ball), Vec3(1, 0.5f, 0), 18.0f, COL_SPARK_GOAL, 48);
            }
            if (events.scoredRight) {
                scorePlayer++;
                serveSign = -1;
                sparks.burst(getPosition(ball), Vec3(-1, 0.5f, 0), 18.0f, COL_SPARK_GOAL, 48);
            }
            audio.play(sfx.goal);
            serveBall(ball, serveSign, sparks.rng);
            lastVxSign = cast(float) serveSign;
            goalFlash = 0.6f;
        }

        trailTimer -= dt;
        if (trailTimer <= 0.0f) {
            sparks.trail(getPosition(ball), getLinearVelocity(ball), COL_BALL);
            trailTimer = 0.03f;
        }
        if (goalFlash > 0)
            goalFlash -= dt;

        sparks.update(dt);

        auto frame = app.beginFrame(Color4(0.03f, 0.035f, 0.06f, 1.0f));
        if (!frame.valid)
            continue;

        scene.begin(camera);

        foreach (ref piece; pieces) {
            scene.drawMatrix(cubeMesh,
                modelMatrix(piece.center, Quat.init, piece.halfExtent * 2.0f),
                piece.color);
        }

        scene.drawMatrix(cubeMesh,
            bodyModelMatrix(player, paddleHalf * 2.0f), COL_PLAYER);
        scene.drawMatrix(cubeMesh,
            bodyModelMatrix(ai, paddleHalf * 2.0f), COL_AI);
        scene.drawMatrix(sphereMesh,
            bodyModelMatrix(ball, Vec3(BALL_RADIUS * 2.0f, BALL_RADIUS * 2.0f, BALL_RADIUS * 2.0f)),
            COL_BALL);

        gizmos.begin(camera.viewProjection());
        gizmos.line(Vec3(0, TABLE_Y + 0.02f, -TABLE_HALF_Z), Vec3(0, TABLE_Y + 0.02f, TABLE_HALF_Z),
            Color4(0.45f, 0.5f, 0.65f, 1.0f));
        sparks.draw(scene, cubeMesh, gizmos);

        scene.end(frame);
        gizmos.render(frame);

        app.resolvePost(frame);

        text.beginFrame();
        text.drawText(frame, fps.text(), 10, 10, 2);
        text.drawText(frame, format("%d   -   %d", scorePlayer, scoreAi), SCREEN_W / 2 - 70, 18, 4);
        text.drawText(frame, "Pong 3D", SCREEN_W / 2 - 50, 70, 2);
        text.drawText(frame, "W/S or Arrows: move   R: reset   Esc: quit", 10, SCREEN_H - 28, 2);

        if (goalFlash > 0) {
            text.drawText(frame, "GOAL!", SCREEN_W / 2 - 50, SCREEN_H / 2 - 20, 4);
        }

        app.endFrame(frame);
    }

    return 0;
}
