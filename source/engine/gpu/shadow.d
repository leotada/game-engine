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
import engine.gpu.shaders : shadowDepthShaderSource;
import engine.graphics.texmesh : TexMesh;
import engine.math.mat    : Mat4;
import engine.math.vec    : Vec3;

@safe:

/// Match `engine.scene.light.POINT_SHADOW_RESOLUTION`.
enum uint DEFAULT_POINT_SHADOW_RESOLUTION = 512;
/// Match `engine.scene.light.SPOT_SHADOW_RESOLUTION`.
enum uint DEFAULT_SPOT_SHADOW_RESOLUTION = 1024;
/// Match `engine.scene.light.LIGHT_SHADOW_NEAR`.
enum float DEFAULT_SHADOW_NEAR = 0.1f;

/// Square depth-only texture usable as both a render target (for the depth
/// pass) and a texture binding (for sampling in the main pass).
struct ShadowMap {
    uint resolution;
    WGPUTexture     depthTexture;
    WGPUTextureView depthView;
    WGPUSampler     comparisonSampler;

    @disable this(this);

    static ShadowMap create(ref GpuContext gpu, uint resolution = 2048) @trusted {
        ShadowMap s;
        s.resolution = resolution;
        auto device = gpu.getDevice();

        WGPUTextureDescriptor td;
        td.usage     = WGPUTextureUsage.renderAttachment | WGPUTextureUsage.textureBinding;
        td.dimension = WGPUTextureDimension.dim2D;
        td.size      = WGPUExtent3D(resolution, resolution, 1);
        td.format    = WGPUTextureFormat.depth32Float;
        s.depthTexture = wgpuDeviceCreateTexture(device, &td);
        if (s.depthTexture is null) fatal("Shadow map texture creation failed");

        WGPUTextureViewDescriptor vd;
        vd.format    = WGPUTextureFormat.depth32Float;
        vd.dimension = WGPUTextureViewDimension.dim2D;
        vd.aspect    = WGPUTextureAspect.depthOnly;
        s.depthView = wgpuTextureCreateView(s.depthTexture, &vd);

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

        info("Shadow map created: ", resolution, "×", resolution, " depth32Float");
        return s;
    }

    void destroy() @trusted nothrow @nogc {
        if (comparisonSampler !is null) { wgpuSamplerRelease(comparisonSampler); comparisonSampler = null; }
        if (depthView !is null)         { wgpuTextureViewRelease(depthView); depthView = null; }
        if (depthTexture !is null)      { wgpuTextureRelease(depthTexture); depthTexture = null; }
    }
}

/// Depth-only pipeline, compatible with TexMesh geometry + InstanceData
/// per-instance buffer. Uses one uniform (binding 0): the light's VP matrix.
struct ShadowPipeline {
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

ShadowPipeline createShadowPipeline(WGPUDevice device) @trusted {
    ShadowPipeline r;
    r.shaderModule = createShaderModule(device, shadowDepthShaderSource.ptr);
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
          attributeCount: 3, attributes: vertexAttrs.ptr },
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
                                          bool clear = true) @trusted {
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
                                       bool clear = true) @trusted {
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
                      bool clear = true) @trusted {
    import engine.gpu.buffer : updateBuffer;

    updateBuffer(gpu.getQueue(), lightBuf, lightVP.m[]);

    WGPUCommandEncoderDescriptor encDesc;
    auto enc = wgpuDeviceCreateCommandEncoder(gpu.getDevice(), &encDesc);
    auto pass = beginShadowPass(enc, shadow, clear);

    wgpuRenderPassEncoderSetPipeline(pass, pipe.pipeline);
    wgpuRenderPassEncoderSetBindGroup(pass, 0, lightBg, 0, null);
    wgpuRenderPassEncoderSetVertexBuffer(pass, 0, mesh.vertexBuffer, 0, mesh.vertexBufSize);
    wgpuRenderPassEncoderSetVertexBuffer(pass, 1, instanceBuf, 0, instanceCount * 80);
    wgpuRenderPassEncoderSetIndexBuffer(pass, mesh.indexBuffer, WGPUIndexFormat.uint16,
                                        0, mesh.indexCount * ushort.sizeof);
    wgpuRenderPassEncoderDrawIndexed(pass, mesh.indexCount, instanceCount, 0, 0, 0);

    endShadowPass(pass);

    WGPUCommandBufferDescriptor cbDesc;
    auto cmd = wgpuCommandEncoderFinish(enc, &cbDesc);
    wgpuCommandEncoderRelease(enc);
    wgpuQueueSubmit(gpu.getQueue(), 1, &cmd);
    wgpuCommandBufferRelease(cmd);
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
        PointShadowMap s;
        s.resolution = resolution;
        s.nearPlane = nearPlane;
        s.farPlane = farPlane;
        auto device = gpu.getDevice();

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
                           bool clear = true) @trusted {
    import engine.gpu.buffer : updateBuffer;

    if (face >= 6) return;
    updateBuffer(gpu.getQueue(), lightBuf, faceVP.m[]);

    WGPUCommandEncoderDescriptor encDesc;
    auto enc = wgpuDeviceCreateCommandEncoder(gpu.getDevice(), &encDesc);
    auto pass = beginShadowPassView(enc, shadow.faceViews[face], clear);

    wgpuRenderPassEncoderSetPipeline(pass, pipe.pipeline);
    wgpuRenderPassEncoderSetBindGroup(pass, 0, lightBg, 0, null);
    wgpuRenderPassEncoderSetVertexBuffer(pass, 0, mesh.vertexBuffer, 0, mesh.vertexBufSize);
    wgpuRenderPassEncoderSetVertexBuffer(pass, 1, instanceBuf, 0, instanceCount * 80);
    wgpuRenderPassEncoderSetIndexBuffer(pass, mesh.indexBuffer, WGPUIndexFormat.uint16,
                                        0, mesh.indexCount * ushort.sizeof);
    wgpuRenderPassEncoderDrawIndexed(pass, mesh.indexCount, instanceCount, 0, 0, 0);

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
