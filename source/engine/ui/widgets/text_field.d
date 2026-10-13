/// Text input field widget supporting focus, typing, and submission.
module engine.ui.widgets.text_field;

import engine.graphics.types : Color4;
import engine.ui.style;
import engine.ui.theme;
import engine.ui.tree;

@safe:

/// Create an editable single-line text input field.
UiNodeId textField(
    ref UiTree tree,
    UiNodeId parent,
    scope const(char)[] initialText = "",
    in UiTheme theme = UiTheme.init,
    float width = 120.0f
) nothrow {
    UiStyle s = theme.inputStyle();
    s.widthMode = UiSizeMode.fixed;
    s.width = width;

    UiNodeId id = tree.createNode(parent, s);
    tree.get(id).setText(initialText);
    return id;
}
