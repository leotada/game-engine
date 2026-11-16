/// Interactive OpenPBR Surface v1.1 Ocean & River Water Showcase.
///
/// Renders realistic water in a single HDR pass using dedicated WGSL shaders:
/// GPU 6-octave Gerstner wave displacement (160x160 grid), 4-octave
/// procedural capillary micro-normals with river streamline deflection around
/// boulders/piers, analytical Beer-Lambert depth absorption, backlit wave-crest
/// subsurface scattering, crisp whitecap & obstacle wake foam, animated RGB
/// Voronoi riverbed caustics modulated by shadows, and a coherent procedural
/// atmospheric sky dome with drifting clouds and sun corona.
module demo.water;

import std.math : cos, fabs, floor, sin, sqrt, tan, PI, PI_2;

import bindings.wgpu;
import engine.app;
import engine.assets.bmp : loadBmpTexture;
import engine.assets.gltf : loadGltfMesh;
import engine.core.log;
import engine.core.pod : isPod;
import engine.gpu.buffer;
import engine.gpu.context : GpuContext;
import engine.gpu.renderer : FrameContext, Renderer;
import engine.gpu.shader : createShaderModule, ValidateUniformLayout;
import engine.gpu.shaders : skyDomeShaderSource, causticsBedShaderSource, waterSurfaceShaderSource, waterSimCsShaderSource;
import engine.gpu.shadow;
import engine.gpu.text;
import engine.graphics.material : Material, MaterialFlags, MaterialParams;
import engine.graphics.texmesh : TexMesh;
import engine.graphics.texture : Sampler, Texture, TextureFilter, TextureWrap;
import engine.graphics.types : Color4, InstanceData, TexTanVert, TexVert;
import engine.math.mat : Mat4;
import engine.math.vec : Vec3;
import engine.platform.input : InputState, Key, MouseButton;
import engine.scene.camera : Camera;
import engine.scene.light :
    GpuSpotLight, LightSet, MAX_POINT_SHADOW_CASTERS, MAX_SPOT_SHADOW_CASTERS,
    SPOT_SHADOW_RESOLUTION;
import engine.scene.scene3d_textured : Scene3DTextured;

@safe:

private enum int W = 1280;
private enum int H = 720;
private enum uint WATER_GRID = 192;
private enum float WATER_HALF = 14.0f;

private struct WaveComponent {
    float dirX;
    float dirZ;
    float wavelength;
    float amplitude;
    float steepness;
    float speedScale;
}

private immutable WaveComponent[6] OCEAN_WAVES = [
    WaveComponent( 0.86f,  0.51f, 9.5f, 0.24f, 0.52f, 1.00f),
    WaveComponent( 0.42f, -0.91f, 6.2f, 0.14f, 0.48f, 1.15f),
    WaveComponent(-0.68f,  0.73f, 4.1f, 0.08f, 0.44f, 1.25f),
    WaveComponent( 0.96f, -0.28f, 2.7f, 0.045f, 0.40f, 1.35f),
    WaveComponent(-0.22f, -0.97f, 1.8f, 0.025f, 0.35f, 1.50f),
    WaveComponent( 0.61f,  0.79f, 1.15f, 0.015f, 0.30f, 1.65f),
];

private immutable WaveComponent[6] RIVER_WAVES = [
    WaveComponent( 0.96f,  0.28f, 4.4f, 0.075f, 0.40f, 1.65f),
    WaveComponent( 0.92f, -0.39f, 3.1f, 0.055f, 0.42f, 1.80f),
    WaveComponent( 0.78f,  0.62f, 2.1f, 0.038f, 0.44f, 1.95f),
    WaveComponent( 0.85f, -0.52f, 1.45f, 0.024f, 0.38f, 2.15f),
    WaveComponent( 0.99f,  0.14f, 0.95f, 0.014f, 0.34f, 2.30f),
    WaveComponent( 0.72f, -0.69f, 0.68f, 0.009f, 0.28f, 2.45f),
];

private struct WaveSample {
    Vec3 position;
    Vec3 normal;
    Vec3 tangent;
    float foam;
}

/// Deterministic fractional noise in [0, 1] from integer coordinates.
private float hash2D(int ix, int iy) pure nothrow @nogc {
    uint n = cast(uint)(ix * 374761393 + iy * 668265263);
    n = (n ^ (n >> 13)) * 1274126177u;
    return cast(float)((n ^ (n >> 16)) & 0x00FFFFFFu) / 16777215.0f;
}

private float valueNoise(float x, float y) pure nothrow @nogc {
    import std.math : floor;
    immutable fx = floor(x);
    immutable fy = floor(y);
    immutable ix = cast(int) fx;
    immutable iy = cast(int) fy;
    immutable tx = x - fx;
    immutable ty = y - fy;
    immutable ux = tx * tx * (3.0f - 2.0f * tx);
    immutable uy = ty * ty * (3.0f - 2.0f * ty);

    immutable a = hash2D(ix, iy);
    immutable b = hash2D(ix + 1, iy);
    immutable c = hash2D(ix, iy + 1);
    immutable d = hash2D(ix + 1, iy + 1);
    return (a + (b - a) * ux) + ((c - a) + (a - b - c + d) * ux) * uy;
}

private float fbmPeriodic(float u, float v, int period, int octaves) pure nothrow @nogc {
    float sum = 0.0f;
    float amp = 0.5f;
    float norm = 0.0f;
    int p = period;
    foreach (_; 0 .. octaves) {
        immutable gx = u * cast(float) p;
        immutable gy = v * cast(float) p;
        import std.math : floor;
        immutable fx = floor(gx);
        immutable fy = floor(gy);
        immutable ix0 = ((cast(int) fx) % p + p) % p;
        immutable iy0 = ((cast(int) fy) % p + p) % p;
        immutable ix1 = (ix0 + 1) % p;
        immutable iy1 = (iy0 + 1) % p;
        immutable tx = gx - fx;
        immutable ty = gy - fy;
        immutable ux = tx * tx * (3.0f - 2.0f * tx);
        immutable uy = ty * ty * (3.0f - 2.0f * ty);
        immutable a = hash2D(ix0 + p * 7, iy0 + p * 13);
        immutable b = hash2D(ix1 + p * 7, iy0 + p * 13);
        immutable c = hash2D(ix0 + p * 7, iy1 + p * 13);
        immutable d = hash2D(ix1 + p * 7, iy1 + p * 13);
        immutable n = (a + (b - a) * ux) + ((c - a) + (a - b - c + d) * ux) * uy;
        sum += n * amp;
        norm += amp;
        amp *= 0.5f;
        p *= 2;
    }
    return norm > 0.0f ? sum / norm : 0.0f;
}

private ubyte clampByte(float v) pure nothrow @nogc {
    if (v <= 0.0f) return 0;
    if (v >= 255.0f) return 255;
    return cast(ubyte) v;
}

/// Evaluate 6-octave Gerstner swell + analytical tangent/bitangent/normal.
private WaveSample sampleGerstner(float x, float z, float time, bool riverMode, float waveScale) pure nothrow @nogc {
    immutable waves = riverMode ? RIVER_WAVES : OCEAN_WAVES;
    Vec3 p = Vec3(x, 0.0f, z);
    Vec3 dPdx = Vec3(1.0f, 0.0f, 0.0f);
    Vec3 dPdz = Vec3(0.0f, 0.0f, 1.0f);

    float bankMask = 1.0f;
    if (riverMode) {
        // Taper wave height slightly near the canyon riverbanks |z| > 5.5
        immutable absZ = fabs(z);
        if (absZ > 4.5f) {
            immutable t = (absZ - 4.5f) / 3.5f;
            bankMask = t >= 1.0f ? 0.15f : 1.0f - t * 0.85f;
        }
    }

    immutable float waveSet = 0.78f + 0.28f * sin(time * 0.68f - x * 0.12f + z * 0.15f);
    float heightAccum = 0.0f;
    foreach (ref w; waves) {
        immutable k = (2.0f * cast(float) PI) / w.wavelength;
        immutable c = sqrt(9.81f / k) * w.speedScale;
        immutable a = w.amplitude * waveScale * bankMask * waveSet;
        immutable q = w.steepness;
        immutable phase = k * (w.dirX * x + w.dirZ * z) - k * c * time;
        immutable sn = sin(phase);
        immutable cs = cos(phase);

        immutable qa = q * a;
        p.x += qa * w.dirX * cs;
        p.y += a * sn;
        p.z += qa * w.dirZ * cs;
        heightAccum += sn * 0.5f + 0.5f;

        immutable wa = k * a;
        immutable qwa = q * wa;
        dPdx.x -= qwa * w.dirX * w.dirX * sn;
        dPdx.y += wa * w.dirX * cs;
        dPdx.z -= qwa * w.dirX * w.dirZ * sn;

        dPdz.x -= qwa * w.dirX * w.dirZ * sn;
        dPdz.y += wa * w.dirZ * cs;
        dPdz.z -= qwa * w.dirZ * w.dirZ * sn;
    }

    // Normal = normalize(cross(dPdz, dPdx)) points +Y when dPdx=(1,0,0), dPdz=(0,0,1).
    Vec3 n = dPdz.cross(dPdx).normalized();
    Vec3 t = dPdx.normalized();
    t = (t - n * n.dot(t)).normalized();

    WaveSample s;
    s.position = p;
    s.normal = n;
    s.tangent = t;
    s.foam = heightAccum / cast(float) waves.length;
    return s;
}

/// GPU uniform payload matching `WaterUniforms` in `assets/shaders/common/water_env.wgsl`.
private struct WaterUniforms {
    float[4] camForward;       // xyz = forward, w = tanHalfFov
    float[4] camRight;         // xyz = right,   w = aspect
    float[4] camUp;            // xyz = up,      w = waterHalf
    float[4] params0;          // x = time, y = waveScale, z = gridSpan, w = seaFloorY
    uint[4]  flags0;           // x = riverMode, y = useOpenPbr, z = transparent, w = lowSun
    uint[4]  counts;           // x = obstacleCount, y = waveCount, z = 0, w = 0
    float[4][6]  wavesA;       // dirX, dirZ, wavelength, amplitude
    float[4][6]  wavesB;       // steepness, speedScale, 0, 0
    float[4][16] obstacles;    // x, z, radius, strength
}

mixin ValidateUniformLayout!WaterUniforms;
static assert(WaterUniforms.sizeof == 544);

/// Lightweight static vertex+index GPU mesh for stride-32 `TexVert` buffers.
private struct StaticMesh32 {
    WGPUBuffer vbuf;
    WGPUBuffer ibuf;
    ulong vSize;
    ulong iSize;
    uint indexCount;

    @disable this(this);

    static StaticMesh32 create(ref GpuContext gpu, scope const(TexVert)[] verts, scope const(ushort)[] indices) @trusted {
        StaticMesh32 m;
        auto dev = gpu.getDevice();
        auto q   = gpu.getQueue();
        m.vSize = verts.length * TexVert.sizeof;
        m.iSize = indices.length * ushort.sizeof;
        m.vbuf = createVertexBuffer(dev, q, verts.ptr, m.vSize);
        m.ibuf = createIndexBuffer(dev, q, indices.ptr, m.iSize);
        m.indexCount = cast(uint) indices.length;
        return m;
    }

    void destroy() nothrow @nogc {
        destroyBuffer(vbuf); vbuf = null;
        destroyBuffer(ibuf); ibuf = null;
    }
}

private void drawNonIndexed(ref FrameContext frame, uint vertexCount) nothrow @nogc @trusted {
    wgpuRenderPassEncoderDraw(frame.pass, vertexCount, 1, 0, 0);
}

/// Custom sky-dome, procedural caustics bed, and GPU-Gerstner water pipelines
/// rendered directly inside the single HDR scene pass without modifying Renderer.
private struct WaterShaderPipelines {
    enum uint SIM_RES = 256;

    WGPUBindGroupLayout waterBgLayout;
    WGPUBindGroupLayout waterSurfaceBgLayout;
    WGPUBindGroupLayout simBgLayout;
    WGPUPipelineLayout  skyPipeLayout;
    WGPUPipelineLayout  pbrPipeLayout;
    WGPUPipelineLayout  waterPipeLayout;
    WGPUPipelineLayout  simPipeLayout;
    WGPUShaderModule    skyMod;
    WGPUShaderModule    bedMod;
    WGPUShaderModule    waterMod;
    WGPUShaderModule    simCsMod;
    WGPURenderPipeline  skyPipe;
    WGPURenderPipeline  bedPipe;
    WGPURenderPipeline  waterPipe;
    WGPUComputePipeline simPipe;
    WGPUBuffer          ubo;
    WGPUBindGroup       waterBg;
    WGPUSampler         sceneSampler;
    WGPUTexture         dummyColorTex;
    WGPUTextureView     dummyColorView;
    WGPUTexture[2]      simTex;
    WGPUTextureView[2]  simView;
    WGPUBindGroup[2]    simBg;
    uint                simPingPong = 0;
    WGPUBindGroup[2]    waterSurfaceBg;
    WGPUTextureView     cachedColorView;
    WGPUTextureView     cachedDepthView;

    @disable this(this);

    static WaterShaderPipelines create(ref GpuContext gpu,
                                       WGPUBindGroupLayout frameLayout,
                                       WGPUBindGroupLayout iblLayout) @trusted {
        WaterShaderPipelines p;
        auto dev = gpu.getDevice();
        auto colorFmt = Renderer.sceneFormat();

        WGPUBindGroupLayoutEntry bgle;
        bgle.binding = 0;
        bgle.visibility = WGPUShaderStage.vertex | WGPUShaderStage.fragment;
        bgle.buffer.type = WGPUBufferBindingType.uniform;
        bgle.buffer.minBindingSize = WaterUniforms.sizeof;

        WGPUBindGroupLayoutDescriptor bglDesc;
        bglDesc.entryCount = 1;
        bglDesc.entries = &bgle;
        p.waterBgLayout = wgpuDeviceCreateBindGroupLayout(dev, &bglDesc);

        WGPUBindGroupLayoutEntry[5] sEntries;
        sEntries[0].binding = 0;
        sEntries[0].visibility = WGPUShaderStage.vertex | WGPUShaderStage.fragment;
        sEntries[0].buffer.type = WGPUBufferBindingType.uniform;
        sEntries[0].buffer.minBindingSize = WaterUniforms.sizeof;
        sEntries[1].binding = 1;
        sEntries[1].visibility = WGPUShaderStage.fragment;
        sEntries[1].texture.sampleType = WGPUTextureSampleType.float_;
        sEntries[1].texture.viewDimension = WGPUTextureViewDimension.dim2D;
        sEntries[2].binding = 2;
        sEntries[2].visibility = WGPUShaderStage.fragment;
        sEntries[2].texture.sampleType = WGPUTextureSampleType.depth;
        sEntries[2].texture.viewDimension = WGPUTextureViewDimension.dim2D;
        sEntries[3].binding = 3;
        sEntries[3].visibility = WGPUShaderStage.fragment;
        sEntries[3].sampler.type = WGPUSamplerBindingType.filtering;
        sEntries[4].binding = 4;
        sEntries[4].visibility = WGPUShaderStage.fragment;
        sEntries[4].texture.sampleType = WGPUTextureSampleType.float_;
        sEntries[4].texture.viewDimension = WGPUTextureViewDimension.dim2D;

        WGPUBindGroupLayoutDescriptor sbglDesc;
        sbglDesc.entryCount = 5;
        sbglDesc.entries = sEntries.ptr;
        p.waterSurfaceBgLayout = wgpuDeviceCreateBindGroupLayout(dev, &sbglDesc);

        // WTR-6 compute layout: UBO + prevSimTex + simSampler + nextSimTex (rgba16float write)
        WGPUBindGroupLayoutEntry[4] csEntries;
        csEntries[0].binding = 0;
        csEntries[0].visibility = WGPUShaderStage.compute;
        csEntries[0].buffer.type = WGPUBufferBindingType.uniform;
        csEntries[0].buffer.minBindingSize = WaterUniforms.sizeof;
        csEntries[1].binding = 1;
        csEntries[1].visibility = WGPUShaderStage.compute;
        csEntries[1].texture.sampleType = WGPUTextureSampleType.float_;
        csEntries[1].texture.viewDimension = WGPUTextureViewDimension.dim2D;
        csEntries[2].binding = 2;
        csEntries[2].visibility = WGPUShaderStage.compute;
        csEntries[2].sampler.type = WGPUSamplerBindingType.filtering;
        csEntries[3].binding = 3;
        csEntries[3].visibility = WGPUShaderStage.compute;
        csEntries[3].storageTexture.access = WGPUStorageTextureAccess.writeOnly;
        csEntries[3].storageTexture.format = WGPUTextureFormat.rgba16Float;
        csEntries[3].storageTexture.viewDimension = WGPUTextureViewDimension.dim2D;

        WGPUBindGroupLayoutDescriptor csBglDesc;
        csBglDesc.entryCount = 4;
        csBglDesc.entries = csEntries.ptr;
        p.simBgLayout = wgpuDeviceCreateBindGroupLayout(dev, &csBglDesc);

        WGPUSamplerDescriptor sampDesc;
        sampDesc.addressModeU = WGPUAddressMode.clampToEdge;
        sampDesc.addressModeV = WGPUAddressMode.clampToEdge;
        sampDesc.addressModeW = WGPUAddressMode.clampToEdge;
        sampDesc.magFilter = WGPUFilterMode.linear;
        sampDesc.minFilter = WGPUFilterMode.linear;
        sampDesc.mipmapFilter = WGPUMipmapFilterMode.nearest;
        sampDesc.lodMinClamp = 0.0f;
        sampDesc.lodMaxClamp = 1.0f;
        sampDesc.maxAnisotropy = 1;
        p.sceneSampler = wgpuDeviceCreateSampler(dev, &sampDesc);

        {
            WGPUTextureDescriptor dtd;
            dtd.usage = WGPUTextureUsage.textureBinding;
            dtd.dimension = WGPUTextureDimension.dim2D;
            dtd.size = WGPUExtent3D(1, 1, 1);
            dtd.format = WGPUTextureFormat.rgba8Unorm;
            p.dummyColorTex = wgpuDeviceCreateTexture(dev, &dtd);
            WGPUTextureViewDescriptor dvd;
            dvd.format = WGPUTextureFormat.rgba8Unorm;
            dvd.dimension = WGPUTextureViewDimension.dim2D;
            p.dummyColorView = wgpuTextureCreateView(p.dummyColorTex, &dvd);
        }

        // 256x256 rgba16Float ping-pong simulation textures (JONSWAP slope + advected foam)
        foreach (i; 0 .. 2) {
            WGPUTextureDescriptor std;
            std.usage = WGPUTextureUsage.textureBinding | WGPUTextureUsage.storageBinding;
            std.dimension = WGPUTextureDimension.dim2D;
            std.size = WGPUExtent3D(SIM_RES, SIM_RES, 1);
            std.format = WGPUTextureFormat.rgba16Float;
            p.simTex[i] = wgpuDeviceCreateTexture(dev, &std);
            if (p.simTex[i] is null) fatal("Failed to allocate WTR-6 water simulation texture");
            WGPUTextureViewDescriptor svd;
            svd.format = WGPUTextureFormat.rgba16Float;
            svd.dimension = WGPUTextureViewDimension.dim2D;
            p.simView[i] = wgpuTextureCreateView(p.simTex[i], &svd);
        }

        WGPUBindGroupLayout[2] skyLayouts = [frameLayout, p.waterBgLayout];
        WGPUPipelineLayoutDescriptor skyPlDesc;
        skyPlDesc.bindGroupLayoutCount = 2;
        skyPlDesc.bindGroupLayouts = skyLayouts.ptr;
        p.skyPipeLayout = wgpuDeviceCreatePipelineLayout(dev, &skyPlDesc);

        WGPUBindGroupLayout[3] pbrLayouts = [frameLayout, p.waterBgLayout, iblLayout];
        WGPUPipelineLayoutDescriptor pbrPlDesc;
        pbrPlDesc.bindGroupLayoutCount = 3;
        pbrPlDesc.bindGroupLayouts = pbrLayouts.ptr;
        p.pbrPipeLayout = wgpuDeviceCreatePipelineLayout(dev, &pbrPlDesc);

        WGPUBindGroupLayout[3] surfLayouts = [frameLayout, p.waterSurfaceBgLayout, iblLayout];
        WGPUPipelineLayoutDescriptor surfPlDesc;
        surfPlDesc.bindGroupLayoutCount = 3;
        surfPlDesc.bindGroupLayouts = surfLayouts.ptr;
        p.waterPipeLayout = wgpuDeviceCreatePipelineLayout(dev, &surfPlDesc);

        WGPUPipelineLayoutDescriptor simPlDesc;
        simPlDesc.bindGroupLayoutCount = 1;
        simPlDesc.bindGroupLayouts = &p.simBgLayout;
        p.simPipeLayout = wgpuDeviceCreatePipelineLayout(dev, &simPlDesc);

        p.ubo = createUniformBuffer(dev, WaterUniforms.sizeof);
        p.waterBg = createUniformBindGroup(dev, p.waterBgLayout, p.ubo, WaterUniforms.sizeof);

        // simBg[0]: read simView[0], write simView[1]; simBg[1]: read simView[1], write simView[0].
        foreach (i; 0 .. 2) {
            WGPUBindGroupEntry[4] ce;
            ce[0].binding = 0; ce[0].buffer = p.ubo; ce[0].offset = 0; ce[0].size = WaterUniforms.sizeof;
            ce[1].binding = 1; ce[1].textureView = p.simView[i];
            ce[2].binding = 2; ce[2].sampler = p.sceneSampler;
            ce[3].binding = 3; ce[3].textureView = p.simView[i ^ 1];
            WGPUBindGroupDescriptor cbgd;
            cbgd.layout = p.simBgLayout;
            cbgd.entryCount = 4;
            cbgd.entries = ce.ptr;
            p.simBg[i] = wgpuDeviceCreateBindGroup(dev, &cbgd);
        }

        p.simCsMod = createShaderModule(dev, waterSimCsShaderSource.ptr);
        if (p.simCsMod is null) fatal("Failed to compile water_sim_cs.wgsl");
        {
            WGPUComputePipelineDescriptor cpd;
            cpd.layout = p.simPipeLayout;
            cpd.compute.module_ = p.simCsMod;
            cpd.compute.entryPoint = wgpuStringView("cs_main");
            p.simPipe = wgpuDeviceCreateComputePipeline(dev, &cpd);
            if (p.simPipe is null) fatal("Failed to create WTR-6 water simulation compute pipeline");
        }

        p.skyMod   = createShaderModule(dev, skyDomeShaderSource.ptr);
        p.bedMod   = createShaderModule(dev, causticsBedShaderSource.ptr);
        p.waterMod = createShaderModule(dev, waterSurfaceShaderSource.ptr);
        if (p.skyMod is null || p.bedMod is null || p.waterMod is null) {
            fatal("Failed to compile water/sky/caustics WGSL shader modules");
        }

        // 1. Sky dome pipeline (fullscreen triangle, depth <= 1.0, no depth write)
        {
            WGPUColorTargetState colorTarget;
            colorTarget.format = colorFmt;
            colorTarget.writeMask = WGPUColorWriteMask.all;

            WGPUFragmentState fragState;
            fragState.module_ = p.skyMod;
            fragState.entryPoint = wgpuStringView("fs_main");
            fragState.targetCount = 1;
            fragState.targets = &colorTarget;

            WGPUDepthStencilState depthState;
            depthState.format = WGPUTextureFormat.depth24Plus;
            depthState.depthWriteEnabled = WGPUOptionalBool.false_;
            depthState.depthCompare = WGPUCompareFunction.lessEqual;

            WGPURenderPipelineDescriptor desc;
            desc.layout = p.skyPipeLayout;
            desc.vertex.module_ = p.skyMod;
            desc.vertex.entryPoint = wgpuStringView("vs_main");
            desc.primitive.topology = WGPUPrimitiveTopology.triangleList;
            desc.primitive.frontFace = WGPUFrontFace.ccw;
            desc.primitive.cullMode = WGPUCullMode.none;
            desc.depthStencil = &depthState;
            desc.fragment = &fragState;
            p.skyPipe = wgpuDeviceCreateRenderPipeline(dev, &desc);
        }

        WGPUVertexAttribute[3] vertAttrs = [
            { format: WGPUVertexFormat.float32x3, offset: 0,  shaderLocation: 0 },
            { format: WGPUVertexFormat.float32x3, offset: 12, shaderLocation: 1 },
            { format: WGPUVertexFormat.float32x2, offset: 24, shaderLocation: 2 },
        ];
        WGPUVertexBufferLayout vbl;
        vbl.arrayStride = TexVert.sizeof;
        vbl.stepMode = WGPUVertexStepMode.vertex;
        vbl.attributeCount = 3;
        vbl.attributes = vertAttrs.ptr;

        // 2. Caustics riverbed pipeline (opaque, depth-writing)
        {
            WGPUColorTargetState colorTarget;
            colorTarget.format = colorFmt;
            colorTarget.writeMask = WGPUColorWriteMask.all;

            WGPUFragmentState fragState;
            fragState.module_ = p.bedMod;
            fragState.entryPoint = wgpuStringView("fs_main");
            fragState.targetCount = 1;
            fragState.targets = &colorTarget;

            WGPUDepthStencilState depthState;
            depthState.format = WGPUTextureFormat.depth24Plus;
            depthState.depthWriteEnabled = WGPUOptionalBool.true_;
            depthState.depthCompare = WGPUCompareFunction.less;

            WGPURenderPipelineDescriptor desc;
            desc.layout = p.pbrPipeLayout;
            desc.vertex.module_ = p.bedMod;
            desc.vertex.entryPoint = wgpuStringView("vs_main");
            desc.vertex.bufferCount = 1;
            desc.vertex.buffers = &vbl;
            desc.primitive.topology = WGPUPrimitiveTopology.triangleList;
            desc.primitive.frontFace = WGPUFrontFace.ccw;
            desc.primitive.cullMode = WGPUCullMode.back;
            desc.depthStencil = &depthState;
            desc.fragment = &fragState;
            p.bedPipe = wgpuDeviceCreateRenderPipeline(dev, &desc);
        }

        // 3. Dedicated GPU-Gerstner water surface pipeline (alpha blend + depth write)
        {
            WGPUBlendState blendState;
            blendState.color.operation = WGPUBlendOperation.add;
            blendState.color.srcFactor = WGPUBlendFactor.srcAlpha;
            blendState.color.dstFactor = WGPUBlendFactor.oneMinusSrcAlpha;
            blendState.alpha.operation = WGPUBlendOperation.add;
            blendState.alpha.srcFactor = WGPUBlendFactor.one;
            blendState.alpha.dstFactor = WGPUBlendFactor.oneMinusSrcAlpha;

            WGPUColorTargetState colorTarget;
            colorTarget.format = colorFmt;
            colorTarget.blend = &blendState;
            colorTarget.writeMask = WGPUColorWriteMask.all;

            WGPUFragmentState fragState;
            fragState.module_ = p.waterMod;
            fragState.entryPoint = wgpuStringView("fs_main");
            fragState.targetCount = 1;
            fragState.targets = &colorTarget;

            WGPUDepthStencilState depthState;
            depthState.format = WGPUTextureFormat.depth24Plus;
            depthState.depthWriteEnabled = WGPUOptionalBool.true_;
            depthState.depthCompare = WGPUCompareFunction.less;

            WGPURenderPipelineDescriptor desc;
            desc.layout = p.waterPipeLayout;
            desc.vertex.module_ = p.waterMod;
            desc.vertex.entryPoint = wgpuStringView("vs_main");
            desc.vertex.bufferCount = 1;
            desc.vertex.buffers = &vbl;
            desc.primitive.topology = WGPUPrimitiveTopology.triangleList;
            desc.primitive.frontFace = WGPUFrontFace.ccw;
            desc.primitive.cullMode = WGPUCullMode.none;
            desc.depthStencil = &depthState;
            desc.fragment = &fragState;
            p.waterPipe = wgpuDeviceCreateRenderPipeline(dev, &desc);
        }

        if (p.skyPipe is null || p.bedPipe is null || p.waterPipe is null) {
            fatal("Failed to create water/sky/caustics render pipelines");
        }
        return p;
    }

    void stepSimulation(ref GpuContext gpu) nothrow @nogc @trusted {
        auto dev = gpu.getDevice();
        auto q = gpu.getQueue();
        WGPUCommandEncoderDescriptor ced;
        auto enc = wgpuDeviceCreateCommandEncoder(dev, &ced);
        WGPUComputePassDescriptor cpd;
        auto pass = wgpuCommandEncoderBeginComputePass(enc, &cpd);
        wgpuComputePassEncoderSetPipeline(pass, simPipe);
        wgpuComputePassEncoderSetBindGroup(pass, 0, simBg[simPingPong], 0, null);
        wgpuComputePassEncoderDispatchWorkgroups(pass, SIM_RES / 8, SIM_RES / 8, 1);
        wgpuComputePassEncoderEnd(pass);
        wgpuComputePassEncoderRelease(pass);
        WGPUCommandBufferDescriptor cbd;
        auto cmd = wgpuCommandEncoderFinish(enc, &cbd);
        wgpuCommandEncoderRelease(enc);
        wgpuQueueSubmit(q, 1, &cmd);
        wgpuCommandBufferRelease(cmd);
        simPingPong ^= 1u;
    }

    void updateSurfaceBindGroup(WGPUDevice dev, WGPUTextureView colorView, WGPUTextureView depthView) nothrow @nogc @trusted {
        if (colorView is null || depthView is null) return;
        if (waterSurfaceBg[0] !is null && cachedColorView is colorView && cachedDepthView is depthView) return;
        foreach (i; 0 .. 2) {
            releaseBindGroup(waterSurfaceBg[i]);
            WGPUBindGroupEntry[5] e;
            e[0].binding = 0; e[0].buffer = ubo; e[0].offset = 0; e[0].size = WaterUniforms.sizeof;
            e[1].binding = 1; e[1].textureView = colorView;
            e[2].binding = 2; e[2].textureView = depthView;
            e[3].binding = 3; e[3].sampler = sceneSampler;
            e[4].binding = 4; e[4].textureView = simView[i];
            WGPUBindGroupDescriptor bgd;
            bgd.layout = waterSurfaceBgLayout;
            bgd.entryCount = 5;
            bgd.entries = e.ptr;
            waterSurfaceBg[i] = wgpuDeviceCreateBindGroup(dev, &bgd);
        }
        cachedColorView = colorView;
        cachedDepthView = depthView;
    }

    void destroy() nothrow @nogc @trusted {
        if (simPipe !is null)              { wgpuComputePipelineRelease(simPipe); simPipe = null; }
        if (simCsMod !is null)             { wgpuShaderModuleRelease(simCsMod); simCsMod = null; }
        if (waterPipe !is null)            { wgpuRenderPipelineRelease(waterPipe); waterPipe = null; }
        if (bedPipe !is null)              { wgpuRenderPipelineRelease(bedPipe); bedPipe = null; }
        if (skyPipe !is null)              { wgpuRenderPipelineRelease(skyPipe); skyPipe = null; }
        if (waterMod !is null)             { wgpuShaderModuleRelease(waterMod); waterMod = null; }
        if (bedMod !is null)               { wgpuShaderModuleRelease(bedMod); bedMod = null; }
        if (skyMod !is null)               { wgpuShaderModuleRelease(skyMod); skyMod = null; }
        foreach (i; 0 .. 2) {
            releaseBindGroup(waterSurfaceBg[i]);
            releaseBindGroup(simBg[i]);
            if (simView[i] !is null) { wgpuTextureViewRelease(simView[i]); simView[i] = null; }
            if (simTex[i] !is null)  { wgpuTextureRelease(simTex[i]); simTex[i] = null; }
        }
        releaseBindGroup(waterBg);
        if (dummyColorView !is null)       { wgpuTextureViewRelease(dummyColorView); dummyColorView = null; }
        if (dummyColorTex !is null)        { wgpuTextureRelease(dummyColorTex); dummyColorTex = null; }
        if (sceneSampler !is null)         { wgpuSamplerRelease(sceneSampler); sceneSampler = null; }
        destroyBuffer(ubo); ubo = null;
        if (simPipeLayout !is null)        { wgpuPipelineLayoutRelease(simPipeLayout); simPipeLayout = null; }
        if (waterPipeLayout !is null)      { wgpuPipelineLayoutRelease(waterPipeLayout); waterPipeLayout = null; }
        if (pbrPipeLayout !is null)        { wgpuPipelineLayoutRelease(pbrPipeLayout); pbrPipeLayout = null; }
        if (skyPipeLayout !is null)        { wgpuPipelineLayoutRelease(skyPipeLayout); skyPipeLayout = null; }
        if (simBgLayout !is null)          { wgpuBindGroupLayoutRelease(simBgLayout); simBgLayout = null; }
        if (waterSurfaceBgLayout !is null) { wgpuBindGroupLayoutRelease(waterSurfaceBgLayout); waterSurfaceBgLayout = null; }
        if (waterBgLayout !is null)        { wgpuBindGroupLayoutRelease(waterBgLayout); waterBgLayout = null; }
        cachedColorView = null;
        cachedDepthView = null;
    }
}

private StaticMesh32 buildWaterGridMesh32(ref GpuContext gpu) {
    immutable uint stride = WATER_GRID + 1;
    immutable float span = WATER_HALF * 2.0f;
    auto verts = new TexVert[stride * stride];
    foreach (row; 0 .. stride) {
        immutable float v = cast(float) row / cast(float) WATER_GRID;
        immutable float z = -WATER_HALF + v * span;
        foreach (col; 0 .. stride) {
            immutable float u = cast(float) col / cast(float) WATER_GRID;
            immutable float x = -WATER_HALF + u * span;
            verts[row * stride + col] = TexVert([x, 0.0f, z], [0.0f, 1.0f, 0.0f], [u, v]);
        }
    }

    auto indices = new ushort[WATER_GRID * WATER_GRID * 6];
    uint ii = 0;
    foreach (row; 0 .. WATER_GRID) {
        foreach (col; 0 .. WATER_GRID) {
            immutable ushort a = cast(ushort)(row * stride + col);
            immutable ushort b = cast(ushort)(a + 1);
            immutable ushort c = cast(ushort)(a + stride);
            immutable ushort d = cast(ushort)(c + 1);
            // Counter-clockwise winding viewed from +Y
            indices[ii++] = a;
            indices[ii++] = d;
            indices[ii++] = b;
            indices[ii++] = a;
            indices[ii++] = c;
            indices[ii++] = d;
        }
    }
    return StaticMesh32.create(gpu, verts, indices);
}

private StaticMesh32 buildBedQuad32(ref GpuContext gpu) {
    immutable float h = WATER_HALF;
    TexVert[4] verts = [
        TexVert([-h, -1.15f, -h], [0, 1, 0], [0.0f, 0.0f]),
        TexVert([ h, -1.15f, -h], [0, 1, 0], [8.0f, 0.0f]),
        TexVert([ h, -1.15f,  h], [0, 1, 0], [8.0f, 8.0f]),
        TexVert([-h, -1.15f,  h], [0, 1, 0], [0.0f, 8.0f]),
    ];
    ushort[6] indices = [0, 2, 1, 0, 3, 2];
    return StaticMesh32.create(gpu, verts[], indices[]);
}

private void buildHeightNormalMap(const(float)[] height, uint sz, float strength, ubyte[] normalOut) pure nothrow @nogc {
    foreach (y; 0 .. sz) {
        immutable uint ym = (y + sz - 1) % sz;
        immutable uint yp = (y + 1) % sz;
        foreach (x; 0 .. sz) {
            immutable uint xm = (x + sz - 1) % sz;
            immutable uint xp = (x + 1) % sz;
            immutable float dx = (height[y * sz + xp] - height[y * sz + xm]) * strength;
            immutable float dy = (height[yp * sz + x] - height[ym * sz + x]) * strength;
            immutable Vec3 n = Vec3(-dx, -dy, 1.0f).normalized();
            immutable idx = (y * sz + x) * 4;
            normalOut[idx + 0] = clampByte((n.x * 0.5f + 0.5f) * 255.0f);
            normalOut[idx + 1] = clampByte((n.y * 0.5f + 0.5f) * 255.0f);
            normalOut[idx + 2] = clampByte((n.z * 0.5f + 0.5f) * 255.0f);
            normalOut[idx + 3] = 255;
        }
    }
}

private void generateEnvTextures(ref GpuContext gpu,
                                 out Texture bankAlbedoTex, out Texture bankNormalTex,
                                 out Texture woodAlbedoTex, out Texture woodNormalTex,
                                 out Texture masonryAlbedoTex, out Texture masonryNormalTex) {
    enum uint SZ = 512;
    auto bankA    = new ubyte[SZ * SZ * 4];
    auto bankN    = new ubyte[SZ * SZ * 4];
    auto bankH    = new float[SZ * SZ];
    auto woodA    = new ubyte[SZ * SZ * 4];
    auto woodN    = new ubyte[SZ * SZ * 4];
    auto woodH    = new float[SZ * SZ];
    auto masonryA = new ubyte[SZ * SZ * 4];
    auto masonryN = new ubyte[SZ * SZ * 4];
    auto masonryH = new float[SZ * SZ];

    foreach (y; 0 .. SZ) {
        immutable float v = cast(float) y / cast(float) SZ;
        foreach (x; 0 .. SZ) {
            immutable float u = cast(float) x / cast(float) SZ;
            immutable idx = (y * SZ + x) * 4;

            // 2. Damp mossy forest earth & dark slate gravel for riverbanks ([0.03..0.10])
            immutable soil = fbmPeriodic(u + 0.11f, v + 0.37f, 12, 4);
            immutable gravel = fbmPeriodic(u + 0.73f, v + 0.29f, 32, 3);
            immutable mossPatch = soil > 0.54f ? (soil - 0.54f) * 2.1f : 0.0f;
            immutable bankElev = soil * 0.55f + gravel * 0.45f;
            bankH[y * SZ + x] = bankElev;
            immutable bankDark = 0.036f + bankElev * 0.058f;
            immutable rSoil = bankDark * 1.08f;
            immutable gSoil = bankDark * 0.95f;
            immutable bSoil = bankDark * 0.78f;
            immutable mp = mossPatch > 1.0f ? 1.0f : mossPatch;
            bankA[idx + 0] = clampByte((rSoil * (1.0f - mp) + 0.036f * mp) * 255.0f);
            bankA[idx + 1] = clampByte((gSoil * (1.0f - mp) + 0.068f * mp) * 255.0f);
            bankA[idx + 2] = clampByte((bSoil * (1.0f - mp) + 0.022f * mp) * 255.0f);
            bankA[idx + 3] = 255;

            // 3. Weathered timber bridge planks along V (linear [0.05..0.15])
            immutable int plankIdx = cast(int)(u * 8.0f);
            immutable float uInPlank = u * 8.0f - cast(float) plankIdx;
            immutable bool plankSeam = (uInPlank < 0.035f || uInPlank > 0.965f);
            immutable float grain = sin((u * 48.0f + fbmPeriodic(u + 0.05f * plankIdx, v, 8, 3) * 3.8f) * PI_2) * 0.5f + 0.5f;
            immutable float plankTone = 0.85f + hash2D(plankIdx, 19) * 0.30f;
            immutable float woodVal = plankSeam ? 0.12f : (0.45f + grain * 0.55f);
            woodH[y * SZ + x] = woodVal;
            immutable float woodLin = (0.052f + woodVal * 0.082f) * plankTone;
            woodA[idx + 0] = clampByte(woodLin * 1.24f * 255.0f);
            woodA[idx + 1] = clampByte(woodLin * 0.84f * 255.0f);
            woodA[idx + 2] = clampByte(woodLin * 0.52f * 255.0f);
            woodA[idx + 3] = 255;

            // 4. Coursed granite ashlar blocks for bridge abutments & lighthouse trim ([0.05..0.14])
            immutable int rowIdx = cast(int)(v * 6.0f);
            immutable float vInRow = v * 6.0f - cast(float) rowIdx;
            immutable float staggeredU = u + ((rowIdx & 1) != 0 ? 0.5f / 4.0f : 0.0f);
            immutable float uBlockPos = staggeredU * 4.0f;
            import std.math : floor;
            immutable int colIdx = cast(int) floor(uBlockPos);
            immutable float uInBlock = uBlockPos - floor(uBlockPos);
            immutable bool mortar = (vInRow < 0.06f || vInRow > 0.94f || uInBlock < 0.045f || uInBlock > 0.955f);
            immutable float blockSeed = hash2D(colIdx, rowIdx);
            immutable float stoneGrain = fbmPeriodic(u + blockSeed * 0.3f, v, 24, 3);
            immutable float mH = mortar ? 0.15f : (0.55f + stoneGrain * 0.45f);
            masonryH[y * SZ + x] = mH;
            immutable float mLin = mortar
                ? 0.045f + stoneGrain * 0.020f
                : (0.072f + stoneGrain * 0.055f) * (0.85f + blockSeed * 0.30f);
            masonryA[idx + 0] = clampByte(mLin * 1.03f * 255.0f);
            masonryA[idx + 1] = clampByte(mLin * 0.99f * 255.0f);
            masonryA[idx + 2] = clampByte(mLin * 0.94f * 255.0f);
            masonryA[idx + 3] = 255;
        }
    }

    buildHeightNormalMap(bankH, SZ, 3.4f, bankN);
    buildHeightNormalMap(woodH, SZ, 3.2f, woodN);
    buildHeightNormalMap(masonryH, SZ, 3.6f, masonryN);

    bankAlbedoTex    = Texture.fromPixels(gpu, bankA, SZ, SZ);
    bankNormalTex    = Texture.fromPixels(gpu, bankN, SZ, SZ);
    woodAlbedoTex    = Texture.fromPixels(gpu, woodA, SZ, SZ);
    woodNormalTex    = Texture.fromPixels(gpu, woodN, SZ, SZ);
    masonryAlbedoTex = Texture.fromPixels(gpu, masonryA, SZ, SZ);
    masonryNormalTex = Texture.fromPixels(gpu, masonryN, SZ, SZ);
}

/// Fills GPU `WaterUniforms` on the stack with camera ray basis, waves, and active obstacles.
private WaterUniforms packWaterUniforms(ref const Camera camera,
                                        float time,
                                        float waveScale,
                                        bool riverMode,
                                        bool useOpenPbr,
                                        bool transparent,
                                        bool lowSun,
                                        bool enableRefraction,
                                        bool enableSsr,
                                        scope const(RockPlacement)[] rocks) nothrow @nogc {
    WaterUniforms wu;
    immutable fwd = (camera.target - camera.position).normalized();
    immutable right = fwd.cross(camera.up).normalized();
    immutable up = right.cross(fwd);
    immutable tanHalfFov = tan(camera.fovY * 0.5f);

    wu.camForward = [fwd.x, fwd.y, fwd.z, tanHalfFov];
    wu.camRight   = [right.x, right.y, right.z, camera.aspect];
    wu.camUp      = [up.x, up.y, up.z, WATER_HALF];
    wu.params0    = [time, waveScale, camera.near, camera.far];
    wu.flags0     = [
        riverMode ? 1u : 0u,
        useOpenPbr ? 1u : 0u,
        transparent ? 1u : 0u,
        lowSun ? 1u : 0u,
    ];

    immutable waves = riverMode ? RIVER_WAVES : OCEAN_WAVES;
    foreach (i, ref w; waves) {
        wu.wavesA[i] = [w.dirX, w.dirZ, w.wavelength, w.amplitude];
        wu.wavesB[i] = [w.steepness, w.speedScale, 0.0f, 0.0f];
    }

    uint obsCount = 0;
    if (riverMode) {
        // Wooden bridge piers breaking stream flow & forming downstream wakes.
        wu.obstacles[obsCount++] = [-1.5f, -4.6f, 0.42f, 1.0f];
        wu.obstacles[obsCount++] = [-1.5f,  4.6f, 0.42f, 1.0f];
    }
    foreach (ref rk; rocks) {
        if (rk.kind != 1 || obsCount >= 16) continue;
        // Approximate emergent boulder waterline radius from mesh scale.
        immutable r = 0.34f * (rk.scale.x + rk.scale.z) * 0.5f;
        wu.obstacles[obsCount++] = [rk.pos.x, rk.pos.z, r, 1.0f];
    }
    wu.counts = [obsCount, 6u, enableRefraction ? 1u : 0u, enableSsr ? 1u : 0u];
    return wu;
}

/// Sculpted sloping riverbank terrain strip (z in [0..1], scaled/mirrored per side).
private TexMesh buildRiverBankMesh(ref GpuContext gpu, float zSign) {
    enum uint NX = 28;
    enum uint NZ = 10;
    enum uint SX = NX + 1;
    enum uint SZ = NZ + 1;
    auto verts = new TexTanVert[SX * SZ];

    float evalHeight(float x, float tZ) {
        // Rises organically from -0.85 beneath shoreline boulders to +2.25 up the gorge bank.
        immutable smooth = tZ * tZ * (3.0f - 2.0f * tZ);
        immutable baseH = -0.85f + smooth * 3.10f;
        immutable n1 = valueNoise(x * 0.25f + zSign * 7.3f, tZ * 2.5f + zSign * 3.1f) - 0.5f;
        immutable n2 = valueNoise(x * 0.65f + 12.1f, tZ * 5.0f + 4.7f) - 0.5f;
        return baseH + (n1 * 0.72f + n2 * 0.26f) * (0.25f + 0.75f * smooth);
    }

    foreach (iz; 0 .. SZ) {
        immutable float tZ = cast(float) iz / cast(float) NZ;
        immutable float z = zSign * (4.6f + tZ * 11.4f);
        foreach (ix; 0 .. SX) {
            immutable float tX = cast(float) ix / cast(float) NX;
            immutable float x = -16.0f + tX * 32.0f;
            immutable float y = evalHeight(x, tZ);
            immutable float eps = 0.25f;
            immutable float hdx = evalHeight(x + eps, tZ) - evalHeight(x - eps, tZ);
            immutable float hdz = evalHeight(x, tZ + 0.025f) - evalHeight(x, tZ - 0.025f);
            immutable float dzStep = zSign * (0.05f * 11.4f);
            Vec3 n = Vec3(-hdx / (2.0f * eps), 1.0f, -hdz / dzStep).normalized();
            Vec3 t = Vec3(1.0f, hdx / (2.0f * eps), 0.0f).normalized();
            t = (t - n * n.dot(t)).normalized();
            verts[iz * SX + ix] = TexTanVert(
                [x, y, z],
                [n.x, n.y, n.z],
                [tX * 7.0f, tZ * 3.0f],
                [t.x, t.y, t.z, -1.0f]
            );
        }
    }

    auto indices = new ushort[NX * NZ * 6];
    uint ii = 0;
    foreach (iz; 0 .. NZ) {
        foreach (ix; 0 .. NX) {
            immutable ushort a = cast(ushort)(iz * SX + ix);
            immutable ushort b = cast(ushort)(a + 1);
            immutable ushort c = cast(ushort)(a + SX);
            immutable ushort d = cast(ushort)(c + 1);
            if (zSign > 0.0f) {
                indices[ii++] = a; indices[ii++] = d; indices[ii++] = b;
                indices[ii++] = a; indices[ii++] = c; indices[ii++] = d;
            } else {
                indices[ii++] = a; indices[ii++] = b; indices[ii++] = d;
                indices[ii++] = a; indices[ii++] = d; indices[ii++] = c;
            }
        }
    }
    return TexMesh.fromData(gpu, verts, indices);
}

private struct RockPlacement {
    Vec3 pos;
    Vec3 scale;
    float rotY;
    ubyte kind;     // 0 = dry, 1 = wet, 2 = mossy, 3 = submerged pebble
    ubyte meshKind; // 0 = cliff, 1 = boulder, 2 = cobble
}

private enum RockPlacement[34] SEA_ROCKS = [
    // Shoreline rocky headland along -X and +Z edge (wet near waterline, dry higher up)
    RockPlacement(Vec3(-11.4f, -0.35f, -6.5f), Vec3(3.4f, 1.35f, 3.1f), 0.3f, 1, 1),
    RockPlacement(Vec3(-12.3f,  0.75f, -6.9f), Vec3(2.9f, 1.80f, 2.5f), 1.1f, 0, 0),
    RockPlacement(Vec3(-10.7f, -0.42f, -2.4f), Vec3(3.1f, 1.15f, 3.6f), 0.8f, 1, 1),
    RockPlacement(Vec3(-12.1f,  0.65f, -1.9f), Vec3(2.6f, 1.55f, 2.8f), 2.2f, 0, 0),
    RockPlacement(Vec3(-11.1f, -0.32f,  2.6f), Vec3(3.6f, 1.45f, 3.2f), 1.6f, 1, 1),
    RockPlacement(Vec3(-12.4f,  0.88f,  3.2f), Vec3(2.8f, 1.85f, 2.7f), 0.4f, 0, 0),
    RockPlacement(Vec3(-10.2f, -0.38f,  7.4f), Vec3(3.7f, 1.25f, 3.4f), 2.7f, 1, 1),
    RockPlacement(Vec3(-12.0f,  0.95f,  8.1f), Vec3(3.1f, 2.10f, 2.8f), 1.9f, 2, 0),
    RockPlacement(Vec3(-12.6f,  0.25f, -10.2f), Vec3(2.9f, 1.60f, 2.6f), 0.9f, 0, 0),
    RockPlacement(Vec3(-9.8f,  -0.45f, -9.8f), Vec3(2.6f, 1.10f, 2.4f), 2.4f, 1, 1),
    RockPlacement(Vec3(-9.2f,  -0.48f,  4.8f), Vec3(2.2f, 0.95f, 2.0f), 1.3f, 1, 1),
    RockPlacement(Vec3(-9.5f,  -0.50f,  0.2f), Vec3(2.0f, 0.90f, 2.1f), 0.5f, 1, 1),
    // Sea stack / offshore wet reefs
    RockPlacement(Vec3(  7.8f, -0.25f, -7.2f), Vec3(2.6f, 1.35f, 2.4f), 0.5f, 1, 0),
    RockPlacement(Vec3(  8.3f,  0.65f, -7.4f), Vec3(1.8f, 1.50f, 1.6f), 1.8f, 0, 0),
    RockPlacement(Vec3(  9.2f, -0.45f, -6.5f), Vec3(1.9f, 0.95f, 1.8f), 2.9f, 1, 1),
    RockPlacement(Vec3( -4.2f, -0.52f,  6.4f), Vec3(2.2f, 1.00f, 2.0f), 1.2f, 1, 1),
    RockPlacement(Vec3( -5.1f, -0.60f,  7.4f), Vec3(1.6f, 0.85f, 1.5f), 2.6f, 1, 1),
    // Submerged boulders visible through translucent water (rendered with wet coat)
    RockPlacement(Vec3( -2.8f, -0.88f, -2.4f), Vec3(2.0f, 0.72f, 1.7f), 0.6f, 3, 2),
    RockPlacement(Vec3(  1.6f, -0.86f,  2.8f), Vec3(2.3f, 0.78f, 1.9f), 2.1f, 3, 2),
    RockPlacement(Vec3(  4.5f, -0.92f, -1.2f), Vec3(1.8f, 0.64f, 1.6f), 1.4f, 3, 2),
    RockPlacement(Vec3( -6.2f, -0.82f,  1.2f), Vec3(2.2f, 0.76f, 1.8f), 0.9f, 3, 1),
    RockPlacement(Vec3(  0.2f, -0.94f, -4.8f), Vec3(2.5f, 0.68f, 2.0f), 2.5f, 3, 2),
    RockPlacement(Vec3(  5.2f, -0.84f,  5.0f), Vec3(2.0f, 0.70f, 1.8f), 0.2f, 3, 2),
    RockPlacement(Vec3( -7.8f, -0.78f, -4.8f), Vec3(1.8f, 0.76f, 1.6f), 1.7f, 3, 1),
    RockPlacement(Vec3(  2.5f, -0.89f, -6.5f), Vec3(2.2f, 0.68f, 1.9f), 2.8f, 3, 2),
    RockPlacement(Vec3( -1.5f, -0.91f,  5.6f), Vec3(1.9f, 0.65f, 1.7f), 1.0f, 3, 2),
    RockPlacement(Vec3(  8.8f, -0.82f,  1.5f), Vec3(2.4f, 0.80f, 2.0f), 0.4f, 3, 1),
    RockPlacement(Vec3( -5.0f, -0.86f, -7.2f), Vec3(2.0f, 0.72f, 1.8f), 2.3f, 3, 2),
    RockPlacement(Vec3( -0.9f, -0.98f,  0.9f), Vec3(1.6f, 0.60f, 1.4f), 1.1f, 3, 2),
    RockPlacement(Vec3(  3.1f, -0.87f, -2.6f), Vec3(1.7f, 0.66f, 1.5f), 2.0f, 3, 2),
    RockPlacement(Vec3( -4.4f, -0.83f,  3.2f), Vec3(1.8f, 0.68f, 1.5f), 0.7f, 3, 2),
    RockPlacement(Vec3(  6.4f, -0.88f, -3.9f), Vec3(2.1f, 0.66f, 1.8f), 1.5f, 3, 2),
    RockPlacement(Vec3( -8.2f, -0.80f,  5.5f), Vec3(1.9f, 0.72f, 1.7f), 2.9f, 3, 1),
    RockPlacement(Vec3(  1.2f, -0.90f,  6.8f), Vec3(1.8f, 0.62f, 1.6f), 0.8f, 3, 2),
];

private enum RockPlacement[34] RIVER_ROCKS = [
    // Left canyon bank (-Z side, flowing along +X) — naturally staggered boulders & ledges
    RockPlacement(Vec3(-11.2f, -0.22f, -6.2f), Vec3(3.1f, 1.10f, 2.5f), 0.35f, 1, 1),
    RockPlacement(Vec3(-10.8f,  0.62f, -8.8f), Vec3(3.6f, 1.65f, 2.9f), 1.10f, 2, 0),
    RockPlacement(Vec3( -7.4f, -0.28f, -5.9f), Vec3(2.6f, 0.95f, 2.2f), 2.15f, 1, 1),
    RockPlacement(Vec3( -6.8f,  0.48f, -8.3f), Vec3(3.2f, 1.35f, 2.6f), 0.65f, 2, 1),
    RockPlacement(Vec3( -3.6f,  0.85f,-10.2f), Vec3(3.8f, 1.85f, 3.0f), 1.85f, 0, 0),
    RockPlacement(Vec3(  1.6f, -0.24f, -6.1f), Vec3(2.9f, 1.05f, 2.3f), 1.40f, 1, 1),
    RockPlacement(Vec3(  2.5f,  0.65f, -8.7f), Vec3(3.9f, 1.75f, 3.1f), 2.75f, 2, 0),
    RockPlacement(Vec3(  6.2f, -0.30f, -6.4f), Vec3(2.5f, 0.90f, 2.2f), 0.85f, 1, 1),
    RockPlacement(Vec3(  8.8f,  0.55f, -8.5f), Vec3(3.5f, 1.55f, 2.8f), 1.95f, 2, 0),
    RockPlacement(Vec3( 11.4f, -0.20f, -6.7f), Vec3(3.0f, 1.15f, 2.5f), 2.45f, 1, 1),
    // Right canyon bank (+Z side)
    RockPlacement(Vec3(-10.9f, -0.25f,  6.5f), Vec3(2.9f, 1.05f, 2.4f), 2.60f, 1, 1),
    RockPlacement(Vec3(-10.2f,  0.72f,  9.0f), Vec3(3.9f, 1.75f, 3.2f), 0.45f, 2, 0),
    RockPlacement(Vec3( -6.5f, -0.22f,  6.0f), Vec3(2.7f, 0.98f, 2.2f), 1.25f, 1, 1),
    RockPlacement(Vec3( -5.8f,  0.52f,  8.6f), Vec3(3.3f, 1.45f, 2.7f), 2.95f, 2, 1),
    RockPlacement(Vec3( -2.8f,  0.90f, 10.4f), Vec3(3.6f, 1.90f, 2.9f), 0.90f, 0, 0),
    RockPlacement(Vec3(  1.9f, -0.26f,  6.3f), Vec3(2.8f, 1.00f, 2.3f), 1.75f, 1, 1),
    RockPlacement(Vec3(  3.4f,  0.68f,  8.9f), Vec3(3.7f, 1.80f, 3.0f), 0.30f, 2, 0),
    RockPlacement(Vec3(  7.1f, -0.28f,  5.8f), Vec3(2.6f, 0.92f, 2.1f), 2.20f, 1, 1),
    RockPlacement(Vec3(  9.2f,  0.58f,  8.6f), Vec3(3.4f, 1.55f, 2.8f), 1.15f, 2, 0),
    RockPlacement(Vec3( 11.5f, -0.20f,  6.4f), Vec3(3.1f, 1.15f, 2.6f), 0.55f, 1, 1),
    // Mid-stream wet boulders breaking rapids
    RockPlacement(Vec3( -8.5f, -0.28f,  1.6f), Vec3(2.1f, 1.05f, 1.8f), 0.70f, 1, 0),
    RockPlacement(Vec3( -5.2f, -0.34f, -1.9f), Vec3(1.8f, 0.90f, 1.6f), 2.35f, 1, 1),
    RockPlacement(Vec3(  3.8f, -0.32f, -1.4f), Vec3(2.2f, 0.96f, 1.9f), 1.85f, 1, 1),
    RockPlacement(Vec3(  8.4f, -0.26f,  1.5f), Vec3(2.3f, 1.08f, 2.0f), 0.25f, 1, 0),
    // Submerged riverbed cobbles & stones (wet water coat clearly visible underwater)
    RockPlacement(Vec3( -9.4f, -0.78f, -1.5f), Vec3(2.0f, 0.62f, 1.7f), 1.10f, 3, 2),
    RockPlacement(Vec3( -6.4f, -0.82f,  2.9f), Vec3(1.7f, 0.58f, 1.5f), 2.60f, 3, 2),
    RockPlacement(Vec3( -3.4f, -0.76f,  0.8f), Vec3(2.2f, 0.66f, 1.8f), 0.45f, 3, 2),
    RockPlacement(Vec3( -2.0f, -0.80f, -2.5f), Vec3(1.9f, 0.60f, 1.6f), 1.90f, 3, 1),
    RockPlacement(Vec3(  0.6f, -0.74f,  1.9f), Vec3(2.3f, 0.68f, 1.9f), 2.30f, 3, 2),
    RockPlacement(Vec3(  1.2f, -0.82f, -0.4f), Vec3(1.6f, 0.54f, 1.4f), 0.80f, 3, 2),
    RockPlacement(Vec3(  2.9f, -0.78f,  3.6f), Vec3(2.0f, 0.64f, 1.7f), 1.45f, 3, 2),
    RockPlacement(Vec3(  5.6f, -0.80f,  0.6f), Vec3(2.4f, 0.65f, 1.9f), 2.85f, 3, 1),
    RockPlacement(Vec3(  6.8f, -0.84f, -3.2f), Vec3(1.8f, 0.56f, 1.6f), 0.35f, 3, 2),
    RockPlacement(Vec3( 10.2f, -0.76f, -0.6f), Vec3(2.1f, 0.62f, 1.8f), 1.65f, 3, 2),
];

private struct OrbitState {
    Vec3 target = Vec3(0.0f, 0.2f, 0.0f);
    float distance = 16.5f;
    float yaw = 0.85f;
    float pitch = 0.42f;

    void update(ref const InputState input, float dt, ref Camera camera) {
        if (input.keyDown(Key.left))  yaw   -= 1.6f * dt;
        if (input.keyDown(Key.right)) yaw   += 1.6f * dt;
        if (input.keyDown(Key.up))    pitch += 0.9f * dt;
        if (input.keyDown(Key.down))  pitch -= 0.9f * dt;
        if (input.keyDown(Key.w)) distance -= 9.0f * dt;
        if (input.keyDown(Key.s)) distance += 9.0f * dt;

        if (input.mouseDown(MouseButton.left) || input.mouseDown(MouseButton.right)) {
            yaw   += input.mdx() * 0.005f;
            pitch -= input.mdy() * 0.005f;
        }
        distance -= input.wheelY() * 1.2f;

        if (pitch < 0.08f) pitch = 0.08f;
        if (pitch > 1.42f) pitch = 1.42f;
        if (distance < 4.5f) distance = 4.5f;
        if (distance > 34.0f) distance = 34.0f;

        immutable cp = cos(pitch);
        immutable eye = target + Vec3(
            cos(yaw) * cp * distance,
            sin(pitch) * distance,
            sin(yaw) * cp * distance,
        );
        camera.lookAt(eye, target);
    }
}

private MaterialParams buildDryRockParams() {
    MaterialParams p;
    // Albedo is baked directly in true linear reflectance in rock_*_albedo.bmp.
    p.baseColor = [1.0f, 0.98f, 0.95f];
    p.baseDiffuseRoughness = 0.85f;
    p.specularRoughness = 0.95f;
    p.specularIor = 1.52f;
    p.flags = MaterialFlags.normal | MaterialFlags.metallicRoughness | MaterialFlags.occlusion;
    return p;
}

private MaterialParams buildWetRockParams(bool useOpenPbr) {
    MaterialParams p = buildDryRockParams();
    if (useOpenPbr) {
        p.baseColor = [0.95f, 0.96f, 0.98f];
        p.baseDiffuseRoughness = 0.65f;
        p.specularRoughness = 0.52f;
        p.coatWeight = 0.90f;
        p.coatRoughness = 0.065f;
        p.coatIor = 1.333f;
        p.coatColor = [0.90f, 0.94f, 0.97f];
        p.coatDarkening = 0.72f;
    }
    return p;
}

private MaterialParams buildMossRockParams(bool useOpenPbr) {
    MaterialParams p = buildDryRockParams();
    p.baseColor = [1.0f, 1.0f, 1.0f];
    if (useOpenPbr) {
        p.baseDiffuseRoughness = 0.82f;
        p.specularRoughness = 0.90f;
        p.coatWeight = 0.12f;
        p.coatRoughness = 0.24f;
        p.coatIor = 1.333f;
        p.coatDarkening = 0.45f;
        p.fuzzWeight = 0.28f;
        p.fuzzColor = [0.20f, 0.28f, 0.11f];
        p.fuzzRoughness = 0.78f;
    } else {
        p.baseDiffuseRoughness = 0.0f;
        p.specularRoughness = 0.85f;
    }
    return p;
}

private MaterialParams buildSubmergedRockParams(bool useOpenPbr) {
    MaterialParams p = buildDryRockParams();
    if (useOpenPbr) {
        p.baseColor = [0.88f, 0.96f, 0.94f];
        p.baseDiffuseRoughness = 0.55f;
        p.specularRoughness = 0.42f;
        p.coatWeight = 0.95f;
        p.coatRoughness = 0.05f;
        p.coatIor = 1.333f;
        p.coatColor = [0.76f, 0.92f, 0.90f];
        p.coatDarkening = 0.72f;
    } else {
        p.baseColor = [0.88f, 0.86f, 0.82f];
        p.baseDiffuseRoughness = 0.0f;
        p.specularRoughness = 0.85f;
    }
    return p;
}

private struct RockTextureSet {
    Texture albedo, normal, mr, ao;
    Texture mossAlbedo, mossMr;
    bool hasMoss;

    @disable this(this);

    static RockTextureSet load(ref GpuContext gpu, string prefix, bool loadMoss) {
        RockTextureSet s;
        s.albedo = loadBmpTexture(gpu, prefix ~ "_albedo.bmp");
        s.normal = loadBmpTexture(gpu, prefix ~ "_normal.bmp");
        s.mr     = loadBmpTexture(gpu, prefix ~ "_mr.bmp");
        s.ao     = loadBmpTexture(gpu, prefix ~ "_ao.bmp");
        s.hasMoss = loadMoss;
        if (loadMoss) {
            s.mossAlbedo = loadBmpTexture(gpu, prefix ~ "_moss_albedo.bmp");
            s.mossMr     = loadBmpTexture(gpu, prefix ~ "_moss_mr.bmp");
        }
        return s;
    }

    void destroy() nothrow @nogc {
        albedo.destroy();
        normal.destroy();
        mr.destroy();
        ao.destroy();
        if (hasMoss) {
            mossAlbedo.destroy();
            mossMr.destroy();
        }
    }
}

private struct RockMaterialGroup {
    Material dry, wet, moss, submerged;

    @disable this(this);

    void destroy() nothrow @nogc {
        dry.destroy();
        wet.destroy();
        moss.destroy();
        submerged.destroy();
    }
}

private void writeCaptureBmp(string path, const(ubyte)[] rgba, uint w, uint h) @trusted {
    import std.stdio : File;
    immutable uint rowBytes = (w * 3 + 3) & ~3u;
    immutable uint imgBytes = rowBytes * h;
    immutable uint fileSize = 54 + imgBytes;
    ubyte[54] hdr = 0;
    hdr[0] = 'B'; hdr[1] = 'M';
    hdr[2] = cast(ubyte)(fileSize & 0xFF);
    hdr[3] = cast(ubyte)((fileSize >> 8) & 0xFF);
    hdr[4] = cast(ubyte)((fileSize >> 16) & 0xFF);
    hdr[5] = cast(ubyte)((fileSize >> 24) & 0xFF);
    hdr[10] = 54;
    hdr[14] = 40;
    hdr[18] = cast(ubyte)(w & 0xFF);
    hdr[19] = cast(ubyte)((w >> 8) & 0xFF);
    hdr[20] = cast(ubyte)((w >> 16) & 0xFF);
    hdr[21] = cast(ubyte)((w >> 24) & 0xFF);
    hdr[22] = cast(ubyte)(h & 0xFF);
    hdr[23] = cast(ubyte)((h >> 8) & 0xFF);
    hdr[24] = cast(ubyte)((h >> 16) & 0xFF);
    hdr[25] = cast(ubyte)((h >> 24) & 0xFF);
    hdr[26] = 1;
    hdr[28] = 24;
    hdr[34] = cast(ubyte)(imgBytes & 0xFF);
    hdr[35] = cast(ubyte)((imgBytes >> 8) & 0xFF);
    hdr[36] = cast(ubyte)((imgBytes >> 16) & 0xFF);
    hdr[37] = cast(ubyte)((imgBytes >> 24) & 0xFF);

    auto f = File(path, "wb");
    f.rawWrite(hdr[]);
    auto row = new ubyte[rowBytes];
    foreach_reverse (y; 0 .. h) {
        row[] = 0;
        const size_t srcBase = cast(size_t) y * w * 4;
        foreach (x; 0 .. w) {
            const size_t s = srcBase + cast(size_t) x * 4;
            const size_t d = cast(size_t) x * 3;
            row[d + 0] = rgba[s + 2];
            row[d + 1] = rgba[s + 1];
            row[d + 2] = rgba[s + 0];
        }
        f.rawWrite(row);
    }
}

void main(string[] args) {
    import core.memory : GC;
    import core.time : MonoTime;
    import std.algorithm : sort, startsWith;
    import std.conv : to;
    import std.stdio : writefln;

    uint maxFrames = 0;
    uint benchFrames = 0;
    uint renderStage = 3;
    uint winW = W;
    uint winH = H;
    bool initRiver = false;
    bool initLowSun = true;
    bool initHud = true;
    bool noWater = false;
    bool initImmediate = false;
    bool benchSync = false;
    string capturePath;
    foreach (a; args[1 .. $]) {
        if (a.startsWith("--frames=")) {
            maxFrames = a[9 .. $].to!uint;
        } else if (a.startsWith("--bench=")) {
            benchFrames = a[8 .. $].to!uint;
        } else if (a.startsWith("--stage=")) {
            renderStage = a[8 .. $].to!uint;
        } else if (a == "--river") {
            initRiver = true;
        } else if (a == "--noon") {
            initLowSun = false;
        } else if (a == "--no-hud") {
            initHud = false;
        } else if (a == "--no-water") {
            noWater = true;
        } else if (a == "--immediate") {
            initImmediate = true;
        } else if (a == "--bench-sync") {
            benchSync = true;
        } else if (a == "--1080p") {
            winW = 1920;
            winH = 1080;
        } else if (a.startsWith("--capture=")) {
            capturePath = a[10 .. $];
        }
    }
    enum uint WARMUP_FRAMES = 120;
    if (benchFrames > 0) {
        initImmediate = true;
        initHud = false;
        benchSync = true;
        maxFrames = WARMUP_FRAMES + benchFrames;
    } else if (capturePath.length > 0) {
        initImmediate = true;
        if (maxFrames == 0) maxFrames = 3;
    }
    auto app = App.create(
        "OpenPBR Water Showcase — Ocean & River",
        winW,
        winH,
        initImmediate ? WGPUPresentMode.immediate : WGPUPresentMode.fifo
    );

    auto scene = Scene3DTextured.create(app.gpu);
    scope(exit) scene.destroy();

    auto sphere = TexMesh.sphere(app.gpu, 32, 16);
    scope(exit) sphere.destroy();
    auto cliffRockMesh = loadGltfMesh(app.gpu, "assets/models/rock_cliff.gltf");
    scope(exit) cliffRockMesh.destroy();
    auto boulderRockMesh = loadGltfMesh(app.gpu, "assets/models/rock_boulder.gltf");
    scope(exit) boulderRockMesh.destroy();
    auto cobbleRockMesh = loadGltfMesh(app.gpu, "assets/models/rock_cobble.gltf");
    scope(exit) cobbleRockMesh.destroy();
    auto cube = TexMesh.cube(app.gpu);
    scope(exit) cube.destroy();
    auto bedQuad = buildBedQuad32(app.gpu);
    scope(exit) bedQuad.destroy();
    auto leftBankMesh = buildRiverBankMesh(app.gpu, -1.0f);
    scope(exit) leftBankMesh.destroy();
    auto rightBankMesh = buildRiverBankMesh(app.gpu, 1.0f);
    scope(exit) rightBankMesh.destroy();
    auto waterGrid = buildWaterGridMesh32(app.gpu);
    scope(exit) waterGrid.destroy();

    auto waterPipes = WaterShaderPipelines.create(app.gpu, scene.frameLayout(), scene.iblLayout());
    scope(exit) waterPipes.destroy();

    auto sampler = Sampler.create(app.gpu, TextureFilter.linear, TextureWrap.repeat);
    scope(exit) sampler.destroy();

    auto whiteTex = Texture.solid(app.gpu, 255, 255, 255, 255);
    scope(exit) whiteTex.destroy();

    Texture bankAlbedoTex, bankNormalTex;
    Texture woodAlbedoTex, woodNormalTex, masonryAlbedoTex, masonryNormalTex;
    generateEnvTextures(app.gpu,
                        bankAlbedoTex, bankNormalTex,
                        woodAlbedoTex, woodNormalTex,
                        masonryAlbedoTex, masonryNormalTex);
    scope(exit) {
        bankAlbedoTex.destroy();
        bankNormalTex.destroy();
        woodAlbedoTex.destroy();
        woodNormalTex.destroy();
        masonryAlbedoTex.destroy();
        masonryNormalTex.destroy();
    }

    RockTextureSet[3] rockTexSets = [
        RockTextureSet.load(app.gpu, "assets/models/rock_cliff", true),
        RockTextureSet.load(app.gpu, "assets/models/rock_boulder", true),
        RockTextureSet.load(app.gpu, "assets/models/rock_cobble", false),
    ];
    scope(exit) {
        foreach (ref ts; rockTexSets) ts.destroy();
    }

    auto layout = scene.materialLayout();

    Material makePbrMat(ref Texture albedo, MaterialParams params,
                        scope Texture* mr = null, scope Texture* nrm = null,
                        scope Texture* ao = null) @trusted {
        return Material.create(app.gpu, layout, sampler, albedo, params, mr, nrm, ao, null);
    }

    bool riverMode = initRiver;
    bool lowSun = initLowSun;
    bool useOpenPbr = true;
    int waveLevel = 1; // 0 = calm, 1 = moderate, 2 = stormy
    bool transparent = true;
    bool ssrEnabled = (renderStage >= 3);

    RockMaterialGroup[3] rockMats;
    foreach (i; 0 .. 3) {
        rockMats[i].dry = makePbrMat(
            rockTexSets[i].albedo, buildDryRockParams(),
            &rockTexSets[i].mr, &rockTexSets[i].normal, &rockTexSets[i].ao);
        rockMats[i].wet = makePbrMat(
            rockTexSets[i].albedo, buildWetRockParams(useOpenPbr),
            &rockTexSets[i].mr, &rockTexSets[i].normal, &rockTexSets[i].ao);
        if (rockTexSets[i].hasMoss) {
            rockMats[i].moss = makePbrMat(
                rockTexSets[i].mossAlbedo, buildMossRockParams(useOpenPbr),
                &rockTexSets[i].mossMr, &rockTexSets[i].normal, &rockTexSets[i].ao);
        } else {
            rockMats[i].moss = makePbrMat(
                rockTexSets[i].albedo, buildMossRockParams(useOpenPbr),
                &rockTexSets[i].mr, &rockTexSets[i].normal, &rockTexSets[i].ao);
        }
        rockMats[i].submerged = makePbrMat(
            rockTexSets[i].albedo, buildSubmergedRockParams(useOpenPbr),
            &rockTexSets[i].mr, &rockTexSets[i].normal, &rockTexSets[i].ao);
    }
    scope(exit) {
        foreach (ref mg; rockMats) mg.destroy();
    }

    MaterialParams bankP;
    bankP.baseColor = [1.0f, 1.0f, 1.0f];
    bankP.baseDiffuseRoughness = 0.92f;
    bankP.specularRoughness = 0.86f;
    bankP.flags = MaterialFlags.normal;
    auto bankMat = makePbrMat(bankAlbedoTex, bankP, null, &bankNormalTex);
    scope(exit) bankMat.destroy();

    MaterialParams woodP;
    woodP.baseColor = [1.0f, 1.0f, 1.0f];
    woodP.baseDiffuseRoughness = 0.72f;
    woodP.specularRoughness = 0.62f;
    woodP.coatWeight = 0.20f;
    woodP.coatRoughness = 0.16f;
    woodP.coatIor = 1.333f;
    woodP.coatDarkening = 0.50f;
    woodP.flags = MaterialFlags.normal;
    auto woodMat = makePbrMat(woodAlbedoTex, woodP, null, &woodNormalTex);
    scope(exit) woodMat.destroy();

    MaterialParams masonryP;
    masonryP.baseColor = [1.0f, 1.0f, 1.0f];
    masonryP.baseDiffuseRoughness = 0.85f;
    masonryP.specularRoughness = 0.78f;
    masonryP.flags = MaterialFlags.normal;
    auto masonryMat = makePbrMat(masonryAlbedoTex, masonryP, null, &masonryNormalTex);
    scope(exit) masonryMat.destroy();

    // Wooden bridge / lighthouse trim & metallic buoys
    MaterialParams goldBuoyP;
    goldBuoyP.baseColor = [0.98f, 0.78f, 0.36f];
    goldBuoyP.specularColor = [1.0f, 0.70f, 0.32f];
    goldBuoyP.baseMetalness = 1.0f;
    goldBuoyP.specularRoughness = 0.18f;
    goldBuoyP.coatWeight = 0.45f;
    goldBuoyP.coatRoughness = 0.04f;
    auto goldBuoyMat = Material.create(
        app.gpu, layout, sampler, whiteTex, goldBuoyP, null, null, null, null);
    scope(exit) goldBuoyMat.destroy();

    MaterialParams filmBuoyP;
    filmBuoyP.baseColor = [0.14f, 0.16f, 0.22f];
    filmBuoyP.baseMetalness = 0.85f;
    filmBuoyP.specularRoughness = 0.12f;
    filmBuoyP.thinFilmWeight = 0.95f;
    filmBuoyP.thinFilmThickness = 470.0f;
    filmBuoyP.thinFilmIor = 1.52f;
    auto filmBuoyMat = Material.create(
        app.gpu, layout, sampler, whiteTex, filmBuoyP, null, null, null, null);
    scope(exit) filmBuoyMat.destroy();

    MaterialParams lighthouseP;
    lighthouseP.baseColor = [0.92f, 0.91f, 0.88f];
    lighthouseP.baseDiffuseRoughness = 0.55f;
    lighthouseP.specularRoughness = 0.52f;
    auto lighthouseMat = Material.create(
        app.gpu, layout, sampler, whiteTex, lighthouseP, null, null, null, null);
    scope(exit) lighthouseMat.destroy();

    MaterialParams beaconP;
    beaconP.baseColor = [1.0f, 0.88f, 0.55f];
    beaconP.emissionColor = [1.0f, 0.76f, 0.32f];
    beaconP.emissionLuminance = 5.5f;
    auto beaconMat = Material.create(
        app.gpu, layout, sampler, whiteTex, beaconP, null, null, null, null);
    scope(exit) beaconMat.destroy();

    // Shadows (Directional + Lighthouse/Bridge Spot)
    auto shadowPipe = createShadowPipeline(app.gpu.getDevice());
    scope(exit) shadowPipe.release();
    auto lightBuf = createUniformBuffer(app.gpu.getDevice(), 64);
    scope(exit) destroyBuffer(lightBuf);
    auto lightBg = createUniformBindGroup(app.gpu.getDevice(), shadowPipe.bindGroupLayout, lightBuf, 64);
    scope(exit) releaseBindGroup(lightBg);
    auto shadowInstanceBuf = createDynamicVertexBuffer(app.gpu.getDevice(), 64 * InstanceData.sizeof);
    scope(exit) destroyBuffer(shadowInstanceBuf);

    auto dirShadow = ShadowMap.create(app.gpu, 2048);
    scope(exit) dirShadow.destroy();
    auto spotShadow = SpotShadowMap.create(app.gpu, SPOT_SHADOW_RESOLUTION);
    scope(exit) spotShadow.destroy();

    auto camera = Camera.create(0.85f, cast(int) winW, cast(int) winH, 0.1f, 260.0f);
    auto orbit = OrbitState();
    auto text = TextRenderer.create(app.gpu, winW, winH);
    scope(exit) text.destroy();
    auto fps = FpsCounter.create();
    bool showHud = initHud;

    info("OpenPBR Water Showcase — [1] Ocean [2] River [3] Sun [4] OpenPBR A/B [5] Waves [6] Opacity [7] SSR [F1] HUD");

    double[] benchSamples;
    if (benchFrames > 0) {
        benchSamples = new double[benchFrames];
    }
    size_t gcStartBytes = 0;
    size_t gcEndBytes = 0;

    float time = capturePath.length > 0 ? 1.8f : 0.0f;
    float wetMemoryScale = 1.0f;
    uint frameNum = 0;
    while (app.running()) {
        if (maxFrames > 0 && frameNum >= maxFrames) break;
        immutable bool isMeasuredFrame = benchFrames > 0 && frameNum >= WARMUP_FRAMES;
        immutable uint sampleIdx = frameNum >= WARMUP_FRAMES ? frameNum - WARMUP_FRAMES : 0;
        if (benchFrames > 0 && frameNum == WARMUP_FRAMES) {
            gcStartBytes = GC.stats().usedSize;
        }
        frameNum++;
        immutable bool captureThisFrame = capturePath.length > 0 && frameNum == maxFrames;
        immutable auto frameStartT = MonoTime.currTime;
        app.pollEvents();
        immutable float realDt = fps.tick();
        immutable float dt = benchFrames > 0 ? (1.0f / 60.0f) : realDt;
        time += dt;
        if (app.input.keyPressed(Key.escape)) break;

        bool paramsDirty = false;
        if (app.input.keyPressed(Key.digit1)) { riverMode = false; paramsDirty = true; }
        if (app.input.keyPressed(Key.digit2)) { riverMode = true;  paramsDirty = true; }
        if (app.input.keyPressed(Key.digit3)) { lowSun = !lowSun; }
        if (app.input.keyPressed(Key.digit4)) { useOpenPbr = !useOpenPbr; paramsDirty = true; }
        if (app.input.keyPressed(Key.digit5)) { waveLevel = (waveLevel + 1) % 3; }
        if (app.input.keyPressed(Key.digit6)) { transparent = !transparent; paramsDirty = true; }
        if (app.input.keyPressed(Key.digit7)) { ssrEnabled = !ssrEnabled; }
        if (app.input.keyPressed(Key.f1))     { showHud = !showHud; }
        if (app.input.keyPressed(Key.b))      { app.post.bloom = !app.post.bloom; }
        if (app.input.keyPressed(Key.f))      { app.post.fxaa = !app.post.fxaa; }
        if (app.input.keyPressed(Key.g))      { app.post.tonemapMode = 1 - app.post.tonemapMode; }
        if (app.input.keyPressed(Key.r))      { orbit = OrbitState(); }
        if (app.input.keyPressed(Key.equals) || app.input.keyPressed(Key.kpPlus))
            app.post.exposure += 0.1f;
        if (app.input.keyPressed(Key.minus) || app.input.keyPressed(Key.kpMinus)) {
            app.post.exposure -= 0.1f;
            if (app.post.exposure < 0.1f) app.post.exposure = 0.1f;
        }

        immutable float waveScale = waveLevel == 0 ? 0.35f : (waveLevel == 1 ? 1.0f : 1.75f);
        if (waveScale >= wetMemoryScale) {
            wetMemoryScale = waveScale;
        } else {
            wetMemoryScale -= dt * 0.28f;
            if (wetMemoryScale < waveScale) wetMemoryScale = waveScale;
        }
        immutable bool propWaterFx = !noWater && renderStage >= 3;

        if (paramsDirty || propWaterFx) {
            immutable uint waterFlagBits = propWaterFx
                ? (MaterialFlags.waterWetCaustics | (riverMode ? MaterialFlags.waterRiverMode : 0u))
                : 0u;
            immutable float memFrac = wetMemoryScale * 0.25f;
            immutable float clampedMem = memFrac < 0.001f ? 0.001f : (memFrac > 0.999f ? 0.999f : memFrac);
            immutable float packedPad1 = floor(waveScale * 1000.0f + 0.5f) + clampedMem;
            void applyWaterFx(ref MaterialParams p) {
                p.flags |= waterFlagBits;
                if (propWaterFx) {
                    p._pad0 = time;
                    p._pad1 = packedPad1;
                }
            }
            auto dryP  = buildDryRockParams();
            auto wetP  = buildWetRockParams(useOpenPbr);
            auto mossP = buildMossRockParams(useOpenPbr);
            auto subP  = buildSubmergedRockParams(useOpenPbr);
            applyWaterFx(dryP);
            applyWaterFx(wetP);
            applyWaterFx(mossP);
            applyWaterFx(subP);
            foreach (ref mg; rockMats) {
                mg.dry.updateParams(app.gpu, dryP);
                mg.wet.updateParams(app.gpu, wetP);
                mg.moss.updateParams(app.gpu, mossP);
                mg.submerged.updateParams(app.gpu, subP);
            }
            auto curWoodP = woodP;
            auto curMasP = masonryP;
            auto curBankP = bankP;
            if (propWaterFx) {
                curBankP.coatWeight = 0.72f;
                curBankP.coatRoughness = 0.10f;
                curBankP.coatIor = 1.333f;
                curBankP.coatDarkening = 0.55f;
            }
            applyWaterFx(curWoodP);
            applyWaterFx(curMasP);
            applyWaterFx(curBankP);
            woodMat.updateParams(app.gpu, curWoodP);
            masonryMat.updateParams(app.gpu, curMasP);
            bankMat.updateParams(app.gpu, curBankP);
        }

        orbit.update(app.input, dt, camera);

        immutable Vec3 sunDir = lowSun
            ? Vec3(-0.78f, 0.24f, -0.58f).normalized()
            : Vec3(0.38f, 0.88f, 0.29f).normalized();
        immutable Vec3 sunCol = lowSun
            ? Vec3(1.0f, 0.72f, 0.44f)
            : Vec3(1.0f, 0.98f, 0.94f);
        immutable float sunIntensity = lowSun ? 3.8f : 3.2f;

        immutable spotPos = riverMode ? Vec3(-0.7f, 2.30f, -5.6f) : Vec3(-11.2f, 6.8f, -6.2f);
        immutable spotTarget = riverMode ? Vec3(0.4f, -0.2f, 1.0f) : Vec3(0.0f, 0.0f, 0.0f);
        immutable spotDir = (spotTarget - spotPos).normalized();
        immutable lightVP = directionalLightVP(sunDir, Vec3(0, 0, 0), 20.0f);
        immutable spotVP = spotLightVPFromCone(spotPos, spotDir, 45.0f, 0.2f, 28.0f);

        // Compute floating buoy transforms from wave height + surface normal (ocean mode)
        immutable float[2][3] buoyXZ = [
            [-2.2f, -1.5f],
            [ 3.4f,  1.8f],
            [ 0.5f,  4.2f],
        ];
        Mat4[3] buoyModels;
        if (!riverMode) {
            foreach (i, xz; buoyXZ) {
                immutable w = sampleGerstner(xz[0], xz[1], time, riverMode, waveScale);
                immutable pitchX = -w.normal.z * 0.55f;
                immutable rollZ  =  w.normal.x * 0.55f;
                buoyModels[i] = Mat4.translation(w.position.x, w.position.y + 0.10f, w.position.z)
                              * Mat4.rotationZ(rollZ)
                              * Mat4.rotationX(pitchX)
                              * Mat4.scaling(0.85f, 0.85f, 0.85f);
            }
        }

        // Gather shadow casters (rocks by mesh kind + buoys + bridge/lighthouse)
        const rocks = riverMode ? RIVER_ROCKS : SEA_ROCKS;
        InstanceData[48] cliffCasters;
        InstanceData[48] boulderCasters;
        InstanceData[48] cobbleCasters;
        uint cliffCount = 0;
        uint boulderCount = 0;
        uint cobbleCount = 0;
        foreach (ref rk; rocks) {
            if (rk.kind == 3) continue; // submerged pebbles don't cast overhead shadows
            immutable inst = InstanceData(
                (Mat4.translation(rk.pos.x, rk.pos.y, rk.pos.z)
                 * Mat4.rotationY(rk.rotY)
                 * Mat4.scaling(rk.scale.x, rk.scale.y, rk.scale.z)).m,
                Color4.white.toArray());
            if (rk.meshKind == 0)
                cliffCasters[cliffCount++] = inst;
            else if (rk.meshKind == 1)
                boulderCasters[boulderCount++] = inst;
            else
                cobbleCasters[cobbleCount++] = inst;
        }
        InstanceData[8] structureCasters;
        uint sCount = 0;
        if (riverMode) {
            // Wooden footbridge, piers, stone abutments, and lantern post
            structureCasters[sCount++] = InstanceData(
                (Mat4.translation(-1.5f, 1.35f, 0.0f) * Mat4.scaling(1.8f, 0.28f, 16.2f)).m,
                Color4.white.toArray());
            structureCasters[sCount++] = InstanceData(
                (Mat4.translation(-1.5f, 0.10f, -4.6f) * Mat4.scaling(0.55f, 2.6f, 0.55f)).m,
                Color4.white.toArray());
            structureCasters[sCount++] = InstanceData(
                (Mat4.translation(-1.5f, 0.10f,  4.6f) * Mat4.scaling(0.55f, 2.6f, 0.55f)).m,
                Color4.white.toArray());
            structureCasters[sCount++] = InstanceData(
                (Mat4.translation(-1.5f, 0.65f, -7.8f) * Mat4.scaling(2.3f, 1.25f, 1.8f)).m,
                Color4.white.toArray());
            structureCasters[sCount++] = InstanceData(
                (Mat4.translation(-1.5f, 0.65f,  7.8f) * Mat4.scaling(2.3f, 1.25f, 1.8f)).m,
                Color4.white.toArray());
            structureCasters[sCount++] = InstanceData(
                (Mat4.translation(-0.7f, 1.75f, -5.6f) * Mat4.scaling(0.16f, 0.65f, 0.16f)).m,
                Color4.white.toArray());
        } else {
            // Coastal headland lighthouse tower
            structureCasters[sCount++] = InstanceData(
                (Mat4.translation(-11.4f, 3.6f, -6.4f) * Mat4.scaling(1.4f, 5.2f, 1.4f)).m,
                Color4.white.toArray());
        }

        InstanceData[3] buoyCasters;
        if (!riverMode) {
            foreach (i; 0 .. 3)
                buoyCasters[i] = InstanceData(buoyModels[i].m, Color4.white.toArray());
        }

        // Directional shadow pass
        bool firstDirShadow = true;
        if (cliffCount > 0) {
            updateBuffer(app.gpu.getQueue(), shadowInstanceBuf, cliffCasters[0 .. cliffCount]);
            submitShadowPass(app.gpu, dirShadow, shadowPipe, lightBg, lightBuf, lightVP,
                             cliffRockMesh, shadowInstanceBuf, cliffCount, firstDirShadow);
            firstDirShadow = false;
        }
        if (boulderCount > 0) {
            updateBuffer(app.gpu.getQueue(), shadowInstanceBuf, boulderCasters[0 .. boulderCount]);
            submitShadowPass(app.gpu, dirShadow, shadowPipe, lightBg, lightBuf, lightVP,
                             boulderRockMesh, shadowInstanceBuf, boulderCount, firstDirShadow);
            firstDirShadow = false;
        }
        if (cobbleCount > 0) {
            updateBuffer(app.gpu.getQueue(), shadowInstanceBuf, cobbleCasters[0 .. cobbleCount]);
            submitShadowPass(app.gpu, dirShadow, shadowPipe, lightBg, lightBuf, lightVP,
                             cobbleRockMesh, shadowInstanceBuf, cobbleCount, firstDirShadow);
            firstDirShadow = false;
        }
        updateBuffer(app.gpu.getQueue(), shadowInstanceBuf, structureCasters[0 .. sCount]);
        submitShadowPass(app.gpu, dirShadow, shadowPipe, lightBg, lightBuf, lightVP,
                         cube, shadowInstanceBuf, sCount, firstDirShadow);
        if (!riverMode) {
            updateBuffer(app.gpu.getQueue(), shadowInstanceBuf, buoyCasters[]);
            submitShadowPass(app.gpu, dirShadow, shadowPipe, lightBg, lightBuf, lightVP,
                             sphere, shadowInstanceBuf, 3, false);
        }

        // Spot shadow pass
        bool firstSpotShadow = true;
        if (cliffCount > 0) {
            updateBuffer(app.gpu.getQueue(), shadowInstanceBuf, cliffCasters[0 .. cliffCount]);
            submitSpotShadowPass(app.gpu, spotShadow, shadowPipe, lightBg, lightBuf, spotVP,
                                 cliffRockMesh, shadowInstanceBuf, cliffCount, firstSpotShadow);
            firstSpotShadow = false;
        }
        if (boulderCount > 0) {
            updateBuffer(app.gpu.getQueue(), shadowInstanceBuf, boulderCasters[0 .. boulderCount]);
            submitSpotShadowPass(app.gpu, spotShadow, shadowPipe, lightBg, lightBuf, spotVP,
                                 boulderRockMesh, shadowInstanceBuf, boulderCount, firstSpotShadow);
            firstSpotShadow = false;
        }
        if (cobbleCount > 0) {
            updateBuffer(app.gpu.getQueue(), shadowInstanceBuf, cobbleCasters[0 .. cobbleCount]);
            submitSpotShadowPass(app.gpu, spotShadow, shadowPipe, lightBg, lightBuf, spotVP,
                                 cobbleRockMesh, shadowInstanceBuf, cobbleCount, firstSpotShadow);
            firstSpotShadow = false;
        }
        updateBuffer(app.gpu.getQueue(), shadowInstanceBuf, structureCasters[0 .. sCount]);
        submitSpotShadowPass(app.gpu, spotShadow, shadowPipe, lightBg, lightBuf, spotVP,
                             cube, shadowInstanceBuf, sCount, firstSpotShadow);

        LightSet lights;
        lights.dirEnabled = true;
        lights.dir.direction = sunDir;
        lights.dir.viewProj = lightVP;
        lights.dir.color = sunCol;
        lights.dir.intensity = sunIntensity;
        lights.dir.castShadows = true;

        lights.spots[0] = GpuSpotLight(
            spotPos, spotDir, Vec3(1.0f, 0.88f, 0.64f), 26.0f, 36.0f,
            18.0f, 44.0f, spotVP, true);
        lights.spotCount = 1;
        lights.shadowBias = 0.0005f;

        PointShadowMap*[MAX_POINT_SHADOW_CASTERS] pointMaps;
        SpotShadowMap*[MAX_SPOT_SHADOW_CASTERS] spotMaps;
        spotMaps[0] = &spotShadow;
        scene.setLights(lights, &dirShadow, pointMaps, spotMaps);

        // Pre-frame water UBO upload + WTR-6 compute simulation pass (JONSWAP + ping-pong advected foam)
        immutable bool enableRefraction = !noWater && renderStage >= 2;
        immutable bool enableSsr        = !noWater && renderStage >= 3 && ssrEnabled;
        auto wu = packWaterUniforms(
            camera, time, waveScale, riverMode, useOpenPbr, transparent, lowSun,
            enableRefraction, enableSsr, rocks[]);
        () @trusted {
            updateBuffer(app.gpu.getQueue(), waterPipes.ubo, &wu, WaterUniforms.sizeof);
        }();
        if (!noWater && renderStage >= 3) {
            waterPipes.stepSimulation(app.gpu);
        }

        immutable bgCol = lowSun
            ? Color4(0.16f, 0.12f, 0.11f, 1.0f)
            : Color4(0.24f, 0.38f, 0.56f, 1.0f);
        auto frame = app.beginFrame(bgCol);
        if (!frame.valid) continue;

        scene.begin(camera);

        // 1. Opaque geometry FIRST (rocks, riverbanks, bridge/lighthouse, buoys)
        void drawRock(ref const RockPlacement rk, ref const Mat4 model) {
            immutable size_t mi = rk.meshKind < 3 ? rk.meshKind : 1;
            void submit(ref Material mat) {
                if (mi == 0)      scene.drawMatrix(cliffRockMesh, mat, model, Color4.white);
                else if (mi == 1) scene.drawMatrix(boulderRockMesh, mat, model, Color4.white);
                else              scene.drawMatrix(cobbleRockMesh, mat, model, Color4.white);
            }
            if (rk.kind == 0)      submit(rockMats[mi].dry);
            else if (rk.kind == 1) submit(rockMats[mi].wet);
            else if (rk.kind == 2) submit(rockMats[mi].moss);
            else                   submit(rockMats[mi].submerged);
        }

        foreach (ref rk; rocks) {
            auto model = Mat4.translation(rk.pos.x, rk.pos.y, rk.pos.z)
                       * Mat4.rotationY(rk.rotY)
                       * Mat4.scaling(rk.scale.x, rk.scale.y, rk.scale.z);
            drawRock(rk, model);
        }

        if (riverMode) {
            scene.draw(leftBankMesh, bankMat, Vec3(0.0f, 0.0f, 0.0f), Vec3(1.0f, 1.0f, 1.0f), Color4.white);
            scene.draw(rightBankMesh, bankMat, Vec3(0.0f, 0.0f, 0.0f), Vec3(1.0f, 1.0f, 1.0f), Color4.white);
            scene.draw(cube, woodMat, Vec3(-1.5f, 1.35f,  0.0f), Vec3(1.8f, 0.28f, 16.2f), Color4.white);
            scene.draw(cube, woodMat, Vec3(-1.5f, 0.10f, -4.6f), Vec3(0.55f, 2.6f, 0.55f), Color4(0.85f, 0.80f, 0.76f, 1.0f));
            scene.draw(cube, woodMat, Vec3(-1.5f, 0.10f,  4.6f), Vec3(0.55f, 2.6f, 0.55f), Color4(0.85f, 0.80f, 0.76f, 1.0f));
            scene.draw(cube, masonryMat, Vec3(-1.5f, 0.65f, -7.8f), Vec3(2.3f, 1.25f, 1.8f), Color4.white);
            scene.draw(cube, masonryMat, Vec3(-1.5f, 0.65f,  7.8f), Vec3(2.3f, 1.25f, 1.8f), Color4.white);
            scene.draw(cube, woodMat, Vec3(-0.7f, 1.75f, -5.6f), Vec3(0.16f, 0.65f, 0.16f), Color4(0.80f, 0.75f, 0.70f, 1.0f));
            scene.draw(sphere, beaconMat, Vec3(-0.7f, 2.10f, -5.6f), Vec3(0.24f, 0.24f, 0.24f), Color4.white);
        } else {
            scene.draw(cube, lighthouseMat, Vec3(-11.4f, 3.6f, -6.4f), Vec3(1.4f, 5.2f, 1.4f), Color4.white);
            scene.draw(sphere, beaconMat, Vec3(-11.4f, 6.5f, -6.4f), Vec3(0.75f, 0.75f, 0.75f), Color4.white);
            scene.drawMatrix(sphere, goldBuoyMat, buoyModels[0], Color4.white);
            scene.drawMatrix(sphere, filmBuoyMat, buoyModels[1], Color4.white);
            scene.drawMatrix(sphere, goldBuoyMat, buoyModels[2], Color4.white);
        }

        scene.end(frame);

        // 2. Water environment draws in the HDR frame pass:
        //    (a) sky dome behind geometry, (b) riverbed with caustics,
        //    (c) optional Renderer.snapshotOpaque + optical water surface
        frame.setBindGroup(0, scene.frameGroup());
        frame.setBindGroup(1, waterPipes.waterBg);

        frame.setPipeline(waterPipes.skyPipe);
        drawNonIndexed(frame, 3);

        frame.setBindGroup(2, scene.iblGroup());
        frame.setPipeline(waterPipes.bedPipe);
        frame.setVertexBuffer(0, bedQuad.vbuf, bedQuad.vSize);
        frame.setIndexBuffer(bedQuad.ibuf, WGPUIndexFormat.uint16, bedQuad.iSize);
        frame.drawIndexed(bedQuad.indexCount, 1);

        if (!noWater) {
            if (renderStage >= 1) {
                app.renderer.snapshotOpaque(frame);
                waterPipes.updateSurfaceBindGroup(
                    app.gpu.getDevice(),
                    app.renderer.opaqueColorView(),
                    app.renderer.opaqueDepthView()
                );
            } else {
                waterPipes.updateSurfaceBindGroup(
                    app.gpu.getDevice(),
                    waterPipes.dummyColorView,
                    dirShadow.depthView
                );
            }
            frame.setBindGroup(0, scene.frameGroup());
            frame.setBindGroup(1, waterPipes.waterSurfaceBg[waterPipes.simPingPong]);
            frame.setBindGroup(2, scene.iblGroup());
            frame.setPipeline(waterPipes.waterPipe);
            frame.setVertexBuffer(0, waterGrid.vbuf, waterGrid.vSize);
            frame.setIndexBuffer(waterGrid.ibuf, WGPUIndexFormat.uint16, waterGrid.iSize);
            frame.drawIndexed(waterGrid.indexCount, 1);
        }

        app.resolvePost(frame);
        if (!frame.valid) continue;

        if (benchFrames == 0) {
            text.beginFrame();
            if (showHud) {
                immutable waveName = waveLevel == 0 ? "Calm" : (waveLevel == 1 ? "Moderate" : "Stormy");
                immutable sceneName = riverMode ? "Mountain River (Stream)" : "Open Ocean (Beaufort 5)";
                immutable sunName = lowSun ? "Golden Hour" : "High Noon";
                immutable shadingName = useOpenPbr
                    ? "Shading: OpenPBR v1.1 (Coat + Aniso + Fuzz + IOR 1.333)"
                    : "Shading: Legacy PBR Baseline (No Coat/Fuzz, IOR 1.5)";
                immutable waterAlphaName = transparent ? "Refractive Optical" : "Opaque (1.0)";
                immutable ssrName = enableSsr ? "SSR=ON" : "SSR=OFF";
                immutable tmName = app.post.tonemapMode == 0 ? "ACES" : "Reinhard";

                text.drawText(frame, app.arena.fmt("OPENPBR WATER SHOWCASE  |  %s", fps.text()), 16, 14, 2);
                text.drawText(frame, app.arena.fmt("Scene: %s  |  Sun: %s", sceneName, sunName), 16, 34, 2);
                text.drawText(frame, shadingName, 16, 54, 2);
                text.drawText(frame, app.arena.fmt("Waves: %s  |  Surface: %s  |  %s", waveName, waterAlphaName, ssrName), 16, 74, 2);
                text.drawText(frame, app.arena.fmt("Post: Bloom=%s  FXAA=%s  TM=%s  Exp=%.2f",
                              app.post.bloom ? "ON" : "OFF",
                              app.post.fxaa ? "ON" : "OFF",
                              tmName, app.post.exposure), 16, 94, 2);

                text.drawText(frame, "[CONTROLS]", 16, 124, 2);
                text.drawText(frame, "[1] Ocean Swell            [2] Mountain River", 16, 144, 2);
                text.drawText(frame, "[3] Toggle Sun Angle       [4] OpenPBR vs Legacy", 16, 164, 2);
                text.drawText(frame, "[5] Wave State (C/M/S)     [6] Water Alpha/Opaque   [7] Toggle SSR", 16, 184, 2);
                text.drawText(frame, "[B] Bloom    [F] FXAA      [G] Tonemap   [+/-] Exposure", 16, 204, 2);
                text.drawText(frame, "[Drag/Arrows] Orbit        [W/S/Wheel] Zoom  [R] Reset", 16, 224, 2);
                text.drawText(frame, "[F1] Hide HUD              [ESC] Quit", 16, 244, 2);
            } else {
                text.drawText(frame, "[F1] Show Controls HUD", 16, 14, 2);
            }
        }

        if (captureThisFrame) {
            app.renderer.requestCapture();
        }
        app.endFrame(frame);
        if (benchSync) {
            () @trusted {
                wgpuDevicePoll(app.gpu.getDevice(), WGPU_TRUE, null);
            }();
        }
        if (isMeasuredFrame && sampleIdx < benchSamples.length) {
            immutable auto elapsed = MonoTime.currTime - frameStartT;
            benchSamples[sampleIdx] = elapsed.total!"hnsecs" / 10_000.0;
        }
        if (benchFrames > 0 && frameNum == maxFrames) {
            gcEndBytes = GC.stats().usedSize;
        }
        if (captureThisFrame) {
            uint cw, ch;
            auto px = app.renderer.readCapture(cw, ch);
            if (px.length > 0) {
                writeCaptureBmp(capturePath, px, cw, ch);
            }
        }
    }

    if (benchFrames > 0 && benchSamples.length > 0) {
        sort(benchSamples);
        double sum = 0.0;
        foreach (s; benchSamples) sum += s;
        immutable double avgMs = sum / cast(double) benchSamples.length;
        immutable double p50Ms = benchSamples[(benchSamples.length * 50) / 100];
        immutable double p95Ms = benchSamples[(benchSamples.length * 95) / 100];
        immutable double p99Ms = benchSamples[(benchSamples.length * 99) / 100];
        immutable double maxMs = benchSamples[$ - 1];
        immutable double fpsMean = avgMs > 0.0 ? (1000.0 / avgMs) : 0.0;
        immutable long gcDelta = cast(long) gcEndBytes - cast(long) gcStartBytes;
        immutable string scenName = noWater ? "No-Water" : (riverMode ? "River" : "Ocean");
        writefln("BENCH_RESULT scenario=%s res=%ux%u avg_ms=%.3f p50_ms=%.3f p95_ms=%.3f p99_ms=%.3f max_ms=%.3f fps=%.1f gc_delta_bytes=%d",
                 scenName, winW, winH, avgMs, p50Ms, p95Ms, p99Ms, maxMs, fpsMean, gcDelta);
    }

    app.destroy();
}
