/// Water surface renderer: draws up to `MAX_WATER_BODIES` water bodies after
/// the sky (transparent hook), runs their wave/foam simulation and feeds the
/// shared water data (frame binding 10) every frame.
///
/// ```d
/// auto water = WaterRenderer.create(app.gpu, scene);
/// scope(exit) water.destroy();
/// water.attach(scene, app.renderer);           // `water`, `scene`, `renderer` must not move
/// immutable id = water.addBody(WaterBody.ocean());
/// // per frame, before beginFrame:
/// water.update(camera, time);
/// ```
module engine.water.renderer;

import bindings.wgpu;
import engine.core.log : fatal, info;
import engine.gpu.buffer : createIndexBuffer, createUniformBuffer, createVertexBuffer,
    destroyBuffer, releaseBindGroup, updateBuffer;
import engine.gpu.context : GpuContext;
import engine.gpu.renderer : FrameContext, Renderer;
import engine.gpu.shader : createShaderModule;
import engine.gpu.shaders : waterSimCsShaderSource, waterSurfaceShaderSource;
import engine.graphics.types : TexVert;
import engine.scene.camera : Camera;
import engine.scene.scene3d_textured : Scene3DTextured;
import engine.water.query : WaterSurfacePoint, waterBodyContains, waterSurfaceAt;
import engine.water.water_body;
import engine.water.gpu_data : GpuWaterData, MAX_WATER_BODIES, packWaterBody;

@safe:

/// Resolution of each body's wave/foam simulation texture.
enum uint WATER_SIM_RES = 256;

// Module-level immutables: using the CTFE-built shader `enum`s directly
// inside a function crashes DMD 2.113's backend (stack overflow).
private immutable string surfaceShaderSrc = waterSurfaceShaderSource;
private immutable string simShaderSrc = waterSimCsShaderSource;

/// Largest grid resolution (16-bit indices).
enum uint MAX_WATER_GRID = 254;

/// GPU payload matching `WaterUniforms` in `assets/shaders/common/water_env.wgsl`.
struct WaterSurfaceUniforms {
    float[4] params0;      // x = time, y = amplitudeScale, z = near, w = far
    uint[4]  flags0;       // x = style, y = openPbr, z = transparent, w = grid resolution
    uint[4]  counts;       // x = obstacleCount, y = body index, z = refraction, w = SSR
    float[4] area;         // xy = center, z = halfExtent, w = level
    float[4] flow;         // xy = current, z = flow profile half width, w = bedDepth
    float[4] channel;      // xy = channel origin, zw = channel direction
    float[4] absorption;   // rgb = sigma, w = roughness
    float[4] shallowColor; // rgb, w = anisotropy
    float[4] deepColor;
    float[4] coatColor;    // rgb, w = causticsStrength
    float[4] sssTint;
    float[4][MAX_WATER_OBSTACLES] obstacles; // x, z, radius, strength
}
static assert(WaterSurfaceUniforms.sizeof == 432);

/// Fills the surface uniforms for one body (`bodyIndex` = its slot in `GpuWaterData`).
WaterSurfaceUniforms packWaterSurfaceUniforms(ref const WaterBody b, uint bodyIndex,
                                              scope const(WaterObstacle)[] obstacles,
                                              float time, float near, float far) pure nothrow @nogc {
    WaterSurfaceUniforms u;
    u.params0 = [time, b.waves.amplitudeScale, near, far];
    u.flags0 = [cast(uint) b.style, b.has(WaterFeature.openPbr) ? 1u : 0u,
                b.has(WaterFeature.transparent) ? 1u : 0u, clampGrid(b.gridResolution)];
    u.counts = [0u, bodyIndex, b.has(WaterFeature.refraction) ? 1u : 0u,
                b.has(WaterFeature.ssr) ? 1u : 0u];
    u.area = [b.centerX, b.centerZ, b.halfExtent, b.level];
    u.flow = [b.flow[0], b.flow[1], b.flowProfileWidth, b.bedDepth];
    immutable ch = b.waves.channel;
    u.channel = [ch.originX, ch.originZ, ch.dirX, ch.dirZ];
    immutable o = b.optics;
    u.absorption = [o.absorption[0], o.absorption[1], o.absorption[2], o.roughness];
    u.shallowColor = [o.shallowColor[0], o.shallowColor[1], o.shallowColor[2], o.anisotropy];
    u.deepColor = [o.deepColor[0], o.deepColor[1], o.deepColor[2], 0.0f];
    u.coatColor = [o.coatColor[0], o.coatColor[1], o.coatColor[2], b.causticsStrength];
    u.sssTint = [o.sssTint[0], o.sssTint[1], o.sssTint[2], 0.0f];
    uint n = 0;
    foreach (ref ob; obstacles) {
        if (n >= MAX_WATER_OBSTACLES) break;
        u.obstacles[n++] = [ob.x, ob.z, ob.radius, ob.strength];
    }
    u.counts[0] = n;
    return u;
}

private uint clampGrid(uint r) pure nothrow @nogc {
    return r < 2 ? 2 : (r > MAX_WATER_GRID ? MAX_WATER_GRID : r);
}

/// GPU state of one water body.
private struct BodySlot {
    bool used;
    WaterBody desc;
    WaterObstacle[MAX_WATER_OBSTACLES] obstacles;
    uint obstacleCount;

    WGPUBuffer ubo;
    WGPUTexture[2] simTex;
    WGPUTextureView[2] simView;
    WGPUBindGroup[2] simBg;
    WGPUBindGroup[2] surfaceBg;
    WGPUTextureView boundColor;
    WGPUTextureView boundDepth;
    uint ping;

    WGPUBuffer vbuf;
    WGPUBuffer ibuf;
    ulong vSize;
    ulong iSize;
    uint indexCount;
    uint gridRes;
}

/// Draws and simulates water bodies. Move-only; keep it at a stable address
/// after `attach`.
struct WaterRenderer {
    private WGPUDevice device;
    private WGPUQueue queue;
    private WGPUBindGroupLayout surfaceLayout;
    private WGPUBindGroupLayout simLayout;
    private WGPUPipelineLayout surfacePipeLayout;
    private WGPUPipelineLayout simPipeLayout;
    private WGPUShaderModule surfaceModule;
    private WGPUShaderModule simModule;
    private WGPURenderPipeline surfacePipe;
    private WGPUComputePipeline simPipe;
    private WGPUSampler sampler;
    private BodySlot[MAX_WATER_BODIES] slots;
    private Scene3DTextured* scene;
    private Renderer* renderer;

    @disable this(this);

    /// Builds the pipelines. Bodies are added with `addBody`.
    static WaterRenderer create(ref GpuContext gpu, ref Scene3DTextured scene) @trusted {
        WaterRenderer r;
        r.device = gpu.getDevice();
        r.queue = gpu.getQueue();
        r.surfaceLayout = createSurfaceLayout(r.device);
        r.simLayout = createSimLayout(r.device);
        r.sampler = createLinearClampSampler(r.device);
        r.surfacePipeLayout = createPipelineLayout3(r.device,
            scene.frameLayout(), r.surfaceLayout, scene.iblLayout());
        r.simPipeLayout = createPipelineLayout1(r.device, r.simLayout);
        r.surfaceModule = createShaderModule(r.device, surfaceShaderSrc);
        r.simModule = createShaderModule(r.device, simShaderSrc);
        if (r.surfaceModule is null || r.simModule is null) fatal("Water shader compile failed");
        r.surfacePipe = createSurfacePipeline(r.device, r.surfacePipeLayout, r.surfaceModule);
        r.simPipe = createSimPipeline(r.device, r.simPipeLayout, r.simModule);
        if (r.surfacePipe is null || r.simPipe is null) fatal("Water pipeline creation failed");
        return r;
    }

    /// Registers the transparent draw hook (after the sky, before alpha
    /// batches). `this`, `scene` and `renderer` must not move afterwards.
    void attach(ref Scene3DTextured scene, ref Renderer renderer) @trusted {
        this.scene = &scene;
        this.renderer = &renderer;
        scene.addTransparentHook(&draw);
    }

    /// Adds a body and returns its id, or -1 when all `MAX_WATER_BODIES`
    /// slots are used. Allocates GPU resources (not for the frame loop).
    int addBody(ref const WaterBody b) @trusted {
        foreach (i, ref s; slots) {
            if (s.used) continue;
            s.used = true;
            s.desc = b;
            s.obstacleCount = 0;
            s.ping = 0;
            s.ubo = createUniformBuffer(device, WaterSurfaceUniforms.sizeof);
            createSimTargets(s);
            buildGrid(s, clampGrid(b.gridResolution));
            info("Water body ", i, ": ", b.style == WaterStyle.ocean ? "ocean" : "river",
                 " half=", b.halfExtent, " grid=", s.gridRes);
            return cast(int) i;
        }
        return -1;
    }

    /// Frees a body's GPU resources; its id becomes free for reuse.
    void removeBody(int id) nothrow @nogc @trusted {
        if (!valid(id)) return;
        releaseSlot(slots[id]);
    }

    /// Replaces a body's settings (any frame). A different `gridResolution`
    /// takes effect only through `setGridResolution`.
    void setBody(int id, ref const WaterBody b) nothrow @nogc {
        if (!valid(id)) return;
        immutable res = slots[id].desc.gridResolution;
        slots[id].desc = b;
        slots[id].desc.gridResolution = res;
    }

    /// Rebuilds a body's surface grid (allocates; not for the frame loop).
    void setGridResolution(int id, uint resolution) @trusted {
        if (!valid(id)) return;
        auto s = &slots[id];
        immutable res = clampGrid(resolution);
        s.desc.gridResolution = res;
        if (res == s.gridRes) return;
        destroyBuffer(s.vbuf);
        destroyBuffer(s.ibuf);
        buildGrid(*s, res);
    }

    /// Current settings of a body (`WaterBody.init` for an invalid id).
    WaterBody bodyAt(int id) const nothrow @nogc {
        return valid(id) ? slots[id].desc : WaterBody.init;
    }

    /// Obstacles (rocks, piers) for a body; at most `MAX_WATER_OBSTACLES` are kept.
    void setObstacles(int id, scope const(WaterObstacle)[] obstacles) nothrow @nogc {
        if (!valid(id)) return;
        uint n = 0;
        foreach (ref ob; obstacles) {
            if (n >= MAX_WATER_OBSTACLES) break;
            slots[id].obstacles[n++] = ob;
        }
        slots[id].obstacleCount = n;
    }

    /// Water surface above world `xz` at `time`, from the first body (in GPU
    /// order) containing the point; false outside every body. CPU-side, the
    /// same waves the GPU draws (see `engine.water.query`).
    bool surfaceAt(float x, float z, float time, out WaterSurfacePoint result,
                   uint iterations = 3) const nothrow @nogc {
        foreach (ref s; slots) {
            if (!s.used || !waterBodyContains(s.desc, x, z)) continue;
            result = waterSurfaceAt(s.desc, x, z, time, iterations);
            return true;
        }
        return false;
    }

    /// Number of active bodies.
    uint bodyCount() const nothrow @nogc {
        uint n = 0;
        foreach (ref s; slots) if (s.used) ++n;
        return n;
    }

    /// Per frame, before `beginFrame`: uploads the shared water data and the
    /// surface uniforms, and steps the simulations. Also sets the scene time.
    void update(ref const Camera camera, float time) nothrow @nogc @trusted {
        if (scene is null) return;
        scene.setTime(time);
        GpuWaterData data;
        WGPUCommandEncoder enc;
        WGPUComputePassEncoder pass;
        foreach (ref s; slots) {
            if (!s.used) continue;
            immutable uint index = data.count();
            immutable gp = s.desc.gpuParams();
            data.add(packWaterBody(s.desc.waves, gp));
            auto u = packWaterSurfaceUniforms(s.desc, index, s.obstacles[0 .. s.obstacleCount],
                                              time, camera.near, camera.far);
            updateBuffer(queue, s.ubo, &u, WaterSurfaceUniforms.sizeof);
            if (!s.desc.has(WaterFeature.simulation)) continue;
            if (pass is null) {
                WGPUCommandEncoderDescriptor ced;
                enc = wgpuDeviceCreateCommandEncoder(device, &ced);
                WGPUComputePassDescriptor cpd;
                pass = wgpuCommandEncoderBeginComputePass(enc, &cpd);
                wgpuComputePassEncoderSetPipeline(pass, simPipe);
            }
            wgpuComputePassEncoderSetBindGroup(pass, 0, s.simBg[s.ping], 0, null);
            wgpuComputePassEncoderDispatchWorkgroups(pass, WATER_SIM_RES / 8, WATER_SIM_RES / 8, 1);
            s.ping ^= 1u;
        }
        scene.setWaterData(data);
        if (pass is null) return;
        wgpuComputePassEncoderEnd(pass);
        wgpuComputePassEncoderRelease(pass);
        WGPUCommandBufferDescriptor cbd;
        auto cmd = wgpuCommandEncoderFinish(enc, &cbd);
        wgpuCommandEncoderRelease(enc);
        wgpuQueueSubmit(queue, 1, &cmd);
        wgpuCommandBufferRelease(cmd);
    }

    /// Releases every GPU resource.
    void destroy() nothrow @nogc @trusted {
        foreach (ref s; slots) if (s.used) releaseSlot(s);
        if (simPipe !is null) { wgpuComputePipelineRelease(simPipe); simPipe = null; }
        if (surfacePipe !is null) { wgpuRenderPipelineRelease(surfacePipe); surfacePipe = null; }
        if (simModule !is null) { wgpuShaderModuleRelease(simModule); simModule = null; }
        if (surfaceModule !is null) { wgpuShaderModuleRelease(surfaceModule); surfaceModule = null; }
        if (simPipeLayout !is null) { wgpuPipelineLayoutRelease(simPipeLayout); simPipeLayout = null; }
        if (surfacePipeLayout !is null) { wgpuPipelineLayoutRelease(surfacePipeLayout); surfacePipeLayout = null; }
        if (simLayout !is null) { wgpuBindGroupLayoutRelease(simLayout); simLayout = null; }
        if (surfaceLayout !is null) { wgpuBindGroupLayoutRelease(surfaceLayout); surfaceLayout = null; }
        if (sampler !is null) { wgpuSamplerRelease(sampler); sampler = null; }
        scene = null;
        renderer = null;
    }

    private bool valid(int id) const nothrow @nogc {
        return id >= 0 && id < cast(int) MAX_WATER_BODIES && slots[id].used;
    }

    /// Transparent hook: one opaque snapshot, then every body.
    private void draw(ref FrameContext frame) nothrow @nogc @trusted {
        if (renderer is null || scene is null || !frame.valid) return;
        bool any, needSnapshot;
        foreach (ref s; slots) {
            if (!s.used) continue;
            any = true;
            if (s.desc.has(WaterFeature.refraction) || s.desc.has(WaterFeature.ssr)) needSnapshot = true;
        }
        if (!any) return;
        if (needSnapshot) renderer.snapshotOpaque(frame);
        auto colorView = renderer.opaqueColorView();
        auto depthView = renderer.opaqueDepthView();
        if (colorView is null || depthView is null) return;

        frame.setPipeline(surfacePipe);
        frame.setBindGroup(0, scene.frameGroup());
        frame.setBindGroup(2, scene.iblGroup());
        foreach (ref s; slots) {
            if (!s.used) continue;
            bindSurface(s, colorView, depthView);
            frame.setBindGroup(1, s.surfaceBg[s.ping]);
            frame.setVertexBuffer(0, s.vbuf, s.vSize);
            frame.setIndexBuffer(s.ibuf, WGPUIndexFormat.uint16, s.iSize);
            frame.drawIndexed(s.indexCount, 1);
        }
    }

    private void bindSurface(ref BodySlot s, WGPUTextureView colorView, WGPUTextureView depthView) nothrow @nogc @trusted {
        if (s.surfaceBg[0] !is null && s.boundColor is colorView && s.boundDepth is depthView) return;
        foreach (i; 0 .. 2) {
            releaseBindGroup(s.surfaceBg[i]);
            WGPUBindGroupEntry[5] e;
            e[0].binding = 0; e[0].buffer = s.ubo; e[0].size = WaterSurfaceUniforms.sizeof;
            e[1].binding = 1; e[1].textureView = colorView;
            e[2].binding = 2; e[2].textureView = depthView;
            e[3].binding = 3; e[3].sampler = sampler;
            e[4].binding = 4; e[4].textureView = s.simView[i];
            WGPUBindGroupDescriptor d;
            d.layout = surfaceLayout;
            d.entryCount = e.length;
            d.entries = e.ptr;
            s.surfaceBg[i] = wgpuDeviceCreateBindGroup(device, &d);
        }
        s.boundColor = colorView;
        s.boundDepth = depthView;
    }

    private void createSimTargets(ref BodySlot s) @trusted {
        foreach (i; 0 .. 2) {
            WGPUTextureDescriptor td;
            td.usage = WGPUTextureUsage.textureBinding | WGPUTextureUsage.storageBinding;
            td.dimension = WGPUTextureDimension.dim2D;
            td.size = WGPUExtent3D(WATER_SIM_RES, WATER_SIM_RES, 1);
            td.format = WGPUTextureFormat.rgba16Float;
            td.mipLevelCount = 1;
            td.sampleCount = 1;
            s.simTex[i] = wgpuDeviceCreateTexture(device, &td);
            if (s.simTex[i] is null) fatal("Water simulation texture allocation failed");
            WGPUTextureViewDescriptor vd;
            vd.format = WGPUTextureFormat.rgba16Float;
            vd.dimension = WGPUTextureViewDimension.dim2D;
            vd.mipLevelCount = 1;
            vd.arrayLayerCount = 1;
            s.simView[i] = wgpuTextureCreateView(s.simTex[i], &vd);
        }
        // simBg[i] reads simView[i] and writes simView[i ^ 1].
        foreach (i; 0 .. 2) {
            WGPUBindGroupEntry[4] e;
            e[0].binding = 0; e[0].buffer = s.ubo; e[0].size = WaterSurfaceUniforms.sizeof;
            e[1].binding = 1; e[1].textureView = s.simView[i];
            e[2].binding = 2; e[2].sampler = sampler;
            e[3].binding = 3; e[3].textureView = s.simView[i ^ 1];
            WGPUBindGroupDescriptor d;
            d.layout = simLayout;
            d.entryCount = e.length;
            d.entries = e.ptr;
            s.simBg[i] = wgpuDeviceCreateBindGroup(device, &d);
        }
    }

    /// Unit grid over [-1, 1]² (the shader scales it by the body extent).
    private void buildGrid(ref BodySlot s, uint res) @trusted {
        immutable uint stride = res + 1;
        auto verts = new TexVert[stride * stride];
        foreach (row; 0 .. stride) {
            immutable float v = cast(float) row / cast(float) res;
            foreach (col; 0 .. stride) {
                immutable float u = cast(float) col / cast(float) res;
                verts[row * stride + col] = TexVert([u * 2.0f - 1.0f, 0.0f, v * 2.0f - 1.0f],
                                                    [0.0f, 1.0f, 0.0f], [u, v]);
            }
        }
        auto indices = new ushort[res * res * 6];
        uint k = 0;
        foreach (row; 0 .. res) {
            foreach (col; 0 .. res) {
                immutable ushort a = cast(ushort)(row * stride + col);
                immutable ushort b = cast(ushort)(a + 1);
                immutable ushort c = cast(ushort)(a + stride);
                immutable ushort d = cast(ushort)(c + 1);
                // Counter-clockwise viewed from +Y.
                indices[k .. k + 6] = [a, d, b, a, c, d];
                k += 6;
            }
        }
        s.vSize = verts.length * TexVert.sizeof;
        s.iSize = indices.length * ushort.sizeof;
        s.vbuf = createVertexBuffer(device, queue, verts.ptr, s.vSize);
        s.ibuf = createIndexBuffer(device, queue, indices.ptr, s.iSize);
        s.indexCount = cast(uint) indices.length;
        s.gridRes = res;
    }

    private static void releaseSlot(ref BodySlot s) nothrow @nogc @trusted {
        foreach (i; 0 .. 2) {
            releaseBindGroup(s.surfaceBg[i]);
            releaseBindGroup(s.simBg[i]);
            if (s.simView[i] !is null) wgpuTextureViewRelease(s.simView[i]);
            if (s.simTex[i] !is null) wgpuTextureRelease(s.simTex[i]);
        }
        destroyBuffer(s.ubo);
        destroyBuffer(s.vbuf);
        destroyBuffer(s.ibuf);
        s = BodySlot.init;
    }
}

// ── Pipeline setup, split into small functions (DMD 2.113's backend
//    overflows its stack on one large pipeline-building function). ──

private WGPUBindGroupLayout createSurfaceLayout(WGPUDevice dev) @trusted {
    enum fs = WGPUShaderStage.fragment;
    WGPUBindGroupLayoutEntry[5] e;
    e[0].binding = 0;
    e[0].visibility = WGPUShaderStage.vertex | fs;
    e[0].buffer.type = WGPUBufferBindingType.uniform;
    e[0].buffer.minBindingSize = WaterSurfaceUniforms.sizeof;
    e[1].binding = 1; e[1].visibility = fs;
    e[1].texture.sampleType = WGPUTextureSampleType.float_;
    e[1].texture.viewDimension = WGPUTextureViewDimension.dim2D;
    e[2].binding = 2; e[2].visibility = fs;
    e[2].texture.sampleType = WGPUTextureSampleType.depth;
    e[2].texture.viewDimension = WGPUTextureViewDimension.dim2D;
    e[3].binding = 3; e[3].visibility = fs;
    e[3].sampler.type = WGPUSamplerBindingType.filtering;
    e[4].binding = 4; e[4].visibility = fs;
    e[4].texture.sampleType = WGPUTextureSampleType.float_;
    e[4].texture.viewDimension = WGPUTextureViewDimension.dim2D;
    WGPUBindGroupLayoutDescriptor d;
    d.entryCount = e.length;
    d.entries = e.ptr;
    return wgpuDeviceCreateBindGroupLayout(dev, &d);
}

private WGPUBindGroupLayout createSimLayout(WGPUDevice dev) @trusted {
    enum cs = WGPUShaderStage.compute;
    WGPUBindGroupLayoutEntry[4] e;
    e[0].binding = 0; e[0].visibility = cs;
    e[0].buffer.type = WGPUBufferBindingType.uniform;
    e[0].buffer.minBindingSize = WaterSurfaceUniforms.sizeof;
    e[1].binding = 1; e[1].visibility = cs;
    e[1].texture.sampleType = WGPUTextureSampleType.float_;
    e[1].texture.viewDimension = WGPUTextureViewDimension.dim2D;
    e[2].binding = 2; e[2].visibility = cs;
    e[2].sampler.type = WGPUSamplerBindingType.filtering;
    e[3].binding = 3; e[3].visibility = cs;
    e[3].storageTexture.access = WGPUStorageTextureAccess.writeOnly;
    e[3].storageTexture.format = WGPUTextureFormat.rgba16Float;
    e[3].storageTexture.viewDimension = WGPUTextureViewDimension.dim2D;
    WGPUBindGroupLayoutDescriptor d;
    d.entryCount = e.length;
    d.entries = e.ptr;
    return wgpuDeviceCreateBindGroupLayout(dev, &d);
}

private WGPUSampler createLinearClampSampler(WGPUDevice dev) @trusted {
    WGPUSamplerDescriptor d;
    d.addressModeU = WGPUAddressMode.clampToEdge;
    d.addressModeV = WGPUAddressMode.clampToEdge;
    d.addressModeW = WGPUAddressMode.clampToEdge;
    d.magFilter = WGPUFilterMode.linear;
    d.minFilter = WGPUFilterMode.linear;
    d.mipmapFilter = WGPUMipmapFilterMode.nearest;
    d.lodMinClamp = 0.0f;
    d.lodMaxClamp = 1.0f;
    d.maxAnisotropy = 1;
    return wgpuDeviceCreateSampler(dev, &d);
}

private WGPUPipelineLayout createPipelineLayout3(WGPUDevice dev, WGPUBindGroupLayout a,
                                                 WGPUBindGroupLayout b, WGPUBindGroupLayout c) @trusted {
    WGPUBindGroupLayout[3] layouts = [a, b, c];
    WGPUPipelineLayoutDescriptor d;
    d.bindGroupLayoutCount = layouts.length;
    d.bindGroupLayouts = layouts.ptr;
    return wgpuDeviceCreatePipelineLayout(dev, &d);
}

private WGPUPipelineLayout createPipelineLayout1(WGPUDevice dev, WGPUBindGroupLayout a) @trusted {
    WGPUPipelineLayoutDescriptor d;
    d.bindGroupLayoutCount = 1;
    d.bindGroupLayouts = &a;
    return wgpuDeviceCreatePipelineLayout(dev, &d);
}

private WGPUComputePipeline createSimPipeline(WGPUDevice dev, WGPUPipelineLayout layout,
                                              WGPUShaderModule mod) @trusted {
    WGPUComputePipelineDescriptor d;
    d.layout = layout;
    d.compute.module_ = mod;
    d.compute.entryPoint = wgpuStringView("cs_main");
    return wgpuDeviceCreateComputePipeline(dev, &d);
}

/// Alpha-blended, depth-writing surface (the opaque snapshot already holds
/// what lies behind the water).
private WGPURenderPipeline createSurfacePipeline(WGPUDevice dev, WGPUPipelineLayout layout,
                                                 WGPUShaderModule mod) @trusted {
    WGPUVertexAttribute[3] attrs = [
        { format: WGPUVertexFormat.float32x3, offset: 0,  shaderLocation: 0 },
        { format: WGPUVertexFormat.float32x3, offset: 12, shaderLocation: 1 },
        { format: WGPUVertexFormat.float32x2, offset: 24, shaderLocation: 2 },
    ];
    WGPUVertexBufferLayout vbl;
    vbl.arrayStride = TexVert.sizeof;
    vbl.stepMode = WGPUVertexStepMode.vertex;
    vbl.attributeCount = attrs.length;
    vbl.attributes = attrs.ptr;

    WGPUBlendState blend;
    blend.color.operation = WGPUBlendOperation.add;
    blend.color.srcFactor = WGPUBlendFactor.srcAlpha;
    blend.color.dstFactor = WGPUBlendFactor.oneMinusSrcAlpha;
    blend.alpha.operation = WGPUBlendOperation.add;
    blend.alpha.srcFactor = WGPUBlendFactor.one;
    blend.alpha.dstFactor = WGPUBlendFactor.oneMinusSrcAlpha;
    WGPUColorTargetState target;
    target.format = Renderer.sceneFormat();
    target.blend = &blend;
    target.writeMask = WGPUColorWriteMask.all;
    WGPUFragmentState fst;
    fst.module_ = mod;
    fst.entryPoint = wgpuStringView("fs_main");
    fst.targetCount = 1;
    fst.targets = &target;

    WGPUDepthStencilState depth;
    depth.format = WGPUTextureFormat.depth24Plus;
    depth.depthWriteEnabled = WGPUOptionalBool.true_;
    depth.depthCompare = WGPUCompareFunction.less;

    WGPURenderPipelineDescriptor d;
    d.layout = layout;
    d.vertex.module_ = mod;
    d.vertex.entryPoint = wgpuStringView("vs_main");
    d.vertex.bufferCount = 1;
    d.vertex.buffers = &vbl;
    d.primitive.topology = WGPUPrimitiveTopology.triangleList;
    d.primitive.frontFace = WGPUFrontFace.ccw;
    d.primitive.cullMode = WGPUCullMode.none;
    d.depthStencil = &depth;
    d.fragment = &fst;
    return wgpuDeviceCreateRenderPipeline(dev, &d);
}

unittest {
    auto b = WaterBody.river();
    b.centerX = 5.0f;
    b.level = 2.0f;
    WaterObstacle[20] obs;
    auto u = packWaterSurfaceUniforms(b, 1, obs[], 3.0f, 0.1f, 500.0f);
    assert(u.flags0[0] == WaterStyle.river && u.flags0[3] == 192);
    assert(u.counts[0] == MAX_WATER_OBSTACLES && u.counts[1] == 1);
    assert(u.area == [5.0f, 0.0f, 14.0f, 2.0f]);
    assert(u.flow[0] == 1.35f && u.flow[3] == 1.15f);
    assert(u.coatColor[3] == b.causticsStrength);
    assert(clampGrid(1000) == MAX_WATER_GRID && clampGrid(0) == 2);
}
