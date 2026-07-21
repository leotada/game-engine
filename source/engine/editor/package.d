/// Level-editor core (ED-1…ED-8): picking, selection (multi), TRS gizmos,
/// commands + undo/redo, hierarchy + inspector, lights UI, physics Simulate/Esc,
/// scene save/load (`*.scene.json`).
/// Builds on `engine.editor.ui`.
///
/// ```
/// import engine.editor;
///
/// EditorWorld world;
/// Selection sel;
/// GizmoTool gizmo;
/// CommandStack cmds;
/// HierarchyState hier;
/// InspectorState insp;
/// LightPanelState lights;
/// PhysicsSimSession sim;
/// PhysicsWorld physics;
/// float[3] gravity = [0, -9.81f, 0];
///
/// // Ctrl+S / Ctrl+O / New (ASCII paths — no native dialog in v1):
/// // newScene(world, lights.scene, gravity);
/// // saveScene(world, "assets/scenes/arena_01.scene.json", lights.scene, gravity, "arena_01");
/// // loadScene(world, "assets/scenes/arena_01.scene.json", lights.scene, gravity);
///
/// // per frame (viewport mouse, after UI begin):
/// auto ray = screenToWorldRay(mx, my, vw, vh, viewProj);
/// if (!ui.consumeClick() && !gizmo.wantCaptureMouse && mousePressed) {
///     auto hit = pickClosestAabb(world, ray);
///     if (hit.hit) {
///         if (shift) sel.toggle(hit.entity); else sel.select(hit.entity);
///     } else if (!shift) sel.clear();
/// }
/// gizmo.update(world, sel, ray, pressed, down, released);
/// if (gizmo.dragJustEnded)
///     recordGizmoDrag(cmds, world, gizmo.dragIds[0 .. gizmo.dragCount],
///                     gizmo.dragStarts[0 .. gizmo.dragCount]);
/// gizmo.draw(world, sel.primary, gizmos);
/// drawAllLightGizmos(world, gizmos, lights.scene);
/// drawSelectionHighlights(world, sel, gizmos);
/// drawPhysicsColliderGizmos(world, gizmos, makeAssetResolver(world));
///
/// auto cols = editorColumns(sw, sh);
/// drawHierarchy(ui, cols.hierarchy, world, sel, cmds, hier, lights);
/// drawInspector(ui, cols.inspector, world, sel, cmds, insp, gizmo, lights);
/// drawPhysicsSimControls(ui, world, sim, physics, makeAssetResolver(world));
/// sim.handleEscape(world, input.keyPressed(Key.escape));
/// sim.tick(world, physics, dt);
/// auto packed = packLightsFromWorld(world, lights.scene);
/// ```
module engine.editor;

public import engine.editor.ui;
public import engine.editor.components;
public import engine.editor.picking;
public import engine.editor.selection;
public import engine.editor.gizmo_tool;
public import engine.editor.commands;
public import engine.editor.hierarchy;
public import engine.editor.inspector;
public import engine.editor.light_panel;
public import engine.editor.light_gizmos;
public import engine.editor.physics_sim;
public import engine.editor.physics_panel;
public import engine.editor.scene_load;
public import engine.editor.scene_io;
