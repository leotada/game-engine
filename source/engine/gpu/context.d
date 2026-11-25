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
    private bool timestamps; /// device created with timestamp-query features (GPU profiler)

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
        version (WebAssembly) wgpuWebInstance = ctx.instance;
        info("WGPU instance created");

        // 2. Surface (Wayland / X11 fallback / Win32 / Android / Metal / WebGPU canvas)
        WGPUSurfaceSourceWaylandSurface waylandSource;
        WGPUSurfaceSourceXlibWindow x11Source;
        WGPUSurfaceSourceWindowsHWND win32Source;
        WGPUSurfaceSourceAndroidNativeWindow androidSource;
        WGPUSurfaceSourceMetalLayer metalSource;
        WGPUSurfaceSourceCanvasHTMLSelector webCanvasSource;
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
            case NativeSurfaceBackend.webCanvas:
                webCanvasSource.chain.sType = WGPUSType.surfaceSourceCanvasHTMLSelector;
                webCanvasSource.chain.next  = null;
                webCanvasSource.selector    = wgpuStringView(
                    surfInfo.canvasSelector !is null ? surfInfo.canvasSelector : "#canvas"
                );
                chainPtr = cast(WGPUChainedStruct*) &webCanvasSource;
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

        version (WebAssembly) {
            AsyncRequest!WGPUAdapter adapterReq;
            adapterCb.callback  = &onWebRequest!(WGPURequestAdapterStatus, WGPUAdapter);
            adapterCb.userdata1 = cast(void*) &adapterReq;
            wgpuInstanceRequestAdapter(ctx.instance, &adapterOpts, adapterCb);
            while (!adapterReq.done) {
                emscripten_sleep(1);
                wgpuInstanceProcessEvents(ctx.instance);
            }
            ctx.adapter = adapterReq.handle;
        } else {
            wgpuInstanceRequestAdapter(ctx.instance, &adapterOpts, adapterCb);
            wgpuInstanceProcessEvents(ctx.instance);
        }

        if (ctx.adapter is null) {
            fatal("Failed to obtain WGPU adapter");
        }
        info("WGPU adapter obtained");

        // 4. Device (request raised limits for OpenPBR layer maps & Clustered Forward compute)
        WGPULimits adapterLimits;
        adapterLimits.nextInChain = null;
        WGPULimits reqLimits;
        reqLimits.nextInChain = null;
        WGPUDeviceDescriptor devDesc;
        if (wgpuAdapterGetLimits(ctx.adapter, &adapterLimits) == WGPUStatus.success) {
            static uint clampLimit(uint adapterVal, uint desired) pure nothrow @nogc {
                if (adapterVal == 0 || adapterVal == WGPU_LIMIT_U32_UNDEFINED) return desired;
                return adapterVal >= desired ? desired : adapterVal;
            }
            reqLimits.maxSampledTexturesPerShaderStage = clampLimit(adapterLimits.maxSampledTexturesPerShaderStage, 32);
            reqLimits.maxStorageBuffersPerShaderStage  = clampLimit(adapterLimits.maxStorageBuffersPerShaderStage, 8);
            reqLimits.maxComputeWorkgroupStorageSize   = clampLimit(adapterLimits.maxComputeWorkgroupStorageSize, 16384);
            reqLimits.maxComputeInvocationsPerWorkgroup = clampLimit(adapterLimits.maxComputeInvocationsPerWorkgroup, 64);
            reqLimits.maxComputeWorkgroupsPerDimension = clampLimit(adapterLimits.maxComputeWorkgroupsPerDimension, 65_535);
            devDesc.requiredLimits = &reqLimits;
        }
        // Optional features: requested only when the adapter has them, so the device never fails to
        // open because of one. Query them with `hasFeature`.
        WGPUFeatureName[6] features;
        size_t featureCount = 0;
        foreach (f; [WGPUFeatureName.textureCompressionBC, WGPUFeatureName.indirectFirstInstance,
                   WGPUFeatureName.multiDrawIndirectCount])
            if (wgpuAdapterHasFeature(ctx.adapter, f) != 0) features[featureCount++] = f;

        // GPU timestamps for the profiler (engine.gpu.gpu_profiler): only when the adapter has
        // all three features; `ENGINE_NO_GPU_TIMESTAMPS=1` opts out (fallback testing).
        WGPUFeatureName[3] tsFeatures = [WGPUFeatureName.timestampQuery,
            WGPUFeatureName.timestampQueryInsideEncoders, WGPUFeatureName.timestampQueryInsidePasses];
        version (WebAssembly) {} else {
            import core.stdc.stdlib : getenv;
            const optOut = getenv("ENGINE_NO_GPU_TIMESTAMPS");
            bool all = optOut is null || optOut[0] == '0';
            foreach (f; tsFeatures)
                all = all && wgpuAdapterHasFeature(ctx.adapter, f) != 0;
            if (all)
                foreach (f; tsFeatures) features[featureCount++] = f;
        }
        if (featureCount > 0) {
            devDesc.requiredFeatureCount = featureCount;
            devDesc.requiredFeatures = cast(void*) features.ptr;
        }
        WGPURequestDeviceCallbackInfo devCb;
        devCb.mode      = WGPUCallbackMode.allowProcessEvents;
        devCb.callback  = &onDeviceReady;
        devCb.userdata1 = cast(void*) &ctx.device;

        version (WebAssembly) {
            AsyncRequest!WGPUDevice deviceReq;
            devCb.callback  = &onWebRequest!(WGPURequestDeviceStatus, WGPUDevice);
            devCb.userdata1 = cast(void*) &deviceReq;
            wgpuAdapterRequestDevice(ctx.adapter, &devDesc, devCb);
            while (!deviceReq.done) {
                emscripten_sleep(1);
                wgpuInstanceProcessEvents(ctx.instance);
            }
            ctx.device = deviceReq.handle;
        } else {
            wgpuAdapterRequestDevice(ctx.adapter, &devDesc, devCb);
            wgpuInstanceProcessEvents(ctx.instance);
        }

        if (ctx.device is null) {
            fatal("Failed to obtain WGPU device");
        }
        info("WGPU device obtained");
        version (WebAssembly) {} else {
            ctx.timestamps = wgpuDeviceHasFeature(ctx.device, WGPUFeatureName.timestampQuery) != 0
                && wgpuDeviceHasFeature(ctx.device, WGPUFeatureName.timestampQueryInsidePasses) != 0;
        }
        info("GPU timestamps: ", ctx.timestamps ? "available" : "unavailable");

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

        // Canvases only present with vsync.
        version (WebAssembly) chosenPresent = WGPUPresentMode.fifo;

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
        config.usage       = WGPUTextureUsage.renderAttachment | WGPUTextureUsage.copySrc; // copySrc: frame capture
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

    /// Reconfigure swapchain present mode at runtime (`fifo` = vsync, `immediate`/`mailbox` = uncapped).
    /// Returns false if the adapter surface does not support the requested mode.
    bool setPresentMode(WGPUPresentMode mode) @trusted {
        if (surface is null || adapter is null || device is null) return false;
        WGPUSurfaceCapabilities caps;
        if (wgpuSurfaceGetCapabilities(surface, adapter, &caps) != WGPUStatus.success) {
            return false;
        }
        scope(exit) wgpuSurfaceCapabilitiesFreeMembers(caps);

        bool supported = false;
        if (caps.presentModes !is null) {
            foreach (i; 0 .. caps.presentModeCount) {
                if (caps.presentModes[i] == mode) {
                    supported = true;
                    break;
                }
            }
        }
        if (!supported) {
            return false;
        }
        if (presentModeVal != mode) {
            presentModeVal = mode;
            configureSurface();
        }
        return true;
    }

    WGPUPresentMode presentMode() const nothrow @nogc { return presentModeVal; }

    WGPUDevice   getDevice()  nothrow @nogc { return device; }
    WGPUQueue    getQueue()   nothrow @nogc { return queue; }
    /// True when GPU timestamp queries (between and inside passes) are enabled on the device.
    bool timestampsSupported() const nothrow @nogc { return timestamps; }
    /// True when the device was opened with the optional feature `f`.
    bool hasFeature(WGPUFeatureName f) nothrow @nogc @trusted {
        return device !is null && wgpuDeviceHasFeature(device, f) != 0;
    }
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
version (WebAssembly) {
    /// Browser requests resolve after control returns to the event loop, with success or failure.
    private struct AsyncRequest(H) {
        H handle;
        bool done;
    }

    private extern (C) void onWebRequest(Status, H)(
        Status status, H handle, WGPUStringView message, void* userdata1, void* userdata2,
    ) nothrow @nogc @trusted {
        auto req = cast(AsyncRequest!H*) userdata1;
        if (status == Status.success) req.handle = handle;
        req.done = true;
    }
}

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
