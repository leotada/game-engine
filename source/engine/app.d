/// Application framework — ties window, GPU, and input into a simple loop API.
module engine.app;

import bindings.sdl3;
import engine.platform.window;
import engine.platform.input;
import engine.gpu.context;
import engine.gpu.renderer;
import engine.core.log;

@safe:

struct App {
    Window    window;
    GpuContext gpu;
    Renderer  renderer;
    InputState input;

    private bool _running = true;

    @disable this(this);

    static App create(const(char)* title, uint width, uint height) @trusted {
        App app;
        app.window   = Window.create(title, width, height);
        app.gpu      = GpuContext.create(
            app.window.waylandDisplay(),
            app.window.waylandSurface(),
            width, height,
        );
        app.renderer = Renderer.create(app.gpu);
        info("App ready");
        return app;
    }

    bool running() const nothrow @nogc { return _running; }

    void close() nothrow @nogc { _running = false; }

    void pollEvents() nothrow @nogc @trusted {
        input.beginFrame();
        SDL_Event ev = void;
        while (SDL_PollEvent(&ev))
            input.processEvent(ev);

        if (input.quitRequested())
            _running = false;
    }

    FrameContext beginFrame(Color clearColor) nothrow @nogc {
        return renderer.beginFrame(clearColor);
    }

    void endFrame(ref FrameContext frame) nothrow @nogc {
        renderer.endFrame(frame);
    }

    void destroy() {
        renderer = Renderer.init;
        gpu.destroy();
        window.destroy();
        info("App destroyed");
    }

    ~this() { destroy(); }
}
