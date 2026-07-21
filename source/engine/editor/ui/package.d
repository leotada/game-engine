/// Custom immediate-mode editor UI over TextRenderer.
///
/// ```
/// import engine.editor.ui;
///
/// UiContext ui;
/// ui.beginFrame(mx, my, down, pressed, released, screenW, screenH);
/// ui.bindRenderer(text, frame);
///
/// auto cols = editorColumns(screenW, screenH);
/// panel(ui, "Hierarchy", cols.hierarchy);
/// if (button(ui, "Spawn")) { ... }
///
/// panel(ui, "Inspector", cols.inspector);
/// sliderFloat(ui, "roughness", roughness, 0, 1);
///
/// ui.endFrame();
/// if (ui.consumeClick()) { /* skip scene pick */ }
/// ```
module engine.editor.ui;

public import engine.editor.ui.context;
public import engine.editor.ui.layout;
public import engine.editor.ui.widgets;
