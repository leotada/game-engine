/// Application framework — ties window, GPU, and input into a simple loop API.
module engine.app;

import bindings.sdl3;
import bindings.wgpu;
import engine.platform.window;
import engine.platform.input;
import engine.gpu.context;
import engine.gpu.renderer;
import engine.graphics.types : Color4;
import engine.core.log;
import engine.core.arena : FrameArena;

@safe:

private enum size_t FRAME_ARENA_CAPACITY = 4 * 1024 * 1024; // 4 MB

struct App {
    Window    window;
    GpuContext gpu;
    Renderer  renderer;
    InputState input;
    FrameArena frameArena;

    private bool _running = true;

    @disable this(this);

    static App create(scope const(char)[] title, uint width, uint height,
                      WGPUPresentMode presentMode = WGPUPresentMode.fifo) @trusted {
        import std.string : toStringz;

        App app;
        app.window   = Window.create(toStringz(title), width, height);
        GpuContext.create(
            app.gpu,
            app.window.waylandDisplay(),
            app.window.waylandSurface(),
            width, height,
            presentMode,
        );
        app.renderer = Renderer.create(app.gpu);
        app.frameArena = FrameArena(FRAME_ARENA_CAPACITY);
        info("App ready");
        return app;
    }

    bool running() const nothrow @nogc { return _running; }

    void close() nothrow @nogc { _running = false; }

    /// Per-frame scratch arena; reset at end of every frame.
    ref FrameArena arena() return nothrow @nogc { return frameArena; }

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

    /// Convenience: accept a Color4 directly.
    FrameContext beginFrame(Color4 clearColor) nothrow @nogc {
        return renderer.beginFrame(clearColor);
    }

    void endFrame(ref FrameContext frame) nothrow @nogc {
        renderer.endFrame(frame);
        frameArena.reset();
    }

    void destroy() {
        renderer.destroy();
        gpu.destroy();
        window.destroy();
        info("App destroyed");
    }

    ~this() { destroy(); }
}
