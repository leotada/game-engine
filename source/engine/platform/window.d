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
        if (!SDL_Init(SDL_INIT_VIDEO | SDL_INIT_EVENTS)) {
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
