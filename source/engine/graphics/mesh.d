/// GPU mesh handle — owns vertex/index buffers for a 3D shape.
module engine.graphics.mesh;

import bindings.wgpu : WGPUBuffer;
import engine.gpu.buffer;
import engine.gpu.context : GpuContext;
import engine.graphics.types : Vert;
import engine.graphics.primitives;

@safe:

struct Mesh {
    package(engine) WGPUBuffer vertexBuffer;
    package(engine) WGPUBuffer indexBuffer;
    package(engine) uint indexCount;
    package(engine) ulong vertexBufSize;

    @disable this(this);

    // --- Built-in primitive factories ---

    static Mesh cube(ref GpuContext gpu) {
        return fromData(gpu, cubeVertices[], cubeIndices[]);
    }

    static Mesh pyramid(ref GpuContext gpu) {
        return fromData(gpu, pyramidVertices[], pyramidIndices[]);
    }

    static Mesh diamond(ref GpuContext gpu) {
        return fromData(gpu, diamondVertices[], diamondIndices[]);
    }

    /// Create a mesh from custom vertex/index data.
    static Mesh fromData(ref GpuContext gpu, const(Vert)[] verts, const(ushort)[] indices) {
        auto device = gpu.getDevice();
        auto queue  = gpu.getQueue();
        Mesh m;
        m.vertexBuffer  = createVertexBuffer(device, queue, verts);
        m.indexBuffer   = createIndexBuffer(device, queue, indices);
        m.indexCount    = cast(uint) indices.length;
        m.vertexBufSize = verts.length * Vert.sizeof;
        return m;
    }

    void destroy() nothrow @nogc {
        destroyBuffer(vertexBuffer);
        destroyBuffer(indexBuffer);
        vertexBuffer = null;
        indexBuffer = null;
    }
}
