/// Showcase demo for Phase 6 (textures + materials) and Phase 7 (scene graph).
/// Renders a small solar system: a textured "sun" cube with two orbiting planets,
/// each with its own moon. All transforms come from the SceneGraph hierarchy.
module demo.showcase;

import engine.app;
import engine.core.log;
import engine.gpu.text;
import engine.graphics.material : Material;
import engine.graphics.mesh : Mesh;
import engine.graphics.texmesh : TexMesh;
import engine.graphics.texture : Texture, Sampler, TextureFilter, TextureWrap;
import engine.graphics.types : Color4;
import engine.math.mat : Mat4;
import engine.math.vec : Vec3;
import engine.platform.input : Key;
import engine.scene.camera : Camera;
import engine.scene.graph : SceneGraph, NodeId, Transform, ROOT;
import engine.scene.scene3d : Scene3D;
import engine.scene.scene3d_textured : Scene3DTextured;

import std.math : sin, cos;

@safe:

private enum W = 1280;
private enum H = 720;

void main() {
    auto app = App.create("Textures + SceneGraph Demo", W, H);

    // --- Textured renderer + materials ---
    auto texScene = Scene3DTextured.create(app.gpu);
    scope(exit) texScene.destroy();
    auto cubeMesh = TexMesh.cube(app.gpu);
    scope(exit) cubeMesh.destroy();
    auto quadMesh = TexMesh.quad(app.gpu);
    scope(exit) quadMesh.destroy();

    // Shared sampler used by every material.
    auto sampler = Sampler.create(app.gpu, TextureFilter.linear, TextureWrap.repeat);
    scope(exit) sampler.destroy();

    // Three distinct textures built procedurally (no asset files needed).
    auto sunTex    = Texture.checker(app.gpu, 64, [255,220, 80,255], [255,140, 40,255]);
    scope(exit) sunTex.destroy();
    auto earthTex  = Texture.checker(app.gpu, 64, [ 80,170,255,255], [ 40,120,200,255]);
    scope(exit) earthTex.destroy();
    auto marsTex   = Texture.checker(app.gpu, 64, [220,120, 70,255], [160, 80, 40,255]);
    scope(exit) marsTex.destroy();
    auto moonTex   = Texture.checker(app.gpu, 32, [220,220,220,255], [120,120,120,255]);
    scope(exit) moonTex.destroy();
    auto groundTex = Texture.checker(app.gpu, 256, [ 50, 50, 60,255], [ 30, 30, 40,255]);
    scope(exit) groundTex.destroy();

    auto layout = texScene.bindGroupLayout();
    auto uniBuf = texScene.sharedUniformBuffer();

    auto sunMat   = Material.create(app.gpu, layout, uniBuf, sampler, sunTex);
    scope(exit) sunMat.destroy();
    auto earthMat = Material.create(app.gpu, layout, uniBuf, sampler, earthTex);
    scope(exit) earthMat.destroy();
    auto marsMat  = Material.create(app.gpu, layout, uniBuf, sampler, marsTex);
    scope(exit) marsMat.destroy();
    auto moonMat  = Material.create(app.gpu, layout, uniBuf, sampler, moonTex);
    scope(exit) moonMat.destroy();
    auto groundMat = Material.create(app.gpu, layout, uniBuf, sampler, groundTex);
    scope(exit) groundMat.destroy();

    // --- Scene graph: sun → (earth → moon), (mars → moon) ---
    auto graph = SceneGraph.create();

    immutable sunNode     = graph.addChild(ROOT,     Transform(Vec3(0, 1.5f, 0), Vec3(1.2f, 1.2f, 1.2f)));
    immutable earthOrbit  = graph.addChild(sunNode,  Transform(Vec3(0, 0, 0),    Vec3(1, 1, 1)));
    immutable earthNode   = graph.addChild(earthOrbit, Transform(Vec3(3.5f, 0, 0), Vec3(0.5f, 0.5f, 0.5f)));
    immutable earthMoonOrbit = graph.addChild(earthNode, Transform(Vec3(0, 0, 0), Vec3(1, 1, 1)));
    immutable earthMoon   = graph.addChild(earthMoonOrbit, Transform(Vec3(1.2f, 0, 0), Vec3(0.4f, 0.4f, 0.4f)));
    immutable marsOrbit   = graph.addChild(sunNode,  Transform(Vec3(0, 0, 0),   Vec3(1, 1, 1)));
    immutable marsNode    = graph.addChild(marsOrbit, Transform(Vec3(-5.5f, 0, 0.5f), Vec3(0.7f, 0.7f, 0.7f)));
    immutable marsMoonOrbit = graph.addChild(marsNode, Transform(Vec3(0, 0, 0), Vec3(1, 1, 1)));
    immutable marsMoon    = graph.addChild(marsMoonOrbit, Transform(Vec3(1.4f, 0, 0), Vec3(0.3f, 0.3f, 0.3f)));

    auto camera = Camera.create(0.9f, W, H);
    camera.lookAt(Vec3(0, 7, 12), Vec3(0, 1, 0));

    auto textRenderer = TextRenderer.create(app.gpu, W, H);
    scope(exit) textRenderer.destroy();
    auto fps = FpsCounter.create();

    info("Showcase running — WASD/arrows to orbit, ESC to quit");

    float time = 0;

    while (app.running()) {
        app.pollEvents();
        immutable dt = fps.tick();
        time += dt;

        if (app.input.keyPressed(Key.escape)) break;

        // --- Animate via graph transforms ---
        graph.transform(sunNode).rotationY        = time * 0.3f;
        graph.transform(earthOrbit).rotationY     = time * 0.8f;
        graph.transform(earthNode).rotationY      = time * 1.5f;
        graph.transform(earthMoonOrbit).rotationY = time * 2.5f;
        graph.transform(marsOrbit).rotationY      = time * 0.5f;
        graph.transform(marsNode).rotationY       = time * 1.2f;
        graph.transform(marsMoonOrbit).rotationY  = time * 1.8f;

        // Camera orbit
        immutable camR = 14.0f;
        camera.lookAt(
            Vec3(cos(time * 0.15f) * camR, 7, sin(time * 0.15f) * camR),
            Vec3(0, 1, 0),
        );

        // Resolve world matrices for all nodes in one sweep.
        graph.updateWorld();

        // --- Render ---
        auto frame = app.beginFrame(Color4(0.02f, 0.02f, 0.06f, 1.0f));
        if (!frame.valid) continue;

        texScene.begin(camera);

        // Ground plane
        texScene.draw(quadMesh, groundMat,
                      Vec3(0, 0, 0), Vec3(40, 1, 40),
                      Color4(0.8f, 0.8f, 0.9f, 1));

        // Each body uses its world matrix from the graph.
        texScene.drawMatrix(cubeMesh, sunMat,   graph.worldMatrix(sunNode),   Color4(1.2f, 1.0f, 0.6f, 1));
        texScene.drawMatrix(cubeMesh, earthMat, graph.worldMatrix(earthNode), Color4.white);
        texScene.drawMatrix(cubeMesh, moonMat,  graph.worldMatrix(earthMoon), Color4.white);
        texScene.drawMatrix(cubeMesh, marsMat,  graph.worldMatrix(marsNode),  Color4.white);
        texScene.drawMatrix(cubeMesh, moonMat,  graph.worldMatrix(marsMoon),  Color4.white);

        texScene.end(frame);

        // HUD
        import std.format : format;
        textRenderer.beginFrame();
        textRenderer.drawText(frame, "Phase 6: Textures + Materials", 20, 20, 2);
        textRenderer.drawText(frame, "Phase 7: Scene Graph Hierarchy", 20, 50, 2);
        textRenderer.drawText(frame, format("FPS: %.0f  nodes: %d", fps.fps, graph.length),
                              20, 90, 2);

        app.endFrame(frame);
    }

    app.destroy();
}
