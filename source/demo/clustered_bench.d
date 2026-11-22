/// Clustered Forward stress benchmark & visual showcase: renders an OpenPBR sphere +
/// ground grid illuminated by up to 1,024 dynamic orbiting point lights and 256 spotlights.
/// Supports A/B toggling Clustered vs Brute-force culling via `[C]` or `--unclustered`.
module demo.clustered_bench;

import core.memory : GC;
import core.time : MonoTime;
import std.algorithm.sorting : sort;
import std.conv : to;
import std.math : cos, sin, PI;
import std.stdio : writefln;
import std.string : startsWith;

import bindings.wgpu : wgpuDevicePoll, WGPU_TRUE;
import engine.app;
import engine.core.log;
import engine.gpu.text : FpsCounter, TextRenderer;
import engine.graphics.material : Material, MaterialParams;
import engine.graphics.texmesh : TexMesh;
import engine.graphics.texture : Sampler, Texture, TextureFilter, TextureWrap;
import engine.graphics.types : Color4;
import engine.math.vec : Vec3;
import engine.platform.input : Key;
import engine.scene.camera : Camera;
import engine.scene.light :
    GpuPointLight, GpuSpotLight, LightList, MAX_POINT_LIGHTS, MAX_SPOT_LIGHTS;
import engine.scene.scene3d_textured : Scene3DTextured;

@safe:

private enum uint WIN_W = 1280;
private enum uint WIN_H = 720;

private struct Options {
    uint pointLights = 512;
    uint spotLights = 64;
    uint headlessFrames = 0;
    bool unclustered = false;
    bool benchSync = false;
    bool assertNoGc = false;
    string screenshot;
}

private Options parseArgs(string[] args) {
    Options o;
    foreach (a; args[1 .. $]) {
        if (a.startsWith("--lights=")) {
            o.pointLights = to!uint(a["--lights=".length .. $]);
        } else if (a.startsWith("--spots=")) {
            o.spotLights = to!uint(a["--spots=".length .. $]);
        } else if (a.startsWith("--headless-frames=")) {
            o.headlessFrames = to!uint(a["--headless-frames=".length .. $]);
        } else if (a == "--unclustered") {
            o.unclustered = true;
        } else if (a == "--bench-sync") {
            o.benchSync = true;
        } else if (a == "--assert-no-gc") {
            o.assertNoGc = true;
        } else if (a.startsWith("--screenshot=")) {
            o.screenshot = a["--screenshot=".length .. $];
        }
    }
    if (o.pointLights > MAX_POINT_LIGHTS) o.pointLights = MAX_POINT_LIGHTS;
    if (o.spotLights > MAX_SPOT_LIGHTS) o.spotLights = MAX_SPOT_LIGHTS;
    return o;
}

private Vec3 hueRgb(float t) pure nothrow @nogc {
    immutable float r = 0.5f + 0.5f * cos(6.28318f * (t + 0.0f));
    immutable float g = 0.5f + 0.5f * cos(6.28318f * (t + 0.333f));
    immutable float b = 0.5f + 0.5f * cos(6.28318f * (t + 0.667f));
    return Vec3(r, g, b);
}

void main(string[] args) {
    immutable opts = parseArgs(args);

    auto app = App.create("Clustered Forward Benchmark", WIN_W, WIN_H);
    app.setVsync(false);
    app.post.exposure = 1.05f;
    app.post.bloom = true;

    auto scene = Scene3DTextured.create(app.gpu);
    scope(exit) scene.destroy();
    scene.setIblIntensity(0.22f);
    scene.setClusteredCulling(!opts.unclustered);

    auto sphere = TexMesh.sphere(app.gpu, 32, 16);
    scope(exit) sphere.destroy();
    auto quad = TexMesh.quad(app.gpu);
    scope(exit) quad.destroy();

    auto sampler = Sampler.create(app.gpu, TextureFilter.linear, TextureWrap.repeat);
    scope(exit) sampler.destroy();
    auto whiteTex = Texture.solid(app.gpu, 255, 255, 255, 255);
    scope(exit) whiteTex.destroy();
    auto groundTex = Texture.checker(app.gpu, 128, [45, 48, 56, 255], [30, 32, 38, 255]);
    scope(exit) groundTex.destroy();

    auto layout = scene.materialLayout();
    MaterialParams gp;
    gp.baseColor = [0.75f, 0.78f, 0.85f];
    gp.specularRoughness = 0.35f;
    gp.baseMetalness = 0.1f;
    auto groundMat = Material.create(app.gpu, layout, sampler, groundTex, gp, null, null, null, null);
    scope(exit) groundMat.destroy();

    Material[4] sphereMats;
    foreach (m; 0 .. 4) {
        MaterialParams p;
        p.baseColor = [0.85f, 0.85f, 0.90f];
        p.baseMetalness = (m % 2 == 0) ? 0.15f : 0.88f;
        p.specularRoughness = 0.18f + 0.22f * cast(float)(m / 2);
        sphereMats[m] = Material.create(app.gpu, layout, sampler, whiteTex, p, null, null, null, null);
    }
    scope(exit) foreach (ref sm; sphereMats) sm.destroy();

    auto text = TextRenderer.create(app.gpu, WIN_W, WIN_H);
    scope(exit) text.destroy();

    Camera camera = Camera.create(0.95f, WIN_W, WIN_H, 0.2f, 250.0f);
    camera.lookAt(Vec3(0.0f, 18.0f, 44.0f), Vec3(0.0f, 1.0f, 0.0f));

    LightList lights;
    scope(exit) lights.release();

    immutable uint WARMUP = opts.headlessFrames > 0 ? 5 : 0;
    immutable uint totalFrames = opts.headlessFrames > 0 ? opts.headlessFrames + WARMUP : uint.max;
    double[] samples;
    if (opts.headlessFrames > 0) samples = new double[opts.headlessFrames];

    FpsCounter fps;
    float time = 0.0f;
    size_t gcBefore = 0;

    enum int GRID_COLS = 14;
    enum int GRID_ROWS = 14;
    enum float SPACING = 3.8f;

    for (uint frameNo = 0; frameNo < totalFrames && app.running(); frameNo++) {
        if (opts.headlessFrames > 0 && frameNo == WARMUP) {
            if (opts.assertNoGc) {
                GC.collect();
                gcBefore = GC.stats().allocatedInCurrentThread;
            }
        }
        immutable frameStart = MonoTime.currTime;

        app.pollEvents();
        immutable dt = opts.headlessFrames > 0 ? (1.0f / 60.0f) : fps.tick();
        time += dt;
        if (app.input.keyPressed(Key.escape)) break;
        if (app.input.keyPressed(Key.c)) {
            scene.setClusteredCulling(!scene.clusteredCullingEnabled());
        }

        immutable camAngle = time * 0.12f;
        camera.lookAt(Vec3(sin(camAngle) * 42.0f, 18.0f, cos(camAngle) * 42.0f), Vec3(0.0f, 0.8f, 0.0f));

        // Pack dynamic point & spot lights via zero-GC LightList.
        lights.clear();
        lights.dirEnabled = true;
        lights.dir.direction = Vec3(0.3f, 0.9f, 0.4f).normalized();
        lights.dir.color = Vec3(0.7f, 0.78f, 0.95f);
        lights.dir.intensity = 0.22f;
        lights.dir.castShadows = false;

        foreach (i; 0 .. opts.pointLights) {
            immutable float u = cast(float) i / cast(float) (opts.pointLights > 1 ? opts.pointLights : 1);
            immutable float angle = u * 62.8318f + time * (0.35f + (i % 7) * 0.08f);
            immutable float rad = 3.0f + u * 27.0f;
            GpuPointLight pl;
            pl.position = Vec3(cos(angle) * rad, 1.3f + 0.8f * sin(time * 2.1f + i * 0.7f), sin(angle) * rad);
            pl.color = hueRgb(u * 4.0f);
            pl.intensity = 10.0f;
            pl.range = 6.5f;
            pl.castShadows = false;
            lights.addPoint(pl);
        }

        foreach (i; 0 .. opts.spotLights) {
            immutable float u = cast(float) i / cast(float) (opts.spotLights > 1 ? opts.spotLights : 1);
            immutable float angle = u * 25.1327f - time * 0.45f;
            immutable float rad = 6.0f + u * 22.0f;
            GpuSpotLight sl;
            sl.position = Vec3(cos(angle) * rad, 6.2f, sin(angle) * rad);
            sl.direction = Vec3(sin(angle + time) * 0.25f, -1.0f, -cos(angle + time) * 0.25f).normalized();
            sl.color = hueRgb(u * 2.5f + 0.5f);
            sl.intensity = 18.0f;
            sl.range = 14.0f;
            sl.innerConeDeg = 18.0f;
            sl.outerConeDeg = 32.0f;
            sl.castShadows = false;
            lights.addSpot(sl);
        }

        auto frame = app.beginFrame(Color4(0.015f, 0.018f, 0.025f, 1.0f));
        if (!frame.valid) continue;

        scene.begin(camera);
        scene.draw(quad, groundMat, Vec3(0.0f, 0.0f, 0.0f), Vec3(68.0f, 1.0f, 68.0f), Color4.white);
        foreach (rz; 0 .. GRID_ROWS) {
            foreach (cx; 0 .. GRID_COLS) {
                immutable float px = (cast(float) cx - (GRID_COLS - 1) * 0.5f) * SPACING;
                immutable float pz = (cast(float) rz - (GRID_ROWS - 1) * 0.5f) * SPACING;
                scene.draw(sphere, sphereMats[(cx + rz) % 4], Vec3(px, 0.9f, pz), Vec3(0.9f, 0.9f, 0.9f));
            }
        }
        scene.renderShadows(frame, lights);
        scene.end(frame);

        app.resolvePost(frame);
        text.beginFrame();
        text.drawText(frame, app.arena.fmt("Clustered Forward [%s]  Points=%u  Spots=%u  FPS=%.0f  [C] Toggle",
            scene.clusteredCullingEnabled() ? "ON" : "OFF (linear)",
            opts.pointLights, opts.spotLights, fps.fps), 16, 16, 2);

        if (opts.screenshot.length > 0 && frameNo + 1 == totalFrames) {
            app.saveScreenshot(opts.screenshot);
        }
        app.endFrame(frame);

        if (opts.benchSync) {
            () @trusted {
                wgpuDevicePoll(app.gpu.getDevice(), WGPU_TRUE, null);
            }();
        }
        if (opts.headlessFrames > 0 && frameNo >= WARMUP) {
            immutable ms = (MonoTime.currTime - frameStart).total!"hnsecs" / 10_000.0;
            samples[frameNo - WARMUP] = ms;
        }
    }

    if (opts.headlessFrames > 0 && samples.length > 0) {
        immutable size_t gcDelta = opts.assertNoGc
            ? (GC.stats().allocatedInCurrentThread - gcBefore) : 0;
        sort(samples);
        double sum = 0.0;
        foreach (s; samples) sum += s;
        immutable avgMs = sum / cast(double) samples.length;
        immutable p50Ms = samples[(samples.length * 50) / 100];
        immutable p95Ms = samples[(samples.length * 95) / 100];
        immutable p99Ms = samples[(samples.length * 99) / 100];
        immutable fpsMean = avgMs > 0.0 ? (1000.0 / avgMs) : 0.0;
        writefln("CLUSTERED_BENCH mode=%s points=%u spots=%u avg_ms=%.3f p50_ms=%.3f p95_ms=%.3f p99_ms=%.3f fps=%.1f gc_delta_bytes=%u",
            scene.clusteredCullingEnabled() ? "clustered" : "unclustered",
            opts.pointLights, opts.spotLights, avgMs, p50Ms, p95Ms, p99Ms, fpsMean, gcDelta);
        if (opts.assertNoGc) {
            assert(gcDelta == 0, "GC allocations detected in clustered_bench frame loop!");
        }
    }

    app.destroy();
}
