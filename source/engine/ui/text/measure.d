/// Fills `UiNode.textWidth/textHeight` from a loaded `Font` so the layout engine
/// can size labels, buttons and tabs to their real glyph metrics.
module engine.ui.text.measure;

import engine.ui.text.font : Font;
import engine.ui.tree;

@safe:

/// Walk the subtree under `id` and measure every node that carries inline text.
/// Call after building the tree and before `computeLayout`.
void measureTextNodes(ref UiTree tree, UiNodeId id, ref Font font) nothrow {
    if (!tree.isValid(id)) return;
    auto n = &tree.get(id);
    if (n.textLen > 0 && font.isLoaded) {
        float w = 0, h = 0;
        font.measure(n.text, w, h);
        n.textWidth = w;
        n.textHeight = h;
    } else {
        n.textWidth = 0;
        n.textHeight = 0;
    }
    UiNodeId child = n.firstChild;
    while (child.isValid()) {
        measureTextNodes(tree, child, font);
        child = tree.get(child).nextSibling;
    }
}
