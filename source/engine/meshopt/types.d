// Ported from meshoptimizer v1.3 (src/meshoptimizer.h), Copyright (c) 2016-2026 Arseny Kapoulkine, MIT License.
/// Public structs and enums from meshoptimizer v1.3. Bit values match upstream.
module engine.meshopt.types;

import engine.core.pod : isPod;

@safe:

/// `MESHOPTIMIZER_VERSION` for v1.3 (major * 1000 + minor * 10 + patch).
enum meshoptVersion = 1030;

/**
 * Vertex attribute stream (`meshopt_Stream`).
 *
 * `address` is the first byte (0 = null). It is stored as an integer so the
 * struct stays POD; the caller keeps the buffer alive. `stride` is the byte
 * distance between elements and is not required to be a multiple of 4.
 * `stride >= size`.
 */
struct VertexStream {
    ulong address;
    size_t size;
    size_t stride;
}

/// Build a stream over `data`. Does not require `stride % 4 == 0`.
VertexStream vertexStream(const(void)[] data, size_t size, size_t stride) pure nothrow @nogc @trusted {
    assert(stride >= size);
    assert(data.length == 0 || data.length >= size);
    VertexStream s;
    s.size = size;
    s.stride = stride;
    if (data.length)
        s.address = cast(ulong) data.ptr;
    return s;
}

/**
 * Strided float view. The byte stride is `strideFloats * 4`, so this view is
 * always a multiple of 4. Raw `VertexStream.stride` is not.
 */
struct FloatStream {
    ulong address;
    size_t strideFloats;
    size_t count;

    float[3] get3(size_t i) const pure nothrow @nogc {
        assert(i < count);
        return load3(address + i * strideFloats * float.sizeof);
    }
}

/// Zero-copy view of a `float[3]` field. `T.sizeof` must be a multiple of 4.
FloatStream positionsOf(T, string field = "pos")(const(T)[] verts) pure nothrow @nogc @trusted {
    static assert(T.sizeof % 4 == 0, "FloatStream byte stride must be a multiple of 4");
    enum off = mixin("T." ~ field ~ ".offsetof");
    alias F = typeof(mixin("T.init." ~ field));
    static assert(F.sizeof == 12, field ~ " must be a 12-byte float3");
    FloatStream s;
    s.strideFloats = T.sizeof / 4;
    s.count = verts.length;
    if (verts.length)
        s.address = cast(ulong)(cast(const(ubyte)*) verts.ptr + off);
    return s;
}

private float[3] load3(ulong address) pure nothrow @nogc @trusted {
    const(float)* p = cast(const(float)*) address;
    return [p[0], p[1], p[2]];
}

/// `meshopt_EncodeExpMode`.
enum EncodeExpMode {
    separate,
    sharedVector,
    sharedComponent,
    clamped,
}

/// `meshopt_Simplify*` bits.
enum SimplifyOptions : uint {
    none = 0,
    lockBorder = 1 << 0,
    sparse = 1 << 1,
    errorAbsolute = 1 << 2,
    prune = 1 << 3,
    regularize = 1 << 4,
    permissive = 1 << 5,
    regularizeLight = 1 << 6,
    preserveFolds = 1 << 7,
    errorClamped = 1 << 8,
}

/// `meshopt_SimplifyVertex_*` bits.
enum SimplifyVertexFlags : ubyte {
    lock = 1,
    protect = 2,
    priority = 4,
}

/// `meshopt_Tangent*` bits.
enum TangentOptions : uint {
    none = 0,
    compatible = 1 << 0,
    zeroFallback = 1 << 1,
}

/// `meshopt_Remesh*` bits. The remesher itself stays deferred.
enum RemeshOptions : uint {
    none = 0,
    shell = 1 << 0,
    solve = 1 << 1,
}

/// `meshopt_VertexCacheStatistics`.
struct VertexCacheStatistics {
    uint verticesTransformed;
    uint warpsExecuted;
    float acmr;
    float atvr;
}

/// `meshopt_VertexFetchStatistics`.
struct VertexFetchStatistics {
    uint bytesFetched;
    float overfetch;
}

/// `meshopt_OverdrawStatistics`.
struct OverdrawStatistics {
    uint pixelsCovered;
    uint pixelsShaded;
    float overdraw;
}

/// `meshopt_CoverageStatistics`.
struct CoverageStatistics {
    float[3] coverage;
    float extent;
}

/// `meshopt_Meshlet`.
struct Meshlet {
    uint vertexOffset;
    uint triangleOffset;
    uint vertexCount;
    uint triangleCount;
}

/// `meshopt_Bounds`. `coneCutoff` is cos(angle/2). S8 fields are snorm8.
struct Bounds {
    float[3] center;
    float radius;
    float[3] coneApex;
    float[3] coneAxis;
    float coneCutoff;
    byte[3] coneAxisS8;
    byte coneCutoffS8;
}

static assert(isPod!VertexStream);
static assert(isPod!FloatStream);
static assert(isPod!VertexCacheStatistics);
static assert(isPod!VertexFetchStatistics);
static assert(isPod!OverdrawStatistics);
static assert(isPod!CoverageStatistics);
static assert(isPod!Meshlet);
static assert(isPod!Bounds);

@safe pure nothrow @nogc unittest {
    static assert(EncodeExpMode.separate == 0);
    static assert(EncodeExpMode.clamped == 3);
    static assert(SimplifyOptions.lockBorder == 1);
    static assert(SimplifyOptions.errorClamped == 256);
    static assert(SimplifyVertexFlags.lock == 1);
    static assert(SimplifyVertexFlags.priority == 4);
    static assert(TangentOptions.zeroFallback == 2);
    static assert(RemeshOptions.solve == 2);
    static assert(meshoptVersion == 1030);

    ubyte[8] raw = [1, 2, 3, 4, 5, 6, 0, 0];
    VertexStream odd = vertexStream(raw[], 6, 6);
    assert(odd.stride == 6 && odd.stride % 4 != 0);
    assert(odd.size == 6);

    static struct V {
        float[3] pos;
        float[2] uv;
    }

    V[2] verts;
    verts[0].pos = [1, 2, 3];
    verts[1].pos = [4, 5, 6];
    FloatStream fs = positionsOf!V(verts[]);
    assert(fs.count == 2);
    assert(fs.strideFloats == V.sizeof / 4);
    float[3] a = fs.get3(0);
    float[3] b = fs.get3(1);
    assert(a == [1, 2, 3]);
    assert(b == [4, 5, 6]);
}
