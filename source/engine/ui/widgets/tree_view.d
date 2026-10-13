/// Tree view widget for hierarchical data (Hierarchy panel, folder browser).
module engine.ui.widgets.tree_view;

import engine.graphics.types : Color4;
import engine.ui.style;
import engine.ui.theme;
import engine.ui.tree;

@safe:

/// Create a tree view container.
UiNodeId treeView(
    ref UiTree tree,
    UiNodeId parent,
    in UiTheme theme = UiTheme.init
) nothrow {
    UiStyle s;
    s.direction = UiFlexDirection.column;
    s.widthMode = UiSizeMode.fill;
    s.heightMode = UiSizeMode.fill;
    s.backgroundColor = theme.colors.bgBase;
    s.padding = [4.0f, 4.0f, 4.0f, 4.0f];
    s.gap = 1.0f;

    UiNodeId id = tree.createNode(parent, s);
    return id;
}

/// Create a single hierarchical item row in a tree view.
UiNodeId treeItem(
    ref UiTree tree,
    UiNodeId parentTreeView,
    scope const(char)[] labelText,
    uint depth = 0,
    bool hasChildren = false,
    bool isExpanded = false,
    bool isSelected = false,
    in UiTheme theme = UiTheme.init
) nothrow {
    // Row container
    UiStyle rowStyle;
    rowStyle.direction = UiFlexDirection.row;
    rowStyle.alignItems = UiAlign.center;
    rowStyle.height = 22.0f;
    rowStyle.heightMode = UiSizeMode.fixed;
    rowStyle.widthMode = UiSizeMode.fill;
    rowStyle.backgroundColor = isSelected ? theme.colors.accent : (Color4(0, 0, 0, 0));
    rowStyle.cornerRadius = 2.0f;
    rowStyle.gap = 4.0f;
    rowStyle.cursor = UiCursor.pointer;
    rowStyle.padding = [2.0f, 4.0f, 2.0f, 4.0f + depth * 16.0f]; // Indentation by depth

    UiNodeId row = tree.createNode(parentTreeView, rowStyle);

    // Expand / collapse arrow indicator
    UiStyle arrowStyle;
    arrowStyle.width = 14.0f;
    arrowStyle.height = 14.0f;
    arrowStyle.widthMode = UiSizeMode.fixed;
    arrowStyle.heightMode = UiSizeMode.fixed;
    arrowStyle.textColor = isSelected ? theme.colors.text : theme.colors.textDim;
    arrowStyle.fontSize = 10.0f;
    arrowStyle.justifyContent = UiJustify.center;
    arrowStyle.alignItems = UiAlign.center;

    UiNodeId arrow = tree.createNode(row, arrowStyle);
    if (hasChildren) {
        tree.get(arrow).setText(isExpanded ? "v" : ">");
    }

    // Label
    UiStyle lblStyle;
    lblStyle.widthMode = UiSizeMode.auto_;
    lblStyle.heightMode = UiSizeMode.auto_;
    lblStyle.textColor = isSelected ? theme.colors.text : theme.colors.text;
    lblStyle.fontSize = theme.defaultFontSize;

    UiNodeId lbl = tree.createNode(row, lblStyle);
    tree.get(lbl).setText(labelText);

    return row;
}

/// Virtualized tree renderer for ultra-large hierarchies (10k+ items at 60 fps).
struct VirtualizedTree {
    float rowHeight = 22.0f;
    uint totalItems = 0;

    void renderVisible(
        ref UiTree tree,
        UiNodeId parentView,
        float scrollY,
        float viewHeight,
        scope void delegate(uint itemIndex, ref UiTree tree, UiNodeId parent) @safe nothrow renderItem
    ) nothrow {
        if (totalItems == 0 || rowHeight <= 0) return;

        immutable uint firstVisible = cast(uint)(scrollY / rowHeight);
        immutable uint visibleCount = cast(uint)(viewHeight / rowHeight) + 2; // +2 overscan
        immutable uint lastVisible = (firstVisible + visibleCount < totalItems) ? (firstVisible + visibleCount) : totalItems;

        foreach (uint idx; firstVisible .. lastVisible) {
            renderItem(idx, tree, parentView);
        }
    }
}

unittest {
    auto tree = UiTree.create();
    auto root = tree.root;

    // Simulate 10,000 items in a virtualized tree view
    VirtualizedTree vtree;
    vtree.rowHeight = 22.0f;
    vtree.totalItems = 10_000;

    auto tv = treeView(tree, root);
    uint renderedCount = 0;

    // Viewport height 600px with scroll at 1000px
    vtree.renderVisible(tree, tv, 1000.0f, 600.0f, (uint idx, ref UiTree t, UiNodeId parent) @safe nothrow {
        treeItem(t, parent, "Entity_Node", 0, false, false, false);
        renderedCount++;
    });

    // Only ~30 rows rendered for 10,000 items!
    assert(renderedCount >= 28 && renderedCount <= 32);
}

