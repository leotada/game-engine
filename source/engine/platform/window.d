/// SDL3 window wrapper with Wayland surface handle extraction for WGPU.
module engine.platform.window;

import bindings.sdl3;
import engine.core.log;

@safe:

struct Window {
    private SDL_Window* handle;
    private uint w, h;

    @disable this(this);

    static Window create(const(char)* title, uint width, uint height) @trusted {
        // SDL captures the pointer on every button press and, on KWin/Wayland,
        // that capture does a wl_display round-trip. Nested with the wgpu
        // present wait, the round-trip stalls the frame for a few seconds.
        SDL_SetHint("SDL_MOUSE_AUTO_CAPTURE", "0");
        if (!SDL_Init(SDL_INIT_VIDEO | SDL_INIT_EVENTS | SDL_INIT_AUDIO)) {
            err("SDL_Init failed");
            assert(false);
        }
        auto win = SDL_CreateWindow(title, width, height, 0);
        if (win is null) {
            err("SDL_CreateWindow failed");
            assert(false);
        }
        info("Window created");
        return Window(win, width, height);
    }

    bool valid() const @trusted { return handle !is null; }
    uint width()  const { return w; }
    uint height() const { return h; }

    /// Re-read the drawable size (in pixels) from SDL. Returns true when it changed.
    bool refreshSize() @trusted {
        int pw = 0, ph = 0;
        if (!SDL_GetWindowSizeInPixels(handle, &pw, &ph) || pw <= 0 || ph <= 0) return false;
        if (cast(uint) pw == w && cast(uint) ph == h) return false;
        w = cast(uint) pw;
        h = cast(uint) ph;
        return true;
    }

    /// Lock the cursor to the window and switch to relative-motion mode
    /// (useful for FPS-style camera controllers). Pass `false` to release.
    bool setRelativeMouseMode(bool enabled) @trusted {
        return SDL_SetWindowRelativeMouseMode(handle, enabled);
    }

    /// Get Wayland wl_display pointer (for WGPU surface creation).
    void* waylandDisplay() @trusted {
        auto props = SDL_GetWindowProperties(handle);
        return SDL_GetPointerProperty(props, SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER, null);
    }

    /// Get Wayland wl_surface pointer (for WGPU surface creation).
    void* waylandSurface() @trusted {
        auto props = SDL_GetWindowProperties(handle);
        return SDL_GetPointerProperty(props, SDL_PROP_WINDOW_WAYLAND_SURFACE_POINTER, null);
    }

    void destroy() @trusted {
        if (handle !is null) {
            SDL_DestroyWindow(handle);
            handle = null;
            SDL_Quit();
            info("Window destroyed");
        }
    }

    ~this() @trusted { destroy(); }
}
