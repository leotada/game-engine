/// Dock space hierarchy, tab management, split trees, and drop zones.
module engine.ui.dock.dock_space;

import engine.core.pod : isPod, Pod;

@safe:

enum DockKind : ubyte {
    leaf = 0,
    splitHorizontal = 1, // Left | Right
    splitVertical   = 2, // Top / Bottom
}

enum MAX_DOCK_TABS = 8;
enum MAX_TAB_NAME_LEN = 32;

/// A node in the dock tree (strictly POD).
struct DockNode {
    uint id = 0;
    DockKind kind = DockKind.leaf;
    bool inUse = false;

    // For splits
    float splitRatio = 0.5f; // ratio of childA size (0.05 .. 0.95)
    uint childA = 0;
    uint childB = 0;

    // For leaf nodes
    char[MAX_TAB_NAME_LEN][MAX_DOCK_TABS] tabNames;
    uint[MAX_DOCK_TABS] tabNameLens;
    uint tabCount = 0;
    uint activeTab = 0;

    // Computed layout bounds in pixels
    float x = 0;
    float y = 0;
    float width = 0;
    float height = 0;

    /// Add a tab title to leaf node.
    bool addTab(scope const(char)[] title) nothrow @nogc {
        if (tabCount >= MAX_DOCK_TABS) return false;
        immutable size_t n = title.length < MAX_TAB_NAME_LEN ? title.length : MAX_TAB_NAME_LEN;
        tabNames[tabCount][0 .. n] = title[0 .. n];
        tabNameLens[tabCount] = cast(uint)n;
        tabCount++;
        return true;
    }

    /// Read tab title at index.
    const(char)[] getTab(uint index) return const nothrow @nogc pure {
        if (index >= tabCount) return "";
        return tabNames[index][0 .. tabNameLens[index]];
    }

    /// Read active tab title.
    const(char)[] getActiveTab() return const nothrow @nogc pure {
        if (tabCount == 0 || activeTab >= tabCount) return "";
        return tabNames[activeTab][0 .. tabNameLens[activeTab]];
    }

    /// Close tab at index.
    void removeTab(uint index) nothrow @nogc {
        if (index >= tabCount) return;
        foreach (i; index .. tabCount - 1) {
            tabNames[i] = tabNames[i + 1];
            tabNameLens[i] = tabNameLens[i + 1];
        }
        tabCount--;
        if (activeTab >= tabCount && tabCount > 0) {
            activeTab = tabCount - 1;
        }
    }
}

static assert(isPod!DockNode);

/// Retained dock manager with hierarchical splits and tab stacks.
struct DockSpace {
    enum MAX_NODES = 64;
    DockNode[MAX_NODES] pool;
    private uint rootIndex = 0;
    private uint nextNodeId = 1;

    /// Allocate a new node in pool.
    uint allocateNode(DockKind kind = DockKind.leaf) nothrow @nogc {
        foreach (uint i; 1 .. MAX_NODES) {
            if (!pool[i].inUse) {
                pool[i] = DockNode.init;
                pool[i].id = nextNodeId++;
                pool[i].kind = kind;
                pool[i].inUse = true;
                return i;
            }
        }
        return 0; // pool exhausted
    }

    /// Free a node.
    void freeNode(uint idx) nothrow @nogc {
        if (idx > 0 && idx < MAX_NODES) {
            pool[idx].inUse = false;
        }
    }

    /// Access node by pool index.
    ref DockNode node(uint idx) return nothrow @nogc {
        assert(idx > 0 && idx < MAX_NODES && pool[idx].inUse);
        return pool[idx];
    }

    /// Const access node by pool index.
    ref const(DockNode) node(uint idx) return const nothrow @nogc {
        assert(idx > 0 && idx < MAX_NODES && pool[idx].inUse);
        return pool[idx];
    }

    /// Root node index.
    uint root() const nothrow @nogc pure {
        return rootIndex;
    }

    /// Set root node.
    void setRoot(uint r) nothrow @nogc {
        rootIndex = r;
    }

    /// Initialize standard default 4-zone layout (Godot style).
    /// - Left: Cena
    /// - Center: Viewport (active) and Game
    /// - Right: Inspetor
    /// - Bottom: Arquivos and Console
    void initDefaultLayout(float width, float height) nothrow @nogc {
        // Clear all
        foreach (uint i; 1 .. MAX_NODES) pool[i].inUse = false;

        // Leaf: Left (Cena)
        uint leftLeaf = allocateNode(DockKind.leaf);
        pool[leftLeaf].addTab("Cena");

        // Leaf: Center (Viewport starts active; Game stays as the second tab)
        uint centerLeaf = allocateNode(DockKind.leaf);
        pool[centerLeaf].addTab("Viewport");
        pool[centerLeaf].addTab("Game");

        // Leaf: Right (Inspetor)
        uint rightLeaf = allocateNode(DockKind.leaf);
        pool[rightLeaf].addTab("Inspetor");

        // Leaf: Bottom (Arquivos, Console)
        uint bottomLeaf = allocateNode(DockKind.leaf);
        pool[bottomLeaf].addTab("Arquivos");
        pool[bottomLeaf].addTab("Console");

        // Center split H: Left | Center
        uint leftCenterSplit = allocateNode(DockKind.splitHorizontal);
        pool[leftCenterSplit].splitRatio = 0.22f;
        pool[leftCenterSplit].childA = leftLeaf;
        pool[leftCenterSplit].childB = centerLeaf;

        // Top split H: (Left|Center) | Right
        uint topSplit = allocateNode(DockKind.splitHorizontal);
        pool[topSplit].splitRatio = 0.78f;
        pool[topSplit].childA = leftCenterSplit;
        pool[topSplit].childB = rightLeaf;

        // Root split V: Top | Bottom
        uint mainSplit = allocateNode(DockKind.splitVertical);
        pool[mainSplit].splitRatio = 0.70f;
        pool[mainSplit].childA = topSplit;
        pool[mainSplit].childB = bottomLeaf;

        rootIndex = mainSplit;
        computeLayout(0, 0, width, height);
    }

    /// Compute bounds recursively for all dock nodes.
    void computeLayout(float x, float y, float w, float h) nothrow @nogc {
        if (rootIndex == 0 || !pool[rootIndex].inUse) return;
        layoutNode(rootIndex, x, y, w, h);
    }

    private void layoutNode(uint idx, float x, float y, float w, float h) nothrow @nogc {
        if (idx == 0 || idx >= MAX_NODES || !pool[idx].inUse) return;

        auto n = &pool[idx];
        n.x = x;
        n.y = y;
        n.width = w;
        n.height = h;

        if (n.kind == DockKind.splitHorizontal) {
            immutable float wA = w * n.splitRatio;
            immutable float wB = w - wA;
            layoutNode(n.childA, x, y, wA, h);
            layoutNode(n.childB, x + wA, y, wB, h);
        } else if (n.kind == DockKind.splitVertical) {
            immutable float hA = h * n.splitRatio;
            immutable float hB = h - hA;
            layoutNode(n.childA, x, y, w, hA);
            layoutNode(n.childB, x, y + hA, w, hB);
        }
    }

    /// Find the leaf dock node containing (mx, my).
    uint findLeafAt(float mx, float my) const nothrow @nogc {
        if (rootIndex == 0) return 0;
        return findLeafRecursive(rootIndex, mx, my);
    }

    private uint findLeafRecursive(uint idx, float mx, float my) const nothrow @nogc {
        if (idx == 0 || idx >= MAX_NODES || !pool[idx].inUse) return 0;
        const n = &pool[idx];

        if (mx < n.x || mx > n.x + n.width || my < n.y || my > n.y + n.height) {
            return 0;
        }

        if (n.kind == DockKind.leaf) {
            return idx;
        }

        uint hitA = findLeafRecursive(n.childA, mx, my);
        if (hitA != 0) return hitA;
        return findLeafRecursive(n.childB, mx, my);
    }

    /// Move tab from one leaf to another.
    bool moveTab(uint srcLeaf, uint srcTabIndex, uint dstLeaf) nothrow @nogc {
        if (srcLeaf == 0 || dstLeaf == 0 || srcLeaf >= MAX_NODES || dstLeaf >= MAX_NODES) return false;
        if (!pool[srcLeaf].inUse || !pool[dstLeaf].inUse) return false;
        if (pool[srcLeaf].kind != DockKind.leaf || pool[dstLeaf].kind != DockKind.leaf) return false;
        if (srcTabIndex >= pool[srcLeaf].tabCount) return false;

        const(char)[] title = pool[srcLeaf].getTab(srcTabIndex);
        if (!pool[dstLeaf].addTab(title)) return false;

        pool[srcLeaf].removeTab(srcTabIndex);
        return true;
    }
}

static assert(isPod!DockSpace);

unittest {
    DockSpace dock;
    dock.initDefaultLayout(1024, 768);

    assert(dock.root != 0);
    assert(dock.node(dock.root).kind == DockKind.splitVertical);

    // Test findLeafAt
    uint leaf = dock.findLeafAt(100, 100);
    assert(leaf != 0);
    assert(dock.node(leaf).kind == DockKind.leaf);
    assert(dock.node(leaf).getTab(0) == "Cena");

    // Center starts on Viewport and keeps the Game tab.
    uint centerLeaf = dock.findLeafAt(500, 200);
    assert(centerLeaf != 0);
    assert(dock.node(centerLeaf).getActiveTab() == "Viewport");
    assert(dock.node(centerLeaf).getTab(1) == "Game");
    assert(dock.node(centerLeaf).tabCount == 2);

    uint rightLeaf = dock.findLeafAt(900, 100);
    assert(rightLeaf != 0);
    assert(dock.node(rightLeaf).getTab(0) == "Inspetor");

    uint bottomLeaf = dock.findLeafAt(400, 700);
    assert(bottomLeaf != 0);
    assert(dock.node(bottomLeaf).getActiveTab() == "Arquivos");
    assert(dock.node(bottomLeaf).getTab(1) == "Console");

    // Moving Cena onto the center leaf makes that leaf's tab count 3.
    bool ok = dock.moveTab(leaf, 0, centerLeaf);
    assert(ok);
    assert(dock.node(centerLeaf).tabCount == 3);
}
