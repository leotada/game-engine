/// Textured mesh (position + normal + uv) and built-in textured primitives.
module engine.graphics.texmesh;

import bindings.wgpu : WGPUBuffer, WGPUIndexFormat;
import engine.gpu.buffer;
import engine.gpu.context : GpuContext;
import engine.graphics.types : TexTanVert, TexVert;
import engine.math.bounds : Aabb, BoundingSphere;

@safe:

/// Shadow pass range. `useLodRange` means draw `indexBuffer[first .. first + count]`.
struct ShadowLodDraw {
    bool useLodRange;
    uint first;
    uint count;
}

/// Index range for one color LOD level.
struct LodRange {
    uint first;
    uint count;
}

/// Owned GPU mesh with UV-equipped vertices (TexVert, stride 32).
struct TexMesh {
    package(engine) WGPUBuffer vertexBuffer;
    package(engine) WGPUBuffer indexBuffer;
    /// Position-welded index buffer. Null when the mesh has no shadow indices.
    package(engine) WGPUBuffer shadowIndexBuffer;
    /// Optional vertex colors (RGBA8, linear), see `setVertexColors`. Null = white.
    package(engine) WGPUBuffer colorBuffer;
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
    /// Mesh-relative simplifier error per LOD (`buildLodChain`), for screen-space selection.
    package(engine) float[8] lodErrors;
    /// `simplifyScale` of the vertex buffer: converts relative errors to object units.
    package(engine) float lodMeshScale = 1;
    /// Object-space bounds computed from the vertex positions at upload.
    Aabb localBounds;
    /// Object-space bounding sphere (from `localBounds`), used for culling.
    BoundingSphere localSphere;

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

    /// Color-pass index range for `lod`. Without a chain this is the whole
    /// index buffer; levels past the chain clamp to the coarsest one.
    LodRange colorLodRange(ubyte lod = 0) const pure nothrow @nogc {
        if (lodLevels <= 1)
            return LodRange(0, indexCount);
        immutable l = lod < lodLevels ? lod : lodLevels - 1;
        return LodRange(lodFirst[l], lodDrawCount[l]);
    }

    /// True when `localBounds` was computed (any non-empty upload).
    bool hasBounds() const pure nothrow @nogc { return !localBounds.empty; }

    /// Number of LOD levels (1 when the mesh has no chain).
    ubyte lodCount() const pure nothrow @nogc { return lodLevels <= 1 ? 1 : lodLevels; }

    /// Index buffer the shadow pass binds. The color pass keeps `indexBuffer`.
    WGPUBuffer shadowDrawBuffer() pure nothrow @nogc {
        return shadowIndexBuffer !is null ? shadowIndexBuffer : indexBuffer;
    }

    /// Byte size of `shadowDrawBuffer`.
    ulong shadowDrawBytes() const pure nothrow @nogc {
        return shadowIndexBuffer !is null ? shadowIndexBufSize : indexBufSize;
    }

    /// Record concatenated LOD ranges. `first.length` is the level count (max 8).
    /// `errors` are the mesh-relative simplifier errors per level and
    /// `meshScale` the `simplifyScale` of the vertex buffer; both drive
    /// automatic screen-space LOD selection.
    void setLodChain(scope const(uint)[] first, scope const(uint)[] counts,
                     scope const(float)[] errors = null, float meshScale = 1) pure nothrow @nogc {
        assert(first.length == counts.length && first.length <= 8);
        assert(errors.length == 0 || errors.length == first.length);
        lodLevels = cast(ubyte) first.length;
        lodMeshScale = meshScale;
        foreach (i; 0 .. 8) {
            lodFirst[i] = i < first.length ? first[i] : 0;
            lodDrawCount[i] = i < counts.length ? counts[i] : 0;
            lodErrors[i] = i < errors.length ? errors[i] : 0;
        }
    }

    /// Simplifier errors of the chain (empty without a chain).
    const(float)[] lodErrorList() const return pure nothrow @nogc {
        return lodLevels <= 1 ? null : lodErrors[0 .. lodLevels];
    }

    /// Update vertex buffer contents in-place without reallocating GPU memory.
    void updateVertices(V)(ref GpuContext gpu, scope const(V)[] verts) nothrow @nogc
    if (is(V == TexVert) || is(V == TexTanVert)) {
        assert(verts.length * V.sizeof == vertexBufSize && V.sizeof == vertexStride);
        () @trusted {
            updateBuffer(gpu.getQueue(), vertexBuffer, verts.ptr, verts.length * V.sizeof);
        }();
    }

    /**
     * Shadow draw of the coarser LOD (`colorLod + 1`).
     * `useLodRange` selects `indexBuffer` at `first`. Otherwise the caller
     * keeps the position-welded shadow index buffer and `indexCount`.
     */
    /// `masked` casters need the full vertices (UVs), so they never use the
    /// position-only shadow indices.
    ShadowLodDraw shadowLodDraw(ubyte colorLod = ubyte.max, bool masked = false) const pure nothrow @nogc {
        ShadowLodDraw draw;
        draw.count = indexCount;
        draw.useLodRange = masked;
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

    /// Attach (or replace) per-vertex colors: one linear RGBA8 value per vertex,
    /// multiplied into base color and opacity. They live in their own stream,
    /// so meshes without colors keep their vertex size. An empty list is a no-op.
    void setVertexColors(ref GpuContext gpu, scope const(ubyte[4])[] colors) @trusted {
        if (colors.length == 0) return;
        assert(colors.length * vertexStride == vertexBufSize, "one color per vertex");
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
    m.localBounds = Aabb.fromPositions(verts);
    m.localSphere = BoundingSphere.fromAabb(m.localBounds);
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
    TexMesh plain;
    plain.indexCount = 30;
    immutable masked = plain.shadowLodDraw(0, true);
    assert(masked.useLodRange && masked.first == 0 && masked.count == 30);
}

@("texmesh.colorLodRange") pure nothrow @nogc unittest {
    TexMesh mesh;
    mesh.indexCount = 57;
    assert(mesh.colorLodRange() == LodRange(0, 57));
    assert(mesh.colorLodRange(3) == LodRange(0, 57));
    assert(mesh.lodCount == 1);
    // Concatenated chain: color LOD0 must not draw the coarser levels too.
    mesh.setLodChain([0u, 30, 48], [30u, 18, 9]);
    assert(mesh.colorLodRange(0) == LodRange(0, 30));
    assert(mesh.colorLodRange(1) == LodRange(30, 18));
    assert(mesh.colorLodRange(2) == LodRange(48, 9));
    assert(mesh.colorLodRange(7) == LodRange(48, 9));
    assert(mesh.lodCount == 3);
}
