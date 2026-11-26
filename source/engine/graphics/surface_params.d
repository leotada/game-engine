/**
 * Shared storage of the `surfaceParams` blocks of every `Material`.
 *
 * Each material owns one 256-byte slot in a chunk buffer (256 slots per
 * chunk). The color pass binds the slot as the material's uniform (binding 7
 * of the material group, offset = slot * 256). Batched shadow passes bind the
 * whole chunk as a storage array and pick the slot per instance.
 *
 * `Material.updateSurfaceParams` only writes a CPU mirror. `flushSurfaceParams`
 * uploads the dirty slots of each chunk in one queue write; `Renderer.endFrame`
 * calls it before the frame is submitted, so a game that updates 66 materials
 * per frame issues one write instead of 66.
 */
module engine.graphics.surface_params;

import bindings.wgpu;
import core.stdc.stdlib : calloc, free;

@safe:

/// Bytes between two slots: the WebGPU uniform offset alignment ceiling.
enum uint SURFACE_SLOT_BYTES = 256;
/// Floats a material writes (`p0 .. p3`).
enum uint SURFACE_SLOT_FLOATS = 16;
/// Slots per chunk buffer (64 KB).
enum uint SURFACE_CHUNK_SLOTS = 256;
enum uint SURFACE_CHUNK_BYTES = SURFACE_SLOT_BYTES * SURFACE_CHUNK_SLOTS;

/// Where a material's block lives. `chunk == ushort.max` means none.
struct SurfaceSlot {
    ushort chunk = ushort.max;
    ushort index;

    bool valid() const pure nothrow @nogc { return chunk != ushort.max; }
    /// Byte offset of the slot in its chunk buffer.
    uint offset() const pure nothrow @nogc { return index * SURFACE_SLOT_BYTES; }
}

private enum uint MAX_CHUNKS = 64;
private enum uint WORDS = SURFACE_CHUNK_SLOTS / 64;

private struct Chunk {
    WGPUDevice device;
    WGPUBuffer buffer;
    /// In use (a null `device` makes a CPU-only chunk, for tests).
    bool live;
    /// CPU mirror laid out like the buffer (256-byte slots).
    float* mirror;
    ulong[WORDS] used;
    uint usedCount;
    uint dirtyLo = uint.max, dirtyHi;
}

private struct Pool {
    Chunk[MAX_CHUNKS] chunks;
    uint count;
    uint writes; /// queue writes issued by `flushSurfaceParams` (tests)
}

private __gshared Pool gPool;

/// Allocate a zeroed slot on `device`. Returns an invalid slot when the buffer
/// cannot be created or every chunk is full.
SurfaceSlot allocSurfaceSlot(WGPUDevice device) nothrow @nogc @trusted {
    foreach (c; 0 .. gPool.count) {
        auto ch = &gPool.chunks[c];
        if (!ch.live || ch.device !is device || ch.usedCount >= SURFACE_CHUNK_SLOTS) continue;
        foreach (w; 0 .. WORDS) {
            if (ch.used[w] == ulong.max) continue;
            foreach (b; 0 .. 64)
                if ((ch.used[w] & (1UL << b)) == 0) {
                    immutable idx = cast(ushort) (w * 64 + b);
                    ch.used[w] |= 1UL << b;
                    ch.usedCount++;
                    ch.mirror[idx * (SURFACE_SLOT_BYTES / 4) .. idx * (SURFACE_SLOT_BYTES / 4) + SURFACE_SLOT_FLOATS] = 0;
                    markDirty(*ch, idx);
                    return SurfaceSlot(cast(ushort) c, idx);
                }
        }
    }
    if (gPool.count >= MAX_CHUNKS) return SurfaceSlot.init;
    // Reuse an emptied chunk of a released device first.
    uint c = gPool.count;
    foreach (i; 0 .. gPool.count)
        if (!gPool.chunks[i].live) { c = i; break; }
    auto ch = &gPool.chunks[c];
    if (ch.mirror is null) ch.mirror = cast(float*) calloc(SURFACE_CHUNK_BYTES, 1);
    if (ch.mirror is null) return SurfaceSlot.init;
    if (device !is null) {
        WGPUBufferDescriptor desc;
        desc.usage = WGPUBufferUsage.uniform | WGPUBufferUsage.storage | WGPUBufferUsage.copyDst;
        desc.size = SURFACE_CHUNK_BYTES;
        ch.buffer = wgpuDeviceCreateBuffer(device, &desc);
        if (ch.buffer is null) return SurfaceSlot.init;
    }
    ch.live = true;
    ch.device = device;
    ch.used[] = 0;
    ch.usedCount = 0;
    ch.dirtyLo = uint.max;
    ch.dirtyHi = 0;
    if (c == gPool.count) gPool.count++;
    return allocSurfaceSlot(device);
}

/// Return a slot. The chunk buffer is released when its last slot goes.
void freeSurfaceSlot(ref SurfaceSlot s) nothrow @nogc @trusted {
    if (!s.valid || s.chunk >= gPool.count) { s = SurfaceSlot.init; return; }
    auto ch = &gPool.chunks[s.chunk];
    immutable w = s.index / 64, b = s.index % 64;
    if ((ch.used[w] & (1UL << b)) != 0) {
        ch.used[w] &= ~(1UL << b);
        ch.usedCount--;
        if (ch.usedCount == 0) {
            if (ch.buffer !is null) {
                wgpuBufferDestroy(ch.buffer);
                wgpuBufferRelease(ch.buffer);
            }
            ch.buffer = null;
            ch.live = false;
            ch.device = null;
            ch.dirtyLo = uint.max;
            ch.dirtyHi = 0;
        }
    }
    s = SurfaceSlot.init;
}

/// Store `values` for the next `flushSurfaceParams`.
void setSurfaceParams(SurfaceSlot s, in float[SURFACE_SLOT_FLOATS] values) nothrow @nogc @trusted {
    if (!s.valid || s.chunk >= gPool.count) return;
    auto ch = &gPool.chunks[s.chunk];
    if (ch.mirror is null) return;
    auto dst = ch.mirror[s.index * (SURFACE_SLOT_BYTES / 4) .. s.index * (SURFACE_SLOT_BYTES / 4) + SURFACE_SLOT_FLOATS];
    if (dst[] == values[]) return;
    dst[] = values[];
    markDirty(*ch, s.index);
}

/// The values last stored for `s` (zeros for an invalid slot).
float[SURFACE_SLOT_FLOATS] surfaceParamsOf(SurfaceSlot s) nothrow @nogc @trusted {
    float[SURFACE_SLOT_FLOATS] r = 0;
    if (!s.valid || s.chunk >= gPool.count || gPool.chunks[s.chunk].mirror is null) return r;
    r[] = gPool.chunks[s.chunk].mirror[s.index * (SURFACE_SLOT_BYTES / 4) .. s.index * (SURFACE_SLOT_BYTES / 4) + SURFACE_SLOT_FLOATS];
    return r;
}

/// Chunk buffer of a slot (null for an invalid slot).
WGPUBuffer surfaceChunkBuffer(uint chunk) nothrow @nogc @trusted {
    return chunk < gPool.count ? gPool.chunks[chunk].buffer : null;
}

/// Upload the slots changed since the last flush: one queue write per dirty chunk.
void flushSurfaceParams(WGPUQueue queue) nothrow @nogc @trusted {
    foreach (c; 0 .. gPool.count) {
        auto ch = &gPool.chunks[c];
        if (!ch.live || ch.dirtyLo == uint.max) continue;
        if (queue !is null && ch.buffer !is null) {
            immutable lo = ch.dirtyLo * SURFACE_SLOT_BYTES;
            immutable bytes = (ch.dirtyHi - ch.dirtyLo) * SURFACE_SLOT_BYTES + SURFACE_SLOT_FLOATS * 4;
            wgpuQueueWriteBuffer(queue, ch.buffer, lo, cast(const(void)*) (cast(ubyte*) ch.mirror + lo), bytes);
            gPool.writes++;
        }
        ch.dirtyLo = uint.max;
        ch.dirtyHi = 0;
    }
}

/// Queue writes issued so far (for tests and stats).
uint surfaceParamWrites() nothrow @nogc @trusted { return gPool.writes; }

private void markDirty(ref Chunk ch, uint idx) nothrow @nogc {
    if (idx < ch.dirtyLo) ch.dirtyLo = idx;
    if (idx > ch.dirtyHi) ch.dirtyHi = idx;
}

@("surface_params.cpu pool") unittest {
    // CPU-only chunk (null device): allocation, dirty tracking, reuse and release.
    auto a = allocSurfaceSlot(null), b = allocSurfaceSlot(null);
    assert(a.valid && b.valid && a.chunk == b.chunk && a.index != b.index);
    float[SURFACE_SLOT_FLOATS] v = 0;
    v[0] = 1; v[15] = 2;
    setSurfaceParams(b, v);
    assert(surfaceParamsOf(b) == v && surfaceParamsOf(a)[0] == 0);
    flushSurfaceParams(null);
    immutable w = surfaceParamWrites();
    setSurfaceParams(b, v);            // unchanged: nothing to upload
    flushSurfaceParams(null);
    assert(surfaceParamWrites() == w);
    immutable ai = a.index;
    freeSurfaceSlot(a);
    assert(!a.valid);
    auto c = allocSurfaceSlot(null);   // reuses the freed slot, zeroed
    assert(c.index == ai && surfaceParamsOf(c)[0] == 0);
    freeSurfaceSlot(b);
    freeSurfaceSlot(c);
}

@("surface_params.slot offsets") unittest {
    SurfaceSlot s = SurfaceSlot(0, 3);
    assert(s.valid && s.offset == 768);
    assert(!SurfaceSlot.init.valid);
    static assert(SURFACE_CHUNK_BYTES == 65536);
}
