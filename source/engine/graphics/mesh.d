/// GPU mesh handle — owns vertex/index buffers for a 3D shape.
module engine.graphics.mesh;

import bindings.wgpu : WGPUBuffer, WGPUIndexFormat;
import engine.gpu.buffer;
import engine.gpu.context : GpuContext;
import engine.graphics.types : Vert;
import engine.graphics.primitives;

@safe:

struct Mesh {
    package(engine) WGPUBuffer vertexBuffer;
    package(engine) WGPUBuffer indexBuffer;
    /// Position-welded index buffer. Null when the mesh has no shadow indices.
    package(engine) WGPUBuffer shadowIndexBuffer;
    package(engine) uint indexCount;
    package(engine) ulong vertexBufSize;
    package(engine) ulong indexBufSize;
    package(engine) ulong shadowIndexBufSize;
    package(engine) WGPUIndexFormat indexFormat;
    /// Byte stride of `vertexBuffer` (`Vert.sizeof`).
    package(engine) uint vertexStride;

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

    static Mesh sphere(ref GpuContext gpu) {
        return fromData(gpu, sphereVertices[], sphereIndices[]);
    }

    static Mesh plane(ref GpuContext gpu) {
        return fromData(gpu, planeVertices[], planeIndices[]);
    }

    /// Create a mesh from custom vertex/index data.
    static Mesh fromData(I)(ref GpuContext gpu, const(Vert)[] verts, const(I)[] indices, const(I)[] shadowIndices = null)
    if (is(I == ushort) || is(I == uint)) {
        static if (is(I == uint)) {
            if (indicesFitU16(indices) && indicesFitU16(shadowIndices))
                return fromData(gpu, verts, narrowU16(indices), narrowU16(shadowIndices));
        }
        return upload(gpu, verts, indices, shadowIndices);
    }

    /// Index buffer the shadow pass binds. The color pass keeps `indexBuffer`.
    WGPUBuffer shadowDrawBuffer() pure nothrow @nogc {
        return shadowIndexBuffer !is null ? shadowIndexBuffer : indexBuffer;
    }

    /// Byte size of `shadowDrawBuffer`.
    ulong shadowDrawBytes() const pure nothrow @nogc {
        return shadowIndexBuffer !is null ? shadowIndexBufSize : indexBufSize;
    }

    void destroy() nothrow @nogc {
        destroyBuffer(vertexBuffer);
        destroyBuffer(indexBuffer);
        destroyBuffer(shadowIndexBuffer);
        vertexBuffer = null;
        indexBuffer = null;
        shadowIndexBuffer = null;
    }
}

private bool indicesFitU16(scope const(uint)[] indices) pure nothrow @nogc {
    foreach (i; indices) {
        if (i > 65535)
            return false;
    }
    return true;
}

private ushort[] narrowU16(const(uint)[] indices) {
    auto dst = new ushort[indices.length];
    foreach (i, v; indices)
        dst[i] = cast(ushort) v;
    return dst;
}

private Mesh upload(I)(ref GpuContext gpu, const(Vert)[] verts, const(I)[] indices, const(I)[] shadowIndices)
if (is(I == ushort) || is(I == uint)) {
    auto device = gpu.getDevice();
    auto queue = gpu.getQueue();
    Mesh m;
    m.vertexBuffer = createVertexBuffer(device, queue, verts);
    m.indexBuffer = createIndexBuffer(device, queue, indices);
    m.indexCount = cast(uint) indices.length;
    m.vertexBufSize = verts.length * Vert.sizeof;
    m.indexBufSize = indices.length * I.sizeof;
    m.vertexStride = Vert.sizeof;
    static if (is(I == uint))
        m.indexFormat = WGPUIndexFormat.uint32;
    else
        m.indexFormat = WGPUIndexFormat.uint16;
    if (shadowIndices.length) {
        m.shadowIndexBuffer = createIndexBuffer(device, queue, shadowIndices);
        m.shadowIndexBufSize = shadowIndices.length * I.sizeof;
    }
    return m;
}
