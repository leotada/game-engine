/**
 * OW-2 open-world rendering benchmark (Phase 2 definition of done).
 *
 * - 12,000 (default, `--props=N`) instanced glTF rocks with load-time LOD
 *   chains, scattered over 3 km × 3 km in one `StaticInstanceBuffer`
 *   (frustum + distance culling and per-cell LOD every frame, no re-upload).
 * - 200 dynamic multi-node vehicles (`GltfAsset` + `ModelInstance`) driven
 *   along the camera path with per-instance material overrides
 *   (`MaterialPool`) and node visibility toggles (doors), drawn through
 *   `drawModel` with automatic per-instance LOD and culling.
 * - Directional light with shadows following the camera, plus a
 *   shadow-casting point light and spot light near the vehicles (per-view
 *   caster culling). `--no-cull` disables culling for comparison.
 *
 * Usage:
 *   dub run --config=openworld-bench
 *   dub run --config=openworld-bench -- --headless-frames=600 --assert-no-gc
 *
 * `--headless-frames=N` renders N frames (after 5 warm-up frames) on a
 * fixed timestep, prints a summary and exits. `--assert-no-gc` fails if
 * the GC heap grew by a single byte during those frames.
 */
module demo.openworld_bench;

import core.memory : GC;
import core.time : MonoTime;
import std.conv : to;
import std.math : sin, cos, PI;
import std.stdio : writefln;

import engine.app;
import engine.assets.gltf : buildGlb;
import engine.core.log;
import engine.gpu.shadow : directionalLightVP;
import engine.scene.atmosphere : FogSettings;
import engine.gpu.ibl_dynamic : DynamicIbl;
import engine.scene.time_of_day : applyEnvironment, applyEnvironmentToScene, evaluateEnvironment,
    skyIblParams, TimeOfDay, Weather;
import engine.gpu.text;
import engine.graphics.material : Material, MaterialParams;
import engine.graphics.material_pool : MaterialHandle, MaterialPool;
import engine.graphics.model : GltfAsset, GltfLoadOptions, ModelInstance, drawModel, loadGltfAsset;
import engine.graphics.texmesh : TexMesh;
import engine.graphics.texture : Texture, Sampler, SamplerDesc, TextureFilter, TextureWrap;
import engine.graphics.types : Color4;
import engine.math.mat : Mat4;
import engine.math.vec : Vec3;
import engine.platform.input : Key;
import engine.scene.camera : Camera;
import engine.scene.light : GpuPointLight, GpuSpotLight, LightSet;
import engine.scene.scene3d_textured : Scene3DTextured, RenderStats;
import engine.scene.static_instances : StaticBuildOptions, StaticInstanceBuffer, StaticInstanceDesc;

@safe:

private enum W = 1280;
private enum H = 720;
private enum WORLD = 3000.0f;
private enum VEHICLES = 200;
private enum PATH_RADIUS = 900.0f;

private struct Options {
    uint props = 12_000;
    uint headlessFrames = 0;
    bool assertNoGc = false;
    bool noCull = false;
    bool debugCascades = false;
    bool fog = false;
    /// Time of day in hours (< 0 = legacy fixed light, no sky).
    float tod = -1;
    bool rain = false;
    /// Override surface wetness (< 0 = from weather).
    float wetness = -1;
    bool noEnvFog = false;
    string screenshot;
}

private Options parseArgs(string[] args) {
    import std.algorithm.searching : startsWith;
    Options o;
    foreach (a; args[1 .. $]) {
        if (a.startsWith("--props=")) o.props = a["--props=".length .. $].to!uint;
        else if (a.startsWith("--headless-frames=")) o.headlessFrames = a["--headless-frames=".length .. $].to!uint;
        else if (a == "--assert-no-gc") o.assertNoGc = true;
        else if (a == "--no-cull") o.noCull = true;
        else if (a == "--debug-cascades") o.debugCascades = true;
        else if (a == "--fog") o.fog = true;
        else if (a.startsWith("--tod=")) o.tod = a["--tod=".length .. $].to!float;
        else if (a == "--rain") o.rain = true;
        else if (a.startsWith("--wetness=")) o.wetness = a["--wetness=".length .. $].to!float;
        else if (a == "--no-env-fog") o.noEnvFog = true;
        else if (a.startsWith("--screenshot=")) o.screenshot = a["--screenshot=".length .. $];
    }
    return o;
}

/// Deterministic xorshift32.
private struct Rng {
    uint state = 0x9E3779B9;
    float next() nothrow @nogc {
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        return (state >> 8) * (1.0f / 16_777_216.0f);
    }
    float range(float lo, float hi) nothrow @nogc { return lo + (hi - lo) * next(); }
}

/// A small multi-node vehicle: root → body, cabin, two doors, four wheels.
/// Two meshes (painted box, tire box) share one unit-cube geometry.
private ubyte[] buildVehicleGlb() @trusted {
    float[] pos, nrm, uv;
    ushort[] idx;
    immutable float[3][6] normals = [[1, 0, 0], [-1, 0, 0], [0, 1, 0], [0, -1, 0], [0, 0, 1], [0, 0, -1]];
    foreach (f, n; normals) {
        // Two tangent axes for this face.
        float[3] u = n[1] != 0 ? [1.0f, 0, 0] : [0, 1.0f, 0];
        float[3] v = [n[1] * u[2] - n[2] * u[1], n[2] * u[0] - n[0] * u[2], n[0] * u[1] - n[1] * u[0]];
        immutable base = cast(ushort)(pos.length / 3);
        foreach (c; 0 .. 4) {
            immutable su = (c == 1 || c == 2) ? 0.5f : -0.5f;
            immutable sv = (c >= 2) ? 0.5f : -0.5f;
            foreach (k; 0 .. 3) pos ~= n[k] * 0.5f + u[k] * su + v[k] * sv;
            nrm ~= n[];
            uv ~= [su + 0.5f, sv + 0.5f];
        }
        idx ~= [base, cast(ushort)(base + 1), cast(ushort)(base + 2),
                base, cast(ushort)(base + 2), cast(ushort)(base + 3)];
    }
    // Wind every face counter-clockwise when seen from outside.
    foreach (t; 0 .. idx.length / 3) {
        immutable a = idx[t * 3], b = idx[t * 3 + 1], c = idx[t * 3 + 2];
        float[3] e1, e2;
        foreach (k; 0 .. 3) { e1[k] = pos[b * 3 + k] - pos[a * 3 + k]; e2[k] = pos[c * 3 + k] - pos[a * 3 + k]; }
        immutable float[3] cr = [e1[1] * e2[2] - e1[2] * e2[1], e1[2] * e2[0] - e1[0] * e2[2], e1[0] * e2[1] - e1[1] * e2[0]];
        if (cr[0] * nrm[a * 3] + cr[1] * nrm[a * 3 + 1] + cr[2] * nrm[a * 3 + 2] < 0) {
            idx[t * 3 + 1] = c;
            idx[t * 3 + 2] = b;
        }
    }
    ubyte[] bin = cast(ubyte[]) pos.dup ~ cast(ubyte[]) nrm.dup ~ cast(ubyte[]) uv.dup ~ cast(ubyte[]) idx.dup;
    immutable pBytes = pos.length * 4, nBytes = nrm.length * 4, uBytes = uv.length * 4, iBytes = idx.length * 2;
    string json = `{
      "asset":{"version":"2.0"},
      "scene":0,
      "scenes":[{"nodes":[0]}],
      "buffers":[{"byteLength":` ~ bin.length.to!string ~ `}],
      "bufferViews":[
        {"buffer":0,"byteOffset":0,"byteLength":` ~ pBytes.to!string ~ `},
        {"buffer":0,"byteOffset":` ~ pBytes.to!string ~ `,"byteLength":` ~ nBytes.to!string ~ `},
        {"buffer":0,"byteOffset":` ~ (pBytes + nBytes).to!string ~ `,"byteLength":` ~ uBytes.to!string ~ `},
        {"buffer":0,"byteOffset":` ~ (pBytes + nBytes + uBytes).to!string ~ `,"byteLength":` ~ iBytes.to!string ~ `}
      ],
      "accessors":[
        {"bufferView":0,"componentType":5126,"count":24,"type":"VEC3","min":[-0.5,-0.5,-0.5],"max":[0.5,0.5,0.5]},
        {"bufferView":1,"componentType":5126,"count":24,"type":"VEC3"},
        {"bufferView":2,"componentType":5126,"count":24,"type":"VEC2"},
        {"bufferView":3,"componentType":5123,"count":36,"type":"SCALAR"}
      ],
      "materials":[
        {"name":"paint","pbrMetallicRoughness":{"baseColorFactor":[0.75,0.12,0.1,1],"metallicFactor":0.4,"roughnessFactor":0.35}},
        {"name":"tire","pbrMetallicRoughness":{"baseColorFactor":[0.04,0.04,0.045,1],"metallicFactor":0.0,"roughnessFactor":0.9}}
      ],
      "meshes":[
        {"name":"paint_box","primitives":[{"attributes":{"POSITION":0,"NORMAL":1,"TEXCOORD_0":2},"indices":3,"material":0}]},
        {"name":"tire_box","primitives":[{"attributes":{"POSITION":0,"NORMAL":1,"TEXCOORD_0":2},"indices":3,"material":1}]}
      ],
      "nodes":[
        {"name":"vehicle","children":[1,2,3,4,5,6,7,8]},
        {"name":"body","mesh":0,"translation":[0,0.9,0],"scale":[2,0.8,4.2]},
        {"name":"cabin","mesh":0,"translation":[0,1.6,-0.3],"scale":[1.8,0.7,2.2]},
        {"name":"door_l","mesh":0,"translation":[-1.03,0.95,0.2],"scale":[0.06,0.65,1.4]},
        {"name":"door_r","mesh":0,"translation":[1.03,0.95,0.2],"scale":[0.06,0.65,1.4]},
        {"name":"wheel_fl","mesh":1,"translation":[-1.05,0.4,1.4],"scale":[0.3,0.8,0.8]},
        {"name":"wheel_fr","mesh":1,"translation":[1.05,0.4,1.4],"scale":[0.3,0.8,0.8]},
        {"name":"wheel_rl","mesh":1,"translation":[-1.05,0.4,-1.4],"scale":[0.3,0.8,0.8]},
        {"name":"wheel_rr","mesh":1,"translation":[1.05,0.4,-1.4],"scale":[0.3,0.8,0.8]}
      ]
    }`;
    return buildGlb(json, bin);
}

private struct Vehicle {
    ModelInstance inst;
    float angle;
    float radius;
    float speed;
    float doorPhase;
}

void main(string[] args) @trusted {
    import std.file : mkdirRecurse, write;

    immutable opts = parseArgs(args);
    immutable headless = opts.headlessFrames > 0;
    auto app = App.create("Open-World Bench — OW-2", W, H);

    auto scene = Scene3DTextured.create(app.gpu);
    scope(exit) scene.destroy();
    scene.setLodScreenHeight(H);
    scene.setCulling(!opts.noCull);
    auto layout = scene.materialLayout();

    SamplerDesc sd;
    sd.filter = TextureFilter.linear;
    sd.wrap = TextureWrap.repeat;
    sd.maxAnisotropy = 8;
    auto sampler = Sampler.create(app.gpu, sd);
    scope(exit) sampler.destroy();

    // ---- Static rocks --------------------------------------------------
    GltfLoadOptions lo;
    lo.generateLods = true;
    lo.lodSettings.maxLods = 4;
    immutable string[3] rockFiles = [
        "assets/models/rock_cliff.gltf", "assets/models/rock_boulder.gltf", "assets/models/rock_cobble.gltf"];
    immutable float[2][3] rockScale = [[2.0f, 6.0f], [1.0f, 3.0f], [0.6f, 1.6f]];
    GltfAsset[3] rocks;
    foreach (i, f; rockFiles) rocks[i] = loadGltfAsset(app.gpu, f, layout, sampler, lo);
    scope(exit) foreach (ref r; rocks) r.destroy();

    TexMesh*[] meshes;
    Material*[] mats;
    foreach (ref r; rocks) {
        meshes ~= &r.subMeshes[0];
        mats ~= r.materialPtr(0);
        info("rock LOD levels: ", r.subMeshes[0].lodCount());
    }

    Rng rng;
    StaticInstanceDesc[] descs;
    descs.reserve(opts.props);
    foreach (i; 0 .. opts.props) {
        // Cobbles are the most common, cliffs the rarest.
        immutable r = rng.next();
        immutable uint m = r < 0.15f ? 0 : (r < 0.5f ? 1 : 2);
        immutable s = rng.range(rockScale[m][0], rockScale[m][1]);
        immutable x = rng.range(-WORLD * 0.5f, WORLD * 0.5f);
        immutable z = rng.range(-WORLD * 0.5f, WORLD * 0.5f);
        immutable model = Mat4.translation(x, s * 0.3f, z) * Mat4.rotationY(rng.range(0, 2 * PI))
                        * Mat4.scaling(s, s, s);
        descs ~= StaticInstanceDesc(m, m, model);
    }
    StaticBuildOptions sbo;
    sbo.cellSize = 128;
    sbo.maxDistance = 1600;
    sbo.minPixelSize = 1.5f;
    auto rocksBuf = StaticInstanceBuffer.build(app.gpu, meshes, mats, descs, sbo);
    scope(exit) rocksBuf.destroy();
    rocksBuf.setMeshCull(2, 700, 2); // cobbles vanish sooner

    // ---- Ground ---------------------------------------------------------
    auto ground = TexMesh.quad(app.gpu);
    scope(exit) ground.destroy();
    auto groundTex = Texture.checker(app.gpu, 128, [72, 84, 60, 255], [64, 76, 54, 255]);
    scope(exit) groundTex.destroy();
    auto groundMat = Material.create(app.gpu, layout, sampler, groundTex);
    scope(exit) groundMat.destroy();

    // ---- Dynamic vehicles ----------------------------------------------
    mkdirRecurse("build");
    write("build/openworld_vehicle.glb", buildVehicleGlb());
    GltfLoadOptions vo;
    vo.generateLods = false;
    auto vehicle = loadGltfAsset(app.gpu, "build/openworld_vehicle.glb", layout, sampler, vo);
    scope(exit) vehicle.destroy();
    immutable doorL = vehicle.findNode("door_l");
    immutable doorR = vehicle.findNode("door_r");
    immutable bodyNode = vehicle.findNode("body");
    assert(doorL >= 0 && doorR >= 0 && bodyNode >= 0, "vehicle fixture nodes missing");
    immutable paintSubMesh = vehicle.nodes[bodyNode].firstSubMesh;

    auto whiteTex = Texture.solid(app.gpu, 255, 255, 255, 255);
    scope(exit) whiteTex.destroy();
    auto pool = MaterialPool.create(16);
    scope(exit) pool.destroy();
    MaterialHandle[3] paints;
    immutable float[3][3] paintColors = [[0.1f, 0.25f, 0.8f], [0.1f, 0.6f, 0.2f], [0.9f, 0.75f, 0.1f]];
    foreach (i, c; paintColors) {
        MaterialParams p;
        p.baseColor = c;
        p.baseMetalness = 0.5f;
        p.specularRoughness = 0.3f;
        auto m = Material.create(app.gpu, layout, sampler, whiteTex, p, null, null, null, null);
        paints[i] = pool.add(m);
    }

    Vehicle[VEHICLES] vehicles;
    foreach (i, ref v; vehicles) {
        v.angle = rng.range(0, 2 * PI);
        v.radius = PATH_RADIUS + rng.range(-40, 40);
        v.speed = rng.range(8, 20) / v.radius; // rad/s
        v.doorPhase = rng.range(0, 2);
        if (i % 4 != 0) v.inst.setMaterialOverride(paintSubMesh, paints[i % 3]);
    }

    // ---- Camera / lights / overlay -------------------------------------
    auto camera = Camera.create(0.9f, W, H, 0.5f, 4000.0f);
    immutable lightDir = Vec3(0.4f, 1.0f, 0.3f);
    auto text = TextRenderer.create(app.gpu, W, H);
    scope(exit) text.destroy();
    auto fps = FpsCounter.create();

    // Optional day/night + weather + engine sky + runtime HDR IBL.
    immutable bool envMode = opts.tod >= 0;
    TimeOfDay tod;
    tod.hours = envMode ? opts.tod : 10;
    tod.dayLengthSec = 0;
    Weather weather;
    if (opts.rain) {
        weather.setTarget(0.95f, 1.0f);
        weather.cloudCoverage = 0.95f;
        weather.rainIntensity = 1.0f;
        weather.wetness = 1.0f;
    }
    DynamicIbl dynIbl;
    if (envMode) {
        scene.setSkyEnabled(true);
        dynIbl = DynamicIbl.create(app.gpu, scene.iblLayout());
        auto env0 = evaluateEnvironment(tod, weather);
        auto p0 = skyIblParams(env0, 0);
        dynIbl.bakeNow(p0);
    }
    scope(exit) if (envMode) dynIbl.destroy();

    info("Open-world bench: ", opts.props, " static props, ", VEHICLES, " vehicles, ",
         rocksBuf.rangeCount(), " static ranges");

    // ---- Frame loop ----------------------------------------------------
    enum WARMUP = 5;
    immutable totalFrames = headless ? opts.headlessFrames + WARMUP : uint.max;
    size_t gcBefore = 0;
    ulong[4] lodTotals;
    ulong visibleTotal = 0, drawTotal = 0, shadowTotal = 0, shadowDrawTotal = 0;
    uint measuredFrames = 0;
    float maxFrameMs = 0;
    MonoTime measureStart;
    char[256] line = void;
    float time = 0;

    for (uint frameNo = 0; frameNo < totalFrames && app.running(); frameNo++) {
        if (headless && frameNo == WARMUP) {
            if (opts.assertNoGc) {
                GC.collect();
                gcBefore = GC.stats().allocatedInCurrentThread;
            }
            measureStart = MonoTime.currTime;
        }
        immutable frameStart = MonoTime.currTime;

        app.pollEvents();
        immutable realDt = fps.tick();
        immutable dt = headless ? 1.0f / 60.0f : realDt;
        time += dt;
        if (app.input.keyPressed(Key.escape)) break;

        // Fly along the ring, climbing periodically to show far LODs.
        immutable a = time * 0.05f;
        immutable alt = 25.0f + 140.0f * (0.5f - 0.5f * cos(time * 0.3f));
        immutable eye = Vec3(cos(a) * PATH_RADIUS, alt, sin(a) * PATH_RADIUS);
        immutable ahead = Vec3(cos(a + 0.12f) * PATH_RADIUS, alt * 0.4f, sin(a + 0.12f) * PATH_RADIUS);
        camera.lookAt(eye, ahead);

        LightSet lights;
        lights.dirEnabled = true;
        lights.dir.direction = lightDir;
        lights.dir.viewProj = directionalLightVP(lightDir, Vec3(ahead.x, 0, ahead.z), 160.0f);
        lights.dir.color = Vec3(1.0f, 0.97f, 0.9f);
        lights.dir.intensity = 2.5f;
        lights.dir.castShadows = true;
        lights.dir.debugCascades = opts.debugCascades;
        FogSettings envFog;
        if (envMode) {
            tod.advance(dt);
            weather.update(dt);
            if (opts.wetness >= 0) weather.wetness = opts.wetness;
            auto env = evaluateEnvironment(tod, weather);
            applyEnvironment(env, lights, envFog, 0.0015f);
            envFog.enabled = !opts.noEnvFog;
            envFog.heightFalloff = 0.01f;
            applyEnvironmentToScene(env, scene);
            scene.setFog(envFog);
            auto p = skyIblParams(env, time);
            dynIbl.request(p);
            dynIbl.update();
            scene.setEnvironmentBindGroup(dynIbl.bindGroup());
        }
        lights.shadowBias = 0.0006f;
        // Local shadow casters around the vehicle stream ahead of the camera.
        lights.points[0] = GpuPointLight(Vec3(ahead.x, 6, ahead.z), Vec3(1.0f, 0.6f, 0.3f), 30.0f, 40.0f, true);
        lights.pointCount = 1;
        GpuSpotLight spot;
        spot.position = Vec3(eye.x, eye.y + 2, eye.z);
        spot.direction = (Vec3(ahead.x, 0, ahead.z) - spot.position).normalized();
        spot.color = Vec3(0.6f, 0.8f, 1.0f);
        spot.intensity = 40.0f;
        spot.range = 250.0f;
        spot.innerConeDeg = 15.0f;
        spot.outerConeDeg = 25.0f;
        spot.castShadows = true;
        lights.spots[0] = spot;
        lights.spotCount = 1;

        auto frame = app.beginFrame(Color4(0.45f, 0.6f, 0.8f, 1));
        if (!frame.valid) continue;

        if (opts.fog) {
            FogSettings fog;
            fog.enabled = true;
            fog.color = Vec3(0.55f, 0.66f, 0.8f);
            fog.density = 0.004f;
            fog.heightFalloff = 0.02f;
            scene.setFog(fog);
        }
        scene.begin(camera);
        scene.drawMatrix(ground, groundMat, Mat4.scaling(WORLD, 1, WORLD), Color4.white);
        scene.submitStatic(rocksBuf);
        foreach (i, ref v; vehicles) {
            v.angle += v.speed * dt;
            immutable doorsOpen = ((time + v.doorPhase) % 4.0f) < 2.0f;
            v.inst.setNodeVisible(doorL, !doorsOpen);
            v.inst.setNodeVisible(doorR, !doorsOpen || (i & 1));
            immutable world = Mat4.translation(cos(v.angle) * v.radius, 0, sin(v.angle) * v.radius)
                            * Mat4.rotationY(-v.angle);
            drawModel(scene, vehicle, v.inst, world, pool);
        }
        scene.renderShadows(frame, lights);
        scene.end(frame);
        app.resolvePost(frame);

        immutable RenderStats st = scene.stats();
        import std.format : sformat;
        text.beginFrame();
        text.drawText(frame, sformat(line[], "FPS %.0f  draws %u (+%u shadow, %u casters)  static %u/%u  dynamic %u/%u",
            fps.fps, st.drawCalls, st.shadowDrawCalls, st.shadowInstancesDrawn, st.staticInstancesVisible,
            rocksBuf.length(), st.instancesVisible, st.instancesSubmitted), 16, 16, 2);
        text.drawText(frame, sformat(line[], "LOD0 %u  LOD1 %u  LOD2 %u  LOD3+ %u   ranges %u",
            st.lodHistogram[0], st.lodHistogram[1], st.lodHistogram[2], st.lodHistogram[3],
            st.staticRangesDrawn), 16, 44, 2);
        if (opts.screenshot.length && frameNo + 1 == totalFrames) app.saveScreenshot(opts.screenshot);
        app.endFrame(frame);

        if (headless && frameNo >= WARMUP) {
            foreach (l; 0 .. 4) lodTotals[l] += st.lodHistogram[l];
            visibleTotal += st.staticInstancesVisible + st.instancesVisible;
            drawTotal += st.drawCalls;
            shadowTotal += st.shadowInstancesDrawn;
            shadowDrawTotal += st.shadowDrawCalls;
            measuredFrames++;
            immutable ms = (MonoTime.currTime - frameStart).total!"usecs" / 1000.0f;
            if (ms > maxFrameMs) maxFrameMs = ms;
        }
    }

    int exitCode = 0;
    if (headless) {
        immutable gcDelta = opts.assertNoGc ? GC.stats().allocatedInCurrentThread - gcBefore : 0;
        immutable elapsedMs = (MonoTime.currTime - measureStart).total!"usecs" / 1000.0;
        immutable n = measuredFrames > 0 ? measuredFrames : 1;
        writefln("openworld-bench: %u frames, %u static props, %u vehicles", measuredFrames,
                 rocksBuf.length(), VEHICLES);
        writefln("  avg frame %.2f ms, max %.2f ms", elapsedMs / n, maxFrameMs);
        writefln("  avg draws %.1f, avg visible instances %.1f", cast(double) drawTotal / n,
                 cast(double) visibleTotal / n);
        writefln("  avg shadow draws %.1f, avg dynamic shadow casters %.1f (dir + 6 point faces + spot)%s",
                 cast(double) shadowDrawTotal / n, cast(double) shadowTotal / n, opts.noCull ? " [no-cull]" : "");
        writefln("  LOD instance-frames: LOD0 %u  LOD1 %u  LOD2 %u  LOD3+ %u",
                 lodTotals[0], lodTotals[1], lodTotals[2], lodTotals[3]);
        if (opts.assertNoGc) {
            writefln("  GC allocations over %u frames: %u bytes", measuredFrames, gcDelta);
            if (gcDelta != 0) {
                err("openworld-bench: GC allocated in the frame loop");
                exitCode = 1;
            }
        }
        if (lodTotals[0] == 0 || lodTotals[1] == 0 || lodTotals[2] == 0) {
            err("openworld-bench: expected LOD0, LOD1 and LOD2 to be used");
            exitCode = 1;
        }
    }

    vehicle.destroy();
    foreach (ref r; rocks) r.destroy();
    app.destroy();
    if (exitCode != 0) {
        import core.stdc.stdlib : exit;
        exit(exitCode);
    }
}
