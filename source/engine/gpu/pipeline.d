/// Render pipeline creation helpers for 3D instanced and 2D text pipelines.
module engine.gpu.pipeline;

import bindings.wgpu;
import engine.gpu.shader;
import engine.gpu.shaders;
import engine.core.log;

@safe:

struct Pipeline3D {
    WGPURenderPipeline  pipeline;
    /// Primary layout: colored/cube = group0; textured = material group1.
    WGPUBindGroupLayout bindGroupLayout;
    /// Textured pipeline only: frame+shadow @group(0). Null for colored pipelines.
    WGPUBindGroupLayout frameBindGroupLayout;
    /// Textured pipeline only: IBL @group(2). Null for colored pipelines.
    WGPUBindGroupLayout iblBindGroupLayout;
    WGPUPipelineLayout  pipelineLayout;
    WGPUShaderModule    shaderModule;

    @disable this(this);

    void release() nothrow @nogc @trusted {
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
    result.shaderModule = createShaderModule(device, cube3dShaderSource.ptr);
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
    WGPUColorTargetState colorTarget;
    colorTarget.format = surfaceFormat;
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
    result.shaderModule = createShaderModule(device, colored3dShaderSource.ptr);
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
    WGPUColorTargetState colorTarget;
    colorTarget.format = surfaceFormat;
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

    result.shaderModule = createShaderModule(device, text2dShaderSource.ptr);
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

    // Depth format must match the render pass, but disable depth write/test for text overlay
    WGPUDepthStencilState depthState;
    depthState.format = WGPUTextureFormat.depth24Plus;
    depthState.depthWriteEnabled = WGPUOptionalBool.false_;
    depthState.depthCompare = WGPUCompareFunction.always;

    WGPURenderPipelineDescriptor pipeDesc;
    pipeDesc.layout = result.pipelineLayout;
    pipeDesc.vertex.module_ = result.shaderModule;
    pipeDesc.vertex.entryPoint = wgpuStringView("vs_text");
    pipeDesc.vertex.bufferCount = 1;
    pipeDesc.vertex.buffers = &bufLayout;
    pipeDesc.primitive.topology = WGPUPrimitiveTopology.triangleList;
    pipeDesc.depthStencil = &depthState;
    pipeDesc.fragment = &fragState;

    result.pipeline = wgpuDeviceCreateRenderPipeline(device, &pipeDesc);
    if (result.pipeline is null) {
        fatal("Failed to create text render pipeline");
    }

    info("Text render pipeline created");
    return result;
}

/// Frame uniform size for textured PBR pipeline (viewProj + lightVP + lightDir/bias + cameraPos).
enum FRAME_UNIFORMS_SIZE = 160;
/// MaterialParams UBO size (baseColor + metallic/roughness/flags).
enum MATERIAL_PARAMS_SIZE = 32;

/// Textured 3D instanced PBR pipeline.
///   Buffer 0 (per-vertex): position + normal + uv, stride=32.
///   Buffer 1 (per-instance): model matrix + tint, stride=80.
///   @group(0) Frame+shadow, @group(1) Material, @group(2) IBL.
Pipeline3D createTexturedPipeline3D(WGPUDevice device, WGPUTextureFormat surfaceFormat) @trusted {
    Pipeline3D result;

    result.shaderModule = createShaderModule(device, textured3dShaderSource.ptr);
    if (result.shaderModule is null) {
        fatal("Failed to create textured 3D shader module");
    }

    // --- Group 0: Frame + shadow ---
    WGPUBindGroupLayoutEntry[3] frameEntries;
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
    frameEntries[2].texture.viewDimension = WGPUTextureViewDimension.dim2D;

    WGPUBindGroupLayoutDescriptor frameBglDesc;
    frameBglDesc.entryCount = 3;
    frameBglDesc.entries = frameEntries.ptr;
    result.frameBindGroupLayout = wgpuDeviceCreateBindGroupLayout(device, &frameBglDesc);

    // --- Group 1: Material ---
    WGPUBindGroupLayoutEntry[7] matEntries;
    matEntries[0].binding = 0;
    matEntries[0].visibility = WGPUShaderStage.fragment;
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

    WGPUBindGroupLayoutDescriptor matBglDesc;
    matBglDesc.entryCount = 7;
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

    WGPUVertexAttribute[3] vertexAttrs = [
        { format: WGPUVertexFormat.float32x3, offset: 0,  shaderLocation: 0 },
        { format: WGPUVertexFormat.float32x3, offset: 12, shaderLocation: 1 },
        { format: WGPUVertexFormat.float32x2, offset: 24, shaderLocation: 2 },
    ];
    WGPUVertexAttribute[5] instanceAttrs = [
        { format: WGPUVertexFormat.float32x4, offset: 0,  shaderLocation: 3 },
        { format: WGPUVertexFormat.float32x4, offset: 16, shaderLocation: 4 },
        { format: WGPUVertexFormat.float32x4, offset: 32, shaderLocation: 5 },
        { format: WGPUVertexFormat.float32x4, offset: 48, shaderLocation: 6 },
        { format: WGPUVertexFormat.float32x4, offset: 64, shaderLocation: 7 },
    ];
    WGPUVertexBufferLayout[2] bufferLayouts = [
        {
            arrayStride: 32,
            stepMode: WGPUVertexStepMode.vertex,
            attributeCount: 3,
            attributes: vertexAttrs.ptr,
        },
        {
            arrayStride: 80,
            stepMode: WGPUVertexStepMode.instance_,
            attributeCount: 5,
            attributes: instanceAttrs.ptr,
        },
    ];

    WGPUColorTargetState colorTarget;
    colorTarget.format = surfaceFormat;
    colorTarget.writeMask = WGPUColorWriteMask.all;

    WGPUFragmentState fragState;
    fragState.module_ = result.shaderModule;
    fragState.entryPoint = wgpuStringView("fs_main");
    fragState.targetCount = 1;
    fragState.targets = &colorTarget;

    WGPUDepthStencilState depthState;
    depthState.format = WGPUTextureFormat.depth24Plus;
    depthState.depthWriteEnabled = WGPUOptionalBool.true_;
    depthState.depthCompare = WGPUCompareFunction.less;

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
        fatal("Failed to create textured 3D render pipeline");
    }

    info("Textured 3D PBR pipeline created (frame + material + IBL)");
    return result;
}
