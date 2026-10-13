/// Retained-mode UI style definition and layout properties.
module engine.ui.style;

import engine.core.pod : isPod;
import engine.graphics.types : Color4;

@safe:

enum UiSizeMode : ubyte {
    auto_   = 0,
    fixed   = 1,
    percent = 2,
    fill    = 3,
}

enum UiFlexDirection : ubyte {
    row    = 0,
    column = 1,
}

enum UiJustify : ubyte {
    start        = 0,
    center       = 1,
    end          = 2,
    spaceBetween = 3,
    spaceAround  = 4,
}

enum UiAlign : ubyte {
    start   = 0,
    center  = 1,
    end     = 2,
    stretch = 3,
}

enum UiCursor : ubyte {
    default_ = 0,
    pointer  = 1,
    text     = 2,
    resizeH  = 3,
    resizeV  = 4,
    grab     = 5,
}

enum UiPosition : ubyte {
    relative = 0,
    absolute = 1,
}

struct UiStyle {
    // Positioning
    UiPosition position = UiPosition.relative;
    float left = 0;
    float top  = 0;

    // Layout
    UiFlexDirection direction = UiFlexDirection.row;
    UiJustify justifyContent  = UiJustify.start;
    UiAlign alignItems        = UiAlign.stretch;

    UiSizeMode widthMode  = UiSizeMode.auto_;
    UiSizeMode heightMode = UiSizeMode.auto_;
    float width           = 0;
    float height          = 0;
    float minWidth        = 0;
    float minHeight       = 0;
    float maxWidth        = 100_000.0f;
    float maxHeight       = 100_000.0f;

    float[4] padding = [0, 0, 0, 0]; // top, right, bottom, left
    float[4] margin  = [0, 0, 0, 0];
    float gap = 0;

    float flexGrow   = 0;
    float flexShrink = 1.0f;

    // Appearance
    Color4 backgroundColor = Color4(0, 0, 0, 0);
    Color4 borderColor     = Color4(0, 0, 0, 0);
    float borderWidth      = 0;
    float cornerRadius     = 0;

    // Typography
    Color4 textColor = Color4(0.9f, 0.9f, 0.9f, 1.0f);
    float fontSize   = 13.0f;

    // Interaction
    UiCursor cursor = UiCursor.default_;
    bool clipChildren = false;
}

static assert(isPod!UiStyle);
