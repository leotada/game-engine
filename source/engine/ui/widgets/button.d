/// Button widget for click interactions.
module engine.ui.widgets.button;

import engine.graphics.types : Color4;
import engine.ui.style;
import engine.ui.theme;
import engine.ui.tree;

@safe:

/// Create a standard clickable button.
UiNodeId button(
    ref UiTree tree,
    UiNodeId parent,
    scope const(char)[] text,
    in UiTheme theme = UiTheme.init,
    float width = 0
) nothrow {
    UiStyle s = theme.buttonStyle();
    if (width > 0) {
        s.widthMode = UiSizeMode.fixed;
        s.width = width;
    } else {
        s.widthMode = UiSizeMode.auto_;
    }

    UiNodeId id = tree.createNode(parent, s);
    tree.get(id).setText(text);
    return id;
}

/// Create an icon button (e.g. Play, Pause, Step).
UiNodeId iconButton(
    ref UiTree tree,
    UiNodeId parent,
    scope const(char)[] iconSymbol,
    in UiTheme theme = UiTheme.init,
    float size = 26.0f
) nothrow {
    UiStyle s = theme.buttonStyle();
    s.widthMode = UiSizeMode.fixed;
    s.heightMode = UiSizeMode.fixed;
    s.width = size;
    s.height = size;
    s.padding = [2.0f, 4.0f, 2.0f, 4.0f];
    s.justifyContent = UiJustify.center;
    s.alignItems = UiAlign.center;

    UiNodeId id = tree.createNode(parent, s);
    tree.get(id).setText(iconSymbol);
    return id;
}
