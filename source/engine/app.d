/// Application framework — ties window, GPU, and input into a simple loop API.
module engine.app;

import bindings.sdl3;
import bindings.wgpu;
import engine.platform.window;
import engine.platform.input;
import engine.platform.gamepad;
import engine.gpu.context;
import engine.gpu.renderer;
import engine.gpu.post : PostSettings;
import engine.graphics.types : Color4;
import engine.assets.png : saveRgbaPngZ;
import engine.core.log;
import engine.core.arena : FrameArena;
import engine.core.gc : gcStepFrameSlack, gcDefragment;
import core.time : MonoTime, Duration, usecs;

@safe:

private enum size_t FRAME_ARENA_CAPACITY = 4 * 1024 * 1024; // 4 MB

version (WebAssembly) {
    private extern (C) nothrow @nogc {
        void emscripten_set_main_loop_arg(
            void function(void*) nothrow @system,
            void* arg,
            int fps,
            bool simulateInfiniteLoop
        );
        void emscripten_cancel_main_loop();
    }

    private struct WebLoopState {
        App* app;
        void* callbackPtr;
        MonoTime prevTime;
        bool firstFrame = true;
    }

    private extern (C) void emscriptenFrameThunk(void* user) nothrow @trusted {
        auto state = cast(WebLoopState*) user;
        if (state is null || state.app is null || !state.app.running) {
            emscripten_cancel_main_loop();
            return;
        }
        immutable now = MonoTime.currTime;
        float dt = 1.0f / 60.0f;
        if (!state.firstFrame) {
            immutable long us = (now - state.prevTime).total!"usecs";
            dt = cast(float) us / 1_000_000.0f;
            if (dt < 0.0001f) dt = 0.0001f;
            if (dt > 0.1f) dt = 0.1f;
        }
        state.firstFrame = false;
        state.prevTime = now;

        alias CallbackFn = void delegate(float);
        try {
            auto dg = *cast(CallbackFn*) state.callbackPtr;
            dg(dt);
        } catch (Throwable) {
            state.app.close();
            emscripten_cancel_main_loop();
        }
        if (!state.app.running) {
            emscripten_cancel_main_loop();
        }
    }
}

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
    private char[256] _pendingShotPath = 0;
    private bool     _hasPendingShot = false;

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

    /// Execute `frameFn(dt)` continuously while `running()` is true.
    /// Uses `emscripten_set_main_loop_arg` on WebAssembly and a `MonoTime`
    /// delta-time loop on native desktop platforms.
    void run(scope void delegate(float dt) frameFn) @trusted {
        version (WebAssembly) {
            WebLoopState state;
            state.app = &this;
            state.callbackPtr = cast(void*) &frameFn;
            state.prevTime = MonoTime.currTime;
            state.firstFrame = true;
            emscripten_set_main_loop_arg(&emscriptenFrameThunk, cast(void*) &state, 0, true);
        } else {
            MonoTime prevTime = MonoTime.currTime;
            bool firstFrame = true;
            while (running) {
                immutable now = MonoTime.currTime;
                float dt = 1.0f / 60.0f;
                if (!firstFrame) {
                    immutable long us = (now - prevTime).total!"usecs";
                    dt = cast(float) us / 1_000_000.0f;
                    if (dt < 0.0001f) dt = 0.0001f;
                    if (dt > 0.1f) dt = 0.1f;
                }
                firstFrame = false;
                prevTime = now;
                frameFn(dt);
            }
        }
    }

    /// Change swapchain present mode at runtime (`fifo` = VSync, `mailbox`/`immediate` = uncapped).
    bool setPresentMode(WGPUPresentMode mode) {
        return gpu.setPresentMode(mode);
    }

    WGPUPresentMode presentMode() const nothrow @nogc {
        return gpu.presentMode();
    }

    /// Toggle VSync on (`fifo`) or off (`mailbox` / `immediate` fallback).
    bool setVsync(bool enabled) {
        if (enabled) return gpu.setPresentMode(WGPUPresentMode.fifo);
        if (gpu.setPresentMode(WGPUPresentMode.mailbox)) return true;
        return gpu.setPresentMode(WGPUPresentMode.immediate);
    }

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

    /// Connected SDL3 gamepads (owned by `input`).
    ref Gamepads gamepads() return nothrow @nogc { return input.gamepads; }

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

    /// Toggle fullscreen and reconfigure the swapchain and HDR/post targets to the
    /// new drawable size right away. Returns false if SDL refused the change.
    /// Games should call this instead of `window.setFullscreen`, then resize
    /// their own size-dependent state (camera, UI) from `window.width/height`.
    bool setFullscreen(bool enabled) @trusted {
        immutable bool ok = window.setFullscreen(enabled);
        handleResize();
        return ok;
    }

    /// Resize the (windowed) window and reconfigure the swapchain and HDR/post targets right
    /// away, like `setFullscreen`. `width`/`height` are SDL window coordinates; read the real
    /// drawable size back from `window.width/height`. Returns false when the size is invalid,
    /// the window is fullscreen (leave fullscreen first) or SDL refused the change.
    /// Games should call this instead of `window.setSize`.
    bool setSize(uint width, uint height) @trusted {
        immutable bool ok = window.setSize(width, height);
        handleResize();
        return ok;
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

    /// Frame capture, see `Renderer.requestCapture` / `readCapture`.
    void requestCapture() nothrow @nogc { renderer.requestCapture(); }
    ubyte[] readCapture(out uint w, out uint h) { return renderer.readCapture(w, h); }

    /// Schedule saving the current frame (after `endFrame()`) to a PNG file via SDL3.
    bool saveScreenshot(scope const(char)[] path) nothrow @nogc {
        if (path.length == 0 || path.length >= _pendingShotPath.length) return false;
        _pendingShotPath[] = 0;
        _pendingShotPath[0 .. path.length] = path[];
        _pendingShotPath[path.length] = '\0';
        _hasPendingShot = true;
        renderer.requestCapture();
        return true;
    }

    private static void pngCaptureSink(const(ubyte)* rgba, uint w, uint h, void* user) nothrow @nogc @trusted {
        saveRgbaPngZ(cast(const(char)*) user, rgba, w, h);
    }

    void endFrame(ref FrameContext frame) nothrow @nogc {
        renderer.endFrame(frame);
        if (_hasPendingShot) {
            _hasPendingShot = false;
            () @trusted {
                renderer.consumeCaptureWith(&pngCaptureSink, _pendingShotPath.ptr);
            }();
        }
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
        input.destroy();
        renderer.destroy();
        gpu.destroy();
        window.destroy();
        info("App destroyed");
    }

    ~this() { destroy(); }
}
