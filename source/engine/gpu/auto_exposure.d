/// Auto exposure: histogram of the HDR image in compute. The result lives in a
/// GPU buffer read by the tone mapper; nothing is read back.
module engine.gpu.auto_exposure;

import bindings.wgpu;
import engine.core.log;
import engine.devtools.profiler : profileZone;
import engine.gpu.buffer : createStorageBuffer, createUniformBuffer, destroyBuffer, updateBuffer;
import engine.gpu.gpu_profiler : gpuScope;
import engine.gpu.shader : createShaderModule, isValidUniformStruct;
import engine.gpu.shaders : autoExposureShaderSource;
import core.stdc.math : expf, log2f;
import core.time : MonoTime;

@safe:

/// Auto exposure (`PostSettings.autoExposure`). Off by default.
/// `PostSettings.exposure` multiplies the result (compensation).
struct AutoExposureSettings {
    bool enabled = false;
    /// Limits of the exposure multiplier.
    float minExposure = 0.05f, maxExposure = 8.0f;
    /// Linear value the average luminance is brought to.
    float key = 0.18f;
    /// Shares of the pixels, from the darkest, left out of the average: below
    /// `lowPercentile` and above `highPercentile`.
    float lowPercentile = 0.1f, highPercentile = 0.9f;
    /// Adaptation speed (1/s) when the scene gets brighter / darker.
    float adaptToBright = 3.0f, adaptToDark = 1.0f;
    /// Luminance range of the histogram, in log2.
    float minEv = -12, maxEv = 8;
    /// Seconds per frame. 0 = measured.
    float fixedDt = 0;
}

/// GPU mirror of WGSL `Params` (`auto_exposure.wgsl`).
private struct ExposureParams {
    float[4] range, meter, adapt;

    static ExposureParams make(ref const AutoExposureSettings s, float dt, bool reset) nothrow @nogc @trusted {
        static float clamp(float v, float lo, float hi) pure nothrow @nogc { return v > lo ? (v < hi ? v : hi) : lo; }
        immutable ev = s.maxEv - s.minEv > 1 ? s.maxEv - s.minEv : 1;
        immutable low = clamp(s.lowPercentile, 0, 0.99f);
        immutable high = clamp(s.highPercentile, low + 0.01f, 1);
        immutable eMin = s.minExposure > 1e-4f ? s.minExposure : 1e-4f;
        immutable eMax = s.maxExposure > eMin ? s.maxExposure : eMin;
        ExposureParams p;
        p.range = [s.minEv, 1 / ev, ev, 0];
        p.meter = [low, high, s.key > 1e-4f ? s.key : 1e-4f, reset ? 1 : 0];
        p.adapt = [log2f(eMin), log2f(eMax), 1 - expf(-dt * clamp(s.adaptToBright, 0, 1e4f)),
                   1 - expf(-dt * clamp(s.adaptToDark, 0, 1e4f))];
        return p;
    }
}
static assert(ExposureParams.sizeof == 48 && isValidUniformStruct!ExposureParams);

package(engine) enum ulong EXPOSURE_STATE_BYTES = 16;
private enum ulong HISTOGRAM_BYTES = 256 * 4;

/// Owned by `PostProcessor`. GPU objects are created on first use.
struct AutoExposurePass {
    private WGPUDevice device;
    private WGPUQueue queue;
    private WGPUShaderModule sm;
    private WGPUBindGroupLayout bgl;
    private WGPUPipelineLayout pl;
    private WGPUComputePipeline histogramPipe, resolvePipe;
    private WGPUBuffer ubo, histogram, state;
    private MonoTime last;
    private bool pendingReset = true;

    @disable this(this);

    package(engine) void setup(WGPUDevice d, WGPUQueue q) nothrow @nogc {
        device = d;
        queue = q;
    }

    /// Jump to the metered exposure in the next frame (camera cut, or off).
    package(engine) void reset() nothrow @nogc { pendingReset = true; }

    /// `State` of the shader: the exposure multiplier is the first float.
    package(engine) WGPUBuffer stateBuffer() nothrow @nogc { return state; }

    package(engine) void run(WGPUCommandEncoder encoder, WGPUTextureView hdr, uint w, uint h,
                             ref const AutoExposureSettings s) nothrow @nogc @trusted {
        auto z = profileZone!"post.autoExposure"();
        auto g = gpuScope!"gpu.post.autoExposure"(encoder);
        ensurePipelines();
        immutable now = MonoTime.currTime;
        float dt = s.fixedDt;
        if (dt <= 0) {
            dt = pendingReset ? 0 : (now - last).total!"usecs" / 1e6f;
            if (dt > 0.1f) dt = 0.1f;
        }
        last = now;
        immutable p = ExposureParams.make(s, dt, pendingReset);
        pendingReset = false;
        updateBuffer(queue, ubo, (&p)[0 .. 1]);

        WGPUBindGroupEntry[4] e;
        foreach (i, ref x; e) x.binding = cast(uint) i;
        e[0].buffer = ubo; e[0].size = ExposureParams.sizeof;
        e[1].textureView = hdr;
        e[2].buffer = histogram; e[2].size = HISTOGRAM_BYTES;
        e[3].buffer = state; e[3].size = EXPOSURE_STATE_BYTES;
        WGPUBindGroupDescriptor bd;
        bd.layout = bgl;
        bd.entryCount = e.length;
        bd.entries = e.ptr;
        auto bg = wgpuDeviceCreateBindGroup(device, &bd);
        scope(exit) wgpuBindGroupRelease(bg);

        WGPUComputePassDescriptor d;
        auto pass = wgpuCommandEncoderBeginComputePass(encoder, &d);
        wgpuComputePassEncoderSetBindGroup(pass, 0, bg, 0, null);
        wgpuComputePassEncoderSetPipeline(pass, histogramPipe);
        wgpuComputePassEncoderDispatchWorkgroups(pass, (w + 63) / 64, (h + 63) / 64, 1);
        wgpuComputePassEncoderSetPipeline(pass, resolvePipe);
        wgpuComputePassEncoderDispatchWorkgroups(pass, 1, 1, 1);
        wgpuComputePassEncoderEnd(pass);
        wgpuComputePassEncoderRelease(pass);
    }

    private void ensurePipelines() nothrow @nogc @trusted {
        if (sm !is null) return;
        sm = createShaderModule(device, autoExposureShaderSource, "auto_exposure");
        if (sm is null) fatal("Failed to create the auto exposure shader module");
        ubo = createUniformBuffer(device, ExposureParams.sizeof);
        histogram = createStorageBuffer(device, HISTOGRAM_BYTES);
        state = createStorageBuffer(device, EXPOSURE_STATE_BYTES);
        WGPUBindGroupLayoutEntry[4] e;
        foreach (i, ref x; e) {
            x.binding = cast(uint) i;
            x.visibility = WGPUShaderStage.compute;
            if (i == 1) {
                x.texture.sampleType = WGPUTextureSampleType.unfilterableFloat;
                x.texture.viewDimension = WGPUTextureViewDimension.dim2D;
            } else {
                x.buffer.type = i == 0 ? WGPUBufferBindingType.uniform : WGPUBufferBindingType.storage;
                x.buffer.minBindingSize = i == 0 ? ExposureParams.sizeof : i == 2 ? HISTOGRAM_BYTES : EXPOSURE_STATE_BYTES;
            }
        }
        WGPUBindGroupLayoutDescriptor d;
        d.entryCount = e.length;
        d.entries = e.ptr;
        bgl = wgpuDeviceCreateBindGroupLayout(device, &d);
        WGPUPipelineLayoutDescriptor pd;
        pd.bindGroupLayoutCount = 1;
        pd.bindGroupLayouts = &bgl;
        pl = wgpuDeviceCreatePipelineLayout(device, &pd);
        histogramPipe = makePipe("cs_histogram");
        resolvePipe = makePipe("cs_resolve");
    }

    private WGPUComputePipeline makePipe(string entry) nothrow @nogc @trusted {
        WGPUComputePipelineDescriptor cd;
        cd.layout = pl;
        cd.compute.module_ = sm;
        cd.compute.entryPoint = wgpuStringView(entry.ptr);
        auto p = wgpuDeviceCreateComputePipeline(device, &cd);
        if (p is null) fatal("Failed to create an auto exposure pipeline");
        return p;
    }

    package(engine) void destroy() nothrow @nogc @trusted {
        if (histogramPipe !is null) { wgpuComputePipelineRelease(histogramPipe); histogramPipe = null; }
        if (resolvePipe !is null) { wgpuComputePipelineRelease(resolvePipe); resolvePipe = null; }
        if (pl !is null) { wgpuPipelineLayoutRelease(pl); pl = null; }
        if (bgl !is null) { wgpuBindGroupLayoutRelease(bgl); bgl = null; }
        destroyBuffer(ubo); ubo = null;
        destroyBuffer(histogram); histogram = null;
        destroyBuffer(state); state = null;
        if (sm !is null) { wgpuShaderModuleRelease(sm); sm = null; }
    }
}

@("autoExposure.params") @safe unittest {
    import std.math : isClose;
    AutoExposureSettings s;
    assert(!s.enabled);
    s.minExposure = 0.25f;
    s.maxExposure = 4;
    auto p = ExposureParams.make(s, 0, false);
    assert(p.adapt[0] == -2 && p.adapt[1] == 2);
    assert(p.adapt[2] == 0 && p.adapt[3] == 0); // no time, no adaptation
    p = ExposureParams.make(s, 1, true);
    assert(p.meter[3] == 1);
    assert(isClose(p.adapt[3], 1 - 0.367879f, 1e-4));
    // Bad input stays in range.
    s.maxExposure = 0.1f;
    s.lowPercentile = 2;
    s.highPercentile = -1;
    s.maxEv = s.minEv;
    p = ExposureParams.make(s, 1, false);
    assert(p.adapt[1] == p.adapt[0]);
    assert(p.meter[0] < p.meter[1] && p.meter[1] <= 1.0001f);
    assert(p.range[2] == 1);
}
