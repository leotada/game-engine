/// Immediate-mode UI context: mouse/hot/active ids, frame lifecycle,
/// screen-space AABB hit-testing, and TextRenderer drawing hooks.
module engine.editor.ui.context;

import engine.gpu.renderer : FrameContext;
import engine.gpu.text : TextRenderer;

@safe:

/// Stable widget identity (0 = none).
alias UiId = uint;

enum UiId uiNullId = 0;

/// Screen-space axis-aligned rect (origin top-left, y down).
struct UiRect {
    float x = 0, y = 0, w = 0, h = 0;

    bool contains(float px, float py) const nothrow @nogc {
        return px >= x && px < x + w && py >= y && py < y + h;
    }
}

/// Per-frame immediate-mode UI state.
///
/// Typical usage:
/// ```
/// ui.beginFrame(input.mx, input.my, mouseDown, mousePressed, mouseReleased, w, h);
/// ui.bindRenderer(text, frame);
/// if (ui.button(...)) { ... }
/// if (ui.wantCaptureMouse) { /* don't pick scene */ }
/// ui.endFrame();
/// ```
struct UiContext {
    // --- Input (copied at beginFrame) ---
    float mouseX = 0;
    float mouseY = 0;
    bool  mouseDown = false;
    bool  mousePressed = false;
    bool  mouseReleased = false;

    // --- Interaction ---
    UiId hotId = uiNullId;
    UiId activeId = uiNullId;
    /// True if the cursor overlapped any registered UI rect this frame.
    bool overUi = false;
    /// True if a click should be eaten (over UI or dragging a widget).
    bool wantCaptureMouse = false;

    // --- Layout cursor (vertical stack) ---
    float cursorX = 0;
    float cursorY = 0;
    float contentW = 200;
    float indent = 0;
    float lineH = 18;
    float padX = 4;
    float padY = 2;
    int   textScale = 1; // glyph = 8 * scale pixels

    float screenW = 0;
    float screenH = 0;

    // --- Optional draw targets (null = hit-test / layout only) ---
    private TextRenderer* textPtr = null;
    private FrameContext* framePtr = null;

    /// Fixed scratch for widget label formatting (no GC).
    char[160] scratch = void;
    size_t scratchLen = 0;

    /// Start a UI frame. Resets hot/over and layout cursor.
    void beginFrame(
        float mx, float my,
        bool down, bool pressed, bool released,
        float sw, float sh
    ) nothrow @nogc {
        mouseX = mx;
        mouseY = my;
        mouseDown = down;
        mousePressed = pressed;
        mouseReleased = released;
        screenW = sw;
        screenH = sh;

        hotId = uiNullId;
        overUi = false;
        wantCaptureMouse = false;
        textPtr = null;
        framePtr = null;

        cursorX = 0;
        cursorY = 0;
        indent = 0;
        contentW = sw;
        lineH = cast(float)(8 * textScale + 2);
    }

    /// Bind TextRenderer + FrameContext for this frame's draw calls.
    /// Pointers must remain valid until `endFrame`.
    void bindRenderer(ref TextRenderer text, ref FrameContext frame) nothrow @nogc @trusted {
        textPtr = &text;
        framePtr = &frame;
    }

    /// Finish the frame: clear active if mouse released; set capture flag.
    void endFrame() nothrow @nogc {
        if (!mouseDown)
            activeId = uiNullId;
        wantCaptureMouse = overUi || (activeId != uiNullId);
    }

    /// True when the scene should ignore this click / drag.
    bool consumeClick() const nothrow @nogc {
        return wantCaptureMouse || overUi || (activeId != uiNullId);
    }

    /// Glyph pixel size for the current text scale.
    float glyphW() const nothrow @nogc { return cast(float)(8 * textScale); }
    float glyphH() const nothrow @nogc { return cast(float)(8 * textScale); }

    /// Measure ASCII text width in pixels.
    float measureText(scope const(char)[] s) const nothrow @nogc {
        size_t n = 0;
        foreach (ch; s) {
            if (ch >= 32 && ch <= 127) n++;
        }
        return cast(float) n * glyphW();
    }

    /// Draw text if a renderer is bound; otherwise no-op.
    void drawText(scope const(char)[] s, float x, float y) nothrow @nogc {
        if (textPtr is null || framePtr is null || !framePtr.valid) return;
        textPtr.drawText(*framePtr, s, x, y, textScale);
    }

    /// Place the layout cursor at an absolute position and set stack width.
    void setCursor(float x, float y, float width) nothrow @nogc {
        cursorX = x;
        cursorY = y;
        contentW = width;
        indent = 0;
    }

    /// Advance the vertical stack by `h` pixels; returns the reserved rect.
    UiRect advance(float h) nothrow @nogc {
        immutable x = cursorX + indent;
        immutable y = cursorY;
        immutable w = contentW - indent;
        cursorY += h + padY;
        return UiRect(x, y, w > 0 ? w : 0, h);
    }

    /// Reserve one line of `lineH` height.
    UiRect nextLine() nothrow @nogc {
        return advance(lineH);
    }

    /// Hash a label into a UiId (FNV-1a 32-bit). Optional seed for nesting.
    static UiId makeId(scope const(char)[] label, UiId seed = uiNullId) nothrow @nogc {
        uint h = seed != uiNullId ? seed : 2166136261u;
        foreach (ch; label) {
            h ^= cast(uint) ch;
            h *= 16777619u;
        }
        // Never return null id for a non-empty label.
        if (h == uiNullId) h = 1;
        return h;
    }

    /// Register a rect for hit-testing; updates hotId / overUi.
    void hit(UiId id, UiRect r) nothrow @nogc {
        if (!r.contains(mouseX, mouseY)) return;
        overUi = true;
        // Last-registered wins (later widgets on top).
        hotId = id;
    }

    /// Register a non-interactive panel/background rect (captures mouse only).
    void hitCapture(UiRect r) nothrow @nogc {
        if (r.contains(mouseX, mouseY))
            overUi = true;
    }

    /// Classic IM button behaviour. Returns true on click (press→release on same id).
    bool buttonBehavior(UiId id, UiRect r) nothrow @nogc {
        hit(id, r);

        if (hotId == id && mousePressed)
            activeId = id;

        if (mouseReleased && activeId == id && hotId == id) {
            activeId = uiNullId;
            return true;
        }
        return false;
    }

    bool isHot(UiId id) const nothrow @nogc { return hotId == id; }
    bool isActive(UiId id) const nothrow @nogc { return activeId == id; }

    /// Format into `scratch` via a tiny @nogc integer/float helper set.
    /// Returns the written slice (valid until next formatScratch).
    const(char)[] formatScratch(scope const(char)[] prefix, float value) return nothrow @nogc {
        size_t p = 0;
        void put(char c) {
            if (p < scratch.length) scratch[p++] = c;
        }
        foreach (ch; prefix) put(ch);

        // sign
        float v = value;
        if (v < 0) { put('-'); v = -v; }

        // integer part
        int ip = cast(int) v;
        float frac = v - cast(float) ip;
        char[12] digits = void;
        size_t nd = 0;
        if (ip == 0) {
            digits[nd++] = '0';
        } else {
            int t = ip;
            while (t > 0 && nd < digits.length) {
                digits[nd++] = cast(char)('0' + (t % 10));
                t /= 10;
            }
        }
        foreach_reverse (i; 0 .. nd) put(digits[i]);

        put('.');
        // two decimal places
        int f1 = cast(int)(frac * 10.0f) % 10;
        int f2 = cast(int)(frac * 100.0f) % 10;
        if (f1 < 0) f1 = -f1;
        if (f2 < 0) f2 = -f2;
        put(cast(char)('0' + f1));
        put(cast(char)('0' + f2));

        scratchLen = p;
        return scratch[0 .. scratchLen];
    }
}

@safe unittest {
    UiContext ui;
    ui.beginFrame(10, 10, false, false, false, 800, 600);
    assert(ui.hotId == uiNullId);
    assert(!ui.overUi);

    immutable id = UiContext.makeId("btn");
    auto r = UiRect(0, 0, 100, 20);
    ui.hit(id, r);
    assert(ui.overUi);
    assert(ui.hotId == id);

    ui.endFrame();
    assert(ui.wantCaptureMouse);
}
