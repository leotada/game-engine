/// Editor scene I/O helpers (ED-7): New / Save / Open via ASCII path strings.
///
/// No native file dialog in v1 — Stream J wires Ctrl+S / Ctrl+O / New to these
/// APIs with a text-field path or CLI argument.
///
/// ```
/// EditorWorld world;
/// SceneLightSettings lights;
/// float[3] gravity = [0, -9.81f, 0];
///
/// newScene(world, lights, gravity);
/// saveScene(world, "assets/scenes/arena_01.scene.json", lights, gravity, "arena_01");
/// loadScene(world, "assets/scenes/arena_01.scene.json", lights, gravity);
/// ```
module engine.editor.scene_io;

import std.exception : enforce;
import std.file : exists;

import engine.editor.components : EditorWorld;
import engine.editor.light_panel : SceneLightSettings;
import engine.editor.scene_load :
    SceneLoadOptions, SceneLoadResult, loadSceneGravity, loadSceneIntoWorld,
    worldToSceneFile;
import engine.scene.scene_file :
    SceneMeta, loadSceneFile, saveSceneFile, sceneToMinifiedJson, validateScene;

@safe:

/// Clear the editor world and reset scene settings (Ctrl+N / New).
void newScene(
    ref EditorWorld world,
    ref SceneLightSettings lights,
    ref float[3] gravity
) {
    world = EditorWorld.init;
    lights = SceneLightSettings.init;
    gravity = [0, -9.81f, 0];
}

/// Save the current editor world to `path` (Ctrl+S). Minified JSON.
void saveScene(
    ref EditorWorld world,
    string path,
    const ref SceneLightSettings lights,
    float[3] gravity = [0, -9.81f, 0],
    string metaName = "untitled",
    string units = "meters"
) {
    enforce(path.length > 0, "saveScene: empty path");
    auto scene = worldToSceneFile(
        world, lights, gravity, SceneMeta(metaName, units));
    auto v = validateScene(scene, false);
    enforce(v.ok, "saveScene: world failed validation (light limits / mesh+dynamic)");
    saveSceneFile(path, scene);
}

/// Load `path` into the editor world, replacing current contents (Ctrl+O).
SceneLoadResult loadScene(
    ref EditorWorld world,
    string path,
    ref SceneLightSettings lights,
    ref float[3] gravity,
    SceneLoadOptions opts = SceneLoadOptions.init
) {
    enforce(path.length > 0, "loadScene: empty path");
    enforce(exists(path), "loadScene: file not found: " ~ path);
    auto scene = loadSceneFile(path);
    auto result = loadSceneIntoWorld(world, scene, lights, opts);
    gravity = loadSceneGravity(scene);
    return result;
}

/// Serialize world to minified JSON string (tests / clipboard helpers).
string sceneToJson(
    ref EditorWorld world,
    const ref SceneLightSettings lights,
    float[3] gravity = [0, -9.81f, 0],
    string metaName = "untitled"
) {
    auto scene = worldToSceneFile(
        world, lights, gravity, SceneMeta(metaName, "meters"));
    return sceneToMinifiedJson(scene);
}
