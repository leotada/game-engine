/// Developer tooling — in-engine debug gizmos and overlay.
///
/// This is the "editor tooling" layer: immediate-mode 3D line drawing
/// (GizmoRenderer) and a text overlay with frame stats and named labels
/// (DebugOverlay). Built on top of the existing renderer + TextRenderer.
module engine.devtools;

public import engine.devtools.gizmos;
public import engine.devtools.overlay;
