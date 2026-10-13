/// Menu bar, dropdown menu items, and popup context menus.
module engine.ui.widgets.menu;

import engine.graphics.types : Color4;
import engine.ui.style;
import engine.ui.theme;
import engine.ui.tree;

@safe:

/// Create a top menu bar container.
UiNodeId menuBar(
    ref UiTree tree,
    UiNodeId parent,
    in UiTheme theme = UiTheme.init
) nothrow {
    UiStyle s;
    s.direction = UiFlexDirection.row;
    s.height = 24.0f;
    s.heightMode = UiSizeMode.fixed;
    s.widthMode = UiSizeMode.fill;
    s.backgroundColor = theme.colors.bgBase;
    s.alignItems = UiAlign.center;
    s.gap = 4.0f;
    s.padding = [0, 6.0f, 0, 6.0f];

    UiNodeId id = tree.createNode(parent, s);
    return id;
}

/// Create a top menu bar item (e.g. "File", "Edit", "Window").
UiNodeId menuBarItem(
    ref UiTree tree,
    UiNodeId parentMenuBar,
    scope const(char)[] labelText,
    in UiTheme theme = UiTheme.init
) nothrow {
    UiStyle s;
    s.height = 22.0f;
    s.heightMode = UiSizeMode.fixed;
    s.widthMode = UiSizeMode.auto_;
    s.textColor = theme.colors.text;
    s.fontSize = theme.defaultFontSize;
    s.padding = [2.0f, 6.0f, 2.0f, 6.0f];
    s.cornerRadius = theme.cornerRadius;
    s.backgroundColor = theme.colors.bgBase;
    s.cursor = UiCursor.pointer;
    s.flexShrink = 0;

    UiNodeId id = tree.createNode(parentMenuBar, s);
    tree.get(id).setText(labelText);
    return id;
}

/// Create a popup context menu container at (x, y).
UiNodeId contextMenu(
    ref UiTree tree,
    UiNodeId root,
    float posX, float posY,
    in UiTheme theme = UiTheme.init,
    float width = 160.0f
) nothrow {
    UiStyle s;
    s.direction = UiFlexDirection.column;
    s.width = width;
    s.widthMode = UiSizeMode.fixed;
    s.heightMode = UiSizeMode.auto_;
    s.backgroundColor = theme.colors.bgElevated;
    s.borderColor = theme.colors.borderLight;
    s.borderWidth = 1.0f;
    s.cornerRadius = theme.cornerRadius;
    s.padding = [4.0f, 4.0f, 4.0f, 4.0f];
    s.gap = 2.0f;
    s.position = UiPosition.absolute;
    s.left = posX;
    s.top = posY;

    UiNodeId id = tree.createNode(root, s);
    return id;
}

/// Create a single item inside a dropdown or context menu.
UiNodeId menuItem(
    ref UiTree tree,
    UiNodeId parentMenu,
    scope const(char)[] labelText,
    scope const(char)[] shortcutText = "",
    in UiTheme theme = UiTheme.init
) nothrow {
    UiStyle rowStyle;
    rowStyle.direction = UiFlexDirection.row;
    rowStyle.alignItems = UiAlign.center;
    rowStyle.justifyContent = UiJustify.spaceBetween;
    rowStyle.height = 22.0f;
    rowStyle.heightMode = UiSizeMode.fixed;
    rowStyle.widthMode = UiSizeMode.fill;
    rowStyle.padding = [2.0f, 8.0f, 2.0f, 8.0f];
    rowStyle.cornerRadius = 2.0f;
    rowStyle.backgroundColor = theme.colors.bgElevated;
    rowStyle.cursor = UiCursor.pointer;
    rowStyle.flexShrink = 0;

    UiNodeId row = tree.createNode(parentMenu, rowStyle);

    // Label
    UiStyle lblStyle;
    lblStyle.widthMode = UiSizeMode.auto_;
    lblStyle.heightMode = UiSizeMode.auto_;
    lblStyle.textColor = theme.colors.text;
    lblStyle.fontSize = theme.defaultFontSize;

    UiNodeId lbl = tree.createNode(row, lblStyle);
    tree.get(lbl).setText(labelText);

    // Optional shortcut
    if (shortcutText.length > 0) {
        UiStyle scStyle;
        scStyle.widthMode = UiSizeMode.auto_;
        scStyle.heightMode = UiSizeMode.auto_;
        scStyle.textColor = theme.colors.textMuted;
        scStyle.fontSize = theme.defaultFontSize - 1.0f;

        UiNodeId sc = tree.createNode(row, scStyle);
        tree.get(sc).setText(shortcutText);
    }

    return row;
}

unittest {
    import engine.ui.layout.flex : computeLayout;

    auto tree = UiTree.create();
    auto id = contextMenu(tree, tree.root, 40, 60, UiTheme.init, 180);
    computeLayout(tree, tree.root, 400, 300);
    assert(tree.get(id).layoutX == 40);
    assert(tree.get(id).layoutY == 60);
    assert(tree.get(id).layoutWidth == 180);
    assert(tree.get(id).style.position == UiPosition.absolute);
}
