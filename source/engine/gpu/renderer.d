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
    private GpuContext* ctx;
    private WGPUTexture  depthTexture;
    private WGPUTextureView depthView;
    private WGPUTexture  hdrTexture;
    private WGPUTextureView hdrView;
    private uint rtW, rtH;
    private PostProcessor post;
    private bool postOwned;

    @disable this(this);

    static Renderer create(return ref GpuContext gpuCtx) @trusted {
        Renderer r;
        r.ctx = &gpuCtx;
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
            depthTexture = wgpuDeviceCreateTexture(ctx.getDevice(), &desc);
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
            hdrTexture = wgpuDeviceCreateTexture(ctx.getDevice(), &desc);
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
        auto encoder = wgpuDeviceCreateCommandEncoder(ctx.getDevice(), &encDesc);

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
        wgpuSurfaceGetCurrentTexture(ctx.getSurface(), &surfTex);
        if (surfTex.status != WGPUSurfaceGetCurrentTextureStatus.successOptimal &&
            surfTex.status != WGPUSurfaceGetCurrentTextureStatus.successSuboptimal)
        {
            // Still finish encoder empty-ish — mark invalid
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

        WGPUCommandBufferDescriptor cbDesc;
        auto cmdBuf = wgpuCommandEncoderFinish(frame.encoder, &cbDesc);
        wgpuCommandEncoderRelease(frame.encoder);

        wgpuQueueSubmit(ctx.getQueue(), 1, &cmdBuf);
        wgpuCommandBufferRelease(cmdBuf);

        wgpuSurfacePresent(ctx.getSurface());

        if (frame.view !is null) wgpuTextureViewRelease(frame.view);
        if (frame.texture !is null) wgpuTextureRelease(frame.texture);

        frame = FrameContext.init;
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
