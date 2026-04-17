/// Structured developer overlay: frame stats + named label lines,
/// rendered on top of any scene via the existing TextRenderer.
///
/// Usage:
///   auto overlay = DebugOverlay.create();
///   // ... inside the frame loop:
///   overlay.beginFrame(dt);
///   overlay.label("cam", "pos=(", cam.pos.x, ",", cam.pos.y, ",", cam.pos.z, ")");
///   overlay.label("entities", world.aliveCount());
///   overlay.render(text, frame);     // draws on top
///
/// Toggle-able via `overlay.setVisible(bool)` — tie to F1 / backtick / etc.
///
/// Lines are fixed-width char buffers (128 bytes each, up to 32 lines);
/// rendering is @nogc. Formatting uses `std.format.sformat` into the
/// fixed buffer — allowed because this path is developer-facing, not the
/// engine frame-hot path in the strict sense.
module engine.devtools.overlay;

import std.format : sformat;

import engine.gpu.renderer : FrameContext;
import engine.gpu.text     : TextRenderer;

@safe:

private enum size_t MAX_LINES     = 32;
private enum size_t LINE_CAPACITY = 128;

struct DebugOverlay {
    private char[LINE_CAPACITY][MAX_LINES] buffer = 0;
    private size_t[MAX_LINES] lineLen;
    private size_t lineCount = 0;
    private bool   _visible = true;

    // Rolling frame-time average (last 60 samples).
    private float[60] frameTimes = 0;
    private size_t    frameIdx   = 0;
    private size_t    frameSamples = 0;

    bool visible() const nothrow @nogc { return _visible; }
    void setVisible(bool v) nothrow @nogc { _visible = v; }
    void toggle() nothrow @nogc { _visible = !_visible; }

    /// Begin a new frame: reset line buffer, record dt for FPS averaging.
    void beginFrame(float dt) nothrow @nogc {
        lineCount = 0;
        frameTimes[frameIdx] = dt;
        frameIdx = (frameIdx + 1) % frameTimes.length;
        if (frameSamples < frameTimes.length) frameSamples++;
    }

    /// Average frame time (seconds) over the last up-to-60 frames.
    float avgFrameTime() const nothrow @nogc {
        if (frameSamples == 0) return 0;
        float sum = 0;
        foreach (i; 0 .. frameSamples) sum += frameTimes[i];
        return sum / cast(float) frameSamples;
    }

    float avgFps() const nothrow @nogc {
        immutable ft = avgFrameTime();
        return ft > 0 ? (1.0f / ft) : 0;
    }

    /// Add a formatted line. Arguments are concatenated via `sformat("%s%s…")`.
    /// Long lines are truncated at LINE_CAPACITY-1 bytes.
    void label(Args...)(scope const(char)[] name, auto ref Args values) {
        if (lineCount >= MAX_LINES) return;
        auto dst = buffer[lineCount][];
        size_t written;
        // Prefix "name: "
        foreach (i, ch; name) {
            if (written + 2 >= dst.length) break;
            dst[written++] = ch;
        }
        if (written + 2 < dst.length) { dst[written++] = ':'; dst[written++] = ' '; }
        // Build remaining format once: "%s%s..." with one %s per arg.
        static if (Args.length > 0) {
            enum string fmt = genFmt(Args.length);
            try {
                auto slice = sformat(dst[written .. $], fmt, values);
                written += slice.length;
            } catch (Exception) {
                // Overflow — silently truncate.
                written = dst.length - 1;
            }
        }
        lineLen[lineCount] = written;
        lineCount++;
    }

    /// Insert a section header line (no "name:" prefix). Renders as
    /// "-- title --" to visually group following labels.
    void section(scope const(char)[] title) nothrow @nogc {
        if (lineCount >= MAX_LINES) return;
        auto dst = buffer[lineCount][];
        size_t w = 0;
        void put(char c) { if (w < dst.length) dst[w++] = c; }
        put('-'); put('-'); put(' ');
        foreach (ch; title) put(ch);
        put(' '); put('-'); put('-');
        lineLen[lineCount] = w;
        lineCount++;
    }

    /// Render the overlay via an existing `TextRenderer` into `frame`.
    /// Always shows a top FPS line (when visible).
    void render(ref TextRenderer text, ref FrameContext frame,
                float x = 8, float y = 8, int scale = 2,
                float lineSpacing = 20) nothrow @nogc {
        if (!_visible) return;

        // FPS header line — formatted in a stack buffer.
        char[64] hdr = 0;
        size_t hdrLen = writeFpsHeader(hdr[], avgFps(), avgFrameTime());
        text.drawText(frame, hdr[0 .. hdrLen], x, y, scale);

        float cursorY = y + lineSpacing;
        foreach (i; 0 .. lineCount) {
            text.drawText(frame, buffer[i][0 .. lineLen[i]], x, cursorY, scale);
            cursorY += lineSpacing;
        }
    }
}

/// Factory (no GPU resources — overlay piggybacks on the caller's TextRenderer).
DebugOverlay create() nothrow @nogc {
    DebugOverlay o;
    return o;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

private string genFmt(size_t n) pure nothrow {
    string r;
    foreach (i; 0 .. n) r ~= "%s";
    return r;
}

/// Manual integer-only FPS formatter (keeps render() `@nogc`).
private size_t writeFpsHeader(scope char[] dst, float fps, float ft) nothrow @nogc {
    size_t w = 0;
    void put(char c) { if (w < dst.length) dst[w++] = c; }
    void putStr(string s) { foreach (c; s) put(c); }
    void putUInt(uint v) {
        if (v == 0) { put('0'); return; }
        char[12] tmp;
        size_t n = 0;
        while (v > 0 && n < tmp.length) { tmp[n++] = cast(char)('0' + (v % 10)); v /= 10; }
        while (n > 0) put(tmp[--n]);
    }
    putStr("FPS: ");
    putUInt(cast(uint) (fps + 0.5f));
    putStr("  (");
    // ft in milliseconds, 1 decimal (truncated).
    immutable ms10 = cast(uint) (ft * 10000.0f + 0.5f); // tenths of ms
    putUInt(ms10 / 10);
    put('.');
    putUInt(ms10 % 10);
    putStr(" ms)");
    return w;
}
