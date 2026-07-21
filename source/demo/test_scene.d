/// Headless golden tests for `game-engine.scene` v1 (no SDL/WGPU).
module demo.test_scene;

import std.file : exists, readText;
import std.stdio : writeln, writefln;

import engine.scene.scene_file;

void main() {
    runSceneFileGoldenTests();

    enum examplePath = "assets/scenes/arena_01.scene.json";
    enforceExists(examplePath);
    auto disk = loadSceneFile(examplePath);
    immutable expected = readText(examplePath).stripNewlines();
    immutable written = sceneToMinifiedJson(disk);
    assert(written == expected, "arena_01.scene.json must round-trip minified");
    assert(disk.meta.name == "arena_01");
    assert(disk.entities.length == 4);
    assert(disk.entities[0].hasVisual && disk.entities[0].visual.hasAsset);
    assert(disk.strings[disk.entities[0].visual.asset] == "assets/models/crate.asset.json");
    assert(disk.entities[0].hasPhysics);
    assert(disk.entities[0].physics.shape == "triangleMesh");
    assert(disk.entities[3].hasLight && disk.entities[3].light.castShadows);

    auto v = validateScene(disk, true);
    assert(v.ok, "example scene must validate (assets present)");

    writeln("scene_file golden tests OK");
    writefln("  example: %s (%s entities, %s strings)",
        examplePath, disk.entities.length, disk.strings.length);
}

private void enforceExists(string path) {
    import std.exception : enforce;
    enforce(exists(path), "missing example scene: " ~ path);
}

private string stripNewlines(string s) {
    import std.array : replace;
    return s.replace("\r\n", "").replace("\n", "").replace("\r", "");
}
