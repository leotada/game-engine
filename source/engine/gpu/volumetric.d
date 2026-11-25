/// Volumetric light (single scattering) of the sun and the local lights,
/// composited between the opaque / water passes and the alpha passes.
module engine.gpu.volumetric;

import bindings.wgpu;
import engine.core.log;
import engine.devtools.profiler : profileZone;
import engine.gpu.gpu_profiler : gpuScope;
import engine.gpu.post_util;
import engine.gpu.shader : createShaderModule, isValidUniformStruct;
import engine.gpu.shaders : volumetricShaderSource;
import engine.scene.camera : Camera;
import core.stdc.math : tanf;

@safe:

/// March steps per ray.
enum VolumetricQuality : ubyte {
    low,    /// 12
    medium, /// 20
    high,   /// 32
    ultra,  /// 64
}

/// Volumetric light (`Renderer.volumetrics`). Off by default.
struct VolumetricSettings {
    bool enabled = false;
    /// Extinction per world unit at `baseHeight` (0.02 = light haze, 0.1 = thick fog).
    float density = 0.02f;
    /// Exponential decrease of the density with height (0 = uniform).
    float heightFalloff = 0;
    float baseHeight = 0;
    /// Forward scattering, -0.9..0.9 (0 = same in every direction).
    float anisotropy = 0.5f;
    /// Scattering color of the medium and brightness of the result.
    float[3] albedo = [1, 1, 1];
    float intensity = 1;
    /// Share of the sun and of the point / spot lights (0 skips them).
    float sunScale = 1, localScale = 1;
    /// Constant light inside the medium.
    float[3] ambient = [0, 0, 0];
    /// The march ends here (world units).
    float maxDistance = 100;
    /// Also darken the scene behind by the transmittance. Leave it off when the
    /// analytic fog already does.
    bool attenuate = false;
    VolumetricQuality quality = VolumetricQuality.medium;
    /// Explicit steps (max 128); 0 = from `quality`.
    ubyte steps = 0;
    /// Quarter instead of half resolution.
    bool quarterResolution = false;
}

private enum MAX_SCENES = 4; /// scenes per frame (split screen)
private enum uint UBO_STRIDE = 256;
private enum FORMAT = WGPUTextureFormat.rgba16Float;

/// GPU mirror of WGSL `VolParams` (`volumetric.wgsl`).
private struct VolParams {
    float[4] viewport, proj, a, b, c, d;

    static VolParams make(ref const VolumetricSettings s, ref const Camera cam, float[4] vp) nothrow @nogc @trusted {
        static float pos(float v) pure nothrow @nogc { return v > 0 ? v : 0; }
        immutable t = tanf(cam.fovY * 0.5f);
        static immutable float[4] effort = [12, 20, 32, 64];
        immutable float steps = s.steps ? (s.steps < 128 ? s.steps : 128) : effort[s.quality];
        immutable g = s.anisotropy < -0.9f ? -0.9f : s.anisotropy > 0.9f ? 0.9f : s.anisotropy;
        VolParams p;
        p.viewport = vp;
        p.proj = [t * cam.aspect, t, cam.near, cam.far];
        p.a = [pos(s.density), pos(s.heightFalloff), s.baseHeight, g];
        p.b = [s.maxDistance > 1 ? s.maxDistance : 1, steps, s.quarterResolution ? 4 : 2, s.attenuate ? 1 : 0];
        p.c = [s.albedo[0] * pos(s.intensity), s.albedo[1] * pos(s.intensity), s.albedo[2] * pos(s.intensity), pos(s.sunScale)];
        p.d = [s.ambient[0], s.ambient[1], s.ambient[2], pos(s.localScale)];
        return p;
    }
}
static assert(VolParams.sizeof == 96 && isValidUniformStruct!VolParams);

private enum Pipe { march, blurX, blurY, composite }

/// Owned by `Renderer`. GPU objects are created on first use.
struct VolumetricPass {
    private WGPUDevice device;
    private WGPUQueue queue;
    private WGPUShaderModule sm;
    private WGPUBindGroupLayout bgl;
    private WGPUPipelineLayout pl;
    private WGPUBuffer ubo;
    private WGPURenderPipeline[Pipe.max + 1] pipes;
    private TexRT dummy, rtA, rtB;
    private WGPUBindGroup marchBg, blurXBg, blurYBg, compositeBg;
    private WGPUTextureView boundDepth;
    private uint width, height, divisor;
    private uint sceneCount;

    @disable this(this);

    package(engine) void setup(WGPUDevice d, WGPUQueue q) nothrow @nogc { device = d; queue = q; }

    package(engine) void beginFrame() nothrow @nogc { sceneCount = 0; }

    package(engine) bool available() const nothrow @nogc { return device !is null && sceneCount < MAX_SCENES; }

    /// `frameLayout` / `frameGroup`: group 0 of the scene (lights, shadows, clusters).
    package(engine) void run(WGPUCommandEncoder encoder, WGPUTextureView color, WGPUTextureView depth,
                             uint w, uint h, float[4] viewport, ref const VolumetricSettings s, ref const Camera cam,
                             WGPUBindGroupLayout frameLayout, WGPUBindGroup frameGroup) nothrow @nogc @trusted {
        auto z = profileZone!"scene.volumetric"();
        auto g = gpuScope!"gpu.volumetric"(encoder);
        ensurePipelines(frameLayout);
        ensureTargets(depth, w, h, s.quarterResolution ? 4 : 2);
        immutable uint offset = sceneCount++ * UBO_STRIDE;
        immutable p = VolParams.make(s, cam, viewport);
        wgpuQueueWriteBuffer(queue, ubo, offset, &p, p.sizeof);
        immutable x0 = clampTo(viewport[0], w), y0 = clampTo(viewport[1], h);
        immutable x1 = clampTo(viewport[0] + viewport[2], w), y1 = clampTo(viewport[1] + viewport[3], h);
        if (x1 <= x0 || y1 <= y0) return;
        {
            auto gm = gpuScope!"gpu.volumetric.march"(encoder);
            pass(encoder, rtA.view, Pipe.march, frameGroup, marchBg, offset, null);
        }
        {
            auto gb = gpuScope!"gpu.volumetric.blur"(encoder);
            pass(encoder, rtB.view, Pipe.blurX, frameGroup, blurXBg, offset, null);
            pass(encoder, rtA.view, Pipe.blurY, frameGroup, blurYBg, offset, null);
        }
        auto gc = gpuScope!"gpu.volumetric.composite"(encoder);
        immutable uint[4] scissor = [x0, y0, x1 - x0, y1 - y0];
        pass(encoder, color, Pipe.composite, frameGroup, compositeBg, offset, &scissor);
    }

    private static uint clampTo(float v, uint limit) pure nothrow @nogc {
        return v <= 0 ? 0 : v >= limit ? limit : cast(uint)(v + 0.5f);
    }

    private void pass(WGPUCommandEncoder encoder, WGPUTextureView target, Pipe k, WGPUBindGroup frameGroup,
                      WGPUBindGroup bg, uint offset, scope const(uint[4])* scissor) nothrow @nogc @trusted {
        WGPURenderPassColorAttachment ca;
        ca.view = target;
        ca.loadOp = scissor is null ? WGPULoadOp.clear : WGPULoadOp.load;
        ca.storeOp = WGPUStoreOp.store;
        ca.depthSlice = WGPU_DEPTH_SLICE_UNDEFINED;
        WGPURenderPassDescriptor pd;
        pd.colorAttachmentCount = 1;
        pd.colorAttachments = &ca;
        auto rp = wgpuCommandEncoderBeginRenderPass(encoder, &pd);
        if (scissor !is null)
            wgpuRenderPassEncoderSetScissorRect(rp, (*scissor)[0], (*scissor)[1], (*scissor)[2], (*scissor)[3]);
        wgpuRenderPassEncoderSetPipeline(rp, pipes[k]);
        wgpuRenderPassEncoderSetBindGroup(rp, 0, frameGroup, 0, null);
        wgpuRenderPassEncoderSetBindGroup(rp, 1, bg, 1, &offset);
        wgpuRenderPassEncoderDraw(rp, 3, 1, 0, 0);
        wgpuRenderPassEncoderEnd(rp);
        wgpuRenderPassEncoderRelease(rp);
    }

    private void ensurePipelines(WGPUBindGroupLayout frameLayout) nothrow @nogc @trusted {
        if (sm !is null) return;
        sm = createShaderModule(device, volumetricShaderSource, "volumetric");
        if (sm is null) fatal("Failed to create the volumetric shader module");
        WGPUBindGroupLayoutEntry[3] e;
        foreach (i, ref x; e) {
            x.binding = cast(uint) i;
            x.visibility = WGPUShaderStage.fragment;
            if (i == 0) {
                x.buffer.type = WGPUBufferBindingType.uniform;
                x.buffer.hasDynamicOffset = WGPU_TRUE;
                x.buffer.minBindingSize = VolParams.sizeof;
            } else {
                x.texture.sampleType = i == 1 ? WGPUTextureSampleType.depth : WGPUTextureSampleType.unfilterableFloat;
                x.texture.viewDimension = WGPUTextureViewDimension.dim2D;
            }
        }
        WGPUBindGroupLayoutDescriptor ld;
        ld.entryCount = e.length;
        ld.entries = e.ptr;
        bgl = wgpuDeviceCreateBindGroupLayout(device, &ld);
        WGPUBindGroupLayout[2] layouts = [frameLayout, bgl];
        WGPUPipelineLayoutDescriptor pld;
        pld.bindGroupLayoutCount = 2;
        pld.bindGroupLayouts = layouts.ptr;
        pl = wgpuDeviceCreatePipelineLayout(device, &pld);
        WGPUBufferDescriptor bd;
        bd.usage = WGPUBufferUsage.uniform | WGPUBufferUsage.copyDst;
        bd.size = UBO_STRIDE * MAX_SCENES;
        ubo = wgpuDeviceCreateBuffer(device, &bd);
        dummy = createRT(device, 1, 1, FORMAT);
        static immutable string[Pipe.max + 1] entries = ["fs_march", "fs_blur_x", "fs_blur_y", "fs_composite"];
        foreach (k; 0 .. pipes.length) {
            WGPUBlendState blend;
            blend.color.operation = WGPUBlendOperation.add;
            blend.color.srcFactor = WGPUBlendFactor.one;
            blend.color.dstFactor = WGPUBlendFactor.srcAlpha;
            blend.alpha.operation = WGPUBlendOperation.add;
            blend.alpha.srcFactor = WGPUBlendFactor.zero;
            blend.alpha.dstFactor = WGPUBlendFactor.one;
            WGPUColorTargetState ct;
            ct.format = FORMAT;
            ct.writeMask = WGPUColorWriteMask.all;
            if (k == Pipe.composite) {
                import engine.gpu.post : SCENE_COLOR_FORMAT;
                ct.format = SCENE_COLOR_FORMAT;
                ct.blend = &blend;
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
            if (pipes[k] is null) fatal("Failed to create a volumetric pipeline");
        }
    }

    private void ensureTargets(WGPUTextureView depth, uint w, uint h, uint div) nothrow @nogc @trusted {
        if (w == width && h == height && div == divisor && depth is boundDepth) return;
        releaseTargets();
        width = w; height = h; divisor = div; boundDepth = depth;
        rtA = createRT(device, (w + div - 1) / div, (h + div - 1) / div, FORMAT);
        rtB = createRT(device, rtA.width, rtA.height, FORMAT);
        marchBg = group(dummy.view);
        blurXBg = group(rtA.view);
        blurYBg = group(rtB.view);
        compositeBg = group(rtA.view);
    }

    private WGPUBindGroup group(WGPUTextureView scatter) nothrow @nogc @trusted {
        WGPUBindGroupEntry[3] e;
        foreach (i, ref x; e) x.binding = cast(uint) i;
        e[0].buffer = ubo;
        e[0].size = VolParams.sizeof;
        e[1].textureView = boundDepth;
        e[2].textureView = scatter;
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
        drop(marchBg); drop(blurXBg); drop(blurYBg); drop(compositeBg);
        rtA.release();
        rtB.release();
        boundDepth = null;
        width = height = divisor = 0;
    }

    package(engine) void destroy() nothrow @nogc @trusted {
        releaseTargets();
        dummy.release();
        foreach (ref p; pipes) if (p !is null) { wgpuRenderPipelineRelease(p); p = null; }
        if (pl !is null) { wgpuPipelineLayoutRelease(pl); pl = null; }
        if (bgl !is null) { wgpuBindGroupLayoutRelease(bgl); bgl = null; }
        if (ubo !is null) { wgpuBufferRelease(ubo); ubo = null; }
        if (sm !is null) { wgpuShaderModuleRelease(sm); sm = null; }
    }
}

@("volumetric.params") @safe unittest {
    VolumetricSettings s;
    assert(!s.enabled && !s.attenuate);
    s.density = -1;
    s.anisotropy = 4;
    s.steps = 200;
    s.quarterResolution = true;
    s.albedo = [1.0f, 0.5f, 0.0f];
    s.intensity = 2;
    Camera c = Camera.create(1.5707964f, 2.0f, 0.5f, 60.0f);
    immutable p = VolParams.make(s, c, [0.0f, 0.0f, 200.0f, 100.0f]);
    assert(p.a[0] == 0 && p.a[3] == 0.9f);
    assert(p.b[1] == 128 && p.b[2] == 4 && p.b[3] == 0);
    assert(p.c == [2.0f, 1.0f, 0.0f, 1.0f]);
    s.steps = 0;
    s.quality = VolumetricQuality.high;
    assert(VolParams.make(s, c, [0.0f, 0.0f, 1.0f, 1.0f]).b[1] == 32);
}
