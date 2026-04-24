module demo.benchmark;

import std.format : format;
import std.math : cos, sin;
import std.random : Mt19937, uniform;
import std.stdio : writefln;

import engine.app : App;
import engine.gpu.text : FpsCounter, TextRenderer;
import engine.graphics.mesh : Mesh;
import engine.graphics.types : Color4;
import engine.math.mat : Mat4;
import engine.math.vec : RenderVec3 = Vec3;
import engine.platform.input : Key;
import engine.scene.camera : Camera;
import engine.scene.scene3d : Scene3D;
import engine.jph.math.mat44 : Mat44;
import engine.jph.math.quat : Quat;
import engine.jph.math.vec3 : PhysVec3 = Vec3;
import engine.jph.physics.body.body_creation_settings : BodyCreationSettings;
import engine.jph.physics.body.body_interface : BodyInterface;
import engine.jph.physics.body.bodyid : BodyID;
import engine.jph.physics.body.motiontype : EMotionType;
import engine.jph.physics.eactivation : EActivation;
import engine.jph.physics.physics_system : PhysicsSystem;
import engine.jph.physics.shape.box_shape : BoxShape;

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
private enum RAIN_LANES = 12;
private enum TAU = 6.283185307179586f;

private RenderVec3 toRenderVec3(PhysVec3 inValue) pure nothrow @nogc {
    return RenderVec3(inValue.GetX(), inValue.GetY(), inValue.GetZ());
}

private Mat4 toRenderMat4(Mat44 inValue) pure nothrow @nogc {
    Mat4 result;

    foreach (column; 0 .. 4)
        foreach (row; 0 .. 4)
            result.m[column * 4 + row] = inValue(cast(uint) row, cast(uint) column);

    return result;
}

private struct TreeInstance {
    PhysVec3 trunkPos;
    PhysVec3 trunkScale;
    PhysVec3 crownPos;
    PhysVec3 crownScale;
}

private struct RainLane {
    PhysVec3 spawnPos;
    PhysVec3 initialVelocity;
    Quat spawnRotation;
    BodyID bodyID;
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
            tree.trunkScale = PhysVec3(trunkRadius * 2.0f, trunkHeight, trunkRadius * 2.0f);
            tree.trunkPos = PhysVec3(px, trunkHeight * 0.5f, pz);
            tree.crownScale = PhysVec3(crownRadius * 2.0f, crownRadius * 1.4f, crownRadius * 2.0f);
            tree.crownPos = PhysVec3(px, trunkHeight + crownRadius * 0.55f, pz);
            trees ~= tree;
        }
    }

    return trees;
}

private void addStaticBox(ref BodyInterface inBodyInterface,
                          PhysVec3 inPosition,
                          PhysVec3 inScale,
                          float inFriction = 0.9f) {
    BodyCreationSettings settings = BodyCreationSettings(
        new BoxShape(inScale * 0.5f),
        inPosition,
        Quat.sIdentity(),
        EMotionType.Static);
    settings.mFriction = inFriction;
    settings.mRestitution = 0.0f;
    inBodyInterface.CreateAndAddBody(settings, EActivation.DontActivate);
}

private BodyID spawnRainBody(ref BodyInterface inBodyInterface,
                             PhysVec3 inPosition,
                             PhysVec3 inInitialVelocity,
                             Quat inRotation) {
    BodyCreationSettings settings = BodyCreationSettings(
        new BoxShape(PhysVec3(0.5f, 0.5f, 0.5f)),
        inPosition,
        inRotation,
        EMotionType.Dynamic);
    settings.mLinearVelocity = inInitialVelocity;
    settings.mFriction = 0.7f;
    settings.mRestitution = 0.0f;
    return inBodyInterface.CreateAndAddBody(settings, EActivation.Activate);
}

private RainLane[] buildRainLanes(scope const(TreeInstance)[] inTrees) {
    RainLane[] lanes;
    lanes.reserve(RAIN_LANES);

    auto rng = Mt19937(0xCAFEu);

    foreach (index; 0 .. RAIN_LANES) {
        immutable tree = inTrees[(index * 19) % inTrees.length];
        RainLane lane;
        lane.spawnPos = tree.crownPos + PhysVec3(0, 9.0f + (index % 3), 0);
        lane.initialVelocity = PhysVec3(index % 2 == 0 ? 0.8f : -0.8f, 0, index % 3 == 0 ? 0.4f : -0.4f);
        lane.spawnRotation = Quat.sRotation(PhysVec3.sAxisX(), uniform(0.0f, TAU, rng))
                           * Quat.sRotation(PhysVec3.sAxisY(), uniform(0.0f, TAU, rng))
                           * Quat.sRotation(PhysVec3.sAxisZ(), uniform(0.0f, TAU, rng));
        lane.bodyID = BodyID();
        lanes ~= lane;
    }

    return lanes;
}

private bool shouldRecycleBody(ref BodyInterface inBodyInterface, BodyID inBodyID) {
    if (inBodyID.IsInvalid())
        return true;

    immutable position = inBodyInterface.GetCenterOfMassPosition(inBodyID);
    immutable velocity = inBodyInterface.GetLinearVelocity(inBodyID);
    return position.GetY() < 0.7f || velocity.LengthSq() < 0.02f || position.GetY() < -5.0f;
}

int main() {
    auto app = App.create("JPH Forest Benchmark", SCREEN_W, SCREEN_H);

    auto scene = Scene3D.create(app.gpu);
    scope(exit) scene.destroy();
    auto cubeMesh = Mesh.cube(app.gpu);
    scope(exit) cubeMesh.destroy();
    auto text = TextRenderer.create(app.gpu, SCREEN_W, SCREEN_H);
    scope(exit) text.destroy();
    auto fps = FpsCounter.create();

    PhysicsSystem physics;
    auto trees = buildForest();
    immutable maxBodies = cast(uint)(trees.length * 2 + RAIN_LANES + 8);
    physics.Init(maxBodies);

    auto bodyInterface = &physics.GetBodyInterface();
    addStaticBox(*bodyInterface, PhysVec3(0, -0.5f, 0), PhysVec3(GROUND_HALF * 2.0f, 1.0f, GROUND_HALF * 2.0f), 1.0f);
    foreach (tree; trees) {
        addStaticBox(*bodyInterface, tree.trunkPos, tree.trunkScale, 0.9f);
        addStaticBox(*bodyInterface, tree.crownPos, tree.crownScale, 0.8f);
    }

    auto lanes = buildRainLanes(trees);
    foreach (ref lane; lanes)
        lane.bodyID = spawnRainBody(*bodyInterface, lane.spawnPos, lane.initialVelocity, lane.spawnRotation);

    auto camera = Camera.create(0.9f, SCREEN_W, SCREEN_H, 0.1f, 300.0f);

    float elapsed = 0.0f;
    float accumulator = 0.0f;
    uint frames = 0;
    uint maxManifolds = 0;
    uint maxPairs = 0;

    writefln("[benchmark] forest=%d trees static_bodies=%d rain_lanes=%d", trees.length, trees.length * 2 + 1, RAIN_LANES);

    while (app.running() && elapsed < BENCHMARK_SECONDS) {
        app.pollEvents();
        immutable rawDt = fps.tick();
        immutable dt = rawDt > 0.1f ? 0.1f : rawDt;
        elapsed += dt;
        ++frames;

        if (app.input.keyPressed(Key.escape))
            break;

        foreach (ref lane; lanes) {
            if (!shouldRecycleBody(*bodyInterface, lane.bodyID))
                continue;

            if (!lane.bodyID.IsInvalid())
                bodyInterface.DestroyBody(lane.bodyID);
            lane.bodyID = spawnRainBody(*bodyInterface, lane.spawnPos, lane.initialVelocity, lane.spawnRotation);
        }

        accumulator += dt;
        if (accumulator > PHYS_STEP * MAX_SUBSTEPS)
            accumulator = PHYS_STEP * MAX_SUBSTEPS;

        uint subSteps = 0;
        while (accumulator >= PHYS_STEP && subSteps < MAX_SUBSTEPS) {
            physics.Step(PHYS_STEP);
            accumulator -= PHYS_STEP;
            ++subSteps;
        }

        if (physics.mStats.mManifoldCount > maxManifolds)
            maxManifolds = physics.mStats.mManifoldCount;
        if (physics.mStats.mBroadphasePairs > maxPairs)
            maxPairs = physics.mStats.mBroadphasePairs;

        immutable float camAngle = elapsed * 0.22f;
        immutable RenderVec3 eye = RenderVec3(cos(camAngle) * 78.0f, 36.0f, sin(camAngle) * 78.0f);
        camera.lookAt(eye, RenderVec3(0, 8, 0));

        auto frame = app.beginFrame(Color4(0.05f, 0.08f, 0.11f, 1.0f));
        if (!frame.valid)
            continue;

        scene.begin(camera);
        scene.draw(cubeMesh, RenderVec3(0, -0.5f, 0), RenderVec3(GROUND_HALF * 2.0f, 1.0f, GROUND_HALF * 2.0f), Color4(0.25f, 0.30f, 0.22f, 1.0f));

        foreach (tree; trees) {
            scene.draw(cubeMesh, toRenderVec3(tree.trunkPos), toRenderVec3(tree.trunkScale), Color4(0.33f, 0.22f, 0.14f, 1.0f));
            scene.draw(cubeMesh, toRenderVec3(tree.crownPos), toRenderVec3(tree.crownScale), Color4(0.18f, 0.48f, 0.24f, 1.0f));
        }

        foreach (lane; lanes) {
            immutable worldTransform = bodyInterface.GetWorldTransform(lane.bodyID);
            scene.drawMatrix(cubeMesh, toRenderMat4(worldTransform), Color4(0.85f, 0.86f, 0.92f, 1.0f));
        }

        scene.end(frame);

        text.beginFrame();
        text.drawText(frame, format("Benchmark t=%.1fs / %.1fs", elapsed, BENCHMARK_SECONDS), 16, 16, 2);
        text.drawText(frame, fps.text(), 16, 40, 2);
        text.drawText(frame, format("Static=%d  Dynamic=%d", trees.length * 2 + 1, RAIN_LANES), 16, 64, 2);
        text.drawText(frame, format("Pairs=%d  Manifolds=%d", physics.mStats.mBroadphasePairs, physics.mStats.mManifoldCount), 16, 88, 2);
        text.drawText(frame, format("Peak pairs=%d  Peak manifolds=%d", maxPairs, maxManifolds), 16, 112, 2);

        app.endFrame(frame);
    }

    immutable float avgFps = elapsed > 0.0f ? frames / elapsed : 0.0f;
    writefln("[benchmark] done frames=%d elapsed=%.2fs avg_fps=%.1f peak_pairs=%d peak_manifolds=%d",
        frames,
        elapsed,
        avgFps,
        maxPairs,
        maxManifolds);
    writefln("[benchmark] adapted legacy benchmark preserved at source/demo/_legacy/benchmark.d.txt");
    return 0;
}
