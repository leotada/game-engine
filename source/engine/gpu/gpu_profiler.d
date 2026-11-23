/// Per-pass GPU timings from timestamp queries, fed into `engine.devtools.profiler` as
/// `ZoneKind.gpu` zones.
///
/// Scopes write a timestamp pair into one query set per frame:
///
/// ---
/// { auto g = gpuScope!"gpu.shadows"(frame.encoder); ... }   // between passes
/// { auto g = gpuPassScope!"gpu.opaque"(frame.pass); ... }   // inside one render pass
/// immutable s = gpuPassBegin!"gpu.sky"(pass); ...; gpuPassEnd(s, pass);  // explicit form
/// ---
///
/// A pass scope must begin and end on the same pass object: never let one span
/// `suspendScenePass`/`resumeScenePass`. Encoder scopes must not be recorded while a pass is
/// open on that encoder.
///
/// `Renderer.endFrame` resolves the queries into one of `GPU_READBACK_SLOTS` mappable buffers
/// and maps it asynchronously; `Renderer.beginFrame` polls the device and commits finished
/// frames (2-3 frames late). Every scope is a child of the root zone "gpu.frame", which holds
/// the span from the first to the last timestamp of the frame. Inactive (profiler off, or the
/// device lacks the timestamp features: `GpuContext.timestampsSupported`) means no-op.
module engine.gpu.gpu_profiler;

import bindings.wgpu;
import engine.devtools.profiler;

@safe:

enum uint MAX_GPU_SCOPES = 256;     /// scopes per frame
enum uint GPU_READBACK_SLOTS = 4;   /// frames in flight
enum uint NO_GPU_SCOPE = uint.max;
private enum uint MAX_GPU_DEPTH = 16;

private struct Slot {
    WGPUBuffer buf;
    bool inFlight, mapped, failed;
    uint scopes;
    long submitNs;
    ushort[MAX_GPU_SCOPES] zone;
    ubyte[MAX_GPU_SCOPES] depth;
}

private struct GpuProfilerState {
    bool supported, created, frameDropped;
    WGPUDevice device;
    WGPUQueue queue;
    WGPUQuerySet querySet;
    WGPUBuffer resolveBuf;
    float periodNs = 1;
    Slot[GPU_READBACK_SLOTS] slots;
    // frame being recorded
    uint scopes;
    ushort[MAX_GPU_SCOPES] zone;
    ubyte[MAX_GPU_SCOPES] depth;
    uint[MAX_GPU_DEPTH] open;
    uint openDepth;
    ushort frameZone = NO_ZONE;
    uint droppedFrames;
    int pendingSlot = -1;
}

private GpuProfilerState gp; // thread-local: the render thread

/// Called by `Renderer.create`. Resources are created lazily once the profiler is enabled.
void gpuProfilerInit(WGPUDevice device, WGPUQueue queue, bool timestampsSupported) nothrow @nogc {
    gp.device = device;
    gp.queue = queue;
    gp.supported = timestampsSupported;
}

/// True while scopes are being recorded this frame.
bool gpuProfilerActive() nothrow @nogc {
    return gp.supported && profilerEnabled() && ensureCreated() && !gp.frameDropped;
}

/// Frames skipped because every readback slot was still in flight.
uint gpuProfilerDroppedFrames() nothrow @nogc { return gp.droppedFrames; }

/// Whether the device can time GPU work at all.
bool gpuProfilerSupported() nothrow @nogc { return gp.supported; }

private bool ensureCreated() nothrow @nogc @trusted {
    if (gp.created)
        return true;
    if (!gp.supported || gp.device is null)
        return false;
    WGPUQuerySetDescriptor qd;
    qd.type = WGPUQueryType.timestamp;
    qd.count = MAX_GPU_SCOPES * 2;
    gp.querySet = wgpuDeviceCreateQuerySet(gp.device, &qd);
    WGPUBufferDescriptor rd;
    rd.usage = cast(WGPUBufferUsage)(WGPUBufferUsage.queryResolve | WGPUBufferUsage.copySrc);
    rd.size = MAX_GPU_SCOPES * 2 * ulong.sizeof;
    gp.resolveBuf = wgpuDeviceCreateBuffer(gp.device, &rd);
    foreach (ref s; gp.slots) {
        WGPUBufferDescriptor bd;
        bd.usage = cast(WGPUBufferUsage)(WGPUBufferUsage.mapRead | WGPUBufferUsage.copyDst);
        bd.size = rd.size;
        s.buf = wgpuDeviceCreateBuffer(gp.device, &bd);
    }
    gp.periodNs = wgpuQueueGetTimestampPeriod(gp.queue);
    if (!(gp.periodNs > 0))
        gp.periodNs = 1;
    gp.created = gp.querySet !is null && gp.resolveBuf !is null;
    if (!gp.created)
        gp.supported = false;
    gp.frameZone = registerZone("gpu.frame", ZoneKind.gpu, NO_ZONE, 0);
    return gp.created;
}

/// Release the query set and buffers (`Renderer.destroy`).
void gpuProfilerDestroy() nothrow @nogc @trusted {
    if (!gp.created)
        return;
    foreach (ref s; gp.slots) {
        if (s.mapped)
            wgpuBufferUnmap(s.buf);
        if (s.buf !is null)
            wgpuBufferRelease(s.buf);
        s = Slot.init;
    }
    wgpuBufferRelease(gp.resolveBuf);
    wgpuQuerySetRelease(gp.querySet);
    gp.resolveBuf = null;
    gp.querySet = null;
    gp.created = false;
}

// ----------------------------------------------------------------------------- scopes

/// Register a GPU zone under the innermost open GPU scope (or "gpu.frame").
private ushort gpuZoneId(string name)() nothrow @nogc {
    static ushort id = NO_ZONE;
    if (id == NO_ZONE) {
        immutable parent = gp.openDepth ? gp.zone[gp.open[gp.openDepth - 1]] : gp.frameZone;
        id = registerZone(name, ZoneKind.gpu, parent, cast(ubyte)(gp.openDepth + 1));
    }
    return id;
}

private uint allocScope(ushort zoneId) nothrow @nogc {
    if (zoneId == NO_ZONE || gp.scopes >= MAX_GPU_SCOPES || gp.openDepth >= MAX_GPU_DEPTH)
        return NO_GPU_SCOPE;
    immutable s = gp.scopes++;
    gp.zone[s] = zoneId;
    gp.depth[s] = cast(ubyte)(gp.openDepth + 1);
    gp.open[gp.openDepth++] = s;
    return s;
}

private void closeScope(uint s) nothrow @nogc {
    if (gp.openDepth && gp.open[gp.openDepth - 1] == s)
        --gp.openDepth;
}

/// Begin a scope on a command encoder (no pass may be open on it). Returns the scope index.
uint gpuEncoderBegin(string name)(WGPUCommandEncoder enc) nothrow @nogc @trusted {
    if (enc is null || !gpuProfilerActive())
        return NO_GPU_SCOPE;
    immutable s = allocScope(gpuZoneId!name());
    if (s != NO_GPU_SCOPE)
        wgpuCommandEncoderWriteTimestamp(enc, gp.querySet, s * 2);
    return s;
}

void gpuEncoderEnd(uint s, WGPUCommandEncoder enc) nothrow @nogc @trusted {
    if (s == NO_GPU_SCOPE || enc is null || !gp.created)
        return;
    wgpuCommandEncoderWriteTimestamp(enc, gp.querySet, s * 2 + 1);
    closeScope(s);
}

/// Begin a scope inside a render pass. End it on the same pass object.
uint gpuPassBegin(string name)(WGPURenderPassEncoder pass) nothrow @nogc @trusted {
    if (pass is null || !gpuProfilerActive())
        return NO_GPU_SCOPE;
    immutable s = allocScope(gpuZoneId!name());
    if (s != NO_GPU_SCOPE)
        wgpuRenderPassEncoderWriteTimestamp(pass, gp.querySet, s * 2);
    return s;
}

void gpuPassEnd(uint s, WGPURenderPassEncoder pass) nothrow @nogc @trusted {
    if (s == NO_GPU_SCOPE || pass is null || !gp.created)
        return;
    wgpuRenderPassEncoderWriteTimestamp(pass, gp.querySet, s * 2 + 1);
    closeScope(s);
}

/// Begin a scope inside a compute pass.
uint gpuComputeBegin(string name)(WGPUComputePassEncoder pass) nothrow @nogc @trusted {
    if (pass is null || !gpuProfilerActive())
        return NO_GPU_SCOPE;
    immutable s = allocScope(gpuZoneId!name());
    if (s != NO_GPU_SCOPE)
        wgpuComputePassEncoderWriteTimestamp(pass, gp.querySet, s * 2);
    return s;
}

void gpuComputeEnd(uint s, WGPUComputePassEncoder pass) nothrow @nogc @trusted {
    if (s == NO_GPU_SCOPE || pass is null || !gp.created)
        return;
    wgpuComputePassEncoderWriteTimestamp(pass, gp.querySet, s * 2 + 1);
    closeScope(s);
}

/// RAII scope over an encoder or a pass (see the module notes on pass lifetimes).
struct GpuScope {
    private uint s = NO_GPU_SCOPE;
    private void* target;
    private ubyte kind; // 0 encoder, 1 render pass, 2 compute pass
    @disable this(this);
    ~this() nothrow @nogc {
        final switch (kind) {
            case 0: gpuEncoderEnd(s, target); break;
            case 1: gpuPassEnd(s, target); break;
            case 2: gpuComputeEnd(s, target); break;
        }
    }
}

GpuScope gpuScope(string name)(WGPUCommandEncoder enc) nothrow @nogc {
    return GpuScope(gpuEncoderBegin!name(enc), enc, 0);
}

GpuScope gpuPassScope(string name)(WGPURenderPassEncoder pass) nothrow @nogc {
    return GpuScope(gpuPassBegin!name(pass), pass, 1);
}

GpuScope gpuComputeScope(string name)(WGPUComputePassEncoder pass) nothrow @nogc {
    return GpuScope(gpuComputeBegin!name(pass), pass, 2);
}

// ----------------------------------------------------------------------------- frame cycle

/// Before `wgpuCommandEncoderFinish` of the frame's last encoder (no pass open): resolve the
/// frame's queries into a free readback slot.
void gpuProfilerResolve(WGPUCommandEncoder enc) nothrow @nogc @trusted {
    gp.pendingSlot = -1;
    if (!gp.created || enc is null || gp.scopes == 0 || gp.frameDropped) {
        resetFrame();
        return;
    }
    int free = -1;
    foreach (i, ref s; gp.slots)
        if (!s.inFlight) {
            free = cast(int) i;
            break;
        }
    if (free < 0) {
        ++gp.droppedFrames;
        resetFrame();
        return;
    }
    auto slot = &gp.slots[free];
    immutable n = gp.scopes;
    immutable bytes = cast(ulong) n * 2 * ulong.sizeof;
    wgpuCommandEncoderResolveQuerySet(enc, gp.querySet, 0, n * 2, gp.resolveBuf, 0);
    wgpuCommandEncoderCopyBufferToBuffer(enc, gp.resolveBuf, 0, slot.buf, 0, bytes);
    slot.scopes = n;
    slot.zone[0 .. n] = gp.zone[0 .. n];
    slot.depth[0 .. n] = gp.depth[0 .. n];
    slot.inFlight = true;
    slot.mapped = false;
    slot.failed = false;
    gp.pendingSlot = free;
    resetFrame();
}

/// The frame was dropped before submit (e.g. swapchain unavailable): forget its scopes.
void gpuProfilerDiscardFrame() nothrow @nogc {
    gp.pendingSlot = -1;
    resetFrame();
}

private void resetFrame() nothrow @nogc {
    gp.scopes = 0;
    gp.openDepth = 0;
    gp.frameDropped = false;
}

private extern (C) void onSlotMapped(WGPUMapAsyncStatus status, WGPUStringView, void* u1, void*) nothrow @nogc @trusted {
    auto s = cast(Slot*) u1;
    s.mapped = status == WGPUMapAsyncStatus.success;
    s.failed = !s.mapped;
}

/// After `wgpuQueueSubmit`: start mapping the slot resolved this frame.
void gpuProfilerAfterSubmit() nothrow @nogc @trusted {
    if (gp.pendingSlot < 0)
        return;
    auto slot = &gp.slots[gp.pendingSlot];
    gp.pendingSlot = -1;
    slot.submitNs = profilerNowNs();
    WGPUBufferMapCallbackInfo cb;
    cb.mode = WGPUCallbackMode.allowProcessEvents;
    cb.callback = &onSlotMapped;
    cb.userdata1 = cast(void*) slot;
    wgpuBufferMapAsync(slot.buf, WGPUMapMode.read, 0, cast(size_t) slot.scopes * 2 * ulong.sizeof, cb);
}

/// Start of a frame: poll the device (non-blocking) and commit every finished frame.
void gpuProfilerCollect() nothrow @nogc @trusted {
    if (!gp.created)
        return;
    bool any = false;
    foreach (ref s; gp.slots)
        any = any || (s.inFlight && !s.mapped && !s.failed);
    if (any)
        wgpuDevicePoll(gp.device, WGPU_FALSE, null);
    // Oldest first, so the trace and the history keep submission order.
    foreach (_; 0 .. GPU_READBACK_SLOTS) {
        Slot* next = null;
        foreach (ref s; gp.slots)
            if (s.inFlight && (s.mapped || s.failed) && (next is null || s.submitNs < next.submitNs))
                next = &s;
        if (next is null)
            break;
        commitSlot(*next);
    }
}

private void commitSlot(ref Slot s) nothrow @nogc @trusted {
    if (s.mapped) {
        immutable bytes = cast(size_t) s.scopes * 2 * ulong.sizeof;
        auto ts = cast(const(ulong)*) wgpuBufferGetConstMappedRange(s.buf, 0, bytes);
        if (ts !is null) {
            ulong first = ulong.max, last = 0;
            foreach (i; 0 .. s.scopes) {
                immutable b = ts[i * 2], e = ts[i * 2 + 1];
                if (b == 0 || e < b)
                    continue; // never written (scope not ended) or bogus
                if (b < first) first = b;
                if (e > last) last = e;
            }
            if (first != ulong.max) {
                foreach (i; 0 .. s.scopes) {
                    immutable b = ts[i * 2], e = ts[i * 2 + 1];
                    if (b == 0 || e < b)
                        continue;
                    addZoneTime(s.zone[i], (e - b) * gp.periodNs / 1e6);
                    traceEvent(s.zone[i], s.depth[i], ZoneKind.gpu,
                        s.submitNs + cast(long)((b - first) * gp.periodNs),
                        s.submitNs + cast(long)((e - first) * gp.periodNs));
                }
                if (gp.frameZone != NO_ZONE) {
                    addZoneTime(gp.frameZone, (last - first) * gp.periodNs / 1e6);
                    traceEvent(gp.frameZone, 0, ZoneKind.gpu, s.submitNs,
                        s.submitNs + cast(long)((last - first) * gp.periodNs));
                }
                profilerEndGpuFrame();
            }
        }
        wgpuBufferUnmap(s.buf);
    }
    s.inFlight = false;
    s.mapped = false;
    s.failed = false;
    s.scopes = 0;
}
