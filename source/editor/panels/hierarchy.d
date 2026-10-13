/// Hierarchy panel displaying the scene's entity graph and spawn controls.
module editor.panels.hierarchy;

import editor.panels.inspector : nameFieldTag;
import engine.core.strings : StringTable;
import engine.ecs.store : EntityId;
import engine.editor.components : Camera3D, Name, Parent, Visual, VisualKind, noParent;
import engine.editor.selection : Selection, noSelection;
import engine.graphics.types : Color4;
import engine.scene.graph : Transform;
import engine.ui;

@safe:

struct HierarchyPanel {
    UiNodeId renameField;

    /// Build the Hierarchy panel UI. `renamingId` shows a text field on that row.
    void buildUi(W)(
        ref W world,
        ref Selection selection,
        ref StringTable strings,
        ref UiTree tree,
        UiNodeId parent,
        in UiTheme theme,
        EntityId renamingId,
        scope const(char)[] renameText,
        scope void delegate(scope const(char)[] primitiveType) @safe onSpawnPrimitive
    ) {
        renameField = UiNodeId.init;
        // Container
        UiStyle panelStyle;
        panelStyle.direction = UiFlexDirection.column;
        panelStyle.widthMode = UiSizeMode.fill;
        panelStyle.heightMode = UiSizeMode.fill;
        panelStyle.backgroundColor = theme.colors.bgBase;

        UiNodeId panel = tree.createNode(parent, panelStyle);

        // Header Toolbar
        UiStyle tbStyle;
        tbStyle.direction = UiFlexDirection.row;
        tbStyle.alignItems = UiAlign.center;
        tbStyle.justifyContent = UiJustify.spaceBetween;
        tbStyle.height = 28.0f;
        tbStyle.heightMode = UiSizeMode.fixed;
        tbStyle.widthMode = UiSizeMode.fill;
        tbStyle.padding = [2.0f, 8.0f, 2.0f, 8.0f];
        tbStyle.backgroundColor = theme.colors.bgSurface;
        tbStyle.borderWidth = 1.0f;
        tbStyle.borderColor = theme.colors.border;

        UiNodeId tb = tree.createNode(panel, tbStyle);
        label(tree, tb, "Cena", theme.colors.text, 13.0f);

        // Create entity button
        UiNodeId addBtn = button(tree, tb, "+ Criar", theme);
        tree.get(addBtn).customTag = 0xD000_0006; // popup Criar

        // Entity list scroll view
        UiNodeId listContainer = scrollView(tree, panel, theme);

        // Render entities
        foreach (EntityId e; world.query!Transform()) {
            if (!world.alive(e)) continue;

            // Only root entities directly (children indented if Parent is set)
            uint depth = 0;
            if (world.has!Parent(e)) {
                EntityId p = world.get!Parent(e).entity;
                if (p != noParent && world.alive(p)) {
                    depth = 1;
                }
            }

            char[64] nameBuf;
            size_t n = 0;
            bool named = false;
            if (world.has!Name(e)) {
                const(char)[] nStr = strings.get(world.get!Name(e).id);
                if (nStr.length > 0) {
                    copyLabel(nameBuf, n, nStr);
                    named = true;
                }
            }
            if (!named)
                copyLabel(nameBuf, n, fallbackLabel(world, e));

            bool isSelected = selection.isSelected(e);
            if (renamingId == e) {
                UiStyle rowStyle;
                rowStyle.direction = UiFlexDirection.row;
                rowStyle.alignItems = UiAlign.center;
                rowStyle.height = 22.0f;
                rowStyle.heightMode = UiSizeMode.fixed;
                rowStyle.widthMode = UiSizeMode.fill;
                rowStyle.backgroundColor = theme.colors.accent;
                rowStyle.padding = [1.0f, 4.0f, 1.0f, 4.0f + depth * 16.0f];
                UiNodeId row = tree.createNode(listContainer, rowStyle);
                UiNodeId field = textField(tree, row, renameText, theme, 160.0f);
                tree.get(field).style.height = 18.0f;
                tree.get(field).style.heightMode = UiSizeMode.fixed;
                tree.get(field).customTag = nameFieldTag;
                renameField = field;
            } else {
                UiNodeId row = treeItem(tree, listContainer, nameBuf[0 .. n], depth, false, false, isSelected, theme);
                // High prefix so tag 0 is never entity 0. Do not use 0xB1000000.
                tree.get(row).customTag = 0xB000_0000 | (e & 0x0FFF_FFFF);
            }
        }
    }
}

private void copyLabel(ref char[64] buf, ref size_t n, scope const(char)[] src) pure nothrow @nogc @safe {
    immutable size_t copyN = src.length < buf.length ? src.length : buf.length;
    buf[0 .. copyN] = src[0 .. copyN];
    n = copyN;
}

/// Name is preferred. Otherwise Cubo / Esfera / Plano, Câmera, or Entidade.
private const(char)[] fallbackLabel(W)(ref W world, EntityId e) {
    if (world.has!Camera3D(e))
        return "Câmera";
    if (world.has!Visual(e)) {
        final switch (world.get!Visual(e).kind) {
            case VisualKind.none: return "Entidade";
            case VisualKind.cube: return "Cubo";
            case VisualKind.sphere: return "Esfera";
            case VisualKind.plane: return "Plano";
            case VisualKind.mesh: return "Entidade";
        }
    }
    return "Entidade";
}
