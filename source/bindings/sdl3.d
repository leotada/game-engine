/// Minimal SDL3 bindings for the game engine.
/// Targets SDL 3.2.x C API — Wayland + Vulkan focus.
module bindings.sdl3;

extern (C):
nothrow:
@nogc:

// ---------------------------------------------------------------------------
// Opaque types
// ---------------------------------------------------------------------------
alias SDL_Window = void;
alias SDL_PropertiesID = uint;
alias SDL_WindowID = uint;

// ---------------------------------------------------------------------------
// Init flags
// ---------------------------------------------------------------------------
enum : uint {
    SDL_INIT_VIDEO  = 0x0000_0020,
    SDL_INIT_AUDIO  = 0x0000_0010,
    SDL_INIT_EVENTS = 0x0000_4000,
}

// ---------------------------------------------------------------------------
// Window flags
// ---------------------------------------------------------------------------
enum : uint {
    SDL_WINDOW_FULLSCREEN         = 0x0000_0001,
    SDL_WINDOW_OPENGL             = 0x0000_0002,
    SDL_WINDOW_HIDDEN             = 0x0000_0008,
    SDL_WINDOW_BORDERLESS         = 0x0000_0010,
    SDL_WINDOW_RESIZABLE          = 0x0000_0020,
    SDL_WINDOW_MINIMIZED          = 0x0000_0040,
    SDL_WINDOW_MAXIMIZED          = 0x0000_0080,
    SDL_WINDOW_HIGH_PIXEL_DENSITY = 0x0000_2000,
    SDL_WINDOW_VULKAN             = 0x1000_0000,
    SDL_WINDOW_METAL              = 0x2000_0000,
}

// ---------------------------------------------------------------------------
// Event types
// ---------------------------------------------------------------------------
enum : uint {
    SDL_EVENT_QUIT                   = 0x100,

    // Window events
    SDL_EVENT_WINDOW_SHOWN           = 0x202,
    SDL_EVENT_WINDOW_HIDDEN          = 0x203,
    SDL_EVENT_WINDOW_EXPOSED         = 0x204,
    SDL_EVENT_WINDOW_MOVED           = 0x205,
    SDL_EVENT_WINDOW_RESIZED         = 0x206,
    SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED = 0x207,
    SDL_EVENT_WINDOW_MINIMIZED       = 0x209,
    SDL_EVENT_WINDOW_MAXIMIZED       = 0x20A,
    SDL_EVENT_WINDOW_RESTORED        = 0x20B,
    SDL_EVENT_WINDOW_MOUSE_ENTER     = 0x20C,
    SDL_EVENT_WINDOW_MOUSE_LEAVE     = 0x20D,
    SDL_EVENT_WINDOW_FOCUS_GAINED    = 0x20E,
    SDL_EVENT_WINDOW_FOCUS_LOST      = 0x20F,
    SDL_EVENT_WINDOW_CLOSE_REQUESTED = 0x210,

    // Keyboard events
    SDL_EVENT_KEY_DOWN               = 0x300,
    SDL_EVENT_KEY_UP                 = 0x301,
    SDL_EVENT_TEXT_INPUT             = 0x303,

    // Mouse events
    SDL_EVENT_MOUSE_MOTION           = 0x400,
    SDL_EVENT_MOUSE_BUTTON_DOWN      = 0x401,
    SDL_EVENT_MOUSE_BUTTON_UP        = 0x402,
    SDL_EVENT_MOUSE_WHEEL            = 0x403,
}

// ---------------------------------------------------------------------------
// Scancode subset (USB HID page 0x07)
// ---------------------------------------------------------------------------
enum SDL_Scancode : uint {
    SCANCODE_A      = 4,
    SCANCODE_B      = 5,
    SCANCODE_C      = 6,
    SCANCODE_D      = 7,
    SCANCODE_E      = 8,
    SCANCODE_F      = 9,
    SCANCODE_G      = 10,
    SCANCODE_H      = 11,
    SCANCODE_I      = 12,
    SCANCODE_J      = 13,
    SCANCODE_K      = 14,
    SCANCODE_L      = 15,
    SCANCODE_M      = 16,
    SCANCODE_N      = 17,
    SCANCODE_O      = 18,
    SCANCODE_P      = 19,
    SCANCODE_Q      = 20,
    SCANCODE_R      = 21,
    SCANCODE_S      = 22,
    SCANCODE_T      = 23,
    SCANCODE_U      = 24,
    SCANCODE_V      = 25,
    SCANCODE_W      = 26,
    SCANCODE_X      = 27,
    SCANCODE_Y      = 28,
    SCANCODE_Z      = 29,
    SCANCODE_1      = 30,
    SCANCODE_2      = 31,
    SCANCODE_3      = 32,
    SCANCODE_4      = 33,
    SCANCODE_5      = 34,
    SCANCODE_6      = 35,
    SCANCODE_7      = 36,
    SCANCODE_8      = 37,
    SCANCODE_9      = 38,
    SCANCODE_0      = 39,
    SCANCODE_RETURN = 40,
    SCANCODE_ESCAPE = 41,
    SCANCODE_BACKSPACE = 42,
    SCANCODE_TAB    = 43,
    SCANCODE_SPACE  = 44,
    SCANCODE_F1     = 58,
    SCANCODE_F2     = 59,
    SCANCODE_F3     = 60,
    SCANCODE_F4     = 61,
    SCANCODE_F5     = 62,
    SCANCODE_F6     = 63,
    SCANCODE_F7     = 64,
    SCANCODE_F8     = 65,
    SCANCODE_F9     = 66,
    SCANCODE_F10    = 67,
    SCANCODE_F11    = 68,
    SCANCODE_F12    = 69,
    SCANCODE_RIGHT  = 79,
    SCANCODE_LEFT   = 80,
    SCANCODE_DOWN   = 81,
    SCANCODE_UP     = 82,
    SCANCODE_LCTRL  = 224,
    SCANCODE_LSHIFT = 225,
    SCANCODE_LALT   = 226,
}

// ---------------------------------------------------------------------------
// Event structures
// ---------------------------------------------------------------------------
struct SDL_KeyboardEvent {
    uint type;
    uint reserved;
    ulong timestamp;
    SDL_WindowID windowID;
    uint which;
    SDL_Scancode scancode;
    uint key;       // SDL_Keycode
    ushort mod;
    ushort raw;
    bool down;
    bool repeat;
}

struct SDL_MouseMotionEvent {
    uint type;
    uint reserved;
    ulong timestamp;
    SDL_WindowID windowID;
    uint which;
    uint state;
    float x, y;
    float xrel, yrel;
}

struct SDL_MouseButtonEvent {
    uint type;
    uint reserved;
    ulong timestamp;
    SDL_WindowID windowID;
    uint which;
    ubyte button;
    bool down;
    ubyte clicks;
    ubyte padding;
    float x, y;
}

struct SDL_MouseWheelEvent {
    uint type;
    uint reserved;
    ulong timestamp;
    SDL_WindowID windowID;
    uint which;
    float x, y;
    int direction;
    float mouse_x, mouse_y;
}

struct SDL_WindowEvent {
    uint type;
    uint reserved;
    ulong timestamp;
    SDL_WindowID windowID;
    int data1;
    int data2;
}

union SDL_Event {
    uint type;
    SDL_KeyboardEvent key;
    SDL_MouseMotionEvent motion;
    SDL_MouseButtonEvent button;
    SDL_MouseWheelEvent wheel;
    SDL_WindowEvent window;
    ubyte[128] padding;
}

// ---------------------------------------------------------------------------
// Window property names (Wayland / X11)
// ---------------------------------------------------------------------------
enum string SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER = "SDL.window.wayland.display";
enum string SDL_PROP_WINDOW_WAYLAND_SURFACE_POINTER = "SDL.window.wayland.surface";
enum string SDL_PROP_WINDOW_X11_DISPLAY_POINTER     = "SDL.window.x11.display";
enum string SDL_PROP_WINDOW_X11_WINDOW_NUMBER       = "SDL.window.x11.window";

// ---------------------------------------------------------------------------
// Functions
// ---------------------------------------------------------------------------

// Initialization
bool SDL_Init(uint flags);
void SDL_Quit();
const(char)* SDL_GetError();

// Window
SDL_Window* SDL_CreateWindow(const(char)* title, int w, int h, uint flags);
void SDL_DestroyWindow(SDL_Window* window);
SDL_PropertiesID SDL_GetWindowProperties(SDL_Window* window);
bool SDL_GetWindowSize(SDL_Window* window, int* w, int* h);
bool SDL_GetWindowSizeInPixels(SDL_Window* window, int* w, int* h);
void SDL_SetWindowTitle(SDL_Window* window, const(char)* title);

// Properties
void* SDL_GetPointerProperty(SDL_PropertiesID props, const(char)* name, void* default_value);
long SDL_GetNumberProperty(SDL_PropertiesID props, const(char)* name, long default_value);

// Mouse
bool SDL_SetWindowRelativeMouseMode(SDL_Window* window, bool enabled);
bool SDL_GetWindowRelativeMouseMode(SDL_Window* window);
bool SDL_HideCursor();
bool SDL_ShowCursor();
bool SDL_WarpMouseInWindow(SDL_Window* window, float x, float y);

// Events
bool SDL_PollEvent(SDL_Event* event);

// Timer
ulong SDL_GetPerformanceCounter();
ulong SDL_GetPerformanceFrequency();
ulong SDL_GetTicks();
void SDL_Delay(uint ms);

// ---------------------------------------------------------------------------
// Audio (SDL_audio.h)
// ---------------------------------------------------------------------------
alias SDL_AudioDeviceID = uint;
alias SDL_AudioStream   = void;

enum : SDL_AudioDeviceID {
    SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK  = 0xFFFF_FFFF,
    SDL_AUDIO_DEVICE_DEFAULT_RECORDING = 0xFFFF_FFFE,
}

/// SDL_AudioFormat values — masked ((signed<<15)|(float<<8)|(be<<12)|size_bits)
enum SDL_AudioFormat : uint {
    SDL_AUDIO_U8     = 0x0008,
    SDL_AUDIO_S8     = 0x8008,
    SDL_AUDIO_S16LE  = 0x8010,
    SDL_AUDIO_S32LE  = 0x8020,
    SDL_AUDIO_F32LE  = 0x8120,
}

struct SDL_AudioSpec {
    SDL_AudioFormat format;
    int channels;
    int freq;
}

// Loading / device / stream API
bool SDL_LoadWAV(const(char)* path, SDL_AudioSpec* spec, ubyte** audio_buf, uint* audio_len);
void* SDL_malloc(size_t size);
void SDL_free(void* mem);
SDL_AudioStream* SDL_OpenAudioDeviceStream(SDL_AudioDeviceID devid,
                                           const(SDL_AudioSpec)* spec,
                                           void* callback, void* userdata);
void SDL_DestroyAudioStream(SDL_AudioStream* stream);
bool SDL_PutAudioStreamData(SDL_AudioStream* stream, const(void)* buf, int len);
bool SDL_ResumeAudioStreamDevice(SDL_AudioStream* stream);
bool SDL_PauseAudioStreamDevice(SDL_AudioStream* stream);
bool SDL_ClearAudioStream(SDL_AudioStream* stream);
int  SDL_GetAudioStreamQueued(SDL_AudioStream* stream);
