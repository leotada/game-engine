/// Runtime HDR image-based lighting driven by the engine sky.
///
/// `DynamicIbl` renders the procedural sky (`common/sky_eval.wgsl`) into an
/// `rgba16Float` environment cube on the GPU and convolves irradiance plus
/// GGX specular mips with compute passes. The work is amortized: one step
/// (sky, irradiance, or one specular mip) per `update()` call, written into
/// a back set of cubes; the bind group swaps only when the whole set is
/// complete, so shading never sees a half-updated environment. The BRDF LUT
/// is generated once at creation and never rebuilt. No CPU allocation after
/// `create`.
///
///   auto ibl = DynamicIbl.create(gpu, scene.iblLayout());
///   ibl.bakeNow(params);                     // first environment, synchronous
///   // each frame:
///   ibl.request(params);                     // starts a cycle when the sky changed
///   ibl.update();                            // ≤ 1 compute step
///   scene.setEnvironmentBindGroup(ibl.bindGroup());
module engine.gpu.ibl_dynamic;

import std.math : abs;

import bindings.wgpu;
import engine.core.log;
import engine.gpu.context : GpuContext;
import engine.gpu.ibl : createLutTexture, generateBrdfLut, IBL_ENV_SIZE, IBL_IRRADIANCE_SIZE,
    IBL_LUT_SIZE, IBL_SPECULAR_MIPS;
import engine.gpu.shader : createShaderModule;
import engine.gpu.shaders : iblSkyCsShaderSource;
import engine.math.vec : Vec3;

@safe:

/// Sky state baked into the environment (mirrors the sky shader inputs).
struct SkyIblParams {
    Vec3 sunDir = Vec3(0.3f, 0.85f, 0.4f);
    Vec3 sunColor = Vec3(1, 0.97f, 0.9f);
    Vec3 moonDir = Vec3(0, -1, 0);
    float moonIntensity = 0;
    float starIntensity = 0;
    float cloudCoverage = 0;
    float time = 0;
    float exposure = 1;

    /// True when the change from `o` is visible in the ambient lighting.
    bool differsFrom(ref const SkyIblParams o) const pure nothrow @nogc {
        enum float dirCos = 0.99985f; // ~1°
        if (sunDir.normalized().dot(o.sunDir.normalized()) < dirCos) return true;
        if (moonDir.normalized().dot(o.moonDir.normalized()) < dirCos) return true;
        if ((sunColor - o.sunColor).length() > 0.02f) return true;
        if (abs(cloudCoverage - o.cloudCoverage) > 0.02f) return true;
        if (abs(moonIntensity - o.moonIntensity) > 0.02f) return true;
        if (abs(starIntensity - o.starIntensity) > 0.05f) return true;
        if (abs(exposure - o.exposure) > 0.01f) return true;
        return false;
    }
}

struct DynamicIbl {
    private enum uint STEP_COUNT = 2 + IBL_SPECULAR_MIPS; // sky, irradiance, specular mips
    private enum uint PARAMS_SIZE = 64;

    private WGPUDevice device;
    private WGPUQueue queue;

    private WGPUTexture envTex;
    private WGPUTextureView envCubeView, envStorageView;
    private WGPUTexture[2] irrTex, specTex;
    private WGPUTextureView[2] irrCubeView, specCubeView, irrStorageView;
    private WGPUTextureView[IBL_SPECULAR_MIPS][2] specStorageView;
    private WGPUTexture dummyTex;
    private WGPUTextureView dummyView;
    private WGPUTexture lutTex;
    private WGPUTextureView lutView;
    private WGPUSampler sampler;

    private WGPUBindGroup[2] renderGroups;

    private WGPUShaderModule csModule;
    private WGPUBindGroupLayout csLayout;
    private WGPUPipelineLayout csPipeLayout;
    private WGPUComputePipeline skyPipe, irrPipe, specPipe;
    private WGPUBindGroup skyBg;
    private WGPUBindGroup[2] irrBg;
    private WGPUBindGroup[IBL_SPECULAR_MIPS][2] specBg;
    private WGPUBuffer paramBuf;

    private uint front = 0;
    private int step = -1;
    private SkyIblParams pending, baked;
    private bool hasBaked = false;
    private uint cyclesCompleted = 0;

    @disable this(this);

    static DynamicIbl create(ref GpuContext gpu, WGPUBindGroupLayout iblLayout) @trusted {
        DynamicIbl d;
        d.device = gpu.getDevice();
        d.queue = gpu.getQueue();
        auto dev = d.device;

        immutable usage = cast(WGPUTextureUsage)(WGPUTextureUsage.textureBinding | WGPUTextureUsage.storageBinding);
        d.envTex = createCube(dev, IBL_ENV_SIZE, 1, usage);
        d.envCubeView = cubeView(d.envTex, 0, 1);
        d.envStorageView = arrayView(d.envTex, 0);
        foreach (s; 0 .. 2) {
            d.irrTex[s] = createCube(dev, IBL_IRRADIANCE_SIZE, 1, usage);
            d.irrCubeView[s] = cubeView(d.irrTex[s], 0, 1);
            d.irrStorageView[s] = arrayView(d.irrTex[s], 0);
            d.specTex[s] = createCube(dev, IBL_ENV_SIZE, IBL_SPECULAR_MIPS, usage);
            d.specCubeView[s] = cubeView(d.specTex[s], 0, IBL_SPECULAR_MIPS);
            foreach (m; 0 .. IBL_SPECULAR_MIPS) d.specStorageView[s][m] = arrayView(d.specTex[s], m);
        }
        d.dummyTex = createCube(dev, 1, 1, WGPUTextureUsage.textureBinding);
        d.dummyView = cubeView(d.dummyTex, 0, 1);

        auto lutPixels = generateBrdfLut(IBL_LUT_SIZE);
        d.lutTex = createLutTexture(dev, d.queue, lutPixels, IBL_LUT_SIZE);
        WGPUTextureViewDescriptor lutVd;
        lutVd.format = WGPUTextureFormat.rgba8Unorm;
        lutVd.dimension = WGPUTextureViewDimension.dim2D;
        d.lutView = wgpuTextureCreateView(d.lutTex, &lutVd);

        WGPUSamplerDescriptor sd;
        sd.addressModeU = WGPUAddressMode.clampToEdge;
        sd.addressModeV = WGPUAddressMode.clampToEdge;
        sd.addressModeW = WGPUAddressMode.clampToEdge;
        sd.magFilter = WGPUFilterMode.linear;
        sd.minFilter = WGPUFilterMode.linear;
        sd.mipmapFilter = WGPUMipmapFilterMode.linear;
        sd.lodMinClamp = 0;
        sd.lodMaxClamp = cast(float)(IBL_SPECULAR_MIPS - 1);
        sd.maxAnisotropy = 1;
        d.sampler = wgpuDeviceCreateSampler(dev, &sd);

        foreach (s; 0 .. 2) {
            WGPUBindGroupEntry[4] e;
            e[0].binding = 0; e[0].textureView = d.irrCubeView[s];
            e[1].binding = 1; e[1].textureView = d.specCubeView[s];
            e[2].binding = 2; e[2].textureView = d.lutView;
            e[3].binding = 3; e[3].sampler = d.sampler;
            WGPUBindGroupDescriptor bgd;
            bgd.layout = iblLayout;
            bgd.entryCount = 4;
            bgd.entries = e.ptr;
            d.renderGroups[s] = wgpuDeviceCreateBindGroup(dev, &bgd);
            if (d.renderGroups[s] is null) fatal("DynamicIbl: render bind group creation failed");
        }

        d.createComputeResources();
        info("Dynamic HDR IBL created (", IBL_ENV_SIZE, "² env, ", IBL_SPECULAR_MIPS,
             " specular mips, rgba16Float, double-buffered)");
        return d;
    }

    private void createComputeResources() @trusted {
        auto dev = device;
        csModule = createShaderModule(dev, iblSkyCsShaderSource);
        if (csModule is null) fatal("DynamicIbl: compute shader compile failed");

        WGPUBindGroupLayoutEntry[4] le;
        le[0].binding = 0;
        le[0].visibility = WGPUShaderStage.compute;
        le[0].buffer.type = WGPUBufferBindingType.uniform;
        le[0].buffer.minBindingSize = PARAMS_SIZE;
        le[1].binding = 1;
        le[1].visibility = WGPUShaderStage.compute;
        le[1].texture.sampleType = WGPUTextureSampleType.float_;
        le[1].texture.viewDimension = WGPUTextureViewDimension.cube;
        le[2].binding = 2;
        le[2].visibility = WGPUShaderStage.compute;
        le[2].sampler.type = WGPUSamplerBindingType.filtering;
        le[3].binding = 3;
        le[3].visibility = WGPUShaderStage.compute;
        le[3].storageTexture.access = WGPUStorageTextureAccess.writeOnly;
        le[3].storageTexture.format = WGPUTextureFormat.rgba16Float;
        le[3].storageTexture.viewDimension = WGPUTextureViewDimension.dim2DArray;
        WGPUBindGroupLayoutDescriptor bld;
        bld.entryCount = 4;
        bld.entries = le.ptr;
        csLayout = wgpuDeviceCreateBindGroupLayout(dev, &bld);

        WGPUPipelineLayoutDescriptor pld;
        pld.bindGroupLayoutCount = 1;
        pld.bindGroupLayouts = &csLayout;
        csPipeLayout = wgpuDeviceCreatePipelineLayout(dev, &pld);

        WGPUComputePipeline makePipe(const(char)* entry) {
            WGPUComputePipelineDescriptor cd;
            cd.layout = csPipeLayout;
            cd.compute.module_ = csModule;
            cd.compute.entryPoint = wgpuStringView(entry);
            auto p = wgpuDeviceCreateComputePipeline(dev, &cd);
            if (p is null) fatal("DynamicIbl: compute pipeline creation failed");
            return p;
        }
        skyPipe = makePipe("cs_sky");
        irrPipe = makePipe("cs_irradiance");
        specPipe = makePipe("cs_specular");

        WGPUBufferDescriptor bd;
        bd.size = PARAMS_SIZE;
        bd.usage = WGPUBufferUsage.uniform | WGPUBufferUsage.copyDst;
        paramBuf = wgpuDeviceCreateBuffer(dev, &bd);

        WGPUBindGroup makeBg(WGPUTextureView src, WGPUTextureView dst) {
            WGPUBindGroupEntry[4] e;
            e[0].binding = 0; e[0].buffer = paramBuf; e[0].size = PARAMS_SIZE;
            e[1].binding = 1; e[1].textureView = src;
            e[2].binding = 2; e[2].sampler = sampler;
            e[3].binding = 3; e[3].textureView = dst;
            WGPUBindGroupDescriptor bgd;
            bgd.layout = csLayout;
            bgd.entryCount = 4;
            bgd.entries = e.ptr;
            auto bg = wgpuDeviceCreateBindGroup(dev, &bgd);
            if (bg is null) fatal("DynamicIbl: compute bind group creation failed");
            return bg;
        }
        skyBg = makeBg(dummyView, envStorageView);
        foreach (s; 0 .. 2) {
            irrBg[s] = makeBg(envCubeView, irrStorageView[s]);
            foreach (m; 0 .. IBL_SPECULAR_MIPS) specBg[s][m] = makeBg(envCubeView, specStorageView[s][m]);
        }
    }

    /// Bind group for `@group(2)` of the textured PBR pipeline (current set).
    WGPUBindGroup bindGroup() const nothrow @nogc @trusted { return cast(WGPUBindGroup) renderGroups[front]; }

    /// True while a cycle is in flight.
    bool busy() const nothrow @nogc { return step >= 0; }

    /// Completed update cycles since creation (tests / stats).
    uint completedCycles() const nothrow @nogc { return cyclesCompleted; }

    /// Start a new cycle when `p` differs visibly from the last bake (or
    /// `force`). Ignored while a cycle is in flight; call again next frame.
    void request(ref const SkyIblParams p, bool force = false) nothrow @nogc {
        if (step >= 0) return;
        if (!force && hasBaked && !p.differsFrom(baked)) return;
        pending = p;
        step = 0;
    }

    /// Run at most one compute step. Returns true when this call completed a
    /// cycle and swapped the environment.
    bool update() nothrow @nogc @trusted {
        if (step < 0) return false;
        immutable back = front ^ 1;
        WGPUCommandEncoderDescriptor ed;
        auto enc = wgpuDeviceCreateCommandEncoder(device, &ed);
        encodeStep(enc, cast(uint) step, back);
        WGPUCommandBufferDescriptor cbd;
        auto cmd = wgpuCommandEncoderFinish(enc, &cbd);
        wgpuCommandEncoderRelease(enc);
        wgpuQueueSubmit(queue, 1, &cmd);
        wgpuCommandBufferRelease(cmd);

        step++;
        if (step >= cast(int) STEP_COUNT) {
            step = -1;
            front = back;
            baked = pending;
            hasBaked = true;
            cyclesCompleted++;
            return true;
        }
        return false;
    }

    /// Bake `p` completely now (every step in one submission) — for start-up
    /// and scene loads. Not for the frame path.
    void bakeNow(ref const SkyIblParams p) nothrow @nogc @trusted {
        step = -1;
        request(p, true);
        while (step >= 0) update();
    }

    private void encodeStep(WGPUCommandEncoder enc, uint s, uint set) nothrow @nogc @trusted {
        float[16] u = [
            pending.sunDir.x, pending.sunDir.y, pending.sunDir.z, pending.moonIntensity,
            pending.sunColor.x, pending.sunColor.y, pending.sunColor.z, pending.starIntensity,
            pending.moonDir.x, pending.moonDir.y, pending.moonDir.z, pending.cloudCoverage,
            pending.time, pending.exposure, 0, 0,
        ];
        WGPUComputePipeline pipe;
        WGPUBindGroup bg;
        uint size;
        if (s == 0) {
            pipe = skyPipe; bg = skyBg; size = IBL_ENV_SIZE;
        } else if (s == 1) {
            pipe = irrPipe; bg = irrBg[set]; size = IBL_IRRADIANCE_SIZE;
        } else {
            immutable mip = s - 2;
            pipe = specPipe; bg = specBg[set][mip]; size = IBL_ENV_SIZE >> mip;
            u[14] = mip == 0 ? 0.0f : cast(float) mip / cast(float)(IBL_SPECULAR_MIPS - 1);
        }
        u[15] = cast(float) size;
        wgpuQueueWriteBuffer(queue, paramBuf, 0, u.ptr, u.sizeof);

        WGPUComputePassDescriptor cpd;
        auto pass = wgpuCommandEncoderBeginComputePass(enc, &cpd);
        wgpuComputePassEncoderSetPipeline(pass, pipe);
        wgpuComputePassEncoderSetBindGroup(pass, 0, bg, 0, null);
        immutable groups = (size + 7) / 8;
        wgpuComputePassEncoderDispatchWorkgroups(pass, groups, groups, 6);
        wgpuComputePassEncoderEnd(pass);
        wgpuComputePassEncoderRelease(pass);
    }

    void destroy() nothrow @nogc @trusted {
        void relBg(ref WGPUBindGroup b) { if (b !is null) { wgpuBindGroupRelease(b); b = null; } }
        void relView(ref WGPUTextureView v) { if (v !is null) { wgpuTextureViewRelease(v); v = null; } }
        void relTex(ref WGPUTexture t) { if (t !is null) { wgpuTextureRelease(t); t = null; } }
        void relPipe(ref WGPUComputePipeline p) { if (p !is null) { wgpuComputePipelineRelease(p); p = null; } }
        relBg(skyBg);
        foreach (s; 0 .. 2) {
            relBg(irrBg[s]);
            foreach (m; 0 .. IBL_SPECULAR_MIPS) { relBg(specBg[s][m]); relView(specStorageView[s][m]); }
            relBg(renderGroups[s]);
            relView(irrCubeView[s]); relView(specCubeView[s]); relView(irrStorageView[s]);
            relTex(irrTex[s]); relTex(specTex[s]);
        }
        relPipe(skyPipe); relPipe(irrPipe); relPipe(specPipe);
        if (csPipeLayout !is null) { wgpuPipelineLayoutRelease(csPipeLayout); csPipeLayout = null; }
        if (csLayout !is null) { wgpuBindGroupLayoutRelease(csLayout); csLayout = null; }
        if (csModule !is null) { wgpuShaderModuleRelease(csModule); csModule = null; }
        if (paramBuf !is null) { wgpuBufferRelease(paramBuf); paramBuf = null; }
        if (sampler !is null) { wgpuSamplerRelease(sampler); sampler = null; }
        relView(lutView); relTex(lutTex);
        relView(dummyView); relTex(dummyTex);
        relView(envCubeView); relView(envStorageView); relTex(envTex);
    }
}

private WGPUTexture createCube(WGPUDevice dev, uint size, uint mips, WGPUTextureUsage usage) @trusted {
    WGPUTextureDescriptor td;
    td.usage = usage;
    td.dimension = WGPUTextureDimension.dim2D;
    td.size = WGPUExtent3D(size, size, 6);
    td.format = WGPUTextureFormat.rgba16Float;
    td.mipLevelCount = mips;
    auto t = wgpuDeviceCreateTexture(dev, &td);
    if (t is null) fatal("DynamicIbl: cube texture creation failed");
    return t;
}

private WGPUTextureView cubeView(WGPUTexture t, uint baseMip, uint mips) @trusted {
    WGPUTextureViewDescriptor vd;
    vd.format = WGPUTextureFormat.rgba16Float;
    vd.dimension = WGPUTextureViewDimension.cube;
    vd.baseMipLevel = baseMip;
    vd.mipLevelCount = mips;
    vd.baseArrayLayer = 0;
    vd.arrayLayerCount = 6;
    return wgpuTextureCreateView(t, &vd);
}

private WGPUTextureView arrayView(WGPUTexture t, uint mip) @trusted {
    WGPUTextureViewDescriptor vd;
    vd.format = WGPUTextureFormat.rgba16Float;
    vd.dimension = WGPUTextureViewDimension.dim2DArray;
    vd.baseMipLevel = mip;
    vd.mipLevelCount = 1;
    vd.baseArrayLayer = 0;
    vd.arrayLayerCount = 6;
    return wgpuTextureCreateView(t, &vd);
}

unittest {
    SkyIblParams a, b;
    assert(!a.differsFrom(b));
    b.cloudCoverage = 0.5f;
    assert(a.differsFrom(b));
    b = a;
    b.sunDir = Vec3(0.3f, 0.80f, 0.4f);
    assert(a.differsFrom(b));
}
