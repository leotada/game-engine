/// Top-level engine module — one import for gameplay/runtime.
/// Level editor is opt-in: `import engine.editor;` (not re-exported here).
module engine;

public import engine.core;
public import engine.ecs;
public import engine.math;
public import engine.platform;
public import engine.gpu;
public import engine.graphics;
public import engine.scene;
public import engine.assets;
public import engine.audio;
public import engine.devtools;
public import engine.physics;
public import engine.app;
