/// GPU culling + indirect draws for `StaticInstanceBuffer`
/// (`StaticBuildOptions.gpuCull`). Every view runs three compute dispatches
/// (`static_cull_cs.wgsl`): classify, sum, scatter. The result is a compacted
/// instance buffer with the stock `TexInstanceData` layout plus one indexed
/// indirect record per (group, LOD), so every vertex shader works unchanged.
module engine.gpu.static_cull;

import bindings.wgpu;
import engine.core.log;
import engine.core.pod : isPod, Pod;
import engine.gpu.buffer;
import engine.gpu.context : GpuContext;
import engine.gpu.pipeline : TexInstanceData;
import engine.gpu.shader : createShaderModule, isValidUniformStruct;
import engine.gpu.shaders : staticCullCsShaderSource;
import engine.graphics.texmesh : TexMesh;
import engine.math.bounds : BoundingSphere, maxAxisScale;
import engine.math.frustum : Frustum;
import engine.math.mat : Mat4;
import engine.math.vec : Vec3;
import engine.scene.cascades : MAX_CASCADES, ReceiverCull;

@safe:

/// View slot 0 is the camera; slot `1 + c` is cascade `c` (a fixed directional map uses slot 1).
enum uint STATIC_CULL_VIEWS = 1 + MAX_CASCADES;
/// Instances per compute workgroup.
enum uint STATIC_CULL_BLOCK = 64;
/// Bytes of one indexed indirect record.
enum uint INDIRECT_STRIDE = 20;

enum : uint { CULL_DISTANCE = 1, CULL_RECEIVER = 2, CULL_SHADOW = 4 }

/// GPU mirror of WGSL `CullView` (256 bytes, also the dynamic offset stride).
struct CullViewUbo {
    float[4][6] planes;
    float[4][6] slicePlanes;
    float[4] sweep;
    float[4] camera;
    float[4] params;
    uint[4] flags;

    static CullViewUbo make(ref const Frustum f, Vec3 camera, float lodBias, float fovY,
                            float screenHeight, uint flags, const(ReceiverCull)* receiver) pure nothrow @nogc {
        CullViewUbo u;
        foreach (i, ref p; f.planes) u.planes[i] = [p.x, p.y, p.z, p.w];
        u.slicePlanes = u.planes;
        u.sweep = [0, 1, 0, 0];
        if (receiver !is null) {
            flags |= CULL_RECEIVER;
            foreach (i, ref p; receiver.slice.planes) u.slicePlanes[i] = [p.x, p.y, p.z, p.w];
            u.sweep = [receiver.toLight.x, receiver.toLight.y, receiver.toLight.z, receiver.drop];
        }
        u.camera = [camera.x, camera.y, camera.z, lodBias];
        import std.math : tan;
        immutable denom = 2.0f * tan(fovY * 0.5f);
        u.params = [denom > 0 ? screenHeight / denom : float.max, 0, 0, 0];
        u.flags = [flags, 0, 0, 0];
        return u;
    }
}
static assert(CullViewUbo.sizeof == 256);
static assert(isValidUniformStruct!CullViewUbo);

/// GPU mirror of WGSL `Block`.
struct CullBlock { uint group, first, count, pad; }
/// GPU mirror of WGSL `Meta`.
struct CullMeta {
    float[3] center = 0;
    float scale = 1;
    float[3] extents = 0;
    float radius = 0;
}
/// GPU mirror of WGSL `Group`.
struct CullGroup {
    uint first, count, firstBlock, blockCount;
    uint firstArg, lodLevels, baseVertex, pad;
    float maxDistance = 0, minPixels = 0, meshScale = 1, displacement = 0;
    float[8] errors = 0;
    uint[2][8] color;
    uint[2][8] shadow;
}
static assert(CullBlock.sizeof == 16 && CullMeta.sizeof == 32 && CullGroup.sizeof == 208);
static assert(isPod!CullBlock && isPod!CullMeta && isPod!CullGroup);

/// Most blocks of one culling group: `cs_sum` walks them in one invocation.
enum uint STATIC_CULL_PART_BLOCKS = 16;

/// Cut groups longer than `STATIC_CULL_PART_BLOCKS` blocks. `order` then lists parts
/// instead of groups and `partGroup` maps each part to its group.
CullGroup[] splitCullGroups(scope const(CullGroup)[] groups, ref uint[] order, out uint[] partGroup) {
    enum uint MAX = STATIC_CULL_PART_BLOCKS * STATIC_CULL_BLOCK;
    CullGroup[] parts;
    auto firstPart = new uint[groups.length + 1];
    foreach (gi, ref g; groups) {
        firstPart[gi] = cast(uint) parts.length;
        uint done = 0;
        do {
            CullGroup p = g;
            p.first = g.first + done;
            p.count = g.count - done < MAX ? g.count - done : MAX;
            done += p.count;
            parts ~= p;
            partGroup ~= cast(uint) gi;
        } while (done < g.count);
    }
    firstPart[groups.length] = cast(uint) parts.length;
    uint[] partOrder;
    foreach (gi; order)
        foreach (k; firstPart[gi] .. firstPart[gi + 1])
            partOrder ~= k;
    order = partOrder;
    return parts;
}

/// Split the groups' instance ranges into blocks of at most 64; a block never crosses a group.
CullBlock[] buildCullBlocks(scope CullGroup[] groups) {
    CullBlock[] blocks;
    foreach (gi, ref g; groups) {
        g.firstBlock = cast(uint) blocks.length;
        for (uint o = 0; o < g.count; o += STATIC_CULL_BLOCK) {
            immutable left = g.count - o;
            blocks ~= CullBlock(cast(uint) gi, g.first + o,
                                left < STATIC_CULL_BLOCK ? left : STATIC_CULL_BLOCK);
        }
        g.blockCount = cast(uint) blocks.length - g.firstBlock;
    }
    return blocks;
}

/// Where one mesh lives inside the shared pools.
struct PoolSlot {
    uint baseVertex;
    uint firstIndex;
    uint firstShadowIndex;
}

/// Meshes of one buffer copied into shared vertex / index buffers, so one
/// bind serves every draw. Vertex pools are per stride (32, 48), index pools per format.
struct MeshPool {
    WGPUBuffer[2] vertices;
    ulong[2] vertexBytes;
    /// Vertex colors of the colored meshes, which come first in `vertices`.
    WGPUBuffer[2] colors;
    ulong[2] colorBytes;
    WGPUBuffer[2] indices;
    ulong[2] indexBytes;
    Pod!PoolSlot[] slots;

    @disable this(this);

    static uint strideIndex(uint stride) pure nothrow @nogc { return stride == 48 ? 1 : 0; }
    static uint formatIndex(WGPUIndexFormat f) pure nothrow @nogc { return f == WGPUIndexFormat.uint32 ? 1 : 0; }

    static MeshPool build(ref GpuContext gpu, scope TexMesh*[] meshes) @trusted {
        MeshPool p;
        p.slots = new PoolSlot[meshes.length];
        static ulong align4(ulong v) { return (v + 3) & ~3UL; }
        foreach (colored; [true, false]) foreach (i, m; meshes) {
            if (m.hasVertexColors != colored) continue;
            immutable si = strideIndex(m.vertexStride), fi = formatIndex(m.indexFormat);
            immutable isz = fi == 1 ? 4 : 2;
            p.slots[i].baseVertex = cast(uint)(p.vertexBytes[si] / m.vertexStride);
            p.vertexBytes[si] += m.vertexBufSize;
            if (colored) p.colorBytes[si] += m.vertexBufSize / m.vertexStride * 4;
            p.slots[i].firstIndex = cast(uint)(p.indexBytes[fi] / isz);
            p.indexBytes[fi] += align4(m.indexBufSize);
            p.slots[i].firstShadowIndex = p.slots[i].firstIndex;
            if (m.shadowIndexBuffer !is null) {
                p.slots[i].firstShadowIndex = cast(uint)(p.indexBytes[fi] / isz);
                p.indexBytes[fi] += align4(m.shadowIndexBufSize);
            }
        }
        auto device = gpu.getDevice();
        foreach (k; 0 .. 2) {
            if (p.vertexBytes[k])
                p.vertices[k] = createBufferWithUsage(device, p.vertexBytes[k],
                    WGPUBufferUsage.vertex | WGPUBufferUsage.copyDst);
            if (p.colorBytes[k])
                p.colors[k] = createBufferWithUsage(device, p.colorBytes[k],
                    WGPUBufferUsage.vertex | WGPUBufferUsage.copyDst);
            if (p.indexBytes[k])
                p.indices[k] = createBufferWithUsage(device, p.indexBytes[k],
                    WGPUBufferUsage.index | WGPUBufferUsage.copyDst);
        }
        WGPUCommandEncoderDescriptor ed;
        auto enc = wgpuDeviceCreateCommandEncoder(device, &ed);
        foreach (i, m; meshes) {
            immutable si = strideIndex(m.vertexStride), fi = formatIndex(m.indexFormat);
            immutable isz = fi == 1 ? 4 : 2;
            auto s = p.slots[i];
            if (m.vertexBufSize)
                wgpuCommandEncoderCopyBufferToBuffer(enc, m.vertexBuffer, 0, p.vertices[si],
                    cast(ulong) s.baseVertex * m.vertexStride, m.vertexBufSize);
            if (m.hasVertexColors)
                wgpuCommandEncoderCopyBufferToBuffer(enc, m.colorBuffer, 0, p.colors[si],
                    cast(ulong) s.baseVertex * 4, m.vertexBufSize / m.vertexStride * 4);
            if (m.indexBufSize)
                wgpuCommandEncoderCopyBufferToBuffer(enc, m.indexBuffer, 0, p.indices[fi],
                    cast(ulong) s.firstIndex * isz, align4(m.indexBufSize));
            if (m.shadowIndexBuffer !is null)
                wgpuCommandEncoderCopyBufferToBuffer(enc, m.shadowIndexBuffer, 0, p.indices[fi],
                    cast(ulong) s.firstShadowIndex * isz, align4(m.shadowIndexBufSize));
        }
        WGPUCommandBufferDescriptor cd;
        auto cb = wgpuCommandEncoderFinish(enc, &cd);
        wgpuQueueSubmit(gpu.getQueue(), 1, &cb);
        wgpuCommandBufferRelease(cb);
        wgpuCommandEncoderRelease(enc);
        return p;
    }

    void destroy() nothrow @nogc {
        foreach (k; 0 .. 2) {
            destroyBuffer(vertices[k]);
            destroyBuffer(colors[k]);
            destroyBuffer(indices[k]);
            colors[k] = null;
            vertices[k] = null;
            indices[k] = null;
        }
    }
}

/// Compute pipelines and view uniforms. Owned by `Scene3DTextured`, created on
/// the first frame that queues a GPU-culled buffer.
struct StaticCuller {
    private WGPUDevice device;
    private WGPUQueue queue;
    private WGPUShaderModule csModule;
    private WGPUBindGroupLayout viewLayout;
    private WGPUBindGroupLayout dataLayout;
    private WGPUPipelineLayout pipeLayout;
    private WGPUComputePipeline cullPipe, sumPipe, scatterPipe;
    private WGPUBuffer viewBuf;
    private WGPUBindGroup viewBg;

    @disable this(this);

    bool ready() const pure nothrow @nogc { return scatterPipe !is null; }

    void init(WGPUDevice dev, WGPUQueue q) nothrow @nogc @trusted {
        device = dev;
        queue = q;
        viewBuf = createUniformBuffer(dev, STATIC_CULL_VIEWS * CullViewUbo.sizeof);
        csModule = createShaderModule(dev, staticCullCsShaderSource, "static_cull_cs");
        if (csModule is null) { fatal("StaticCuller: compute shader compilation failed"); return; }

        WGPUBindGroupLayoutEntry ve;
        ve.binding = 0;
        ve.visibility = WGPUShaderStage.compute;
        ve.buffer.type = WGPUBufferBindingType.uniform;
        ve.buffer.hasDynamicOffset = 1;
        ve.buffer.minBindingSize = CullViewUbo.sizeof;
        WGPUBindGroupLayoutDescriptor vd;
        vd.entryCount = 1;
        vd.entries = &ve;
        viewLayout = wgpuDeviceCreateBindGroupLayout(dev, &vd);

        WGPUBindGroupLayoutEntry[8] de;
        foreach (i, ref e; de) {
            e.binding = cast(uint) i;
            e.visibility = WGPUShaderStage.compute;
            immutable ro = i < 3 || i == 6;
            e.buffer.type = ro ? WGPUBufferBindingType.readOnlyStorage : WGPUBufferBindingType.storage;
        }
        WGPUBindGroupLayoutDescriptor dd;
        dd.entryCount = de.length;
        dd.entries = de.ptr;
        dataLayout = wgpuDeviceCreateBindGroupLayout(dev, &dd);

        WGPUBindGroupLayout[2] layouts = [viewLayout, dataLayout];
        WGPUPipelineLayoutDescriptor pld;
        pld.bindGroupLayoutCount = 2;
        pld.bindGroupLayouts = layouts.ptr;
        pipeLayout = wgpuDeviceCreatePipelineLayout(dev, &pld);

        WGPUComputePipeline make(const(char)* entry) {
            WGPUComputePipelineDescriptor cd;
            cd.layout = pipeLayout;
            cd.compute.module_ = csModule;
            cd.compute.entryPoint = wgpuStringView(entry);
            return wgpuDeviceCreateComputePipeline(dev, &cd);
        }
        cullPipe = make("cs_cull");
        sumPipe = make("cs_sum");
        scatterPipe = make("cs_scatter");
        if (cullPipe is null || sumPipe is null || scatterPipe is null)
            fatal("StaticCuller: compute pipeline creation failed");

        WGPUBindGroupEntry be;
        be.binding = 0;
        be.buffer = viewBuf;
        be.size = CullViewUbo.sizeof;
        WGPUBindGroupDescriptor bd;
        bd.layout = viewLayout;
        bd.entryCount = 1;
        bd.entries = &be;
        viewBg = wgpuDeviceCreateBindGroup(dev, &bd);
    }

    /// Set the uniforms of `slot` for this frame.
    void setView(uint slot, ref const CullViewUbo u) nothrow @nogc {
        updateBuffer(queue, viewBuf, slot, u);
    }

    private static void updateBuffer(WGPUQueue q, WGPUBuffer b, uint slot, ref const CullViewUbo u) nothrow @nogc @trusted {
        wgpuQueueWriteBuffer(q, b, slot * CullViewUbo.sizeof, &u, CullViewUbo.sizeof);
    }

    /// Record culling of `data` (at least one) for view slots `[first, first + count)`.
    void encode(WGPUCommandEncoder encoder, scope StaticGpuData*[] data, uint first, uint count) nothrow @nogc @trusted {
        foreach (d; data) {
            d.flushGroups(queue);
            foreach (s; first .. first + count) d.ensureView(device, dataLayout, s);
        }
        WGPUComputePassDescriptor cpd;
        auto pass = wgpuCommandEncoderBeginComputePass(encoder, &cpd);
        foreach (stage; 0 .. 3) {
            wgpuComputePassEncoderSetPipeline(pass, stage == 0 ? cullPipe : stage == 1 ? sumPipe : scatterPipe);
            foreach (s; first .. first + count) {
                uint offset = s * cast(uint) CullViewUbo.sizeof;
                wgpuComputePassEncoderSetBindGroup(pass, 0, viewBg, 1, &offset);
                foreach (d; data) {
                    wgpuComputePassEncoderSetBindGroup(pass, 1, d.views[s].bindGroup, 0, null);
                    immutable n = stage == 1 ? (cast(uint) d.groups.length + 63) / 64 : d.blockCount;
                    wgpuComputePassEncoderDispatchWorkgroups(pass, n, 1, 1);
                }
            }
        }
        wgpuComputePassEncoderEnd(pass);
        wgpuComputePassEncoderRelease(pass);
    }

    void destroy() nothrow @nogc @trusted {
        releaseBindGroup(viewBg);
        viewBg = null;
        foreach (p; [&cullPipe, &sumPipe, &scatterPipe])
            if (*p !is null) { wgpuComputePipelineRelease(*p); *p = null; }
        if (pipeLayout !is null) { wgpuPipelineLayoutRelease(pipeLayout); pipeLayout = null; }
        if (viewLayout !is null) { wgpuBindGroupLayoutRelease(viewLayout); viewLayout = null; }
        if (dataLayout !is null) { wgpuBindGroupLayoutRelease(dataLayout); dataLayout = null; }
        if (csModule !is null) { wgpuShaderModuleRelease(csModule); csModule = null; }
        destroyBuffer(viewBuf);
        viewBuf = null;
    }
}

/// Culling results of one view.
struct StaticCullView {
    WGPUBuffer lods, blockLods, args, visible;
    WGPUBindGroup bindGroup;
}

/// GPU side of one `StaticInstanceBuffer` (`StaticBuildOptions.gpuCull`). Move-only.
struct StaticGpuData {
    MeshPool pool;
    /// CPU copy of the group table, re-uploaded when `dirty`.
    Pod!CullGroup[] groups;
    /// Group indices in indirect-record order (neighbors share state).
    Pod!uint[] order;
    /// Per entry of `groups`: the group of the `StaticInstanceBuffer` it is part of.
    Pod!uint[] partGroup;
    uint blockCount;
    uint argCount;
    uint instanceCount;
    bool dirty = true;
    private WGPUBuffer blockBuf, metaBuf, groupBuf;
    /// Owned by the `StaticInstanceBuffer`.
    private WGPUBuffer instanceBuf;
    StaticCullView[STATIC_CULL_VIEWS] views;
    /// Per instance: the `surfaceParams` slot of its material, read by the
    /// batched shadow stage (`vs_shadow_table`). Null when no material of the
    /// buffer has a surface shader.
    WGPUBuffer paramIndexBuf;
    /// Bind groups of the batched shadow stage, one per surface parameter chunk.
    private WGPUBindGroup[4] tableBindGroups;
    private ushort[4] tableChunks;
    private uint tableCount;

    @disable this(this);

    bool active() const pure nothrow @nogc { return blockCount > 0; }

    /// Features needed by the GPU path.
    static bool supported(ref GpuContext gpu) {
        return gpu.hasFeature(WGPUFeatureName.indirectFirstInstance)
            && gpu.hasFeature(WGPUFeatureName.multiDrawIndirectCount);
    }

    /// `groups` must carry the instance ranges; blocks and buffers are built here. Load time.
    void build(ref GpuContext gpu, CullGroup[] groupTable, uint[] drawOrder, scope const(CullMeta)[] metas,
               WGPUBuffer instances) {
        groupTable = splitCullGroups(groupTable, drawOrder, partGroup);
        auto blocks = buildCullBlocks(groupTable);
        uint arg = 0;
        foreach (gi; drawOrder) {
            groupTable[gi].firstArg = arg;
            arg += groupTable[gi].lodLevels > 1 ? groupTable[gi].lodLevels : 1;
        }
        groups = groupTable;
        order = drawOrder;
        argCount = arg;
        instanceCount = cast(uint) metas.length;
        instanceBuf = instances;
        blockCount = cast(uint) blocks.length;
        auto device = gpu.getDevice();
        auto queue = gpu.getQueue();
        blockBuf = createStorageBuffer(device, blocks.length * CullBlock.sizeof);
        metaBuf = createStorageBuffer(device, metas.length * CullMeta.sizeof);
        groupBuf = createStorageBuffer(device, groups.length * CullGroup.sizeof);
        updateBuffer(queue, blockBuf, blocks);
        updateBuffer(queue, metaBuf, metas);
        dirty = true;
    }

    /// Upload the per-instance surface parameter slots (load time).
    void setParamIndices(ref GpuContext gpu, scope const(uint)[] slots) @trusted {
        destroyBuffer(paramIndexBuf);
        paramIndexBuf = null;
        if (slots.length == 0) return;
        paramIndexBuf = createStorageBuffer(gpu.getDevice(), slots.length * 4UL);
        updateBuffer(gpu.getQueue(), paramIndexBuf, slots);
    }

    /// Bind group of the batched shadow stage for materials of `chunk`, built
    /// on first use. Null when the buffer has no slot table or too many chunks.
    WGPUBindGroup tableBindGroup(WGPUDevice device, WGPUBindGroupLayout layout, ushort chunk) nothrow @nogc @trusted {
        import engine.graphics.surface_params : SURFACE_CHUNK_BYTES, surfaceChunkBuffer;
        import engine.gpu.shaders : SHADOW_TABLE_INDEX_BINDING, SHADOW_TABLE_PARAMS_BINDING;
        if (paramIndexBuf is null || layout is null) return null;
        foreach (i; 0 .. tableCount)
            if (tableChunks[i] == chunk) return tableBindGroups[i];
        auto chunkBuf = surfaceChunkBuffer(chunk);
        if (tableCount >= tableBindGroups.length || chunkBuf is null) return null;
        WGPUBindGroupEntry[2] e;
        e[0].binding = SHADOW_TABLE_PARAMS_BINDING;
        e[0].buffer = chunkBuf;
        e[0].size = SURFACE_CHUNK_BYTES;
        e[1].binding = SHADOW_TABLE_INDEX_BINDING;
        e[1].buffer = paramIndexBuf;
        e[1].size = instanceCount * 4UL;
        WGPUBindGroupDescriptor d;
        d.layout = layout;
        d.entryCount = 2;
        d.entries = e.ptr;
        auto bg = wgpuDeviceCreateBindGroup(device, &d);
        if (bg is null) return null;
        tableChunks[tableCount] = chunk;
        tableBindGroups[tableCount++] = bg;
        return bg;
    }

    /// Rewrite the culling volume of one instance.
    void setMeta(WGPUQueue queue, uint slot, CullMeta m) nothrow @nogc @trusted {
        wgpuQueueWriteBuffer(queue, metaBuf, slot * CullMeta.sizeof, &m, CullMeta.sizeof);
    }

    /// Indirect records of view `slot`, 5 words each. Blocks until the GPU is
    /// done: tests and debugging only.
    uint[] readArgs(ref GpuContext gpu, uint slot) @trusted {
        if (views[slot].args is null) return null;
        auto device = gpu.getDevice();
        immutable bytes = argCount * cast(size_t) INDIRECT_STRIDE;
        auto buf = createBufferWithUsage(device, bytes, WGPUBufferUsage.mapRead | WGPUBufferUsage.copyDst);
        scope(exit) destroyBuffer(buf);
        WGPUCommandEncoderDescriptor ed;
        auto enc = wgpuDeviceCreateCommandEncoder(device, &ed);
        wgpuCommandEncoderCopyBufferToBuffer(enc, views[slot].args, 0, buf, 0, bytes);
        WGPUCommandBufferDescriptor cd;
        auto cb = wgpuCommandEncoderFinish(enc, &cd);
        wgpuQueueSubmit(gpu.getQueue(), 1, &cb);
        wgpuCommandBufferRelease(cb);
        wgpuCommandEncoderRelease(enc);
        static struct Wait { bool done, ok; }
        Wait wait;
        static extern(C) void onMapped(WGPUMapAsyncStatus status, WGPUStringView, void* u1, void*) nothrow @nogc {
            auto p = cast(Wait*) u1;
            p.ok = status == WGPUMapAsyncStatus.success;
            p.done = true;
        }
        WGPUBufferMapCallbackInfo info;
        info.mode = WGPUCallbackMode.allowProcessEvents;
        info.callback = &onMapped;
        info.userdata1 = &wait;
        wgpuBufferMapAsync(buf, WGPUMapMode.read, 0, bytes, info);
        foreach (_; 0 .. 1000) {
            wgpuDevicePoll(device, WGPU_TRUE, null);
            if (wait.done) break;
        }
        if (!wait.ok) return null;
        auto p = cast(const(uint)*) wgpuBufferGetConstMappedRange(buf, 0, bytes);
        auto result = p[0 .. bytes / 4].dup;
        wgpuBufferUnmap(buf);
        return result;
    }

    private void flushGroups(WGPUQueue queue) nothrow @nogc {
        if (!dirty) return;
        dirty = false;
        updateBuffer(queue, groupBuf, groups);
    }

    private void ensureView(WGPUDevice device, WGPUBindGroupLayout layout, uint slot) nothrow @nogc @trusted {
        auto v = &views[slot];
        if (v.bindGroup !is null) return;
        immutable ulong outBytes = cast(ulong) instanceCount * TexInstanceData.sizeof;
        v.lods = createBufferWithUsage(device, instanceCount * 4UL, WGPUBufferUsage.storage);
        v.blockLods = createBufferWithUsage(device, blockCount * 32UL, WGPUBufferUsage.storage);
        v.args = createBufferWithUsage(device, argCount * cast(ulong) INDIRECT_STRIDE,
            WGPUBufferUsage.storage | WGPUBufferUsage.indirect | WGPUBufferUsage.copySrc);
        v.visible = createBufferWithUsage(device, outBytes, WGPUBufferUsage.storage | WGPUBufferUsage.vertex);
        WGPUBuffer[8] bufs = [blockBuf, metaBuf, groupBuf, v.lods, v.blockLods, v.args, instanceBuf, v.visible];
        ulong[8] sizes = [blockCount * CullBlock.sizeof, instanceCount * CullMeta.sizeof,
                          groups.length * CullGroup.sizeof, instanceCount * 4UL, blockCount * 32UL,
                          argCount * cast(ulong) INDIRECT_STRIDE, outBytes, outBytes];
        WGPUBindGroupEntry[8] e;
        foreach (i, ref x; e) {
            x.binding = cast(uint) i;
            x.buffer = bufs[i];
            x.size = sizes[i];
        }
        WGPUBindGroupDescriptor d;
        d.layout = layout;
        d.entryCount = e.length;
        d.entries = e.ptr;
        v.bindGroup = wgpuDeviceCreateBindGroup(device, &d);
    }

    void destroy() nothrow @nogc {
        pool.destroy();
        foreach (ref v; views) {
            releaseBindGroup(v.bindGroup);
            destroyBuffer(v.lods);
            destroyBuffer(v.blockLods);
            destroyBuffer(v.args);
            destroyBuffer(v.visible);
            v = StaticCullView.init;
        }
        foreach (ref bg; tableBindGroups[0 .. tableCount]) releaseBindGroup(bg);
        tableCount = 0;
        destroyBuffer(paramIndexBuf);
        paramIndexBuf = null;
        destroyBuffer(blockBuf);
        destroyBuffer(metaBuf);
        destroyBuffer(groupBuf);
        blockBuf = null;
        metaBuf = null;
        groupBuf = null;
        blockCount = 0;
    }
}

/// Culling volume of one instance from its world-space sphere.
CullMeta cullMetaOf(BoundingSphere world, float scale) pure nothrow @nogc {
    return CullMeta([world.center.x, world.center.y, world.center.z], scale,
                    [world.radius, world.radius, world.radius], world.radius);
}

@("staticCull.blocks") @safe unittest {
    CullGroup[3] g;
    g[0].first = 0;   g[0].count = 130;
    g[1].first = 130; g[1].count = 64;
    g[2].first = 194; g[2].count = 1;
    auto b = buildCullBlocks(g[]);
    assert(b.length == 5);
    assert(g[0].firstBlock == 0 && g[0].blockCount == 3);
    assert(g[1].firstBlock == 3 && g[1].blockCount == 1);
    assert(g[2].firstBlock == 4 && g[2].blockCount == 1);
    assert(b[2] == CullBlock(0, 128, 2) && b[3] == CullBlock(1, 130, 64) && b[4] == CullBlock(2, 194, 1));
    uint total = 0;
    foreach (ref x; b) total += x.count;
    assert(total == 195);
}

@("staticCull.viewUbo") @safe nothrow @nogc unittest {
    import engine.graphics.lod : projectedPixels;
    Frustum f;
    auto u = CullViewUbo.make(f, Vec3(1, 2, 3), 1, 0.9f, 1080, CULL_DISTANCE, null);
    immutable a = u.params[0] * 2.5f / 40, b = projectedPixels(2.5f, 40, 0.9f, 1080);
    assert(a > b * 0.9999f && a < b * 1.0001f);
    assert(u.flags[0] == CULL_DISTANCE);
    ReceiverCull rc;
    u = CullViewUbo.make(f, Vec3(0, 0, 0), 1, 0.9f, 1080, CULL_SHADOW, &rc);
    assert(u.flags[0] == (CULL_SHADOW | CULL_RECEIVER) && u.sweep[3] == rc.drop);
}

@("staticCull.parts") @safe unittest {
    CullGroup[2] g;
    g[0].count = 2500;
    g[0].firstArg = 7;
    g[1].first = 2500;
    g[1].count = 10;
    uint[] order = [1, 0], map;
    auto p = splitCullGroups(g[], order, map);
    assert(p.length == 4 && map == [0, 0, 0, 1] && order == [3, 0, 1, 2]);
    assert(p[0].first == 0 && p[0].count == 1024 && p[1].first == 1024 && p[2].first == 2048 && p[2].count == 452);
    assert(p[3].first == 2500 && p[3].count == 10);
    foreach (ref x; buildCullBlocks(p)) assert(x.count > 0);
    foreach (ref x; p) assert(x.blockCount <= STATIC_CULL_PART_BLOCKS);
}
