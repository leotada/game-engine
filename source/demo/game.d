/// Crystal Collector 3D — collect all crystals while avoiding enemy sentinels.
/// WASD to move, Left/Right arrows to orbit camera, ESC to quit.
module demo.game;

import engine.app;
import engine.gpu.pipeline;
import engine.gpu.buffer;
import engine.gpu.text;
import engine.gpu.renderer : Color, FrameContext;
import bindings.wgpu : WGPUIndexFormat;
import engine.math.mat;
import engine.math.vec;
import engine.core.log;
import engine.platform.input : Key;
import bindings.sdl3;

import std.format : format;
import core.memory : GC;

@safe:

// ---------------------------------------------------------------------------
// Vertex type — shared by all meshes: position + normal
// ---------------------------------------------------------------------------
private struct Vert {
    float[3] pos;
    float[3] normal;
}

// ---------------------------------------------------------------------------
// Instance data — model matrix (64 bytes) + color (16 bytes) = 80 bytes
// ---------------------------------------------------------------------------
private struct InstanceData {
    float[16] model;
    float[4]  color;
}

// ---------------------------------------------------------------------------
// Cube mesh — 24 vertices, 36 indices (same as benchmark)
// ---------------------------------------------------------------------------
private static immutable Vert[24] cubeVerts = [
    // Front (+Z)
    Vert([-0.5,-0.5, 0.5], [ 0, 0, 1]), Vert([ 0.5,-0.5, 0.5], [ 0, 0, 1]),
    Vert([ 0.5, 0.5, 0.5], [ 0, 0, 1]), Vert([-0.5, 0.5, 0.5], [ 0, 0, 1]),
    // Back (-Z)
    Vert([ 0.5,-0.5,-0.5], [ 0, 0,-1]), Vert([-0.5,-0.5,-0.5], [ 0, 0,-1]),
    Vert([-0.5, 0.5,-0.5], [ 0, 0,-1]), Vert([ 0.5, 0.5,-0.5], [ 0, 0,-1]),
    // Right (+X)
    Vert([ 0.5,-0.5, 0.5], [ 1, 0, 0]), Vert([ 0.5,-0.5,-0.5], [ 1, 0, 0]),
    Vert([ 0.5, 0.5,-0.5], [ 1, 0, 0]), Vert([ 0.5, 0.5, 0.5], [ 1, 0, 0]),
    // Left (-X)
    Vert([-0.5,-0.5,-0.5], [-1, 0, 0]), Vert([-0.5,-0.5, 0.5], [-1, 0, 0]),
    Vert([-0.5, 0.5, 0.5], [-1, 0, 0]), Vert([-0.5, 0.5,-0.5], [-1, 0, 0]),
    // Top (+Y)
    Vert([-0.5, 0.5, 0.5], [ 0, 1, 0]), Vert([ 0.5, 0.5, 0.5], [ 0, 1, 0]),
    Vert([ 0.5, 0.5,-0.5], [ 0, 1, 0]), Vert([-0.5, 0.5,-0.5], [ 0, 1, 0]),
    // Bottom (-Y)
    Vert([-0.5,-0.5,-0.5], [ 0,-1, 0]), Vert([ 0.5,-0.5,-0.5], [ 0,-1, 0]),
    Vert([ 0.5,-0.5, 0.5], [ 0,-1, 0]), Vert([-0.5,-0.5, 0.5], [ 0,-1, 0]),
];

private static immutable ushort[36] cubeIdx = [
     0, 1, 2,  2, 3, 0,
     4, 5, 6,  6, 7, 4,
     8, 9,10, 10,11, 8,
    12,13,14, 14,15,12,
    16,17,18, 18,19,16,
    20,21,22, 22,23,20,
];

// ---------------------------------------------------------------------------
// Pyramid mesh — 4 triangular faces + square base = 16 vertices, 18 indices
// Apex at y=+0.8, base at y=0, base radius ~0.5
// ---------------------------------------------------------------------------
// Pre-computed pyramid vertices: apex at (0,0.8,0), base at y=0
// Face normals computed from cross products and normalized
private static immutable Vert[16] pyVerts = [
    // Front face (b3, b2, apex) — normal ≈ (0, 0.53, 0.848)
    Vert([-0.5, 0,  0.5], [ 0, 0.53, 0.848]),
    Vert([ 0.5, 0,  0.5], [ 0, 0.53, 0.848]),
    Vert([ 0, 0.8,    0], [ 0, 0.53, 0.848]),
    // Right face (b2, b1, apex) — normal ≈ (0.848, 0.53, 0)
    Vert([ 0.5, 0,  0.5], [ 0.848, 0.53, 0]),
    Vert([ 0.5, 0, -0.5], [ 0.848, 0.53, 0]),
    Vert([ 0, 0.8,    0], [ 0.848, 0.53, 0]),
    // Back face (b1, b0, apex) — normal ≈ (0, 0.53, -0.848)
    Vert([ 0.5, 0, -0.5], [ 0, 0.53,-0.848]),
    Vert([-0.5, 0, -0.5], [ 0, 0.53,-0.848]),
    Vert([ 0, 0.8,    0], [ 0, 0.53,-0.848]),
    // Left face (b0, b3, apex) — normal ≈ (-0.848, 0.53, 0)
    Vert([-0.5, 0, -0.5], [-0.848, 0.53, 0]),
    Vert([-0.5, 0,  0.5], [-0.848, 0.53, 0]),
    Vert([ 0, 0.8,    0], [-0.848, 0.53, 0]),
    // Base (two triangles, normal down)
    Vert([-0.5, 0, -0.5], [ 0,-1, 0]),
    Vert([ 0.5, 0, -0.5], [ 0,-1, 0]),
    Vert([ 0.5, 0,  0.5], [ 0,-1, 0]),
    Vert([-0.5, 0,  0.5], [ 0,-1, 0]),
];

private static immutable ushort[18] pyramidIdx = [
    0,  1,  2,   // front
    3,  4,  5,   // right
    6,  7,  8,   // back
    9, 10, 11,   // left
   12, 13, 14,   // base tri 1
   14, 15, 12,   // base tri 2
];

// ---------------------------------------------------------------------------
// Diamond (octahedron) mesh — 8 triangular faces = 24 vertices, 24 indices
// Top at y=+0.7, bottom at y=-0.7, equator at y=0 with radius 0.4
// ---------------------------------------------------------------------------
// Pre-computed diamond (octahedron) vertices
// R=0.4 equator, H=0.7 apex height. 8 triangular faces = 24 vertices.
// Normals computed from cross products of face edges.
private static immutable Vert[24] diaVerts = () {
    enum float R = 0.4;
    enum float H = 0.7;
    // Equator points
    enum float[3] e0 = [ R, 0,  0];
    enum float[3] e1 = [ 0, 0,  R];
    enum float[3] e2 = [-R, 0,  0];
    enum float[3] e3 = [ 0, 0, -R];
    enum float[3] top = [0,  H, 0];
    enum float[3] bot = [0, -H, 0];
    // Pre-computed normalized face normals (8 faces of octahedron)
    enum float[3] n0 = [ 0.655, 0.375, 0.655]; // top: e0,e1
    enum float[3] n1 = [-0.655, 0.375, 0.655]; // top: e1,e2
    enum float[3] n2 = [-0.655, 0.375,-0.655]; // top: e2,e3
    enum float[3] n3 = [ 0.655, 0.375,-0.655]; // top: e3,e0
    enum float[3] n4 = [ 0.655,-0.375, 0.655]; // bot: e1,e0
    enum float[3] n5 = [-0.655,-0.375, 0.655]; // bot: e2,e1
    enum float[3] n6 = [-0.655,-0.375,-0.655]; // bot: e3,e2
    enum float[3] n7 = [ 0.655,-0.375,-0.655]; // bot: e0,e3

    return [
        // Top 4 faces
        Vert(top, n0), Vert(e1, n0), Vert(e0, n0),
        Vert(top, n1), Vert(e2, n1), Vert(e1, n1),
        Vert(top, n2), Vert(e3, n2), Vert(e2, n2),
        Vert(top, n3), Vert(e0, n3), Vert(e3, n3),
        // Bottom 4 faces
        Vert(bot, n4), Vert(e0, n4), Vert(e1, n4),
        Vert(bot, n5), Vert(e1, n5), Vert(e2, n5),
        Vert(bot, n6), Vert(e2, n6), Vert(e3, n6),
        Vert(bot, n7), Vert(e3, n7), Vert(e0, n7),
    ];
}();

private static immutable ushort[24] diamondIdx = [
     0, 1, 2,   3, 4, 5,   6, 7, 8,   9,10,11,
    12,13,14,  15,16,17,  18,19,20,  21,22,23,
];

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

// Max instances per draw call
private enum MAX_CUBE_INSTANCES = 128;
private enum MAX_PYRAMID_INSTANCES = 4;
private enum MAX_DIAMOND_INSTANCES = NUM_CRYSTALS;

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

    auto device = app.gpu.getDevice();
    auto queue  = app.gpu.getQueue();

    // --- GPU mesh buffers (safe slice overloads) ---
    auto cubeVBuf = createVertexBuffer(device, queue, cubeVerts[]);
    scope(exit) destroyBuffer(cubeVBuf);
    auto cubeIBuf = createIndexBuffer(device, queue, cubeIdx[]);
    scope(exit) destroyBuffer(cubeIBuf);

    auto pyrVBuf = createVertexBuffer(device, queue, pyVerts[]);
    scope(exit) destroyBuffer(pyrVBuf);
    auto pyrIBuf = createIndexBuffer(device, queue, pyramidIdx[]);
    scope(exit) destroyBuffer(pyrIBuf);

    auto diaVBuf = createVertexBuffer(device, queue, diaVerts[]);
    scope(exit) destroyBuffer(diaVBuf);
    auto diaIBuf = createIndexBuffer(device, queue, diamondIdx[]);
    scope(exit) destroyBuffer(diaIBuf);

    // Instance buffers (dynamic, per-frame upload)
    auto cubeInstBuf = createDynamicVertexBuffer(device, MAX_CUBE_INSTANCES * InstanceData.sizeof);
    scope(exit) destroyBuffer(cubeInstBuf);
    auto pyrInstBuf = createDynamicVertexBuffer(device, MAX_PYRAMID_INSTANCES * InstanceData.sizeof);
    scope(exit) destroyBuffer(pyrInstBuf);
    auto diaInstBuf = createDynamicVertexBuffer(device, MAX_DIAMOND_INSTANCES * InstanceData.sizeof);
    scope(exit) destroyBuffer(diaInstBuf);

    // Uniform buffer (VP matrix)
    auto uniformBuf = createUniformBuffer(device, 64);
    scope(exit) destroyBuffer(uniformBuf);

    // Pipeline
    auto pipe = createColoredPipeline3D(device, app.gpu.getFormat());
    scope(exit) pipe.release();

    // Bind group for VP uniform
    auto vpBindGroup = createUniformBindGroup(device, pipe.bindGroupLayout, uniformBuf, 64);
    scope(exit) releaseBindGroup(vpBindGroup);

    // Text renderer
    auto textRenderer = TextRenderer.create(device, queue, app.gpu.getFormat(), SCREEN_W, SCREEN_H);
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
        immutable eye    = Vec3(camX, CAMERA_HEIGHT, camZ);
        immutable camTarget = Vec3(playerPos.x, 1.0f, playerPos.z);
        immutable view   = Mat4.lookAt(eye, camTarget, Vec3(0, 1, 0));
        immutable proj   = Mat4.perspective(0.9f, cast(float) SCREEN_W / cast(float) SCREEN_H, 0.1f, 100.0f);
        immutable vp     = proj * view;

        // Upload VP matrix
        updateBuffer(queue, uniformBuf, vp.m[]);

        // --- Build instance data (dynamic arrays — GC allocated each frame) ---
        InstanceData[] cubeInstances;
        InstanceData[] pyrInstances;
        InstanceData[] diaInstances;

        // Ground plane
        cubeInstances ~= InstanceData(
            (Mat4.translation(0, -0.05f, 0) * Mat4.scaling(ARENA_SIZE * 2, 0.1f, ARENA_SIZE * 2)).m,
            [0.2f, 0.35f, 0.2f, 1.0f],
        );

        // Walls
        foreach (ref w; walls) {
            cubeInstances ~= InstanceData(
                (Mat4.translation(w.pos.x, w.pos.y, w.pos.z) * Mat4.scaling(w.scale.x, w.scale.y, w.scale.z)).m,
                [0.45f, 0.42f, 0.38f, 1.0f],
            );
        }

        // Enemies
        foreach (ref e; enemies) {
            cubeInstances ~= InstanceData(
                (Mat4.translation(e.position.x, e.position.y, e.position.z) * Mat4.rotationY(e.angle) * Mat4.scaling(0.7f, 0.7f, 0.7f)).m,
                [0.9f, 0.15f, 0.1f, 1.0f],
            );
        }

        // Player (pyramid)
        {
            immutable visible = invulnTimer <= 0 || (cast(int)(invulnTimer * 8) & 1) == 0;
            if (visible) {
                pyrInstances ~= InstanceData(
                    (Mat4.translation(playerPos.x, 0, playerPos.z) * Mat4.rotationY(playerAngle) * Mat4.scaling(1.0f, 1.2f, 1.0f)).m,
                    [0.1f, 0.9f, 0.85f, 1.0f],
                );
            }
        }

        // Crystals (diamonds)
        foreach (ref c; crystals) {
            if (c.collected) continue;
            immutable bob = sinF(c.angle * 1.5f) * 0.2f;
            diaInstances ~= InstanceData(
                (Mat4.translation(c.position.x, c.position.y + bob, c.position.z) * Mat4.rotationY(c.angle) * Mat4.scaling(0.8f, 0.8f, 0.8f)).m,
                [1.0f, 0.85f, 0.1f, 1.0f],
            );
        }

        // --- Upload instances ---
        if (cubeInstances.length > 0)
            updateBuffer(queue, cubeInstBuf, cubeInstances);
        if (pyrInstances.length > 0)
            updateBuffer(queue, pyrInstBuf, pyrInstances);
        if (diaInstances.length > 0)
            updateBuffer(queue, diaInstBuf, diaInstances);

        // --- Render ---
        auto frame = app.renderer.beginFrame(Color(0.05f, 0.06f, 0.12f, 1.0f));
        if (!frame.valid) continue;

        frame.setPipeline(pipe.pipeline);
        frame.setBindGroup(0, vpBindGroup);

        // Draw cubes (ground + walls + enemies)
        if (cubeInstances.length > 0) {
            frame.setVertexBuffer(0, cubeVBuf, cubeVerts.sizeof);
            frame.setVertexBuffer(1, cubeInstBuf, cubeInstances.length * InstanceData.sizeof);
            frame.setIndexBuffer(cubeIBuf, WGPUIndexFormat.uint16, cubeIdx.sizeof);
            frame.drawIndexed(36, cast(uint) cubeInstances.length);
        }

        // Draw player (pyramid)
        if (pyrInstances.length > 0) {
            frame.setVertexBuffer(0, pyrVBuf, pyVerts.sizeof);
            frame.setVertexBuffer(1, pyrInstBuf, pyrInstances.length * InstanceData.sizeof);
            frame.setIndexBuffer(pyrIBuf, WGPUIndexFormat.uint16, pyramidIdx.sizeof);
            frame.drawIndexed(18, cast(uint) pyrInstances.length);
        }

        // Draw crystals (diamonds)
        if (diaInstances.length > 0) {
            frame.setVertexBuffer(0, diaVBuf, diaVerts.sizeof);
            frame.setVertexBuffer(1, diaInstBuf, diaInstances.length * InstanceData.sizeof);
            frame.setIndexBuffer(diaIBuf, WGPUIndexFormat.uint16, diamondIdx.sizeof);
            frame.drawIndexed(24, cast(uint) diaInstances.length);
        }

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

        app.renderer.endFrame(frame);
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
