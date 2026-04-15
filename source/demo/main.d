/// Demo — clear-screen with WGPU + SDL3.
/// This is the simplest possible rendering demo to validate the engine stack.
module demo.main;

import engine;

void main() {
    auto app = App.create("Game Engine Demo", 1280, 720);
    scope(exit) app.destroy();

    while (app.running) {
        app.pollEvents();

        if (app.input.keyPressed(Key.escape))
            app.close();

        auto frame = app.beginFrame(Color(0.05, 0.05, 0.12, 1.0));
        // Future: draw calls go here using frame.pass
        app.endFrame(frame);
    }
}
