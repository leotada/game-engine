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
    webCanvas = 6,
}

struct NativeSurfaceInfo {
    NativeSurfaceBackend backend = NativeSurfaceBackend.none;
    void* displayOrInstance = null; // wl_display*, Display* (X11), HINSTANCE (Win32)
    void* windowOrSurface   = null; // wl_surface*, HWND (Win32), ANativeWindow* (Android), CAMetalLayer* (Apple)
    ulong x11Window         = 0;    // Window ID (X11)
    const(char)* canvasSelector = null; // CSS selector (Emscripten WebGPU)
}

/// Options for `Window.create`.
struct WindowOptions {
    bool fullscreen = false;
    bool borderless = false;
    bool resizable = false;
    bool highPixelDensity = false;
    bool hidden = false;
}

struct Window {
    private SDL_Window* handle;
    private SDL_MetalView metalView;
    private SDL_Cursor* customCursor;
    private uint w, h;

    @disable this(this);

    static Window create(const(char)* title, uint width, uint height,
                         WindowOptions opts = WindowOptions.init) @trusted {
        // SDL captures the pointer on every button press and, on KWin/Wayland,
        // that capture does a wl_display round-trip. Nested with the wgpu
        // present wait, the round-trip stalls the frame for a few seconds.
        SDL_SetHint("SDL_MOUSE_AUTO_CAPTURE", "0");
        if (!SDL_Init(SDL_INIT_VIDEO | SDL_INIT_EVENTS | SDL_INIT_AUDIO | SDL_INIT_GAMEPAD)) {
            err("SDL_Init failed");
            assert(false);
        }
        ulong flags = 0;
        if (opts.fullscreen)       flags |= SDL_WINDOW_FULLSCREEN;
        if (opts.borderless)       flags |= SDL_WINDOW_BORDERLESS;
        if (opts.resizable)        flags |= SDL_WINDOW_RESIZABLE;
        if (opts.highPixelDensity) flags |= SDL_WINDOW_HIGH_PIXEL_DENSITY;
        if (opts.hidden)           flags |= SDL_WINDOW_HIDDEN;

        auto win = SDL_CreateWindow(title, width, height, flags);
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

        Window result = Window(win, mv, null, width, height);
        result.refreshSize();
        return result;
    }

    bool valid() const nothrow @nogc { return handle !is null; }
    uint width()  const nothrow @nogc { return w; }
    uint height() const nothrow @nogc { return h; }

    /// Toggle exclusive/desktop fullscreen mode. Does NOT update width()/height():
    /// the size change is consumed by `refreshSize()`, and a caller that consumed it
    /// here would leave the swapchain at the old size. Prefer `App.setFullscreen`,
    /// which also reconfigures the swapchain and render targets.
    bool setFullscreen(bool enabled) @trusted {
        if (handle is null) return false;
        immutable bool ok = SDL_SetWindowFullscreen(handle, enabled);
        SDL_SyncWindow(handle);
        return ok;
    }

    bool isFullscreen() const nothrow @nogc @trusted {
        if (handle is null) return false;
        return (SDL_GetWindowFlags(cast(SDL_Window*) handle) & SDL_WINDOW_FULLSCREEN) != 0;
    }

    /// Update the window title bar text (UTF-8, truncated to 255 bytes).
    void setTitle(scope const(char)[] title) nothrow @nogc @trusted {
        if (handle is null) return;
        char[256] buf = 0;
        immutable size_t n = title.length < 255 ? title.length : 255;
        buf[0 .. n] = title[0 .. n];
        buf[n] = '\0';
        SDL_SetWindowTitle(handle, buf.ptr);
    }

    /// Set the OS window icon from an RGBA8 pixel buffer (top-left origin).
    bool setIcon(const(ubyte)[] rgba, uint iconW, uint iconH) nothrow @nogc @trusted {
        if (handle is null || iconW == 0 || iconH == 0) return false;
        if (rgba.length < cast(size_t) iconW * iconH * 4) return false;
        auto surf = SDL_CreateSurfaceFrom(
            cast(int) iconW, cast(int) iconH,
            SDL_PIXELFORMAT_RGBA32,
            cast(void*) rgba.ptr,
            cast(int)(iconW * 4)
        );
        if (surf is null) return false;
        scope(exit) SDL_DestroySurface(surf);
        return SDL_SetWindowIcon(handle, surf);
    }

    bool setResizable(bool enabled) nothrow @nogc @trusted {
        return handle !is null && SDL_SetWindowResizable(handle, enabled);
    }

    bool setBordered(bool enabled) nothrow @nogc @trusted {
        return handle !is null && SDL_SetWindowBordered(handle, enabled);
    }

    /// Show or hide the OS mouse cursor.
    bool setCursorVisible(bool visible) nothrow @nogc @trusted {
        return visible ? SDL_ShowCursor() : SDL_HideCursor();
    }

    bool isCursorVisible() const nothrow @nogc @trusted {
        return SDL_CursorVisible();
    }

    /// Set an RGBA8 custom image as the active OS mouse cursor.
    bool setCustomCursor(const(ubyte)[] rgba, uint cursorW, uint cursorH,
                         int hotX = 0, int hotY = 0) nothrow @nogc @trusted {
        if (cursorW == 0 || cursorH == 0) return false;
        if (rgba.length < cast(size_t) cursorW * cursorH * 4) return false;

        auto surf = SDL_CreateSurfaceFrom(
            cast(int) cursorW, cast(int) cursorH,
            SDL_PIXELFORMAT_RGBA32,
            cast(void*) rgba.ptr,
            cast(int)(cursorW * 4)
        );
        if (surf is null) return false;
        scope(exit) SDL_DestroySurface(surf);

        auto cursor = SDL_CreateColorCursor(surf, hotX, hotY);
        if (cursor is null) return false;

        if (!SDL_SetCursor(cursor)) {
            SDL_DestroyCursor(cursor);
            return false;
        }
        if (customCursor !is null) {
            SDL_DestroyCursor(customCursor);
        }
        customCursor = cursor;
        return true;
    }

    /// Restore the OS default cursor and free any custom cursor image.
    bool resetCursor() nothrow @nogc @trusted {
        immutable bool ok = SDL_SetCursor(null);
        if (customCursor !is null) {
            SDL_DestroyCursor(customCursor);
            customCursor = null;
        }
        return ok;
    }

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

        version (WebAssembly) {
            return NativeSurfaceInfo(NativeSurfaceBackend.webCanvas, null, null, 0, "#canvas".ptr);
        } else version (Windows) {
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
        if (customCursor !is null) {
            SDL_SetCursor(null);
            SDL_DestroyCursor(customCursor);
            customCursor = null;
        }
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
