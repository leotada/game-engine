/// WGPU compute light binning for Clustered Forward rendering (`engine.scene.scene3d_textured`).
/// Subdivides the camera frustum into `16 × 9 × 24` view-space clusters with exponential
/// depth slicing and bins active point and spot lights per frame via `clustered_cull_cs.wgsl`.
module engine.gpu.clustered;

import std.math : floor, log, sqrt;

import bindings.wgpu;
import engine.core.log;
import engine.core.pod : isPod;
import engine.gpu.buffer;
import engine.gpu.shader : createShaderModule, isValidUniformStruct;
import engine.gpu.shaders : clusterCullCsShaderSource;
import engine.math.mat : Mat4;
import engine.math.vec : Vec3, Vec4;
import engine.scene.camera : Camera;

@safe:

private immutable string kClusterCullCsWgsl = clusterCullCsShaderSource;

enum uint CLUSTER_GRID_X = 16;
enum uint CLUSTER_GRID_Y = 9;
enum uint CLUSTER_GRID_Z = 24;
enum uint CLUSTER_COUNT = CLUSTER_GRID_X * CLUSTER_GRID_Y * CLUSTER_GRID_Z; // 3456
enum uint CLUSTER_AVG_LIGHTS_BUDGET = 256;
enum uint CLUSTER_INDEX_CAPACITY = CLUSTER_COUNT * CLUSTER_AVG_LIGHTS_BUDGET; // 884,736 uints (~3.38 MiB)

/// GPU mirror of WGSL `ClusterRecord` (16 bytes).
struct ClusterRecord {
    uint offset = 0;
    uint pointCount = 0;
    uint spotCount = 0;
    uint _pad = 0;
}
static assert(ClusterRecord.sizeof == 16);
static assert(isPod!ClusterRecord);

/// GPU mirror of WGSL `ClusterCullUniforms` (160 bytes).
struct ClusterCullUniforms {
    float[16] viewMatrix;
    float[16] invProj;
    float nearZ = 0.1f;
    float farZ = 100.0f;
    uint pointCount = 0;
    uint spotCount = 0;
    uint gridX = CLUSTER_GRID_X;
    uint gridY = CLUSTER_GRID_Y;
    uint gridZ = CLUSTER_GRID_Z;
    uint indexCapacity = CLUSTER_INDEX_CAPACITY;
}
static assert(ClusterCullUniforms.sizeof == 160);
static assert(isValidUniformStruct!ClusterCullUniforms);

/// GPU mirror of WGSL `ClusterState` (16 bytes).
struct ClusterState {
    uint globalOffset = 0;
    uint overflowCount = 0;
    uint _pad0 = 0;
    uint _pad1 = 0;
}
static assert(ClusterState.sizeof == 16);
static assert(isPod!ClusterState);

/// Compute `(zScale, zBias, nearZ, farZ)` such that `slice = floor(log(viewDepth) * zScale + zBias)`
/// maps `[nearZ, farZ]` logarithmically onto `[0, gridZ)`.
float[4] computeClusterZParams(float nearZ, float farZ, uint gridZ = CLUSTER_GRID_Z) pure nothrow @nogc {
    immutable float n = nearZ > 0.001f ? nearZ : 0.001f;
    immutable float f = farZ > n + 0.1f ? farZ : n + 0.1f;
    immutable float invLog = 1.0f / log(f / n);
    immutable float zScale = cast(float) gridZ * invLog;
    immutable float zBias = -cast(float) gridZ * log(n) * invLog;
    return [zScale, zBias, n, f];
}

/// Depth plane at cluster slice boundary `k ∈ [0 .. gridZ]`.
float clusterSliceDepth(uint k, float nearZ, float farZ, uint gridZ = CLUSTER_GRID_Z) pure nothrow @nogc {
    import std.math : pow;
    immutable float n = nearZ > 0.001f ? nearZ : 0.001f;
    immutable float f = farZ > n + 0.1f ? farZ : n + 0.1f;
    immutable float t = cast(float) k / cast(float) (gridZ > 0 ? gridZ : 1);
    return n * pow(f / n, t);
}

/// CPU mirror of WGSL Z-slice lookup.
uint clusterZSlice(float viewDepth, ref const float[4] zParams, uint gridZ = CLUSTER_GRID_Z) pure nothrow @nogc {
    immutable float d = viewDepth > zParams[2] ? viewDepth : zParams[2];
    immutable float sliceF = floor(log(d) * zParams[0] + zParams[1]);
    if (sliceF <= 0.0f) return 0;
    immutable uint tz = cast(uint) sliceF;
    return tz >= gridZ ? (gridZ - 1) : tz;
}

/// CPU mirror of WGSL `(tileX, tileY)` lookup under `viewportRect = (vpX, vpY, vpW, vpH)`.
uint[2] clusterTileXY(float screenX, float screenY, ref const float[4] viewportRect,
                      uint gridX = CLUSTER_GRID_X, uint gridY = CLUSTER_GRID_Y) pure nothrow @nogc {
    immutable float w = viewportRect[2] > 1.0f ? viewportRect[2] : 1.0f;
    immutable float h = viewportRect[3] > 1.0f ? viewportRect[3] : 1.0f;
    float u = (screenX - viewportRect[0]) / w;
    float v = (screenY - viewportRect[1]) / h;
    if (u < 0.0f) u = 0.0f; else if (u > 0.999999f) u = 0.999999f;
    if (v < 0.0f) v = 0.0f; else if (v > 0.999999f) v = 0.999999f;
    uint tx = cast(uint) (u * gridX);
    uint ty = cast(uint) (v * gridY);
    if (tx >= gridX) tx = gridX - 1;
    if (ty >= gridY) ty = gridY - 1;
    return [tx, ty];
}

uint clusterIndex(uint tx, uint ty, uint tz,
                  uint gridX = CLUSTER_GRID_X, uint gridY = CLUSTER_GRID_Y) pure nothrow @nogc {
    return tx + ty * gridX + tz * (gridX * gridY);
}

/// CPU mirror of view-space AABB construction for tile `(tx, ty, tz)`.
void computeClusterViewAabb(uint tx, uint ty, uint tz, ref const Mat4 invProj,
                            float nearZ, float farZ, out Vec3 aabbMin, out Vec3 aabbMax,
                            uint gridX = CLUSTER_GRID_X, uint gridY = CLUSTER_GRID_Y,
                            uint gridZ = CLUSTER_GRID_Z) pure nothrow @nogc {
    immutable float n = nearZ > 0.001f ? nearZ : 0.001f;
    immutable float f = farZ > n + 0.1f ? farZ : n + 0.1f;
    immutable float d0 = clusterSliceDepth(tz, n, f, gridZ);
    immutable float d1 = clusterSliceDepth(tz + 1, n, f, gridZ);
    immutable float t0 = (d0 - n) / (f - n);
    immutable float t1 = (d1 - n) / (f - n);

    immutable float x0 = (cast(float) tx / cast(float) gridX) * 2.0f - 1.0f;
    immutable float x1 = (cast(float) (tx + 1) / cast(float) gridX) * 2.0f - 1.0f;
    immutable float yTop = 1.0f - (cast(float) ty / cast(float) gridY) * 2.0f;
    immutable float yBot = 1.0f - (cast(float) (ty + 1) / cast(float) gridY) * 2.0f;

    Vec3 unproj(float nx, float ny, float nz) {
        immutable h = invProj * Vec4(nx, ny, nz, 1.0f);
        return Vec3(h.x / h.w, h.y / h.w, h.z / h.w);
    }

    immutable Vec3[4] nearCorners = [
        unproj(x0, yBot, 0.0f), unproj(x1, yBot, 0.0f),
        unproj(x0, yTop, 0.0f), unproj(x1, yTop, 0.0f),
    ];
    immutable Vec3[4] farCorners = [
        unproj(x0, yBot, 1.0f), unproj(x1, yBot, 1.0f),
        unproj(x0, yTop, 1.0f), unproj(x1, yTop, 1.0f),
    ];

    aabbMin = Vec3(float.max, float.max, float.max);
    aabbMax = Vec3(-float.max, -float.max, -float.max);

    void include(Vec3 p) {
        if (p.x < aabbMin.x) aabbMin.x = p.x;
        if (p.y < aabbMin.y) aabbMin.y = p.y;
        if (p.z < aabbMin.z) aabbMin.z = p.z;
        if (p.x > aabbMax.x) aabbMax.x = p.x;
        if (p.y > aabbMax.y) aabbMax.y = p.y;
        if (p.z > aabbMax.z) aabbMax.z = p.z;
    }

    foreach (i; 0 .. 4) {
        immutable nP = nearCorners[i];
        immutable fP = farCorners[i];
        include(Vec3(nP.x + (fP.x - nP.x) * t0, nP.y + (fP.y - nP.y) * t0, nP.z + (fP.z - nP.z) * t0));
        include(Vec3(nP.x + (fP.x - nP.x) * t1, nP.y + (fP.y - nP.y) * t1, nP.z + (fP.z - nP.z) * t1));
    }
}

bool sphereIntersectsAabb(Vec3 center, float radius, Vec3 aabbMin, Vec3 aabbMax) pure nothrow @nogc {
    float clampf(float v, float lo, float hi) { return v < lo ? lo : (v > hi ? hi : v); }
    immutable cx = clampf(center.x, aabbMin.x, aabbMax.x);
    immutable cy = clampf(center.y, aabbMin.y, aabbMax.y);
    immutable cz = clampf(center.z, aabbMin.z, aabbMax.z);
    immutable dx = center.x - cx;
    immutable dy = center.y - cy;
    immutable dz = center.z - cz;
    return dx * dx + dy * dy + dz * dz <= radius * radius;
}

/// CPU mirror of WGSL `tightSpotBoundingSphere`: minimum bounding sphere `(center, radius)` of a finite cone.
void tightSpotBoundingSphere(Vec3 apex, Vec3 dir, float range, float outerConeCos,
                             out Vec3 center, out float radius) pure nothrow @nogc {
    if (outerConeCos <= 0.0f) {
        center = apex;
        radius = range;
        return;
    }
    if (outerConeCos < 0.70710678f) {
        immutable sinTheta = sqrt((1.0f - outerConeCos * outerConeCos) > 0.0f
            ? (1.0f - outerConeCos * outerConeCos) : 0.0f);
        center = apex + dir * (range * outerConeCos);
        radius = range * sinTheta;
        return;
    }
    radius = range / (2.0f * outerConeCos > 1e-4f ? 2.0f * outerConeCos : 1e-4f);
    center = apex + dir * radius;
}

bool spotConeBehindCluster(Vec3 aabbMin, Vec3 aabbMax, Vec3 apex, Vec3 dir, float outerConeCos) pure nothrow @nogc {
    if (outerConeCos <= 0.0f) return false;
    immutable Vec3 extreme = Vec3(
        dir.x >= 0.0f ? aabbMax.x : aabbMin.x,
        dir.y >= 0.0f ? aabbMax.y : aabbMin.y,
        dir.z >= 0.0f ? aabbMax.z : aabbMin.z,
    );
    return extreme.dot(dir) < apex.dot(dir) - 1e-3f;
}

/// Owns cluster grid & light index storage buffers and runs compute culling each frame.
struct ClusteredLightCuller {
    private WGPUDevice device;
    private WGPUShaderModule csModule;
    private WGPUBindGroupLayout bgl;
    private WGPUPipelineLayout pipeLayout;
    private WGPUComputePipeline resetPipe;
    private WGPUComputePipeline cullPipe;

    private WGPUBuffer uniformBuf;
    private WGPUBuffer clusterGridBuf;
    private WGPUBuffer clusterIndicesBuf;
    private WGPUBuffer clusterStateBuf;

    private WGPUBindGroup cachedBg;
    private WGPUBuffer boundPointBuf;
    private ulong boundPointSize;
    private WGPUBuffer boundSpotBuf;
    private ulong boundSpotSize;

    @disable this(this);

    static ClusteredLightCuller create(WGPUDevice dev, WGPUQueue queue) @trusted {
        ClusteredLightCuller c;
        c.device = dev;

        c.uniformBuf = createUniformBuffer(dev, ClusterCullUniforms.sizeof);
        c.clusterGridBuf = createStorageBuffer(dev, CLUSTER_COUNT * ClusterRecord.sizeof);
        c.clusterIndicesBuf = createStorageBuffer(dev, CLUSTER_INDEX_CAPACITY * uint.sizeof);
        c.clusterStateBuf = createStorageBuffer(dev, ClusterState.sizeof);

        // Zero-initialize cluster grid and state once so reading empty clusters before first cull is well-defined.
        {
            ClusterRecord[CLUSTER_COUNT] emptyGrid;
            wgpuQueueWriteBuffer(queue, c.clusterGridBuf, 0, emptyGrid.ptr, emptyGrid.sizeof);
            ClusterState emptyState;
            wgpuQueueWriteBuffer(queue, c.clusterStateBuf, 0, &emptyState, emptyState.sizeof);
            immutable uint[1] zeroIdx = [0];
            wgpuQueueWriteBuffer(queue, c.clusterIndicesBuf, 0, zeroIdx.ptr, zeroIdx.sizeof);
        }

        c.csModule = createShaderModule(dev, kClusterCullCsWgsl, "clustered_cull_cs");
        if (c.csModule is null) fatal("ClusteredLightCuller: compute shader compilation failed");

        enum cs = WGPUShaderStage.compute;
        WGPUBindGroupLayoutEntry[6] le;
        le[0].binding = 0;
        le[0].visibility = cs;
        le[0].buffer.type = WGPUBufferBindingType.uniform;
        le[0].buffer.minBindingSize = ClusterCullUniforms.sizeof;

        le[1].binding = 1;
        le[1].visibility = cs;
        le[1].buffer.type = WGPUBufferBindingType.readOnlyStorage;
        le[1].buffer.minBindingSize = 48;

        le[2].binding = 2;
        le[2].visibility = cs;
        le[2].buffer.type = WGPUBufferBindingType.readOnlyStorage;
        le[2].buffer.minBindingSize = 128;

        le[3].binding = 3;
        le[3].visibility = cs;
        le[3].buffer.type = WGPUBufferBindingType.storage;
        le[3].buffer.minBindingSize = ClusterRecord.sizeof;

        le[4].binding = 4;
        le[4].visibility = cs;
        le[4].buffer.type = WGPUBufferBindingType.storage;
        le[4].buffer.minBindingSize = uint.sizeof;

        le[5].binding = 5;
        le[5].visibility = cs;
        le[5].buffer.type = WGPUBufferBindingType.storage;
        le[5].buffer.minBindingSize = ClusterState.sizeof;

        WGPUBindGroupLayoutDescriptor bld;
        bld.entryCount = le.length;
        bld.entries = le.ptr;
        c.bgl = wgpuDeviceCreateBindGroupLayout(dev, &bld);

        WGPUPipelineLayoutDescriptor pld;
        pld.bindGroupLayoutCount = 1;
        pld.bindGroupLayouts = &c.bgl;
        c.pipeLayout = wgpuDeviceCreatePipelineLayout(dev, &pld);

        WGPUComputePipeline makePipe(const(char)* entry) {
            WGPUComputePipelineDescriptor cd;
            cd.layout = c.pipeLayout;
            cd.compute.module_ = c.csModule;
            cd.compute.entryPoint = wgpuStringView(entry);
            auto p = wgpuDeviceCreateComputePipeline(dev, &cd);
            if (p is null) fatal("ClusteredLightCuller: compute pipeline creation failed");
            return p;
        }

        c.resetPipe = makePipe("cs_reset");
        c.cullPipe = makePipe("cs_cull");
        info("ClusteredLightCuller ready (grid=", CLUSTER_GRID_X, "x", CLUSTER_GRID_Y, "x",
             CLUSTER_GRID_Z, ", ", CLUSTER_COUNT, " clusters)");
        return c;
    }

    WGPUBuffer gridBuffer() nothrow @nogc { return clusterGridBuf; }
    WGPUBuffer indicesBuffer() nothrow @nogc { return clusterIndicesBuf; }
    static ulong gridBufferSize() pure nothrow @nogc { return CLUSTER_COUNT * ClusterRecord.sizeof; }
    static ulong indicesBufferSize() pure nothrow @nogc { return CLUSTER_INDEX_CAPACITY * uint.sizeof; }

    /// Record compute reset + light binning into `encoder` for the active frame camera & light buffers.
    void encode(WGPUCommandEncoder encoder, WGPUQueue queue,
                WGPUBuffer pointBuf, ulong pointBytes,
                WGPUBuffer spotBuf, ulong spotBytes,
                ref const Camera camera, uint pointCount, uint spotCount) nothrow @nogc @trusted {
        if (encoder is null || resetPipe is null || cullPipe is null) return;
        if (pointBuf is null || spotBuf is null) return;

        ensureBindGroup(pointBuf, pointBytes, spotBuf, spotBytes);

        ClusterCullUniforms u;
        u.viewMatrix = Mat4.lookAt(camera.position, camera.target, camera.up).m;
        u.invProj = Mat4.perspective(camera.fovY, camera.aspect, camera.near, camera.far).inverse().m;
        u.nearZ = camera.near > 0.001f ? camera.near : 0.001f;
        u.farZ = camera.far > u.nearZ + 0.1f ? camera.far : u.nearZ + 0.1f;
        u.pointCount = pointCount;
        u.spotCount = spotCount;
        u.gridX = CLUSTER_GRID_X;
        u.gridY = CLUSTER_GRID_Y;
        u.gridZ = CLUSTER_GRID_Z;
        u.indexCapacity = CLUSTER_INDEX_CAPACITY;
        updateBuffer(queue, uniformBuf, &u, ClusterCullUniforms.sizeof);

        // Pass 1: reset atomic global index counter on the GPU timeline.
        {
            WGPUComputePassDescriptor cpd;
            auto pass = wgpuCommandEncoderBeginComputePass(encoder, &cpd);
            wgpuComputePassEncoderSetPipeline(pass, resetPipe);
            wgpuComputePassEncoderSetBindGroup(pass, 0, cachedBg, 0, null);
            wgpuComputePassEncoderDispatchWorkgroups(pass, 1, 1, 1);
            wgpuComputePassEncoderEnd(pass);
            wgpuComputePassEncoderRelease(pass);
        }

        // Pass 2: 1 workgroup (64 threads) per cluster bins point and spot lights.
        {
            WGPUComputePassDescriptor cpd;
            auto pass = wgpuCommandEncoderBeginComputePass(encoder, &cpd);
            wgpuComputePassEncoderSetPipeline(pass, cullPipe);
            wgpuComputePassEncoderSetBindGroup(pass, 0, cachedBg, 0, null);
            wgpuComputePassEncoderDispatchWorkgroups(pass, CLUSTER_GRID_X, CLUSTER_GRID_Y, CLUSTER_GRID_Z);
            wgpuComputePassEncoderEnd(pass);
            wgpuComputePassEncoderRelease(pass);
        }
    }

    private void ensureBindGroup(WGPUBuffer pointBuf, ulong pointBytes,
                                 WGPUBuffer spotBuf, ulong spotBytes) nothrow @nogc @trusted {
        if (cachedBg !is null && pointBuf is boundPointBuf && pointBytes == boundPointSize
                && spotBuf is boundSpotBuf && spotBytes == boundSpotSize) {
            return;
        }
        releaseBindGroup(cachedBg);
        cachedBg = null;

        WGPUBindGroupEntry[6] e;
        e[0].binding = 0; e[0].buffer = uniformBuf;       e[0].offset = 0; e[0].size = ClusterCullUniforms.sizeof;
        e[1].binding = 1; e[1].buffer = pointBuf;         e[1].offset = 0; e[1].size = pointBytes;
        e[2].binding = 2; e[2].buffer = spotBuf;          e[2].offset = 0; e[2].size = spotBytes;
        e[3].binding = 3; e[3].buffer = clusterGridBuf;   e[3].offset = 0; e[3].size = gridBufferSize();
        e[4].binding = 4; e[4].buffer = clusterIndicesBuf;e[4].offset = 0; e[4].size = indicesBufferSize();
        e[5].binding = 5; e[5].buffer = clusterStateBuf;  e[5].offset = 0; e[5].size = ClusterState.sizeof;

        WGPUBindGroupDescriptor d;
        d.layout = bgl;
        d.entryCount = e.length;
        d.entries = e.ptr;
        cachedBg = wgpuDeviceCreateBindGroup(device, &d);
        if (cachedBg is null) fatal("ClusteredLightCuller: compute bind group creation failed");
        boundPointBuf = pointBuf;
        boundPointSize = pointBytes;
        boundSpotBuf = spotBuf;
        boundSpotSize = spotBytes;
    }

    void destroy() nothrow @nogc @trusted {
        releaseBindGroup(cachedBg);
        cachedBg = null;
        boundPointBuf = null;
        boundSpotBuf = null;
        if (resetPipe !is null) { wgpuComputePipelineRelease(resetPipe); resetPipe = null; }
        if (cullPipe !is null)  { wgpuComputePipelineRelease(cullPipe); cullPipe = null; }
        if (pipeLayout !is null) { wgpuPipelineLayoutRelease(pipeLayout); pipeLayout = null; }
        if (bgl !is null)        { wgpuBindGroupLayoutRelease(bgl); bgl = null; }
        if (csModule !is null)   { wgpuShaderModuleRelease(csModule); csModule = null; }
        destroyBuffer(uniformBuf); uniformBuf = null;
        destroyBuffer(clusterGridBuf); clusterGridBuf = null;
        destroyBuffer(clusterIndicesBuf); clusterIndicesBuf = null;
        destroyBuffer(clusterStateBuf); clusterStateBuf = null;
        device = null;
    }
}

// ---------------------------------------------------------------------------
// Unit tests (cluster math parity & bounds)
// ---------------------------------------------------------------------------

@("clustered.zSliceRoundTrip") @safe pure nothrow @nogc unittest {
    immutable float nearZ = 0.1f;
    immutable float farZ = 1000.0f;
    immutable zp = computeClusterZParams(nearZ, farZ, CLUSTER_GRID_Z);

    // Midpoint of every slice k must map back into slice k.
    foreach (k; 0 .. CLUSTER_GRID_Z) {
        immutable d0 = clusterSliceDepth(k, nearZ, farZ, CLUSTER_GRID_Z);
        immutable d1 = clusterSliceDepth(k + 1, nearZ, farZ, CLUSTER_GRID_Z);
        immutable mid = 0.5f * (d0 + d1);
        assert(clusterZSlice(mid, zp, CLUSTER_GRID_Z) == k);
    }
    assert(clusterZSlice(0.01f, zp, CLUSTER_GRID_Z) == 0);
    assert(clusterZSlice(5000.0f, zp, CLUSTER_GRID_Z) == CLUSTER_GRID_Z - 1);
}

@("clustered.viewportSubRectMapping") @safe pure nothrow @nogc unittest {
    // Sub-viewport anchored at (200, 100) of size 1600x900
    immutable float[4] vp = [200.0f, 100.0f, 1600.0f, 900.0f];
    immutable topLeft = clusterTileXY(201.0f, 101.0f, vp);
    assert(topLeft[0] == 0 && topLeft[1] == 0);

    immutable center = clusterTileXY(200.0f + 800.0f, 100.0f + 450.0f, vp);
    assert(center[0] == 8 && center[1] == 4);

    immutable botRight = clusterTileXY(1799.0f, 999.0f, vp);
    assert(botRight[0] == CLUSTER_GRID_X - 1 && botRight[1] == CLUSTER_GRID_Y - 1);

    // Outside viewport clamps safely
    immutable outLow = clusterTileXY(50.0f, 20.0f, vp);
    assert(outLow[0] == 0 && outLow[1] == 0);
}

@("clustered.viewSpaceAabbAndSphereIntersection") @safe unittest {
    import std.math : PI;
    immutable float nearZ = 0.5f;
    immutable float farZ = 200.0f;
    immutable invProj = Mat4.perspective(cast(float)(PI / 3.0), 16.0f / 9.0f, nearZ, farZ).inverse();

    Vec3 bMin, bMax;
    // Center tile at slice 5
    computeClusterViewAabb(8, 4, 5, invProj, nearZ, farZ, bMin, bMax);
    assert(bMin.z < bMax.z);
    assert(bMax.z <= -clusterSliceDepth(5, nearZ, farZ) + 1e-3f);
    assert(bMin.z >= -clusterSliceDepth(6, nearZ, farZ) - 1e-3f);

    immutable midPt = Vec3((bMin.x + bMax.x) * 0.5f, (bMin.y + bMax.y) * 0.5f, (bMin.z + bMax.z) * 0.5f);
    assert(sphereIntersectsAabb(midPt, 0.2f, bMin, bMax));
    assert(!sphereIntersectsAabb(Vec3(midPt.x, midPt.y, 10.0f), 1.0f, bMin, bMax)); // behind camera
}

@("clustered.tightSpotSphereAndHalfSpace") @safe unittest {
    import std.math : cos, PI, sin;

    // Narrow cone (20 deg half-angle) along -Z: rim at Z=-10 must lie inside bounding sphere
    immutable float cos20 = cos(20.0f * PI / 180.0f);
    immutable float sin20 = sin(20.0f * PI / 180.0f);
    Vec3 cN;
    float rN;
    tightSpotBoundingSphere(Vec3(0, 0, 0), Vec3(0, 0, -1), 10.0f, cos20, cN, rN);
    immutable rimN = Vec3(10.0f * sin20, 0.0f, -10.0f * cos20);
    assert((rimN - cN).length() <= rN + 1e-4f);
    assert((Vec3(0, 0, 0) - cN).length() <= rN + 1e-4f);

    // Wide cone (70 deg half-angle): rim lies on base sphere centered at R*cos(70)
    immutable float cos70 = cos(70.0f * PI / 180.0f);
    immutable float sin70 = sin(70.0f * PI / 180.0f);
    Vec3 cW;
    float rW;
    tightSpotBoundingSphere(Vec3(0, 0, 0), Vec3(0, 0, -1), 10.0f, cos70, cW, rW);
    immutable rimW = Vec3(10.0f * sin70, 0.0f, -10.0f * cos70);
    assert((rimW - cW).length() <= rW + 1e-4f);
    assert((Vec3(0, 0, 0) - cW).length() <= rW + 1e-4f);

    // AABB strictly behind spotlight apex must be rejected by half-space test
    assert(spotConeBehindCluster(Vec3(-1, -1, 1), Vec3(1, 1, 5), Vec3(0, 0, 0), Vec3(0, 0, -1), cos20));
    assert(!spotConeBehindCluster(Vec3(-1, -1, -5), Vec3(1, 1, -1), Vec3(0, 0, 0), Vec3(0, 0, -1), cos20));
}
