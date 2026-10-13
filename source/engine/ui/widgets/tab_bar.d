/// Tab bar container and tab button widgets for dock spaces and panel headers.
module engine.ui.widgets.tab_bar;

import engine.graphics.types : Color4;
import engine.ui.style;
import engine.ui.theme;
import engine.ui.tree;

@safe:

/// Create a horizontal tab bar container.
UiNodeId tabBar(
    ref UiTree tree,
    UiNodeId parent,
    in UiTheme theme = UiTheme.init
) nothrow {
    UiStyle s;
    s.direction = UiFlexDirection.row;
    s.height = 28.0f;
    s.heightMode = UiSizeMode.fixed;
    s.widthMode = UiSizeMode.fill;
    s.backgroundColor = theme.colors.bgBase;
    s.borderWidth = 1.0f;
    s.borderColor = theme.colors.border;
    s.alignItems = UiAlign.center;
    s.gap = 2.0f;
    s.padding = [2.0f, 4.0f, 0.0f, 4.0f];

    UiNodeId id = tree.createNode(parent, s);
    return id;
}

/// Create a single tab button inside a tab bar.
UiNodeId tabItem(
    ref UiTree tree,
    UiNodeId parentTabBar,
    scope const(char)[] title,
    bool isActive = false,
    bool closable = true,
    in UiTheme theme = UiTheme.init
) nothrow {
    UiStyle s = theme.tabStyle(isActive);

    // Tab container
    s.direction = UiFlexDirection.row;
    s.alignItems = UiAlign.center;
    s.gap = 6.0f;
    s.padding = [4.0f, 8.0f, 4.0f, 8.0f];

    UiNodeId tab = tree.createNode(parentTabBar, s);

    // Title label
    UiStyle lblStyle;
    lblStyle.widthMode = UiSizeMode.auto_;
    lblStyle.heightMode = UiSizeMode.auto_;
    lblStyle.textColor = isActive ? theme.colors.text : theme.colors.textDim;
    lblStyle.fontSize = theme.defaultFontSize;

    UiNodeId lbl = tree.createNode(tab, lblStyle);
    tree.get(lbl).setText(title);

    // Optional close 'x'
    if (closable) {
        UiStyle closeStyle;
        closeStyle.width = 14.0f;
        closeStyle.height = 14.0f;
        closeStyle.widthMode = UiSizeMode.fixed;
        closeStyle.heightMode = UiSizeMode.fixed;
        closeStyle.textColor = theme.colors.textMuted;
        closeStyle.fontSize = 11.0f;
        closeStyle.justifyContent = UiJustify.center;
        closeStyle.alignItems = UiAlign.center;

        UiNodeId closeBtn = tree.createNode(tab, closeStyle);
        tree.get(closeBtn).setText("x");
    }

    return tab;
}
