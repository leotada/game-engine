/// GPU skinning: draws one skinned mesh with a joint palette in a storage buffer.
///
/// Vertex: position, normal, 4 joint indices (uint32), 4 weights. The palette (`model * inverseBind`
/// per joint, column-major `Mat4`) is rewritten every frame with `updatePalette`.
/// Limit: `maxJoints` (1024, the ozz skeleton limit) palette entries, 64 KiB.
module engine.gpu.skinned;

import bindings.wgpu;
import engine.core.log;
import engine.gpu.buffer   : createIndexBuffer, createUniformBuffer, createVertexBuffer, destroyBuffer;
import engine.gpu.context  : GpuContext;
import engine.gpu.pipeline : Pipeline3D;
import engine.gpu.renderer : FrameContext, Renderer;
import engine.gpu.shader   : createShaderModule;
import engine.gpu.shaders  : skinnedShaderSource;
import engine.graphics.types : Color4;
import engine.math.mat : Mat4;
import engine.math.vec : Vec3;

@safe:

enum size_t maxJoints = 1024;

/// POD vertex uploaded to the GPU (56 bytes).
struct SkinnedVertex {
    float[3] position = 0;
    float[3] normal = 0;
    uint[4] joints = 0;
    float[4] weights = 0;
}

private enum size_t UNIFORM_SIZE = 64 + 16 + 16;

struct SkinnedRenderer {
    private Pipeline3D pipe;
    private WGPUBuffer vertexBuf, indexBuf, uniformBuf, paletteBuf;
    private WGPUBindGroup bindGroup;
    private WGPUQueue queue;
    private uint indexCount;

    @disable this(this);

    static SkinnedRenderer create(ref GpuContext gpu, const(SkinnedVertex)[] vertices,
                                  const(uint)[] indices) @trusted {
        SkinnedRenderer r;
        auto device = gpu.getDevice();
        r.queue = gpu.getQueue();
        r.indexCount = cast(uint) indices.length;
        r.vertexBuf = createVertexBuffer(device, r.queue, vertices.ptr, vertices.length * SkinnedVertex.sizeof);
        r.indexBuf = createIndexBuffer(device, r.queue, indices.ptr, indices.length * uint.sizeof);
        r.uniformBuf = createUniformBuffer(device, UNIFORM_SIZE);
        WGPUBufferDescriptor pd;
        pd.usage = WGPUBufferUsage.storage | WGPUBufferUsage.copyDst;
        pd.size = maxJoints * Mat4.sizeof;
        r.paletteBuf = wgpuDeviceCreateBuffer(device, &pd);
        r.buildPipeline(device, Renderer.sceneFormat());
        r.buildBindGroup(device);
        info("SkinnedRenderer ready (", vertices.length, " vertices, ", indices.length / 3, " triangles)");
        return r;
    }

    /// Uploads the joint palette (at most `maxJoints` entries).
    void updatePalette(const(Mat4)[] palette) @trusted nothrow @nogc {
        immutable n = palette.length < maxJoints ? palette.length : maxJoints;
        wgpuQueueWriteBuffer(queue, paletteBuf, 0, palette.ptr, n * Mat4.sizeof);
    }

    /// Draws the mesh into the frame's pass. Call after `updatePalette`.
    void draw(ref FrameContext frame, Mat4 viewProj, Color4 color,
              Vec3 lightDir = Vec3(-0.4f, -1.0f, -0.6f)) @trusted nothrow @nogc {
        if (!frame.valid || indexCount == 0) return;
        float[24] u = 0;
        u[0 .. 16] = viewProj.m[];
        u[16] = color.r; u[17] = color.g; u[18] = color.b; u[19] = color.a;
        u[20] = lightDir.x; u[21] = lightDir.y; u[22] = lightDir.z;
        wgpuQueueWriteBuffer(queue, uniformBuf, 0, u.ptr, UNIFORM_SIZE);
        wgpuRenderPassEncoderSetPipeline(frame.pass, pipe.pipeline);
        wgpuRenderPassEncoderSetBindGroup(frame.pass, 0, bindGroup, 0, null);
        wgpuRenderPassEncoderSetVertexBuffer(frame.pass, 0, vertexBuf, 0, ulong.max);
        wgpuRenderPassEncoderSetIndexBuffer(frame.pass, indexBuf, WGPUIndexFormat.uint32, 0, ulong.max);
        wgpuRenderPassEncoderDrawIndexed(frame.pass, indexCount, 1, 0, 0, 0);
    }

    void destroy() @trusted nothrow @nogc {
        if (bindGroup !is null) { wgpuBindGroupRelease(bindGroup); bindGroup = null; }
        destroyBuffer(vertexBuf); vertexBuf = null;
        destroyBuffer(indexBuf); indexBuf = null;
        destroyBuffer(uniformBuf); uniformBuf = null;
        destroyBuffer(paletteBuf); paletteBuf = null;
        pipe.release();
    }

    private void buildPipeline(WGPUDevice device, WGPUTextureFormat surfaceFormat) @trusted {
        pipe.shaderModule = createShaderModule(device, skinnedShaderSource.ptr);

        WGPUBindGroupLayoutEntry[2] e;
        e[0].binding = 0;
        e[0].visibility = WGPUShaderStage.vertex | WGPUShaderStage.fragment;
        e[0].buffer.type = WGPUBufferBindingType.uniform;
        e[0].buffer.minBindingSize = UNIFORM_SIZE;
        e[1].binding = 1;
        e[1].visibility = WGPUShaderStage.vertex;
        e[1].buffer.type = WGPUBufferBindingType.readOnlyStorage;
        e[1].buffer.minBindingSize = Mat4.sizeof;
        WGPUBindGroupLayoutDescriptor bgl;
        bgl.entryCount = 2;
        bgl.entries = e.ptr;
        pipe.bindGroupLayout = wgpuDeviceCreateBindGroupLayout(device, &bgl);

        WGPUPipelineLayoutDescriptor pl;
        pl.bindGroupLayoutCount = 1;
        pl.bindGroupLayouts = &pipe.bindGroupLayout;
        pipe.pipelineLayout = wgpuDeviceCreatePipelineLayout(device, &pl);

        WGPUVertexAttribute[4] attrs = [
            { format: WGPUVertexFormat.float32x3, offset: 0,  shaderLocation: 0 },
            { format: WGPUVertexFormat.float32x3, offset: 12, shaderLocation: 1 },
            { format: WGPUVertexFormat.uint32x4,  offset: 24, shaderLocation: 2 },
            { format: WGPUVertexFormat.float32x4, offset: 40, shaderLocation: 3 },
        ];
        WGPUVertexBufferLayout layout;
        layout.arrayStride = SkinnedVertex.sizeof;
        layout.stepMode = WGPUVertexStepMode.vertex;
        layout.attributeCount = 4;
        layout.attributes = attrs.ptr;

        WGPUColorTargetState ct;
        ct.format = surfaceFormat;
        ct.writeMask = WGPUColorWriteMask.all;
        WGPUFragmentState fs;
        fs.module_ = pipe.shaderModule;
        fs.entryPoint = wgpuStringView("fs_main");
        fs.targetCount = 1;
        fs.targets = &ct;

        WGPUDepthStencilState ds;
        ds.format = WGPUTextureFormat.depth24Plus;
        ds.depthWriteEnabled = WGPUOptionalBool.true_;
        ds.depthCompare = WGPUCompareFunction.less;

        WGPURenderPipelineDescriptor pd;
        pd.layout = pipe.pipelineLayout;
        pd.vertex.module_ = pipe.shaderModule;
        pd.vertex.entryPoint = wgpuStringView("vs_main");
        pd.vertex.bufferCount = 1;
        pd.vertex.buffers = &layout;
        pd.primitive.topology = WGPUPrimitiveTopology.triangleList;
        pd.primitive.frontFace = WGPUFrontFace.ccw;
        pd.primitive.cullMode = WGPUCullMode.none;
        pd.depthStencil = &ds;
        pd.fragment = &fs;
        pipe.pipeline = wgpuDeviceCreateRenderPipeline(device, &pd);
        if (pipe.pipeline is null) err("SkinnedRenderer: pipeline creation failed");
    }

    private void buildBindGroup(WGPUDevice device) @trusted {
        WGPUBindGroupEntry[2] e;
        e[0].binding = 0;
        e[0].buffer = uniformBuf;
        e[0].size = UNIFORM_SIZE;
        e[1].binding = 1;
        e[1].buffer = paletteBuf;
        e[1].size = maxJoints * Mat4.sizeof;
        WGPUBindGroupDescriptor bg;
        bg.layout = pipe.bindGroupLayout;
        bg.entryCount = 2;
        bg.entries = e.ptr;
        bindGroup = wgpuDeviceCreateBindGroup(device, &bg);
    }
}
