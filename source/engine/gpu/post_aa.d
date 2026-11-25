/// Optional antialiasing and sharpening passes of the post stack. Pipelines
/// and targets are created on first use, so a disabled mode costs nothing.
module engine.gpu.post_aa;

import bindings.wgpu;
import engine.core.log;
import engine.devtools.profiler : profileZone;
import engine.gpu.buffer : createUniformBuffer, destroyBuffer, updateBuffer;
import engine.gpu.gpu_profiler : gpuScope;
import engine.gpu.post_cmaa2 : Cmaa2Pass;
import engine.gpu.post_smaa : SmaaPass;
import engine.gpu.post_util;
import engine.gpu.shader : createShaderModule;
import engine.gpu.shaders : casShaderSource, fxaaHqShaderSource;

@safe:

/// Antialiasing applied to the tone-mapped image.
enum AaMode : ubyte {
    /// Follow `PostSettings.fxaa` (default).
    legacy,
    off,
    /// Short-blur FXAA, the engine's original filter.
    fxaa,
    /// FXAA with edge-end search and configurable sub-pixel smoothing.
    fxaaQuality,
    /// SMAA 1x, preset high (pattern based, keeps texture detail).
    smaa,
    /// CMAA2, preset high (compute; the sharpest, for scenes with much texture detail).
    cmaa2,
}

/// AA parameters for one frame.
struct AaParams {
    float subpix = 0.5f;
    float sharpness = 0;
    float edgeThreshold = 0.125f;
    float edgeThresholdMin = 0.0312f;
}

/// A fullscreen pipeline in its two target formats (display target, LDR target).
private struct FsPass {
    WGPUShaderModule sm;
    WGPURenderPipeline[2] pipe;

    bool ensure(WGPUDevice device, WGPUPipelineLayout pl, string source, WGPUTextureFormat fmt, size_t slot)
    nothrow @nogc @trusted {
        if (sm is null) sm = createShaderModule(device, source);
        if (sm is null) return false;
        if (pipe[slot] is null) pipe[slot] = tryMakeFSPipeline(device, pl, sm, fmt, false);
        return pipe[slot] !is null;
    }

    /// Swap in a recompiled module; the old pass stays on failure.
    bool reload(WGPUDevice device, WGPUPipelineLayout pl, WGPUShaderModule next, WGPUTextureFormat probeFmt)
    nothrow @nogc @trusted {
        auto probe = tryMakeFSPipeline(device, pl, next, probeFmt, false);
        if (probe is null) return false;
        wgpuRenderPipelineRelease(probe);
        release();
        sm = next;
        return true;
    }

    void release() nothrow @nogc @trusted {
        foreach (ref p; pipe)
            if (p !is null) { wgpuRenderPipelineRelease(p); p = null; }
        if (sm !is null) { wgpuShaderModuleRelease(sm); sm = null; }
    }
}

/// Owned by `PostProcessor`.
struct PostAa {
    private WGPUDevice device;
    private WGPUQueue queue;
    private WGPUSampler sampler;        // borrowed
    private WGPUBindGroupLayout bgl;    // borrowed (UBO + sampler + texture)
    private WGPUPipelineLayout pl;      // borrowed
    private WGPUBuffer ubo;
    private FsPass fxaaHq, cas;
    private SmaaPass smaaPass;
    private Cmaa2Pass cmaa2Pass;
    private WGPUTextureFormat surfaceFormat;

    @disable this(this);

    package(engine) void setup(WGPUDevice device_, WGPUQueue queue_, WGPUSampler sampler_,
                               WGPUBindGroupLayout bgl_, WGPUPipelineLayout pl_, WGPUTextureFormat surfFmt) {
        device = device_;
        queue = queue_;
        sampler = sampler_;
        bgl = bgl_;
        pl = pl_;
        surfaceFormat = surfFmt;
        ubo = createUniformBuffer(device, AaParams.sizeof);
        smaaPass.setup(device, queue, sampler);
        cmaa2Pass.setup(device, queue);
    }

    package(engine) void begin(AaParams params) nothrow @nogc {
        float[4] v = [params.subpix, params.sharpness, params.edgeThreshold, params.edgeThresholdMin];
        updateBuffer(queue, ubo, v[]);
    }

    /// `toSurface` selects the pipeline for the display format.
    package(engine) void fxaaQuality(WGPUCommandEncoder encoder, WGPUTextureView src,
                                     WGPUTextureView dst, bool toSurface) nothrow @nogc {
        auto z = profileZone!"post.fxaaQuality"();
        auto g = gpuScope!"gpu.post.fxaaQuality"(encoder);
        run(fxaaHq, fxaaHqShaderSource, encoder, src, dst, toSurface);
    }

    package(engine) void sharpen(WGPUCommandEncoder encoder, WGPUTextureView src,
                                 WGPUTextureView dst, bool toSurface) nothrow @nogc {
        auto z = profileZone!"post.sharpen"();
        auto g = gpuScope!"gpu.post.sharpen"(encoder);
        run(cas, casShaderSource, encoder, src, dst, toSurface);
    }

    package(engine) void smaa(WGPUCommandEncoder encoder, WGPUTextureView src, WGPUTextureView dst,
                              bool toSurface, uint w, uint h, float threshold) nothrow @nogc {
        smaaPass.run(encoder, src, dst, toSurface ? surfaceFormat : WGPUTextureFormat.rgba8Unorm, toSurface,
                     w, h, threshold);
    }

    /// In place on `image`.
    package(engine) void cmaa2(WGPUCommandEncoder encoder, WGPUTextureView image, uint w, uint h, float threshold)
    nothrow @nogc {
        cmaa2Pass.run(encoder, image, w, h, threshold);
    }

    /// Drop everything sized after the target (resize).
    package(engine) void releaseTargets() nothrow @nogc {
        smaaPass.releaseTargets();
        cmaa2Pass.releaseTargets();
    }

    private void run(ref FsPass pass, string source, WGPUCommandEncoder encoder, WGPUTextureView src,
                     WGPUTextureView dst, bool toSurface) nothrow @nogc @trusted {
        immutable fmt = toSurface ? surfaceFormat : WGPUTextureFormat.rgba8Unorm;
        immutable slot = toSurface ? 0 : 1;
        if (!pass.ensure(device, pl, source, fmt, slot)) fatal("Failed to create AA pipeline");
        WGPUBindGroupEntry[3] e;
        e[0].binding = 0; e[0].buffer = ubo; e[0].size = AaParams.sizeof;
        e[1].binding = 1; e[1].sampler = sampler;
        e[2].binding = 2; e[2].textureView = src;
        WGPUBindGroupDescriptor d;
        d.layout = bgl; d.entryCount = e.length; d.entries = e.ptr;
        auto bg = wgpuDeviceCreateBindGroup(device, &d);
        drawPass(encoder, dst, pass.pipe[slot], bg, true);
        wgpuBindGroupRelease(bg);
    }

    /// Hot reload. Takes ownership of `next` only when it returns true.
    package(engine) bool reload(scope const(char)[] name, WGPUShaderModule next) nothrow @nogc {
        if (name == "post_fxaa_hq" || name == "fxaa_hq") return fxaaHq.reload(device, pl, next, surfaceFormat);
        if (name == "post_cas" || name == "cas") return cas.reload(device, pl, next, surfaceFormat);
        return false;
    }

    package(engine) void destroy() nothrow @nogc {
        smaaPass.destroy();
        cmaa2Pass.destroy();
        fxaaHq.release();
        cas.release();
        destroyBuffer(ubo);
        ubo = null;
    }
}
