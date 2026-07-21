/// PBR validation demo — 5×2 sphere grid (dielectric / metal × roughness),
/// directional light with PCF shadows, IBL, and one glTF PBR cube asset.
module demo.pbr;

import std.math : sin, cos;

import engine.app;
import engine.assets.gltf : loadGltfPbr;
import engine.core.log;
import engine.gpu.buffer;
import engine.gpu.shadow;
import engine.gpu.text;
import engine.graphics.material : Material, MaterialParams;
import engine.graphics.texmesh : TexMesh;
import engine.graphics.texture : Texture, Sampler, TextureFilter, TextureWrap;
import engine.graphics.types : Color4, InstanceData;
import engine.math.mat : Mat4;
import engine.math.vec : Vec3;
import engine.platform.input : Key;
import engine.scene.camera : Camera;
import engine.scene.scene3d_textured : Scene3DTextured;

@safe:

private enum W = 1280;
private enum H = 720;

void main() {
    auto app = App.create("PBR Demo — Metallic/Roughness Grid", W, H);

    auto scene = Scene3DTextured.create(app.gpu);
    scope(exit) scene.destroy();

    auto sphere = TexMesh.sphere(app.gpu, 48, 24);
    scope(exit) sphere.destroy();
    auto quad = TexMesh.quad(app.gpu);
    scope(exit) quad.destroy();
    auto cube = TexMesh.cube(app.gpu);
    scope(exit) cube.destroy();

    auto sampler = Sampler.create(app.gpu, TextureFilter.linear, TextureWrap.repeat);
    scope(exit) sampler.destroy();

    auto whiteTex = Texture.solid(app.gpu, 255, 255, 255, 255);
    scope(exit) whiteTex.destroy();
    auto groundTex = Texture.checker(app.gpu, 128, [60, 60, 70, 255], [35, 35, 42, 255]);
    scope(exit) groundTex.destroy();
    auto casterTex = Texture.solid(app.gpu, 200, 200, 210, 255);
    scope(exit) casterTex.destroy();

    auto layout = scene.materialLayout();

    // 5 roughness × 2 rows (dielectric / metal)
    enum COLS = 5;
    Material[COLS * 2] sphereMats;
    foreach (row; 0 .. 2) {
        foreach (col; 0 .. COLS) {
            MaterialParams p;
            p.baseColorFactor = row == 0
                ? [0.9f, 0.15f, 0.12f, 1.0f]   // dielectric red
                : [0.95f, 0.85f, 0.55f, 1.0f]; // gold metal
            p.metallic = row == 0 ? 0.0f : 1.0f;
            p.roughness = cast(float) col / cast(float)(COLS - 1);
            if (p.roughness < 0.04f) p.roughness = 0.04f;
            sphereMats[row * COLS + col] = Material.create(
                app.gpu, layout, sampler, whiteTex, p, null, null, null, null);
        }
    }
    scope(exit) foreach (ref m; sphereMats) m.destroy();

    auto groundMat = Material.create(app.gpu, layout, sampler, groundTex);
    scope(exit) groundMat.destroy();
    auto casterMat = Material.create(app.gpu, layout, sampler, casterTex);
    scope(exit) casterMat.destroy();

    // glTF PBR cube
    auto gltfModel = loadGltfPbr(app.gpu, "assets/models/pbr_cube.gltf", layout, sampler);
    scope(exit) gltfModel.destroy();

    auto shadowMap = ShadowMap.create(app.gpu, 2048);
    scope(exit) shadowMap.destroy();
    auto shadowPipe = createShadowPipeline(app.gpu.getDevice());
    scope(exit) shadowPipe.release();
    auto lightBuf = createUniformBuffer(app.gpu.getDevice(), 64);
    scope(exit) destroyBuffer(lightBuf);
    auto lightBg = createUniformBindGroup(app.gpu.getDevice(), shadowPipe.bindGroupLayout, lightBuf, 64);
    scope(exit) releaseBindGroup(lightBg);
    auto shadowInstanceBuf = createDynamicVertexBuffer(app.gpu.getDevice(), 32 * InstanceData.sizeof);
    scope(exit) destroyBuffer(shadowInstanceBuf);

    immutable lightDir = Vec3(0.45f, 1.0f, 0.35f);

    auto camera = Camera.create(0.85f, W, H);
    camera.lookAt(Vec3(0, 4.5f, 11), Vec3(0, 1.2f, 0));

    auto text = TextRenderer.create(app.gpu, W, H);
    scope(exit) text.destroy();
    auto fps = FpsCounter.create();

    info("PBR demo — ESC to quit");

    float time = 0;
    while (app.running()) {
        app.pollEvents();
        immutable dt = fps.tick();
        time += dt;
        if (app.input.keyPressed(Key.escape)) break;

        immutable camR = 12.0f;
        camera.lookAt(
            Vec3(sin(time * 0.12f) * camR, 4.5f, cos(time * 0.12f) * camR),
            Vec3(0, 1.2f, 0),
        );

        immutable lightVP = directionalLightVP(lightDir, Vec3(0, 1, 0), 14.0f);

        // Shadow: spheres + caster cube + glTF cube
        InstanceData[COLS * 2 + 2] casters;
        uint ci = 0;
        foreach (row; 0 .. 2) {
            foreach (col; 0 .. COLS) {
                immutable x = (cast(float) col - (COLS - 1) * 0.5f) * 1.6f;
                immutable z = (cast(float) row - 0.5f) * 2.2f;
                auto model = Mat4.translation(x, 1.0f, z) * Mat4.scaling(1, 1, 1);
                casters[ci++] = InstanceData(model.m, Color4.white.toArray());
            }
        }
        {
            auto model = Mat4.translation(-4.5f, 1.5f, -3.0f) * Mat4.scaling(1.2f, 3.0f, 1.2f);
            casters[ci++] = InstanceData(model.m, Color4.white.toArray());
        }
        {
            auto model = Mat4.translation(4.5f, 0.75f, -2.5f)
                       * Mat4.rotationY(time * 0.4f)
                       * Mat4.scaling(1.5f, 1.5f, 1.5f);
            casters[ci++] = InstanceData(model.m, Color4.white.toArray());
        }
        updateBuffer(app.gpu.getQueue(), shadowInstanceBuf, casters[0 .. ci]);
        // Draw spheres as shadow casters (same mesh for first N)
        submitShadowPass(app.gpu, shadowMap, shadowPipe, lightBg, lightBuf, lightVP,
                         sphere, shadowInstanceBuf, COLS * 2);
        // Extra casters: load existing depth so sphere shadows are kept
        InstanceData[2] extra = casters[COLS * 2 .. COLS * 2 + 2];
        updateBuffer(app.gpu.getQueue(), shadowInstanceBuf, extra[]);
        submitShadowPass(app.gpu, shadowMap, shadowPipe, lightBg, lightBuf, lightVP,
                         cube, shadowInstanceBuf, 2, /*clear=*/false);

        scene.setLighting(lightDir, lightVP, shadowMap);

        auto frame = app.beginFrame(Color4(0.04f, 0.045f, 0.06f, 1));
        if (!frame.valid) continue;

        scene.begin(camera);
        scene.draw(quad, groundMat, Vec3(0, 0, 0), Vec3(30, 1, 30), Color4(0.85f, 0.85f, 0.9f, 1));

        foreach (row; 0 .. 2) {
            foreach (col; 0 .. COLS) {
                immutable x = (cast(float) col - (COLS - 1) * 0.5f) * 1.6f;
                immutable z = (cast(float) row - 0.5f) * 2.2f;
                scene.draw(sphere, sphereMats[row * COLS + col],
                           Vec3(x, 1.0f, z), Vec3(1, 1, 1));
            }
        }

        scene.draw(cube, casterMat, Vec3(-4.5f, 1.5f, -3.0f), Vec3(1.2f, 3.0f, 1.2f));
        scene.drawMatrix(gltfModel.mesh, gltfModel.material,
            Mat4.translation(4.5f, 0.75f, -2.5f)
          * Mat4.rotationY(time * 0.4f)
          * Mat4.scaling(1.5f, 1.5f, 1.5f),
            Color4.white);

        scene.end(frame);

        import std.format : format;
        text.beginFrame();
        text.drawText(frame, "PBR: dielectric (top) / metal (bottom)  roughness 0 -> 1", 16, 16, 2);
        text.drawText(frame, "IBL + PCF shadows + glTF cube", 16, 44, 2);
        text.drawText(frame, format("FPS: %.0f", fps.fps), 16, 72, 2);

        app.endFrame(frame);
    }

    app.destroy();
}
