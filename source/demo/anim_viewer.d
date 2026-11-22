/// Windowed animation viewer: a `pab` character blending walk/jog, GPU-skinned procedural bone mesh
/// plus skeleton gizmos.
///
///   Left/Right: blend weight (walk <-> jog)   Up/Down: playback speed
///   G: toggle head look-at (target orbits)    Esc: quit
///   --pbr: render with Scene3DTextured (OpenPBR, CSM/point/spot shadows, IBL, sky)
///   --crowd=N: spawn N animated characters (batches all instances sharing SkinnedMesh + Material)
///   --bench=FRAMES: run FRAMES after warmup, print frame/anim ms, draw calls and GC delta, exit
///   --capture=<file.ppm> [--capture-frame=N]: save presented frame N (default 60, GPU readback), exit
module demo.anim_viewer;

import core.memory : GC;
import std.conv : to;
import std.datetime.stopwatch : AutoStart, StopWatch;
import std.math : cos, sin, sqrt;
import std.stdio : File, stderr, writefln;

import bindings.wgpu : WGPUPresentMode;
import engine.animation;
import engine.animation.ecs;
import engine.app : App;
import engine.devtools.anim_overlay : animationOverlay;
import engine.devtools.gizmos : GizmoRenderer;
import engine.devtools.overlay : DebugOverlay;
import engine.ecs.store : EntityId;
import engine.ecs.world : World;
import engine.gpu.skinned : SkinnedMesh, SkinnedRenderer, SkinnedVertex;
import engine.gpu.text : FpsCounter, TextRenderer;
import engine.graphics.material : Material, MaterialParams;
import engine.graphics.texmesh : TexMesh;
import engine.graphics.texture : Sampler, Texture, TextureFilter, TextureWrap;
import engine.graphics.types : Color4;
import engine.math.mat : Mat4;
import engine.math.vec : Vec3;
import engine.platform.input : Key;
import engine.scene.camera : Camera;
import engine.scene.cascades : CascadeSettings;
import engine.scene.light : LightSet;
import engine.scene.scene3d_textured : Scene3DTextured;

alias AnimWorld = World!(AnimSkeleton, AnimPlayback, AnimBlend2, AnimAdditive, AnimLookAt, AnimTwoBoneIK);

private enum SCREEN_W = 1280;
private enum SCREEN_H = 720;
private enum string fixtures = "assets/animation/test/";

int main(string[] args) {
    string capturePath;
    uint frameNo, captureFrame = 60;
    bool pbrMode = false;
    uint crowdCount = 1;
    uint benchFrames = 0;

    foreach (a; args[1 .. $]) {
        if (a.length > 10 && a[0 .. 10] == "--capture=") capturePath = a[10 .. $];
        else if (a.length > 16 && a[0 .. 16] == "--capture-frame=") captureFrame = a[16 .. $].to!uint;
        else if (a == "--pbr") pbrMode = true;
        else if (a.length > 8 && a[0 .. 8] == "--crowd=") crowdCount = a[8 .. $].to!uint;
        else if (a.length > 8 && a[0 .. 8] == "--bench=") benchFrames = a[8 .. $].to!uint;
    }
    if (crowdCount == 0) crowdCount = 1;

    AnimAssets assets;
    PosePool pool;
    AnimWorld world;
    string err;
    auto sk = loadSkeletonFile(assets.skeletons, fixtures ~ "pab/skeleton.ozz", err);
    auto walk = loadAnimationFile(assets.animations, fixtures ~ "pab/walk.ozz", err);
    auto jog = loadAnimationFile(assets.animations, fixtures ~ "pab/jog.ozz", err);
    if (sk.isNull || walk.isNull || jog.isNull) {
        stderr.writeln("anim_viewer: ", err);
        return 1;
    }
    immutable joints = assets.skeletons.get(sk).numJoints;
    auto boneMesh = buildBoneMesh(*assets.skeletons.get(sk), 0.035f);
    boneMesh.binding.skeleton = sk;
    immutable skin = assets.skins.add(boneMesh.binding);

    auto entities = new EntityId[crowdCount];
    auto charPositions = new Vec3[crowdCount];
    immutable uint cols = cast(uint) sqrt(cast(float) crowdCount) + (crowdCount > 1 ? 1 : 0);
    immutable float spacing = 1.6f;
    foreach (idx; 0 .. crowdCount) {
        immutable e = world.spawn();
        immutable slot = pool.acquire(joints);
        world.set(e, AnimSkeleton(sk, slot, skin));
        immutable float phase = (cast(float) idx) * 0.13f;
        immutable float bw = crowdCount == 1 ? 0.0f : (cast(float)(idx % 5)) * 0.25f;
        AnimBlend2 ab = AnimBlend2(walk, jog, bw);
        ab.timeA = phase;
        ab.timeB = phase;
        world.set(e, ab);
        if (idx == 0)
            world.set(e, AnimLookAt(joints / 2, Vec3(0, 1, 2), 0.0f, Vec3(0, 0, 1), Vec3(0, 1, 0)));
        entities[idx] = e;
        if (crowdCount == 1) {
            charPositions[idx] = Vec3(0, 0, 0);
        } else {
            immutable r = idx / cols;
            immutable c = idx % cols;
            immutable float ox = (cast(float) c - (cast(float)(cols - 1)) * 0.5f) * spacing;
            immutable float oz = (cast(float) r - (cast(float)((crowdCount - 1) / cols)) * 0.5f) * spacing;
            charPositions[idx] = Vec3(ox, 0, oz);
        }
    }

    immutable presentMode = benchFrames > 0 ? WGPUPresentMode.immediate : WGPUPresentMode.fifo;
    auto app = App.create("Animation viewer", SCREEN_W, SCREEN_H, presentMode);
    auto text = TextRenderer.create(app.gpu, SCREEN_W, SCREEN_H);
    scope(exit) text.destroy();
    auto gizmos = GizmoRenderer.create(app.gpu);
    scope(exit) gizmos.destroy();

    SkinnedVertex[] gpuVerts;
    gpuVerts.length = boneMesh.vertices.length;
    foreach (vi, ref v; boneMesh.vertices) {
        SkinnedVertex g;
        g.position = v.position;
        g.normal = v.normal;
        g.uv = [cast(float)(vi % 4) * 0.25f, cast(float)((vi / 4) % 2)];
        g.tangent = [1.0f, 0.0f, 0.0f, 1.0f];
        g.joints = v.joints;
        g.weights = v.weights;
        gpuVerts[vi] = g;
    }

    // Legacy pipeline (default mode)
    SkinnedRenderer skinned;
    if (!pbrMode)
        skinned = SkinnedRenderer.create(app.gpu, gpuVerts, boneMesh.indices);
    scope(exit) if (!pbrMode) skinned.destroy();

    // PBR Scene3DTextured pipeline (--pbr mode)
    Scene3DTextured scene;
    SkinnedMesh pbrMesh;
    TexMesh groundMesh;
    Sampler sampler;
    Texture charTex;
    Texture groundTex;
    Material charMat;
    Material groundMat;
    LightSet lights;
    if (pbrMode) {
        scene = Scene3DTextured.create(app.gpu);
        scene.setSkyEnabled(true);
        scene.setWeather(0.0f, 0.0f, 0.2f);
        pbrMesh = SkinnedMesh.fromData(app.gpu, gpuVerts, boneMesh.indices);
        groundMesh = TexMesh.quad(app.gpu);
        sampler = Sampler.create(app.gpu, TextureFilter.linear, TextureWrap.repeat);
        charTex = Texture.solid(app.gpu, 185, 200, 235, 255);
        groundTex = Texture.checker(app.gpu, 256, [120, 125, 130, 255], [75, 80, 86, 255]);
        MaterialParams cp;
        cp.baseColor = [0.85f, 0.9f, 1.0f];
        cp.baseMetalness = 0.25f;
        cp.specularRoughness = 0.35f;
        charMat = Material.create(app.gpu, scene.materialLayout(), sampler, charTex, cp, null, null, null, null);
        MaterialParams gp;
        gp.specularRoughness = 0.85f;
        groundMat = Material.create(app.gpu, scene.materialLayout(), sampler, groundTex, gp, null, null, null, null);

        lights.dirEnabled = true;
        lights.dir.direction = Vec3(0.55f, 0.8f, 0.45f).normalized();
        lights.dir.color = Vec3(1.0f, 0.96f, 0.9f);
        lights.dir.intensity = 3.5f;
        lights.dir.castShadows = true;
        CascadeSettings cc;
        cc.count = 3;
        cc.resolution = 1024;
        cc.maxDistance = 40.0f;
        lights.dir.cascades = cc;

        lights.pointCount = 1;
        lights.points[0].position = Vec3(-2.5f, 2.2f, 2.0f);
        lights.points[0].color = Vec3(1.0f, 0.72f, 0.45f);
        lights.points[0].intensity = 8.0f;
        lights.points[0].range = 12.0f;
        lights.points[0].castShadows = true;

        lights.spotCount = 1;
        lights.spots[0].position = Vec3(2.8f, 3.8f, 2.5f);
        lights.spots[0].direction = Vec3(-0.55f, -0.75f, -0.45f).normalized();
        lights.spots[0].color = Vec3(0.6f, 0.8f, 1.0f);
        lights.spots[0].intensity = 14.0f;
        lights.spots[0].range = 18.0f;
        lights.spots[0].outerConeDeg = 38.0f;
        lights.spots[0].innerConeDeg = 22.0f;
        lights.spots[0].castShadows = true;
    }
    scope(exit) {
        if (pbrMode) {
            groundMat.destroy();
            charMat.destroy();
            groundTex.destroy();
            charTex.destroy();
            sampler.destroy();
            groundMesh.destroy();
            pbrMesh.destroy();
            scene.destroy();
        }
    }

    auto fps = FpsCounter.create();
    DebugOverlay overlay;
    auto camera = Camera.create(0.85f, SCREEN_W, SCREEN_H, 0.1f, 120.0f);
    if (crowdCount > 1)
        camera.lookAt(Vec3(0, 4.5f, 9.5f), Vec3(0, 0.8f, 0));
    else
        camera.lookAt(Vec3(0, 1.25f, 3.2f), Vec3(0, 0.9f, 0));

    enum uint WARMUP_FRAMES = 30;
    uint totalTicks = 0;
    size_t gcUsedStart = 0;
    double animSumMs = 0.0;
    double frameSumMs = 0.0;
    uint measuredCount = 0;
    uint lastDrawCalls = 0, lastShadowDrawCalls = 0, lastInstances = 0;

    float t = 0;
    while (app.running()) {
        app.pollEvents();
        immutable rawDt = fps.tick();
        immutable float dt = (benchFrames > 0 || capturePath.length > 0)
            ? (1.0f / 60.0f)
            : (rawDt > 0.1f ? 0.1f : rawDt);
        t += dt;
        if (app.input.keyPressed(Key.escape)) break;

        if (benchFrames > 0 && totalTicks == WARMUP_FRAMES)
            gcUsedStart = GC.stats().usedSize;

        auto blend = world.getPtr!AnimBlend2(entities[0]);
        auto look = world.getPtr!AnimLookAt(entities[0]);
        if (app.input.keyDown(Key.left)) blend.weight = blend.weight > 0 ? blend.weight - dt : 0;
        if (app.input.keyDown(Key.right)) blend.weight = blend.weight < 1 ? blend.weight + dt : 1;
        if (app.input.keyDown(Key.up)) blend.speed += dt;
        if (app.input.keyDown(Key.down)) blend.speed = blend.speed > 0.1f ? blend.speed - dt : 0.1f;
        if (app.input.keyPressed(Key.g)) look.weight = look.weight > 0 ? 0 : 1;
        look.target = Vec3(1.5f * cos(t), 1.4f, 1.5f * sin(t) + 0.5f);

        auto frameSw = StopWatch(AutoStart.yes);
        auto sw = StopWatch(AutoStart.yes);
        advancePlaybackSystem(world, assets, dt);
        sampleSystem(world, assets, pool);
        blendSystem(world, assets, pool);
        localToModelSystem(world, assets, pool);
        lookAtSystem(world, assets, pool);
        skinPaletteSystem(world, assets, pool);
        immutable animMs = sw.peek.total!"usecs" / 1000.0;

        auto frame = app.beginFrame(Color4(0.05f, 0.06f, 0.09f, 1.0f));
        if (!frame.valid) continue;

        if (pbrMode) {
            scene.setTime(t);
            scene.begin(camera);
            scene.drawMatrix(groundMesh, groundMat, Mat4.scaling(40.0f, 1.0f, 40.0f), Color4.white);
            foreach (idx, e; entities) {
                auto p = pool.get(world.getPtr!AnimSkeleton(e).poseSlot);
                if (p is null) continue;
                immutable m = Mat4.translation(charPositions[idx].x, charPositions[idx].y, charPositions[idx].z);
                scene.drawSkinned(pbrMesh, charMat, m, Color4.white,
                                  asMat4(p.palette), poseBoundingSphere(p.model));
            }
            scene.renderShadows(frame, lights);
            scene.end(frame);
            immutable st = scene.stats();
            lastDrawCalls = st.drawCalls;
            lastShadowDrawCalls = st.shadowDrawCalls;
            lastInstances = st.instancesVisible;
        } else {
            auto pose_ = pool.get(world.getPtr!AnimSkeleton(entities[0]).poseSlot);
            skinned.updatePalette(asMat4(pose_.palette));
            skinned.draw(frame, camera.viewProjection(), Color4(0.75f, 0.8f, 0.95f, 1.0f));
            gizmos.begin(camera.viewProjection());
            gizmos.grid(6, 12, Color4(0.25f, 0.28f, 0.35f, 1));
            drawSkeleton(gizmos, *assets.skeletons.get(sk), pose_.model);
            if (look.weight > 0) gizmos.axes(look.target, 0.15f);
            gizmos.render(frame);
        }

        app.resolvePost(frame);

        if (benchFrames == 0 && capturePath.length == 0) {
            overlay.beginFrame(dt);
            animationOverlay(overlay, crowdCount, animMs);
            text.beginFrame();
            text.drawText(frame, fps.text(), 10, 10, 2);
            text.drawText(frame, "Left/Right: walk<->jog   Up/Down: speed   G: look-at   Esc: quit",
                          10, SCREEN_H - 28, 2);
            overlay.render(text, frame);
        }
        immutable capturing = capturePath.length && ++frameNo == captureFrame;
        if (capturing) app.requestCapture();
        app.endFrame(frame);

        immutable frameMs = frameSw.peek.total!"usecs" / 1000.0;
        totalTicks++;
        if (benchFrames > 0 && totalTicks > WARMUP_FRAMES) {
            animSumMs += animMs;
            frameSumMs += frameMs;
            measuredCount++;
            if (measuredCount >= benchFrames) {
                immutable gcDelta = GC.stats().usedSize - gcUsedStart;
                writefln("anim_viewer %s bench: chars=%u frames=%u avgFrameMs=%.3f avgAnimMs=%.3f drawCalls=%u shadowDrawCalls=%u instancesVisible=%u gcDelta=%u",
                         pbrMode ? "PBR" : "legacy", crowdCount, measuredCount,
                         frameSumMs / measuredCount, animSumMs / measuredCount,
                         lastDrawCalls, lastShadowDrawCalls, lastInstances, gcDelta);
                return gcDelta == 0 ? 0 : 3;
            }
        }

        if (capturing) {
            uint w, h;
            auto px = app.readCapture(w, h);
            if (px.length == 0) { stderr.writeln("anim_viewer: capture failed"); return 2; }
            auto f = File(capturePath, "wb");
            f.writef("P6\n%d %d\n255\n", w, h);
            foreach (i; 0 .. w * h) f.rawWrite(px[i * 4 .. i * 4 + 3]);
            return 0;
        }
    }
    return 0;
}
