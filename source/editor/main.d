/// Entry point for the visual game engine editor.
module editor.main;

import std.conv : to;
import editor.editor_app;

version (Symgc_cards) {
    /// Default runtime options when built with Symgc configurations: activate steadygc concurrent collector
    extern (C) __gshared string[] rt_options = ["gcopt=gc:sdcq"];
}

void main(string[] args) {
    bool headless = false;
    uint headlessFrames = 0;
    bool assertNoGc = false;
    string scenePath = "";

    foreach (arg; args[1 .. $]) {
        if (arg == "--assert-no-gc") {
            assertNoGc = true;
        } else if (arg.length > 18 && arg[0 .. 18] == "--headless-frames=") {
            headless = true;
            headlessFrames = to!uint(arg[18 .. $]);
        } else if (arg.length > 0 && arg[0] != '-') {
            scenePath = arg;
        }
    }

    EditorApp app;
    app.init(scenePath, headless);

    if (headlessFrames > 0) {
        app.runHeadlessFrames(headlessFrames, assertNoGc);
    } else {
        app.run();
    }
}
