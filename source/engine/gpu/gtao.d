/// Ground-truth ambient occlusion between the opaque and transparent passes of
/// a 3D scene. Opaque pipelines store `1 - ambient share` in the scene alpha;
/// the composite darkens only that share. No depth prepass, no temporal data.
module engine.gpu.gtao;

import bindings.wgpu;
import engine.core.log;
import engine.devtools.profiler : profileZone;
import engine.gpu.gpu_profiler : gpuScope;
import engine.gpu.post_util;
import engine.gpu.shader : createShaderModule, isValidUniformStruct;
import engine.gpu.shaders : gtaoShaderSource;
import engine.scene.camera : Camera;
import core.stdc.math : tanf;

@safe:

/// Search effort (slices per pixel x samples per slice).
enum AoQuality : ubyte {
    low,    /// 1 x 4
    medium, /// 2 x 6
    high,   /// 3 x 8
    ultra,  /// 5 x 10
}

/// Ambient occlusion of opaque surfaces (`Renderer.ambientOcclusion`). Off by default.
struct AoSettings {
    bool enabled = false;
    /// Reach of the occlusion in world units.
    float radius = 1.0f;
    /// Exponent of the occlusion: 0 = none, 1 = physical, above = darker.
    float intensity = 1.0f;
    AoQuality quality = AoQuality.medium;
    /// Explicit slices (max 32) and samples per side (max 64); 0 = from `quality`.
    ubyte slices = 0, steps = 0;
    /// Compute at half resolution with a depth-aware upsample.
    bool halfResolution = false;
    /// Also apply to the default render state (`BlendMode.alpha` with depth
    /// write), drawn without blending. Set it when those materials have no
    /// partial alpha. `BlendMode.opaque`, `alphaMask` and terrain always take part.
    bool treatDefaultBlendAsOpaque = false;
}

private enum AO_MIPS = 5;
private enum AO_MAX_SCENES = 4; /// scenes per frame (split screen)
private enum uint AO_UBO_STRIDE = 256;
private enum LIN_FORMAT = WGPUTextureFormat.r32Float;
/// Float: one pixel can exceed 1 with few slices; only the filtered value is clamped.
private enum AO_FORMAT = WGPUTextureFormat.r16Float;

/// GPU mirror of WGSL `AoParams` (`gtao.wgsl`).
private struct AoParams {
    float[4] viewport;
    float[4] proj;
    float[4] a;
    float[4] b;

    static AoParams make(ref const AoSettings s, ref const Camera c, float[4] vp) nothrow @nogc @trusted {
        immutable t = tanf(c.fovY * 0.5f);
        static immutable float[2][4] effort = [[1, 2], [2, 3], [3, 4], [5, 5]];
        AoParams p;
        p.viewport = vp;
        p.proj = [t * c.aspect, t, c.near, c.far];
        p.a = [s.radius > 0 ? s.radius : 0, s.intensity > 0 ? s.intensity : 0, vp[3] * 0.5f / t, 0];
        immutable float slices = s.slices ? (s.slices < 32 ? s.slices : 32) : effort[s.quality][0];
        immutable float steps = s.steps ? (s.steps < 64 ? s.steps : 64) : effort[s.quality][1];
        p.b = [slices, steps, s.halfResolution ? 2 : 1, 0];
        return p;
    }
}
static assert(AoParams.sizeof == 64 && isValidUniformStruct!AoParams);

private enum AoPipe { linearize, downsample, ao, blurX, blurY, compositeAlpha, compositeColor }

/// Owned by `Renderer`. GPU objects are created on first use.
struct GtaoPass {
    private WGPUDevice device;
    private WGPUQueue queue;
    private WGPUShaderModule sm;
    private WGPUBindGroupLayout bgl;
    private WGPUPipelineLayout pl;
    private WGPUBuffer ubo;
    private WGPURenderPipeline[AoPipe.max + 1] pipes;
    private TexRT dummyLin, dummyAo;
    private WGPUTexture linTex;
    private WGPUTextureView linView;
    private WGPUTextureView[AO_MIPS] linMips;
    private uint mips;
    private TexRT aoA, aoB;
    // linearize, one per mip below 0, ao, blur x, blur y, composite
    private WGPUBindGroup linBg, aoBg, blurXBg, blurYBg, compositeBg;
    private WGPUBindGroup[AO_MIPS] mipBg;
    private WGPUTextureView boundDepth;
    private uint width, height, divisor;
    private uint sceneCount; /// scenes composited this frame

    @disable this(this);

    package(engine) void setup(WGPUDevice d, WGPUQueue q) nothrow @nogc { device = d; queue = q; }

    package(engine) void beginFrame() nothrow @nogc { sceneCount = 0; }

    /// Another scene can still get occlusion this frame.
    package(engine) bool available() const nothrow @nogc { return device !is null && sceneCount < AO_MAX_SCENES; }

    /// Compute the occlusion and darken the ambient share of `color`.
    package(engine) void run(WGPUCommandEncoder encoder, WGPUTextureView color, WGPUTextureView depth,
                             uint w, uint h, float[4] viewport, ref const AoSettings s, ref const Camera cam)
    nothrow @nogc @trusted {
        auto z = profileZone!"scene.gtao"();
        auto g = gpuScope!"gpu.gtao"(encoder);
        ensurePipelines();
        ensureTargets(depth, w, h, s.halfResolution ? 2 : 1);
        immutable uint offset = sceneCount++ * AO_UBO_STRIDE;
        immutable p = AoParams.make(s, cam, viewport);
        wgpuQueueWriteBuffer(queue, ubo, offset, &p, p.sizeof);
        {
            auto gd = gpuScope!"gpu.gtao.depth"(encoder);
            pass(encoder, linMips[0], AoPipe.linearize, linBg, offset);
            foreach (m; 1 .. mips) pass(encoder, linMips[m], AoPipe.downsample, mipBg[m], offset);
        }
        {
            auto ga = gpuScope!"gpu.gtao.ao"(encoder);
            pass(encoder, aoA.view, AoPipe.ao, aoBg, offset);
        }
        {
            auto gb = gpuScope!"gpu.gtao.blur"(encoder);
            pass(encoder, aoB.view, AoPipe.blurX, blurXBg, offset);
            pass(encoder, aoA.view, AoPipe.blurY, blurYBg, offset);
        }
        auto gc = gpuScope!"gpu.gtao.composite"(encoder);
        WGPURenderPassColorAttachment ca;
        ca.view = color;
        ca.loadOp = WGPULoadOp.load;
        ca.storeOp = WGPUStoreOp.store;
        ca.depthSlice = WGPU_DEPTH_SLICE_UNDEFINED;
        WGPURenderPassDescriptor pd;
        pd.colorAttachmentCount = 1;
        pd.colorAttachments = &ca;
        auto rp = wgpuCommandEncoderBeginRenderPass(encoder, &pd);
        immutable x0 = clampTo(viewport[0], w), y0 = clampTo(viewport[1], h);
        immutable x1 = clampTo(viewport[0] + viewport[2], w), y1 = clampTo(viewport[1] + viewport[3], h);
        wgpuRenderPassEncoderSetScissorRect(rp, x0, y0, x1 - x0, y1 - y0);
        wgpuRenderPassEncoderSetBindGroup(rp, 0, compositeBg, 1, &offset);
        foreach (k; AoPipe.compositeAlpha .. AoPipe.max + 1) {
            wgpuRenderPassEncoderSetPipeline(rp, pipes[k]);
            wgpuRenderPassEncoderDraw(rp, 3, 1, 0, 0);
        }
        wgpuRenderPassEncoderEnd(rp);
        wgpuRenderPassEncoderRelease(rp);
    }

    private static uint clampTo(float v, uint limit) pure nothrow @nogc {
        return v <= 0 ? 0 : v >= limit ? limit : cast(uint)(v + 0.5f);
    }

    private void pass(WGPUCommandEncoder encoder, WGPUTextureView target, AoPipe k,
                      WGPUBindGroup bg, uint offset) nothrow @nogc @trusted {
        WGPURenderPassColorAttachment ca;
        ca.view = target;
        ca.loadOp = WGPULoadOp.clear;
        ca.storeOp = WGPUStoreOp.store;
        ca.depthSlice = WGPU_DEPTH_SLICE_UNDEFINED;
        WGPURenderPassDescriptor pd;
        pd.colorAttachmentCount = 1;
        pd.colorAttachments = &ca;
        auto rp = wgpuCommandEncoderBeginRenderPass(encoder, &pd);
        wgpuRenderPassEncoderSetPipeline(rp, pipes[k]);
        wgpuRenderPassEncoderSetBindGroup(rp, 0, bg, 1, &offset);
        wgpuRenderPassEncoderDraw(rp, 3, 1, 0, 0);
        wgpuRenderPassEncoderEnd(rp);
        wgpuRenderPassEncoderRelease(rp);
    }

    private void ensurePipelines() nothrow @nogc @trusted {
        if (sm !is null) return;
        sm = createShaderModule(device, gtaoShaderSource);
        if (sm is null) fatal("Failed to create the GTAO shader module");
        WGPUBindGroupLayoutEntry[4] e;
        foreach (i, ref x; e) {
            x.binding = cast(uint) i;
            x.visibility = WGPUShaderStage.fragment;
            if (i == 0) {
                x.buffer.type = WGPUBufferBindingType.uniform;
                x.buffer.hasDynamicOffset = WGPU_TRUE;
                x.buffer.minBindingSize = AoParams.sizeof;
            } else {
                x.texture.sampleType = i == 1 ? WGPUTextureSampleType.depth : WGPUTextureSampleType.unfilterableFloat;
                x.texture.viewDimension = WGPUTextureViewDimension.dim2D;
            }
        }
        WGPUBindGroupLayoutDescriptor ld;
        ld.entryCount = e.length;
        ld.entries = e.ptr;
        bgl = wgpuDeviceCreateBindGroupLayout(device, &ld);
        WGPUPipelineLayoutDescriptor pld;
        pld.bindGroupLayoutCount = 1;
        pld.bindGroupLayouts = &bgl;
        pl = wgpuDeviceCreatePipelineLayout(device, &pld);
        WGPUBufferDescriptor bd;
        bd.usage = WGPUBufferUsage.uniform | WGPUBufferUsage.copyDst;
        bd.size = AO_UBO_STRIDE * AO_MAX_SCENES;
        ubo = wgpuDeviceCreateBuffer(device, &bd);
        dummyLin = createRT(device, 1, 1, LIN_FORMAT);
        dummyAo = createRT(device, 1, 1, AO_FORMAT);
        static immutable string[AoPipe.max + 1] entries = ["fs_linearize", "fs_downsample", "fs_ao", "fs_blur_x",
            "fs_blur_y", "fs_composite_alpha", "fs_composite_color"];
        foreach (k; 0 .. pipes.length) {
            WGPUBlendState blend;
            WGPUColorTargetState ct;
            ct.format = k <= AoPipe.downsample ? LIN_FORMAT : AO_FORMAT;
            ct.writeMask = WGPUColorWriteMask.all;
            if (k >= AoPipe.compositeAlpha) {
                import engine.gpu.post : SCENE_COLOR_FORMAT;
                ct.format = SCENE_COLOR_FORMAT;
                ct.blend = &blend;
                blend.color.operation = WGPUBlendOperation.add;
                blend.color.srcFactor = WGPUBlendFactor.zero;
                blend.alpha.operation = WGPUBlendOperation.add;
                blend.alpha.srcFactor = WGPUBlendFactor.one;
                if (k == AoPipe.compositeAlpha) {
                    // a = ao + a * (1 - ao)
                    blend.color.dstFactor = WGPUBlendFactor.one;
                    blend.alpha.dstFactor = WGPUBlendFactor.oneMinusSrcAlpha;
                } else {
                    // color *= a; a = 1
                    blend.color.dstFactor = WGPUBlendFactor.dstAlpha;
                    blend.alpha.dstFactor = WGPUBlendFactor.zero;
                }
            }
            WGPUFragmentState fs;
            fs.module_ = sm;
            fs.entryPoint = wgpuStringView(entries[k].ptr);
            fs.targetCount = 1;
            fs.targets = &ct;
            WGPURenderPipelineDescriptor desc;
            desc.layout = pl;
            desc.vertex.module_ = sm;
            desc.vertex.entryPoint = wgpuStringView("vs_main");
            desc.fragment = &fs;
            desc.primitive.topology = WGPUPrimitiveTopology.triangleList;
            pipes[k] = wgpuDeviceCreateRenderPipeline(device, &desc);
            if (pipes[k] is null) fatal("Failed to create a GTAO pipeline");
        }
    }

    private void ensureTargets(WGPUTextureView depth, uint w, uint h, uint div) nothrow @nogc @trusted {
        if (w == width && h == height && div == divisor && depth is boundDepth) return;
        releaseTargets();
        width = w; height = h; divisor = div; boundDepth = depth;
        immutable aw = (w + div - 1) / div, ah = (h + div - 1) / div;
        mips = 1;
        while (mips < AO_MIPS && (aw >> mips) > 0 && (ah >> mips) > 0) mips++;
        WGPUTextureDescriptor td;
        td.usage = WGPUTextureUsage.renderAttachment | WGPUTextureUsage.textureBinding;
        td.dimension = WGPUTextureDimension.dim2D;
        td.size = WGPUExtent3D(aw, ah, 1);
        td.format = LIN_FORMAT;
        td.mipLevelCount = mips;
        linTex = wgpuDeviceCreateTexture(device, &td);
        if (linTex is null) fatal("GTAO depth texture creation failed");
        WGPUTextureViewDescriptor vd;
        vd.format = LIN_FORMAT;
        vd.dimension = WGPUTextureViewDimension.dim2D;
        vd.mipLevelCount = mips;
        linView = wgpuTextureCreateView(linTex, &vd);
        vd.mipLevelCount = 1;
        foreach (m; 0 .. mips) {
            vd.baseMipLevel = m;
            linMips[m] = wgpuTextureCreateView(linTex, &vd);
        }
        aoA = createRT(device, aw, ah, AO_FORMAT);
        aoB = createRT(device, aw, ah, AO_FORMAT);
        linBg = group(dummyLin.view, dummyAo.view);
        foreach (m; 1 .. mips) mipBg[m] = group(linMips[m - 1], dummyAo.view);
        aoBg = group(linView, dummyAo.view);
        blurXBg = group(linView, aoA.view);
        blurYBg = group(linView, aoB.view);
        compositeBg = group(linView, aoA.view);
    }

    private WGPUBindGroup group(WGPUTextureView lin, WGPUTextureView ao) nothrow @nogc @trusted {
        WGPUBindGroupEntry[4] e;
        foreach (i, ref x; e) x.binding = cast(uint) i;
        e[0].buffer = ubo;
        e[0].size = AoParams.sizeof;
        e[1].textureView = boundDepth;
        e[2].textureView = lin;
        e[3].textureView = ao;
        WGPUBindGroupDescriptor d;
        d.layout = bgl;
        d.entryCount = e.length;
        d.entries = e.ptr;
        return wgpuDeviceCreateBindGroup(device, &d);
    }

    /// Drop everything bound to the scene targets (resize).
    package(engine) void releaseTargets() nothrow @nogc @trusted {
        static void drop(ref WGPUBindGroup b) nothrow @nogc @trusted {
            if (b !is null) { wgpuBindGroupRelease(b); b = null; }
        }
        drop(linBg); drop(aoBg); drop(blurXBg); drop(blurYBg); drop(compositeBg);
        foreach (ref b; mipBg) drop(b);
        foreach (ref v; linMips) if (v !is null) { wgpuTextureViewRelease(v); v = null; }
        if (linView !is null) { wgpuTextureViewRelease(linView); linView = null; }
        if (linTex !is null) { wgpuTextureRelease(linTex); linTex = null; }
        aoA.release();
        aoB.release();
        boundDepth = null;
        width = height = divisor = 0;
    }

    package(engine) void destroy() nothrow @nogc @trusted {
        releaseTargets();
        dummyLin.release();
        dummyAo.release();
        foreach (ref p; pipes) if (p !is null) { wgpuRenderPipelineRelease(p); p = null; }
        if (pl !is null) { wgpuPipelineLayoutRelease(pl); pl = null; }
        if (bgl !is null) { wgpuBindGroupLayoutRelease(bgl); bgl = null; }
        if (ubo !is null) { wgpuBufferRelease(ubo); ubo = null; }
        if (sm !is null) { wgpuShaderModuleRelease(sm); sm = null; }
    }
}

@("gtao.params") @safe unittest {
    AoSettings s;
    assert(!s.enabled);
    s.radius = -1;
    s.intensity = -1;
    s.halfResolution = true;
    Camera c = Camera.create(1.5707964f, 2.0f, 0.5f, 60.0f);
    immutable p = AoParams.make(s, c, [10.0f, 20.0f, 200.0f, 100.0f]);
    assert(p.a[0] == 0 && p.a[1] == 0 && p.b[2] == 2);
    assert(p.b[0] == 2 && p.b[1] == 3);
    s.slices = 200;
    s.steps = 7;
    immutable q = AoParams.make(s, c, [0.0f, 0.0f, 1.0f, 1.0f]);
    assert(q.b[0] == 32 && q.b[1] == 7);
    assert(p.proj[2] == 0.5f && p.proj[3] == 60.0f);
    assert(p.a[2] > 49.99f && p.a[2] < 50.01f); // tan(45 deg) = 1
    assert(GtaoPass.clampTo(-3, 10) == 0 && GtaoPass.clampTo(99, 10) == 10 && GtaoPass.clampTo(4, 10) == 4);
}
