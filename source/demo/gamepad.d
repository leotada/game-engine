/// Interactive Xbox / SDL3 Gamepad diagnostic and haptic testbed.
/// Shows connected slots, normalized sticks/triggers, button states, and tests
/// dual-motor rumble + Xbox One/Series impulse trigger rumble.
module demo.gamepad;

import std.format : format;

import bindings.wgpu : WGPUPresentMode;
import engine.app : App;
import engine.core.log;
import engine.gpu.text : FpsCounter, TextRenderer;
import engine.graphics.types : Color4;
import engine.math.vec : Vec2;
import engine.platform.gamepad : GamepadState, MAX_GAMEPADS, PadButton, gamepadTypeName;
import engine.platform.input : Key;

version (Symgc_cards) {
    extern (C) __gshared string[] rt_options = ["gcopt=gc:sdcq"];
}

@safe:

private enum SCREEN_W = 1280;
private enum SCREEN_H = 720;

private struct ButtonLabel {
    PadButton btn;
    string name;
}

private static immutable ButtonLabel[] XBOX_BUTTONS = [
    ButtonLabel(PadButton.a,          "A"),
    ButtonLabel(PadButton.b,          "B"),
    ButtonLabel(PadButton.x,          "X"),
    ButtonLabel(PadButton.y,          "Y"),
    ButtonLabel(PadButton.lb,         "LB"),
    ButtonLabel(PadButton.rb,         "RB"),
    ButtonLabel(PadButton.ls,         "LS"),
    ButtonLabel(PadButton.rs,         "RS"),
    ButtonLabel(PadButton.view,       "View"),
    ButtonLabel(PadButton.menu,       "Menu"),
    ButtonLabel(PadButton.guide,      "Xbox"),
    ButtonLabel(PadButton.share,      "Share"),
    ButtonLabel(PadButton.dpadUp,     "D-Up"),
    ButtonLabel(PadButton.dpadDown,   "D-Down"),
    ButtonLabel(PadButton.dpadLeft,   "D-Left"),
    ButtonLabel(PadButton.dpadRight,  "D-Right"),
];

void main(string[] args) {
    uint headlessFrames = 0;
    foreach (arg; args[1 .. $]) {
        if (arg.length > 18 && arg[0 .. 18] == "--headless-frames=") {
            import std.conv : to;
            headlessFrames = arg[18 .. $].to!uint();
        }
    }

    auto app = App.create("Xbox Controller / SDL3 Gamepad Test", SCREEN_W, SCREEN_H, WGPUPresentMode.fifo);
    scope (exit) app.destroy();

    auto text = TextRenderer.create(app.gpu, SCREEN_W, SCREEN_H);
    scope (exit) text.destroy();
    auto fps = FpsCounter.create();

    uint activeSlot = 0;
    uint frameCount = 0;
    string lastEventMsg = "Waiting for input...";

    while (app.running()) {
        app.pollEvents();
        app.handleResize();
        fps.tick();

        if (app.input.keyPressed(Key.escape))
            break;

        // Allow selecting slot 0..7 with Tab or first connected slot automatically
        if (!app.input.padConnected(activeSlot)) {
            immutable int first = app.input.firstPad();
            if (first >= 0) activeSlot = cast(uint) first;
        }
        if (app.input.keyPressed(Key.tab)) {
            activeSlot = (activeSlot + 1) % MAX_GAMEPADS;
        }

        if (app.input.padConnected(activeSlot)) {
            if (app.input.padPressed(PadButton.x, activeSlot) || app.input.keyPressed(Key.digit1)) {
                immutable ok = app.gamepads.rumble(activeSlot, 0.75f, 0.90f, 300);
                lastEventMsg = ok ? "Body rumble burst (300ms)" : "Body rumble unsupported/failed";
            }
            if (app.input.padPressed(PadButton.y, activeSlot) || app.input.keyPressed(Key.digit2)) {
                immutable ok = app.gamepads.rumbleTriggers(activeSlot, 0.85f, 0.85f, 300);
                lastEventMsg = ok ? "Trigger rumble burst (300ms)" : "Trigger rumble unsupported/failed";
            }
            if (app.input.padPressed(PadButton.b, activeSlot) || app.input.keyPressed(Key.digit0)) {
                app.gamepads.stopRumble(activeSlot);
                lastEventMsg = "Stopped all rumble";
            }

            // Live proportional Xbox trigger rumble while pulling LT or RT
            immutable float lt = app.input.padLeftTrigger(activeSlot);
            immutable float rt = app.input.padRightTrigger(activeSlot);
            if (lt > 0.05f || rt > 0.05f) {
                app.gamepads.rumbleTriggers(activeSlot, lt, rt, 60);
            }
        }

        auto frame = app.beginFrame(Color4(0.06f, 0.08f, 0.12f, 1.0f));
        if (frame.valid) {
            app.resolvePost(frame);
            text.beginFrame();

            int y = 20;
            text.drawText(frame, format!"Xbox / SDL3 Gamepad Monitor   %s"(fps.text()), 24, y, 2);
            y += 32;
            text.drawText(frame,
                format!"Connected: %u / %u   Active Slot: %u (Tab to cycle, Esc to quit)"(
                    app.input.padCount(), MAX_GAMEPADS, activeSlot),
                24, y, 2);
            y += 36;

            // Slot summary
            foreach (i; 0 .. MAX_GAMEPADS) {
                const(GamepadState)* st = app.input.pad(i);
                immutable marker = (i == activeSlot) ? ">" : " ";
                if (st !is null && st.connected) {
                    text.drawText(frame,
                        format!"%s Slot %u: [%s] %s (VID:%04X PID:%04X)"(
                            marker, i, gamepadTypeName(st.type), st.name(),
                            st.vendorId, st.productId),
                        24, y, 2);
                } else {
                    text.drawText(frame, format!"%s Slot %u: (empty)"(marker, i), 24, y, 2);
                }
                y += 24;
            }

            y += 18;
            if (app.input.padConnected(activeSlot)) {
                immutable Vec2 ls = app.input.padLeftStick(activeSlot);
                immutable Vec2 rs = app.input.padRightStick(activeSlot);
                immutable float lt = app.input.padLeftTrigger(activeSlot);
                immutable float rt = app.input.padRightTrigger(activeSlot);

                text.drawText(frame,
                    format!"Left Stick : (%+.3f, %+.3f)    Left Trigger  (LT): %.3f"(ls.x, ls.y, lt),
                    24, y, 2);
                y += 28;
                text.drawText(frame,
                    format!"Right Stick: (%+.3f, %+.3f)    Right Trigger (RT): %.3f"(rs.x, rs.y, rt),
                    24, y, 2);
                y += 36;

                string downStr = "Pressed Buttons: ";
                bool anyDown = false;
                foreach (b; XBOX_BUTTONS) {
                    if (app.input.padDown(b.btn, activeSlot)) {
                        downStr ~= "[" ~ b.name ~ "] ";
                        anyDown = true;
                    }
                }
                if (!anyDown) downStr ~= "(none)";
                text.drawText(frame, downStr, 24, y, 2);
                y += 36;

                text.drawText(frame,
                    "Haptics: [X / 1] Body Rumble   [Y / 2] Trigger Rumble   [B / 0] Stop   [LT/RT] Live Triggers",
                    24, y, 2);
                y += 28;
                text.drawText(frame, format!"Status: %s"(lastEventMsg), 24, y, 2);
            } else {
                text.drawText(frame,
                    "Connect an Xbox controller via USB or Bluetooth to inspect live axes, buttons & rumble.",
                    24, y, 2);
            }

            app.endFrame(frame);
        }

        frameCount++;
        if (headlessFrames > 0 && frameCount >= headlessFrames)
            break;
    }

    info("Gamepad testbed finished cleanly");
}
