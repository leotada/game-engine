/// Post-processing: bloom, tone map (ACES/Reinhard/Linear/AgX), antialiasing, sharpening, and
/// custom fullscreen passes on an HDR scene RT.
module engine.gpu.post;

import bindings.wgpu;
import engine.core.log;
import engine.gpu.buffer : createUniformBuffer, destroyBuffer, updateBuffer;
import engine.gpu.context : GpuContext;
import engine.gpu.shader : createShaderModule;
public import engine.gpu.post_aa : AaMode;
import engine.gpu.post_aa : AaParams, PostAa;
import engine.gpu.post_util;
import engine.gpu.shaders;
import engine.gpu.gpu_profiler : gpuScope;

@safe:

/// Color format for the offscreen scene / HDR post inputs.
enum WGPUTextureFormat SCENE_COLOR_FORMAT = WGPUTextureFormat.rgba16Float;

/// Insertion point for a custom fullscreen post pass.
enum PostStage : ubyte {
    /// Runs on linear HDR color (`SCENE_COLOR_FORMAT`) before bloom & tonemap.
    beforeTonemap,
    /// Runs on LDR surface color after tonemap/FXAA and before UI rendering.
    afterTonemap,
    /// Runs on LDR surface color after UI rendering (affects HUD as well).
    afterUi,
}

/// Encoding of the tone-mapped image for the display.
enum OutputTransfer : ubyte {
    /// `pow(x, 1 / 2.2)`.
    gamma22,
    /// Exact sRGB curve: an unlit sRGB texture returns its own codes.
    srgb,
}

/// Runtime toggles for the post stack. Owned by `Renderer`.
struct PostSettings {
    float exposure = 1.0f;
    bool bloom = true;
    bool fxaa = true;
    /// 0 = ACES, 1 = Reinhard, 2 = linear (clamp), 3 = AgX.
    int tonemapMode = 0;
    /// Composite bloom after tone mapping as `1 - (1 - scene)(1 - bloom)`
    /// instead of adding it to the HDR scene before tone mapping.
    bool bloomScreen = false;
    // Visible bloom with Karis/clamp keeping fireflies in check.
    float bloomThreshold = 1.2f;
    float bloomKnee = 0.7f;
    float bloomStrength = 0.12f;
    float bloomClamp = 8.0f;
    /// Number of bloom mip levels used (clamped to 3..7).
    int bloomRadius = 5;
    /// Post-tonemap color adjustments (1.0 = neutral).
    float saturation = 1.0f;
    float contrast = 1.0f;
    /// Display encoding. Use `srgb` together with sRGB color textures.
    OutputTransfer outputTransfer = OutputTransfer.gamma22;
    /// Antialiasing filter. `legacy` follows `fxaa`.
    AaMode aaMode = AaMode.legacy;
    /// `fxaaQuality`: sub-pixel smoothing (0 = edges only, 1 = softest).
    float fxaaSubpix = 0.5f;
    /// `fxaaQuality`: minimum local contrast, relative to the local maximum.
    float fxaaEdgeThreshold = 0.125f;
    /// Contrast adaptive sharpening after any AA mode (0 = pass skipped, 1 = strongest).
    float sharpness = 0.0f;

    /// AA filter in effect.
    AaMode effectiveAa() const pure nothrow @nogc {
        return aaMode == AaMode.legacy ? (fxaa ? AaMode.fxaa : AaMode.off) : aaMode;
    }
}

private enum MAX_BLOOM_MIPS = 7;
private enum MAX_CUSTOM_POST_PASSES = 16;

/// Expand a custom fullscreen fragment WGSL snippet by supplying the shared
/// fullscreen vertex shader and default `@group(0)` bindings when omitted.
string composeCustomPostShader(scope const(char)[] wgsl) {
    import std.algorithm.searching : canFind;
    import engine.hotreload.shader_source : preprocessShader;

    string src = wgsl.idup;
    if (src.canFind("#include") || src.canFind("#define")) {
        auto prep = preprocessShader(src, "custom_post.wgsl");
        if (prep.success) src = prep.code;
    }

    string header;
    if (!src.canFind("@vertex"))
        header ~= fullscreenVsSource ~ "\n";
    if (!src.canFind("@group(0)")) {
        header ~= q{
struct PostParams {
    p0: vec4<f32>,
    p1: vec4<f32>,
    p2: vec4<f32>,
    p3: vec4<f32>,
};
@group(0) @binding(0) var<uniform> params: PostParams;
@group(0) @binding(1) var srcSamp: sampler;
@group(0) @binding(2) var srcTex: texture_2d<f32>;
};
    }
    return header.length ? (header ~ "\n" ~ src) : src;
}

private struct CustomPostPass {
    uint id = 0;
    PostStage stage = PostStage.afterTonemap;
    bool enabled = true;
    WGPUShaderModule sm;
    WGPURenderPipeline pipe;
    WGPUBuffer ubo;
    ulong uniformBytes = 64;

    void release() nothrow @nogc @trusted {
        if (pipe !is null) { wgpuRenderPipelineRelease(pipe); pipe = null; }
        if (sm !is null) { wgpuShaderModuleRelease(sm); sm = null; }
        destroyBuffer(ubo);
        ubo = null;
        id = 0;
        enabled = false;
    }
}

/// Fullscreen post pipelines and transient bloom / LDR targets.
struct PostProcessor {
    private WGPUDevice device;
    private WGPUQueue  queue;
    private WGPUSampler linearSampler;
    private WGPUBuffer thresholdUBO;
    private WGPUBuffer tonemapUBO;

    private WGPUShaderModule threshSM, downKarisSM, downSM, upSM, tonemapSM, fxaaSM, blitSM;
    private WGPUBindGroupLayout threshBGL, sampleBGL, tonemapBGL;
    private WGPUPipelineLayout threshPL, samplePL, tonemapPL;
    private WGPURenderPipeline threshPipe, downKarisPipe, downPipe, upPipe, upAddPipe;
    private WGPURenderPipeline tonemapPipe, fxaaPipe, fxaaLdrPipe, blitPipe;

    private TexRT[MAX_BLOOM_MIPS] bloomMips;
    private TexRT ldrRT; // tonemap output when AA or sharpening is on
    private TexRT aaRT;  // AA output when sharpening follows
    private PostAa aa;
    private TexRT[2] hdrScratchRT;
    private TexRT[2] ldrScratchRT;
    private TexRT uiTargetRT;
    private CustomPostPass[MAX_CUSTOM_POST_PASSES] customPasses;
    private uint nextCustomPassId = 1;
    private uint bloomLevels = 0;
    private uint width, height;
    private WGPUTextureFormat surfaceFormat;

    PostSettings settings;

    @disable this(this);

    private WGPURenderPipeline tonemapToSurfacePipe;

    static PostProcessor create(ref GpuContext gpu, WGPUTextureFormat surfFmt) @trusted {
        PostProcessor p;
        p.device = gpu.getDevice();
        p.queue = gpu.getQueue();
        p.surfaceFormat = surfFmt;
        p.settings = PostSettings.init;
        p.tonemapToSurfacePipe = null;
        auto device = p.device;

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
        p.tonemapUBO = createUniformBuffer(device, 32);

        p.threshSM = createShaderModule(device, bloomThresholdShaderSource);
        p.downKarisSM = createShaderModule(device, bloomDownsampleKarisShaderSource);
        p.downSM = createShaderModule(device, bloomDownsampleShaderSource);
        p.upSM = createShaderModule(device, bloomUpsampleShaderSource);
        p.tonemapSM = createShaderModule(device, tonemapShaderSource);
        p.fxaaSM = createShaderModule(device, fxaaShaderSource);
        p.blitSM = createShaderModule(device, blitShaderSource);

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
        p.aa.setup(device, p.queue, p.linearSampler, p.threshBGL, p.threshPL, surfFmt);

        return p;
    }

    private void rebuildPresentPipelines(WGPUTextureFormat surfFmt) @trusted {
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
            device, tonemapPL, tonemapSM, surfaceFormat, false);
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
            bloomMips[i] = createRT(device, bw, bh, SCENE_COLOR_FORMAT);
            bloomLevels++;
            bw = bw > 1 ? bw / 2 : 1;
            bh = bh > 1 ? bh / 2 : 1;
        }
        ldrRT = createRT(device, w, h, WGPUTextureFormat.rgba8Unorm);
        ensureTonemapSurfacePipe();
    }

    private void releaseTargets() nothrow @nogc {
        foreach (ref m; bloomMips) m.release();
        ldrRT.release();
        aaRT.release();
        foreach (ref s; hdrScratchRT) s.release();
        foreach (ref s; ldrScratchRT) s.release();
        uiTargetRT.release();
        bloomLevels = 0;
    }

    /// Add a custom fullscreen post pass at `stage`. Returns a 1-based pass id
    /// (0 on compile failure or when the pass table is full).
    uint addPass(scope const(char)[] wgsl, size_t uniformBytes = 64,
                 PostStage stage = PostStage.afterTonemap) @trusted {
        if (device is null) return 0;
        size_t slot = size_t.max;
        foreach (i, ref cp; customPasses) {
            if (cp.id == 0) { slot = i; break; }
        }
        if (slot == size_t.max) {
            warn("PostProcessor: custom pass table full (max=", MAX_CUSTOM_POST_PASSES, ")");
            return 0;
        }

        immutable ulong alignedUbo = uniformBytes < 16 ? 16 : ((uniformBytes + 15) & ~cast(size_t) 15);
        immutable fullWgsl = composeCustomPostShader(wgsl);
        auto sm = createShaderModule(device, fullWgsl, "custom_post");
        if (sm is null) return 0;

        immutable targetFmt = stage == PostStage.beforeTonemap ? SCENE_COLOR_FORMAT : surfaceFormat;
        auto pipe = tryMakeFSPipeline(device, threshPL, sm, targetFmt, false);
        if (pipe is null) {
            wgpuShaderModuleRelease(sm);
            return 0;
        }

        auto ubo = createUniformBuffer(device, alignedUbo);
        ubyte[256] zeros = 0;
        if (alignedUbo <= zeros.length)
            wgpuQueueWriteBuffer(queue, ubo, 0, zeros.ptr, cast(size_t) alignedUbo);

        CustomPostPass p;
        p.id = nextCustomPassId++;
        p.stage = stage;
        p.enabled = true;
        p.sm = sm;
        p.pipe = pipe;
        p.ubo = ubo;
        p.uniformBytes = alignedUbo;
        customPasses[slot] = p;
        return p.id;
    }

    void updatePassParams(uint id, scope const(void)[] data) nothrow @nogc @trusted {
        if (id == 0 || data.length == 0) return;
        foreach (ref cp; customPasses) {
            if (cp.id == id && cp.ubo !is null) {
                immutable n = data.length < cp.uniformBytes ? data.length : cast(size_t) cp.uniformBytes;
                wgpuQueueWriteBuffer(queue, cp.ubo, 0, data.ptr, n);
                return;
            }
        }
    }

    void setPassEnabled(uint id, bool enabled) nothrow @nogc {
        if (id == 0) return;
        foreach (ref cp; customPasses) {
            if (cp.id == id) { cp.enabled = enabled; return; }
        }
    }

    bool reloadPass(uint id, scope const(char)[] wgsl) @trusted {
        if (id == 0 || device is null) return false;
        foreach (ref cp; customPasses) {
            if (cp.id != id) continue;
            immutable fullWgsl = composeCustomPostShader(wgsl);
            auto sm = createShaderModule(device, fullWgsl, "reload_custom_post");
            if (sm is null) return false;
            immutable targetFmt = cp.stage == PostStage.beforeTonemap ? SCENE_COLOR_FORMAT : surfaceFormat;
            auto pipe = tryMakeFSPipeline(device, threshPL, sm, targetFmt, false);
            if (pipe is null) {
                wgpuShaderModuleRelease(sm);
                return false;
            }
            wgpuRenderPipelineRelease(cp.pipe);
            wgpuShaderModuleRelease(cp.sm);
            cp.pipe = pipe;
            cp.sm = sm;
            return true;
        }
        return false;
    }

    void removePass(uint id) nothrow @nogc {
        if (id == 0) return;
        foreach (ref cp; customPasses) {
            if (cp.id == id) { cp.release(); return; }
        }
    }

    bool hasActiveAfterUiPasses() const nothrow @nogc {
        foreach (ref cp; customPasses) {
            if (cp.id != 0 && cp.enabled && cp.stage == PostStage.afterUi)
                return true;
        }
        return false;
    }

    WGPUTextureView ensureUiTargetView() nothrow @nogc {
        if (uiTargetRT.view is null && width > 0 && height > 0)
            uiTargetRT = createRT(device, width, height, surfaceFormat);
        return uiTargetRT.view;
    }

    private uint countActivePasses(PostStage stage) const nothrow @nogc {
        uint n = 0;
        foreach (ref cp; customPasses) {
            if (cp.id != 0 && cp.enabled && cp.stage == stage) n++;
        }
        return n;
    }

    private void ensureHdrScratch() nothrow @nogc {
        if (width == 0 || height == 0) return;
        foreach (ref rt; hdrScratchRT) {
            if (rt.view is null) rt = createRT(device, width, height, SCENE_COLOR_FORMAT);
        }
    }

    private void ensureLdrScratch() nothrow @nogc {
        if (width == 0 || height == 0) return;
        foreach (ref rt; ldrScratchRT) {
            if (rt.view is null) rt = createRT(device, width, height, surfaceFormat);
        }
    }

    /// Run beforeTonemap custom passes → bloom → tone map → FXAA → afterTonemap
    /// custom passes into `surfaceView`. Uses `encoder` (no open pass).
    void execute(WGPUCommandEncoder encoder,
                 WGPUTextureView hdrView,
                 WGPUTextureView surfaceView) nothrow @nogc @trusted {
        if (width == 0 || height == 0) return;

        WGPUTextureView sceneHdrIn = hdrView;
        immutable uint nBefore = countActivePasses(PostStage.beforeTonemap);
        if (nBefore > 0) {
            auto g = gpuScope!"gpu.post.customBeforeTonemap"(encoder);
            ensureHdrScratch();
            uint idx = 0;
            foreach (ref cp; customPasses) {
                if (cp.id == 0 || !cp.enabled || cp.stage != PostStage.beforeTonemap) continue;
                auto dst = hdrScratchRT[idx & 1].view;
                auto bg = makeUBOTexBG(threshBGL, cp.ubo, cp.uniformBytes, sceneHdrIn);
                scope(exit) wgpuBindGroupRelease(bg);
                drawPass(encoder, dst, cp.pipe, bg, true);
                sceneHdrIn = dst;
                idx++;
            }
        }

        immutable int clampedRadius = settings.bloomRadius < 3
            ? 3 : (settings.bloomRadius > MAX_BLOOM_MIPS ? MAX_BLOOM_MIPS : settings.bloomRadius);
        immutable uint activeLevels = bloomLevels < cast(uint) clampedRadius
            ? bloomLevels : cast(uint) clampedRadius;
        immutable useBloom = settings.bloom && activeLevels > 0;
        if (useBloom) {
            auto gBloom = gpuScope!"gpu.post.bloom"(encoder);
            // Threshold → mip0 (soft knee + bloomClamp)
            {
                float[4] params = [
                    settings.bloomThreshold,
                    settings.bloomKnee,
                    settings.bloomClamp,
                    0,
                ];
                updateBuffer(queue, thresholdUBO, params[]);
                auto bg = makeUBOTexBG(threshBGL, thresholdUBO, 16, sceneHdrIn);
                scope(exit) wgpuBindGroupRelease(bg);
                drawPass(encoder, bloomMips[0].view, threshPipe, bg, true);
            }
            // First downsample: Karis (firefly suppression)
            if (activeLevels > 1) {
                auto bg = makeSampleBG(sampleBGL, bloomMips[0].view);
                scope(exit) wgpuBindGroupRelease(bg);
                drawPass(encoder, bloomMips[1].view, downKarisPipe, bg, true);
            }
            // Further downsamples: box filter
            foreach (i; 1 .. activeLevels - 1) {
                auto bg = makeSampleBG(sampleBGL, bloomMips[i].view);
                scope(exit) wgpuBindGroupRelease(bg);
                drawPass(encoder, bloomMips[i + 1].view, downPipe, bg, true);
            }
            // Upsample additive
            foreach_reverse (i; 0 .. activeLevels - 1) {
                auto bg = makeSampleBG(sampleBGL, bloomMips[i + 1].view);
                scope(exit) wgpuBindGroupRelease(bg);
                drawPass(encoder, bloomMips[i].view, upAddPipe, bg, false);
            }
        } else if (bloomLevels > 0) {
            // Clear mip0 so tonemap samples black bloom
            clearRT(encoder, bloomMips[0].view);
        }

        float strength = useBloom ? settings.bloomStrength : 0.0f;
        float[8] tm = [
            settings.exposure,
            strength,
            cast(float) settings.tonemapMode,
            settings.bloomScreen ? 1.0f : 0.0f,
            settings.saturation,
            settings.contrast,
            cast(float) settings.outputTransfer,
            0.0f,
        ];
        updateBuffer(queue, tonemapUBO, tm[]);

        auto bloomView = bloomLevels > 0 ? bloomMips[0].view : sceneHdrIn;
        auto tmBG = makeTonemapBG(tonemapBGL, tonemapUBO, sceneHdrIn, bloomView);
        scope(exit) wgpuBindGroupRelease(tmBG);

        immutable uint nAfter = countActivePasses(PostStage.afterTonemap);
        WGPUTextureView ldrTarget = surfaceView;
        if (nAfter > 0) {
            ensureLdrScratch();
            ldrTarget = ldrScratchRT[0].view;
        }

        immutable mode = settings.effectiveAa();
        immutable sharpen = settings.sharpness > 0;
        if (mode == AaMode.off && !sharpen) {
            ensureTonemapSurfacePipe();
            auto g = gpuScope!"gpu.post.tonemap"(encoder);
            drawPass(encoder, ldrTarget, tonemapToSurfacePipe, tmBG, true);
        } else {
            {
                auto g = gpuScope!"gpu.post.tonemap"(encoder);
                drawPass(encoder, ldrRT.view, tonemapPipe, tmBG, true);
            }
            runAa(encoder, mode, sharpen, ldrTarget);
        }

        if (nAfter > 0) {
            auto g = gpuScope!"gpu.post.customAfterTonemap"(encoder);
            WGPUTextureView cur = ldrScratchRT[0].view;
            uint idx = 0;
            foreach (ref cp; customPasses) {
                if (cp.id == 0 || !cp.enabled || cp.stage != PostStage.afterTonemap) continue;
                immutable bool isLast = (idx + 1 == nAfter);
                auto dst = isLast ? surfaceView : ldrScratchRT[(idx + 1) & 1].view;
                auto bg = makeUBOTexBG(threshBGL, cp.ubo, cp.uniformBytes, cur);
                scope(exit) wgpuBindGroupRelease(bg);
                drawPass(encoder, dst, cp.pipe, bg, true);
                cur = dst;
                idx++;
            }
        }
    }

    /// AA filter on `ldrRT`, then sharpening, into `target` (display format).
    private void runAa(WGPUCommandEncoder encoder, AaMode mode, bool sharpen,
                       WGPUTextureView target) nothrow @nogc @trusted {
        aa.begin(AaParams(settings.fxaaSubpix, settings.sharpness, settings.fxaaEdgeThreshold));
        auto src = ldrRT.view;
        if (mode != AaMode.off) {
            if (sharpen && aaRT.view is null)
                aaRT = createRT(device, width, height, WGPUTextureFormat.rgba8Unorm);
            auto dst = sharpen ? aaRT.view : target;
            final switch (mode) {
                case AaMode.legacy:
                case AaMode.off:
                    assert(0);
                case AaMode.fxaa:
                    if (sharpen && fxaaLdrPipe is null)
                        fxaaLdrPipe = makeFSPipeline(device, samplePL, fxaaSM, WGPUTextureFormat.rgba8Unorm, false);
                    auto fxBG = makeSampleBG(sampleBGL, src);
                    scope(exit) wgpuBindGroupRelease(fxBG);
                    auto g = gpuScope!"gpu.post.fxaa"(encoder);
                    drawPass(encoder, dst, sharpen ? fxaaLdrPipe : fxaaPipe, fxBG, true);
                    break;
                case AaMode.fxaaQuality:
                    aa.fxaaQuality(encoder, src, dst, !sharpen);
                    break;
            }
            src = dst;
        }
        if (sharpen) aa.sharpen(encoder, src, target, true);
    }

    /// Run enabled `afterUi` passes reading `uiTargetRT` and writing to `surfaceView`.
    void executeAfterUi(WGPUCommandEncoder encoder, WGPUTextureView surfaceView) nothrow @nogc @trusted {
        if (width == 0 || height == 0 || uiTargetRT.view is null) return;
        immutable uint nUi = countActivePasses(PostStage.afterUi);
        if (nUi == 0) return;

        ensureLdrScratch();
        auto g = gpuScope!"gpu.post.afterUi"(encoder);
        WGPUTextureView cur = uiTargetRT.view;
        uint idx = 0;
        foreach (ref cp; customPasses) {
            if (cp.id == 0 || !cp.enabled || cp.stage != PostStage.afterUi) continue;
            immutable bool isLast = (idx + 1 == nUi);
            auto dst = isLast ? surfaceView : ldrScratchRT[idx & 1].view;
            auto bg = makeUBOTexBG(threshBGL, cp.ubo, cp.uniformBytes, cur);
            scope(exit) wgpuBindGroupRelease(bg);
            drawPass(encoder, dst, cp.pipe, bg, true);
            cur = dst;
            idx++;
        }
    }

    void destroy() nothrow @nogc @trusted {
        foreach (ref cp; customPasses) cp.release();
        releaseTargets();
        if (linearSampler !is null) { wgpuSamplerRelease(linearSampler); linearSampler = null; }
        if (thresholdUBO !is null) { wgpuBufferRelease(thresholdUBO); thresholdUBO = null; }
        if (tonemapUBO !is null) { wgpuBufferRelease(tonemapUBO); tonemapUBO = null; }

        void relPipe(ref WGPURenderPipeline p) {
            if (p !is null) { wgpuRenderPipelineRelease(p); p = null; }
        }
        relPipe(threshPipe); relPipe(downKarisPipe); relPipe(downPipe); relPipe(upPipe); relPipe(upAddPipe);
        relPipe(tonemapPipe); relPipe(fxaaPipe); relPipe(fxaaLdrPipe);
        relPipe(blitPipe); relPipe(tonemapToSurfacePipe);
        aa.destroy();

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
        return wgpuDeviceCreateBindGroup(device, &d);
    }

    private WGPUBindGroup makeSampleBG(WGPUBindGroupLayout layout, WGPUTextureView tex) nothrow @nogc @trusted {
        WGPUBindGroupEntry[2] e;
        e[0].binding = 0; e[0].sampler = linearSampler;
        e[1].binding = 1; e[1].textureView = tex;
        WGPUBindGroupDescriptor d;
        d.layout = layout; d.entryCount = 2; d.entries = e.ptr;
        return wgpuDeviceCreateBindGroup(device, &d);
    }

    private WGPUBindGroup makeTonemapBG(WGPUBindGroupLayout layout, WGPUBuffer ubo,
                                        WGPUTextureView scene, WGPUTextureView bloom) nothrow @nogc @trusted {
        WGPUBindGroupEntry[4] e;
        e[0].binding = 0; e[0].buffer = ubo; e[0].offset = 0; e[0].size = 32;
        e[1].binding = 1; e[1].sampler = linearSampler;
        e[2].binding = 2; e[2].textureView = scene;
        e[3].binding = 3; e[3].textureView = bloom;
        WGPUBindGroupDescriptor d;
        d.layout = layout; d.entryCount = 4; d.entries = e.ptr;
        return wgpuDeviceCreateBindGroup(device, &d);
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
        e[0].buffer.minBindingSize = 32;
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

    /// Transactional shader reload for post-processing shaders.
    bool reloadShader(scope const(char)[] shaderName, scope const(char)[] newWgsl) nothrow @nogc @trusted {
        if (device is null) return false;
        auto newModule = createShaderModule(device, newWgsl, "reload_post");
        if (newModule is null) return false;

        void relPipe(ref WGPURenderPipeline p) {
            if (p !is null) { wgpuRenderPipelineRelease(p); p = null; }
        }
        void relSM(ref WGPUShaderModule m) {
            if (m !is null) { wgpuShaderModuleRelease(m); m = null; }
        }

        if (shaderName == "bloom_threshold" || shaderName == "post_bloom_threshold") {
            auto pipe = tryMakeFSPipeline(device, threshPL, newModule, SCENE_COLOR_FORMAT, false);
            if (pipe is null) { relSM(newModule); return false; }
            relPipe(threshPipe); relSM(threshSM);
            threshPipe = pipe; threshSM = newModule;
            return true;
        } else if (shaderName == "bloom_down_karis" || shaderName == "post_bloom_down_karis") {
            auto pipe = tryMakeFSPipeline(device, samplePL, newModule, SCENE_COLOR_FORMAT, false);
            if (pipe is null) { relSM(newModule); return false; }
            relPipe(downKarisPipe); relSM(downKarisSM);
            downKarisPipe = pipe; downKarisSM = newModule;
            return true;
        } else if (shaderName == "bloom_down" || shaderName == "post_bloom_down") {
            auto pipe = tryMakeFSPipeline(device, samplePL, newModule, SCENE_COLOR_FORMAT, false);
            if (pipe is null) { relSM(newModule); return false; }
            relPipe(downPipe); relSM(downSM);
            downPipe = pipe; downSM = newModule;
            return true;
        } else if (shaderName == "bloom_up" || shaderName == "post_bloom_up") {
            auto pipe = tryMakeFSPipeline(device, samplePL, newModule, SCENE_COLOR_FORMAT, false);
            auto pipeAdd = tryMakeFSPipeline(device, samplePL, newModule, SCENE_COLOR_FORMAT, true);
            if (pipe is null || pipeAdd is null) {
                relPipe(pipe); relPipe(pipeAdd); relSM(newModule);
                return false;
            }
            relPipe(upPipe); relPipe(upAddPipe); relSM(upSM);
            upPipe = pipe; upAddPipe = pipeAdd; upSM = newModule;
            return true;
        } else if (shaderName == "tonemap" || shaderName == "post_tonemap") {
            auto pipe = tryMakeFSPipeline(device, tonemapPL, newModule, WGPUTextureFormat.rgba8Unorm, false);
            auto pipeSurf = tryMakeFSPipeline(device, tonemapPL, newModule, surfaceFormat, false);
            if (pipe is null || pipeSurf is null) {
                relPipe(pipe); relPipe(pipeSurf); relSM(newModule);
                return false;
            }
            relPipe(tonemapPipe); relPipe(tonemapToSurfacePipe); relSM(tonemapSM);
            tonemapPipe = pipe; tonemapToSurfacePipe = pipeSurf; tonemapSM = newModule;
            return true;
        } else if (shaderName == "fxaa" || shaderName == "post_fxaa") {
            auto pipe = tryMakeFSPipeline(device, samplePL, newModule, surfaceFormat, false);
            if (pipe is null) { relSM(newModule); return false; }
            relPipe(fxaaPipe); relPipe(fxaaLdrPipe); relSM(fxaaSM);
            fxaaPipe = pipe; fxaaSM = newModule;
            return true;
        } else if (shaderName == "blit" || shaderName == "post_blit") {
            auto pipe = tryMakeFSPipeline(device, samplePL, newModule, surfaceFormat, false);
            if (pipe is null) { relSM(newModule); return false; }
            relPipe(blitPipe); relSM(blitSM);
            blitPipe = pipe; blitSM = newModule;
            return true;
        } else if (aa.reload(shaderName, newModule)) {
            return true;
        }

        relSM(newModule);
        return false;
    }

}

@safe unittest {
    import std.algorithm.searching : canFind;

    // 5-line fragment shader automatically gets fullscreen_vs and @group(0).
    enum vignette = q{
        @fragment
        fn fs_main(@location(0) uv: vec2<f32>) -> @location(0) vec4<f32> {
            let c = textureSample(srcTex, srcSamp, uv).rgb;
            return vec4<f32>(c * params.p0.x, 1.0);
        }
    };
    auto composed = composeCustomPostShader(vignette);
    assert(composed.canFind("fn vs_main"));
    assert(composed.canFind("@group(0) @binding(0)"));
    assert(composed.canFind("fn fs_main"));

    // Defaults remain backward-compatible.
    PostSettings ps;
    assert(ps.tonemapMode == 0);
    assert(ps.bloomRadius == 5);
    assert(ps.saturation == 1.0f);
    assert(ps.contrast == 1.0f);
    assert(ps.outputTransfer == OutputTransfer.gamma22 && ps.sharpness == 0);

    // `legacy` follows the `fxaa` toggle; explicit modes ignore it.
    assert(ps.effectiveAa() == AaMode.fxaa);
    ps.fxaa = false;
    assert(ps.effectiveAa() == AaMode.off);
    ps.aaMode = AaMode.fxaaQuality;
    assert(ps.effectiveAa() == AaMode.fxaaQuality);
}
