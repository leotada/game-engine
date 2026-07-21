/// Immediate-mode widgets drawn via TextRenderer with screen-space hit-tests.
module engine.editor.ui.widgets;

import engine.editor.ui.context : UiContext, UiId, UiRect, uiNullId;
import engine.editor.ui.layout : beginRegion, pushIndent, popIndent;

@safe:

// ---------------------------------------------------------------------------
// Panel
// ---------------------------------------------------------------------------

/// Draw a titled panel chrome and set the layout cursor below the title.
/// `area` is registered for mouse capture.
void panel(ref UiContext ui, scope const(char)[] title, UiRect area) nothrow @nogc {
    beginRegion(ui, area);

    // Title line
    auto titleRect = ui.nextLine();
    char[144] buf = void;
    size_t n = 0;
    void put(char c) { if (n < buf.length) buf[n++] = c; }
    put('='); put('='); put(' ');
    foreach (ch; title) {
        if (n + 4 >= buf.length) break;
        put(ch);
    }
    put(' '); put('='); put('=');
    ui.drawText(buf[0 .. n], titleRect.x, titleRect.y);
}

// ---------------------------------------------------------------------------
// Label / separator
// ---------------------------------------------------------------------------

void label(ref UiContext ui, scope const(char)[] text) nothrow @nogc {
    auto r = ui.nextLine();
    ui.drawText(text, r.x, r.y);
}

void separator(ref UiContext ui) nothrow @nogc {
    auto r = ui.advance(ui.lineH * 0.5f);
    immutable w = cast(int)(r.w / ui.glyphW());
    char[96] line = void;
    size_t n = w > cast(int) line.length ? line.length : (w > 0 ? cast(size_t) w : 0);
    foreach (i; 0 .. n) line[i] = '-';
    if (n > 0) ui.drawText(line[0 .. n], r.x, r.y);
}

// ---------------------------------------------------------------------------
// Button
// ---------------------------------------------------------------------------

/// Returns true the frame the button is clicked (release on hot+active).
bool button(ref UiContext ui, scope const(char)[] text) nothrow @nogc {
    immutable id = UiContext.makeId(text);
    auto r = ui.nextLine();

    char[144] buf = void;
    size_t n = 0;
    void put(char c) { if (n < buf.length) buf[n++] = c; }

    immutable hot = ui.isHot(id);
    immutable active = ui.isActive(id);
    put(active ? '{' : '[');
    put(' ');
    foreach (ch; text) {
        if (n + 3 >= buf.length) break;
        put(ch);
    }
    put(' ');
    put(active ? '}' : ']');
    if (hot && !active) {
        // prefix marker when hovered
    }

    immutable clicked = ui.buttonBehavior(id, r);
    ui.drawText(buf[0 .. n], r.x, r.y);
    return clicked;
}

// ---------------------------------------------------------------------------
// Checkbox
// ---------------------------------------------------------------------------

/// Toggle `checked` when clicked. Returns true if value changed.
bool checkbox(ref UiContext ui, scope const(char)[] text, ref bool checked) nothrow @nogc {
    immutable id = UiContext.makeId(text);
    auto r = ui.nextLine();

    char[144] buf = void;
    size_t n = 0;
    void put(char c) { if (n < buf.length) buf[n++] = c; }
    put('[');
    put(checked ? 'x' : ' ');
    put(']');
    put(' ');
    foreach (ch; text) {
        if (n + 1 >= buf.length) break;
        put(ch);
    }

    immutable clicked = ui.buttonBehavior(id, r);
    if (clicked) checked = !checked;
    ui.drawText(buf[0 .. n], r.x, r.y);
    return clicked;
}

// ---------------------------------------------------------------------------
// Slider
// ---------------------------------------------------------------------------

/// Float slider. Mutates `value` while dragging. Returns true if changed.
bool sliderFloat(
    ref UiContext ui,
    scope const(char)[] labelText,
    ref float value,
    float vMin,
    float vMax
) nothrow @nogc {
    if (vMax < vMin) {
        immutable t = vMin;
        vMin = vMax;
        vMax = t;
    }
    immutable range = vMax - vMin;
    immutable id = UiContext.makeId(labelText);
    auto r = ui.nextLine();
    ui.hit(id, r);

    bool changed = false;

    if (ui.hotId == id && ui.mousePressed)
        ui.activeId = id;

    if (ui.isActive(id) && ui.mouseDown && range > 0) {
        // Map mouse X across the widget rect to [vMin, vMax].
        float t = (ui.mouseX - r.x) / (r.w > 1 ? r.w : 1);
        if (t < 0) t = 0;
        if (t > 1) t = 1;
        immutable nv = vMin + t * range;
        if (nv != value) {
            value = nv;
            changed = true;
        }
    }

    // Clamp display value
    if (value < vMin) value = vMin;
    if (value > vMax) value = vMax;

    // Build: label [####----] 1.23
    char[160] buf = void;
    size_t n = 0;
    void put(char c) { if (n < buf.length) buf[n++] = c; }
    foreach (ch; labelText) {
        if (n + 20 >= buf.length) break;
        put(ch);
    }
    put(' ');
    put('[');

    enum barSlots = 12;
    float tBar = range > 0 ? (value - vMin) / range : 0;
    if (tBar < 0) tBar = 0;
    if (tBar > 1) tBar = 1;
    immutable filled = cast(int)(tBar * barSlots + 0.5f);
    foreach (i; 0 .. barSlots) {
        put(i < filled ? '#' : '-');
    }
    put(']');
    put(' ');

    // append formatted value
    auto vs = ui.formatScratch("", value);
    foreach (ch; vs) {
        if (n >= buf.length) break;
        put(ch);
    }

    ui.drawText(buf[0 .. n], r.x, r.y);
    return changed;
}

// ---------------------------------------------------------------------------
// Text field (ASCII)
// ---------------------------------------------------------------------------

/// Single-line ASCII text field. `buf` is a fixed caller-owned buffer;
/// `len` is the current string length (in/out).
///
/// Typing: while active, printable ASCII keys append; backspace deletes.
/// Pass key events via `textFieldKey` after the widget call, or use the
/// overload that accepts an optional typed character / backspace flag.
bool textField(
    ref UiContext ui,
    scope const(char)[] labelText,
    scope char[] buf,
    ref size_t len,
    char typedChar = 0,
    bool backspace = false
) nothrow @nogc {
    if (buf.length == 0) return false;
    if (len > buf.length) len = buf.length;

    immutable id = UiContext.makeId(labelText);
    auto r = ui.nextLine();
    immutable clicked = ui.buttonBehavior(id, r);

    bool changed = false;
    if (ui.isActive(id) || clicked) {
        ui.activeId = id;
        if (backspace && len > 0) {
            len--;
            changed = true;
        } else if (typedChar >= 32 && typedChar <= 126 && len < buf.length) {
            buf[len++] = typedChar;
            changed = true;
        }
    }

    // Draw: label [contents_]
    char[160] line = void;
    size_t n = 0;
    void put(char c) { if (n < line.length) line[n++] = c; }
    foreach (ch; labelText) {
        if (n + 8 >= line.length) break;
        put(ch);
    }
    put(' ');
    put(ui.isActive(id) ? '{' : '[');
    immutable maxShow = line.length > n + 2 ? line.length - n - 2 : 0;
    immutable show = len < maxShow ? len : maxShow;
    foreach (i; 0 .. show) put(buf[i]);
    if (ui.isActive(id) && n < line.length) put('_');
    put(ui.isActive(id) ? '}' : ']');

    ui.drawText(line[0 .. n], r.x, r.y);
    return changed;
}

// ---------------------------------------------------------------------------
// Combo
// ---------------------------------------------------------------------------

/// Dropdown combo. `items` are option labels; `selected` is the index.
/// Returns true if selection changed.
bool combo(
    ref UiContext ui,
    scope const(char)[] labelText,
    scope const(char[])[] items,
    ref int selected,
    ref bool open
) nothrow @nogc {
    if (items.length == 0) return false;
    if (selected < 0) selected = 0;
    if (selected >= cast(int) items.length) selected = cast(int) items.length - 1;

    immutable id = UiContext.makeId(labelText);
    auto r = ui.nextLine();

    char[160] buf = void;
    size_t n = 0;
    void put(char c) { if (n < buf.length) buf[n++] = c; }
    foreach (ch; labelText) {
        if (n + 16 >= buf.length) break;
        put(ch);
    }
    put(' ');
    put('[');
    foreach (ch; items[selected]) {
        if (n + 4 >= buf.length) break;
        put(ch);
    }
    put(' ');
    put(open ? '^' : 'v');
    put(']');

    immutable clicked = ui.buttonBehavior(id, r);
    if (clicked) open = !open;
    ui.drawText(buf[0 .. n], r.x, r.y);

    bool changed = false;
    if (open) {
        pushIndent(ui);
        foreach (i, item; items) {
            // Unique id per item
            immutable itemId = UiContext.makeId(item, id);
            auto ir = ui.nextLine();
            char[144] ibuf = void;
            size_t in_ = 0;
            void iput(char c) { if (in_ < ibuf.length) ibuf[in_++] = c; }
            iput(cast(int) i == selected ? '>' : ' ');
            iput(' ');
            foreach (ch; item) {
                if (in_ + 1 >= ibuf.length) break;
                iput(ch);
            }
            if (ui.buttonBehavior(itemId, ir)) {
                if (selected != cast(int) i) {
                    selected = cast(int) i;
                    changed = true;
                }
                open = false;
            }
            ui.drawText(ibuf[0 .. in_], ir.x, ir.y);
        }
        popIndent(ui);
    }
    return changed;
}

// ---------------------------------------------------------------------------
// Tree node
// ---------------------------------------------------------------------------

/// Collapsible tree node. Caller owns `open`. Returns true while open
/// (so callers can draw children inside `if (treeNode(...)) { ... }`).
bool treeNode(ref UiContext ui, scope const(char)[] text, ref bool open) nothrow @nogc {
    immutable id = UiContext.makeId(text);
    auto r = ui.nextLine();

    char[144] buf = void;
    size_t n = 0;
    void put(char c) { if (n < buf.length) buf[n++] = c; }
    put(open ? 'v' : '>');
    put(' ');
    foreach (ch; text) {
        if (n + 1 >= buf.length) break;
        put(ch);
    }

    if (ui.buttonBehavior(id, r))
        open = !open;
    ui.drawText(buf[0 .. n], r.x, r.y);
    return open;
}

// ---------------------------------------------------------------------------
// Unit tests — slider mutates float (no GPU)
// ---------------------------------------------------------------------------

@safe unittest {
    UiContext ui;
    float value = 0.25f;

    // Frame 1: press on the slider row
    ui.beginFrame(50, 5, true, true, false, 400, 300);
    ui.setCursor(0, 0, 200);
    // Simulate: first call registers hit; mouse at mid-ish of rect
    ui.sliderFloat("gain", value, 0.0f, 1.0f);
    ui.endFrame();
    assert(ui.activeId != uiNullId);

    // Frame 2: drag toward the right edge → value increases
    ui.beginFrame(190, 5, true, false, false, 400, 300);
    ui.setCursor(0, 0, 200);
    immutable changed = ui.sliderFloat("gain", value, 0.0f, 1.0f);
    ui.endFrame();
    assert(changed);
    assert(value > 0.5f);
    assert(value <= 1.0f);
}

@safe unittest {
    UiContext ui;
    bool on = false;
    ui.beginFrame(10, 5, true, true, false, 400, 300);
    ui.setCursor(0, 0, 200);
    ui.checkbox("enabled", on); // press
    ui.endFrame();

    ui.beginFrame(10, 5, false, false, true, 400, 300);
    ui.setCursor(0, 0, 200);
    immutable changed = ui.checkbox("enabled", on); // release
    ui.endFrame();
    assert(changed);
    assert(on);
}
