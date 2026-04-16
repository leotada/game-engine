/// GPU context — manages the WGPU instance→adapter→device→surface lifecycle.
/// Wayland-native surface creation for Linux.
module engine.gpu.context;

import bindings.wgpu;
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

    /// Initialize the full WGPU stack with a Wayland surface.
    static GpuContext create(void* wlDisplay, void* wlSurface, uint width, uint height,
                             WGPUPresentMode presentMode = WGPUPresentMode.fifo) @trusted {
        GpuContext ctx;

        // 1. Instance
        WGPUInstanceDescriptor instDesc;
        ctx.instance = wgpuCreateInstance(&instDesc);
        if (ctx.instance is null) {
            fatal("wgpuCreateInstance failed");
        }
        info("WGPU instance created");

        // 2. Surface (Wayland)
        WGPUSurfaceSourceWaylandSurface waylandSource;
        waylandSource.chain.sType = WGPUSType.surfaceSourceWaylandSurface;
        waylandSource.chain.next  = null;
        waylandSource.display     = wlDisplay;
        waylandSource.surface     = wlSurface;

        WGPUSurfaceDescriptor surfDesc;
        surfDesc.nextInChain = cast(WGPUChainedStruct*) &waylandSource;
        ctx.surface = wgpuInstanceCreateSurface(ctx.instance, &surfDesc);
        if (ctx.surface is null) {
            fatal("wgpuInstanceCreateSurface failed");
        }
        info("WGPU surface created");

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

        // 6. Configure surface
        ctx.surfaceFormat = WGPUTextureFormat.bgra8Unorm;
        ctx.presentModeVal = presentMode;
        ctx.surfW = width;
        ctx.surfH = height;
        ctx.configureSurface();

        info("GPU context fully initialized");
        return ctx;
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
