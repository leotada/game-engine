/// High-level frame rendering — HDR offscreen scene + post + present.
module engine.gpu.renderer;

import bindings.wgpu;
import engine.gpu.context;
import engine.gpu.post : PostProcessor, PostSettings, SCENE_COLOR_FORMAT;
import engine.graphics.types : Color4;
import engine.core.log;

@safe:

struct Color {
    double r = 0, g = 0, b = 0, a = 1;
}

struct Renderer {
    private WGPUDevice   device;
    private WGPUQueue    queue;
    private WGPUSurface  surface;
    private WGPUTexture  depthTexture;
    private WGPUTextureView depthView;
    private WGPUTexture  hdrTexture;
    private WGPUTextureView hdrView;
    private uint rtW, rtH;
    private PostProcessor post;
    private bool postOwned;
    private WGPUTextureFormat surfaceFormat;
    // Frame capture (screenshots for verification): readback buffer filled during endFrame.
    private WGPUBuffer captureBuf;
    private uint captureStride, captureW, captureH;

    @disable this(this);

    static Renderer create(return ref GpuContext gpuCtx) @trusted {
        Renderer r;
        r.device = gpuCtx.getDevice();
        r.queue = gpuCtx.getQueue();
        r.surface = gpuCtx.getSurface();
        r.surfaceFormat = gpuCtx.getFormat();
        r.post = PostProcessor.create(gpuCtx, gpuCtx.getFormat());
        r.postOwned = true;
        r.createSceneTargets(gpuCtx.width(), gpuCtx.height());
        return r;
    }

    /// Mutable post-processing settings (exposure, bloom, FXAA, …).
    ref PostSettings postSettings() return nothrow @nogc {
        return post.settings;
    }

    /// Format used by Scene3D / Scene3DTextured / gizmos color targets.
    static WGPUTextureFormat sceneFormat() nothrow @nogc {
        return SCENE_COLOR_FORMAT;
    }

    /// Forward shader hot-reloading to the PostProcessor.
    bool reloadPostShader(scope const(char)[] shaderName, scope const(char)[] newWgsl) nothrow @nogc {
        return post.reloadShader(shaderName, newWgsl);
    }

    private void createSceneTargets(uint w, uint h) nothrow @nogc @trusted {
        releaseSceneTargets();
        rtW = w;
        rtH = h;

        // Depth
        {
            WGPUTextureDescriptor desc;
            desc.usage     = WGPUTextureUsage.renderAttachment;
            desc.dimension = WGPUTextureDimension.dim2D;
            desc.size      = WGPUExtent3D(w, h, 1);
            desc.format    = WGPUTextureFormat.depth24Plus;
            depthTexture = wgpuDeviceCreateTexture(device, &desc);
            WGPUTextureViewDescriptor viewDesc;
            viewDesc.format    = WGPUTextureFormat.depth24Plus;
            viewDesc.dimension = WGPUTextureViewDimension.dim2D;
            depthView = wgpuTextureCreateView(depthTexture, &viewDesc);
        }

        // HDR color
        {
            WGPUTextureDescriptor desc;
            desc.usage     = WGPUTextureUsage.renderAttachment | WGPUTextureUsage.textureBinding;
            desc.dimension = WGPUTextureDimension.dim2D;
            desc.size      = WGPUExtent3D(w, h, 1);
            desc.format    = SCENE_COLOR_FORMAT;
            hdrTexture = wgpuDeviceCreateTexture(device, &desc);
            if (hdrTexture is null) fatal("HDR scene texture creation failed");
            WGPUTextureViewDescriptor viewDesc;
            viewDesc.format    = SCENE_COLOR_FORMAT;
            viewDesc.dimension = WGPUTextureViewDimension.dim2D;
            hdrView = wgpuTextureCreateView(hdrTexture, &viewDesc);
        }

        post.resize(w, h);
    }

    private void releaseSceneTargets() nothrow @nogc @trusted {
        if (depthView !is null)    { wgpuTextureViewRelease(depthView); depthView = null; }
        if (depthTexture !is null) { wgpuTextureRelease(depthTexture); depthTexture = null; }
        if (hdrView !is null)      { wgpuTextureViewRelease(hdrView); hdrView = null; }
        if (hdrTexture !is null)   { wgpuTextureRelease(hdrTexture); hdrTexture = null; }
    }

    /// Begin a frame: clear the HDR offscreen target (no surface acquire yet).
    FrameContext beginFrame(Color clear) nothrow @nogc @trusted {
        return beginFrameImpl(clear.r, clear.g, clear.b, clear.a);
    }

    FrameContext beginFrame(Color4 clear) nothrow @nogc @trusted {
        return beginFrameImpl(clear.r, clear.g, clear.b, clear.a);
    }

    private FrameContext beginFrameImpl(double cr, double cg, double cb, double ca) nothrow @nogc @trusted {
        WGPUCommandEncoderDescriptor encDesc;
        auto encoder = wgpuDeviceCreateCommandEncoder(device, &encDesc);

        WGPURenderPassColorAttachment colorAtt;
        colorAtt.view       = hdrView;
        colorAtt.loadOp     = WGPULoadOp.clear;
        colorAtt.storeOp    = WGPUStoreOp.store;
        colorAtt.clearValue = WGPUColor(cr, cg, cb, ca);
        colorAtt.depthSlice = WGPU_DEPTH_SLICE_UNDEFINED;

        WGPURenderPassDescriptor passDesc;
        passDesc.colorAttachmentCount = 1;
        passDesc.colorAttachments     = &colorAtt;

        WGPURenderPassDepthStencilAttachment depthAtt;
        depthAtt.view            = depthView;
        depthAtt.depthLoadOp     = WGPULoadOp.clear;
        depthAtt.depthStoreOp    = WGPUStoreOp.store;
        depthAtt.depthClearValue = 1.0f;
        passDesc.depthStencilAttachment = &depthAtt;

        auto pass = wgpuCommandEncoderBeginRenderPass(encoder, &passDesc);

        FrameContext frame;
        frame.encoder = encoder;
        frame.pass = pass;
        frame.valid = true;
        frame.postResolved = false;
        return frame;
    }

    /// End the HDR scene pass, run bloom/tonemap/FXAA into the swapchain,
    /// then reopen `frame.pass` as a load-only present pass for UI/text.
    void resolvePost(ref FrameContext frame) nothrow @nogc @trusted {
        if (!frame.valid || frame.postResolved) return;

        wgpuRenderPassEncoderEnd(frame.pass);
        wgpuRenderPassEncoderRelease(frame.pass);
        frame.pass = null;

        // Acquire swapchain
        WGPUSurfaceTexture surfTex;
        wgpuSurfaceGetCurrentTexture(surface, &surfTex);
        frame.acquireStatus = surfTex.status;
        if (surfTex.status != WGPUSurfaceGetCurrentTextureStatus.successOptimal &&
            surfTex.status != WGPUSurfaceGetCurrentTextureStatus.successSuboptimal)
        {
            // Swapchain not available this frame (outdated / timeout / lost):
            // drop the recorded work instead of leaking the encoder + texture.
            if (surfTex.texture !is null) wgpuTextureRelease(surfTex.texture);
            wgpuCommandEncoderRelease(frame.encoder);
            frame.encoder = null;
            frame.valid = false;
            return;
        }

        WGPUTextureViewDescriptor viewDesc;
        auto surfView = wgpuTextureCreateView(surfTex.texture, &viewDesc);
        frame.texture = surfTex.texture;
        frame.view = surfView;

        post.execute(frame.encoder, hdrView, surfView);

        // Present pass for UI (no depth)
        WGPURenderPassColorAttachment colorAtt;
        colorAtt.view       = surfView;
        colorAtt.loadOp     = WGPULoadOp.load;
        colorAtt.storeOp    = WGPUStoreOp.store;
        colorAtt.clearValue = WGPUColor(0, 0, 0, 1);
        colorAtt.depthSlice = WGPU_DEPTH_SLICE_UNDEFINED;

        WGPURenderPassDescriptor passDesc;
        passDesc.colorAttachmentCount = 1;
        passDesc.colorAttachments     = &colorAtt;

        frame.pass = wgpuCommandEncoderBeginRenderPass(frame.encoder, &passDesc);
        frame.postResolved = true;
    }

    /// End the frame: ensure post ran, finish UI pass, submit, present.
    void endFrame(ref FrameContext frame) nothrow @nogc @trusted {
        if (!frame.valid) return;

        if (!frame.postResolved)
            resolvePost(frame);
        if (!frame.valid) return;

        wgpuRenderPassEncoderEnd(frame.pass);
        wgpuRenderPassEncoderRelease(frame.pass);

        if (captureBuf !is null && frame.texture !is null) encodeCapture(frame);

        WGPUCommandBufferDescriptor cbDesc;
        auto cmdBuf = wgpuCommandEncoderFinish(frame.encoder, &cbDesc);
        wgpuCommandEncoderRelease(frame.encoder);

        wgpuQueueSubmit(queue, 1, &cmdBuf);
        wgpuCommandBufferRelease(cmdBuf);

        wgpuSurfacePresent(surface);

        if (frame.view !is null) wgpuTextureViewRelease(frame.view);
        if (frame.texture !is null) wgpuTextureRelease(frame.texture);

        frame = FrameContext.init;
    }

    /// Asks for the next presented frame to be copied into a readback buffer. Fetch it with
    /// `readCapture` after `endFrame`. Not for the frame path (allocates a GPU buffer).
    void requestCapture() nothrow @nogc @trusted {
        if (captureBuf !is null) return;
        captureW = rtW;
        captureH = rtH;
        captureStride = (captureW * 4 + 255) & ~255u; // bytesPerRow must be a multiple of 256
        WGPUBufferDescriptor bd;
        bd.usage = WGPUBufferUsage.copyDst | WGPUBufferUsage.mapRead;
        bd.size = cast(ulong) captureStride * captureH;
        captureBuf = wgpuDeviceCreateBuffer(device, &bd);
    }

    private void encodeCapture(ref FrameContext frame) nothrow @nogc @trusted {
        WGPUImageCopyTexture src;
        src.texture = frame.texture;
        WGPUImageCopyBuffer dst;
        dst.buffer = captureBuf;
        dst.layout.bytesPerRow = captureStride;
        dst.layout.rowsPerImage = captureH;
        immutable size = WGPUExtent3D(captureW, captureH, 1);
        wgpuCommandEncoderCopyTextureToBuffer(frame.encoder, &src, &dst, &size);
    }

    /// Returns the captured frame as tightly packed RGBA8 (empty if none was requested or the
    /// format is not 8-bit BGRA/RGBA), then releases the readback buffer. Blocks until the GPU is done.
    ubyte[] readCapture(out uint width, out uint height) @trusted {
        if (captureBuf is null) return null;
        scope(exit) { wgpuBufferRelease(captureBuf); captureBuf = null; }
        static struct Wait { bool done; bool ok; }
        Wait w;
        static extern(C) void onMapped(WGPUMapAsyncStatus status, WGPUStringView, void* u1, void*) nothrow @nogc {
            auto p = cast(Wait*) u1;
            p.ok = status == WGPUMapAsyncStatus.success;
            p.done = true;
        }
        WGPUBufferMapCallbackInfo cb;
        cb.mode = WGPUCallbackMode.allowProcessEvents;
        cb.callback = &onMapped;
        cb.userdata1 = &w;
        wgpuBufferMapAsync(captureBuf, WGPUMapMode.read, 0, cast(size_t) captureStride * captureH, cb);
        foreach (_; 0 .. 1000) {
            wgpuDevicePoll(device, WGPU_TRUE, null);
            if (w.done) break;
        }
        if (!w.ok) { warn("frame capture: buffer map failed"); return null; }
        immutable bgra = surfaceFormat == WGPUTextureFormat.bgra8Unorm
                      || surfaceFormat == WGPUTextureFormat.bgra8UnormSrgb;
        immutable rgba = surfaceFormat == WGPUTextureFormat.rgba8Unorm
                      || surfaceFormat == WGPUTextureFormat.rgba8UnormSrgb;
        if (!bgra && !rgba) { warn("frame capture: unsupported surface format"); wgpuBufferUnmap(captureBuf); return null; }
        auto src = cast(const(ubyte)*) wgpuBufferGetConstMappedRange(captureBuf, 0, cast(size_t) captureStride * captureH);
        auto outPx = new ubyte[captureW * captureH * 4];
        foreach (y; 0 .. captureH) {
            foreach (x; 0 .. captureW) {
                const px = src + y * captureStride + x * 4;
                auto o = outPx.ptr + (y * captureW + x) * 4;
                o[0] = bgra ? px[2] : px[0];
                o[1] = px[1];
                o[2] = bgra ? px[0] : px[2];
                o[3] = 255;
            }
        }
        wgpuBufferUnmap(captureBuf);
        width = captureW;
        height = captureH;
        return outPx;
    }

    void resize(uint w, uint h) nothrow @nogc {
        createSceneTargets(w, h);
    }

    void destroy() nothrow @nogc {
        releaseSceneTargets();
        if (postOwned) {
            post.destroy();
            postOwned = false;
        }
    }
}

struct FrameContext {
    WGPUTexture            texture; // swapchain texture after resolvePost
    WGPUTextureView        view;    // swapchain view after resolvePost
    WGPUCommandEncoder     encoder;
    WGPURenderPassEncoder  pass;
    bool                   valid = false;
    bool                   postResolved = false;
    WGPUSurfaceGetCurrentTextureStatus acquireStatus;

    /// True when the swapchain wait failed and the surface should be reconfigured.
    bool acquireNeedsRecover() const nothrow @nogc pure {
        return acquireStatus == WGPUSurfaceGetCurrentTextureStatus.timeout
            || acquireStatus == WGPUSurfaceGetCurrentTextureStatus.outdated
            || acquireStatus == WGPUSurfaceGetCurrentTextureStatus.lost;
    }

    /// Restrict subsequent draws of the current pass to a pixel rectangle
    /// (viewport transform + scissor). Used to render a 3D scene into a UI panel.
    void setViewport(float x, float y, float w, float h, uint targetW, uint targetH) nothrow @nogc @trusted {
        if (w < 1 || h < 1) return;
        wgpuRenderPassEncoderSetViewport(pass, x, y, w, h, 0.0f, 1.0f);
        immutable uint sx = x < 0 ? 0 : cast(uint) x;
        immutable uint sy = y < 0 ? 0 : cast(uint) y;
        uint sw = cast(uint) w;
        uint sh = cast(uint) h;
        if (sx + sw > targetW) sw = targetW > sx ? targetW - sx : 1;
        if (sy + sh > targetH) sh = targetH > sy ? targetH - sy : 1;
        wgpuRenderPassEncoderSetScissorRect(pass, sx, sy, sw, sh);
    }

    void setPipeline(WGPURenderPipeline pipeline) nothrow @nogc @trusted {
        wgpuRenderPassEncoderSetPipeline(pass, pipeline);
    }

    void setBindGroup(uint group, WGPUBindGroup bg) nothrow @nogc @trusted {
        wgpuRenderPassEncoderSetBindGroup(pass, group, bg, 0, null);
    }

    void setVertexBuffer(uint slot, WGPUBuffer buf, ulong size, ulong offset = 0) nothrow @nogc @trusted {
        wgpuRenderPassEncoderSetVertexBuffer(pass, slot, buf, offset, size);
    }

    void setIndexBuffer(WGPUBuffer buf, WGPUIndexFormat fmt, ulong size, ulong offset = 0) nothrow @nogc @trusted {
        wgpuRenderPassEncoderSetIndexBuffer(pass, buf, fmt, offset, size);
    }

    void drawIndexed(uint indexCount, uint instanceCount) nothrow @nogc @trusted {
        wgpuRenderPassEncoderDrawIndexed(pass, indexCount, instanceCount, 0, 0, 0);
    }
}
