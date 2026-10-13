/// Image / textured quad widget (e.g. for viewport renders or icons).
module engine.ui.widgets.image;

import engine.graphics.types : Color4;
import engine.ui.style;
import engine.ui.tree;

@safe:

/// Create an image quad node.
UiNodeId image(
    ref UiTree tree,
    UiNodeId parent,
    ulong textureHandle,
    float width,
    float height,
    float cornerRadius = 0
) nothrow {
    UiStyle s;
    s.width = width;
    s.height = height;
    s.widthMode = UiSizeMode.fixed;
    s.heightMode = UiSizeMode.fixed;
    s.cornerRadius = cornerRadius;
    s.backgroundColor = Color4(1, 1, 1, 1);

    UiNodeId id = tree.createNode(parent, s);
    auto node = &tree.get(id);
    node.textureHandle = textureHandle;
    return id;
}
