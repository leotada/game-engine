/// Per-frame keyboard & mouse input tracking built on SDL3 events.
module engine.platform.input;

import bindings.sdl3;
import core.stdc.stdio : fprintf, stderr;

@safe:

/// Keyboard key identifiers (subset — extend as needed).
enum Key : uint {
    unknown  = 0,
    escape   = SDL_Scancode.SCANCODE_ESCAPE,
    space    = SDL_Scancode.SCANCODE_SPACE,
    tab      = SDL_Scancode.SCANCODE_TAB,
    lshift   = SDL_Scancode.SCANCODE_LSHIFT,
    lctrl    = SDL_Scancode.SCANCODE_LCTRL,
    w        = SDL_Scancode.SCANCODE_W,
    a        = SDL_Scancode.SCANCODE_A,
    s        = SDL_Scancode.SCANCODE_S,
    d        = SDL_Scancode.SCANCODE_D,
    e        = SDL_Scancode.SCANCODE_E,
    f        = SDL_Scancode.SCANCODE_F,
    g        = SDL_Scancode.SCANCODE_G,
    b        = SDL_Scancode.SCANCODE_B,
    q        = SDL_Scancode.SCANCODE_Q,
    r        = SDL_Scancode.SCANCODE_R,
    n        = SDL_Scancode.SCANCODE_N,
    o        = SDL_Scancode.SCANCODE_O,
    p        = SDL_Scancode.SCANCODE_P,
    x        = SDL_Scancode.SCANCODE_X,
    y        = SDL_Scancode.SCANCODE_Y,
    z        = SDL_Scancode.SCANCODE_Z,
    c        = SDL_Scancode.SCANCODE_C,
    equals   = SDL_Scancode.SCANCODE_EQUALS,
    minus    = SDL_Scancode.SCANCODE_MINUS,
    backspace = SDL_Scancode.SCANCODE_BACKSPACE,
    return_  = SDL_Scancode.SCANCODE_RETURN,
    delete_  = SDL_Scancode.SCANCODE_DELETE,
    home     = SDL_Scancode.SCANCODE_HOME,
    end      = SDL_Scancode.SCANCODE_END,
    pageUp   = SDL_Scancode.SCANCODE_PAGEUP,
    pageDown = SDL_Scancode.SCANCODE_PAGEDOWN,
    rshift   = SDL_Scancode.SCANCODE_RSHIFT,
    rctrl    = SDL_Scancode.SCANCODE_RCTRL,
    lalt     = SDL_Scancode.SCANCODE_LALT,
    ralt     = SDL_Scancode.SCANCODE_RALT,
    period   = SDL_Scancode.SCANCODE_PERIOD,
    slash    = SDL_Scancode.SCANCODE_SLASH,
    kpPlus   = SDL_Scancode.SCANCODE_KP_PLUS,
    kpMinus  = SDL_Scancode.SCANCODE_KP_MINUS,
    up       = SDL_Scancode.SCANCODE_UP,
    down     = SDL_Scancode.SCANCODE_DOWN,
    left     = SDL_Scancode.SCANCODE_LEFT,
    right    = SDL_Scancode.SCANCODE_RIGHT,
    f1       = SDL_Scancode.SCANCODE_F1,
    f2       = SDL_Scancode.SCANCODE_F2,
    f3       = SDL_Scancode.SCANCODE_F3,
    f4       = SDL_Scancode.SCANCODE_F4,
    f5       = SDL_Scancode.SCANCODE_F5,
    digit0   = SDL_Scancode.SCANCODE_0,
    digit1   = SDL_Scancode.SCANCODE_1,
    digit2   = SDL_Scancode.SCANCODE_2,
    digit3   = SDL_Scancode.SCANCODE_3,
    digit4   = SDL_Scancode.SCANCODE_4,
    digit5   = SDL_Scancode.SCANCODE_5,
    digit6   = SDL_Scancode.SCANCODE_6,
    digit7   = SDL_Scancode.SCANCODE_7,
    digit8   = SDL_Scancode.SCANCODE_8,
    digit9   = SDL_Scancode.SCANCODE_9,
}

/// SDL3 mouse button indices (1-based, matching SDL_BUTTON_*).
enum MouseButton : ubyte {
    left   = 1,
    middle = 2,
    right  = 3,
}

struct InputState {
    private enum MAX_KEYS = 512;
    private enum MAX_MOUSE_BUTTONS = 6; // indices 1..5 used (SDL button ids)
    private bool[MAX_KEYS] current;
    private bool[MAX_KEYS] keyPressedEdge;
    private bool[MAX_KEYS] keyReleasedEdge;

    private bool[MAX_MOUSE_BUTTONS] mouseCurrent;
    private bool[MAX_MOUSE_BUTTONS] mousePressedEdge;
    private bool[MAX_MOUSE_BUTTONS] mouseReleasedEdge;

    private float mouseX = 0, mouseY = 0;
    private float mouseDX = 0, mouseDY = 0;
    private float _wheelX = 0, _wheelY = 0;
    private bool _quit = false;
    private bool keepEdges = false;

    private char[128] _textBuf;
    private uint _textLen = 0;

    /// Call once per frame before polling events.
    ///
    /// Press/release edges survive this call when `keepEdgesForNextFrame`
    /// was set, so a click drained just before a blocking present is still
    /// visible to the next update instead of being cleared unread.
    void beginFrame() nothrow @nogc {
        if (!keepEdges) {
            keyPressedEdge[] = false;
            keyReleasedEdge[] = false;
            mousePressedEdge[] = false;
            mouseReleasedEdge[] = false;
        }
        keepEdges = false;
        mouseDX = 0;
        mouseDY = 0;
        _wheelX = 0;
        _wheelY = 0;
        _textLen = 0;
    }

    /// Keep edges set after this frame's update so the next `beginFrame`
    /// does not drop them. Used when events are pumped after input was
    /// already consumed (just before the swapchain wait).
    void keepEdgesForNextFrame() nothrow @nogc {
        keepEdges = true;
    }

    void clearKeyEdges() nothrow @nogc {
        keyPressedEdge[] = false;
        keyReleasedEdge[] = false;
    }

    void clearPointerEdges() nothrow @nogc {
        mousePressedEdge[] = false;
        mouseReleasedEdge[] = false;
    }

    bool hasPendingEdges() const nothrow @nogc {
        foreach (i; 0 .. MAX_KEYS) {
            if (keyPressedEdge[i] || keyReleasedEdge[i]) return true;
        }
        foreach (i; 1 .. MAX_MOUSE_BUTTONS) {
            if (mousePressedEdge[i] || mouseReleasedEdge[i]) return true;
        }
        return false;
    }

    private void releaseAllMouseButtons() nothrow @nogc {
        foreach (i; 1 .. MAX_MOUSE_BUTTONS) {
            if (mouseCurrent[i]) {
                mouseReleasedEdge[i] = true;
                mouseCurrent[i] = false;
            }
        }
    }

    /// Process a single SDL event.
    void processEvent(ref const SDL_Event ev) nothrow @nogc @trusted {
        switch (ev.type) {
            case SDL_EVENT_QUIT:
                () @trusted { fprintf(stderr, "[INPUT] SDL_EVENT_QUIT received\n"); }();
                _quit = true;
                break;
            case SDL_EVENT_KEY_DOWN:
                immutable sc = ev.key.scancode;
                if (sc < MAX_KEYS) {
                    if (!current[sc]) keyPressedEdge[sc] = true;
                    current[sc] = true;
                }
                break;
            case SDL_EVENT_KEY_UP:
                immutable sc = ev.key.scancode;
                if (sc < MAX_KEYS) {
                    if (current[sc]) keyReleasedEdge[sc] = true;
                    current[sc] = false;
                }
                break;
            case SDL_EVENT_TEXT_INPUT:
                if (ev.text.text !is null) {
                    import core.stdc.string : strlen;
                    immutable size_t len = strlen(ev.text.text);
                    foreach (i; 0 .. len) {
                        if (_textLen < _textBuf.length) {
                            _textBuf[_textLen++] = ev.text.text[i];
                        }
                    }
                }
                break;
            case SDL_EVENT_MOUSE_MOTION:
                mouseX  = ev.motion.x;
                mouseY  = ev.motion.y;
                mouseDX += ev.motion.xrel;
                mouseDY += ev.motion.yrel;
                break;
            case SDL_EVENT_MOUSE_BUTTON_DOWN:
                mouseX = ev.button.x;
                mouseY = ev.button.y;
                immutable bd = ev.button.button;
                if (bd > 0 && bd < MAX_MOUSE_BUTTONS) {
                    if (!mouseCurrent[bd]) mousePressedEdge[bd] = true;
                    mouseCurrent[bd] = true;
                }
                break;
            case SDL_EVENT_MOUSE_BUTTON_UP:
                mouseX = ev.button.x;
                mouseY = ev.button.y;
                immutable bu = ev.button.button;
                if (bu > 0 && bu < MAX_MOUSE_BUTTONS) {
                    if (mouseCurrent[bu]) mouseReleasedEdge[bu] = true;
                    mouseCurrent[bu] = false;
                }
                break;
            case SDL_EVENT_MOUSE_WHEEL:
                _wheelX += ev.wheel.x;
                _wheelY += ev.wheel.y;
                break;
            case SDL_EVENT_WINDOW_FOCUS_LOST:
                // Without pointer capture, a release outside the window never
                // arrives. Drop held buttons so the UI cannot stay stuck down.
                releaseAllMouseButtons();
                break;
            case SDL_EVENT_WINDOW_CLOSE_REQUESTED:
                () @trusted { fprintf(stderr, "[INPUT] SDL_EVENT_WINDOW_CLOSE_REQUESTED received\n"); }();
                _quit = true;
                break;
            default:
                break;
        }
    }

    bool keyDown(Key k)    const nothrow @nogc { return current[k]; }
    bool keyPressed(Key k) const nothrow @nogc { return keyPressedEdge[k]; }
    bool keyUp(Key k)      const nothrow @nogc { return keyReleasedEdge[k]; }

    bool mouseDown(MouseButton b) const nothrow @nogc {
        return mouseCurrent[b];
    }
    bool mousePressed(MouseButton b) const nothrow @nogc {
        return mousePressedEdge[b];
    }
    bool mouseUp(MouseButton b) const nothrow @nogc {
        return mouseReleasedEdge[b];
    }

    bool quitRequested() const nothrow @nogc { return _quit; }

    float mx() const nothrow @nogc { return mouseX; }
    float my() const nothrow @nogc { return mouseY; }
    float mdx() const nothrow @nogc { return mouseDX; }
    float mdy() const nothrow @nogc { return mouseDY; }

    /// Horizontal scroll delta this frame (SDL wheel.x, accumulated).
    float wheelX() const nothrow @nogc { return _wheelX; }
    /// Vertical scroll delta this frame (SDL wheel.y, accumulated). Positive = away from user.
    float wheelY() const nothrow @nogc { return _wheelY; }

    /// UTF-8 characters received via SDL_EVENT_TEXT_INPUT during this frame.
    const(char)[] textInput() return const nothrow @nogc {
        return _textBuf[0 .. _textLen];
    }

    /// True if Ctrl is currently pressed.
    bool ctrlDown() const nothrow @nogc { return keyDown(Key.lctrl) || keyDown(Key.rctrl); }
    /// True if Shift is currently pressed.
    bool shiftDown() const nothrow @nogc { return keyDown(Key.lshift) || keyDown(Key.rshift); }
    /// True if Alt is currently pressed.
    bool altDown() const nothrow @nogc { return keyDown(Key.lalt) || keyDown(Key.ralt); }
}

private void pushButton(ref InputState s, uint type, ubyte button) @trusted {
    SDL_Event ev = SDL_Event.init;
    ev.type = type;
    ev.button.button = button;
    ev.button.x = 4;
    ev.button.y = 5;
    s.processEvent(ev);
}

unittest {
    InputState s;
    s.beginFrame();

    pushButton(s, SDL_EVENT_MOUSE_BUTTON_DOWN, MouseButton.left);
    pushButton(s, SDL_EVENT_MOUSE_BUTTON_UP, MouseButton.left);

    // Down and up in the same poll must both be visible. Comparing only the
    // level at frame end drops the click, which is what happens when a stall
    // delivers the whole click in one SDL_PollEvent loop.
    assert(s.mousePressed(MouseButton.left));
    assert(s.mouseUp(MouseButton.left));
    assert(!s.mouseDown(MouseButton.left));

    s.keepEdgesForNextFrame();
    s.beginFrame();
    assert(s.mousePressed(MouseButton.left));
    assert(s.mouseUp(MouseButton.left));
    s.clearPointerEdges();
    assert(!s.mousePressed(MouseButton.left));
    assert(!s.mouseUp(MouseButton.left));

    s.beginFrame();
    pushButton(s, SDL_EVENT_MOUSE_BUTTON_DOWN, MouseButton.left);
    s.clearPointerEdges();
    s.beginFrame();
    assert(s.mouseDown(MouseButton.left));
    assert(!s.mousePressed(MouseButton.left));
}
