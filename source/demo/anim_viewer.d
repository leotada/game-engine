/// Windowed animation viewer: a `pab` character blending walk/jog, drawn as skeleton gizmos.
///
///   Left/Right: blend weight (walk <-> jog)   Up/Down: playback speed
///   G: toggle head look-at (target orbits)    Esc: quit
module demo.anim_viewer;

import std.math : cos, sin;

import bindings.wgpu : WGPUPresentMode;
import engine.animation;
import engine.animation.ecs;
import engine.app : App;
import engine.devtools.anim_overlay : animationOverlay;
import engine.devtools.gizmos : GizmoRenderer;
import engine.devtools.overlay : DebugOverlay;
import engine.ecs.world : World;
import engine.gpu.text : FpsCounter, TextRenderer;
import engine.graphics.types : Color4;
import engine.math.vec : Vec3;
import engine.platform.input : Key;
import engine.scene.camera : Camera;

alias AnimWorld = World!(AnimSkeleton, AnimPlayback, AnimBlend2, AnimAdditive, AnimLookAt, AnimTwoBoneIK);

private enum SCREEN_W = 1280;
private enum SCREEN_H = 720;
private enum string fixtures = "assets/animation/test/";

int main() {
    AnimAssets assets;
    PosePool pool;
    AnimWorld world;
    string err;
    auto sk = loadSkeletonFile(assets.skeletons, fixtures ~ "pab/skeleton.ozz", err);
    auto walk = loadAnimationFile(assets.animations, fixtures ~ "pab/walk.ozz", err);
    auto jog = loadAnimationFile(assets.animations, fixtures ~ "pab/jog.ozz", err);
    if (sk.isNull || walk.isNull || jog.isNull) {
        import std.stdio : stderr;
        stderr.writeln("anim_viewer: ", err);
        return 1;
    }
    immutable joints = assets.skeletons.get(sk).numJoints;
    immutable e = world.spawn();
    immutable slot = pool.acquire(joints);
    world.set(e, AnimSkeleton(sk, slot));
    world.set(e, AnimBlend2(walk, jog, 0.0f));
    world.set(e, AnimLookAt(joints / 2, Vec3(0, 1, 2), 0.0f, Vec3(0, 0, 1), Vec3(0, 1, 0)));

    auto app = App.create("Animation viewer", SCREEN_W, SCREEN_H, WGPUPresentMode.fifo);
    auto text = TextRenderer.create(app.gpu, SCREEN_W, SCREEN_H);
    scope(exit) text.destroy();
    auto gizmos = GizmoRenderer.create(app.gpu);
    scope(exit) gizmos.destroy();
    auto fps = FpsCounter.create();
    DebugOverlay overlay;
    auto camera = Camera.create(0.85f, SCREEN_W, SCREEN_H, 0.1f, 100.0f);
    camera.lookAt(Vec3(0, 1.0f, 3.5f), Vec3(0, 0.9f, 0));

    float t = 0;
    while (app.running()) {
        app.pollEvents();
        immutable rawDt = fps.tick();
        immutable float dt = rawDt > 0.1f ? 0.1f : rawDt;
        t += dt;
        if (app.input.keyPressed(Key.escape)) break;

        auto blend = world.getPtr!AnimBlend2(e);
        auto look = world.getPtr!AnimLookAt(e);
        if (app.input.keyDown(Key.left)) blend.weight = blend.weight > 0 ? blend.weight - dt : 0;
        if (app.input.keyDown(Key.right)) blend.weight = blend.weight < 1 ? blend.weight + dt : 1;
        if (app.input.keyDown(Key.up)) blend.speed += dt;
        if (app.input.keyDown(Key.down)) blend.speed = blend.speed > 0.1f ? blend.speed - dt : 0.1f;
        if (app.input.keyPressed(Key.g)) look.weight = look.weight > 0 ? 0 : 1;
        look.target = Vec3(1.5f * cos(t), 1.4f, 1.5f * sin(t) + 0.5f);

        // Time of the animation systems only, for the overlay line.
        import std.datetime.stopwatch : StopWatch, AutoStart;
        auto sw = StopWatch(AutoStart.yes);
        advancePlaybackSystem(world, assets, dt);
        sampleSystem(world, assets, pool);
        blendSystem(world, assets, pool);
        localToModelSystem(world, assets, pool);
        lookAtSystem(world, assets, pool);
        skinPaletteSystem(world, assets, pool);
        immutable ms = sw.peek.total!"usecs" / 1000.0;

        auto frame = app.beginFrame(Color4(0.05f, 0.06f, 0.09f, 1.0f));
        if (!frame.valid) continue;
        gizmos.begin(camera.viewProjection());
        gizmos.grid(6, 12, Color4(0.25f, 0.28f, 0.35f, 1));
        drawSkeleton(gizmos, *assets.skeletons.get(sk), pool.get(slot).model);
        if (look.weight > 0) gizmos.axes(look.target, 0.15f);
        gizmos.render(frame);
        app.resolvePost(frame);

        overlay.beginFrame(dt);
        animationOverlay(overlay, 1, ms);
        text.beginFrame();
        text.drawText(frame, fps.text(), 10, 10, 2);
        text.drawText(frame, "Left/Right: walk<->jog   Up/Down: speed   G: look-at   Esc: quit",
                      10, SCREEN_H - 28, 2);
        overlay.render(text, frame);
        app.endFrame(frame);
    }
    return 0;
}
