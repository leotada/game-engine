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

/// Create a rotated image quad node (for compass needles, player/vehicle icons).
UiNodeId imageRotated(
    ref UiTree tree,
    UiNodeId parent,
    ulong textureHandle,
    float width,
    float height,
    float rotationRad,
    float cornerRadius = 0
) nothrow {
    UiStyle s;
    s.width = width;
    s.height = height;
    s.widthMode = UiSizeMode.fixed;
    s.heightMode = UiSizeMode.fixed;
    s.cornerRadius = cornerRadius;
    s.imageRotation = rotationRad;
    s.backgroundColor = Color4(0, 0, 0, 0);

    UiNodeId id = tree.createNode(parent, s);
    auto node = &tree.get(id);
    node.textureHandle = textureHandle;
    return id;
}

/// Create a circular minimap image node whose UVs rotate around `(centerU, centerV)` while
/// its children are clipped to the circular aperture.
UiNodeId minimapImage(
    ref UiTree tree,
    UiNodeId parent,
    ulong textureHandle,
    float diameter,
    float centerU = 0.5f,
    float centerV = 0.5f,
    float spanU = 0.25f,
    float spanV = 0.25f,
    float rotationRad = 0.0f
) nothrow {
    UiStyle s;
    s.width = diameter;
    s.height = diameter;
    s.widthMode = UiSizeMode.fixed;
    s.heightMode = UiSizeMode.fixed;
    s.cornerRadius = diameter * 0.5f;
    s.clipChildren = true;
    s.clipCircle = true;
    s.rotateImageUv = true;
    s.imageRotation = rotationRad;

    UiNodeId id = tree.createNode(parent, s);
    auto node = &tree.get(id);
    node.textureHandle = textureHandle;
    node.imageUvRect = [centerU, centerV, spanU, spanV];
    return id;
}
