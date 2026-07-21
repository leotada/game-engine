/// Post-processing: bloom, tone map (ACES/Reinhard), FXAA on an HDR scene RT.
module engine.gpu.post;

import bindings.wgpu;
import engine.core.log;
import engine.gpu.buffer : createUniformBuffer, updateBuffer;
import engine.gpu.context : GpuContext;
import engine.gpu.shader : createShaderModule;
import engine.gpu.shaders;

@safe:

/// Color format for the offscreen scene / HDR post inputs.
enum WGPUTextureFormat SCENE_COLOR_FORMAT = WGPUTextureFormat.rgba16Float;

/// Runtime toggles for the post stack. Owned by `Renderer`.
struct PostSettings {
    float exposure = 1.0f;
    bool bloom = true;
    bool fxaa = true;
    int tonemapMode = 0; // 0 = ACES, 1 = Reinhard
    // Visible bloom with Karis/clamp keeping fireflies in check.
    float bloomThreshold = 1.2f;
    float bloomKnee = 0.7f;
    float bloomStrength = 0.12f;
    float bloomClamp = 8.0f;
}

private enum MAX_BLOOM_MIPS = 5;

private struct TexRT {
    WGPUTexture texture;
    WGPUTextureView view;
    uint width;
    uint height;

    void release() nothrow @nogc @trusted {
        if (view !is null) { wgpuTextureViewRelease(view); view = null; }
        if (texture !is null) { wgpuTextureRelease(texture); texture = null; }
        width = height = 0;
    }
}

/// Fullscreen post pipelines and transient bloom / LDR targets.
struct PostProcessor {
    private GpuContext* ctx;
    private WGPUSampler linearSampler;
    private WGPUBuffer thresholdUBO;
    private WGPUBuffer tonemapUBO;

    private WGPUShaderModule threshSM, downKarisSM, downSM, upSM, tonemapSM, fxaaSM, blitSM;
    private WGPUBindGroupLayout threshBGL, sampleBGL, tonemapBGL;
    private WGPUPipelineLayout threshPL, samplePL, tonemapPL;
    private WGPURenderPipeline threshPipe, downKarisPipe, downPipe, upPipe, upAddPipe;
    private WGPURenderPipeline tonemapPipe, fxaaPipe, blitPipe;

    private TexRT[MAX_BLOOM_MIPS] bloomMips;
    private TexRT ldrRT; // tonemap output when FXAA is on
    private uint bloomLevels = 0;
    private uint width, height;
    private WGPUTextureFormat surfaceFormat;

    PostSettings settings;

    @disable this(this);

    private WGPURenderPipeline tonemapToSurfacePipe;

    static PostProcessor create(ref GpuContext gpu, WGPUTextureFormat surfFmt) @trusted {
        PostProcessor p;
        p.ctx = &gpu;
        p.surfaceFormat = surfFmt;
        p.settings = PostSettings.init;
        p.tonemapToSurfacePipe = null;
        auto device = gpu.getDevice();

        WGPUSamplerDescriptor sd;
        sd.addressModeU = WGPUAddressMode.clampToEdge;
        sd.addressModeV = WGPUAddressMode.clampToEdge;
        sd.addressModeW = WGPUAddressMode.clampToEdge;
        sd.magFilter = WGPUFilterMode.linear;
        sd.minFilter = WGPUFilterMode.linear;
        sd.mipmapFilter = WGPUMipmapFilterMode.nearest;
        sd.lodMinClamp = 0;
        sd.lodMaxClamp = 1;
        sd.maxAnisotropy = 1;
        p.linearSampler = wgpuDeviceCreateSampler(device, &sd);

        p.thresholdUBO = createUniformBuffer(device, 16);
        p.tonemapUBO = createUniformBuffer(device, 16);

        p.threshSM = createShaderModule(device, bloomThresholdShaderSource.ptr);
        p.downKarisSM = createShaderModule(device, bloomDownsampleKarisShaderSource.ptr);
        p.downSM = createShaderModule(device, bloomDownsampleShaderSource.ptr);
        p.upSM = createShaderModule(device, bloomUpsampleShaderSource.ptr);
        p.tonemapSM = createShaderModule(device, tonemapShaderSource.ptr);
        p.fxaaSM = createShaderModule(device, fxaaShaderSource.ptr);
        p.blitSM = createShaderModule(device, blitShaderSource.ptr);

        p.threshBGL = makeTexUBOBGL(device, /*hasUbo=*/true);
        p.sampleBGL = makeTexUBOBGL(device, /*hasUbo=*/false);
        p.tonemapBGL = makeTonemapBGL(device);

        p.threshPL = makePL(device, p.threshBGL);
        p.samplePL = makePL(device, p.sampleBGL);
        p.tonemapPL = makePL(device, p.tonemapBGL);

        p.threshPipe = makeFSPipeline(device, p.threshPL, p.threshSM, SCENE_COLOR_FORMAT, false);
        p.downKarisPipe = makeFSPipeline(device, p.samplePL, p.downKarisSM, SCENE_COLOR_FORMAT, false);
        p.downPipe = makeFSPipeline(device, p.samplePL, p.downSM, SCENE_COLOR_FORMAT, false);
        p.upPipe = makeFSPipeline(device, p.samplePL, p.upSM, SCENE_COLOR_FORMAT, false);
        p.upAddPipe = makeFSPipeline(device, p.samplePL, p.upSM, SCENE_COLOR_FORMAT, true);
        // Tonemap / FXAA / blit targets are created per-call with surface or LDR format
        p.tonemapPipe = null;
        p.fxaaPipe = null;
        p.blitPipe = null;
        p.rebuildPresentPipelines(surfFmt);

        return p;
    }

    private void rebuildPresentPipelines(WGPUTextureFormat surfFmt) @trusted {
        auto device = ctx.getDevice();
        if (tonemapPipe !is null) { wgpuRenderPipelineRelease(tonemapPipe); tonemapPipe = null; }
        if (fxaaPipe !is null) { wgpuRenderPipelineRelease(fxaaPipe); fxaaPipe = null; }
        if (blitPipe !is null) { wgpuRenderPipelineRelease(blitPipe); blitPipe = null; }
        surfaceFormat = surfFmt;
        // Tonemap can write to surface (no FXAA) or to rgba8 LDR RT
        tonemapPipe = makeFSPipeline(device, tonemapPL, tonemapSM, WGPUTextureFormat.rgba8Unorm, false);
        fxaaPipe = makeFSPipeline(device, samplePL, fxaaSM, surfFmt, false);
        blitPipe = makeFSPipeline(device, samplePL, blitSM, surfFmt, false);
    }

    private void ensureTonemapSurfacePipe() nothrow @nogc @trusted {
        if (tonemapToSurfacePipe !is null) return;
        tonemapToSurfacePipe = makeFSPipeline(
            ctx.getDevice(), tonemapPL, tonemapSM, surfaceFormat, false);
    }

    void resize(uint w, uint h) nothrow @nogc @trusted {
        if (w == 0 || h == 0) return;
        if (w == width && h == height) return;
        width = w;
        height = h;
        releaseTargets();

        // Bloom chain at half-res and below
        uint bw = w > 1 ? w / 2 : 1;
        uint bh = h > 1 ? h / 2 : 1;
        bloomLevels = 0;
        foreach (i; 0 .. MAX_BLOOM_MIPS) {
            if (bw < 2 || bh < 2) break;
            bloomMips[i] = createRT(bw, bh, SCENE_COLOR_FORMAT);
            bloomLevels++;
            bw = bw > 1 ? bw / 2 : 1;
            bh = bh > 1 ? bh / 2 : 1;
        }
        ldrRT = createRT(w, h, WGPUTextureFormat.rgba8Unorm);
        ensureTonemapSurfacePipe();
    }

    private void releaseTargets() nothrow @nogc {
        foreach (ref m; bloomMips) m.release();
        ldrRT.release();
        bloomLevels = 0;
    }

    /// Run bloom → tone map → FXAA into `surfaceView`. Uses `encoder` (no open pass).
    void execute(WGPUCommandEncoder encoder,
                 WGPUTextureView hdrView,
                 WGPUTextureView surfaceView) nothrow @nogc @trusted {
        if (width == 0 || height == 0) return;

        immutable useBloom = settings.bloom && bloomLevels > 0;
        if (useBloom) {
            // Threshold → mip0 (soft knee + bloomClamp)
            {
                float[4] params = [
                    settings.bloomThreshold,
                    settings.bloomKnee,
                    settings.bloomClamp,
                    0,
                ];
                updateBuffer(ctx.getQueue(), thresholdUBO, params[]);
                auto bg = makeUBOTexBG(threshBGL, thresholdUBO, 16, hdrView);
                scope(exit) wgpuBindGroupRelease(bg);
                drawPass(encoder, bloomMips[0].view, threshPipe, bg, true);
            }
            // First downsample: Karis (firefly suppression)
            if (bloomLevels > 1) {
                auto bg = makeSampleBG(sampleBGL, bloomMips[0].view);
                scope(exit) wgpuBindGroupRelease(bg);
                drawPass(encoder, bloomMips[1].view, downKarisPipe, bg, true);
            }
            // Further downsamples: box filter
            foreach (i; 1 .. bloomLevels - 1) {
                auto bg = makeSampleBG(sampleBGL, bloomMips[i].view);
                scope(exit) wgpuBindGroupRelease(bg);
                drawPass(encoder, bloomMips[i + 1].view, downPipe, bg, true);
            }
            // Upsample additive
            foreach_reverse (i; 0 .. bloomLevels - 1) {
                auto bg = makeSampleBG(sampleBGL, bloomMips[i + 1].view);
                scope(exit) wgpuBindGroupRelease(bg);
                drawPass(encoder, bloomMips[i].view, upAddPipe, bg, false);
            }
        } else if (bloomLevels > 0) {
            // Clear mip0 so tonemap samples black bloom
            clearRT(encoder, bloomMips[0].view);
        }

        float strength = useBloom ? settings.bloomStrength : 0.0f;
        float[4] tm = [
            settings.exposure,
            strength,
            cast(float) settings.tonemapMode,
            0,
        ];
        updateBuffer(ctx.getQueue(), tonemapUBO, tm[]);

        auto bloomView = bloomLevels > 0 ? bloomMips[0].view : hdrView;
        auto tmBG = makeTonemapBG(tonemapBGL, tonemapUBO, hdrView, bloomView);
        scope(exit) wgpuBindGroupRelease(tmBG);

        if (settings.fxaa) {
            drawPass(encoder, ldrRT.view, tonemapPipe, tmBG, true);
            auto fxBG = makeSampleBG(sampleBGL, ldrRT.view);
            scope(exit) wgpuBindGroupRelease(fxBG);
            drawPass(encoder, surfaceView, fxaaPipe, fxBG, true);
        } else {
            ensureTonemapSurfacePipe();
            drawPass(encoder, surfaceView, tonemapToSurfacePipe, tmBG, true);
        }
    }

    void destroy() nothrow @nogc @trusted {
        releaseTargets();
        if (linearSampler !is null) { wgpuSamplerRelease(linearSampler); linearSampler = null; }
        if (thresholdUBO !is null) { wgpuBufferRelease(thresholdUBO); thresholdUBO = null; }
        if (tonemapUBO !is null) { wgpuBufferRelease(tonemapUBO); tonemapUBO = null; }

        void relPipe(ref WGPURenderPipeline p) {
            if (p !is null) { wgpuRenderPipelineRelease(p); p = null; }
        }
        relPipe(threshPipe); relPipe(downKarisPipe); relPipe(downPipe); relPipe(upPipe); relPipe(upAddPipe);
        relPipe(tonemapPipe); relPipe(fxaaPipe); relPipe(blitPipe); relPipe(tonemapToSurfacePipe);

        void relPL(ref WGPUPipelineLayout p) {
            if (p !is null) { wgpuPipelineLayoutRelease(p); p = null; }
        }
        relPL(threshPL); relPL(samplePL); relPL(tonemapPL);

        void relBGL(ref WGPUBindGroupLayout p) {
            if (p !is null) { wgpuBindGroupLayoutRelease(p); p = null; }
        }
        relBGL(threshBGL); relBGL(sampleBGL); relBGL(tonemapBGL);

        void relSM(ref WGPUShaderModule p) {
            if (p !is null) { wgpuShaderModuleRelease(p); p = null; }
        }
        relSM(threshSM); relSM(downKarisSM); relSM(downSM); relSM(upSM);
        relSM(tonemapSM); relSM(fxaaSM); relSM(blitSM);
    }

    // --- helpers ---

    private TexRT createRT(uint w, uint h, WGPUTextureFormat fmt) nothrow @nogc @trusted {
        TexRT rt;
        rt.width = w;
        rt.height = h;
        WGPUTextureDescriptor td;
        td.usage = WGPUTextureUsage.renderAttachment | WGPUTextureUsage.textureBinding;
        td.dimension = WGPUTextureDimension.dim2D;
        td.size = WGPUExtent3D(w, h, 1);
        td.format = fmt;
        td.mipLevelCount = 1;
        td.sampleCount = 1;
        rt.texture = wgpuDeviceCreateTexture(ctx.getDevice(), &td);
        if (rt.texture is null) fatal("Post RT texture creation failed");
        WGPUTextureViewDescriptor vd;
        vd.format = fmt;
        vd.dimension = WGPUTextureViewDimension.dim2D;
        vd.mipLevelCount = 1;
        vd.arrayLayerCount = 1;
        rt.view = wgpuTextureCreateView(rt.texture, &vd);
        return rt;
    }

    private void drawPass(WGPUCommandEncoder encoder, WGPUTextureView target,
                          WGPURenderPipeline pipe, WGPUBindGroup bg, bool clear) nothrow @nogc @trusted {
        WGPURenderPassColorAttachment ca;
        ca.view = target;
        ca.loadOp = clear ? WGPULoadOp.clear : WGPULoadOp.load;
        ca.storeOp = WGPUStoreOp.store;
        ca.clearValue = WGPUColor(0, 0, 0, 1);
        ca.depthSlice = WGPU_DEPTH_SLICE_UNDEFINED;

        WGPURenderPassDescriptor pd;
        pd.colorAttachmentCount = 1;
        pd.colorAttachments = &ca;
        auto pass = wgpuCommandEncoderBeginRenderPass(encoder, &pd);
        wgpuRenderPassEncoderSetPipeline(pass, pipe);
        wgpuRenderPassEncoderSetBindGroup(pass, 0, bg, 0, null);
        wgpuRenderPassEncoderDraw(pass, 3, 1, 0, 0);
        wgpuRenderPassEncoderEnd(pass);
        wgpuRenderPassEncoderRelease(pass);
    }

    private void clearRT(WGPUCommandEncoder encoder, WGPUTextureView target) nothrow @nogc @trusted {
        WGPURenderPassColorAttachment ca;
        ca.view = target;
        ca.loadOp = WGPULoadOp.clear;
        ca.storeOp = WGPUStoreOp.store;
        ca.clearValue = WGPUColor(0, 0, 0, 1);
        ca.depthSlice = WGPU_DEPTH_SLICE_UNDEFINED;
        WGPURenderPassDescriptor pd;
        pd.colorAttachmentCount = 1;
        pd.colorAttachments = &ca;
        auto pass = wgpuCommandEncoderBeginRenderPass(encoder, &pd);
        wgpuRenderPassEncoderEnd(pass);
        wgpuRenderPassEncoderRelease(pass);
    }

    private WGPUBindGroup makeUBOTexBG(WGPUBindGroupLayout layout, WGPUBuffer ubo, ulong uboSize,
                                       WGPUTextureView tex) nothrow @nogc @trusted {
        WGPUBindGroupEntry[3] e;
        e[0].binding = 0; e[0].buffer = ubo; e[0].offset = 0; e[0].size = uboSize;
        e[1].binding = 1; e[1].sampler = linearSampler;
        e[2].binding = 2; e[2].textureView = tex;
        WGPUBindGroupDescriptor d;
        d.layout = layout; d.entryCount = 3; d.entries = e.ptr;
        return wgpuDeviceCreateBindGroup(ctx.getDevice(), &d);
    }

    private WGPUBindGroup makeSampleBG(WGPUBindGroupLayout layout, WGPUTextureView tex) nothrow @nogc @trusted {
        WGPUBindGroupEntry[2] e;
        e[0].binding = 0; e[0].sampler = linearSampler;
        e[1].binding = 1; e[1].textureView = tex;
        WGPUBindGroupDescriptor d;
        d.layout = layout; d.entryCount = 2; d.entries = e.ptr;
        return wgpuDeviceCreateBindGroup(ctx.getDevice(), &d);
    }

    private WGPUBindGroup makeTonemapBG(WGPUBindGroupLayout layout, WGPUBuffer ubo,
                                        WGPUTextureView scene, WGPUTextureView bloom) nothrow @nogc @trusted {
        WGPUBindGroupEntry[4] e;
        e[0].binding = 0; e[0].buffer = ubo; e[0].offset = 0; e[0].size = 16;
        e[1].binding = 1; e[1].sampler = linearSampler;
        e[2].binding = 2; e[2].textureView = scene;
        e[3].binding = 3; e[3].textureView = bloom;
        WGPUBindGroupDescriptor d;
        d.layout = layout; d.entryCount = 4; d.entries = e.ptr;
        return wgpuDeviceCreateBindGroup(ctx.getDevice(), &d);
    }

    private static WGPUBindGroupLayout makeTexUBOBGL(WGPUDevice device, bool hasUbo) @trusted {
        WGPUBindGroupLayoutEntry[3] entries;
        uint n = 0;
        if (hasUbo) {
            entries[n].binding = 0;
            entries[n].visibility = WGPUShaderStage.fragment;
            entries[n].buffer.type = WGPUBufferBindingType.uniform;
            entries[n].buffer.minBindingSize = 16;
            n++;
            entries[n].binding = 1;
            entries[n].visibility = WGPUShaderStage.fragment;
            entries[n].sampler.type = WGPUSamplerBindingType.filtering;
            n++;
            entries[n].binding = 2;
            entries[n].visibility = WGPUShaderStage.fragment;
            entries[n].texture.sampleType = WGPUTextureSampleType.float_;
            entries[n].texture.viewDimension = WGPUTextureViewDimension.dim2D;
            n++;
        } else {
            entries[n].binding = 0;
            entries[n].visibility = WGPUShaderStage.fragment;
            entries[n].sampler.type = WGPUSamplerBindingType.filtering;
            n++;
            entries[n].binding = 1;
            entries[n].visibility = WGPUShaderStage.fragment;
            entries[n].texture.sampleType = WGPUTextureSampleType.float_;
            entries[n].texture.viewDimension = WGPUTextureViewDimension.dim2D;
            n++;
        }
        WGPUBindGroupLayoutDescriptor d;
        d.entryCount = n;
        d.entries = entries.ptr;
        return wgpuDeviceCreateBindGroupLayout(device, &d);
    }

    private static WGPUBindGroupLayout makeTonemapBGL(WGPUDevice device) @trusted {
        WGPUBindGroupLayoutEntry[4] e;
        e[0].binding = 0;
        e[0].visibility = WGPUShaderStage.fragment;
        e[0].buffer.type = WGPUBufferBindingType.uniform;
        e[0].buffer.minBindingSize = 16;
        e[1].binding = 1;
        e[1].visibility = WGPUShaderStage.fragment;
        e[1].sampler.type = WGPUSamplerBindingType.filtering;
        e[2].binding = 2;
        e[2].visibility = WGPUShaderStage.fragment;
        e[2].texture.sampleType = WGPUTextureSampleType.float_;
        e[2].texture.viewDimension = WGPUTextureViewDimension.dim2D;
        e[3].binding = 3;
        e[3].visibility = WGPUShaderStage.fragment;
        e[3].texture.sampleType = WGPUTextureSampleType.float_;
        e[3].texture.viewDimension = WGPUTextureViewDimension.dim2D;
        WGPUBindGroupLayoutDescriptor d;
        d.entryCount = 4;
        d.entries = e.ptr;
        return wgpuDeviceCreateBindGroupLayout(device, &d);
    }

    private static WGPUPipelineLayout makePL(WGPUDevice device, WGPUBindGroupLayout bgl) @trusted {
        WGPUPipelineLayoutDescriptor d;
        d.bindGroupLayoutCount = 1;
        d.bindGroupLayouts = &bgl;
        return wgpuDeviceCreatePipelineLayout(device, &d);
    }

    private static WGPURenderPipeline makeFSPipeline(
        WGPUDevice device, WGPUPipelineLayout pl, WGPUShaderModule sm,
        WGPUTextureFormat colorFmt, bool additive) nothrow @nogc @trusted {

        WGPUColorTargetState ct;
        ct.format = colorFmt;
        ct.writeMask = WGPUColorWriteMask.all;
        WGPUBlendState blend;
        if (additive) {
            blend.color.operation = WGPUBlendOperation.add;
            blend.color.srcFactor = WGPUBlendFactor.one;
            blend.color.dstFactor = WGPUBlendFactor.one;
            blend.alpha.operation = WGPUBlendOperation.add;
            blend.alpha.srcFactor = WGPUBlendFactor.one;
            blend.alpha.dstFactor = WGPUBlendFactor.one;
            ct.blend = &blend;
        }

        WGPUFragmentState fs;
        fs.module_ = sm;
        fs.entryPoint = wgpuStringView("fs_main");
        fs.targetCount = 1;
        fs.targets = &ct;

        WGPURenderPipelineDescriptor desc;
        desc.layout = pl;
        desc.vertex.module_ = sm;
        desc.vertex.entryPoint = wgpuStringView("vs_main");
        desc.fragment = &fs;
        desc.primitive.topology = WGPUPrimitiveTopology.triangleList;
        desc.multisample.count = 1;
        desc.multisample.mask = ~0u;

        auto pipe = wgpuDeviceCreateRenderPipeline(device, &desc);
        if (pipe is null) fatal("Failed to create post pipeline");
        return pipe;
    }
}
