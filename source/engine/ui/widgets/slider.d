/// Slider widget for scalar value editing.
module engine.ui.widgets.slider;

import engine.graphics.types : Color4;
import engine.ui.style;
import engine.ui.theme;
import engine.ui.tree;

@safe:

/// Create a horizontal slider widget.
UiNodeId slider(
    ref UiTree tree,
    UiNodeId parent,
    float value,
    float minVal,
    float maxVal,
    in UiTheme theme = UiTheme.init,
    float width = 120.0f
) nothrow {
    // Slider track
    UiStyle trackStyle;
    trackStyle.width = width;
    trackStyle.height = theme.controlHeight;
    trackStyle.widthMode = UiSizeMode.fixed;
    trackStyle.heightMode = UiSizeMode.fixed;
    trackStyle.backgroundColor = theme.colors.bgInput;
    trackStyle.borderColor = theme.colors.border;
    trackStyle.borderWidth = 1.0f;
    trackStyle.cornerRadius = theme.cornerRadius;
    trackStyle.direction = UiFlexDirection.row;
    trackStyle.alignItems = UiAlign.center;
    trackStyle.padding = [2.0f, 2.0f, 2.0f, 2.0f];
    trackStyle.cursor = UiCursor.pointer;

    UiNodeId track = tree.createNode(parent, trackStyle);

    // Filled portion
    float norm = 0;
    if (maxVal > minVal) {
        norm = (value - minVal) / (maxVal - minVal);
        if (norm < 0) norm = 0;
        if (norm > 1) norm = 1;
    }

    UiStyle fillStyle;
    fillStyle.width = (width - 4.0f) * norm;
    fillStyle.height = theme.controlHeight - 4.0f;
    fillStyle.widthMode = UiSizeMode.fixed;
    fillStyle.heightMode = UiSizeMode.fixed;
    fillStyle.backgroundColor = theme.colors.accent;
    fillStyle.cornerRadius = theme.cornerRadius - 1.0f;
    fillStyle.alignItems = UiAlign.center;
    fillStyle.justifyContent = UiJustify.center;

    UiNodeId fill = tree.createNode(track, fillStyle);

    // Value text overlay
    char[32] valBuf;
    import core.stdc.stdio : snprintf;
    () @trusted {
        snprintf(valBuf.ptr, valBuf.length, "%.2f", value);
    }();
    import core.stdc.string : strlen;
    size_t len = () @trusted { return strlen(valBuf.ptr); }();
    tree.get(track).setText(valBuf[0 .. len]);

    return track;
}
