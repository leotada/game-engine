/// Application framework — ties window, GPU, and input into a simple loop API.
module engine.app;

import bindings.sdl3;
import bindings.wgpu;
import engine.platform.window;
import engine.platform.input;
import engine.gpu.context;
import engine.gpu.renderer;
import engine.gpu.post : PostSettings;
import engine.graphics.types : Color4;
import engine.core.log;
import engine.core.arena : FrameArena;
import engine.core.gc : gcStepFrameSlack, gcDefragment;
import core.time : MonoTime, Duration, usecs;

@safe:

private enum size_t FRAME_ARENA_CAPACITY = 4 * 1024 * 1024; // 4 MB

struct App {
    Window    window;
    GpuContext gpu;
    Renderer  renderer;
    InputState input;
    FrameArena frameArena;

    private bool     _running = true;
    private MonoTime _frameStartTime;
    private Duration _targetFrameBudget = 16_666.usecs; // ~60 FPS default
    private uint     _targetFps = 60;
    private Duration _lastFrameElapsed = Duration.zero;

    @disable this(this);

    static App create(scope const(char)[] title, uint width, uint height,
                      WGPUPresentMode presentMode = WGPUPresentMode.fifo) @trusted {
        import std.string : toStringz;

        App app;
        app.window   = Window.create(toStringz(title), width, height);
        GpuContext.create(
            app.gpu,
            app.window.nativeSurface(),
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

    /// Configure target FPS and compute expected frame budget. Pass 0 for uncapped.
    void setTargetFps(uint fps) nothrow @nogc {
        _targetFps = fps;
        _targetFrameBudget = fps > 0 ? (1_000_000.usecs / fps) : Duration.zero;
    }

    uint targetFps() const nothrow @nogc { return _targetFps; }
    Duration targetFrameBudget() const nothrow @nogc { return _targetFrameBudget; }
    Duration lastFrameElapsed() const nothrow @nogc { return _lastFrameElapsed; }

    /// Per-frame scratch arena; reset at end of every frame.
    ref FrameArena arena() return nothrow @nogc { return frameArena; }

    /// Post-processing settings (exposure, bloom, FXAA).
    ref PostSettings post() return nothrow @nogc {
        return renderer.postSettings();
    }

    void pollEvents() nothrow @nogc @trusted {
        input.beginFrame();
        pumpEvents();
    }

    /// Drain the OS queue without starting a new input frame.
    /// Call this immediately before a blocking swapchain acquire so a click
    /// is not left unread on the Wayland socket while wgpu waits.
    void pumpEvents() nothrow @nogc @trusted {
        SDL_Event ev = void;
        while (SDL_PollEvent(&ev)) {
            if (ev.type == SDL_EVENT_LOW_MEMORY || ev.type == SDL_EVENT_WILL_ENTER_BACKGROUND) {
                gcDefragment();
            }
            input.processEvent(ev);
        }

        if (input.quitRequested())
            _running = false;
    }

    /// Reconfigure the swapchain and scene targets at the current size.
    /// Used when acquire returns timeout / outdated / lost.
    void recoverSurface() @trusted {
        gpu.resize(window.width(), window.height());
        renderer.resize(window.width(), window.height());
    }

    /// Track the window's drawable size: reconfigure the swapchain and the
    /// HDR/post targets when it changes. Returns true if a resize happened.
    bool handleResize() @trusted {
        if (!window.refreshSize()) return false;
        gpu.resize(window.width(), window.height());
        renderer.resize(window.width(), window.height());
        info("Window resized to ", window.width(), "x", window.height());
        return true;
    }

    FrameContext beginFrame(Color clearColor) nothrow @nogc {
        _frameStartTime = MonoTime.currTime;
        return renderer.beginFrame(clearColor);
    }

    FrameContext beginFrame(Color4 clearColor) nothrow @nogc {
        _frameStartTime = MonoTime.currTime;
        return renderer.beginFrame(clearColor);
    }

    /// Close the HDR scene pass, run post, reopen swapchain pass for UI/text.
    void resolvePost(ref FrameContext frame) nothrow @nogc {
        renderer.resolvePost(frame);
    }

    void endFrame(ref FrameContext frame) nothrow @nogc {
        renderer.endFrame(frame);
        frameArena.reset();

        immutable now = MonoTime.currTime;
        _lastFrameElapsed = now - _frameStartTime;

        if (_targetFrameBudget > Duration.zero && _lastFrameElapsed < _targetFrameBudget) {
            immutable slack = _targetFrameBudget - _lastFrameElapsed;
            // Leave a 250us safety margin for presentation & OS scheduling
            if (slack > 500.usecs) {
                gcStepFrameSlack(slack - 250.usecs);
            }
        }
    }

    void destroy() {
        if (!window.valid()) return;
        renderer.destroy();
        gpu.destroy();
        window.destroy();
        info("App destroyed");
    }

    ~this() { destroy(); }
}
