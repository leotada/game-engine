/// Hierarchy panel — entity tree via editor immediate-mode UI.
module engine.editor.hierarchy;

import engine.editor.commands :
    CommandStack, alignSelectedToGround, copyAttrsFromPrimary, defaultLightName,
    defaultNameFor, deleteSelected, duplicateSelected, spawnDefaultLightEntity,
    spawnPrimitive;
import engine.editor.components : Name, Parent, VisualKind, noParent;
import engine.editor.light_panel :
    LightPanelState, canSpawnAnyLight, countLightBudgets, drawSceneSettingsInline,
    formatLightBudgetHint;
import engine.editor.selection : Selection, noSelection;
import engine.editor.ui :
    UiContext, UiRect, button, label, panel, pushIndent, popIndent, separator, treeNode;
import engine.ecs.store : EntityId;
import engine.math.vec : Vec3;
import engine.scene.graph : Transform;

@safe:

/// Persistent hierarchy UI state (tree open flags).
struct HierarchyState {
    enum cap = 512;
    bool[cap] open; /// false until first expand toggle (drawn open by default via treeNode caller).
    bool rootOpen = true;
    bool initialized = false;

    void ensureInit() nothrow @nogc {
        if (initialized) return;
        foreach (ref o; open) o = true;
        initialized = true;
    }
}

private ref bool openFlag(return ref HierarchyState st, EntityId id) nothrow @nogc {
    if (id >= HierarchyState.cap)
        return st.rootOpen;
    return st.open[id];
}

private void formatEntityLabel(
    ref char[96] buf,
    ref size_t len,
    EntityId id,
    scope const(char)[] name
) nothrow @nogc {
    len = 0;
    void put(char c) {
        if (len < buf.length) buf[len++] = c;
    }
    if (name.length > 0) {
        foreach (ch; name) put(ch);
        return;
    }
    put('#');
    char[10] digits = void;
    size_t nd = 0;
    uint v = id;
    if (v == 0) {
        digits[nd++] = '0';
    } else {
        while (v > 0 && nd < digits.length) {
            digits[nd++] = cast(char)('0' + (v % 10));
            v /= 10;
        }
    }
    foreach_reverse (i; 0 .. nd) put(digits[i]);
}

private bool hasChildren(W)(ref W world, EntityId id) nothrow @nogc {
    foreach (cid; world.query!(Parent)()) {
        if (world.alive(cid) && world.get!Parent(cid).entity == id)
            return true;
    }
    return false;
}

/// Draw hierarchy column. Returns a focus-request entity id, or `noSelection`.
EntityId drawHierarchy(W)(
    ref UiContext ui,
    UiRect area,
    ref W world,
    ref Selection sel,
    ref CommandStack stack,
    ref HierarchyState state,
    ref LightPanelState lights
) {
    panel(ui, "Hierarchy", area);
    state.ensureInit();

    EntityId focusRequest = noSelection;

    if (button(ui, "Spawn Cube")) {
        auto name = defaultNameFor(world.strings, VisualKind.cube);
        Transform t;
        t.position = Vec3(0, 0.5f, 0);
        spawnPrimitive(world, stack, sel, VisualKind.cube, t, name);
    }
    if (button(ui, "Spawn Sphere")) {
        auto name = defaultNameFor(world.strings, VisualKind.sphere);
        Transform t;
        t.position = Vec3(0, 0.5f, 0);
        spawnPrimitive(world, stack, sel, VisualKind.sphere, t, name);
    }
    if (canSpawnAnyLight(world)) {
        if (button(ui, "Spawn Light")) {
            auto name = defaultLightName(world.strings);
            Transform t;
            t.position = Vec3(0, 2, 0);
            spawnDefaultLightEntity(world, stack, sel, t, name);
        }
    } else {
        label(ui, "(light budget full)");
    }
    if (button(ui, "Duplicate") && !sel.empty)
        duplicateSelected(world, stack, sel);
    if (button(ui, "Delete") && !sel.empty)
        deleteSelected(world, stack, sel);
    if (button(ui, "Align Ground") && !sel.empty)
        alignSelectedToGround(world, stack, sel);
    if (button(ui, "Copy Attrs") && sel.count >= 2)
        copyAttrsFromPrimary(world, stack, sel);
    if (button(ui, "Focus") && !sel.empty)
        focusRequest = sel.primary;

    {
        char[64] hint = void;
        immutable c = countLightBudgets(world);
        immutable n = formatLightBudgetHint(c, hint[]);
        label(ui, hint[0 .. n]);
    }

    separator(ui);
    label(ui, "Entities");

    if (treeNode(ui, "Scene", state.rootOpen)) {
        pushIndent(ui);
        foreach (id; world.query!(Transform)()) {
            if (!world.alive(id)) continue;
            if (world.has!Parent(id)) {
                immutable p = world.get!Parent(id).entity;
                if (p != noParent && world.alive(p))
                    continue;
            }
            drawNode(ui, world, sel, state, id);
        }
        popIndent(ui);
    }

    drawSceneSettingsInline(ui, lights);
    return focusRequest;
}

private void drawNode(W)(
    ref UiContext ui,
    ref W world,
    ref Selection sel,
    ref HierarchyState state,
    EntityId id
) {
    char[96] labelBuf = void;
    size_t labelLen = 0;
    const(char)[] nameSlice = null;
    if (world.has!Name(id))
        nameSlice = world.strings.get(world.get!Name(id).id);
    formatEntityLabel(labelBuf, labelLen, id, nameSlice);

    char[112] row = void;
    size_t n = 0;
    void put(char c) { if (n < row.length) row[n++] = c; }
    put(sel.isSelected(id) ? '>' : ' ');
    put(' ');
    foreach (ch; labelBuf[0 .. labelLen]) put(ch);

    immutable kids = hasChildren(world, id);
    if (kids) {
        if (treeNode(ui, row[0 .. n], openFlag(state, id))) {
            // Selecting via tree click: also offer explicit select
            if (button(ui, "select"))
                sel.select(id);
            pushIndent(ui);
            foreach (cid; world.query!(Parent)()) {
                if (!world.alive(cid)) continue;
                if (world.get!Parent(cid).entity == id)
                    drawNode(ui, world, sel, state, cid);
            }
            popIndent(ui);
        }
    } else {
        if (button(ui, row[0 .. n]))
            sel.select(id);
    }
}
