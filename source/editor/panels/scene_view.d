/// Viewport panel: TRS toolbar and the 3D canvas. Gizmo state lives on `GizmoTool`.
module editor.panels.scene_view;

import engine.editor.gizmo_tool : GizmoMode;
import engine.graphics.types : Color4;
import engine.ui;

@safe:

enum viewportCanvasTag = 0xC000_0001;
enum gizmoMoveTag = 0xC000_0041;
enum gizmoRotateTag = 0xC000_0042;
enum gizmoScaleTag = 0xC000_0043;
enum gridToggleTag = 0xCC10;
enum snapToggleTag = 0xCC11;

struct SceneViewPanel {
    /// Transparent canvas node: its laid-out rect is where the 3D scene shows through.
    UiNodeId vpNode;

    /// Toolbar reads `GizmoTool`; it does not keep a second mode.
    void buildUi(
        ref UiTree tree,
        UiNodeId parent,
        in UiTheme theme,
        GizmoMode mode,
        bool showGrid,
        bool snapEnabled
    ) nothrow {
        UiStyle panelStyle;
        panelStyle.direction = UiFlexDirection.column;
        panelStyle.widthMode = UiSizeMode.fill;
        panelStyle.heightMode = UiSizeMode.fill;
        panelStyle.backgroundColor = Color4(0, 0, 0, 0);

        UiNodeId panel = tree.createNode(parent, panelStyle);

        UiStyle tbStyle;
        tbStyle.direction = UiFlexDirection.row;
        tbStyle.alignItems = UiAlign.center;
        tbStyle.justifyContent = UiJustify.spaceBetween;
        tbStyle.height = 28.0f;
        tbStyle.heightMode = UiSizeMode.fixed;
        tbStyle.widthMode = UiSizeMode.fill;
        tbStyle.padding = [2.0f, 8.0f, 2.0f, 8.0f];
        tbStyle.backgroundColor = theme.colors.bgSurface;
        tbStyle.borderWidth = 1.0f;
        tbStyle.borderColor = theme.colors.border;

        UiNodeId tb = tree.createNode(panel, tbStyle);

        auto modesGroup = tree.createNode(tb);
        tree.get(modesGroup).style.direction = UiFlexDirection.row;
        tree.get(modesGroup).style.gap = 4.0f;

        auto moveBtn = button(tree, modesGroup, "W: Mover", theme);
        auto rotBtn = button(tree, modesGroup, "E: Girar", theme);
        auto scaleBtn = button(tree, modesGroup, "R: Escalar", theme);
        tree.get(moveBtn).customTag = gizmoMoveTag;
        tree.get(rotBtn).customTag = gizmoRotateTag;
        tree.get(scaleBtn).customTag = gizmoScaleTag;
        if (mode == GizmoMode.translate)
            tree.get(moveBtn).style.backgroundColor = theme.colors.accent;
        else if (mode == GizmoMode.rotate)
            tree.get(rotBtn).style.backgroundColor = theme.colors.accent;
        else
            tree.get(scaleBtn).style.backgroundColor = theme.colors.accent;

        auto rightGroup = tree.createNode(tb);
        tree.get(rightGroup).style.direction = UiFlexDirection.row;
        tree.get(rightGroup).style.gap = 8.0f;

        auto gridBox = checkbox(tree, rightGroup, "Grade", showGrid, theme);
        tree.get(gridBox).customTag = gridToggleTag;
        auto snapBox = checkbox(tree, rightGroup, "Snap", snapEnabled, theme);
        tree.get(snapBox).customTag = snapToggleTag;

        // Non-zero tag so the click stops on the canvas instead of the dock tab.
        UiStyle vpStyle;
        vpStyle.widthMode = UiSizeMode.fill;
        vpStyle.heightMode = UiSizeMode.fill;
        vpStyle.backgroundColor = Color4(0, 0, 0, 0);
        vpStyle.cursor = UiCursor.default_;

        vpNode = tree.createNode(panel, vpStyle);
        tree.get(vpNode).customTag = viewportCanvasTag;
    }
}
