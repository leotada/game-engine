/// Retained-mode UI input processing, hit-testing, and event dispatch.
module engine.ui.input;

import engine.core.pod : isPod;
import engine.platform.input : InputState, Key, MouseButton;
import engine.ui.events;
import engine.ui.style : UiCursor;
import engine.ui.tree;

@safe:

/// State tracker for UI interactions.
struct UiInputContext {
    UiNodeId hoveredNode;
    UiNodeId pressedNode;
    UiNodeId focusedNode;
    float dragStartX = 0;
    float dragStartY = 0;
    bool isDragging = false;

    /// Hit-test finding the deepest interactive leaf containing (x, y).
    static UiNodeId hitTest(ref const UiTree tree, UiNodeId rootId, float x, float y) nothrow @nogc {
        if (!tree.isValid(rootId)) return UiNodeId.init;

        const r = &tree.get(rootId);
        if (!r.visible) return UiNodeId.init;

        // Check if inside bounds
        if (x < r.layoutX || x > r.layoutX + r.layoutWidth ||
            y < r.layoutY || y > r.layoutY + r.layoutHeight) {
            return UiNodeId.init;
        }

        // Test children in reverse order (last child drawn on top)
        UiNodeId child = r.lastChild;
        while (child.isValid()) {
            UiNodeId hit = hitTest(tree, child, x, y);
            if (hit.isValid()) return hit;
            child = tree.get(child).prevSibling;
        }

        return rootId;
    }

    /// Deepest node is often a label inside the control that owns `customTag`
    /// and the pointer cursor. Walk up to that control so the click, hover and
    /// press land on the button, tab or row — not on its text child.
    static UiNodeId interactiveTarget(ref const UiTree tree, UiNodeId hit) nothrow @nogc {
        UiNodeId n = hit;
        while (n.isValid() && tree.isValid(n)) {
            const node = &tree.get(n);
            if (node.style.cursor == UiCursor.text)
                return n;
            if (node.customTag != 0 || node.style.cursor == UiCursor.pointer)
                return n;
            n = node.parent;
        }
        return hit;
    }

    /// Re-apply hover / press / focus flags to a freshly rebuilt tree. Ids are
    /// stable across `UiTree.resetForRebuild()` when the structure is unchanged.
    void applyState(ref UiTree tree) nothrow @nogc {
        if (hoveredNode.isValid() && tree.isValid(hoveredNode)) tree.get(hoveredNode).hovered = true;
        if (pressedNode.isValid() && tree.isValid(pressedNode)) tree.get(pressedNode).pressed = true;
        if (focusedNode.isValid() && tree.isValid(focusedNode)) tree.get(focusedNode).focused = true;
    }

    /// Update input interactions and populate event queue.
    void update(ref UiTree tree, ref UiEventQueue queue, in InputState input, float dt) nothrow @nogc {
        immutable float mx = input.mx;
        immutable float my = input.my;

        UiNodeId hit = hitTest(tree, tree.root, mx, my);
        immutable target = interactiveTarget(tree, hit);

        // Hover events follow the control, not the text glyph inside it.
        if (target != hoveredNode) {
            if (hoveredNode.isValid() && tree.isValid(hoveredNode)) {
                tree.get(hoveredNode).hovered = false;
                UiEvent ev;
                ev.node = hoveredNode;
                ev.kind = UiEventKind.mouseLeave;
                ev.mouseX = mx;
                ev.mouseY = my;
                queue.push(ev);
            }
            hoveredNode = target;
            if (hoveredNode.isValid() && tree.isValid(hoveredNode)) {
                tree.get(hoveredNode).hovered = true;
                UiEvent ev;
                ev.node = hoveredNode;
                ev.kind = UiEventKind.mouseEnter;
                ev.mouseX = mx;
                ev.mouseY = my;
                queue.push(ev);
            }
        }

        // Mouse Down
        if (input.mousePressed(MouseButton.left)) {
            if (focusedNode.isValid() && focusedNode != target && tree.isValid(focusedNode)) {
                tree.get(focusedNode).focused = false;
            }
            focusedNode = target;
            pressedNode = target;
            dragStartX = mx;
            dragStartY = my;
            isDragging = false;

            if (focusedNode.isValid() && tree.isValid(focusedNode)) {
                tree.get(focusedNode).focused = true;
            }

            if (pressedNode.isValid() && tree.isValid(pressedNode)) {
                tree.get(pressedNode).pressed = true;
                UiEvent ev;
                ev.node = pressedNode;
                ev.kind = UiEventKind.mouseDown;
                ev.mouseX = mx;
                ev.mouseY = my;
                queue.push(ev);
            }
        }

        // Mouse Up & Click
        if (input.mouseUp(MouseButton.left)) {
            if (pressedNode.isValid() && tree.isValid(pressedNode)) {
                tree.get(pressedNode).pressed = false;

                UiEvent ev;
                ev.node = pressedNode;
                ev.kind = UiEventKind.mouseUp;
                ev.mouseX = mx;
                ev.mouseY = my;
                queue.push(ev);

                // If released over same element without dragging -> Click!
                if (pressedNode == target && !isDragging) {
                    UiEvent clickEv;
                    clickEv.node = pressedNode;
                    clickEv.kind = UiEventKind.click;
                    clickEv.mouseX = mx;
                    clickEv.mouseY = my;
                    queue.push(clickEv);
                }
            }
            pressedNode = UiNodeId.init;
            isDragging = false;
        }

        // Context Menu (Right Click)
        if (input.mousePressed(MouseButton.right)) {
            if (target.isValid() && tree.isValid(target)) {
                UiEvent ev;
                ev.node = target;
                ev.kind = UiEventKind.contextMenu;
                ev.mouseX = mx;
                ev.mouseY = my;
                queue.push(ev);
            }
        }

        // Scroll
        if (input.wheelY != 0 || input.wheelX != 0) {
            UiNodeId scrollTarget = hit;
            while (scrollTarget.isValid() && tree.isValid(scrollTarget)) {
                auto sn = &tree.get(scrollTarget);
                if (sn.contentHeight > sn.layoutHeight || sn.contentWidth > sn.layoutWidth) {
                    sn.scrollY -= input.wheelY * 24.0f;
                    if (sn.scrollY < 0) sn.scrollY = 0;
                    immutable float maxScrollY = (sn.contentHeight > sn.layoutHeight) ? (sn.contentHeight - sn.layoutHeight) : 0;
                    if (sn.scrollY > maxScrollY) sn.scrollY = maxScrollY;
                    break;
                }
                scrollTarget = sn.parent;
            }

            if (hit.isValid() && tree.isValid(hit)) {
                UiEvent ev;
                ev.node = hit;
                ev.kind = UiEventKind.scroll;
                ev.wheelX = input.wheelX;
                ev.wheelY = input.wheelY;
                queue.push(ev);
            }
        }

        // Keyboard text input and shortcuts when node is focused
        if (focusedNode.isValid() && tree.isValid(focusedNode)) {
            auto fn = &tree.get(focusedNode);

            // Return / Enter -> Submit
            if (input.keyPressed(Key.return_)) {
                UiEvent ev;
                ev.node = focusedNode;
                ev.kind = UiEventKind.submit;
                queue.push(ev);
            }

            // Backspace
            if (input.keyPressed(Key.backspace) && fn.textLen > 0) {
                // Delete previous UTF-8 character
                size_t prevLen = fn.textLen;
                while (fn.textLen > 0) {
                    fn.textLen--;
                    // UTF-8 continuation byte has top 2 bits == 10 (0x80..0xBF)
                    if ((cast(ubyte)fn.textBuf[fn.textLen] & 0xC0) != 0x80) break;
                }
                fn.layoutDirty = true;

                UiEvent ev;
                ev.node = focusedNode;
                ev.kind = UiEventKind.textChange;
                immutable size_t n = fn.textLen < MAX_EVENT_TEXT ? fn.textLen : MAX_EVENT_TEXT;
                ev.text[0 .. n] = fn.textBuf[0 .. n];
                ev.textLen = cast(uint)n;
                queue.push(ev);
            }

            // Typed characters
            const(char)[] chars = input.textInput;
            if (chars.length > 0) {
                foreach (c; chars) {
                    if (fn.textLen < fn.textBuf.length) {
                        fn.textBuf[fn.textLen++] = c;
                    }
                }
                fn.layoutDirty = true;

                UiEvent ev;
                ev.node = focusedNode;
                ev.kind = UiEventKind.textChange;
                immutable size_t n = fn.textLen < MAX_EVENT_TEXT ? fn.textLen : MAX_EVENT_TEXT;
                ev.text[0 .. n] = fn.textBuf[0 .. n];
                ev.textLen = cast(uint)n;
                queue.push(ev);
            }
        }
    }
}

static assert(isPod!UiInputContext);

unittest {
    import engine.ui.style : UiStyle;

    auto tree = UiTree.create();
    UiStyle rowStyle;
    rowStyle.cursor = UiCursor.pointer;
    auto row = tree.createNode(tree.root, rowStyle);
    tree.get(row).customTag = 42;
    auto label = tree.createNode(row);
    tree.get(label).setText("Cubo");

    assert(UiInputContext.interactiveTarget(tree, label) == row);
    assert(UiInputContext.interactiveTarget(tree, row) == row);

    UiStyle fieldStyle;
    fieldStyle.cursor = UiCursor.text;
    auto field = tree.createNode(row, fieldStyle);
    assert(UiInputContext.interactiveTarget(tree, field) == field);
}
