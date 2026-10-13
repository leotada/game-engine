/// Retained UI color palette, themes, and styling constants.
module engine.ui.theme;

import engine.core.pod : isPod;
import engine.graphics.types : Color4;
import engine.ui.style : UiStyle;

@safe:

/// Color palette for UI theme.
struct UiColors {
    Color4 bgBase       = Color4(0.12f, 0.12f, 0.14f, 1.0f); // #1e1e24
    Color4 bgSurface    = Color4(0.16f, 0.16f, 0.19f, 1.0f); // #292930
    Color4 bgElevated   = Color4(0.20f, 0.20f, 0.24f, 1.0f); // #33333d
    Color4 bgInput      = Color4(0.10f, 0.10f, 0.12f, 1.0f); // #19191f
    Color4 bgHover      = Color4(0.24f, 0.24f, 0.28f, 1.0f);
    Color4 bgActive     = Color4(0.28f, 0.28f, 0.34f, 1.0f);

    Color4 border       = Color4(0.24f, 0.24f, 0.28f, 1.0f);
    Color4 borderLight  = Color4(0.32f, 0.32f, 0.38f, 1.0f);
    Color4 borderFocus  = Color4(0.25f, 0.50f, 0.95f, 1.0f);

    Color4 text         = Color4(0.92f, 0.92f, 0.95f, 1.0f);
    Color4 textDim      = Color4(0.65f, 0.65f, 0.70f, 1.0f);
    Color4 textMuted    = Color4(0.45f, 0.45f, 0.50f, 1.0f);

    Color4 accent       = Color4(0.23f, 0.48f, 0.92f, 1.0f); // #3a7afe
    Color4 accentHover  = Color4(0.31f, 0.55f, 0.99f, 1.0f);
    Color4 accentActive = Color4(0.18f, 0.42f, 0.85f, 1.0f);

    Color4 success      = Color4(0.22f, 0.69f, 0.30f, 1.0f);
    Color4 warning      = Color4(0.95f, 0.65f, 0.10f, 1.0f);
    Color4 error        = Color4(0.90f, 0.25f, 0.25f, 1.0f);
}

static assert(isPod!UiColors);

/// Theme defining styles for widgets.
struct UiTheme {
    UiColors colors;
    float defaultFontSize = 13.0f;
    float controlHeight   = 24.0f;
    float cornerRadius    = 4.0f;
    float borderWidth     = 1.0f;

    /// Style for a standard button.
    UiStyle buttonStyle() const nothrow @nogc pure {
        UiStyle s;
        s.height = controlHeight;
        s.heightMode = typeof(s.heightMode).fixed;
        s.backgroundColor = colors.bgElevated;
        s.borderColor = colors.border;
        s.borderWidth = borderWidth;
        s.cornerRadius = cornerRadius;
        s.textColor = colors.text;
        s.fontSize = defaultFontSize;
        s.padding = [4.0f, 10.0f, 4.0f, 10.0f];
        s.cursor = typeof(s.cursor).pointer;
        s.flexShrink = 0;
        return s;
    }

    /// Style for a text input field.
    UiStyle inputStyle() const nothrow @nogc pure {
        UiStyle s;
        s.height = controlHeight;
        s.heightMode = typeof(s.heightMode).fixed;
        s.backgroundColor = colors.bgInput;
        s.borderColor = colors.border;
        s.borderWidth = borderWidth;
        s.cornerRadius = cornerRadius;
        s.textColor = colors.text;
        s.fontSize = defaultFontSize;
        s.padding = [4.0f, 8.0f, 4.0f, 8.0f];
        s.cursor = typeof(s.cursor).text;
        return s;
    }

    /// Style for panel headers / dock tabs.
    UiStyle tabStyle(bool active = false) const nothrow @nogc pure {
        UiStyle s;
        s.height = 26.0f;
        s.heightMode = typeof(s.heightMode).fixed;
        s.backgroundColor = active ? colors.bgSurface : colors.bgBase;
        s.borderColor = colors.border;
        s.borderWidth = borderWidth;
        s.cornerRadius = cornerRadius;
        s.textColor = active ? colors.text : colors.textDim;
        s.fontSize = defaultFontSize;
        s.padding = [4.0f, 12.0f, 4.0f, 12.0f];
        s.cursor = typeof(s.cursor).pointer;
        return s;
    }
}

static assert(isPod!UiTheme);
