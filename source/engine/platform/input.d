/// Per-frame keyboard & mouse input tracking built on SDL3 events.
module engine.platform.input;

import bindings.sdl3;

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
    equals   = SDL_Scancode.SCANCODE_EQUALS,
    minus    = SDL_Scancode.SCANCODE_MINUS,
    kpPlus   = SDL_Scancode.SCANCODE_KP_PLUS,
    kpMinus  = SDL_Scancode.SCANCODE_KP_MINUS,
    up       = SDL_Scancode.SCANCODE_UP,
    down     = SDL_Scancode.SCANCODE_DOWN,
    left     = SDL_Scancode.SCANCODE_LEFT,
    right    = SDL_Scancode.SCANCODE_RIGHT,
    f1       = SDL_Scancode.SCANCODE_F1,
    f2       = SDL_Scancode.SCANCODE_F2,
    f3       = SDL_Scancode.SCANCODE_F3,
}

struct InputState {
    private enum MAX_KEYS = 512;
    private bool[MAX_KEYS] current;
    private bool[MAX_KEYS] previous;

    private float mouseX = 0, mouseY = 0;
    private float mouseDX = 0, mouseDY = 0;
    private bool _quit = false;

    /// Call once per frame before polling events.
    void beginFrame() nothrow @nogc {
        previous = current;
        mouseDX = 0;
        mouseDY = 0;
    }

    /// Process a single SDL event.
    void processEvent(ref const SDL_Event ev) nothrow @nogc @trusted {
        switch (ev.type) {
import core.stdc.stdio : fprintf, stderr;

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

    bool quitRequested() const nothrow @nogc { return _quit; }

    float mx() const nothrow @nogc { return mouseX; }
    float my() const nothrow @nogc { return mouseY; }
    float mdx() const nothrow @nogc { return mouseDX; }
    float mdy() const nothrow @nogc { return mouseDY; }
}
