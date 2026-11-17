/// Minimal example demonstrating an external DUB project depending on `game-engine`.
module app;

import engine;
import engine.graphics.shapes;
import engine.graphics.material : Material, MaterialParams;
import engine.gpu.ibl : IblEnvironment;
import engine.scene.light : LightSet;
import engine.scene.scene3d_textured : Scene3DTextured;

@safe:

void main(string[] args) {
    bool headless = false;
    foreach (arg; args) {
        if (arg == "--headless-check") headless = true;
    }

    // Exercise core POD utilities cleanly without a GPU when --headless-check is passed
    auto clock = GameClock.create(60.0f);
    Tweens tw;
    immutable TweenId tid = tw.start(0.0f, 1.0f, 0.5f, Ease.outCubic);
    immutable float n = fbm2D(1.5f, 2.5f);
    MeshData sphere = icosphere(1.0f, 1);

    if (headless) {
        clock.advance(1.0f / 60.0f);
        tw.update(0.25f);
        assert(sphere.vertices.length > 0 && tid != 0 && n == n);
        return;
    }

    auto app = App.create("External Game Example", 1280, 720);
    scope(exit) app.destroy();

    auto scene = Scene3DTextured.create(app.gpu);
    scope(exit) scene.destroy();

    auto ibl = IblEnvironment.createGradient(
        app.gpu,
        scene.iblLayout(),
        [0.18f, 0.30f, 0.55f],
        [0.45f, 0.55f, 0.65f],
        [0.12f, 0.10f, 0.08f]
    );
    scope(exit) ibl.destroy();
    scene.setEnvironment(ibl);

    auto mesh = sphere.toTexMesh(app.gpu);
    scope(exit) mesh.destroy();

    auto sampler = Sampler.create(app.gpu);
    scope(exit) sampler.destroy();
    auto albedo = Texture.solid(app.gpu, 220, 95, 55, 255);
    scope(exit) albedo.destroy();

    MaterialParams mp;
    mp.specularRoughness = 0.35f;
    auto mat = Material.create(
        app.gpu, scene.materialLayout(), sampler, albedo, mp, null, null, null, null
    );
    scope(exit) mat.destroy();

    auto camera = Camera.create(0.9f, 1280, 720);
    camera.lookAt(Vec3(0, 2, 5), Vec3(0, 0, 0));

    LightSet lights;
    lights.dirEnabled = true;
    lights.dir.direction = Vec3(-0.6f, -1.0f, -0.4f).normalized();
    lights.dir.color = Vec3(1.0f, 0.96f, 0.9f);
    lights.dir.intensity = 2.5f;
    lights.dir.castShadows = true;

    app.input.actions.bindKey("quit", Key.escape);
    auto fps = FpsCounter.create();

    while (app.running()) {
        app.pollEvents();
        app.handleResize();
        immutable float dt = fps.tick();
        if (app.input.actionPressed("quit")) break;

        immutable step = clock.advance(dt);
        tw.update(step.scaledDt);

        auto frame = app.beginFrame(Color4(0.05f, 0.07f, 0.10f));
        if (!frame.valid) continue;

        scene.begin(camera);
        scene.drawMatrix(mesh, mat, Mat4.trs(Vec3(0, 0, 0), Quat.identity(), Vec3(1, 1, 1)), Color4.white);
        scene.renderShadows(frame, lights);
        scene.end(frame);
        app.resolvePost(frame);
        app.endFrame(frame);
    }
}
