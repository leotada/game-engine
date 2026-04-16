/// Scene3DTextured — batched textured-mesh renderer.
/// Like Scene3D, but each batch is keyed by (TexMesh, Material).
module engine.scene.scene3d_textured;

import bindings.wgpu : WGPUBuffer, WGPUBindGroup, WGPUIndexFormat, wgpuBindGroupLayoutRelease;
import engine.gpu.buffer;
import engine.gpu.context : GpuContext;
import engine.gpu.pipeline : Pipeline3D, createTexturedPipeline3D;
import engine.gpu.renderer : FrameContext;
import engine.graphics.types : InstanceData, Color4;
import engine.graphics.texmesh : TexMesh;
import engine.graphics.material : Material;
import engine.math.mat : Mat4;
import engine.math.vec : Vec3;
import engine.scene.camera : Camera;

@safe:

/// Batched renderer for textured instanced 3D meshes.
/// One pipeline, one shared VP uniform buffer; materials carry per-texture bind groups.
struct Scene3DTextured {
    private Pipeline3D pipeline;
    private WGPUBuffer uniformBuf;
    private GpuContext* gpu;

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

        s.pipeline   = createTexturedPipeline3D(device, gpu.getFormat());
        s.uniformBuf = createUniformBuffer(device, 64);

        foreach (ref b; s.batches) {
            b.instanceBuf = createDynamicVertexBuffer(
                device, MAX_INSTANCES_PER_BATCH * InstanceData.sizeof);
        }
        return s;
    }

    /// Accessor so game code can build Materials against the pipeline's bind group layout.
    WGPUBuffer sharedUniformBuffer() nothrow @nogc { return uniformBuf; }

    /// Bind group layout used by any Material that will be drawn with this scene.
    auto bindGroupLayout() nothrow @nogc { return pipeline.bindGroupLayout; }

    void begin(ref const Camera camera) {
        immutable vp = camera.viewProjection();
        updateBuffer(gpu.getQueue(), uniformBuf, vp.m[]);

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

        foreach (ref b; batches[0 .. batchCount]) {
            if (b.instances.length == 0) continue;
            updateBuffer(queue, b.instanceBuf, b.instances);

            frame.setBindGroup(0, b.material.bindGroup);
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
        destroyBuffer(uniformBuf);
        pipeline.release();
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
