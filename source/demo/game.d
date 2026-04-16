/// Crystal Collector 3D — collect all crystals while avoiding enemy sentinels.
/// WASD to move, Left/Right arrows to orbit camera, ESC to quit.
module demo.game;

import engine.app;
import engine.gpu.text;
import engine.gpu.renderer : Color;
import engine.math.mat;
import engine.math.vec;
import engine.core.log;
import engine.platform.input : Key;
import engine.graphics.types : Color4;
import engine.graphics.mesh : Mesh;
import engine.scene.camera : Camera;
import engine.scene.scene3d : Scene3D;

import std.format : format;
import core.memory : GC;

@safe:

// ---------------------------------------------------------------------------
// Game configuration
// ---------------------------------------------------------------------------
private enum SCREEN_W   = 1280;
private enum SCREEN_H   = 720;
private enum ARENA_SIZE  = 20.0f;     // half-extent of the playable area
private enum WALL_HEIGHT = 1.5f;
private enum PLAYER_SPEED = 6.0f;
private enum CAMERA_DIST  = 10.0f;
private enum CAMERA_HEIGHT = 7.0f;
private enum CAMERA_ROT_SPEED = 2.0f;
private enum NUM_CRYSTALS = 10;
private enum NUM_ENEMIES  = 5;
private enum ENEMY_SPEED  = 2.5f;
private enum ENEMY_CHASE_SPEED = 4.0f;
private enum ENEMY_DETECT_RANGE = 8.0f;
private enum COLLECT_RADIUS = 1.2f;
private enum HIT_RADIUS = 0.8f;
private enum INVULN_TIME = 2.0f;       // seconds of invulnerability after hit

// ---------------------------------------------------------------------------
// Game state
// ---------------------------------------------------------------------------
private struct Crystal {
    Vec3 position;
    float angle = 0;
    bool collected = false;
}

private struct Enemy {
    Vec3 position;
    Vec3 waypointA;
    Vec3 waypointB;
    bool goingToB = true;
    float angle = 0;
}

private enum GameState { playing, won, lost }

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------
void main() {
    auto app = App.create("Crystal Collector 3D", SCREEN_W, SCREEN_H);

    // --- High-level GPU resources ---
    auto scene   = Scene3D.create(app.gpu);
    scope(exit) scene.destroy();
    auto cube    = Mesh.cube(app.gpu);
    scope(exit) cube.destroy();
    auto pyramid = Mesh.pyramid(app.gpu);
    scope(exit) pyramid.destroy();
    auto diamond = Mesh.diamond(app.gpu);
    scope(exit) diamond.destroy();
    auto camera  = Camera.create(0.9f, SCREEN_W, SCREEN_H);

    // Text renderer
    auto textRenderer = TextRenderer.create(app.gpu, SCREEN_W, SCREEN_H);
    scope(exit) textRenderer.destroy();

    auto fps = FpsCounter.create();

    // --- Initialize game state (dynamic arrays — GC allocated) ---
    Vec3 playerPos = Vec3(0, 0, 0);
    float playerAngle = 0;
    int lives = 3;
    int score = 0;
    float invulnTimer = 0;
    float cameraAngle = 0;
    GameState gameState = GameState.playing;

    // Place crystals in a ring + some random-ish positions
    Crystal[] crystals;
    foreach (i; 0 .. NUM_CRYSTALS) {
        immutable fi = cast(float) i;
        immutable angle = fi * 6.2832f / cast(float) NUM_CRYSTALS;
        immutable radius = 8.0f + sinF(fi * 2.7f) * 6.0f;
        crystals ~= Crystal(
            Vec3(cosF(angle) * radius, 1.0f, sinF(angle) * radius),
        );
    }

    // Place enemies with patrol waypoints
    Enemy[] enemies;
    foreach (i; 0 .. NUM_ENEMIES) {
        immutable fi = cast(float) i;
        immutable angle = fi * 6.2832f / cast(float) NUM_ENEMIES + 0.5f;
        immutable r = 10.0f;
        enemies ~= Enemy(
            Vec3(cosF(angle) * r, 0.4f, sinF(angle) * r),
            Vec3(cosF(angle) * 5.0f, 0.4f, sinF(angle) * 5.0f),
            Vec3(cosF(angle) * (ARENA_SIZE - 2.0f), 0.4f, sinF(angle) * (ARENA_SIZE - 2.0f)),
        );
    }

    // --- Arena layout: walls ---
    struct WallDef {
        Vec3 pos;
        Vec3 scale;
    }

    static immutable WallDef[8] walls = [
        // North/South walls
        WallDef(Vec3( 0,       WALL_HEIGHT*0.5, ARENA_SIZE), Vec3(ARENA_SIZE*2, WALL_HEIGHT, 0.5)),
        WallDef(Vec3( 0,       WALL_HEIGHT*0.5,-ARENA_SIZE), Vec3(ARENA_SIZE*2, WALL_HEIGHT, 0.5)),
        // East/West walls
        WallDef(Vec3( ARENA_SIZE, WALL_HEIGHT*0.5, 0), Vec3(0.5, WALL_HEIGHT, ARENA_SIZE*2)),
        WallDef(Vec3(-ARENA_SIZE, WALL_HEIGHT*0.5, 0), Vec3(0.5, WALL_HEIGHT, ARENA_SIZE*2)),
        // Inner obstacles (pillars)
        WallDef(Vec3( 6, WALL_HEIGHT*0.5,  6), Vec3(1.5, WALL_HEIGHT, 1.5)),
        WallDef(Vec3(-6, WALL_HEIGHT*0.5, -6), Vec3(1.5, WALL_HEIGHT, 1.5)),
        WallDef(Vec3( 6, WALL_HEIGHT*0.5, -6), Vec3(1.5, WALL_HEIGHT, 1.5)),
        WallDef(Vec3(-6, WALL_HEIGHT*0.5,  6), Vec3(1.5, WALL_HEIGHT, 1.5)),
    ];

    // -----------------------------------------------------------------------
    // Main loop
    // -----------------------------------------------------------------------
    while (app.running()) {
        app.pollEvents();
        immutable dt = fps.tick();

        if (app.input.keyPressed(Key.escape)) break;

        // --- Player input ---
        if (gameState == GameState.playing) {
            Vec3 moveDir = Vec3(0, 0, 0);

            // Movement relative to camera orientation
            immutable camForward = Vec3(-sinF(cameraAngle), 0, -cosF(cameraAngle));
            immutable camRight   = Vec3( cosF(cameraAngle), 0, -sinF(cameraAngle));

            if (app.input.keyDown(Key.w)) moveDir = moveDir + camForward;
            if (app.input.keyDown(Key.s)) moveDir = moveDir - camForward;
            if (app.input.keyDown(Key.d)) moveDir = moveDir + camRight;
            if (app.input.keyDown(Key.a)) moveDir = moveDir - camRight;

            if (moveDir.lengthSquared() > 0.001f) {
                moveDir = moveDir.normalized();
                playerPos = playerPos + moveDir * (PLAYER_SPEED * dt);
                import std.math : atan2;
                playerAngle = atan2(moveDir.x, moveDir.z);
            }

            // Clamp to arena
            if (playerPos.x >  ARENA_SIZE - 1.0f) playerPos.x =  ARENA_SIZE - 1.0f;
            if (playerPos.x < -ARENA_SIZE + 1.0f) playerPos.x = -ARENA_SIZE + 1.0f;
            if (playerPos.z >  ARENA_SIZE - 1.0f) playerPos.z =  ARENA_SIZE - 1.0f;
            if (playerPos.z < -ARENA_SIZE + 1.0f) playerPos.z = -ARENA_SIZE + 1.0f;

            // Simple pillar collision
            foreach (ref w; walls[4 .. 8]) {
                immutable halfW = w.scale.x * 0.5f + 0.5f;
                immutable halfD = w.scale.z * 0.5f + 0.5f;
                immutable dx = playerPos.x - w.pos.x;
                immutable dz = playerPos.z - w.pos.z;
                if (dx > -halfW && dx < halfW && dz > -halfD && dz < halfD) {
                    immutable overlapX = halfW - (dx > 0 ? dx : -dx);
                    immutable overlapZ = halfD - (dz > 0 ? dz : -dz);
                    if (overlapX < overlapZ)
                        playerPos.x += dx > 0 ? overlapX : -overlapX;
                    else
                        playerPos.z += dz > 0 ? overlapZ : -overlapZ;
                }
            }

            // Camera orbit
            if (app.input.keyDown(Key.left))  cameraAngle -= CAMERA_ROT_SPEED * dt;
            if (app.input.keyDown(Key.right)) cameraAngle += CAMERA_ROT_SPEED * dt;

            // --- Crystal collection ---
            foreach (ref c; crystals) {
                if (c.collected) continue;
                immutable dist = Vec3(playerPos.x - c.position.x, 0, playerPos.z - c.position.z).length();
                if (dist < COLLECT_RADIUS) {
                    c.collected = true;
                    score++;
                    if (score >= NUM_CRYSTALS)
                        gameState = GameState.won;
                }
            }

            // --- Enemy AI ---
            foreach (ref e; enemies) {
                immutable toPlayer = Vec3(playerPos.x - e.position.x, 0, playerPos.z - e.position.z);
                immutable distToPlayer = toPlayer.length();

                if (distToPlayer < ENEMY_DETECT_RANGE) {
                    immutable chaseDir = toPlayer.normalized();
                    e.position.x += chaseDir.x * ENEMY_CHASE_SPEED * dt;
                    e.position.z += chaseDir.z * ENEMY_CHASE_SPEED * dt;
                } else {
                    immutable target = e.goingToB ? e.waypointB : e.waypointA;
                    immutable toTarget = Vec3(target.x - e.position.x, 0, target.z - e.position.z);
                    immutable distTarget = toTarget.length();

                    if (distTarget < 0.5f) {
                        e.goingToB = !e.goingToB;
                    } else {
                        immutable dir = toTarget.normalized();
                        e.position.x += dir.x * ENEMY_SPEED * dt;
                        e.position.z += dir.z * ENEMY_SPEED * dt;
                    }
                }

                e.angle += 1.5f * dt;

                // Hit check
                if (invulnTimer <= 0) {
                    immutable hitDist = Vec3(playerPos.x - e.position.x, 0, playerPos.z - e.position.z).length();
                    if (hitDist < HIT_RADIUS) {
                        lives--;
                        invulnTimer = INVULN_TIME;
                        if (lives <= 0) {
                            gameState = GameState.lost;
                        } else {
                            playerPos = Vec3(0, 0, 0);
                        }
                    }
                }
            }

            if (invulnTimer > 0) invulnTimer -= dt;
        }

        // Restart on Space when game over
        if ((gameState == GameState.won || gameState == GameState.lost) && app.input.keyPressed(Key.space)) {
            gameState = GameState.playing;
            playerPos = Vec3(0, 0, 0);
            lives = 3;
            score = 0;
            invulnTimer = 0;
            foreach (ref c; crystals) c.collected = false;
            foreach (i; 0 .. NUM_ENEMIES) {
                immutable fi = cast(float) i;
                immutable angle = fi * 6.2832f / cast(float) NUM_ENEMIES + 0.5f;
                immutable r = 10.0f;
                enemies[i].position = Vec3(cosF(angle) * r, 0.4f, sinF(angle) * r);
                enemies[i].goingToB = true;
            }
        }

        // --- Update crystal rotation ---
        foreach (ref c; crystals)
            c.angle += 2.0f * dt;

        // --- Camera ---
        immutable camX = playerPos.x + sinF(cameraAngle) * CAMERA_DIST;
        immutable camZ = playerPos.z + cosF(cameraAngle) * CAMERA_DIST;
        camera.lookAt(
            Vec3(camX, CAMERA_HEIGHT, camZ),
            Vec3(playerPos.x, 1.0f, playerPos.z),
        );

        // --- Build scene ---
        scene.begin(camera);

        // Ground plane
        scene.draw(cube, Vec3(0, -0.05f, 0), Vec3(ARENA_SIZE * 2, 0.1f, ARENA_SIZE * 2), Color4(0.2f, 0.35f, 0.2f));

        // Walls
        foreach (ref w; walls) {
            scene.draw(cube, w.pos, w.scale, Color4(0.45f, 0.42f, 0.38f));
        }

        // Enemies
        foreach (ref e; enemies) {
            scene.draw(cube, e.position, Vec3(0.7f, 0.7f, 0.7f), Color4(0.9f, 0.15f, 0.1f), e.angle);
        }

        // Player (pyramid)
        {
            immutable visible = invulnTimer <= 0 || (cast(int)(invulnTimer * 8) & 1) == 0;
            if (visible) {
                scene.drawMatrix(pyramid,
                    Mat4.translation(playerPos.x, 0, playerPos.z) * Mat4.rotationY(playerAngle) * Mat4.scaling(1.0f, 1.2f, 1.0f),
                    Color4(0.1f, 0.9f, 0.85f),
                );
            }
        }

        // Crystals (diamonds)
        foreach (ref c; crystals) {
            if (c.collected) continue;
            immutable bob = sinF(c.angle * 1.5f) * 0.2f;
            scene.draw(diamond, Vec3(c.position.x, c.position.y + bob, c.position.z), Vec3(0.8f, 0.8f, 0.8f), Color4(1.0f, 0.85f, 0.1f), c.angle);
        }

        // --- Render ---
        auto frame = app.beginFrame(Color(0.05f, 0.06f, 0.12f, 1.0f));
        if (!frame.valid) continue;

        scene.end(frame);

        // --- HUD ---
        textRenderer.beginFrame();
        textRenderer.drawText(frame.pass, fps.text(), 10, 10, 2);

        textRenderer.drawText(frame.pass, format!"Crystals: %d/%d"(score, NUM_CRYSTALS), SCREEN_W / 2 - 80, 10, 2);
        textRenderer.drawText(frame.pass, format!"Lives: %d"(lives), SCREEN_W - 150, 10, 2);

        if (gameState == GameState.won) {
            textRenderer.drawText(frame.pass, "YOU WIN!", SCREEN_W / 2 - 80, SCREEN_H / 2 - 30, 4);
            textRenderer.drawText(frame.pass, "Press SPACE to restart", SCREEN_W / 2 - 160, SCREEN_H / 2 + 30, 2);
        } else if (gameState == GameState.lost) {
            textRenderer.drawText(frame.pass, "GAME OVER", SCREEN_W / 2 - 90, SCREEN_H / 2 - 30, 4);
            textRenderer.drawText(frame.pass, "Press SPACE to restart", SCREEN_W / 2 - 160, SCREEN_H / 2 + 30, 2);
        } else {
            textRenderer.drawText(frame.pass, "WASD:move  Arrows:camera", 10, SCREEN_H - 30, 2);
        }

        app.endFrame(frame);
    }

    // GC stats
    auto gcStats = GC.profileStats;
    immutable totalPauseUs = gcStats.totalPauseTime.total!"usecs";
    immutable maxPauseUs = gcStats.maxPauseTime.total!"usecs";
    info(format!"GC: %d collections | total pause: %.2f ms | max pause: %.2f ms"(
        gcStats.numCollections,
        totalPauseUs / 1000.0,
        maxPauseUs / 1000.0,
    ));
    info("Crystal Collector finished");
}

// ---------------------------------------------------------------------------
// Math helpers
// ---------------------------------------------------------------------------

private float sinF(float x) pure nothrow @nogc @safe {
    import std.math : sin;
    return sin(x);
}

private float cosF(float x) pure nothrow @nogc @safe {
    import std.math : cos;
    return cos(x);
}
