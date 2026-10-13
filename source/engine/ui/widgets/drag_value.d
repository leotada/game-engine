/// Unity/Godot-style drag_value widget for interactive numeric tweaking.
module engine.ui.widgets.drag_value;

import engine.graphics.types : Color4;
import engine.ui.style;
import engine.ui.theme;
import engine.ui.tree;

@safe:

/// Create a drag_value widget.
UiNodeId dragValue(
    ref UiTree tree,
    UiNodeId parent,
    scope const(char)[] labelText,
    float value,
    in UiTheme theme = UiTheme.init,
    float width = 140.0f
) nothrow {
    // Container row
    UiStyle rowStyle;
    rowStyle.direction = UiFlexDirection.row;
    rowStyle.alignItems = UiAlign.center;
    rowStyle.justifyContent = UiJustify.spaceBetween;
    rowStyle.width = width;
    rowStyle.height = theme.controlHeight;
    rowStyle.widthMode = UiSizeMode.fixed;
    rowStyle.heightMode = UiSizeMode.fixed;
    rowStyle.backgroundColor = theme.colors.bgInput;
    rowStyle.borderColor = theme.colors.border;
    rowStyle.borderWidth = 1.0f;
    rowStyle.cornerRadius = theme.cornerRadius;
    rowStyle.padding = [2.0f, 6.0f, 2.0f, 6.0f];
    rowStyle.cursor = UiCursor.resizeH;

    UiNodeId row = tree.createNode(parent, rowStyle);

    // Label on left
    UiStyle lblStyle;
    lblStyle.widthMode = UiSizeMode.auto_;
    lblStyle.heightMode = UiSizeMode.auto_;
    lblStyle.textColor = theme.colors.textDim;
    lblStyle.fontSize = theme.defaultFontSize;

    UiNodeId lbl = tree.createNode(row, lblStyle);
    tree.get(lbl).setText(labelText);

    // Formatted value on right
    char[32] valBuf;
    import core.stdc.stdio : snprintf;
    () @trusted {
        snprintf(valBuf.ptr, valBuf.length, "%.2f", value);
    }();
    import core.stdc.string : strlen;
    size_t len = () @trusted { return strlen(valBuf.ptr); }();

    UiStyle valStyle;
    valStyle.widthMode = UiSizeMode.auto_;
    valStyle.heightMode = UiSizeMode.auto_;
    valStyle.textColor = theme.colors.text;
    valStyle.fontSize = theme.defaultFontSize;

    UiNodeId valNode = tree.createNode(row, valStyle);
    tree.get(valNode).setText(valBuf[0 .. len]);

    return row;
}
