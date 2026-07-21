/// Scene management — camera, graph, lights, and batched 3D renderers.
/// Scene disk format (`*.scene.json`) lives here; EditorWorld spawn/load is
/// in `engine.editor.scene_load` (opt-in via `import engine.editor;`).
module engine.scene;

public import engine.scene.camera;
public import engine.scene.controllers;
public import engine.scene.graph;
public import engine.scene.light;
public import engine.scene.scene3d;
public import engine.scene.scene3d_textured;
// scene_file (ED-7 format); gated so headless physics configs can exclude it.
version (NoSceneFile) {
} else {
    public import engine.scene.scene_file;
}
