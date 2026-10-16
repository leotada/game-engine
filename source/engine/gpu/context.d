/// GPU context — manages the WGPU instance→adapter→device→surface lifecycle.
/// Wayland-native surface creation for Linux.
module engine.gpu.context;

import bindings.wgpu;
import engine.platform.window : NativeSurfaceInfo, NativeSurfaceBackend;
import engine.core.log;

@safe:

struct GpuContext {
    private WGPUInstance  instance;
    private WGPUAdapter   adapter;
    private WGPUDevice    device;
    private WGPUQueue     queue;
    private WGPUSurface   surface;
    private WGPUTextureFormat surfaceFormat;
    private WGPUPresentMode presentModeVal;
    private uint surfW, surfH;

    @disable this(this);

    /// Initialize the full WGPU stack with a multiplatform native surface.
    static void create(ref GpuContext ctx, NativeSurfaceInfo surfInfo,
                       uint width, uint height,
                       WGPUPresentMode presentMode = WGPUPresentMode.fifo) @trusted {

        // 1. Instance
        WGPUInstanceDescriptor instDesc;
        ctx.instance = wgpuCreateInstance(&instDesc);
        if (ctx.instance is null) {
            fatal("wgpuCreateInstance failed");
        }
        info("WGPU instance created");

        // 2. Surface (Wayland / X11 fallback / Win32 / Android / Metal)
        WGPUSurfaceSourceWaylandSurface waylandSource;
        WGPUSurfaceSourceXlibWindow x11Source;
        WGPUSurfaceSourceWindowsHWND win32Source;
        WGPUSurfaceSourceAndroidNativeWindow androidSource;
        WGPUSurfaceSourceMetalLayer metalSource;
        WGPUChainedStruct* chainPtr = null;

        final switch (surfInfo.backend) {
            case NativeSurfaceBackend.wayland:
                waylandSource.chain.sType = WGPUSType.surfaceSourceWaylandSurface;
                waylandSource.chain.next  = null;
                waylandSource.display     = surfInfo.displayOrInstance;
                waylandSource.surface     = surfInfo.windowOrSurface;
                chainPtr = cast(WGPUChainedStruct*) &waylandSource;
                break;
            case NativeSurfaceBackend.x11:
                x11Source.chain.sType = WGPUSType.surfaceSourceXlibWindow;
                x11Source.chain.next  = null;
                x11Source.display     = surfInfo.displayOrInstance;
                x11Source.window      = surfInfo.x11Window;
                chainPtr = cast(WGPUChainedStruct*) &x11Source;
                break;
            case NativeSurfaceBackend.win32:
                win32Source.chain.sType = WGPUSType.surfaceSourceWindowsHWND;
                win32Source.chain.next  = null;
                win32Source.hinstance   = surfInfo.displayOrInstance;
                win32Source.hwnd        = surfInfo.windowOrSurface;
                chainPtr = cast(WGPUChainedStruct*) &win32Source;
                break;
            case NativeSurfaceBackend.android:
                androidSource.chain.sType = WGPUSType.surfaceSourceAndroidNativeWindow;
                androidSource.chain.next  = null;
                androidSource.window      = surfInfo.windowOrSurface;
                chainPtr = cast(WGPUChainedStruct*) &androidSource;
                break;
            case NativeSurfaceBackend.metal:
                metalSource.chain.sType = WGPUSType.surfaceSourceMetalLayer;
                metalSource.chain.next  = null;
                metalSource.layer       = surfInfo.windowOrSurface;
                chainPtr = cast(WGPUChainedStruct*) &metalSource;
                break;
            case NativeSurfaceBackend.none:
                fatal("Cannot create WGPU surface: no native surface provided");
                break;
        }

        WGPUSurfaceDescriptor surfDesc;
        surfDesc.nextInChain = chainPtr;
        ctx.surface = wgpuInstanceCreateSurface(ctx.instance, &surfDesc);
        if (ctx.surface is null) {
            fatal("wgpuInstanceCreateSurface failed");
        }
        info("WGPU surface created (backend=", cast(int) surfInfo.backend, ")");

        // 3. Adapter (synchronous via processEvents)
        WGPURequestAdapterOptions adapterOpts;
        adapterOpts.compatibleSurface  = ctx.surface;
        adapterOpts.powerPreference    = WGPUPowerPreference.highPerformance;

        WGPURequestAdapterCallbackInfo adapterCb;
        adapterCb.mode      = WGPUCallbackMode.allowProcessEvents;
        adapterCb.callback  = &onAdapterReady;
        adapterCb.userdata1 = cast(void*) &ctx.adapter;

        wgpuInstanceRequestAdapter(ctx.instance, &adapterOpts, adapterCb);
        wgpuInstanceProcessEvents(ctx.instance);

        if (ctx.adapter is null) {
            fatal("Failed to obtain WGPU adapter");
        }
        info("WGPU adapter obtained");

        // 4. Device
        WGPUDeviceDescriptor devDesc;
        WGPURequestDeviceCallbackInfo devCb;
        devCb.mode      = WGPUCallbackMode.allowProcessEvents;
        devCb.callback  = &onDeviceReady;
        devCb.userdata1 = cast(void*) &ctx.device;

        wgpuAdapterRequestDevice(ctx.adapter, &devDesc, devCb);
        wgpuInstanceProcessEvents(ctx.instance);

        if (ctx.device is null) {
            fatal("Failed to obtain WGPU device");
        }
        info("WGPU device obtained");

        // 5. Queue
        ctx.queue = wgpuDeviceGetQueue(ctx.device);

        // 6. Negotiate surface format and present mode dynamically
        WGPUTextureFormat chosenFormat = WGPUTextureFormat.bgra8Unorm;
        WGPUPresentMode chosenPresent = presentMode;

        WGPUSurfaceCapabilities caps;
        if (wgpuSurfaceGetCapabilities(ctx.surface, ctx.adapter, &caps) == WGPUStatus.success) {
            scope (exit) wgpuSurfaceCapabilitiesFreeMembers(caps);

            bool hasBgra = false;
            bool hasRgba = false;
            foreach (i; 0 .. caps.formatCount) {
                if (caps.formats[i] == WGPUTextureFormat.bgra8Unorm) hasBgra = true;
                if (caps.formats[i] == WGPUTextureFormat.rgba8Unorm) hasRgba = true;
            }

            if (hasBgra) {
                chosenFormat = WGPUTextureFormat.bgra8Unorm;
            } else if (hasRgba) {
                chosenFormat = WGPUTextureFormat.rgba8Unorm;
            } else if (caps.formatCount > 0) {
                chosenFormat = caps.formats[0];
            }

            bool presentSupported = false;
            foreach (i; 0 .. caps.presentModeCount) {
                if (caps.presentModes[i] == presentMode) {
                    presentSupported = true;
                    break;
                }
            }
            if (!presentSupported && caps.presentModeCount > 0) {
                chosenPresent = WGPUPresentMode.fifo;
            }
        }

        ctx.surfaceFormat = chosenFormat;
        ctx.presentModeVal = chosenPresent;
        ctx.surfW = width;
        ctx.surfH = height;
        ctx.configureSurface();

        info("GPU context fully initialized (format=", cast(uint) ctx.surfaceFormat, ")");
    }

    /// Legacy overload for Wayland display + surface pointers.
    static void create(ref GpuContext ctx, void* wlDisplay, void* wlSurface,
                       uint width, uint height,
                       WGPUPresentMode presentMode = WGPUPresentMode.fifo) @trusted {
        import engine.platform.window : NativeSurfaceInfo, NativeSurfaceBackend;
        NativeSurfaceInfo info;
        info.backend = NativeSurfaceBackend.wayland;
        info.displayOrInstance = wlDisplay;
        info.windowOrSurface   = wlSurface;
        create(ctx, info, width, height, presentMode);
    }

    private void configureSurface() @trusted {
        WGPUSurfaceConfiguration config;
        config.device      = device;
        config.format      = surfaceFormat;
        config.usage       = WGPUTextureUsage.renderAttachment;
        config.width       = surfW;
        config.height      = surfH;
        config.presentMode = presentModeVal;
        config.alphaMode   = WGPUCompositeAlphaMode.opaque;
        wgpuSurfaceConfigure(surface, &config);
    }

    void resize(uint w, uint h) @trusted {
        surfW = w;
        surfH = h;
        configureSurface();
    }

    WGPUDevice   getDevice()  nothrow @nogc { return device; }
    WGPUQueue    getQueue()   nothrow @nogc { return queue; }
    WGPUSurface  getSurface() nothrow @nogc { return surface; }
    WGPUTextureFormat getFormat() const nothrow @nogc { return surfaceFormat; }
    uint width()  const nothrow @nogc { return surfW; }
    uint height() const nothrow @nogc { return surfH; }

    void destroy() @trusted {
        if (instance is null && device is null) return;
        if (surface !is null)  { wgpuSurfaceUnconfigure(surface); wgpuSurfaceRelease(surface); surface = null; }
        if (queue !is null)    { wgpuQueueRelease(queue); queue = null; }
        if (device !is null)   { wgpuDeviceDestroy(device); wgpuDeviceRelease(device); device = null; }
        if (adapter !is null)  { wgpuAdapterRelease(adapter); adapter = null; }
        if (instance !is null) { wgpuInstanceRelease(instance); instance = null; }
        info("GPU context destroyed");
    }

    ~this() @trusted { destroy(); }
}

// ---------------------------------------------------------------------------
// Callbacks (extern(C) for WGPU)
// ---------------------------------------------------------------------------
private extern(C) void onAdapterReady(
    WGPURequestAdapterStatus status,
    WGPUAdapter adapter,
    WGPUStringView message,
    void* userdata1,
    void* userdata2,
) nothrow @nogc @trusted {
    if (status == WGPURequestAdapterStatus.success) {
        *cast(WGPUAdapter*) userdata1 = adapter;
    }
}

private extern(C) void onDeviceReady(
    WGPURequestDeviceStatus status,
    WGPUDevice device,
    WGPUStringView message,
    void* userdata1,
    void* userdata2,
) nothrow @nogc @trusted {
    if (status == WGPURequestDeviceStatus.success) {
        *cast(WGPUDevice*) userdata1 = device;
    }
}
