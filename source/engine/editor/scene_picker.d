/**
 * Scene file discovery for the editor's "Abrir cena" picker.
 *
 * The editor has no native file dialog, so Cena → Abrir cena (Ctrl+O) lists
 * every `*.scene.json` under `assets/` and opens the chosen one. The walk runs
 * only when the picker is opened, never in the frame path.
 */
module engine.editor.scene_picker;

import std.algorithm.sorting : sort;
import std.file : SpanMode, dirEntries, exists, isDir, isFile;

@safe:

/// Suffix of every scene file (`*.scene.json`).
enum string SCENE_SUFFIX = ".scene.json";

/// True when `path` names a scene file.
bool isScenePath(scope const(char)[] path) pure nothrow @nogc {
    if (path.length < SCENE_SUFFIX.length)
        return false;
    return path[$ - SCENE_SUFFIX.length .. $] == SCENE_SUFFIX;
}

/// Picker label: the path without its `assets/` root and `.scene.json` suffix
/// (`assets/scenes/arena_01.scene.json` → `scenes/arena_01`).
const(char)[] scenePickerLabel(return const(char)[] path) pure nothrow @nogc {
    enum string root = "assets/";
    const(char)[] s = path;
    if (s.length >= root.length && s[0 .. root.length] == root)
        s = s[root.length .. $];
    if (isScenePath(s))
        s = s[0 .. $ - SCENE_SUFFIX.length];
    return s;
}

/// Every `*.scene.json` under `root`, sorted by path. Empty when `root` is missing.
string[] findScenePaths(string root) {
    string[] found;
    if (!exists(root) || !isDir(root))
        return found;
    foreach (entry; dirEntries(root, SpanMode.depth)) {
        if (entry.isFile && isScenePath(entry.name))
            found ~= entry.name;
    }
    found.sort();
    return found;
}

@("scenePicker.isScenePath") pure nothrow @nogc unittest {
    assert(isScenePath("assets/scenes/arena_01.scene.json"));
    assert(!isScenePath("assets/scenes/arena_01.json"));
    assert(isScenePath(".scene.json"));
    assert(!isScenePath("scene"));
}

@("scenePicker.label") pure nothrow @nogc unittest {
    assert(scenePickerLabel("assets/scenes/arena_01.scene.json") == "scenes/arena_01");
    assert(scenePickerLabel("assets/untitled.scene.json") == "untitled");
    assert(scenePickerLabel("other/x.scene.json") == "other/x");
}

@("scenePicker.find") unittest {
    import std.file : mkdirRecurse, rmdirRecurse, write, tempDir;
    import std.path : buildPath;

    immutable root = buildPath(tempDir(), "game_engine_scene_picker_test");
    if (exists(root)) rmdirRecurse(root);
    mkdirRecurse(buildPath(root, "scenes", "deep"));
    write(buildPath(root, "scenes", "b.scene.json"), "{}");
    write(buildPath(root, "scenes", "deep", "a.scene.json"), "{}");
    write(buildPath(root, "scenes", "notes.txt"), "x");
    scope(exit) rmdirRecurse(root);

    auto found = findScenePaths(root);
    assert(found.length == 2);
    assert(found[0] == buildPath(root, "scenes", "b.scene.json"));
    assert(found[1] == buildPath(root, "scenes", "deep", "a.scene.json"));
    assert(findScenePaths(buildPath(root, "missing")).length == 0);
}
