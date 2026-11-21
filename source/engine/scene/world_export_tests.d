/**
 * Integration tests for worlds written by `tools/blender_export_scene.py`.
 *
 * `assets/world/ow8_test_level*` is the exporter's generated multi-biome
 * test level (`--build-test-level`: forest, desert and snow biomes over
 * 3 × 3 cells of 256 m, a Bezier main road, a closed traffic loop, a river
 * and a sun). Regenerate it with:
 *
 * ---
 * blender -b --factory-startup -P tools/blender_export_scene.py -- --build-test-level
 * ---
 */
module engine.scene.world_export_tests;

@safe:

version (unittest):

import std.file : exists;
import engine.assets.asset_file : loadAssetFile;
import engine.assets.gltf : parseGltfDocument;
import engine.ecs.scene_world : SceneWorld;
import engine.editor.components : PhysicsBody, Visual;
import engine.math.vec : Vec3;
import engine.scene.graph : Transform;
import engine.scene.scene_file : SceneFile, loadSceneFile, validateScene;
import engine.scene.splines : loadSplineSetFile, sceneSplineSetPath;
import engine.scene.streamer : WorldStreamer;

private enum rootScenePath = "assets/world/ow8_test_level.scene.json";

@("worldExport.blenderTestLevelIsValid") @trusted unittest {
    if (!exists(rootScenePath)) return; // asset not checked out
    auto root = loadSceneFile(rootScenePath);
    assert(root.schemaVersion == 2);
    assert(validateScene(root, true).ok);
    assert(root.hasChunkManifest && root.chunkManifest.cellSize == 256);
    assert(root.chunkManifest.chunks.length == 9);
    assert(root.chunkManifest.unloadRadius > root.chunkManifest.loadRadius);

    // Root scene: the sun only; everything else is streamed.
    assert(root.entities.length == 1 && root.entities[0].hasLight);
    assert(root.entities[0].light.type == "directional");

    // Road / traffic / river splines linked from the root scene.
    immutable splinesPath = sceneSplineSetPath(root);
    assert(splinesPath.length && exists(splinesPath));
    auto splines = loadSplineSetFile(splinesPath);
    assert(splines.paths.length == 3);
    assert(splines.countRole("road") == 1 && splines.countRole("traffic") == 1
        && splines.countRole("river") == 1);
    auto road = splines.find("main_road");
    assert(road !is null && road.curve.length > 700 && road.width == 9 && road.lanes == 2);
    assert(splines.find("desert_loop").curve.closed);
    // Blender (x, y, z) -> engine (x, z, -y): the road runs at engine z ≈ 380 m.
    immutable mid = road.curve.sampleAtDistance(road.curve.length / 2);
    assert(mid.z > 300 && mid.z < 460 && mid.y > -5 && mid.y < 5);

    // Every chunk: valid v2 scene, entities inside their cell, loadable models.
    bool[string] checkedAssets;
    size_t dynamicBodies;
    foreach (ref ch; root.chunkManifest.chunks) {
        auto sf = loadSceneFile(ch.scenePath);
        assert(sf.schemaVersion == 2 && sf.hasCellBounds);
        auto v = validateScene(sf, true);
        assert(v.ok, ch.scenePath);
        foreach (ref e; sf.entities) {
            immutable p = e.transform.pos;
            assert(p[0] >= ch.bounds.min[0] && p[0] < ch.bounds.max[0], ch.scenePath);
            assert(p[2] >= ch.bounds.min[2] && p[2] < ch.bounds.max[2], ch.scenePath);
            assert(p[1] >= ch.bounds.min[1] && p[1] <= ch.bounds.max[1], ch.scenePath);
            if (e.hasPhysics && e.physics.motion == "dynamic") {
                assert(e.physics.shape == "convexHull");
                dynamicBodies++;
            }
            if (!e.hasVisual || !e.visual.hasAsset) continue;
            immutable assetPath = sf.strings[e.visual.asset];
            if (assetPath in checkedAssets) continue;
            checkedAssets[assetPath] = true;
            auto asset = loadAssetFile(assetPath);
            immutable glb = asset.renderGltfPath();
            assert(exists(glb), glb);
            auto doc = parseGltfDocument(glb);
            assert("meshes" in doc.root);
            assert(asset.hullPoints().length > 0);
        }
    }
    assert(checkedAssets.length == 7);
    assert(dynamicBodies == 4);
}

@("worldExport.blenderTestLevelStreamsThroughWorldStreamer") @trusted unittest {
    if (!exists(rootScenePath)) return;
    auto root = loadSceneFile(rootScenePath);
    size_t expectedEntities;
    foreach (ref ch; root.chunkManifest.chunks)
        expectedEntities += loadSceneFile(ch.scenePath).entities.length;

    SceneWorld world;
    world.ensureRegistered!Transform();
    world.ensureRegistered!Visual();
    world.ensureRegistered!PhysicsBody();

    WorldStreamer streamer;
    streamer.initFromManifest(root.chunkManifest);
    assert(streamer.cells.length == 9);

    // From the map centre every cell centre is within the 384 m load radius.
    foreach (_; 0 .. 32) {
        streamer.update(world, Vec3(384, 0, 384), 50.0f);
        if (streamer.stats().activeCount == 9) break;
    }
    assert(streamer.stats().activeCount == 9);
    assert(world.entityCount() == expectedEntities);
    assert(streamer.stats().activeGltfCount == 7);

    // From the forest corner only nearby cells stay; far ones unload.
    foreach (_; 0 .. 8) streamer.update(world, Vec3(-400, 0, -400), 50.0f);
    immutable partial = streamer.stats().activeCount;
    assert(partial < 9);

    // Leave the map: everything unloads and shared models are released.
    foreach (_; 0 .. 8) streamer.update(world, Vec3(-5000, 0, -5000), 50.0f);
    assert(streamer.stats().activeCount == 0);
    assert(streamer.stats().activeGltfCount == 0);
    assert(world.entityCount() == 0);
}
