/// High-level frame rendering — HDR offscreen scene + post + present.
module engine.gpu.renderer;

import bindings.wgpu;
import engine.gpu.context;
import engine.gpu.gtao : AoSettings, GtaoPass;
import engine.scene.camera : Camera;
import engine.gpu.post : PostPassDesc, PostProcessor, PostSceneCamera, PostSettings, PostStage, SCENE_COLOR_FORMAT;
import engine.gpu.shader : createShaderModule;
import engine.gpu.shaders : depthCopyShaderSource, bloomDownsampleShaderSource;
import engine.graphics.texture : mipCount;
import engine.graphics.types : Color4;
import engine.core.log;
import engine.devtools.profiler : profileZone;
import engine.gpu.gpu_profiler;

@safe:

struct Color {
    double r = 0, g = 0, b = 0, a = 1;
}

/// What `Renderer.snapshotOpaque` copies.
enum SnapshotParts : uint {
    none  = 0,
    /// HDR color, level 0 (water refraction / reflections).
    color = 1,
    /// Downsampled color pyramid, levels 1+ (rough SSR, rough transmission). Requires `color`.
    mips  = 2 | color,
    /// Resolved depth (decals, water, SSR ray marching).
    depth = 4,
    /// Level-0 color and depth, no pyramid (water).
    colorAndDepth = color | depth,
    all   = color | mips | depth,
}
private enum uint SNAPSHOT_MIPS_BIT = 2;

struct Renderer {
    private WGPUDevice   device;
    private WGPUQueue    queue;
    private uint uiGpuScope = NO_GPU_SCOPE; /// GPU profiler scope over the UI pass
    private WGPUSurface  surface;
    private WGPUTexture  depthTexture;
    private WGPUTextureView depthView;
    private WGPUTexture  hdrTexture;
    private WGPUTextureView hdrView;
    private uint rtW, rtH;
    private PostProcessor post;
    private GtaoPass gtao;
    private AoSettings aoSettings;
    private bool postOwned;
    private WGPUTextureFormat surfaceFormat;
    // Frame capture (screenshots for verification): readback buffer filled during endFrame.
    private WGPUBuffer captureBuf;
    private uint captureStride, captureW, captureH;
    private bool captureFilled; // the copy was recorded: the buffer holds (or will hold) a frame
    // Lazy opt-in opaque snapshot (HDR color pyramid + depth32Float resolve for water/transmission).
    private enum uint OPAQUE_COLOR_MIPS = 5;
    private bool snapshotActive = false;
    private uint opaqueMipCount = 0;
    private WGPUTexture        opaqueColorTex;
    private WGPUTextureView    opaqueColorView_;
    private WGPUTextureView[OPAQUE_COLOR_MIPS] opaqueMipViews;
    private WGPUBindGroup[OPAQUE_COLOR_MIPS]   opaqueDownBG;
    private WGPUSampler        opaqueDownSampler;
    private WGPUShaderModule   opaqueDownSM;
    private WGPUBindGroupLayout opaqueDownBGL;
    private WGPUPipelineLayout opaqueDownPL;
    private WGPURenderPipeline opaqueDownPipe;
    private WGPUTexture        opaqueDepthTex;
    private WGPUTextureView    opaqueDepthView_;
    private WGPUShaderModule   depthCopySM;
    private WGPUBindGroupLayout depthCopyBGL;
    private WGPUPipelineLayout depthCopyPL;
    private WGPURenderPipeline depthCopyPipe;
    private WGPUBindGroup      depthCopyBG;

    @disable this(this);

    static Renderer create(return ref GpuContext gpuCtx) @trusted {
        Renderer r;
        r.device = gpuCtx.getDevice();
        r.queue = gpuCtx.getQueue();
        r.surface = gpuCtx.getSurface();
        r.surfaceFormat = gpuCtx.getFormat();
        r.post = PostProcessor.create(gpuCtx, gpuCtx.getFormat());
        r.postOwned = true;
        r.gtao.setup(r.device, r.queue);
        r.createSceneTargets(gpuCtx.width(), gpuCtx.height());
        gpuProfilerInit(r.device, r.queue, gpuCtx.timestampsSupported());
        return r;
    }

    /// Mutable post-processing settings (exposure, bloom, FXAA, …).
    ref PostSettings postSettings() return nothrow @nogc {
        return post.settings;
    }

    /// Ambient occlusion of opaque surfaces (off by default).
    ref AoSettings ambientOcclusion() return nothrow @nogc { return aoSettings; }

    package(engine) bool aoAvailable() const nothrow @nogc {
        return aoSettings.enabled && aoSettings.intensity > 0 && gtao.available;
    }

    /// Composite GTAO into the scene color (called after the opaque draws).
    package(engine) void applyAmbientOcclusion(ref FrameContext frame, ref const Camera cam, float[4] viewport)
    nothrow @nogc {
        if (!frame.valid || frame.postResolved) return;
        frame.suspendScenePass();
        gtao.run(frame.encoder, hdrView, depthView, rtW, rtH, viewport, aoSettings, cam);
        frame.resumeScenePass();
    }

    /// Format used by Scene3D / Scene3DTextured / gizmos color targets.
    static WGPUTextureFormat sceneFormat() nothrow @nogc {
        return SCENE_COLOR_FORMAT;
    }

    /// Forward shader hot-reloading to the PostProcessor.
    bool reloadPostShader(scope const(char)[] shaderName, scope const(char)[] newWgsl) nothrow @nogc {
        return post.reloadShader(shaderName, newWgsl);
    }

    /// Add a custom fullscreen post-processing pass at `stage`.
    /// Returns a 1-based pass id (0 on compile failure).
    uint addPostPass(scope const(char)[] wgsl, size_t uniformBytes = 64,
                     PostStage stage = PostStage.afterTonemap) {
        return post.addPass(wgsl, uniformBytes, stage);
    }

    /// Add a pass that can read scene depth, the camera and named intermediate
    /// targets, or write one at reduced resolution. See `PostPassDesc`.
    uint addPostPass(scope const ref PostPassDesc desc) { return post.addPass(desc); }

    /// True when a post pass reads the scene inputs this frame.
    package(engine) bool needsSceneCamera() const nothrow @nogc { return post.anySceneInputs(); }

    /// Camera of this frame's 3D scene (set by `Scene3DTextured.end`; the last scene wins).
    package(engine) void setSceneCamera(ref const PostSceneCamera c) nothrow @nogc { post.setSceneCamera(c); }

    void updatePostPassParams(uint id, scope const(void)[] data) nothrow @nogc {
        post.updatePassParams(id, data);
    }

    void updatePostPassParams(T)(uint id, ref const T data) nothrow @nogc @trusted {
        post.updatePassParams(id, (cast(const(void)*) &data)[0 .. T.sizeof]);
    }

    void setPostPassEnabled(uint id, bool enabled) nothrow @nogc {
        post.setPassEnabled(id, enabled);
    }

    bool reloadPostPass(uint id, scope const(char)[] wgsl) {
        return post.reloadPass(id, wgsl);
    }

    void removePostPass(uint id) nothrow @nogc {
        post.removePass(id);
    }

    private void createSceneTargets(uint w, uint h) nothrow @nogc @trusted {
        releaseSceneTargets();
        rtW = w;
        rtH = h;

        // Depth
        {
            WGPUTextureDescriptor desc;
            desc.usage     = WGPUTextureUsage.renderAttachment | WGPUTextureUsage.textureBinding;
            desc.dimension = WGPUTextureDimension.dim2D;
            desc.size      = WGPUExtent3D(w, h, 1);
            desc.format    = WGPUTextureFormat.depth24Plus;
            depthTexture = wgpuDeviceCreateTexture(device, &desc);
            WGPUTextureViewDescriptor viewDesc;
            viewDesc.format    = WGPUTextureFormat.depth24Plus;
            viewDesc.dimension = WGPUTextureViewDimension.dim2D;
            viewDesc.aspect    = WGPUTextureAspect.depthOnly;
            depthView = wgpuTextureCreateView(depthTexture, &viewDesc);
        }

        // HDR color
        {
            WGPUTextureDescriptor desc;
            desc.usage     = WGPUTextureUsage.renderAttachment | WGPUTextureUsage.textureBinding | WGPUTextureUsage.copySrc;
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

        if (snapshotActive) {
            createSnapshotTargets(w, h);
        }

        gtao.releaseTargets();
        post.resize(w, h);
    }

    private void createSnapshotTargets(uint w, uint h) nothrow @nogc @trusted {
        releaseSnapshotTargets();
        if (w == 0 || h == 0) return;

        {
            immutable uint maxMips = mipCount(w, h);
            opaqueMipCount = maxMips < OPAQUE_COLOR_MIPS ? maxMips : OPAQUE_COLOR_MIPS;

            WGPUTextureDescriptor td;
            td.usage         = WGPUTextureUsage.copyDst | WGPUTextureUsage.textureBinding | WGPUTextureUsage.renderAttachment;
            td.dimension     = WGPUTextureDimension.dim2D;
            td.size          = WGPUExtent3D(w, h, 1);
            td.format        = SCENE_COLOR_FORMAT;
            td.mipLevelCount = opaqueMipCount;
            opaqueColorTex = wgpuDeviceCreateTexture(device, &td);
            if (opaqueColorTex is null) fatal("Opaque color snapshot texture creation failed");
            WGPUTextureViewDescriptor vd;
            vd.format        = SCENE_COLOR_FORMAT;
            vd.dimension     = WGPUTextureViewDimension.dim2D;
            vd.baseMipLevel  = 0;
            vd.mipLevelCount = opaqueMipCount;
            opaqueColorView_ = wgpuTextureCreateView(opaqueColorTex, &vd);

            foreach (m; 0 .. opaqueMipCount) {
                WGPUTextureViewDescriptor mvd;
                mvd.format        = SCENE_COLOR_FORMAT;
                mvd.dimension     = WGPUTextureViewDimension.dim2D;
                mvd.baseMipLevel  = m;
                mvd.mipLevelCount = 1;
                opaqueMipViews[m] = wgpuTextureCreateView(opaqueColorTex, &mvd);
            }
            if (opaqueDownBGL !is null && opaqueDownSampler !is null) {
                foreach (m; 1 .. opaqueMipCount) {
                    WGPUBindGroupEntry[2] e;
                    e[0].binding     = 0;
                    e[0].sampler     = opaqueDownSampler;
                    e[1].binding     = 1;
                    e[1].textureView = opaqueMipViews[m - 1];
                    WGPUBindGroupDescriptor bgd;
                    bgd.layout     = opaqueDownBGL;
                    bgd.entryCount = 2;
                    bgd.entries    = e.ptr;
                    opaqueDownBG[m] = wgpuDeviceCreateBindGroup(device, &bgd);
                }
            }
        }

        {
            WGPUTextureDescriptor td;
            td.usage     = WGPUTextureUsage.renderAttachment | WGPUTextureUsage.textureBinding;
            td.dimension = WGPUTextureDimension.dim2D;
            td.size      = WGPUExtent3D(w, h, 1);
            td.format    = WGPUTextureFormat.depth32Float;
            opaqueDepthTex = wgpuDeviceCreateTexture(device, &td);
            if (opaqueDepthTex is null) fatal("Opaque depth snapshot texture creation failed");
            WGPUTextureViewDescriptor vd;
            vd.format    = WGPUTextureFormat.depth32Float;
            vd.dimension = WGPUTextureViewDimension.dim2D;
            vd.aspect    = WGPUTextureAspect.depthOnly;
            opaqueDepthView_ = wgpuTextureCreateView(opaqueDepthTex, &vd);
        }

        if (depthCopyBGL !is null && depthView !is null) {
            WGPUBindGroupEntry bge;
            bge.binding = 0;
            bge.textureView = depthView;
            WGPUBindGroupDescriptor bgd;
            bgd.layout = depthCopyBGL;
            bgd.entryCount = 1;
            bgd.entries = &bge;
            depthCopyBG = wgpuDeviceCreateBindGroup(device, &bgd);
        }
    }

    private void releaseSnapshotTargets() nothrow @nogc @trusted {
        if (depthCopyBG !is null)      { wgpuBindGroupRelease(depthCopyBG); depthCopyBG = null; }
        if (opaqueDepthView_ !is null) { wgpuTextureViewRelease(opaqueDepthView_); opaqueDepthView_ = null; }
        if (opaqueDepthTex !is null)   { wgpuTextureRelease(opaqueDepthTex); opaqueDepthTex = null; }
        foreach (i; 0 .. OPAQUE_COLOR_MIPS) {
            if (opaqueDownBG[i] !is null)   { wgpuBindGroupRelease(opaqueDownBG[i]); opaqueDownBG[i] = null; }
            if (opaqueMipViews[i] !is null) { wgpuTextureViewRelease(opaqueMipViews[i]); opaqueMipViews[i] = null; }
        }
        opaqueMipCount = 0;
        if (opaqueColorView_ !is null) { wgpuTextureViewRelease(opaqueColorView_); opaqueColorView_ = null; }
        if (opaqueColorTex !is null)   { wgpuTextureRelease(opaqueColorTex); opaqueColorTex = null; }
    }

    private void ensureOpaqueSnapshot() nothrow @nogc @trusted {
        if (opaqueDownPipe is null) {
            WGPUSamplerDescriptor sd;
            sd.addressModeU  = WGPUAddressMode.clampToEdge;
            sd.addressModeV  = WGPUAddressMode.clampToEdge;
            sd.addressModeW  = WGPUAddressMode.clampToEdge;
            sd.magFilter     = WGPUFilterMode.linear;
            sd.minFilter     = WGPUFilterMode.linear;
            sd.mipmapFilter  = WGPUMipmapFilterMode.nearest;
            sd.lodMinClamp   = 0;
            sd.lodMaxClamp   = 1;
            sd.maxAnisotropy = 1;
            opaqueDownSampler = wgpuDeviceCreateSampler(device, &sd);

            WGPUBindGroupLayoutEntry[2] bglEntries;
            bglEntries[0].binding      = 0;
            bglEntries[0].visibility   = WGPUShaderStage.fragment;
            bglEntries[0].sampler.type = WGPUSamplerBindingType.filtering;
            bglEntries[1].binding               = 1;
            bglEntries[1].visibility            = WGPUShaderStage.fragment;
            bglEntries[1].texture.sampleType    = WGPUTextureSampleType.float_;
            bglEntries[1].texture.viewDimension = WGPUTextureViewDimension.dim2D;

            WGPUBindGroupLayoutDescriptor bgld;
            bgld.entryCount = 2;
            bgld.entries    = bglEntries.ptr;
            opaqueDownBGL = wgpuDeviceCreateBindGroupLayout(device, &bgld);

            WGPUPipelineLayoutDescriptor pld;
            pld.bindGroupLayoutCount = 1;
            pld.bindGroupLayouts     = &opaqueDownBGL;
            opaqueDownPL = wgpuDeviceCreatePipelineLayout(device, &pld);

            static immutable string downSrc = bloomDownsampleShaderSource;
            opaqueDownSM = createShaderModule(device, downSrc);
            if (opaqueDownSM is null) fatal("Failed to compile post_bloom_down.wgsl for opaque pyramid");

            WGPUColorTargetState ct;
            ct.format    = SCENE_COLOR_FORMAT;
            ct.writeMask = WGPUColorWriteMask.all;

            WGPUFragmentState fs;
            fs.module_     = opaqueDownSM;
            fs.entryPoint  = wgpuStringView("fs_main");
            fs.targetCount = 1;
            fs.targets     = &ct;

            WGPURenderPipelineDescriptor pd;
            pd.layout             = opaqueDownPL;
            pd.vertex.module_     = opaqueDownSM;
            pd.vertex.entryPoint  = wgpuStringView("vs_main");
            pd.primitive.topology = WGPUPrimitiveTopology.triangleList;
            pd.fragment           = &fs;
            pd.multisample.count  = 1;
            pd.multisample.mask   = ~0u;
            opaqueDownPipe = wgpuDeviceCreateRenderPipeline(device, &pd);
            if (opaqueDownPipe is null) fatal("Failed to create opaque downsample pipeline");
        }
        if (depthCopyPipe is null) {
            WGPUBindGroupLayoutEntry bgle;
            bgle.binding = 0;
            bgle.visibility = WGPUShaderStage.fragment;
            bgle.texture.sampleType = WGPUTextureSampleType.depth;
            bgle.texture.viewDimension = WGPUTextureViewDimension.dim2D;

            WGPUBindGroupLayoutDescriptor bgld;
            bgld.entryCount = 1;
            bgld.entries = &bgle;
            depthCopyBGL = wgpuDeviceCreateBindGroupLayout(device, &bgld);

            WGPUPipelineLayoutDescriptor pld;
            pld.bindGroupLayoutCount = 1;
            pld.bindGroupLayouts = &depthCopyBGL;
            depthCopyPL = wgpuDeviceCreatePipelineLayout(device, &pld);

            static immutable string depthCopySrc = depthCopyShaderSource;
            depthCopySM = createShaderModule(device, depthCopySrc);
            if (depthCopySM is null) fatal("Failed to compile depth_copy.wgsl");

            WGPUFragmentState fs;
            fs.module_ = depthCopySM;
            fs.entryPoint = wgpuStringView("fs_main");
            fs.targetCount = 0;
            fs.targets = null;

            WGPUDepthStencilState ds;
            ds.format = WGPUTextureFormat.depth32Float;
            ds.depthWriteEnabled = WGPUOptionalBool.true_;
            ds.depthCompare = WGPUCompareFunction.always;

            WGPURenderPipelineDescriptor pd;
            pd.layout = depthCopyPL;
            pd.vertex.module_ = depthCopySM;
            pd.vertex.entryPoint = wgpuStringView("vs_main");
            pd.primitive.topology = WGPUPrimitiveTopology.triangleList;
            pd.primitive.frontFace = WGPUFrontFace.ccw;
            pd.primitive.cullMode = WGPUCullMode.none;
            pd.depthStencil = &ds;
            pd.fragment = &fs;
            pd.multisample.count = 1;
            pd.multisample.mask = ~0u;
            depthCopyPipe = wgpuDeviceCreateRenderPipeline(device, &pd);
            if (depthCopyPipe is null) fatal("Failed to create depth copy pipeline");
        }
        snapshotActive = true;
        if (opaqueColorTex is null && rtW > 0 && rtH > 0) {
            createSnapshotTargets(rtW, rtH);
        }
    }

    /// Snapshot the current opaque HDR color and depth buffers for subsequent
    /// refractive/SSR draws, then reopen the HDR pass with loadOp = load.
    /// `parts` limits the copy to what the caller reads (each part is a copy pass):
    /// depth-only consumers (decals) or level-0 color readers (water) skip the rest.
    /// Parts not copied keep their previous content.
    void snapshotOpaque(ref FrameContext frame, SnapshotParts parts = SnapshotParts.all) nothrow @nogc @trusted {
        if (!frame.valid || frame.postResolved || parts == SnapshotParts.none) return;
        auto z = profileZone!"renderer.snapshotOpaque"();
        auto g = gpuFrameScope!"gpu.snapshotOpaque"(frame);
        ensureOpaqueSnapshot();
        if (opaqueColorTex is null || opaqueDepthView_ is null || depthCopyBG is null) return;

        {
            frame.suspendScenePass();
            scope(exit) frame.resumeScenePass();
            if (parts & SnapshotParts.color) {
                WGPUImageCopyTexture src;
                src.texture = hdrTexture;
                WGPUImageCopyTexture dst;
                dst.texture  = opaqueColorTex;
                dst.mipLevel = 0;
                immutable copySz = WGPUExtent3D(rtW, rtH, 1);
                wgpuCommandEncoderCopyTextureToTexture(frame.encoder, &src, &dst, &copySz);
            }

            if (opaqueDownPipe !is null && (parts & SNAPSHOT_MIPS_BIT)) {
                foreach (m; 1 .. opaqueMipCount) {
                    if (opaqueMipViews[m] is null || opaqueDownBG[m] is null) break;
                    WGPURenderPassColorAttachment ca;
                    ca.view       = opaqueMipViews[m];
                    ca.loadOp     = WGPULoadOp.clear;
                    ca.storeOp    = WGPUStoreOp.store;
                    ca.depthSlice = WGPU_DEPTH_SLICE_UNDEFINED;
                    WGPURenderPassDescriptor mpd;
                    mpd.colorAttachmentCount = 1;
                    mpd.colorAttachments     = &ca;
                    auto mipPass = wgpuCommandEncoderBeginRenderPass(frame.encoder, &mpd);
                    wgpuRenderPassEncoderSetPipeline(mipPass, opaqueDownPipe);
                    wgpuRenderPassEncoderSetBindGroup(mipPass, 0, opaqueDownBG[m], 0, null);
                    wgpuRenderPassEncoderDraw(mipPass, 3, 1, 0, 0);
                    wgpuRenderPassEncoderEnd(mipPass);
                    wgpuRenderPassEncoderRelease(mipPass);
                }
            }

            if (parts & SnapshotParts.depth) {
                WGPURenderPassDepthStencilAttachment dAtt;
                dAtt.view = opaqueDepthView_;
                dAtt.depthLoadOp = WGPULoadOp.clear;
                dAtt.depthStoreOp = WGPUStoreOp.store;
                dAtt.depthClearValue = 1.0f;

                WGPURenderPassDescriptor rpd;
                rpd.colorAttachmentCount = 0;
                rpd.colorAttachments = null;
                rpd.depthStencilAttachment = &dAtt;

                auto dPass = wgpuCommandEncoderBeginRenderPass(frame.encoder, &rpd);
                wgpuRenderPassEncoderSetPipeline(dPass, depthCopyPipe);
                wgpuRenderPassEncoderSetBindGroup(dPass, 0, depthCopyBG, 0, null);
                wgpuRenderPassEncoderDraw(dPass, 3, 1, 0, 0);
                wgpuRenderPassEncoderEnd(dPass);
                wgpuRenderPassEncoderRelease(dPass);
            }
        }
    }

    WGPUTextureView opaqueColorView() nothrow @nogc @trusted {
        ensureOpaqueSnapshot();
        return opaqueColorView_;
    }

    WGPUTextureView opaqueDepthView() nothrow @nogc @trusted {
        ensureOpaqueSnapshot();
        return opaqueDepthView_;
    }

    private void releaseSceneTargets() nothrow @nogc @trusted {
        releaseSnapshotTargets();
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
        {
            auto z = profileZone!"renderer.gpuReadback"();
            gpuProfilerCollect(); // commit GPU timings of frames that finished (non-blocking)
        }
        post.clearSceneCamera();
        gtao.beginFrame();
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
        frame.owner = &this;
        frame.encoder = encoder;
        frame.pass = pass;
        frame.sceneColorView = hdrView;
        frame.sceneDepthView = depthView;
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
        {
            auto z = profileZone!"renderer.acquire"();
            wgpuSurfaceGetCurrentTexture(surface, &surfTex);
        }
        frame.acquireStatus = surfTex.status;
        if (surfTex.status != WGPUSurfaceGetCurrentTextureStatus.successOptimal &&
            surfTex.status != WGPUSurfaceGetCurrentTextureStatus.successSuboptimal)
        {
            // Swapchain not available this frame (outdated / timeout / lost):
            // drop the recorded work instead of leaking the encoder + texture.
            if (surfTex.texture !is null) wgpuTextureRelease(surfTex.texture);
            gpuProfilerDiscardFrame();
            wgpuCommandEncoderRelease(frame.encoder);
            frame.encoder = null;
            frame.valid = false;
            return;
        }

        WGPUTextureViewDescriptor viewDesc;
        auto surfView = wgpuTextureCreateView(surfTex.texture, &viewDesc);
        frame.texture = surfTex.texture;
        frame.view = surfView;

        immutable bool useUiRT = post.hasActiveAfterUiPasses();
        WGPUTextureView uiDst = useUiRT ? post.ensureUiTargetView() : surfView;
        if (uiDst is null) uiDst = surfView;

        {
            auto z = profileZone!"renderer.post"();
            auto g = gpuScope!"gpu.post"(frame.encoder);
            post.execute(frame.encoder, hdrView, uiDst, depthView);
        }

        // Present pass for UI (no depth)
        WGPURenderPassColorAttachment colorAtt;
        colorAtt.view       = uiDst;
        colorAtt.loadOp     = WGPULoadOp.load;
        colorAtt.storeOp    = WGPUStoreOp.store;
        colorAtt.clearValue = WGPUColor(0, 0, 0, 1);
        colorAtt.depthSlice = WGPU_DEPTH_SLICE_UNDEFINED;

        WGPURenderPassDescriptor passDesc;
        passDesc.colorAttachmentCount = 1;
        passDesc.colorAttachments     = &colorAtt;

        frame.pass = wgpuCommandEncoderBeginRenderPass(frame.encoder, &passDesc);
        uiGpuScope = gpuPassBegin!"gpu.ui"(frame.pass); // ended in endFrame, same pass
        frame.postResolved = true;
    }

    /// End the frame: ensure post ran, finish UI pass, submit, present.
    void endFrame(ref FrameContext frame) nothrow @nogc @trusted {
        if (!frame.valid) return;

        if (!frame.postResolved)
            resolvePost(frame);
        if (!frame.valid) return;

        gpuPassEnd(uiGpuScope, frame.pass);
        uiGpuScope = NO_GPU_SCOPE;
        wgpuRenderPassEncoderEnd(frame.pass);
        wgpuRenderPassEncoderRelease(frame.pass);

        if (post.hasActiveAfterUiPasses()) {
            post.executeAfterUi(frame.encoder, frame.view, depthView);
        }

        if (captureBuf !is null && frame.texture !is null) encodeCapture(frame);
        gpuProfilerResolve(frame.encoder);

        {
            auto z = profileZone!"renderer.submit"();
            auto zFinish = profileZone!"renderer.submit.finish"(); // wgpu-core validates the recorded passes
            WGPUCommandBufferDescriptor cbDesc;
            auto cmdBuf = wgpuCommandEncoderFinish(frame.encoder, &cbDesc);
            wgpuCommandEncoderRelease(frame.encoder);
            zFinish.close();

            auto zQueue = profileZone!"renderer.submit.queue"(); // HAL encoding + vkQueueSubmit
            wgpuQueueSubmit(queue, 1, &cmdBuf);
            wgpuCommandBufferRelease(cmdBuf);
        }
        gpuProfilerAfterSubmit();

        {
            auto z = profileZone!"renderer.present"();
            wgpuSurfacePresent(surface);
        }

        if (frame.view !is null) wgpuTextureViewRelease(frame.view);
        if (frame.texture !is null) wgpuTextureRelease(frame.texture);

        frame = FrameContext.init;
    }

    /// Asks for the next presented frame to be copied into a readback buffer. Fetch it with
    /// `readCapture` after `endFrame`. Not for the frame path (allocates a GPU buffer).
    void requestCapture() nothrow @nogc @trusted {
        if (captureBuf !is null || rtW == 0 || rtH == 0) return;
        captureFilled = false;
        captureW = rtW;
        captureH = rtH;
        captureStride = (captureW * 4 + 255) & ~255u; // bytesPerRow must be a multiple of 256
        WGPUBufferDescriptor bd;
        bd.usage = WGPUBufferUsage.copyDst | WGPUBufferUsage.mapRead;
        bd.size = cast(ulong) captureStride * captureH;
        captureBuf = wgpuDeviceCreateBuffer(device, &bd);
    }

    /// True when a requested capture was recorded by `endFrame` and can be read. A frame that could not be presented
    /// leaves the request pending for the next one.
    bool captureReady() const nothrow @nogc { return captureBuf !is null && captureFilled; }

    private void encodeCapture(ref FrameContext frame) nothrow @nogc @trusted {
        if (captureFilled) return; // not read yet
        if (captureW != rtW || captureH != rtH) { // resized since the request
            wgpuBufferRelease(captureBuf);
            captureBuf = null;
            requestCapture();
            if (captureBuf is null) return;
        }
        captureFilled = true;
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
    private bool mapCaptureBuffer(
        out const(ubyte)* mappedPtr,
        out bool isBgra,
        out uint w,
        out uint h,
        out uint stride
    ) nothrow @nogc @trusted {
        if (captureBuf is null) return false;
        static struct Wait { bool done; bool ok; }
        Wait waitState;
        static extern(C) void onMapped(WGPUMapAsyncStatus status, WGPUStringView, void* u1, void*) nothrow @nogc {
            auto p = cast(Wait*) u1;
            p.ok = status == WGPUMapAsyncStatus.success;
            p.done = true;
        }
        WGPUBufferMapCallbackInfo cb;
        cb.mode = WGPUCallbackMode.allowProcessEvents;
        cb.callback = &onMapped;
        cb.userdata1 = &waitState;
        wgpuBufferMapAsync(captureBuf, WGPUMapMode.read, 0, cast(size_t) captureStride * captureH, cb);
        foreach (_; 0 .. 1000) {
            wgpuDevicePoll(device, WGPU_TRUE, null);
            if (waitState.done) break;
        }
        if (!waitState.ok) return false;

        immutable bool bgra = surfaceFormat == WGPUTextureFormat.bgra8Unorm
                           || surfaceFormat == WGPUTextureFormat.bgra8UnormSrgb;
        immutable bool rgba = surfaceFormat == WGPUTextureFormat.rgba8Unorm
                           || surfaceFormat == WGPUTextureFormat.rgba8UnormSrgb;
        if (!bgra && !rgba) {
            wgpuBufferUnmap(captureBuf);
            return false;
        }
        mappedPtr = cast(const(ubyte)*) wgpuBufferGetConstMappedRange(
            captureBuf, 0, cast(size_t) captureStride * captureH
        );
        if (mappedPtr is null) {
            wgpuBufferUnmap(captureBuf);
            return false;
        }
        isBgra = bgra;
        w = captureW;
        h = captureH;
        stride = captureStride;
        return true;
    }

    private static void swizzleCaptureRows(
        const(ubyte)* src, ubyte* dst, uint w, uint h, uint stride, bool bgra
    ) nothrow @nogc @trusted {
        foreach (y; 0 .. h) {
            foreach (x; 0 .. w) {
                const px = src + y * stride + x * 4;
                auto o = dst + (y * w + x) * 4;
                o[0] = bgra ? px[2] : px[0];
                o[1] = px[1];
                o[2] = bgra ? px[0] : px[2];
                o[3] = 255;
            }
        }
    }

    ubyte[] readCapture(out uint width, out uint height) @trusted {
        if (!captureReady()) return null;
        scope(exit) { captureFilled = false; wgpuBufferRelease(captureBuf); captureBuf = null; }
        const(ubyte)* src = null;
        bool bgra = false;
        uint cw = 0, ch = 0, stride = 0;
        if (!mapCaptureBuffer(src, bgra, cw, ch, stride)) {
            warn("frame capture: map or format check failed");
            return null;
        }
        scope(exit) wgpuBufferUnmap(captureBuf);
        auto outPx = new ubyte[cw * ch * 4];
        swizzleCaptureRows(src, outPx.ptr, cw, ch, stride, bgra);
        width = cw;
        height = ch;
        return outPx;
    }

    /// `@nogc` frame-capture sink using C-heap temporary storage (used by `App.saveScreenshot`).
    bool consumeCaptureWith(
        scope void function(const(ubyte)* rgba, uint w, uint h, void* user) nothrow @nogc sink,
        void* user
    ) nothrow @nogc @trusted {
        import core.stdc.stdlib : malloc, free;
        if (!captureReady() || sink is null) return false;
        scope(exit) { captureFilled = false; wgpuBufferRelease(captureBuf); captureBuf = null; }

        const(ubyte)* src = null;
        bool bgra = false;
        uint cw = 0, ch = 0, stride = 0;
        if (!mapCaptureBuffer(src, bgra, cw, ch, stride)) return false;
        scope(exit) wgpuBufferUnmap(captureBuf);

        immutable size_t total = cast(size_t) cw * ch * 4;
        auto rgbaBuf = cast(ubyte*) malloc(total);
        if (rgbaBuf is null) return false;
        scope(exit) free(rgbaBuf);

        swizzleCaptureRows(src, rgbaBuf, cw, ch, stride, bgra);
        sink(rgbaBuf, cw, ch, user);
        return true;
    }

    void resize(uint w, uint h) nothrow @nogc {
        createSceneTargets(w, h);
    }

    void destroy() nothrow @nogc @trusted {
        gpuProfilerDestroy();
        releaseSceneTargets();
        if (opaqueDownPipe !is null)    { wgpuRenderPipelineRelease(opaqueDownPipe); opaqueDownPipe = null; }
        if (opaqueDownPL !is null)      { wgpuPipelineLayoutRelease(opaqueDownPL); opaqueDownPL = null; }
        if (opaqueDownBGL !is null)     { wgpuBindGroupLayoutRelease(opaqueDownBGL); opaqueDownBGL = null; }
        if (opaqueDownSM !is null)      { wgpuShaderModuleRelease(opaqueDownSM); opaqueDownSM = null; }
        if (opaqueDownSampler !is null) { wgpuSamplerRelease(opaqueDownSampler); opaqueDownSampler = null; }
        if (depthCopyPipe !is null) { wgpuRenderPipelineRelease(depthCopyPipe); depthCopyPipe = null; }
        if (depthCopyPL !is null)   { wgpuPipelineLayoutRelease(depthCopyPL); depthCopyPL = null; }
        if (depthCopyBGL !is null)  { wgpuBindGroupLayoutRelease(depthCopyBGL); depthCopyBGL = null; }
        if (depthCopySM !is null)   { wgpuShaderModuleRelease(depthCopySM); depthCopySM = null; }
        snapshotActive = false;
        if (postOwned) {
            post.destroy();
            gtao.destroy();
            postOwned = false;
        }
    }
}

struct FrameContext {
    package(engine) Renderer* owner = null;
    WGPUTexture            texture; // swapchain texture after resolvePost
    WGPUTextureView        view;    // swapchain view after resolvePost
    WGPUCommandEncoder     encoder;
    WGPURenderPassEncoder  pass;
    WGPUTextureView        sceneColorView;
    WGPUTextureView        sceneDepthView;
    bool                   valid = false;
    bool                   postResolved = false;
    /// Last `setViewport` rectangle, re-applied by `resumeScenePass`.
    private bool           hasViewport = false;
    private float[4]       viewportRect;
    private uint[2]        viewportTarget;
    WGPUSurfaceGetCurrentTextureStatus acquireStatus;

    /// Active viewport rectangle `(x, y, w, h)` in pixels, or the full HDR scene target.
    package(engine) float[4] activeViewportRect() const nothrow @nogc {
        if (hasViewport) return viewportRect;
        if (owner !is null) return [0.0f, 0.0f, cast(float) owner.rtW, cast(float) owner.rtH];
        return [0.0f, 0.0f, 1920.0f, 1080.0f];
    }

    /// End the active HDR scene pass temporarily so auxiliary depth/compute
    /// passes can be recorded on `encoder`. Pair with `resumeScenePass`.
    void suspendScenePass() nothrow @nogc @trusted {
        if (!valid || postResolved || pass is null) return;
        wgpuRenderPassEncoderEnd(pass);
        wgpuRenderPassEncoderRelease(pass);
        pass = null;
    }

    /// Reopen the HDR scene pass with `loadOp = load` after `suspendScenePass`.
    void resumeScenePass() nothrow @nogc @trusted {
        if (!valid || postResolved || pass !is null) return;
        if (sceneColorView is null || sceneDepthView is null) return;

        WGPURenderPassColorAttachment colorAtt;
        colorAtt.view       = sceneColorView;
        colorAtt.loadOp     = WGPULoadOp.load;
        colorAtt.storeOp    = WGPUStoreOp.store;
        colorAtt.depthSlice = WGPU_DEPTH_SLICE_UNDEFINED;

        WGPURenderPassDepthStencilAttachment depthAtt;
        depthAtt.view            = sceneDepthView;
        depthAtt.depthLoadOp     = WGPULoadOp.load;
        depthAtt.depthStoreOp    = WGPUStoreOp.store;

        WGPURenderPassDescriptor passDesc;
        passDesc.colorAttachmentCount = 1;
        passDesc.colorAttachments     = &colorAtt;
        passDesc.depthStencilAttachment = &depthAtt;
        pass = wgpuCommandEncoderBeginRenderPass(encoder, &passDesc);
        // A new pass starts with a full-target viewport: restore the panel
        // rectangle (editor viewport, split screen) set before the suspend.
        if (hasViewport)
            setViewport(viewportRect[0], viewportRect[1], viewportRect[2], viewportRect[3],
                        viewportTarget[0], viewportTarget[1]);
    }

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
        hasViewport = true;
        viewportRect = [x, y, w, h];
        viewportTarget = [targetW, targetH];
        wgpuRenderPassEncoderSetViewport(pass, x, y, w, h, 0.0f, 1.0f);
        uint sx, sy, sw, sh;
        clipSpan(x, w, targetW, sx, sw);
        clipSpan(y, h, targetH, sy, sh);
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

    /// Non-indexed draw (fullscreen triangles, procedural geometry).
    void draw(uint vertexCount, uint instanceCount = 1, uint firstVertex = 0,
              uint firstInstance = 0) nothrow @nogc @trusted {
        wgpuRenderPassEncoderDraw(pass, vertexCount, instanceCount, firstVertex, firstInstance);
    }

    /// Indexed draw. `firstIndex` selects a sub-range of the bound index buffer
    /// (LOD levels, glTF primitives); `firstInstance` selects a sub-range of the
    /// per-instance vertex buffer (retained static instancing).
    void drawIndexed(uint indexCount, uint instanceCount, uint firstIndex = 0,
                     int baseVertex = 0, uint firstInstance = 0) nothrow @nogc @trusted {
        wgpuRenderPassEncoderDrawIndexed(pass, indexCount, instanceCount, firstIndex, baseVertex, firstInstance);
    }
}

/// Intersect the viewport span `[pos, pos + size)` with `[0, target)`: a scissor rect must lie inside the target.
private void clipSpan(float pos, float size, uint target, out uint start, out uint length) pure nothrow @nogc @safe {
    immutable float lo = pos < 0 ? 0 : pos;
    immutable float end = pos + size;
    immutable float hi = end > target ? target : end;
    if (!(hi > lo)) return; // fully outside: empty
    start = cast(uint) lo;
    length = cast(uint) hi - start;
}

@("renderer: the viewport scissor stays inside the target")
@safe pure nothrow @nogc unittest {
    static uint[2] clip(float p, float s, uint t) {
        uint a, b;
        clipSpan(p, s, t, a, b);
        return [a, b];
    }
    assert(clip(0, 100, 100) == [0, 100]);
    assert(clip(-20, 100, 200) == [0, 80]);
    assert(clip(150, 100, 200) == [150, 50]);
    assert(clip(250, 100, 200) == [0, 0]);
    assert(clip(-300, 100, 200) == [0, 0]);
}
