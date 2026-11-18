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
alias SDL_Joystick = void;
alias SDL_Gamepad = void;
alias SDL_JoystickID = uint;

// ---------------------------------------------------------------------------
// Init flags
// ---------------------------------------------------------------------------
enum : uint {
    SDL_INIT_AUDIO    = 0x0000_0010,
    SDL_INIT_VIDEO    = 0x0000_0020,
    SDL_INIT_JOYSTICK = 0x0000_0200,
    SDL_INIT_HAPTIC   = 0x0000_1000,
    SDL_INIT_GAMEPAD  = 0x0000_2000,
    SDL_INIT_EVENTS   = 0x0000_4000,
}

// ---------------------------------------------------------------------------
// Window flags
// ---------------------------------------------------------------------------
enum : ulong {
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
    SDL_EVENT_TERMINATING            = 0x101,
    SDL_EVENT_LOW_MEMORY             = 0x102,
    SDL_EVENT_WILL_ENTER_BACKGROUND  = 0x103,
    SDL_EVENT_DID_ENTER_BACKGROUND   = 0x104,
    SDL_EVENT_WILL_ENTER_FOREGROUND  = 0x105,
    SDL_EVENT_DID_ENTER_FOREGROUND   = 0x106,

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

    // Gamepad events (SDL_events.h)
    SDL_EVENT_GAMEPAD_AXIS_MOTION          = 0x650,
    SDL_EVENT_GAMEPAD_BUTTON_DOWN          = 0x651,
    SDL_EVENT_GAMEPAD_BUTTON_UP            = 0x652,
    SDL_EVENT_GAMEPAD_ADDED                = 0x653,
    SDL_EVENT_GAMEPAD_REMOVED              = 0x654,
    SDL_EVENT_GAMEPAD_REMAPPED             = 0x655,
    SDL_EVENT_GAMEPAD_TOUCHPAD_DOWN        = 0x656,
    SDL_EVENT_GAMEPAD_TOUCHPAD_MOTION      = 0x657,
    SDL_EVENT_GAMEPAD_TOUCHPAD_UP          = 0x658,
    SDL_EVENT_GAMEPAD_SENSOR_UPDATE        = 0x659,
    SDL_EVENT_GAMEPAD_UPDATE_COMPLETE      = 0x65A,
    SDL_EVENT_GAMEPAD_STEAM_HANDLE_UPDATED = 0x65B,

    // Drop events
    SDL_EVENT_DROP_FILE              = 0x1000,
    SDL_EVENT_DROP_TEXT              = 0x1001,
    SDL_EVENT_DROP_BEGIN             = 0x1002,
    SDL_EVENT_DROP_COMPLETE          = 0x1003,
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
    SCANCODE_MINUS  = 45,
    SCANCODE_EQUALS = 46,
    SCANCODE_COMMA  = 54,
    SCANCODE_PERIOD = 55,
    SCANCODE_SLASH  = 56,
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
    SCANCODE_HOME   = 74,
    SCANCODE_PAGEUP = 75,
    SCANCODE_DELETE = 76,
    SCANCODE_END    = 77,
    SCANCODE_PAGEDOWN = 78,
    SCANCODE_RIGHT  = 79,
    SCANCODE_LEFT   = 80,
    SCANCODE_DOWN   = 81,
    SCANCODE_UP     = 82,
    SCANCODE_KP_MINUS = 86,
    SCANCODE_KP_PLUS  = 87,
    SCANCODE_LCTRL  = 224,
    SCANCODE_LSHIFT = 225,
    SCANCODE_LALT   = 226,
    SCANCODE_RCTRL  = 228,
    SCANCODE_RSHIFT = 229,
    SCANCODE_RALT   = 230,
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

struct SDL_TextInputEvent {
    uint type;
    uint reserved;
    ulong timestamp;
    SDL_WindowID windowID;
    const(char)* text;
}

struct SDL_DropEvent {
    uint type;
    uint reserved;
    ulong timestamp;
    SDL_WindowID windowID;
    float x;
    float y;
    const(char)* source;
    const(char)* data;
}

struct SDL_GamepadAxisEvent {
    uint type;
    uint reserved;
    ulong timestamp;
    SDL_JoystickID which;
    ubyte axis;
    ubyte padding1;
    ubyte padding2;
    ubyte padding3;
    short value;
    ushort padding4;
}

struct SDL_GamepadButtonEvent {
    uint type;
    uint reserved;
    ulong timestamp;
    SDL_JoystickID which;
    ubyte button;
    bool down;
    ubyte padding1;
    ubyte padding2;
}

struct SDL_GamepadDeviceEvent {
    uint type;
    uint reserved;
    ulong timestamp;
    SDL_JoystickID which;
}

struct SDL_Rect {
    int x, y, w, h;
}

union SDL_Event {
    uint type;
    SDL_KeyboardEvent key;
    SDL_MouseMotionEvent motion;
    SDL_MouseButtonEvent button;
    SDL_MouseWheelEvent wheel;
    SDL_WindowEvent window;
    SDL_TextInputEvent text;
    SDL_GamepadDeviceEvent gdevice;
    SDL_GamepadAxisEvent gaxis;
    SDL_GamepadButtonEvent gbutton;
    SDL_DropEvent drop;
    ubyte[128] padding;
}

static assert(SDL_Event.sizeof == 128);

// ---------------------------------------------------------------------------
// Window property names (Wayland / X11)
// ---------------------------------------------------------------------------
enum string SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER = "SDL.window.wayland.display";
enum string SDL_PROP_WINDOW_WAYLAND_SURFACE_POINTER = "SDL.window.wayland.surface";
enum string SDL_PROP_WINDOW_X11_DISPLAY_POINTER     = "SDL.window.x11.display";
enum string SDL_PROP_WINDOW_X11_WINDOW_NUMBER       = "SDL.window.x11.window";
enum string SDL_PROP_WINDOW_WIN32_HWND_POINTER      = "SDL.window.win32.hwnd";
enum string SDL_PROP_WINDOW_WIN32_HINSTANCE_POINTER = "SDL.window.win32.hinstance";
enum string SDL_PROP_WINDOW_ANDROID_WINDOW_POINTER  = "SDL.window.android.window";

// ---------------------------------------------------------------------------
// Functions
// ---------------------------------------------------------------------------

// Initialization
bool SDL_Init(uint flags);
void SDL_Quit();
const(char)* SDL_GetError();

// Window
SDL_Window* SDL_CreateWindow(const(char)* title, int w, int h, ulong flags);
void SDL_DestroyWindow(SDL_Window* window);
SDL_PropertiesID SDL_GetWindowProperties(SDL_Window* window);
ulong SDL_GetWindowFlags(SDL_Window* window);
bool SDL_GetWindowSize(SDL_Window* window, int* w, int* h);
bool SDL_GetWindowSizeInPixels(SDL_Window* window, int* w, int* h);
void SDL_SetWindowTitle(SDL_Window* window, const(char)* title);
bool SDL_SetWindowFullscreen(SDL_Window* window, bool fullscreen);
bool SDL_SetWindowResizable(SDL_Window* window, bool resizable);
bool SDL_SetWindowBordered(SDL_Window* window, bool bordered);
bool SDL_SyncWindow(SDL_Window* window);
const(char)* SDL_GetCurrentVideoDriver();

// Surface, IOStream, PNG/BMP & SharedObject
alias SDL_SurfaceFlags = uint;
enum : SDL_SurfaceFlags {
    SDL_SURFACE_PREALLOCATED = 0x0000_0001u,
    SDL_SURFACE_LOCK_NEEDED  = 0x0000_0002u,
    SDL_SURFACE_LOCKED       = 0x0000_0004u,
    SDL_SURFACE_SIMD_ALIGNED = 0x0000_0008u,
}

enum SDL_PixelFormat : uint {
    SDL_PIXELFORMAT_UNKNOWN  = 0,
    SDL_PIXELFORMAT_INDEX8   = 0x1300_0801u,
    SDL_PIXELFORMAT_RGB24    = 0x1710_1803u,
    SDL_PIXELFORMAT_BGR24    = 0x1740_1803u,
    SDL_PIXELFORMAT_ARGB8888 = 0x1636_2004u,
    SDL_PIXELFORMAT_RGBA8888 = 0x1646_2004u,
    SDL_PIXELFORMAT_ABGR8888 = 0x1676_2004u,
    SDL_PIXELFORMAT_BGRA8888 = 0x1686_2004u,
}

version (BigEndian) {
    enum SDL_PixelFormat SDL_PIXELFORMAT_RGBA32 = SDL_PixelFormat.SDL_PIXELFORMAT_RGBA8888;
    enum SDL_PixelFormat SDL_PIXELFORMAT_ARGB32 = SDL_PixelFormat.SDL_PIXELFORMAT_ARGB8888;
    enum SDL_PixelFormat SDL_PIXELFORMAT_BGRA32 = SDL_PixelFormat.SDL_PIXELFORMAT_BGRA8888;
    enum SDL_PixelFormat SDL_PIXELFORMAT_ABGR32 = SDL_PixelFormat.SDL_PIXELFORMAT_ABGR8888;
} else {
    enum SDL_PixelFormat SDL_PIXELFORMAT_RGBA32 = SDL_PixelFormat.SDL_PIXELFORMAT_ABGR8888;
    enum SDL_PixelFormat SDL_PIXELFORMAT_ARGB32 = SDL_PixelFormat.SDL_PIXELFORMAT_BGRA8888;
    enum SDL_PixelFormat SDL_PIXELFORMAT_BGRA32 = SDL_PixelFormat.SDL_PIXELFORMAT_ARGB8888;
    enum SDL_PixelFormat SDL_PIXELFORMAT_ABGR32 = SDL_PixelFormat.SDL_PIXELFORMAT_RGBA8888;
}

struct SDL_Color {
    ubyte r;
    ubyte g;
    ubyte b;
    ubyte a;
}

struct SDL_Surface {
    SDL_SurfaceFlags flags;
    SDL_PixelFormat format;
    int w;
    int h;
    int pitch;
    void* pixels;
    int refcount;
    void* reserved;
}

static assert(size_t.sizeof == 8 ? SDL_Surface.sizeof == 48 : SDL_Surface.sizeof == 32);

alias SDL_IOStream = void;
SDL_IOStream* SDL_IOFromFile(const(char)* file, const(char)* mode);
SDL_IOStream* SDL_IOFromMem(void* mem, size_t size);
SDL_IOStream* SDL_IOFromConstMem(const(void)* mem, size_t size);
bool SDL_CloseIO(SDL_IOStream* context);

SDL_Surface* SDL_CreateSurface(int width, int height, SDL_PixelFormat format);
SDL_Surface* SDL_CreateSurfaceFrom(int width, int height, SDL_PixelFormat format, void* pixels, int pitch);
void SDL_DestroySurface(SDL_Surface* surface);
SDL_Surface* SDL_ConvertSurface(SDL_Surface* surface, SDL_PixelFormat format);
bool SDL_ConvertPixels(int width, int height, SDL_PixelFormat src_format, const(void)* src, int src_pitch,
                       SDL_PixelFormat dst_format, void* dst, int dst_pitch);
bool SDL_LockSurface(SDL_Surface* surface);
void SDL_UnlockSurface(SDL_Surface* surface);
SDL_Surface* SDL_LoadBMP(const(char)* file);
SDL_Surface* SDL_LoadBMP_IO(SDL_IOStream* src, bool closeio);
bool SDL_SaveBMP(SDL_Surface* surface, const(char)* file);
bool SDL_SaveBMP_IO(SDL_Surface* surface, SDL_IOStream* dst, bool closeio);
SDL_Surface* SDL_LoadPNG(const(char)* file);
SDL_Surface* SDL_LoadPNG_IO(SDL_IOStream* src, bool closeio);
bool SDL_SavePNG(SDL_Surface* surface, const(char)* file);
bool SDL_SavePNG_IO(SDL_Surface* surface, SDL_IOStream* dst, bool closeio);
SDL_Surface* SDL_LoadSurface(const(char)* file);
SDL_Surface* SDL_LoadSurface_IO(SDL_IOStream* src, bool closeio);
bool SDL_SetWindowIcon(SDL_Window* window, SDL_Surface* icon);

// Dynamic Shared Object Loading
alias SDL_SharedObject = void;
alias SDL_FunctionPointer = void*;
SDL_SharedObject* SDL_LoadObject(const(char)* sofile);
SDL_FunctionPointer SDL_LoadFunction(SDL_SharedObject* handle, const(char)* name);
void SDL_UnloadObject(SDL_SharedObject* handle);

// Metal
alias SDL_MetalView = void*;
SDL_MetalView SDL_Metal_CreateView(SDL_Window* window);
void SDL_Metal_DestroyView(SDL_MetalView view);
void* SDL_Metal_GetLayer(SDL_MetalView view);

// Properties
void* SDL_GetPointerProperty(SDL_PropertiesID props, const(char)* name, void* default_value);
long SDL_GetNumberProperty(SDL_PropertiesID props, const(char)* name, long default_value);

// Mouse & Cursor
alias SDL_Cursor = void;

enum SDL_SystemCursor : uint {
    SDL_SYSTEM_CURSOR_DEFAULT = 0,
    SDL_SYSTEM_CURSOR_TEXT,
    SDL_SYSTEM_CURSOR_WAIT,
    SDL_SYSTEM_CURSOR_CROSSHAIR,
    SDL_SYSTEM_CURSOR_PROGRESS,
    SDL_SYSTEM_CURSOR_NWSE_RESIZE,
    SDL_SYSTEM_CURSOR_NESW_RESIZE,
    SDL_SYSTEM_CURSOR_EW_RESIZE,
    SDL_SYSTEM_CURSOR_NS_RESIZE,
    SDL_SYSTEM_CURSOR_MOVE,
    SDL_SYSTEM_CURSOR_NOT_ALLOWED,
    SDL_SYSTEM_CURSOR_POINTER,
    SDL_SYSTEM_CURSOR_NW_RESIZE,
    SDL_SYSTEM_CURSOR_N_RESIZE,
    SDL_SYSTEM_CURSOR_NE_RESIZE,
    SDL_SYSTEM_CURSOR_E_RESIZE,
    SDL_SYSTEM_CURSOR_SE_RESIZE,
    SDL_SYSTEM_CURSOR_S_RESIZE,
    SDL_SYSTEM_CURSOR_SW_RESIZE,
    SDL_SYSTEM_CURSOR_W_RESIZE,
    SDL_SYSTEM_CURSOR_COUNT
}

bool SDL_SetWindowRelativeMouseMode(SDL_Window* window, bool enabled);
bool SDL_GetWindowRelativeMouseMode(SDL_Window* window);
bool SDL_HideCursor();
bool SDL_ShowCursor();
bool SDL_CursorVisible();
bool SDL_WarpMouseInWindow(SDL_Window* window, float x, float y);
SDL_Cursor* SDL_CreateSystemCursor(SDL_SystemCursor id);
SDL_Cursor* SDL_CreateColorCursor(SDL_Surface* surface, int hot_x, int hot_y);
bool SDL_SetCursor(SDL_Cursor* cursor);
void SDL_DestroyCursor(SDL_Cursor* cursor);

// Text input & Clipboard
bool SDL_StartTextInput(SDL_Window* window);
bool SDL_StopTextInput(SDL_Window* window);
bool SDL_SetTextInputArea(SDL_Window* window, const(SDL_Rect)* rect, int cursor);
const(char)* SDL_GetClipboardText();
bool SDL_SetClipboardText(const(char)* text);
bool SDL_HasClipboardText();
float SDL_GetWindowDisplayScale(SDL_Window* window);

// Events
bool SDL_PollEvent(SDL_Event* event);
bool SDL_SetHint(const(char)* name, const(char)* value);

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
alias SDL_AudioStreamCallback = extern(C) void function(
    void* userdata, SDL_AudioStream* stream, int additional_amount, int total_amount) nothrow @nogc;

bool SDL_LoadWAV(const(char)* path, SDL_AudioSpec* spec, ubyte** audio_buf, uint* audio_len);
void* SDL_malloc(size_t size);
void SDL_free(void* mem);
SDL_AudioStream* SDL_OpenAudioDeviceStream(SDL_AudioDeviceID devid,
                                           const(SDL_AudioSpec)* spec,
                                           SDL_AudioStreamCallback callback, void* userdata);
void SDL_DestroyAudioStream(SDL_AudioStream* stream);
bool SDL_PutAudioStreamData(SDL_AudioStream* stream, const(void)* buf, int len);
bool SDL_ResumeAudioStreamDevice(SDL_AudioStream* stream);
bool SDL_PauseAudioStreamDevice(SDL_AudioStream* stream);
bool SDL_ClearAudioStream(SDL_AudioStream* stream);
int  SDL_GetAudioStreamQueued(SDL_AudioStream* stream);
bool SDL_SetAudioStreamGain(SDL_AudioStream* stream, float gain);
float SDL_GetAudioStreamGain(SDL_AudioStream* stream);
bool SDL_LockAudioStream(SDL_AudioStream* stream);
bool SDL_UnlockAudioStream(SDL_AudioStream* stream);
bool SDL_ConvertAudioSamples(const(SDL_AudioSpec)* src_spec, const(ubyte)* src_data, int src_len,
                             const(SDL_AudioSpec)* dst_spec, ubyte** dst_data, int* dst_len);

// ---------------------------------------------------------------------------
// Subsystem control
// ---------------------------------------------------------------------------
bool SDL_InitSubSystem(uint flags);
void SDL_QuitSubSystem(uint flags);
uint SDL_WasInit(uint flags);

// ---------------------------------------------------------------------------
// Gamepad & Joystick (SDL_gamepad.h / SDL_joystick.h)
// ---------------------------------------------------------------------------
enum short SDL_JOYSTICK_AXIS_MAX = 32767;
enum short SDL_JOYSTICK_AXIS_MIN = -32768;

enum SDL_JoystickConnectionState : int {
    SDL_JOYSTICK_CONNECTION_INVALID  = -1,
    SDL_JOYSTICK_CONNECTION_UNKNOWN  = 0,
    SDL_JOYSTICK_CONNECTION_WIRED    = 1,
    SDL_JOYSTICK_CONNECTION_WIRELESS = 2,
}

enum SDL_GamepadType : int {
    SDL_GAMEPAD_TYPE_UNKNOWN = 0,
    SDL_GAMEPAD_TYPE_STANDARD,
    SDL_GAMEPAD_TYPE_XBOX360,
    SDL_GAMEPAD_TYPE_XBOXONE,
    SDL_GAMEPAD_TYPE_PS3,
    SDL_GAMEPAD_TYPE_PS4,
    SDL_GAMEPAD_TYPE_PS5,
    SDL_GAMEPAD_TYPE_NINTENDO_SWITCH_PRO,
    SDL_GAMEPAD_TYPE_NINTENDO_SWITCH_JOYCON_LEFT,
    SDL_GAMEPAD_TYPE_NINTENDO_SWITCH_JOYCON_RIGHT,
    SDL_GAMEPAD_TYPE_NINTENDO_SWITCH_JOYCON_PAIR,
    SDL_GAMEPAD_TYPE_GAMECUBE,
    SDL_GAMEPAD_TYPE_COUNT,
}

enum SDL_GamepadButton : int {
    SDL_GAMEPAD_BUTTON_INVALID = -1,
    SDL_GAMEPAD_BUTTON_SOUTH,
    SDL_GAMEPAD_BUTTON_EAST,
    SDL_GAMEPAD_BUTTON_WEST,
    SDL_GAMEPAD_BUTTON_NORTH,
    SDL_GAMEPAD_BUTTON_BACK,
    SDL_GAMEPAD_BUTTON_GUIDE,
    SDL_GAMEPAD_BUTTON_START,
    SDL_GAMEPAD_BUTTON_LEFT_STICK,
    SDL_GAMEPAD_BUTTON_RIGHT_STICK,
    SDL_GAMEPAD_BUTTON_LEFT_SHOULDER,
    SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER,
    SDL_GAMEPAD_BUTTON_DPAD_UP,
    SDL_GAMEPAD_BUTTON_DPAD_DOWN,
    SDL_GAMEPAD_BUTTON_DPAD_LEFT,
    SDL_GAMEPAD_BUTTON_DPAD_RIGHT,
    SDL_GAMEPAD_BUTTON_MISC1,
    SDL_GAMEPAD_BUTTON_RIGHT_PADDLE1,
    SDL_GAMEPAD_BUTTON_LEFT_PADDLE1,
    SDL_GAMEPAD_BUTTON_RIGHT_PADDLE2,
    SDL_GAMEPAD_BUTTON_LEFT_PADDLE2,
    SDL_GAMEPAD_BUTTON_TOUCHPAD,
    SDL_GAMEPAD_BUTTON_MISC2,
    SDL_GAMEPAD_BUTTON_MISC3,
    SDL_GAMEPAD_BUTTON_MISC4,
    SDL_GAMEPAD_BUTTON_MISC5,
    SDL_GAMEPAD_BUTTON_MISC6,
    SDL_GAMEPAD_BUTTON_COUNT,
}

enum SDL_GamepadAxis : int {
    SDL_GAMEPAD_AXIS_INVALID = -1,
    SDL_GAMEPAD_AXIS_LEFTX,
    SDL_GAMEPAD_AXIS_LEFTY,
    SDL_GAMEPAD_AXIS_RIGHTX,
    SDL_GAMEPAD_AXIS_RIGHTY,
    SDL_GAMEPAD_AXIS_LEFT_TRIGGER,
    SDL_GAMEPAD_AXIS_RIGHT_TRIGGER,
    SDL_GAMEPAD_AXIS_COUNT,
}

bool SDL_HasGamepad();
SDL_JoystickID* SDL_GetGamepads(int* count);
bool SDL_IsGamepad(SDL_JoystickID instance_id);
SDL_Gamepad* SDL_OpenGamepad(SDL_JoystickID instance_id);
void SDL_CloseGamepad(SDL_Gamepad* gamepad);
SDL_Gamepad* SDL_GetGamepadFromID(SDL_JoystickID instance_id);
SDL_Gamepad* SDL_GetGamepadFromPlayerIndex(int player_index);
SDL_JoystickID SDL_GetGamepadID(SDL_Gamepad* gamepad);
const(char)* SDL_GetGamepadName(SDL_Gamepad* gamepad);
const(char)* SDL_GetGamepadNameForID(SDL_JoystickID instance_id);
SDL_GamepadType SDL_GetGamepadType(SDL_Gamepad* gamepad);
SDL_GamepadType SDL_GetRealGamepadType(SDL_Gamepad* gamepad);
int SDL_GetGamepadPlayerIndex(SDL_Gamepad* gamepad);
bool SDL_SetGamepadPlayerIndex(SDL_Gamepad* gamepad, int player_index);
ushort SDL_GetGamepadVendor(SDL_Gamepad* gamepad);
ushort SDL_GetGamepadProduct(SDL_Gamepad* gamepad);
bool SDL_GamepadConnected(SDL_Gamepad* gamepad);
bool SDL_GamepadHasAxis(SDL_Gamepad* gamepad, SDL_GamepadAxis axis);
short SDL_GetGamepadAxis(SDL_Gamepad* gamepad, SDL_GamepadAxis axis);
bool SDL_GamepadHasButton(SDL_Gamepad* gamepad, SDL_GamepadButton button);
bool SDL_GetGamepadButton(SDL_Gamepad* gamepad, SDL_GamepadButton button);
bool SDL_RumbleGamepad(SDL_Gamepad* gamepad, ushort low_frequency_rumble, ushort high_frequency_rumble, uint duration_ms);
bool SDL_RumbleGamepadTriggers(SDL_Gamepad* gamepad, ushort left_rumble, ushort right_rumble, uint duration_ms);
void SDL_UpdateGamepads();
