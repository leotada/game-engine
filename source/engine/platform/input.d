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
    x        = SDL_Scancode.SCANCODE_X,
    y        = SDL_Scancode.SCANCODE_Y,
    z        = SDL_Scancode.SCANCODE_Z,
    c        = SDL_Scancode.SCANCODE_C,
    equals   = SDL_Scancode.SCANCODE_EQUALS,
    minus    = SDL_Scancode.SCANCODE_MINUS,
    backspace = SDL_Scancode.SCANCODE_BACKSPACE,
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
    private bool[MAX_KEYS] previous;

    private bool[MAX_MOUSE_BUTTONS] mouseCurrent;
    private bool[MAX_MOUSE_BUTTONS] mousePrevious;

    private float mouseX = 0, mouseY = 0;
    private float mouseDX = 0, mouseDY = 0;
    private float _wheelX = 0, _wheelY = 0;
    private bool _quit = false;

    /// Call once per frame before polling events.
    void beginFrame() nothrow @nogc {
        previous = current;
        mousePrevious = mouseCurrent;
        mouseDX = 0;
        mouseDY = 0;
        _wheelX = 0;
        _wheelY = 0;
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
                if (sc < MAX_KEYS) current[sc] = true;
                break;
            case SDL_EVENT_KEY_UP:
                immutable sc = ev.key.scancode;
                if (sc < MAX_KEYS) current[sc] = false;
                break;
            case SDL_EVENT_MOUSE_MOTION:
                mouseX  = ev.motion.x;
                mouseY  = ev.motion.y;
                mouseDX = ev.motion.xrel;
                mouseDY = ev.motion.yrel;
                break;
            case SDL_EVENT_MOUSE_BUTTON_DOWN:
                mouseX = ev.button.x;
                mouseY = ev.button.y;
                immutable bd = ev.button.button;
                if (bd < MAX_MOUSE_BUTTONS) mouseCurrent[bd] = true;
                break;
            case SDL_EVENT_MOUSE_BUTTON_UP:
                mouseX = ev.button.x;
                mouseY = ev.button.y;
                immutable bu = ev.button.button;
                if (bu < MAX_MOUSE_BUTTONS) mouseCurrent[bu] = false;
                break;
            case SDL_EVENT_MOUSE_WHEEL:
                _wheelX += ev.wheel.x;
                _wheelY += ev.wheel.y;
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
    bool keyPressed(Key k) const nothrow @nogc { return current[k] && !previous[k]; }
    bool keyUp(Key k)      const nothrow @nogc { return !current[k] && previous[k]; }

    bool mouseDown(MouseButton b) const nothrow @nogc {
        return mouseCurrent[b];
    }
    bool mousePressed(MouseButton b) const nothrow @nogc {
        return mouseCurrent[b] && !mousePrevious[b];
    }
    bool mouseUp(MouseButton b) const nothrow @nogc {
        return !mouseCurrent[b] && mousePrevious[b];
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
}
