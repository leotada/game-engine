/// Action/axis input mapping with multi-device bindings (keyboard, mouse, gamepad)
/// and JSON persistence. Pure POD (`isPod!InputMap`) so it never creates GC scan roots.
module engine.platform.input_map;

import engine.core.pod : isPod;
import engine.math.vec : Vec2;
import engine.platform.gamepad : GamepadState, PadButton;
import engine.platform.input : InputState, Key, MouseButton;
import std.math : sqrt;

@safe:

/// Standard gamepad analog axes mapped cleanly without SDL bindings in game code.
enum PadAxis : ubyte {
    leftX = 0,
    leftY = 1,
    rightX = 2,
    rightY = 3,
    leftTrigger = 4,
    rightTrigger = 5,
}

/// Source device type for an `InputBinding`.
enum InputBindingKind : ubyte {
    key = 0,
    mouseButton = 1,
    gamepadButton = 2,
    gamepadAxisPos = 3,
    gamepadAxisNeg = 4,
}

/// Single input binding contributing to an action or axis.
struct InputBinding {
    InputBindingKind kind = InputBindingKind.key;
    uint code = 0;
    float scale = 1.0f;
    float deadzone = 0.15f;

    static InputBinding fromKey(Key k, float scale = 1.0f) nothrow @nogc pure {
        return InputBinding(InputBindingKind.key, cast(uint) k, scale, 0.0f);
    }

    static InputBinding fromMouse(MouseButton b, float scale = 1.0f) nothrow @nogc pure {
        return InputBinding(InputBindingKind.mouseButton, cast(uint) b, scale, 0.0f);
    }

    static InputBinding fromPadButton(PadButton b, float scale = 1.0f) nothrow @nogc pure {
        return InputBinding(InputBindingKind.gamepadButton, cast(uint) b, scale, 0.0f);
    }

    static InputBinding fromPadAxis(PadAxis a, bool positive = true, float deadzone = 0.15f, float scale = 1.0f) nothrow @nogc pure {
        return InputBinding(
            positive ? InputBindingKind.gamepadAxisPos : InputBindingKind.gamepadAxisNeg,
            cast(uint) a,
            scale,
            deadzone
        );
    }
}

static assert(isPod!InputBinding);

private struct ActionSlot {
    char[32] nameBuf = 0;
    uint nameLen = 0;
    InputBinding[4] bindings;
    uint bindingCount = 0;

    const(char)[] name() const return nothrow @nogc pure {
        return nameBuf[0 .. nameLen];
    }
}

static assert(isPod!ActionSlot);

/// Logical action and 2D axis map (up to 32 actions, 4 bindings per action).
struct InputMap {
    enum uint MAX_ACTIONS = 32;
    enum uint MAX_BINDINGS_PER_ACTION = 4;

    private ActionSlot[MAX_ACTIONS] slots;
    private uint actionCount = 0;

    private int findSlot(scope const(char)[] name) const nothrow @nogc pure {
        foreach (uint i; 0 .. actionCount) {
            if (slots[i].name() == name) return cast(int) i;
        }
        return -1;
    }

    private int getOrCreateSlot(scope const(char)[] name) nothrow @nogc {
        immutable int existing = findSlot(name);
        if (existing >= 0) return existing;
        if (name.length == 0 || actionCount >= MAX_ACTIONS) return -1;

        immutable uint idx = actionCount++;
        auto s = &slots[idx];
        *s = ActionSlot.init;
        immutable uint n = cast(uint)(name.length < 32 ? name.length : 32);
        s.nameBuf[0 .. n] = name[0 .. n];
        s.nameLen = n;
        return cast(int) idx;
    }

    /// Add a binding to an action (avoids duplicates). Returns false if table/slot full.
    bool bind(scope const(char)[] action, InputBinding binding) nothrow @nogc {
        immutable int idx = getOrCreateSlot(action);
        if (idx < 0) return false;
        auto s = &slots[idx];
        foreach (i; 0 .. s.bindingCount) {
            if (s.bindings[i].kind == binding.kind && s.bindings[i].code == binding.code) {
                s.bindings[i] = binding;
                return true;
            }
        }
        if (s.bindingCount >= MAX_BINDINGS_PER_ACTION) return false;
        s.bindings[s.bindingCount++] = binding;
        return true;
    }

    /// Convenience key binding overload.
    bool bindKey(scope const(char)[] action, Key k, float scale = 1.0f) nothrow @nogc {
        return bind(action, InputBinding.fromKey(k, scale));
    }

    /// Convenience mouse button binding overload.
    bool bindMouse(scope const(char)[] action, MouseButton b, float scale = 1.0f) nothrow @nogc {
        return bind(action, InputBinding.fromMouse(b, scale));
    }

    /// Convenience gamepad button binding overload.
    bool bindPadButton(scope const(char)[] action, PadButton b, float scale = 1.0f) nothrow @nogc {
        return bind(action, InputBinding.fromPadButton(b, scale));
    }

    /// Convenience gamepad axis half-axis binding overload.
    bool bindPadAxis(scope const(char)[] action, PadAxis a, bool positive = true,
                     float deadzone = 0.15f, float scale = 1.0f) nothrow @nogc {
        return bind(action, InputBinding.fromPadAxis(a, positive, deadzone, scale));
    }

    /// Remove a specific binding from an action. Returns true if removed.
    bool unbind(scope const(char)[] action, InputBinding binding) nothrow @nogc {
        immutable int idx = findSlot(action);
        if (idx < 0) return false;
        auto s = &slots[idx];
        foreach (i; 0 .. s.bindingCount) {
            if (s.bindings[i].kind == binding.kind && s.bindings[i].code == binding.code) {
                s.bindings[i] = s.bindings[s.bindingCount - 1];
                s.bindings[--s.bindingCount] = InputBinding.init;
                return true;
            }
        }
        return false;
    }

    /// Clear all bindings for `action`.
    void clearAction(scope const(char)[] action) nothrow @nogc {
        immutable int idx = findSlot(action);
        if (idx < 0) return;
        slots[idx].bindingCount = 0;
    }

    /// Clear all registered actions and bindings.
    void clearAll() nothrow @nogc {
        actionCount = 0;
    }

    /// Bind 4 directional keyboard keys to negative/positive X and Y action names.
    void bindAxis2D(
        scope const(char)[] negX, scope const(char)[] posX,
        scope const(char)[] negY, scope const(char)[] posY,
        Key kNegX, Key kPosX, Key kNegY, Key kPosY
    ) nothrow @nogc {
        bindKey(negX, kNegX);
        bindKey(posX, kPosX);
        bindKey(negY, kNegY);
        bindKey(posY, kPosY);
    }

    /// Bind a thumbstick's X/Y axes to four directional actions.
    void bindStick(
        scope const(char)[] negX, scope const(char)[] posX,
        scope const(char)[] negY, scope const(char)[] posY,
        PadAxis xAxis = PadAxis.leftX, PadAxis yAxis = PadAxis.leftY,
        float deadzone = 0.15f
    ) nothrow @nogc {
        bindPadAxis(negX, xAxis, false, deadzone);
        bindPadAxis(posX, xAxis, true,  deadzone);
        bindPadAxis(negY, yAxis, false, deadzone);
        bindPadAxis(posY, yAxis, true,  deadzone);
    }

    /// Analog strength in `[0, 1]` across all bound devices for `action`.
    float strength(scope const(char)[] action, const ref InputState input, uint padSlot = 0) const nothrow @nogc {
        immutable int idx = findSlot(action);
        if (idx < 0) return 0.0f;
        const s = &slots[idx];
        float best = 0.0f;
        foreach (i; 0 .. s.bindingCount) {
            immutable b = s.bindings[i];
            float v = 0.0f;
            final switch (b.kind) {
                case InputBindingKind.key:
                    if (input.keyDown(cast(Key) b.code)) v = 1.0f;
                    break;
                case InputBindingKind.mouseButton:
                    if (input.mouseDown(cast(MouseButton) cast(ubyte) b.code)) v = 1.0f;
                    break;
                case InputBindingKind.gamepadButton:
                    if (input.padDown(cast(PadButton) cast(ubyte) b.code, padSlot)) v = 1.0f;
                    break;
                case InputBindingKind.gamepadAxisPos:
                    v = evalAxis(input.pad(padSlot), cast(PadAxis) cast(ubyte) b.code, true, b.deadzone);
                    break;
                case InputBindingKind.gamepadAxisNeg:
                    v = evalAxis(input.pad(padSlot), cast(PadAxis) cast(ubyte) b.code, false, b.deadzone);
                    break;
            }
            v *= b.scale;
            if (v > best) best = v;
        }
        return best > 1.0f ? 1.0f : (best < 0.0f ? 0.0f : best);
    }

    bool isDown(scope const(char)[] action, const ref InputState input, uint padSlot = 0) const nothrow @nogc {
        return strength(action, input, padSlot) >= 0.5f;
    }

    bool isPressed(scope const(char)[] action, const ref InputState input, uint padSlot = 0) const nothrow @nogc {
        immutable int idx = findSlot(action);
        if (idx < 0) return false;
        const s = &slots[idx];
        foreach (i; 0 .. s.bindingCount) {
            immutable b = s.bindings[i];
            final switch (b.kind) {
                case InputBindingKind.key:
                    if (input.keyPressed(cast(Key) b.code)) return true;
                    break;
                case InputBindingKind.mouseButton:
                    if (input.mousePressed(cast(MouseButton) cast(ubyte) b.code)) return true;
                    break;
                case InputBindingKind.gamepadButton:
                    if (input.padPressed(cast(PadButton) cast(ubyte) b.code, padSlot)) return true;
                    break;
                case InputBindingKind.gamepadAxisPos:
                case InputBindingKind.gamepadAxisNeg:
                    break;
            }
        }
        return false;
    }

    bool isUp(scope const(char)[] action, const ref InputState input, uint padSlot = 0) const nothrow @nogc {
        immutable int idx = findSlot(action);
        if (idx < 0) return false;
        const s = &slots[idx];
        foreach (i; 0 .. s.bindingCount) {
            immutable b = s.bindings[i];
            final switch (b.kind) {
                case InputBindingKind.key:
                    if (input.keyUp(cast(Key) b.code)) return true;
                    break;
                case InputBindingKind.mouseButton:
                    if (input.mouseUp(cast(MouseButton) cast(ubyte) b.code)) return true;
                    break;
                case InputBindingKind.gamepadButton:
                    if (input.padUp(cast(PadButton) cast(ubyte) b.code, padSlot)) return true;
                    break;
                case InputBindingKind.gamepadAxisPos:
                case InputBindingKind.gamepadAxisNeg:
                    break;
            }
        }
        return false;
    }

    /// Combine 4 directional actions into a radial-clamped 2D axis vector (`|v| <= 1`).
    Vec2 axis2D(
        scope const(char)[] negX, scope const(char)[] posX,
        scope const(char)[] negY, scope const(char)[] posY,
        const ref InputState input, uint padSlot = 0
    ) const nothrow @nogc {
        immutable float x = strength(posX, input, padSlot) - strength(negX, input, padSlot);
        immutable float y = strength(posY, input, padSlot) - strength(negY, input, padSlot);
        immutable float len2 = x * x + y * y;
        if (len2 > 1.0f) {
            immutable float inv = 1.0f / sqrt(len2);
            return Vec2(x * inv, y * inv);
        }
        return Vec2(x, y);
    }

    /// Serialize all action bindings to JSON string.
    string toJson() const {
        import std.format : format;
        string outStr = "{\n  \"actions\": {\n";
        foreach (uint i; 0 .. actionCount) {
            const s = &slots[i];
            outStr ~= format("    \"%s\": [", s.name());
            foreach (uint j; 0 .. s.bindingCount) {
                immutable b = s.bindings[j];
                if (j > 0) outStr ~= ", ";
                outStr ~= format(
                    `{"kind": %d, "code": %d, "scale": %.4f, "deadzone": %.4f}`,
                    cast(uint) b.kind, b.code, b.scale, b.deadzone
                );
            }
            outStr ~= (i + 1 < actionCount) ? "],\n" : "]\n";
        }
        outStr ~= "  }\n}\n";
        return outStr;
    }

    /// Deserialize action bindings from JSON text produced by `toJson`.
    bool fromJson(scope const(char)[] jsonText) {
        import std.json;
        try {
            auto root = parseJSON(jsonText);
            if (root.type != JSONType.object || "actions" !in root) return false;
            auto acts = root["actions"];
            if (acts.type != JSONType.object) return false;

            clearAll();
            auto actsObj = () @trusted { return acts.object; }();
            foreach (string name, JSONValue arr; actsObj) {
                if (arr.type != JSONType.array) continue;
                auto arrItems = () @trusted { return arr.array; }();
                foreach (item; arrItems) {
                    if (item.type != JSONType.object) continue;
                    InputBinding b;
                    if ("kind" in item) b.kind = cast(InputBindingKind) item["kind"].get!long();
                    if ("code" in item) b.code = cast(uint) item["code"].get!long();
                    if ("scale" in item) b.scale = cast(float) jsonFloat(item["scale"]);
                    if ("deadzone" in item) b.deadzone = cast(float) jsonFloat(item["deadzone"]);
                    bind(name, b);
                }
            }
            return true;
        } catch (Exception) {
            return false;
        }
    }

    bool saveToFile(scope const(char)[] path) const {
        import std.file : write;
        try {
            () @trusted { write(path, toJson()); }();
            return true;
        } catch (Exception) {
            return false;
        }
    }

    bool loadFromFile(scope const(char)[] path) {
        import std.file : exists, readText;
        if (!exists(path)) return false;
        try {
            auto txt = () @trusted { return readText(path); }();
            return fromJson(txt);
        } catch (Exception) {
            return false;
        }
    }

    private static double jsonFloat(T)(T v) {
        import std.json : JSONType;
        if (v.type == JSONType.float_) return v.floating;
        if (v.type == JSONType.integer) return cast(double) v.integer;
        if (v.type == JSONType.uinteger) return cast(double) v.uinteger;
        return 0.0;
    }

    private static float evalAxis(const(GamepadState)* gp, PadAxis axis, bool positive, float deadzone) nothrow @nogc pure {
        if (gp is null || !gp.connected) return 0.0f;
        float raw = 0.0f;
        final switch (axis) {
            case PadAxis.leftX:        raw = gp.leftX; break;
            case PadAxis.leftY:        raw = gp.leftY; break;
            case PadAxis.rightX:       raw = gp.rightX; break;
            case PadAxis.rightY:       raw = gp.rightY; break;
            case PadAxis.leftTrigger:  raw = gp.leftTrigger; break;
            case PadAxis.rightTrigger: raw = gp.rightTrigger; break;
        }
        immutable float signed = positive ? raw : -raw;
        if (signed <= deadzone) return 0.0f;
        if (deadzone >= 0.99f) return 1.0f;
        immutable float scaled = (signed - deadzone) / (1.0f - deadzone);
        return scaled > 1.0f ? 1.0f : scaled;
    }
}

static assert(isPod!InputMap);

private void pushKeyEvent(ref InputState s, uint type, uint scancode) @trusted {
    import bindings.sdl3 : SDL_Event, SDL_Scancode;
    SDL_Event ev = SDL_Event.init;
    ev.type = type;
    ev.key.scancode = cast(SDL_Scancode) scancode;
    s.processEvent(ev);
}

unittest {
    import bindings.sdl3;

    InputState input;
    input.actions.bindKey("jump", Key.space);
    input.actions.bindMouse("fire", MouseButton.left);
    input.actions.bindPadButton("jump", PadButton.a);
    input.actions.bindAxis2D(
        "move_left", "move_right", "move_down", "move_up",
        Key.a, Key.d, Key.s, Key.w
    );
    input.actions.bindStick("move_left", "move_right", "move_up", "move_down");

    input.beginFrame();
    pushKeyEvent(input, SDL_EVENT_KEY_DOWN, SDL_Scancode.SCANCODE_SPACE);

    assert(input.actionPressed("jump"));
    assert(input.actionDown("jump"));
    assert(input.actionStrength("jump") == 1.0f);

    // Diagonal W + D axis2D clamps magnitude to 1.0
    pushKeyEvent(input, SDL_EVENT_KEY_DOWN, SDL_Scancode.SCANCODE_W);
    pushKeyEvent(input, SDL_EVENT_KEY_DOWN, SDL_Scancode.SCANCODE_D);

    immutable Vec2 move = input.axis2D("move_left", "move_right", "move_down", "move_up");
    assert(move.x > 0.7f && move.x < 0.72f);
    assert(move.y > 0.7f && move.y < 0.72f);

    // JSON round-trip
    string json = input.actions.toJson();
    InputMap restored;
    assert(restored.fromJson(json));
    assert(restored.isDown("jump", input));
    assert(restored.isDown("move_right", input));
}
