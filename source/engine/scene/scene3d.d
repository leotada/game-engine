/// Scene3D — batched instanced renderer for 3D meshes.
/// Manages pipeline, uniform buffer, and per-mesh instance batches internally.
module engine.scene.scene3d;

import bindings.wgpu : WGPUBuffer, WGPUBindGroup, WGPUIndexFormat;
import engine.gpu.buffer;
import engine.gpu.context : GpuContext;
import engine.gpu.pipeline : Pipeline3D, createColoredPipeline3D;
import engine.gpu.renderer : FrameContext;
import engine.graphics.types : InstanceData, Color4;
import engine.graphics.mesh : Mesh;
import engine.math.mat : Mat4;
import engine.math.vec : Vec3;
import engine.scene.camera : Camera;

@safe:

struct Scene3D {
    private Pipeline3D pipeline;
    private WGPUBuffer uniformBuf;
    private WGPUBindGroup vpBindGroup;
    private GpuContext* gpu;

    // Per-mesh batch tracking — up to 16 different meshes per frame
    private enum MAX_MESH_KINDS = 16;
    private enum MAX_INSTANCES_PER_MESH = 256;

    private struct MeshBatch {
        Mesh* mesh;
        InstanceData[] instances;
        WGPUBuffer instanceBuf;
    }

    private MeshBatch[MAX_MESH_KINDS] batches;
    private uint batchCount = 0;

    @disable this(this);

    static Scene3D create(ref GpuContext gpu) @trusted {
        Scene3D s;
        s.gpu = &gpu;

        auto device = gpu.getDevice();

        // Create colored 3D pipeline
        s.pipeline = createColoredPipeline3D(device, gpu.getFormat());

        // Uniform buffer for VP matrix (64 bytes = Mat4)
        s.uniformBuf = createUniformBuffer(device, 64);

        // Bind group for VP uniform
        s.vpBindGroup = createUniformBindGroup(device, s.pipeline.bindGroupLayout, s.uniformBuf, 64);

        // Pre-allocate instance buffers
        foreach (ref b; s.batches) {
            b.instanceBuf = createDynamicVertexBuffer(device, MAX_INSTANCES_PER_MESH * InstanceData.sizeof);
        }

        return s;
    }

    /// Reset batches and upload the view-projection matrix.
    void begin(ref const Camera camera) {
        // Upload VP matrix
        immutable vp = camera.viewProjection();
        updateBuffer(gpu.getQueue(), uniformBuf, vp.m[]);

        // Clear all batches
        batchCount = 0;
        foreach (ref b; batches) {
            b.mesh = null;
            b.instances = null;
        }
    }

    /// Queue an instance: position + uniform scale + color + optional Y rotation.
    void draw(ref Mesh mesh, Vec3 pos, Vec3 scale, Color4 color, float rotationY = 0) {
        auto model = Mat4.translation(pos.x, pos.y, pos.z)
                   * Mat4.rotationY(rotationY)
                   * Mat4.scaling(scale.x, scale.y, scale.z);
        drawMatrix(mesh, model, color);
    }

    /// Queue an instance with a full model matrix + color.
    void drawMatrix(ref Mesh mesh, Mat4 model, Color4 color) {
        auto batch = findOrAddBatch(mesh);
        if (batch is null) return; // too many mesh kinds
        batch.instances ~= InstanceData(model.m, color.toArray());
    }

    /// Upload instance data and issue all draw calls.
    void end(ref FrameContext frame) {
        if (!frame.valid) return;

        auto queue = gpu.getQueue();

        frame.setPipeline(pipeline.pipeline);
        frame.setBindGroup(0, vpBindGroup);

        foreach (ref b; batches[0 .. batchCount]) {
            if (b.instances.length == 0) continue;

            // Upload instance data
            updateBuffer(queue, b.instanceBuf, b.instances);

            // Set vertex buffers and draw
            frame.setVertexBuffer(0, b.mesh.vertexBuffer, b.mesh.vertexBufSize);
            frame.setVertexBuffer(1, b.instanceBuf, b.instances.length * InstanceData.sizeof);
            frame.setIndexBuffer(b.mesh.indexBuffer, WGPUIndexFormat.uint16,
                                 b.mesh.indexCount * ushort.sizeof);
            frame.drawIndexed(b.mesh.indexCount, cast(uint) b.instances.length);
        }
    }

    void destroy() nothrow @nogc {
        foreach (ref b; batches)
            destroyBuffer(b.instanceBuf);
        releaseBindGroup(vpBindGroup);
        destroyBuffer(uniformBuf);
        pipeline.release();
    }

    // --- internals ---

    private MeshBatch* findOrAddBatch(ref Mesh mesh) @trusted {
        // Find existing batch for this mesh
        foreach (ref b; batches[0 .. batchCount]) {
            if (b.mesh is &mesh) return &b;
        }
        // Add new batch
        if (batchCount >= MAX_MESH_KINDS) return null;
        batches[batchCount].mesh = &mesh;
        batches[batchCount].instances = null;
        return &batches[batchCount++];
    }
}
