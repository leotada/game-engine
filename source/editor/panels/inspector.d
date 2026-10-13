/// Inspector: name, transform, mesh, color, physics, and Camera3D.
/// The text buffer lives on `EditorApp` — this panel only displays it.
module editor.panels.inspector;

import engine.ecs.store : EntityId;
import engine.editor.components : Camera3D, MaterialOverride, PhysicsBody, PhysicsMotion, Visual, VisualKind;
import engine.editor.selection : Selection;
import engine.graphics.types : Color4;
import engine.math.quat;
import engine.math.vec : Vec3;
import engine.scene.graph : Transform;
import engine.ui;

@safe:

enum nameFieldTag = 0xE000_0001;
enum physicsToggleTag = 0xC000_0020;
enum cameraCurrentTag = 0xC000_0021;
enum meshCubeTag = 0xC000_0010;
enum meshSphereTag = 0xC000_0011;
enum meshPlaneTag = 0xC000_0012;
enum dragTagBase = 0xE100_0000;

struct InspectorPanel {
    /// `entityName` is the editor's name buffer. `useDragEuler` shows `dragEuler`
    /// instead of extracting the quaternion again (gimbal-safe while dragging).
    void buildUi(W)(
        ref W world,
        ref Selection selection,
        ref UiTree tree,
        UiNodeId parent,
        in UiTheme theme,
        scope const(char)[] entityName,
        bool editable,
        bool useDragEuler,
        Vec3 dragEuler
    ) {
        UiStyle panelStyle;
        panelStyle.direction = UiFlexDirection.column;
        panelStyle.widthMode = UiSizeMode.fill;
        panelStyle.heightMode = UiSizeMode.fill;
        panelStyle.backgroundColor = theme.colors.bgBase;

        UiNodeId panel = tree.createNode(parent, panelStyle);

        UiStyle tbStyle;
        tbStyle.direction = UiFlexDirection.row;
        tbStyle.alignItems = UiAlign.center;
        tbStyle.height = 28.0f;
        tbStyle.heightMode = UiSizeMode.fixed;
        tbStyle.widthMode = UiSizeMode.fill;
        tbStyle.padding = [2.0f, 8.0f, 2.0f, 8.0f];
        tbStyle.backgroundColor = theme.colors.bgSurface;
        tbStyle.borderWidth = 1.0f;
        tbStyle.borderColor = theme.colors.border;

        UiNodeId tb = tree.createNode(panel, tbStyle);
        label(tree, tb, "Inspetor", theme.colors.text, 13.0f);

        if (selection.empty() || !world.alive(selection.primary)) {
            UiStyle emptyStyle;
            emptyStyle.padding = [20.0f, 16.0f, 20.0f, 16.0f];
            UiNodeId emptyRow = tree.createNode(panel, emptyStyle);
            label(tree, emptyRow, "Nenhuma entidade selecionada.", theme.colors.textMuted);
            return;
        }

        EntityId e = selection.primary;
        immutable bool cameraEntity = world.has!Camera3D(e);
        immutable bool meshEntity = world.has!Visual(e)
            && world.get!Visual(e).kind != VisualKind.none
            && !cameraEntity;

        UiNodeId content = scrollView(tree, panel, theme);
        tree.get(content).style.padding = [8.0f, 12.0f, 8.0f, 12.0f];
        tree.get(content).style.gap = 12.0f;

        UiNodeId section(scope const(char)[] title) {
            auto box = tree.createNode(content);
            tree.get(box).style.direction = UiFlexDirection.column;
            tree.get(box).style.gap = 6.0f;
            tree.get(box).style.padding = [6.0f, 8.0f, 6.0f, 8.0f];
            tree.get(box).style.backgroundColor = theme.colors.bgSurface;
            tree.get(box).style.cornerRadius = theme.cornerRadius;
            label(tree, box, title, theme.colors.accent, 13.0f);
            return box;
        }

        auto headerBox = tree.createNode(content);
        tree.get(headerBox).style.direction = UiFlexDirection.row;
        tree.get(headerBox).style.alignItems = UiAlign.center;
        tree.get(headerBox).style.gap = 8.0f;

        if (editable) {
            auto field = textField(tree, headerBox, entityName, theme, 200.0f);
            tree.get(field).customTag = nameFieldTag;
        } else {
            label(tree, headerBox, entityName, theme.colors.text, 13.0f);
        }

        char[32] idBuf;
        import core.stdc.stdio : snprintf;
        import core.stdc.string : strlen;
        () @trusted {
            snprintf(idBuf.ptr, idBuf.length, "ID: %u", e);
        }();
        label(tree, headerBox, idBuf[0 .. () @trusted { return strlen(idBuf.ptr); }()], theme.colors.textMuted, 11.0f);

        if (world.has!Transform(e)) {
            auto tr = world.get!Transform(e);
            auto trBox = section("Transform");
            Vec3 euler = useDragEuler ? dragEuler : tr.rotation.toEulerYXZ();

            auto posRow = tree.createNode(trBox);
            tree.get(posRow).style.direction = UiFlexDirection.row;
            tree.get(posRow).style.gap = 4.0f;
            tagDrag(tree, posRow, "Pos X", tr.position.x, theme, 0, editable);
            tagDrag(tree, posRow, "Y", tr.position.y, theme, 1, editable);
            tagDrag(tree, posRow, "Z", tr.position.z, theme, 2, editable);

            auto rotRow = tree.createNode(trBox);
            tree.get(rotRow).style.direction = UiFlexDirection.row;
            tree.get(rotRow).style.gap = 4.0f;
            tagDrag(tree, rotRow, "Rot X", euler.x, theme, 3, editable);
            tagDrag(tree, rotRow, "Y", euler.y, theme, 4, editable);
            tagDrag(tree, rotRow, "Z", euler.z, theme, 5, editable);

            auto scaleRow = tree.createNode(trBox);
            tree.get(scaleRow).style.direction = UiFlexDirection.row;
            tree.get(scaleRow).style.gap = 4.0f;
            tagDrag(tree, scaleRow, "Esc X", tr.scale.x, theme, 6, editable);
            tagDrag(tree, scaleRow, "Y", tr.scale.y, theme, 7, editable);
            tagDrag(tree, scaleRow, "Z", tr.scale.z, theme, 8, editable);
        }

        if (meshEntity) {
            auto vis = world.get!Visual(e);
            auto visBox = section("Malha");
            auto row = tree.createNode(visBox);
            tree.get(row).style.direction = UiFlexDirection.row;
            tree.get(row).style.gap = 4.0f;
            meshButton(tree, row, "Cubo", vis.kind == VisualKind.cube, meshCubeTag, theme, editable);
            meshButton(tree, row, "Esfera", vis.kind == VisualKind.sphere, meshSphereTag, theme, editable);
            meshButton(tree, row, "Plano", vis.kind == VisualKind.plane, meshPlaneTag, theme, editable);
        }

        if (meshEntity) {
            float r = 1, g = 1, b = 1;
            if (world.has!MaterialOverride(e)) {
                auto m = world.get!MaterialOverride(e);
                r = m.baseColor[0];
                g = m.baseColor[1];
                b = m.baseColor[2];
            }
            auto matBox = section("Cor");
            auto row = tree.createNode(matBox);
            tree.get(row).style.direction = UiFlexDirection.row;
            tree.get(row).style.gap = 4.0f;
            tagDrag(tree, row, "R", r, theme, 9, editable);
            tagDrag(tree, row, "G", g, theme, 10, editable);
            tagDrag(tree, row, "B", b, theme, 11, editable);
        }

        if (meshEntity) {
            bool dynamicOn = false;
            if (world.has!PhysicsBody(e)) {
                auto pb = world.get!PhysicsBody(e);
                dynamicOn = pb.enabled != 0 && pb.motion == PhysicsMotion.dynamic_;
            }
            auto physBox = section("Física");
            if (editable) {
                auto box = checkbox(tree, physBox, "Dinâmico", dynamicOn, theme);
                tree.get(box).customTag = physicsToggleTag;
            } else {
                label(tree, physBox, dynamicOn ? "Dinâmico" : "Estático", theme.colors.text, 12.0f);
            }
        }

        if (cameraEntity) {
            auto cam = world.get!Camera3D(e);
            auto camBox = section("Câmera");
            if (editable) {
                auto box = checkbox(tree, camBox, "Atual", cam.current != 0, theme);
                tree.get(box).customTag = cameraCurrentTag;
            } else {
                label(tree, camBox, cam.current != 0 ? "Atual" : "Inativa", theme.colors.text, 12.0f);
            }
            tagDrag(tree, camBox, "FOV", cam.fovYDeg, theme, 12, editable, 160.0f);
            tagDrag(tree, camBox, "Near", cam.nearPlane, theme, 13, editable, 160.0f);
            tagDrag(tree, camBox, "Far", cam.farPlane, theme, 14, editable, 160.0f);
        }
    }
}

private void tagDrag(
    ref UiTree tree,
    UiNodeId parent,
    scope const(char)[] labelText,
    float value,
    in UiTheme theme,
    uint slot,
    bool writable,
    float width = 80.0f
) nothrow {
    auto id = dragValue(tree, parent, labelText, value, theme, width);
    if (writable)
        tree.get(id).customTag = dragTagBase | slot;
}

private void meshButton(
    ref UiTree tree,
    UiNodeId parent,
    scope const(char)[] text,
    bool active,
    uint tag,
    in UiTheme theme,
    bool writable
) nothrow {
    auto id = button(tree, parent, text, theme);
    if (writable)
        tree.get(id).customTag = tag;
    if (active)
        tree.get(id).style.backgroundColor = theme.colors.accent;
}
