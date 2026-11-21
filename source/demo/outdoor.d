/**
 * OW-3 outdoor demo / perf gate: procedural chunked terrain (4 biomes by
 * height and slope) with cascaded shadows, height fog, engine sky,
 * day/night cycle with rain and wetness, runtime HDR IBL, Box3D terrain
 * colliders and thousands of instanced rocks placed on the surface.
 *
 * Usage:
 *   dub run --config=outdoor
 *   dub run --config=outdoor -- --headless-frames=600 --assert-no-gc
 *
 * Options:
 *   --size=N          chunks per side (128 m each at 1 m cells; default 24 = 3 km)
 *   --cell=M          meters between height samples (default 1)
 *   --props=N         instanced rocks (default 12000)
 *   --decals=N        projected decals (default 500)
 *   --tod=H           start time of day in hours (default 9.5)
 *   --time-scale=S    in-game seconds per real second multiplier (default 1; 0 freezes)
 *   --rain            start in a storm (clouds, rain, wet surfaces)
 *   --debug-cascades  tint the shadow cascades
 *   --view=N          camera preset (0 = orbit path, 1 = low over a ridge, 2 = high overview)
 *   --headless-frames=N --assert-no-gc --screenshot=PATH
 */
module demo.outdoor;

import core.memory : GC;
import core.time : MonoTime;
import std.conv : to;
import std.math : sin, cos, PI;
import std.stdio : writefln;

import engine.app;
import engine.core.log;
import engine.gpu.ibl_dynamic : DynamicIbl;
import engine.gpu.text;
import engine.graphics.decals : DecalRenderer, DecalStyle, DecalSystem, proceduralDecalLayers;
import engine.graphics.material : Material;
import engine.math.vec : Vec2;
import engine.graphics.model : GltfAsset, GltfLoadOptions, loadGltfAsset;
import engine.graphics.texmesh : TexMesh;
import engine.graphics.texture : Sampler, SamplerDesc, TextureFilter, TextureWrap;
import engine.graphics.types : Color4;
import engine.math.mat : Mat4;
import engine.math.vec : Vec3;
import engine.physics.queries : castRayClosest;
import engine.physics.world : PhysicsWorld;
import engine.platform.input : Key;
import engine.scene.atmosphere : FogSettings;
import engine.scene.camera : Camera;
import engine.scene.light : LightSet;
import engine.scene.scene3d_textured : RenderStats, Scene3DTextured;
import engine.scene.static_instances : StaticBuildOptions, StaticInstanceBuffer, StaticInstanceDesc;
import engine.scene.time_of_day : applyEnvironment, applyEnvironmentToScene, evaluateEnvironment,
    skyIblParams, TimeOfDay, Weather;
import engine.terrain;

@safe:

private enum W = 1280;
private enum H = 720;

private struct Options {
    uint size = 24;
    float cell = 1.0f;
    uint props = 12_000;
    uint decals = 500;
    float tod = 9.5f;
    float timeScale = 1.0f;
    bool rain = false;
    bool debugCascades = false;
    uint view = 0;
    uint headlessFrames = 0;
    bool assertNoGc = false;
    string screenshot;
}

private Options parseArgs(string[] args) {
    import std.algorithm.searching : startsWith;
    Options o;
    foreach (a; args[1 .. $]) {
        string v(string p) { return a[p.length .. $]; }
        if (a.startsWith("--size=")) o.size = v("--size=").to!uint;
        else if (a.startsWith("--cell=")) o.cell = v("--cell=").to!float;
        else if (a.startsWith("--props=")) o.props = v("--props=").to!uint;
        else if (a.startsWith("--decals=")) o.decals = v("--decals=").to!uint;
        else if (a.startsWith("--tod=")) o.tod = v("--tod=").to!float;
        else if (a.startsWith("--time-scale=")) o.timeScale = v("--time-scale=").to!float;
        else if (a == "--rain") o.rain = true;
        else if (a == "--debug-cascades") o.debugCascades = true;
        else if (a.startsWith("--view=")) o.view = v("--view=").to!uint;
        else if (a.startsWith("--headless-frames=")) o.headlessFrames = v("--headless-frames=").to!uint;
        else if (a == "--assert-no-gc") o.assertNoGc = true;
        else if (a.startsWith("--screenshot=")) o.screenshot = v("--screenshot=");
    }
    if (o.size < 1) o.size = 1;
    return o;
}

/// Deterministic xorshift32.
private struct Rng {
    uint state = 0x2545F491;
    float next() nothrow @nogc {
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        return (state >> 8) * (1.0f / 16_777_216.0f);
    }
    float range(float lo, float hi) nothrow @nogc { return lo + (hi - lo) * next(); }
}

void main(string[] args) @trusted {
    immutable opts = parseArgs(args);
    immutable headless = opts.headlessFrames > 0;
    auto app = App.create("Outdoor — OW-3", W, H);

    auto scene = Scene3DTextured.create(app.gpu);
    scope(exit) scene.destroy();
    scene.setLodScreenHeight(H);
    scene.setSkyEnabled(true);

    // ---- Terrain -------------------------------------------------------
    immutable t0 = MonoTime.currTime;
    TerrainDesc td;
    td.chunkCells = 128;
    td.samplesX = opts.size * td.chunkCells + 1;
    td.samplesZ = td.samplesX;
    td.cellSize = opts.cell;
    immutable worldSize = (td.samplesX - 1) * td.cellSize;
    td.origin = Vec3(-worldSize * 0.5f, 0, -worldSize * 0.5f);
    td.minHeight = -20;
    td.maxHeight = 480;
    TerrainGenSettings gs;
    gs.flatRadius = 0;
    gs.mountainCoverage = 0.45f;
    gs.baseWavelength = 900.0f * (worldSize / 3072.0f > 0.25f ? worldSize / 3072.0f : 0.25f);
    auto heights = generateHeights(td, gs);
    immutable splatRes = td.samplesX - 1 > 1024 ? 1024 : td.samplesX - 1;
    auto splat = generateBiomeSplat(heights, splatRes, splatRes);
    TerrainLodSettings lodSettings;
    lodSettings.lod0Distance = 140.0f * td.cellSize;
    auto terrain = Terrain.create(heights, splat, lodSettings);

    enum LAYER_TEX = 512;
    TerrainLayer[4] layers;
    const(ubyte)[][4] alb, nrm, orm;
    immutable float[4] uvScales = [0.22f, 0.08f, 0.18f, 0.12f];
    foreach (i; 0 .. 4) {
        ubyte[] a, n, o;
        generateLayerTextures(cast(BiomeLayer) i, LAYER_TEX, a, n, o);
        alb[i] = a; nrm[i] = n; orm[i] = o;
        layers[i].uvScale = uvScales[i];
        layers[i].physicsMaterial = cast(ubyte)(i + 1);
        layers[i].triplanarSharpness = i == BiomeLayer.rock ? 6.0f : 0.0f;
    }
    layers[BiomeLayer.sand].friction = 0.6f;
    layers[BiomeLayer.snow].friction = 0.3f;
    auto terrainMat = TerrainMaterial.create(app.gpu, layers[], alb[], nrm[], orm[], LAYER_TEX);
    scope(exit) terrainMat.destroy();
    auto terrainRenderer = TerrainRenderer.create(app.gpu, scene, terrain, terrainMat);
    terrainRenderer.attach(scene, terrain);
    scope(exit) terrainRenderer.destroy();

    auto physics = PhysicsWorld.createDefault();
    immutable tiles = buildTerrainColliders(physics, terrain, layers[]);
    info("Outdoor: terrain ", worldSize, " m, ", tiles, " collider tiles, built in ",
         (MonoTime.currTime - t0).total!"msecs", " ms");

    // ---- Rocks on the surface ------------------------------------------
    SamplerDesc sd;
    sd.filter = TextureFilter.linear;
    sd.wrap = TextureWrap.repeat;
    sd.maxAnisotropy = 8;
    auto sampler = Sampler.create(app.gpu, sd);
    scope(exit) sampler.destroy();
    GltfLoadOptions lo;
    lo.generateLods = true;
    lo.lodSettings.maxLods = 4;
    immutable string[3] rockFiles = [
        "assets/models/rock_cliff.gltf", "assets/models/rock_boulder.gltf", "assets/models/rock_cobble.gltf"];
    immutable float[2][3] rockScale = [[2.0f, 6.0f], [1.0f, 3.0f], [0.6f, 1.6f]];
    GltfAsset[3] rocks;
    foreach (i, f; rockFiles) rocks[i] = loadGltfAsset(app.gpu, f, scene.materialLayout(), sampler, lo);
    scope(exit) foreach (ref r; rocks) r.destroy();
    TexMesh*[] meshes;
    Material*[] mats;
    foreach (ref r; rocks) {
        meshes ~= &r.subMeshes[0];
        mats ~= r.materialPtr(0);
    }
    Rng rng;
    StaticInstanceDesc[] descs;
    descs.reserve(opts.props);
    immutable half = worldSize * 0.5f - 4;
    while (descs.length < opts.props) {
        immutable x = rng.range(-half, half), z = rng.range(-half, half);
        immutable layer = terrain.layerAt(x, z);
        if (layer == BiomeLayer.snow || (layer == BiomeLayer.sand && rng.next() < 0.7f)) continue;
        immutable r = rng.next();
        immutable uint m = r < 0.15f ? 0 : (r < 0.5f ? 1 : 2);
        immutable s = rng.range(rockScale[m][0], rockScale[m][1]);
        immutable y = terrain.heightAt(x, z);
        descs ~= StaticInstanceDesc(m, m, Mat4.translation(x, y + s * 0.15f, z)
            * Mat4.rotationY(rng.range(0, 2 * PI)) * Mat4.scaling(s, s, s));
    }
    StaticBuildOptions sbo;
    sbo.cellSize = 128;
    sbo.maxDistance = 1600;
    sbo.minPixelSize = 1.5f;
    auto rocksBuf = StaticInstanceBuffer.build(app.gpu, meshes, mats, descs, sbo);
    scope(exit) rocksBuf.destroy();
    rocksBuf.setMeshCull(2, 700, 2);

    // ---- Decals ------------------------------------------------------------
    // Skid marks, impact cracks, mud and painted arrows around the camera
    // presets and along the orbit path, projected along the terrain normal.
    immutable decalCap = opts.decals > 0 ? opts.decals : 1;
    auto decals = DecalSystem.create(decalCap);
    ubyte[][4] decalAlb, decalNrm;
    proceduralDecalLayers(256, decalAlb, decalNrm);
    const(ubyte)[][4] da = decalAlb, dn = decalNrm;
    auto decalRenderer = DecalRenderer.create(app.gpu, scene, da[], dn[], 256, decalCap);
    decalRenderer.attach(scene, app.renderer, decals);
    scope(exit) decalRenderer.destroy();
    {
        immutable c = terrain.center();
        immutable pathRadius = worldSize * 0.3f;
        foreach (i; 0 .. opts.decals) {
            float x, z;
            if (i % 3 == 0) { // near the low-ridge preset
                x = c.x + 40 + rng.range(-60, 60);
                z = c.z + 220 - rng.range(0, 160);
            } else { // along the orbit path
                immutable a = rng.range(0, 2 * PI);
                immutable rr = pathRadius + rng.range(-40, 40);
                x = c.x + cos(a) * rr;
                z = c.z + sin(a) * rr;
            }
            immutable layer = cast(uint)(rng.next() * 4) & 3;
            immutable float[4] sizes = [3.0f, 2.5f, 4.0f, 3.0f];
            immutable sz = sizes[layer] * rng.range(0.7f, 1.6f);
            DecalStyle st;
            st.roughness = layer == 3 ? 0.5f : 0.85f;
            st.opacity = layer == 2 ? 0.9f : 1.0f;
            decals.spawn(Vec3(x, terrain.heightAt(x, z), z), terrain.normalAt(x, z),
                         Vec2(layer == 0 ? sz * 0.6f : sz, sz * (layer == 0 ? 2.5f : 1.0f)), 2.0f,
                         rng.range(0, 2 * PI), layer, st);
        }
    }

    // ---- Environment ---------------------------------------------------
    TimeOfDay tod;
    tod.hours = opts.tod;
    tod.dayLengthSec = 1440.0f; // 1 real minute per in-game hour
    Weather weather;
    if (opts.rain) {
        weather.setTarget(0.95f, 1.0f);
        weather.cloudCoverage = 0.95f;
        weather.rainIntensity = 1.0f;
        weather.wetness = 1.0f;
    }
    auto dynIbl = DynamicIbl.create(app.gpu, scene.iblLayout());
    scope(exit) dynIbl.destroy();
    {
        auto env0 = evaluateEnvironment(tod, weather);
        auto p0 = skyIblParams(env0, 0);
        dynIbl.bakeNow(p0);
    }

    auto camera = Camera.create(0.9f, W, H, 0.5f, 6000.0f);
    auto text = TextRenderer.create(app.gpu, W, H);
    scope(exit) text.destroy();
    auto fps = FpsCounter.create();

    enum WARMUP = 5;
    immutable totalFrames = headless ? opts.headlessFrames + WARMUP : uint.max;
    size_t gcBefore = 0;
    uint measuredFrames = 0;
    float maxFrameMs = 0;
    ulong drawTotal = 0, terrainDrawTotal = 0, shadowDrawTotal = 0;
    uint maxTerrainDraws = 0;
    MonoTime measureStart;
    char[256] line = void;
    float time = 0;
    immutable center = terrain.center();
    immutable pathR = worldSize * 0.3f;

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
        if (app.input.keyPressed(Key.r)) weather.setTarget(weather.targetRain > 0 ? 0.15f : 0.95f,
                                                           weather.targetRain > 0 ? 0.0f : 1.0f);

        // Camera.
        Vec3 eye, look;
        if (opts.view == 1) {
            eye = Vec3(center.x + 40, 0, center.z + 220);
            eye.y = terrain.heightAt(eye.x, eye.z) + 6;
            look = Vec3(center.x - 200, 0, center.z - 400);
            look.y = terrain.heightAt(look.x, look.z) + 20;
        } else if (opts.view == 2) {
            eye = Vec3(center.x - worldSize * 0.35f, 420, center.z - worldSize * 0.35f);
            look = Vec3(center.x, 60, center.z);
        } else {
            immutable a = time * 0.04f;
            eye = Vec3(center.x + cos(a) * pathR, 0, center.z + sin(a) * pathR);
            immutable ground = terrain.heightAt(eye.x, eye.z);
            eye.y = (ground > 0 ? ground : 0) + 30.0f + 90.0f * (0.5f - 0.5f * cos(time * 0.25f));
            look = Vec3(center.x + cos(a + 0.15f) * pathR, 0, center.z + sin(a + 0.15f) * pathR);
            look.y = terrain.heightAt(look.x, look.z) + 10;
        }
        camera.lookAt(eye, look);

        // Environment.
        tod.advance(dt * opts.timeScale);
        weather.update(dt);
        auto env = evaluateEnvironment(tod, weather);
        LightSet lights;
        FogSettings fog;
        applyEnvironment(env, lights, fog, 0.00028f);
        fog.enabled = true;
        fog.heightBase = 0;
        fog.heightFalloff = 0.004f;
        lights.dir.castShadows = true;
        lights.dir.debugCascades = opts.debugCascades;
        lights.dir.cascades.maxDistance = 500;
        lights.shadowBias = 0.0006f;
        applyEnvironmentToScene(env, scene);
        scene.setFog(fog);
        auto ip = skyIblParams(env, time);
        dynIbl.request(ip);
        dynIbl.update();
        scene.setEnvironmentBindGroup(dynIbl.bindGroup());

        auto frame = app.beginFrame(Color4(0.45f, 0.6f, 0.8f, 1));
        if (!frame.valid) continue;
        terrainRenderer.update(terrain, camera);
        decals.update(dt);
        decalRenderer.update(decals, camera);
        scene.begin(camera);
        scene.submitStatic(rocksBuf);
        scene.renderShadows(frame, lights);
        scene.end(frame);
        app.resolvePost(frame);

        immutable RenderStats st = scene.stats();
        immutable ts = terrainRenderer.stats();
        auto hit = castRayClosest(physics, Vec3(eye.x, eye.y + 1, eye.z), Vec3(0, -1, 0), 2000);
        import std.format : sformat;
        text.beginFrame();
        text.drawText(frame, sformat(line[], "FPS %.0f  %02d:%02d  draws %u (+%u shadow)  terrain %u chunks / %u draws (+%u shadow)",
            fps.fps, cast(int) tod.hours, cast(int)((tod.hours % 1.0f) * 60), st.drawCalls, st.shadowDrawCalls,
            ts.visibleChunks, ts.drawCalls, ts.shadowDrawCalls), 16, 16, 2);
        text.drawText(frame, sformat(line[], "rain %.2f  wet %.2f  clouds %.2f  ground layer %u  rocks %u/%u  decals %u  [R] rain",
            weather.rainIntensity, weather.wetness, weather.cloudCoverage,
            hit.hit ? cast(uint) hit.surfaceMaterialId : 0, st.staticInstancesVisible, rocksBuf.length(), decalRenderer.drawnCount()), 16, 44, 2);
        if (opts.screenshot.length && frameNo + 1 == totalFrames) app.saveScreenshot(opts.screenshot);
        app.endFrame(frame);

        if (headless && frameNo >= WARMUP) {
            measuredFrames++;
            drawTotal += st.drawCalls;
            terrainDrawTotal += ts.drawCalls;
            shadowDrawTotal += st.shadowDrawCalls + ts.shadowDrawCalls;
            if (ts.drawCalls > maxTerrainDraws) maxTerrainDraws = ts.drawCalls;
            immutable ms = (MonoTime.currTime - frameStart).total!"usecs" / 1000.0f;
            if (ms > maxFrameMs) maxFrameMs = ms;
        }
    }

    int exitCode = 0;
    if (headless) {
        immutable gcDelta = opts.assertNoGc ? GC.stats().allocatedInCurrentThread - gcBefore : 0;
        immutable elapsedMs = (MonoTime.currTime - measureStart).total!"usecs" / 1000.0;
        immutable n = measuredFrames > 0 ? measuredFrames : 1;
        writefln("outdoor: %u frames, terrain %.0f m (%u chunks), %u rocks", measuredFrames, worldSize,
                 terrain.chunks.chunkCount(), rocksBuf.length());
        writefln("  avg frame %.2f ms, max %.2f ms", elapsedMs / n, maxFrameMs);
        writefln("  avg scene draws %.1f, avg terrain draws %.2f (max %u), avg shadow draws %.1f",
                 cast(double) drawTotal / n, cast(double) terrainDrawTotal / n, maxTerrainDraws,
                 cast(double) shadowDrawTotal / n);
        if (maxTerrainDraws > 6) {
            err("outdoor: terrain exceeded 6 draw calls");
            exitCode = 1;
        }
        if (opts.assertNoGc) {
            writefln("  GC allocations over %u frames: %u bytes", measuredFrames, gcDelta);
            if (gcDelta != 0) {
                err("outdoor: GC allocated in the frame loop");
                exitCode = 1;
            }
        }
    }
    app.destroy();
    if (exitCode != 0) {
        import core.stdc.stdlib : exit;
        exit(exitCode);
    }
}
