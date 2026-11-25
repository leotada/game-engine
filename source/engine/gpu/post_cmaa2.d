/// CMAA2 in compute, in place on the LDR image. GPU objects are created on
/// first use.
module engine.gpu.post_cmaa2;

import bindings.wgpu;
import engine.core.log;
import engine.devtools.profiler : profileZone;
import engine.gpu.buffer : createBufferWithUsage, createStorageBuffer, createUniformBuffer, destroyBuffer, updateBuffer;
import engine.gpu.gpu_profiler : gpuScope;
import engine.gpu.post_util;
import engine.gpu.shader : createShaderModule, isValidUniformStruct;
import engine.gpu.shaders : cmaa2ShaderSource;

@safe:

/// GPU mirror of WGSL `Params` (`post_cmaa2.wgsl`).
private struct Cmaa2Params {
    uint[2] size;
    float threshold = 0.07f;
    float unused = 0;
}
static assert(isValidUniformStruct!Cmaa2Params);

private enum Stage { edges, argsProcess, process, argsApply, apply }
private enum STAGES = Stage.max + 1;
private enum BINDINGS = 11;
private static immutable uint[STAGES] stageBindings = [
    1 << 0 | 1 << 1 | 1 << 2 | 1 << 4 | 1 << 7 | 1 << 8,
    1 << 4 | 1 << 8 | 1 << 9,
    1 << 0 | 1 << 1 | 1 << 3 | 1 << 4 | 1 << 5 | 1 << 6 | 1 << 7 | 1 << 8,
    1 << 5 | 1 << 8 | 1 << 9,
    1 << 0 | 1 << 5 | 1 << 6 | 1 << 7 | 1 << 8 | 1 << 10,
];

/// Owned by `PostAa`.
struct Cmaa2Pass {
    private WGPUDevice device;
    private WGPUQueue queue;
    private WGPUShaderModule sm;
    private WGPUBindGroupLayout[STAGES] bgl;
    private WGPUPipelineLayout[STAGES] pl;
    private WGPUComputePipeline[STAGES] pipe;
    private WGPUBindGroup[STAGES] bg;
    private WGPUBuffer ubo, control, args;
    private WGPUBuffer candidates, locations, items, heads;
    private ulong candidateBytes, locationBytes, itemBytes, headBytes;
    private TexRT edges;
    private WGPUTextureView boundView;
    private uint width, height;

    @disable this(this);

    package(engine) void setup(WGPUDevice d, WGPUQueue q) nothrow @nogc {
        device = d;
        queue = q;
    }

    /// Filter `image` (rgba8unorm with storage usage) in place.
    package(engine) void run(WGPUCommandEncoder encoder, WGPUTextureView image, uint w, uint h, float threshold)
    nothrow @nogc @trusted {
        auto z = profileZone!"post.cmaa2"();
        auto g = gpuScope!"gpu.post.cmaa2"(encoder);
        ensurePipelines();
        ensureTargets(image, w, h);
        immutable p = Cmaa2Params([w, h], threshold > 0.01f ? threshold : 0.01f);
        updateBuffer(queue, ubo, (&p)[0 .. 1]);
        {
            auto ge = gpuScope!"gpu.post.cmaa2.edges"(encoder);
            dispatch(encoder, Stage.edges, ((w + 1) / 2 + 13) / 14, ((h + 1) / 2 + 13) / 14);
        }
        {
            auto gp = gpuScope!"gpu.post.cmaa2.shapes"(encoder);
            dispatch(encoder, Stage.argsProcess, 1, 1);
            dispatch(encoder, Stage.process, 0, 0);
        }
        auto ga = gpuScope!"gpu.post.cmaa2.apply"(encoder);
        dispatch(encoder, Stage.argsApply, 1, 1);
        dispatch(encoder, Stage.apply, 0, 0);
    }

    /// `x == 0`: indirect.
    private void dispatch(WGPUCommandEncoder encoder, Stage s, uint x, uint y) nothrow @nogc @trusted {
        WGPUComputePassDescriptor d;
        auto pass = wgpuCommandEncoderBeginComputePass(encoder, &d);
        wgpuComputePassEncoderSetPipeline(pass, pipe[s]);
        wgpuComputePassEncoderSetBindGroup(pass, 0, bg[s], 0, null);
        if (x == 0) wgpuComputePassEncoderDispatchWorkgroupsIndirect(pass, args, 0);
        else wgpuComputePassEncoderDispatchWorkgroups(pass, x, y, 1);
        wgpuComputePassEncoderEnd(pass);
        wgpuComputePassEncoderRelease(pass);
    }

    private void ensurePipelines() nothrow @nogc @trusted {
        if (sm !is null) return;
        sm = createShaderModule(device, cmaa2ShaderSource);
        if (sm is null) fatal("Failed to create the CMAA2 shader module");
        ubo = createUniformBuffer(device, Cmaa2Params.sizeof);
        control = createStorageBuffer(device, 16);
        args = createBufferWithUsage(device, 16, WGPUBufferUsage.storage | WGPUBufferUsage.indirect);
        static immutable string[STAGES] entries =
            ["cs_edges", "cs_args_process", "cs_process", "cs_args_apply", "cs_apply"];
        foreach (s; 0 .. STAGES) {
            WGPUBindGroupLayoutEntry[BINDINGS] e;
            uint n = 0;
            foreach (b; 0 .. BINDINGS) {
                if (!(stageBindings[s] >> b & 1)) continue;
                auto x = &e[n++];
                x.binding = b;
                x.visibility = WGPUShaderStage.compute;
                if (b == 0) x.buffer.type = WGPUBufferBindingType.uniform;
                else if (b == 1 || b == 3) {
                    x.texture.sampleType = b == 1 ? WGPUTextureSampleType.float_ : WGPUTextureSampleType.uint_;
                    x.texture.viewDimension = WGPUTextureViewDimension.dim2D;
                } else if (b == 2 || b == 10) {
                    x.storageTexture.access = WGPUStorageTextureAccess.writeOnly;
                    x.storageTexture.format = b == 2 ? WGPUTextureFormat.r32Uint : WGPUTextureFormat.rgba8Unorm;
                    x.storageTexture.viewDimension = WGPUTextureViewDimension.dim2D;
                } else x.buffer.type = WGPUBufferBindingType.storage;
            }
            WGPUBindGroupLayoutDescriptor d;
            d.entryCount = n;
            d.entries = e.ptr;
            bgl[s] = wgpuDeviceCreateBindGroupLayout(device, &d);
            WGPUPipelineLayoutDescriptor pd;
            pd.bindGroupLayoutCount = 1;
            pd.bindGroupLayouts = &bgl[s];
            pl[s] = wgpuDeviceCreatePipelineLayout(device, &pd);
            WGPUComputePipelineDescriptor cd;
            cd.layout = pl[s];
            cd.compute.module_ = sm;
            cd.compute.entryPoint = wgpuStringView(entries[s].ptr);
            pipe[s] = wgpuDeviceCreateComputePipeline(device, &cd);
            if (pipe[s] is null) fatal("Failed to create a CMAA2 pipeline");
        }
    }

    private void ensureTargets(WGPUTextureView image, uint w, uint h) nothrow @nogc @trusted {
        if (image is boundView && w == width && h == height) return;
        releaseTargets();
        boundView = image;
        width = w;
        height = h;
        immutable ulong quads = cast(ulong)((w + 1) / 2) * ((h + 1) / 2);
        headBytes = quads * 4;
        candidateBytes = quads * 4;  // one candidate per 4 pixels, as upstream
        locationBytes = quads * 4;
        itemBytes = quads * 2 * 8;   // one item per 2 pixels, as upstream
        heads = createStorageBuffer(device, headBytes);
        candidates = createStorageBuffer(device, candidateBytes);
        locations = createStorageBuffer(device, locationBytes);
        items = createStorageBuffer(device, itemBytes);
        edges = createRT(device, (w + 1) / 2, (h + 1) / 2, WGPUTextureFormat.r32Uint, WGPUTextureUsage.storageBinding);
        foreach (s; 0 .. STAGES) {
            WGPUBindGroupEntry[BINDINGS] e;
            uint n = 0;
            foreach (b; 0 .. BINDINGS) {
                if (!(stageBindings[s] >> b & 1)) continue;
                auto x = &e[n++];
                x.binding = b;
                final switch (b) {
                    case 0: x.buffer = ubo; x.size = Cmaa2Params.sizeof; break;
                    case 1: case 10: x.textureView = image; break;
                    case 2: case 3: x.textureView = edges.view; break;
                    case 4: x.buffer = candidates; x.size = candidateBytes; break;
                    case 5: x.buffer = locations; x.size = locationBytes; break;
                    case 6: x.buffer = items; x.size = itemBytes; break;
                    case 7: x.buffer = heads; x.size = headBytes; break;
                    case 8: x.buffer = control; x.size = 16; break;
                    case 9: x.buffer = args; x.size = 16; break;
                }
            }
            WGPUBindGroupDescriptor d;
            d.layout = bgl[s];
            d.entryCount = n;
            d.entries = e.ptr;
            bg[s] = wgpuDeviceCreateBindGroup(device, &d);
        }
    }

    package(engine) void releaseTargets() nothrow @nogc @trusted {
        foreach (ref b; bg) if (b !is null) { wgpuBindGroupRelease(b); b = null; }
        edges.release();
        destroyBuffer(heads); heads = null;
        destroyBuffer(candidates); candidates = null;
        destroyBuffer(locations); locations = null;
        destroyBuffer(items); items = null;
        boundView = null;
        width = height = 0;
    }

    package(engine) void destroy() nothrow @nogc @trusted {
        releaseTargets();
        foreach (s; 0 .. STAGES) {
            if (pipe[s] !is null) { wgpuComputePipelineRelease(pipe[s]); pipe[s] = null; }
            if (pl[s] !is null) { wgpuPipelineLayoutRelease(pl[s]); pl[s] = null; }
            if (bgl[s] !is null) { wgpuBindGroupLayoutRelease(bgl[s]); bgl[s] = null; }
        }
        destroyBuffer(ubo); ubo = null;
        destroyBuffer(control); control = null;
        destroyBuffer(args); args = null;
        if (sm !is null) { wgpuShaderModuleRelease(sm); sm = null; }
    }
}
