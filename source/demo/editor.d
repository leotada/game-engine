/// Editor / devtools demo — exercises Phase 12 (gizmos + debug overlay).
///
/// Controls:
///   WASD            — move the camera (horizontal)
///   Space / LCtrl   — move up / down
///   LShift          — sprint (x3 speed)
///   Mouse           — look around (cursor is captured)
///   G               — toggle gizmo visibility
///   F1              — toggle debug overlay
///   ESC             — quit (releases the cursor)
module demo.editor;

import std.math : sin, cos;

import engine.app;
import engine.core.log;
import engine.devtools.gizmos  : GizmoRenderer;
import engine.devtools.overlay : DebugOverlay;
import engine.gpu.text         : TextRenderer, FpsCounter;
import engine.graphics.material : Material;
import engine.graphics.texmesh  : TexMesh;
import engine.graphics.texture  : Texture, Sampler, TextureFilter, TextureWrap;
import engine.graphics.types    : Color4;
import engine.math.vec          : Vec3;
import engine.platform.input    : Key;
import engine.scene.camera      : Camera;
import engine.scene.controllers : FlyCamera;
import engine.scene.scene3d_textured : Scene3DTextured;

@safe:

private enum W = 1280;
private enum H = 720;

void main() {
    auto app = App.create("Engine Editor — Gizmos + Overlay", W, H);

    // Scene renderer for a few reference cubes.
    auto scene  = Scene3DTextured.create(app.gpu);
    scope(exit) scene.destroy();
    auto mesh   = TexMesh.cube(app.gpu);
    scope(exit) mesh.destroy();
    auto quad   = TexMesh.quad(app.gpu);
    scope(exit) quad.destroy();

    auto sampler = Sampler.create(app.gpu, TextureFilter.linear, TextureWrap.repeat);
    scope(exit) sampler.destroy();
    auto groundTex = Texture.checker(app.gpu, 128, [50,50,60,255], [30,30,40,255]);
    scope(exit) groundTex.destroy();
    auto cubeTex   = Texture.checker(app.gpu, 64,  [200,100,80,255], [150,60,40,255]);
    scope(exit) cubeTex.destroy();

    auto layout = scene.bindGroupLayout();
    auto uniBuf = scene.sharedUniformBuffer();
    auto groundMat = Material.create(app.gpu, layout, uniBuf, sampler, groundTex);
    scope(exit) groundMat.destroy();
    auto cubeMat   = Material.create(app.gpu, layout, uniBuf, sampler, cubeTex);
    scope(exit) cubeMat.destroy();

    // Devtools.
    auto gizmos  = GizmoRenderer.create(app.gpu);
    scope(exit) gizmos.destroy();
    auto text    = TextRenderer.create(app.gpu, W, H);
    scope(exit) text.destroy();
    auto overlay = DebugOverlay();
    bool gizmosVisible  = true;
    bool overlayVisible = true;

    // Camera + controller.
    auto camera = Camera.create(0.9f, W, H);
    camera.lookAt(Vec3(6, 5, 8), Vec3(0, 1, 0));
    auto fly = FlyCamera.create(Vec3(6, 5, 8));

    // Capture the mouse so FPS-style look works without the cursor leaving the window.
    app.window.setRelativeMouseMode(true);
    scope(exit) app.window.setRelativeMouseMode(false);

    info("Editor demo running — G toggles gizmos, F1 toggles overlay, ESC quits.");

    auto fps = FpsCounter.create();
    float time = 0;

    // A handful of demo cubes at known positions — targets for gizmo AABBs.
    struct Box { Vec3 pos; Vec3 size; Color4 tint; }
    Box[5] boxes = [
        Box(Vec3(-3, 1, 0),   Vec3(1, 2, 1), Color4(1.0f, 0.6f, 0.4f, 1)),
        Box(Vec3( 0, 1, 0),   Vec3(1, 2, 1), Color4(0.4f, 0.8f, 1.0f, 1)),
        Box(Vec3( 3, 1, 0),   Vec3(1, 2, 1), Color4(0.5f, 1.0f, 0.6f, 1)),
        Box(Vec3( 0, 1,-3),   Vec3(2, 1, 2), Color4(1.0f, 0.9f, 0.3f, 1)),
        Box(Vec3( 0, 1, 3),   Vec3(1, 3, 1), Color4(0.9f, 0.4f, 1.0f, 1)),
    ];

    while (app.running()) {
        app.pollEvents();
        immutable dt = fps.tick();
        time += dt;

        if (app.input.keyPressed(Key.escape)) break;
        if (app.input.keyPressed(Key.g))      gizmosVisible  = !gizmosVisible;
        if (app.input.keyPressed(Key.f1))     overlayVisible = !overlayVisible;

        fly.update(app.input, dt, camera);

        // ---- Render ---------------------------------------------------
        auto frame = app.beginFrame(Color4(0.03f, 0.03f, 0.05f, 1));
        if (!frame.valid) continue;

        // Scene (ground + animated cubes)
        scene.begin(camera);
        scene.draw(quad, groundMat,
                   Vec3(0, 0, 0), Vec3(40, 1, 40), Color4(0.8f, 0.8f, 0.9f, 1));
        foreach (i, ref b; boxes) {
            immutable float phase = time + cast(float) i * 0.7f;
            scene.draw(mesh, cubeMat,
                       b.pos + Vec3(0, sin(phase) * 0.25f, 0), b.size, b.tint, phase * 0.3f);
        }
        scene.end(frame);

        // Gizmos overlay
        if (gizmosVisible) {
            gizmos.begin(camera.viewProjection());
            gizmos.grid(20.0f, 20, Color4(0.25f, 0.25f, 0.30f, 1), 0.001f);
            gizmos.axes(Vec3(0, 0.01f, 0), 2.0f);
            foreach (ref b; boxes) {
                gizmos.box(b.pos, b.size, Color4(0.2f, 1.0f, 0.6f, 1));
            }
            // A rotating ray from the origin showing current time vector.
            immutable rx = cast(float) cos(time);
            immutable rz = cast(float) sin(time);
            gizmos.ray(Vec3(0, 2, 0), Vec3(rx, 0, rz), 3.0f, Color4(1, 0.4f, 0.2f, 1));
            gizmos.render(frame);
        }

        // Debug overlay (text)
        if (overlayVisible) {
            overlay.beginFrame(dt);
            overlay.label("cam",    "pos=(", fly.position.x, ", ", fly.position.y, ", ", fly.position.z, ")");
            overlay.label("yaw",    fly.yaw);
            overlay.label("pitch",  fly.pitch);
            overlay.label("boxes",  boxes.length);
            overlay.label("gizmos", gizmosVisible ? "ON" : "OFF");
            overlay.label("keys",   "WASD move, Space/Ctrl up/down, Shift sprint, G gizmos, F1 overlay, ESC quit");
            text.beginFrame();
            overlay.render(text, frame, 16, 16, 2, 22);
        }

        app.endFrame(frame);
    }

    app.destroy();
}
