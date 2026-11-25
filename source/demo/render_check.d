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
import engine.graphics.types : Color4, SkinnedVertex, TexTanVert, TexVert;
import engine.gpu.pipeline : BlendMode, RenderState;
import engine.gpu.gtao : AoQuality, AoSettings;
import engine.gpu.post : AaMode, OutputTransfer, PostPassDesc, PostSettings, PostStage;
import bindings.wgpu : WGPUTextureFormat;
import engine.gpu.renderer : FrameContext;
import engine.math.mat : Mat4;
import engine.math.vec : Vec3;
import engine.scene.camera : Camera;
import engine.scene.light : GpuPointLight, GpuSpotLight, LightList;
import engine.scene.scene3d_textured : Scene3DTextured;
import engine.scene.static_instances : StaticBuildOptions, StaticInstanceBuffer, StaticInstanceDesc;

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
    immutable smaa = run("aa_smaa", AaMode.smaa, 0);
    immutable cmaa2 = run("aa_cmaa2", AaMode.cmaa2, 0);
    immutable smaaSharp = run("aa_smaa_cas", AaMode.smaa, 0.6f);
    immutable cmaa2Sharp = run("aa_cmaa2_cas", AaMode.cmaa2, 0.6f);

    // Coverage of straight edges at several angles against the exact value.
    float coverageError(AaMode mode) {
        import std.math : cos, sin, tan;
        auto post = neutralPost();
        post.aaMode = mode;
        app.renderer.postSettings() = post;
        double err = 0;
        uint n;
        foreach (a; [0.03f, 0.11f, 0.24f, 0.4f, 0.6f, 0.785f, 1.0f, 1.35f, 1.53f]) {
            auto s = capture(app, "aa_angle", (ref FrameContext f) {
                rig.scene.begin(rig.camera);
                rig.scene.drawMatrix(rig.quad, edgeMat, Mat4.rotationY(a) * Mat4.translation(0, 0, 10)
                                     * Mat4.scaling(40.0f, 1, 20), Color4.white);
                rig.scene.end(f);
            });
            if (!s.valid) return 1e9f;
            // Edge through the center; signed distance grows to the lit side.
            immutable nx = sin(a), ny = cos(a);
            foreach (y; s.h / 2 - 100 .. s.h / 2 + 100) foreach (x; s.w / 2 - 100 .. s.w / 2 + 100) {
                float cov = 0;
                foreach (sy; 0 .. 8) foreach (sx; 0 .. 8) {
                    immutable px = x + (sx + 0.5f) / 8 - s.w * 0.5f, py = y + (sy + 0.5f) / 8 - s.h * 0.5f;
                    if (px * nx + py * ny > 0) cov += 1.0f / 64;
                }
                immutable near = cov > 0 && cov < 1;
                if (!near && s.luma(x, y) != 0 && s.luma(x, y) < 219) { /* blur outside the edge counts */ }
                else if (!near) continue;
                import std.math : pow;
                immutable got = pow(s.luma(x, y) / 220.0f, 2.2f);
                err += (got - cov) * (got - cov);
                n++;
            }
        }
        immutable r = cast(float) sqrt(err / n);
        writefln("  %-14s coverage error %.3f", mode, r);
        return r;
    }
    immutable covOff = coverageError(AaMode.off), covFxaa = coverageError(AaMode.fxaa),
        covHq = coverageError(AaMode.fxaaQuality), covSmaa = coverageError(AaMode.smaa),
        covCmaa2 = coverageError(AaMode.cmaa2);
    foreach (i, mode; [AaMode.off, AaMode.fxaa, AaMode.fxaaQuality, AaMode.smaa, AaMode.cmaa2]) {
        foreach (sh; [0.0f, 0.6f]) {
            auto post = neutralPost();
            post.aaMode = mode;
            post.sharpness = sh;
            app.renderer.postSettings() = post;
            string[5] names = ["off", "fxaa", "fxaaQuality", "smaa", "cmaa2"];
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
    ok &= expect(smaa.stairs < off.stairs * 0.5f && smaa.stairs < old.stairs, "SMAA removes stair steps");
    ok &= expect(cmaa2.stairs < off.stairs * 0.5f && cmaa2.stairs < old.stairs, "CMAA2 removes stair steps");
    ok &= expect(smaa.detail > old.detail && cmaa2.detail > old.detail, "SMAA and CMAA2 keep more texture than FXAA");
    ok &= expect(covSmaa < covOff * 0.6f && covSmaa < covFxaa, "SMAA coverage is closer to the exact value");
    ok &= expect(covCmaa2 < covOff * 0.6f && covCmaa2 < covFxaa, "CMAA2 coverage is closer to the exact value");
    ok &= expect(smaaSharp.detail > smaa.detail && cmaa2Sharp.detail > cmaa2.detail
                 && smaaSharp.stairs < off.stairs * 0.6f && cmaa2Sharp.stairs < off.stairs * 0.6f,
                 "sharpening after SMAA and CMAA2");
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

/// GPU culling of static instances against the CPU path: same frames for a
/// still, turning and jumping camera, over LODs, masks, `displaceEx`, both
/// vertex strides, both index formats and edited instances.
private bool checkGpuCull(ref App app) {
    if (bench) return gpuCullScene(app, 40_000, 900, 64, true);
    immutable small = gpuCullScene(app, 4000, 140, 4, true);
    // Many groups, like a city: no edits, just the image.
    immutable city = gpuCullScene(app, 40_000, 400, 64, false);
    return small && city;
}

private bool gpuCullScene(ref App app, uint total, float area, uint matCount, bool edits) {
    import std.math : cos, sin;
    import std.random : Random, uniform;
    auto scene = Scene3DTextured.create(app.gpu, 64, false);
    scope(exit) scene.destroy();
    auto sampler = Sampler.create(app.gpu, TextureFilter.linear, TextureWrap.repeat);
    scope(exit) sampler.destroy();
    app.renderer.postSettings() = neutralPost();
    auto white = Texture.solid(app.gpu, 255, 255, 255);
    scope(exit) white.destroy();
    auto px = new ubyte[16 * 16 * 4];
    foreach (i; 0 .. 256) {
        px[i * 4 .. i * 4 + 4] = 255;
        if ((i / 4 + i / 64) % 2) px[i * 4 + 3] = 0;
    }
    auto holes = Texture.fromPixels(app.gpu, px, 16, 16);
    scope(exit) holes.destroy();

    auto cube = TexMesh.cube(app.gpu);
    scope(exit) cube.destroy();
    auto quad = TexMesh.quad(app.gpu);
    scope(exit) quad.destroy();
    // 16-bit, stride 32, with a two-level chain inside one index buffer.
    auto ball = lodSphere(app, 24, 12);
    scope(exit) ball.destroy();
    // 32-bit indices (more than 65536 vertices) and stride 48.
    auto tan = TexMesh.sphere(app.gpu, 16, 8, true);
    scope(exit) tan.destroy();
    auto dense = TexMesh.sphere(app.gpu, 320, 210);
    scope(exit) dense.destroy();
    auto tri = oddTriangle(app);
    scope(exit) tri.destroy();

    auto layout = scene.materialLayout();
    immutable shader = scene.createSurfaceShader(`
fn surface(in: SurfaceIn, base: SurfaceOut) -> SurfaceOut { return base; }
fn displaceEx(d: DisplaceIn) -> vec3<f32> { return d.localPos + vec3<f32>(0.2 * d.localPos.y, 0.0, 0.0); }
`);
    if (shader == 0) return expect(false, "surface shader compiles");
    Material make(float r, float g, float b, bool mask, uint sh, bool ds) {
        MaterialParams mp;
        mp.baseColor = [r, g, b];
        auto m = Material.create(app.gpu, layout, sampler, mask ? holes : white, mp, null, null, null, null);
        m.surfaceShader = sh;
        m.renderState = RenderState(BlendMode.opaque, true, ds, mask);
        m.displacementBound = sh ? 0.5f : 0;
        return m;
    }
    auto red = make(0.7f, 0.2f, 0.2f, false, 0, false);
    scope(exit) red.destroy();
    auto green = make(0.2f, 0.7f, 0.2f, true, 0, true);
    scope(exit) green.destroy();
    auto blue = make(0.2f, 0.3f, 0.8f, false, shader, false);
    scope(exit) blue.destroy();
    auto grey = make(0.5f, 0.5f, 0.5f, false, 0, true);
    scope(exit) grey.destroy();

    enum M = 6;
    auto extra = new Material[matCount > 4 ? matCount - 4 : 0];
    foreach (i, ref e; extra) {
        auto m = make(0.2f + 0.01f * i, 0.5f, 0.3f, i % 4 == 1, i % 8 == 2 ? shader : 0, i % 3 == 0);
        import core.lifetime : move;
        move(m, e);
    }
    scope(exit) foreach (ref e; extra) e.destroy();
    auto meshes = new TexMesh*[M];
    auto mats = new Material*[matCount];
    () @trusted {
        meshes[0] = &cube; meshes[1] = &quad; meshes[2] = &ball; meshes[3] = &tan; meshes[4] = &dense; meshes[5] = &tri;
        mats[0] = &red; mats[1] = &green; mats[2] = &blue; mats[3] = &grey;
        foreach (i, ref e; extra) mats[4 + i] = &e;
    }();
    writefln("  scene: %s instances, %s materials", total, matCount);
    auto rng = Random(5);
    auto descs = new StaticInstanceDesc[total];
    foreach (i, ref d; descs) {
        d.mesh = total > 4000 ? [0u, 1, 2, 3, 5][uniform(0, 5, rng)] : (i % 400 == 0 ? 4 : [0u, 1, 2, 3, 5][uniform(0, 5, rng)]);
        d.material = uniform(0, matCount, rng);
        immutable sc = uniform(0.5f, 3.0f, rng);
        d.model = Mat4.translation(uniform(-area, area, rng), uniform(0.2f, 6.0f, rng), uniform(-area, area, rng))
            * Mat4.rotationY(uniform(0.0f, 6.28f, rng)) * Mat4.scaling(sc, sc, sc);
    }
    StaticInstanceBuffer build(bool gpu, bool parity) {
        StaticBuildOptions o;
        o.cellSize = total > 4000 ? 64 : 32;
        o.gpuCull = gpu;
        o.rangeLodParity = parity;
        return StaticInstanceBuffer.build(app.gpu, meshes, mats, descs, o);
    }
    auto cpu = build(false, false);
    scope(exit) cpu.destroy();
    auto gpu = build(true, false);
    scope(exit) gpu.destroy();
    auto parity = build(true, true);
    scope(exit) parity.destroy();
    if (!gpu.gpuCulled) {
        writeln("  GPU culling not supported by this adapter: skipped");
        return true;
    }
    LightList lights;
    scope(exit) lights.release();
    lights.dirEnabled = true;
    lights.dir.direction = Vec3(0.6f, 1, 0.3f).normalized();
    lights.dir.intensity = 3;
    lights.dir.castShadows = true;
    lights.dir.cascades.count = 3;
    lights.dir.cascades.maxDistance = 120;
    Vec3 eye, dirv;
    void frameOf(ref FrameContext f, ref StaticInstanceBuffer b) {
        Camera cam = Camera.create(0.9f, WIN_W, WIN_H, 0.3f, 400.0f);
        cam.lookAt(eye, eye + dirv);
        scene.begin(cam);
        scene.draw(quad, grey, Vec3(0, 0, 0), Vec3(area * 2, 1, area * 2));
        scene.submitStatic(b);
        scene.renderShadows(f, lights);
        scene.end(f);
    }
    if (bench) {
        eye = Vec3(0, 8, 0);
        dirv = Vec3(0.3f, -0.1f, 1).normalized();
        static immutable zones = ["scene.", "gpu.scene.opaque.static", "gpu.shadows", "gpu.staticCull", "renderer.", "frame"];
        timeZones(app, "static CPU 40k", zones, (ref FrameContext f) { frameOf(f, cpu); });
        writefln("    draws %s shadow draws %s", scene.stats.drawCalls, scene.stats.shadowDrawCalls);
        timeZones(app, "static GPU 40k", zones, (ref FrameContext f) { frameOf(f, gpu); });
        writefln("    draws %s shadow draws %s", scene.stats.drawCalls, scene.stats.shadowDrawCalls);
        return true;
    }
    uint[2] compare(string name, ref StaticInstanceBuffer a, ref StaticInstanceBuffer b, uint warmup) {
        auto sa = capture(app, name ~ "_a", (ref FrameContext f) { frameOf(f, a); }, warmup);
        auto sb = capture(app, name ~ "_b", (ref FrameContext f) { frameOf(f, b); }, warmup);
        if (!sa.valid || !sb.valid) return [uint.max, 0];
        uint diff = 0, worst = 0;
        foreach (i; 0 .. sa.px.length / 4) {
            uint d = 0;
            foreach (c; 0 .. 3) {
                immutable e = abs(cast(int) sa.px[i * 4 + c] - cast(int) sb.px[i * 4 + c]);
                if (e > d) d = e;
            }
            if (d > 0) diff++;
            if (d > worst) worst = d;
        }
        return [diff, worst];
    }
    bool ok = true;
    uint worstParity = 0, worstInst = 0, parityDiff = 0, instDiff = 0;
    void views(bool withLods) {
        foreach (k; 0 .. 8) {
            immutable float a = k * 0.8f;
            eye = k < 6 ? Vec3(0, 5, 0) : Vec3(k == 6 ? 90 : -110, 12, k == 6 ? -60 : 100);
            dirv = Vec3(sin(a), -0.15f, cos(a)).normalized();
            immutable p = compare("gpucull_parity", cpu, parity, 0);
            if (p[0] > parityDiff) parityDiff = p[0];
            if (p[1] > worstParity) worstParity = p[1];
            if (withLods) continue;
            immutable i = compare("gpucull", cpu, gpu, 0);
            if (i[0] > instDiff) instDiff = i[0];
            if (i[1] > worstInst) worstInst = i[1];
        }
    }
    views(true);
    writefln("  with LODs, range decisions: max %s px differ, max step %s", parityDiff, worstParity);
    ok &= expect(parityDiff == 0, "GPU path equals the CPU path with the same decisions");
    // Per-instance decisions: equal images need equal LODs, so drop the chain.
    scene.setLodBias(1e6f);
    views(false);
    writefln("  LOD 0, per instance: max %s px differ, max step %s", instDiff, worstInst);
    ok &= expect(instDiff == 0, "per-instance culling never drops a visible instance");
    // The GPU must keep at least what is needed and at most what the ranges keep.
    uint drawnInstances(ref StaticInstanceBuffer b) @trusted {
        uint n = 0;
        auto a = b.gpuData.readArgs(app.gpu, 0);
        foreach (i; 0 .. a.length / 5) n += a[i * 5 + 1];
        return n;
    }
    // The CPU path has no displacement slack: compare the counts without it.
    foreach (m; mats) m.displacementBound = 0;
    compare("gpucull_count", gpu, parity, 0);
    immutable nInst = drawnInstances(gpu), nRange = drawnInstances(parity);
    auto cpuFrame = capture(app, "gpucull_count_cpu", (ref FrameContext f) { frameOf(f, cpu); });
    immutable nCpu = scene.stats.staticInstancesVisible;
    writefln("  camera instances: per instance %s, range decisions %s, CPU path %s", nInst, nRange, nCpu);
    ok &= expect(nRange == nCpu, "range decisions draw exactly the CPU path's instances");
    ok &= expect(nInst > 0 && nInst <= nCpu, "per-instance culling only removes");
    foreach (m; mats) m.displacementBound = m.surfaceShader ? 0.5f : 0;
    compare("gpucull_count", gpu, parity, 0);
    immutable nSlack = drawnInstances(gpu);
    ok &= expect(nSlack > nInst, "displacementBound keeps more instances at the border");
    if (!edits) return ok;
    // Control: removing instances on one side must be seen.
    eye = Vec3(0, 5, 0);
    dirv = Vec3(0, -0.15f, 1).normalized();
    foreach (i; 0 .. 400) gpu.hideInstance(i);
    immutable hidden = compare("gpucull_control", cpu, gpu, 0);
    writefln("  control: 400 hidden instances change %s px", hidden[0]);
    ok &= expect(hidden[0] > 500, "the comparison sees missing instances (control)");
    foreach (i; 0 .. 400) cpu.hideInstance(i);
    ok &= expect(compare("gpucull_hidden", cpu, gpu, 0)[0] == 0, "hidden instances match");
    // A moved instance (inside its cell) takes its culling volume along.
    foreach (i; 400 .. 800) {
        auto m = Mat4.translation(0, 4, 0) * descs[i].model;
        cpu.updateInstance(i, m);
        gpu.updateInstance(i, m);
    }
    ok &= expect(compare("gpucull_moved", cpu, gpu, 0)[0] == 0, "moved instances match");
    // Culling changed after the build.
    scene.setLodBias(1);
    parity.setMeshCull(0, 40, 0);
    cpu.setMeshCull(0, 40, 0);
    parity.setMeshCull(1, 0, 12);
    cpu.setMeshCull(1, 0, 12);
    foreach (i; 0 .. 400) parity.hideInstance(i);
    foreach (i; 400 .. 800) parity.updateInstance(i, Mat4.translation(0, 4, 0) * descs[i].model);
    ok &= expect(compare("gpucull_ranges", cpu, parity, 0)[0] == 0, "distance and pixel culling match");
    return ok;
}

/// Sphere with a coarser second level in the same index buffer.
private TexMesh lodSphere(ref App app, uint segments, uint rings) {
    import engine.graphics.types : TexVert;
    import std.math : cos, PI, sin;
    TexVert[] verts;
    ushort[] idx;
    uint[2] first, count;
    foreach (l; 0 .. 2) {
        immutable seg = segments >> l, ring = rings >> l;
        immutable base = cast(uint) verts.length;
        first[l] = cast(uint) idx.length;
        foreach (y; 0 .. ring + 1) foreach (x; 0 .. seg + 1) {
            immutable float phi = cast(float) PI * y / ring, th = 2 * cast(float) PI * x / seg;
            immutable float nx = sin(phi) * cos(th), ny = cos(phi), nz = sin(phi) * sin(th);
            verts ~= TexVert([nx * 0.5f, ny * 0.5f, nz * 0.5f], [nx, ny, nz],
                             [cast(float) x / seg, cast(float) y / ring]);
        }
        foreach (y; 0 .. ring) foreach (x; 0 .. seg) {
            immutable a = cast(ushort)(base + y * (seg + 1) + x), b = cast(ushort)(a + seg + 1);
            idx ~= [a, cast(ushort)(a + 1), b, cast(ushort)(a + 1), cast(ushort)(b + 1), b];
        }
        count[l] = cast(uint) idx.length - first[l];
    }
    auto m = TexMesh.fromData(app.gpu, verts, idx);
    immutable float[2] errors = [0.0f, 0.02f];
    m.setLodChain(first[], count[], errors[], 1);
    return m;
}

/// One triangle: three 16-bit indices, not a multiple of 4 bytes.
private TexMesh oddTriangle(ref App app) {
    import engine.graphics.types : TexVert;
    auto verts = [TexVert([-0.5f, 0, 0], [0, 0, 1], [0, 1]), TexVert([0.5f, 0, 0], [0, 0, 1], [1, 1]),
                  TexVert([0, 1, 0], [0, 0, 1], [0.5f, 0])];
    ushort[] idx = [0, 1, 2];
    return TexMesh.fromData(app.gpu, verts, idx);
}

/// Scene inputs of post passes: depth, camera and normals against known
/// geometry, named targets at reduced resolution, every stage.
private bool checkPassInputs(ref App app) {
    auto scene = Scene3DTextured.create(app.gpu, 16, false);
    scope(exit) scene.destroy();
    auto quad = TexMesh.quad(app.gpu);
    scope(exit) quad.destroy();
    auto sampler = Sampler.create(app.gpu, TextureFilter.linear, TextureWrap.repeat);
    scope(exit) sampler.destroy();
    auto white = Texture.solid(app.gpu, 255, 255, 255);
    scope(exit) white.destroy();
    app.renderer.postSettings() = neutralPost();
    MaterialParams mp;
    auto mat = Material.create(app.gpu, scene.materialLayout(), sampler, white, mp, null, null, null, null);
    scope(exit) mat.destroy();
    mat.renderState = RenderState(BlendMode.opaque, true, true, false);
    // Camera 10 above a floor at y = 0, looking down; a slope on the right
    // rises 45 degrees along +X from x = 1.
    Camera cam = Camera.create(0.9f, WIN_W, WIN_H, 0.5f, 60.0f);
    cam.lookAt(Vec3(0, 10, 0), Vec3(0, 0, 0));
    cam.up = Vec3(0, 0, -1);
    immutable slope = Mat4.translation(2, 1, 0) * Mat4.rotationZ(0.78539816f) * Mat4.scaling(2.8284271f, 1, 4);
    void draw(ref FrameContext f) {
        scene.begin(cam);
        scene.setTime(0.5f);
        scene.draw(quad, mat, Vec3(0, 0, 0), Vec3(6, 1, 6));
        scene.drawMatrix(quad, mat, slope, Color4.white);
        scene.end(f);
    }
    import std.math : tan;
    // Pixel of a world point.
    uint[2] at(float x, float y, float z) {
        immutable k = (WIN_H * 0.5f) / (tan(0.45f) * (10 - y));
        return [cast(uint)(WIN_W * 0.5f + x * k), cast(uint)(WIN_H * 0.5f + z * k)];
    }
    bool near(ref Shot s, uint[2] p, int r, int g, int b, int tol) {
        immutable okay = abs(s.at(p[0], p[1], 0) - r) <= tol && abs(s.at(p[0], p[1], 1) - g) <= tol
            && abs(s.at(p[0], p[1], 2) - b) <= tol;
        if (!okay) writefln("    at %s: %s %s %s, expected %s %s %s", p, s.at(p[0], p[1], 0), s.at(p[0], p[1], 1),
                            s.at(p[0], p[1], 2), r, g, b);
        return okay;
    }
    bool ok = true;
    auto floor_ = at(-1.5f, 0, 1), onSlope = at(2, 1, -0.5f), sky = [WIN_W - 4, 4u];
    uint[2] skyP = [sky[0], sky[1]];

    // World position / 8 + 0.5, then world normal, then depth, camera and planes.
    static immutable string[3] shaders = [
        "@fragment fn fs_main(@location(0) uv: vec2<f32>) -> @location(0) vec4<f32> {
            let p = scenePixel(uv);
            if (sceneDepthAt(p) >= 1.0) { return vec4<f32>(0.0, 0.0, 0.0, 1.0); }
            return vec4<f32>(sceneWorldPosition(p) / 8.0 + 0.5, 1.0); }",
        "@fragment fn fs_main(@location(0) uv: vec2<f32>) -> @location(0) vec4<f32> {
            let p = scenePixel(uv);
            if (sceneDepthAt(p) >= 1.0) { return vec4<f32>(0.0, 0.0, 0.0, 1.0); }
            return vec4<f32>(sceneWorldNormal(p) * 0.5 + 0.5, 1.0); }",
        "@fragment fn fs_main(@location(0) uv: vec2<f32>) -> @location(0) vec4<f32> {
            return vec4<f32>(sceneLinearDepth(sceneDepth(uv)) / 60.0, sceneCamera.position.y / 20.0,
                             sceneCamera.position.w * sceneCamera.planes.z, 1.0); }"];
    foreach (stage; [PostStage.afterTonemap, PostStage.afterUi]) {
        immutable label = stage == PostStage.afterUi ? "afterUi " : "afterTonemap ";
        foreach (i, src; shaders) {
            PostPassDesc d;
            d.wgsl = src;
            d.stage = stage;
            d.sceneInputs = true;
            immutable id = app.renderer.addPostPass(d);
            ok &= expect(id != 0, label ~ "pass compiles");
            auto s = capture(app, "passinputs", &draw);
            app.renderer.removePostPass(id);
            if (!s.valid) return expect(false, "frame captured");
            if (i == 0) {
                ok &= expect(near(s, floor_, 80, 128, 159, 2), label ~ "world position of the floor");
                ok &= expect(near(s, onSlope, 191, 159, 112, 2), label ~ "world position of the slope");
                ok &= expect(near(s, skyP, 0, 0, 0, 0), label ~ "empty depth is 1");
            } else if (i == 1) {
                ok &= expect(near(s, floor_, 128, 255, 128, 2), label ~ "normal of the floor");
                ok &= expect(near(s, onSlope, 37, 218, 128, 3), label ~ "normal of the slope");
            } else {
                ok &= expect(near(s, floor_, 42, 128, 128, 1), label ~ "linear depth, camera position, time");
                ok &= expect(near(s, onSlope, 38, 128, 128, 1), label ~ "linear depth of the slope");
            }
        }
    }

    // Scene inside a panel (editor): same world positions at the panel's pixels.
    {
        PostPassDesc v;
        v.wgsl = shaders[0];
        v.sceneInputs = true;
        immutable vid = app.renderer.addPostPass(v);
        auto panel = capture(app, "passinputs_viewport", (ref FrameContext f) {
            f.setViewport(100, 60, 320, 240, WIN_W, WIN_H);
            draw(f);
        });
        app.renderer.removePostPass(vid);
        immutable uint[2] pf = [100 + floor_[0] / 2, 60 + floor_[1] / 2];
        ok &= expect(panel.valid && near(panel, pf, 80, 128, 159, 3), "world position inside a viewport panel");
    }

    // Named targets: half-resolution pass, quarter-resolution pass reading it, composite.
    PostPassDesc a;
    a.wgsl = "@fragment fn fs_main(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
        let full = vec2<f32>(textureDimensions(sceneDepthTex));
        return vec4<f32>(pos.x / full.x, 0.25, 0.0, 1.0); }";
    a.sceneInputs = true;
    a.stage = PostStage.beforeTonemap;
    a.output = "half";
    a.scale = 2;
    PostPassDesc b;
    b.wgsl = "@fragment fn fs_main(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
        let d = vec2<f32>(textureDimensions(input0));
        let h = textureLoad(input0, vec2<i32>(pos.xy) * 2, 0);
        return vec4<f32>(d.x / 1000.0, h.x, h.y, 1.0); }";
    b.stage = PostStage.beforeTonemap;
    b.inputs[0] = "half";
    b.output = "quarter";
    b.scale = 4;
    b.format = WGPUTextureFormat.rgba8Unorm;
    PostPassDesc c;
    c.wgsl = "@fragment fn fs_main(@location(0) uv: vec2<f32>) -> @location(0) vec4<f32> {
        return vec4<f32>(textureLoad(input1, vec2<i32>(uv * vec2<f32>(textureDimensions(input1))), 0).rg,
                         textureSampleLevel(srcTex, srcSamp, uv, 0.0).b * 0.0 + textureLoad(input0, vec2<i32>(0), 0).g, 1.0); }";
    c.inputs[0] = "half";
    c.inputs[1] = "quarter";
    ok &= expect(app.renderer.addPostPass(b) == 0, "reading a target before its writer is refused");
    immutable ia = app.renderer.addPostPass(a), ib = app.renderer.addPostPass(b), ic = app.renderer.addPostPass(c);
    ok &= expect(ia && ib && ic, "named target passes compile");
    auto s = capture(app, "passinputs_targets", &draw);
    if (!s.valid) return expect(false, "frame captured");
    immutable uint[2] mid = [WIN_W / 2 + 1, WIN_H / 2];
    // half width 320 -> 0.32; x at half resolution over full width -> 0.25; constant 0.25.
    ok &= expect(near(s, mid, 82, 64, 64, 2), "reduced-resolution targets are chained");
    // Only named-output passes in a stage: the picture must be untouched.
    app.renderer.removePostPass(ic);
    auto plain = capture(app, "passinputs_named_only", &draw);
    PostPassDesc d;
    d.wgsl = a.wgsl;
    d.sceneInputs = true;
    d.output = "unused";
    immutable id = app.renderer.addPostPass(d);
    auto named = capture(app, "passinputs_named_only2", &draw);
    app.renderer.removePostPass(id);
    app.renderer.removePostPass(ib);
    app.renderer.removePostPass(ia);
    auto none = capture(app, "passinputs_none", &draw);
    ok &= expect(plain.px == none.px && named.px == none.px, "passes with a named output leave the picture alone");
    // Order survives removal: a pass added after a removal still runs last.
    immutable p1 = app.renderer.addPostPass("@fragment fn fs_main(@location(0) uv: vec2<f32>) -> @location(0) vec4<f32> { return vec4<f32>(1.0, 0.0, 0.0, 1.0); }");
    immutable p2 = app.renderer.addPostPass("@fragment fn fs_main(@location(0) uv: vec2<f32>) -> @location(0) vec4<f32> { return vec4<f32>(0.0, 1.0, 0.0, 1.0); }");
    app.renderer.removePostPass(p1);
    immutable p3 = app.renderer.addPostPass("@fragment fn fs_main(@location(0) uv: vec2<f32>) -> @location(0) vec4<f32> { return vec4<f32>(0.0, 0.0, 1.0, 1.0); }");
    auto order = capture(app, "passinputs_order", &draw);
    ok &= expect(near(order, mid, 0, 0, 255, 0), "passes run in insertion order after a removal");
    app.renderer.removePostPass(p2);
    app.renderer.removePostPass(p3);
    return ok;
}

/// GTAO: analytic occlusion beside a wall, ambient only, participating
/// materials, scene alpha restored, resolution and viewport.
private bool checkAo(ref App app) {
    import std.algorithm.comparison : max;
    import std.math : atan, cos, pow;
    auto scene = Scene3DTextured.create(app.gpu, 16, false);
    scope(exit) scene.destroy();
    auto quad = TexMesh.quad(app.gpu);
    scope(exit) quad.destroy();
    auto cube = TexMesh.cube(app.gpu);
    scope(exit) cube.destroy();
    auto sampler = Sampler.create(app.gpu, TextureFilter.linear, TextureWrap.repeat);
    scope(exit) sampler.destroy();
    auto white = Texture.solid(app.gpu, 255, 255, 255);
    scope(exit) white.destroy();
    app.renderer.postSettings() = neutralPost();
    scope(exit) app.renderer.ambientOcclusion() = AoSettings.init;
    Material make(RenderState st, uint flags) {
        MaterialParams mp;
        mp.baseColor = [0.8f, 0.8f, 0.8f];
        mp.specularRoughness = 1;
        mp.alphaCutoff = 0.5f;
        mp.flags = flags;
        auto m = Material.create(app.gpu, scene.materialLayout(), sampler, white, mp, null, null, null, null);
        m.renderState = st;
        return m;
    }
    auto opaque = make(RenderState(BlendMode.opaque), 0);
    scope(exit) opaque.destroy();
    auto masked = make(RenderState(BlendMode.alpha, true, false, true), 0);
    scope(exit) masked.destroy();
    auto blended = make(RenderState.init, 0);
    scope(exit) blended.destroy();
    auto unlit = make(RenderState(BlendMode.opaque), MaterialFlags.unlit);
    scope(exit) unlit.destroy();
    Camera cam = Camera.create(0.9f, WIN_W, WIN_H, 0.5f, 60.0f);
    cam.lookAt(Vec3(0, 10, 0), Vec3(0, 0, 0));
    cam.up = Vec3(0, 0, -1);
    LightList lights;
    scope(exit) lights.release();

    AoSettings ao;
    ao.enabled = true;
    ao.radius = 2.5f;
    ao.quality = AoQuality.ultra;
    Shot shoot(string name, bool on, ref Material floor_, float ibl, bool sun, bool box = true) {
        app.renderer.ambientOcclusion() = on ? ao : AoSettings.init;
        return capture(app, name, (ref FrameContext f) {
            lights.clear();
            lights.dirEnabled = sun;
            lights.dir.direction = Vec3(0, 1, 0);
            lights.dir.intensity = 1.0f;
            lights.dir.castShadows = false;
            scene.setIblIntensity(ibl);
            scene.begin(cam);
            scene.draw(quad, floor_, Vec3(0, 0, 0), Vec3(9, 1, 9));
            if (box) scene.draw(cube, opaque, Vec3(2.5f, 0.125f, 0), Vec3(3, 0.25f, 9));
            scene.renderShadows(f, lights);
            scene.end(f);
        });
    }
    // Mean linear value of the floor at distance `d` from the wall (x = 1).
    float lin(ref Shot s, float d) {
        import std.math : tan;
        immutable k = (WIN_H * 0.5f) / (tan(0.45f) * 10);
        immutable x = cast(uint)(WIN_W * 0.5f + (1 - d) * k);
        float sum = 0;
        foreach (y; WIN_H / 2 - 16 .. WIN_H / 2 + 16) sum += pow(s.at(x, y, 1) / 255.0f, 2.2f);
        return sum / 32;
    }
    bool ok = true;
    static immutable float[4] dist = [0.12f, 0.25f, 0.5f, 1.0f];
    immutable float bright = 2.0f;
    auto off = shoot("ao_off", false, opaque, bright, false);
    if (!off.valid) return expect(false, "frame captured");
    float[4] expected;
    foreach (i, d; dist) expected[i] = 1 - (1 - cos(atan(0.25f / d))) * 0.5f;
    // Reference sampling converges to the analytic value. The presets sample
    // sparsely (the wall is 1/10 of the radius here): they may only
    // underestimate, and less with each quality level.
    float[4] measure(string label) {
        auto on = shoot("ao_" ~ label, true, opaque, bright, false);
        float[4] got;
        foreach (i, d; dist) got[i] = lin(on, d) / lin(off, d);
        writefln("    %s: %s, analytic %s", label, got, expected);
        return got;
    }
    ao.slices = 32;
    ao.steps = 64;
    immutable reference = measure("reference");
    float refWorst = 0;
    foreach (i; 0 .. 4) refWorst = max(refWorst, abs(reference[i] - expected[i]));
    ok &= expect(refWorst < 0.02f, "reference sampling matches the analytic value");
    ao.slices = ao.steps = 0;
    foreach (half; [false, true]) {
        ao.halfResolution = half;
        float last = 2;
        foreach (q; [AoQuality.low, AoQuality.medium, AoQuality.high, AoQuality.ultra]) {
            ao.quality = q;
            import std.conv : text;
            immutable got = measure(text(q, half ? " half" : ""));
            bool fine = got[0] < last && got[0] < 0.95f;
            foreach (i; 0 .. 4) fine &= got[i] > expected[i] - 0.02f;
            foreach (i; 1 .. 4) fine &= got[i] >= got[i - 1];
            ok &= expect(fine, "preset approaches the reference from above");
            last = got[0];
        }
    }
    ao.halfResolution = false;
    ao.quality = AoQuality.medium;

    // Flat floor: no self occlusion, from above and at a grazing angle.
    foreach (grazing; [false, true]) {
        immutable saved = cam;
        if (grazing) {
            cam.up = Vec3(0, 1, 0);
            cam.lookAt(Vec3(0, 0.6f, 4.4f), Vec3(0, 0.3f, 0));
        }
        auto a = shoot("ao_flat_off", false, opaque, bright, false, false);
        auto b = shoot("ao_flat_on", true, opaque, bright, false, false);
        int worst = 0;
        foreach (i; 0 .. a.px.length) worst = max(worst, abs(a.px[i] - b.px[i]));
        writefln("    flat floor%s: max difference %s", grazing ? " grazing" : "", worst);
        ok &= expect(worst <= 2, "no self occlusion on a flat floor");
        cam = saved;
    }

    // Direct light is untouched; mixed light loses exactly the ambient part.
    auto dOff = shoot("ao_direct_off", false, opaque, 0, true);
    auto dOn = shoot("ao_direct_on", true, opaque, 0, true);
    ok &= expect(dOff.px == dOn.px, "direct light is not darkened");
    auto aOn = shoot("ao_amb_on", true, opaque, 1, false);
    auto mOn = shoot("ao_mix_on", true, opaque, 1, true);
    float worstMix = 0;
    foreach (d; dist) worstMix = max(worstMix, abs(lin(mOn, d) - lin(dOff, d) - lin(aOn, d)));
    ok &= expect(worstMix < 0.01f, "mixed light loses only the ambient part");

    // Who takes part.
    bool darkened(ref Material m) {
        auto a = shoot("ao_mat_off", false, m, bright, false);
        auto b = shoot("ao_mat_on", true, m, bright, false);
        return lin(b, 0.12f) < lin(a, 0.12f) * 0.9f;
    }
    ok &= expect(darkened(masked), "masked materials take part");
    ok &= expect(!darkened(blended), "the default blend state does not take part");
    ok &= expect(!darkened(unlit), "unlit materials do not take part");
    ao.treatDefaultBlendAsOpaque = true;
    ok &= expect(darkened(blended), "treatDefaultBlendAsOpaque adds the default blend state");
    ao.treatDefaultBlendAsOpaque = false;

    // Static buffers, CPU and GPU culled: same as the dynamic draw.
    auto dynOn = shoot("ao_dyn", true, opaque, bright, false);
    immutable mediumRef = lin(dynOn, 0.25f) / lin(off, 0.25f);
    foreach (gpu; [false, true]) {
        StaticBuildOptions o;
        o.gpuCull = gpu;
        auto meshes = new TexMesh*[2];
        auto mats = new Material*[1];
        () @trusted { meshes[0] = &quad; meshes[1] = &cube; mats[0] = &opaque; }();
        auto descs = new StaticInstanceDesc[2];
        descs[0].model = Mat4.scaling(9, 1, 9);
        descs[1].model = Mat4.translation(2.5f, 0.125f, 0) * Mat4.scaling(3, 0.25f, 9);
        descs[1].mesh = 1;
        auto sib = StaticInstanceBuffer.build(app.gpu, meshes, mats, descs, o);
        scope(exit) sib.destroy();
        Shot st(bool on) {
            app.renderer.ambientOcclusion() = on ? ao : AoSettings.init;
            return capture(app, "ao_static", (ref FrameContext f) {
                lights.clear();
                lights.dirEnabled = false;
                scene.setIblIntensity(bright);
                scene.begin(cam);
                scene.submitStatic(sib);
                scene.renderShadows(f, lights);
                scene.end(f);
            });
        }
        auto a = st(false), b = st(true);
        ok &= expect(abs(lin(b, 0.25f) / lin(a, 0.25f) - mediumRef) < 0.02f, gpu ? "GPU-culled static" : "static");
    }

    // Scene alpha ends at 1 wherever something was drawn.
    PostPassDesc d;
    d.wgsl = "@fragment fn fs_main(@location(0) uv: vec2<f32>) -> @location(0) vec4<f32> {
        let a = textureSampleLevel(srcTex, srcSamp, uv, 0.0).a;
        return vec4<f32>(vec3<f32>(select(0.0, 1.0, abs(a - 1.0) < 1e-4)), 1.0); }";
    d.stage = PostStage.beforeTonemap;
    immutable id = app.renderer.addPostPass(d);
    auto alpha = shoot("ao_alpha", true, opaque, bright, false);
    app.renderer.removePostPass(id);
    bool allOne = true;
    foreach (v; alpha.px) allOne &= v == 255;
    ok &= expect(allOne, "scene alpha is restored");

    // Panel: same occlusion inside, nothing outside.
    Shot panel(bool on) {
        app.renderer.ambientOcclusion() = on ? ao : AoSettings.init;
        return capture(app, "ao_panel", (ref FrameContext f) {
            f.setViewport(100, 60, 320, 240, WIN_W, WIN_H);
            lights.clear();
            lights.dirEnabled = false;
            scene.setIblIntensity(bright);
            scene.begin(cam);
            scene.draw(quad, opaque, Vec3(0, 0, 0), Vec3(9, 1, 9));
            scene.draw(cube, opaque, Vec3(2.5f, 0.125f, 0), Vec3(3, 0.25f, 9));
            scene.renderShadows(f, lights);
            scene.end(f);
        });
    }
    {
        import std.math : tan;
        auto a = panel(false), b = panel(true);
        immutable x = cast(uint)(100 + 160 + 0.5f * 120 / (tan(0.45f) * 10));
        immutable r = pow(b.at(x, 180, 1) / cast(float) a.at(x, 180, 1), 2.2f);
        ok &= expect(abs(r - expected[2]) < 0.04f, "occlusion inside a viewport panel");
        bool same = true;
        foreach (y; 0 .. b.h)
            foreach (px; 0 .. b.w)
                if (px < 100 || px >= 420 || y < 60 || y >= 300) same &= a.at(px, y, 1) == b.at(px, y, 1);
        ok &= expect(same, "pixels outside the panel are unchanged");
    }
    if (bench) {
        foreach (half; [false, true])
            foreach (q; [AoQuality.low, AoQuality.medium, AoQuality.high, AoQuality.ultra]) {
                ao.quality = q;
                ao.halfResolution = half;
                ao.radius = 1.0f;
                app.renderer.ambientOcclusion() = ao;
                timeZones(app, "GTAO", ["gpu.gtao", "scene.gtao"], (ref FrameContext f) {
                    scene.begin(cam);
                    scene.draw(quad, opaque, Vec3(0, 0, 0), Vec3(9, 1, 9));
                    scene.draw(cube, opaque, Vec3(2.5f, 0.125f, 0), Vec3(3, 0.25f, 9));
                    scene.end(f);
                });
            }
    }
    return ok;
}

/// Specular antialiasing: a bumpy plane seen from afar must keep the mean
/// brightness of the same plane seen up close, and a curved surface with
/// `geometricSpecularAa` must not shimmer.
private bool checkSpecularAa(ref App app) {
    import std.math : cos, PI, pow, sin, sqrt;
    import std.random : Random, uniform;
    import engine.graphics.specular_aa : specularAaTexture;
    auto scene = Scene3DTextured.create(app.gpu, 16, false);
    scope(exit) scene.destroy();
    auto quad = TexMesh.quad(app.gpu);
    scope(exit) quad.destroy();
    auto sampler = Sampler.create(app.gpu, TextureFilter.linear, TextureWrap.repeat);
    scope(exit) sampler.destroy();
    auto white = Texture.solid(app.gpu, 255, 255, 255);
    scope(exit) white.destroy();
    app.renderer.postSettings() = neutralPost();
    enum N = 256;
    auto px = new ubyte[N * N * 4];
    auto rng = Random(11);
    // Smooth bumps about 4 texels wide.
    float[64][64] hmap;
    foreach (ref row; hmap) foreach (ref v; row) v = uniform(-1.0f, 1.0f, rng);
    float height(uint x, uint y) {
        immutable fx = x / 4.0f, fy = y / 4.0f;
        immutable x0 = cast(uint) fx, y0 = cast(uint) fy;
        immutable tx = fx - x0, ty = fy - y0;
        float h(uint a, uint b) { return hmap[b % 64][a % 64]; }
        return (h(x0, y0) * (1 - tx) + h(x0 + 1, y0) * tx) * (1 - ty)
            + (h(x0, y0 + 1) * (1 - tx) + h(x0 + 1, y0 + 1) * tx) * ty;
    }
    foreach (y; 0 .. N) foreach (x; 0 .. N) {
        immutable dx = (height((x + 1) % N, y) - height(x, y)) * 0.6f, dy = (height(x, (y + 1) % N) - height(x, y)) * 0.6f;
        immutable l = sqrt(dx * dx + dy * dy + 1);
        immutable float[3] n = [-dx / l, -dy / l, 1 / l];
        foreach (c; 0 .. 3) px[(y * N + x) * 4 + c] = cast(ubyte)((n[c] * 0.5f + 0.5f) * 255 + 0.5f);
        px[(y * N + x) * 4 + 3] = 255;
    }
    auto normal = Texture.fromPixels(app.gpu, px, N, N, TextureDesc.mippedNormal());
    scope(exit) normal.destroy();
    enum ROUGH = 0.25f;
    auto baked = specularAaTexture(app.gpu, null, 0, 0, px, N, N, ROUGH);
    scope(exit) baked.destroy();
    MaterialParams mp;
    mp.baseColor = [0.0f, 0.0f, 0.0f];
    mp.specularRoughness = ROUGH;
    mp.flags = MaterialFlags.normal;
    auto plain = Material.create(app.gpu, scene.materialLayout(), sampler, white, mp, null, () @trusted { return &normal; }(), null, null);
    scope(exit) plain.destroy();
    mp.specularRoughness = 1;
    mp.flags |= MaterialFlags.metallicRoughness;
    auto aa = Material.create(app.gpu, scene.materialLayout(), sampler, white, mp, () @trusted { return &baked; }(), () @trusted { return &normal; }(), null, null);
    scope(exit) aa.destroy();
    LightList lights;
    scope(exit) lights.release();
    // Orthographic-like view: the camera backs off and narrows the field of view.
    float mean(string name, ref Material m, float quadPixels, float tilt) {
        import std.math : atan;
        Camera cam = Camera.create(2 * atan(4.0f * WIN_H / quadPixels / 2 / 200), WIN_W, WIN_H, 100, 300);
        cam.lookAt(Vec3(0, 200, 0), Vec3(0, 0, 0));
        cam.up = Vec3(0, 0, -1);
        auto s = capture(app, name, (ref FrameContext f) {
            lights.clear();
            lights.dirEnabled = true;
            lights.dir.direction = Vec3(tilt, 1, 0).normalized();
            lights.dir.intensity = 0.35f;
            lights.dir.castShadows = false;
            scene.setIblIntensity(0);
            scene.begin(cam);
            scene.draw(quad, m, Vec3(0, 0, 0), Vec3(4, 1, 4));
            scene.renderShadows(f, lights);
            scene.end(f);
        });
        if (!s.valid) return -1;
        immutable half = cast(int)(quadPixels / 2) - 2;
        double sum = 0;
        uint n;
        foreach (y; s.h / 2 - half .. s.h / 2 + half) foreach (x; s.w / 2 - half .. s.w / 2 + half) {
            sum += pow(s.at(x, y, 1) / 255.0f, 2.2f);
            n++;
        }
        return cast(float)(sum / n);
    }
    bool ok = true;
    // GGX is not closed under this convolution, so one angle can be off by a
    // third: sum the error over several light angles.
    static immutable float[5] tilts = [0.0f, 0.1f, 0.2f, 0.3f, 0.45f];
    foreach (q; [32.0f, 16.0f]) {
        float errPlain = 0, errAa = 0, total = 0;
        foreach (t; tilts) {
            immutable r = mean("saa_near", plain, 256 * 1.7f, t), a = mean("saa_plain", plain, q, t),
                b = mean("saa_aa", aa, q, t);
            writefln("    %3.0f px, tilt %.2f: plain %.3f, specular AA %.3f, reference %.3f", q, t, a, b, r);
            errPlain += abs(a - r);
            errAa += abs(b - r);
            total += r;
        }
        writefln("    %3.0f px: relative error plain %.2f, specular AA %.2f", q, errPlain / total, errAa / total);
        ok &= expect(errAa < errPlain * 0.4f, "baked roughness keeps the distant brightness");
    }

    // A sphere a few pixels wide sliding by fractions of a pixel: its specular
    // highlight must change less with the flag.
    auto ball = lodSphere(app, 64, 32);
    scope(exit) ball.destroy();
    mp = MaterialParams.init;
    mp.baseColor = [0.0f, 0.0f, 0.0f];
    mp.specularRoughness = 0.15f;
    auto shiny = Material.create(app.gpu, scene.materialLayout(), sampler, white, mp, null, null, null, null);
    scope(exit) shiny.destroy();
    mp.flags = MaterialFlags.geometricSpecularAa;
    auto calm = Material.create(app.gpu, scene.materialLayout(), sampler, white, mp, null, null, null, null);
    scope(exit) calm.destroy();
    float flicker(ref Material m) {
        Camera cam = Camera.create(0.9f, WIN_W, WIN_H, 0.5f, 100);
        cam.lookAt(Vec3(0, 20, 0), Vec3(0, 0, 0));
        cam.up = Vec3(0, 0, -1);
        double[16] total;
        double avg = 0;
        foreach (i; 0 .. 16) {
            auto s = capture(app, "saa_ball", (ref FrameContext f) {
                lights.clear();
                lights.dirEnabled = true;
                lights.dir.direction = Vec3(0.4f, 1, 0.3f).normalized();
                lights.dir.intensity = 0.05f;
                lights.dir.castShadows = false;
                scene.setIblIntensity(0);
                scene.begin(cam);
                scene.draw(ball, m, Vec3(i * 0.007f, 0, i * 0.011f), Vec3(0.18f, 0.18f, 0.18f));
                scene.renderShadows(f, lights);
                scene.end(f);
            });
            double t = 0;
            foreach (y; WIN_H / 2 - 20 .. WIN_H / 2 + 20) foreach (x; WIN_W / 2 - 20 .. WIN_W / 2 + 20)
                t += pow(s.at(x, y, 1) / 255.0f, 2.2f);
            total[i] = t;
            avg += t / 16;
        }
        double var = 0;
        foreach (t; total) var += (t - avg) * (t - avg) / 16;
        return cast(float)(sqrt(var) / avg);
    }
    immutable fPlain = flicker(shiny), fCalm = flicker(calm);
    writefln("    highlight flicker: plain %.3f, geometric specular AA %.3f", fPlain, fCalm);
    ok &= expect(fCalm < fPlain * 0.5f, "geometricSpecularAa steadies small highlights");
    return ok;
}

/// Vertex colors on dynamic, tangent, skinned, surface-shader and static (CPU
/// and GPU) draws; meshes without colors next to them keep their look.
private bool checkVertexColor(ref App app) {
    auto scene = Scene3DTextured.create(app.gpu, 64, false);
    scope(exit) scene.destroy();
    auto sampler = Sampler.create(app.gpu, TextureFilter.linear, TextureWrap.repeat);
    scope(exit) sampler.destroy();
    auto white = Texture.solid(app.gpu, 255, 255, 255);
    scope(exit) white.destroy();
    app.renderer.postSettings() = neutralPost();

    // Unit quad on XZ: red on -X, blue on +X, alpha 1 on -Z, 0 on +Z.
    TexVert[] tv;
    TexTanVert[] ttv;
    SkinnedVertex[] sv;
    ubyte[4][] colors;
    foreach (i; 0 .. 4) {
        immutable float u = (i == 1 || i == 2) ? 1 : 0, w = i >= 2 ? 1 : 0;
        tv ~= TexVert([u - 0.5f, 0, w - 0.5f], [0, 1, 0], [u, w]);
        ttv ~= TexTanVert([u - 0.5f, 0, w - 0.5f], [0, 1, 0], [u, w], [1, 0, 0, 1]);
        SkinnedVertex v;
        v.position = [u - 0.5f, 0, w - 0.5f];
        v.uv = [u, w];
        sv ~= v;
        colors ~= [cast(ubyte)(u > 0 ? 0 : 255), ubyte(0), cast(ubyte)(u > 0 ? 255 : 0), cast(ubyte)(w > 0 ? 0 : 255)];
    }
    auto idx = [0u, 2, 1, 0, 3, 2];
    auto plain = TexMesh.fromData(app.gpu, tv, idx);
    scope(exit) plain.destroy();
    auto colored = TexMesh.fromData(app.gpu, tv, idx);
    scope(exit) colored.destroy();
    colored.setVertexColors(app.gpu, colors);
    auto tangent = TexMesh.fromData(app.gpu, ttv, idx);
    scope(exit) tangent.destroy();
    tangent.setVertexColors(app.gpu, colors);
    auto plainTangent = TexMesh.fromData(app.gpu, ttv, idx);
    scope(exit) plainTangent.destroy();
    auto skinned = SkinnedMesh.fromData(app.gpu, sv, idx);
    scope(exit) skinned.destroy();
    skinned.setVertexColors(app.gpu, colors);
    auto plainSkinned = SkinnedMesh.fromData(app.gpu, sv, idx);
    scope(exit) plainSkinned.destroy();
    // Characters without COLOR_0 pass an empty list: it must be a no-op, not an assert.
    plain.setVertexColors(app.gpu, null);
    plainSkinned.setVertexColors(app.gpu, null);
    assert(!plain.hasVertexColors && !plainSkinned.hasVertexColors);

    enum kSurface = `
fn surface(in: SurfaceIn, base: SurfaceOut) -> SurfaceOut {
    var o = base;
    // Show the color as emission: the hook sees the vertex color, white without one.
    o.emission = in.vertexColor.rgb * 0.2;
    o.baseColor = vec3<f32>(0.0);
    return o;
}
`;
    immutable shader = scene.createSurfaceShader(kSurface);
    if (shader == 0) return expect(false, "surface shader compiles");
    MaterialParams mp;
    mp.baseColor = [1, 1, 1];
    mp.specularWeight = 0;
    auto mat = Material.create(app.gpu, scene.materialLayout(), sampler, white, mp, null, null, null, null);
    scope(exit) mat.destroy();
    mat.renderState.blend = BlendMode.opaque;
    auto surf = Material.create(app.gpu, scene.materialLayout(), sampler, white, mp, null, null, null, null);
    scope(exit) surf.destroy();
    surf.renderState.blend = BlendMode.opaque;
    surf.surfaceShader = shader;
    auto masked = Material.create(app.gpu, scene.materialLayout(), sampler, white, mp, null, null, null, null);
    scope(exit) masked.destroy();
    masked.renderState = RenderState(BlendMode.opaque, true, true, true);
    auto blended = Material.create(app.gpu, scene.materialLayout(), sampler, white, mp, null, null, null, null);
    scope(exit) blended.destroy();

    auto meshes = new TexMesh*[4];
    auto mats = new Material*[2];
    () @trusted {
        meshes[0] = &plain; meshes[1] = &colored; meshes[2] = &tangent; meshes[3] = &plainTangent;
        mats[0] = &mat; mats[1] = &surf;
    }();
    auto descs = new StaticInstanceDesc[8];
    foreach (i, ref d; descs) {
        d.mesh = cast(uint)(i % 4);
        d.material = cast(uint)(i / 4);
        d.model = Mat4.translation(-10.5f + i * 3, 0, 4) * Mat4.scaling(2.5f, 1, 2.5f);
    }
    Camera cam = Camera.create(0.9f, WIN_W, WIN_H, 0.5f, 100.0f);
    cam.lookAt(Vec3(0, 30, 0), Vec3(0, 0, 0));
    cam.up = Vec3(0, 0, -1);
    LightList lights;
    scope(exit) lights.release();
    immutable Mat4[1] palette = [Mat4.identity()];
    if (bench) {
        // 400 spheres of 3.2k triangles each, all on screen.
        auto balls = [lodSphereColored(app, false), lodSphereColored(app, true)];
        scope(exit) foreach (b; balls) { b.destroy(); }
        foreach (c, b; balls)
            timeZones(app, c == 0 ? "400 spheres, plain" : "400 spheres, vertex color", ["gpu.scene", "gpu.frame", "renderer.submit"],
                      (ref FrameContext f) {
                scene.begin(cam);
                foreach (n; 0 .. 400)
                    scene.draw(*b, mat, Vec3(-19 + (n % 20) * 2, 0, -14 + (n / 20) * 1.4f), Vec3(1, 1, 1));
                scene.end(f);
            });
        return true;
    }
    bool ok = true;
    foreach (gpu; [false, true]) {
        import engine.gpu.static_cull : StaticGpuData;
        if (gpu && !StaticGpuData.supported(app.gpu)) continue;
        StaticBuildOptions o;
        o.gpuCull = gpu;
        auto sib = StaticInstanceBuffer.build(app.gpu, meshes, mats, descs, o);
        scope(exit) sib.destroy();
        auto s = capture(app, gpu ? "vcolor_gpu" : "vcolor_cpu", (ref FrameContext f) {
            lights.clear();
            lights.dirEnabled = true;
            lights.dir.direction = Vec3(0, 1, 0);
            lights.dir.intensity = 1.0f;
            lights.dir.color = Vec3(1, 1, 1);
            scene.setIblIntensity(0);
            scene.begin(cam);
            Mat4 at(float x, float z) { return Mat4.translation(x, 0, z) * Mat4.scaling(2.5f, 1, 2.5f); }
            scene.drawMatrix(plain, mat, at(-10.5f, -4), Color4.white);
            scene.drawMatrix(colored, mat, at(-7.5f, -4), Color4.white);
            scene.drawMatrix(tangent, mat, at(-4.5f, -4), Color4.white);
            scene.drawMatrix(colored, surf, at(-1.5f, -4), Color4.white);
            scene.drawMatrix(plain, surf, at(1.5f, -4), Color4.white);
            scene.drawSkinned(skinned, mat, at(4.5f, -4), Color4.white, palette[]);
            scene.drawSkinned(plainSkinned, mat, at(7.5f, -4), Color4.white, palette[]);
            scene.drawMatrix(colored, masked, at(10.5f, -4), Color4.white);
            scene.drawMatrix(colored, blended, at(0, 0), Color4.white);
            scene.submitStatic(sib);
            scene.renderShadows(f, lights);
            scene.end(f);
        });
        if (!s.valid) return expect(false, "frame captured");
        import std.math : tan;
        immutable k = (s.h * 0.5f) / (tan(0.45f) * 30);
        ubyte[3] px(float x, float z) {
            immutable ix = cast(uint)(s.w * 0.5f + x * k), iy = cast(uint)(s.h * 0.5f + z * k);
            return [s.at(ix, iy, 0), s.at(ix, iy, 1), s.at(ix, iy, 2)];
        }
        // `kind`: 0 = white, 1 = red to blue.
        void probe(string name, float x, float z, bool isColored) {
            immutable l = px(x - 1, z - 0.3f), r = px(x + 1, z - 0.3f);
            immutable good = isColored
                ? l[0] > 60 && l[0] > l[2] * 1.5f && r[2] > 60 && r[2] > r[0] * 1.5f && l[1] < 12 && r[1] < 12
                : l[0] > 60 && abs(l[0] - l[1]) < 3 && abs(l[0] - l[2]) < 3 && abs(l[0] - r[0]) < 4;
            if (!good) writefln("    %s: left %s right %s", name, l, r);
            ok &= expect(good, name ~ (isColored ? " is colored" : " stays white"));
        }
        immutable tag = gpu ? "gpu " : "cpu ";
        probe(tag ~ "plain", -10.5f, -4, false);
        probe(tag ~ "colored", -7.5f, -4, true);
        probe(tag ~ "tangent", -4.5f, -4, true);
        probe(tag ~ "surface", -1.5f, -4, true);
        probe(tag ~ "surface without colors", 1.5f, -4, false);
        probe(tag ~ "skinned", 4.5f, -4, true);
        probe(tag ~ "skinned without colors", 7.5f, -4, false);
        foreach (i; 0 .. 8) {
            immutable c = i % 4 == 1 || i % 4 == 2;
            probe(tag ~ "static " ~ cast(char)('0' + i), -10.5f + i * 3, 4, c);
        }
        // Alpha: the mask cuts at 0.5, blending fades.
        immutable keep = px(10.5f, -4.8f), cut = px(10.5f, -3.2f);
        ok &= expect(keep[0] + keep[2] > 60 && cut[0] + cut[2] < 10, tag ~ "vertex alpha drives the mask");
        immutable a = px(-0.9f, -0.9f), b = px(-0.9f, 0), c = px(-0.9f, 0.9f);
        ok &= expect(a[0] > b[0] && b[0] > c[0], tag ~ "vertex alpha blends");
    }
    return ok;
}

/// 64x32 sphere on the heap (bench only).
private TexMesh* lodSphereColored(ref App app, bool colored) @trusted {
    import core.lifetime : move;
    auto m = new TexMesh;
    auto src = TexMesh.sphere(app.gpu, 64, 25);
    move(src, *m);
    if (colored) {
        auto c = new ubyte[4][65 * 26];
        foreach (ref x; c) x = [255, 128, 64, 255];
        m.setVertexColors(app.gpu, c);
    }
    return m;
}

/// Volumetric light: analytic brightness, sun and local shadows in the air, no
/// visible jitter, no halo around foreground objects, off = same image.
private bool checkVolumetric(ref App app) {
    import engine.gpu.volumetric : VolumetricQuality, VolumetricSettings;
    import std.math : exp, PI, pow, sqrt, tan;
    auto scene = Scene3DTextured.create(app.gpu, 64, false);
    scope(exit) scene.destroy();
    auto sampler = Sampler.create(app.gpu, TextureFilter.linear, TextureWrap.repeat);
    scope(exit) sampler.destroy();
    auto white = Texture.solid(app.gpu, 255, 255, 255);
    scope(exit) white.destroy();
    auto cube = TexMesh.cube(app.gpu);
    scope(exit) cube.destroy();
    MaterialParams mp;
    mp.baseColor = [0, 0, 0];
    mp.specularWeight = 0;
    auto black = Material.create(app.gpu, scene.materialLayout(), sampler, white, mp, null, null, null, null);
    scope(exit) black.destroy();
    black.renderState.blend = BlendMode.opaque;
    app.renderer.postSettings() = neutralPost();
    scope(exit) app.renderer.volumetrics() = VolumetricSettings.init;
    LightList lights;
    scope(exit) lights.release();
    Camera cam = Camera.create(0.9f, WIN_W, WIN_H, 0.1f, 200.0f);
    cam.lookAt(Vec3(0, 0, 0), Vec3(0, 0, -1));
    enum E = 8.0f;

    struct Setup {
        bool sun, blocker, nearBox, spot, spotBlocker, point;
    }
    Shot shoot(string name, VolumetricSettings v, Setup u) {
        app.renderer.volumetrics() = v;
        return capture(app, name, (ref FrameContext f) {
            lights.clear();
            lights.dirEnabled = u.sun;
            lights.dir.direction = Vec3(0, 1, 0);
            lights.dir.color = Vec3(1, 1, 1);
            lights.dir.intensity = E;
            lights.dir.castShadows = u.blocker;
            lights.dir.cascades.maxDistance = 60;
            if (u.spot) {
                GpuSpotLight sl;
                sl.position = Vec3(0, 5, -15);
                sl.direction = Vec3(0, -1, 0);
                sl.range = 20;
                sl.intensity = 300;
                sl.innerConeDeg = 14;
                sl.outerConeDeg = 16;
                sl.castShadows = true;
                lights.addSpot(sl);
            }
            if (u.point) {
                GpuPointLight pl;
                pl.position = Vec3(0, 0, -15);
                pl.range = 6;
                pl.intensity = 300;
                lights.addPoint(pl);
            }
            scene.setIblIntensity(0);
            scene.begin(cam);
            // A roof over the right half of the view.
            if (u.blocker) scene.drawMatrix(cube, black, Mat4.translation(30, 20, -30) * Mat4.scaling(60, 1, 100), Color4.white);
            if (u.nearBox) scene.drawMatrix(cube, black, Mat4.translation(0, 0, -10.5f) * Mat4.scaling(3, 3, 1), Color4.white);
            if (u.spotBlocker) scene.drawMatrix(cube, black, Mat4.translation(0, 1.5f, -15) * Mat4.scaling(6, 0.2f, 6), Color4.white);
            scene.renderShadows(f, lights);
            scene.end(f);
        }, 2, Color4(0, 0, 0, 1));
    }
    float linear(ref Shot s, uint x, uint y) { return pow(s.luma(x, y) / 255.0f, 2.2f); }
    float mean(ref Shot s, int cx, int cy, int r) {
        double sum = 0;
        uint n;
        foreach (y; cy - r .. cy + r) foreach (x; cx - r .. cx + r) { sum += linear(s, x, y); n++; }
        return cast(float)(sum / n);
    }
    // Largest difference inside a square (jitter that the blur left).
    float spread(ref Shot s, int cx, int cy, int r) {
        float lo = 255, hi = 0;
        foreach (y; cy - r .. cy + r) foreach (x; cx - r .. cx + r) {
            immutable l = s.luma(x, y);
            if (l < lo) lo = l;
            if (l > hi) hi = l;
        }
        return hi - lo;
    }
    if (bench) {
        Vec3[64] at;
        foreach (i, ref a; at) a = Vec3((i % 8 - 4.0f) * 5, (i / 8 % 4) * 2.0f - 3, -10 - (i / 8) * 8.0f);
        foreach (withLocals; [false, true]) foreach (quarter; [false, true])
            foreach (q; [VolumetricQuality.low, VolumetricQuality.medium, VolumetricQuality.high, VolumetricQuality.ultra]) {
                VolumetricSettings v;
                v.enabled = true;
                v.quality = q;
                v.quarterResolution = quarter;
                app.renderer.volumetrics() = v;
                import std.conv : to;
                timeZones(app, (withLocals ? "sun + 64 lights " : "sun ") ~ (quarter ? "quarter " : "half ") ~ q.to!string,
                          ["gpu.volumetric", "scene.volumetric"], (ref FrameContext f) {
                    lights.clear();
                    lights.dirEnabled = true;
                    lights.dir.direction = Vec3(0.3f, 1, 0.2f).normalized();
                    lights.dir.castShadows = true;
                    lights.dir.cascades.maxDistance = 100;
                    if (withLocals) foreach (i, a; at) {
                        if (i % 2) {
                            GpuPointLight pl;
                            pl.position = a;
                            pl.range = 8;
                            lights.addPoint(pl);
                        } else {
                            GpuSpotLight sl;
                            sl.position = a;
                            sl.direction = Vec3(0, -1, 0);
                            sl.range = 10;
                            lights.addSpot(sl);
                        }
                    }
                    scene.begin(cam);
                    scene.drawMatrix(cube, black, Mat4.translation(0, -5, -50) * Mat4.scaling(100, 1, 100), Color4.white);
                    foreach (i; 0 .. 20)
                        scene.drawMatrix(cube, black, Mat4.translation((i % 5 - 2.0f) * 6, -2, -12 - (i / 5) * 12.0f) * Mat4.scaling(2, 6, 2), Color4.white);
                    scene.renderShadows(f, lights);
                    scene.end(f);
                });
            }
        return true;
    }

    bool ok = true;
    VolumetricSettings v;
    v.enabled = true;
    v.density = 0.03f;
    v.anisotropy = 0;
    v.maxDistance = 40;
    Setup sunOnly;
    sunOnly.sun = true;
    float expected(float distance) { return E / (4 * PI) * (1 - exp(-0.03f * distance)); }
    immutable cx = WIN_W / 2, cy = WIN_H / 2;
    foreach (quarter; [false, true]) {
        v.quarterResolution = quarter;
        immutable tag = quarter ? "quarter: " : "half: ";
        auto sky = shoot("vol_sky", v, sunOnly);
        if (!sky.valid) return expect(false, "frame captured");
        immutable a = mean(sky, cx, cy, 20), want = expected(40);
        writefln("    %sopen air %.4f, exact %.4f, spread %.1f", tag, a, want, spread(sky, cx, cy, 40));
        ok &= expect(abs(a - want) < want * 0.04f, tag ~ "open air matches the exact integral");
        ok &= expect(spread(sky, cx, cy, 40) <= 3, tag ~ "no visible jitter in open air");

        Setup box = sunOnly;
        box.nearBox = true;
        auto b = shoot("vol_box", v, box);
        // Box front face at z = -10: 3x3 units.
        immutable k = (WIN_H * 0.5f) / tan(0.45f) / 10.0f;
        immutable edge = cast(int)(1.5f * k);
        immutable inside = mean(b, cx, cy, 10), wantBox = expected(10);
        writefln("    %sbox %.4f, exact %.4f", tag, inside, wantBox);
        ok &= expect(abs(inside - wantBox) < wantBox * 0.06f, tag ~ "surfaces stop the light at their depth");
        // Halo: rows crossing the silhouette, compared with both sides.
        float inErr = 0, outErr = 0;
        foreach (dy; [-20, 0, 20]) {
            foreach (d; 2 .. 8) {
                immutable i = abs(b.luma(cx + edge - d, cy + dy) - b.luma(cx, cy + dy));
                immutable o = abs(b.luma(cx + edge + d, cy + dy) - b.luma(cx + edge + 40, cy + dy));
                if (i > inErr) inErr = i;
                if (o > outErr) outErr = o;
            }
        }
        writefln("    %ssilhouette error inside %.0f outside %.0f", tag, inErr, outErr);
        ok &= expect(inErr <= 4 && outErr <= 4, tag ~ "no halo at silhouettes");

        Setup roof = sunOnly;
        roof.blocker = true;
        auto r = shoot("vol_roof", v, roof);
        immutable litSide = mean(r, cx / 2, cy, 15), darkSide = mean(r, cx + cx / 2, cy, 15);
        writefln("    %sunder the open sky %.4f, under the roof %.4f", tag, litSide, darkSide);
        ok &= expect(litSide > want * 0.8f && darkSide < want * 0.1f, tag ~ "the roof shadows the air");
        ok &= expect(spread(r, cx / 2, cy, 25) <= 5, tag ~ "no visible jitter beside the shadow");

        Setup spot;
        spot.spot = true;
        auto c = shoot("vol_spot", v, spot);
        // At z = -15: cone half width at 4 units below the light is 1.1.
        immutable ks = (WIN_H * 0.5f) / tan(0.45f) / 15.0f;
        immutable inCone = mean(c, cx, cy - cast(int)(1 * ks), 4), outCone = mean(c, cx + cast(int)(3.5f * ks), cy - cast(int)(1 * ks), 4);
        spot.spotBlocker = true;
        auto cb = shoot("vol_spot_shadow", v, spot);
        immutable above = mean(cb, cx, cy - cast(int)(3 * ks), 4), below = mean(cb, cx, cy + cast(int)(1 * ks), 4);
        immutable belowLit = mean(c, cx, cy + cast(int)(1 * ks), 4);
        writefln("    %sspot cone %.4f beside %.5f; blocked: above %.4f below %.5f (open %.4f)", tag, inCone, outCone, above, below, belowLit);
        ok &= expect(inCone > 0.01f && outCone < inCone * 0.02f, tag ~ "the spot draws a cone");
        ok &= expect(above > 0.01f && below < belowLit * 0.1f, tag ~ "the spot cone is shadowed");
        Setup point;
        point.point = true;
        auto pt = shoot("vol_point", v, point);
        immutable core_ = mean(pt, cx, cy, 4), rim = mean(pt, cx + cast(int)(4 * ks), cy, 4), outside = mean(pt, cx + cast(int)(6.8f * ks), cy, 4);
        writefln("    %spoint core %.4f, 4 units away %.4f, outside the range %.5f", tag, core_, rim, outside);
        ok &= expect(core_ > rim && rim > outside && outside < 0.0005f, tag ~ "the point light glows within its range");
    }
    // Attenuation and off.
    v.quarterResolution = false;
    v.attenuate = true;
    Setup none;
    MaterialParams em;
    em.baseColor = [0, 0, 0];
    em.emissionColor = [1, 1, 1];
    em.emissionLuminance = 0.8f;
    auto glow = Material.create(app.gpu, scene.materialLayout(), sampler, white, em, null, null, null, null);
    scope(exit) glow.destroy();
    glow.renderState.blend = BlendMode.opaque;
    Shot wall(string name, VolumetricSettings vs) {
        app.renderer.volumetrics() = vs;
        return capture(app, name, (ref FrameContext f) {
            lights.clear();
            scene.begin(cam);
            scene.drawMatrix(cube, glow, Mat4.translation(0, 0, -20.5f) * Mat4.scaling(60, 60, 1), Color4.white);
            scene.renderShadows(f, lights);
            scene.end(f);
        }, 2, Color4(0, 0, 0, 1));
    }
    auto off = wall("vol_off", VolumetricSettings.init);
    auto on = wall("vol_attenuate", v);
    v.attenuate = false;
    auto additive = wall("vol_additive", v);
    immutable ratio = mean(on, cx, cy, 10) / mean(off, cx, cy, 10);
    writefln("    transmittance %.3f, exact %.3f", ratio, exp(-0.03f * 20));
    ok &= expect(abs(ratio - exp(-0.03f * 20)) < 0.02f, "attenuation matches the exact transmittance");
    ok &= expect(abs(mean(additive, cx, cy, 10) - mean(off, cx, cy, 10)) < 0.003f, "without lights or attenuation nothing changes");
    return ok;
}

/// Auto exposure brings a uniform image to the key, adapts at the set speed and
/// ignores outliers; the color table is exact on identity and on known colors.
private bool checkExposure(ref App app) {
    import engine.assets.cube_lut : CubeLut;
    import std.math : exp, log2, pow;
    auto rig = QuadRig.create(app);
    scope(exit) rig.destroy();
    auto white = Texture.solid(app.gpu, 255, 255, 255);
    scope(exit) white.destroy();
    app.renderer.postSettings() = neutralPost();
    scope(exit) app.renderer.postSettings() = PostSettings.init;
    scope(exit) app.renderer.clearColorLut();
    MaterialParams mp;
    mp.baseColor = [1, 1, 1];
    mp.flags = MaterialFlags.unlit;
    auto mat = Material.create(app.gpu, rig.scene.materialLayout(), rig.sampler, white, mp, null, null, null, null);
    scope(exit) mat.destroy();
    float level = 1;
    bool spot;
    void draw(ref FrameContext f) {
        rig.scene.begin(rig.camera);
        rig.scene.draw(rig.quad, mat, Vec3(0, 0, 0), Vec3(40, 1, 40), Color4(level, level, level, 1));
        // A lamp over 3% of the view.
        if (spot) rig.scene.draw(rig.quad, mat, Vec3(0, 0.01f, 0), Vec3(2, 1, 2), Color4(60, 60, 60, 1));
        rig.scene.end(f);
    }
    if (bench) {
        app.renderer.postSettings().autoExposure.enabled = true;
        timeZones(app, "auto exposure", ["gpu.post.autoExposure", "post.autoExposure", "gpu.post.tonemap"], &draw);
        auto lut = CubeLut.identity(33);
        app.renderer.setColorLut(lut);
        timeZones(app, "auto exposure + table", ["gpu.post.autoExposure", "gpu.post.tonemap"], &draw);
        app.renderer.postSettings().autoExposure.enabled = false;
        timeZones(app, "table", ["gpu.post.tonemap"], &draw);
        app.renderer.clearColorLut();
        timeZones(app, "off", ["gpu.post.tonemap"], &draw);
        return true;
    }
    bool ok = true;
    float linear(ref Shot s) { return pow(s.at(s.w / 8, s.h / 8, 1) / 255.0f, 2.2f); }
    auto settings = () @trusted { return &app.renderer.postSettings(); }();
    level = 0.3f;
    auto off = capture(app, "exposure_off", &draw);
    if (!off.valid) return expect(false, "frame captured");

    // Uniform images land on the key.
    settings.autoExposure.enabled = true;
    settings.autoExposure.fixedDt = 1 / 60.0f;
    settings.autoExposure.minExposure = 0.001f;
    settings.autoExposure.maxExposure = 1000;
    foreach (l; [0.01f, 0.3f, 1.0f, 20.0f]) {
        level = l;
        app.renderer.resetAutoExposure();
        auto s = capture(app, "exposure_on", &draw, 0);
        writefln("    level %.2f -> %.4f", l, linear(s));
        ok &= expect(abs(linear(s) - 0.18f) < 0.18f * 0.03f, "a uniform image lands on the key in one frame after a reset");
    }
    // Limits.
    settings.autoExposure.maxExposure = 2;
    level = 0.02f;
    app.renderer.resetAutoExposure();
    auto clamped = capture(app, "exposure_clamp", &draw, 0);
    ok &= expect(abs(linear(clamped) - 0.04f) < 0.004f, "the exposure limit holds");
    settings.autoExposure.maxExposure = 1000;
    // Outliers.
    level = 0.3f;
    spot = true;
    app.renderer.resetAutoExposure();
    auto outlier = capture(app, "exposure_spot", &draw, 0);
    writefln("    with a lamp in view %.4f", linear(outlier));
    ok &= expect(abs(linear(outlier) - 0.18f) < 0.18f * 0.05f, "a small bright object does not move the exposure");
    spot = false;
    // Adaptation: log2 exposure follows 1 - exp(-t * speed).
    foreach (toBright; [true, false]) {
        immutable from = toBright ? 0.1f : 0.8f, to = toBright ? 0.8f : 0.1f;
        settings.autoExposure.adaptToBright = 3;
        settings.autoExposure.adaptToDark = 1;
        level = from;
        app.renderer.resetAutoExposure();
        capture(app, "exposure_from", &draw, 0);
        level = to;
        auto s = capture(app, "exposure_adapt", &draw, 29); // 30 frames = 0.5 s
        immutable speed = toBright ? 3.0f : 1.0f;
        immutable start = log2(0.18f / from), goal = log2(0.18f / to);
        immutable want = to * pow(2.0f, goal + (start - goal) * exp(-0.5f * speed));
        immutable float shown = want > 1 ? 1 : want;
        writefln("    %s after 0.5 s: %.4f, exact %.4f", toBright ? "to bright" : "to dark", linear(s), shown);
        ok &= expect(abs(linear(s) - shown) < shown * 0.05f, toBright ? "adapts to bright at its speed" : "adapts to dark at its speed");
    }
    settings.autoExposure.enabled = false;
    level = 0.3f;
    auto offAgain = capture(app, "exposure_off_again", &draw);
    ok &= expect(offAgain.px == off.px, "off returns the same image");

    // Color table.
    auto lut = CubeLut.identity(17);
    app.renderer.setColorLut(lut);
    uint worst;
    foreach (l; [0.0f, 0.02f, 0.3f, 0.7f, 1.0f]) {
        level = l;
        settings.lutStrength = 0;
        auto a = capture(app, "lut_none", &draw, 0);
        settings.lutStrength = 1;
        auto b = capture(app, "lut_identity", &draw, 0);
        foreach (c; 0 .. 3) {
            immutable d = abs(a.at(50, 50, c) - b.at(50, 50, c));
            if (d > worst) worst = d;
        }
    }
    ok &= expect(worst <= 1, "the identity table keeps every level within 1/255");
    // Swap red and blue, darken green.
    foreach (i; 0 .. lut.rgb.length / 3) {
        immutable r = lut.rgb[i * 3];
        lut.rgb[i * 3] = lut.rgb[i * 3 + 2];
        lut.rgb[i * 3 + 1] *= 0.5f;
        lut.rgb[i * 3 + 2] = r;
    }
    app.renderer.setColorLut(lut);
    mp.baseColor = [0.9f, 0.4f, 0.1f];
    mat.updateParams(app.gpu, mp);
    level = 1;
    settings.lutStrength = 0;
    auto plain = capture(app, "lut_plain", &draw);
    settings.lutStrength = 1;
    auto swapped = capture(app, "lut_swapped", &draw);
    writefln("    plain %s swapped %s", plain.px[0 .. 3], swapped.px[0 .. 3]);
    ok &= expect(abs(swapped.at(50, 50, 0) - plain.at(50, 50, 2)) <= 1 && abs(swapped.at(50, 50, 2) - plain.at(50, 50, 0)) <= 1
                 && abs(swapped.at(50, 50, 1) - plain.at(50, 50, 1) / 2) <= 1, "the table maps the display colors");
    settings.lutStrength = 0.5f;
    auto half = capture(app, "lut_half", &draw);
    ok &= expect(abs(half.at(50, 50, 0) - (plain.at(50, 50, 0) + swapped.at(50, 50, 0)) / 2) <= 1, "strength blends");
    settings.lutStrength = 1;
    foreach (aa; [AaMode.off, AaMode.smaa]) {
        settings.aaMode = aa;
        auto s = capture(app, "lut_aa", &draw);
        ok &= expect(abs(s.at(50, 50, 0) - swapped.at(50, 50, 0)) <= 1, "works with the AA chain");
    }
    settings.aaMode = AaMode.legacy;
    app.renderer.clearColorLut();
    auto cleared = capture(app, "lut_cleared", &draw);
    ok &= expect(cleared.px == plain.px, "clearing the table returns the same image");
    return ok;
}

/// Particles: soft fade against the depth, wrapped lighting with shadows, flipbook atlas.
private bool checkParticles(ref App app) {
    import engine.graphics.particles : ParticleDesc, ParticleSystem;
    import std.math : PI, pow;
    auto scene = Scene3DTextured.create(app.gpu, 4096, false);
    scope(exit) scene.destroy();
    auto quad = TexMesh.quad(app.gpu);
    scope(exit) quad.destroy();
    auto cube = TexMesh.cube(app.gpu);
    scope(exit) cube.destroy();
    auto sampler = Sampler.create(app.gpu, TextureFilter.linear, TextureWrap.clamp);
    scope(exit) sampler.destroy();
    auto white = Texture.solid(app.gpu, 255, 255, 255);
    scope(exit) white.destroy();
    // 4x2 atlas of 16x16 frames: frame i is the solid color (i * 32, 255 - i * 32, 64).
    ubyte[] px = new ubyte[64 * 32 * 4];
    foreach (y; 0 .. 32) foreach (x; 0 .. 64) {
        immutable i = (y / 16) * 4 + x / 16;
        px[(y * 64 + x) * 4 .. (y * 64 + x) * 4 + 4] = [cast(ubyte)(i * 32), cast(ubyte)(255 - i * 32), 64, 255];
    }
    auto atlas = Texture.fromPixels(app.gpu, px, 64, 32);
    scope(exit) atlas.destroy();
    app.renderer.postSettings() = neutralPost();
    LightList lights;
    scope(exit) lights.release();

    Material make(ref Texture tex, uint flags, BlendMode blend, float softDistance = 0, float blendFrames = 1) {
        MaterialParams mp;
        mp.baseColor = [1, 1, 1];
        mp.flags = flags;
        mp.softDistance = softDistance;
        mp.flipbookGrid = [4, 2];
        mp.flipbookBlend = blendFrames;
        mp.lightWrap = 0.5f;
        Material m = Material.create(app.gpu, scene.materialLayout(), sampler, tex, mp, null, null, null, null);
        m.renderState = RenderState(blend, false, true);
        return m;
    }
    MaterialParams bp;
    bp.baseColor = [0, 0, 0];
    bp.specularWeight = 0;
    auto black = Material.create(app.gpu, scene.materialLayout(), sampler, white, bp, null, null, null, null);
    scope(exit) black.destroy();
    black.renderState.blend = BlendMode.opaque;
    auto hard = make(white, MaterialFlags.unlit, BlendMode.alpha);
    scope(exit) hard.destroy();
    auto soft = make(white, MaterialFlags.unlit | MaterialFlags.soft, BlendMode.alpha, 1);
    scope(exit) soft.destroy();
    auto softAdd = make(white, MaterialFlags.unlit | MaterialFlags.soft, BlendMode.additive, 1);
    scope(exit) softAdd.destroy();
    auto lit = make(white, MaterialFlags.litParticle, BlendMode.alpha);
    scope(exit) lit.destroy();
    auto book = make(atlas, MaterialFlags.unlit | MaterialFlags.flipbook, BlendMode.alpha);
    scope(exit) book.destroy();
    auto bookHard = make(atlas, MaterialFlags.unlit | MaterialFlags.flipbook, BlendMode.alpha, 0, 0);
    scope(exit) bookHard.destroy();
    Camera cam = Camera.create(0.9f, WIN_W, WIN_H, 0.1f, 100.0f);
    cam.lookAt(Vec3(0, 0, 10), Vec3(0, 0, 0));
    // Unit quad facing +Z.
    Mat4 facing(Vec3 at, float size) {
        import engine.graphics.particles : billboardMatrix;
        return billboardMatrix(at, Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1), size);
    }
    immutable cx = WIN_W / 2, cy = WIN_H / 2;
    float linear(ref Shot s, uint x, uint y) { return pow(s.at(x, y, 1) / 255.0f, 2.2f); }

    if (bench) {
        auto disc = Texture.softDisc(app.gpu);
        scope(exit) disc.destroy();
        auto dUnlit = make(disc, MaterialFlags.unlit, BlendMode.alpha);
        auto dSoft = make(disc, MaterialFlags.unlit | MaterialFlags.soft, BlendMode.alpha, 1);
        auto dLit = make(disc, MaterialFlags.litParticle, BlendMode.alpha);
        auto dAll = make(disc, MaterialFlags.litParticle | MaterialFlags.soft | MaterialFlags.flipbook, BlendMode.alpha, 1);
        scope(exit) { dUnlit.destroy(); dSoft.destroy(); dLit.destroy(); dAll.destroy(); }
        auto ps = ParticleSystem.create(2000);
        foreach (i; 0 .. 2000) {
            ParticleDesc d;
            d.pos = Vec3((i % 50 - 25) * 0.25f, (i / 50 - 20) * 0.2f, (i * 7 % 40) * 0.1f - 2);
            d.life = 1e6f;
            d.sizeStart = 0.8f;
            d.colorStart = Color4(1, 1, 1, 0.1f);
            ps.spawn(d);
        }
        void run(string label, ref Material m, uint points = 16) {
            auto mat = () @trusted { return &m; }();
            timeZones(app, label, ["gpu.scene.alpha", "gpu.snapshotOpaque"], (ref FrameContext f) {
                lights.clear();
                lights.dirEnabled = true;
                lights.dir.direction = Vec3(0.3f, 1, 0.2f).normalized();
                lights.dir.castShadows = true;
                foreach (i; 0 .. points) {
                    GpuPointLight pl;
                    pl.position = Vec3(i % 4 * 2.0f - 3, i / 4 * 1.5f - 2, 1);
                    pl.range = 4;
                    lights.addPoint(pl);
                }
                scene.begin(cam);
                scene.drawMatrix(cube, black, Mat4.translation(0, 0, -3) * Mat4.scaling(30, 30, 1), Color4.white);
                ps.draw(scene, quad, *mat, cam);
                scene.renderShadows(f, lights);
                scene.end(f);
            });
        }
        run("2000 unlit", dUnlit);
        run("2000 soft", dSoft);
        run("2000 lit, sun", dLit, 0);
        run("2000 lit, sun + 16 point lights", dLit);
        run("2000 lit + soft + flipbook", dAll);
        return true;
    }

    bool ok = true;
    // --- soft: a wall behind the particle, at several gaps.
    Shot wallShot(string name, ref Material m, float gap, bool wall = true) {
        auto mat = () @trusted { return &m; }();
        return capture(app, name, (ref FrameContext f) {
            lights.clear();
            scene.begin(cam);
            if (wall) scene.drawMatrix(cube, black, Mat4.translation(0, 0, -0.5f) * Mat4.scaling(30, 30, 1), Color4.white);
            scene.drawMatrix(quad, *mat, facing(Vec3(0, 0, gap), 4), Color4.white);
            scene.renderShadows(f, lights);
            scene.end(f);
        });
    }
    static float smooth(float t) { return t <= 0 ? 0 : t >= 1 ? 1 : t * t * (3 - 2 * t); }
    foreach (gap; [0.1f, 0.25f, 0.5f, 0.75f, 1.5f]) {
        auto a = wallShot("soft_alpha", soft, gap);
        if (!a.valid) return expect(false, "frame captured");
        auto b = wallShot("soft_additive", softAdd, gap);
        immutable want = smooth(gap);
        writefln("    gap %.2f: alpha %.3f additive %.3f, exact %.3f", gap, linear(a, cx, cy), linear(b, cx, cy), want);
        ok &= expect(abs(linear(a, cx, cy) - want) < 0.02f && abs(linear(b, cx, cy) - want) < 0.02f, "soft fade follows the gap");
    }
    auto hardShot = wallShot("hard", hard, 0.1f);
    ok &= expect(hardShot.at(cx, cy, 1) == 255, "without the flag the particle is not faded");
    auto sky = wallShot("soft_sky", soft, 0.1f, false);
    ok &= expect(sky.at(cx, cy, 1) == 255, "nothing behind: not faded");

    // --- lit: sun on the camera side, aside and behind; shadow; point light.
    Shot litShot(string name, Vec3 sunDir, bool blocker, bool point) {
        return capture(app, name, (ref FrameContext f) {
            lights.clear();
            lights.dirEnabled = !point;
            lights.dir.direction = sunDir;
            lights.dir.color = Vec3(1, 1, 1);
            lights.dir.intensity = 2;
            lights.dir.castShadows = blocker;
            if (point) {
                GpuPointLight pl;
                pl.position = Vec3(0, 0, 2);
                pl.range = 10;
                pl.intensity = 10;
                lights.addPoint(pl);
            }
            scene.setIblIntensity(0);
            scene.begin(cam);
            if (blocker) scene.drawMatrix(cube, black, Mat4.translation(0, 3.5f, 0) * Mat4.scaling(8, 0.5f, 8), Color4.white);
            scene.drawMatrix(quad, lit, facing(Vec3(0, 0, 0), 4), Color4.white);
            scene.renderShadows(f, lights);
            scene.end(f);
        });
    }
    float wrapped(float c) { return c + 0.5f > 0 ? (c + 0.5f) / 2.25f : 0; }
    foreach (i, d; [Vec3(0, 0, 1), Vec3(0, 1, 0), Vec3(0, 0, -1)]) {
        auto s = litShot("lit", d, false, false);
        // The center of the ball faces the camera.
        immutable want = 2 / PI * wrapped(d.z);
        writefln("    sun %s: %.4f, exact %.4f", d, linear(s, cx, cy), want);
        ok &= expect(abs(linear(s, cx, cy) - want) < 0.01f, "wrapped sun light");
        if (i == 1) ok &= expect(linear(s, cx, cy - 80) > linear(s, cx, cy + 80) * 2, "the ball is brighter on the side of the sun");
    }
    auto shadowed = litShot("lit_shadow", Vec3(0, 1, 0), true, false);
    ok &= expect(linear(shadowed, cx, cy) < 0.002f, "the particle receives shadows");
    auto pointLit = litShot("lit_point", Vec3(0, 1, 0), false, true);
    immutable att = pow(1 - pow(0.2f, 4.0f), 2.0f) / 5;
    immutable wantPoint = 10 / PI * att * wrapped(1);
    writefln("    point light %.4f, exact %.4f", linear(pointLit, cx, cy), wantPoint);
    ok &= expect(abs(linear(pointLit, cx, cy) - wantPoint) < 0.02f, "point lights reach the particle");

    // --- flipbook
    Shot bookShot(string name, ref Material m, float frameIndex, float size = 4) {
        auto mat = () @trusted { return &m; }();
        return capture(app, name, (ref FrameContext f) {
            lights.clear();
            scene.begin(cam);
            scene.drawMatrix(quad, *mat, facing(Vec3(0, 0, 0), size), Color4.white, [1, 0, 0, frameIndex]);
            scene.renderShadows(f, lights);
            scene.end(f);
        });
    }
    int code(float lin) { return cast(int)(pow(lin, 1 / 2.2f) * 255 + 0.5f); }
    foreach (i; 0 .. 8) {
        auto s = bookShot("flipbook", book, i);
        bool exact = true;
        // Every pixel of the quad, edges included: no bleeding from the neighbors.
        immutable half = cast(int)(2 * (WIN_H * 0.5f) / 0.483f / 10) - 2;
        foreach (y; cy - half .. cy + half) foreach (x; cx - half .. cx + half)
            if (abs(s.at(x, y, 0) - code(i * 32 / 255.0f)) > 1 || abs(s.at(x, y, 1) - code((255 - i * 32) / 255.0f)) > 1) exact = false;
        ok &= expect(exact, "frame " ~ cast(char)('0' + i) ~ " fills the quad with its own color");
    }
    auto mid = bookShot("flipbook_mid", book, 2.5f);
    ok &= expect(abs(mid.at(cx, cy, 0) - code(80 / 255.0f)) <= 1, "frames cross-fade");
    auto step = bookShot("flipbook_step", bookHard, 2.9f);
    ok &= expect(abs(step.at(cx, cy, 0) - code(64 / 255.0f)) <= 1, "hard steps without blending");
    auto wrap = bookShot("flipbook_wrap", book, 8.0f);
    ok &= expect(abs(wrap.at(cx, cy, 1) - 255) <= 1, "the frame index wraps");
    auto tiny = bookShot("flipbook_tiny", book, 5, 0.1f);
    ok &= expect(abs(tiny.at(cx, cy, 0) - code(160 / 255.0f)) <= 3, "a minified frame keeps its color");

    // --- through ParticleSystem
    auto ps = ParticleSystem.create(1);
    ParticleDesc d;
    d.life = 2;
    d.sizeStart = d.sizeEnd = 4;
    d.colorEnd = Color4(1, 1, 1, 1);
    d.flipbookFrames = 8;
    ps.spawn(d);
    ps.update(1);
    auto sys = capture(app, "flipbook_system", (ref FrameContext f) {
        lights.clear();
        scene.begin(cam);
        ps.draw(scene, quad, book, cam);
        scene.renderShadows(f, lights);
        scene.end(f);
    });
    ok &= expect(abs(sys.at(cx, cy, 0) - code(112 / 255.0f)) <= 1, "ParticleSystem plays the atlas over the lifetime");
    // Frames are upright: one 2x2 frame, red on top.
    auto flag = Texture.fromPixels(app.gpu, [255, 0, 0, 255, 255, 0, 0, 255, 0, 0, 255, 255, 0, 0, 255, 255], 2, 2);
    scope(exit) flag.destroy();
    MaterialParams fp;
    fp.baseColor = [1, 1, 1];
    fp.flags = MaterialFlags.unlit | MaterialFlags.flipbook;
    auto flagMat = Material.create(app.gpu, scene.materialLayout(), sampler, flag, fp, null, null, null, null);
    scope(exit) flagMat.destroy();
    flagMat.renderState = RenderState(BlendMode.alpha, false, true);
    ps.clear();
    d.flipbookFrames = 1;
    ps.spawn(d);
    auto upright = capture(app, "flipbook_upright", (ref FrameContext f) {
        lights.clear();
        scene.begin(cam);
        ps.draw(scene, quad, flagMat, cam);
        scene.renderShadows(f, lights);
        scene.end(f);
    });
    ok &= expect(upright.at(cx, cy - 80, 0) > 200 && upright.at(cx, cy + 80, 2) > 200, "atlas frames are upright");
    return ok;
}

/// E10: block-compressed textures. The CPU decoder must agree with the GPU for
/// every BC7 mode, a compressed image must look like its source, and the RGBA8
/// fallback must look like the blocks.
private bool checkBc(ref App app) {
    import core.time : MonoTime;
    import engine.assets.bc : BcQuality, encodeBcLevel;
    import engine.assets.ktx2 : Ktx2Image, TextureCodec, textureLevelBytes, writeKtx2;
    import engine.assets.png : saveRgbaPng;
    import engine.graphics.texture : generateMipChainRgba8, mipCount, mipExtent;
    import std.algorithm.comparison : max;
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.math : log10, sin, sqrt;
    import std.path : buildPath;
    import std.random : Random, uniform;
    import bindings.wgpu : WGPUFeatureName;

    if (!app.gpu.hasFeature(WGPUFeatureName.textureCompressionBC)) {
        writeln("  no BC support on this GPU: skipped");
        return true;
    }
    auto rig = QuadRig.create(app);
    scope(exit) rig.destroy();
    auto post = neutralPost();
    post.outputTransfer = OutputTransfer.srgb;
    app.renderer.postSettings() = post;
    bool ok = true;

    /// The texture over black; `opaque_` ignores alpha.
    Shot show(string name, ref Texture tex, bool opaque_) {
        MaterialParams mp;
        mp.flags = MaterialFlags.unlit;
        auto mat = Material.create(app.gpu, rig.scene.materialLayout(), rig.sampler, tex, mp, null, null, null, null);
        scope(exit) mat.destroy();
        if (opaque_) mat.renderState.blend = BlendMode.opaque;
        return capture(app, name, (ref FrameContext f) {
            rig.scene.begin(rig.camera);
            rig.scene.draw(rig.quad, mat, Vec3(0, 0, 0), Vec3(9.4f, 1, 9.4f));
            rig.scene.end(f);
        });
    }
    static int worst(ref Shot a, ref Shot b) {
        int m = 0;
        foreach (i; 0 .. a.px.length) m = max(m, abs(cast(int) a.px[i] - b.px[i]));
        return m;
    }
    static double psnr(ref Shot a, ref Shot b) {
        double e = 0;
        size_t n;
        foreach (i; 0 .. a.px.length) {
            if (i % 4 == 3) continue;
            immutable d = cast(double) a.px[i] - b.px[i];
            e += d * d;
            n++;
        }
        return e == 0 ? 99 : 10 * log10(255.0 * 255.0 * n / e);
    }

    // Random bits, every mode 512 times (every two- and three-subset shape).
    enum N = 256;
    auto rng = Random(5);
    foreach (codec; [TextureCodec.bc7, TextureCodec.bc5]) {
        auto blocks = new ubyte[textureLevelBytes(codec, N, N, 0)];
        foreach (i, ref b; blocks) b = cast(ubyte) uniform(0, 256, rng);
        if (codec == TextureCodec.bc7)
            foreach (i; 0 .. blocks.length / 16) {
                immutable m = i % 8;
                blocks[i * 16] = cast(ubyte)((blocks[i * 16] & ~((2 << m) - 1)) | (1 << m));
            }
        Ktx2Image img;
        img.codec = codec;
        img.width = img.height = N;
        img.levels = [blocks];
        auto gpuTex = Texture.fromKtx2(app.gpu, img, false);
        scope(exit) gpuTex.destroy();
        auto cpuTex = Texture.fromKtx2(app.gpu, img, false, true);
        scope(exit) cpuTex.destroy();
        ok &= expect(gpuTex.normalXy == (codec == TextureCodec.bc5) && !cpuTex.normalXy, "only BC5 on the GPU lacks Z");
        if (codec == TextureCodec.bc5) {
            // Blue differs by design (Z is rebuilt on the CPU): compare red and green.
            auto a = show("bc5_gpu", gpuTex, true), b = show("bc5_cpu", cpuTex, true);
            // The CPU follows the specification (sevenths, 8 bits). An RX 6600 uses
            // weights in 64ths and more bits (checked: with those weights the worst
            // difference is one output step): up to 1.7 + 0.5 codes for random
            // endpoints. Compare in linear: the output curve magnifies that near black.
            static float linear(ubyte v) {
                immutable float c = v / 255.0f;
                return 255 * (c <= 0.04045f ? c / 12.92f : ((c + 0.055f) / 1.055f) ^^ 2.4f);
            }
            float m = 0;
            foreach (i; 0 .. a.px.length) if (i % 4 < 2) m = max(m, abs(linear(a.px[i]) - linear(b.px[i])));
            writefln("  bc5 random blocks: worst difference GPU - CPU %.2f codes", m);
            // Plus the rounding of the captures (up to 1.2 codes each near white).
            ok &= expect(a.valid && m <= 4.0f, "BC5 decoder matches the GPU");
            continue;
        }
        foreach (opaque_; [true, false]) {
            auto a = show(opaque_ ? "bc7_gpu" : "bc7_gpu_alpha", gpuTex, opaque_);
            auto b = show(opaque_ ? "bc7_cpu" : "bc7_cpu_alpha", cpuTex, opaque_);
            immutable m = worst(a, b);
            writefln("  bc7 random blocks%s: worst difference GPU - CPU %s", opaque_ ? "" : " (alpha)", m);
            ok &= expect(a.valid && m == 0, "BC7 decoder matches the GPU");
        }
    }

    // A picture: source against its compressed files, through every loading path.
    auto dir = buildPath(tempDir(), "game-engine-bc-check");
    mkdirRecurse(dir);
    scope(exit) if (dir.exists) rmdirRecurse(dir);
    immutable uint P = bench ? 2048 : 512;
    auto px = new ubyte[cast(size_t) P * P * 4];
    auto bump = new ubyte[cast(size_t) P * P * 4];
    foreach (y; 0 .. P) foreach (x; 0 .. P) {
        immutable float fx = x * 512.0f / P, fy = y * 512.0f / P;
        auto o = px[(cast(size_t) y * P + x) * 4 .. (cast(size_t) y * P + x) * 4 + 4];
        immutable brick = (cast(int)(fx / 64 + (cast(int)(fy / 32) & 1) * 0.5f) * 37 + cast(int)(fy / 32) * 91) & 31;
        immutable mortar = (cast(int) fy % 32 < 3) || (cast(int)(fx + (cast(int)(fy / 32) & 1) * 32) % 64 < 3);
        immutable int grain = uniform(-6, 7, rng);
        o[0] = cast(ubyte)((mortar ? 170 : 130 + brick) + grain);
        o[1] = cast(ubyte)((mortar ? 165 : 62 + brick) + grain);
        o[2] = cast(ubyte)((mortar ? 160 : 48 + brick / 2) + grain);
        o[3] = 255;
        immutable float dx = 0.5f * sin(fx * 0.2f) * (1 + 0.3f * sin(fy * 0.05f)), dy = 0.4f * sin(fy * 0.17f + fx * 0.03f);
        immutable l = sqrt(dx * dx + dy * dy + 1);
        auto b = bump[(cast(size_t) y * P + x) * 4 .. (cast(size_t) y * P + x) * 4 + 4];
        b[0] = cast(ubyte)((-dx / l * 0.5f + 0.5f) * 255 + 0.5f);
        b[1] = cast(ubyte)((-dy / l * 0.5f + 0.5f) * 255 + 0.5f);
        b[2] = cast(ubyte)((1 / l * 0.5f + 0.5f) * 255 + 0.5f);
        b[3] = 255;
    }
    Ktx2Image pack(const(ubyte)[] src, TextureCodec codec, bool srgb) {
        Ktx2Image img;
        img.codec = codec;
        img.srgb = srgb;
        img.width = img.height = P;
        immutable n = mipCount(P, P);
        size_t bytes = 0;
        foreach (l; 1 .. n) bytes += textureLevelBytes(TextureCodec.rgba8, P, P, l);
        auto tail = new ubyte[bytes];
        generateMipChainRgba8(src, P, P, tail, n, codec == TextureCodec.bc5, srgb);
        size_t off = 0;
        foreach (l; 0 .. n) {
            immutable b = textureLevelBytes(TextureCodec.rgba8, P, P, l);
            auto lv = l == 0 ? src : tail[off .. off + b];
            if (l > 0) off += b;
            img.levels ~= encodeBcLevel(lv, mipExtent(P, l), mipExtent(P, l), codec == TextureCodec.bc7);
        }
        return img;
    }
    auto color = pack(px, TextureCodec.bc7, true);
    auto png = buildPath(dir, "wall.png"), plainKtx = buildPath(dir, "plain.ktx2"), zstdKtx = buildPath(dir, "wall.ktx2");
    saveRgbaPng(png, px, P, P);
    () @trusted {
        write(plainKtx, writeKtx2(color));
        write(zstdKtx, writeKtx2(color, 3));
    }();
    auto desc = TextureDesc.mippedSrgb();
    auto reference = Texture.fromImageFile(app.gpu, png, desc);
    scope(exit) reference.destroy();
    auto sideDesc = desc;
    sideDesc.compressed = true;
    auto sidecar = Texture.fromImageFile(app.gpu, png, sideDesc);
    scope(exit) sidecar.destroy();
    auto direct = Texture.fromImageFile(app.gpu, plainKtx, desc);
    scope(exit) direct.destroy();
    auto decoded = Texture.fromKtx2(app.gpu, color, true, true);
    scope(exit) decoded.destroy();
    ok &= expect(sidecar.format == WGPUTextureFormat.bc7RgbaUnormSrgb && direct.format == sidecar.format
        && sidecar.mipLevels == reference.mipLevels, "KTX2 beside the image is used");
    ok &= expect(reference.format == WGPUTextureFormat.rgba8UnormSrgb, "off by default");
    ok &= expect(sidecar.gpuBytes * 4 <= reference.gpuBytes + 64 * 4, "a quarter of the memory");
    if (!bench) {
        auto a = show("bc_source", reference, true), b = show("bc_sidecar", sidecar, true),
            c = show("bc_direct", direct, true), d = show("bc_decoded", decoded, true);
        writefln("  picture: PSNR %.1f dB, zstd against plain worst %s, fallback against blocks worst %s",
            psnr(a, b), worst(b, c), worst(b, d));
        ok &= expect(a.valid && psnr(a, b) > 36, "compressed picture looks like its source");
        ok &= expect(worst(b, c) == 0, "zstd is lossless");
        ok &= expect(worst(b, d) <= 1, "fallback looks like the blocks");
    }

    // Normal map: BC5 with rebuilt Z against RGBA8, lit from the side.
    auto normals = pack(bump, TextureCodec.bc5, false);
    auto rgbaNormal = Texture.fromPixels(app.gpu, bump, P, P, TextureDesc.mippedNormal());
    scope(exit) rgbaNormal.destroy();
    auto bc5 = Texture.fromKtx2(app.gpu, normals, false);
    scope(exit) bc5.destroy();
    auto bc5cpu = Texture.fromKtx2(app.gpu, normals, false, true);
    scope(exit) bc5cpu.destroy();
    auto white = Texture.solid(app.gpu, 255, 255, 255);
    scope(exit) white.destroy();
    auto smp = Sampler.create(app.gpu, TextureFilter.linear, TextureWrap.repeat);
    scope(exit) smp.destroy();
    LightList lights;
    scope(exit) lights.release();
    if (!bench) {
        Shot lit(string name, ref Texture n) {
            MaterialParams mp;
            mp.flags = MaterialFlags.normal;
            auto mat = Material.create(app.gpu, rig.scene.materialLayout(), smp, white, mp, null, () @trusted { return &n; }(), null, null);
            scope(exit) mat.destroy();
            return capture(app, name, (ref FrameContext f) {
                lights.clear();
                lights.dirEnabled = true;
                lights.dir.direction = Vec3(1, 1, 0.4f).normalized();
                lights.dir.intensity = 1;
                lights.dir.castShadows = false;
                rig.scene.setIblIntensity(0);
                rig.scene.begin(rig.camera);
                rig.scene.draw(rig.quad, mat, Vec3(0, 0, 0), Vec3(9.4f, 1, 9.4f));
                rig.scene.renderShadows(f, lights);
                rig.scene.end(f);
            });
        }
        auto a = lit("bc_normal_rgba", rgbaNormal), b = lit("bc_normal_bc5", bc5), c = lit("bc_normal_fallback", bc5cpu);
        auto flat = lit("bc_normal_flat", white);
        writefln("  normal map: BC5 against RGBA8 PSNR %.1f dB (a white map: %.1f), fallback against BC5 %.1f dB",
            psnr(a, b), psnr(a, flat), psnr(b, c));
        ok &= expect(a.valid && psnr(a, b) > 38, "BC5 normals shade like RGBA8 normals");
        ok &= expect(psnr(b, c) > 38, "the fallback shades like BC5");
    }

    if (bench) {
        double ms(scope Texture delegate() @safe load) {
            double best = 1e9;
            foreach (_; 0 .. 5) {
                immutable t = MonoTime.currTime;
                auto tex = load();
                immutable e = (MonoTime.currTime - t).total!"usecs" / 1000.0;
                tex.destroy();
                if (e < best) best = e;
            }
            return best;
        }
        import std.file : getSize;
        immutable tp = ms(() => Texture.fromImageFile(app.gpu, png, desc));
        immutable tk = ms(() => Texture.fromImageFile(app.gpu, plainKtx, desc));
        immutable tz = ms(() => Texture.fromImageFile(app.gpu, zstdKtx, desc));
        immutable td = ms(() => Texture.fromKtx2(app.gpu, color, true, true));
        writefln("  bench %sx%s color map with mips, best of 5", P, P);
        writefln("    PNG          %7.1f ms  %6.2f MiB file  %6.2f MiB GPU", tp, getSize(png) / 1048576.0, reference.gpuBytes / 1048576.0);
        writefln("    KTX2 BC7     %7.1f ms  %6.2f MiB file  %6.2f MiB GPU", tk, getSize(plainKtx) / 1048576.0, direct.gpuBytes / 1048576.0);
        writefln("    KTX2 + zstd  %7.1f ms  %6.2f MiB file  %6.2f MiB GPU", tz, getSize(zstdKtx) / 1048576.0, sidecar.gpuBytes / 1048576.0);
        writefln("    BC7 decoded to RGBA8 on the CPU %.1f ms", td);
    }
    return ok;
}

/// E13: wires thinner than a pixel. Plain wires break up, thin ones keep their
/// light whatever the angle, and wide geometry is untouched.
private bool checkThin(ref App app) {
    import std.math : cos, PI, pow, sin, tan;
    auto scene = Scene3DTextured.create(app.gpu, 256, false);
    scope(exit) scene.destroy();
    auto sampler = Sampler.create(app.gpu, TextureFilter.linear, TextureWrap.repeat);
    scope(exit) sampler.destroy();
    auto white = Texture.solid(app.gpu, 255, 255, 255);
    scope(exit) white.destroy();
    auto post = neutralPost();
    post.outputTransfer = OutputTransfer.srgb;
    app.renderer.postSettings() = post;

    // Unit-radius tube along X, length 2.
    enum SIDES = 24;
    TexVert[] tv;
    uint[] idx;
    foreach (i; 0 .. SIDES + 1) {
        immutable float a = 2 * PI * i / SIDES, y = cos(a), z = sin(a);
        tv ~= TexVert([-1, y, z], [0, y, z], [0, 0]);
        tv ~= TexVert([1, y, z], [0, y, z], [1, 0]);
    }
    foreach (i; 0 .. SIDES) {
        immutable uint o = i * 2;
        idx ~= [o, o + 2, o + 1, o + 1, o + 2, o + 3];
    }
    auto tube = TexMesh.fromData(app.gpu, tv, idx);
    scope(exit) tube.destroy();

    enum DIST = 100.0f, FOV = 0.9f;
    Camera cam = Camera.create(FOV, WIN_W, WIN_H, 1, 300);
    cam.lookAt(Vec3(0, 0, DIST), Vec3(0, 0, 0));
    immutable float pixel = 2 * DIST * tan(FOV / 2) / WIN_H; // world size of a pixel at the wires
    Material make(float radius, uint flags, bool alpha, bool ds) {
        MaterialParams mp;
        mp.flags = MaterialFlags.unlit | flags;
        mp.thinRadius = radius;
        auto m = Material.create(app.gpu, scene.materialLayout(), sampler, white, mp, null, null, null, null);
        m.renderState = RenderState(alpha ? BlendMode.alpha : BlendMode.opaque, !alpha, ds);
        return m;
    }
    Shot render(string name, ref Material m, float radius, float angle, float shift) {
        return capture(app, name, (ref FrameContext f) {
            scene.begin(cam);
            scene.drawMatrix(tube, m, Mat4.translation(shift * pixel * -sin(angle), shift * pixel * cos(angle), 0)
                * Mat4.rotationZ(angle) * Mat4.scaling(30, radius, radius), Color4(1, 1, 1, 1));
            scene.end(f);
        });
    }
    static float linear(ubyte v) {
        immutable float c = v / 255.0f;
        return c <= 0.04045f ? c / 12.92f : ((c + 0.055f) / 1.055f) ^^ 2.4f;
    }
    static double light(ref Shot s) {
        double t = 0;
        for (size_t i = 0; i < s.px.length; i += 4) t += linear(s.px[i]);
        return t;
    }
    bool ok = true;
    immutable float lengthPx = 60 / pixel;
    foreach (width; [0.25f, 0.6f]) {
        immutable radius = width * pixel / 2;
        auto plain = make(radius, 0, false, false), thin = make(radius, MaterialFlags.thin, false, false),
            soft = make(radius, MaterialFlags.thin, true, false);
        scope(exit) { plain.destroy(); thin.destroy(); soft.destroy(); }
        // Light of each wire over angles and sub-pixel shifts, against its real coverage.
        // At 45 degrees a one-pixel band holds one or two pixels per 1.41: up to 41% off.
        float worstPlain = 0, worstThin = 0, worstSoft = 0, diagonal = 0;
        uint gaps = 0, plainGaps = 0, columns = 0;
        foreach (angle; [0.0f, 0.03f, 0.4f, 0.785f, 1.2f, 1.5707f]) foreach (shift; [0.1f, 0.3f, 0.6f, 0.8f]) {
            auto a = render("thin_plain", plain, radius, angle, shift), b = render("thin_dither", thin, radius, angle, shift),
                c = render("thin_alpha", soft, radius, angle, shift);
            immutable want = width * lengthPx;
            float rel(ref Shot s) { return abs(cast(float)(light(s) / want) - 1); }
            if (rel(a) > worstPlain) worstPlain = rel(a);
            if (angle == 0.785f) {
                diagonal = rel(b) > diagonal ? rel(b) : diagonal;
                diagonal = rel(c) > diagonal ? rel(c) : diagonal;
            } else {
                if (rel(b) > worstThin) worstThin = rel(b);
                if (rel(c) > worstSoft) worstSoft = rel(c);
            }
            if (angle == 0.03f) foreach (x; c.w / 2 - 80 .. c.w / 2 + 80) {
                bool hit = false, plainHit = false;
                foreach (y; 0 .. c.h) {
                    if (c.at(x, y, 0) > 0) hit = true;
                    if (a.at(x, y, 0) > 0) plainHit = true;
                }
                columns++;
                if (!hit) gaps++;
                if (!plainHit) plainGaps++;
            }
        }
        writefln("  wire %.2f px wide, worst light error: plain %.2f, thin %.2f, thin with alpha %.2f, at 45 degrees %.2f; gaps: plain %s, thin with alpha %s of %s columns",
            width, worstPlain, worstThin, worstSoft, diagonal, plainGaps, gaps, columns);
        ok &= expect(worstThin < 0.1f, "dithered wires keep their light");
        ok &= expect(worstSoft < 0.05f && gaps == 0, "blended wires keep their light without gaps");
        ok &= expect(diagonal < 0.45f, "the diagonal stays within the pixel lattice");
        ok &= expect(worstPlain > 0.3f && plainGaps > columns / 4, "plain wires break up");
    }
    // Wider than a pixel: same image with and without the flag.
    immutable radius = 3 * pixel;
    auto plain = make(radius, 0, false, false), thin = make(radius, MaterialFlags.thin, false, false);
    scope(exit) { plain.destroy(); thin.destroy(); }
    auto a = render("thin_wide_plain", plain, radius, 0.4f, 0.3f), b = render("thin_wide", thin, radius, 0.4f, 0.3f);
    ok &= expect(a.valid && a.px == b.px, "geometry wider than a pixel is untouched");

    // Cost: 4000 wires.
    foreach (flag; [0u, cast(uint) MaterialFlags.thin]) {
        auto m = make(0.1f * pixel, flag, false, false);
        scope(exit) m.destroy();
        timeZones(app, flag ? "4000 wires, thin" : "4000 wires, plain", ["gpu.scene.opaque.batches"], (ref FrameContext f) {
            scene.begin(cam);
            foreach (i; 0 .. 4000)
                scene.drawMatrix(tube, m, Mat4.translation(0, (i % 800) * 0.1f - 40, (i / 800) * -2.0f)
                    * Mat4.scaling(60, 0.1f * pixel, 0.1f * pixel), Color4(1, 1, 1, 1));
            scene.end(f);
        });
    }
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
    Check("gpucull", &checkGpuCull),
    Check("passinputs", &checkPassInputs),
    Check("ao", &checkAo),
    Check("specaa", &checkSpecularAa),
    Check("vcolor", &checkVertexColor),
    Check("volumetric", &checkVolumetric),
    Check("exposure", &checkExposure),
    Check("particles", &checkParticles),
    Check("bc", &checkBc),
    Check("thin", &checkThin),
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
