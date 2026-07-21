/// Scene3DTextured — batched textured-mesh renderer with PBR + shadows + IBL.
/// Batches keyed by (TexMesh, Material). Frame uniforms and shadow/IBL bind
/// groups are owned by the scene (group 0 / group 2); materials own group 1.
module engine.scene.scene3d_textured;

import bindings.wgpu;
import engine.gpu.buffer;
import engine.gpu.context : GpuContext;
import engine.gpu.ibl : IblEnvironment;
import engine.gpu.pipeline : Pipeline3D, createTexturedPipeline3D, FRAME_UNIFORMS_SIZE;
import engine.gpu.renderer : FrameContext;
import engine.gpu.shadow : ShadowMap;
import engine.graphics.types : InstanceData, Color4;
import engine.graphics.texmesh : TexMesh;
import engine.graphics.material : Material;
import engine.math.mat : Mat4;
import engine.math.vec : Vec3;
import engine.scene.camera : Camera;
import engine.core.log;

@safe:

/// CPU mirror of WGSL FrameUniforms (160 bytes).
struct FrameUniforms {
    float[16] viewProj;
    float[16] lightViewProj;
    float[3] lightDir = [0.3f, 1.0f, 0.5f];
    float shadowBias = 0.003f;
    float[3] cameraPos = [0, 5, 10];
    float _pad = 0;
}

/// Batched renderer for textured instanced 3D meshes (PBR path).
struct Scene3DTextured {
    private Pipeline3D pipeline;
    private WGPUBuffer frameUniformBuf;
    private WGPUBindGroup frameBindGroup;
    private WGPUBindGroup iblBindGroup;
    private IblEnvironment ownedIbl; // default procedural env
    private bool ownsIbl = true;
    private GpuContext* gpu;

    // Default 1×1 depth so the pipeline is valid before setLighting.
    private WGPUTexture defaultShadowTex;
    private WGPUTextureView defaultShadowView;
    private WGPUSampler defaultShadowSampler;

    private FrameUniforms frameData;

    private enum MAX_BATCHES = 32;
    private enum MAX_INSTANCES_PER_BATCH = 512;

    private struct Batch {
        TexMesh*   mesh;
        Material*  material;
        InstanceData[] instances;
        WGPUBuffer instanceBuf;
    }

    private Batch[MAX_BATCHES] batches;
    private uint batchCount = 0;

    @disable this(this);

    static Scene3DTextured create(ref GpuContext gpu) @trusted {
        Scene3DTextured s;
        s.gpu = &gpu;
        auto device = gpu.getDevice();

        s.pipeline = createTexturedPipeline3D(device, gpu.getFormat());
        s.frameUniformBuf = createUniformBuffer(device, FRAME_UNIFORMS_SIZE);

        // Default identity light VP + upward light.
        s.frameData.viewProj = Mat4.identity().m;
        s.frameData.lightViewProj = Mat4.identity().m;
        s.frameData.lightDir = [0.3f, 1.0f, 0.5f];
        s.frameData.shadowBias = 0.003f;

        s.createDefaultShadow(device);
        s.rebuildFrameBindGroup();

        s.ownedIbl = IblEnvironment.create(gpu, s.pipeline.iblBindGroupLayout);
        s.iblBindGroup = s.ownedIbl.bindGroup;
        s.ownsIbl = true;

        foreach (ref b; s.batches) {
            b.instanceBuf = createDynamicVertexBuffer(
                device, MAX_INSTANCES_PER_BATCH * InstanceData.sizeof);
        }
        return s;
    }

    /// Material bind group layout (@group(1)).
    auto materialLayout() nothrow @nogc { return pipeline.bindGroupLayout; }

    /// Alias kept for older call sites.
    auto bindGroupLayout() nothrow @nogc { return materialLayout(); }

    /// IBL layout (@group(2)) — for custom environment construction.
    auto iblLayout() nothrow @nogc { return pipeline.iblBindGroupLayout; }

    /// Update directional light + shadow map resources for the next draws.
    void setLighting(Vec3 lightDir, Mat4 lightVP, ref ShadowMap shadow,
                     float bias = 0.003f) @trusted {
        immutable d = lightDir.normalized();
        frameData.lightDir = [d.x, d.y, d.z];
        frameData.lightViewProj = lightVP.m;
        frameData.shadowBias = bias;
        rebuildFrameBindGroup(shadow.comparisonSampler, shadow.depthView);
    }

    /// Bind a custom IBL environment (replaces the default procedural one for draws).
    /// The scene does not take ownership — caller must keep `ibl` alive.
    void setEnvironment(ref IblEnvironment ibl) nothrow @nogc {
        iblBindGroup = ibl.bindGroup;
        // Keep ownedIbl alive as fallback; just redirect the bind group pointer.
    }

    void begin(ref const Camera camera) @trusted {
        frameData.viewProj = camera.viewProjection().m;
        frameData.cameraPos = [camera.position.x, camera.position.y, camera.position.z];
        updateBuffer(gpu.getQueue(), frameUniformBuf, (&frameData)[0 .. 1]);

        batchCount = 0;
        foreach (ref b; batches) {
            b.mesh = null;
            b.material = null;
            b.instances = null;
        }
    }

    void draw(ref TexMesh mesh, ref Material material,
              Vec3 pos, Vec3 scale, Color4 tint = Color4.white, float rotationY = 0) {
        auto model = Mat4.translation(pos.x, pos.y, pos.z)
                   * Mat4.rotationY(rotationY)
                   * Mat4.scaling(scale.x, scale.y, scale.z);
        drawMatrix(mesh, material, model, tint);
    }

    void drawMatrix(ref TexMesh mesh, ref Material material, Mat4 model, Color4 tint) {
        auto b = findOrAdd(mesh, material);
        if (b is null) return;
        b.instances ~= InstanceData(model.m, tint.toArray());
    }

    void end(ref FrameContext frame) {
        if (!frame.valid) return;
        auto queue = gpu.getQueue();

        frame.setPipeline(pipeline.pipeline);
        frame.setBindGroup(0, frameBindGroup);
        frame.setBindGroup(2, iblBindGroup);

        foreach (ref b; batches[0 .. batchCount]) {
            if (b.instances.length == 0) continue;
            updateBuffer(queue, b.instanceBuf, b.instances);

            frame.setBindGroup(1, b.material.bindGroup);
            frame.setVertexBuffer(0, b.mesh.vertexBuffer, b.mesh.vertexBufSize);
            frame.setVertexBuffer(1, b.instanceBuf, b.instances.length * InstanceData.sizeof);
            frame.setIndexBuffer(b.mesh.indexBuffer, WGPUIndexFormat.uint16,
                                 b.mesh.indexCount * ushort.sizeof);
            frame.drawIndexed(b.mesh.indexCount, cast(uint) b.instances.length);
        }
    }

    void destroy() nothrow @nogc @trusted {
        foreach (ref b; batches)
            destroyBuffer(b.instanceBuf);
        if (frameBindGroup !is null) {
            wgpuBindGroupRelease(frameBindGroup);
            frameBindGroup = null;
        }
        destroyBuffer(frameUniformBuf);
        if (ownsIbl) ownedIbl.destroy();
        if (defaultShadowSampler !is null) {
            wgpuSamplerRelease(defaultShadowSampler);
            defaultShadowSampler = null;
        }
        if (defaultShadowView !is null) {
            wgpuTextureViewRelease(defaultShadowView);
            defaultShadowView = null;
        }
        if (defaultShadowTex !is null) {
            wgpuTextureRelease(defaultShadowTex);
            defaultShadowTex = null;
        }
        pipeline.release();
    }

    private void createDefaultShadow(WGPUDevice device) @trusted {
        WGPUTextureDescriptor td;
        td.usage = WGPUTextureUsage.renderAttachment | WGPUTextureUsage.textureBinding;
        td.dimension = WGPUTextureDimension.dim2D;
        td.size = WGPUExtent3D(1, 1, 1);
        td.format = WGPUTextureFormat.depth32Float;
        defaultShadowTex = wgpuDeviceCreateTexture(device, &td);

        WGPUTextureViewDescriptor vd;
        vd.format = WGPUTextureFormat.depth32Float;
        vd.dimension = WGPUTextureViewDimension.dim2D;
        vd.aspect = WGPUTextureAspect.depthOnly;
        defaultShadowView = wgpuTextureCreateView(defaultShadowTex, &vd);

        WGPUSamplerDescriptor sd;
        sd.addressModeU = WGPUAddressMode.clampToEdge;
        sd.addressModeV = WGPUAddressMode.clampToEdge;
        sd.addressModeW = WGPUAddressMode.clampToEdge;
        sd.magFilter = WGPUFilterMode.linear;
        sd.minFilter = WGPUFilterMode.linear;
        sd.mipmapFilter = WGPUMipmapFilterMode.nearest;
        sd.compare = WGPUCompareFunction.lessEqual;
        sd.maxAnisotropy = 1;
        defaultShadowSampler = wgpuDeviceCreateSampler(device, &sd);

        // Clear depth to 1 so PCF comparisons pass (fully lit) until setLighting.
        WGPUCommandEncoderDescriptor encDesc;
        auto enc = wgpuDeviceCreateCommandEncoder(device, &encDesc);
        WGPURenderPassDepthStencilAttachment depthAtt;
        depthAtt.view = defaultShadowView;
        depthAtt.depthLoadOp = WGPULoadOp.clear;
        depthAtt.depthStoreOp = WGPUStoreOp.store;
        depthAtt.depthClearValue = 1.0f;
        WGPURenderPassDescriptor pd;
        pd.depthStencilAttachment = &depthAtt;
        auto pass = wgpuCommandEncoderBeginRenderPass(enc, &pd);
        wgpuRenderPassEncoderEnd(pass);
        wgpuRenderPassEncoderRelease(pass);
        WGPUCommandBufferDescriptor cbDesc;
        auto cmd = wgpuCommandEncoderFinish(enc, &cbDesc);
        wgpuCommandEncoderRelease(enc);
        wgpuQueueSubmit(gpu.getQueue(), 1, &cmd);
        wgpuCommandBufferRelease(cmd);
    }

    private void rebuildFrameBindGroup() @trusted {
        rebuildFrameBindGroup(defaultShadowSampler, defaultShadowView);
    }

    private void rebuildFrameBindGroup(WGPUSampler shadowSampler,
                                       WGPUTextureView shadowView) @trusted {
        if (frameBindGroup !is null) {
            wgpuBindGroupRelease(frameBindGroup);
            frameBindGroup = null;
        }
        WGPUBindGroupEntry[3] entries;
        entries[0].binding = 0;
        entries[0].buffer = frameUniformBuf;
        entries[0].offset = 0;
        entries[0].size = FRAME_UNIFORMS_SIZE;
        entries[1].binding = 1;
        entries[1].sampler = shadowSampler;
        entries[2].binding = 2;
        entries[2].textureView = shadowView;

        WGPUBindGroupDescriptor desc;
        desc.layout = pipeline.frameBindGroupLayout;
        desc.entryCount = 3;
        desc.entries = entries.ptr;
        frameBindGroup = wgpuDeviceCreateBindGroup(gpu.getDevice(), &desc);
        if (frameBindGroup is null) fatal("Failed to create frame bind group");
    }

    private Batch* findOrAdd(ref TexMesh mesh, ref Material material) @trusted {
        foreach (ref b; batches[0 .. batchCount]) {
            if (b.mesh is &mesh && b.material is &material) return &b;
        }
        if (batchCount >= MAX_BATCHES) return null;
        batches[batchCount].mesh = &mesh;
        batches[batchCount].material = &material;
        batches[batchCount].instances = null;
        return &batches[batchCount++];
    }
}
