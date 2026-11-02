/// C++ oracle entry points. This module is not part of the engine library.
/// Real symbols are compiled only with `-version=MeshoptOracle`.
module meshopt_oracle_capi;

/// C layout of `meshopt_Stream` (pointer, not the engine's `ulong` address).
struct RefStream {
    const(void)* data;
    size_t size;
    size_t stride;
}

alias MeshoptPred = extern (C) int function(void*, uint, uint) nothrow @nogc;

extern (C) int meshoptOraclePredTrue(void*, uint, uint) nothrow @nogc {
    return 1;
}

extern (C) int meshoptOraclePredFalse(void*, uint, uint) nothrow @nogc {
    return 0;
}

version (MeshoptOracle)
extern (C) nothrow @nogc {
    ushort meshopt_quantizeHalf(float v);
    float meshopt_quantizeFloat(float v, int n);
    float meshopt_dequantizeHalf(ushort h);
    int meshopt_computePositionExponent(const(float)* minv, const(float)* maxv, int minExp, int maxBits);
    int meshopt_ref_quantizeUnorm(float v, int n);
    int meshopt_ref_quantizeSnorm(float v, int n);

    size_t meshopt_generateVertexRemap(uint* destination, const(uint)* indices, size_t indexCount, const(void)* vertices, size_t vertexCount, size_t vertexSize);
    size_t meshopt_generateVertexRemapMulti(uint* destination, const(uint)* indices, size_t indexCount, size_t vertexCount, const(RefStream)* streams, size_t streamCount);
    size_t meshopt_generateVertexRemapCustom(uint* destination, const(uint)* indices, size_t indexCount, const(float)* positions, size_t vertexCount, size_t positionStride, MeshoptPred callback, void* context);
    void meshopt_remapVertexBuffer(void* destination, const(void)* vertices, size_t vertexCount, size_t vertexSize, const(uint)* remap);
    void meshopt_remapIndexBuffer(uint* destination, const(uint)* indices, size_t indexCount, const(uint)* remap);
    size_t meshopt_filterIndexBuffer(uint* destination, const(uint)* indices, size_t indexCount, const(void)* vertices, size_t vertexCount, size_t vertexSize, size_t vertexStride);
    size_t meshopt_filterIndexBufferMulti(uint* destination, const(uint)* indices, size_t indexCount, size_t vertexCount, const(RefStream)* streams, size_t streamCount);
    void meshopt_generateShadowIndexBuffer(uint* destination, const(uint)* indices, size_t indexCount, const(void)* vertices, size_t vertexCount, size_t vertexSize, size_t vertexStride);
    void meshopt_generateShadowIndexBufferMulti(uint* destination, const(uint)* indices, size_t indexCount, size_t vertexCount, const(RefStream)* streams, size_t streamCount);
    void meshopt_generatePositionRemap(uint* destination, const(float)* positions, size_t vertexCount, size_t positionStride);
    void meshopt_generateAdjacencyIndexBuffer(uint* destination, const(uint)* indices, size_t indexCount, const(float)* positions, size_t vertexCount, size_t positionStride);
    void meshopt_generateTessellationIndexBuffer(uint* destination, const(uint)* indices, size_t indexCount, const(float)* positions, size_t vertexCount, size_t positionStride);
    size_t meshopt_generateProvokingIndexBuffer(uint* destination, uint* reorder, const(uint)* indices, size_t indexCount, size_t vertexCount);
}

version (MeshoptOracle) {

ushort refQuantizeHalf(float v) nothrow @nogc @trusted {
    return meshopt_quantizeHalf(v);
}

float refQuantizeFloat(float v, int n) nothrow @nogc @trusted {
    return meshopt_quantizeFloat(v, n);
}

float refDequantizeHalf(ushort h) nothrow @nogc @trusted {
    return meshopt_dequantizeHalf(h);
}

int refQuantizeUnorm(float v, int n) nothrow @nogc @trusted {
    return meshopt_ref_quantizeUnorm(v, n);
}

int refQuantizeSnorm(float v, int n) nothrow @nogc @trusted {
    return meshopt_ref_quantizeSnorm(v, n);
}

int refPositionExponent(const(float)[3] minv, const(float)[3] maxv, int minExp, int maxBits) nothrow @nogc @trusted {
    return meshopt_computePositionExponent(&minv[0], &maxv[0], minExp, maxBits);
}

size_t refGenerateVertexRemap(scope uint[] destination, scope const(uint)[] indices, scope const(ubyte)[] vertices, size_t vertexCount, size_t vertexSize) nothrow @nogc @trusted {
    const(uint)* ip = indices.length ? indices.ptr : null;
    size_t indexCount = indices.length ? indices.length : vertexCount;
    const(void)* vp = vertices.length ? vertices.ptr : null;
    return meshopt_generateVertexRemap(destination.ptr, ip, indexCount, vp, vertexCount, vertexSize);
}

size_t refGenerateVertexRemapMulti(scope uint[] destination, scope const(uint)[] indices, size_t vertexCount, scope const(RefStream)[] streams) nothrow @nogc @trusted {
    const(uint)* ip = indices.length ? indices.ptr : null;
    size_t indexCount = indices.length ? indices.length : vertexCount;
    return meshopt_generateVertexRemapMulti(destination.ptr, ip, indexCount, vertexCount, streams.ptr, streams.length);
}

size_t refGenerateVertexRemapCustom(scope uint[] destination, scope const(uint)[] indices, scope const(float)[] positions, size_t vertexCount, size_t positionStride, MeshoptPred pred) nothrow @nogc @trusted {
    const(uint)* ip = indices.length ? indices.ptr : null;
    size_t indexCount = indices.length ? indices.length : vertexCount;
    const(float)* pp = positions.length ? positions.ptr : null;
    return meshopt_generateVertexRemapCustom(destination.ptr, ip, indexCount, pp, vertexCount, positionStride, pred, null);
}

void refRemapVertexBuffer(scope ubyte[] destination, scope const(ubyte)[] vertices, size_t vertexCount, size_t vertexSize, scope const(uint)[] remap) nothrow @nogc @trusted {
    meshopt_remapVertexBuffer(destination.ptr, vertices.ptr, vertexCount, vertexSize, remap.ptr);
}

void refRemapIndexBuffer(scope uint[] destination, scope const(uint)[] indices, scope const(uint)[] remap) nothrow @nogc @trusted {
    const(uint)* ip = indices.length ? indices.ptr : null;
    size_t indexCount = indices.length ? indices.length : destination.length;
    meshopt_remapIndexBuffer(destination.ptr, ip, indexCount, remap.ptr);
}

size_t refFilterIndexBuffer(scope uint[] destination, scope const(uint)[] indices, scope const(ubyte)[] vertices, size_t vertexCount, size_t vertexSize, size_t vertexStride) nothrow @nogc @trusted {
    const(void)* vp = vertices.length ? vertices.ptr : null;
    return meshopt_filterIndexBuffer(destination.ptr, indices.ptr, indices.length, vp, vertexCount, vertexSize, vertexStride);
}

size_t refFilterIndexBufferMulti(scope uint[] destination, scope const(uint)[] indices, size_t vertexCount, scope const(RefStream)[] streams) nothrow @nogc @trusted {
    return meshopt_filterIndexBufferMulti(destination.ptr, indices.ptr, indices.length, vertexCount, streams.ptr, streams.length);
}

void refGenerateShadowIndexBuffer(scope uint[] destination, scope const(uint)[] indices, scope const(ubyte)[] vertices, size_t vertexCount, size_t vertexSize, size_t vertexStride) nothrow @nogc @trusted {
    const(void)* vp = vertices.length ? vertices.ptr : null;
    meshopt_generateShadowIndexBuffer(destination.ptr, indices.ptr, indices.length, vp, vertexCount, vertexSize, vertexStride);
}

void refGenerateShadowIndexBufferMulti(scope uint[] destination, scope const(uint)[] indices, size_t vertexCount, scope const(RefStream)[] streams) nothrow @nogc @trusted {
    meshopt_generateShadowIndexBufferMulti(destination.ptr, indices.ptr, indices.length, vertexCount, streams.ptr, streams.length);
}

void refGeneratePositionRemap(scope uint[] destination, scope const(float)[] positions, size_t vertexCount, size_t positionStride) nothrow @nogc @trusted {
    const(float)* pp = positions.length ? positions.ptr : null;
    meshopt_generatePositionRemap(destination.ptr, pp, vertexCount, positionStride);
}

void refGenerateAdjacencyIndexBuffer(scope uint[] destination, scope const(uint)[] indices, scope const(float)[] positions, size_t vertexCount, size_t positionStride) nothrow @nogc @trusted {
    const(float)* pp = positions.length ? positions.ptr : null;
    meshopt_generateAdjacencyIndexBuffer(destination.ptr, indices.ptr, indices.length, pp, vertexCount, positionStride);
}

void refGenerateTessellationIndexBuffer(scope uint[] destination, scope const(uint)[] indices, scope const(float)[] positions, size_t vertexCount, size_t positionStride) nothrow @nogc @trusted {
    const(float)* pp = positions.length ? positions.ptr : null;
    meshopt_generateTessellationIndexBuffer(destination.ptr, indices.ptr, indices.length, pp, vertexCount, positionStride);
}

size_t refGenerateProvokingIndexBuffer(scope uint[] destination, scope uint[] reorder, scope const(uint)[] indices, size_t vertexCount) nothrow @nogc @trusted {
    return meshopt_generateProvokingIndexBuffer(destination.ptr, reorder.ptr, indices.ptr, indices.length, vertexCount);
}
} else {
ushort refQuantizeHalf(float) nothrow @nogc {
    return 0;
}

float refQuantizeFloat(float, int) nothrow @nogc {
    return 0;
}

float refDequantizeHalf(ushort) nothrow @nogc {
    return 0;
}

int refQuantizeUnorm(float, int) nothrow @nogc {
    return 0;
}

int refQuantizeSnorm(float, int) nothrow @nogc {
    return 0;
}

int refPositionExponent(const(float)[3], const(float)[3], int, int) nothrow @nogc {
    return 0;
}
}
