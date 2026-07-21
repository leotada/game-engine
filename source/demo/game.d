/// Crystal Collector v2 — character controller, push-levers, and crystal cages.
/// WASD: move  Space: jump  Arrows: camera  Esc: quit
module demo.game;

import std.format : format;
import std.math : PI, atan2, cos, sin, sqrt;
import core.memory : GC;

import bindings.box3d : b3BodyId, b3ShapeId;
import bindings.wgpu : WGPUPresentMode;
import engine.app : App;
import engine.core.log;
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

private enum float ARENA_HALF = 20.0f;
private enum float WALL_HEIGHT = 1.5f;
private enum float CAMERA_DIST = 12.0f;
private enum float CAMERA_HEIGHT = 8.0f;
private enum float CAMERA_ROT_SPEED = 2.0f;

private enum float PLAYER_HEIGHT = 1.8f;
private enum float PLAYER_RADIUS = 0.35f;
private enum float PUSH_RADIUS = 1.25f;
private enum float PUSH_IMPULSE = 4.0f;
private enum float HIT_RADIUS = 0.9f;
private enum float INVULN_TIME = 2.0f;
private enum float ENEMY_SPEED = 2.5f;
private enum float ENEMY_CHASE_SPEED = 4.0f;
private enum float ENEMY_DETECT_RANGE = 8.0f;

private enum int NUM_FREE_CRYSTALS = 4;
private enum int NUM_STATIONS = 3;
private enum int NUM_CRYSTALS = NUM_FREE_CRYSTALS + NUM_STATIONS;
private enum int NUM_ENEMIES = 4;
private enum int CAGE_WALLS = 4;

private enum EntityId PLAYER_ENTITY = 1;
private enum EntityId CRYSTAL_ENTITY_BASE = 10;
private enum EntityId LEVER_ON_ENTITY_BASE = 20;
private enum EntityId LEVER_ARM_ENTITY_BASE = 30;

private immutable Vec3 PLAYER_SPAWN = Vec3(0.0f, PLAYER_HEIGHT * 0.5f, 0.0f);
private immutable Vec3 PROXY_PARK = Vec3(0.0f, -50.0f, 0.0f);

private immutable Color4[NUM_STATIONS] STATION_COLORS = [
    Color4(1.0f, 0.45f, 0.12f, 1.0f), // orange
    Color4(0.15f, 0.85f, 0.95f, 1.0f), // cyan
    Color4(0.95f, 0.25f, 0.75f, 1.0f), // magenta
];

private enum GameState { playing, won, lost }

private struct Crystal {
    b3BodyId sensor;
    Vec3 position;
    int gatedBy = -1; // station index, or -1 if free
    bool unlocked = true;
    bool collected = false;
    float angle = 0.0f;
}

/// Push the hinged lever into the ON slot → cage opens → collect crystal.
private struct Station {
    b3BodyId hingeBase;
    b3BodyId arm;
    b3BodyId onSensor;
    b3BodyId[CAGE_WALLS] cageWalls;
    Vec3 hingePos;
    Vec3 armRestPos;
    Vec3 onSlotPos;
    Vec3[CAGE_WALLS] cageWallPos;
    Vec3[CAGE_WALLS] cageWallHalf;
    Color4 accent;
    bool activated = false;
}

private struct Enemy {
    b3BodyId body;
    Vec3 position;
    Vec3 waypointA;
    Vec3 waypointB;
    bool goingToB = true;
    float angle = 0.0f;
}

private struct StaticPiece {
    Vec3 center;
    Vec3 halfExtent;
    Color4 color;
}

private struct GameCtx {
    Crystal[NUM_CRYSTALS] crystals;
    Station[NUM_STATIONS] stations;
    int score = 0;
    int stationsOn = 0;
}

private struct PushCtx {
    Vec3 impulse;
    EntityId skipEntity;
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

private void addStatic(ref PhysicsWorld physics, ref StaticPiece[] pieces,
                       Vec3 center, Vec3 halfExtent, Color4 color, float friction = 0.7f) {
    createStaticBox(physics, center, halfExtent, Quat.init, noPhysicsEntity, friction);
    pieces ~= StaticPiece(center, halfExtent, color);
}

private bool isPushableEntity(EntityId id) pure nothrow @nogc {
    return id >= LEVER_ARM_ENTITY_BASE && id < LEVER_ARM_ENTITY_BASE + NUM_STATIONS;
}

private bool onPushOverlap(b3ShapeId shapeId, b3BodyId bodyId, EntityId entityId, void* context)
    nothrow @nogc @trusted {
    cast(void) shapeId;
    auto ctx = cast(PushCtx*) context;
    if (ctx is null)
        return true;
    if (entityId == ctx.skipEntity || !isPushableEntity(entityId))
        return true;
    if (!isBodyValid(bodyId))
        return true;
    applyLinearImpulseToCenter(bodyId, ctx.impulse);
    return true;
}

private void pushNearbyDynamics(ref PhysicsWorld physics, Vec3 center, Vec3 wishDir) nothrow @nogc {
    immutable lenSq = wishDir.x * wishDir.x + wishDir.z * wishDir.z;
    if (lenSq < 1e-6f)
        return;
    immutable inv = 1.0f / sqrt(lenSq);
    immutable dir = Vec3(wishDir.x * inv, 0.0f, wishDir.z * inv);
    PushCtx ctx;
    ctx.impulse = dir * PUSH_IMPULSE;
    ctx.skipEntity = PLAYER_ENTITY;
    overlapSphere(physics, center, PUSH_RADIUS, &onPushOverlap, &ctx);
}

private void activateStation(ref GameCtx ctx, int stationIdx) nothrow @nogc {
    if (stationIdx < 0 || stationIdx >= NUM_STATIONS)
        return;
    auto st = &ctx.stations[stationIdx];
    if (st.activated)
        return;
    st.activated = true;
    ctx.stationsOn += 1;
    foreach (wall; st.cageWalls)
        writeBodyTransform(wall, PROXY_PARK, Quat.init);
    foreach (ref c; ctx.crystals) {
        if (c.gatedBy == stationIdx)
            c.unlocked = true;
    }
}

private void onSensorEnter(PhysicsSensorEvent event, void* context) nothrow @nogc @trusted {
    auto ctx = cast(GameCtx*) context;
    if (ctx is null)
        return;

    // Lever arm swung into the ON slot → open that cage.
    if (event.sensorEntity >= LEVER_ON_ENTITY_BASE &&
        event.sensorEntity < LEVER_ON_ENTITY_BASE + NUM_STATIONS) {
        immutable stationIdx = cast(int)(event.sensorEntity - LEVER_ON_ENTITY_BASE);
        immutable expectedArm = cast(EntityId)(LEVER_ARM_ENTITY_BASE + stationIdx);
        if (event.visitorEntity == expectedArm)
            activateStation(*ctx, stationIdx);
        return;
    }

    // Crystal sensors: player proxy.
    if (event.visitorEntity != PLAYER_ENTITY)
        return;
    if (event.sensorEntity < CRYSTAL_ENTITY_BASE ||
        event.sensorEntity >= CRYSTAL_ENTITY_BASE + NUM_CRYSTALS)
        return;

    immutable crystalIdx = cast(int)(event.sensorEntity - CRYSTAL_ENTITY_BASE);
    auto c = &ctx.crystals[crystalIdx];
    if (c.collected || !c.unlocked)
        return;
    c.collected = true;
    ctx.score += 1;
}

private void buildArena(ref PhysicsWorld physics, ref StaticPiece[] pieces) {
    immutable Color4 ground = Color4(0.22f, 0.38f, 0.24f, 1.0f);
    immutable Color4 wall = Color4(0.45f, 0.42f, 0.38f, 1.0f);
    immutable Color4 pillar = Color4(0.50f, 0.48f, 0.44f, 1.0f);

    addStatic(physics, pieces, Vec3(0.0f, -0.25f, 0.0f),
        Vec3(ARENA_HALF, 0.25f, ARENA_HALF), ground, 1.0f);

    addStatic(physics, pieces, Vec3(0.0f, WALL_HEIGHT * 0.5f, ARENA_HALF),
        Vec3(ARENA_HALF, WALL_HEIGHT * 0.5f, 0.25f), wall);
    addStatic(physics, pieces, Vec3(0.0f, WALL_HEIGHT * 0.5f, -ARENA_HALF),
        Vec3(ARENA_HALF, WALL_HEIGHT * 0.5f, 0.25f), wall);
    addStatic(physics, pieces, Vec3(ARENA_HALF, WALL_HEIGHT * 0.5f, 0.0f),
        Vec3(0.25f, WALL_HEIGHT * 0.5f, ARENA_HALF), wall);
    addStatic(physics, pieces, Vec3(-ARENA_HALF, WALL_HEIGHT * 0.5f, 0.0f),
        Vec3(0.25f, WALL_HEIGHT * 0.5f, ARENA_HALF), wall);

    addStatic(physics, pieces, Vec3(6.0f, WALL_HEIGHT * 0.5f, 6.0f),
        Vec3(0.75f, WALL_HEIGHT * 0.5f, 0.75f), pillar);
    addStatic(physics, pieces, Vec3(-6.0f, WALL_HEIGHT * 0.5f, -6.0f),
        Vec3(0.75f, WALL_HEIGHT * 0.5f, 0.75f), pillar);
    addStatic(physics, pieces, Vec3(6.0f, WALL_HEIGHT * 0.5f, -6.0f),
        Vec3(0.75f, WALL_HEIGHT * 0.5f, 0.75f), pillar);
    addStatic(physics, pieces, Vec3(-6.0f, WALL_HEIGHT * 0.5f, 6.0f),
        Vec3(0.75f, WALL_HEIGHT * 0.5f, 0.75f), pillar);
}

private void buildCrystals(ref PhysicsWorld physics, ref GameCtx ctx) {
    foreach (i; 0 .. NUM_FREE_CRYSTALS) {
        immutable fi = cast(float) i;
        immutable angle = fi * (2.0f * cast(float) PI) / cast(float) NUM_FREE_CRYSTALS;
        immutable radius = 6.5f;
        immutable pos = Vec3(cos(angle) * radius, 1.0f, sin(angle) * radius);
        immutable id = cast(EntityId)(CRYSTAL_ENTITY_BASE + i);
        ctx.crystals[i] = Crystal(
            createSensorBox(physics, pos, Vec3(0.6f, 0.8f, 0.6f), id),
            pos, -1, true, false,
        );
    }

    static immutable Vec3[NUM_STATIONS] lockedPos = [
        Vec3(14.5f, 1.0f, 14.5f),
        Vec3(-14.5f, 1.0f, 14.5f),
        Vec3(14.5f, 1.0f, -14.5f),
    ];
    foreach (i; 0 .. NUM_STATIONS) {
        immutable idx = NUM_FREE_CRYSTALS + i;
        immutable id = cast(EntityId)(CRYSTAL_ENTITY_BASE + idx);
        ctx.crystals[idx] = Crystal(
            createSensorBox(physics, lockedPos[i], Vec3(0.6f, 0.8f, 0.6f), id),
            lockedPos[i], i, false, false,
        );
    }
}

private void buildStations(ref PhysicsWorld physics, ref GameCtx ctx) {
    // Cage at crystal. Lever sits toward arena center: push arm sideways into ON slot.
    static immutable Vec3[NUM_STATIONS] crystalPos = [
        Vec3(14.5f, 1.0f, 14.5f),
        Vec3(-14.5f, 1.0f, 14.5f),
        Vec3(14.5f, 1.0f, -14.5f),
    ];
    static immutable Vec3[NUM_STATIONS] inward = [
        Vec3(-1.0f, 0.0f, -1.0f),
        Vec3(1.0f, 0.0f, -1.0f),
        Vec3(-1.0f, 0.0f, 1.0f),
    ];
    // Perpendicular on XZ (rotate inward 90°) — arm rest direction / push direction.
    static immutable Vec3[NUM_STATIONS] side = [
        Vec3(-1.0f, 0.0f, 1.0f),
        Vec3(1.0f, 0.0f, 1.0f),
        Vec3(-1.0f, 0.0f, -1.0f),
    ];

    immutable float cageHalf = 1.35f;
    immutable float wallThick = 0.18f;
    immutable float wallH = 1.1f;
    immutable float armLen = 1.2f;

    foreach (i; 0 .. NUM_STATIONS) {
        immutable crystal = crystalPos[i];
        immutable inLen = 1.0f / sqrt(inward[i].x * inward[i].x + inward[i].z * inward[i].z);
        immutable inDir = Vec3(inward[i].x * inLen, 0.0f, inward[i].z * inLen);
        immutable sideLen = 1.0f / sqrt(side[i].x * side[i].x + side[i].z * side[i].z);
        immutable sideDir = Vec3(side[i].x * sideLen, 0.0f, side[i].z * sideLen);

        // Hinge between cage and center — easy to reach.
        immutable hinge = Vec3(
            crystal.x + inDir.x * 3.4f,
            1.0f,
            crystal.z + inDir.z * 3.4f,
        );
        // Arm rests pointing sideways so the player pushes it toward the ON slot (inward of hinge).
        immutable armRest = Vec3(
            hinge.x + sideDir.x * armLen,
            hinge.y,
            hinge.z + sideDir.z * armLen,
        );
        // ON slot ~90° from rest: toward the cage / along -side… actually toward -inDir from hinge
        // so the arm swings from sideDir to -inDir (into a slot facing the player approach).
        immutable onSlot = Vec3(
            hinge.x - inDir.x * armLen,
            0.55f,
            hinge.z - inDir.z * armLen,
        );

        // Cage walls.
        Vec3[CAGE_WALLS] wallPos;
        Vec3[CAGE_WALLS] wallHalf;
        wallPos[0] = Vec3(crystal.x + cageHalf, wallH * 0.5f, crystal.z);
        wallHalf[0] = Vec3(wallThick, wallH * 0.5f, cageHalf);
        wallPos[1] = Vec3(crystal.x - cageHalf, wallH * 0.5f, crystal.z);
        wallHalf[1] = Vec3(wallThick, wallH * 0.5f, cageHalf);
        wallPos[2] = Vec3(crystal.x, wallH * 0.5f, crystal.z + cageHalf);
        wallHalf[2] = Vec3(cageHalf, wallH * 0.5f, wallThick);
        wallPos[3] = Vec3(crystal.x, wallH * 0.5f, crystal.z - cageHalf);
        wallHalf[3] = Vec3(cageHalf, wallH * 0.5f, wallThick);

        b3BodyId[CAGE_WALLS] walls;
        foreach (w; 0 .. CAGE_WALLS)
            walls[w] = createKinematicBox(physics, wallPos[w], wallHalf[w]);

        immutable armId = cast(EntityId)(LEVER_ARM_ENTITY_BASE + i);
        immutable onId = cast(EntityId)(LEVER_ON_ENTITY_BASE + i);

        auto base = createStaticBox(physics, hinge, Vec3(0.22f, 1.05f, 0.22f), Quat.init);
        // Orient arm along sideDir: box half-extent along local X; rotate yaw to match sideDir.
        immutable armYaw = atan2(sideDir.x, sideDir.z);
        immutable armRot = Quat.fromAxisAngle(Vec3(0, 1, 0), armYaw);
        // Box extends along local Z after yaw from atan2(x,z)... fromAxisAngle Y with atan2(x,z)
        // maps local -Z/+Z. Simpler: place arm center at armRest with axis-aligned extent and
        // let joint constrain — use a long box along the rest direction via rotation.
        auto arm = createDynamicBox(physics, armRest, Vec3(0.18f, 0.18f, armLen),
            armRot, 0.6f, armId, 0.35f, 0.0f);
        setLinearDamping(arm, 0.35f);
        setAngularDamping(arm, 0.55f);
        createRevoluteJoint(physics, base, arm, hinge, Vec3(0.0f, 1.0f, 0.0f));

        // Tall ON slot the arm tip must enter — reads as a switch dock.
        auto onSensor = createSensorBox(physics, onSlot, Vec3(0.45f, 0.7f, 0.45f), onId);

        ctx.stations[i] = Station(
            base, arm, onSensor, walls,
            hinge, armRest, onSlot,
            wallPos, wallHalf,
            STATION_COLORS[i],
            false,
        );
    }
}

private void buildEnemies(ref PhysicsWorld physics, ref Enemy[NUM_ENEMIES] enemies) {
    foreach (i; 0 .. NUM_ENEMIES) {
        immutable fi = cast(float) i;
        immutable angle = fi * (2.0f * cast(float) PI) / cast(float) NUM_ENEMIES + 0.4f;
        immutable r = 10.0f;
        immutable pos = Vec3(cos(angle) * r, 0.4f, sin(angle) * r);
        auto body = createKinematicBox(physics, pos, Vec3(0.35f, 0.35f, 0.35f));
        enemies[i] = Enemy(
            body,
            pos,
            Vec3(cos(angle) * 5.0f, 0.4f, sin(angle) * 5.0f),
            Vec3(cos(angle) * (ARENA_HALF - 3.0f), 0.4f, sin(angle) * (ARENA_HALF - 3.0f)),
        );
    }
}

private void resetLevel(ref CharacterController player,
                        b3BodyId playerProxy,
                        ref GameCtx ctx,
                        ref Enemy[NUM_ENEMIES] enemies) {
    player.position = PLAYER_SPAWN;
    player.velocity = Vec3(0.0f, 0.0f, 0.0f);
    player.onGround = false;
    writeBodyTransform(playerProxy, PROXY_PARK, Quat.init);

    ctx.score = 0;
    ctx.stationsOn = 0;
    foreach (ref c; ctx.crystals) {
        c.collected = false;
        c.unlocked = c.gatedBy < 0;
        c.angle = 0.0f;
    }
    foreach (i; 0 .. NUM_STATIONS) {
        auto st = &ctx.stations[i];
        st.activated = false;
        foreach (w; 0 .. CAGE_WALLS)
            writeBodyTransform(st.cageWalls[w], st.cageWallPos[w], Quat.init);

        immutable side = st.armRestPos - st.hingePos;
        immutable armYaw = atan2(side.x, side.z);
        writeBodyTransform(st.arm, st.armRestPos, Quat.fromAxisAngle(Vec3(0, 1, 0), armYaw));
        setLinearVelocity(st.arm, Vec3(0.0f, 0.0f, 0.0f));
        setAngularVelocity(st.arm, Vec3(0.0f, 0.0f, 0.0f));
    }
    foreach (i; 0 .. NUM_ENEMIES) {
        immutable fi = cast(float) i;
        immutable angle = fi * (2.0f * cast(float) PI) / cast(float) NUM_ENEMIES + 0.4f;
        immutable r = 10.0f;
        enemies[i].position = Vec3(cos(angle) * r, 0.4f, sin(angle) * r);
        enemies[i].goingToB = true;
        enemies[i].angle = 0.0f;
        writeBodyTransform(enemies[i].body, enemies[i].position, Quat.init);
    }
}

void main() {
    auto app = App.create("Crystal Collector v2", SCREEN_W, SCREEN_H, WGPUPresentMode.fifo);

    auto scene = Scene3D.create(app.gpu);
    scope(exit) scene.destroy();
    auto cube = Mesh.cube(app.gpu);
    scope(exit) cube.destroy();
    auto pyramid = Mesh.pyramid(app.gpu);
    scope(exit) pyramid.destroy();
    auto diamond = Mesh.diamond(app.gpu);
    scope(exit) diamond.destroy();
    auto textRenderer = TextRenderer.create(app.gpu, SCREEN_W, SCREEN_H);
    scope(exit) textRenderer.destroy();
    auto fps = FpsCounter.create();
    auto camera = Camera.create(0.9f, SCREEN_W, SCREEN_H);

    auto physics = PhysicsWorld(Vec3(0.0f, -9.81f, 0.0f));
    StaticPiece[] staticPieces;
    buildArena(physics, staticPieces);

    GameCtx ctx;
    buildCrystals(physics, ctx);
    buildStations(physics, ctx);

    Enemy[NUM_ENEMIES] enemies;
    buildEnemies(physics, enemies);

    auto player = CharacterController(PLAYER_SPAWN, PLAYER_HEIGHT, PLAYER_RADIUS);
    player.maxSpeed = 6.0f;
    player.jumpSpeed = 5.5f;
    immutable playerProxy = createKinematicBox(
        physics, PROXY_PARK, Vec3(PLAYER_RADIUS, PLAYER_HEIGHT * 0.5f, PLAYER_RADIUS), PLAYER_ENTITY);

    ContactListener listener;
    listener.onSensorEnter = &onSensorEnter;
    listener.context = &ctx;

    float cameraAngle = 0.0f;
    float playerYaw = 0.0f;
    int lives = 3;
    float invulnTimer = 0.0f;
    float accumulator = 0.0f;
    GameState gameState = GameState.playing;

    while (app.running()) {
        app.pollEvents();
        immutable rawDt = fps.tick();
        immutable float dt = rawDt > 0.1f ? 0.1f : rawDt;

        if (app.input.keyPressed(Key.escape))
            break;

        if (app.input.keyDown(Key.left))
            cameraAngle -= CAMERA_ROT_SPEED * dt;
        if (app.input.keyDown(Key.right))
            cameraAngle += CAMERA_ROT_SPEED * dt;

        if ((gameState == GameState.won || gameState == GameState.lost) &&
            app.input.keyPressed(Key.space)) {
            gameState = GameState.playing;
            lives = 3;
            invulnTimer = 0.0f;
            resetLevel(player, playerProxy, ctx, enemies);
        }

        Vec3 wishDir = Vec3(0.0f, 0.0f, 0.0f);
        bool jumpPressed = false;
        if (gameState == GameState.playing) {
            immutable camForward = Vec3(-sin(cameraAngle), 0.0f, -cos(cameraAngle));
            immutable camRight = Vec3(cos(cameraAngle), 0.0f, -sin(cameraAngle));
            if (app.input.keyDown(Key.w)) wishDir = wishDir + camForward;
            if (app.input.keyDown(Key.s)) wishDir = wishDir - camForward;
            if (app.input.keyDown(Key.d)) wishDir = wishDir + camRight;
            if (app.input.keyDown(Key.a)) wishDir = wishDir - camRight;
            jumpPressed = app.input.keyPressed(Key.space);

            immutable wlen = wishDir.x * wishDir.x + wishDir.z * wishDir.z;
            if (wlen > 1e-6f)
                playerYaw = atan2(wishDir.x, wishDir.z);
        }

        accumulator += dt;
        if (accumulator > PHYS_STEP * MAX_SUBSTEPS)
            accumulator = PHYS_STEP * MAX_SUBSTEPS;

        uint subSteps = 0;
        bool jump = jumpPressed;
        while (accumulator >= PHYS_STEP && subSteps < MAX_SUBSTEPS) {
            if (gameState == GameState.playing) {
                writeBodyTransform(playerProxy, PROXY_PARK, Quat.init);
                player.move(physics, wishDir, PHYS_STEP, jump);
                jump = false;

                writeBodyTransform(playerProxy, player.position, Quat.init);
                pushNearbyDynamics(physics, player.position, wishDir);
            }

            physics.step(PHYS_STEP, 4);
            drainPhysicsEvents(physics, listener);
            accumulator -= PHYS_STEP;
            ++subSteps;
        }

        if (gameState == GameState.playing) {
            foreach (ref e; enemies) {
                immutable toPlayer = Vec3(player.position.x - e.position.x, 0.0f,
                    player.position.z - e.position.z);
                immutable distToPlayer = sqrt(toPlayer.x * toPlayer.x + toPlayer.z * toPlayer.z);

                if (distToPlayer < ENEMY_DETECT_RANGE && distToPlayer > 1e-4f) {
                    immutable inv = 1.0f / distToPlayer;
                    e.position.x += toPlayer.x * inv * ENEMY_CHASE_SPEED * dt;
                    e.position.z += toPlayer.z * inv * ENEMY_CHASE_SPEED * dt;
                } else {
                    immutable target = e.goingToB ? e.waypointB : e.waypointA;
                    immutable toTarget = Vec3(target.x - e.position.x, 0.0f, target.z - e.position.z);
                    immutable distTarget = sqrt(toTarget.x * toTarget.x + toTarget.z * toTarget.z);
                    if (distTarget < 0.5f) {
                        e.goingToB = !e.goingToB;
                    } else if (distTarget > 1e-4f) {
                        immutable inv = 1.0f / distTarget;
                        e.position.x += toTarget.x * inv * ENEMY_SPEED * dt;
                        e.position.z += toTarget.z * inv * ENEMY_SPEED * dt;
                    }
                }
                e.angle += 1.5f * dt;
                writeBodyTransform(e.body, e.position, Quat.fromAxisAngle(Vec3(0, 1, 0), e.angle));

                if (invulnTimer <= 0.0f) {
                    immutable hitDist = sqrt(
                        (player.position.x - e.position.x) * (player.position.x - e.position.x) +
                        (player.position.z - e.position.z) * (player.position.z - e.position.z));
                    if (hitDist < HIT_RADIUS) {
                        lives -= 1;
                        invulnTimer = INVULN_TIME;
                        if (lives <= 0) {
                            gameState = GameState.lost;
                        } else {
                            player.position = PLAYER_SPAWN;
                            player.velocity = Vec3(0.0f, 0.0f, 0.0f);
                            writeBodyTransform(playerProxy, PROXY_PARK, Quat.init);
                        }
                    }
                }
            }

            if (invulnTimer > 0.0f)
                invulnTimer -= dt;

            if (ctx.score >= NUM_CRYSTALS)
                gameState = GameState.won;
        }

        foreach (ref c; ctx.crystals)
            c.angle += 2.0f * dt;

        immutable camX = player.position.x + sin(cameraAngle) * CAMERA_DIST;
        immutable camZ = player.position.z + cos(cameraAngle) * CAMERA_DIST;
        camera.lookAt(
            Vec3(camX, CAMERA_HEIGHT, camZ),
            Vec3(player.position.x, 1.0f, player.position.z),
        );

        auto frame = app.beginFrame(Color4(0.05f, 0.06f, 0.12f, 1.0f));
        if (!frame.valid)
            continue;

        scene.begin(camera);

        foreach (ref piece; staticPieces) {
            scene.drawMatrix(cube,
                modelMatrix(piece.center, Quat.init, piece.halfExtent * 2.0f),
                piece.color);
        }

        foreach (i; 0 .. NUM_STATIONS) {
            auto st = &ctx.stations[i];

            // Hinge post.
            scene.drawMatrix(cube,
                bodyModelMatrix(st.hingeBase, Vec3(0.44f, 2.1f, 0.44f)),
                Color4(0.55f, 0.55f, 0.60f, 1.0f));

            // Lever arm (accent color; green when activated).
            immutable armColor = st.activated
                ? Color4(0.25f, 1.0f, 0.35f, 1.0f)
                : st.accent;
            scene.drawMatrix(cube,
                bodyModelMatrix(st.arm, Vec3(0.36f, 0.36f, 2.4f)),
                armColor);

            // ON slot dock.
            immutable slotColor = st.activated
                ? Color4(0.25f, 1.0f, 0.35f, 1.0f)
                : Color4(st.accent.r * 0.7f, st.accent.g * 0.7f, st.accent.b * 0.7f, 1.0f);
            scene.draw(cube, st.onSlotPos, Vec3(0.7f, 1.2f, 0.7f), slotColor);

            if (!st.activated) {
                foreach (w; 0 .. CAGE_WALLS) {
                    scene.draw(cube, st.cageWallPos[w], st.cageWallHalf[w] * 2.0f,
                        Color4(st.accent.r * 0.55f, st.accent.g * 0.55f, st.accent.b * 0.55f, 1.0f));
                }
            }
        }

        foreach (ref e; enemies) {
            scene.draw(cube, e.position, Vec3(0.7f, 0.7f, 0.7f), Color4(0.9f, 0.15f, 0.1f, 1.0f), e.angle);
        }

        {
            immutable visible = invulnTimer <= 0.0f || (cast(int)(invulnTimer * 8) & 1) == 0;
            if (visible) {
                immutable feetY = player.position.y - PLAYER_HEIGHT * 0.5f;
                scene.drawMatrix(pyramid,
                    Mat4.translation(player.position.x, feetY, player.position.z) *
                        Mat4.rotationY(playerYaw) *
                        Mat4.scaling(1.0f, 1.2f, 1.0f),
                    Color4(0.1f, 0.9f, 0.85f, 1.0f));
            }
        }

        foreach (ref c; ctx.crystals) {
            if (c.collected)
                continue;
            immutable bob = sin(c.angle * 1.5f) * 0.2f;
            Color4 color = Color4(1.0f, 0.85f, 0.1f, 1.0f);
            if (!c.unlocked && c.gatedBy >= 0)
                color = STATION_COLORS[c.gatedBy];
            scene.draw(diamond,
                Vec3(c.position.x, c.position.y + bob, c.position.z),
                Vec3(0.8f, 0.8f, 0.8f), color, c.angle);
        }

        scene.end(frame);
        app.resolvePost(frame);

        textRenderer.beginFrame();
        textRenderer.drawText(frame, fps.text(), 10, 10, 2);
        textRenderer.drawText(frame,
            format!"Crystals: %d/%d"(ctx.score, NUM_CRYSTALS), SCREEN_W / 2 - 90, 10, 2);
        textRenderer.drawText(frame,
            format!"Levers: %d/%d"(ctx.stationsOn, NUM_STATIONS), SCREEN_W / 2 - 70, 36, 2);
        textRenderer.drawText(frame, format!"Lives: %d"(lives), SCREEN_W - 150, 10, 2);

        if (gameState == GameState.won) {
            textRenderer.drawText(frame, "YOU WIN!", SCREEN_W / 2 - 80, SCREEN_H / 2 - 30, 4);
            textRenderer.drawText(frame, "Press SPACE to restart", SCREEN_W / 2 - 160, SCREEN_H / 2 + 30, 2);
        } else if (gameState == GameState.lost) {
            textRenderer.drawText(frame, "GAME OVER", SCREEN_W / 2 - 90, SCREEN_H / 2 - 30, 4);
            textRenderer.drawText(frame, "Press SPACE to restart", SCREEN_W / 2 - 160, SCREEN_H / 2 + 30, 2);
        } else {
            textRenderer.drawText(frame,
                "WASD:move  Space:jump  Push each colored lever into its slot to open the cage",
                10, SCREEN_H - 30, 2);
        }

        app.endFrame(frame);
    }

    auto gcStats = GC.profileStats;
    immutable totalPauseUs = gcStats.totalPauseTime.total!"usecs";
    immutable maxPauseUs = gcStats.maxPauseTime.total!"usecs";
    info(format!"GC: %d collections | total pause: %.2f ms | max pause: %.2f ms"(
        gcStats.numCollections,
        totalPauseUs / 1000.0,
        maxPauseUs / 1000.0,
    ));
    info("Crystal Collector v2 finished");
}
