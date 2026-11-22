/// GPU regression check: a surface shader with `displace` / `displaceEx` must
/// animate the cast shadow too, and `displaceEx` must tell instances apart.
///
///   dub run --config=surface-shadow-check
///
/// A top-down camera looks at a ground plane lit by a 45 degree sun. Floating
/// quads bend along X with `sin(frame.time * 2 + phase) * amp`. The program
/// renders two frames (t0 and t1), measures where each quad's shadow lands on
/// the ground and asserts it moved by the analytic amount. Exit code 0 = pass.
module demo.surface_shadow_check;

import core.stdc.stdlib : exit;
import std.math : abs, sin, tan, PI;
import std.stdio : writefln, writeln;

import engine.app;
import engine.gpu.pipeline : BlendMode, RenderState;
import engine.graphics.material : Material, MaterialParams;
import engine.graphics.texmesh : TexMesh;
import engine.graphics.texture : Sampler, Texture, TextureFilter, TextureWrap;
import engine.graphics.types : Color4;
import engine.math.mat : Mat4;
import engine.math.vec : Vec3;
import engine.scene.camera : Camera;
import engine.scene.light : LightList;
import engine.scene.scene3d_textured : Scene3DTextured;
import engine.scene.static_instances : StaticInstanceBuffer, StaticInstanceDesc;

@safe:

private enum uint WIN_W = 960;
private enum uint WIN_H = 720;
private enum float CAM_H = 40.0f;
private enum float FOV = 0.95f;
private enum float CASTER_Y = 6.0f;
private enum float AMP = 1.0f;
private enum float OMEGA = 2.0f;
/// Sun from +X at 45 degrees: a caster at height 6 throws its shadow 6 units toward -X.
private enum float SHADOW_SHIFT = -6.0f;

/// Extended hook: phase from the per-instance `custom.x`.
private enum string kExtendedWgsl = q{
fn surface(in: SurfaceIn, base: SurfaceOut) -> SurfaceOut { return base; }
fn displaceEx(d: DisplaceIn) -> vec3<f32> {
    // Touch every field so the whole DisplaceIn contract is compiled.
    let w = 1.0 + 0.0 * (d.uv.x + d.instancePos.y + d.objectScale.x + d.localNormal.y);
    let dx = sin(frame.time * 2.0 + d.custom.x) * surfaceParams.p0.x * w;
    return d.localPos + vec3<f32>(dx / d.objectScale.x, 0.0, 0.0);
}
};

/// Legacy hook, original signature (no instance data).
private enum string kLegacyWgsl = q{
fn surface(in: SurfaceIn, base: SurfaceOut) -> SurfaceOut { return base; }
fn displace(localPos: vec3<f32>, localNormal: vec3<f32>) -> vec3<f32> {
    return localPos + vec3<f32>(sin(frame.time * 2.0) * surfaceParams.p0.x / 2.0, 0.0, 0.0);
}
};

private struct Probe {
    string name;
    float x0, z0;
    /// Expected shadow X offset from the pivot at t0 and t1 (world units).
    float expect0, expect1;
}

private float lum(const(ubyte)[] px, uint w, uint x, uint y) pure nothrow @nogc {
    immutable i = (y * w + x) * 4;
    return 0.299f * px[i] + 0.587f * px[i + 1] + 0.114f * px[i + 2];
}

/// X centroid (world units) of shadowed pixels in a window around the probe.
/// Returns NaN when fewer than 40 dark pixels are found.
private float shadowCentroid(const(ubyte)[] px, uint w, uint h, float lit, ref const Probe p) {
    immutable s = (h * 0.5f) / (tan(FOV * 0.5f) * CAM_H);
    immutable cx = p.x0 + SHADOW_SHIFT;
    double sum = 0;
    uint n = 0;
    foreach (y; 0 .. h) {
        immutable wz = (cast(float) y - h * 0.5f) / s;
        if (abs(wz - p.z0) > 3.0f) continue;
        foreach (x; 0 .. w) {
            immutable wx = (cast(float) x - w * 0.5f) / s;
            if (abs(wx - cx) > 4.0f) continue;
            if (lum(px, w, x, y) < lit * 0.75f) { sum += wx; n++; }
        }
    }
    if (n < 40) return float.nan;
    return cast(float)(sum / n);
}

int main() {
    auto app = App.create("Surface shadow check", WIN_W, WIN_H);
    app.setVsync(false);
    auto scene = Scene3DTextured.create(app.gpu);
    scope(exit) scene.destroy();
    scene.setIblIntensity(0.15f);

    auto quad = TexMesh.quad(app.gpu);
    scope(exit) quad.destroy();
    auto sampler = Sampler.create(app.gpu, TextureFilter.linear, TextureWrap.repeat);
    scope(exit) sampler.destroy();
    auto white = Texture.solid(app.gpu, 255, 255, 255, 255);
    scope(exit) white.destroy();

    auto layout = scene.materialLayout();
    MaterialParams gp;
    gp.baseColor = [0.8f, 0.8f, 0.8f];
    gp.specularRoughness = 0.9f;
    auto groundMat = Material.create(app.gpu, layout, sampler, white, gp, null, null, null, null);
    scope(exit) groundMat.destroy();

    MaterialParams cp;
    cp.baseColor = [1.0f, 1.0f, 1.0f];
    cp.specularRoughness = 0.9f;
    void setupCaster(ref Material m, uint shader) {
        m.surfaceShader = shader;
        m.renderState = RenderState(BlendMode.opaque, true, true);
        float[16] sp = 0;
        sp[0] = AMP;
        m.updateSurfaceParams(app.gpu, sp);
    }
    immutable extId = scene.createSurfaceShader(kExtendedWgsl);
    immutable legId = scene.createSurfaceShader(kLegacyWgsl);
    if (extId == 0 || legId == 0) { writeln("FAIL: surface shader did not compile"); return 1; }
    auto stockMat = Material.create(app.gpu, layout, sampler, white, cp, null, null, null, null);
    scope(exit) stockMat.destroy();
    auto extMat = Material.create(app.gpu, layout, sampler, white, cp, null, null, null, null);
    scope(exit) extMat.destroy();
    auto legMat = Material.create(app.gpu, layout, sampler, white, cp, null, null, null, null);
    scope(exit) legMat.destroy();
    setupCaster(stockMat, 0);
    setupCaster(extMat, extId);
    setupCaster(legMat, legId);

    // Static path: one displaced instance with phase 0.
    auto meshes = new TexMesh*[1];
    auto mats = new Material*[1];
    () @trusted { meshes[0] = &quad; mats[0] = &extMat; }();
    auto descs = new StaticInstanceDesc[1];
    descs[0].mesh = 0;
    descs[0].material = 0;
    descs[0].model = Mat4.translation(12, CASTER_Y, -6) * Mat4.scaling(2, 1, 2);
    descs[0].custom = [0.0f, 0, 0, 0];
    auto sib = StaticInstanceBuffer.build(app.gpu, meshes, mats, descs);

    // t0 = 0, t1 = pi/4 (2 * t1 = pi/2).
    immutable float[2] times = [0.0f, cast(float)(PI / 4)];
    immutable Probe[] probes = [
        Probe("dynamic displaceEx phase 0   ", -12, -6, 0, AMP),
        Probe("dynamic displaceEx phase pi/2",   0, -6, AMP, 0),
        Probe("static  displaceEx phase 0   ",  12, -6, 0, AMP),
        Probe("stock material (control)     ", -12,  8, 0, 0),
        Probe("legacy displace()            ",  12,  8, 0, AMP),
    ];

    Camera camera = Camera.create(FOV, WIN_W, WIN_H, 0.5f, 200.0f);
    camera.lookAt(Vec3(0, CAM_H, 0), Vec3(0, 0, 0));
    camera.up = Vec3(0, 0, -1);

    LightList lights;
    scope(exit) lights.release();

    float[probes.length][2] centroid;
    foreach (pass; 0 .. 2) {
        // Warm-up frames let the lazily built pipelines settle.
        foreach (rep; 0 .. 3) {
            app.pollEvents();
            lights.clear();
            lights.dirEnabled = true;
            lights.dir.direction = Vec3(1, 1, 0).normalized();
            lights.dir.intensity = 3.5f;
            lights.dir.castShadows = true;
            lights.dir.cascades.maxDistance = 120;
            auto frame = app.beginFrame(Color4(0.02f, 0.02f, 0.03f, 1.0f));
            if (!frame.valid) { writeln("FAIL: no frame"); return 1; }
            scene.begin(camera);
            scene.setTime(times[pass]);
            scene.draw(quad, groundMat, Vec3(0, 0, 0), Vec3(100, 1, 100), Color4.white);
            immutable sc = Mat4.scaling(2, 1, 2);
            scene.drawMatrix(quad, extMat, Mat4.translation(-12, CASTER_Y, -6) * sc, Color4.white, [0.0f, 0, 0, 0]);
            scene.drawMatrix(quad, extMat, Mat4.translation(0, CASTER_Y, -6) * sc, Color4.white,
                             [cast(float)(PI / 2), 0, 0, 0]);
            scene.drawMatrix(quad, stockMat, Mat4.translation(-12, CASTER_Y, 8) * sc, Color4.white);
            scene.drawMatrix(quad, legMat, Mat4.translation(12, CASTER_Y, 8) * sc, Color4.white);
            scene.submitStatic(sib);
            scene.renderShadows(frame, lights);
            scene.end(frame);
            app.resolvePost(frame);
            if (rep == 2) app.requestCapture();
            app.endFrame(frame);
        }
        uint w, h;
        auto px = app.readCapture(w, h);
        if (px.length == 0) { writeln("FAIL: frame capture unavailable"); return 1; }
        // Lit ground reference: far corner of the visible plane, away from every shadow.
        immutable s = (h * 0.5f) / (tan(FOV * 0.5f) * CAM_H);
        immutable lit = lum(px, w, cast(uint)(w * 0.5f + 0 * s), cast(uint)(h * 0.5f + 16.0f * s));
        foreach (i, ref p; probes) centroid[pass][i] = shadowCentroid(px, w, h, lit, p) - p.x0;
    }

    bool ok = true;
    writeln("shadow X offset from pivot (world units): measured vs expected, t0 -> t1");
    foreach (i, ref p; probes) {
        immutable e0 = SHADOW_SHIFT + p.expect0;
        immutable e1 = SHADOW_SHIFT + p.expect1;
        immutable m0 = centroid[0][i], m1 = centroid[1][i];
        immutable pass_ = abs(m0 - e0) < 0.45f && abs(m1 - e1) < 0.45f; // NaN fails
        writefln("  %s  t0 %6.2f (%5.1f)   t1 %6.2f (%5.1f)  %s",
                 p.name, m0, e0, m1, e1, pass_ ? "ok" : "FAIL");
        ok = ok && pass_;
    }
    // displaceEx must separate instances: first two probes move in opposite directions.
    immutable d0 = centroid[1][0] - centroid[0][0];
    immutable d1 = centroid[1][1] - centroid[0][1];
    immutable distinct = d0 - d1 > 1.0f;
    writefln("  instance separation (delta A - delta B) = %.2f  %s", d0 - d1, distinct ? "ok" : "FAIL");
    ok = ok && distinct;

    sib.destroy();
    app.destroy();
    writeln(ok ? "SURFACE_SHADOW_CHECK PASS" : "SURFACE_SHADOW_CHECK FAIL");
    return ok ? 0 : 1;
}
