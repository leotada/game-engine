/// Checkbox toggle widget.
module engine.ui.widgets.checkbox;

import engine.graphics.types : Color4;
import engine.ui.style : UiStyle, UiFlexDirection, UiSizeMode, UiAlign, UiJustify, UiCursor;
import engine.ui.theme;
import engine.ui.tree;

@safe:

/// Create a checkbox widget with label.
UiNodeId checkbox(
    ref UiTree tree,
    UiNodeId parent,
    scope const(char)[] labelText,
    bool checked,
    in UiTheme theme = UiTheme.init
) nothrow {
    // Row container
    UiStyle rowStyle;
    rowStyle.direction = UiFlexDirection.row;
    rowStyle.alignItems = UiAlign.center;
    rowStyle.gap = 6.0f;
    rowStyle.cursor = UiCursor.pointer;
    rowStyle.height = theme.controlHeight;
    rowStyle.heightMode = UiSizeMode.fixed;
    rowStyle.widthMode = UiSizeMode.auto_;

    UiNodeId row = tree.createNode(parent, rowStyle);

    // Box indicator
    UiStyle boxStyle;
    boxStyle.width = 16.0f;
    boxStyle.height = 16.0f;
    boxStyle.widthMode = UiSizeMode.fixed;
    boxStyle.heightMode = UiSizeMode.fixed;
    boxStyle.cornerRadius = 3.0f;
    boxStyle.borderWidth = 1.0f;
    boxStyle.borderColor = theme.colors.border;
    boxStyle.backgroundColor = checked ? theme.colors.accent : theme.colors.bgInput;
    boxStyle.textColor = theme.colors.text;
    boxStyle.justifyContent = UiJustify.center;
    boxStyle.alignItems = UiAlign.center;

    UiNodeId box = tree.createNode(row, boxStyle);
    if (checked) {
        tree.get(box).setText("v"); // Checkmark symbol
    }

    // Label
    UiStyle lblStyle;
    lblStyle.widthMode = UiSizeMode.auto_;
    lblStyle.heightMode = UiSizeMode.auto_;
    lblStyle.textColor = theme.colors.text;
    lblStyle.fontSize = theme.defaultFontSize;

    UiNodeId lbl = tree.createNode(row, lblStyle);
    tree.get(lbl).setText(labelText);

    return row;
}
