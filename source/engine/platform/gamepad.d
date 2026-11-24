/// SDL3 gamepad (Xbox / standard controller) input, hot-plugging, deadzones, and haptics.
module engine.platform.gamepad;

import std.math : sqrt;
import core.stdc.string : strlen;

import bindings.sdl3;
import engine.core.log;
import engine.core.pod : isPod;
import engine.math.vec : Vec2;

@safe:

enum uint MAX_GAMEPADS = 8;

/// Standard SDL3 gamepad buttons with Xbox-friendly aliases.
enum PadButton : ubyte {
    south = 0,       /// Bottom face button (Xbox A)
    east,            /// Right face button (Xbox B)
    west,            /// Left face button (Xbox X)
    north,           /// Top face button (Xbox Y)
    back,            /// Back / Xbox View button
    guide,           /// Center Xbox / Guide button
    start,           /// Start / Xbox Menu button
    leftStick,       /// Left thumbstick click (LS)
    rightStick,      /// Right thumbstick click (RS)
    leftShoulder,    /// Left bumper (LB)
    rightShoulder,   /// Right bumper (RB)
    dpadUp,
    dpadDown,
    dpadLeft,
    dpadRight,
    misc1,           /// Extra button (Xbox Series X|S Share button)

    // Xbox aliases
    a     = south,
    b     = east,
    x     = west,
    y     = north,
    view  = back,
    menu  = start,
    ls    = leftStick,
    rs    = rightStick,
    lb    = leftShoulder,
    rb    = rightShoulder,
    share = misc1,
}

enum uint PAD_BUTTON_COUNT = PadButton.misc1 + 1;

/// Mirrors SDL_GamepadType for game code without importing bindings.sdl3.
enum GamepadType : ubyte {
    unknown = 0,
    standard,
    xbox360,
    xboxOne,
    ps3,
    ps4,
    ps5,
    switchPro,
    switchJoyconLeft,
    switchJoyconRight,
    switchJoyconPair,
    gamecube,
}

/// Per-slot gamepad state. Pure POD so it never creates GC scan roots.
struct GamepadState {
    SDL_JoystickID id = 0; // 0 = empty slot
    bool connected = false;
    GamepadType type = GamepadType.unknown;
    ushort vendorId = 0;
    ushort productId = 0;
    int playerIndex = -1;

    char[64] nameBuf = 0;
    ubyte nameLen = 0;

    bool[PAD_BUTTON_COUNT] down = false;
    bool[PAD_BUTTON_COUNT] pressed = false;
    bool[PAD_BUTTON_COUNT] released = false;

    /// Normalized thumbstick axes in [-1, 1] after radial deadzone.
    /// SDL convention: X negative = left, positive = right; Y negative = up, positive = down.
    float leftX = 0.0f;
    float leftY = 0.0f;
    float rightX = 0.0f;
    float rightY = 0.0f;

    /// Normalized trigger axes in [0, 1] after trigger deadzone.
    float leftTrigger = 0.0f;
    float rightTrigger = 0.0f;

    /// Raw SDL axis values indexed by SDL_GamepadAxis (0..5) so radial
    /// deadzones stay coupled across X/Y pairs when single-axis events arrive.
    short[6] rawAxes = 0;

    /// Normalized axes (PadAxis order) as they were at the previous frame; lets axis bindings detect a press edge.
    float[6] prevAxes = 0.0f;

    /// Button edges that arrived after the frame's input was consumed (`Gamepads.beginLateEvents`).
    package bool[PAD_BUTTON_COUNT] latePressed = false;
    package bool[PAD_BUTTON_COUNT] lateReleased = false;

    /// Current normalized axes in PadAxis order.
    float[6] axes() const pure nothrow @nogc {
        return [leftX, leftY, rightX, rightY, leftTrigger, rightTrigger];
    }

    /// Human-readable device name reported by SDL3.
    const(char)[] name() const return pure nothrow @nogc {
        return nameBuf[0 .. nameLen];
    }

    /// Left thumbstick vector in [-1, 1] (Y negative = up, positive = down).
    Vec2 leftStick() const pure nothrow @nogc {
        return Vec2(leftX, leftY);
    }

    /// Right thumbstick vector in [-1, 1] (Y negative = up, positive = down).
    Vec2 rightStick() const pure nothrow @nogc {
        return Vec2(rightX, rightY);
    }
}

static assert(isPod!GamepadState);

/// Map SDL's signed 16-bit stick axis [-32768, 32767] into [-1.0, 1.0].
float normalizeStickAxis(short v) pure nothrow @nogc {
    float f = v >= 0 ? (cast(float) v / 32767.0f) : (cast(float) v / 32768.0f);
    if (f < -1.0f) f = -1.0f;
    if (f >  1.0f) f =  1.0f;
    return f;
}

/// Apply a scaled radial deadzone to a 2D stick pair in [-1, 1].
Vec2 applyRadialDeadzone(float x, float y, float deadzone) pure nothrow @nogc {
    if (deadzone <= 0.0f) return Vec2(x, y);
    if (deadzone >= 1.0f) return Vec2(0.0f, 0.0f);

    immutable float lenSq = x * x + y * y;
    if (lenSq <= deadzone * deadzone) return Vec2(0.0f, 0.0f);

    immutable float len = sqrt(lenSq);
    float scaled = (len - deadzone) / (1.0f - deadzone);
    if (scaled > 1.0f) scaled = 1.0f;
    immutable float s = scaled / len;
    return Vec2(x * s, y * s);
}

/// Map SDL's trigger axis [0, 32767] into [0.0, 1.0] with deadzone rescaling.
float normalizeTriggerAxis(short v, float deadzone) pure nothrow @nogc {
    if (v <= 0) return 0.0f;
    float f = cast(float) v / 32767.0f;
    if (f > 1.0f) f = 1.0f;
    if (deadzone <= 0.0f) return f;
    if (deadzone >= 1.0f || f <= deadzone) return 0.0f;
    float scaled = (f - deadzone) / (1.0f - deadzone);
    return scaled > 1.0f ? 1.0f : scaled;
}

private ushort toU16Intensity(float v) pure nothrow @nogc {
    if (v <= 0.0f) return 0;
    if (v >= 1.0f) return 0xFFFF;
    return cast(ushort)(v * 65535.0f + 0.5f);
}

private GamepadType mapGamepadType(SDL_GamepadType t) pure nothrow @nogc {
    if (t >= SDL_GamepadType.SDL_GAMEPAD_TYPE_UNKNOWN &&
        t <= SDL_GamepadType.SDL_GAMEPAD_TYPE_GAMECUBE) {
        return cast(GamepadType) t;
    }
    return GamepadType.unknown;
}

/// Human-readable label for a `GamepadType`.
const(char)[] gamepadTypeName(GamepadType t) pure nothrow @nogc {
    final switch (t) {
        case GamepadType.unknown:           return "Unknown";
        case GamepadType.standard:          return "Standard";
        case GamepadType.xbox360:           return "Xbox 360";
        case GamepadType.xboxOne:           return "Xbox One/Series";
        case GamepadType.ps3:               return "PS3";
        case GamepadType.ps4:               return "PS4";
        case GamepadType.ps5:               return "PS5";
        case GamepadType.switchPro:         return "Switch Pro";
        case GamepadType.switchJoyconLeft:  return "Joy-Con L";
        case GamepadType.switchJoyconRight: return "Joy-Con R";
        case GamepadType.switchJoyconPair:  return "Joy-Con Pair";
        case GamepadType.gamecube:          return "GameCube";
    }
}

/// Manages up to `MAX_GAMEPADS` connected SDL3 gamepads with hot-plug and haptics.
struct Gamepads {
    GamepadState[MAX_GAMEPADS] pads;
    private SDL_Gamepad*[MAX_GAMEPADS] handles;
    private bool keepEdges = false;
    private bool late = false;

    float stickDeadzone = 0.15f;
    float triggerDeadzone = 0.05f;

    @disable this(this);

    ~this() nothrow @nogc {
        closeAll();
    }

    /// Close all opened SDL_Gamepad handles and reset all slots.
    void closeAll() nothrow @nogc @trusted {
        foreach (i; 0 .. MAX_GAMEPADS) {
            if (handles[i] !is null) {
                SDL_CloseGamepad(handles[i]);
                handles[i] = null;
            }
            pads[i] = GamepadState.init;
        }
    }

    /// Clear per-frame press/release edges unless `keepEdgesForNextFrame` was set.
    void beginFrame() nothrow @nogc {
        foreach (i; 0 .. MAX_GAMEPADS) {
            auto p = &pads[i];
            if (!keepEdges) {
                p.pressed = p.latePressed;
                p.released = p.lateReleased;
            }
            p.latePressed[] = false;
            p.lateReleased[] = false;
            if (!late)
                p.prevAxes = p.axes();
        }
        keepEdges = false;
        late = false;
    }

    /// Events from here until the next `beginFrame` arrive after this frame's input was consumed: their edges are
    /// delivered (again) in the next frame.
    void beginLateEvents() nothrow @nogc {
        if (late) return;
        late = true;
        foreach (i; 0 .. MAX_GAMEPADS)
            pads[i].prevAxes = pads[i].axes();
    }

    /// Preserve edges through the next `beginFrame` (used when pumping before present).
    void keepEdgesForNextFrame() nothrow @nogc {
        keepEdges = true;
    }

    /// Explicitly clear all button press/release edge flags.
    void clearEdges() nothrow @nogc {
        foreach (i; 0 .. MAX_GAMEPADS) {
            pads[i].pressed[] = false;
            pads[i].released[] = false;
            pads[i].latePressed[] = false;
            pads[i].lateReleased[] = false;
        }
    }

    /// True if any connected slot has unread button press/release edges.
    bool hasPendingEdges() const nothrow @nogc {
        foreach (i; 0 .. MAX_GAMEPADS) {
            if (!pads[i].connected) continue;
            foreach (b; 0 .. PAD_BUTTON_COUNT) {
                if (pads[i].pressed[b] || pads[i].released[b]) return true;
            }
        }
        return false;
    }

    /// Enumerate already-connected SDL gamepads (idempotent).
    void scanExisting() nothrow @nogc @trusted {
        int count = 0;
        SDL_JoystickID* ids = SDL_GetGamepads(&count);
        if (ids is null) return;
        scope (exit) SDL_free(ids);
        foreach (i; 0 .. count) {
            onAdded(ids[i]);
        }
    }

    /// Process a single SDL3 event (hot-plug, buttons, axes).
    void processEvent(ref const SDL_Event ev) nothrow @nogc @trusted {
        switch (ev.type) {
            case SDL_EVENT_GAMEPAD_ADDED:
                onAdded(ev.gdevice.which);
                break;
            case SDL_EVENT_GAMEPAD_REMOVED:
                onRemoved(ev.gdevice.which);
                break;
            case SDL_EVENT_GAMEPAD_REMAPPED:
                onRemapped(ev.gdevice.which);
                break;
            case SDL_EVENT_GAMEPAD_BUTTON_DOWN:
                onButton(ev.gbutton.which, ev.gbutton.button, true);
                break;
            case SDL_EVENT_GAMEPAD_BUTTON_UP:
                onButton(ev.gbutton.which, ev.gbutton.button, false);
                break;
            case SDL_EVENT_GAMEPAD_AXIS_MOTION:
                onAxis(ev.gaxis.which, ev.gaxis.axis, ev.gaxis.value);
                break;
            default:
                break;
        }
    }

    // -----------------------------------------------------------------------
    // Queries
    // -----------------------------------------------------------------------

    uint connectedCount() const pure nothrow @nogc {
        uint n = 0;
        foreach (i; 0 .. MAX_GAMEPADS) {
            if (pads[i].connected) n++;
        }
        return n;
    }

    int firstConnectedSlot() const pure nothrow @nogc {
        foreach (i; 0 .. MAX_GAMEPADS) {
            if (pads[i].connected) return cast(int) i;
        }
        return -1;
    }

    bool isConnected(uint slot = 0) const pure nothrow @nogc {
        return slot < MAX_GAMEPADS && pads[slot].connected;
    }

    const(GamepadState)* pad(uint slot = 0) const return pure nothrow @nogc {
        if (slot >= MAX_GAMEPADS) return null;
        return &pads[slot];
    }

    bool buttonDown(PadButton b, uint slot = 0) const pure nothrow @nogc {
        if (slot >= MAX_GAMEPADS || !pads[slot].connected || b >= PAD_BUTTON_COUNT)
            return false;
        return pads[slot].down[b];
    }

    bool buttonPressed(PadButton b, uint slot = 0) const pure nothrow @nogc {
        if (slot >= MAX_GAMEPADS || !pads[slot].connected || b >= PAD_BUTTON_COUNT)
            return false;
        return pads[slot].pressed[b];
    }

    bool buttonUp(PadButton b, uint slot = 0) const pure nothrow @nogc {
        if (slot >= MAX_GAMEPADS || !pads[slot].connected || b >= PAD_BUTTON_COUNT)
            return false;
        return pads[slot].released[b];
    }

    Vec2 leftStick(uint slot = 0) const pure nothrow @nogc {
        if (slot >= MAX_GAMEPADS || !pads[slot].connected) return Vec2(0.0f, 0.0f);
        return pads[slot].leftStick();
    }

    Vec2 rightStick(uint slot = 0) const pure nothrow @nogc {
        if (slot >= MAX_GAMEPADS || !pads[slot].connected) return Vec2(0.0f, 0.0f);
        return pads[slot].rightStick();
    }

    float leftTrigger(uint slot = 0) const pure nothrow @nogc {
        if (slot >= MAX_GAMEPADS || !pads[slot].connected) return 0.0f;
        return pads[slot].leftTrigger;
    }

    float rightTrigger(uint slot = 0) const pure nothrow @nogc {
        if (slot >= MAX_GAMEPADS || !pads[slot].connected) return 0.0f;
        return pads[slot].rightTrigger;
    }

    // -----------------------------------------------------------------------
    // Haptics (Rumble & Xbox Impulse Triggers)
    // -----------------------------------------------------------------------

    /// Trigger dual-motor controller rumble. Intensities are clamped to [0, 1].
    bool rumble(uint slot, float lowFreq, float highFreq, uint durationMs) nothrow @nogc @trusted {
        if (slot >= MAX_GAMEPADS || !pads[slot].connected || handles[slot] is null)
            return false;
        return SDL_RumbleGamepad(
            handles[slot],
            toU16Intensity(lowFreq),
            toU16Intensity(highFreq),
            durationMs,
        );
    }

    /// Trigger Xbox One/Series impulse trigger rumble. Intensities are clamped to [0, 1].
    bool rumbleTriggers(uint slot, float left, float right, uint durationMs) nothrow @nogc @trusted {
        if (slot >= MAX_GAMEPADS || !pads[slot].connected || handles[slot] is null)
            return false;
        return SDL_RumbleGamepadTriggers(
            handles[slot],
            toU16Intensity(left),
            toU16Intensity(right),
            durationMs,
        );
    }

    /// Stop both body and trigger rumble on a slot.
    void stopRumble(uint slot = 0) nothrow @nogc {
        rumble(slot, 0.0f, 0.0f, 0);
        rumbleTriggers(slot, 0.0f, 0.0f, 0);
    }

    // -----------------------------------------------------------------------
    // Internal event handlers
    // -----------------------------------------------------------------------

    private int findSlotById(SDL_JoystickID id) const pure nothrow @nogc {
        if (id == 0) return -1;
        foreach (i; 0 .. MAX_GAMEPADS) {
            if (pads[i].connected && pads[i].id == id) return cast(int) i;
        }
        return -1;
    }

    private void onAdded(SDL_JoystickID id) nothrow @nogc @trusted {
        if (id == 0 || findSlotById(id) >= 0) return;

        int emptySlot = -1;
        foreach (i; 0 .. MAX_GAMEPADS) {
            if (!pads[i].connected) {
                emptySlot = cast(int) i;
                break;
            }
        }
        if (emptySlot < 0) {
            warn("Gamepad ignored (all ", MAX_GAMEPADS, " slots occupied)");
            return;
        }

        SDL_Gamepad* gp = SDL_OpenGamepad(id);
        if (gp is null) {
            warn("SDL_OpenGamepad failed for id=", id);
            return;
        }

        SDL_SetGamepadPlayerIndex(gp, emptySlot);

        handles[emptySlot] = gp;
        pads[emptySlot] = GamepadState.init;
        pads[emptySlot].id = id;
        pads[emptySlot].connected = true;
        pads[emptySlot].type = mapGamepadType(SDL_GetGamepadType(gp));
        pads[emptySlot].vendorId = SDL_GetGamepadVendor(gp);
        pads[emptySlot].productId = SDL_GetGamepadProduct(gp);
        pads[emptySlot].playerIndex = SDL_GetGamepadPlayerIndex(gp);

        const(char)* cname = SDL_GetGamepadName(gp);
        if (cname !is null) {
            immutable size_t rawLen = strlen(cname);
            immutable size_t n = rawLen < pads[emptySlot].nameBuf.length
                ? rawLen : pads[emptySlot].nameBuf.length;
            pads[emptySlot].nameBuf[0 .. n] = cname[0 .. n];
            pads[emptySlot].nameLen = cast(ubyte) n;
        }

        syncSlotFromHandle(emptySlot);

        info("Gamepad connected [slot ", emptySlot, ", ",
            gamepadTypeName(pads[emptySlot].type), "]: ",
            pads[emptySlot].name());
    }

    private void onRemoved(SDL_JoystickID id) nothrow @nogc @trusted {
        immutable int slot = findSlotById(id);
        if (slot < 0) return;

        info("Gamepad disconnected [slot ", slot, "]: ", pads[slot].name());

        if (handles[slot] !is null) {
            SDL_CloseGamepad(handles[slot]);
            handles[slot] = null;
        }
        // Keep other slots intact so player slot indices do not shift.
        pads[slot] = GamepadState.init;
    }

    private void onRemapped(SDL_JoystickID id) nothrow @nogc @trusted {
        immutable int slot = findSlotById(id);
        if (slot < 0 || handles[slot] is null) return;
        syncSlotFromHandle(slot);
    }

    private void syncSlotFromHandle(int slot) nothrow @nogc @trusted {
        SDL_Gamepad* gp = handles[slot];
        if (gp is null) return;

        foreach (b; 0 .. PAD_BUTTON_COUNT) {
            pads[slot].down[b] = SDL_GetGamepadButton(gp, cast(SDL_GamepadButton) b);
        }
        foreach (a; 0 .. 6) {
            pads[slot].rawAxes[a] = SDL_GetGamepadAxis(gp, cast(SDL_GamepadAxis) a);
        }
        recomputeAxes(pads[slot]);
    }

    private void onButton(SDL_JoystickID id, ubyte btn, bool isDown) nothrow @nogc {
        immutable int slot = findSlotById(id);
        if (slot < 0 || btn >= PAD_BUTTON_COUNT) return;

        if (isDown) {
            if (!pads[slot].down[btn]) {
                pads[slot].pressed[btn] = true;
                if (late) pads[slot].latePressed[btn] = true;
            }
            pads[slot].down[btn] = true;
        } else {
            if (pads[slot].down[btn]) {
                pads[slot].released[btn] = true;
                if (late) pads[slot].lateReleased[btn] = true;
            }
            pads[slot].down[btn] = false;
        }
    }

    private void onAxis(SDL_JoystickID id, ubyte axis, short value) nothrow @nogc {
        immutable int slot = findSlotById(id);
        if (slot < 0 || axis >= 6) return;

        pads[slot].rawAxes[axis] = value;
        recomputeAxes(pads[slot]);
    }

    private void recomputeAxes(ref GamepadState st) const pure nothrow @nogc {
        immutable Vec2 left = applyRadialDeadzone(
            normalizeStickAxis(st.rawAxes[SDL_GamepadAxis.SDL_GAMEPAD_AXIS_LEFTX]),
            normalizeStickAxis(st.rawAxes[SDL_GamepadAxis.SDL_GAMEPAD_AXIS_LEFTY]),
            stickDeadzone,
        );
        st.leftX = left.x;
        st.leftY = left.y;

        immutable Vec2 right = applyRadialDeadzone(
            normalizeStickAxis(st.rawAxes[SDL_GamepadAxis.SDL_GAMEPAD_AXIS_RIGHTX]),
            normalizeStickAxis(st.rawAxes[SDL_GamepadAxis.SDL_GAMEPAD_AXIS_RIGHTY]),
            stickDeadzone,
        );
        st.rightX = right.x;
        st.rightY = right.y;

        st.leftTrigger = normalizeTriggerAxis(
            st.rawAxes[SDL_GamepadAxis.SDL_GAMEPAD_AXIS_LEFT_TRIGGER],
            triggerDeadzone,
        );
        st.rightTrigger = normalizeTriggerAxis(
            st.rawAxes[SDL_GamepadAxis.SDL_GAMEPAD_AXIS_RIGHT_TRIGGER],
            triggerDeadzone,
        );
    }
}

// ---------------------------------------------------------------------------
// Unit tests (synthetic SDL_Events & deadzone math)
// ---------------------------------------------------------------------------

private void pushPadButton(ref Gamepads gp, uint type, SDL_JoystickID id, ubyte btn) @trusted {
    SDL_Event ev = SDL_Event.init;
    ev.type = type;
    ev.gbutton.which = id;
    ev.gbutton.button = btn;
    ev.gbutton.down = (type == SDL_EVENT_GAMEPAD_BUTTON_DOWN);
    gp.processEvent(ev);
}

private void pushPadAxis(ref Gamepads gp, SDL_JoystickID id, ubyte axis, short value) @trusted {
    SDL_Event ev = SDL_Event.init;
    ev.type = SDL_EVENT_GAMEPAD_AXIS_MOTION;
    ev.gaxis.which = id;
    ev.gaxis.axis = axis;
    ev.gaxis.value = value;
    gp.processEvent(ev);
}

private void setMockConnectedSlot(ref Gamepads gp, uint slot, SDL_JoystickID id) @trusted {
    gp.pads[slot] = GamepadState.init;
    gp.pads[slot].id = id;
    gp.pads[slot].connected = true;
    gp.pads[slot].type = GamepadType.xboxOne;
}

@safe unittest {
    import std.math : abs;

    // 1. Axis normalization & scaled radial deadzone
    assert(normalizeStickAxis(0) == 0.0f);
    assert(abs(normalizeStickAxis(32767) - 1.0f) < 1e-5f);
    assert(abs(normalizeStickAxis(-32768) + 1.0f) < 1e-5f);

    immutable Vec2 insideDz = applyRadialDeadzone(0.10f, 0.10f, 0.15f);
    assert(insideDz.x == 0.0f && insideDz.y == 0.0f);

    immutable Vec2 fullDeflect = applyRadialDeadzone(1.0f, 0.0f, 0.15f);
    assert(abs(fullDeflect.x - 1.0f) < 1e-5f && abs(fullDeflect.y) < 1e-5f);

    immutable Vec2 midDeflect = applyRadialDeadzone(0.575f, 0.0f, 0.15f);
    assert(abs(midDeflect.x - 0.5f) < 1e-4f);

    assert(normalizeTriggerAxis(0, 0.05f) == 0.0f);
    assert(normalizeTriggerAxis(1000, 0.05f) == 0.0f);
    assert(abs(normalizeTriggerAxis(32767, 0.05f) - 1.0f) < 1e-5f);

    // 2. Button edges & keepEdgesForNextFrame
    Gamepads gp;
    setMockConnectedSlot(gp, 0, 101);
    setMockConnectedSlot(gp, 1, 202);
    assert(gp.connectedCount() == 2);

    gp.beginFrame();
    pushPadButton(gp, SDL_EVENT_GAMEPAD_BUTTON_DOWN, 101, PadButton.a);
    pushPadButton(gp, SDL_EVENT_GAMEPAD_BUTTON_UP, 101, PadButton.a);
    assert(gp.buttonPressed(PadButton.a, 0));
    assert(gp.buttonUp(PadButton.a, 0));
    assert(!gp.buttonDown(PadButton.a, 0));

    gp.keepEdgesForNextFrame();
    gp.beginFrame();
    assert(gp.buttonPressed(PadButton.a, 0));
    assert(gp.buttonUp(PadButton.a, 0));

    gp.beginFrame();
    assert(!gp.buttonPressed(PadButton.a, 0));
    assert(!gp.buttonUp(PadButton.a, 0));

    // 3. Axis updates & coupled radial deadzone
    pushPadAxis(gp, 101, SDL_GamepadAxis.SDL_GAMEPAD_AXIS_LEFTX, 32767);
    pushPadAxis(gp, 101, SDL_GamepadAxis.SDL_GAMEPAD_AXIS_LEFT_TRIGGER, 32767);
    assert(abs(gp.leftStick(0).x - 1.0f) < 1e-5f);
    assert(gp.leftStick(0).y == 0.0f);
    assert(abs(gp.leftTrigger(0) - 1.0f) < 1e-5f);

    // 4. Removal does not shift slot 1 into slot 0
    SDL_Event rem = SDL_Event.init;
    rem.type = SDL_EVENT_GAMEPAD_REMOVED;
    rem.gdevice.which = 101;
    gp.processEvent(rem);
    assert(!gp.isConnected(0));
    assert(gp.isConnected(1));
    assert(gp.pads[1].id == 202);
}
