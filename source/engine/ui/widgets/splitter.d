/// Resizable splitter widget for dividing panels horizontally or vertically.
module engine.ui.widgets.splitter;

import engine.graphics.types : Color4;
import engine.ui.style;
import engine.ui.theme;
import engine.ui.tree;

@safe:

enum SplitDirection : ubyte {
    horizontal = 0, // Left/Right split (vertical divider bar)
    vertical   = 1, // Top/Bottom split (horizontal divider bar)
}

/// Create a draggable splitter divider.
UiNodeId splitter(
    ref UiTree tree,
    UiNodeId parent,
    SplitDirection direction = SplitDirection.horizontal,
    in UiTheme theme = UiTheme.init,
    float thickness = 4.0f
) nothrow {
    UiStyle s;
    if (direction == SplitDirection.horizontal) {
        s.width = thickness;
        s.widthMode = UiSizeMode.fixed;
        s.heightMode = UiSizeMode.fill;
        s.cursor = UiCursor.resizeH;
    } else {
        s.height = thickness;
        s.heightMode = UiSizeMode.fixed;
        s.widthMode = UiSizeMode.fill;
        s.cursor = UiCursor.resizeV;
    }

    s.backgroundColor = theme.colors.border;
    s.cornerRadius = 0;

    UiNodeId id = tree.createNode(parent, s);
    return id;
}
