/// Layout helpers for the editor immediate-mode UI:
/// vertical stack cursor + fixed 3-column editor chrome
/// (Hierarchy | Viewport gap | Inspector).
module engine.editor.ui.layout;

import engine.editor.ui.context : UiContext, UiRect;

@safe:

/// Default side-panel widths (pixels).
enum float defaultHierarchyW = 220;
enum float defaultInspectorW = 280;

/// Result of splitting the screen into Hierarchy | Viewport | Inspector.
struct EditorColumns {
    UiRect hierarchy;
    UiRect viewport;
    UiRect inspector;
}

/// Split `screenW × screenH` into three columns.
/// Hierarchy on the left, Inspector on the right, Viewport fills the middle gap.
EditorColumns editorColumns(
    float screenW, float screenH,
    float hierarchyW = defaultHierarchyW,
    float inspectorW = defaultInspectorW
) nothrow @nogc {
    EditorColumns c;
    immutable hw = hierarchyW > 0 ? hierarchyW : 0;
    immutable iw = inspectorW > 0 ? inspectorW : 0;
    immutable mid = screenW - hw - iw;
    c.hierarchy = UiRect(0, 0, hw, screenH);
    c.viewport  = UiRect(hw, 0, mid > 0 ? mid : 0, screenH);
    c.inspector = UiRect(hw + (mid > 0 ? mid : 0), 0, iw, screenH);
    return c;
}

/// Begin laying out widgets inside `area` (sets UiContext cursor + width).
/// Registers the area as a mouse-capture region (blocks scene picking).
void beginRegion(ref UiContext ui, UiRect area) nothrow @nogc {
    ui.hitCapture(area);
    ui.setCursor(area.x + ui.padX, area.y + ui.padY, area.w - 2 * ui.padX);
}

/// Vertical stack: bump indent for nested rows (tree children, etc.).
void pushIndent(ref UiContext ui, float dx = 12) nothrow @nogc {
    ui.indent += dx;
}

void popIndent(ref UiContext ui, float dx = 12) nothrow @nogc {
    ui.indent -= dx;
    if (ui.indent < 0) ui.indent = 0;
}

/// Convenience: begin Hierarchy column layout.
void beginHierarchy(ref UiContext ui, ref const EditorColumns cols) nothrow @nogc {
    beginRegion(ui, cols.hierarchy);
}

/// Convenience: begin Inspector column layout.
void beginInspector(ref UiContext ui, ref const EditorColumns cols) nothrow @nogc {
    beginRegion(ui, cols.inspector);
}

@safe unittest {
    immutable cols = editorColumns(1280, 720, 200, 300);
    assert(cols.hierarchy.x == 0);
    assert(cols.hierarchy.w == 200);
    assert(cols.inspector.w == 300);
    assert(cols.viewport.x == 200);
    assert(cols.viewport.w == 1280 - 200 - 300);
    assert(cols.inspector.x == 200 + cols.viewport.w);
}
