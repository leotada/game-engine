/// Inspector panel — Transform (Euler↔quat), Name, Visual, MaterialOverride,
/// Light (via `light_panel`).
module engine.editor.inspector;

import engine.core.strings : StringId;
import engine.editor.commands : CommandStack, recordMaterial, recordTransform;
import engine.editor.components : MaterialOverride, Name, Visual, VisualKind;
import engine.editor.gizmo_tool : GizmoMode, GizmoSpace, GizmoTool;
import engine.editor.light_panel : LightPanelState, drawLightInspectorSection;
import engine.editor.physics_panel : PhysicsPanelState, drawPhysicsPanel;
import engine.editor.selection : Selection, noSelection;
import engine.editor.ui :
    UiContext, UiRect, checkbox, combo, label, panel, separator, sliderFloat, textField;
import engine.ecs.store : EntityId;
import engine.math.quat : Quat;
import engine.math.vec : Vec3;
import engine.scene.graph : Transform;

@safe:

/// Inspector scratch / undo-commit state (survives across frames).
struct InspectorState {
    // Name edit buffer
    char[64] nameBuf = void;
    size_t nameLen = 0;
    EntityId nameBound = noSelection;

    // Transform edit (Euler degrees for UI)
    Vec3 eulerDeg = Vec3(0, 0, 0);
    EntityId eulerBound = noSelection;
    Transform transformAtEditStart;
    bool editingTransform = false;

    // Material undo baseline
    MaterialOverride matAtEditStart;
    bool editingMaterial = false;
    EntityId matBound = noSelection;

    // Combo open flags
    bool visualKindOpen = false;
    bool gizmoModeOpen = false;
    bool gizmoSpaceOpen = false;

    /// ED-5 physics inspector scratch (combos + bake status).
    PhysicsPanelState physics;
}

/// Draw inspector for the current selection. Mutates world components live.
/// Returns true if any property changed this frame.
bool drawInspector(W)(
    ref UiContext ui,
    UiRect area,
    ref W world,
    ref Selection sel,
    ref CommandStack stack,
    ref InspectorState state,
    ref GizmoTool gizmo,
    ref LightPanelState lights
) {
    panel(ui, "Inspector", area);
    bool changed = false;

    // Tool settings (always visible)
    label(ui, "Tools");
    {
        int mode = cast(int) gizmo.mode;
        scope const(char[])[] modes = ["Translate", "Rotate", "Scale"];
        if (combo(ui, "Mode", modes, mode, state.gizmoModeOpen)) {
            gizmo.mode = cast(GizmoMode) mode;
            changed = true;
        }
        int space = cast(int) gizmo.space;
        scope const(char[])[] spaces = ["World", "Local"];
        if (combo(ui, "Space", spaces, space, state.gizmoSpaceOpen)) {
            gizmo.space = cast(GizmoSpace) space;
            changed = true;
        }
        if (checkbox(ui, "Snap", gizmo.snapEnabled))
            changed = true;
        if (gizmo.snapEnabled && sliderFloat(ui, "Snap step", gizmo.translateSnap, 0.05f, 2.0f))
            changed = true;
        if (checkbox(ui, "Grid", gizmo.showGrid))
            changed = true;
    }
    separator(ui);

    if (sel.empty || !world.alive(sel.primary)) {
        label(ui, "(nothing selected)");
        return changed;
    }

    if (sel.count > 1) {
        char[48] buf = void;
        size_t n = 0;
        void put(char c) { if (n < buf.length) buf[n++] = c; }
        put('[');
        // write count
        {
            char[10] digits = void;
            size_t nd = 0;
            uint v = cast(uint) sel.count;
            if (v == 0) digits[nd++] = '0';
            else while (v > 0 && nd < digits.length) {
                digits[nd++] = cast(char)('0' + (v % 10));
                v /= 10;
            }
            foreach_reverse (i; 0 .. nd) put(digits[i]);
        }
        immutable msg = " selected]";
        foreach (ch; msg) put(ch);
        label(ui, buf[0 .. n]);
    }

    immutable id = sel.primary;

    // --- Name ---
    if (syncNameBuffer(world, id, state)) {
        // rebound
    }
    char typed = 0;
    bool back = false;
    if (textField(ui, "Name", state.nameBuf[], state.nameLen, typed, back)) {
        auto sid = world.strings.intern(state.nameBuf[0 .. state.nameLen]);
        world.set(id, Name(sid));
        changed = true;
    }

    // --- Transform ---
    if (world.has!Transform(id)) {
        label(ui, "Transform");
        auto t = world.get!Transform(id);

        if (state.eulerBound != id) {
            state.eulerDeg = t.rotation.toEulerYXZ();
            state.eulerBound = id;
            state.transformAtEditStart = t;
            state.editingTransform = false;
        }

        bool xformChanged = false;
        if (sliderFloat(ui, "Pos X", t.position.x, -50, 50)) xformChanged = true;
        if (sliderFloat(ui, "Pos Y", t.position.y, -50, 50)) xformChanged = true;
        if (sliderFloat(ui, "Pos Z", t.position.z, -50, 50)) xformChanged = true;

        if (sliderFloat(ui, "Rot X", state.eulerDeg.x, -180, 180)) xformChanged = true;
        if (sliderFloat(ui, "Rot Y", state.eulerDeg.y, -180, 180)) xformChanged = true;
        if (sliderFloat(ui, "Rot Z", state.eulerDeg.z, -180, 180)) xformChanged = true;

        if (sliderFloat(ui, "Scale X", t.scale.x, 0.01f, 20)) xformChanged = true;
        if (sliderFloat(ui, "Scale Y", t.scale.y, 0.01f, 20)) xformChanged = true;
        if (sliderFloat(ui, "Scale Z", t.scale.z, 0.01f, 20)) xformChanged = true;

        if (xformChanged) {
            if (!state.editingTransform) {
                state.transformAtEditStart = world.get!Transform(id);
                state.editingTransform = true;
            }
            t.rotation = Quat.fromEulerYXZ(state.eulerDeg);
            world.set(id, t);
            changed = true;
        }

        // Commit undo when mouse released after editing
        if (state.editingTransform && ui.mouseReleased) {
            recordTransform(stack, id, state.transformAtEditStart, world.get!Transform(id));
            state.editingTransform = false;
            state.transformAtEditStart = world.get!Transform(id);
        }
    }

    // --- Visual ---
    if (world.has!Visual(id)) {
        separator(ui);
        label(ui, "Visual");
        auto vis = world.get!Visual(id);
        int kind = cast(int) vis.kind;
        if (kind < 0) kind = 0;
        if (kind > 4) kind = 4;
        scope const(char[])[] kinds = ["none", "cube", "sphere", "plane", "mesh"];
        if (combo(ui, "Kind", kinds, kind, state.visualKindOpen)) {
            vis.kind = cast(VisualKind) kind;
            world.set(id, vis);
            changed = true;
        }
    }

    // --- Material ---
    if (world.has!MaterialOverride(id)) {
        separator(ui);
        label(ui, "Material");
        auto mat = world.get!MaterialOverride(id);

        if (state.matBound != id) {
            state.matAtEditStart = mat;
            state.matBound = id;
            state.editingMaterial = false;
        }

        bool matChanged = false;
        bool active = mat.active != 0;
        if (checkbox(ui, "Override", active)) {
            mat.active = active ? 1 : 0;
            matChanged = true;
        }
        if (sliderFloat(ui, "Base R", mat.baseColor[0], 0, 1)) matChanged = true;
        if (sliderFloat(ui, "Base G", mat.baseColor[1], 0, 1)) matChanged = true;
        if (sliderFloat(ui, "Base B", mat.baseColor[2], 0, 1)) matChanged = true;
        if (sliderFloat(ui, "Metallic", mat.metallic, 0, 1)) matChanged = true;
        if (sliderFloat(ui, "Roughness", mat.roughness, 0, 1)) matChanged = true;

        if (matChanged) {
            if (!state.editingMaterial) {
                state.matAtEditStart = world.get!MaterialOverride(id);
                state.editingMaterial = true;
            }
            world.set(id, mat);
            changed = true;
        }
        if (state.editingMaterial && ui.mouseReleased) {
            recordMaterial(stack, id, state.matAtEditStart, world.get!MaterialOverride(id));
            state.editingMaterial = false;
            state.matAtEditStart = world.get!MaterialOverride(id);
        }
    }

    // --- Light (ED-6) ---
    if (drawLightInspectorSection(ui, world, id, lights))
        changed = true;

    // --- Physics (ED-5) ---
    if (drawPhysicsPanel(ui, world, id, state.physics))
        changed = true;

    return changed;
}

/// Apply `MaterialOverride` into GPU `MaterialParams`-compatible floats.
/// Caller uploads to the material UBO / instance tint.
void materialOverrideToParams(
    ref const MaterialOverride m,
    ref float[4] baseColor,
    ref float metallic,
    ref float roughness
) nothrow @nogc {
    if (m.active == 0) {
        baseColor = [1, 1, 1, 1];
        metallic = 0;
        roughness = 1;
        return;
    }
    baseColor = m.baseColor;
    metallic = m.metallic;
    roughness = m.roughness;
}

private bool syncNameBuffer(W)(ref W world, EntityId id, ref InspectorState state) {
    if (state.nameBound == id) return false;
    state.nameBound = id;
    state.nameLen = 0;
    if (world.has!Name(id)) {
        auto s = world.strings.get(world.get!Name(id).id);
        immutable n = s.length < state.nameBuf.length ? s.length : state.nameBuf.length;
        foreach (i; 0 .. n)
            state.nameBuf[i] = s[i];
        state.nameLen = n;
    }
    return true;
}

@safe unittest {
    MaterialOverride m;
    m.roughness = 0.3f;
    m.active = 1;
    float[4] bc;
    float met, rough;
    materialOverrideToParams(m, bc, met, rough);
    assert(rough == 0.3f);
}
