/// SMAA 1x (edges, blending weights, neighborhood blending). GPU objects are
/// created on first use.
module engine.gpu.post_smaa;

import bindings.wgpu;
import engine.core.log;
import engine.devtools.profiler : profileZone;
import engine.gpu.buffer : createUniformBuffer, destroyBuffer, updateBuffer;
import engine.gpu.gpu_profiler : gpuScope;
import engine.gpu.post_util;
import engine.gpu.shader : createShaderModule, isValidUniformStruct;
import engine.gpu.shaders : smaaShaderSource;

@safe:

/// GPU mirror of WGSL `Params` (`post_smaa.wgsl`).
private struct SmaaParams {
    float[4] rt;
    float[4] a = 0;
}
static assert(isValidUniformStruct!SmaaParams);

// Subtexture 0 of the SMAA area table (160x80 RG8), then the search table
// (64x16 R8). MIT, see docs/third-party-licenses.md.
private immutable ubyte[] smaaTables = cast(immutable ubyte[]) import("smaa_tables.bin");
private enum AREA_W = 160, AREA_H = 80, SEARCH_W = 64, SEARCH_H = 16;
static assert(import("smaa_tables.bin").length == AREA_W * AREA_H * 2 + SEARCH_W * SEARCH_H);

/// Owned by `PostAa`.
struct SmaaPass {
    private WGPUDevice device;
    private WGPUQueue queue;
    private WGPUSampler sampler; // borrowed, linear clamp
    private WGPUShaderModule sm;
    private WGPUBindGroupLayout bgl;
    private WGPUPipelineLayout pl;
    private WGPURenderPipeline edgePipe, weightPipe;
    private WGPURenderPipeline[2] blendPipe; // display format, LDR format
    private WGPUBuffer ubo;
    private TexRT areaTex, searchTex, dummy;
    private TexRT edgesRT, weightsRT;

    @disable this(this);

    package(engine) void setup(WGPUDevice d, WGPUQueue q, WGPUSampler s) nothrow @nogc {
        device = d;
        queue = q;
        sampler = s;
    }

    package(engine) void run(WGPUCommandEncoder encoder, WGPUTextureView src, WGPUTextureView dst,
                             WGPUTextureFormat dstFormat, bool toSurface, uint w, uint h, float threshold)
    nothrow @nogc @trusted {
        auto z = profileZone!"post.smaa"();
        auto g = gpuScope!"gpu.post.smaa"(encoder);
        ensure();
        immutable slot = toSurface ? 0 : 1;
        if (blendPipe[slot] is null) blendPipe[slot] = makePipe("fs_blend", dstFormat);
        if (edgesRT.width != w || edgesRT.height != h) {
            releaseTargets();
            edgesRT = createRT(device, w, h, WGPUTextureFormat.rg8Unorm);
            weightsRT = createRT(device, w, h, WGPUTextureFormat.rgba8Unorm);
        }
        SmaaParams p;
        p.rt = [1.0f / w, 1.0f / h, w, h];
        p.a[0] = threshold > 0.01f ? threshold : 0.01f;
        updateBuffer(queue, ubo, (&p)[0 .. 1]);
        pass!"gpu.post.smaa.edges"(encoder, edgesRT.view, edgePipe, src, dummy.view, dummy.view);
        pass!"gpu.post.smaa.weights"(encoder, weightsRT.view, weightPipe, edgesRT.view, areaTex.view, searchTex.view);
        pass!"gpu.post.smaa.blend"(encoder, dst, blendPipe[slot], src, weightsRT.view, dummy.view);
    }

    private void pass(string zone)(WGPUCommandEncoder encoder, WGPUTextureView target, WGPURenderPipeline pipe,
                                   WGPUTextureView t0, WGPUTextureView t1, WGPUTextureView t2) nothrow @nogc @trusted {
        auto g = gpuScope!zone(encoder);
        WGPUBindGroupEntry[5] e;
        foreach (i, ref x; e) x.binding = cast(uint) i;
        e[0].buffer = ubo;
        e[0].size = SmaaParams.sizeof;
        e[1].sampler = sampler;
        e[2].textureView = t0;
        e[3].textureView = t1;
        e[4].textureView = t2;
        WGPUBindGroupDescriptor d;
        d.layout = bgl;
        d.entryCount = e.length;
        d.entries = e.ptr;
        auto bg = wgpuDeviceCreateBindGroup(device, &d);
        drawPass(encoder, target, pipe, bg, true);
        wgpuBindGroupRelease(bg);
    }

    private void ensure() nothrow @nogc @trusted {
        if (sm !is null) return;
        sm = createShaderModule(device, smaaShaderSource);
        if (sm is null) fatal("Failed to create the SMAA shader module");
        WGPUBindGroupLayoutEntry[5] e;
        foreach (i, ref x; e) {
            x.binding = cast(uint) i;
            x.visibility = WGPUShaderStage.fragment;
            if (i == 0) {
                x.buffer.type = WGPUBufferBindingType.uniform;
                x.buffer.minBindingSize = SmaaParams.sizeof;
            } else if (i == 1) {
                x.sampler.type = WGPUSamplerBindingType.filtering;
            } else {
                x.texture.sampleType = WGPUTextureSampleType.float_;
                x.texture.viewDimension = WGPUTextureViewDimension.dim2D;
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
        ubo = createUniformBuffer(device, SmaaParams.sizeof);
        edgePipe = makePipe("fs_edges", WGPUTextureFormat.rg8Unorm);
        weightPipe = makePipe("fs_weights", WGPUTextureFormat.rgba8Unorm);
        dummy = createRT(device, 1, 1, WGPUTextureFormat.rgba8Unorm);
        areaTex = createRT(device, AREA_W, AREA_H, WGPUTextureFormat.rg8Unorm, WGPUTextureUsage.copyDst);
        searchTex = createRT(device, SEARCH_W, SEARCH_H, WGPUTextureFormat.r8Unorm, WGPUTextureUsage.copyDst);
        upload(areaTex, smaaTables[0 .. AREA_W * AREA_H * 2], AREA_W * 2);
        upload(searchTex, smaaTables[AREA_W * AREA_H * 2 .. $], SEARCH_W);
    }

    private void upload(ref TexRT t, scope const(ubyte)[] data, uint pitch) nothrow @nogc @trusted {
        WGPUImageCopyTexture dst;
        dst.texture = t.texture;
        WGPUTextureDataLayout layout;
        layout.bytesPerRow = pitch;
        layout.rowsPerImage = t.height;
        immutable extent = WGPUExtent3D(t.width, t.height, 1);
        wgpuQueueWriteTexture(queue, &dst, data.ptr, data.length, &layout, &extent);
    }

    private WGPURenderPipeline makePipe(const(char)* entry, WGPUTextureFormat fmt) nothrow @nogc @trusted {
        WGPUColorTargetState ct;
        ct.format = fmt;
        ct.writeMask = WGPUColorWriteMask.all;
        WGPUFragmentState fs;
        fs.module_ = sm;
        fs.entryPoint = wgpuStringView(entry);
        fs.targetCount = 1;
        fs.targets = &ct;
        WGPURenderPipelineDescriptor desc;
        desc.layout = pl;
        desc.vertex.module_ = sm;
        desc.vertex.entryPoint = wgpuStringView("vs_main");
        desc.fragment = &fs;
        desc.primitive.topology = WGPUPrimitiveTopology.triangleList;
        auto p = wgpuDeviceCreateRenderPipeline(device, &desc);
        if (p is null) fatal("Failed to create a SMAA pipeline");
        return p;
    }

    package(engine) void releaseTargets() nothrow @nogc {
        edgesRT.release();
        weightsRT.release();
    }

    package(engine) void destroy() nothrow @nogc @trusted {
        releaseTargets();
        areaTex.release();
        searchTex.release();
        dummy.release();
        if (edgePipe !is null) { wgpuRenderPipelineRelease(edgePipe); edgePipe = null; }
        if (weightPipe !is null) { wgpuRenderPipelineRelease(weightPipe); weightPipe = null; }
        foreach (ref p; blendPipe) if (p !is null) { wgpuRenderPipelineRelease(p); p = null; }
        if (pl !is null) { wgpuPipelineLayoutRelease(pl); pl = null; }
        if (bgl !is null) { wgpuBindGroupLayoutRelease(bgl); bgl = null; }
        destroyBuffer(ubo);
        ubo = null;
        if (sm !is null) { wgpuShaderModuleRelease(sm); sm = null; }
    }
}
