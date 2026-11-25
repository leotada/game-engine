/// Render pipeline creation helpers for 3D instanced and 2D text pipelines.
module engine.gpu.pipeline;

import bindings.wgpu;
import engine.gpu.shader;
import engine.gpu.shaders;
import engine.core.log;
import engine.water.gpu_data : WATER_DATA_SIZE;

@safe:

private immutable string kTextured3dWgsl = textured3dShaderSource;
private immutable string kTextured3dTangentWgsl = textured3dTangentShaderSource;
private immutable string kTextured3dSkinnedWgsl = textured3dSkinnedShaderSource;

struct Pipeline3D {
    WGPURenderPipeline  pipeline;
    /// Primary layout: colored/cube = group0; textured = material group1.
    WGPUBindGroupLayout bindGroupLayout;
    /// Textured pipeline only: frame+shadow @group(0). Null for colored pipelines.
    WGPUBindGroupLayout frameBindGroupLayout;
    /// Textured pipeline only: IBL @group(2). Null for colored pipelines.
    WGPUBindGroupLayout iblBindGroupLayout;
    /// Skinned PBR pipeline only: joint palette storage buffer @group(3).
    WGPUBindGroupLayout skinBindGroupLayout;
    WGPUPipelineLayout  pipelineLayout;
    WGPUPipelineLayout  skinnedPipelineLayout;
    WGPUShaderModule    shaderModule;
    /// Stride-48 PBR pipeline (`TexTanVert`). Null on colored pipelines.
    WGPURenderPipeline  pipelineTangent;
    WGPUShaderModule    shaderModuleTangent;
    /// Stride-80 skinned PBR pipeline (`SkinnedVertex`). Null on non-PBR pipelines.
    WGPURenderPipeline  pipelineSkinned;
    WGPUShaderModule    shaderModuleSkinned;

    @disable this(this);

    void release() nothrow @nogc @trusted {
        if (pipelineSkinned !is null)       { wgpuRenderPipelineRelease(pipelineSkinned); pipelineSkinned = null; }
        if (shaderModuleSkinned !is null)   { wgpuShaderModuleRelease(shaderModuleSkinned); shaderModuleSkinned = null; }
        if (skinnedPipelineLayout !is null) { wgpuPipelineLayoutRelease(skinnedPipelineLayout); skinnedPipelineLayout = null; }
        if (skinBindGroupLayout !is null)   { wgpuBindGroupLayoutRelease(skinBindGroupLayout); skinBindGroupLayout = null; }
        if (pipelineTangent !is null) { wgpuRenderPipelineRelease(pipelineTangent); pipelineTangent = null; }
        if (shaderModuleTangent !is null) { wgpuShaderModuleRelease(shaderModuleTangent); shaderModuleTangent = null; }
        if (pipeline !is null)        { wgpuRenderPipelineRelease(pipeline); pipeline = null; }
        if (pipelineLayout !is null)  { wgpuPipelineLayoutRelease(pipelineLayout); pipelineLayout = null; }
        if (bindGroupLayout !is null) { wgpuBindGroupLayoutRelease(bindGroupLayout); bindGroupLayout = null; }
        if (frameBindGroupLayout !is null) {
            wgpuBindGroupLayoutRelease(frameBindGroupLayout);
            frameBindGroupLayout = null;
        }
        if (iblBindGroupLayout !is null) {
            wgpuBindGroupLayoutRelease(iblBindGroupLayout);
            iblBindGroupLayout = null;
        }
        if (shaderModule !is null)    { wgpuShaderModuleRelease(shaderModule); shaderModule = null; }
    }
}

/// Create the 3D instanced render pipeline.
/// Vertex layout:
///   Buffer 0 (per-vertex): position(float32x3) + normal(float32x3), stride=24
///   Buffer 1 (per-instance): model matrix as 4× float32x4, stride=64
/// Bind group 0, binding 0: uniform buffer (VP matrix, 64 bytes)
Pipeline3D createPipeline3D(WGPUDevice device, WGPUTextureFormat surfaceFormat) @trusted {
    Pipeline3D result;

    // Shader
    result.shaderModule = createShaderModule(device, cube3dShaderSource);
    if (result.shaderModule is null) {
        fatal("Failed to create 3D shader module");
    }

    // Bind group layout: 1 uniform buffer at binding 0
    WGPUBindGroupLayoutEntry bglEntry;
    bglEntry.binding = 0;
    bglEntry.visibility = WGPUShaderStage.vertex;
    bglEntry.buffer.type = WGPUBufferBindingType.uniform;
    bglEntry.buffer.minBindingSize = 64; // Mat4 = 16 floats × 4 bytes

    WGPUBindGroupLayoutDescriptor bglDesc;
    bglDesc.entryCount = 1;
    bglDesc.entries = &bglEntry;
    result.bindGroupLayout = wgpuDeviceCreateBindGroupLayout(device, &bglDesc);

    // Pipeline layout
    WGPUPipelineLayoutDescriptor plDesc;
    plDesc.bindGroupLayoutCount = 1;
    plDesc.bindGroupLayouts = &result.bindGroupLayout;
    result.pipelineLayout = wgpuDeviceCreatePipelineLayout(device, &plDesc);

    // Vertex attributes — buffer 0: position + normal
    WGPUVertexAttribute[2] vertexAttrs = [
        { format: WGPUVertexFormat.float32x3, offset: 0,  shaderLocation: 0 },  // position
        { format: WGPUVertexFormat.float32x3, offset: 12, shaderLocation: 1 },  // normal
    ];

    // Vertex attributes — buffer 1: instance model matrix (4 columns)
    WGPUVertexAttribute[4] instanceAttrs = [
        { format: WGPUVertexFormat.float32x4, offset: 0,  shaderLocation: 2 },
        { format: WGPUVertexFormat.float32x4, offset: 16, shaderLocation: 3 },
        { format: WGPUVertexFormat.float32x4, offset: 32, shaderLocation: 4 },
        { format: WGPUVertexFormat.float32x4, offset: 48, shaderLocation: 5 },
    ];

    WGPUVertexBufferLayout[2] bufferLayouts = [
        {
            arrayStride: 24,
            stepMode: WGPUVertexStepMode.vertex,
            attributeCount: 2,
            attributes: vertexAttrs.ptr,
        },
        {
            arrayStride: 64,
            stepMode: WGPUVertexStepMode.instance_,
            attributeCount: 4,
            attributes: instanceAttrs.ptr,
        },
    ];

    // Fragment state
    WGPUBlendState blendState;
    blendState.color.operation = WGPUBlendOperation.add;
    blendState.color.srcFactor = WGPUBlendFactor.srcAlpha;
    blendState.color.dstFactor = WGPUBlendFactor.oneMinusSrcAlpha;
    blendState.alpha.operation = WGPUBlendOperation.add;
    blendState.alpha.srcFactor = WGPUBlendFactor.one;
    blendState.alpha.dstFactor = WGPUBlendFactor.oneMinusSrcAlpha;

    WGPUColorTargetState colorTarget;
    colorTarget.format = surfaceFormat;
    colorTarget.blend = &blendState;
    colorTarget.writeMask = WGPUColorWriteMask.all;

    WGPUFragmentState fragState;
    fragState.module_ = result.shaderModule;
    fragState.entryPoint = wgpuStringView("fs_main");
    fragState.targetCount = 1;
    fragState.targets = &colorTarget;

    // Depth stencil
    WGPUDepthStencilState depthState;
    depthState.format = WGPUTextureFormat.depth24Plus;
    depthState.depthWriteEnabled = WGPUOptionalBool.true_;
    depthState.depthCompare = WGPUCompareFunction.less;

    // Render pipeline
    WGPURenderPipelineDescriptor pipeDesc;
    pipeDesc.layout = result.pipelineLayout;
    pipeDesc.vertex.module_ = result.shaderModule;
    pipeDesc.vertex.entryPoint = wgpuStringView("vs_main");
    pipeDesc.vertex.bufferCount = 2;
    pipeDesc.vertex.buffers = bufferLayouts.ptr;
    pipeDesc.primitive.topology = WGPUPrimitiveTopology.triangleList;
    pipeDesc.primitive.frontFace = WGPUFrontFace.ccw;
    pipeDesc.primitive.cullMode = WGPUCullMode.back;
    pipeDesc.depthStencil = &depthState;
    pipeDesc.fragment = &fragState;

    result.pipeline = wgpuDeviceCreateRenderPipeline(device, &pipeDesc);
    if (result.pipeline is null) {
        fatal("Failed to create 3D render pipeline");
    }

    info("3D render pipeline created");
    return result;
}

/// Create the 3D instanced render pipeline with per-instance color.
/// Vertex layout:
///   Buffer 0 (per-vertex): position(float32x3) + normal(float32x3), stride=24
///   Buffer 1 (per-instance): model matrix as 4× float32x4 + color float32x4, stride=80
/// Bind group 0, binding 0: uniform buffer (VP matrix, 64 bytes)
Pipeline3D createColoredPipeline3D(WGPUDevice device, WGPUTextureFormat surfaceFormat) @trusted {
    Pipeline3D result;

    // Shader
    result.shaderModule = createShaderModule(device, colored3dShaderSource);
    if (result.shaderModule is null) {
        fatal("Failed to create colored 3D shader module");
    }

    // Bind group layout: 1 uniform buffer at binding 0
    WGPUBindGroupLayoutEntry bglEntry;
    bglEntry.binding = 0;
    bglEntry.visibility = WGPUShaderStage.vertex;
    bglEntry.buffer.type = WGPUBufferBindingType.uniform;
    bglEntry.buffer.minBindingSize = 64;

    WGPUBindGroupLayoutDescriptor bglDesc;
    bglDesc.entryCount = 1;
    bglDesc.entries = &bglEntry;
    result.bindGroupLayout = wgpuDeviceCreateBindGroupLayout(device, &bglDesc);

    // Pipeline layout
    WGPUPipelineLayoutDescriptor plDesc;
    plDesc.bindGroupLayoutCount = 1;
    plDesc.bindGroupLayouts = &result.bindGroupLayout;
    result.pipelineLayout = wgpuDeviceCreatePipelineLayout(device, &plDesc);

    // Vertex attributes — buffer 0: position + normal
    WGPUVertexAttribute[2] vertexAttrs = [
        { format: WGPUVertexFormat.float32x3, offset: 0,  shaderLocation: 0 },
        { format: WGPUVertexFormat.float32x3, offset: 12, shaderLocation: 1 },
    ];

    // Vertex attributes — buffer 1: instance model matrix (4 columns) + color
    WGPUVertexAttribute[5] instanceAttrs = [
        { format: WGPUVertexFormat.float32x4, offset: 0,  shaderLocation: 2 },
        { format: WGPUVertexFormat.float32x4, offset: 16, shaderLocation: 3 },
        { format: WGPUVertexFormat.float32x4, offset: 32, shaderLocation: 4 },
        { format: WGPUVertexFormat.float32x4, offset: 48, shaderLocation: 5 },
        { format: WGPUVertexFormat.float32x4, offset: 64, shaderLocation: 6 },  // color
    ];

    WGPUVertexBufferLayout[2] bufferLayouts = [
        {
            arrayStride: 24,
            stepMode: WGPUVertexStepMode.vertex,
            attributeCount: 2,
            attributes: vertexAttrs.ptr,
        },
        {
            arrayStride: 80,
            stepMode: WGPUVertexStepMode.instance_,
            attributeCount: 5,
            attributes: instanceAttrs.ptr,
        },
    ];

    // Fragment state
    WGPUBlendState blendState;
    blendState.color.operation = WGPUBlendOperation.add;
    blendState.color.srcFactor = WGPUBlendFactor.srcAlpha;
    blendState.color.dstFactor = WGPUBlendFactor.oneMinusSrcAlpha;
    blendState.alpha.operation = WGPUBlendOperation.add;
    blendState.alpha.srcFactor = WGPUBlendFactor.one;
    blendState.alpha.dstFactor = WGPUBlendFactor.oneMinusSrcAlpha;

    WGPUColorTargetState colorTarget;
    colorTarget.format = surfaceFormat;
    colorTarget.blend = &blendState;
    colorTarget.writeMask = WGPUColorWriteMask.all;

    WGPUFragmentState fragState;
    fragState.module_ = result.shaderModule;
    fragState.entryPoint = wgpuStringView("fs_main");
    fragState.targetCount = 1;
    fragState.targets = &colorTarget;

    // Depth stencil
    WGPUDepthStencilState depthState;
    depthState.format = WGPUTextureFormat.depth24Plus;
    depthState.depthWriteEnabled = WGPUOptionalBool.true_;
    depthState.depthCompare = WGPUCompareFunction.less;

    // Render pipeline
    WGPURenderPipelineDescriptor pipeDesc;
    pipeDesc.layout = result.pipelineLayout;
    pipeDesc.vertex.module_ = result.shaderModule;
    pipeDesc.vertex.entryPoint = wgpuStringView("vs_main");
    pipeDesc.vertex.bufferCount = 2;
    pipeDesc.vertex.buffers = bufferLayouts.ptr;
    pipeDesc.primitive.topology = WGPUPrimitiveTopology.triangleList;
    pipeDesc.primitive.frontFace = WGPUFrontFace.ccw;
    pipeDesc.primitive.cullMode = WGPUCullMode.back;
    pipeDesc.depthStencil = &depthState;
    pipeDesc.fragment = &fragState;

    result.pipeline = wgpuDeviceCreateRenderPipeline(device, &pipeDesc);
    if (result.pipeline is null) {
        fatal("Failed to create colored 3D render pipeline");
    }

    info("Colored 3D render pipeline created");
    return result;
}

struct PipelineText {
    WGPURenderPipeline  pipeline;
    WGPUBindGroupLayout bindGroupLayout;
    WGPUPipelineLayout  pipelineLayout;
    WGPUShaderModule    shaderModule;

    @disable this(this);

    void release() nothrow @nogc @trusted {
        if (pipeline !is null)        { wgpuRenderPipelineRelease(pipeline); pipeline = null; }
        if (pipelineLayout !is null)  { wgpuPipelineLayoutRelease(pipelineLayout); pipelineLayout = null; }
        if (bindGroupLayout !is null) { wgpuBindGroupLayoutRelease(bindGroupLayout); bindGroupLayout = null; }
        if (shaderModule !is null)    { wgpuShaderModuleRelease(shaderModule); shaderModule = null; }
    }
}

/// Create the 2D text render pipeline.
/// Vertex layout: position(float32x2) + texcoord(float32x2), stride=16
/// Bind group 0: binding 0 = uniform (screen size), binding 1 = sampler, binding 2 = texture
PipelineText createPipelineText(WGPUDevice device, WGPUTextureFormat surfaceFormat) @trusted {
    PipelineText result;

    result.shaderModule = createShaderModule(device, text2dShaderSource);
    if (result.shaderModule is null) {
        fatal("Failed to create text shader module");
    }

    // Bind group layout: uniform + sampler + texture
    WGPUBindGroupLayoutEntry[3] bglEntries;

    // binding 0: uniform buffer (screen size)
    bglEntries[0].binding = 0;
    bglEntries[0].visibility = WGPUShaderStage.vertex;
    bglEntries[0].buffer.type = WGPUBufferBindingType.uniform;
    bglEntries[0].buffer.minBindingSize = 8; // vec2<f32>

    // binding 1: sampler
    bglEntries[1].binding = 1;
    bglEntries[1].visibility = WGPUShaderStage.fragment;
    bglEntries[1].sampler.type = WGPUSamplerBindingType.filtering;

    // binding 2: texture
    bglEntries[2].binding = 2;
    bglEntries[2].visibility = WGPUShaderStage.fragment;
    bglEntries[2].texture.sampleType = WGPUTextureSampleType.float_;
    bglEntries[2].texture.viewDimension = WGPUTextureViewDimension.dim2D;

    WGPUBindGroupLayoutDescriptor bglDesc;
    bglDesc.entryCount = 3;
    bglDesc.entries = bglEntries.ptr;
    result.bindGroupLayout = wgpuDeviceCreateBindGroupLayout(device, &bglDesc);

    // Pipeline layout
    WGPUPipelineLayoutDescriptor plDesc;
    plDesc.bindGroupLayoutCount = 1;
    plDesc.bindGroupLayouts = &result.bindGroupLayout;
    result.pipelineLayout = wgpuDeviceCreatePipelineLayout(device, &plDesc);

    // Vertex attributes
    WGPUVertexAttribute[2] attrs = [
        { format: WGPUVertexFormat.float32x2, offset: 0, shaderLocation: 0 },  // position
        { format: WGPUVertexFormat.float32x2, offset: 8, shaderLocation: 1 },  // texcoord
    ];

    WGPUVertexBufferLayout bufLayout;
    bufLayout.arrayStride = 16;
    bufLayout.stepMode = WGPUVertexStepMode.vertex;
    bufLayout.attributeCount = 2;
    bufLayout.attributes = attrs.ptr;

    // Fragment — alpha blend
    WGPUBlendState blendState;
    blendState.color.operation = WGPUBlendOperation.add;
    blendState.color.srcFactor = WGPUBlendFactor.srcAlpha;
    blendState.color.dstFactor = WGPUBlendFactor.oneMinusSrcAlpha;
    blendState.alpha.operation = WGPUBlendOperation.add;
    blendState.alpha.srcFactor = WGPUBlendFactor.one;
    blendState.alpha.dstFactor = WGPUBlendFactor.zero;

    WGPUColorTargetState colorTarget;
    colorTarget.format = surfaceFormat;
    colorTarget.blend = &blendState;
    colorTarget.writeMask = WGPUColorWriteMask.all;

    WGPUFragmentState fragState;
    fragState.module_ = result.shaderModule;
    fragState.entryPoint = wgpuStringView("fs_text");
    fragState.targetCount = 1;
    fragState.targets = &colorTarget;

    // No depth-stencil: text draws on the post-resolve present pass (swapchain only).
    WGPURenderPipelineDescriptor pipeDesc;
    pipeDesc.layout = result.pipelineLayout;
    pipeDesc.vertex.module_ = result.shaderModule;
    pipeDesc.vertex.entryPoint = wgpuStringView("vs_text");
    pipeDesc.vertex.bufferCount = 1;
    pipeDesc.vertex.buffers = &bufLayout;
    pipeDesc.primitive.topology = WGPUPrimitiveTopology.triangleList;
    pipeDesc.fragment = &fragState;

    result.pipeline = wgpuDeviceCreateRenderPipeline(device, &pipeDesc);
    if (result.pipeline is null) {
        fatal("Failed to create text render pipeline");
    }

    info("Text render pipeline created");
    return result;
}

/// Frame uniform size for textured PBR pipeline.
/// Layout must match `shadows.wgsl` FrameUniforms (1024 bytes):
/// viewProj(64) + cameraPos/bias(16) + DirLight(96) + counts/time(16)
/// + iblIntensity/wetness/rain/clouds(16) + cascades(352) + camera(96)
/// + atmosphere/sky(112) + ssrParams(16) + probeCount/clusteredFlags/pad(16)
/// + ReflectionProbeData[4](192) + viewportRect(16) + clusterZParams(16).
/// Point lights (@binding(9)), spot lights (@binding(13)), and cluster
/// culling tables (@binding(14..15)) live in read-only storage buffers.
enum FRAME_UNIFORMS_SIZE = 1024;
/// Entries in the frame bind group (@group(0)): uniforms, shadow sampler,
/// 7 shadow maps, point lights (9), shared water data (10),
/// opaque scene color pyramid (11), opaque scene depth (12),
/// spot lights (13), cluster grid (14), and cluster light indices (15).
enum uint FRAME_BINDING_COUNT = 16;
/// MaterialParams UBO size (OpenPBR v1.1 + OPBR-6/7/8 block + surface options, 15 × vec4<f32> = 240 bytes).
enum MATERIAL_PARAMS_SIZE = 240;
/// Entries in the material bind group (@group(1)): params UBO, sampler,
/// albedo/MR/normal/AO/emissive maps (2..6), custom surfaceParams UBO (7),
/// and OPBR-6/7 layer maps: coat, coatNormal, fuzz, anisoFilm, transmission (8..12).
enum uint MATERIAL_BINDING_COUNT = 13;
/// Per-instance data of the textured PBR pipeline (buffer 1, stride 96):
/// model matrix, albedo tint and a free `custom` vec4. The stock shader reads
/// `custom` as x = emission multiplier, y = white flash [0..1],
/// z = dissolve threshold [0..1]; w is free for custom surface shaders.
struct TexInstanceData {
    float[16] model;
    float[4] color = [1, 1, 1, 1];
    float[4] custom = [1, 0, 0, 0];
}
static assert(TexInstanceData.sizeof == 96);

/// How a material is composited into the HDR target.
enum BlendMode : ubyte {
    /// Standard alpha blending (default; opaque when alpha is 1).
    alpha,
    /// `dst += src * srcAlpha`: glows, beams, particles. Never darkens.
    additive,
    /// No blending at all.
    opaque,
}

/// Fixed-function state baked into a textured draw pipeline.
struct RenderState {
    BlendMode blend = BlendMode.alpha;
    bool depthWrite = true;
    bool doubleSided = false;
    /// Discard pixels whose opacity is below `MaterialParams.alphaCutoff`, in
    /// the color pass and in every shadow map. Surviving pixels are opaque.
    bool alphaMask = false;
    /// Set by the engine while `AoSettings` is enabled: no blending, and alpha
    /// holds `1 - ambient share of the color`.
    package(engine) bool ambientAlpha = false;
    /// Set by the engine for materials with sprite features (`soft`, `litParticle`, `flipbook`).
    package(engine) bool sprite = false;
    /// Set by the engine for materials whose normal map holds X and Y only.
    package(engine) bool normalXy = false;

    bool isDefault() const pure nothrow @nogc { return this == RenderState.init; }
}

/// Free parameter block for custom surface shaders (4 × vec4<f32>), material binding 7.
enum SURFACE_PARAMS_SIZE = 64;

/// Textured 3D instanced PBR pipeline.
///   Buffer 0 (per-vertex): `TexVert` stride 32, or `TexTanVert` stride 48 on `pipelineTangent`.
///   Buffer 1 (per-instance): model matrix + tint, stride=80.
///   @group(0) Frame+shadows, @group(1) Material, @group(2) IBL.
/// A stride-48 buffer must be drawn with `pipelineTangent`.
Pipeline3D createTexturedPipeline3D(WGPUDevice device, WGPUTextureFormat surfaceFormat) @trusted {
    Pipeline3D result;

    result.shaderModule = createShaderModule(device, kTextured3dWgsl);
    if (result.shaderModule is null) {
        fatal("Failed to create textured 3D shader module");
    }

    // --- Group 0: Frame UBO + comparison sampler + dir/point/spot shadows + point light storage
    //     + shared water data (binding 10, `common/waves.wgsl`) ---
    WGPUBindGroupLayoutEntry[FRAME_BINDING_COUNT] frameEntries;
    frameEntries[0].binding = 0;
    frameEntries[0].visibility = WGPUShaderStage.vertex | WGPUShaderStage.fragment;
    frameEntries[0].buffer.type = WGPUBufferBindingType.uniform;
    frameEntries[0].buffer.minBindingSize = FRAME_UNIFORMS_SIZE;

    frameEntries[1].binding = 1;
    frameEntries[1].visibility = WGPUShaderStage.fragment;
    frameEntries[1].sampler.type = WGPUSamplerBindingType.comparison;

    frameEntries[2].binding = 2;
    frameEntries[2].visibility = WGPUShaderStage.fragment;
    frameEntries[2].texture.sampleType = WGPUTextureSampleType.depth;
    // Directional shadow: one layer per cascade (a fixed map is a 1-layer array).
    frameEntries[2].texture.viewDimension = WGPUTextureViewDimension.dim2DArray;

    foreach (i; 0 .. 4) {
        frameEntries[3 + i].binding = cast(uint)(3 + i);
        frameEntries[3 + i].visibility = WGPUShaderStage.fragment;
        frameEntries[3 + i].texture.sampleType = WGPUTextureSampleType.depth;
        frameEntries[3 + i].texture.viewDimension = WGPUTextureViewDimension.cube;
    }

    foreach (i; 0 .. 2) {
        frameEntries[7 + i].binding = cast(uint)(7 + i);
        frameEntries[7 + i].visibility = WGPUShaderStage.fragment;
        frameEntries[7 + i].texture.sampleType = WGPUTextureSampleType.depth;
        frameEntries[7 + i].texture.viewDimension = WGPUTextureViewDimension.dim2D;
    }

    frameEntries[9].binding = 9;
    frameEntries[9].visibility = WGPUShaderStage.fragment;
    frameEntries[9].buffer.type = WGPUBufferBindingType.readOnlyStorage;
    frameEntries[9].buffer.minBindingSize = 48; // sizeof(PointLight)

    frameEntries[10].binding = 10;
    frameEntries[10].visibility = WGPUShaderStage.vertex | WGPUShaderStage.fragment;
    frameEntries[10].buffer.type = WGPUBufferBindingType.readOnlyStorage;
    frameEntries[10].buffer.minBindingSize = WATER_DATA_SIZE;

    frameEntries[11].binding = 11;
    frameEntries[11].visibility = WGPUShaderStage.fragment;
    frameEntries[11].texture.sampleType = WGPUTextureSampleType.float_;
    frameEntries[11].texture.viewDimension = WGPUTextureViewDimension.dim2D;

    frameEntries[12].binding = 12;
    frameEntries[12].visibility = WGPUShaderStage.fragment;
    frameEntries[12].texture.sampleType = WGPUTextureSampleType.depth;
    frameEntries[12].texture.viewDimension = WGPUTextureViewDimension.dim2D;

    frameEntries[13].binding = 13;
    frameEntries[13].visibility = WGPUShaderStage.fragment;
    frameEntries[13].buffer.type = WGPUBufferBindingType.readOnlyStorage;
    frameEntries[13].buffer.minBindingSize = 128; // sizeof(SpotLight)

    frameEntries[14].binding = 14;
    frameEntries[14].visibility = WGPUShaderStage.fragment;
    frameEntries[14].buffer.type = WGPUBufferBindingType.readOnlyStorage;
    frameEntries[14].buffer.minBindingSize = 16; // sizeof(ClusterRecord)

    frameEntries[15].binding = 15;
    frameEntries[15].visibility = WGPUShaderStage.fragment;
    frameEntries[15].buffer.type = WGPUBufferBindingType.readOnlyStorage;
    frameEntries[15].buffer.minBindingSize = 4; // u32 light index

    WGPUBindGroupLayoutDescriptor frameBglDesc;
    frameBglDesc.entryCount = FRAME_BINDING_COUNT;
    frameBglDesc.entries = frameEntries.ptr;
    result.frameBindGroupLayout = wgpuDeviceCreateBindGroupLayout(device, &frameBglDesc);

    // --- Group 1: Material ---
    WGPUBindGroupLayoutEntry[MATERIAL_BINDING_COUNT] matEntries;
    matEntries[0].binding = 0;
    matEntries[0].visibility = WGPUShaderStage.vertex | WGPUShaderStage.fragment;
    matEntries[0].buffer.type = WGPUBufferBindingType.uniform;
    matEntries[0].buffer.minBindingSize = MATERIAL_PARAMS_SIZE;

    matEntries[1].binding = 1;
    matEntries[1].visibility = WGPUShaderStage.fragment;
    matEntries[1].sampler.type = WGPUSamplerBindingType.filtering;

    foreach (i; 0 .. 5) {
        matEntries[2 + i].binding = cast(uint)(2 + i);
        matEntries[2 + i].visibility = WGPUShaderStage.fragment;
        matEntries[2 + i].texture.sampleType = WGPUTextureSampleType.float_;
        matEntries[2 + i].texture.viewDimension = WGPUTextureViewDimension.dim2D;
    }

    // Custom surface parameters: unused by the stock shader, read by
    // `surface` (fragment) and `displace` (vertex) in custom variants.
    matEntries[7].binding = 7;
    matEntries[7].visibility = WGPUShaderStage.vertex | WGPUShaderStage.fragment;
    matEntries[7].buffer.type = WGPUBufferBindingType.uniform;
    matEntries[7].buffer.minBindingSize = SURFACE_PARAMS_SIZE;

    // OPBR-6 / OPBR-7 per-pixel layer maps: coat (8), coatNormal (9),
    // fuzz (10), anisoFilm (11), transmission (12).
    foreach (i; 0 .. 5) {
        matEntries[8 + i].binding = cast(uint)(8 + i);
        matEntries[8 + i].visibility = WGPUShaderStage.fragment;
        matEntries[8 + i].texture.sampleType = WGPUTextureSampleType.float_;
        matEntries[8 + i].texture.viewDimension = WGPUTextureViewDimension.dim2D;
    }

    WGPUBindGroupLayoutDescriptor matBglDesc;
    matBglDesc.entryCount = MATERIAL_BINDING_COUNT;
    matBglDesc.entries = matEntries.ptr;
    result.bindGroupLayout = wgpuDeviceCreateBindGroupLayout(device, &matBglDesc);

    // --- Group 2: IBL ---
    WGPUBindGroupLayoutEntry[4] iblEntries;
    iblEntries[0].binding = 0;
    iblEntries[0].visibility = WGPUShaderStage.fragment;
    iblEntries[0].texture.sampleType = WGPUTextureSampleType.float_;
    iblEntries[0].texture.viewDimension = WGPUTextureViewDimension.cube;

    iblEntries[1].binding = 1;
    iblEntries[1].visibility = WGPUShaderStage.fragment;
    iblEntries[1].texture.sampleType = WGPUTextureSampleType.float_;
    iblEntries[1].texture.viewDimension = WGPUTextureViewDimension.cube;

    iblEntries[2].binding = 2;
    iblEntries[2].visibility = WGPUShaderStage.fragment;
    iblEntries[2].texture.sampleType = WGPUTextureSampleType.float_;
    iblEntries[2].texture.viewDimension = WGPUTextureViewDimension.dim2D;

    iblEntries[3].binding = 3;
    iblEntries[3].visibility = WGPUShaderStage.fragment;
    iblEntries[3].sampler.type = WGPUSamplerBindingType.filtering;

    WGPUBindGroupLayoutDescriptor iblBglDesc;
    iblBglDesc.entryCount = 4;
    iblBglDesc.entries = iblEntries.ptr;
    result.iblBindGroupLayout = wgpuDeviceCreateBindGroupLayout(device, &iblBglDesc);

    WGPUBindGroupLayout[3] layouts = [
        result.frameBindGroupLayout,
        result.bindGroupLayout,
        result.iblBindGroupLayout,
    ];
    WGPUPipelineLayoutDescriptor plDesc;
    plDesc.bindGroupLayoutCount = 3;
    plDesc.bindGroupLayouts = layouts.ptr;
    result.pipelineLayout = wgpuDeviceCreatePipelineLayout(device, &plDesc);

    result.pipeline = createTexturedDrawPipeline(device, result.shaderModule, result.pipelineLayout, surfaceFormat, 32, false);
    if (result.pipeline is null) {
        fatal("Failed to create textured 3D render pipeline");
    }

    result.shaderModuleTangent = createShaderModule(device, kTextured3dTangentWgsl);
    if (result.shaderModuleTangent is null)
        fatal("Failed to create textured 3D tangent shader module");
    result.pipelineTangent = createTexturedDrawPipeline(device, result.shaderModuleTangent, result.pipelineLayout, surfaceFormat, 48, true);
    if (result.pipelineTangent is null)
        fatal("Failed to create textured 3D tangent render pipeline");

    // --- Group 3 (skinned PBR): concatenated joint palette storage buffer ---
    WGPUBindGroupLayoutEntry skinEntry;
    skinEntry.binding = 0;
    skinEntry.visibility = WGPUShaderStage.vertex;
    skinEntry.buffer.type = WGPUBufferBindingType.readOnlyStorage;
    skinEntry.buffer.minBindingSize = 64;
    WGPUBindGroupLayoutDescriptor skinBglDesc;
    skinBglDesc.entryCount = 1;
    skinBglDesc.entries = &skinEntry;
    result.skinBindGroupLayout = wgpuDeviceCreateBindGroupLayout(device, &skinBglDesc);

    WGPUBindGroupLayout[4] skinLayouts = [
        result.frameBindGroupLayout,
        result.bindGroupLayout,
        result.iblBindGroupLayout,
        result.skinBindGroupLayout,
    ];
    WGPUPipelineLayoutDescriptor splDesc;
    splDesc.bindGroupLayoutCount = 4;
    splDesc.bindGroupLayouts = skinLayouts.ptr;
    result.skinnedPipelineLayout = wgpuDeviceCreatePipelineLayout(device, &splDesc);

    result.shaderModuleSkinned = createShaderModule(device, kTextured3dSkinnedWgsl, "textured3d_skinned");
    if (result.shaderModuleSkinned is null)
        fatal("Failed to create textured 3D skinned shader module");
    result.pipelineSkinned = createSkinnedTexturedDrawPipeline(
        device, result.shaderModuleSkinned, result.skinnedPipelineLayout, surfaceFormat);
    if (result.pipelineSkinned is null)
        fatal("Failed to create textured 3D skinned render pipeline");

    info("Textured 3D PBR pipeline created (frame + material + IBL + skin)");
    return result;
}

/// Vertex layout is stride 32 (`TexVert`) or 48 (`TexTanVert`, location 8);
/// instances are `TexInstanceData` (stride 96, custom at location 9).
WGPURenderPipeline createTexturedDrawPipeline(WGPUDevice device, WGPUShaderModule shader, WGPUPipelineLayout layout, WGPUTextureFormat surfaceFormat, ulong stride, bool tangent, RenderState state = RenderState.init, bool colored = false) nothrow @nogc @trusted {
    WGPUVertexAttribute[4] vertexAttrs = [
        { format: WGPUVertexFormat.float32x3, offset: 0,  shaderLocation: 0 },
        { format: WGPUVertexFormat.float32x3, offset: 12, shaderLocation: 1 },
        { format: WGPUVertexFormat.float32x2, offset: 24, shaderLocation: 2 },
        { format: WGPUVertexFormat.float32x4, offset: 32, shaderLocation: 8 },
    ];
    return createTexturedDrawPipelineWithAttrs(
        device, shader, layout, surfaceFormat,
        stride, vertexAttrs.ptr, tangent ? 4 : 3, state, colored);
}

/// Stride-80 skinned PBR pipeline (`SkinnedVertex`: pos, normal, uv, tangent, joints, weights).
WGPURenderPipeline createSkinnedTexturedDrawPipeline(WGPUDevice device, WGPUShaderModule shader, WGPUPipelineLayout layout, WGPUTextureFormat surfaceFormat, RenderState state = RenderState.init, bool colored = false) nothrow @nogc @trusted {
    WGPUVertexAttribute[6] vertexAttrs = [
        { format: WGPUVertexFormat.float32x3, offset: 0,  shaderLocation: 0 },
        { format: WGPUVertexFormat.float32x3, offset: 12, shaderLocation: 1 },
        { format: WGPUVertexFormat.float32x2, offset: 24, shaderLocation: 2 },
        { format: WGPUVertexFormat.float32x4, offset: 32, shaderLocation: 8 },
        { format: WGPUVertexFormat.uint32x4,  offset: 48, shaderLocation: 10 },
        { format: WGPUVertexFormat.float32x4, offset: 64, shaderLocation: 11 },
    ];
    return createTexturedDrawPipelineWithAttrs(
        device, shader, layout, surfaceFormat,
        80, vertexAttrs.ptr, 6, state, colored);
}

private WGPURenderPipeline createTexturedDrawPipelineWithAttrs(
    WGPUDevice device, WGPUShaderModule shader, WGPUPipelineLayout layout,
    WGPUTextureFormat surfaceFormat, ulong stride,
    const(WGPUVertexAttribute)* vertexAttrs, uint vertexAttrCount,
    RenderState state, bool colored) nothrow @nogc @trusted
{
    WGPUVertexAttribute colorAttr = { format: WGPUVertexFormat.unorm8x4, offset: 0, shaderLocation: 12 };
    WGPUVertexAttribute[6] instanceAttrs = [
        { format: WGPUVertexFormat.float32x4, offset: 0,  shaderLocation: 3 },
        { format: WGPUVertexFormat.float32x4, offset: 16, shaderLocation: 4 },
        { format: WGPUVertexFormat.float32x4, offset: 32, shaderLocation: 5 },
        { format: WGPUVertexFormat.float32x4, offset: 48, shaderLocation: 6 },
        { format: WGPUVertexFormat.float32x4, offset: 64, shaderLocation: 7 },
        { format: WGPUVertexFormat.float32x4, offset: 80, shaderLocation: 9 },
    ];
    WGPUVertexBufferLayout[3] bufferLayouts = [
        {
            arrayStride: stride,
            stepMode: WGPUVertexStepMode.vertex,
            attributeCount: vertexAttrCount,
            attributes: vertexAttrs,
        },
        {
            arrayStride: TexInstanceData.sizeof,
            stepMode: WGPUVertexStepMode.instance_,
            attributeCount: 6,
            attributes: instanceAttrs.ptr,
        },
        // Optional vertex color stream.
        {
            arrayStride: 4,
            stepMode: WGPUVertexStepMode.vertex,
            attributeCount: 1,
            attributes: &colorAttr,
        },
    ];

    WGPUBlendState blendState;
    blendState.color.operation = WGPUBlendOperation.add;
    blendState.color.srcFactor = WGPUBlendFactor.srcAlpha;
    blendState.color.dstFactor = WGPUBlendFactor.oneMinusSrcAlpha;
    blendState.alpha.operation = WGPUBlendOperation.add;
    blendState.alpha.srcFactor = WGPUBlendFactor.one;
    blendState.alpha.dstFactor = WGPUBlendFactor.oneMinusSrcAlpha;
    if (state.blend == BlendMode.additive) {
        blendState.color.dstFactor = WGPUBlendFactor.one;
        blendState.alpha.srcFactor = WGPUBlendFactor.zero;
        blendState.alpha.dstFactor = WGPUBlendFactor.one;
    }

    WGPUColorTargetState colorTarget;
    colorTarget.format = surfaceFormat;
    colorTarget.blend = state.blend == BlendMode.opaque || state.ambientAlpha ? null : &blendState;
    colorTarget.writeMask = WGPUColorWriteMask.all;

    WGPUFragmentState fragState;
    fragState.module_ = shader;
    fragState.entryPoint = wgpuStringView("fs_main");
    fragState.targetCount = 1;
    fragState.targets = &colorTarget;
    WGPUConstantEntry[4] constants;
    if (state.alphaMask) constants[fragState.constantCount++].key = wgpuStringView("ALPHA_MASK");
    if (state.ambientAlpha) constants[fragState.constantCount++].key = wgpuStringView("AMBIENT_ALPHA");
    if (state.sprite) constants[fragState.constantCount++].key = wgpuStringView("SPRITE_FEATURES");
    if (state.normalXy) constants[fragState.constantCount++].key = wgpuStringView("NORMAL_XY");
    foreach (ref c; constants) c.value = 1;
    if (fragState.constantCount > 0) fragState.constants = constants.ptr;

    WGPUDepthStencilState depthState;
    depthState.format = WGPUTextureFormat.depth24Plus;
    depthState.depthWriteEnabled = state.depthWrite ? WGPUOptionalBool.true_ : WGPUOptionalBool.false_;
    depthState.depthCompare = WGPUCompareFunction.less;

    WGPURenderPipelineDescriptor pipeDesc;
    pipeDesc.layout = layout;
    pipeDesc.vertex.module_ = shader;
    pipeDesc.vertex.entryPoint = wgpuStringView("vs_main");
    pipeDesc.vertex.bufferCount = colored ? 3 : 2;
    pipeDesc.vertex.buffers = bufferLayouts.ptr;
    pipeDesc.primitive.topology = WGPUPrimitiveTopology.triangleList;
    pipeDesc.primitive.frontFace = WGPUFrontFace.ccw;
    pipeDesc.primitive.cullMode = state.doubleSided ? WGPUCullMode.none : WGPUCullMode.back;
    pipeDesc.depthStencil = &depthState;
    pipeDesc.fragment = &fragState;
    return wgpuDeviceCreateRenderPipeline(device, &pipeDesc);
}

/// Draw pipelines (stride 32 and stride 48) for one custom surface shader.
/// They share the stock pipeline layout, so every `Material` binds to them.
struct SurfacePipelines {
    WGPURenderPipeline pipeline;
    WGPURenderPipeline pipelineTangent;
    WGPUShaderModule shaderModule;
    WGPUShaderModule shaderModuleTangent;
    /// Vertex hook the snippet defines; anything but `none` gets displaced shadow pipelines.
    DisplaceKind displace;
    /// Depth-only `vs_shadow` pipelines, built lazily by the scene on first
    /// shadow use. Index: `(tangent ? 2 : 0) + (doubleSided ? 1 : 0)`.
    WGPURenderPipeline[4] shadowPipelines;
    /// Same, for alpha-masked materials (`vs_shadow_mask` + `fs_shadow_mask`).
    WGPURenderPipeline[4] shadowMaskPipelines;

    bool valid() const nothrow @nogc { return pipeline !is null && pipelineTangent !is null; }

    void release() nothrow @nogc @trusted {
        foreach (ref p; shadowPipelines)
            if (p !is null) { wgpuRenderPipelineRelease(p); p = null; }
        foreach (ref p; shadowMaskPipelines)
            if (p !is null) { wgpuRenderPipelineRelease(p); p = null; }
        if (pipeline !is null) { wgpuRenderPipelineRelease(pipeline); pipeline = null; }
        if (pipelineTangent !is null) { wgpuRenderPipelineRelease(pipelineTangent); pipelineTangent = null; }
        if (shaderModule !is null) { wgpuShaderModuleRelease(shaderModule); shaderModule = null; }
        if (shaderModuleTangent !is null) { wgpuShaderModuleRelease(shaderModuleTangent); shaderModuleTangent = null; }
    }
}

/// Build both vertex-layout variants from fully composed WGSL
/// (see `composeSurfaceShader`). Returns an invalid struct on failure.
SurfacePipelines createSurfacePipelines(ref Pipeline3D base, WGPUDevice device, WGPUTextureFormat surfaceFormat,
                                        scope const(char)[] wgsl, scope const(char)[] wgslTangent) nothrow @nogc @trusted {
    SurfacePipelines result;
    if (base.pipelineLayout is null || device is null) return result;
    result.shaderModule = createShaderModule(device, wgsl, "custom_surface");
    result.shaderModuleTangent = createShaderModule(device, wgslTangent, "custom_surface_tangent");
    if (result.shaderModule !is null)
        result.pipeline = createTexturedDrawPipeline(device, result.shaderModule, base.pipelineLayout, surfaceFormat, 32, false);
    if (result.shaderModuleTangent !is null)
        result.pipelineTangent = createTexturedDrawPipeline(device, result.shaderModuleTangent, base.pipelineLayout, surfaceFormat, 48, true);
    if (!result.valid) result.release();
    return result;
}

/// Transactional hot-reload for colored 3D pipeline: keeps old pipeline if new shader fails.
bool reloadColoredPipeline3D(ref Pipeline3D pipe, WGPUDevice device, WGPUTextureFormat surfaceFormat, scope const(char)[] newWgsl) nothrow @nogc @trusted {
    if (pipe.pipelineLayout is null || device is null) return false;
    auto newModule = createShaderModule(device, newWgsl, "reload_colored_3d");
    if (newModule is null) return false;

    WGPUVertexAttribute[2] vertexAttrs = [
        { format: WGPUVertexFormat.float32x3, offset: 0,  shaderLocation: 0 },
        { format: WGPUVertexFormat.float32x3, offset: 12, shaderLocation: 1 },
    ];
    WGPUVertexAttribute[5] instanceAttrs = [
        { format: WGPUVertexFormat.float32x4, offset: 0,  shaderLocation: 2 },
        { format: WGPUVertexFormat.float32x4, offset: 16, shaderLocation: 3 },
        { format: WGPUVertexFormat.float32x4, offset: 32, shaderLocation: 4 },
        { format: WGPUVertexFormat.float32x4, offset: 48, shaderLocation: 5 },
        { format: WGPUVertexFormat.float32x4, offset: 64, shaderLocation: 6 },
    ];
    WGPUVertexBufferLayout[2] bufferLayouts = [
        {
            arrayStride: 24,
            stepMode: WGPUVertexStepMode.vertex,
            attributeCount: 2,
            attributes: vertexAttrs.ptr,
        },
        {
            arrayStride: 80,
            stepMode: WGPUVertexStepMode.instance_,
            attributeCount: 5,
            attributes: instanceAttrs.ptr,
        },
    ];

    WGPUBlendState blendState;
    blendState.color.operation = WGPUBlendOperation.add;
    blendState.color.srcFactor = WGPUBlendFactor.srcAlpha;
    blendState.color.dstFactor = WGPUBlendFactor.oneMinusSrcAlpha;
    blendState.alpha.operation = WGPUBlendOperation.add;
    blendState.alpha.srcFactor = WGPUBlendFactor.one;
    blendState.alpha.dstFactor = WGPUBlendFactor.oneMinusSrcAlpha;

    WGPUColorTargetState colorTarget;
    colorTarget.format = surfaceFormat;
    colorTarget.blend = &blendState;
    colorTarget.writeMask = WGPUColorWriteMask.all;

    WGPUFragmentState fragState;
    fragState.module_ = newModule;
    fragState.entryPoint = wgpuStringView("fs_main");
    fragState.targetCount = 1;
    fragState.targets = &colorTarget;

    WGPUDepthStencilState depthState;
    depthState.format = WGPUTextureFormat.depth24Plus;
    depthState.depthWriteEnabled = WGPUOptionalBool.true_;
    depthState.depthCompare = WGPUCompareFunction.less;

    WGPURenderPipelineDescriptor pipeDesc;
    pipeDesc.layout = pipe.pipelineLayout;
    pipeDesc.vertex.module_ = newModule;
    pipeDesc.vertex.entryPoint = wgpuStringView("vs_main");
    pipeDesc.vertex.bufferCount = 2;
    pipeDesc.vertex.buffers = bufferLayouts.ptr;
    pipeDesc.primitive.topology = WGPUPrimitiveTopology.triangleList;
    pipeDesc.primitive.frontFace = WGPUFrontFace.ccw;
    pipeDesc.primitive.cullMode = WGPUCullMode.back;
    pipeDesc.depthStencil = &depthState;
    pipeDesc.fragment = &fragState;

    auto newPipeline = wgpuDeviceCreateRenderPipeline(device, &pipeDesc);
    if (newPipeline is null) {
        wgpuShaderModuleRelease(newModule);
        return false;
    }

    if (pipe.pipeline !is null) wgpuRenderPipelineRelease(pipe.pipeline);
    if (pipe.shaderModule !is null) wgpuShaderModuleRelease(pipe.shaderModule);
    pipe.pipeline = newPipeline;
    pipe.shaderModule = newModule;
    return true;
}

/// Transactional hot-reload for textured 3D PBR pipeline: keeps old pipeline if new shader fails.
bool reloadTexturedPipeline3D(ref Pipeline3D pipe, WGPUDevice device, WGPUTextureFormat surfaceFormat, scope const(char)[] newWgsl, bool tangent = false) nothrow @nogc @trusted {
    if (pipe.pipelineLayout is null || device is null) return false;
    auto newModule = createShaderModule(device, newWgsl, "reload_textured_3d");
    if (newModule is null) return false;

    auto newPipeline = createTexturedDrawPipeline(device, newModule, pipe.pipelineLayout, surfaceFormat, tangent ? 48 : 32, tangent);
    if (newPipeline is null) {
        wgpuShaderModuleRelease(newModule);
        return false;
    }

    if (tangent) {
        if (pipe.pipelineTangent !is null) wgpuRenderPipelineRelease(pipe.pipelineTangent);
        if (pipe.shaderModuleTangent !is null) wgpuShaderModuleRelease(pipe.shaderModuleTangent);
        pipe.pipelineTangent = newPipeline;
        pipe.shaderModuleTangent = newModule;
    } else {
        if (pipe.pipeline !is null) wgpuRenderPipelineRelease(pipe.pipeline);
        if (pipe.shaderModule !is null) wgpuShaderModuleRelease(pipe.shaderModule);
        pipe.pipeline = newPipeline;
        pipe.shaderModule = newModule;
    }
    return true;
}

/// Transactional hot-reload for 2D text pipeline: keeps old pipeline if new shader fails.
bool reloadPipelineText(ref PipelineText pipe, WGPUDevice device, WGPUTextureFormat surfaceFormat, scope const(char)[] newWgsl) nothrow @nogc @trusted {
    if (pipe.pipelineLayout is null || device is null) return false;
    auto newModule = createShaderModule(device, newWgsl, "reload_text");
    if (newModule is null) return false;

    WGPUVertexAttribute[2] attrs = [
        { format: WGPUVertexFormat.float32x2, offset: 0, shaderLocation: 0 },
        { format: WGPUVertexFormat.float32x2, offset: 8, shaderLocation: 1 },
    ];

    WGPUVertexBufferLayout bufLayout;
    bufLayout.arrayStride = 16;
    bufLayout.stepMode = WGPUVertexStepMode.vertex;
    bufLayout.attributeCount = 2;
    bufLayout.attributes = attrs.ptr;

    WGPUBlendState blendState;
    blendState.color.operation = WGPUBlendOperation.add;
    blendState.color.srcFactor = WGPUBlendFactor.srcAlpha;
    blendState.color.dstFactor = WGPUBlendFactor.oneMinusSrcAlpha;
    blendState.alpha.operation = WGPUBlendOperation.add;
    blendState.alpha.srcFactor = WGPUBlendFactor.one;
    blendState.alpha.dstFactor = WGPUBlendFactor.zero;

    WGPUColorTargetState colorTarget;
    colorTarget.format = surfaceFormat;
    colorTarget.blend = &blendState;
    colorTarget.writeMask = WGPUColorWriteMask.all;

    WGPUFragmentState fragState;
    fragState.module_ = newModule;
    fragState.entryPoint = wgpuStringView("fs_text");
    fragState.targetCount = 1;
    fragState.targets = &colorTarget;

    WGPURenderPipelineDescriptor pipeDesc;
    pipeDesc.layout = pipe.pipelineLayout;
    pipeDesc.vertex.module_ = newModule;
    pipeDesc.vertex.entryPoint = wgpuStringView("vs_text");
    pipeDesc.vertex.bufferCount = 1;
    pipeDesc.vertex.buffers = &bufLayout;
    pipeDesc.primitive.topology = WGPUPrimitiveTopology.triangleList;
    pipeDesc.fragment = &fragState;

    auto newPipeline = wgpuDeviceCreateRenderPipeline(device, &pipeDesc);
    if (newPipeline is null) {
        wgpuShaderModuleRelease(newModule);
        return false;
    }

    if (pipe.pipeline !is null) wgpuRenderPipelineRelease(pipe.pipeline);
    if (pipe.shaderModule !is null) wgpuShaderModuleRelease(pipe.shaderModule);
    pipe.pipeline = newPipeline;
    pipe.shaderModule = newModule;
    return true;
}

