/// Scroll view container with content clipping and scrollbar support.
module engine.ui.widgets.scroll_view;

import engine.graphics.types : Color4;
import engine.ui.style;
import engine.ui.theme;
import engine.ui.tree;

@safe:

/// Create a scrollable container with clipping.
UiNodeId scrollView(
    ref UiTree tree,
    UiNodeId parent,
    in UiTheme theme = UiTheme.init,
    bool verticalScroll = true,
    bool horizontalScroll = false
) nothrow {
    // Outer clipped container
    UiStyle outerStyle;
    outerStyle.widthMode = UiSizeMode.fill;
    outerStyle.heightMode = UiSizeMode.fill;
    outerStyle.direction = UiFlexDirection.column;
    outerStyle.clipChildren = true;
    outerStyle.backgroundColor = Color4(0, 0, 0, 0);

    UiNodeId outer = tree.createNode(parent, outerStyle);

    // Inner content container
    UiStyle innerStyle;
    innerStyle.widthMode = horizontalScroll ? UiSizeMode.auto_ : UiSizeMode.fill;
    innerStyle.heightMode = verticalScroll ? UiSizeMode.auto_ : UiSizeMode.fill;
    innerStyle.direction = UiFlexDirection.column;

    UiNodeId inner = tree.createNode(outer, innerStyle);
    return inner;
}
