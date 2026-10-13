/// Editor keyboard shortcuts and command bindings.
module editor.shortcuts;

import engine.platform.input : InputState, Key, MouseButton;

@safe:

enum EditorAction : ubyte {
    none = 0,
    saveScene,
    openScene,
    newScene,
    undo,
    redo,
    duplicate,
    deleteSelection,
    focusCamera,
    togglePlay,
    pausePlay,
    stepPlay,
    gizmoTranslate,
    gizmoRotate,
    gizmoScale,
}

/// Detect triggered editor action from current input state.
/// `textFieldFocused` suppresses letter and Delete shortcuts so typing in a
/// name field does not change the gizmo, focus the camera, or delete.
/// Ctrl+S, Ctrl+O, Ctrl+N, Ctrl+Z, Ctrl+Y, Ctrl+Shift+Z, and Ctrl+P still run.
EditorAction pollShortcuts(in InputState input, bool textFieldFocused = false) nothrow @nogc {
    immutable bool ctrl = input.ctrlDown();
    immutable bool shift = input.shiftDown();

    // Scene & File — still active while a text field is focused.
    if (ctrl && input.keyPressed(Key.s)) return EditorAction.saveScene;
    if (ctrl && input.keyPressed(Key.o)) return EditorAction.openScene;
    if (ctrl && input.keyPressed(Key.n)) return EditorAction.newScene;

    // Undo / Redo (Ctrl+Shift+Z before Ctrl+Z).
    if (ctrl && shift && input.keyPressed(Key.z)) return EditorAction.redo;
    if (ctrl && input.keyPressed(Key.z)) return EditorAction.undo;
    if (ctrl && input.keyPressed(Key.y)) return EditorAction.redo;

    // Play — still active while typing.
    if (ctrl && input.keyPressed(Key.p)) return EditorAction.togglePlay;

    if (textFieldFocused)
        return EditorAction.none;

    // Edit operations. Delete is the only delete shortcut (not Key.x).
    if (ctrl && input.keyPressed(Key.d)) return EditorAction.duplicate;
    if (input.keyPressed(Key.delete_)) return EditorAction.deleteSelection;
    if (input.keyPressed(Key.f)) return EditorAction.focusCamera;

    // Gizmo modes (when not navigating with RMB)
    if (!input.mouseDown(MouseButton.right)) {
        if (input.keyPressed(Key.w) || input.keyPressed(Key.digit1)) return EditorAction.gizmoTranslate;
        if (input.keyPressed(Key.e) || input.keyPressed(Key.digit2)) return EditorAction.gizmoRotate;
        if (input.keyPressed(Key.r) || input.keyPressed(Key.digit3)) return EditorAction.gizmoScale;
    }

    return EditorAction.none;
}
