/// SDL3 window wrapper with multiplatform surface handle extraction (Wayland, X11 fallback, Win32, Android, Metal).
module engine.platform.window;

import bindings.sdl3;
import engine.core.log;

@safe:

enum NativeSurfaceBackend : ubyte {
    none = 0,
    wayland = 1,
    x11 = 2,
    win32 = 3,
    android = 4,
    metal = 5,
}

struct NativeSurfaceInfo {
    NativeSurfaceBackend backend = NativeSurfaceBackend.none;
    void* displayOrInstance = null; // wl_display*, Display* (X11), HINSTANCE (Win32)
    void* windowOrSurface   = null; // wl_surface*, HWND (Win32), ANativeWindow* (Android), CAMetalLayer* (Apple)
    ulong x11Window         = 0;    // Window ID (X11)
}

struct Window {
    private SDL_Window* handle;
    private SDL_MetalView metalView;
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

        SDL_MetalView mv = null;
        version (OSX) {
            mv = SDL_Metal_CreateView(win);
        } else version (iOS) {
            mv = SDL_Metal_CreateView(win);
        }

        return Window(win, mv, width, height);
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

    /// Multiplatform surface info (Wayland with automatic X11 fallback on Linux, Win32, Android, Metal).
    NativeSurfaceInfo nativeSurface() @trusted {
        if (handle is null) return NativeSurfaceInfo.init;
        auto props = SDL_GetWindowProperties(handle);

        version (Windows) {
            void* hwnd = SDL_GetPointerProperty(props, SDL_PROP_WINDOW_WIN32_HWND_POINTER, null);
            void* hinst = SDL_GetPointerProperty(props, SDL_PROP_WINDOW_WIN32_HINSTANCE_POINTER, null);
            return NativeSurfaceInfo(NativeSurfaceBackend.win32, hinst, hwnd, 0);
        } else version (Android) {
            void* aWin = SDL_GetPointerProperty(props, SDL_PROP_WINDOW_ANDROID_WINDOW_POINTER, null);
            return NativeSurfaceInfo(NativeSurfaceBackend.android, null, aWin, 0);
        } else version (OSX) {
            void* layer = metalView !is null ? SDL_Metal_GetLayer(metalView) : null;
            return NativeSurfaceInfo(NativeSurfaceBackend.metal, null, layer, 0);
        } else version (iOS) {
            void* layer = metalView !is null ? SDL_Metal_GetLayer(metalView) : null;
            return NativeSurfaceInfo(NativeSurfaceBackend.metal, null, layer, 0);
        } else {
            // Linux / Unix: Primary = Wayland
            void* wlDisp = SDL_GetPointerProperty(props, SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER, null);
            void* wlSurf = SDL_GetPointerProperty(props, SDL_PROP_WINDOW_WAYLAND_SURFACE_POINTER, null);
            if (wlDisp !is null && wlSurf !is null) {
                return NativeSurfaceInfo(NativeSurfaceBackend.wayland, wlDisp, wlSurf, 0);
            }

            // Fallback: X11 (useful when running the standalone game on X11 or XWayland)
            void* x11Disp = SDL_GetPointerProperty(props, SDL_PROP_WINDOW_X11_DISPLAY_POINTER, null);
            long x11Win = SDL_GetNumberProperty(props, SDL_PROP_WINDOW_X11_WINDOW_NUMBER, 0);
            if (x11Disp !is null && x11Win != 0) {
                info("Native surface: falling back to X11");
                return NativeSurfaceInfo(NativeSurfaceBackend.x11, x11Disp, null, cast(ulong) x11Win);
            }

            warn("Unable to extract Wayland or X11 native surface handles from SDL window");
            return NativeSurfaceInfo.init;
        }
    }

    /// Get Wayland wl_display pointer (for WGPU surface creation). Kept for backward compatibility.
    void* waylandDisplay() @trusted {
        auto props = SDL_GetWindowProperties(handle);
        return SDL_GetPointerProperty(props, SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER, null);
    }

    /// Get Wayland wl_surface pointer (for WGPU surface creation). Kept for backward compatibility.
    void* waylandSurface() @trusted {
        auto props = SDL_GetWindowProperties(handle);
        return SDL_GetPointerProperty(props, SDL_PROP_WINDOW_WAYLAND_SURFACE_POINTER, null);
    }

    void destroy() @trusted {
        if (metalView !is null) {
            SDL_Metal_DestroyView(metalView);
            metalView = null;
        }
        if (handle !is null) {
            SDL_DestroyWindow(handle);
            handle = null;
            SDL_Quit();
            info("Window destroyed");
        }
    }

    ~this() @trusted { destroy(); }
}
