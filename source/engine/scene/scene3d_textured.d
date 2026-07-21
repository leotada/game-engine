/// Scene3DTextured — batched textured-mesh renderer with multi-light PBR +
/// shadows + IBL. Batches keyed by (TexMesh, Material). Frame uniforms and
/// shadow/IBL bind groups are owned by the scene (group 0 / group 2);
/// materials own group 1.
module engine.scene.scene3d_textured;

import std.math : cos, PI;

import bindings.wgpu;
import engine.core.log;
import engine.gpu.buffer;
import engine.gpu.context : GpuContext;
import engine.gpu.ibl : IblEnvironment;
import engine.gpu.pipeline : Pipeline3D, createTexturedPipeline3D, FRAME_UNIFORMS_SIZE;
import engine.gpu.renderer : FrameContext, Renderer;
import engine.gpu.shadow : PointShadowMap, ShadowMap, SpotShadowMap;
import engine.graphics.types : InstanceData, Color4;
import engine.graphics.texmesh : TexMesh;
import engine.graphics.material : Material;
import engine.math.mat : Mat4;
import engine.math.vec : Vec3;
import engine.scene.camera : Camera;
import engine.scene.light :
    LightSet, MAX_POINT_LIGHTS, MAX_POINT_SHADOW_CASTERS,
    MAX_SPOT_LIGHTS, MAX_SPOT_SHADOW_CASTERS;

@safe:

/// GPU mirror of WGSL `DirLight` (96 bytes).
struct GpuDirLightUbo {
    float[3] direction = [0.3f, 1.0f, 0.5f];
    float intensity = 3.5f;
    float[3] color = [1.0f, 0.98f, 0.92f];
    uint castShadows = 0;
    float[16] viewProj;
}
static assert(GpuDirLightUbo.sizeof == 96);

/// GPU mirror of WGSL `PointLight` (48 bytes).
struct GpuPointLightUbo {
    float[3] position = [0, 0, 0];
    float range = 10.0f;
    float[3] color = [1, 1, 1];
    float intensity = 1.0f;
    int shadowSlot = -1;
    float _pad0 = 0, _pad1 = 0, _pad2 = 0;
}
static assert(GpuPointLightUbo.sizeof == 48);

/// GPU mirror of WGSL `SpotLight` (128 bytes).
struct GpuSpotLightUbo {
    float[3] position = [0, 0, 0];
    float range = 10.0f;
    float[3] direction = [0, -1, 0];
    float intensity = 1.0f;
    float[3] color = [1, 1, 1];
    float innerConeCos = 0.96f;
    float outerConeCos = 0.9f;
    int shadowSlot = -1;
    float _pad0 = 0, _pad1 = 0;
    float[16] viewProj;
}
static assert(GpuSpotLightUbo.sizeof == 128);

/// CPU mirror of WGSL FrameUniforms (1088 bytes).
struct FrameUniforms {
    float[16] viewProj;
    float[3] cameraPos = [0, 5, 10];
    float shadowBias = 0.0004f;
    GpuDirLightUbo dirLight;
    uint pointCount = 0;
    uint spotCount = 0;
    uint dirEnabled = 1;
    uint _padCounts = 0;
    GpuPointLightUbo[MAX_POINT_LIGHTS] points;
    GpuSpotLightUbo[MAX_SPOT_LIGHTS] spots;
}
static assert(FrameUniforms.sizeof == FRAME_UNIFORMS_SIZE);

/// Batched renderer for textured instanced 3D meshes (PBR path).
struct Scene3DTextured {
    private Pipeline3D pipeline;
    private WGPUBuffer frameUniformBuf;
    private WGPUBindGroup frameBindGroup;
    private WGPUBindGroup iblBindGroup;
    private IblEnvironment ownedIbl;
    private bool ownsIbl = true;
    private GpuContext* gpu;

    // Default 1×1 depth resources so the pipeline is valid before setLights.
    private WGPUTexture defaultShadow2dTex;
    private WGPUTextureView defaultShadow2dView;
    private WGPUTexture defaultShadowCubeTex;
    private WGPUTextureView defaultShadowCubeView;
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

        s.pipeline = createTexturedPipeline3D(device, Renderer.sceneFormat());
        s.frameUniformBuf = createUniformBuffer(device, FRAME_UNIFORMS_SIZE);

        s.frameData = FrameUniforms.init;
        s.frameData.viewProj = Mat4.identity().m;
        s.frameData.dirEnabled = 1;
        s.frameData.dirLight.intensity = 3.5f;
        s.frameData.dirLight.color = [1.0f, 0.98f, 0.92f];
        s.frameData.dirLight.direction = [0.3f, 1.0f, 0.5f];
        s.frameData.dirLight.viewProj = Mat4.identity().m;
        s.frameData.shadowBias = 0.0004f;

        s.createDefaultShadows(device);
        s.rebuildFrameBindGroup(
            s.defaultShadowSampler,
            s.defaultShadow2dView,
            s.defaultShadowCubeView, s.defaultShadowCubeView,
            s.defaultShadowCubeView, s.defaultShadowCubeView,
            s.defaultShadow2dView, s.defaultShadow2dView);

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

    /// Update multi-light UBO + bind shadow maps for the next draws.
    ///
    /// `dirShadow` may be null (uses a fully-lit placeholder).
    /// Point/spot lights with `castShadows` consume maps from `pointShadows` /
    /// `spotShadows` in order; overflow warns and leaves those lights unshadowed.
    void setLights(ref const LightSet lights,
                   scope ShadowMap* dirShadow,
                   scope PointShadowMap*[MAX_POINT_SHADOW_CASTERS] pointShadows,
                   scope SpotShadowMap*[MAX_SPOT_SHADOW_CASTERS] spotShadows) @trusted {
        frameData.shadowBias = lights.shadowBias;
        frameData.dirEnabled = lights.dirEnabled ? 1 : 0;

        if (lights.dirEnabled) {
            immutable d = lights.dir.direction.normalized();
            frameData.dirLight.direction = [d.x, d.y, d.z];
            frameData.dirLight.color = [
                lights.dir.color.x, lights.dir.color.y, lights.dir.color.z
            ];
            frameData.dirLight.intensity = lights.dir.intensity;
            frameData.dirLight.viewProj = lights.dir.viewProj.m;
            immutable wantDirShadow = lights.dir.castShadows && dirShadow !is null;
            frameData.dirLight.castShadows = wantDirShadow ? 1 : 0;
            if (lights.dir.castShadows && dirShadow is null)
                warn("Directional castShadows requested but no ShadowMap provided");
        }

        immutable pc = lights.pointCount > MAX_POINT_LIGHTS
            ? MAX_POINT_LIGHTS : lights.pointCount;
        if (lights.pointCount > MAX_POINT_LIGHTS)
            warn("Point light UBO overflow: ", lights.pointCount, " > ", MAX_POINT_LIGHTS);
        frameData.pointCount = pc;
        frameData.points = GpuPointLightUbo.init;

        WGPUTextureView[MAX_POINT_SHADOW_CASTERS] boundPoints = [
            defaultShadowCubeView, defaultShadowCubeView,
            defaultShadowCubeView, defaultShadowCubeView,
        ];
        uint pointShadowUsed = 0;
        foreach (i; 0 .. pc) {
            immutable pl = lights.points[i];
            frameData.points[i].position = [pl.position.x, pl.position.y, pl.position.z];
            frameData.points[i].range = pl.range;
            frameData.points[i].color = [pl.color.x, pl.color.y, pl.color.z];
            frameData.points[i].intensity = pl.intensity;
            frameData.points[i].shadowSlot = -1;
            if (!pl.castShadows) continue;
            if (pointShadowUsed >= MAX_POINT_SHADOW_CASTERS
                || pointShadows[pointShadowUsed] is null) {
                warn("Point shadow caster budget exceeded (MAX_POINT_SHADOW_CASTERS=",
                     MAX_POINT_SHADOW_CASTERS, "); light ", i, " stays unshadowed");
                continue;
            }
            frameData.points[i].shadowSlot = cast(int) pointShadowUsed;
            boundPoints[pointShadowUsed] = pointShadows[pointShadowUsed].cubeView;
            pointShadowUsed++;
        }

        immutable sc = lights.spotCount > MAX_SPOT_LIGHTS
            ? MAX_SPOT_LIGHTS : lights.spotCount;
        if (lights.spotCount > MAX_SPOT_LIGHTS)
            warn("Spot light UBO overflow: ", lights.spotCount, " > ", MAX_SPOT_LIGHTS);
        frameData.spotCount = sc;
        frameData.spots = GpuSpotLightUbo.init;

        WGPUTextureView[MAX_SPOT_SHADOW_CASTERS] boundSpots = [
            defaultShadow2dView, defaultShadow2dView,
        ];
        uint spotShadowUsed = 0;
        foreach (i; 0 .. sc) {
            immutable sl = lights.spots[i];
            immutable dir = sl.direction.normalized();
            immutable innerRad = sl.innerConeDeg * (PI / 180.0f);
            immutable outerRad = sl.outerConeDeg * (PI / 180.0f);
            frameData.spots[i].position = [sl.position.x, sl.position.y, sl.position.z];
            frameData.spots[i].range = sl.range;
            frameData.spots[i].direction = [dir.x, dir.y, dir.z];
            frameData.spots[i].intensity = sl.intensity;
            frameData.spots[i].color = [sl.color.x, sl.color.y, sl.color.z];
            frameData.spots[i].innerConeCos = cos(innerRad);
            frameData.spots[i].outerConeCos = cos(outerRad);
            frameData.spots[i].viewProj = sl.viewProj.m;
            frameData.spots[i].shadowSlot = -1;
            if (!sl.castShadows) continue;
            if (spotShadowUsed >= MAX_SPOT_SHADOW_CASTERS
                || spotShadows[spotShadowUsed] is null) {
                warn("Spot shadow caster budget exceeded (MAX_SPOT_SHADOW_CASTERS=",
                     MAX_SPOT_SHADOW_CASTERS, "); light ", i, " stays unshadowed");
                continue;
            }
            frameData.spots[i].shadowSlot = cast(int) spotShadowUsed;
            boundSpots[spotShadowUsed] = spotShadows[spotShadowUsed].depthView;
            spotShadowUsed++;
        }

        auto dirView = (dirShadow !is null) ? dirShadow.depthView : defaultShadow2dView;
        auto sampler = defaultShadowSampler;
        if (dirShadow !is null)
            sampler = dirShadow.comparisonSampler;
        else if (pointShadowUsed > 0)
            sampler = pointShadows[0].comparisonSampler;
        else if (spotShadowUsed > 0)
            sampler = spotShadows[0].comparisonSampler;

        rebuildFrameBindGroup(
            sampler, dirView,
            boundPoints[0], boundPoints[1], boundPoints[2], boundPoints[3],
            boundSpots[0], boundSpots[1]);
    }

    /// Backward-compatible single directional light + shadow map.
    void setLighting(Vec3 lightDir, Mat4 lightVP, ref ShadowMap shadow,
                     float bias = 0.0004f) @trusted {
        LightSet ls;
        ls.dirEnabled = true;
        ls.dir.direction = lightDir;
        ls.dir.viewProj = lightVP;
        ls.dir.color = Vec3(1.0f, 0.98f, 0.92f);
        ls.dir.intensity = 3.5f;
        ls.dir.castShadows = true;
        ls.shadowBias = bias;
        ls.pointCount = 0;
        ls.spotCount = 0;
        PointShadowMap*[MAX_POINT_SHADOW_CASTERS] pts;
        SpotShadowMap*[MAX_SPOT_SHADOW_CASTERS] spts;
        setLights(ls, &shadow, pts, spts);
    }

    /// Bind a custom IBL environment (replaces the default procedural one for draws).
    /// The scene does not take ownership — caller must keep `ibl` alive.
    void setEnvironment(ref IblEnvironment ibl) nothrow @nogc {
        iblBindGroup = ibl.bindGroup;
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
        if (defaultShadow2dView !is null) {
            wgpuTextureViewRelease(defaultShadow2dView);
            defaultShadow2dView = null;
        }
        if (defaultShadow2dTex !is null) {
            wgpuTextureRelease(defaultShadow2dTex);
            defaultShadow2dTex = null;
        }
        if (defaultShadowCubeView !is null) {
            wgpuTextureViewRelease(defaultShadowCubeView);
            defaultShadowCubeView = null;
        }
        if (defaultShadowCubeTex !is null) {
            wgpuTextureRelease(defaultShadowCubeTex);
            defaultShadowCubeTex = null;
        }
        pipeline.release();
    }

    private void createDefaultShadows(WGPUDevice device) @trusted {
        // 1×1 2D depth (dir / spot placeholders)
        {
            WGPUTextureDescriptor td;
            td.usage = WGPUTextureUsage.renderAttachment | WGPUTextureUsage.textureBinding;
            td.dimension = WGPUTextureDimension.dim2D;
            td.size = WGPUExtent3D(1, 1, 1);
            td.format = WGPUTextureFormat.depth32Float;
            defaultShadow2dTex = wgpuDeviceCreateTexture(device, &td);

            WGPUTextureViewDescriptor vd;
            vd.format = WGPUTextureFormat.depth32Float;
            vd.dimension = WGPUTextureViewDimension.dim2D;
            vd.aspect = WGPUTextureAspect.depthOnly;
            defaultShadow2dView = wgpuTextureCreateView(defaultShadow2dTex, &vd);
        }
        // 1×1×6 depth cube (point placeholders)
        {
            WGPUTextureDescriptor td;
            td.usage = WGPUTextureUsage.renderAttachment | WGPUTextureUsage.textureBinding;
            td.dimension = WGPUTextureDimension.dim2D;
            td.size = WGPUExtent3D(1, 1, 6);
            td.format = WGPUTextureFormat.depth32Float;
            defaultShadowCubeTex = wgpuDeviceCreateTexture(device, &td);

            WGPUTextureViewDescriptor vd;
            vd.format = WGPUTextureFormat.depth32Float;
            vd.dimension = WGPUTextureViewDimension.cube;
            vd.aspect = WGPUTextureAspect.depthOnly;
            vd.baseArrayLayer = 0;
            vd.arrayLayerCount = 6;
            defaultShadowCubeView = wgpuTextureCreateView(defaultShadowCubeTex, &vd);
        }

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

        // Clear depths to 1 so PCF comparisons pass (fully lit) until setLights.
        clearDepthView(device, defaultShadow2dView);
        foreach (face; 0 .. 6) {
            WGPUTextureViewDescriptor faceVd;
            faceVd.format = WGPUTextureFormat.depth32Float;
            faceVd.dimension = WGPUTextureViewDimension.dim2D;
            faceVd.aspect = WGPUTextureAspect.depthOnly;
            faceVd.baseArrayLayer = face;
            faceVd.arrayLayerCount = 1;
            auto faceView = wgpuTextureCreateView(defaultShadowCubeTex, &faceVd);
            clearDepthView(device, faceView);
            wgpuTextureViewRelease(faceView);
        }
    }

    private void clearDepthView(WGPUDevice device, WGPUTextureView view) @trusted {
        WGPUCommandEncoderDescriptor encDesc;
        auto enc = wgpuDeviceCreateCommandEncoder(device, &encDesc);
        WGPURenderPassDepthStencilAttachment depthAtt;
        depthAtt.view = view;
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

    private void rebuildFrameBindGroup(
        WGPUSampler shadowSampler,
        WGPUTextureView dirView,
        WGPUTextureView point0, WGPUTextureView point1,
        WGPUTextureView point2, WGPUTextureView point3,
        WGPUTextureView spot0, WGPUTextureView spot1) @trusted
    {
        if (frameBindGroup !is null) {
            wgpuBindGroupRelease(frameBindGroup);
            frameBindGroup = null;
        }
        WGPUBindGroupEntry[9] entries;
        entries[0].binding = 0;
        entries[0].buffer = frameUniformBuf;
        entries[0].offset = 0;
        entries[0].size = FRAME_UNIFORMS_SIZE;
        entries[1].binding = 1;
        entries[1].sampler = shadowSampler;
        entries[2].binding = 2;
        entries[2].textureView = dirView;
        entries[3].binding = 3;
        entries[3].textureView = point0;
        entries[4].binding = 4;
        entries[4].textureView = point1;
        entries[5].binding = 5;
        entries[5].textureView = point2;
        entries[6].binding = 6;
        entries[6].textureView = point3;
        entries[7].binding = 7;
        entries[7].textureView = spot0;
        entries[8].binding = 8;
        entries[8].textureView = spot1;

        WGPUBindGroupDescriptor desc;
        desc.layout = pipeline.frameBindGroupLayout;
        desc.entryCount = 9;
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
