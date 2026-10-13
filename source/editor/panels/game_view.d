/// Game panel: scene-camera canvas. Play controls live on the global toolbar.
module editor.panels.game_view;

import engine.graphics.types : Color4;
import engine.ui;

@safe:

enum gameCanvasTag = 0xC000_0002;

struct GameViewPanel {
    /// Transparent canvas node: its laid-out rect is where the 3D scene shows through.
    UiNodeId vpNode;

    /// `cameraLabel` is "Câmera: <nome>" or "Nenhuma câmera".
    /// When `noCamera`, the canvas shows "Nenhuma câmera na cena".
    void buildUi(
        ref UiTree tree,
        UiNodeId parent,
        in UiTheme theme,
        bool playing,
        scope const(char)[] cameraLabel,
        bool noCamera
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
        tbStyle.height = 28.0f;
        tbStyle.heightMode = UiSizeMode.fixed;
        tbStyle.widthMode = UiSizeMode.fill;
        tbStyle.padding = [2.0f, 8.0f, 2.0f, 8.0f];
        tbStyle.backgroundColor = playing ? Color4(0.12f, 0.24f, 0.16f, 1.0f) : theme.colors.bgSurface;
        tbStyle.borderWidth = 1.0f;
        tbStyle.borderColor = theme.colors.border;

        UiNodeId tb = tree.createNode(panel, tbStyle);
        label(tree, tb, cameraLabel, theme.colors.text, 12.0f);

        UiStyle vpStyle;
        vpStyle.widthMode = UiSizeMode.fill;
        vpStyle.heightMode = UiSizeMode.fill;
        vpStyle.direction = UiFlexDirection.column;
        vpStyle.justifyContent = UiJustify.center;
        vpStyle.alignItems = UiAlign.center;
        vpStyle.backgroundColor = Color4(0, 0, 0, 0);
        vpStyle.cursor = UiCursor.default_;

        vpNode = tree.createNode(panel, vpStyle);
        tree.get(vpNode).customTag = gameCanvasTag;

        if (noCamera)
            label(tree, vpNode, "Nenhuma câmera na cena", theme.colors.textMuted, 14.0f);
    }
}
