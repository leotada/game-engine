/// High-level frame rendering — beginFrame/endFrame with clear color.
module engine.gpu.renderer;

import bindings.wgpu;
import engine.gpu.context;
import engine.core.log;

@safe:

struct Color {
    double r = 0, g = 0, b = 0, a = 1;
}

struct Renderer {
    private GpuContext* ctx;
    private WGPUTexture  depthTexture;
    private WGPUTextureView depthView;

    @disable this(this);

    static Renderer create(return ref GpuContext gpuCtx) @trusted {
        Renderer r;
        r.ctx = &gpuCtx;
        r.createDepthBuffer(gpuCtx.width(), gpuCtx.height());
        return r;
    }

    private void createDepthBuffer(uint w, uint h) nothrow @nogc @trusted {
        releaseDepthBuffer();

        WGPUTextureDescriptor desc;
        desc.usage     = WGPUTextureUsage.renderAttachment;
        desc.dimension = WGPUTextureDimension.dim2D;
        desc.size      = WGPUExtent3D(w, h, 1);
        desc.format    = WGPUTextureFormat.depth24Plus;

        depthTexture = wgpuDeviceCreateTexture(ctx.getDevice(), &desc);

        WGPUTextureViewDescriptor viewDesc;
        viewDesc.format    = WGPUTextureFormat.depth24Plus;
        viewDesc.dimension = WGPUTextureViewDimension.dim2D;
        depthView = wgpuTextureCreateView(depthTexture, &viewDesc);
    }

    private void releaseDepthBuffer() nothrow @nogc @trusted {
        if (depthView !is null)    { wgpuTextureViewRelease(depthView); depthView = null; }
        if (depthTexture !is null) { wgpuTextureRelease(depthTexture); depthTexture = null; }
    }

    /// Begin a frame: acquire surface texture, clear with given color,
    /// return the render pass encoder for additional draw commands.
    /// Returns null on surface error (skip frame).
    FrameContext beginFrame(Color clear) nothrow @nogc @trusted {
        // 1. Get current surface texture
        WGPUSurfaceTexture surfTex;
        wgpuSurfaceGetCurrentTexture(ctx.getSurface(), &surfTex);

        if (surfTex.status != WGPUSurfaceGetCurrentTextureStatus.successOptimal &&
            surfTex.status != WGPUSurfaceGetCurrentTextureStatus.successSuboptimal)
        {
            return FrameContext.init; // skip frame
        }

        // 2. Create texture view
        WGPUTextureViewDescriptor viewDesc;
        auto view = wgpuTextureCreateView(surfTex.texture, &viewDesc);

        // 3. Command encoder
        WGPUCommandEncoderDescriptor encDesc;
        auto encoder = wgpuDeviceCreateCommandEncoder(ctx.getDevice(), &encDesc);

        // 4. Render pass
        WGPURenderPassColorAttachment colorAtt;
        colorAtt.view       = view;
        colorAtt.loadOp     = WGPULoadOp.clear;
        colorAtt.storeOp    = WGPUStoreOp.store;
        colorAtt.clearValue = WGPUColor(clear.r, clear.g, clear.b, clear.a);
        colorAtt.depthSlice = WGPU_DEPTH_SLICE_UNDEFINED;

        WGPURenderPassDescriptor passDesc;
        passDesc.colorAttachmentCount = 1;
        passDesc.colorAttachments     = &colorAtt;

        WGPURenderPassDepthStencilAttachment depthAtt;
        depthAtt.view           = depthView;
        depthAtt.depthLoadOp    = WGPULoadOp.clear;
        depthAtt.depthStoreOp   = WGPUStoreOp.store;
        depthAtt.depthClearValue = 1.0f;
        passDesc.depthStencilAttachment = &depthAtt;

        auto pass = wgpuCommandEncoderBeginRenderPass(encoder, &passDesc);

        return FrameContext(surfTex.texture, view, encoder, pass, true);
    }

    /// End the frame: finish render pass, submit command buffer, present.
    void endFrame(ref FrameContext frame) nothrow @nogc @trusted {
        if (!frame.valid) return;

        wgpuRenderPassEncoderEnd(frame.pass);
        wgpuRenderPassEncoderRelease(frame.pass);

        WGPUCommandBufferDescriptor cbDesc;
        auto cmdBuf = wgpuCommandEncoderFinish(frame.encoder, &cbDesc);
        wgpuCommandEncoderRelease(frame.encoder);

        wgpuQueueSubmit(ctx.getQueue(), 1, &cmdBuf);
        wgpuCommandBufferRelease(cmdBuf);

        wgpuSurfacePresent(ctx.getSurface());

        wgpuTextureViewRelease(frame.view);
        wgpuTextureRelease(frame.texture);

        frame = FrameContext.init;
    }

    void resize(uint w, uint h) nothrow @nogc {
        createDepthBuffer(w, h);
    }

    void destroy() nothrow @nogc {
        releaseDepthBuffer();
    }
}

struct FrameContext {
    WGPUTexture            texture;
    WGPUTextureView        view;
    WGPUCommandEncoder     encoder;
    WGPURenderPassEncoder  pass;
    bool                   valid = false;
}
