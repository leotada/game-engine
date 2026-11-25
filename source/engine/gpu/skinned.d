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
public import engine.graphics.types : SkinnedVertex;
import engine.math.bounds : Aabb, BoundingSphere;
import engine.math.mat : Mat4;
import engine.math.vec : Vec3;

@safe:

enum size_t maxJoints = 1024;

/// GPU-resident skinned mesh (80-byte `SkinnedVertex` buffer + 16/32-bit index buffer)
/// drawn by `Scene3DTextured.drawSkinned`.
struct SkinnedMesh {
    package(engine) WGPUBuffer vertexBuffer;
    package(engine) WGPUBuffer indexBuffer;
    /// Optional vertex colors (RGBA8, linear), see `setVertexColors`.
    package(engine) WGPUBuffer colorBuffer;
    package(engine) uint indexCount;
    package(engine) uint vertexCount;
    package(engine) ulong vertexBufSize;
    package(engine) ulong indexBufSize;
    package(engine) WGPUIndexFormat indexFormat = WGPUIndexFormat.uint32;
    /// Bind-pose object-space bounds computed from the vertex positions at upload.
    Aabb localBounds;
    /// Bind-pose bounding sphere (fallback when a caller omits a pose sphere).
    BoundingSphere localSphere;

    @disable this(this);

    /// Build a `SkinnedMesh` from vertex + index data.
    /// `uint` indices are narrowed to `ushort` when every index fits in 65535.
    static SkinnedMesh fromData(I)(ref GpuContext gpu, const(SkinnedVertex)[] verts, const(I)[] indices)
    if (is(I == ushort) || is(I == uint)) {
        static if (is(I == uint)) {
            if (skinnedIndicesFitU16(indices)) {
                auto narrowed = narrowSkinnedU16(indices);
                return uploadSkinned(gpu, verts, narrowed);
            }
        }
        return uploadSkinned(gpu, verts, indices);
    }

    bool valid() const pure nothrow @nogc {
        return vertexBuffer !is null && indexBuffer !is null && indexCount > 0;
    }

    bool hasBounds() const pure nothrow @nogc { return !localBounds.empty; }

    /// Attach (or replace) per-vertex colors, see `TexMesh.setVertexColors`. An empty list is a no-op.
    void setVertexColors(ref GpuContext gpu, scope const(ubyte[4])[] colors) @trusted {
        import engine.gpu.buffer : updateBuffer;
        if (colors.length == 0) return;
        assert(colors.length == vertexCount, "one color per vertex");
        if (colorBuffer is null)
            colorBuffer = createVertexBuffer(gpu.getDevice(), gpu.getQueue(), colors.ptr, colors.length * 4);
        else
            updateBuffer(gpu.getQueue(), colorBuffer, colors.ptr, colors.length * 4);
    }

    /// True when the mesh carries vertex colors.
    bool hasVertexColors() const pure nothrow @nogc { return colorBuffer !is null; }

    void destroy() nothrow @nogc {
        destroyBuffer(colorBuffer);
        colorBuffer = null;
        destroyBuffer(vertexBuffer);
        destroyBuffer(indexBuffer);
        vertexBuffer = null;
        indexBuffer = null;
        indexCount = 0;
        vertexCount = 0;
        vertexBufSize = 0;
        indexBufSize = 0;
    }
}

private bool skinnedIndicesFitU16(scope const(uint)[] indices) pure nothrow @nogc {
    foreach (i; indices)
        if (i > 65535) return false;
    return true;
}

private ushort[] narrowSkinnedU16(const(uint)[] indices) {
    auto dst = new ushort[indices.length];
    foreach (i, v; indices) dst[i] = cast(ushort) v;
    return dst;
}

private SkinnedMesh uploadSkinned(I)(ref GpuContext gpu, const(SkinnedVertex)[] verts, const(I)[] indices)
if (is(I == ushort) || is(I == uint)) {
    auto device = gpu.getDevice();
    auto queue = gpu.getQueue();
    SkinnedMesh m;
    m.vertexBuffer = createVertexBuffer(device, queue, verts);
    m.indexBuffer = createIndexBuffer(device, queue, indices);
    m.vertexCount = cast(uint) verts.length;
    m.indexCount = cast(uint) indices.length;
    m.vertexBufSize = verts.length * SkinnedVertex.sizeof;
    m.indexBufSize = indices.length * I.sizeof;
    m.localBounds = Aabb.fromPositions(verts);
    m.localSphere = BoundingSphere.fromAabb(m.localBounds);
    static if (is(I == uint))
        m.indexFormat = WGPUIndexFormat.uint32;
    else
        m.indexFormat = WGPUIndexFormat.uint16;
    return m;
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
        pipe.shaderModule = createShaderModule(device, skinnedShaderSource);

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
            { format: WGPUVertexFormat.uint32x4,  offset: 48, shaderLocation: 2 },
            { format: WGPUVertexFormat.float32x4, offset: 64, shaderLocation: 3 },
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
