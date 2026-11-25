/// GPU renderer for `Terrain`: heightmap (`r32Float`, read with
/// `textureLoad` in the vertex shader), smooth normal map, splat planes and
/// layer arrays, one shared grid-template index buffer, and an instance
/// buffer of visible chunks. Draws one instanced call per LOD inside the
/// scene's opaque pass and casts into every directional (cascade) shadow
/// view through `Scene3DTextured` hooks.
///
///   auto tr = TerrainRenderer.create(gpu, scene, terrain, material);
///   tr.attach(scene, terrain);      // after `tr` reached its final address
///   // per frame, before scene.renderShadows / scene.end:
///   tr.update(terrain, camera);
module engine.terrain.renderer;

import core.stdc.string : memcpy;

import bindings.wgpu;
import engine.core.log;
import engine.gpu.context : GpuContext;
import engine.gpu.renderer : FrameContext, Renderer;
import engine.gpu.shader : createShaderModule;
import engine.gpu.shaders : terrainPbrShaderSource, terrainShadowShaderSource;
import engine.graphics.texture : Sampler, SamplerDesc, Texture, TextureArray, TextureDesc,
    TextureFilter, TextureWrap;
import engine.math.frustum : Frustum;
import engine.math.vec : Vec3;
import engine.scene.camera : Camera;
import engine.scene.scene3d_textured : Scene3DTextured;
import engine.terrain.chunks : buildGridTemplate, LodRange, MAX_TERRAIN_LODS, TerrainChunkInstance;
import engine.terrain.material : TerrainMaterial;
import engine.terrain.terrain : Terrain;

@safe:

import engine.devtools.profiler : profileZone;
import engine.gpu.gpu_profiler : gpuFrameScope;

struct TerrainRenderSettings {
    /// Skirt depth at LOD0 (meters; scaled by the LOD step).
    float skirtDepth = 1.5f;
    /// Height-blend transition depth (0..1 weight units).
    float blendDepth = 0.2f;
    /// Second UV scale used in the distance to hide tiling.
    float detileScale = 0.17f;
    /// 0 = smooth heightmap normal only, 1 = full layer normal detail.
    float normalStrength = 1.0f;
    bool castShadows = true;
}

/// Per-frame counters.
struct TerrainStats {
    uint visibleChunks;
    uint drawCalls;
    uint shadowDrawCalls;
    uint shadowViews;
}

struct TerrainRenderer {
    enum uint MAX_SHADOW_VIEWS = 8;
    private enum uint PARAMS_SIZE = 176;

    private WGPUDevice device;
    private WGPUQueue queue;
    private Texture heightTex, normalTex;
    private TextureArray splatTex;
    private Sampler layerSampler, clampSampler;
    private WGPUBuffer indexBuf, instanceBuf, shadowInstanceBuf, paramBuf;
    private ulong indexBytes;
    private LodRange[MAX_TERRAIN_LODS] ranges;
    private uint chunkCount;

    private WGPUShaderModule mainModule, shadowModule;
    private WGPUBindGroupLayout mainLayout, shadowLayout;
    private WGPUPipelineLayout mainPipeLayout, shadowPipeLayout;
    private WGPURenderPipeline mainPipe, shadowPipe;
    private WGPURenderPipeline aoPipe; /// created when GTAO first runs
    private WGPUBindGroup mainBg, shadowBg;

    private float[PARAMS_SIZE / 4] params;
    private TerrainRenderSettings settings;
    private Scene3DTextured* scene;
    private Terrain* terrain;
    private uint shadowViewIndex;
    private TerrainStats stats_;

    @disable this(this);

    static TerrainRenderer create(ref GpuContext gpu, ref Scene3DTextured scene, ref const Terrain terrain,
                                  ref TerrainMaterial material,
                                  TerrainRenderSettings settings = TerrainRenderSettings.init) @trusted {
        TerrainRenderer r;
        r.device = gpu.getDevice();
        r.queue = gpu.getQueue();
        r.settings = settings;
        const h = &terrain.height;
        immutable W = h.desc.samplesX, H = h.desc.samplesZ;

        // Heightmap: decoded floats (exactly the physics surface).
        {
            auto hf = new float[cast(size_t) W * H];
            foreach (i, q; h.q) hf[i] = h.decode(q);
            r.heightTex = Texture.fromR32F(gpu, hf, W, H);
            if (!r.heightTex.valid) fatal("Terrain: heightmap texture creation failed");
        }
        // Smooth normal map (central differences).
        {
            auto px = new ubyte[cast(size_t) W * H * 4];
            foreach (z; 0 .. H)
                foreach (x; 0 .. W) {
                    immutable n = h.sampleNormal(x, z);
                    immutable i = (cast(size_t) z * W + x) * 4;
                    px[i] = toByte(n.x * 0.5f + 0.5f);
                    px[i + 1] = toByte(n.y * 0.5f + 0.5f);
                    px[i + 2] = toByte(n.z * 0.5f + 0.5f);
                    px[i + 3] = 255;
                }
            TextureDesc nd;
            nd.generateMips = true;
            nd.normalMap = true;
            r.normalTex = Texture.fromPixels(gpu, px, W, H, nd);
        }
        {
            ubyte[] p0, p1;
            terrain.splat.planes(p0, p1);
            const(ubyte)[][2] planes = [p0, p1];
            TextureDesc sd;
            sd.generateMips = true;
            r.splatTex = TextureArray.fromLayers(gpu, planes[], terrain.splat.width, terrain.splat.height, sd);
        }
        r.layerSampler = Sampler.create(gpu, SamplerDesc(TextureFilter.linear, TextureWrap.repeat, 8));
        r.clampSampler = Sampler.create(gpu, SamplerDesc(TextureFilter.linear, TextureWrap.clamp, 1));

        auto idx = buildGridTemplate(terrain.chunks.chunkCells, terrain.chunks.lod.lodCount, r.ranges);
        if (idx.length & 1) idx ~= cast(ushort) 0;
        r.indexBytes = idx.length * ushort.sizeof;
        r.indexBuf = createBuffer(r.device, r.indexBytes, WGPUBufferUsage.index | WGPUBufferUsage.copyDst);
        wgpuQueueWriteBuffer(r.queue, r.indexBuf, 0, idx.ptr, r.indexBytes);

        r.chunkCount = terrain.chunks.chunkCount();
        r.instanceBuf = createBuffer(r.device, r.chunkCount * TerrainChunkInstance.sizeof,
                                     WGPUBufferUsage.vertex | WGPUBufferUsage.copyDst);
        r.shadowInstanceBuf = createBuffer(r.device, r.chunkCount * MAX_SHADOW_VIEWS * TerrainChunkInstance.sizeof,
                                           WGPUBufferUsage.vertex | WGPUBufferUsage.copyDst);
        r.paramBuf = createBuffer(r.device, PARAMS_SIZE, WGPUBufferUsage.uniform | WGPUBufferUsage.copyDst);
        r.fillParams(terrain, material);

        r.createPipelines(scene);
        r.createBindGroups(material);
        info("Terrain renderer: ", W, "x", H, " samples, ", r.chunkCount, " chunks, ",
             terrain.chunks.lod.lodCount, " LODs, ", material.layerCount, " layers");
        return r;
    }

    /// Register the opaque and shadow hooks. `this`, `scene` and `terrain`
    /// must not move afterwards.
    void attach(ref Scene3DTextured scene, ref Terrain terrain) @trusted {
        this.scene = &scene;
        this.terrain = &terrain;
        scene.addOpaqueHook(&drawOpaque);
        if (settings.castShadows) scene.addShadowCasterHook(&drawShadow);
    }

    /// Remove every opaque / shadow hook from the scene (call before destroy).
    void detach() nothrow @nogc @trusted {
        if (scene is null) return;
        scene.clearOpaqueHooks();
        scene.clearShadowCasterHooks();
        scene = null;
    }

    TerrainStats stats() const nothrow @nogc { return stats_; }

    /// Cull and select LODs for `camera`, upload the visible instances.
    void update(ref Terrain terrain, ref const Camera camera) nothrow @nogc @trusted {
        auto z = profileZone!"terrain.update"();
        immutable f = Frustum.fromViewProj(camera.viewProjection());
        immutable vis = terrain.chunks.update(f, camera.position);
        if (vis > 0)
            wgpuQueueWriteBuffer(queue, instanceBuf, 0, terrain.chunks.visible.ptr,
                                 vis * TerrainChunkInstance.sizeof);
        params[12] = camera.position.x;
        params[13] = camera.position.y;
        params[14] = camera.position.z;
        wgpuQueueWriteBuffer(queue, paramBuf, 0, params.ptr, PARAMS_SIZE);
        shadowViewIndex = 0;
        stats_ = TerrainStats.init;
        stats_.visibleChunks = vis;
    }

    private void drawOpaque(ref FrameContext frame) nothrow @nogc @trusted {
        if (terrain is null || scene is null || !frame.valid) return;
        auto ch = &terrain.chunks;
        if (ch.visibleCount == 0) return;
        auto z = profileZone!"terrain.draw"();
        auto g = gpuFrameScope!"gpu.terrain"(frame);
        if (scene.writesAmbientAlpha && aoPipe is null) aoPipe = createMainPipe(true);
        frame.setPipeline(scene.writesAmbientAlpha ? aoPipe : mainPipe);
        frame.setBindGroup(0, scene.frameGroup());
        frame.setBindGroup(1, mainBg);
        frame.setBindGroup(2, scene.iblGroup());
        frame.setVertexBuffer(0, instanceBuf, chunkCount * TerrainChunkInstance.sizeof);
        frame.setIndexBuffer(indexBuf, WGPUIndexFormat.uint16, indexBytes);
        foreach (l; 0 .. MAX_TERRAIN_LODS) {
            if (ch.lodCount[l] == 0) continue;
            frame.drawIndexed(ranges[l].count, ch.lodCount[l], ranges[l].first, 0, ch.lodFirst[l]);
            stats_.drawCalls++;
        }
    }

    private void drawShadow(WGPURenderPassEncoder pass, WGPUBindGroup vpBg, uint dynOffset,
                            ref const Frustum view) nothrow @nogc @trusted {
        if (terrain is null || shadowViewIndex >= MAX_SHADOW_VIEWS) return;
        auto ch = &terrain.chunks;
        uint[MAX_TERRAIN_LODS] first, count;
        immutable n = ch.gatherShadow(view, ch.scratch, first, count);
        immutable slot = shadowViewIndex++;
        stats_.shadowViews++;
        if (n == 0) return;
        immutable ulong stride = TerrainChunkInstance.sizeof;
        immutable ulong base = cast(ulong) slot * chunkCount * stride;
        wgpuQueueWriteBuffer(queue, shadowInstanceBuf, base, ch.scratch.ptr, n * stride);
        wgpuRenderPassEncoderSetPipeline(pass, shadowPipe);
        wgpuRenderPassEncoderSetBindGroup(pass, 0, vpBg, 1, &dynOffset);
        wgpuRenderPassEncoderSetBindGroup(pass, 1, shadowBg, 0, null);
        wgpuRenderPassEncoderSetVertexBuffer(pass, 0, shadowInstanceBuf, base, n * stride);
        wgpuRenderPassEncoderSetIndexBuffer(pass, indexBuf, WGPUIndexFormat.uint16, 0, indexBytes);
        foreach (l; 0 .. MAX_TERRAIN_LODS) {
            if (count[l] == 0) continue;
            wgpuRenderPassEncoderDrawIndexed(pass, ranges[l].count, count[l], ranges[l].first, 0, first[l]);
            stats_.shadowDrawCalls++;
        }
    }

    private void fillParams(ref const Terrain t, ref const TerrainMaterial m) {
        params[] = 0;
        const d = &t.height.desc;
        params[0 .. 4] = [d.origin.x, d.origin.y, d.origin.z, d.cellSize];
        params[4 .. 8] = [cast(float) d.samplesX, cast(float) d.samplesZ, cast(float) d.chunkCells, settings.skirtDepth];
        params[8 .. 12] = [t.chunks.lod.lod0Distance, t.chunks.lod.morphFraction, cast(float) t.chunks.lod.lodCount, t.chunks.lod.hysteresis];
        foreach (i; 0 .. m.layerCount) {
            params[16 + i] = m.layers[i].uvScale;
            params[24 + i] = m.layers[i].heightBlend;
            params[32 + i] = m.layers[i].triplanarSharpness;
        }
        params[40 .. 44] = [cast(float) m.layerCount, settings.blendDepth, settings.detileScale, settings.normalStrength];
    }

    private void createPipelines(ref Scene3DTextured scene) @trusted {
        mainModule = createShaderModule(device, terrainPbrShaderSource);
        shadowModule = createShaderModule(device, terrainShadowShaderSource);
        if (mainModule is null || shadowModule is null) fatal("Terrain shader compile failed");

        enum vs = WGPUShaderStage.vertex;
        enum fs = WGPUShaderStage.fragment;
        WGPUBindGroupLayoutEntry[9] e;
        e[0].binding = 0; e[0].visibility = vs | fs;
        e[0].buffer.type = WGPUBufferBindingType.uniform; e[0].buffer.minBindingSize = PARAMS_SIZE;
        e[1].binding = 1; e[1].visibility = fs; e[1].sampler.type = WGPUSamplerBindingType.filtering;
        e[2].binding = 2; e[2].visibility = vs;
        e[2].texture.sampleType = WGPUTextureSampleType.unfilterableFloat;
        e[2].texture.viewDimension = WGPUTextureViewDimension.dim2D;
        e[3].binding = 3; e[3].visibility = fs;
        e[3].texture.sampleType = WGPUTextureSampleType.float_;
        e[3].texture.viewDimension = WGPUTextureViewDimension.dim2D;
        foreach (k; 4 .. 8) {
            e[k].binding = k; e[k].visibility = fs;
            e[k].texture.sampleType = WGPUTextureSampleType.float_;
            e[k].texture.viewDimension = WGPUTextureViewDimension.dim2DArray;
        }
        e[8].binding = 8; e[8].visibility = fs; e[8].sampler.type = WGPUSamplerBindingType.filtering;
        WGPUBindGroupLayoutDescriptor ld;
        ld.entryCount = e.length;
        ld.entries = e.ptr;
        mainLayout = wgpuDeviceCreateBindGroupLayout(device, &ld);

        WGPUBindGroupLayoutEntry[2] se = [e[0], e[2]];
        se[0].visibility = vs;
        ld.entryCount = se.length;
        ld.entries = se.ptr;
        shadowLayout = wgpuDeviceCreateBindGroupLayout(device, &ld);

        WGPUBindGroupLayout[3] mainLayouts = [scene.frameLayout(), mainLayout, scene.iblLayout()];
        WGPUPipelineLayoutDescriptor pld;
        pld.bindGroupLayoutCount = 3;
        pld.bindGroupLayouts = mainLayouts.ptr;
        mainPipeLayout = wgpuDeviceCreatePipelineLayout(device, &pld);
        WGPUBindGroupLayout[2] shadowLayouts = [scene.shadowVpLayout(), shadowLayout];
        pld.bindGroupLayoutCount = 2;
        pld.bindGroupLayouts = shadowLayouts.ptr;
        shadowPipeLayout = wgpuDeviceCreatePipelineLayout(device, &pld);

        WGPUVertexAttribute attr = { format: WGPUVertexFormat.float32x4, offset: 0, shaderLocation: 0 };
        WGPUVertexBufferLayout vbl;
        vbl.arrayStride = TerrainChunkInstance.sizeof;
        vbl.stepMode = WGPUVertexStepMode.instance_;
        vbl.attributeCount = 1;
        vbl.attributes = &attr;

        mainPipe = createMainPipe(false);

        WGPUDepthStencilState sdepth;
        sdepth.format = WGPUTextureFormat.depth32Float;
        sdepth.depthWriteEnabled = WGPUOptionalBool.true_;
        sdepth.depthCompare = WGPUCompareFunction.less;
        sdepth.depthBias = 2;
        sdepth.depthBiasSlopeScale = 2.0f;
        WGPURenderPipelineDescriptor sp;
        sp.layout = shadowPipeLayout;
        sp.vertex.module_ = shadowModule;
        sp.vertex.entryPoint = wgpuStringView("vs_main");
        sp.vertex.bufferCount = 1;
        sp.vertex.buffers = &vbl;
        sp.primitive.topology = WGPUPrimitiveTopology.triangleList;
        sp.primitive.frontFace = WGPUFrontFace.ccw;
        sp.primitive.cullMode = WGPUCullMode.none;
        sp.depthStencil = &sdepth;
        shadowPipe = wgpuDeviceCreateRenderPipeline(device, &sp);
        if (shadowPipe is null) fatal("Terrain shadow pipeline creation failed");
    }

    /// Color pipeline; `ambientAlpha` selects the GTAO variant.
    private WGPURenderPipeline createMainPipe(bool ambientAlpha) nothrow @nogc @trusted {
        WGPUVertexAttribute attr = { format: WGPUVertexFormat.float32x4, offset: 0, shaderLocation: 0 };
        WGPUVertexBufferLayout vbl;
        vbl.arrayStride = TerrainChunkInstance.sizeof;
        vbl.stepMode = WGPUVertexStepMode.instance_;
        vbl.attributeCount = 1;
        vbl.attributes = &attr;

        WGPUColorTargetState target;
        target.format = Renderer.sceneFormat();
        target.writeMask = WGPUColorWriteMask.all;
        WGPUFragmentState fst;
        fst.module_ = mainModule;
        fst.entryPoint = wgpuStringView("fs_main");
        fst.targetCount = 1;
        fst.targets = &target;
        WGPUConstantEntry constant;
        constant.key = wgpuStringView("AMBIENT_ALPHA");
        constant.value = 1;
        if (ambientAlpha) {
            fst.constantCount = 1;
            fst.constants = &constant;
        }
        WGPUDepthStencilState depth;
        depth.format = WGPUTextureFormat.depth24Plus;
        depth.depthWriteEnabled = WGPUOptionalBool.true_;
        depth.depthCompare = WGPUCompareFunction.less;

        WGPURenderPipelineDescriptor pd;
        pd.layout = mainPipeLayout;
        pd.vertex.module_ = mainModule;
        pd.vertex.entryPoint = wgpuStringView("vs_main");
        pd.vertex.bufferCount = 1;
        pd.vertex.buffers = &vbl;
        pd.fragment = &fst;
        pd.primitive.topology = WGPUPrimitiveTopology.triangleList;
        pd.primitive.frontFace = WGPUFrontFace.ccw;
        pd.primitive.cullMode = WGPUCullMode.back;
        pd.depthStencil = &depth;
        auto pipe = wgpuDeviceCreateRenderPipeline(device, &pd);
        if (pipe is null) fatal("Terrain pipeline creation failed");
        return pipe;
    }

    private void createBindGroups(ref TerrainMaterial m) @trusted {
        WGPUBindGroupEntry[9] e;
        e[0].binding = 0; e[0].buffer = paramBuf; e[0].size = PARAMS_SIZE;
        e[1].binding = 1; e[1].sampler = layerSampler.sampler;
        e[2].binding = 2; e[2].textureView = heightTex.view;
        e[3].binding = 3; e[3].textureView = normalTex.view;
        e[4].binding = 4; e[4].textureView = splatTex.view;
        e[5].binding = 5; e[5].textureView = m.albedo.view;
        e[6].binding = 6; e[6].textureView = m.normal.view;
        e[7].binding = 7; e[7].textureView = m.orm.view;
        e[8].binding = 8; e[8].sampler = clampSampler.sampler;
        WGPUBindGroupDescriptor d;
        d.layout = mainLayout;
        d.entryCount = e.length;
        d.entries = e.ptr;
        mainBg = wgpuDeviceCreateBindGroup(device, &d);
        if (mainBg is null) fatal("Terrain bind group creation failed");
        WGPUBindGroupEntry[2] se = [e[0], e[2]];
        d.layout = shadowLayout;
        d.entryCount = se.length;
        d.entries = se.ptr;
        shadowBg = wgpuDeviceCreateBindGroup(device, &d);
        if (shadowBg is null) fatal("Terrain shadow bind group creation failed");
    }

    void destroy() nothrow @nogc @trusted {
        detach();
        if (mainBg !is null) { wgpuBindGroupRelease(mainBg); mainBg = null; }
        if (shadowBg !is null) { wgpuBindGroupRelease(shadowBg); shadowBg = null; }
        if (aoPipe !is null) { wgpuRenderPipelineRelease(aoPipe); aoPipe = null; }
        if (mainPipe !is null) { wgpuRenderPipelineRelease(mainPipe); mainPipe = null; }
        if (shadowPipe !is null) { wgpuRenderPipelineRelease(shadowPipe); shadowPipe = null; }
        if (mainPipeLayout !is null) { wgpuPipelineLayoutRelease(mainPipeLayout); mainPipeLayout = null; }
        if (shadowPipeLayout !is null) { wgpuPipelineLayoutRelease(shadowPipeLayout); shadowPipeLayout = null; }
        if (mainLayout !is null) { wgpuBindGroupLayoutRelease(mainLayout); mainLayout = null; }
        if (shadowLayout !is null) { wgpuBindGroupLayoutRelease(shadowLayout); shadowLayout = null; }
        if (mainModule !is null) { wgpuShaderModuleRelease(mainModule); mainModule = null; }
        if (shadowModule !is null) { wgpuShaderModuleRelease(shadowModule); shadowModule = null; }
        static void rel(ref WGPUBuffer b) nothrow @nogc @trusted { if (b !is null) { wgpuBufferRelease(b); b = null; } }
        rel(indexBuf);
        rel(instanceBuf);
        rel(shadowInstanceBuf);
        rel(paramBuf);
        heightTex.destroy();
        normalTex.destroy();
        splatTex.destroy();
        layerSampler.destroy();
        clampSampler.destroy();
    }
}

private WGPUBuffer createBuffer(WGPUDevice dev, ulong size, WGPUBufferUsage usage) @trusted {
    WGPUBufferDescriptor bd;
    bd.size = (size + 3) & ~3UL;
    bd.usage = usage;
    auto b = wgpuDeviceCreateBuffer(dev, &bd);
    if (b is null) fatal("Terrain: buffer creation failed");
    return b;
}

private ubyte toByte(float v) pure nothrow @nogc {
    v = v < 0 ? 0 : (v > 1 ? 1 : v);
    return cast(ubyte)(v * 255.0f + 0.5f);
}
