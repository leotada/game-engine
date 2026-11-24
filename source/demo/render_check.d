/// GPU regression checks for the renderer. Each check draws a small scene,
/// reads the presented frame back and asserts on the pixels.
///
///   dub run --config=render-check                  # every check
///   dub run --config=render-check -- --check=unlit # one check
///   dub run --config=render-check -- --dump=DIR    # also write the frames as PNG
///   dub run --config=render-check -- --bench --size=1920x1080  # profiler zones of each feature
///
/// Exit code 0 = every selected check passed.
module demo.render_check;

import std.math : abs;
import std.stdio : writefln, writeln;

import engine.app;
import engine.graphics.material : Material, MaterialFlags, MaterialParams;
import engine.gpu.skinned : SkinnedMesh;
import engine.graphics.texmesh : TexMesh;
import engine.graphics.texture : alphaCoverageOf, Sampler, Texture, TextureDesc, TextureFilter, TextureWrap;
import engine.graphics.types : Color4, SkinnedVertex;
import engine.gpu.pipeline : BlendMode, RenderState;
import engine.gpu.post : AaMode, OutputTransfer, PostSettings;
import engine.gpu.renderer : FrameContext;
import engine.math.mat : Mat4;
import engine.math.vec : Vec3;
import engine.scene.camera : Camera;
import engine.scene.light : GpuPointLight, GpuSpotLight, LightList;
import engine.scene.scene3d_textured : Scene3DTextured;
import engine.scene.static_instances : StaticInstanceBuffer, StaticInstanceDesc;

@safe:

private uint WIN_W = 640;
private uint WIN_H = 480;
private bool bench;

/// One captured frame (tightly packed RGBA8).
private struct Shot {
    const(ubyte)[] px;
    uint w, h;

    bool valid() const { return px.length == cast(size_t) w * h * 4 && px.length > 0; }
    ubyte at(uint x, uint y, uint ch) const { return px[(cast(size_t) y * w + x) * 4 + ch]; }
    float luma(uint x, uint y) const {
        return 0.299f * at(x, y, 0) + 0.587f * at(x, y, 1) + 0.114f * at(x, y, 2);
    }
}

private string dumpDir;

/// Render `warmup + 1` frames with `draw` and capture the last one.
private Shot capture(ref App app, string name, scope void delegate(ref FrameContext) @safe draw,
                     uint warmup = 2, Color4 clear = Color4(0, 0, 0, 1)) {
    foreach (rep; 0 .. warmup + 1) {
        app.pollEvents();
        auto frame = app.beginFrame(clear);
        if (!frame.valid) return Shot.init;
        draw(frame);
        app.resolvePost(frame);
        if (rep == warmup) app.requestCapture();
        app.endFrame(frame);
    }
    Shot s;
    s.px = app.readCapture(s.w, s.h);
    if (dumpDir.length && s.valid) {
        import engine.assets.png : saveRgbaPng;
        saveRgbaPng(dumpDir ~ "/" ~ name ~ ".png", s.px, s.w, s.h);
    }
    return s;
}

/// Print the profiler zones whose name starts with one of `prefixes`, averaged
/// over 240 frames. Only with `--bench`.
private void timeZones(ref App app, string label, scope const(string)[] prefixes,
                       scope void delegate(ref FrameContext) @safe draw) {
    import engine.devtools.profiler : enableProfiler, profilerReport, resetProfilerStats;
    import std.algorithm.searching : startsWith;
    if (!bench) return;
    void frames(uint n) {
        foreach (_; 0 .. n) {
            app.pollEvents();
            auto frame = app.beginFrame(Color4(0, 0, 0, 1));
            if (!frame.valid) return;
            draw(frame);
            app.resolvePost(frame);
            app.endFrame(frame);
        }
    }
    enableProfiler(true);
    frames(30);
    resetProfilerStats();
    frames(240);
    writefln("  bench %s (%sx%s)", label, app.window.width(), app.window.height());
    foreach (ref r; profilerReport()) {
        if (r.meanMs <= 0) continue;
        foreach (p; prefixes)
            if (r.name.startsWith(p)) { writefln("    %-36s mean %.3f ms  p95 %.3f", r.name, r.meanMs, r.p95); break; }
    }
    enableProfiler(false);
}

private bool expect(bool ok, string what) {
    if (bench) return true; // pixel checks assume the default window size
    writeln("  ", ok ? "ok   " : "FAIL ", what);
    return ok;
}

/// Full-screen unlit quad facing the camera.
private struct QuadRig {
    Scene3DTextured scene;
    TexMesh quad;
    Sampler sampler;
    Camera camera;

    @disable this(this);

    static QuadRig create(ref App app) {
        QuadRig r;
        r.scene = Scene3DTextured.create(app.gpu, 16, false);
        r.quad = TexMesh.quad(app.gpu);
        r.sampler = Sampler.create(app.gpu, TextureFilter.nearest, TextureWrap.clamp);
        r.camera = Camera.create(0.9f, WIN_W, WIN_H, 0.1f, 100.0f);
        r.camera.lookAt(Vec3(0, 10, 0), Vec3(0, 0, 0));
        r.camera.up = Vec3(0, 0, -1);
        return r;
    }

    void destroy() {
        scene.destroy();
        quad.destroy();
        sampler.destroy();
    }
}

private PostSettings neutralPost() {
    PostSettings p;
    p.bloom = false;
    p.fxaa = false;
    p.tonemapMode = 2;
    return p;
}

/// Unlit linear 0.5 through the linear tone mapper is `255 * 0.5^(1/2.2)`.
private bool checkUnlit(ref App app) {
    auto rig = QuadRig.create(app);
    scope(exit) rig.destroy();
    app.renderer.postSettings() = neutralPost();
    auto tex = Texture.solid(app.gpu, 255, 255, 255);
    scope(exit) tex.destroy();
    MaterialParams mp;
    mp.baseColor = [0.5f, 0.5f, 0.5f];
    mp.flags = MaterialFlags.unlit;
    auto mat = Material.create(app.gpu, rig.scene.materialLayout(), rig.sampler, tex, mp, null, null, null, null);
    scope(exit) mat.destroy();
    auto s = capture(app, "unlit", (ref FrameContext f) {
        rig.scene.begin(rig.camera);
        rig.scene.draw(rig.quad, mat, Vec3(0, 0, 0), Vec3(40, 1, 40));
        rig.scene.end(f);
    });
    if (!s.valid) return expect(false, "frame captured");
    immutable v = s.at(s.w / 2, s.h / 2, 0);
    writefln("  center = %s (expected 186)", v);
    return expect(abs(v - 186) <= 1, "unlit 0.5 is gamma encoded on output");
}

/// An unlit sRGB texture through the linear tone mapper returns its own codes,
/// for `Texture` and for minified mips (averaged in linear light).
private bool checkSrgb(ref App app) {
    auto rig = QuadRig.create(app);
    scope(exit) rig.destroy();
    bool ok = true;

    ubyte render(string name, ref Texture tex, OutputTransfer transfer, float size) {
        auto post = neutralPost();
        post.outputTransfer = transfer;
        app.renderer.postSettings() = post;
        MaterialParams mp;
        mp.flags = MaterialFlags.unlit;
        auto smp = Sampler.create(app.gpu, TextureFilter.linear, TextureWrap.repeat);
        scope(exit) smp.destroy();
        auto mat = Material.create(app.gpu, rig.scene.materialLayout(), smp, tex, mp, null, null, null, null);
        scope(exit) mat.destroy();
        auto s = capture(app, name, (ref FrameContext f) {
            rig.scene.begin(rig.camera);
            rig.scene.draw(rig.quad, mat, Vec3(0, 0, 0), Vec3(size, 1, size));
            rig.scene.end(f);
        });
        return s.valid ? s.at(s.w / 2, s.h / 2, 0) : 0;
    }

    foreach (code; [cast(ubyte) 10, cast(ubyte) 64, cast(ubyte) 128, cast(ubyte) 200, cast(ubyte) 250]) {
        auto px = new ubyte[4];
        px[] = code;
        px[3] = 255;
        TextureDesc d;
        d.srgb = true;
        auto tex = Texture.fromPixels(app.gpu, px, 1, 1, d);
        scope(exit) tex.destroy();
        immutable exact = render("srgb_exact", tex, OutputTransfer.srgb, 40);
        immutable gamma = render("srgb_gamma", tex, OutputTransfer.gamma22, 40);
        writefln("  code %s: srgb transfer %s, gamma22 %s", code, exact, gamma);
        ok &= expect(abs(exact - code) <= 1, "sRGB transfer returns the texture code");
        if (code == 128) ok &= expect(abs(gamma - code) <= 1, "gamma22 returns grey 128");
    }

    // Black/white checker seen through the last mips: half the light = code 188.
    auto checker = new ubyte[64 * 64 * 4];
    foreach (y; 0 .. 64) foreach (x; 0 .. 64) {
        immutable v = cast(ubyte)(((x ^ y) & 1) ? 255 : 0);
        checker[(y * 64 + x) * 4 .. (y * 64 + x) * 4 + 4] = [v, v, v, 255];
    }
    auto mipped = Texture.fromPixels(app.gpu, checker, 64, 64, TextureDesc.mippedSrgb());
    scope(exit) mipped.destroy();
    immutable m = render("srgb_mips", mipped, OutputTransfer.srgb, 0.3f);
    writefln("  minified checker %s (expected 188)", m);
    ok &= expect(abs(m - 188) <= 2, "mips are averaged in linear light");
    return ok;
}

/// Scene for the AA check: a near-horizontal edge on the left and a
/// high-contrast detail texture on the right.
private struct AaScores {
    float stairs;  // RMS deviation (px) of the edge from a straight line
    float detail;  // mean neighbor contrast of the texture
}

private bool checkAa(ref App app) {
    import std.math : PI, sqrt;
    auto rig = QuadRig.create(app);
    scope(exit) rig.destroy();
    MaterialParams mp;
    mp.flags = MaterialFlags.unlit;
    auto white = Texture.solid(app.gpu, 220, 220, 220);
    scope(exit) white.destroy();
    auto px = new ubyte[64 * 64 * 4];
    uint rng = 0x9E3779B9;
    foreach (i; 0 .. 64 * 64) {
        rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5;
        px[i * 4 .. i * 4 + 4] = (rng & 0x100) ? 190 : 40;
        px[i * 4 + 3] = 255;
    }
    auto noise = Texture.fromPixels(app.gpu, px, 64, 64);
    scope(exit) noise.destroy();
    auto linear = Sampler.create(app.gpu, TextureFilter.linear, TextureWrap.clamp);
    scope(exit) linear.destroy();
    auto edgeMat = Material.create(app.gpu, rig.scene.materialLayout(), rig.sampler, white, mp, null, null, null, null);
    scope(exit) edgeMat.destroy();
    auto texMat = Material.create(app.gpu, rig.scene.materialLayout(), linear, noise, mp, null, null, null, null);
    scope(exit) texMat.destroy();

    AaScores run(string name, AaMode mode, float sharpness) {
        auto post = neutralPost();
        post.aaMode = mode;
        post.sharpness = sharpness;
        app.renderer.postSettings() = post;
        auto s = capture(app, name, (ref FrameContext f) {
            rig.scene.begin(rig.camera);
            rig.scene.drawMatrix(rig.quad, edgeMat, Mat4.translation(-3.5f, 0, 5) * Mat4.rotationY(0.07f)
                                 * Mat4.scaling(5.0f, 1, 10), Color4.white);
            rig.scene.draw(rig.quad, texMat, Vec3(3.4f, 0, 0), Vec3(4.0f, 1, 4.0f));
            rig.scene.end(f);
        });
        AaScores r = AaScores(1e9f, 0);
        if (!s.valid) return r;
        // Edge position per column from coverage, then a least-squares line.
        double sx = 0, sy = 0, sxx = 0, sxy = 0;
        uint n;
        float[] pos;
        foreach (x; 60 .. 220) {
            float cov = 0;
            foreach (y; s.h / 2 - 60 .. s.h / 2 + 60) cov += s.luma(x, y) / 220.0f;
            pos ~= cov;
            sx += x; sy += cov; sxx += cast(double) x * x; sxy += x * cov;
            n++;
        }
        immutable slope = (n * sxy - sx * sy) / (n * sxx - sx * sx);
        immutable icept = (sy - slope * sx) / n;
        double acc = 0;
        foreach (i, c; pos) { immutable d = c - (icept + slope * (60 + i)); acc += d * d; }
        r.stairs = cast(float) sqrt(acc / n);
        double det = 0;
        uint dn;
        foreach (y; s.h / 2 - 60 .. s.h / 2 + 60) foreach (x; s.w / 2 + 100 .. s.w / 2 + 220) {
            det += abs(s.luma(x, y) - s.luma(x + 1, y)) + abs(s.luma(x, y) - s.luma(x, y + 1));
            dn += 2;
        }
        r.detail = cast(float)(det / dn);
        writefln("  %-14s stairs %.3f px, texture contrast %.2f", name, r.stairs, r.detail);
        return r;
    }

    immutable off = run("aa_off", AaMode.off, 0);
    immutable old = run("aa_fxaa", AaMode.fxaa, 0);
    immutable hq = run("aa_fxaaQuality", AaMode.fxaaQuality, 0);
    immutable sharp = run("aa_fxaaQ_cas", AaMode.fxaaQuality, 0.6f);
    immutable offSharp = run("aa_off_cas", AaMode.off, 0.6f);
    immutable oldSharp = run("aa_fxaa_cas", AaMode.fxaa, 0.6f);
    foreach (i, mode; [AaMode.off, AaMode.fxaa, AaMode.fxaaQuality]) {
        foreach (sh; [0.0f, 0.6f]) {
            auto post = neutralPost();
            post.aaMode = mode;
            post.sharpness = sh;
            app.renderer.postSettings() = post;
            string[3] names = ["off", "fxaa", "fxaaQuality"];
            timeZones(app, names[i] ~ (sh > 0 ? " + sharpening" : ""), ["gpu.post.", "post."], (ref FrameContext f) {
                rig.scene.begin(rig.camera);
                rig.scene.draw(rig.quad, texMat, Vec3(0, 0, 0), Vec3(20, 1, 12));
                rig.scene.end(f);
            });
        }
    }

    bool ok = expect(hq.stairs < old.stairs && hq.stairs < off.stairs * 0.6f, "fewer stair steps than FXAA");
    ok &= expect(hq.detail > old.detail, "textures are sharper than FXAA");
    ok &= expect(sharp.detail > hq.detail * 1.05f && sharp.stairs < old.stairs, "sharpening after quality FXAA");
    ok &= expect(offSharp.detail > off.detail && oldSharp.detail > old.detail, "sharpening after any AA mode");
    return ok;
}

/// Alpha mask: a striped quad floats over a lit ground. Stripes must be cut in
/// the color image and in the cast shadow, on the dynamic, static and
/// `displaceEx` paths, and the opaque control must cast a full shadow.
private bool checkMask(ref App app) {
    auto scene = Scene3DTextured.create(app.gpu, 32, false);
    scope(exit) scene.destroy();
    auto quad = TexMesh.quad(app.gpu);
    scope(exit) quad.destroy();
    auto sampler = Sampler.create(app.gpu, TextureFilter.linear, TextureWrap.repeat);
    scope(exit) sampler.destroy();
    app.renderer.postSettings() = neutralPost();

    // Left half of every tile is transparent.
    auto px = new ubyte[64 * 64 * 4];
    foreach (y; 0 .. 64) foreach (x; 0 .. 64) {
        px[(y * 64 + x) * 4 .. (y * 64 + x) * 4 + 4] = 255;
        if (x < 32) px[(y * 64 + x) * 4 + 3] = 40;
    }
    auto stripes = Texture.fromPixels(app.gpu, px, 64, 64);
    scope(exit) stripes.destroy();
    auto white = Texture.solid(app.gpu, 255, 255, 255);
    scope(exit) white.destroy();
    MaterialParams gp;
    gp.baseColor = [0.6f, 0.6f, 0.6f];
    auto layout = scene.materialLayout();
    auto ground = Material.create(app.gpu, layout, sampler, white, gp, null, null, null, null);
    scope(exit) ground.destroy();
    enum kDisplaceEx = `
fn surface(in: SurfaceIn, base: SurfaceOut) -> SurfaceOut { return base; }
fn displaceEx(d: DisplaceIn) -> vec3<f32> { return d.localPos + vec3<f32>(0.0, 0.001, 0.0); }
`;
    immutable shader = scene.createSurfaceShader(kDisplaceEx);
    if (shader == 0) return expect(false, "surface shader compiles");
    Material make(uint sh, bool mask) {
        MaterialParams mp;
        mp.baseColor = [0.0f, 0.5f, 0.0f];
        mp.emissionLuminance = 0;
        auto m = Material.create(app.gpu, layout, sampler, stripes, mp, null, null, null, null);
        m.surfaceShader = sh;
        m.renderState = RenderState(BlendMode.opaque, true, true, mask);
        return m;
    }
    auto maskMat = make(0, true);
    scope(exit) maskMat.destroy();
    auto exMat = make(shader, true);
    scope(exit) exMat.destroy();
    auto solidMat = make(0, false);
    scope(exit) solidMat.destroy();

    // Same quad, bound to one joint.
    auto sv = new SkinnedVertex[4];
    foreach (i, ref v; sv) {
        immutable float u = (i == 1 || i == 2) ? 1 : 0, w = i >= 2 ? 1 : 0;
        v.position = [u - 0.5f, 0, w - 0.5f];
        v.normal = [0, 1, 0];
        v.uv = [u, w];
        v.tangent = [1, 0, 0, 1];
        v.joints = [0, 0, 0, 0];
        v.weights = [1, 0, 0, 0];
    }
    auto si = [0u, 2, 1, 0, 3, 2];
    auto skinned = SkinnedMesh.fromData(app.gpu, sv, si);
    scope(exit) skinned.destroy();
    immutable Mat4[1] palette = [Mat4.identity()];

    auto meshes = new TexMesh*[1];
    auto mats = new Material*[1];
    () @trusted { meshes[0] = &quad; mats[0] = &maskMat; }();
    auto descs = new StaticInstanceDesc[1];
    enum float H = 3;
    descs[0].model = Mat4.translation(4, H, -4) * Mat4.scaling(4, 1, 4);
    auto sib = StaticInstanceBuffer.build(app.gpu, meshes, mats, descs);
    scope(exit) sib.destroy();

    Camera cam = Camera.create(0.9f, WIN_W, WIN_H, 0.5f, 100.0f);
    cam.lookAt(Vec3(0, 30, 0), Vec3(0, 0, 0));
    cam.up = Vec3(0, 0, -1);
    LightList lights;
    scope(exit) lights.release();

    Vec3 localAt;
    bool localPoint;
    Shot shoot(string name, bool local, bool sun) {
        return capture(app, name, (ref FrameContext f) {
            lights.clear();
            lights.dirEnabled = sun;
            lights.dir.direction = Vec3(1, 1, 0).normalized();
            lights.dir.intensity = 3.0f;
            lights.dir.castShadows = true;
            lights.dir.cascades.maxDistance = 80;
            if (local && localPoint) {
                GpuPointLight p;
                p.position = localAt;
                p.range = 20;
                p.intensity = 200;
                p.castShadows = true;
                lights.addPoint(p);
            } else if (local) {
                GpuSpotLight sl;
                sl.position = localAt;
                sl.range = 20;
                sl.intensity = 200;
                sl.castShadows = true;
                sl.innerConeDeg = 45;
                sl.outerConeDeg = 50;
                lights.addSpot(sl);
            }
            scene.begin(cam);
            scene.draw(quad, ground, Vec3(0, 0, 0), Vec3(60, 1, 60));
            scene.drawMatrix(quad, maskMat, Mat4.translation(-4, H, -4) * Mat4.scaling(4, 1, 4), Color4.white);
            scene.drawMatrix(quad, exMat, Mat4.translation(-4, H, 4) * Mat4.scaling(4, 1, 4), Color4.white);
            scene.drawMatrix(quad, solidMat, Mat4.translation(4, H, 4) * Mat4.scaling(4, 1, 4), Color4.white);
            scene.drawSkinned(skinned, maskMat, Mat4.translation(-4, H, 10) * Mat4.scaling(4, 1, 4), Color4.white, palette[]);
            scene.submitStatic(sib);
            scene.renderShadows(f, lights);
            scene.end(f);
        });
    }
    auto s = shoot("mask", false, true);
    if (!s.valid) return expect(false, "frame captured");
    import std.math : tan;
    float lumaAt(ref Shot sh, float wx, float wy, float wz) {
        immutable k = (sh.h * 0.5f) / (tan(0.45f) * (30 - wy));
        return sh.luma(cast(uint)(sh.w * 0.5f + wx * k), cast(uint)(sh.h * 0.5f + wz * k));
    }
    float greenAt(ref Shot sh, float wx, float wy, float wz) {
        immutable k = (sh.h * 0.5f) / (tan(0.45f) * (30 - wy));
        immutable x = cast(uint)(sh.w * 0.5f + wx * k), y = cast(uint)(sh.h * 0.5f + wz * k);
        return sh.at(x, y, 1) - sh.at(x, y, 0);
    }
    immutable lit = lumaAt(s, 0, 0, 0);
    bool ok = expect(lit > 60, "ground is lit");
    void probe(string name, float cx, float cz, bool masked) {
        // Color: left half shows the ground (grey), right half the green quad.
        immutable left = greenAt(s, cx - 1, H, cz), right = greenAt(s, cx + 1, H, cz);
        ok &= expect(right > 20, name ~ ": kept half is drawn");
        ok &= expect(masked ? left < 8 : left > 20, name ~ (masked ? ": masked half is cut" : ": control is not cut"));
        // Shadow lands H units toward -X; the quad's right half covers x in (0, 2).
        immutable shadowKept = lumaAt(s, cx + 1 - H, 0, cz + 1.0f);
        immutable shadowCut = lumaAt(s, cx - 1 - H, 0, cz + 1.0f);
        writefln("  %s: shadow kept %.0f cut %.0f lit %.0f", name, shadowKept, shadowCut, lit);
        ok &= expect(masked ? shadowCut > lit * 0.9f : shadowCut < lit * 0.75f,
                     name ~ (masked ? ": light passes the hole" : ": control casts a full shadow"));
    }
    probe("dynamic", -4, -4, true);
    probe("displaceEx", -4, 4, true);
    probe("skinned", -4, 10, true);
    probe("static", 4, -4, true);
    probe("control", 4, 4, false);

    // Local lights one at a time, 8 units up over each quad: a shadow edge is
    // 1.6x the quad. With no other light, the shadowed ground must match the
    // unlit frame (ambient only) and the ground behind the hole must be lit.
    auto ambient = shoot("mask_ambient", false, false);
    if (!ambient.valid) return expect(false, "frame captured");
    struct Caster { string name; float x, z; bool masked; }
    static immutable Caster[5] casters = [
        Caster("dynamic", -4, -4, true), Caster("displaceEx", -4, 4, true), Caster("skinned", -4, 10, true),
        Caster("static", 4, -4, true), Caster("control", 4, 4, false)];
    foreach (point; [false, true]) foreach (ref c; casters) {
        immutable label = (point ? "point " : "spot ") ~ c.name;
        localAt = Vec3(c.x, 8, c.z);
        localPoint = point;
        auto sh = shoot("mask_local", true, false);
        if (!sh.valid) return expect(false, "frame captured");
        immutable kept = lumaAt(sh, c.x + 2.9f, 0, c.z), keptDark = lumaAt(ambient, c.x + 2.9f, 0, c.z);
        immutable cut = lumaAt(sh, c.x - 2.9f, 0, c.z), cutDark = lumaAt(ambient, c.x - 2.9f, 0, c.z);
        writefln("  %s: kept %.0f (unlit %.0f) cut %.0f (unlit %.0f)", label, kept, keptDark, cut, cutDark);
        ok &= expect(kept - keptDark < 8, label ~ ": kept half casts a full shadow");
        ok &= expect(c.masked ? cut - cutDark > 60 : cut - cutDark < 8,
                     label ~ (c.masked ? ": light passes the hole" : ": control casts a full shadow"));
    }
    immutable coverageOk = checkMaskCoverage(app);
    return ok && coverageOk;
}

/// Distant masked noise: `alphaCoverage` mips keep the fraction of drawn pixels
/// of level 0, plain box mips lose it.
private bool checkMaskCoverage(ref App app) {
    import std.random : Random, uniform;
    auto scene = Scene3DTextured.create(app.gpu, 32, false);
    scope(exit) scene.destroy();
    auto quad = TexMesh.quad(app.gpu);
    scope(exit) quad.destroy();
    auto sampler = Sampler.create(app.gpu, TextureFilter.linear, TextureWrap.repeat);
    scope(exit) sampler.destroy();
    app.renderer.postSettings() = neutralPost();
    enum N = 512, SIZE = 12.0f;
    auto px = new ubyte[N * N * 4];
    Camera cam = Camera.create(0.9f, WIN_W, WIN_H, 0.5f, 400.0f);
    cam.lookAt(Vec3(0, 60, 0), Vec3(0, 0, 0));
    cam.up = Vec3(0, 0, -1);
    float drawn(string name, float coverage) @safe {
        auto d = TextureDesc.mipped();
        d.alphaCoverage = coverage;
        auto tex = Texture.fromPixels(app.gpu, px, N, N, d);
        scope(exit) tex.destroy();
        MaterialParams mp;
        mp.baseColor = [0, 0, 0];
        mp.emissionColor = [1, 1, 1];
        mp.emissionLuminance = 1;
        auto mat = Material.create(app.gpu, scene.materialLayout(), sampler, tex, mp, null, null, null, null);
        scope(exit) mat.destroy();
        mat.renderState = RenderState(BlendMode.opaque, true, true, true);
        auto sh = capture(app, name, (ref FrameContext f) {
            scene.begin(cam);
            scene.drawMatrix(quad, mat, Mat4.scaling(SIZE, 1, SIZE), Color4.white);
            scene.end(f);
        });
        if (!sh.valid) return -1;
        import std.math : tan;
        immutable k = (sh.h * 0.5f) / (tan(0.45f) * 60);
        immutable r = cast(int)(SIZE * 0.5f * k) - 2;
        uint hit = 0, total = 0;
        foreach (y; -r .. r) foreach (x; -r .. r) {
            total++;
            if (sh.luma(cast(uint)(cast(int) sh.w / 2 + x), cast(uint)(cast(int) sh.h / 2 + y)) > 128) hit++;
        }
        return cast(float) hit / total;
    }
    bool ok = true;
    void check(string name) {
        immutable want = alphaCoverageOf(px, N, N, 0.5f);
        immutable plain = drawn("mask_" ~ name ~ "_plain", 0), kept = drawn("mask_" ~ name ~ "_coverage", 0.5f);
        writefln("  %s coverage: near %.3f, far plain %.3f, far preserved %.3f", name, want, plain, kept);
        ok &= expect(plain < want * 0.8f, name ~ ": plain mips miss the same 20% band (control)");
        ok &= expect(kept > want * 0.8f && kept < want * 1.2f, name ~ ": coverage mips keep it within 20%");
    }
    auto rng = Random(11);
    foreach (i; 0 .. N * N) {
        px[i * 4 .. i * 4 + 4] = 255;
        px[i * 4 + 3] = uniform(0, 100, rng) < 30 ? 255 : 0;
    }
    check("noise");
    // Wire grid, 3 texels every 32: a chain-link fence seen from afar.
    foreach (y; 0 .. N) foreach (x; 0 .. N)
        px[(y * N + x) * 4 + 3] = (x % 32 < 3 || y % 32 < 3) ? 255 : 0;
    check("grid");
    return ok;
}

/// Stars are round: every isolated bright blob must be compact (no voxel
/// slivers or X shapes) and peak at its center.
private bool checkStars(ref App app) {
    import std.math : sqrt;
    auto rig = QuadRig.create(app);
    scope(exit) rig.destroy();
    app.renderer.postSettings() = neutralPost();
    auto cam = Camera.create(0.45f, WIN_W, WIN_H, 0.1f, 1000.0f);
    cam.lookAt(Vec3(0, 0, 0), Vec3(1, 1.2f, 0.4f));
    rig.scene.setSkyEnabled(true);
    rig.scene.setSkyState(Vec3(0, -1, 0), 0, 1.0f);
    rig.scene.setSkySun(Vec3(0, -1, 0), Vec3(0, 0, 0));
    auto s = capture(app, "stars", (ref FrameContext f) {
        rig.scene.begin(cam);
        rig.scene.end(f);
    });
    if (!s.valid) return expect(false, "frame captured");

    enum R = 5;
    uint stars, round, centered;
    foreach (y; R + 1 .. s.h - R - 1) foreach (x; R + 1 .. s.w - R - 1) {
        immutable c = s.luma(x, y);
        if (c < 110) continue;
        bool peak = true;
        foreach (dy; -1 .. 2) foreach (dx; -1 .. 2)
            if ((dx || dy) && s.luma(x + dx, y + dy) > c) peak = false;
        if (!peak) continue;
        // Second moments of the light above the local background.
        float bg = 255;
        foreach (dy; -R .. R + 1) foreach (dx; -R .. R + 1) {
            immutable l = s.luma(x + dx, y + dy);
            if (l < bg) bg = l;
        }
        float sum = 0, mx = 0, my = 0, xx = 0, yy = 0, xy = 0, edge = 0;
        foreach (dy; -R .. R + 1) foreach (dx; -R .. R + 1) {
            immutable l = s.luma(x + dx, y + dy) - bg - 6;
            if (l <= 0) continue;
            if (abs(dx) == R || abs(dy) == R) edge += l;
            sum += l; mx += l * dx; my += l * dy;
            xx += l * dx * dx; yy += l * dy * dy; xy += l * dx * dy;
        }
        if (edge > 30 || sum <= 0) continue; // touches a neighbor
        mx /= sum; my /= sum;
        xx = xx / sum - mx * mx; yy = yy / sum - my * my; xy = xy / sum - mx * my;
        immutable disc = sqrt((xx - yy) * (xx - yy) + 4 * xy * xy);
        immutable hi = sqrt((xx + yy + disc) * 0.5f), lo2 = (xx + yy - disc) * 0.5f;
        immutable lo = lo2 > 0.01f ? sqrt(lo2) : 0.1f;
        stars++;
        if (hi / lo < 1.6f) round++;
        if (abs(mx) < 0.8f && abs(my) < 0.8f) centered++;
    }
    writefln("  stars %s, round %s, centered %s", stars, round, centered);
    bool ok = expect(stars >= 15, "the night sky has stars");
    ok &= expect(round * 100 >= stars * 90, "stars are round");
    ok &= expect(centered * 100 >= stars * 90, "stars peak at their center");
    return ok;
}

private struct Check {
    string name;
    bool function(ref App) @safe run;
}

private immutable Check[] checks = [
    Check("unlit", &checkUnlit),
    Check("srgb", &checkSrgb),
    Check("aa", &checkAa),
    Check("mask", &checkMask),
    Check("stars", &checkStars),
];

int main(string[] args) {
    import std.algorithm.searching : startsWith;
    string only;
    foreach (a; args[1 .. $]) {
        if (a.startsWith("--check=")) only = a["--check=".length .. $];
        else if (a == "--bench") bench = true;
        else if (a.startsWith("--size=")) {
            import std.conv : to;
            import std.string : split;
            auto wh = a["--size=".length .. $].split("x");
            if (wh.length == 2) { WIN_W = wh[0].to!uint; WIN_H = wh[1].to!uint; }
        }
        else if (a.startsWith("--dump=")) dumpDir = a["--dump=".length .. $];
    }
    auto app = App.create("Render check", WIN_W, WIN_H);
    app.setVsync(false);
    uint failed = 0, ran = 0;
    foreach (ref c; checks) {
        if (only.length && c.name != only) continue;
        writeln("[", c.name, "]");
        ran++;
        if (!c.run(app)) failed++;
    }
    app.destroy();
    writefln("RENDER_CHECK %s (%s run, %s failed)", ran > 0 && failed == 0 ? "PASS" : "FAIL", ran, failed);
    return ran > 0 && failed == 0 ? 0 : 1;
}
