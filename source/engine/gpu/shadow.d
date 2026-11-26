/// Shadow-mapping resources: depth texture + comparison sampler + a
/// depth-only render pipeline that reuses the textured 3D vertex layout
/// (TexVert buffer 0 + InstanceData buffer 1).
///
/// Supports:
///   - Directional: ortho 2D depth map (PCF) — `ShadowMap`
///   - Point: depth cubemap (6 faces) — `PointShadowMap`
///   - Spot: perspective 2D depth map (PCF) — `SpotShadowMap` (alias of ShadowMap)
///
/// Budget constants live in `engine.scene.light` (`MAX_*_SHADOW_CASTERS`,
/// `*_SHADOW_RESOLUTION`). Defaults here match those values.
///
/// Typical flow (one directional light):
///
///   auto shadow = ShadowMap.create(gpu, 2048);
///   auto pipe   = createShadowPipeline(device);
///   auto lightBuf = createUniformBuffer(device, 64);
///   auto lightBg  = createUniformBindGroup(device, pipe.bindGroupLayout, lightBuf, 64);
///
///   // Each frame, BEFORE the main color pass:
///   // direction = surface→light (same vector as N·L shading).
///   immutable lightVP = directionalLightVP(
///       Vec3(0.4, 1.0, 0.3), Vec3(0,0,0), 20.0f);
///   updateBuffer(queue, lightBuf, lightVP.m[]);
///   auto shadowEnc = wgpuDeviceCreateCommandEncoder(device, &encDesc);
///   auto shadowPass = beginShadowPass(shadowEnc, shadow);
///   // Bind pipeline + lightBg, then draw all shadow-casting meshes.
///   endShadowPass(shadowPass);
///
///   // Then run the main color pass, calling Scene3DTextured.setLighting
///   // with `shadow.depthView` and `shadow.comparisonSampler` via ShadowMap.
module engine.gpu.shadow;

import std.math : abs, PI;

import bindings.wgpu;
import engine.core.log;
import engine.gpu.context : GpuContext;
import engine.gpu.shader  : createShaderModule;
import engine.gpu.pipeline : FRAME_UNIFORMS_SIZE;
import engine.gpu.shaders : shadowDepthMaskShaderSource, shadowDepthShaderSource,
    shadowDepthSkinnedMaskShaderSource, shadowDepthSkinnedShaderSource;
import engine.graphics.texmesh : ShadowLodDraw, TexMesh;
import engine.math.mat    : Mat4;
import engine.math.vec    : Vec3;

@safe:

private immutable string kShadowDepthSkinnedWgsl = shadowDepthSkinnedShaderSource;
private immutable string kShadowDepthMaskWgsl = shadowDepthMaskShaderSource;
private immutable string kShadowDepthSkinnedMaskWgsl = shadowDepthSkinnedMaskShaderSource;

/// Match `engine.scene.light.POINT_SHADOW_RESOLUTION`.
enum uint DEFAULT_POINT_SHADOW_RESOLUTION = 512;
/// Match `engine.scene.light.SPOT_SHADOW_RESOLUTION`.
enum uint DEFAULT_SPOT_SHADOW_RESOLUTION = 1024;
/// Match `engine.scene.light.LIGHT_SHADOW_NEAR`.
enum float DEFAULT_SHADOW_NEAR = 0.1f;

/// Square depth-only texture usable as both a render target (for the depth
/// pass) and a texture binding (for sampling in the main pass).
struct ShadowMap {
    /// Maximum array layers (directional cascades) of one shadow map.
    enum uint MAX_LAYERS = 4;

    uint resolution;
    /// Array layers: 1 for spot / fixed directional maps, N for cascades.
    uint layers = 1;
    WGPUTexture     depthTexture;
    /// 2D view of layer 0 — render target for single-layer maps and the
    /// binding used by spot shadows.
    WGPUTextureView depthView;
    /// `dim2DArray` view of every layer — the directional shadow binding.
    WGPUTextureView arrayView;
    /// Per-layer 2D render views (`layerViews[0]` aliases `depthView`).
    WGPUTextureView[MAX_LAYERS] layerViews;
    WGPUSampler     comparisonSampler;

    @disable this(this);

    static ShadowMap create(ref GpuContext gpu, uint resolution = 2048, uint layers = 1) @trusted {
        return createForDevice(gpu.getDevice(), resolution, layers);
    }

    package(engine) static ShadowMap createForDevice(WGPUDevice device, uint resolution = 2048,
                                                     uint layers = 1) @trusted {
        ShadowMap s;
        s.resolution = resolution;
        if (layers < 1) layers = 1;
        if (layers > MAX_LAYERS) layers = MAX_LAYERS;
        s.layers = layers;

        WGPUTextureDescriptor td;
        td.usage     = WGPUTextureUsage.renderAttachment | WGPUTextureUsage.textureBinding;
        td.dimension = WGPUTextureDimension.dim2D;
        td.size      = WGPUExtent3D(resolution, resolution, layers);
        td.format    = WGPUTextureFormat.depth32Float;
        s.depthTexture = wgpuDeviceCreateTexture(device, &td);
        if (s.depthTexture is null) fatal("Shadow map texture creation failed");

        foreach (l; 0 .. layers) {
            WGPUTextureViewDescriptor vd;
            vd.format          = WGPUTextureFormat.depth32Float;
            vd.dimension       = WGPUTextureViewDimension.dim2D;
            vd.aspect          = WGPUTextureAspect.depthOnly;
            vd.baseArrayLayer  = l;
            vd.arrayLayerCount = 1;
            s.layerViews[l] = wgpuTextureCreateView(s.depthTexture, &vd);
        }
        s.depthView = s.layerViews[0];

        WGPUTextureViewDescriptor avd;
        avd.format          = WGPUTextureFormat.depth32Float;
        avd.dimension       = WGPUTextureViewDimension.dim2DArray;
        avd.aspect          = WGPUTextureAspect.depthOnly;
        avd.baseArrayLayer  = 0;
        avd.arrayLayerCount = layers;
        s.arrayView = wgpuTextureCreateView(s.depthTexture, &avd);

        WGPUSamplerDescriptor sd;
        sd.addressModeU = WGPUAddressMode.clampToEdge;
        sd.addressModeV = WGPUAddressMode.clampToEdge;
        sd.addressModeW = WGPUAddressMode.clampToEdge;
        sd.magFilter    = WGPUFilterMode.linear;
        sd.minFilter    = WGPUFilterMode.linear;
        sd.mipmapFilter = WGPUMipmapFilterMode.nearest;
        sd.compare      = WGPUCompareFunction.lessEqual;
        sd.lodMinClamp  = 0.0f;
        sd.lodMaxClamp  = 1.0f;
        sd.maxAnisotropy = 1;
        s.comparisonSampler = wgpuDeviceCreateSampler(device, &sd);

        info("Shadow map created: ", resolution, "×", resolution, "×", layers, " depth32Float");
        return s;
    }

    void destroy() @trusted nothrow @nogc {
        if (comparisonSampler !is null) { wgpuSamplerRelease(comparisonSampler); comparisonSampler = null; }
        if (arrayView !is null)         { wgpuTextureViewRelease(arrayView); arrayView = null; }
        foreach (ref v; layerViews) {
            if (v !is null) { wgpuTextureViewRelease(v); v = null; }
        }
        depthView = null;
        if (depthTexture !is null)      { wgpuTextureRelease(depthTexture); depthTexture = null; }
    }
}

/// Depth-only pipeline, compatible with TexMesh geometry + InstanceData
/// per-instance buffer. Uses one uniform (binding 0): the light's VP matrix.
struct ShadowPipeline {
    WGPURenderPipeline  pipeline;
    /// Same depth shader, vertex stride 48 (`TexTanVert`).
    WGPURenderPipeline  pipeline48;
    WGPUBindGroupLayout bindGroupLayout;
    WGPUPipelineLayout  pipelineLayout;
    WGPUShaderModule    shaderModule;

    @disable this(this);

    void release() nothrow @nogc @trusted {
        if (pipeline48 !is null)      { wgpuRenderPipelineRelease(pipeline48); pipeline48 = null; }
        if (pipeline !is null)        { wgpuRenderPipelineRelease(pipeline); pipeline = null; }
        if (pipelineLayout !is null)  { wgpuPipelineLayoutRelease(pipelineLayout); pipelineLayout = null; }
        if (bindGroupLayout !is null) { wgpuBindGroupLayoutRelease(bindGroupLayout); bindGroupLayout = null; }
        if (shaderModule !is null)    { wgpuShaderModuleRelease(shaderModule); shaderModule = null; }
    }
}

ShadowPipeline createShadowPipeline(WGPUDevice device) @trusted {
    ShadowPipeline r;
    r.shaderModule = createShaderModule(device, shadowDepthShaderSource);
    if (r.shaderModule is null) fatal("Shadow depth shader compile failed");

    WGPUBindGroupLayoutEntry bgle;
    bgle.binding = 0;
    bgle.visibility = WGPUShaderStage.vertex;
    bgle.buffer.type = WGPUBufferBindingType.uniform;
    bgle.buffer.minBindingSize = 64;

    WGPUBindGroupLayoutDescriptor bglDesc;
    bglDesc.entryCount = 1;
    bglDesc.entries = &bgle;
    r.bindGroupLayout = wgpuDeviceCreateBindGroupLayout(device, &bglDesc);

    WGPUPipelineLayoutDescriptor plDesc;
    plDesc.bindGroupLayoutCount = 1;
    plDesc.bindGroupLayouts = &r.bindGroupLayout;
    r.pipelineLayout = wgpuDeviceCreatePipelineLayout(device, &plDesc);

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
        { arrayStride: 32, stepMode: WGPUVertexStepMode.vertex,
          attributeCount: 3, attributes: vertexAttrs.ptr }, // TexVert. M8 selects 48 for TexTanVert.
        { arrayStride: 80, stepMode: WGPUVertexStepMode.instance_,
          attributeCount: 5, attributes: instanceAttrs.ptr },
    ];

    WGPUDepthStencilState depthState;
    depthState.format            = WGPUTextureFormat.depth32Float;
    depthState.depthWriteEnabled = WGPUOptionalBool.true_;
    depthState.depthCompare      = WGPUCompareFunction.less;
    // Caster-side slope bias fights acne so receiver bias can stay small
    // (large constant receiver bias caused contact shadows to detach).
    depthState.depthBias = 1;
    depthState.depthBiasSlopeScale = 1.75f;
    depthState.depthBiasClamp = 0.0f;

    WGPURenderPipelineDescriptor pd;
    pd.layout = r.pipelineLayout;
    pd.vertex.module_ = r.shaderModule;
    pd.vertex.entryPoint = wgpuStringView("vs_main");
    pd.vertex.bufferCount = 2;
    pd.vertex.buffers = bufferLayouts.ptr;
    pd.primitive.topology = WGPUPrimitiveTopology.triangleList;
    pd.primitive.frontFace = WGPUFrontFace.ccw;
    // Back-face cull: front faces sit at the lit silhouette → tighter contact.
    // Slope depthBias above covers acne that front-cull used to hide.
    pd.primitive.cullMode = WGPUCullMode.back;
    pd.depthStencil = &depthState;
    // No fragment state → depth-only.

    r.pipeline = wgpuDeviceCreateRenderPipeline(device, &pd);
    if (r.pipeline is null) fatal("Shadow pipeline creation failed");
    WGPUVertexBufferLayout[2] wideLayouts = bufferLayouts;
    wideLayouts[0].arrayStride = 48;
    pd.vertex.buffers = wideLayouts.ptr;
    r.pipeline48 = wgpuDeviceCreateRenderPipeline(device, &pd);
    if (r.pipeline48 is null) fatal("Shadow pipeline (stride 48) creation failed");

    info("Shadow depth-only pipeline created");
    return r;
}

/// Compute an orthographic light view-projection matrix for a directional
/// light. `direction` is the same vector used for shading (surface → light,
/// i.e. the `L` in N·L). The light camera sits along that axis looking back
/// at `sceneCenter`, framing a sphere of radius `sceneRadius`.
Mat4 directionalLightVP(Vec3 direction, Vec3 sceneCenter, float sceneRadius) {
    immutable d = direction.normalized();
    // Place the light camera on the light side of the scene (toward +d).
    immutable eye = sceneCenter + d * (sceneRadius * 2.0f);
    // Avoid a degenerate lookAt when the light is nearly parallel to +Y.
    immutable up = abs(d.y) > 0.9f ? Vec3(0, 0, 1) : Vec3(0, 1, 0);
    immutable view = Mat4.lookAt(eye, sceneCenter, up);
    immutable proj = Mat4.ortho(-sceneRadius, sceneRadius,
                                -sceneRadius, sceneRadius,
                                 0.1f, sceneRadius * 4.0f);
    return proj * view;
}

/// Begin a depth-only render pass writing into an arbitrary depth view
/// (2D shadow map or a single cubemap face).
WGPURenderPassEncoder beginShadowPassView(WGPUCommandEncoder encoder,
                                          WGPUTextureView depthView,
                                          bool clear = true) nothrow @nogc @trusted {
    WGPURenderPassDepthStencilAttachment depthAtt;
    depthAtt.view            = depthView;
    depthAtt.depthLoadOp     = clear ? WGPULoadOp.clear : WGPULoadOp.load;
    depthAtt.depthStoreOp    = WGPUStoreOp.store;
    depthAtt.depthClearValue = 1.0f;

    WGPURenderPassDescriptor pd;
    pd.colorAttachmentCount     = 0;
    pd.colorAttachments         = null;
    pd.depthStencilAttachment   = &depthAtt;

    return wgpuCommandEncoderBeginRenderPass(encoder, &pd);
}

/// Begin a depth-only render pass writing into the shadow map.
/// Returns the pass encoder — caller must `endShadowPass` after draws.
/// Pass `clear=false` to accumulate casters across multiple submit/draw calls.
WGPURenderPassEncoder beginShadowPass(WGPUCommandEncoder encoder,
                                       ref ShadowMap shadow,
                                       bool clear = true) nothrow @nogc @trusted {
    return beginShadowPassView(encoder, shadow.depthView, clear);
}

/// End and release a shadow pass encoder.
void endShadowPass(WGPURenderPassEncoder pass) @trusted nothrow @nogc {
    wgpuRenderPassEncoderEnd(pass);
    wgpuRenderPassEncoderRelease(pass);
}

/// Submit a depth-only shadow pass that draws `instanceCount` instances of `mesh`.
/// Uses a temporary command encoder and submits immediately (before the color pass).
/// Set `clear` to false when chaining multiple mesh draws into the same map.
void submitShadowPass(ref GpuContext gpu, ref ShadowMap shadow, ref ShadowPipeline pipe,
                      WGPUBindGroup lightBg, WGPUBuffer lightBuf, Mat4 lightVP,
                      ref TexMesh mesh, WGPUBuffer instanceBuf, uint instanceCount,
                      bool clear = true, ubyte colorLod = ubyte.max) @trusted {
    import engine.gpu.buffer : updateBuffer;

    updateBuffer(gpu.getQueue(), lightBuf, lightVP.m[]);

    WGPUCommandEncoderDescriptor encDesc;
    auto enc = wgpuDeviceCreateCommandEncoder(gpu.getDevice(), &encDesc);
    auto pass = beginShadowPass(enc, shadow, clear);

    wgpuRenderPassEncoderSetPipeline(pass, shadowPipelineFor(pipe, mesh.vertexStride));
    wgpuRenderPassEncoderSetBindGroup(pass, 0, lightBg, 0, null);
    wgpuRenderPassEncoderSetVertexBuffer(pass, 0, mesh.vertexBuffer, 0, mesh.vertexBufSize);
    wgpuRenderPassEncoderSetVertexBuffer(pass, 1, instanceBuf, 0, instanceCount * 80);
    ShadowLodDraw lod = mesh.shadowLodDraw(colorLod);
    WGPUBuffer indexBuf = lod.useLodRange ? mesh.indexBuffer : mesh.shadowDrawBuffer();
    ulong indexBytes = lod.useLodRange ? mesh.indexBufSize : mesh.shadowDrawBytes();
    wgpuRenderPassEncoderSetIndexBuffer(pass, indexBuf, mesh.indexFormat, 0, indexBytes);
    wgpuRenderPassEncoderDrawIndexed(pass, lod.count, instanceCount, lod.first, 0, 0);

    endShadowPass(pass);

    WGPUCommandBufferDescriptor cbDesc;
    auto cmd = wgpuCommandEncoderFinish(enc, &cbDesc);
    wgpuCommandEncoderRelease(enc);
    wgpuQueueSubmit(gpu.getQueue(), 1, &cmd);
    wgpuCommandBufferRelease(cmd);
}

private WGPURenderPipeline shadowPipelineFor(ref ShadowPipeline pipe, uint vertexStride) pure nothrow @nogc {
    return vertexStride == 48 ? pipe.pipeline48 : pipe.pipeline;
}

/// Depth-only pipeline for `Scene3DTextured` batches (`TexInstanceData`, stride 96),
/// supporting dynamic uniform offsets for multi-pass shadow encoding and
/// back-face / double-sided culling.
struct TexShadowPipeline {
    WGPURenderPipeline  pipe32Back;
    WGPURenderPipeline  pipe48Back;
    WGPURenderPipeline  pipe32None;
    WGPURenderPipeline  pipe48None;
    WGPURenderPipeline  pipeSkinnedBack;
    WGPURenderPipeline  pipeSkinnedNone;
    WGPUBindGroupLayout bindGroupLayout;
    WGPUPipelineLayout  pipelineLayout;
    WGPUPipelineLayout  skinnedPipelineLayout;
    WGPUShaderModule    shaderModule;
    WGPUShaderModule    skinnedShaderModule;
    /// Group 0 of displaced-surface shadow pipelines: frame uniforms
    /// (binding 0) + light view-projection with dynamic offset (binding 20).
    WGPUBindGroupLayout surfaceBindGroupLayout;
    /// Group 0 = `surfaceBindGroupLayout`, group 1 = the material layout
    /// (`surfaceParams` at binding 7).
    WGPUPipelineLayout  surfacePipelineLayout;
    /// Group 1 of batched displaced shadow pipelines (`vs_shadow_table`): the
    /// material surface parameter chunk (binding 30) and the slot of each
    /// instance (binding 31), both read-only storage.
    WGPUBindGroupLayout tableBindGroupLayout;
    /// Group 0 = `surfaceBindGroupLayout`, group 1 = `tableBindGroupLayout`.
    WGPUPipelineLayout  tablePipelineLayout;
    /// Alpha-masked casters, built on first use. Index: vertex layout
    /// (0 = stride 32, 1 = stride 48, 2 = skinned) * 2 + (doubleSided ? 1 : 0).
    private WGPURenderPipeline[6] maskPipes;
    private WGPUShaderModule maskModule, skinnedMaskModule;
    private WGPUPipelineLayout maskLayout, skinnedMaskLayout;

    @disable this(this);

    /// Pipeline for an alpha-masked static caster (group 1 = material), or null.
    WGPURenderPipeline maskedPipelineFor(WGPUDevice device, uint vertexStride, bool doubleSided) nothrow @nogc @trusted {
        if (maskLayout is null) return null;
        immutable idx = (vertexStride == 48 ? 2 : 0) + (doubleSided ? 1 : 0);
        if (maskPipes[idx] is null) {
            if (maskModule is null) maskModule = createShaderModule(device, kShadowDepthMaskWgsl, "shadow_depth_mask");
            WGPUVertexAttribute[3] attrs = [
                { format: WGPUVertexFormat.float32x3, offset: 0,  shaderLocation: 0 },
                { format: WGPUVertexFormat.float32x3, offset: 12, shaderLocation: 1 },
                { format: WGPUVertexFormat.float32x2, offset: 24, shaderLocation: 2 },
            ];
            maskPipes[idx] = createTexShadowDrawPipeline(device, maskLayout, maskModule,
                vertexStride == 48 ? 48 : 32, attrs[], doubleSided, true);
        }
        return maskPipes[idx];
    }

    /// Pipeline for an alpha-masked skinned caster (group 1 = palette, group 2 = material), or null.
    WGPURenderPipeline maskedSkinnedPipelineFor(WGPUDevice device, bool doubleSided) nothrow @nogc @trusted {
        if (skinnedMaskLayout is null) return null;
        immutable idx = 4 + (doubleSided ? 1 : 0);
        if (maskPipes[idx] is null) {
            if (skinnedMaskModule is null)
                skinnedMaskModule = createShaderModule(device, kShadowDepthSkinnedMaskWgsl, "shadow_depth_skinned_mask");
            WGPUVertexAttribute[5] attrs = [
                { format: WGPUVertexFormat.float32x3, offset: 0,  shaderLocation: 0 },
                { format: WGPUVertexFormat.float32x3, offset: 12, shaderLocation: 1 },
                { format: WGPUVertexFormat.float32x2, offset: 24, shaderLocation: 2 },
                { format: WGPUVertexFormat.uint32x4,  offset: 48, shaderLocation: 10 },
                { format: WGPUVertexFormat.float32x4, offset: 64, shaderLocation: 11 },
            ];
            maskPipes[idx] = createTexShadowDrawPipeline(device, skinnedMaskLayout, skinnedMaskModule,
                80, attrs[], doubleSided, true);
        }
        return maskPipes[idx];
    }

    WGPURenderPipeline pipelineFor(uint vertexStride, bool doubleSided) pure nothrow @nogc {
        if (doubleSided)
            return vertexStride == 48 ? pipe48None : pipe32None;
        return vertexStride == 48 ? pipe48Back : pipe32Back;
    }

    WGPURenderPipeline skinnedPipelineFor(bool doubleSided) pure nothrow @nogc {
        return doubleSided ? pipeSkinnedNone : pipeSkinnedBack;
    }

    void release() nothrow @nogc @trusted {
        void rel(ref WGPURenderPipeline p) {
            if (p !is null) { wgpuRenderPipelineRelease(p); p = null; }
        }
        rel(pipe32Back); rel(pipe48Back); rel(pipe32None); rel(pipe48None);
        rel(pipeSkinnedBack); rel(pipeSkinnedNone);
        foreach (ref p; maskPipes) rel(p);
        if (maskModule !is null)        { wgpuShaderModuleRelease(maskModule); maskModule = null; }
        if (skinnedMaskModule !is null) { wgpuShaderModuleRelease(skinnedMaskModule); skinnedMaskModule = null; }
        if (maskLayout !is null)        { wgpuPipelineLayoutRelease(maskLayout); maskLayout = null; }
        if (skinnedMaskLayout !is null) { wgpuPipelineLayoutRelease(skinnedMaskLayout); skinnedMaskLayout = null; }
        if (tablePipelineLayout !is null)    { wgpuPipelineLayoutRelease(tablePipelineLayout); tablePipelineLayout = null; }
        if (tableBindGroupLayout !is null)   { wgpuBindGroupLayoutRelease(tableBindGroupLayout); tableBindGroupLayout = null; }
        if (surfacePipelineLayout !is null)  { wgpuPipelineLayoutRelease(surfacePipelineLayout); surfacePipelineLayout = null; }
        if (surfaceBindGroupLayout !is null) { wgpuBindGroupLayoutRelease(surfaceBindGroupLayout); surfaceBindGroupLayout = null; }
        if (skinnedPipelineLayout !is null) { wgpuPipelineLayoutRelease(skinnedPipelineLayout); skinnedPipelineLayout = null; }
        if (pipelineLayout !is null)        { wgpuPipelineLayoutRelease(pipelineLayout); pipelineLayout = null; }
        if (bindGroupLayout !is null)       { wgpuBindGroupLayoutRelease(bindGroupLayout); bindGroupLayout = null; }
        if (skinnedShaderModule !is null)   { wgpuShaderModuleRelease(skinnedShaderModule); skinnedShaderModule = null; }
        if (shaderModule !is null)          { wgpuShaderModuleRelease(shaderModule); shaderModule = null; }
    }
}

/// Depth-only pipeline for `TexInstanceData` instances. `mask` adds the
/// `fs_mask` fragment stage. Returns null on failure.
private WGPURenderPipeline createTexShadowDrawPipeline(
    WGPUDevice device, WGPUPipelineLayout layout, WGPUShaderModule mod, uint vStride,
    scope const(WGPUVertexAttribute)[] vAttrs, bool doubleSided, bool mask) nothrow @nogc @trusted
{
    if (layout is null || mod is null) return null;
    WGPUVertexAttribute[5] instanceAttrs = [
        { format: WGPUVertexFormat.float32x4, offset: 0,  shaderLocation: 3 },
        { format: WGPUVertexFormat.float32x4, offset: 16, shaderLocation: 4 },
        { format: WGPUVertexFormat.float32x4, offset: 32, shaderLocation: 5 },
        { format: WGPUVertexFormat.float32x4, offset: 48, shaderLocation: 6 },
        { format: WGPUVertexFormat.float32x4, offset: 64, shaderLocation: 7 },
    ];
    WGPUVertexBufferLayout[2] bufferLayouts = [
        { arrayStride: vStride, stepMode: WGPUVertexStepMode.vertex,
          attributeCount: vAttrs.length, attributes: vAttrs.ptr },
        { arrayStride: 96, stepMode: WGPUVertexStepMode.instance_,
          attributeCount: 5, attributes: instanceAttrs.ptr },
    ];
    WGPUDepthStencilState depthState;
    depthState.format            = WGPUTextureFormat.depth32Float;
    depthState.depthWriteEnabled = WGPUOptionalBool.true_;
    depthState.depthCompare      = WGPUCompareFunction.less;
    depthState.depthBias         = 1;
    depthState.depthBiasSlopeScale = 1.75f;
    depthState.depthBiasClamp    = 0.0f;

    WGPUFragmentState fs;
    fs.module_ = mod;
    fs.entryPoint = wgpuStringView("fs_mask");

    WGPURenderPipelineDescriptor pd;
    pd.layout = layout;
    pd.vertex.module_ = mod;
    pd.vertex.entryPoint = wgpuStringView("vs_main");
    pd.vertex.bufferCount = 2;
    pd.vertex.buffers = bufferLayouts.ptr;
    pd.primitive.topology = WGPUPrimitiveTopology.triangleList;
    pd.primitive.frontFace = WGPUFrontFace.ccw;
    pd.primitive.cullMode = doubleSided ? WGPUCullMode.none : WGPUCullMode.back;
    pd.depthStencil = &depthState;
    if (mask) pd.fragment = &fs;
    return wgpuDeviceCreateRenderPipeline(device, &pd);
}

TexShadowPipeline createTexShadowPipeline(WGPUDevice device, WGPUBindGroupLayout skinBindGroupLayout = null,
                                          WGPUBindGroupLayout materialBindGroupLayout = null) @trusted {
    TexShadowPipeline r;
    r.shaderModule = createShaderModule(device, shadowDepthShaderSource);
    if (r.shaderModule is null) fatal("Tex shadow depth shader compile failed");

    WGPUBindGroupLayoutEntry bgle;
    bgle.binding = 0;
    bgle.visibility = WGPUShaderStage.vertex;
    bgle.buffer.type = WGPUBufferBindingType.uniform;
    bgle.buffer.hasDynamicOffset = WGPU_TRUE;
    bgle.buffer.minBindingSize = 64;

    WGPUBindGroupLayoutDescriptor bglDesc;
    bglDesc.entryCount = 1;
    bglDesc.entries = &bgle;
    r.bindGroupLayout = wgpuDeviceCreateBindGroupLayout(device, &bglDesc);

    WGPUPipelineLayoutDescriptor plDesc;
    plDesc.bindGroupLayoutCount = 1;
    plDesc.bindGroupLayouts = &r.bindGroupLayout;
    r.pipelineLayout = wgpuDeviceCreatePipelineLayout(device, &plDesc);

    WGPUVertexAttribute[3] vertexAttrs = [
        { format: WGPUVertexFormat.float32x3, offset: 0,  shaderLocation: 0 },
        { format: WGPUVertexFormat.float32x3, offset: 12, shaderLocation: 1 },
        { format: WGPUVertexFormat.float32x2, offset: 24, shaderLocation: 2 },
    ];
    WGPURenderPipeline buildPipe(WGPUPipelineLayout layout, WGPUShaderModule mod,
                                 uint vStride, const(WGPUVertexAttribute)* vAttrs, uint vAttrCount,
                                 bool doubleSided) {
        auto pipe = createTexShadowDrawPipeline(device, layout, mod, vStride, vAttrs[0 .. vAttrCount],
                                                doubleSided, false);
        if (pipe is null) fatal("Tex shadow pipeline creation failed");
        return pipe;
    }

    r.pipe32Back = buildPipe(r.pipelineLayout, r.shaderModule, 32, vertexAttrs.ptr, 3, false);
    r.pipe48Back = buildPipe(r.pipelineLayout, r.shaderModule, 48, vertexAttrs.ptr, 3, false);
    r.pipe32None = buildPipe(r.pipelineLayout, r.shaderModule, 32, vertexAttrs.ptr, 3, true);
    r.pipe48None = buildPipe(r.pipelineLayout, r.shaderModule, 48, vertexAttrs.ptr, 3, true);

    if (skinBindGroupLayout !is null) {
        r.skinnedShaderModule = createShaderModule(device, kShadowDepthSkinnedWgsl, "shadow_depth_skinned");
        if (r.skinnedShaderModule is null) fatal("Skinned shadow depth shader compile failed");
        WGPUBindGroupLayout[2] skinLayouts = [r.bindGroupLayout, skinBindGroupLayout];
        WGPUPipelineLayoutDescriptor splDesc;
        splDesc.bindGroupLayoutCount = 2;
        splDesc.bindGroupLayouts = skinLayouts.ptr;
        r.skinnedPipelineLayout = wgpuDeviceCreatePipelineLayout(device, &splDesc);

        WGPUVertexAttribute[5] skinnedAttrs = [
            { format: WGPUVertexFormat.float32x3, offset: 0,  shaderLocation: 0 },
            { format: WGPUVertexFormat.float32x3, offset: 12, shaderLocation: 1 },
            { format: WGPUVertexFormat.float32x2, offset: 24, shaderLocation: 2 },
            { format: WGPUVertexFormat.uint32x4,  offset: 48, shaderLocation: 10 },
            { format: WGPUVertexFormat.float32x4, offset: 64, shaderLocation: 11 },
        ];
        r.pipeSkinnedBack = buildPipe(r.skinnedPipelineLayout, r.skinnedShaderModule, 80, skinnedAttrs.ptr, 5, false);
        r.pipeSkinnedNone = buildPipe(r.skinnedPipelineLayout, r.skinnedShaderModule, 80, skinnedAttrs.ptr, 5, true);
    }

    if (materialBindGroupLayout !is null) {
        WGPUBindGroupLayoutEntry[2] se;
        se[0].binding = 0;
        se[0].visibility = WGPUShaderStage.vertex;
        se[0].buffer.type = WGPUBufferBindingType.uniform;
        se[0].buffer.minBindingSize = FRAME_UNIFORMS_SIZE;
        se[1].binding = SURFACE_SHADOW_LIGHT_BINDING;
        se[1].visibility = WGPUShaderStage.vertex;
        se[1].buffer.type = WGPUBufferBindingType.uniform;
        se[1].buffer.hasDynamicOffset = WGPU_TRUE;
        se[1].buffer.minBindingSize = 64;
        WGPUBindGroupLayoutDescriptor sbd;
        sbd.entryCount = 2;
        sbd.entries = se.ptr;
        r.surfaceBindGroupLayout = wgpuDeviceCreateBindGroupLayout(device, &sbd);
        WGPUBindGroupLayout[2] sl = [r.surfaceBindGroupLayout, materialBindGroupLayout];
        WGPUPipelineLayoutDescriptor spd;
        spd.bindGroupLayoutCount = 2;
        spd.bindGroupLayouts = sl.ptr;
        r.surfacePipelineLayout = wgpuDeviceCreatePipelineLayout(device, &spd);

        import engine.gpu.shaders : SHADOW_TABLE_INDEX_BINDING, SHADOW_TABLE_PARAMS_BINDING;
        import engine.graphics.surface_params : SURFACE_CHUNK_BYTES;
        WGPUBindGroupLayoutEntry[2] te;
        te[0].binding = SHADOW_TABLE_PARAMS_BINDING;
        te[0].visibility = WGPUShaderStage.vertex;
        te[0].buffer.type = WGPUBufferBindingType.readOnlyStorage;
        te[0].buffer.minBindingSize = SURFACE_CHUNK_BYTES;
        te[1].binding = SHADOW_TABLE_INDEX_BINDING;
        te[1].visibility = WGPUShaderStage.vertex;
        te[1].buffer.type = WGPUBufferBindingType.readOnlyStorage;
        te[1].buffer.minBindingSize = 4;
        WGPUBindGroupLayoutDescriptor tbd;
        tbd.entryCount = 2;
        tbd.entries = te.ptr;
        r.tableBindGroupLayout = wgpuDeviceCreateBindGroupLayout(device, &tbd);
        WGPUBindGroupLayout[2] tl = [r.surfaceBindGroupLayout, r.tableBindGroupLayout];
        WGPUPipelineLayoutDescriptor tpd;
        tpd.bindGroupLayoutCount = 2;
        tpd.bindGroupLayouts = tl.ptr;
        r.tablePipelineLayout = wgpuDeviceCreatePipelineLayout(device, &tpd);

        WGPUBindGroupLayout[3] ml = [r.bindGroupLayout, materialBindGroupLayout, null];
        WGPUPipelineLayoutDescriptor mpd;
        mpd.bindGroupLayoutCount = 2;
        mpd.bindGroupLayouts = ml.ptr;
        r.maskLayout = wgpuDeviceCreatePipelineLayout(device, &mpd);
        if (skinBindGroupLayout !is null) {
            ml = [r.bindGroupLayout, skinBindGroupLayout, materialBindGroupLayout];
            mpd.bindGroupLayoutCount = 3;
            r.skinnedMaskLayout = wgpuDeviceCreatePipelineLayout(device, &mpd);
        }
    }
    return r;
}

/// `@binding` of the light view-projection in the `vs_shadow` stage of composed surface shaders.
enum uint SURFACE_SHADOW_LIGHT_BINDING = 20;

/// Depth-only pipeline running the `vs_shadow` entry point of a composed
/// surface shader (`composeSurfaceShader`), so `displace` / `displaceEx` also
/// move the cast shadow. Reads instance data (model matrix at 3..6, `custom`
/// at location 9 from the same 96-byte instance stride, no extra bandwidth).
/// Returns null on failure. `vertexStride` is 32 (`TexVert`) or 48 (`TexTanVert`).
/// `mask` selects the alpha-masked entry points (`vs_shadow_mask` / `fs_shadow_mask`).
WGPURenderPipeline createSurfaceShadowPipeline(WGPUDevice device, WGPUPipelineLayout surfaceLayout,
                                               WGPUShaderModule surfaceModule, uint vertexStride,
                                               bool doubleSided, bool mask = false,
                                               bool table = false) nothrow @nogc @trusted {
    if (surfaceLayout is null || surfaceModule is null) return null;
    WGPUVertexAttribute[3] vertexAttrs = [
        { format: WGPUVertexFormat.float32x3, offset: 0,  shaderLocation: 0 },
        { format: WGPUVertexFormat.float32x3, offset: 12, shaderLocation: 1 },
        { format: WGPUVertexFormat.float32x2, offset: 24, shaderLocation: 2 },
    ];
    WGPUVertexAttribute[6] instanceAttrs = [
        { format: WGPUVertexFormat.float32x4, offset: 0,  shaderLocation: 3 },
        { format: WGPUVertexFormat.float32x4, offset: 16, shaderLocation: 4 },
        { format: WGPUVertexFormat.float32x4, offset: 32, shaderLocation: 5 },
        { format: WGPUVertexFormat.float32x4, offset: 48, shaderLocation: 6 },
        { format: WGPUVertexFormat.float32x4, offset: 80, shaderLocation: 9 },
        { format: WGPUVertexFormat.float32x4, offset: 64, shaderLocation: 7 }, // masked casters only
    ];
    WGPUVertexBufferLayout[2] bufferLayouts = [
        { arrayStride: vertexStride, stepMode: WGPUVertexStepMode.vertex,
          attributeCount: 3, attributes: vertexAttrs.ptr },
        { arrayStride: 96, stepMode: WGPUVertexStepMode.instance_,
          attributeCount: mask ? 6 : 5, attributes: instanceAttrs.ptr },
    ];
    WGPUDepthStencilState depthState;
    depthState.format            = WGPUTextureFormat.depth32Float;
    depthState.depthWriteEnabled = WGPUOptionalBool.true_;
    depthState.depthCompare      = WGPUCompareFunction.less;
    depthState.depthBias         = 1;
    depthState.depthBiasSlopeScale = 1.75f;
    depthState.depthBiasClamp    = 0.0f;

    WGPUFragmentState fs;
    fs.module_ = surfaceModule;
    fs.entryPoint = wgpuStringView("fs_shadow_mask");

    WGPURenderPipelineDescriptor pd;
    pd.layout = surfaceLayout;
    if (mask) pd.fragment = &fs;
    pd.vertex.module_ = surfaceModule;
    pd.vertex.entryPoint = wgpuStringView(table ? "vs_shadow_table" : mask ? "vs_shadow_mask" : "vs_shadow");
    pd.vertex.bufferCount = 2;
    pd.vertex.buffers = bufferLayouts.ptr;
    pd.primitive.topology = WGPUPrimitiveTopology.triangleList;
    pd.primitive.frontFace = WGPUFrontFace.ccw;
    pd.primitive.cullMode = doubleSided ? WGPUCullMode.none : WGPUCullMode.back;
    pd.depthStencil = &depthState;
    return wgpuDeviceCreateRenderPipeline(device, &pd);
}

// ---------------------------------------------------------------------------
// Point light — depth cubemap (6 faces)
// ---------------------------------------------------------------------------

/// Depth cubemap for one point light. Sample with `texture_depth_cube` +
/// comparison sampler; render each face via `faceViews[0..6]`.
struct PointShadowMap {
    uint resolution;
    float nearPlane = DEFAULT_SHADOW_NEAR;
    float farPlane = 25.0f;
    WGPUTexture     depthTexture;
    WGPUTextureView cubeView;       /// Full cube for sampling
    WGPUTextureView[6] faceViews;   /// Per-face 2D views for depth passes
    WGPUSampler     comparisonSampler;

    @disable this(this);

    static PointShadowMap create(ref GpuContext gpu,
                                 uint resolution = DEFAULT_POINT_SHADOW_RESOLUTION,
                                 float nearPlane = DEFAULT_SHADOW_NEAR,
                                 float farPlane = 25.0f) @trusted {
        return createForDevice(gpu.getDevice(), resolution, nearPlane, farPlane);
    }

    package(engine) static PointShadowMap createForDevice(
        WGPUDevice device,
        uint resolution = DEFAULT_POINT_SHADOW_RESOLUTION,
        float nearPlane = DEFAULT_SHADOW_NEAR,
        float farPlane = 25.0f) @trusted {
        PointShadowMap s;
        s.resolution = resolution;
        s.nearPlane = nearPlane;
        s.farPlane = farPlane;

        WGPUTextureDescriptor td;
        td.usage     = WGPUTextureUsage.renderAttachment | WGPUTextureUsage.textureBinding;
        td.dimension = WGPUTextureDimension.dim2D;
        td.size      = WGPUExtent3D(resolution, resolution, 6);
        td.format    = WGPUTextureFormat.depth32Float;
        s.depthTexture = wgpuDeviceCreateTexture(device, &td);
        if (s.depthTexture is null) fatal("Point shadow cubemap creation failed");

        WGPUTextureViewDescriptor cubeVd;
        cubeVd.format          = WGPUTextureFormat.depth32Float;
        cubeVd.dimension       = WGPUTextureViewDimension.cube;
        cubeVd.aspect          = WGPUTextureAspect.depthOnly;
        cubeVd.baseArrayLayer  = 0;
        cubeVd.arrayLayerCount = 6;
        s.cubeView = wgpuTextureCreateView(s.depthTexture, &cubeVd);

        foreach (face; 0 .. 6) {
            WGPUTextureViewDescriptor faceVd;
            faceVd.format          = WGPUTextureFormat.depth32Float;
            faceVd.dimension       = WGPUTextureViewDimension.dim2D;
            faceVd.aspect          = WGPUTextureAspect.depthOnly;
            faceVd.baseArrayLayer  = face;
            faceVd.arrayLayerCount = 1;
            s.faceViews[face] = wgpuTextureCreateView(s.depthTexture, &faceVd);
        }

        WGPUSamplerDescriptor sd;
        sd.addressModeU  = WGPUAddressMode.clampToEdge;
        sd.addressModeV  = WGPUAddressMode.clampToEdge;
        sd.addressModeW  = WGPUAddressMode.clampToEdge;
        sd.magFilter     = WGPUFilterMode.linear;
        sd.minFilter     = WGPUFilterMode.linear;
        sd.mipmapFilter  = WGPUMipmapFilterMode.nearest;
        sd.compare       = WGPUCompareFunction.lessEqual;
        sd.lodMinClamp   = 0.0f;
        sd.lodMaxClamp   = 1.0f;
        sd.maxAnisotropy = 1;
        s.comparisonSampler = wgpuDeviceCreateSampler(device, &sd);

        info("Point shadow cubemap created: ", resolution, "² × 6 depth32Float");
        return s;
    }

    void destroy() @trusted nothrow @nogc {
        if (comparisonSampler !is null) {
            wgpuSamplerRelease(comparisonSampler);
            comparisonSampler = null;
        }
        foreach (ref v; faceViews) {
            if (v !is null) { wgpuTextureViewRelease(v); v = null; }
        }
        if (cubeView !is null) { wgpuTextureViewRelease(cubeView); cubeView = null; }
        if (depthTexture !is null) { wgpuTextureRelease(depthTexture); depthTexture = null; }
    }
}

/// Face order matches WebGPU / Vulkan cubemap layer order:
/// +X, -X, +Y, -Y, +Z, -Z.
/// Six 90° perspective VPs for a point light at `lightPos`.
/// `farPlane` should match the light's attenuation `range`.
Mat4[6] pointLightFaceVPs(Vec3 lightPos, float nearPlane, float farPlane) {
    immutable Vec3[6] targets = [
        Vec3( 1,  0,  0),
        Vec3(-1,  0,  0),
        Vec3( 0,  1,  0),
        Vec3( 0, -1,  0),
        Vec3( 0,  0,  1),
        Vec3( 0,  0, -1),
    ];
    immutable Vec3[6] ups = [
        Vec3(0, -1,  0),
        Vec3(0, -1,  0),
        Vec3(0,  0,  1),
        Vec3(0,  0, -1),
        Vec3(0, -1,  0),
        Vec3(0, -1,  0),
    ];
    immutable proj = Mat4.perspective(PI * 0.5f, 1.0f, nearPlane, farPlane);
    Mat4[6] vps;
    foreach (i; 0 .. 6) {
        immutable view = Mat4.lookAt(lightPos, lightPos + targets[i], ups[i]);
        vps[i] = proj * view;
    }
    return vps;
}

/// Depth-pass one cubemap face. `clear` should be true on the first mesh for
/// that face; false when accumulating additional casters on the same face.
void submitPointShadowFace(ref GpuContext gpu, ref PointShadowMap shadow,
                           uint face, ref ShadowPipeline pipe,
                           WGPUBindGroup lightBg, WGPUBuffer lightBuf, Mat4 faceVP,
                           ref TexMesh mesh, WGPUBuffer instanceBuf, uint instanceCount,
                           bool clear = true, ubyte colorLod = ubyte.max) @trusted {
    import engine.gpu.buffer : updateBuffer;

    if (face >= 6) return;
    updateBuffer(gpu.getQueue(), lightBuf, faceVP.m[]);

    WGPUCommandEncoderDescriptor encDesc;
    auto enc = wgpuDeviceCreateCommandEncoder(gpu.getDevice(), &encDesc);
    auto pass = beginShadowPassView(enc, shadow.faceViews[face], clear);

    wgpuRenderPassEncoderSetPipeline(pass, shadowPipelineFor(pipe, mesh.vertexStride));
    wgpuRenderPassEncoderSetBindGroup(pass, 0, lightBg, 0, null);
    wgpuRenderPassEncoderSetVertexBuffer(pass, 0, mesh.vertexBuffer, 0, mesh.vertexBufSize);
    wgpuRenderPassEncoderSetVertexBuffer(pass, 1, instanceBuf, 0, instanceCount * 80);
    ShadowLodDraw lod = mesh.shadowLodDraw(colorLod);
    WGPUBuffer indexBuf = lod.useLodRange ? mesh.indexBuffer : mesh.shadowDrawBuffer();
    ulong indexBytes = lod.useLodRange ? mesh.indexBufSize : mesh.shadowDrawBytes();
    wgpuRenderPassEncoderSetIndexBuffer(pass, indexBuf, mesh.indexFormat, 0, indexBytes);
    wgpuRenderPassEncoderDrawIndexed(pass, lod.count, instanceCount, lod.first, 0, 0);

    endShadowPass(pass);

    WGPUCommandBufferDescriptor cbDesc;
    auto cmd = wgpuCommandEncoderFinish(enc, &cbDesc);
    wgpuCommandEncoderRelease(enc);
    wgpuQueueSubmit(gpu.getQueue(), 1, &cmd);
    wgpuCommandBufferRelease(cmd);
}

/// Render all 6 faces for `mesh` instances (clears each face first).
void submitPointShadowCubemap(ref GpuContext gpu, ref PointShadowMap shadow,
                              ref ShadowPipeline pipe,
                              WGPUBindGroup lightBg, WGPUBuffer lightBuf,
                              Vec3 lightPos,
                              ref TexMesh mesh, WGPUBuffer instanceBuf, uint instanceCount) @trusted {
    immutable vps = pointLightFaceVPs(lightPos, shadow.nearPlane, shadow.farPlane);
    foreach (face; 0 .. 6) {
        submitPointShadowFace(gpu, shadow, face, pipe, lightBg, lightBuf, vps[face],
                              mesh, instanceBuf, instanceCount, /*clear=*/true);
    }
}

// ---------------------------------------------------------------------------
// Spot light — perspective 2D depth map
// ---------------------------------------------------------------------------

/// Spot shadow map — same GPU layout as directional; use perspective VP.
alias SpotShadowMap = ShadowMap;

/// Perspective light VP for a spot. `direction` points along the cone axis
/// (light → scene). `fovY` should cover the outer cone (typically
/// `2 * outerConeDeg` in radians). `farPlane` ≈ light range.
Mat4 spotLightVP(Vec3 position, Vec3 direction, float fovY,
                 float nearPlane = DEFAULT_SHADOW_NEAR, float farPlane = 25.0f) {
    immutable d = direction.normalized();
    immutable up = abs(d.y) > 0.9f ? Vec3(0, 0, 1) : Vec3(0, 1, 0);
    immutable view = Mat4.lookAt(position, position + d, up);
    immutable proj = Mat4.perspective(fovY, 1.0f, nearPlane, farPlane);
    return proj * view;
}

/// Convenience: build spot VP from outer cone half-angle in degrees.
Mat4 spotLightVPFromCone(Vec3 position, Vec3 direction, float outerConeDeg,
                         float nearPlane = DEFAULT_SHADOW_NEAR, float farPlane = 25.0f) {
    immutable fovY = outerConeDeg * (PI / 180.0f) * 2.0f;
    return spotLightVP(position, direction, fovY, nearPlane, farPlane);
}

/// Spot depth pass — identical to directional `submitShadowPass`.
void submitSpotShadowPass(ref GpuContext gpu, ref SpotShadowMap shadow,
                          ref ShadowPipeline pipe,
                          WGPUBindGroup lightBg, WGPUBuffer lightBuf, Mat4 lightVP,
                          ref TexMesh mesh, WGPUBuffer instanceBuf, uint instanceCount,
                          bool clear = true) @trusted {
    submitShadowPass(gpu, shadow, pipe, lightBg, lightBuf, lightVP,
                     mesh, instanceBuf, instanceCount, clear);
}
