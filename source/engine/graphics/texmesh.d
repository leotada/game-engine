/// Textured mesh (position + normal + uv) and built-in textured primitives.
module engine.graphics.texmesh;

import bindings.wgpu : WGPUBuffer, WGPUIndexFormat;
import engine.gpu.buffer;
import engine.gpu.context : GpuContext;
import engine.graphics.types : TexTanVert, TexVert;

@safe:

/// Shadow pass range. `useLodRange` means draw `indexBuffer[first .. first + count]`.
struct ShadowLodDraw {
    bool useLodRange;
    uint first;
    uint count;
}

/// Owned GPU mesh with UV-equipped vertices (TexVert, stride 32).
struct TexMesh {
    package(engine) WGPUBuffer vertexBuffer;
    package(engine) WGPUBuffer indexBuffer;
    /// Position-welded index buffer. Null when the mesh has no shadow indices.
    package(engine) WGPUBuffer shadowIndexBuffer;
    package(engine) uint indexCount;
    package(engine) ulong vertexBufSize;
    package(engine) ulong indexBufSize;
    package(engine) ulong shadowIndexBufSize;
    package(engine) WGPUIndexFormat indexFormat;
    /// Byte stride of `vertexBuffer`. 32 for `TexVert`, 48 for `TexTanVert`.
    package(engine) uint vertexStride;
    /// Concatenated LOD index ranges in `indexBuffer`. 0 or 1 means no chain.
    package(engine) ubyte lodLevels;
    package(engine) uint[8] lodFirst;
    package(engine) uint[8] lodDrawCount;

    @disable this(this);

    /// Build a TexMesh from vertex + index data.
    /// `uint` indices are stored as `ushort` when every index fits in 65535.
    static TexMesh fromData(I)(ref GpuContext gpu, const(TexVert)[] verts, const(I)[] indices, const(I)[] shadowIndices = null)
    if (is(I == ushort) || is(I == uint)) {
        static if (is(I == uint)) {
            if (indicesFitU16(indices) && indicesFitU16(shadowIndices))
                return fromData(gpu, verts, narrowU16(indices), narrowU16(shadowIndices));
        }
        return upload!TexVert(gpu, verts, indices, shadowIndices);
    }

    /// `TexTanVert` upload. Stride is 48. `uint` indices narrow when every index fits in 65535.
    static TexMesh fromData(I)(ref GpuContext gpu, const(TexTanVert)[] verts, const(I)[] indices, const(I)[] shadowIndices = null)
    if (is(I == ushort) || is(I == uint)) {
        static if (is(I == uint)) {
            if (indicesFitU16(indices) && indicesFitU16(shadowIndices))
                return fromData(gpu, verts, narrowU16(indices), narrowU16(shadowIndices));
        }
        return upload!TexTanVert(gpu, verts, indices, shadowIndices);
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
    /// `withTangents` builds a `TexTanVert` sphere for normal-mapped draws.
    static TexMesh sphere(ref GpuContext gpu, uint segments = 32, uint rings = 16, bool withTangents = false) {
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
        if (!withTangents)
            return fromData(gpu, verts, indices);
        return uploadSphereTangents(gpu, verts, indices);
    }

    /// Index buffer the shadow pass binds. The color pass keeps `indexBuffer`.
    WGPUBuffer shadowDrawBuffer() pure nothrow @nogc {
        return shadowIndexBuffer !is null ? shadowIndexBuffer : indexBuffer;
    }

    /// Byte size of `shadowDrawBuffer`.
    ulong shadowDrawBytes() const pure nothrow @nogc {
        return shadowIndexBuffer !is null ? shadowIndexBufSize : indexBufSize;
    }

    /// Record concatenated LOD ranges. `first.length` is the level count (max 8).
    void setLodChain(scope const(uint)[] first, scope const(uint)[] counts) pure nothrow @nogc {
        assert(first.length == counts.length && first.length <= 8);
        lodLevels = cast(ubyte) first.length;
        foreach (i; 0 .. 8) {
            lodFirst[i] = i < first.length ? first[i] : 0;
            lodDrawCount[i] = i < counts.length ? counts[i] : 0;
        }
    }

    /**
     * Shadow draw of the coarser LOD (`colorLod + 1`).
     * `useLodRange` selects `indexBuffer` at `first`. Otherwise the caller
     * keeps the position-welded shadow index buffer and `indexCount`.
     */
    ShadowLodDraw shadowLodDraw(ubyte colorLod = ubyte.max) const pure nothrow @nogc {
        ShadowLodDraw draw;
        draw.count = indexCount;
        if (lodLevels <= 1)
            return draw;
        uint level = colorLod == ubyte.max ? 1 : cast(uint) colorLod + 1;
        if (level >= lodLevels)
            level = lodLevels - 1;
        draw.useLodRange = true;
        draw.first = lodFirst[level];
        draw.count = lodDrawCount[level];
        return draw;
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

private TexMesh uploadSphereTangents(ref GpuContext gpu, TexVert[] verts, ushort[] indices) {
    import engine.meshopt.pipeline : optimizeMesh;
    import engine.meshopt.tangent : generateTangents;
    import engine.meshopt.types : FloatStream, TangentOptions, positionsOf;

    uint[] idx = new uint[indices.length];
    foreach (i, v; indices)
        idx[i] = v;
    float[4][] corners = new float[4][](idx.length);
    FloatStream uvs;
    uvs.strideFloats = TexVert.sizeof / 4;
    uvs.count = verts.length;
    uvs.address = () @trusted {
        return verts.length ? cast(ulong)(cast(ubyte*) verts.ptr + TexVert.uv.offsetof) : 0;
    }();
    generateTangents(corners, idx, positionsOf!TexVert(verts), positionsOf!(TexVert, "normal")(verts), uvs, TangentOptions.compatible);
    TexTanVert[] expanded = new TexTanVert[idx.length];
    foreach (i, id; idx) {
        expanded[i].pos = verts[id].pos;
        expanded[i].normal = verts[id].normal;
        expanded[i].uv = verts[id].uv;
        expanded[i].tangent = corners[i];
        idx[i] = cast(uint) i;
    }
    auto opt = optimizeMesh(expanded, idx);
    return TexMesh.fromData(gpu, opt.vertices, opt.indices, opt.shadowIndices);
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

private TexMesh upload(V, I)(ref GpuContext gpu, const(V)[] verts, const(I)[] indices, const(I)[] shadowIndices)
if ((is(I == ushort) || is(I == uint)) && V.sizeof % 4 == 0) {
    auto device = gpu.getDevice();
    auto queue = gpu.getQueue();
    TexMesh m;
    m.vertexBuffer = createVertexBuffer(device, queue, verts);
    m.indexBuffer = createIndexBuffer(device, queue, indices);
    m.indexCount = cast(uint) indices.length;
    m.vertexBufSize = verts.length * V.sizeof;
    m.indexBufSize = indices.length * I.sizeof;
    m.vertexStride = cast(uint) V.sizeof;
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

@("texmesh.shadowLod") pure nothrow @nogc unittest {
    TexMesh mesh;
    mesh.indexCount = 30;
    assert(!mesh.shadowLodDraw().useLodRange);
    assert(mesh.shadowLodDraw().count == 30);
    mesh.setLodChain([0u, 30, 48], [30u, 18, 9]);
    ShadowLodDraw coarse = mesh.shadowLodDraw();
    assert(coarse.useLodRange);
    assert(coarse.first == 30 && coarse.count == 18);
    ShadowLodDraw fromCurrent = mesh.shadowLodDraw(1);
    assert(fromCurrent.first == 48 && fromCurrent.count == 9);
    ShadowLodDraw clamped = mesh.shadowLodDraw(2);
    assert(clamped.first == 48 && clamped.count == 9);
}
