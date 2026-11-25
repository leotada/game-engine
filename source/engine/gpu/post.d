/// Post-processing: bloom, tone map (ACES/Reinhard/Linear/AgX), antialiasing, sharpening, and
/// custom fullscreen passes on an HDR scene RT.
module engine.gpu.post;

import bindings.wgpu;
import engine.core.log;
import engine.gpu.buffer : createUniformBuffer, destroyBuffer, updateBuffer;
import engine.gpu.context : GpuContext;
import engine.gpu.shader : createShaderModule, isValidUniformStruct;
public import engine.gpu.post_aa : AaMode;
import engine.gpu.post_aa : AaParams, PostAa;
import engine.gpu.post_util;
import engine.gpu.shaders;
import engine.gpu.gpu_profiler : gpuScope;
import engine.math.mat : Mat4;
import engine.scene.camera : Camera;

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
    /// `smaa`: luma difference that makes an edge (0.05 = ultra, 0.1 = high, 0.15 = low).
    float smaaThreshold = 0.1f;
    /// `cmaa2`: luma difference that makes an edge (0.05 = ultra, 0.07 = high, 0.15 = low).
    float cmaa2Threshold = 0.07f;
    /// Contrast adaptive sharpening after any AA mode (0 = pass skipped, 1 = strongest).
    float sharpness = 0.0f;

    /// AA filter in effect.
    AaMode effectiveAa() const pure nothrow @nogc {
        return aaMode == AaMode.legacy ? (fxaa ? AaMode.fxaa : AaMode.off) : aaMode;
    }
}

private enum MAX_BLOOM_MIPS = 7;
private enum MAX_CUSTOM_POST_PASSES = 16;
private enum MAX_POST_TARGETS = 8;
/// Named targets one pass can read.
enum MAX_POST_INPUTS = 4;

/// Description of a custom fullscreen pass (`Renderer.addPostPass`).
struct PostPassDesc {
    /// Fragment shader (`fs_main`); the vertex shader and bindings are added when missing.
    const(char)[] wgsl;
    size_t uniformBytes = 64;
    PostStage stage = PostStage.afterTonemap;
    /// Bind scene depth, camera and the named inputs at `@group(1)`
    /// (`common/post_scene.wgsl` is prepended). Implied by `inputs`.
    bool sceneInputs = false;
    /// Named targets read as `input0 .. input3`. Each must be the `output` of a
    /// pass added before this one. Their content is this frame's.
    const(char)[][MAX_POST_INPUTS] inputs;
    /// Named target this pass writes instead of the color chain. Empty = chain.
    /// Passes sharing one name must agree on `scale` and `format`.
    const(char)[] output;
    /// Target size divisor (1 = full resolution, 2 = half, ...). Only with `output`.
    uint scale = 1;
    /// Target format: a filterable color format. Only with `output`.
    WGPUTextureFormat format = SCENE_COLOR_FORMAT;
}

/// GPU mirror of WGSL `SceneCamera` (`common/post_scene.wgsl`).
struct PostSceneCamera {
    float[16] view;
    float[16] proj;
    float[16] viewProj;
    float[16] invView;
    float[16] invProj;
    float[16] invViewProj;
    float[4] position = 0;
    float[4] planes = [0.1f, 100.0f, 0.0f, 0.0f];
    float[4] viewport = [0.0f, 0.0f, 1.0f, 1.0f];

    static PostSceneCamera make(ref const Camera c, float[4] viewport, float time) pure nothrow @nogc {
        PostSceneCamera s;
        immutable view = Mat4.lookAt(c.position, c.target, c.up);
        immutable proj = Mat4.perspective(c.fovY, c.aspect, c.near, c.far);
        immutable vp = proj * view;
        s.view = view.m;
        s.proj = proj.m;
        s.viewProj = vp.m;
        s.invView = view.inverse().m;
        s.invProj = proj.inverse().m;
        s.invViewProj = vp.inverse().m;
        s.position = [c.position.x, c.position.y, c.position.z, time];
        s.planes = [c.near, c.far, 1, 0];
        s.viewport = viewport;
        return s;
    }
}
static assert(PostSceneCamera.sizeof == 432);
static assert(isValidUniformStruct!PostSceneCamera);

/// Formats accepted for named targets: renderable and filterable.
private bool isPostTargetFormat(WGPUTextureFormat f) pure nothrow @nogc {
    switch (f) with (WGPUTextureFormat) {
        case r8Unorm, rg8Unorm, rgba8Unorm, r16Float, rg16Float, rgba16Float: return true;
        default: return false;
    }
}

private struct PostTarget {
    char[32] name = 0;
    ubyte nameLength;
    uint scale = 1;
    WGPUTextureFormat format;
    uint users; /// passes that write it
    TexRT rt;

    const(char)[] nameOf() const return pure nothrow @nogc { return name[0 .. nameLength]; }
}

/// Expand a custom fullscreen fragment WGSL snippet by supplying the shared
/// fullscreen vertex shader and default `@group(0)` bindings when omitted.
string composeCustomPostShader(scope const(char)[] wgsl, bool sceneInputs = false) {
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
    if (sceneInputs) header ~= postSceneSource ~ "\n";
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
    bool sceneInputs;
    byte output = -1;                         /// index into `targets`, -1 = color chain
    byte[MAX_POST_INPUTS] inputs = [-1, -1, -1, -1];
    WGPUTextureFormat format;

    void release() nothrow @nogc @trusted {
        if (pipe !is null) { wgpuRenderPipelineRelease(pipe); pipe = null; }
        if (sm !is null) { wgpuShaderModuleRelease(sm); sm = null; }
        destroyBuffer(ubo);
        ubo = null;
        id = 0;
        enabled = false;
        output = -1;
        inputs = -1;
        sceneInputs = false;
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
    private bool ldrStorage; // `ldrRT` can be written by compute
    private TexRT ldrRT; // tonemap output when AA or sharpening is on
    private TexRT aaRT;  // AA output when sharpening follows
    private PostAa aa;
    private TexRT[2] hdrScratchRT;
    private TexRT[2] ldrScratchRT;
    private TexRT uiTargetRT;
    private CustomPostPass[MAX_CUSTOM_POST_PASSES] customPasses;
    private uint nextCustomPassId = 1;
    private PostTarget[MAX_POST_TARGETS] targets;
    private WGPUBindGroupLayout sceneBGL;
    private WGPUPipelineLayout scenePL;
    private WGPUBuffer sceneUBO;
    private TexRT blackRT;
    private PostSceneCamera sceneCamera;
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
        ldrStorage = false;
        aa.releaseTargets();
        aaRT.release();
        foreach (ref s; hdrScratchRT) s.release();
        foreach (ref s; ldrScratchRT) s.release();
        uiTargetRT.release();
        foreach (ref t; targets) t.rt.release();
        bloomLevels = 0;
    }

    /// Add a custom fullscreen post pass at `stage`. Returns a 1-based pass id
    /// (0 on compile failure or when the pass table is full).
    uint addPass(scope const(char)[] wgsl, size_t uniformBytes = 64,
                 PostStage stage = PostStage.afterTonemap) {
        PostPassDesc desc;
        desc.uniformBytes = uniformBytes;
        desc.stage = stage;
        return addPass(desc, wgsl);
    }

    /// Add a custom pass with scene inputs and named targets. Passes of one stage
    /// run in insertion order. Returns 0 (with a warning) when the shader does
    /// not compile or the description is not valid.
    uint addPass(scope const ref PostPassDesc desc) { return addPass(desc, desc.wgsl); }

    private uint addPass(scope const ref PostPassDesc desc, scope const(char)[] wgsl) @trusted {
        if (device is null) return 0;
        size_t slot = size_t.max;
        foreach (i, ref cp; customPasses) {
            if (cp.id == 0) { slot = i; break; }
        }
        if (slot == size_t.max) {
            warn("PostProcessor: custom pass table full (max=", MAX_CUSTOM_POST_PASSES, ")");
            return 0;
        }

        CustomPostPass p;
        p.stage = desc.stage;
        p.sceneInputs = desc.sceneInputs;
        foreach (i, name; desc.inputs) {
            if (name.length == 0) continue;
            p.sceneInputs = true;
            immutable t = findTarget(name);
            if (t < 0 || !writtenBefore(t, desc.stage)) {
                warn("PostProcessor: input '", name, "' is not written by an earlier pass");
                return 0;
            }
            p.inputs[i] = cast(byte) t;
        }
        p.format = desc.stage == PostStage.beforeTonemap ? SCENE_COLOR_FORMAT : surfaceFormat;
        if (desc.output.length) {
            foreach (i; 0 .. MAX_POST_INPUTS)
                if (desc.inputs[i] == desc.output) {
                    warn("PostProcessor: a pass cannot read its own output '", desc.output, "'");
                    return 0;
                }
            if (!isPostTargetFormat(desc.format) || desc.scale == 0) {
                warn("PostProcessor: unsupported format or scale for target '", desc.output, "'");
                return 0;
            }
            p.format = desc.format;
        } else if (desc.scale != 1 || desc.format != SCENE_COLOR_FORMAT) {
            warn("PostProcessor: scale and format need an output name");
            return 0;
        }

        immutable ulong alignedUbo = desc.uniformBytes < 16 ? 16 : ((desc.uniformBytes + 15) & ~cast(size_t) 15);
        auto sm = createShaderModule(device, composeCustomPostShader(wgsl, p.sceneInputs), "custom_post");
        if (sm is null) return 0;
        if (p.sceneInputs) ensureSceneResources();
        auto pipe = tryMakeFSPipeline(device, p.sceneInputs ? scenePL : threshPL, sm, p.format, false);
        if (pipe is null) {
            wgpuShaderModuleRelease(sm);
            return 0;
        }
        if (desc.output.length) {
            immutable t = acquireTarget(desc.output, desc.scale, desc.format);
            if (t < 0) {
                wgpuRenderPipelineRelease(pipe);
                wgpuShaderModuleRelease(sm);
                return 0;
            }
            p.output = cast(byte) t;
        }

        auto ubo = createUniformBuffer(device, alignedUbo);
        ubyte[256] zeros = 0;
        if (alignedUbo <= zeros.length)
            wgpuQueueWriteBuffer(queue, ubo, 0, zeros.ptr, cast(size_t) alignedUbo);

        p.id = nextCustomPassId++;
        p.enabled = true;
        p.sm = sm;
        p.pipe = pipe;
        p.ubo = ubo;
        p.uniformBytes = alignedUbo;
        customPasses[slot] = p;
        return p.id;
    }

    private int findTarget(scope const(char)[] name) const nothrow @nogc {
        foreach (i, ref t; targets)
            if (t.users > 0 && t.nameOf == name) return cast(int) i;
        return -1;
    }

    /// True when a pass already added writes target `t` no later than `stage`.
    private bool writtenBefore(int t, PostStage stage) const nothrow @nogc {
        foreach (ref cp; customPasses)
            if (cp.id != 0 && cp.output == t && cp.stage <= stage) return true;
        return false;
    }

    private int acquireTarget(scope const(char)[] name, uint scale, WGPUTextureFormat format) nothrow {
        immutable found = findTarget(name);
        if (found >= 0) {
            if (targets[found].scale != scale || targets[found].format != format) {
                warn("PostProcessor: target '", name, "' already exists with another scale or format");
                return -1;
            }
            targets[found].users++;
            return found;
        }
        if (name.length > PostTarget.name.length) {
            warn("PostProcessor: target name too long");
            return -1;
        }
        foreach (i, ref t; targets) {
            if (t.users > 0) continue;
            t.name[0 .. name.length] = name[];
            t.nameLength = cast(ubyte) name.length;
            t.scale = scale;
            t.format = format;
            t.users = 1;
            return cast(int) i;
        }
        warn("PostProcessor: target table full (max=", MAX_POST_TARGETS, ")");
        return -1;
    }

    /// Camera of this frame's 3D scene, read by passes with `sceneInputs`.
    void setSceneCamera(ref const PostSceneCamera c) nothrow @nogc { sceneCamera = c; }

    /// Forget the previous frame's camera (`planes.z` = 0).
    void clearSceneCamera() nothrow @nogc { sceneCamera.planes[2] = 0; }

    private void ensureSceneResources() @trusted {
        if (scenePL !is null) return;
        WGPUBindGroupLayoutEntry[2 + MAX_POST_INPUTS] e;
        foreach (i, ref x; e) {
            x.binding = cast(uint) i;
            x.visibility = WGPUShaderStage.fragment;
            if (i == 0) {
                x.buffer.type = WGPUBufferBindingType.uniform;
                x.buffer.minBindingSize = PostSceneCamera.sizeof;
            } else {
                x.texture.sampleType = i == 1 ? WGPUTextureSampleType.depth : WGPUTextureSampleType.float_;
                x.texture.viewDimension = WGPUTextureViewDimension.dim2D;
            }
        }
        WGPUBindGroupLayoutDescriptor d;
        d.entryCount = e.length;
        d.entries = e.ptr;
        sceneBGL = wgpuDeviceCreateBindGroupLayout(device, &d);
        WGPUBindGroupLayout[2] layouts = [threshBGL, sceneBGL];
        WGPUPipelineLayoutDescriptor pd;
        pd.bindGroupLayoutCount = 2;
        pd.bindGroupLayouts = layouts.ptr;
        scenePL = wgpuDeviceCreatePipelineLayout(device, &pd);
        sceneUBO = createUniformBuffer(device, PostSceneCamera.sizeof);
        blackRT = createRT(device, 1, 1, WGPUTextureFormat.rgba8Unorm); // zero-initialized
    }

    private WGPUBindGroup makeSceneBG(ref const CustomPostPass cp, WGPUTextureView depthView) nothrow @nogc @trusted {
        WGPUBindGroupEntry[2 + MAX_POST_INPUTS] e;
        foreach (i, ref x; e) {
            x.binding = cast(uint) i;
            if (i == 0) {
                x.buffer = sceneUBO;
                x.size = PostSceneCamera.sizeof;
            } else if (i == 1) {
                x.textureView = depthView;
            } else {
                immutable t = cp.inputs[i - 2];
                x.textureView = t >= 0 && targets[t].rt.view !is null ? targets[t].rt.view : blackRT.view;
            }
        }
        WGPUBindGroupDescriptor d;
        d.layout = sceneBGL;
        d.entryCount = e.length;
        d.entries = e.ptr;
        return wgpuDeviceCreateBindGroup(device, &d);
    }

    /// Run the enabled passes of `stage` from `cur`. Chain passes alternate
    /// between the two `scratch` targets; when `final_` is set the result lands
    /// there. Returns the view holding the result.
    private WGPUTextureView runCustomPasses(WGPUCommandEncoder encoder, PostStage stage, WGPUTextureView cur,
                                            ref TexRT[2] scratch, WGPUTextureView final_,
                                            WGPUTextureView depthView) nothrow @nogc @trusted {
        immutable total = countActivePasses(stage);
        uint idx = 0;
        foreach (ref cp; customPasses) {
            if (cp.id == 0 || !cp.enabled || cp.stage != stage) continue;
            idx++;
            WGPUTextureView dst;
            if (cp.output >= 0) {
                auto t = &targets[cp.output];
                if (t.rt.view is null) {
                    immutable w = width / t.scale, h = height / t.scale;
                    t.rt = createRT(device, w ? w : 1, h ? h : 1, t.format);
                }
                dst = t.rt.view;
            } else {
                // The surface cannot be sampled: only the last pass may write it.
                dst = final_ !is null && idx == total ? final_
                    : (scratch[0].view is cur ? scratch[1].view : scratch[0].view);
            }
            auto bg = makeUBOTexBG(threshBGL, cp.ubo, cp.uniformBytes, cur);
            scope(exit) wgpuBindGroupRelease(bg);
            WGPUBindGroup sceneBg = cp.sceneInputs ? makeSceneBG(cp, depthView) : null;
            scope(exit) if (sceneBg !is null) wgpuBindGroupRelease(sceneBg);
            drawPass(encoder, dst, cp.pipe, bg, true, sceneBg);
            if (cp.output < 0) cur = dst;
        }
        if (final_ !is null && cur !is final_) {
            auto bg = makeSampleBG(sampleBGL, cur);
            scope(exit) wgpuBindGroupRelease(bg);
            drawPass(encoder, final_, blitPipe, bg, true);
            cur = final_;
        }
        return cur;
    }

    /// True when an enabled pass reads the scene inputs.
    bool anySceneInputs() const nothrow @nogc {
        foreach (ref cp; customPasses)
            if (cp.id != 0 && cp.enabled && cp.sceneInputs) return true;
        return false;
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
            auto sm = createShaderModule(device, composeCustomPostShader(wgsl, cp.sceneInputs), "reload_custom_post");
            if (sm is null) return false;
            auto pipe = tryMakeFSPipeline(device, cp.sceneInputs ? scenePL : threshPL, sm, cp.format, false);
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
        foreach (i, ref cp; customPasses) {
            if (cp.id != id) continue;
            if (cp.output >= 0) {
                auto t = &targets[cp.output];
                if (--t.users == 0) {
                    t.rt.release();
                    // Readers fall back to black.
                    foreach (ref other; customPasses)
                        foreach (ref input; other.inputs) if (input == cp.output) input = -1;
                }
            }
            cp.release();
            // Close the gap: passes keep running in insertion order.
            foreach (k; i + 1 .. MAX_CUSTOM_POST_PASSES) {
                customPasses[k - 1] = customPasses[k];
                customPasses[k] = CustomPostPass.init;
            }
            return;
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
                 WGPUTextureView surfaceView,
                 WGPUTextureView depthView = null) nothrow @nogc @trusted {
        if (width == 0 || height == 0) return;
        if (anySceneInputs()) updateBuffer(queue, sceneUBO, (&sceneCamera)[0 .. 1]);

        WGPUTextureView sceneHdrIn = hdrView;
        immutable uint nBefore = countActivePasses(PostStage.beforeTonemap);
        if (nBefore > 0) {
            auto g = gpuScope!"gpu.post.customBeforeTonemap"(encoder);
            ensureHdrScratch();
            sceneHdrIn = runCustomPasses(encoder, PostStage.beforeTonemap, hdrView, hdrScratchRT, null, depthView);
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
        if (mode == AaMode.cmaa2 && !ldrStorage) {
            ldrRT.release();
            ldrRT = createRT(device, width, height, WGPUTextureFormat.rgba8Unorm, WGPUTextureUsage.storageBinding);
            ldrStorage = true;
        }
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
            runCustomPasses(encoder, PostStage.afterTonemap, ldrScratchRT[0].view, ldrScratchRT, surfaceView, depthView);
        }
    }

    /// AA filter on `ldrRT`, then sharpening, into `target` (display format).
    private void runAa(WGPUCommandEncoder encoder, AaMode mode, bool sharpen,
                       WGPUTextureView target) nothrow @nogc @trusted {
        aa.begin(AaParams(settings.fxaaSubpix, settings.sharpness, settings.fxaaEdgeThreshold));
        auto src = ldrRT.view;
        if (mode != AaMode.off) {
            if (sharpen && mode != AaMode.cmaa2 && aaRT.view is null)
                aaRT = createRT(device, width, height, WGPUTextureFormat.rgba8Unorm);
            auto dst = mode == AaMode.cmaa2 ? src : sharpen ? aaRT.view : target;
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
                case AaMode.smaa:
                    aa.smaa(encoder, src, dst, !sharpen, width, height, settings.smaaThreshold);
                    break;
                case AaMode.cmaa2:
                    aa.cmaa2(encoder, src, width, height, settings.cmaa2Threshold);
                    if (!sharpen) {
                        auto blBG = makeSampleBG(sampleBGL, src);
                        scope(exit) wgpuBindGroupRelease(blBG);
                        auto gb = gpuScope!"gpu.post.cmaa2.copy"(encoder);
                        drawPass(encoder, target, blitPipe, blBG, true);
                    }
                    break;
            }
            src = dst;
        }
        if (sharpen) aa.sharpen(encoder, src, target, true);
    }

    /// Run enabled `afterUi` passes reading `uiTargetRT` and writing to `surfaceView`.
    void executeAfterUi(WGPUCommandEncoder encoder, WGPUTextureView surfaceView,
                        WGPUTextureView depthView = null) nothrow @nogc @trusted {
        if (width == 0 || height == 0 || uiTargetRT.view is null) return;
        immutable uint nUi = countActivePasses(PostStage.afterUi);
        if (nUi == 0) return;

        ensureLdrScratch();
        auto g = gpuScope!"gpu.post.afterUi"(encoder);
        runCustomPasses(encoder, PostStage.afterUi, uiTargetRT.view, ldrScratchRT, surfaceView, depthView);
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
        relPL(scenePL);
        relPL(threshPL); relPL(samplePL); relPL(tonemapPL);

        void relBGL(ref WGPUBindGroupLayout p) {
            if (p !is null) { wgpuBindGroupLayoutRelease(p); p = null; }
        }
        relBGL(sceneBGL);
        blackRT.release();
        destroyBuffer(sceneUBO);
        sceneUBO = null;
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

    // Scene inputs are declared once, only on request.
    assert(!composed.canFind("sceneDepthTex"));
    assert(composeCustomPostShader(vignette, true).canFind("var sceneDepthTex: texture_depth_2d"));
    PostPassDesc pd;
    assert(pd.scale == 1 && pd.format == SCENE_COLOR_FORMAT && !pd.sceneInputs && pd.output.length == 0);
    assert(isPostTargetFormat(WGPUTextureFormat.r8Unorm) && !isPostTargetFormat(WGPUTextureFormat.r32Float));

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
