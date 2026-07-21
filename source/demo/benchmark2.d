module demo.benchmark2;

import core.memory : GC;
import core.time : Duration;
import std.format : format;
import std.math : cos, sin;
import std.random : Mt19937, uniform;
import std.stdio : writefln;

import engine.app : App;
import engine.gpu.text : FpsCounter, TextRenderer;
import engine.graphics.mesh : Mesh;
import engine.graphics.types : Color4;
import engine.math.mat : Mat4;
import engine.math.quat : Quat;
import engine.math.vec : Vec3;
import engine.platform.input : Key;
import engine.physics;
import engine.scene.camera : Camera;
import engine.scene.scene3d : Scene3D;
import bindings.box3d : b3BodyId;

@safe:

private enum SCREEN_W = 1280;
private enum SCREEN_H = 720;
private enum BENCHMARK_SECONDS = 12.0f;
private enum PHYS_STEP = 1.0f / 60.0f;
private enum MAX_SUBSTEPS = 4;

private enum FOREST_X = 18;
private enum FOREST_Z = 18;
private enum TREE_SPACING = 6.0f;
private enum GROUND_HALF = 70.0f;
private enum MAX_RAIN_DROPS = 500;
private enum TAU = 6.283185307179586f;

private double toMs(Duration d) pure nothrow @safe { return d.total!"hnsecs" / 10_000.0; }

private Mat4 toRenderMat4(PhysicsTransform transform) {
    Mat4 result = transform.rotation.toMat4();
    result.m[12] = transform.position.x;
    result.m[13] = transform.position.y;
    result.m[14] = transform.position.z;
    return result;
}

private struct TreeInstance {
    Vec3 trunkPos;
    Vec3 trunkScale;
    Vec3 crownPos;
    Vec3 crownScale;
}

private struct RainDrop {
    b3BodyId bodyID;
}

private TreeInstance[] buildForest() {
    TreeInstance[] trees;
    trees.reserve(FOREST_X * FOREST_Z);

    auto rng = Mt19937(0xBEEFu);
    immutable float originX = -0.5f * (FOREST_X - 1) * TREE_SPACING;
    immutable float originZ = -0.5f * (FOREST_Z - 1) * TREE_SPACING;

    foreach (gx; 0 .. FOREST_X) {
        foreach (gz; 0 .. FOREST_Z) {
            immutable float jitterX = uniform(-1.25f, 1.25f, rng);
            immutable float jitterZ = uniform(-1.25f, 1.25f, rng);
            immutable float trunkHeight = uniform(3.0f, 6.5f, rng);
            immutable float trunkRadius = uniform(0.22f, 0.45f, rng);
            immutable float crownRadius = uniform(1.3f, 2.4f, rng);
            immutable float px = originX + gx * TREE_SPACING + jitterX;
            immutable float pz = originZ + gz * TREE_SPACING + jitterZ;

            TreeInstance tree;
            tree.trunkScale = Vec3(trunkRadius * 2.0f, trunkHeight, trunkRadius * 2.0f);
            tree.trunkPos = Vec3(px, trunkHeight * 0.5f, pz);
            tree.crownScale = Vec3(crownRadius * 2.0f, crownRadius * 1.4f, crownRadius * 2.0f);
            tree.crownPos = Vec3(px, trunkHeight + crownRadius * 0.55f, pz);
            trees ~= tree;
        }
    }

    return trees;
}

private void addStaticBox(ref PhysicsWorld physics,
                          Vec3 inPosition,
                          Vec3 inScale,
                          float inFriction = 0.9f) {
    createStaticBox(physics, inPosition, inScale * 0.5f, noPhysicsEntity, inFriction);
}

private b3BodyId spawnRainBody(ref PhysicsWorld physics,
                             Vec3 inPosition,
                             Vec3 inInitialVelocity,
                             Quat inRotation) {
    immutable body = createDynamicBox(physics, inPosition, Vec3(0.5f, 0.5f, 0.5f), inRotation, 1.0f, noPhysicsEntity, 0.7f);
    setLinearVelocity(body, inInitialVelocity);
    return body;
}

private RainDrop[] buildRainDrops() {
    RainDrop[] drops;
    drops.reserve(MAX_RAIN_DROPS);
    foreach (index; 0 .. MAX_RAIN_DROPS) {
        RainDrop drop;
        drop.bodyID = b3BodyId.init;
        drops ~= drop;
    }
    return drops;
}

private bool shouldRecycleBody(b3BodyId inBodyID, float inElapsed) {
    if (!isBodyValid(inBodyID))
        return inElapsed < 10.0f;

    immutable position = getPosition(inBodyID);
    if (position.y < -5.0f)
        return inElapsed < 10.0f;

    return false;
}

int main() {
    auto app = App.create("Box3D Forest Benchmark", SCREEN_W, SCREEN_H);

    auto scene = Scene3D.create(app.gpu);
    scope(exit) scene.destroy();
    auto cubeMesh = Mesh.cube(app.gpu);
    scope(exit) cubeMesh.destroy();
    auto text = TextRenderer.create(app.gpu, SCREEN_W, SCREEN_H);
    scope(exit) text.destroy();
    auto fps = FpsCounter.create();

    auto physics = PhysicsWorld(Vec3(0.0f, -9.81f, 0.0f));
    auto trees = buildForest();

    addStaticBox(physics, Vec3(0, -0.5f, 0), Vec3(GROUND_HALF * 2.0f, 1.0f, GROUND_HALF * 2.0f), 1.0f);
    foreach (tree; trees) {
        addStaticBox(physics, tree.trunkPos, tree.trunkScale, 0.9f);
        addStaticBox(physics, tree.crownPos, tree.crownScale, 0.8f);
    }

    auto drops = buildRainDrops();
    uint activeDrops = 0;
    auto rng = Mt19937(0xCAFEu);

    auto camera = Camera.create(0.9f, SCREEN_W, SCREEN_H, 0.1f, 300.0f);

    float elapsed = 0.0f;
    float accumulator = 0.0f;
    uint frames = 0;
    uint maxActiveDrops = 0;

    GC.profileStats();

    writefln("[benchmark2] forest=%d trees static_bodies=%d max_rain_drops=%d", trees.length, trees.length * 2 + 1, MAX_RAIN_DROPS);

    while (app.running() && elapsed < BENCHMARK_SECONDS) {
        app.pollEvents();
        immutable rawDt = fps.tick();
        immutable dt = rawDt > 0.1f ? 0.1f : rawDt;
        elapsed += dt;
        ++frames;

        if (app.input.keyPressed(Key.escape))
            break;

        if (elapsed < 10.0f) {
            uint toSpawn = cast(uint)(dt * 150.0f);
            if (toSpawn == 0 && uniform(0.0f, 1.0f, rng) < (dt * 150.0f)) toSpawn = 1;
            while (toSpawn > 0 && activeDrops < MAX_RAIN_DROPS) {
                immutable float px = uniform(-GROUND_HALF + 10.0f, GROUND_HALF - 10.0f, rng);
                immutable float pz = uniform(-GROUND_HALF + 10.0f, GROUND_HALF - 10.0f, rng);
                immutable float py = uniform(40.0f, 60.0f, rng);

                Vec3 spawnPos = Vec3(px, py, pz);
                Vec3 initialVec = Vec3(0, -2.0f, 0);
                Quat spawnRot = Quat.fromAxisAngle(Vec3(1.0f, 0.0f, 0.0f), uniform(0.0f, TAU, rng))
                              * Quat.fromAxisAngle(Vec3(0.0f, 1.0f, 0.0f), uniform(0.0f, TAU, rng))
                              * Quat.fromAxisAngle(Vec3(0.0f, 0.0f, 1.0f), uniform(0.0f, TAU, rng));

                drops[activeDrops].bodyID = spawnRainBody(physics, spawnPos, initialVec, spawnRot);
                activeDrops++;
                toSpawn--;
            }
        }

        foreach (ref drop; drops[0 .. activeDrops]) {
            if (shouldRecycleBody(drop.bodyID, elapsed)) {
                if (isBodyValid(drop.bodyID))
                    destroyBody(drop.bodyID);

                immutable float px = uniform(-GROUND_HALF + 10.0f, GROUND_HALF - 10.0f, rng);
                immutable float pz = uniform(-GROUND_HALF + 10.0f, GROUND_HALF - 10.0f, rng);
                immutable float py = uniform(40.0f, 60.0f, rng);

                Vec3 spawnPos = Vec3(px, py, pz);
                Vec3 initialVec = Vec3(0, -2.0f, 0);
                Quat spawnRot = Quat.fromAxisAngle(Vec3(1.0f, 0.0f, 0.0f), uniform(0.0f, TAU, rng))
                              * Quat.fromAxisAngle(Vec3(0.0f, 1.0f, 0.0f), uniform(0.0f, TAU, rng))
                              * Quat.fromAxisAngle(Vec3(0.0f, 0.0f, 1.0f), uniform(0.0f, TAU, rng));

                drop.bodyID = spawnRainBody(physics, spawnPos, initialVec, spawnRot);
            }
        }

        accumulator += dt;
        if (accumulator > PHYS_STEP * MAX_SUBSTEPS)
            accumulator = PHYS_STEP * MAX_SUBSTEPS;

        uint subSteps = 0;
        while (accumulator >= PHYS_STEP && subSteps < MAX_SUBSTEPS) {
            physics.step(PHYS_STEP, 4);
            accumulator -= PHYS_STEP;
            ++subSteps;
        }

        if (activeDrops > maxActiveDrops)
            maxActiveDrops = activeDrops;

        immutable float camAngle = elapsed * 0.22f;
        immutable Vec3 eye = Vec3(cos(camAngle) * 78.0f, 36.0f, sin(camAngle) * 78.0f);
        camera.lookAt(eye, Vec3(0, 8, 0));

        auto frame = app.beginFrame(Color4(0.05f, 0.08f, 0.11f, 1.0f));
        if (!frame.valid)
            continue;

        scene.begin(camera);
        scene.draw(cubeMesh, Vec3(0, -0.5f, 0), Vec3(GROUND_HALF * 2.0f, 1.0f, GROUND_HALF * 2.0f), Color4(0.25f, 0.30f, 0.22f, 1.0f));

        foreach (tree; trees) {
            scene.draw(cubeMesh, tree.trunkPos, tree.trunkScale, Color4(0.33f, 0.22f, 0.14f, 1.0f));
            scene.draw(cubeMesh, tree.crownPos, tree.crownScale, Color4(0.18f, 0.48f, 0.24f, 1.0f));
        }

        foreach (drop; drops[0 .. activeDrops]) {
            if (!isBodyValid(drop.bodyID))
                continue;
            scene.drawMatrix(cubeMesh, toRenderMat4(readBodyTransform(drop.bodyID)), Color4(0.85f, 0.86f, 0.92f, 1.0f));
        }

        scene.end(frame);

        app.resolvePost(frame);

        text.beginFrame();
        text.drawText(frame, format("Benchmark2 t=%.1fs / %.1fs", elapsed, BENCHMARK_SECONDS), 16, 16, 2);
        text.drawText(frame, fps.text(), 16, 40, 2);
        text.drawText(frame, format("Static=%d  Dynamic=%d", trees.length * 2 + 1, activeDrops), 16, 64, 2);
        text.drawText(frame, format("Peak dynamic=%d", maxActiveDrops), 16, 88, 2);

        immutable gs = GC.profileStats;
        text.drawText(frame, format("GC: %d col | total: %.1f ms | max: %.1f ms", gs.numCollections, toMs(gs.totalPauseTime), toMs(gs.maxPauseTime)), 16, 112, 2);

        app.endFrame(frame);
    }

    immutable float avgFps = elapsed > 0.0f ? frames / elapsed : 0.0f;
    immutable gs = GC.profileStats;
    writefln("[benchmark2] done frames=%d elapsed=%.2fs avg_fps=%.1f peak_dynamic=%d",
        frames,
        elapsed,
        avgFps,
        maxActiveDrops);
    writefln("[benchmark2] gc collections=%d total_pause=%.1fms max_pause=%.1fms",
        gs.numCollections,
        toMs(gs.totalPauseTime),
        toMs(gs.maxPauseTime));
    return 0;
}
