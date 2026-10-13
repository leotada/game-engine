/// Flexbox-inspired retained-mode UI layout engine.
///
/// Two passes:
///  1. `measure` (bottom-up) computes every node's intrinsic size (`prefW/prefH`)
///     from its text and children. `auto` sized nodes use it.
///  2. `layoutChildren` (top-down) resolves base sizes, distributes free space
///     (flex grow / shrink), aligns children and positions them.
///
/// A node's own `layoutWidth/layoutHeight` are always decided by its parent
/// before its children are laid out — nothing here reads a previous frame's
/// results, so rebuilding the tree every frame is safe.
module engine.ui.layout.flex;

import engine.ui.style;
import engine.ui.tree;

@safe:

/// Run layout computation on the tree from rootId.
void computeLayout(ref UiTree tree, UiNodeId rootId, float windowWidth, float windowHeight) nothrow @nogc {
    if (!tree.isValid(rootId)) return;

    measure(tree, rootId);

    auto root = &tree.get(rootId);
    root.layoutX = 0;
    root.layoutY = 0;
    root.layoutWidth = windowWidth;
    root.layoutHeight = windowHeight;

    layoutChildren(tree, rootId);
}

private float clampf(float v, float lo, float hi) nothrow @nogc pure {
    return v < lo ? lo : (v > hi ? hi : v);
}

/// Size of `c` along one axis before free space is distributed.
/// `inner` is the parent's inner size on that axis, `crossAxis` tells whether
/// that axis is the parent's cross axis (fill means "stretch" there and "grow
/// from zero" on the main axis).
private float baseSize(in UiNode c, bool horizontal, float inner, bool crossAxis) nothrow @nogc pure {
    immutable UiSizeMode mode = horizontal ? c.style.widthMode : c.style.heightMode;
    immutable float fixedV = horizontal ? c.style.width : c.style.height;
    immutable float pref = horizontal ? c.prefW : c.prefH;
    immutable float mA = horizontal ? (c.style.margin[3] + c.style.margin[1]) : (c.style.margin[0] + c.style.margin[2]);
    immutable float lo = horizontal ? c.style.minWidth : c.style.minHeight;
    immutable float hi = horizontal ? c.style.maxWidth : c.style.maxHeight;

    float v = 0;
    final switch (mode) {
        case UiSizeMode.fixed:   v = fixedV; break;
        case UiSizeMode.percent: v = inner * (fixedV * 0.01f); break;
        case UiSizeMode.fill:    v = crossAxis ? (inner - mA) : 0; break;
        case UiSizeMode.auto_:   v = pref; break;
    }
    return clampf(v, lo, hi);
}

/// Bottom-up intrinsic size computation.
private void measure(ref UiTree tree, UiNodeId id) nothrow @nogc {
    auto n = &tree.get(id);
    immutable bool isRow = (n.style.direction == UiFlexDirection.row);

    float main = 0;
    float cross = 0;
    uint count = 0;

    UiNodeId childId = n.firstChild;
    while (childId.isValid()) {
        measure(tree, childId);
        const c = &tree.get(childId);
        if (c.visible && c.style.position != UiPosition.absolute) {
            immutable float ow = baseSize(*c, true, 0, false) + c.style.margin[3] + c.style.margin[1];
            immutable float oh = baseSize(*c, false, 0, false) + c.style.margin[0] + c.style.margin[2];
            immutable float cm = isRow ? ow : oh;
            immutable float cc = isRow ? oh : ow;
            main += cm;
            if (cc > cross) cross = cc;
            count++;
        }
        childId = c.nextSibling;
    }
    if (count > 1) main += n.style.gap * (count - 1);

    float cw = 0;
    float ch = 0;
    if (n.textLen > 0) {
        cw = n.textWidth > 0 ? n.textWidth : n.textLen * 8.0f;
        ch = n.textHeight > 0 ? n.textHeight : 16.0f;
    }
    if (count > 0) {
        immutable float childW = isRow ? main : cross;
        immutable float childH = isRow ? cross : main;
        if (childW > cw) cw = childW;
        if (childH > ch) ch = childH;
    }

    n.prefW = n.style.padding[1] + n.style.padding[3] + cw;
    n.prefH = n.style.padding[0] + n.style.padding[2] + ch;
}

/// Top-down resolve: `p.layoutX/Y/Width/Height` are already final.
private void layoutChildren(ref UiTree tree, UiNodeId parentId) nothrow @nogc {
    auto p = &tree.get(parentId);
    if (p.childCount == 0) return;

    immutable bool isRow = (p.style.direction == UiFlexDirection.row);

    // Padding: [0]=top, [1]=right, [2]=bottom, [3]=left
    immutable float padTop = p.style.padding[0];
    immutable float padRight = p.style.padding[1];
    immutable float padBottom = p.style.padding[2];
    immutable float padLeft = p.style.padding[3];

    immutable float innerWidth = (p.layoutWidth > padLeft + padRight) ? (p.layoutWidth - padLeft - padRight) : 0;
    immutable float innerHeight = (p.layoutHeight > padTop + padBottom) ? (p.layoutHeight - padTop - padBottom) : 0;
    immutable float parentMain = isRow ? innerWidth : innerHeight;
    immutable float parentCross = isRow ? innerHeight : innerWidth;

    // ---- Pass 1: base sizes, totals ------------------------------------
    float usedMain = 0;
    float totalGrow = 0;
    float totalShrink = 0;
    uint activeChildren = 0;

    UiNodeId childId = p.firstChild;
    while (childId.isValid()) {
        auto c = &tree.get(childId);
        if (c.visible) {
            if (c.style.position == UiPosition.absolute) {
                c.layoutWidth = (c.style.widthMode == UiSizeMode.fill)
                    ? clampf(innerWidth, c.style.minWidth, c.style.maxWidth)
                    : baseSize(*c, true, innerWidth, true);
                c.layoutHeight = (c.style.heightMode == UiSizeMode.fill)
                    ? clampf(innerHeight, c.style.minHeight, c.style.maxHeight)
                    : baseSize(*c, false, innerHeight, true);
                c.layoutX = p.layoutX + c.style.left;
                c.layoutY = p.layoutY + c.style.top;
                layoutChildren(tree, childId);
            } else {
                activeChildren++;
                c.layoutWidth  = baseSize(*c, true,  innerWidth,  !isRow);
                c.layoutHeight = baseSize(*c, false, innerHeight, isRow);

                immutable float mMain = isRow ? (c.style.margin[3] + c.style.margin[1])
                                              : (c.style.margin[0] + c.style.margin[2]);
                usedMain += (isRow ? c.layoutWidth : c.layoutHeight) + mMain;

                immutable bool mainFill = isRow ? (c.style.widthMode == UiSizeMode.fill)
                                                : (c.style.heightMode == UiSizeMode.fill);
                immutable float effGrow = (c.style.flexGrow == 0 && mainFill) ? 1.0f : c.style.flexGrow;
                totalGrow += effGrow;

                // Fixed-size nodes never shrink.
                immutable UiSizeMode mainMode = isRow ? c.style.widthMode : c.style.heightMode;
                if (c.style.flexShrink > 0 && mainMode != UiSizeMode.fixed) totalShrink += c.style.flexShrink;
            }
        }
        childId = c.nextSibling;
    }
    if (activeChildren > 1) usedMain += p.style.gap * (activeChildren - 1);

    // ---- Pass 2: flex distribution --------------------------------------
    float remainingMain = parentMain - usedMain;

    if (remainingMain > 0 && totalGrow > 0) {
        immutable float spacePerGrow = remainingMain / totalGrow;
        childId = p.firstChild;
        while (childId.isValid()) {
            auto c = &tree.get(childId);
            if (c.visible && c.style.position != UiPosition.absolute) {
                immutable bool mainFill = isRow ? (c.style.widthMode == UiSizeMode.fill)
                                                : (c.style.heightMode == UiSizeMode.fill);
                immutable float effGrow = (c.style.flexGrow == 0 && mainFill) ? 1.0f : c.style.flexGrow;
                if (effGrow > 0) {
                    immutable float add = spacePerGrow * effGrow;
                    if (isRow) c.layoutWidth = clampf(c.layoutWidth + add, c.style.minWidth, c.style.maxWidth);
                    else       c.layoutHeight = clampf(c.layoutHeight + add, c.style.minHeight, c.style.maxHeight);
                }
            }
            childId = c.nextSibling;
        }
        remainingMain = 0;
    } else if (remainingMain < 0 && totalShrink > 0) {
        immutable float shrinkPerFactor = (-remainingMain) / totalShrink;
        childId = p.firstChild;
        while (childId.isValid()) {
            auto c = &tree.get(childId);
            immutable UiSizeMode mainMode = isRow ? c.style.widthMode : c.style.heightMode;
            if (c.visible && c.style.position != UiPosition.absolute
                && c.style.flexShrink > 0 && mainMode != UiSizeMode.fixed)
            {
                immutable float sub = shrinkPerFactor * c.style.flexShrink;
                immutable float lo = isRow ? c.style.minWidth : c.style.minHeight;
                if (isRow) c.layoutWidth = (c.layoutWidth - sub > lo) ? c.layoutWidth - sub : lo;
                else       c.layoutHeight = (c.layoutHeight - sub > lo) ? c.layoutHeight - sub : lo;
            }
            childId = c.nextSibling;
        }
        remainingMain = 0;
    }

    // ---- Pass 3: justify / align / position -----------------------------
    float curMain = isRow ? padLeft : padTop;
    float gapSpace = p.style.gap;

    final switch (p.style.justifyContent) {
        case UiJustify.start:
            break;
        case UiJustify.center:
            if (remainingMain > 0) curMain += remainingMain * 0.5f;
            break;
        case UiJustify.end:
            if (remainingMain > 0) curMain += remainingMain;
            break;
        case UiJustify.spaceBetween:
            if (remainingMain > 0 && activeChildren > 1) gapSpace += remainingMain / (activeChildren - 1);
            break;
        case UiJustify.spaceAround:
            if (remainingMain > 0 && activeChildren > 0) {
                immutable float unit = remainingMain / activeChildren;
                curMain += unit * 0.5f;
                gapSpace += unit;
            }
            break;
    }

    float maxContentCross = 0;

    childId = p.firstChild;
    while (childId.isValid()) {
        auto c = &tree.get(childId);
        if (c.visible && c.style.position != UiPosition.absolute) {
            immutable float mStart = isRow ? c.style.margin[3] : c.style.margin[0];
            immutable float mEnd = isRow ? c.style.margin[1] : c.style.margin[2];
            immutable float mCrossStart = isRow ? c.style.margin[0] : c.style.margin[3];
            immutable float mCrossEnd = isRow ? c.style.margin[2] : c.style.margin[1];

            curMain += mStart;
            if (isRow) c.layoutX = p.layoutX + curMain - p.scrollX;
            else       c.layoutY = p.layoutY + curMain - p.scrollY;

            // Cross axis: stretch resizes `auto` children, everything else aligns.
            immutable UiSizeMode crossMode = isRow ? c.style.heightMode : c.style.widthMode;
            if (p.style.alignItems == UiAlign.stretch && crossMode == UiSizeMode.auto_) {
                immutable float stretched = clampf(parentCross - mCrossStart - mCrossEnd,
                    isRow ? c.style.minHeight : c.style.minWidth,
                    isRow ? c.style.maxHeight : c.style.maxWidth);
                if (isRow) c.layoutHeight = stretched; else c.layoutWidth = stretched;
            }
            immutable float childCross = isRow ? c.layoutHeight : c.layoutWidth;

            float crossOffset = isRow ? padTop : padLeft;
            final switch (p.style.alignItems) {
                case UiAlign.stretch:
                case UiAlign.start:
                    crossOffset += mCrossStart;
                    break;
                case UiAlign.center:
                    crossOffset += (parentCross - childCross) * 0.5f;
                    break;
                case UiAlign.end:
                    crossOffset += parentCross - childCross - mCrossEnd;
                    break;
            }
            if (isRow) c.layoutY = p.layoutY + crossOffset - p.scrollY;
            else       c.layoutX = p.layoutX + crossOffset - p.scrollX;

            immutable float childMain = isRow ? c.layoutWidth : c.layoutHeight;
            curMain += childMain + mEnd + gapSpace;

            immutable float outerCross = childCross + mCrossStart + mCrossEnd;
            if (outerCross > maxContentCross) maxContentCross = outerCross;

            layoutChildren(tree, childId);
        }
        childId = c.nextSibling;
    }

    // Extent of the content (used for scrolling); the node's own size is untouched.
    immutable float mainExtent = curMain - gapSpace + (isRow ? padRight : padBottom);
    p.contentWidth = isRow ? mainExtent : (maxContentCross + padLeft + padRight);
    p.contentHeight = isRow ? (maxContentCross + padTop + padBottom) : mainExtent;
    p.layoutDirty = false;
}

unittest {
    auto tree = UiTree.create();
    auto root = tree.root;

    // Container with 2 children in a row
    auto container = tree.createNode(root);
    tree.get(container).style.direction = UiFlexDirection.row;
    tree.get(container).style.widthMode = UiSizeMode.fixed;
    tree.get(container).style.heightMode = UiSizeMode.fixed;
    tree.get(container).style.width = 400;
    tree.get(container).style.height = 100;
    tree.get(container).style.gap = 10;

    auto childA = tree.createNode(container);
    tree.get(childA).style.widthMode = UiSizeMode.fixed;
    tree.get(childA).style.heightMode = UiSizeMode.fixed;
    tree.get(childA).style.width = 100;
    tree.get(childA).style.height = 50;

    auto childB = tree.createNode(container);
    tree.get(childB).style.widthMode = UiSizeMode.fixed;
    tree.get(childB).style.heightMode = UiSizeMode.fixed;
    tree.get(childB).style.width = 200;
    tree.get(childB).style.height = 50;

    computeLayout(tree, root, 800, 600);

    assert(tree.get(childA).layoutX == 0);
    assert(tree.get(childA).layoutWidth == 100);
    assert(tree.get(childB).layoutX == 110); // 100 + 10 gap
    assert(tree.get(childB).layoutWidth == 200);

    // Test flex grow
    tree.get(childA).style.flexGrow = 1.0f;
    tree.get(childB).style.flexGrow = 1.0f;
    // 400 total - 10 gap = 390 available; 390 - 300 base = 90 leftover; 45 extra each
    computeLayout(tree, root, 800, 600);
    assert(tree.get(childA).layoutWidth == 145);
    assert(tree.get(childB).layoutWidth == 245);
}

/// A row of auto-sized children is as wide as its content, independent of
/// whatever a recycled node slot held before.
unittest {
    auto tree = UiTree.create();
    auto row = tree.createNode(tree.root);
    tree.get(row).style.direction = UiFlexDirection.row;
    tree.get(row).style.gap = 4;
    tree.get(row).style.alignItems = UiAlign.center;
    foreach (i; 0 .. 3) {
        auto b = tree.createNode(row);
        tree.get(b).style.padding = [2.0f, 5.0f, 2.0f, 5.0f];
        tree.get(b).style.heightMode = UiSizeMode.fixed;
        tree.get(b).style.height = 20;
        tree.get(b).setText("abcd");
    }
    computeLayout(tree, tree.root, 800, 600);
    // textLen*8 = 32 + padding 10 = 42 each, gaps 4
    auto first = tree.get(row).firstChild;
    assert(tree.get(first).layoutWidth == 42);
    assert(tree.get(row).prefW == 3 * 42 + 2 * 4);

    // Rebuild: ids are stable, nothing stale survives.
    tree.resetForRebuild();
    auto row2 = tree.createNode(tree.root);
    assert(row2 == row);
    auto b2 = tree.createNode(row2);
    assert(tree.get(b2).layoutWidth == 0 && !tree.get(b2).hovered && tree.get(b2).customTag == 0);
}

/// Dock-style layout: a fill column with absolutely positioned panes.
unittest {
    auto tree = UiTree.create();
    tree.get(tree.root).style.direction = UiFlexDirection.column;

    UiStyle bar;
    bar.heightMode = UiSizeMode.fixed; bar.height = 24; bar.widthMode = UiSizeMode.fill;
    tree.createNode(tree.root, bar);

    UiStyle area;
    area.widthMode = UiSizeMode.fill; area.heightMode = UiSizeMode.fill;
    auto areaId = tree.createNode(tree.root, area);

    UiStyle pane;
    pane.position = UiPosition.absolute;
    pane.left = 100; pane.top = 50;
    pane.widthMode = UiSizeMode.fixed; pane.width = 200;
    pane.heightMode = UiSizeMode.fixed; pane.height = 80;
    auto paneId = tree.createNode(areaId, pane);

    computeLayout(tree, tree.root, 1000, 700);
    assert(tree.get(areaId).layoutY == 24);
    assert(tree.get(areaId).layoutHeight == 676);
    assert(tree.get(paneId).layoutX == 100);
    assert(tree.get(paneId).layoutY == 74);
    assert(tree.get(paneId).layoutWidth == 200);
}
