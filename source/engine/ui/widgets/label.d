/// Label widget for displaying static or dynamic text.
module engine.ui.widgets.label;

import engine.graphics.types : Color4;
import engine.ui.style;
import engine.ui.tree;

@safe:

/// Create a text label node.
UiNodeId label(
    ref UiTree tree,
    UiNodeId parent,
    scope const(char)[] text,
    in Color4 color = Color4(0.9f, 0.9f, 0.9f, 1.0f),
    float fontSize = 13.0f
) nothrow {
    UiStyle s;
    s.widthMode = UiSizeMode.auto_;
    s.heightMode = UiSizeMode.auto_;
    s.textColor = color;
    s.fontSize = fontSize;
    s.backgroundColor = Color4(0, 0, 0, 0);

    UiNodeId id = tree.createNode(parent, s);
    tree.get(id).setText(text);
    return id;
}
