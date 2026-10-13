/// Retained-mode UI tree and node pool.
module engine.ui.tree;

import engine.core.pod : isPod, Pod;
import engine.graphics.types : Color4;
import engine.ui.style : UiStyle;

@safe:

/// Generational identifier for a UI node.
struct UiNodeId {
    uint index = 0;
    uint generation = 0;

    bool isValid() const nothrow @nogc pure {
        return index != 0;
    }

    bool opEquals(in UiNodeId other) const nothrow @nogc pure {
        return index == other.index && generation == other.generation;
    }
}

static assert(isPod!UiNodeId);

/// Maximum inline text length in a node (for labels, button text, etc.).
enum MAX_NODE_TEXT = 128;

/// A node in the retained UI tree (strictly POD).
struct UiNode {
    // Generational identity
    uint generation = 1;
    bool inUse = false;

    // Hierarchy (linked list of siblings, parent, first/last child)
    UiNodeId parent;
    UiNodeId firstChild;
    UiNodeId lastChild;
    UiNodeId prevSibling;
    UiNodeId nextSibling;
    uint childCount = 0;

    // Style & Appearance
    UiStyle style;

    // Computed layout coordinates (relative to window / root)
    float layoutX = 0;
    float layoutY = 0;
    float layoutWidth = 0;
    float layoutHeight = 0;

    // Scroll offset for scrollable containers
    float scrollX = 0;
    float scrollY = 0;
    float contentWidth = 0;
    float contentHeight = 0;

    // Intrinsic (preferred) size, filled by the layout measure pass
    float prefW = 0;
    float prefH = 0;

    // Measured size of the inline text in pixels (filled by `measureTextNodes`)
    float textWidth = 0;
    float textHeight = 0;

    // Interaction flags
    bool visible = true;
    bool enabled = true;
    bool hovered = false;
    bool pressed = false;
    bool focused = false;
    bool layoutDirty = true;

    // Inline text
    char[MAX_NODE_TEXT] textBuf;
    uint textLen = 0;

    // Optional texture / image identifier or handle (0 = solid/none)
    ulong textureHandle = 0;
    uint customTag = 0;
    uint nextFree = 0;

    /// Set inline text.
    void setText(scope const(char)[] s) nothrow @nogc {
        immutable uint n = cast(uint)(s.length < MAX_NODE_TEXT ? s.length : MAX_NODE_TEXT);
        textBuf[0 .. n] = s[0 .. n];
        textLen = n;
        layoutDirty = true;
    }

    /// Read inline text.
    const(char)[] text() return const nothrow @nogc pure {
        return textBuf[0 .. textLen];
    }
}

static assert(isPod!UiNode);

/// Retained UI tree managing the node pool, hierarchy, and dirty flags.
struct UiTree {
    private enum INITIAL_CAPACITY = 1024;
    private Pod!UiNode[] nodes;
    private uint firstFree = 0;
    private UiNodeId _root;

    /// Initialize the tree and allocate the root node.
    static UiTree create() nothrow {
        UiTree tree;
        tree.nodes.length = INITIAL_CAPACITY;
        foreach (uint i; 1 .. INITIAL_CAPACITY - 1) {
            tree.nodes[i].nextFree = i + 1;
        }
        tree.nodes[INITIAL_CAPACITY - 1].nextFree = 0;
        tree.firstFree = 1;

        // Spawn root
        tree._root = tree.allocateNode();
        auto r = &tree.nodes[tree._root.index];
        r.style.widthMode = typeof(r.style.widthMode).fill;
        r.style.heightMode = typeof(r.style.heightMode).fill;
        return tree;
    }

    /// Root node of the tree.
    UiNodeId root() const nothrow @nogc pure {
        return _root;
    }

    /// Total number of nodes allocated in pool.
    size_t capacity() const nothrow @nogc pure {
        return nodes.length;
    }

    /// Check if node ID is currently valid and active.
    bool isValid(UiNodeId id) const nothrow @nogc pure {
        if (id.index == 0 || id.index >= nodes.length) return false;
        const n = &nodes[id.index];
        return n.inUse && n.generation == id.generation;
    }

    /// Access node by ID.
    ref UiNode get(UiNodeId id) return nothrow @nogc {
        assert(isValid(id), "UiTree.get: invalid UiNodeId");
        return nodes[id.index];
    }

    /// Const access node by ID.
    ref const(UiNode) get(UiNodeId id) return const nothrow @nogc {
        assert(isValid(id), "UiTree.get: invalid UiNodeId");
        return nodes[id.index];
    }

    /// Create a new child node under parent.
    UiNodeId createNode(UiNodeId parentId, in UiStyle style = UiStyle.init) nothrow {
        UiNodeId childId = allocateNode();
        auto child = &nodes[childId.index];
        child.style = style;
        child.layoutDirty = true;

        if (parentId.isValid()) {
            appendChild(parentId, childId);
        }
        return childId;
    }

    /// Add a child to parent.
    void appendChild(UiNodeId parentId, UiNodeId childId) nothrow @nogc {
        assert(isValid(parentId), "appendChild: parent invalid");
        assert(isValid(childId), "appendChild: child invalid");

        auto p = &nodes[parentId.index];
        auto c = &nodes[childId.index];

        c.parent = parentId;
        c.prevSibling = p.lastChild;
        c.nextSibling = UiNodeId.init;

        if (p.lastChild.isValid()) {
            nodes[p.lastChild.index].nextSibling = childId;
            p.lastChild = childId;
        } else {
            p.firstChild = childId;
            p.lastChild = childId;
        }
        p.childCount++;
        p.layoutDirty = true;
    }

    /// Remove a child from its parent without freeing it.
    void removeChild(UiNodeId childId) nothrow @nogc {
        if (!isValid(childId)) return;
        auto c = &nodes[childId.index];
        if (!c.parent.isValid()) return;

        auto p = &nodes[c.parent.index];

        if (c.prevSibling.isValid()) {
            nodes[c.prevSibling.index].nextSibling = c.nextSibling;
        } else {
            p.firstChild = c.nextSibling;
        }

        if (c.nextSibling.isValid()) {
            nodes[c.nextSibling.index].prevSibling = c.prevSibling;
        } else {
            p.lastChild = c.prevSibling;
        }

        if (p.childCount > 0) p.childCount--;
        p.layoutDirty = true;

        c.parent = UiNodeId.init;
        c.prevSibling = UiNodeId.init;
        c.nextSibling = UiNodeId.init;
    }

    /// Recursively destroy node and its children.
    void destroyNode(UiNodeId id) nothrow @nogc {
        if (!isValid(id)) return;

        // Destroy all children first
        UiNodeId child = nodes[id.index].firstChild;
        while (child.isValid()) {
            UiNodeId next = nodes[child.index].nextSibling;
            destroyNode(child);
            child = next;
        }

        // Unlink from parent
        removeChild(id);

        // Recycle slot
        auto n = &nodes[id.index];
        n.inUse = false;
        n.generation++;
        n.childCount = 0;
        n.firstChild = UiNodeId.init;
        n.lastChild = UiNodeId.init;
        n.nextFree = firstFree;
        firstFree = id.index;
    }

    /// Drop every node except the root and rebuild the free list in ascending
    /// order, WITHOUT bumping generations. A UI that is rebuilt from scratch
    /// every frame therefore hands out the same `UiNodeId`s each frame as long
    /// as its structure is unchanged, which keeps hover / press / focus state
    /// (stored by id in `UiInputContext`) valid across rebuilds.
    void resetForRebuild() nothrow @nogc {
        immutable uint rootIdx = _root.index;
        firstFree = 0;
        foreach_reverse (uint i; 1 .. cast(uint)nodes.length) {
            if (i == rootIdx) continue;
            nodes[i].inUse = false;
            nodes[i].nextFree = firstFree;
            firstFree = i;
        }
        auto r = &nodes[rootIdx];
        r.firstChild = UiNodeId.init;
        r.lastChild = UiNodeId.init;
        r.childCount = 0;
        r.layoutDirty = true;
    }

    /// Clear all children under a parent node.
    void clearChildren(UiNodeId parentId) nothrow @nogc {
        if (!isValid(parentId)) return;
        UiNodeId child = nodes[parentId.index].firstChild;
        while (child.isValid()) {
            UiNodeId next = nodes[child.index].nextSibling;
            destroyNode(child);
            child = next;
        }
    }

    private UiNodeId allocateNode() nothrow {
        if (firstFree == 0) {
            immutable size_t oldCap = nodes.length;
            immutable size_t newCap = oldCap * 2;
            nodes.length = newCap;
            foreach (uint i; cast(uint)oldCap .. cast(uint)newCap - 1) {
                nodes[i].nextFree = i + 1;
            }
            nodes[newCap - 1].nextFree = 0;
            firstFree = cast(uint)oldCap;
        }

        immutable uint idx = firstFree;
        firstFree = nodes[idx].nextFree;

        // Reset EVERYTHING: a recycled slot must not leak layout results,
        // hover/press flags, tags or textures from its previous occupant.
        immutable uint gen = nodes[idx].generation;
        nodes[idx] = UiNode.init;
        auto n = &nodes[idx];
        n.generation = gen;
        n.inUse = true;

        return UiNodeId(idx, gen);
    }
}

unittest {
    auto tree = UiTree.create();
    assert(tree.root.isValid());

    auto child1 = tree.createNode(tree.root);
    auto child2 = tree.createNode(tree.root);
    assert(tree.get(tree.root).childCount == 2);
    assert(tree.get(child1).parent == tree.root);
    assert(tree.get(child1).nextSibling == child2);
    assert(tree.get(child2).prevSibling == child1);

    tree.get(child1).setText("Hello UI");
    assert(tree.get(child1).text == "Hello UI");

    tree.destroyNode(child1);
    assert(!tree.isValid(child1));
    assert(tree.get(tree.root).childCount == 1);
    assert(tree.get(tree.root).firstChild == child2);
}
