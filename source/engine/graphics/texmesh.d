/// Textured mesh (position + normal + uv) and built-in textured primitives.
module engine.graphics.texmesh;

import bindings.wgpu : WGPUBuffer;
import engine.gpu.buffer;
import engine.gpu.context : GpuContext;
import engine.graphics.types : TexVert;

@safe:

/// Owned GPU mesh with UV-equipped vertices (TexVert).
struct TexMesh {
    package(engine) WGPUBuffer vertexBuffer;
    package(engine) WGPUBuffer indexBuffer;
    package(engine) uint indexCount;
    package(engine) ulong vertexBufSize;

    @disable this(this);

    /// Build a TexMesh from vertex + index data.
    static TexMesh fromData(ref GpuContext gpu,
                            const(TexVert)[] verts,
                            const(ushort)[] indices) {
        auto device = gpu.getDevice();
        auto queue  = gpu.getQueue();
        TexMesh m;
        m.vertexBuffer  = createVertexBuffer(device, queue, verts);
        m.indexBuffer   = createIndexBuffer(device, queue, indices);
        m.indexCount    = cast(uint) indices.length;
        m.vertexBufSize = verts.length * TexVert.sizeof;
        return m;
    }

    /// Textured unit cube with per-face UVs (0..1 on each face).
    static TexMesh cube(ref GpuContext gpu) {
        return fromData(gpu, texCubeVertices[], texCubeIndices[]);
    }

    /// Textured unit quad on the XZ plane (useful for ground planes, walls, sprites).
    /// Normal points +Y. Size: 1×1 centered at origin.
    static TexMesh quad(ref GpuContext gpu) {
        return fromData(gpu, texQuadVertices[], texQuadIndices[]);
    }

    /// UV sphere of radius 0.5 centered at origin (unit diameter).
    /// `segments` = longitude subdivisions, `rings` = latitude subdivisions.
    static TexMesh sphere(ref GpuContext gpu, uint segments = 32, uint rings = 16) {
        import std.math : sin, cos, PI;
        assert(segments >= 3 && rings >= 2);

        immutable uint vertCount = (rings + 1) * (segments + 1);
        auto verts = new TexVert[vertCount];
        auto indices = new ushort[rings * segments * 6];

        uint vi = 0;
        foreach (y; 0 .. rings + 1) {
            immutable v = cast(float) y / cast(float) rings;
            immutable phi = v * PI;
            immutable sy = cast(float) cos(phi);
            immutable sr = cast(float) sin(phi);
            foreach (x; 0 .. segments + 1) {
                immutable u = cast(float) x / cast(float) segments;
                immutable theta = u * 2.0f * PI;
                immutable nx = sr * cast(float) cos(theta);
                immutable nz = sr * cast(float) sin(theta);
                verts[vi++] = TexVert([nx * 0.5f, sy * 0.5f, nz * 0.5f],
                                      [nx, sy, nz], [u, 1.0f - v]);
            }
        }

        uint ii = 0;
        foreach (y; 0 .. rings) {
            foreach (x; 0 .. segments) {
                immutable ushort a = cast(ushort)(y * (segments + 1) + x);
                immutable ushort b = cast(ushort)(a + segments + 1);
                indices[ii++] = a;
                indices[ii++] = cast(ushort)(a + 1);
                indices[ii++] = b;
                indices[ii++] = cast(ushort)(a + 1);
                indices[ii++] = cast(ushort)(b + 1);
                indices[ii++] = b;
            }
        }
        return fromData(gpu, verts, indices);
    }

    void destroy() nothrow @nogc {
        destroyBuffer(vertexBuffer);
        destroyBuffer(indexBuffer);
        vertexBuffer = null;
        indexBuffer = null;
    }
}

// ---------------------------------------------------------------------------
// Textured cube — 24 verts, 36 indices. UVs: each face covers 0..1.
// ---------------------------------------------------------------------------
immutable TexVert[24] texCubeVertices = [
    // Front (+Z)
    TexVert([-0.5,-0.5, 0.5], [ 0, 0, 1], [0, 1]),
    TexVert([ 0.5,-0.5, 0.5], [ 0, 0, 1], [1, 1]),
    TexVert([ 0.5, 0.5, 0.5], [ 0, 0, 1], [1, 0]),
    TexVert([-0.5, 0.5, 0.5], [ 0, 0, 1], [0, 0]),
    // Back (-Z)
    TexVert([ 0.5,-0.5,-0.5], [ 0, 0,-1], [0, 1]),
    TexVert([-0.5,-0.5,-0.5], [ 0, 0,-1], [1, 1]),
    TexVert([-0.5, 0.5,-0.5], [ 0, 0,-1], [1, 0]),
    TexVert([ 0.5, 0.5,-0.5], [ 0, 0,-1], [0, 0]),
    // Right (+X)
    TexVert([ 0.5,-0.5, 0.5], [ 1, 0, 0], [0, 1]),
    TexVert([ 0.5,-0.5,-0.5], [ 1, 0, 0], [1, 1]),
    TexVert([ 0.5, 0.5,-0.5], [ 1, 0, 0], [1, 0]),
    TexVert([ 0.5, 0.5, 0.5], [ 1, 0, 0], [0, 0]),
    // Left (-X)
    TexVert([-0.5,-0.5,-0.5], [-1, 0, 0], [0, 1]),
    TexVert([-0.5,-0.5, 0.5], [-1, 0, 0], [1, 1]),
    TexVert([-0.5, 0.5, 0.5], [-1, 0, 0], [1, 0]),
    TexVert([-0.5, 0.5,-0.5], [-1, 0, 0], [0, 0]),
    // Top (+Y)
    TexVert([-0.5, 0.5, 0.5], [ 0, 1, 0], [0, 1]),
    TexVert([ 0.5, 0.5, 0.5], [ 0, 1, 0], [1, 1]),
    TexVert([ 0.5, 0.5,-0.5], [ 0, 1, 0], [1, 0]),
    TexVert([-0.5, 0.5,-0.5], [ 0, 1, 0], [0, 0]),
    // Bottom (-Y)
    TexVert([-0.5,-0.5,-0.5], [ 0,-1, 0], [0, 1]),
    TexVert([ 0.5,-0.5,-0.5], [ 0,-1, 0], [1, 1]),
    TexVert([ 0.5,-0.5, 0.5], [ 0,-1, 0], [1, 0]),
    TexVert([-0.5,-0.5, 0.5], [ 0,-1, 0], [0, 0]),
];

immutable ushort[36] texCubeIndices = [
     0, 1, 2,  2, 3, 0,
     4, 5, 6,  6, 7, 4,
     8, 9,10, 10,11, 8,
    12,13,14, 14,15,12,
    16,17,18, 18,19,16,
    20,21,22, 22,23,20,
];

// ---------------------------------------------------------------------------
// Textured quad on XZ plane (Y up).
// ---------------------------------------------------------------------------
immutable TexVert[4] texQuadVertices = [
    TexVert([-0.5, 0,-0.5], [0, 1, 0], [0, 0]),
    TexVert([ 0.5, 0,-0.5], [0, 1, 0], [1, 0]),
    TexVert([ 0.5, 0, 0.5], [0, 1, 0], [1, 1]),
    TexVert([-0.5, 0, 0.5], [0, 1, 0], [0, 1]),
];

immutable ushort[6] texQuadIndices = [0, 2, 1,  0, 3, 2];
