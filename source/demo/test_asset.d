/// Headless golden tests for `game-engine.asset` v1 (no SDL/WGPU).
module demo.test_asset;

import std.file : exists, readText;
import std.stdio : writeln, writefln;

import engine.assets.asset_file;

void main() {
    runAssetFileGoldenTests();

    enum examplePath = "assets/models/crate.asset.json";
    enforceExists(examplePath);
    auto disk = loadAssetFile(examplePath);
    immutable expected = readText(examplePath).stripNewlines();
    immutable written = assetToMinifiedJson(disk);
    assert(written == expected, "crate.asset.json must round-trip minified");
    assert(disk.meta.name == "crate");
    assert(disk.renderGltfPath() == "assets/models/pbr_cube.gltf");
    assert(disk.hullPoints().length == 8);

    writeln("asset_file golden tests OK");
    writefln("  example: %s (%s hull points)", examplePath, disk.hullPoints().length);
}

private void enforceExists(string path) {
    import std.exception : enforce;
    enforce(exists(path), "missing example asset: " ~ path);
}

private string stripNewlines(string s) {
    import std.array : replace;
    return s.replace("\r\n", "").replace("\n", "").replace("\r", "");
}
