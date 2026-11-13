/// PBR validation demo — 5×2 sphere grid (dielectric / metal × roughness),
/// directional + point + spot lights with shadows, IBL, and one glTF PBR cube.
module demo.pbr;

import std.math : sin, cos, PI;

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
import engine.scene.light :
    LightSet, GpuPointLight, GpuSpotLight,
    MAX_POINT_SHADOW_CASTERS, MAX_SPOT_SHADOW_CASTERS,
    POINT_SHADOW_RESOLUTION, SPOT_SHADOW_RESOLUTION;
import engine.scene.scene3d_textured : Scene3DTextured;

@safe:

private enum W = 1280;
private enum H = 720;

void main() {
    auto app = App.create("PBR Demo — Multi-Light + Shadows", W, H);

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

    // 5 cols × 4 rows (OpenPBR Surface v1.1 showcase):
    //   Row 0: Dielectric + Fujii Oren-Nayar diffuse (roughness 0.04 -> 1.0)
    //   Row 1: Conductor F82 edge tint + Anisotropy (roughness 0.04 -> 0.8)
    //   Row 2: Automotive Clearcoat + Darkening (coatRoughness 0.02 -> 0.4)
    //   Row 3: Velvet Fuzz (cols 0..2) + Thin-Film Iridescence (cols 3..4)
    enum COLS = 5;
    enum ROWS = 4;
    Material[COLS * ROWS] sphereMats;
    foreach (row; 0 .. ROWS) {
        foreach (col; 0 .. COLS) {
            MaterialParams p;
            immutable t = cast(float) col / cast(float)(COLS - 1);
            if (row == 0) {
                p.baseColor = [0.9f, 0.15f, 0.12f];
                p.baseMetalness = 0.0f;
                p.baseDiffuseRoughness = 0.5f;
                p.specularIor = 1.5f;
                p.specularRoughness = t < 0.04f ? 0.04f : t;
            } else if (row == 1) {
                p.baseColor = [0.95f, 0.78f, 0.45f];
                p.specularColor = [1.0f, 0.65f, 0.35f];
                p.baseMetalness = 1.0f;
                p.specularAnisotropy = 0.6f;
                p.specularRoughness = 0.04f + t * 0.76f;
            } else if (row == 2) {
                p.baseColor = [0.08f, 0.25f, 0.75f];
                p.baseMetalness = 0.6f;
                p.specularRoughness = 0.35f;
                p.coatWeight = 1.0f;
                p.coatColor = [0.85f, 0.95f, 1.0f];
                p.coatRoughness = 0.02f + t * 0.38f;
                p.coatDarkening = 1.0f;
            } else if (col < 3) {
                p.baseColor = [0.35f, 0.08f, 0.45f];
                p.baseMetalness = 0.0f;
                p.specularWeight = 0.2f;
                p.specularRoughness = 0.7f;
                p.fuzzWeight = 1.0f;
                p.fuzzColor = [0.85f, 0.65f, 1.0f];
                p.fuzzRoughness = 0.2f + cast(float) col * 0.3f;
            } else {
                p.baseColor = [0.15f, 0.15f, 0.18f];
                p.baseMetalness = 0.8f;
                p.specularRoughness = 0.12f;
                p.thinFilmWeight = 1.0f;
                p.thinFilmThickness = 380.0f + cast(float)(col - 3) * 140.0f;
                p.thinFilmIor = 1.5f;
            }
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

    auto shadowPipe = createShadowPipeline(app.gpu.getDevice());
    scope(exit) shadowPipe.release();
    auto lightBuf = createUniformBuffer(app.gpu.getDevice(), 64);
    scope(exit) destroyBuffer(lightBuf);
    auto lightBg = createUniformBindGroup(app.gpu.getDevice(), shadowPipe.bindGroupLayout, lightBuf, 64);
    scope(exit) releaseBindGroup(lightBg);
    auto shadowInstanceBuf = createDynamicVertexBuffer(app.gpu.getDevice(), 32 * InstanceData.sizeof);
    scope(exit) destroyBuffer(shadowInstanceBuf);

    auto dirShadow = ShadowMap.create(app.gpu, 2048);
    scope(exit) dirShadow.destroy();
    auto pointShadow = PointShadowMap.create(app.gpu, POINT_SHADOW_RESOLUTION, 0.1f, 18.0f);
    scope(exit) pointShadow.destroy();
    auto spotShadow = SpotShadowMap.create(app.gpu, SPOT_SHADOW_RESOLUTION);
    scope(exit) spotShadow.destroy();

    immutable lightDir = Vec3(0.45f, 1.0f, 0.35f);
    immutable pointPos = Vec3(-2.5f, 3.5f, 1.5f);
    immutable spotPos = Vec3(3.5f, 5.0f, 2.0f);
    immutable spotDir = Vec3(-0.35f, -1.0f, -0.4f);

    auto camera = Camera.create(0.85f, W, H);
    camera.lookAt(Vec3(0, 4.5f, 11), Vec3(0, 1.2f, 0));

    auto text = TextRenderer.create(app.gpu, W, H);
    scope(exit) text.destroy();
    auto fps = FpsCounter.create();

    info("PBR multi-light demo — ESC to quit");

    float time = 0;
    while (app.running()) {
        app.pollEvents();
        immutable dt = fps.tick();
        time += dt;
        if (app.input.keyPressed(Key.escape)) break;

        if (app.input.keyPressed(Key.equals) || app.input.keyPressed(Key.kpPlus))
            app.post.exposure += 0.1f;
        if (app.input.keyPressed(Key.minus) || app.input.keyPressed(Key.kpMinus)) {
            app.post.exposure -= 0.1f;
            if (app.post.exposure < 0.05f) app.post.exposure = 0.05f;
        }
        if (app.input.keyPressed(Key.b))
            app.post.bloom = !app.post.bloom;
        if (app.input.keyPressed(Key.f))
            app.post.fxaa = !app.post.fxaa;

        immutable camR = 12.0f;
        camera.lookAt(
            Vec3(sin(time * 0.12f) * camR, 4.5f, cos(time * 0.12f) * camR),
            Vec3(0, 1.2f, 0),
        );

        immutable lightVP = directionalLightVP(lightDir, Vec3(0, 1, 0), 14.0f);
        immutable spotVP = spotLightVPFromCone(spotPos, spotDir, 30.0f, 0.1f, 20.0f);

        // Shadow casters: spheres + tall cube + glTF cube
        InstanceData[COLS * ROWS + 2] casters;
        uint ci = 0;
        foreach (row; 0 .. ROWS) {
            foreach (col; 0 .. COLS) {
                immutable x = (cast(float) col - (COLS - 1) * 0.5f) * 1.6f;
                immutable z = (cast(float) row - (ROWS - 1) * 0.5f) * 2.0f;
                auto model = Mat4.translation(x, 1.0f, z) * Mat4.scaling(1, 1, 1);
                casters[ci++] = InstanceData(model.m, Color4.white.toArray());
            }
        }
        {
            auto model = Mat4.translation(-4.5f, 1.5f, -4.5f) * Mat4.scaling(1.2f, 3.0f, 1.2f);
            casters[ci++] = InstanceData(model.m, Color4.white.toArray());
        }
        {
            auto model = Mat4.translation(4.5f, 0.75f, -4.0f)
                       * Mat4.rotationY(time * 0.4f)
                       * Mat4.scaling(1.5f, 1.5f, 1.5f);
            casters[ci++] = InstanceData(model.m, Color4.white.toArray());
        }
        updateBuffer(app.gpu.getQueue(), shadowInstanceBuf, casters[0 .. ci]);

        // Directional shadow
        submitShadowPass(app.gpu, dirShadow, shadowPipe, lightBg, lightBuf, lightVP,
                         sphere, shadowInstanceBuf, COLS * ROWS);
        InstanceData[2] extra = casters[COLS * ROWS .. COLS * ROWS + 2];
        updateBuffer(app.gpu.getQueue(), shadowInstanceBuf, extra[]);
        submitShadowPass(app.gpu, dirShadow, shadowPipe, lightBg, lightBuf, lightVP,
                         cube, shadowInstanceBuf, 2, /*clear=*/false);

        // Point cubemap (spheres + cubes)
        updateBuffer(app.gpu.getQueue(), shadowInstanceBuf, casters[0 .. COLS * ROWS]);
        immutable faceVPs = pointLightFaceVPs(pointPos, pointShadow.nearPlane, pointShadow.farPlane);
        foreach (face; 0 .. 6) {
            submitPointShadowFace(app.gpu, pointShadow, face, shadowPipe, lightBg, lightBuf,
                                  faceVPs[face], sphere, shadowInstanceBuf, COLS * ROWS);
            updateBuffer(app.gpu.getQueue(), shadowInstanceBuf, extra[]);
            submitPointShadowFace(app.gpu, pointShadow, face, shadowPipe, lightBg, lightBuf,
                                  faceVPs[face], cube, shadowInstanceBuf, 2, /*clear=*/false);
        }

        // Spot perspective shadow
        updateBuffer(app.gpu.getQueue(), shadowInstanceBuf, casters[0 .. COLS * ROWS]);
        submitSpotShadowPass(app.gpu, spotShadow, shadowPipe, lightBg, lightBuf, spotVP,
                             sphere, shadowInstanceBuf, COLS * ROWS);
        updateBuffer(app.gpu.getQueue(), shadowInstanceBuf, extra[]);
        submitSpotShadowPass(app.gpu, spotShadow, shadowPipe, lightBg, lightBuf, spotVP,
                             cube, shadowInstanceBuf, 2, /*clear=*/false);

        LightSet lights;
        lights.dirEnabled = true;
        lights.dir.direction = lightDir;
        lights.dir.viewProj = lightVP;
        lights.dir.color = Vec3(1.0f, 0.98f, 0.92f);
        lights.dir.intensity = 2.2f;
        lights.dir.castShadows = true;

        lights.points[0] = GpuPointLight(
            pointPos, Vec3(0.3f, 0.7f, 1.0f), 12.0f, 18.0f, true);
        lights.pointCount = 1;

        lights.spots[0] = GpuSpotLight(
            spotPos, spotDir, Vec3(1.0f, 0.85f, 0.55f), 18.0f, 20.0f,
            18.0f, 30.0f, spotVP, true);
        lights.spotCount = 1;
        lights.shadowBias = 0.0004f;

        PointShadowMap*[MAX_POINT_SHADOW_CASTERS] pointMaps;
        pointMaps[0] = &pointShadow;
        SpotShadowMap*[MAX_SPOT_SHADOW_CASTERS] spotMaps;
        spotMaps[0] = &spotShadow;
        scene.setLights(lights, &dirShadow, pointMaps, spotMaps);

        auto frame = app.beginFrame(Color4(0.04f, 0.045f, 0.06f, 1));
        if (!frame.valid) continue;

        scene.begin(camera);
        scene.draw(quad, groundMat, Vec3(0, 0, 0), Vec3(30, 1, 30), Color4(0.85f, 0.85f, 0.9f, 1));

        foreach (row; 0 .. ROWS) {
            foreach (col; 0 .. COLS) {
                immutable x = (cast(float) col - (COLS - 1) * 0.5f) * 1.6f;
                immutable z = (cast(float) row - (ROWS - 1) * 0.5f) * 2.0f;
                scene.draw(sphere, sphereMats[row * COLS + col],
                           Vec3(x, 1.0f, z), Vec3(1, 1, 1));
            }
        }

        scene.draw(cube, casterMat, Vec3(-4.5f, 1.5f, -4.5f), Vec3(1.2f, 3.0f, 1.2f));
        scene.drawMatrix(gltfModel.mesh, gltfModel.material,
            Mat4.translation(4.5f, 0.75f, -4.0f)
          * Mat4.rotationY(time * 0.4f)
          * Mat4.scaling(1.5f, 1.5f, 1.5f),
            Color4.white);

        scene.end(frame);

        app.resolvePost(frame);

        import std.format : format;
        text.beginFrame();
        text.drawText(frame, "OpenPBR v1.1: Oren-Nayar / F82 Aniso / Coat / Fuzz & Thin-Film", 16, 16, 2);
        text.drawText(frame, format("IBL + bloom/FXAA  exp=%.2f  B=%s  F=%s",
            app.post.exposure,
            app.post.bloom ? "on" : "off",
            app.post.fxaa ? "on" : "off"), 16, 44, 2);
        text.drawText(frame, format("FPS: %.0f   +/- exposure  B bloom  F FXAA", fps.fps), 16, 72, 2);

        app.endFrame(frame);
    }

    app.destroy();
}
